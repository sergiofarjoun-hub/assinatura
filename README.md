# PWA assets — ícones na Home para os apps Hamsa

Artefatos **prontos para deploy** que dão identidade PWA (ícone standalone na home
do Android, sem barra do navegador) aos apps Hamsa. Produzidos a partir do logo
`hamsa_group_insurance.png`.

> ⚠️ **Estes arquivos são a Fase 3 do runbook.** As fases que tocam o NAS/Tailscale
> (Fase 1 — descoberta, Fase 2 — `tailscale serve`, Fase 5 — deploy) **não foram
> executadas aqui** e exigem rodar no Mac com acesso à tailnet + **autorização
> explícita do Sergio**. Veja "O que falta" abaixo.

## O que tem aqui

```
icons/
  hamsa-192.png          # ícone base da marca, 192×192, opaco sobre #0b1424
  hamsa-512.png          # idem, 512×512  (serve como any + maskable + apple-touch)
manifests/
  command-center.webmanifest   scope /
  renovacoes.webmanifest       scope /renovacoes/
  claims.webmanifest           scope /claims/
  pipeline.webmanifest         scope /pipeline/
  multicalculo.webmanifest     scope /multicalculo/
  multiapolices.webmanifest    scope /multiapolices/
snippets/
  head-snippet.html      # o que colar no <head> de cada app
hamsa_group_insurance.png  # logo de origem
```

Os ícones usam **só o símbolo da hamsa** (sem o texto "HAMSA GROUP INSURANCE",
que fica ilegível e seria cortado no recorte circular/maskable do Android),
centralizado com zona de segurança (~70% do canvas) sobre o fundo da marca
`#0b1424`. Por serem opacos servem ao mesmo tempo como `any`, `maskable` e
`apple-touch-icon`.

## Escopos por app (cada um DISTINTO → 6 ícones separados)

| App            | start_url / scope  | manifest                          |
|----------------|--------------------|-----------------------------------|
| Command Center | `/`                | `command-center.webmanifest`      |
| Renovações     | `/renovacoes/`     | `renovacoes.webmanifest`          |
| Claims         | `/claims/`         | `claims.webmanifest`              |
| Sales Pipeline | `/pipeline/`       | `pipeline.webmanifest`            |
| Multi Cálculo  | `/multicalculo/`   | `multicalculo.webmanifest`        |
| Multi Apólices | `/multiapolices/`  | `multiapolices.webmanifest`       |

> Os caminhos acima são **provisórios** — vêm da tabela do runbook e **precisam
> ser confirmados pela Fase 1** (descoberta da arquitetura real no NAS). Se os 6
> apps forem só estados internos de um único SPA na raiz (Cenário C), scopes
> separados **não** vão funcionar sem reorganizar as rotas; nesse caso o caminho
> honesto é 1 PWA (Command Center) + atalhos simples. **Decidir só depois de mapear.**

## Ícones distintos por app (opcional, recomendado)

Hoje os 6 manifests apontam para o mesmo ícone base (`/icons/hamsa-*.png`).
Para dar um ícone próprio a cada app, no **Mac**:

```bash
# exporte o ícone do app (o que aparece no sidebar) e gere os dois tamanhos
sips -z 192 192 command-center.png --out icons/command-center-192.png
sips -z 512 512 command-center.png --out icons/command-center-512.png
```

…e troque os dois `src` no manifest daquele app.

## Validação local (Fase 4 — faça antes do NAS)

`localhost` é contexto seguro, então dá pra validar sem HTTPS:

```bash
# a partir da RAIZ que será servida (onde /icons e /manifests resolvem)
python3 -m http.server 8080
```

No Chrome desktop em `http://localhost:8080`:
1. DevTools (F12) → **Application → Manifest**: name, ícones carregando, sem erros.
2. **Lighthouse → PWA** → "Installable" ✓.
3. Repetir por app.

## O que falta (rodar no Mac, com OK do Sergio)

- [ ] **Fase 1 — Descoberta:** mapear o que escuta na :10000, se é Docker, onde
      está o HTML, e se cada app é path/porta/SPA. Preencher a tabela e escolher
      Cenário A/B/C. **Confirmar os scopes acima.**
- [ ] **Pré-req tailnet:** HTTPS Certificates + MagicDNS habilitados.
- [ ] **Fase 2 — HTTPS:** `tailscale serve --bg http://localhost:10000`
      (ou `--set-path` por serviço, Cenário B). Validar com `curl -sI https://…`.
- [ ] **Fase 4 — Validação local** dos 6 manifests (acima).
- [ ] **Fase 5 — Deploy (1× só, após "pode deploy"):** backup → copiar `icons/`,
      `manifests/` e os `<head>` alterados → verificar
      `curl -sI https://hamsa-usa.taild4370d.ts.net/manifests/command-center.webmanifest`.
      **1 falha → PARAR**, voltar pro Mac.
- [ ] **Android:** abrir cada URL no Chrome (Tailscale conectado) → Install app.
