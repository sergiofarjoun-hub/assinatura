-- ============================================================================
-- HAMSA — schema unificado (banco: hamsa)
-- core       = cadastros mestres (fonte única): cliente, seguradora, produto,
--              apolice, apolice_segurado
-- 1 schema por app = dados próprios de cada app (criados vazios aqui; cada
--              app popula o seu quando migrar)
-- Aplicado pelo fase-db1-provision.sh. Idempotente (IF NOT EXISTS).
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS core;

-- ---------------------------------------------------------------- trigger --
-- atualizado_em automatico em todo UPDATE (usado por todas as tabelas core)
CREATE OR REPLACE FUNCTION core.touch_atualizado_em() RETURNS trigger AS $$
BEGIN
  NEW.atualizado_em := now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------- cliente --
CREATE TABLE IF NOT EXISTS core.cliente (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo_pessoa    text NOT NULL DEFAULT 'PF' CHECK (tipo_pessoa IN ('PF','PJ')),
  nome           text NOT NULL,
  cpf_cnpj       text UNIQUE
                 CHECK (cpf_cnpj IS NULL OR cpf_cnpj ~ '^[0-9]{11}$|^[0-9]{14}$'),
  email          text,
  telefone       text,
  whatsapp       text,
  data_nascimento date,
  endereco       jsonb NOT NULL DEFAULT '{}'::jsonb,
  dados          jsonb NOT NULL DEFAULT '{}'::jsonb,  -- campos extras sem ALTER TABLE
  observacoes    text,
  ativo          boolean NOT NULL DEFAULT true,
  criado_em      timestamptz NOT NULL DEFAULT now(),
  atualizado_em  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE core.cliente IS 'Cadastro mestre de clientes (PF/PJ). cpf_cnpj so digitos.';
CREATE INDEX IF NOT EXISTS cliente_nome_idx ON core.cliente (lower(nome));

DROP TRIGGER IF EXISTS trg_touch ON core.cliente;
CREATE TRIGGER trg_touch BEFORE UPDATE ON core.cliente
  FOR EACH ROW EXECUTE FUNCTION core.touch_atualizado_em();

-- ------------------------------------------------------------- seguradora --
CREATE TABLE IF NOT EXISTS core.seguradora (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nome           text NOT NULL UNIQUE,
  cnpj           text UNIQUE CHECK (cnpj IS NULL OR cnpj ~ '^[0-9]{14}$'),
  codigo_susep   text UNIQUE,
  contato        jsonb NOT NULL DEFAULT '{}'::jsonb,  -- emails, telefones, portal
  dados          jsonb NOT NULL DEFAULT '{}'::jsonb,
  ativo          boolean NOT NULL DEFAULT true,
  criado_em      timestamptz NOT NULL DEFAULT now(),
  atualizado_em  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE core.seguradora IS 'Cadastro mestre de seguradoras/operadoras.';

DROP TRIGGER IF EXISTS trg_touch ON core.seguradora;
CREATE TRIGGER trg_touch BEFORE UPDATE ON core.seguradora
  FOR EACH ROW EXECUTE FUNCTION core.touch_atualizado_em();

-- ---------------------------------------------------------------- produto --
CREATE TABLE IF NOT EXISTS core.produto (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  seguradora_id  uuid REFERENCES core.seguradora(id),  -- NULL = produto/ramo generico
  ramo           text NOT NULL,   -- saude, vida, auto, viagem, residencial, ...
  nome           text NOT NULL,
  descricao      text,
  dados          jsonb NOT NULL DEFAULT '{}'::jsonb,
  ativo          boolean NOT NULL DEFAULT true,
  criado_em      timestamptz NOT NULL DEFAULT now(),
  atualizado_em  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (seguradora_id, nome)
);
COMMENT ON TABLE core.produto IS 'Produtos por seguradora/ramo.';
CREATE INDEX IF NOT EXISTS produto_ramo_idx ON core.produto (ramo);

DROP TRIGGER IF EXISTS trg_touch ON core.produto;
CREATE TRIGGER trg_touch BEFORE UPDATE ON core.produto
  FOR EACH ROW EXECUTE FUNCTION core.touch_atualizado_em();

-- ---------------------------------------------------------------- apolice --
CREATE TABLE IF NOT EXISTS core.apolice (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_id       uuid NOT NULL REFERENCES core.cliente(id),
  seguradora_id    uuid NOT NULL REFERENCES core.seguradora(id),
  produto_id       uuid REFERENCES core.produto(id),
  numero           text NOT NULL,
  ramo             text,
  status           text NOT NULL DEFAULT 'ativa'
                   CHECK (status IN ('proposta','ativa','renovada','cancelada','vencida')),
  inicio_vigencia  date,
  fim_vigencia     date,
  premio_total     numeric(14,2),
  moeda            char(3) NOT NULL DEFAULT 'BRL',
  comissao_percent numeric(5,2),
  apolice_anterior uuid REFERENCES core.apolice(id),  -- cadeia de renovacao
  dados            jsonb NOT NULL DEFAULT '{}'::jsonb, -- especificos do ramo
  observacoes      text,
  criado_em        timestamptz NOT NULL DEFAULT now(),
  atualizado_em    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (seguradora_id, numero)
);
COMMENT ON TABLE core.apolice IS 'Cadastro mestre de apolices. Unica por (seguradora, numero).';
CREATE INDEX IF NOT EXISTS apolice_cliente_idx   ON core.apolice (cliente_id);
CREATE INDEX IF NOT EXISTS apolice_vigencia_idx  ON core.apolice (fim_vigencia)
  WHERE status IN ('ativa','proposta');

DROP TRIGGER IF EXISTS trg_touch ON core.apolice;
CREATE TRIGGER trg_touch BEFORE UPDATE ON core.apolice
  FOR EACH ROW EXECUTE FUNCTION core.touch_atualizado_em();

-- ------------------------------------------------------- apolice_segurado --
CREATE TABLE IF NOT EXISTS core.apolice_segurado (
  apolice_id  uuid NOT NULL REFERENCES core.apolice(id) ON DELETE CASCADE,
  cliente_id  uuid NOT NULL REFERENCES core.cliente(id),
  papel       text NOT NULL DEFAULT 'titular'
              CHECK (papel IN ('titular','dependente','beneficiario')),
  dados       jsonb NOT NULL DEFAULT '{}'::jsonb,
  criado_em   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (apolice_id, cliente_id, papel)
);
COMMENT ON TABLE core.apolice_segurado IS 'Vidas por apolice (titular/dependentes/beneficiarios).';

-- ------------------------------------------------------------------ views --
-- Feed natural do app de Renovacoes: apolices ativas vencendo em ate 90 dias
CREATE OR REPLACE VIEW core.v_apolices_a_vencer AS
SELECT a.id, a.numero, a.ramo, a.status,
       a.inicio_vigencia, a.fim_vigencia,
       (a.fim_vigencia - CURRENT_DATE) AS dias_restantes,
       c.id AS cliente_id, c.nome AS cliente_nome,
       c.email AS cliente_email, c.whatsapp AS cliente_whatsapp,
       s.id AS seguradora_id, s.nome AS seguradora_nome,
       p.nome AS produto_nome,
       a.premio_total, a.moeda
FROM core.apolice a
JOIN core.cliente    c ON c.id = a.cliente_id
JOIN core.seguradora s ON s.id = a.seguradora_id
LEFT JOIN core.produto p ON p.id = a.produto_id
WHERE a.status = 'ativa'
  AND a.fim_vigencia IS NOT NULL
  AND a.fim_vigencia <= CURRENT_DATE + 90
ORDER BY a.fim_vigencia;

-- ------------------------------------------------------- schemas dos apps --
-- Vazios por enquanto: cada app cria/migra as proprias tabelas aqui na sua
-- fase DB4, sempre com FK para core.* (nunca copia de mestre).
CREATE SCHEMA IF NOT EXISTS renovacoes;
CREATE SCHEMA IF NOT EXISTS claims;
CREATE SCHEMA IF NOT EXISTS pipeline;
CREATE SCHEMA IF NOT EXISTS multicalculo;
CREATE SCHEMA IF NOT EXISTS multiapolices;
CREATE SCHEMA IF NOT EXISTS commandcenter;
