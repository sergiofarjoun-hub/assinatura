-- =============================================================================
-- Módulo de Comunicação — Hamsa IPMI
-- Schema PostgreSQL 16 (schema "comunicacao")
--
-- PRÉ-REQUISITO: cadastro/schema.sql já aplicado (consentimento LGPD mora lá).
-- Idempotente. Desenho: ver README.md nesta pasta.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS comunicacao;
SET search_path TO comunicacao;

-- -----------------------------------------------------------------------------
-- Provedores por canal. Credencial NUNCA no banco: guarda-se o NOME da
-- variável de ambiente que o worker lê (ex.: 'TWILIO_AUTH_TOKEN').
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS provedor (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    canal          text NOT NULL CHECK (canal IN ('whatsapp','email')),
    nome           text NOT NULL,                 -- twilio, meta, smtp…
    config         jsonb NOT NULL DEFAULT '{}',   -- host, remetente, numero…
    credencial_env text NOT NULL,                 -- nome da env var no worker
    ativo          boolean NOT NULL DEFAULT true,
    UNIQUE (canal, nome)
);
-- no máximo 1 provedor ativo por canal
CREATE UNIQUE INDEX IF NOT EXISTS uq_provedor_ativo ON provedor (canal) WHERE ativo;

-- -----------------------------------------------------------------------------
-- Templates versionados. Editar corpo = nova versão (INSERT), nunca UPDATE
-- do corpo — a mensagem enviada referencia a versão exata que o cliente viu.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS template (
    id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo                 text NOT NULL,          -- ex.: renovacao_d30
    versao                 int  NOT NULL DEFAULT 1,
    canal                  text NOT NULL CHECK (canal IN ('whatsapp','email')),
    idioma                 text NOT NULL DEFAULT 'pt-BR',
    finalidade             text NOT NULL DEFAULT 'operacional'
                           CHECK (finalidade IN ('operacional','marketing')),
    assunto                text,                   -- e-mail
    corpo                  text NOT NULL,          -- placeholders {{variavel}}
    variaveis              jsonb NOT NULL DEFAULT '[]',  -- nomes esperados
    whatsapp_template_name text,                   -- template aprovado na Meta
    ativo                  boolean NOT NULL DEFAULT true,
    criado_em              timestamptz NOT NULL DEFAULT now(),
    UNIQUE (codigo, versao),
    CHECK (canal <> 'whatsapp' OR whatsapp_template_name IS NOT NULL)
);
-- no máximo 1 versão ativa por código
CREATE UNIQUE INDEX IF NOT EXISTS uq_template_ativo ON template (codigo) WHERE ativo;

