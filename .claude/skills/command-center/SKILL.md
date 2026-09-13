---
name: command-center
description: >
  Monta o Command Center pessoal/profissional do Sergio: um painel HTML
  (Artifact) com as principais urgências do dia e da semana, compromissos do
  Google Calendar, pendências de e-mail do Gmail, reuniões recentes (Granola)
  e follow-ups. Use quando o usuário pedir "command center", "painel do dia",
  "briefing do dia/semana", "minhas pendências", "o que tenho pra hoje" ou
  variações. Também serve para re-gerar/atualizar o painel.
---

# Command Center — briefing do dia e da semana

Você vai coletar dados das integrações conectadas, triar por urgência e
renderizar um painel HTML amigável via ferramenta **Artifact**. O resultado
final é UMA página, em português (pt-BR), com identidade visual Hamsa.

## 1. Contexto fixo

- Usuário: Sergio (sergio@chamsa.com.br), corretora de seguros **Hamsa**.
- Fuso horário: `America/Sao_Paulo`. Obtenha a data/hora atual com
  `TZ=America/Sao_Paulo date` antes de qualquer consulta.
- Janela padrão: **hoje** (dia atual) e **semana** (hoje + 7 dias corridos).
- Identidade visual: navy `#0b1424` (fundo/tema), dourado `#c9a24b` (acentos),
  mesma linguagem dos PWAs Hamsa deste repositório.

## 2. URL fixa — SEMPRE atualizar o mesmo Artifact

O painel tem UMA casa. Nunca crie um segundo Artifact de Command Center:

1. Procure o painel existente com `Artifact` `action: "list"` — título
   **"Command Center Hamsa"**, favicon 🕹️.
2. Se existir: faça `action: "read"` na URL dele (obrigatório antes de
   republicar de outra sessão) e depois publique passando `url` — a URL não
   muda, e o Sergio a tem fixada na tela inicial do Android e no sidebar.
3. Se não existir (primeira vez): publique novo com `<title>Command Center
   Hamsa</title>`, favicon `🕹️`, e ofereça fixar (`action: "pin"`) — fixe
   apenas se ele disser sim.
4. Ao republicar na MESMA sessão, reutilize o mesmo caminho de arquivo no
   scratchpad. Ao republicar, omita `favicon` e `capabilities` para manter os
   já armazenados (declare `capabilities` só na primeira publicação ou se o
   modelo de dados mudar).

## 3. Estado compartilhado e memória (capacidade `db`)

O painel usa o banco compartilhado do Artifact para que "✓ concluir"/"adiar"
sincronizem entre Mac, Android e regenerações. **Antes de escrever o HTML,
carregue a skill `artifact-capabilities`** e siga o contrato dela; declare
`capabilities: {db: {}}` na primeira publicação.

Modelo de dados — coleção `items`, um doc por pendência, com `doc_id` =
hash estável do texto normalizado do item (minúsculas, sem acentos/espaços
extras — mesmo esquema no gerador e na página):

```json
{
  "title":  "Responder proposta Porto Seguro",
  "sphere": "business" | "pessoal",
  "status": "pending" | "done" | "snoozed",
  "first_seen": "2026-09-13",
  "last_seen":  "2026-09-13",
  "done_at": "...",        // quando status=done
  "snoozed_until": "...",  // quando status=snoozed (padrão: amanhã)
  "source": "gmail:<threadId>" | "calendar:<eventId>" | "granola:..." | "manual"
}
```

- **Na página**: `const db = await claude.use("db")`; botões gravam via
  `db.doc("items/"+id)` e `onSnapshot` reflete mudanças de outros aparelhos.
  Se `db` vier `null` (visualização sem capacidade), caia para `localStorage`
  (chave `hamsa-cc-v1`) sem quebrar nada.
- **Ao gerar/regerar o painel** (você, nesta sessão): ANTES de renderizar,
  leia a coleção com `Artifact` `action: "read_db"` (`db_op: "query"` ou
  `"list"`). Use o resultado para:
  - **não reexibir** como pendente o que está `done` (mostre no máximo um
    contador "X concluídos desde ontem");
  - itens `snoozed` com `snoozed_until` futuro vão para o quadrante Radar com
    nota "adiado até <data>"; vencido o prazo, voltam ao quadrante normal;
  - calcular a etiqueta de idade: item pendente com `first_seen` ≥ 2 dias
    atrás ganha badge **"no painel há N dias"** (âmbar a partir de 2, vermelho
    a partir de 5) — nada escapa por envelhecer.
- Depois de montar a lista final, grave os itens novos/atualizados com
  `action: "write_db"` `db_op: "batch"` (set para novos com `first_seen` =
  hoje; update de `last_seen`/`title` para os já existentes, preservando
  `first_seen` e `status`, com `if_version`).
- Itens que sumiram das fontes (e-mail arquivado etc.) e estão `pending` há
  mais de 30 dias sem `last_seen` recente podem ser ignorados na leitura; não
  precisa apagar docs.

