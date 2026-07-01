# Deploy — ícones PWA nos apps Hamsa (Tailscale HTTPS)

Arquitetura real (Fase 1): **cada app é um serviço separado, na sua própria
porta**, rodando em `127.0.0.1` da máquina host.

## Onde os apps rodam
Hoje quem serve é o **MacBook** (`sergios-macbook-air.taild4370d.ts.net`),
proxyando pros apps locais. Isso significa que **o ícone no celular só funciona
com o Mac ligado/acordado**. Para funcionar sempre, rodar o `tailscale serve`
na máquina **sempre-ligada** (NAS) — os comandos são os mesmos, muda só o host.

Neste doc, `<HOST>` = o nome Tailscale da máquina host:
- Mac → `sergios-macbook-air.taild4370d.ts.net`
- NAS → (o nome do nó do NAS, ex. `hamsa-usa.taild4370d.ts.net`)

## Mapa de portas

| App            | porta local | porta HTTPS sugerida |
|----------------|-------------|----------------------|
| Command Center | 4000        | 443 (raiz)           |
| Renovações     | 3001        | 8443                 |
| Claims         | 9292        | 10000                |
| Multi Cálculo  | 9191        | 10001                |
| Multi Apólices | 8081        | 10002                |
| Sales Pipeline | **?**       | 10003                |

> **Por que uma porta por app (e não paths):** cada porta HTTPS é uma **origem**
> própria, servida na **raiz** `/` — o app roda igualzinho ao localhost, sem
> risco de quebrar assets como aconteceria num subpath (`/claims`). Cada app vira
> um PWA limpo e independente. (Requer que o Tailscale aceite portas arbitrárias —
> confirmado neste tailnet.)

## Por que HTTPS
O Chrome só instala PWA em **contexto seguro** (`https://` ou `localhost`). Os
atalhos `http://100.x…:PORTA` são HTTP puro → não instalam. O `tailscale serve`
resolve com certificado automático.

## Pré-requisito (uma vez)
Admin console do Tailscale → Settings → Features: **HTTPS Certificates** + **MagicDNS**.

## Passo 1 — Limpar a config atual e servir 1 porta por app
Rodar na máquina host (Mac hoje; NAS se for pra always-on):

```bash
sudo tailscale serve reset                                        # limpa o estado bagunçado
sudo tailscale serve --bg --https=443   http://127.0.0.1:4000     # Command Center
sudo tailscale serve --bg --https=8443  http://127.0.0.1:3001     # Renovações
sudo tailscale serve --bg --https=10000 http://127.0.0.1:9292     # Claims
sudo tailscale serve --bg --https=10001 http://127.0.0.1:9191     # Multi Cálculo
sudo tailscale serve --bg --https=10002 http://127.0.0.1:8081     # Multi Apólices
# sudo tailscale serve --bg --https=10003 http://127.0.0.1:PORTA  # Sales Pipeline
sudo tailscale serve status
```
Endereços resultantes: `https://<HOST>/` (CC), `https://<HOST>:8443/` (Renov.),
`https://<HOST>:10000/` (Claims), etc.

## Passo 2 — Manifest + ícones em cada app
Cada app precisa servir o manifest + ícones na **própria raiz**. Para cada app:

1. Copie a pasta `icons/` para o diretório servido do app (`public/` ou raiz do build).
2. Copie o manifest do app renomeando para `manifest.webmanifest`
   (ex.: `manifests/claims.webmanifest` → `<app-claims>/public/manifest.webmanifest`).
3. Cole no `<head>` do `index.html` do app o bloco de `snippets/head-snippet.html`.
4. Rebuild/redeploy se o app usa build (Vite/Next/etc.).

Os manifests usam caminhos **relativos** (`./icons/…`, `start_url`/`scope` = `./`),
então funcionam na raiz de qualquer porta sem edição.

> **Backup antes** de editar cada `index.html`. **1 falha → PARAR**, re-validar. Não iterar no NAS.

## Passo 3 — Verificar
```bash
curl -skI https://<HOST>:10000/manifest.webmanifest | head -5   # Claims → 200 + application/manifest+json
```

## Passo 4 — Instalar no Android
Tailscale ligado no celular → abrir cada endereço (`https://<HOST>/`,
`https://<HOST>:8443/`, …) no Chrome → menu ⋮ → **Instalar app**. Um ícone
standalone por app na home.
