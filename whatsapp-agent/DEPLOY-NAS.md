# Deploy do Assistente Hamsa no NAS (Docker)

O bot roda no NAS `hamsa-usa` (sempre ligado), gravando os documentos direto na
pasta de clientes do NAS. O Mac é espelho bidirecional, então tudo sincroniza.

> ⚠️ **Rode o bot em UM lugar só.** Antes de subir no NAS, PARE o bot no Mac
> (Ctrl+C, ou `bash macos/desinstalar-servico.sh` se instalou o serviço). Rodar
> a mesma sessão no Mac e no NAS ao mesmo tempo derruba a conexão.

## 1. Entrar no NAS por SSH (do Terminal do Mac)
```bash
ssh Hamsa_Group@100.94.13.31       # use o seu login real do NAS
```

## 2. Descobrir o caminho da pasta de clientes NO NAS
```bash
find /volume1 -maxdepth 5 -type d -iname CLIENTES 2>/dev/null
```
Anote o caminho retornado (ex.: `/volume1/SERVER/CLIENTES`). Confirme que dentro
dele há `SAUDE/VUMI/...`:
```bash
ls "<caminho>/SAUDE" | head
```

## 3. Levar o código para o NAS
```bash
# escolha uma pasta de trabalho no NAS, ex.:
cd /volume1/docker 2>/dev/null || cd ~
git clone https://github.com/sergiofarjoun-hub/assinatura.git 2>/dev/null || true
cd assinatura && git fetch origin && git checkout claude/ipmi-brokerage-system-gb34lg && git pull
cd whatsapp-agent
```
(Se o `git` pedir login, use o mesmo token do Mac.)

## 4. Criar o `.env` no NAS
```bash
cp .env.example .env
vi .env    # ou nano .env
```
Preencha:
- `ANTHROPIC_API_KEY=` a sua chave.
- `ADMIN_NUMBERS=` seu número (só dígitos com DDI).
- `CLIENTES_DIR=/clientes` (deixe assim — é o caminho DENTRO do container).
- `CLIENTES_HOST_DIR=` o caminho REAL do passo 2 (ex.: `/volume1/SERVER/CLIENTES`).

## 5. Subir o container
```bash
sudo docker compose up -d --build
```

## 6. Parear o WhatsApp (só na primeira vez)
```bash
sudo docker compose logs -f whatsapp-agent
```
Vai aparecer o QR code. No celular: WhatsApp → Configurações → Dispositivos
conectados → Conectar dispositivo → escaneie. Quando aparecer `✅ Conectado`,
saia dos logs com Ctrl+C (o container continua rodando).

## 7. Testar
- Mande "oi" de um contato de teste → deve vir a saudação formal + menu.
- Diga um cliente real + operadora → o bot confirma o cadastro.
- Envie uma foto de nota fiscal → confira em
  `<caminho>/SAUDE/<Operadora>/<Cliente>/reembolsos/`.

## Comandos úteis (no NAS)
```bash
sudo docker compose logs -f whatsapp-agent   # ver logs
sudo docker compose restart whatsapp-agent   # reiniciar
sudo docker compose down                     # parar
sudo docker compose up -d --build            # atualizar após git pull
```
A sessão do WhatsApp e o histórico ficam no volume `./data` (no NAS). Faça backup
dessa pasta; se apagá-la, será preciso escanear o QR de novo.
