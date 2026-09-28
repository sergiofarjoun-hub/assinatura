-- =============================================================================
-- Módulo de Claims / Reembolsos — Hamsa IPMI
-- Schema PostgreSQL 16 (schema "claims")
--
-- PRÉ-REQUISITOS: comissoes/schema.sql e cadastro/schema.sql aplicados.
-- Idempotente. Desenho: ver README.md nesta pasta.
--
-- Fonte automatizada e única da posição de reembolsos e franquia. Substitui o
-- controle em Excel. Alimenta a rotina de renovação, o WhatsApp agent e o Portal.
-- LGPD: nada de conteúdo clínico estruturado — apenas valores, prestador,
-- categoria não clínica e REFERÊNCIAS ao documento/EOB.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS claims;
SET search_path TO claims;

-- -----------------------------------------------------------------------------
-- Teto da franquia por apólice e ano-apólice (individual x familiar)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS plano_franquia (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    apolice_id     bigint NOT NULL REFERENCES comissoes.apolice(id),
    ano_inicio     date NOT NULL,                     -- início do ano-apólice
    franquia_anual numeric(14,2) NOT NULL CHECK (franquia_anual >= 0),
    moeda          char(3) NOT NULL DEFAULT 'USD',
    tipo           text NOT NULL DEFAULT 'individual'
                   CHECK (tipo IN ('individual','familiar')),
    observacao     text,
    criado_em      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (apolice_id, ano_inicio)
);

