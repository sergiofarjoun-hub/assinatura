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

> Os caminhos acima são **provisórios** — vêm da tabela do runbook e **precisam
> ser confirmados pela Fase 1** (descoberta da arquitetura real no NAS). Se os 6
> apps forem só estados internos de um único SPA na raiz (Cenário C), scopes
> separados **não** vão funcionar sem reorganizar as rotas; nesse caso o caminho
> honesto é 1 PWA (Command Center) + atalhos simples. **Decidir só depois de mapear.**

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
