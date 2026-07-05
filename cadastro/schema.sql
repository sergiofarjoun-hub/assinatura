-- =============================================================================
-- Módulo de Cadastro — Hamsa IPMI
-- Schema PostgreSQL 16 (schema "cadastro")
--
-- PRÉ-REQUISITO: comissoes/schema.sql já aplicado (este arquivo adiciona
-- cliente_id a comissoes.apolice).
--
-- Idempotente: pode ser re-executado. Desenho: ver README.md nesta pasta.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS cadastro;
SET search_path TO cadastro;

-- -----------------------------------------------------------------------------
-- Pessoas (físicas e jurídicas; brasileiras e estrangeiras)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pessoa (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tipo            text NOT NULL DEFAULT 'fisica' CHECK (tipo IN ('fisica','juridica')),
    nome            text NOT NULL,
    doc_tipo        text CHECK (doc_tipo IN ('cpf','cnpj','passaporte','outro')),
    doc_numero      text,
    doc_norm        text GENERATED ALWAYS AS
                    (upper(regexp_replace(coalesce(doc_numero, ''), '[^A-Za-z0-9]', '', 'g'))) STORED,
    nascimento      date,
    nacionalidade   char(2),                      -- ISO-3166 alpha-2
    pais_residencia char(2) NOT NULL DEFAULT 'BR',
    email           text,
    telefone_e164   text CHECK (telefone_e164 IS NULL OR telefone_e164 ~ '^\+[1-9][0-9]{6,14}$'),
    idioma          text NOT NULL DEFAULT 'pt-BR',
    observacoes     text,
    mesclada_em     bigint REFERENCES pessoa(id), -- alvo do merge (soft delete auditável)
    anonimizada_em  timestamptz,                  -- LGPD: direito de eliminação
    criado_em       timestamptz NOT NULL DEFAULT now(),
    atualizado_em   timestamptz NOT NULL DEFAULT now(),
    CHECK (doc_numero IS NULL OR doc_tipo IS NOT NULL)
);
-- unicidade de documento só entre registros vivos (não mesclados/anonimizados)
CREATE UNIQUE INDEX IF NOT EXISTS uq_pessoa_doc
    ON pessoa (doc_tipo, doc_norm)
    WHERE doc_numero IS NOT NULL AND mesclada_em IS NULL AND anonimizada_em IS NULL;
CREATE INDEX IF NOT EXISTS idx_pessoa_email ON pessoa (lower(email)) WHERE email IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_pessoa_nome  ON pessoa (lower(nome));

