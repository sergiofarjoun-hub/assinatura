-- =============================================================================
-- Módulo de Renovações 2.0 — Hamsa IPMI
-- Schema PostgreSQL 16 (schema "renovacoes")
--
-- PRÉ-REQUISITOS: comissoes/schema.sql e comunicacao/schema.sql aplicados.
-- Idempotente. Desenho: ver README.md nesta pasta.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS renovacoes;
SET search_path TO renovacoes;

-- -----------------------------------------------------------------------------
-- Parâmetros do módulo (configuração, não código)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS parametro (
    chave text PRIMARY KEY,
    valor text NOT NULL,
    descricao text
);
INSERT INTO parametro (chave, valor, descricao) VALUES
    ('reajuste_alerta_pct', '15', 'Reajuste (%) acima do qual recomenda-se re-cotação'),
    ('dias_geracao_ciclo',  '120', 'Antecedência (dias) da criação do ciclo de renovação')
ON CONFLICT (chave) DO NOTHING;

-- -----------------------------------------------------------------------------
-- Marcos da régua de contato (configuráveis). dias_antes negativo = depois
-- do aniversário (D+3). Template NULL = tarefa manual (ligação).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cadencia_config (
    marco           text PRIMARY KEY,             -- 'D-90', 'D-60', …
    dias_antes      int NOT NULL,
    automatica      boolean NOT NULL DEFAULT false,
    template_codigo text,                         -- comunicacao.template.codigo
    ativo           boolean NOT NULL DEFAULT true
);
INSERT INTO cadencia_config (marco, dias_antes, automatica, template_codigo) VALUES
    ('D-90', 90, false, NULL),                    -- ligação: condições e expectativa
    ('D-60', 60, false, NULL),                    -- follow-up manual
    ('D-30', 30, true,  'renovacao_d30'),         -- e-mail automático
    ('D-7',   7, false, NULL),                    -- ligação de fechamento
    ('D+3',  -3, false, NULL)                     -- pós-vencimento sem resposta
ON CONFLICT (marco) DO NOTHING;

-- -----------------------------------------------------------------------------
-- O dossiê de cada renovação
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ciclo_renovacao (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    apolice_id           bigint NOT NULL REFERENCES comissoes.apolice(id),
    aniversario          date NOT NULL,
    premio_atual         numeric(14,2) NOT NULL,
    premio_renovacao     numeric(14,2),            -- quando a seguradora informar
    moeda                char(3) NOT NULL,
    pct_reajuste         numeric(7,4) GENERATED ALWAYS AS (
                             CASE WHEN premio_renovacao IS NULL OR premio_atual = 0 THEN NULL
                                  ELSE round((premio_renovacao / premio_atual - 1) * 100, 4)
                             END) STORED,
    pct_faixa_etaria     numeric(7,4),             -- decomposição, se informada
    pct_inflacao_medica  numeric(7,4),
    status               text NOT NULL DEFAULT 'aguardando_condicoes'
                         CHECK (status IN ('aguardando_condicoes','condicoes_recebidas',
                                           'comunicado_cliente','em_negociacao','re_cotacao',
                                           'renovada','nao_renovada','trocada')),
    decisao              text CHECK (decisao IN ('renovar','re_broking','cancelar')),
    recotacao_ref        text,                     -- cotação no Multi Cálculo
    proposta_id          bigint,                   -- se trocou: propostas.proposta (FK fraca:
                                                   -- módulos aplicáveis em qualquer ordem)
    observacoes          text,
    criado_em            timestamptz NOT NULL DEFAULT now(),
    atualizado_em        timestamptz NOT NULL DEFAULT now(),
    encerrado_em         timestamptz,
    UNIQUE (apolice_id, aniversario)
);
CREATE INDEX IF NOT EXISTS idx_ciclo_status ON ciclo_renovacao (status, aniversario);

