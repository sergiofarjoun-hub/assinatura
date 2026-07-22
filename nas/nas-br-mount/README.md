# Auto-mount NAS BR no Mac — `Server` e `Pessoal` sempre montados

Mantém os dois volumes do NAS BR permanentemente disponíveis em
`/Volumes/Server` e `/Volumes/Pessoal`. Um LaunchAgent roda um watchdog a cada
60 segundos: se o volume não estiver montado (rede caiu, Mac acordou do sleep,
NAS reiniciou), remonta automaticamente usando a credencial salva no Keychain
— nenhuma senha fica em arquivo.

## Arquivos

| Arquivo | Papel |
|---|---|
| `mount-nas-br.sh` | Watchdog: confere e remonta os shares |
| `com.hamsa.nasbr.mount.plist` | LaunchAgent (login + a cada 60s) |
| `install.sh` | Instalação em um comando |

## Instalação (no Mac, uma vez)

1. **Endereço do NAS BR já preenchido**: `hamsa-br` (Tailscale,
   `100.70.191.55`). Se os shares tiverem nomes diferentes de
   `Server`/`Pessoal`, ajustar o array `SHARES` em `mount-nas-br.sh`.
2. **Salvar a credencial no Keychain**: no Finder, `Cmd+K` →
   `smb://hamsa-br/Server`, login com o usuário do NAS marcando **"Guardar
   senha nas Chaves"**. Repetir para `Pessoal`.
3. Rodar:
   ```bash
   bash install.sh
   ```

Pronto — os volumes montam no login e remontam sozinhos em até 1 minuto após
qualquer queda.

## Verificação / operação

```bash
mount -t smbfs                          # deve listar os 2 volumes
tail -f ~/Library/Logs/nas-br-mount.log # atividade do watchdog
launchctl print "gui/$(id -u)/com.hamsa.nasbr.mount" | head  # agente ativo?
```

Desinstalar: `launchctl bootout gui/$(id -u)/com.hamsa.nasbr.mount` e apagar
o plist em `~/Library/LaunchAgents` e o script em `~/Library/Scripts`.

## Notas

- Acesso remoto (fora da rede do NAS BR) exige o Tailscale ativo no Mac e no
  NAS — por isso o `NAS_HOST` deve ser o hostname/IP da tailnet, nunca o IP
  LAN ou o IP externo dinâmico.
- O script sai silenciosamente se o NAS estiver inalcançável (não trava o
  Finder) e volta a tentar no ciclo seguinte.
- Mesmo padrão pode ser replicado para o `hamsa-usa` acrescentando os shares
  dele ao array `SHARES` (ex.: `Sistema`), desde que a credencial esteja no
  Keychain.