CREATE TABLE IF NOT EXISTS endereco (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pessoa_id  bigint NOT NULL REFERENCES pessoa(id),
    tipo       text NOT NULL DEFAULT 'residencial'
               CHECK (tipo IN ('residencial','comercial','cobranca')),
    logradouro text NOT NULL,
    complemento text,
    cidade     text NOT NULL,
    estado     text,
    cep        text,
    pais       char(2) NOT NULL DEFAULT 'BR',
    principal  boolean NOT NULL DEFAULT false,
    criado_em  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_endereco_principal
    ON endereco (pessoa_id) WHERE principal;

-- -----------------------------------------------------------------------------
-- Clientes: o subconjunto de pessoas que contrata
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cliente (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pessoa_id   bigint NOT NULL UNIQUE REFERENCES pessoa(id),
    status      text NOT NULL DEFAULT 'prospect'
                CHECK (status IN ('prospect','ativo','inativo')),
    origem      text,                             -- indicação, campanha, orgânico…
    responsavel text,                             -- corretor da conta
    criado_em   timestamptz NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- Vínculos pessoa ↔ apólice (titular, dependentes, pagador), com histórico
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS vinculo_apolice (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    apolice_id     bigint NOT NULL REFERENCES comissoes.apolice(id),
    pessoa_id      bigint NOT NULL REFERENCES pessoa(id),
    papel          text NOT NULL CHECK (papel IN ('titular','dependente','pagador')),
    parentesco     text,                          -- cônjuge, filho(a)… (dependentes)
    data_inclusao  date NOT NULL DEFAULT current_date,
    data_exclusao  date,                          -- saiu da apólice (nunca apagar)
    CHECK (data_exclusao IS NULL OR data_exclusao >= data_inclusao)
);
-- no máximo 1 titular vigente por apólice
CREATE UNIQUE INDEX IF NOT EXISTS uq_vinculo_titular
    ON vinculo_apolice (apolice_id) WHERE papel = 'titular' AND data_exclusao IS NULL;
CREATE INDEX IF NOT EXISTS idx_vinculo_pessoa ON vinculo_apolice (pessoa_id);

-- -----------------------------------------------------------------------------
-- Consentimento LGPD (consumido pelo módulo Comunicação)
-- Revogação é um novo estado com timestamp — nunca UPDATE destrutivo.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS consentimento (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pessoa_id    bigint NOT NULL REFERENCES pessoa(id),
    finalidade   text NOT NULL CHECK (finalidade IN ('marketing','operacional')),
    canal        text NOT NULL CHECK (canal IN ('whatsapp','email','telefone')),
    concedido_em timestamptz NOT NULL DEFAULT now(),
    origem       text,                            -- proposta, portal, verbal registrado…
    revogado_em  timestamptz
);
CREATE INDEX IF NOT EXISTS idx_consentimento_pessoa
    ON consentimento (pessoa_id, finalidade, canal);

-- -----------------------------------------------------------------------------
-- Evolução de comissoes.apolice: vínculo forte com o cliente titular
-- (substitui gradualmente o titular_nome texto-livre)
-- -----------------------------------------------------------------------------
ALTER TABLE comissoes.apolice
    ADD COLUMN IF NOT EXISTS cliente_id bigint REFERENCES cadastro.cliente(id);
CREATE INDEX IF NOT EXISTS idx_apolice_cliente ON comissoes.apolice (cliente_id);

-- =============================================================================
-- Funções
-- =============================================================================

-- Merge de duplicatas: mantém p_manter, reponta FKs, marca p_remover como
-- mesclada. Decisão de QUEM mesclar é humana (via v_possiveis_duplicatas).
CREATE OR REPLACE FUNCTION mesclar_pessoas(p_manter bigint, p_remover bigint)
RETURNS void
LANGUAGE plpgsql SET search_path = cadastro AS $$
BEGIN
    IF p_manter = p_remover THEN
        RAISE EXCEPTION 'p_manter e p_remover são a mesma pessoa (%)', p_manter;
    END IF;
    PERFORM 1 FROM pessoa WHERE id = p_manter AND mesclada_em IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'pessoa % inexistente ou já mesclada', p_manter; END IF;

    UPDATE vinculo_apolice SET pessoa_id = p_manter WHERE pessoa_id = p_remover;
    UPDATE consentimento   SET pessoa_id = p_manter WHERE pessoa_id = p_remover;
    UPDATE endereco        SET pessoa_id = p_manter WHERE pessoa_id = p_remover;
    -- se o removido era cliente, reponta apólices e desativa o cliente duplicado
    UPDATE comissoes.apolice a
       SET cliente_id = (SELECT id FROM cliente WHERE pessoa_id = p_manter)
     WHERE a.cliente_id = (SELECT id FROM cliente WHERE pessoa_id = p_remover)
       AND EXISTS (SELECT 1 FROM cliente WHERE pessoa_id = p_manter);
    UPDATE cliente SET status = 'inativo' WHERE pessoa_id = p_remover;

    UPDATE pessoa SET mesclada_em = p_manter, atualizado_em = now() WHERE id = p_remover;
END;
$$;

-- LGPD: eliminação — apaga identificação direta, preserva esqueleto
-- referencial (apólices/comissões são registro legal e permanecem).
CREATE OR REPLACE FUNCTION anonimizar_pessoa(p_pessoa bigint)
RETURNS void
LANGUAGE plpgsql SET search_path = cadastro AS $$
BEGIN
    UPDATE pessoa
       SET nome = 'ANONIMIZADO-' || id,
           doc_tipo = NULL, doc_numero = NULL, nascimento = NULL,
           email = NULL, telefone_e164 = NULL, observacoes = NULL,
           anonimizada_em = now(), atualizado_em = now()
     WHERE id = p_pessoa;
    DELETE FROM endereco WHERE pessoa_id = p_pessoa;
END;
$$;

-- =============================================================================
-- Views para o Command Center
-- =============================================================================

CREATE OR REPLACE VIEW v_clientes AS
SELECT
    c.id AS cliente_id,
    p.nome,
    p.email,
    p.telefone_e164,
    c.status,
    c.responsavel,
    count(a.id) FILTER (WHERE a.status = 'ativa')          AS apolices_ativas,
    string_agg(DISTINCT a.moeda || ' ' || a.premio_anual::text, ' | ')
        FILTER (WHERE a.status = 'ativa')                  AS premios_ativos
FROM cliente c
JOIN pessoa p ON p.id = c.pessoa_id
LEFT JOIN comissoes.apolice a ON a.cliente_id = c.id
WHERE p.mesclada_em IS NULL
GROUP BY c.id, p.nome, p.email, p.telefone_e164, c.status, c.responsavel;

-- progresso da migração: apólices ainda sem vínculo forte (meta: zero)
CREATE OR REPLACE VIEW v_apolices_sem_cliente AS
SELECT a.id, s.nome AS seguradora, a.numero, a.titular_nome, a.status
FROM comissoes.apolice a
JOIN comissoes.seguradora s ON s.id = a.seguradora_id
WHERE a.cliente_id IS NULL
ORDER BY a.status = 'ativa' DESC, s.nome, a.numero;

-- fila de revisão humana de identidade
CREATE OR REPLACE VIEW v_possiveis_duplicatas AS
SELECT p1.id AS pessoa_a, p2.id AS pessoa_b, p1.nome AS nome_a, p2.nome AS nome_b,
       CASE WHEN lower(p1.email) = lower(p2.email) THEN 'mesmo_email'
            ELSE 'mesmo_nome_nascimento' END AS criterio
FROM pessoa p1
JOIN pessoa p2 ON p2.id > p1.id
WHERE p1.mesclada_em IS NULL AND p2.mesclada_em IS NULL
  AND p1.anonimizada_em IS NULL AND p2.anonimizada_em IS NULL
  AND (
        (p1.email IS NOT NULL AND lower(p1.email) = lower(p2.email))
     OR (p1.nascimento IS NOT NULL AND p1.nascimento = p2.nascimento
         AND lower(p1.nome) = lower(p2.nome))
  );

CREATE OR REPLACE VIEW v_aniversariantes_mes AS
SELECT p.id, p.nome, p.nascimento, p.telefone_e164, p.email
FROM pessoa p
WHERE p.nascimento IS NOT NULL
  AND p.mesclada_em IS NULL AND p.anonimizada_em IS NULL
  AND extract(month FROM p.nascimento) = extract(month FROM current_date)
ORDER BY extract(day FROM p.nascimento);
