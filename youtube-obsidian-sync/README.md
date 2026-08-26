# YouTube → Obsidian Sync

Transforma vídeos do YouTube em notas Markdown no vault **BASE_CONHECIMENTO**: você cola
a URL numa nota de fila, e de hora em hora o sync baixa metadados + legenda e cria a nota
com a **transcrição em texto** e, opcionalmente, **frames do vídeo** em `YouTube/`. Nada de
assistir de novo para achar aquele trecho — e o conteúdo passa a estar disponível para
busca, para links do Obsidian e para o Claude ler.

Os frames são o que permite a um agente **ver** o vídeo: um modelo não processa vídeo, mas
lê imagens. Fatiado em imagens com marca de tempo, o conteúdo visual (tela de código,
slide, diagrama) entra na nota junto com a fala.

## Arquitetura

```
Você cola a URL em <vault>/YouTube/_fila.md
   └─ Mac, de hora em hora (launchd): yt-sync.sh
        ├─ yt-dlp: metadados (.info.json) + legenda (.vtt/.srt), sem baixar o vídeo
        ├─ [opcional] sem legenda → baixa o áudio e chama seu transcritor local (Whisper)
        ├─ [opcional] frames → baixa o vídeo, ffmpeg fatia em JPEG, descarta o vídeo
        └─ yt2vault.py: → <vault>/YouTube/<data> - <título> (<id>).md
             └─ marca a linha da fila como feita, apontando para a nota
```

- **Idempotente**: cada vídeo vira uma nota só. Estado em
  `<vault>/YouTube/.yt-sync-state.json` (oculto no Obsidian); ID já importado é pulado,
  mesmo que a URL apareça de novo na fila.
- **Legenda limpa**: as legendas automáticas do YouTube são "rolantes" (cada trecho repete
  o final do anterior). O parser desfaz isso, remove as marcações inline e `[Música]`, e
  agrupa em parágrafos com marca de tempo a cada ~30s.
- **Preferência de idioma**: legenda manual antes da automática, `pt` antes de `en`
  (configurável).
- **Mount do NAS fora?** Sai em silêncio e tenta na hora seguinte. Escrita é atômica
  (tmp + rename) — nada de nota pela metade.
- **Frames**: com `framesEvery` > 0, o vídeo é baixado, fatiado em JPEG (1 a cada N
  segundos, altura limitada) e **apagado em seguida** — só as imagens ficam, em
  `<vault>/YouTube/_frames/<id>/`, embutidas na nota com a marca de tempo.
- **Lock** em `~/.yt-obsidian-sync/sync.lock` impede execuções sobrepostas (stale após 30min).

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
![[_frames/fBz-MU4fdJw/fBz-MU4fdJw-00000.jpg]]

**[0:15]**
![[_frames/fBz-MU4fdJw/fBz-MU4fdJw-00015.jpg]]
```

## Instalação (no Mac)

```bash
bash install.sh
```

O instalador: verifica Python 3 e instala o `yt-dlp` se preciso → pergunta vault, pasta,
idiomas, navegador para cookies (vídeo com restrição) e comando de transcrição opcional →
instala em `~/.yt-obsidian-sync/` → cria a nota de fila → registra o agente launchd
(`com.hamsa.yt-sync`, 1h em 1h + ao logar) → roda o primeiro sync na hora.

## Operação

| Ação | Comando |
|---|---|
| Importar um vídeo agora | `~/.yt-obsidian-sync/yt-sync.sh <url>` |
| Processar a fila agora | `~/.yt-obsidian-sync/yt-sync.sh` |
| Ver log | `tail -f ~/Library/Logs/yt-sync.log` |
| Mudar pasta/idiomas/Whisper | editar `~/.yt-obsidian-sync/config.json` |
| Atualizar o yt-dlp | `brew upgrade yt-dlp` |
| Desinstalar | `launchctl bootout gui/$(id -u)/com.hamsa.yt-sync && rm -rf ~/Library/LaunchAgents/com.hamsa.yt-sync.plist ~/.yt-obsidian-sync` |

## Config (`~/.yt-obsidian-sync/config.json`)

| Chave | O que faz |
|---|---|
| `vaultDir` / `subdir` | onde as notas nascem (padrão `YouTube/`) |
| `queueFile` | nota de fila, relativa ao vault (padrão `YouTube/_fila.md`) |
| `subLangs` / `ytdlpSubLangs` | idiomas preferidos, em ordem |
| `cookiesFromBrowser` | `safari`/`chrome`/`firefox` — só para vídeo privado ou com restrição de idade |
| `whisperCmd` | transcritor local para vídeo sem legenda (ver contrato abaixo) |
| `framesEvery` | 1 frame a cada N segundos; `0` desliga (padrão). Precisa de `ffmpeg` |
| `framesMax` | teto de frames por vídeo (padrão 60) — evita nota gigante em vídeo longo |
| `framesMaxHeight` | altura máxima do frame e do download (padrão 720) |
| `extraTags` | tags extras no frontmatter de toda nota |

### Vídeo sem legenda

Se `whisperCmd` estiver configurado, o sync baixa o áudio em MP3 e chama:

```
<whisperCmd> <arquivo.mp3> <pasta-de-trabalho>
```

O comando deve deixar um `.srt` ou `.vtt` na pasta de trabalho — o resto do pipeline segue
igual. Serve para `whisper.cpp`, `faster-whisper` ou qualquer wrapper seu. Sem `whisperCmd`,
a nota nasce só com metadados e descrição, marcada como `legenda: "nenhuma"`.

### Frames — quando ligar

Para vídeo **falado** (entrevista, aula), a transcrição basta: deixe `framesEvery: 0`.
Ligue para conteúdo em que a **tela é o conteúdo** — screencast, demo de ferramenta,
slide, diagrama. Um Short de 60s com `framesEvery: 10` rende 6 imagens; uma aula de 1h
com `framesEvery: 30` bate no teto de `framesMax` (60 imagens).

O vídeo é apagado assim que os frames saem — o que fica no vault são só as imagens.

## Notas técnicas

- Download: [yt-dlp](https://github.com/yt-dlp/yt-dlp) com `--skip-download` — por padrão só
  o `.info.json` e a legenda saem da rede. O áudio só é baixado com `whisperCmd` ligado, e
  o vídeo só com `framesEvery` > 0; nos dois casos o arquivo é apagado depois.
- Frames: `ffmpeg -vf "fps=1/N,scale=-2:min(H,ih)" -q:v 4`, limitado por `framesMax`.
- Aceita todas as formas de URL: `youtube.com/watch?v=`, `youtu.be/`, `/shorts/`,
  `/embed/`, `/live/` — ou o ID de 11 caracteres cru.
- A fila é uma nota comum do Obsidian: dá para colar URL do celular pelo app e o Mac
  processa sozinho na hora seguinte.
- Transcrição de terceiros é conteúdo de terceiros: use para estudo e referência, com o
  link para o original sempre na nota (o frontmatter guarda `url`).
