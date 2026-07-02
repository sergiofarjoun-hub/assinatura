# Deploy — ícones PWA nos apps Hamsa (NAS `hamsa-usa` via Tailscale)

**Confirmado (Fase 1):** `100.94.13.31` = **`hamsa-usa`** (Synology, linux, sempre
ligado). Os apps já rodam nele — os atalhos `http://100.94.13.31:PORTA` são a
prova. Falta só: (a) HTTPS via `tailscale serve` no NAS, (b) manifest + ícones
em cada app.

## Mapa de portas

| App            | porta do app no NAS | porta HTTPS (serve) | endereço final                                  |
|----------------|---------------------|---------------------|-------------------------------------------------|
| Command Center | 4000                | 443                 | `https://hamsa-usa.taild4370d.ts.net/`          |
| Renovações     | 3001                | 8443                | `https://hamsa-usa.taild4370d.ts.net:8443/`     |
| Claims         | 9292                | 10000               | `https://hamsa-usa.taild4370d.ts.net:10000/`    |
| Multi Cálculo  | 9191                | 10001               | `https://hamsa-usa.taild4370d.ts.net:10001/`    |
| Multi Apólices | 8080                | 10002               | `https://hamsa-usa.taild4370d.ts.net:10002/`    |
| Sales Pipeline | **?** (confirmar)   | 10003               | `https://hamsa-usa.taild4370d.ts.net:10003/`    |

> **Por que 1 porta HTTPS por app:** cada porta é uma **origem** própria → cada
> app vira um PWA independente (nome + ícone próprios), servido na raiz `/`,
> sem risco de quebrar assets como num subpath. Verificado: portas de `serve`
> podem ser quaisquer (a restrição 443/8443/10000 é só do Funnel); e as portas
> HTTPS escolhidas são ≠ das portas dos apps de propósito, pra não interceptar
> os atalhos HTTP atuais, que continuam funcionando.

> **Não precisa de service worker:** desde o Chrome 108, manifest + HTTPS bastam
> pro menu ⋮ → "Instalar app". (O banner automático pode não aparecer — instala
> pelo menu.)

## Pré-requisito (uma vez, no admin console do Tailscale)
Settings → Features: **HTTPS Certificates** + **MagicDNS** habilitados.

## Particularidades do Synology (verificadas)
- O CLI **não está no PATH**: use o caminho completo
  `/var/packages/Tailscale/target/bin/tailscale`, sempre com `sudo`.
- `serve --bg` exige **Tailscale ≥ 1.52**. O Package Center atrasa (~trimestral);
  se a versão for antiga, instalar o SPK atual de <https://pkgs.tailscale.com/stable/#spks>
  (Package Center → Manual Install).
- Config feita com `--bg` **persiste após reboot** do NAS.
- O certificado HTTPS é emitido automaticamente no primeiro acesso (precisa só
  do pré-requisito acima; não depende do fix de TUN).

## Passo 1 — HTTPS no NAS (SSH no `hamsa-usa`) ✅ FEITO em 2026-07-02

Executado como `Hamsa_Group@Hamsa_USA` (Tailscale 1.98.2). `serve status` confirma
os 5 proxies ativos (443→4000, 8443→3001, 10000→9292, 10001→9191, 10002→8080).
Falta só o Sales Pipeline (porta a confirmar). Comandos usados:

```bash
TS=/var/packages/Tailscale/target/bin/tailscale

sudo $TS version        # precisa ser >= 1.52; se for menor, atualizar o SPK antes

sudo $TS serve reset    # limpa qualquer estado antigo
sudo $TS serve --bg --https=443   http://127.0.0.1:4000   # Command Center
sudo $TS serve --bg --https=8443  http://127.0.0.1:3001   # Renovações
sudo $TS serve --bg --https=10000 http://127.0.0.1:9292   # Claims
sudo $TS serve --bg --https=10001 http://127.0.0.1:9191   # Multi Cálculo
sudo $TS serve --bg --https=10002 http://127.0.0.1:8080   # Multi Apólices
# sudo $TS serve --bg --https=10003 http://127.0.0.1:PORTA_PIPELINE  # Sales Pipeline
sudo $TS serve status
```

Testar do Mac: abrir `https://hamsa-usa.taild4370d.ts.net:10000/` → deve abrir o
Claims com cadeado válido (o primeiro acesso pode demorar ~10s emitindo o certificado).

> Se algum app não abrir: o `serve` só alcança `127.0.0.1` do NAS. Se o app
> estiver escutando só no IP externo, teste no NAS:
> `curl -sI http://127.0.0.1:9292 | head -1` — se não responder, o serviço
> precisa escutar também em localhost (ou 0.0.0.0).

## Passo 2 — Manifest + ícones em cada app (no NAS, com backup)

Para cada app, no diretório servido (raiz dos arquivos web / `public/`):

1. **Backup** do `index.html`.
2. Copiar a pasta `icons/` deste repo.
3. Copiar o manifest do app renomeando: `manifests/claims.webmanifest` → `manifest.webmanifest`.
4. Colar no `<head>` do `index.html` o bloco de `snippets/head-snippet.html`.
5. Se o app usa build (Vite/Next), colocar em `public/` e rebuildar.

Os manifests usam caminhos **relativos** (`start_url`/`scope` = `./`,
ícones `./icons/…`) — resolvem contra a raiz de cada porta, sem edição.
**1 falha → PARAR**, re-validar. Não iterar no NAS.

## Passo 3 — Verificar
```bash
curl -skI https://hamsa-usa.taild4370d.ts.net:10000/manifest.webmanifest | head -5
# esperar HTTP 200 (content-type json/manifest)
```

## Passo 4 — Instalar no Android
Tailscale ligado no celular → abrir cada endereço da tabela no Chrome →
menu ⋮ → **Instalar app**. Um ícone standalone por app na home.
