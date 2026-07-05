-- =============================================================================
-- Módulo de Propostas & Subscrição — Hamsa IPMI
-- Schema PostgreSQL 16 (schema "propostas")
--
-- PRÉ-REQUISITOS: comissoes/schema.sql e cadastro/schema.sql já aplicados.
-- Idempotente. Desenho: ver README.md nesta pasta.
--
-- LGPD: declaração de saúde e laudos NUNCA entram estruturados — só o
-- documento (referência + hash + status). Ver README §4.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS propostas;
SET search_path TO propostas;

CREATE TABLE IF NOT EXISTS proposta (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cliente_id         bigint NOT NULL REFERENCES cadastro.cliente(id),
    seguradora_id      bigint NOT NULL REFERENCES comissoes.seguradora(id),
    produto_id         bigint REFERENCES comissoes.produto(id),
    cotacao_ref        text,                      -- id/URL da cotação no Multi Cálculo
    premio_cotado      numeric(14,2),
    moeda              char(3),
    inicio_desejado    date,
    corretor           text,
    status             text NOT NULL DEFAULT 'cotacao'
                       CHECK (status IN ('cotacao','preenchimento','assinatura_pendente',
                                         'em_subscricao','contraproposta','aprovada',
                                         'emitida','recusada','desistida')),
    apolice_id         bigint REFERENCES comissoes.apolice(id),  -- preenchido na emissão
    criado_em          timestamptz NOT NULL DEFAULT now(),
    atualizado_em      timestamptz NOT NULL DEFAULT now(),
    CHECK (status <> 'emitida' OR apolice_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_proposta_status  ON proposta (status, atualizado_em);
CREATE INDEX IF NOT EXISTS idx_proposta_cliente ON proposta (cliente_id);

CREATE TABLE IF NOT EXISTS proposta_pessoa (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    proposta_id   bigint NOT NULL REFERENCES proposta(id) ON DELETE CASCADE,
    pessoa_id     bigint NOT NULL REFERENCES cadastro.pessoa(id),
    papel         text NOT NULL DEFAULT 'dependente' CHECK (papel IN ('titular','dependente')),
    ds_exigida    boolean NOT NULL DEFAULT true,   -- declaração de saúde
    ds_recebida_em timestamptz,                    -- flag de status; conteúdo só no PDF
    UNIQUE (proposta_id, pessoa_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_proposta_titular
    ON proposta_pessoa (proposta_id) WHERE papel = 'titular';

-- -----------------------------------------------------------------------------
-- Timeline: mudanças de status + exigências do underwriting.
-- Exigência aberta (resolvido_em NULL) = fila de trabalho.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS proposta_evento (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    proposta_id  bigint NOT NULL REFERENCES proposta(id) ON DELETE CASCADE,
    tipo         text NOT NULL
                 CHECK (tipo IN ('mudanca_status','exigencia_exame','exigencia_documento',
                                 'contraproposta','aprovacao','recusa','nota')),
    descricao    text NOT NULL,                   -- sem conteúdo clínico (LGPD)
    status_de    text,                            -- em mudanca_status
    status_para  text,
    prazo        date,                            -- exigências com data-limite
    resolvido_em timestamptz,
    autor        text NOT NULL,
    criado_em    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_evento_proposta ON proposta_evento (proposta_id, criado_em);
CREATE INDEX IF NOT EXISTS idx_evento_aberto
    ON proposta_evento (prazo)
    WHERE resolvido_em IS NULL AND tipo IN ('exigencia_exame','exigencia_documento');

-- -----------------------------------------------------------------------------
-- Documentos da proposta + integração DocuSeal
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS documento (
    id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    proposta_id           bigint NOT NULL REFERENCES proposta(id) ON DELETE CASCADE,
    pessoa_id             bigint REFERENCES cadastro.pessoa(id),  -- DS é por pessoa
    tipo                  text NOT NULL
                          CHECK (tipo IN ('proposta','declaracao_saude','passaporte',
                                          'comprovante_residencia','w8_fatca','exame',
                                          'contraproposta','apolice_emitida','outro')),
    storage_path          text,                   -- caminho no NAS (volume dedicado)
    sha256                text,
    docuseal_submission_id text,
    assinatura            text NOT NULL DEFAULT 'nao_requer'
                          CHECK (assinatura IN ('nao_requer','pendente','assinado','recusado')),
    assinado_em           timestamptz,
    enviado_seguradora_em timestamptz,
    criado_em             timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_documento_proposta ON documento (proposta_id);
CREATE INDEX IF NOT EXISTS idx_documento_docuseal
    ON documento (docuseal_submission_id) WHERE docuseal_submission_id IS NOT NULL;

-- Qual template DocuSeal usar por seguradora/produto/tipo
CREATE TABLE IF NOT EXISTS modelo_documento (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    seguradora_id        bigint NOT NULL REFERENCES comissoes.seguradora(id),
    produto_id           bigint REFERENCES comissoes.produto(id),  -- NULL = todos
    tipo                 text NOT NULL,
    docuseal_template_id text NOT NULL,
    ativo                boolean NOT NULL DEFAULT true,
    UNIQUE (seguradora_id, produto_id, tipo)
);

-- Checklist configurável por produto (condicao: expressão legível avaliada
-- pelo app — ex.: 'idade_titular > 64', 'pais_residencia <> BR')
CREATE TABLE IF NOT EXISTS requisito_produto (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    produto_id  bigint NOT NULL REFERENCES comissoes.produto(id),
    tipo_documento text NOT NULL,
    obrigatorio boolean NOT NULL DEFAULT true,
    condicao    text,
    UNIQUE (produto_id, tipo_documento)
);

-- =============================================================================
-- mudar_status(): transição com trilha — o único jeito correto de mover
-- uma proposta. Valida a máquina de estados do README §2.
-- =============================================================================
CREATE OR REPLACE FUNCTION mudar_status(
    p_proposta bigint, p_novo text, p_autor text, p_nota text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SET search_path = propostas AS $$
DECLARE
    v_atual text;
    v_ok    boolean;
BEGIN
    SELECT status INTO v_atual FROM proposta WHERE id = p_proposta FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'proposta % não existe', p_proposta; END IF;

    v_ok := CASE v_atual
        WHEN 'cotacao'             THEN p_novo IN ('preenchimento','desistida')
        WHEN 'preenchimento'       THEN p_novo IN ('assinatura_pendente','desistida')
        WHEN 'assinatura_pendente' THEN p_novo IN ('em_subscricao','desistida')
        WHEN 'em_subscricao'       THEN p_novo IN ('contraproposta','aprovada','recusada')
        WHEN 'contraproposta'      THEN p_novo IN ('em_subscricao','desistida')
        WHEN 'aprovada'            THEN p_novo IN ('emitida')
        ELSE false                 -- emitida/recusada/desistida são terminais
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'transição inválida: % -> %', v_atual, p_novo;
    END IF;

    UPDATE proposta SET status = p_novo, atualizado_em = now() WHERE id = p_proposta;
    INSERT INTO proposta_evento (proposta_id, tipo, descricao, status_de, status_para, autor)
    VALUES (p_proposta, 'mudanca_status',
            coalesce(p_nota, v_atual || ' -> ' || p_novo), v_atual, p_novo, p_autor);
END;
$$;

-- =============================================================================
-- Views para o Command Center
-- =============================================================================

CREATE OR REPLACE VIEW v_funil AS
SELECT pr.id, cp.nome AS cliente, s.nome AS seguradora, pr.status,
       pr.premio_cotado, pr.moeda, pr.corretor,
       (current_date - pr.atualizado_em::date) AS dias_parada
FROM proposta pr
JOIN cadastro.cliente c  ON c.id = pr.cliente_id
JOIN cadastro.pessoa  cp ON cp.id = c.pessoa_id
JOIN comissoes.seguradora s ON s.id = pr.seguradora_id
WHERE pr.status NOT IN ('emitida','recusada','desistida')
ORDER BY dias_parada DESC;

CREATE OR REPLACE VIEW v_exigencias_abertas AS
SELECT e.id, e.proposta_id, cp.nome AS cliente, s.nome AS seguradora,
       e.tipo, e.descricao, e.prazo,
       (e.prazo IS NOT NULL AND e.prazo < current_date) AS vencida
FROM proposta_evento e
JOIN proposta pr ON pr.id = e.proposta_id
JOIN cadastro.cliente c  ON c.id = pr.cliente_id
JOIN cadastro.pessoa  cp ON cp.id = c.pessoa_id
JOIN comissoes.seguradora s ON s.id = pr.seguradora_id
WHERE e.resolvido_em IS NULL
  AND e.tipo IN ('exigencia_exame','exigencia_documento')
ORDER BY e.prazo NULLS LAST;

-- checklist × recebidos: o que falta coletar por proposta ativa
CREATE OR REPLACE VIEW v_pendencias AS
SELECT pr.id AS proposta_id, cp.nome AS cliente, r.tipo_documento, r.condicao
FROM proposta pr
JOIN requisito_produto r ON r.produto_id = pr.produto_id AND r.obrigatorio
JOIN cadastro.cliente c  ON c.id = pr.cliente_id
JOIN cadastro.pessoa  cp ON cp.id = c.pessoa_id
WHERE pr.status IN ('preenchimento','assinatura_pendente','em_subscricao')
  AND NOT EXISTS (
      SELECT 1 FROM documento d
      WHERE d.proposta_id = pr.id AND d.tipo = r.tipo_documento
  )
ORDER BY pr.id;

CREATE OR REPLACE VIEW v_conversao AS
SELECT date_trunc('month', pr.criado_em)::date AS mes,
       s.nome AS seguradora,
       count(*)                                          AS criadas,
       count(*) FILTER (WHERE pr.status = 'emitida')     AS emitidas,
       count(*) FILTER (WHERE pr.status = 'recusada')    AS recusadas,
       count(*) FILTER (WHERE pr.status = 'desistida')   AS desistidas,
       round(avg(pr.atualizado_em::date - pr.criado_em::date)
             FILTER (WHERE pr.status = 'emitida'), 1)    AS dias_ate_emissao
FROM proposta pr
JOIN comissoes.seguradora s ON s.id = pr.seguradora_id
GROUP BY 1, 2
ORDER BY 1 DESC, 2;
