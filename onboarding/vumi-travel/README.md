# Manual de onboarding — cliente VUMI® Travel VIP

Manual do segurado (9 páginas A4, PT-BR, identidade Hamsa) para enviar junto
com o Kit de Boas-Vindas da VUMI a todo cliente novo de Travel VIP.

| Arquivo | Uso |
|---|---|
| `manual-vumi-travel-vip.pdf` | o que vai para o cliente (e-mail / WhatsApp) |
| `manual-vumi-travel-vip.html` | fonte editável; gera o PDF |
| `hamsa-simbolo-360.png` | símbolo Hamsa reduzido usado na capa |

**Genérico de propósito**: a capa tem campos em branco (titular, apólice,
plano, vigência). A personalização já vem no Certificado da VUMI; manter um
único manual evita retrabalho a cada venda.

## Fonte dos dados

Tudo foi tirado das **Condições de Cobertura Travel VIP 2026 (PT)**, as
mesmas que o Kit de Boas-Vindas da VUMI linka:
<https://s3.amazonaws.com/vumigroup.planes/Condiciones_Cobertura_travel/2026/condiciones_cobertura_travel_pt.pdf>
Principais trechos usados: tabela de benefícios, §2 (duração, carência de 3 dias,
extensões), §6 (benefícios e anexos opcionais), §7 (exclusões) e §8
(notificação, reembolso de 180 dias, recursos, reclamações).

⚠️ **Contatos de emergência**: o manual usa os da apólice Travel
(+1 416 744 3870, +1 888 809 3493 nos EUA, emergencytravel@vumigroup.com) e
manda o cliente conferir o verso da carteirinha. O card
`seguradoras_emergencia_2026.png` lista outros números da VUMI
(+1 214 276-6376 / +55 11 3197-6670 / notify@), que parecem ser da linha de
saúde (IPMI). Isso precisa ser validado com a SDM/VUMI antes de distribuir.

## Regenerar o PDF

```bash
node -e "
const {chromium}=require('playwright');(async()=>{const b=await chromium.launch();
const p=await b.newPage();await p.goto('file://'+process.cwd()+'/manual-vumi-travel-vip.html',{waitUntil:'networkidle'});
await p.pdf({path:'manual-vumi-travel-vip.pdf',format:'A4',printBackground:true,preferCSSPageSize:true});await b.close();})()"
```

Ao atualizar para 2027: troque os valores da tabela (pág. 4) e o ano das
Condições de Cobertura.
