# Banco unificado — PostgreSQL no NAS `hamsa-usa`

**Decisão de arquitetura:** antes de qualquer app novo, um **PostgreSQL único**
em container no NAS com os **cadastros mestres** — `cliente`, `apolice`,
`seguradora`, `produto` — e os apps consumindo dele. Hoje cada app (servidores
Python independentes) tende a ter a própria cópia de "cliente" e "apólice";
o banco unificado elimina retrabalho e divergência. Esta é a fundação para
tudo que vier depois.

## Visão geral

```
                         NAS hamsa-usa (100.94.13.31)
┌────────────────────────────────────────────────────────────────────┐
│  ┌──────────────┐ ┌────────────┐ ┌────────┐ ┌──────────┐  ...      │
│  │ CommandCenter│ │ Renovações │ │ Claims │ │ Pipeline │           │
│  │    :4000     │ │   :3001    │ │ :9292  │ │  :5556   │           │
│  └──────┬───────┘ └─────┬──────┘ └───┬────┘ └────┬─────┘           │
│         │               │           │           │                 │
│         └───────────────┴─────┬─────┴───────────┘                  │
│                               ▼                                    │
│                     ┌───────────────────┐                          │
│                     │  hamsa-db :5432   │  PostgreSQL 16           │
│                     │  schema core      │  (mestres, fonte única)  │
│                     │  schema por app   │  (dados próprios)        │
│                     └───────────────────┘                          │
│   dados: /volume1/docker/hamsa-db/data                             │
│   dumps: /volume1/docker/hamsa-db/backups (→ Hyper Backup)         │
└────────────────────────────────────────────────────────────────────┘
```

Princípios:

1. **`core` é a fonte única dos mestres.** Cliente, seguradora, produto e
   apólice vivem no schema `core`. Nenhum app mantém cópia própria desses
   cadastros depois de migrado.
2. **Um schema por app para o que é do app.** Cotações do Multi Cálculo,
   tickets do Claims, funil do Pipeline etc. ficam em schemas próprios
   (`renovacoes`, `claims`, `pipeline`, `multicalculo`, `multiapolices`,
   `commandcenter`) — referenciando os mestres por FK, nunca duplicando.
3. **Um papel (role) por app, com o mínimo de privilégio.** Cada app entra
   com seu próprio usuário: leitura em `core` + escrita apenas no seu schema.
   Escrita nos mestres começa centralizada (ver Fase DB4) para não nascer
   bagunça.
4. **Migração estranguladora, não big-bang.** Os 6 apps continuam funcionando
   como estão; cada um migra quando fizer sentido, primeiro lendo de `core`,
   depois escrevendo. Nenhuma fase quebra o que já roda.

## Endereço e conexão

| Item | Valor |
|------|-------|
| Container | `hamsa-db` (postgres:16-alpine, `restart: unless-stopped`) |
| Porta | `5432` (LAN/tailnet — o NAS não é exposto à internet) |
| Banco | `hamsa` |
| Admin | `hamsa_admin` (senha gerada no provisionamento) |
| Papéis dos apps | `app_renovacoes`, `app_claims`, `app_pipeline`, `app_multicalculo`, `app_multiapolices`, `app_commandcenter` |
| Credenciais | `/volume1/docker/hamsa-db/credenciais.txt` (chmod 600, só root) |

DSN de exemplo (de dentro de um container de app, usar o IP do NAS — o mesmo
que os apps já usam entre si):

```
postgresql://app_renovacoes:SENHA@100.94.13.31:5432/hamsa
```

> **Segurança:** a porta 5432 só é alcançável pela LAN e pelo tailnet (mesmo
> perímetro dos apps hoje, que já servem HTTP nessas redes). Senhas fortes
> geradas por papel; nada de senha compartilhada entre apps. Se quiser apertar
> mais: DSM → Firewall → permitir 5432 apenas para a subnet Docker + tailnet.

## Schema `core` (mestres)

| Tabela | O que guarda | Pontos-chave |
|--------|--------------|--------------|
| `core.cliente` | PF/PJ, contato, endereço | `cpf_cnpj` único (só dígitos); `dados jsonb` p/ campos extras |
| `core.seguradora` | Companhias | `cnpj`/`codigo_susep` únicos; flag `ativo` |
| `core.produto` | Produtos por ramo/seguradora | único por (`seguradora_id`, `nome`) |
| `core.apolice` | Apólices | FK p/ cliente, seguradora, produto; único por (`seguradora_id`, `numero`); `fim_vigencia` indexado (motor das Renovações) |
| `core.apolice_segurado` | Titular/dependentes/beneficiários por apólice | N:N entre apólice e cliente, com papel |

