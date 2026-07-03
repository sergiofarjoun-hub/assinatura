# PWA assets — ícones na Home para os apps Hamsa

Artefatos **prontos para deploy** que dão identidade PWA (ícone standalone na home
do Android, sem barra do navegador) aos apps Hamsa. Produzidos a partir do símbolo
**2026** `hamsa_simbolo_2026.png` (hamsa dourado 3D, fundo transparente).

> ✅ **PROJETO CONCLUÍDO em 2026-07-03.** Os 6 apps (Command Center, Renovações,
> Claims, Sales Pipeline, Multi Cálculo, Multi Apólices) estão instaláveis como
> PWA no Android, com o ícone 2026, servidos em HTTPS pelo NAS `hamsa-usa` via
> `tailscale serve`. O passo-a-passo executado, o mapa de portas e os scripts
> estão em [`DEPLOY.md`](DEPLOY.md) e [`nas/`](nas/).
>
> Nota: os `manifests/*.webmanifest` deste repo foram o plano inicial; no deploy
> real, 4 apps já tinham manifest próprio (só trocamos os ícones) e Renovações/
> Claims ganharam `manifest.json` gerado pelos scripts em `nas/`.

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

## Checklist final — tudo concluído ✅

- [x] **Fase 1 — Descoberta:** cada app é um container Docker numa porta própria
      no NAS `hamsa-usa` (100.94.13.31). Cenário B.
- [x] **Pré-req tailnet:** HTTPS Certificates + MagicDNS habilitados.
- [x] **Fase 2 — HTTPS:** `tailscale serve --bg --https=<porta>` por app
      (1 origem HTTPS por app, na raiz — sem risco de subpath). Persiste após reboot.
- [x] **Fase A:** ícones 2026 nos 3 apps que já tinham PWA (CC, MC, MA).
- [x] **Fase B1:** ícones do CRM/Pipeline em `static/img`.
- [x] **Fase B2:** manifest + rota estática + `<head>` em Renovações e Claims
      (Claims com rebuild do container). Sintaxe validada antes de cada restart.
- [x] **Verificação:** `/`, `/manifest.json` e `/icon-192.png` → HTTP 200 nos 6.
- [x] **Backups:** todo arquivo alterado tem `.bak.<timestamp>` ao lado.
- [ ] **Android:** instalar os 6 pelo Chrome (⋮ → Instalar app) — endereços em
      [`DEPLOY.md`](DEPLOY.md).