-- -----------------------------------------------------------------------------
-- Fila + histórico de mensagens (outbound)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS mensagem (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pessoa_id           bigint NOT NULL REFERENCES cadastro.pessoa(id),
    template_id         bigint NOT NULL REFERENCES template(id),
    canal               text NOT NULL CHECK (canal IN ('whatsapp','email')),
    destino             text NOT NULL,             -- e164 ou e-mail no momento do enfileiramento
    corpo_renderizado   text NOT NULL,
    contexto            jsonb NOT NULL DEFAULT '{}',  -- {"modulo":"renovacoes","ref":"ciclo:123"}
    status              text NOT NULL DEFAULT 'na_fila'
                        CHECK (status IN ('na_fila','enviada','entregue','lida',
                                          'falha','bloqueada_sem_consentimento','cancelada')),
    agendada_para       timestamptz NOT NULL DEFAULT now(),
    enviada_em          timestamptz,
    provider_message_id text,
    tentativas          int NOT NULL DEFAULT 0,
    ultimo_erro         text,
    criado_em           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_mensagem_fila
    ON mensagem (agendada_para) WHERE status = 'na_fila';
CREATE INDEX IF NOT EXISTS idx_mensagem_pessoa   ON mensagem (pessoa_id, criado_em DESC);
CREATE INDEX IF NOT EXISTS idx_mensagem_contexto ON mensagem USING gin (contexto);

-- Inbound (fase 2): respostas de WhatsApp via webhook
CREATE TABLE IF NOT EXISTS mensagem_recebida (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pessoa_id     bigint REFERENCES cadastro.pessoa(id),  -- NULL = telefone não reconhecido
    canal         text NOT NULL DEFAULT 'whatsapp' CHECK (canal IN ('whatsapp','email')),
    origem        text NOT NULL,                  -- e164 / e-mail remetente
    corpo         text NOT NULL,
    provider_id   text,
    recebida_em   timestamptz NOT NULL DEFAULT now(),
    tratada_em    timestamptz                     -- alguém do time viu/respondeu
);
CREATE INDEX IF NOT EXISTS idx_recebida_nao_tratada
    ON mensagem_recebida (recebida_em) WHERE tratada_em IS NULL;

-- =============================================================================
-- enfileirar(): o único jeito correto de mandar mensagem.
-- Aplica a regra LGPD:
--   marketing    → exige opt-in vigente (concedido, não revogado) no canal
--   operacional  → permitido, salvo revogação explícita vigente no canal
-- Sem base legal → grava com status 'bloqueada_sem_consentimento' e retorna
-- o id mesmo assim (fica no log/relatório, não vai ao provedor).
-- =============================================================================
CREATE OR REPLACE FUNCTION enfileirar(
    p_pessoa   bigint,
    p_template_codigo text,
    p_contexto jsonb DEFAULT '{}',
    p_variaveis jsonb DEFAULT '{}',
    p_quando   timestamptz DEFAULT now()
) RETURNS bigint
LANGUAGE plpgsql SET search_path = comunicacao AS $$
DECLARE
    t          template%ROWTYPE;
    v_destino  text;
    v_corpo    text;
    v_permitido boolean;
    v_status   text;
    v_id       bigint;
    k          text;
BEGIN
    SELECT * INTO t FROM template WHERE codigo = p_template_codigo AND ativo;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'template ativo não encontrado: %', p_template_codigo;
    END IF;

    SELECT CASE WHEN t.canal = 'whatsapp' THEN p.telefone_e164 ELSE p.email END
      INTO v_destino
      FROM cadastro.pessoa p
     WHERE p.id = p_pessoa AND p.mesclada_em IS NULL AND p.anonimizada_em IS NULL;
    IF v_destino IS NULL THEN
        RAISE EXCEPTION 'pessoa % sem destino para o canal % (ou anonimizada)', p_pessoa, t.canal;
    END IF;

    IF t.finalidade = 'marketing' THEN
        SELECT EXISTS (
            SELECT 1 FROM cadastro.consentimento c
            WHERE c.pessoa_id = p_pessoa AND c.finalidade = 'marketing'
              AND c.canal = t.canal AND c.revogado_em IS NULL
        ) INTO v_permitido;
    ELSE
        -- operacional: bloqueia só se a revogação mais recente está vigente
        SELECT NOT EXISTS (
            SELECT 1 FROM cadastro.consentimento c
            WHERE c.pessoa_id = p_pessoa AND c.finalidade = 'operacional'
              AND c.canal = t.canal AND c.revogado_em IS NOT NULL
              AND NOT EXISTS (
                  SELECT 1 FROM cadastro.consentimento c2
                  WHERE c2.pessoa_id = p_pessoa AND c2.finalidade = 'operacional'
                    AND c2.canal = t.canal AND c2.revogado_em IS NULL
                    AND c2.concedido_em > c.revogado_em
              )
        ) INTO v_permitido;
    END IF;
    v_status := CASE WHEN v_permitido THEN 'na_fila'
                     ELSE 'bloqueada_sem_consentimento' END;

    -- render simples de {{variavel}} (validação fina fica no app)
    v_corpo := t.corpo;
    FOR k IN SELECT jsonb_object_keys(p_variaveis) LOOP
        v_corpo := replace(v_corpo, '{{' || k || '}}', p_variaveis ->> k);
    END LOOP;

    INSERT INTO mensagem (pessoa_id, template_id, canal, destino,
                          corpo_renderizado, contexto, status, agendada_para)
    VALUES (p_pessoa, t.id, t.canal, v_destino, v_corpo, p_contexto, v_status, p_quando)
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$;

-- =============================================================================
-- Views para o Command Center
-- =============================================================================

CREATE OR REPLACE VIEW v_fila AS
SELECT m.id, p.nome, m.canal, t.codigo AS template, m.agendada_para,
       greatest(0, extract(epoch FROM (now() - m.agendada_para)) / 60)::int AS atraso_min
FROM mensagem m
JOIN cadastro.pessoa p ON p.id = m.pessoa_id
JOIN template t ON t.id = m.template_id
WHERE m.status = 'na_fila'
ORDER BY m.agendada_para;

CREATE OR REPLACE VIEW v_falhas_recentes AS
SELECT m.id, p.nome, m.canal, t.codigo AS template, m.tentativas, m.ultimo_erro, m.criado_em
FROM mensagem m
JOIN cadastro.pessoa p ON p.id = m.pessoa_id
JOIN template t ON t.id = m.template_id
WHERE m.status = 'falha' AND m.criado_em > now() - interval '48 hours'
ORDER BY m.criado_em DESC;

CREATE OR REPLACE VIEW v_bloqueadas AS
SELECT m.id, p.nome, m.canal, t.codigo AS template, t.finalidade, m.criado_em
FROM mensagem m
JOIN cadastro.pessoa p ON p.id = m.pessoa_id
JOIN template t ON t.id = m.template_id
WHERE m.status = 'bloqueada_sem_consentimento'
ORDER BY m.criado_em DESC;

CREATE OR REPLACE VIEW v_engajamento AS
SELECT t.codigo AS template, m.canal,
       count(*)                                        AS enviadas,
       count(*) FILTER (WHERE m.status IN ('entregue','lida')) AS entregues,
       count(*) FILTER (WHERE m.status = 'lida')       AS lidas
FROM mensagem m
JOIN template t ON t.id = m.template_id
WHERE m.criado_em > now() - interval '30 days'
  AND m.status NOT IN ('na_fila','cancelada','bloqueada_sem_consentimento')
GROUP BY t.codigo, m.canal
ORDER BY enviadas DESC;

-- =============================================================================
-- Seeds — templates operacionais mínimos (corpo de exemplo; ajustar no hub)
-- =============================================================================
INSERT INTO template (codigo, canal, finalidade, assunto, corpo, variaveis) VALUES
    ('renovacao_d30', 'email', 'operacional',
     'Sua apólice {{numero}} renova em 30 dias',
     'Olá {{nome}}, a apólice {{numero}} ({{seguradora}}) renova em {{data}}. O novo prêmio anual é {{premio_novo}} ({{pct_reajuste}} de reajuste). Vamos conversar sobre as opções?',
     '["nome","numero","seguradora","data","premio_novo","pct_reajuste"]'),
    ('proposta_assinatura', 'email', 'operacional',
     'Documentos da sua proposta {{seguradora}} para assinatura',
     'Olá {{nome}}, sua proposta na {{seguradora}} está pronta. Assine aqui: {{link_assinatura}}',
     '["nome","seguradora","link_assinatura"]')
ON CONFLICT (codigo, versao) DO NOTHING;
