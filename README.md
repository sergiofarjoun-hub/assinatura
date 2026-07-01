# PWA assets — ícones na Home para os apps Hamsa

Artefatos **prontos para deploy** que dão identidade PWA (ícone standalone na home
do Android, sem barra do navegador) aos apps Hamsa. Produzidos a partir do símbolo
**2026** `hamsa_simbolo_2026.png` (hamsa dourado 3D, fundo transparente).

> ⚠️ **Estes arquivos são a Fase 3 do runbook.** As fases que tocam o NAS/Tailscale
> (Fase 1 — descoberta, Fase 2 — `tailscale serve`, Fase 5 — deploy) **não foram
> executadas aqui** e exigem rodar no Mac com acesso à tailnet + **autorização
> explícita do Sergio**. Veja "O que falta" abaixo.

## O que tem aqui

```
icons/
  hamsa-192.png / hamsa-512.png   # ícone único da marca (navy) usado por todos os apps
manifests/
  command-center.webmanifest   scope /
  renovacoes.webmanifest       scope /renovacoes/
  claims.webmanifest           scope /claims/
  pipeline.webmanifest         scope /pipeline/
  multicalculo.webmanifest     scope /multicalculo/
  multiapolices.webmanifest    scope /multiapolices/
snippets/
  head-snippet.html      # o que colar no <head> de cada app
preview/
  index.html             # página de preview/validação local (abrir /preview/)
hamsa_group_insurance.png  # logo de origem
```

O ícone usa **só o símbolo da hamsa 2026** (dourado 3D, sem texto — o texto some
no tamanho de ícone), centralizado com zona de segurança (~68% do canvas) sobre o
navy da marca `#0b1424`. Por ser opaco serve ao mesmo tempo como `any`, `maskable`
e `apple-touch-icon`.

**Os 6 apps usam o mesmo ícone e o mesmo fundo navy `#0b1424`** (também no
`background_color`/`theme_color` de cada manifest); a distinção na home é pelo
**nome** de cada app.

## Escopos por app (cada um com scope DISTINTO)

| App            | start_url / scope  | manifest                          |
|----------------|--------------------|-----------------------------------|
| Command Center | `/`                | `command-center.webmanifest`      |
| Renovações     | `/renovacoes/`     | `renovacoes.webmanifest`          |
| Claims         | `/claims/`         | `claims.webmanifest`              |
| Sales Pipeline | `/pipeline/`       | `pipeline.webmanifest`            |
| Multi Cálculo  | `/multicalculo/`   | `multicalculo.webmanifest`        |
| Multi Apólices | `/multiapolices/`  | `multiapolices.webmanifest`       |

> **Fase 1 concluída:** cada app é um serviço próprio numa porta separada no NAS
> (Cenário B). Os paths acima são reais, servidos via `tailscale serve`. Os
> manifests usam caminhos **relativos** (`./icons/...`, `start_url`/`scope` = `./`),
> então o mesmo bundle funciona em qualquer path. **Deploy: ver [`DEPLOY.md`](DEPLOY.md).**

## Ícone próprio por app (opcional, no Mac)

Hoje os 6 usam o mesmo ícone da marca. Se um app tiver ícone próprio e você
quiser usá-lo, no **Mac** gere os dois tamanhos e aponte o manifest daquele app:

```bash
sips -z 192 192 renovacoes.png --out icons/renovacoes-192.png
sips -z 512 512 renovacoes.png --out icons/renovacoes-512.png
# depois, em manifests/renovacoes.webmanifest, troque os "src" de
# /icons/hamsa-*.png para /icons/renovacoes-*.png
```

(Se o ícone não for quadrado nem tiver zona de segurança, o `purpose:"maskable"`
pode cortar; nesse caso deixe só `purpose:"any"` naquele manifest.)

## Validação local (Fase 4 — faça antes do NAS)

`localhost` é contexto seguro, então dá pra validar sem HTTPS:

```bash
# a partir da RAIZ do repo (onde /icons e /manifests resolvem)
python3 -m http.server 8080
```

No Chrome desktop:
1. Abra `http://localhost:8080/preview/` — confere os 6 ícones lado a lado.
2. DevTools (F12) → **Application → Manifest**: name, ícones carregando, sem erros.
3. **Lighthouse → PWA** → "Installable" ✓ (rode em cada app no seu scope real).

## O que falta (rodar no NAS/Mac, com OK do Sergio) → ver DEPLOY.md

- [x] **Fase 1 — Descoberta:** feito. Cenário B — cada app numa porta no NAS
      `100.94.13.31` (Command Center 4000, Renovações 3001, Claims 9292,
      Multi Cálculo 9191, Multi Apólices 8080; Sales Pipeline: porta a confirmar).
- [ ] **Pré-req tailnet:** HTTPS Certificates + MagicDNS habilitados.
- [ ] **Passo 0 — Teste de subpath** (DEPLOY.md): 1 comando `tailscale serve` no
      NAS pra decidir se os apps rodam em `/claims` etc. sem ajuste de base path.
- [ ] **Passo 1 — HTTPS pra todos:** `tailscale serve --set-path` por app (DEPLOY.md).
- [ ] **Passo 2 — Deploy (1× só, com backup):** copiar `icons/` + `manifest.webmanifest`
      pra cada app e colar o `<head>`. **1 falha → PARAR.**
- [ ] **Passo 3 — Verificar:** `curl -sI https://hamsa-usa.taild4370d.ts.net/claims/manifest.webmanifest`.
- [ ] **Passo 4 — Android:** abrir cada path no Chrome (Tailscale ligado) → Instalar app.