-- -----------------------------------------------------------------------------
-- A solicitação de reembolso (uma linha do extrato)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS reembolso (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    apolice_id        bigint NOT NULL REFERENCES comissoes.apolice(id),
    -- segurado (titular ou dependente): FK quando Cadastro estiver vinculado;
    -- segurado_nome é o fallback texto-livre durante a migração.
    segurado_pessoa_id bigint REFERENCES cadastro.pessoa(id),
    segurado_nome     text,
    data_servico      date NOT NULL,
    prestador         text,
    beneficio         text,                           -- categoria NÃO clínica:
                      -- consulta, exame, internacao, checkup, maternidade, outro
    -- valores na moeda de liquidação (normalmente USD)
    moeda             char(3) NOT NULL DEFAULT 'USD',
    apresentado       numeric(14,2) NOT NULL DEFAULT 0 CHECK (apresentado >= 0),
    franquia          numeric(14,2) NOT NULL DEFAULT 0 CHECK (franquia >= 0),
    reembolsado       numeric(14,2) NOT NULL DEFAULT 0 CHECK (reembolsado >= 0),
    nao_coberto       numeric(14,2) GENERATED ALWAYS AS
                          (round(apresentado - franquia - reembolsado, 2)) STORED,
    -- valor original apresentado, quando a despesa veio em outra moeda (ex.: BRL)
    moeda_orig        char(3),
    apresentado_orig  numeric(14,2),
    isenta            boolean NOT NULL DEFAULT false,  -- check-up/maternidade: sem franquia
    status            text NOT NULL DEFAULT 'recebido'
                      CHECK (status IN ('recebido','em_processamento','processado','negado')),
    motivo_nao_cobertura text,                         -- ex.: 'S26 — serviços não cobertos'
    documento_ref     text,                            -- arquivo em _CLAIMS (caminho/hash)
    eob_ref           text,                            -- EOB oficial da seguradora (ref/hash)
    origem            text NOT NULL DEFAULT 'manual'
                      CHECK (origem IN ('manual','whatsapp','import','portal')),
    origem_id         text,                            -- id na origem (idempotência)
    observacoes       text,
    criado_em         timestamptz NOT NULL DEFAULT now(),
    atualizado_em     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_reembolso_apolice ON reembolso (apolice_id, data_servico);
CREATE INDEX IF NOT EXISTS idx_reembolso_status  ON reembolso (status)
    WHERE status IN ('recebido','em_processamento');
-- idempotência da ingestão: não duplica a mesma linha de uma mesma origem
CREATE UNIQUE INDEX IF NOT EXISTS uq_reembolso_origem
    ON reembolso (origem, origem_id) WHERE origem_id IS NOT NULL;

-- =============================================================================
-- Funções
-- =============================================================================

-- Início do ano-apólice de uma data de serviço (aniversário por calendário).
-- A franquia acumula dentro dessa janela e zera no aniversário seguinte.
CREATE OR REPLACE FUNCTION ano_apolice(p_apolice_id bigint, p_data date)
RETURNS date
LANGUAGE sql STABLE SET search_path = claims AS $$
    SELECT (a.data_inicio + make_interval(
                years => extract(year FROM age(p_data, a.data_inicio))::int))::date
    FROM comissoes.apolice a WHERE a.id = p_apolice_id;
$$;

-- Registra uma solicitação de reembolso (idempotente por origem+origem_id).
-- Retorna o id da linha (nova ou já existente). Escrita sempre por aqui.
CREATE OR REPLACE FUNCTION registrar_reembolso(
    p_apolice_id       bigint,
    p_data_servico     date,
    p_apresentado      numeric,
    p_segurado_nome    text    DEFAULT NULL,
    p_segurado_pessoa_id bigint DEFAULT NULL,
    p_prestador        text    DEFAULT NULL,
    p_beneficio        text    DEFAULT NULL,
    p_moeda            char    DEFAULT 'USD',
    p_isenta           boolean DEFAULT false,
    p_documento_ref    text    DEFAULT NULL,
    p_origem           text    DEFAULT 'whatsapp',
    p_origem_id        text    DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SET search_path = claims AS $$
DECLARE
    v_id bigint;
BEGIN
    IF p_origem_id IS NOT NULL THEN
        SELECT id INTO v_id FROM reembolso
         WHERE origem = p_origem AND origem_id = p_origem_id;
        IF FOUND THEN RETURN v_id; END IF;
    END IF;

    INSERT INTO reembolso (apolice_id, segurado_pessoa_id, segurado_nome,
                           data_servico, prestador, beneficio, moeda,
                           apresentado, isenta, documento_ref, origem, origem_id)
    VALUES (p_apolice_id, p_segurado_pessoa_id, p_segurado_nome,
            p_data_servico, p_prestador, p_beneficio, p_moeda,
            p_apresentado, p_isenta, p_documento_ref, p_origem, p_origem_id)
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$;

-- Concilia a solicitação com o EOB da seguradora: grava franquia/reembolsado
-- confirmados e move o status. A seguradora é a fonte do valor final.
CREATE OR REPLACE FUNCTION atualizar_status(
    p_id          bigint,
    p_status      text,
    p_franquia    numeric DEFAULT NULL,
    p_reembolsado numeric DEFAULT NULL,
    p_eob_ref     text    DEFAULT NULL,
    p_motivo_nao_cobertura text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SET search_path = claims AS $$
BEGIN
    IF p_status NOT IN ('recebido','em_processamento','processado','negado') THEN
        RAISE EXCEPTION 'status inválido: %', p_status;
    END IF;
    UPDATE reembolso
       SET status        = p_status,
           franquia      = coalesce(p_franquia, franquia),
           reembolsado   = coalesce(p_reembolsado, reembolsado),
           eob_ref       = coalesce(p_eob_ref, eob_ref),
           motivo_nao_cobertura = coalesce(p_motivo_nao_cobertura, motivo_nao_cobertura),
           atualizado_em = now()
     WHERE id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'reembolso % não existe', p_id; END IF;
END;
$$;

-- =============================================================================
-- Views para os consumidores (renovação, WhatsApp agent, Portal)
-- =============================================================================

-- Extrato linha a linha (o PDF de hoje).
CREATE OR REPLACE VIEW v_extrato_reembolsos AS
SELECT r.id,
       r.apolice_id,
       a.numero              AS apolice,
       a.titular_nome,
       s.nome                AS seguradora,
       claims.ano_apolice(r.apolice_id, r.data_servico) AS ano_apolice_inicio,
       coalesce(p.nome, r.segurado_nome) AS segurado,
       r.data_servico,
       r.prestador,
       r.moeda,
       r.apresentado,
       r.franquia,
       r.reembolsado,
       r.nao_coberto,
       r.isenta,
       r.status,
       r.motivo_nao_cobertura
FROM reembolso r
JOIN comissoes.apolice a    ON a.id = r.apolice_id
JOIN comissoes.seguradora s ON s.id = a.seguradora_id
LEFT JOIN cadastro.pessoa p ON p.id = r.segurado_pessoa_id
ORDER BY r.apolice_id, r.data_servico DESC;

-- Posição da franquia por apólice e POR SEGURADO no ano-apólice CORRENTE,
-- com o teto do plano e o quanto falta.
CREATE OR REPLACE VIEW v_posicao_franquia AS
WITH corrente AS (
    SELECT r.*,
           claims.ano_apolice(r.apolice_id, current_date) AS ano_atual
    FROM reembolso r
    WHERE claims.ano_apolice(r.apolice_id, r.data_servico)
        = claims.ano_apolice(r.apolice_id, current_date)
)
SELECT c.apolice_id,
       a.numero  AS apolice,
       a.titular_nome,
       s.nome    AS seguradora,
       c.ano_atual AS ano_apolice_inicio,
       coalesce(p.nome, c.segurado_nome) AS segurado,
       c.segurado_pessoa_id,
       count(*)                              AS solicitacoes,
       count(*) FILTER (WHERE c.status IN ('recebido','em_processamento')) AS pendentes,
       sum(c.apresentado)                    AS apresentado,
       sum(c.franquia)                       AS franquia_acumulada,
       sum(c.reembolsado)                    AS reembolsado,
       sum(c.nao_coberto)                    AS nao_coberto,
       pf.franquia_anual,
       pf.tipo   AS franquia_tipo,
       CASE WHEN pf.franquia_anual IS NULL THEN NULL
            ELSE greatest(pf.franquia_anual - sum(c.franquia), 0) END AS franquia_restante
FROM corrente c
JOIN comissoes.apolice a    ON a.id = c.apolice_id
JOIN comissoes.seguradora s ON s.id = a.seguradora_id
LEFT JOIN cadastro.pessoa p ON p.id = c.segurado_pessoa_id
LEFT JOIN plano_franquia pf ON pf.apolice_id = c.apolice_id AND pf.ano_inicio = c.ano_atual
GROUP BY c.apolice_id, a.numero, a.titular_nome, s.nome, c.ano_atual,
         coalesce(p.nome, c.segurado_nome), c.segurado_pessoa_id,
         pf.franquia_anual, pf.tipo;

-- Posição da franquia agregada por FAMÍLIA (a apólice inteira) no ano corrente.
CREATE OR REPLACE VIEW v_posicao_franquia_familia AS
WITH corrente AS (
    SELECT r.*,
           claims.ano_apolice(r.apolice_id, current_date) AS ano_atual
    FROM reembolso r
    WHERE claims.ano_apolice(r.apolice_id, r.data_servico)
        = claims.ano_apolice(r.apolice_id, current_date)
)
SELECT c.apolice_id,
       a.numero  AS apolice,
       a.titular_nome,
       s.nome    AS seguradora,
       c.ano_atual AS ano_apolice_inicio,
       count(*)                              AS solicitacoes,
       count(*) FILTER (WHERE c.status IN ('recebido','em_processamento')) AS pendentes,
       count(DISTINCT coalesce(c.segurado_nome, c.segurado_pessoa_id::text)) AS segurados,
       sum(c.apresentado)                    AS apresentado,
       sum(c.franquia)                       AS franquia_acumulada,
       sum(c.reembolsado)                    AS reembolsado,
       sum(c.nao_coberto)                    AS nao_coberto,
       pf.franquia_anual,
       pf.tipo   AS franquia_tipo,
       CASE WHEN pf.franquia_anual IS NULL OR pf.tipo <> 'familiar' THEN NULL
            ELSE greatest(pf.franquia_anual - sum(c.franquia), 0) END AS franquia_restante
FROM corrente c
JOIN comissoes.apolice a    ON a.id = c.apolice_id
JOIN comissoes.seguradora s ON s.id = a.seguradora_id
LEFT JOIN plano_franquia pf ON pf.apolice_id = c.apolice_id AND pf.ano_inicio = c.ano_atual
GROUP BY c.apolice_id, a.numero, a.titular_nome, s.nome, c.ano_atual,
         pf.franquia_anual, pf.tipo;

-- "Seu seguro em uso" — totais do ano-apólice corrente (bloco do e-mail de renovação).
CREATE OR REPLACE VIEW v_seguro_em_uso AS
SELECT apolice_id, apolice, titular_nome, seguradora, ano_apolice_inicio,
       solicitacoes, pendentes, apresentado, reembolsado, nao_coberto,
       franquia_acumulada
FROM v_posicao_franquia_familia;
