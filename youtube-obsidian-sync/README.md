# YouTube → Obsidian Sync

Transforma vídeos do YouTube — e, desde 18/10/2026, **posts e reels do Instagram** — em notas
Markdown no vault **BASE_CONHECIMENTO**: você cola a URL numa nota de fila, e de hora em hora o sync baixa metadados + legenda e cria a nota
com a **transcrição em texto** e, opcionalmente, **frames do vídeo** em `YouTube/`. Nada de
assistir de novo para achar aquele trecho — e o conteúdo passa a estar disponível para
busca, para links do Obsidian e para o Claude ler.

Os frames são o que permite a um agente **ver** o vídeo: um modelo não processa vídeo, mas
lê imagens. Fatiado em imagens com marca de tempo, o conteúdo visual (tela de código,
slide, diagrama) entra na nota junto com a fala.

## Arquitetura

```
Você cola a URL em <vault>/YouTube/_fila.md
   └─ Mac, de hora em hora, minuto 20 (launchd por calendário): yt-sync.sh
        ├─ yt-dlp: metadados (.info.json) e depois UMA legenda (.vtt/.srt), sem baixar o vídeo
        ├─ [opcional] sem legenda → baixa o áudio e chama seu transcritor local (Whisper)
        ├─ [opcional] frames → baixa o vídeo, ffmpeg corta nas mudanças de cena,
        │                       descarta o vídeo
        └─ yt2vault.py: → <vault>/YouTube/<data> - <título> (<id>).md
             └─ marca a linha da fila como feita, apontando para a nota
```

- **Idempotente**: cada vídeo vira uma nota só. Estado em
  `<vault>/YouTube/.yt-sync-state.json` (oculto no Obsidian); ID já importado é pulado,
  mesmo que a URL apareça de novo na fila.
- **Legenda limpa**: as legendas automáticas do YouTube são "rolantes" (cada trecho repete
  o final do anterior). O parser desfaz isso, remove as marcações inline e `[Música]`, e
  agrupa em parágrafos com marca de tempo a cada ~30s.
- **Uma legenda só, a melhor**: manual no idioma preferido → manual no idioma original →
  automática do **idioma original** → tradução automática no idioma preferido → o que houver.
  A tradução automática fica por último de propósito: ela é gerada em cima da legenda
  automática, e erra mais em nome próprio e termo técnico. Pedir várias línguas de uma vez
  (`pt`, `pt-PT`, `en`, `en-orig`) fazia o YouTube responder **HTTP 429**; agora vem uma só,
  com uma pausa de 6 s antes do download (`--sleep-subtitles`).
- **Vault indisponível (mount do NAS fora)?** Grava uma linha "Vault indisponível" no log, sai
  com código 0 e tenta na hora seguinte. Escrita é atômica (tmp + rename) — nada de nota pela
  metade.
- **Fallback espalhado pelo vídeo todo**: quando cai no intervalo fixo, o intervalo cresce o
  quanto for preciso para os `framesMax` frames se espalharem por toda a duração —
  `framesEvery` é o **mínimo**, não o valor final. Antes, 60 frames a cada 10 s paravam nos
  primeiros 10 min de um vídeo de 21. Amostrar por intervalo nunca alcança o fim exato: a
  última imagem fica a menos de um intervalo do final (num vídeo de 20 min com 60 frames,
  os últimos 20 s).
- **Frames por mudança de cena**: com `framesEvery` > 0, o vídeo é baixado, cortado nas
  **trocas de cena** (primeiro frame + cada mudança acima do limiar) e **apagado em
  seguida** — só as imagens ficam, em `<vault>/YouTube/_frames/<id>/`, embutidas na nota
  com a marca de tempo real. Num screencast isso captura cada slide uma vez, em vez de
  três frames do mesmo slide parado. Vídeo de plano único (talking head) rende quase
  nenhuma cena: abaixo de `sceneMinFrames`, cai automaticamente para intervalo fixo.
- **Lock** em `~/.yt-obsidian-sync/sync.lock` impede execuções sobrepostas (stale após 30min).

## Instagram (post, carrossel ou reel)

A mesma fila aceita `instagram.com/p/<código>/`, `/reel/`, `/reels/` e `/tv/` (com ou sem o
usuário na frente; `?img_index=…` e outros parâmetros são ignorados). O código do post tem 11
caracteres, como o id do YouTube — o nome da nota, o estado e o `youtube-nota` do Hamsa OS
servem aos dois.

