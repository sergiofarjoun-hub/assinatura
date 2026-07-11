-- =============================================================================
-- Módulo Portal do Cliente — Hamsa IPMI
-- Schema PostgreSQL 16 (schema "portal") — mínimo de propósito: o portal é
-- uma lente sobre os outros módulos, não um dono de dados.
--
-- PRÉ-REQUISITO: cadastro/schema.sql aplicado.
-- Idempotente. Desenho e threat model: ver README.md nesta pasta.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS portal;
SET search_path TO portal;

CREATE TABLE IF NOT EXISTS usuario (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pessoa_id           bigint NOT NULL UNIQUE REFERENCES cadastro.pessoa(id),
    email_verificado_em timestamptz,
    fone_verificado_em  timestamptz,
    status              text NOT NULL DEFAULT 'ativo'
                        CHECK (status IN ('ativo','bloqueado')),
    criado_em           timestamptz NOT NULL DEFAULT now(),
    ultimo_login_em     timestamptz
);

-- Magic links / OTP: guarda-se o HASH do token, nunca o token.
CREATE TABLE IF NOT EXISTS token_acesso (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    usuario_id  bigint NOT NULL REFERENCES usuario(id),
    tipo        text NOT NULL CHECK (tipo IN ('magic_link','otp')),
    token_hash  text NOT NULL UNIQUE,             -- sha256(token + pepper do app)
    expira_em   timestamptz NOT NULL,
    usado_em    timestamptz,                      -- uso único
    criado_em   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_token_usuario ON token_acesso (usuario_id, criado_em DESC);

CREATE TABLE IF NOT EXISTS sessao (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    usuario_id   bigint NOT NULL REFERENCES usuario(id),
    sessao_hash  text NOT NULL UNIQUE,
    criada_em    timestamptz NOT NULL DEFAULT now(),
    expira_em    timestamptz NOT NULL,
    revogada_em  timestamptz,
    ip           inet,
    user_agent   text
);
CREATE INDEX IF NOT EXISTS idx_sessao_ativa
    ON sessao (usuario_id) WHERE revogada_em IS NULL;

-- Trilha de auditoria LGPD (append-only: sem UPDATE/DELETE pela aplicação)
CREATE TABLE IF NOT EXISTS acesso_log (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    usuario_id bigint REFERENCES usuario(id),
    acao       text NOT NULL,                     -- login, ver_apolice, baixar_doc…
    recurso    text,                              -- ex.: 'apolice:42'
    ip         inet,
    criado_em  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_acesso_log_usuario ON acesso_log (usuario_id, criado_em DESC);

-- =============================================================================
-- Views da allowlist do usuário portal_ro — SEMPRE parametrizadas por pessoa.
-- O app define a pessoa da sessão via: SET LOCAL portal.pessoa = '<id>';
-- =============================================================================

CREATE OR REPLACE VIEW v_minhas_apolices AS
SELECT a.id, s.nome AS seguradora, a.numero, a.status,
       a.data_inicio, a.premio_anual, a.moeda, a.frequencia,
       v.papel, v.data_inclusao
FROM cadastro.vinculo_apolice v
JOIN comissoes.apolice a    ON a.id = v.apolice_id
JOIN comissoes.seguradora s ON s.id = a.seguradora_id
WHERE v.pessoa_id = current_setting('portal.pessoa', true)::bigint
  AND v.data_exclusao IS NULL;

CREATE OR REPLACE VIEW v_meus_dependentes AS
SELECT a.numero AS apolice, p.nome, v2.papel, v2.parentesco, v2.data_inclusao
FROM cadastro.vinculo_apolice v1                  -- apólices em que EU sou titular
JOIN cadastro.vinculo_apolice v2 ON v2.apolice_id = v1.apolice_id
                                AND v2.data_exclusao IS NULL
JOIN cadastro.pessoa p ON p.id = v2.pessoa_id
JOIN comissoes.apolice a ON a.id = v1.apolice_id
WHERE v1.pessoa_id = current_setting('portal.pessoa', true)::bigint
  AND v1.papel = 'titular' AND v1.data_exclusao IS NULL;

CREATE OR REPLACE VIEW v_meus_consentimentos AS
SELECT c.id, c.finalidade, c.canal, c.concedido_em, c.revogado_em
FROM cadastro.consentimento c
WHERE c.pessoa_id = current_setting('portal.pessoa', true)::bigint
ORDER BY c.concedido_em DESC;

-- =============================================================================
-- Usuário de banco do portal: só-leitura na allowlist + escrita no próprio
-- schema. Executar uma vez (idempotente); a senha real vem de env var na
-- criação do usuário — placeholder aqui de propósito.
-- =============================================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'portal_ro') THEN
        CREATE ROLE portal_ro LOGIN PASSWORD 'TROCAR_VIA_ENV_NA_IMPLANTACAO';
    END IF;
END $$;

GRANT USAGE ON SCHEMA portal TO portal_ro;
GRANT SELECT ON portal.v_minhas_apolices, portal.v_meus_dependentes,
                portal.v_meus_consentimentos TO portal_ro;
GRANT SELECT, INSERT, UPDATE ON portal.usuario, portal.token_acesso, portal.sessao TO portal_ro;
GRANT INSERT ON portal.acesso_log TO portal_ro;   -- append-only: sem UPDATE/DELETE
GRANT USAGE ON ALL SEQUENCES IN SCHEMA portal TO portal_ro;
-- as views rodam com permissão do dono (postgres), então portal_ro NÃO
-- precisa (nem recebe) SELECT nas tabelas de cadastro/comissoes.
