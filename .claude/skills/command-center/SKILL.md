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

## 2. Coleta de dados (chamadas em paralelo sempre que possível)

Colete apenas de integrações disponíveis na sessão (verifique com ToolSearch);
se alguma estiver fora, siga sem ela e registre no rodapé do painel.

1. **Google Calendar** (compromissos)
   - `list_calendars` para descobrir agendas (pessoal vs. trabalho).
   - `list_events` de hoje 00:00 até +7 dias, nas agendas relevantes.
2. **Gmail** (pendências de e-mail) — `search_threads` com:
   - `in:inbox is:unread newer_than:7d` (não lidos recentes)
   - `is:starred` (marcados pelo usuário)
   - `in:inbox is:important is:unread` (importantes)
3. **Granola** (reuniões e action items): `list_meetings`/`get_meetings` dos
   últimos 7 dias; extraia action items pendentes atribuídos ao Sergio.
4. **Slack** (se conectado): menções e DMs não respondidas recentes.
5. **GitHub** (profissional/dev): PRs abertos e issues atribuídas nos repos da
   sessão, se fizer sentido no contexto.
6. **QuickBooks** (financeiro, opcional): `qbo_accounting_get_ar_aging_summary`
   para contas a receber vencidas, só se o usuário pedir visão financeira.

Mantenha as consultas enxutas (pageSize pequeno); o painel mostra o topo, não
o histórico completo.

## 3. Triagem

Classifique cada item em dois eixos:

- **Urgência**: `HOJE` (prazo/compromisso hoje ou atrasado) · `ESTA SEMANA`
  (próximos 7 dias) · `RADAR` (sem prazo, mas relevante).
- **Esfera**: `Profissional` (domínios de trabalho, clientes, seguradoras,
  agenda de trabalho) vs. `Pessoal` (agenda pessoal, e-mails pessoais,
  família, saúde). Na dúvida, marque Profissional.

Selecione um **Top 3 do dia**: os 3 itens mais críticos considerando prazo,
remetente/participantes e impacto. Justifique em uma linha cada.

## 4. Renderização (Artifact)

Antes de escrever o HTML, carregue a skill `artifact-design` (obrigatório para
Artifacts). Depois escreva o arquivo no scratchpad e publique com `Artifact`
(favicon sugerido: `🕹️`; ao ATUALIZAR um painel existente na mesma sessão,
reutilize o mesmo caminho de arquivo para manter a URL).

Estrutura da página (mobile-first — Sergio usa PWAs no Android):

1. **Cabeçalho**: logo da Hamsa + "Command Center — Hamsa", data por extenso
   em pt-BR, hora da geração. O logo é obrigatório: use o símbolo 2026 com
   fundo transparente (`hamsa_simbolo_2026.png` na raiz deste repo), reduzido
   para ~220px com Pillow (`pip install pillow`) e embutido como data URI
   base64 (`data:image/png;base64,...`) — o Artifact não pode referenciar
   imagens externas. Altura de exibição ~52px, à esquerda do título.
2. **Top 3 urgências do dia** — cartões em destaque (dourado).
3. **Agenda de hoje** — linha do tempo com horários; destaque o próximo
   compromisso; badge Pessoal/Profissional.
4. **Semana à frente** — compromissos importantes por dia (agrupados).
5. **Pendências de e-mail** — remetente, assunto, idade, link
   `https://mail.google.com/mail/u/0/#inbox/<threadId>`.
6. **Tarefas & follow-ups** — duas colunas (Profissional | Pessoal), com
   origem de cada item (reunião, e-mail, Slack).
7. **Rodapé** — fontes consultadas, integrações indisponíveis, e nota "gerado
   por /command-center".

Requisitos técnicos: HTML autocontido (CSS/JS inline, sem CDN), responsivo,
tema claro/escuro via `prefers-color-scheme` + `:root[data-theme=...]`,
tabelas/listas largas com `overflow-x:auto`. Não exponha conteúdo integral de
e-mails — só remetente/assunto/resumo de uma linha.

**Interatividade obrigatória (concluir/adiar):** todo item acionável (Top 3,
agenda, semana, e-mails, follow-ups) recebe, via JS injetado no load, um
checkbox `✓` (concluir → risca e esmaece o item) e um botão `adiar` (esmaece
e vira `retomar`; itens adiados voltam ao normal automaticamente no dia
seguinte). Estado persistido em `localStorage` na chave `hamsa-cc-v1`, com id
derivado de hash do texto normalizado do item (assim os checks sobrevivem a
republicações do painel na mesma URL). Mostrar linha de progresso no
cabeçalho ("X concluído(s) · Y adiado(s)") e nota no rodapé de que os
marcadores ficam salvos no navegador. Ao RE-GERAR o painel em outra sessão,
lembre que esse estado é local do navegador do usuário — não presuma no chat
que algo foi concluído.

## 5. Resposta ao usuário

Além do link do Artifact, escreva no chat um resumo de 3–6 linhas: o Top 3 do
dia e o primeiro compromisso de amanhã. Se detectar conflito de agenda ou
prazo estourado, destaque no início.

## 6. Agendamento (opcional, só se o usuário pedir)

Se o usuário quiser o painel automaticamente (ex.: toda manhã), crie uma
rotina com `create_trigger` (Claude Code Remote) — ex.: cron `30 7 * * 1-5`,
prompt "Execute a skill /command-center e gere o painel do dia". Confirme o
horário com o usuário antes de criar.