-- -----------------------------------------------------------------------------
-- A régua de contato de cada ciclo
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tarefa_cadencia (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ciclo_id        bigint NOT NULL REFERENCES ciclo_renovacao(id) ON DELETE CASCADE,
    marco           text NOT NULL REFERENCES cadencia_config(marco),
    data_alvo       date NOT NULL,
    automatica      boolean NOT NULL,
    template_codigo text,
    mensagem_id     bigint,                        -- comunicacao.mensagem enviada (auditoria)
    feito_em        timestamptz,
    cancelada_em    timestamptz,
    UNIQUE (ciclo_id, marco)
);
CREATE INDEX IF NOT EXISTS idx_tarefa_pendente
    ON tarefa_cadencia (data_alvo) WHERE feito_em IS NULL AND cancelada_em IS NULL;

-- =============================================================================
-- Funções
-- =============================================================================

-- Régua do ciclo a partir da configuração (idempotente por UNIQUE)
CREATE OR REPLACE FUNCTION gerar_cadencia(p_ciclo bigint)
RETURNS integer
LANGUAGE plpgsql SET search_path = renovacoes AS $$
DECLARE
    c ciclo_renovacao%ROWTYPE;
    v_criadas int := 0;
    cfg RECORD;
BEGIN
    SELECT * INTO c FROM ciclo_renovacao WHERE id = p_ciclo;
    IF NOT FOUND THEN RAISE EXCEPTION 'ciclo % não existe', p_ciclo; END IF;

    FOR cfg IN SELECT * FROM cadencia_config WHERE ativo ORDER BY dias_antes DESC LOOP
        INSERT INTO tarefa_cadencia (ciclo_id, marco, data_alvo, automatica, template_codigo)
        VALUES (p_ciclo, cfg.marco, c.aniversario - cfg.dias_antes,
                cfg.automatica, cfg.template_codigo)
        ON CONFLICT (ciclo_id, marco) DO NOTHING;
        IF FOUND THEN v_criadas := v_criadas + 1; END IF;
    END LOOP;
    RETURN v_criadas;
END;
$$;

-- Job diário: cria ciclos (com régua) para apólices ativas com aniversário
-- dentro da janela. Aniversário exato por calendário (age()), sem aproximação.
CREATE OR REPLACE FUNCTION gerar_ciclos()
RETURNS integer
LANGUAGE plpgsql SET search_path = renovacoes AS $$
DECLARE
    v_janela int := (SELECT valor::int FROM parametro WHERE chave = 'dias_geracao_ciclo');
    a RECORD;
    v_aniv date;
    v_ciclo bigint;
    v_criados int := 0;
BEGIN
    FOR a IN SELECT * FROM comissoes.apolice WHERE status = 'ativa' LOOP
        v_aniv := (a.data_inicio + make_interval(
                       years => extract(year FROM age(current_date, a.data_inicio))::int + 1
                  ))::date;
        CONTINUE WHEN v_aniv > current_date + v_janela;

        INSERT INTO ciclo_renovacao (apolice_id, aniversario, premio_atual, moeda)
        VALUES (a.id, v_aniv, a.premio_anual, a.moeda)
        ON CONFLICT (apolice_id, aniversario) DO NOTHING
        RETURNING id INTO v_ciclo;

        IF v_ciclo IS NOT NULL THEN
            PERFORM gerar_cadencia(v_ciclo);
            v_criados := v_criados + 1;
        END IF;
    END LOOP;
    RETURN v_criados;
END;
$$;

-- Encerramento: fecha o ciclo e cancela a régua restante. Se renovou,
-- atualiza o prêmio da apólice e gera as parcelas de comissão do novo ano.
CREATE OR REPLACE FUNCTION encerrar_ciclo(
    p_ciclo bigint, p_resultado text  -- 'renovada' | 'nao_renovada' | 'trocada'
) RETURNS void
LANGUAGE plpgsql SET search_path = renovacoes AS $$
DECLARE
    c ciclo_renovacao%ROWTYPE;