- **Post de imagens (um ou carrossel):** o Instagram não tem legenda; o texto do autor vai para
  `## Descrição`. O yt-dlp não baixa imagem como vídeo, mas com `--ignore-no-formats-error
  --write-thumbnail` entrega a imagem inteira de cada item (HEIC, às vezes JPG/WEBP). Cada uma
  vira um "frame" rotulado `**[slide N/T]**`, **independente de `framesEvery`** (os slides são o
  conteúdo). Conversão HEIC→JPG pelo `sips` do macOS (ffmpeg de reserva), maior lado em
  `slidesMaxSize` px (padrão 1440). Nome do arquivo: `<id>-NNN-SSSSS.jpg`, com SSSSS = número
  do slide. A Transcrição traz a frase `_Post de imagens, sem áudio…_`.
- **Reel (ou post de um vídeo só):** baixa o vídeo e corta frames como no YouTube; sem legenda
  (vale `whisperCmd`, se configurado).
- **Limite conhecido:** carrossel com um item de vídeo fica só com a capa desse item.
- Frontmatter: `instagram_id` (em vez de `youtube_id`), `fonte: "instagram"`, `tipo: "imagens"`
  ou `"video"`, `canal` (nome), `perfil` (`@usuário`); tag `instagram`. Título = primeira linha
  do texto do post (até 70 caracteres) ou `Post de @usuário`. Link: `[Ver no Instagram](…)`.
