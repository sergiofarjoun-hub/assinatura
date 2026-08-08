# Agente WhatsApp × Multicálculo — cotação automática

Desenho da integração que faz o **Hamsa Group Concierge (WhatsApp)** gerar a
proposta no **Multicálculo** e devolvê-la ao cliente — hoje esse caminho termina
em "retorno em 3–5 dias úteis" + escalação para concierge humano.

## Caso real que motivou (teste de 07/08/2026)

O agente já coleta bem o intake de cotação, em conversa natural:

> 3 vidas (52, 52, 16) · residência Brasil · cobertura Brasil + EUA livre
> escolha · sem pré-existências · objetivo: alternativas à VUMI

…e então para: `🔔 Concierge solicitado` + promessa de 3–5 dias úteis.
**É exatamente nesse ponto que a automação entra**: com esses dados o
Multicálculo gera o comparativo em segundos.

## O que já existe (verificado no código em 08/08/2026)

### Multicálculo (repo `hamsa-multicalculo`, container `hamsa-cotacao` no NAS, porta 9191)

| Rota | Função |
|---|---|
| `GET /` | serve a calculadora (`HAMSA_MultiCalculo.html`) |
| `POST /gerar` | recebe `{nome, data, idade, idade_conjuge, num_filhos, dolar, selected_plans[]}` e gera PPTX + PDF (template `quote.pptx` + LibreOffice), devolvendo links `/download/...` |
| `GET /download/<arquivo>` | entrega o PDF/PPTX gerado |

- **Tabelas de preço** (`RATES`): anuais em USD por plano × faixa etária ×
  franquia, + grupos de filhos (1/2/3+), **embutidas no HTML** (~linha 326).
- **Catálogo** (`PLANS`): VUMI (Absolute, Universal, Direct, Special, Senior 60+),
  EVER (Everest Prestige, Everywhere, Everpresent, Everlasting 60+),
  RED/RedBridge (Supreme, Protection, Inpatient), AFA/American Fidelity
  (Superior Open/Ultra, Optima Plus/Ultra, Vital Core/Plus) e BDI Medical Elite.
- **Descontos** (affinity/incentive por marca, toggle médico, VUMI Direct 15%):
  calculados **no JavaScript do navegador** (`getDiscountFactor`, `lookupRate`,
  `lookupChildren`).

### Agente WA (`agente-wa-app`, código no Mac em `SISTEMA HAMSA/agente-wa-app/`, fora do GitHub)

- Máquina de conversa com memória + knowledge base (`kb/`).
- Intake de cotação estruturado e escalação com resumo (`🔔 Concierge solicitado`).

## O gap

`POST /gerar` **não calcula preço** — espera `selected_plans` com os valores já
computados. Quem calcula é o navegador. Um agente automático precisa desse
cálculo **no servidor**.

## Desenho da solução

### Fase 1 — Motor de cálculo server-side (repo `hamsa-multicalculo`)

1. **Extrair `RATES` + `PLANS` do HTML para `rates.json`** — fonte única de
   verdade. O HTML passa a carregar esse JSON (via `fetch` no boot) e o servidor
   Python passa a lê-lo também. Atualização de tabela vira edição de 1 arquivo.
2. **Novo endpoint `POST /cotar`** no `server.py` (mesmo container):

   ```json
   {
     "idade": 52,
     "idade_conjuge": 52,
     "num_filhos": 1,
     "marcas": ["ever", "red", "afa", "bdi"],
     "franquias": [2000, 5000, 10000],
     "dolar": 5.16
   }
   ```

   Resposta: `selected_plans[]` no formato exato que `/gerar` já consome
   (replicando `lookupRate`/`lookupChildren`/descontos em Python).
   Cadeia completa: `/cotar` → `/gerar` → link do PDF. Nada muda na UI.
3. **Descontos default conservadores** para cotações automáticas: os padrões
   atuais da calculadora sem toggles manuais (VUMI Direct 15%, demais marcas
   10% — regra já vigente no Multicálculo). Toggle "médico" nunca automático.

### Fase 2 — Ponte no agente WA (`agente-wa-app`)

Quando o intake estiver completo **e** sem pré-existências declaradas:
mapear intake → parâmetros (titular = `idade`; 2º adulto = `idade_conjuge`;
menores = `num_filhos` 1/2/3+), chamar `/cotar` + `/gerar` na rede interna do
NAS e receber o PDF.

### Fase 3 — Aprovação humana antes do envio (v1 obrigatório)

O agente **não** manda a proposta direto ao cliente. Fluxo v1:

1. Agente gera o PDF e envia **para o Sergio** no WhatsApp: resumo do caso +
   PDF + "responda APROVAR para enviar ao cliente, ou ajuste no Multicálculo".
2. Sergio aprova → agente envia ao cliente com mensagem padrão + disclaimer.
3. Sem resposta em N horas → lembrete; nunca envia sozinho.

v2 (opcional, depois de rodar bem): envio automático apenas para casos limpos
(sem pré-existência, idades dentro da tabela), mantendo cópia para o Sergio.

## Guardrails (não negociáveis)

- **Pré-existência declarada → nunca cotar automático.** Roteia para
  posicionamento de underwriting (concierge humano), como hoje.
- **Idade fora da tabela** (ex.: >75 na maioria dos planos) → concierge humano.
- **Disclaimer sempre presente** na mensagem e no PDF: valores indicativos,
  sujeitos a underwriting e confirmação da seguradora.
- **Dólar**: valor configurável (default atual 5.16) — nunca inventado pelo bot.
- **Nada exposto à internet**: `/cotar` fica na tailnet como todo o resto;
  o agente WA chama via rede interna do NAS.
- **Log de toda cotação automática** (payload + PDF gerado + quem aprovou).

## Inconsistência a corrigir no bot

O script do agente oferece "Best Doctors, Redbridge, AFGS, **Trawick**" — mas
Trawick **não existe** no Multicálculo. Corrigir o texto do bot para as marcas
reais (VUMI, EVER, RedBridge, American Fidelity, BDI) ou adicionar o carrier à
calculadora antes.

## Onde implementar

| Peça | Onde | Esforço |
|---|---|---|
| `rates.json` + `POST /cotar` | repo `hamsa-multicalculo` (`docker/app/`) | 1 sessão |
| Ponte + fluxo de aprovação | `agente-wa-app` no Mac (sessão Claude Code local) | 1–2 sessões |
| Deploy | NAS, protocolo padrão (backup → unlock → 1 execução → smoke test) | — |

A Fase 1 pode ser desenvolvida e testada **inteiramente fora do NAS** (o
container roda local com `docker compose up`); só o deploy final toca produção.