Convenções (valem para os schemas de app também):

- PK `uuid` com `gen_random_uuid()` — permite gerar ID no app sem round-trip
  e facilita importar dados legados sem colisão.
- `criado_em` / `atualizado_em` `timestamptz`, com trigger de `atualizado_em`.
- Campos específicos de ramo em `dados jsonb` — evita ALTER TABLE a cada
  particularidade de saúde/vida/auto/viagem.
- View pronta `core.v_apolices_a_vencer` (vigência ≤ 90 dias) — o feed
  natural do app de Renovações.

DDL completo: [`nas/db/schema-core.sql`](nas/db/schema-core.sql).

## Fases (mesmo protocolo das fases A/B do PWA)

| Fase | Script | O que faz | Risco |
|------|--------|-----------|-------|
| **DB0 — Inventário** | [`nas/db/fase-db0-inspect-storage.sh`](nas/db/fase-db0-inspect-storage.sh) | **Somente leitura.** Descobre onde cada app guarda dados hoje (SQLite? JSON? CSV?), confere se a 5432 está livre e se já existe Postgres no NAS (ex.: o DocuSeal pode embutir um). A saída decide o plano de carga da DB3. | zero |
| **DB1 — Provisionar** | [`nas/db/fase-db1-provision.sh`](nas/db/fase-db1-provision.sh) | Sobe o `hamsa-db` (compose em `/volume1/docker/hamsa-db`), aplica o schema `core` + schemas de app, cria papéis com senhas geradas, grava `credenciais.txt` (600) e verifica com `pg_isready` + contagem de tabelas. Não toca em nenhum app. | baixo |
| **DB2 — Backup** | [`nas/db/backup-db.sh`](nas/db/backup-db.sh) | `pg_dump -Fc` diário com retenção de 14 dias em `backups/`. Agendar no DSM (Task Scheduler) e incluir a pasta no Hyper Backup. **Agendar antes de pôr dado de verdade.** | zero |
| **DB3 — Carga dos mestres** | (a escrever após a DB0) | Importa clientes/apólices/seguradoras/produtos da melhor fonte identificada na DB0 (provavelmente Renovações ou Multi Apólices), com deduplicação por `cpf_cnpj` e (`seguradora`,`numero`). Idempotente: rodar 2× não duplica. | baixo |
| **DB4 — Apps consomem** | (1 script por app, sob demanda) | Cada app passa a **ler** de `core` (mantendo o storage antigo como fallback num primeiro momento) e depois a **escrever**. Ordem sugerida: Renovações (dono natural de apólices) → Multi Apólices → Pipeline (clientes) → Claims → CC/Multi Cálculo. | médio, por app |

> **Regra de ouro da DB4:** enquanto dois lugares puderem escrever o mesmo
> cadastro, um deles é o dono e o outro é read-only. Nunca dois donos.

## Backup e restauração

- Dump: `backup-db.sh` gera `backups/hamsa_AAAAMMDD_HHMMSS.dump` (formato
  custom, comprimido) e apaga o que passar de 14 dias.
- Agendamento: DSM → Painel de Controle → Task Scheduler → tarefa root diária
  (ex.: 02:00) rodando `sh /volume1/docker/hamsa-db/backup-db.sh`.
- Hyper Backup: incluir `/volume1/docker/hamsa-db/backups` (o **dump**, não o
  `data/` vivo — copiar data dir de Postgres em uso gera backup corrompido).
- Restaurar: `sudo docker exec -i hamsa-db pg_restore -U hamsa_admin -d hamsa --clean < arquivo.dump`.
- Teste de restauração: 1× por trimestre, restaurar num banco `hamsa_teste`
  e conferir contagens.

## O que NÃO fazer

- ❌ Apps novos com SQLite/JSON próprio para cliente/apólice — nasce apontando
  pro `core`.
- ❌ Dar `hamsa_admin` (superuser) a um app — cada app usa o seu papel.
- ❌ Backup copiando `/volume1/docker/hamsa-db/data` com o banco em pé — usar
  o dump.
- ❌ Expor a 5432 via `tailscale funnel` ou port-forward — LAN/tailnet basta.
- ❌ Duplicar mestre em schema de app "só por conveniência" — FK para `core`.