- Conta no sistema: a importação nasceu do pedido do Sergio em 18/10/2026 ("quero que a
  rotina também consiga importar links do Instagram"); detalhe e ensaio na memória
  `youtube_conhecimento_fila_e_resumo`.

## Formato da nota

```markdown
---
youtube_id: "fBz-MU4fdJw"
title: "Obsidian + Graphify: contexto infinito"
canal: "Canal Teste"
url: "https://www.youtube.com/shorts/fBz-MU4fdJw"
publicado: "2026-08-10"
duracao: "0:58"
legenda: "pt"
frames: 2
importado: "2026-08-26 00:54"
tags:
  - youtube
---

# Obsidian + Graphify: contexto infinito

[Assistir no YouTube](https://www.youtube.com/shorts/fBz-MU4fdJw) · Canal Teste

## Descrição
…

## Transcrição

**[0:00]** o segredo aqui é o grafo que o agente consulta

**[0:38]** e isso corta o custo de token

## Frames

**[0:00]**
![[_frames/fBz-MU4fdJw/fBz-MU4fdJw-000-00000.jpg]]

**[0:15]**
![[_frames/fBz-MU4fdJw/fBz-MU4fdJw-001-00015.jpg]]
```

- `frames` no frontmatter é a **contagem de imagens embutidas** na seção Frames — sai em
  toda nota, `0` quando os frames estão desligados ou o vídeo não rendeu nenhum.
- Cada arquivo de frame se chama `<id>-NNN-SSSSS.jpg`: `NNN` é o índice do frame mantido
  (000, 001, …) e `SSSSS` o segundo do vídeo, com zeros à esquerda. O índice garante nome
  único mesmo quando dois frames caem no mesmo segundo. Caminho absoluto:
  `<vault>/YouTube/_frames/<id>/<id>-NNN-SSSSS.jpg`.

## Instalação (no Mac)

```bash
bash install.sh
```

O instalador: verifica Python 3 e instala o `yt-dlp` se preciso → pergunta vault, pasta,
idiomas, navegador para cookies (vídeo com restrição), comando de transcrição opcional e
intervalo dos frames → instala em `~/.yt-obsidian-sync/` → cria a nota de fila → registra o
agente launchd (`com.hamsa.yt-sync`, de hora em hora no minuto 20) → roda o primeiro sync na hora.

### Sem terminal (rotina, automatismo) e sem carregar o agente

São duas coisas separadas, cada uma com a sua variável:

- **`YT_SYNC_SKIP_LAUNCHD=1`** — o plist é gravado normalmente e o primeiro sync roda, mas o
  agente **não** é carregado (para quem prefere carregar à mão, ou para um automatismo que não
  pode chamar o `launchctl`). O instalador imprime o comando para o dono da máquina rodar depois.
- **As seis perguntas** aceitam resposta por variável de ambiente. Variável definida (mesmo
  vazia) = resposta pronta, a pergunta não aparece; vazia vale o padrão, igual a apertar Enter.
  `YT_SYNC_NONINTERACTIVE=1` responde o padrão a toda pergunta que não tiver variável. Sem
  terminal e sem essas variáveis, o instalador **para com erro claro na primeira pergunta** —
  não fica esperando resposta nem morre em silêncio (sem esse tratamento, `read` com a entrada
  fechada devolve 1 e o `set -e` encerrava o script sem mensagem, antes de gravar qualquer coisa).

| Variável | Pergunta | Padrão |
|---|---|---|
| `YT_SYNC_VAULT` | vault do Obsidian | `~/SERVER/BASE_CONHECIMENTO` (ou `~/SERVER`, se o `.obsidian` estiver lá) |
| `YT_SYNC_SUBDIR` | pasta das notas dentro do vault | `YouTube` |
| `YT_SYNC_LANGS` | idiomas de legenda, em ordem | `pt,en` |
| `YT_SYNC_COOKIES` | navegador dos cookies (`safari`/`chrome`/`firefox`) | vazio = nenhum |
| `YT_SYNC_WHISPER` | comando de transcrição local | vazio = nenhum |
| `YT_SYNC_FRAMES` | intervalo mínimo dos frames, em segundos (`0` = desligado); só dígitos | `0` |

Exemplo — instalação inteira sem pergunta nenhuma, frames ligados, agente por carregar:

```bash
YT_SYNC_SKIP_LAUNCHD=1 YT_SYNC_NONINTERACTIVE=1 YT_SYNC_FRAMES=10 bash install.sh
```

Depois, o dono da máquina carrega o agente:

```bash
launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/com.hamsa.yt-sync.plist"
```

Já carregado com este mesmo plist e quer rodar agora: `launchctl kickstart -k gui/$(id -u)/com.hamsa.yt-sync`.
O plist mudou (reinstalação)? O `kickstart` não relê o arquivo: descarregue com
`launchctl bootout gui/$(id -u)/com.hamsa.yt-sync` e rode o `bootstrap` de novo.

## Operação

| Ação | Comando |
|---|---|
| Importar um vídeo agora | `~/.yt-obsidian-sync/yt-sync.sh <url>` |
| Processar a fila agora | `~/.yt-obsidian-sync/yt-sync.sh` |
| Ver log | `tail -f ~/Library/Logs/yt-sync.log` |
| Mudar pasta/idiomas/Whisper | editar `~/.yt-obsidian-sync/config.json` |
| Atualizar o yt-dlp | `brew upgrade yt-dlp` |
| Desinstalar | `launchctl bootout gui/$(id -u)/com.hamsa.yt-sync; rm -rf ~/Library/LaunchAgents/com.hamsa.yt-sync.plist ~/.yt-obsidian-sync` (o `;` no lugar de `&&` faz o `rm` rodar mesmo que o agente nunca tenha sido carregado) |

## Config (`~/.yt-obsidian-sync/config.json`)

| Chave | O que faz |
|---|---|
| `vaultDir` / `subdir` | onde as notas nascem (padrão `YouTube/`) |
| `queueFile` | nota de fila, relativa ao vault (padrão `YouTube/_fila.md`) |
| `subLangs` | idiomas preferidos, em ordem — valem para a legenda **manual** e para a tradução automática; a automática vem sempre no idioma original do vídeo (`ytdlpSubLangs`, das configs antigas, ainda é lido) |
| `ytdlpBin` | caminho absoluto do `yt-dlp` (o instalador grava o que achou, ex. `/opt/homebrew/bin/yt-dlp`) — é o que ajustar se o `yt-dlp` mudar de lugar |
| `cookiesFromBrowser` | `safari`/`chrome`/`firefox` — só para vídeo privado ou com restrição de idade |
| `whisperCmd` | transcritor local para vídeo sem legenda (ver contrato abaixo) |
| `framesEvery` | liga os frames (`0` desliga, padrão) e define o intervalo **mínimo** do fallback — em vídeo longo ele cresce para `framesMax` frames se espalharem por toda a duração. Precisa de `ffmpeg` |
| `framesMode` | `scene` (padrão) ou `interval` |
| `sceneThreshold` | sensibilidade da detecção de cena (0.3 padrão; menor = mais frames) |
| `sceneMinFrames` | abaixo disso, cai para intervalo fixo (3 padrão) |
| `frameMinGap` | descarta frame a menos de N segundos do anterior (1 padrão; o instalador não grava esta chave — acrescente à mão se quiser outro valor) |
| `framesMax` | teto de frames por vídeo (padrão 60) — evita nota gigante em vídeo longo |
| `framesMaxHeight` | altura máxima do frame e do download (padrão 720) |
| `slidesMaxSize` | maior lado, em px, de cada slide de post do Instagram (padrão 1440; o instalador não grava esta chave) |
| `extraTags` | tags extras no frontmatter de toda nota |

### Vídeo sem legenda

Se `whisperCmd` estiver configurado, o sync baixa o áudio em MP3 e chama:

```
<whisperCmd> <arquivo.mp3> <pasta-de-trabalho>
```

O comando deve deixar um `.srt` ou `.vtt` na pasta de trabalho — o resto do pipeline segue
igual. Serve para `whisper.cpp`, `faster-whisper` ou qualquer wrapper seu. Sem `whisperCmd`,
a nota nasce só com metadados e descrição, marcada como `legenda: "nenhuma"`.
O valor é separado por espaços e executado **direto, sem shell**: aspas, `$VAR` e `~` ficam
literais — use caminhos absolutos ou aponte para um script seu.

### Frames — quando ligar

Para vídeo **falado** (entrevista, aula), a transcrição basta: deixe `framesEvery: 0`.
Ligue para conteúdo em que a **tela é o conteúdo** — screencast, demo de ferramenta,
slide, diagrama.

No modo `scene` (padrão) a quantidade de frames acompanha o conteúdo, não a duração: um
vídeo de 40s com 4 slides rende 4 imagens; uma aula de 1h com 30 trocas de tela rende 30.
`framesMax` (60) é o teto. Uma mesma transição às vezes dispara dois frames seguidos —
`frameMinGap` colapsa isso.

Se a detecção estiver pegando de menos, baixe `sceneThreshold` (0.2, 0.15); se estiver
pegando ruído de câmera tremida, suba (0.4, 0.5).

O vídeo é apagado assim que os frames saem — o que fica no vault são só as imagens.

## Notas técnicas

- Download: [yt-dlp](https://github.com/yt-dlp/yt-dlp) com `--skip-download` — por padrão só
  o `.info.json` e a legenda saem da rede. São duas chamadas: a primeira traz os metadados, a
  segunda pede a legenda escolhida a partir deles (com `--load-info-json`, sem bater de novo
  na página do vídeo). O áudio só é baixado com `whisperCmd` ligado, e
  o vídeo só com `framesEvery` > 0; nos dois casos o arquivo é apagado depois.
- Frames (modo `scene`): `ffmpeg -vf "select='eq(n,0)+gt(scene,T)',scale,showinfo" -fps_mode vfr`,
  com as marcas de tempo lidas do `pts_time` que o `showinfo` emite. O `-fps_mode` existe do
  ffmpeg 5.1 em diante; o antigo `-vsync` foi **removido no ffmpeg 9** ("Unrecognized option
  'vsync'") e derrubava a detecção de cena em silêncio — o script usa `-fps_mode` se a ajuda
  do `ffmpeg -h full` instalado a cita, senão `-vsync`. Abordagem tomada de
  [bradautomates/claude-video](https://github.com/bradautomates/claude-video) (MIT), que
  resolve o mesmo problema numa skill sob demanda.
- Frames (modo `interval`): `ffmpeg -vf "fps=1/N,scale"`. Nos dois, `framesMax` é o teto.
- Agendamento: `StartCalendarInterval` com **só a chave `Minute`** (20), e não `StartInterval`.
  Neste Mac os agentes por intervalo pararam de disparar de 02 a 06/09/2026, enquanto os por
  calendário sobreviveram. E só `Minute`, sem `Hour`: quando o Mac troca de fuso, um agente
  com `Hour` continua disparando no fuso antigo; o que só tem `Minute` é imune. `RunAtLoad`
  fica em `false` porque o próprio instalador já roda o primeiro sync.
- Aceita todas as formas de URL: `youtube.com/watch?v=`, `youtu.be/`, `/shorts/`,
  `/embed/`, `/live/`. O ID de 11 caracteres cru só vale como argumento na linha de comando
  (`yt-sync.sh <id>`); na fila, a linha precisa ser uma URL do youtube.com ou youtu.be.
- A fila é uma nota comum do Obsidian: dá para colar URL do celular pelo app e o Mac
  processa sozinho na hora seguinte.
- Transcrição de terceiros é conteúdo de terceiros: use para estudo e referência, com o
  link para o original sempre na nota (o frontmatter guarda `url`).
