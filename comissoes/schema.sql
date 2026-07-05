-- =============================================================================
-- Módulo de Comissões — Hamsa IPMI
-- Schema PostgreSQL 16 (schema "comissoes")
--
-- Uso (no container Postgres do NAS):
--   psql -U hamsa -d hamsa -f schema.sql
--
-- Idempotente: pode ser re-executado (IF NOT EXISTS / ON CONFLICT DO NOTHING).
-- Desenho e fluxo operacional: ver README.md nesta pasta.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS btree_gist;  -- p/ exclusão de vigências sobrepostas

CREATE SCHEMA IF NOT EXISTS comissoes;
SET search_path TO comissoes;

-- -----------------------------------------------------------------------------
-- Seguradoras
-- mapeamento_bordereau: template jsonb de importação do extrato desta
-- seguradora (nome/posição das colunas de nº de apólice, segurado, prêmio,
-- comissão, competência). Seguradora nova = novo mapeamento, sem código novo.
-- Ex.: {"numero_apolice": "Policy No", "segurado_nome": "Member Name",
--       "premio": "Gross Premium", "comissao": "Commission Due",
--       "competencia": "Period", "formato_data": "MM/DD/YYYY", "pular_linhas": 2}
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS seguradora (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome                 text NOT NULL,
    codigo               text NOT NULL UNIQUE,          -- slug estável p/ integrações
    moeda_padrao         char(3) NOT NULL DEFAULT 'USD',
    cadencia_bordereau   text NOT NULL DEFAULT 'mensal'
                         CHECK (cadencia_bordereau IN ('mensal','trimestral','irregular')),
    mapeamento_bordereau jsonb,
    contato_email        text,
    ativo                boolean NOT NULL DEFAULT true,
    criado_em            timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS produto (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    seguradora_id bigint NOT NULL REFERENCES seguradora(id),
    nome          text NOT NULL,
    codigo        text NOT NULL,
    tipo          text NOT NULL DEFAULT 'ipmi_individual'
                  CHECK (tipo IN ('ipmi_individual','ipmi_grupo','travel','vida','outro')),
    ativo         boolean NOT NULL DEFAULT true,
    UNIQUE (seguradora_id, codigo)
);

-- -----------------------------------------------------------------------------
-- Regras de comissão, com vigência e sem sobreposição.
-- produto_id NULL = regra padrão da seguradora (produto específico prevalece).
-- Mudou a taxa? Fecha a vigência da regra antiga e cria outra — parcelas já
-- geradas continuam apontando para a regra que as calculou.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS regra_comissao (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    seguradora_id  bigint NOT NULL REFERENCES seguradora(id),
    produto_id     bigint REFERENCES produto(id),
    vigencia       daterange NOT NULL,
    base           text NOT NULL DEFAULT 'premio_bruto'
                   CHECK (base IN ('premio_bruto','premio_liquido')),
    taxa_ano1      numeric(6,4) NOT NULL CHECK (taxa_ano1      >= 0 AND taxa_ano1      <= 1),
    taxa_renovacao numeric(6,4) NOT NULL CHECK (taxa_renovacao >= 0 AND taxa_renovacao <= 1),
    observacao     text,
    criado_em      timestamptz NOT NULL DEFAULT now(),
    EXCLUDE USING gist (
        seguradora_id WITH =,
        COALESCE(produto_id, -1) WITH =,
        vigencia WITH &&
    )
);

-- -----------------------------------------------------------------------------
-- Apólices — espelho mínimo; a fonte da verdade é o Multi Apólices
-- (origem = 'multi_apolices', origem_id = id lá). numero_norm serve ao matching.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS apolice (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    seguradora_id bigint NOT NULL REFERENCES seguradora(id),
    produto_id    bigint REFERENCES produto(id),
    numero        text NOT NULL,
    numero_norm   text GENERATED ALWAYS AS
                  (upper(regexp_replace(numero, '[^A-Za-z0-9]', '', 'g'))) STORED,
    titular_nome  text NOT NULL,
    data_inicio   date NOT NULL,
    status        text NOT NULL DEFAULT 'ativa'
                  CHECK (status IN ('ativa','suspensa','cancelada','nao_renovada')),
    premio_anual  numeric(14,2) NOT NULL CHECK (premio_anual >= 0),
    moeda         char(3) NOT NULL,
    frequencia    text NOT NULL DEFAULT 'anual'
                  CHECK (frequencia IN ('mensal','trimestral','semestral','anual')),
    origem        text NOT NULL DEFAULT 'manual'
                  CHECK (origem IN ('multi_apolices','manual')),
    origem_id     text,
    criado_em     timestamptz NOT NULL DEFAULT now(),
    atualizado_em timestamptz NOT NULL DEFAULT now(),
    UNIQUE (seguradora_id, numero)
);
CREATE INDEX IF NOT EXISTS idx_apolice_numero_norm ON apolice (numero_norm);

-- -----------------------------------------------------------------------------
-- Parcelas esperadas: uma linha por competência de cada vigência.
-- taxa_aplicada é congelada na geração — recadastrar regra não reescreve história.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS parcela_esperada (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    apolice_id        bigint NOT NULL REFERENCES apolice(id),
    competencia       date NOT NULL,                    -- 1º dia do período
    ano_vigencia      int  NOT NULL CHECK (ano_vigencia >= 1),  -- 1 = taxa cheia
    premio_esperado   numeric(14,2) NOT NULL,
    moeda             char(3) NOT NULL,
    regra_comissao_id bigint REFERENCES regra_comissao(id),
    taxa_aplicada     numeric(6,4) NOT NULL,
    comissao_esperada numeric(14,2) NOT NULL,
    status            text NOT NULL DEFAULT 'prevista'
                      CHECK (status IN ('prevista','conciliada','parcial',
                                        'divergente','cancelada','clawback')),
    criado_em         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (apolice_id, competencia)
);
CREATE INDEX IF NOT EXISTS idx_parcela_status_comp ON parcela_esperada (status, competencia);

-- -----------------------------------------------------------------------------
-- Bordereaux (extratos importados) e seus itens.
-- arquivo_hash único = mesmo arquivo não entra duas vezes.
-- dados_brutos preserva a linha original do arquivo (auditoria/reprocesso).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bordereau (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    seguradora_id      bigint NOT NULL REFERENCES seguradora(id),
    periodo_referencia date NOT NULL,
    arquivo_nome       text NOT NULL,
    arquivo_hash       text NOT NULL UNIQUE,            -- sha256 do arquivo
    moeda              char(3) NOT NULL,
    total_informado    numeric(14,2),                   -- total declarado no extrato
    status             text NOT NULL DEFAULT 'importado'
                       CHECK (status IN ('importado','conciliando','fechado')),
    importado_por      text NOT NULL,
    importado_em       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS bordereau_item (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bordereau_id        bigint NOT NULL REFERENCES bordereau(id) ON DELETE CASCADE,
    linha_num           int NOT NULL,
    dados_brutos        jsonb NOT NULL,
    numero_apolice      text,
    numero_apolice_norm text GENERATED ALWAYS AS
                        (upper(regexp_replace(coalesce(numero_apolice, ''),
                                              '[^A-Za-z0-9]', '', 'g'))) STORED,
    segurado_nome       text,
    premio              numeric(14,2),
    comissao            numeric(14,2) NOT NULL,         -- negativa em clawback
    moeda               char(3) NOT NULL,
    tipo                text NOT NULL DEFAULT 'comissao'
                        CHECK (tipo IN ('comissao','clawback','ajuste','bonus')),
    status_match        text NOT NULL DEFAULT 'sem_match'
                        CHECK (status_match IN ('auto','manual','sem_match','ignorado')),
    parcela_id          bigint REFERENCES parcela_esperada(id),
    UNIQUE (bordereau_id, linha_num)
);
CREATE INDEX IF NOT EXISTS idx_bitem_numero_norm ON bordereau_item (numero_apolice_norm);
CREATE INDEX IF NOT EXISTS idx_bitem_parcela     ON bordereau_item (parcela_id);
CREATE INDEX IF NOT EXISTS idx_bitem_sem_match   ON bordereau_item (status_match)
    WHERE status_match = 'sem_match';

-- -----------------------------------------------------------------------------
-- Divergências: fila de trabalho da conciliação.
-- resolvido_em NULL = aberta. "Recuperado no ano" = soma de diferenca das
-- resolvidas com motivo a favor da corretora.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS divergencia (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parcela_id        bigint REFERENCES parcela_esperada(id),
    bordereau_item_id bigint REFERENCES bordereau_item(id),
    valor_esperado    numeric(14,2),
    valor_recebido    numeric(14,2),
    diferenca         numeric(14,2) NOT NULL,
    moeda             char(3) NOT NULL,
    motivo            text NOT NULL DEFAULT 'desconhecido'
                      CHECK (motivo IN ('cambio','taxa','reajuste_nao_registrado',
                                        'clawback','apolice_desconhecida','desconhecido')),
    resolucao         text,
    resolvido_em      timestamptz,
    criado_em         timestamptz NOT NULL DEFAULT now(),
    CHECK (parcela_id IS NOT NULL OR bordereau_item_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_divergencia_aberta ON divergencia (criado_em)
    WHERE resolvido_em IS NULL;

-- -----------------------------------------------------------------------------
-- Câmbio (PTAX/BCB ou manual) — consolidação em BRL sem tocar na moeda de origem.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS taxa_cambio (
    dia   date NOT NULL,
    de    char(3) NOT NULL,
    para  char(3) NOT NULL,
    taxa  numeric(16,8) NOT NULL CHECK (taxa > 0),
    fonte text NOT NULL DEFAULT 'ptax' CHECK (fonte IN ('ptax','manual')),
    PRIMARY KEY (dia, de, para)
);

-- =============================================================================
-- Geração de parcelas esperadas de uma vigência da apólice.
-- p_ano NULL = vigência corrente (job diário). p_ano explícito = vigência
-- alvo — usado pela renovação, que confirma ANTES do aniversário e precisa
-- gerar o ano novo (taxa de renovação), não o corrente.
-- Idempotente (ON CONFLICT DO NOTHING). Retorna quantas parcelas criou.
-- =============================================================================
DROP FUNCTION IF EXISTS gerar_parcelas(bigint);  -- assinatura antiga (1 arg)
CREATE OR REPLACE FUNCTION gerar_parcelas(p_apolice_id bigint, p_ano int DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql SET search_path = comissoes AS $$
DECLARE
    a         apolice%ROWTYPE;
    r         regra_comissao%ROWTYPE;
    v_ano     int;
    v_ini     date;
    v_n       int;
    v_premio  numeric(14,2);
    v_taxa    numeric(6,4);
    v_comp    date;
    v_criadas int := 0;
    i         int;
BEGIN
    SELECT * INTO a FROM apolice WHERE id = p_apolice_id;
    IF NOT FOUND OR a.status <> 'ativa' THEN
        RETURN 0;
    END IF;

    -- ano de vigência (1 = primeiro ano): explícito ou o corrente
    v_ano := coalesce(p_ano,
                      greatest(1, floor((current_date - a.data_inicio) / 365.25)::int + 1));
    v_ini := (a.data_inicio + make_interval(years => v_ano - 1))::date;

    v_n := CASE a.frequencia
               WHEN 'mensal'     THEN 12
               WHEN 'trimestral' THEN 4
               WHEN 'semestral'  THEN 2
               ELSE 1
           END;
    v_premio := round(a.premio_anual / v_n, 2);

    -- regra vigente: produto específico prevalece sobre a padrão da seguradora
    SELECT * INTO r
    FROM regra_comissao
    WHERE seguradora_id = a.seguradora_id
      AND (produto_id = a.produto_id OR produto_id IS NULL)
      AND vigencia @> v_ini
    ORDER BY produto_id NULLS LAST
    LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sem regra de comissão vigente para apólice % (seguradora %)',
            a.numero, a.seguradora_id;
    END IF;

    v_taxa := CASE WHEN v_ano = 1 THEN r.taxa_ano1 ELSE r.taxa_renovacao END;

    FOR i IN 0 .. v_n - 1 LOOP
        v_comp := (v_ini + make_interval(months => i * (12 / v_n)))::date;
        INSERT INTO parcela_esperada
            (apolice_id, competencia, ano_vigencia, premio_esperado, moeda,
             regra_comissao_id, taxa_aplicada, comissao_esperada)
        VALUES
            (a.id, v_comp, v_ano, v_premio, a.moeda,
             r.id, v_taxa, round(v_premio * v_taxa, 2))
        ON CONFLICT (apolice_id, competencia) DO NOTHING;
        IF FOUND THEN
            v_criadas := v_criadas + 1;
        END IF;
    END LOOP;

    RETURN v_criadas;
END;
$$;

-- =============================================================================
-- Views para o Command Center e para o fechamento mensal
-- =============================================================================

-- Esperado × recebido por mês / seguradora / moeda
CREATE OR REPLACE VIEW v_receita_mensal AS
SELECT
    date_trunc('month', p.competencia)::date AS mes,
    s.nome                                   AS seguradora,
    p.moeda,
    sum(p.comissao_esperada)                 AS esperado,
    coalesce(sum(bi.comissao), 0)            AS recebido,
    sum(p.comissao_esperada) - coalesce(sum(bi.comissao), 0) AS saldo
FROM parcela_esperada p
JOIN apolice    a ON a.id = p.apolice_id
JOIN seguradora s ON s.id = a.seguradora_id
LEFT JOIN bordereau_item bi
       ON bi.parcela_id = p.id AND bi.status_match IN ('auto','manual')
GROUP BY 1, 2, 3
ORDER BY 1 DESC, 2;

-- Aging de comissões vencidas e não conciliadas — a lista de cobrança
CREATE OR REPLACE VIEW v_aging AS
SELECT
    s.nome  AS seguradora,
    p.moeda,
    sum(p.comissao_esperada) FILTER (WHERE current_date - p.competencia <= 30)  AS d0_30,
    sum(p.comissao_esperada) FILTER (WHERE current_date - p.competencia
                                           BETWEEN 31 AND 60)                  AS d31_60,
    sum(p.comissao_esperada) FILTER (WHERE current_date - p.competencia
                                           BETWEEN 61 AND 90)                  AS d61_90,
    sum(p.comissao_esperada) FILTER (WHERE current_date - p.competencia > 90)  AS d90_mais,
    sum(p.comissao_esperada)                                                   AS total,
    count(*)                                                                   AS parcelas
FROM parcela_esperada p
JOIN apolice    a ON a.id = p.apolice_id
JOIN seguradora s ON s.id = a.seguradora_id
WHERE p.status IN ('prevista','parcial','divergente')
  AND p.competencia <= current_date
GROUP BY 1, 2
ORDER BY total DESC;

-- Fila única de pendências: itens sem match + divergências abertas
CREATE OR REPLACE VIEW v_pendencias_matching AS
SELECT
    'item_sem_match'      AS tipo,
    bi.id                 AS ref_id,
    s.nome                AS seguradora,
    bi.numero_apolice,
    bi.segurado_nome,
    bi.comissao           AS valor,
    bi.moeda,
    b.periodo_referencia  AS referencia,
    NULL::text            AS motivo
FROM bordereau_item bi
JOIN bordereau  b ON b.id = bi.bordereau_id
JOIN seguradora s ON s.id = b.seguradora_id
WHERE bi.status_match = 'sem_match'
UNION ALL
SELECT
    'divergencia',
    d.id,
    s.nome,
    a.numero,
    a.titular_nome,
    d.diferenca,
    d.moeda,
    p.competencia,
    d.motivo
FROM divergencia d
JOIN parcela_esperada p ON p.id = d.parcela_id
JOIN apolice    a ON a.id = p.apolice_id
JOIN seguradora s ON s.id = a.seguradora_id
WHERE d.resolvido_em IS NULL
ORDER BY referencia;

-- =============================================================================
-- Seeds — seguradoras IPMI usuais (ajustar/complementar no cadastro real).
-- Taxas de comissão NÃO são seedadas: cadastrar as taxas reais de cada
-- contrato de corretagem em regra_comissao.
-- =============================================================================
INSERT INTO seguradora (nome, codigo, moeda_padrao, cadencia_bordereau) VALUES
    ('Cigna Global',        'cigna',   'USD', 'mensal'),
    ('Bupa Global',         'bupa',    'USD', 'mensal'),
    ('Allianz Care',        'allianz', 'EUR', 'mensal'),
    ('GeoBlue',             'geoblue', 'USD', 'mensal'),
    ('IMG',                 'img',     'USD', 'mensal'),
    ('April International', 'april',   'EUR', 'mensal'),
    ('VUMI',                'vumi',    'USD', 'mensal')
ON CONFLICT (codigo) DO NOTHING;