BEGIN
    IF p_resultado NOT IN ('renovada','nao_renovada','trocada') THEN
        RAISE EXCEPTION 'resultado inválido: %', p_resultado;
    END IF;
    SELECT * INTO c FROM ciclo_renovacao WHERE id = p_ciclo FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'ciclo % não existe', p_ciclo; END IF;
    IF c.encerrado_em IS NOT NULL THEN RAISE EXCEPTION 'ciclo % já encerrado', p_ciclo; END IF;

    UPDATE ciclo_renovacao
       SET status = p_resultado, encerrado_em = now(), atualizado_em = now()
     WHERE id = p_ciclo;
    UPDATE tarefa_cadencia SET cancelada_em = now()
     WHERE ciclo_id = p_ciclo AND feito_em IS NULL AND cancelada_em IS NULL;

    IF p_resultado = 'renovada' THEN
        UPDATE comissoes.apolice
           SET premio_anual = coalesce(c.premio_renovacao, premio_anual),
               atualizado_em = now()
         WHERE id = c.apolice_id;
        -- gera o ANO NOVO (que começa no aniversário), não o corrente:
        -- a renovação é confirmada antes do aniversário, e o ano novo usa
        -- a taxa de renovação e o prêmio reajustado
        PERFORM comissoes.gerar_parcelas(
            c.apolice_id,
            (SELECT extract(year FROM age(c.aniversario, a.data_inicio))::int + 1
             FROM comissoes.apolice a WHERE a.id = c.apolice_id));
    ELSIF p_resultado = 'nao_renovada' THEN
        UPDATE comissoes.apolice SET status = 'nao_renovada', atualizado_em = now()
         WHERE id = c.apolice_id;
    END IF;
END;
$$;

-- =============================================================================
-- Views para o Command Center
-- =============================================================================

CREATE OR REPLACE VIEW v_pipeline AS
SELECT c.id, a.numero, a.titular_nome, s.nome AS seguradora,
       c.aniversario, (c.aniversario - current_date) AS dias_restantes,
       c.premio_atual, c.premio_renovacao, c.pct_reajuste, c.moeda, c.status
FROM ciclo_renovacao c
JOIN comissoes.apolice a    ON a.id = c.apolice_id
JOIN comissoes.seguradora s ON s.id = a.seguradora_id
WHERE c.encerrado_em IS NULL
ORDER BY c.aniversario;

CREATE OR REPLACE VIEW v_cadencia_hoje AS
SELECT t.id, t.marco, t.data_alvo, t.automatica, t.template_codigo,
       a.numero, a.titular_nome, c.aniversario, c.status AS status_ciclo
FROM tarefa_cadencia t
JOIN ciclo_renovacao c ON c.id = t.ciclo_id
JOIN comissoes.apolice a ON a.id = c.apolice_id
WHERE t.feito_em IS NULL AND t.cancelada_em IS NULL
  AND t.data_alvo <= current_date
ORDER BY t.data_alvo;

CREATE OR REPLACE VIEW v_recotacao_recomendada AS
SELECT c.id, a.numero, a.titular_nome, s.nome AS seguradora,
       c.premio_atual, c.premio_renovacao, c.pct_reajuste, c.moeda,
       c.aniversario, c.status
FROM ciclo_renovacao c
JOIN comissoes.apolice a    ON a.id = c.apolice_id
JOIN comissoes.seguradora s ON s.id = a.seguradora_id
WHERE c.encerrado_em IS NULL
  AND c.pct_reajuste >= (SELECT valor::numeric FROM parametro
                         WHERE chave = 'reajuste_alerta_pct')
ORDER BY c.pct_reajuste DESC;

CREATE OR REPLACE VIEW v_retencao AS
SELECT date_trunc('month', c.aniversario)::date AS mes,
       count(*) FILTER (WHERE c.status = 'renovada')     AS renovadas,
       count(*) FILTER (WHERE c.status = 'trocada')      AS trocadas,
       count(*) FILTER (WHERE c.status = 'nao_renovada') AS perdidas,
       round(100.0 * count(*) FILTER (WHERE c.status IN ('renovada','trocada'))
             / nullif(count(*), 0), 1)                   AS retencao_pct,
       round(avg(c.pct_reajuste) FILTER (WHERE c.status = 'renovada'), 2)
                                                         AS reajuste_medio_aceito
FROM ciclo_renovacao c
WHERE c.encerrado_em IS NOT NULL
GROUP BY 1
ORDER BY 1 DESC;
