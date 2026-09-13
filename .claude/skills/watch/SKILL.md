---
name: watch
description: Assiste a um vídeo por você — YouTube (inclusive Shorts), Vimeo, X, Instagram, qualquer site que o yt-dlp suporte, ou arquivo local — e trabalha o conteúdo inteiro. Baixa a legenda e a transforma em transcrição limpa com marcas de tempo, fatia o vídeo em frames por mudança de cena e lê cada frame como imagem, para poder responder sobre o que foi dito E o que apareceu na tela. Use sempre que o usuário colar um link de vídeo (youtube.com, youtu.be, /shorts/, vimeo.com…) ou mencionar um arquivo .mp4/.mov/.webm e quiser saber o que tem nele, um resumo, o passo a passo mostrado, extrair o código/comandos de um screencast, comparar com algo do repo, ou "trabalhar o conteúdo" — mesmo que só mande o link sem dizer nada. Também para "/watch <url>".
---

# /watch — assistir vídeo

Um modelo não processa vídeo, mas lê texto e imagens. Esta skill converte o vídeo nessas
duas coisas: **transcrição** (a fala) e **frames por mudança de cena** (a tela). Juntas,
elas costumam cobrir o conteúdo inteiro — inclusive de screencast, onde o que importa
está na tela e não na fala.

## Passo a passo

1. **Garantir as ferramentas** (uma vez por ambiente; é idempotente e rápido quando já tem tudo):
   ```bash
   bash .claude/skills/watch/scripts/setup.sh
   ```
   Se falhar por rede (`403`, `Tunnel connection failed`), o ambiente não alcança o
   PyPI ou o YouTube — veja "Quando a rede bloqueia" abaixo antes de insistir.

2. **Preparar o vídeo**:
   ```bash
   python3 .claude/skills/watch/scripts/watch.py "<url ou arquivo>"
   ```
   Imprime o caminho de um `manifest.md`. Opções úteis:
   - `--no-frames` — só transcrição (entrevista, podcast, aula falada): mais rápido, não baixa o vídeo.
   - `--scene 0.2` — mais frames (screencast com transições sutis); `--scene 0.5` — menos (câmera tremida).
   - `--every 5` — intervalo do fallback quando o vídeo é de plano único.
   - `--cookies-from-browser safari` — vídeo privado ou com restrição de idade (só no Mac).

3. **Ler, nesta ordem**: o `manifest.md` (metadados + lista), depois `transcript.md`,
   depois **cada frame** listado, com a ferramenta Read. Não pule frames: um Short de
   60s rende meia dúzia; uma aula de 1h bate no teto de 60. Se forem muitos, leia todos
   mesmo assim — o custo de perder o slide que respondia a pergunta é maior.

4. **Responder à pergunta do usuário**, não descrever o processo. Cite marcas de tempo
   (`[1:23]`) quando apontar algo específico, para ele poder conferir no vídeo. Se a
   pergunta era vaga ("o que tem aqui?"), entregue: do que se trata em uma frase, os
   pontos principais com tempo, e o que apareceu na tela que a fala não cobre (comandos,
   nomes de ferramentas, URLs, código — transcreva-os dos frames).

## O que fazer com o conteúdo

O usuário raramente quer só um resumo. Padrões frequentes:

- **Screencast de ferramenta/setup** → extrair os comandos e a sequência exata que
  apareceram na tela; conferir se batem com o que a fala descreve (às vezes diferem).
- **"Como isso se aplica ao que já temos?"** → cruzar com o repo antes de responder
  (aqui: `ARQUITETURA.md`, os módulos `*-obsidian-sync/`, `manus/`).
- **Virar nota do vault** → o módulo `youtube-obsidian-sync/` é o caminho desassistido
  (fila + launchd + nota com transcrição e frames). Esta skill é o sob demanda.

## Limites — dizer em vez de fingir

- **Sem legenda** → `transcript.md` avisa. Não há transcrição de terceiros por padrão:
  áudio não sai da máquina. Diga isso ao usuário e trabalhe com os frames; ofereça
  Whisper local (no Mac: `mlx-whisper`/`whisper.cpp`) se ele quiser a fala.
- **Legenda automática** tem erros de reconhecimento, principalmente em nome próprio e
  termo técnico. Quando um termo importar, confira contra os frames antes de afirmar.
- **Frames são amostras**: entre um e outro pode ter acontecido algo. Se a resposta
  depende de um momento não coberto, rode de novo com `--scene` menor ou `--every` menor.

## Quando a rede bloqueia

No container cloud do Claude Code, o nível de rede **Trusted** não inclui YouTube: o
`yt-dlp` morre com `403` no proxy. Não é falha da skill nem tem contorno daqui. O ambiente
precisa estar em **Custom** com estes domínios liberados (e "include default list" marcado
para o pip continuar funcionando):

```
*.youtube.com
youtu.be
*.googlevideo.com
*.ytimg.com
```

Isso se ajusta em claude.ai/code → ícone de nuvem acima da caixa de mensagem → engrenagem
do ambiente → Network access. Vale para sessões novas. Enquanto isso, o usuário pode rodar
os mesmos dois comandos no Mac e anexar os frames + `transcript.md` no chat.

## Privacidade

Por padrão só metadados e legenda saem da rede; o vídeo é baixado apenas para extrair
frames e apagado em seguida. Nada é enviado a serviço de terceiros. Para gravação com
conteúdo de cliente, mantenha assim — não adicione transcrição via API.
