# Diagnóstico — site da Katy (`http://192.168.1.147:8082`)

> **Importante:** `192.168.1.147` é um endereço de **rede local**. Ele só é
> acessível de dentro da sua rede (LAN). Não dá para diagnosticá-lo a partir
> da nuvem — estes scripts precisam ser executados **na sua rede local**,
> de preferência na própria máquina servidora `192.168.1.147`.

## Qual script usar

| Sistema da máquina | Script |
|--------------------|--------|
| Linux / macOS      | `diagnostico.sh` |
| Windows            | `diagnostico.bat` |

## Como rodar

### Linux / macOS
```bash
chmod +x diagnostico.sh
./diagnostico.sh
# ou informando IP e porta:
./diagnostico.sh 192.168.1.147 8082
```

### Windows
- Dê duplo clique em `diagnostico.bat`, **ou** no Prompt de Comando:
```bat
diagnostico.bat
diagnostico.bat 192.168.1.147 8082
```

## O que os scripts checam

1. **Ping** — a máquina responde na rede?
2. **Porta 8082** — está aberta/escutando?
3. **HTTP** — o site devolve alguma resposta (e qual código)?
4. **(no servidor) Porta local** — qual processo está escutando na 8082.
5. **(no servidor) Docker** — containers ativos e os que pararam (causa comum de queda).
6. **(no servidor) Disco/Memória** — recursos esgotados também derrubam serviços.

## Depois de rodar

Copie **toda** a saída e envie de volta. Com base nela conseguimos apontar a
causa (serviço parado, container caído, porta fechada, máquina offline, disco
cheio, etc.) e o próximo passo para religar o site.
