# Deploy — ícones PWA nos apps Hamsa (NAS via Tailscale)

Arquitetura real (descoberta na Fase 1): **cada app é um serviço separado, na sua
própria porta**, rodando no NAS (nó Tailscale `100.94.13.31` =
`hamsa-usa.taild4370d.ts.net`, sempre ligado).

## Mapa de portas

| App            | path HTTPS        | porta no NAS |
|----------------|-------------------|--------------|
| Command Center | `/`               | 4000         |
| Renovações     | `/renovacoes/`    | 3001         |
| Claims         | `/claims/`        | 9292         |
| Multi Cálculo  | `/multicalculo/`  | 9191         |
| Multi Apólices | `/multiapolices/` | 8080         |
| Sales Pipeline | `/pipeline/`      | **?** (confirmar) |

## Por que HTTPS (e não os atalhos `http://100.94.13.31:PORTA`)

O Chrome só instala PWA em **contexto seguro** (`https://` ou `localhost`). Os
atalhos atuais são HTTP puro → não instalam. O `tailscale serve` põe um endereço
**HTTPS** (certificado automático) na frente e mapeia cada app num path.

## Pré-requisito (uma vez)
Admin console do Tailscale → Settings → Features: **HTTPS Certificates** + **MagicDNS** ligados.

## Passo 0 — TESTE de subpath (rodar 1 comando, no NAS via SSH)

Servir um app num subpath só funciona se ele usar caminhos **relativos** pros
próprios assets. Testar com o Claims antes de fazer os 6:

```bash
sudo tailscale serve --bg --set-path=/claims http://127.0.0.1:9292
sudo tailscale serve status
```
Abrir no Mac: `https://hamsa-usa.taild4370d.ts.net/claims`
- **Abriu com estilo + dados** → subpath OK, seguir pro Passo 1.
- **Quebrado / sem CSS** → o app usa paths absolutos; precisa configurar um
  "base path" (ex.: Vite `base: '/claims/'`, e rebuild) antes de servir no subpath.

Reverter o teste a qualquer momento: `sudo tailscale serve reset`.

## Passo 1 — HTTPS pra todos (no NAS, após o teste passar)

```bash
sudo tailscale serve --bg --set-path=/            http://127.0.0.1:4000
sudo tailscale serve --bg --set-path=/renovacoes  http://127.0.0.1:3001
sudo tailscale serve --bg --set-path=/claims      http://127.0.0.1:9292
sudo tailscale serve --bg --set-path=/multicalculo http://127.0.0.1:9191
sudo tailscale serve --bg --set-path=/multiapolices http://127.0.0.1:8080
# sudo tailscale serve --bg --set-path=/pipeline http://127.0.0.1:PORTA_PIPELINE
sudo tailscale serve status
```

## Passo 2 — Manifest + ícones em cada app

Os manifests aqui usam caminhos **relativos** (`./icons/...`), então o bundle
funciona em qualquer path sem edição. Para cada app:

1. Copie a pasta `icons/` para o diretório servido do app (ex.: `public/` ou raiz do build).
2. Copie o manifest do app renomeando para `manifest.webmanifest`:
   `manifests/claims.webmanifest` → `<app-claims>/public/manifest.webmanifest`
3. Cole no `<head>` do `index.html` do app o bloco de `snippets/head-snippet.html`.
4. Rebuild/redeploy do app se ele usa build (Vite/Next/etc.).

> **Backup antes** de editar o `index.html` de cada app. **1 falha → PARAR**,
> voltar, re-validar. Não iterar no NAS.

## Passo 3 — Verificar
```bash
curl -sI https://hamsa-usa.taild4370d.ts.net/claims/manifest.webmanifest | head -5
# esperar: 200 + content-type application/manifest+json
```

## Passo 4 — Instalar no Android
Tailscale ligado no celular → abrir cada `https://hamsa-usa.taild4370d.ts.net/<path>`
no Chrome → menu ⋮ → **Instalar app**. Um ícone standalone por app na home.