### Fila de delegação (coleção `queue`)

O botão "☁ delegar ao Claude" do painel grava docs na coleção `queue`
(mesmo `doc_id` do item; campos `title`, `sphere`, `source`, `status`,
`requested_at`). **Em toda geração, leia também `queue`**: cada doc com
`status: "queued"` é um pedido do Sergio para você executar aquela pendência.

- Execute o que for seguro sem confirmação: rascunhos de e-mail
  (`create_draft`, nunca `send`), minutas de cobrança de renovação, resumos,
  pesquisas. Ao concluir, `update` do doc para `status: "done"` +
  `result` (1 linha) e relate no chat o que foi feito.
- O que exigir ação irreversível (enviar e-mail, pagar, cancelar), deixe
  pronto como rascunho, marque `status: "ready"` e peça confirmação no chat.
- Não conseguiu (falta acesso/contexto)? `status: "blocked"` + `result`
  explicando, e diga no chat o que falta.

## 4. Coleta de dados (chamadas em paralelo sempre que possível)

Colete apenas de integrações disponíveis na sessão (verifique com ToolSearch);
se alguma estiver fora, siga sem ela e registre no rodapé do painel.

1. **Google Calendar** (compromissos)
   - `list_calendars` para descobrir agendas (pessoal vs. trabalho).
   - `list_events` de hoje 00:00 até +7 dias, nas agendas relevantes.
   - Guarde o link de videochamada do evento (hangoutLink/conferenceData, ou
     URL de Zoom/Meet no location/description) para o botão "entrar".
2. **Gmail** (pendências de e-mail) — `search_threads` com:
   - `in:inbox is:unread newer_than:7d` (não lidos recentes)
   - `is:starred` (marcados pelo usuário)
   - `in:inbox is:important is:unread` (importantes)
3. **Granola** (reuniões e action items): `list_meetings`/`get_meetings` dos
   últimos 7 dias; extraia action items pendentes atribuídos ao Sergio.
4. **Slack** (se conectado): menções e DMs não respondidas recentes.
5. **GitHub** (profissional/dev): PRs abertos e issues atribuídas nos repos da
   sessão, se fizer sentido no contexto.

Mantenha as consultas enxutas (pageSize pequeno); o painel mostra o topo, não
o histórico completo.

## 5. Triagem

Classifique cada item em dois eixos:

- **Urgência**: `HOJE` (prazo/compromisso hoje ou atrasado) · `ESTA SEMANA`
  (próximos 7 dias) · `RADAR` (sem prazo, mas relevante).
- **Esfera**: `Business` (domínios de trabalho, clientes, seguradoras,
  agenda de trabalho) vs. `Pessoal` (agenda pessoal, e-mails pessoais,
  família, saúde). Na dúvida, marque Business.

### Regras de prioridade do negócio (seguros)

Suba automaticamente para Q1/Top 3 (salvo spam/newsletter óbvios):

- **Palavras-chave críticas** no assunto/corpo: *sinistro, apólice, renovação,
  endosso, vencimento, cancelamento, proposta, cotação, boleto, regulação,
  indenização, vistoria*. "Sinistro" é sempre a prioridade máxima do dia.
- **Remetentes VIP** — domínios de seguradoras e parceiros: portoseguro,
  bradescoseguros, sulamerica, allianz, tokiomarine, hdi, mapfre, azulseguros,
  suhaicorretora/suhai, akadseguros/akad, sancorseguros, zurich, chubb, ezze,
  swissre, pier (ajuste/expanda conforme o Sergio pedir — esta lista é dele).
- E-mail de **cliente aguardando resposta há ≥ 2 dias** sobe um quadrante.

A antiguidade (badge "no painel há N dias", da seção 3) também pesa: item
âmbar/vermelho não pode ficar em Q4.

### Radar de renovações (card obrigatório)

Procure ativamente **vencimentos e renovações de apólices nos próximos 30
dias**: no Gmail (`search_threads` com `renovação OR vencimento OR "vigência"
newer_than:60d`) e em eventos/lembretes do Calendar. Monte o card
**"🔄 Renovações — próximos 30 dias"** listando cliente/seguradora, data e
link do e-mail, ordenado por data. Sem achados: "Nenhuma renovação detectada
nos próximos 30 dias" (deixe claro que a detecção é por e-mail/agenda, não
pelo sistema da corretora).

Selecione um **Top 3 do dia**: os 3 itens mais críticos considerando prazo,
regras acima, remetente/participantes e impacto. Justifique em uma linha cada.

## 6. Renderização (Artifact)

Antes de escrever o HTML, carregue a skill `artifact-design` (obrigatório para
Artifacts). Depois escreva o arquivo no scratchpad e publique conforme a
seção 2 (URL fixa).

Estrutura da página (mobile-first — Sergio usa PWAs no Android):

1. **Cabeçalho**: logo da Hamsa + "Command Center — Hamsa", data por extenso
   em pt-BR, hora da geração. O logo é obrigatório: use o símbolo 2026 com
   fundo transparente (`hamsa_simbolo_2026.png` na raiz deste repo), reduzido
   para ~220px com Pillow (`pip install pillow`) e embutido como data URI
   base64 (`data:image/png;base64,...`) — o Artifact não pode referenciar
   imagens externas. Altura de exibição ~52px, à esquerda do título.
2. **Top 3 urgências do dia** — cartões em destaque (dourado).
3. **Agenda de hoje** — linha do tempo com horários; destaque o próximo
   compromisso; badge Pessoal/Business; evento com videochamada ganha botão
   **"📹 entrar"** (link direto Meet/Zoom).
4. **Semana à frente** — compromissos importantes por dia (agrupados).
5. **🔄 Renovações — próximos 30 dias** (card da seção 5).
6. **Matriz Business** e 7. **Matriz Pessoal** — duas matrizes de Eisenhower
   (importância × urgência), cada uma em grade 2×2 (1 coluna no mobile):
   - Q1 `Urgente + Importante` → "Fazer agora" (borda superior vermelha)
   - Q2 `Importante, não urgente` → "Agendar" (borda dourada)
   - Q3 `Urgente, menos importante` → "Delegar / despachar rápido" (azul)
   - Q4 `Nem urgente, nem importante` → "Radar / quando der" (neutra)
   Distribua nelas TODAS as pendências acionáveis (e-mails, follow-ups,
   action items), com idade ("aguardando desde 10/jun"), badge "no painel há
   N dias" quando aplicável, e botões de ação. Quadrante vazio ganha texto em
   itálico (ex.: "Sem itens no radar — bom sinal"), não lista.
8. **Rodapé** — fontes consultadas, integrações indisponíveis, contagem "X
   concluídos", e nota "gerado por /command-center".

Requisitos técnicos: HTML autocontido (CSS/JS inline, sem CDN), responsivo,
tema claro/escuro via `prefers-color-scheme` + `:root[data-theme=...]`,
tabelas/listas largas com `overflow-x:auto`. Não exponha conteúdo integral de
e-mails — só remetente/assunto/resumo de uma linha.

**Interatividade obrigatória:** todo item acionável (Top 3, e-mails,
follow-ups, renovações) recebe botões-pílula COM RÓTULO VISÍVEL (nunca um
checkbox sem texto):

- `✓ concluir` (contorno dourado; ao marcar vira `✓ concluído` preenchido,
  risca e esmaece o item);
- `adiar` (esmaece, grava `snoozed_until` = amanhã e vira `retomar`);
- item de e-mail: `✉ responder` — link `https://mail.google.com/mail/u/0/
  #inbox/<threadId>` abrindo em nova aba;
- evento com videochamada: `📹 entrar`;
- `🤖 agente` — link `https://hamsa-usa.taild4370d.ts.net:3010/?task=<texto
  da tarefa URL-encoded>` (nova aba): abre o Hamsa Agent do NAS com a tarefa
  pré-preenchida (o `manus/` aceita `?task=`); inclua o link do e-mail no
  texto quando houver;
- `☁ delegar ao Claude` — grava o item na coleção `queue` (seção 3); botão
  só aparece quando o `db` conecta, e vira "na fila"/"feito" conforme o
  status.

**Integração Agentic OS:** o cabeçalho traz uma barra de atalhos-pílula para
os apps da tailnet (`DEPLOY.md` tem as portas): Hub `/`, Renovações `:8443`,
Claims `:10000`, Multi Cálculo `:10001`, Multi Apólices `:10002`, Pipeline
`:10003`, Hamsa Agent `:3010` — base `https://hamsa-usa.taild4370d.ts.net`.
Com nota de que exigem Tailscale ligado.

Estado gravado no `db` (seção 3), com fallback `localStorage`. Mostrar linha
de progresso no cabeçalho ("X concluído(s) · Y adiado(s)") que atualiza ao
vivo via `onSnapshot`.

## 7. Resposta ao usuário

Além do link do Artifact, escreva no chat um resumo de 3–6 linhas: o Top 3 do
dia, renovações próximas e o primeiro compromisso de amanhã. Se detectar
conflito de agenda, prazo estourado ou item vermelho ("no painel há 5+
dias"), destaque no início. Não presuma no chat que algo foi concluído sem
ver `status: "done"` no db.

## 8. Agendamento

Existe (ou pode existir) uma rotina "Command Center matinal" que roda em dias
úteis de manhã, gera o painel e envia push com o Top 3. Se o usuário pedir
para criar/alterar/pausar, use `create_trigger`/`update_trigger` (Claude Code
Remote); confirme o horário antes de criar. Numa execução disparada pela
rotina, siga esta skill normalmente (URL fixa, db, resumo curto — o resumo
vira a notificação).
