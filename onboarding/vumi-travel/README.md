# Onboarding VUMI® Travel VIP: guia personalizado por cliente

Segue a mesma rotina do onboarding de saúde (ex.: `Onboarding_EVER_<plano>_<nome>.pdf`):
quando a apólice Travel é aprovada, o cliente recebe um **PDF com o nome dele, o plano
e os opcionais que contratou**, junto com o e-mail "Bem-vindo(a) à VUMI Travel VIP —
<Nome> — Apólice <nº> | Sessão de Onboarding | HAMSA".

## O que o guia traz (PT-BR, linguagem simples)

| Pág. | Conteúdo | Quando aparece |
|---|---|---|
| Capa | "Olá, <nome>!", apólice, plano (anual 30/45/90 dias ou simples), vigência, segurados, limite médico, opcionais ✓/– | sempre |
| Passo a passo 1 | **Fiquei doente ou me machuquei**, com o aviso de que a **emergência do viagem é diferente da do saúde VUMI** e os números do Travel | sempre |
| Passo a passo 2 | **Mala não chegou · voo atrasou · perdi a conexão · fui roubado** | só se contratou "imprevistos de viagem" |
| Passo a passo 3 | **Precisei cancelar a viagem** (limite de US$ 2.500 no plano simples, US$ 1.500 no anual) | só se contratou cancelamento |
| Passo a passo N | **Como pedir reembolso** (180 dias, documentos, revisão pela Hamsa antes do envio). Sem o anexo de imprevistos, mostra o que fazer com a companhia aérea | sempre |
| Seu plano | Tabela de coberturas, com os opcionais **não contratados em cinza**, e checklist "antes de cada viagem" | sempre |
| Contatos | Primeiros 10 minutos (app, credenciais), contatos de emergência do Travel e da Hamsa | sempre |

Com `agente`, a capa ganha o cartão "Seu corretor" (logo, nome, cargo e contatos), a página de
contatos ganha o card do corretor e o convite para incluir opcionais na renovação aponta para ele.
Emergência e reembolso continuam com a Hamsa.

Outras regras de personalização: aviso de limite de US$ 500 mil para segurados com 70 anos
ou mais (a idade é calculada na data de início da vigência), nomes próprios corrigidos
("MARIA DA SILVA" vira "Maria da Silva") e a numeração dos passos e das páginas se ajusta
às seções presentes.

## Como usar

```bash
cd onboarding/vumi-travel
python3 gerar_onboarding.py cliente.json            # gera em ./saida/ (ignorado pelo git)
```

`cliente.json` aceita um objeto ou uma lista (veja `exemplos/cliente-exemplo.json`):

```json
{
  "titular": "MARIA EXEMPLO DA SILVA",
  "apolice": "7150000001",
  "plano": "anual",                 // "anual" | "simples"
  "dias_por_viagem": 45,            // só no anual: 30 | 45 | 90
  "vigencia_inicio": "2026-11-01",
  "vigencia_fim": "2027-10-31",
  "pais_residencia": "Brasil",      // opcional; padrão Brasil (o seguro não cobre nada nele)
  "agente": {                       // opcional: apólice de agente (corretor parceiro)
    "nome": "…", "cargo": "…", "empresa": "…", "whatsapp": "…", "celular": "…",
    "telefone": "…", "email": "…", "site": "…",
    "logo": "agentes/<agente>.jpg"  // relativo ao JSON; guarde em saida/agentes/ (fora do git)
  },
  "segurados": [{"nome": "Maria Exemplo da Silva", "nascimento": "1968-03-14"}],
  "opcionais": {"nao_medicos": true, "cancelamento": false}
}
```

Para cada cliente saem `…pdf` (anexo), `…email.txt` (assunto + corpo) e `…html`.
O render **falha** se algum conteúdo não couber na página A4, para nunca enviar PDF cortado.

Requisitos: Python 3 + Jinja2, Node + Playwright (Chromium). As fontes ficam em `fonts/` (OFL) para o PDF
sair com cerca de 100 KB. Com web fonts, o Chromium embute fontes Type 3 e o arquivo passa de 700 KB.

Exemplos gerados em `exemplos/saida/`: Maria (anual, todos os opcionais, um segurado com 72
anos, 7 págs.), Ana (anual, só cancelamento, 6 págs.) e Pedro (simples, sem opcionais, 5 págs.).

## Fonte dos dados

Condições de Cobertura Travel VIP 2026 (PT), o documento linkado no Kit de Boas-Vindas da VUMI:
<https://s3.amazonaws.com/vumigroup.planes/Condiciones_Cobertura_travel/2026/condiciones_cobertura_travel_pt.pdf>

Contatos de emergência do Travel (diferentes dos do saúde VUMI do card
`seguradoras_emergencia_2026.png`): +1 416 744 3870, +1 888 809 3493 (grátis nos EUA),
emergencytravel@vumigroup.com.

## Integração com a rotina de Kits de Boas-Vindas

A rotina que gera os rascunhos "📝 Kits de Boas-Vindas" roda fora deste repositório (Mac/NAS).
Para ligar o Travel nela, basta isto onde ela monta o rascunho de cada apólice:

```python
import sys; sys.path.insert(0, "/caminho/para/assinatura/onboarding/vumi-travel")
import gerar_onboarding as travel

if travel.eh_travel(apolice):                 # 7150… = Travel; 8000… = saúde VUMI
    r = travel.gerar(cliente, pasta_saida)    # dict no formato de exemplos/cliente-exemplo.json
    anexos.append(r["pdf"])                   # + os PDFs da VUMI que a rotina já anexa
    assunto, corpo = r["assunto"], r["corpo"]
```

`gerar()` levanta `ValueError` se faltar dado (plano, vigência…) e `CalledProcessError`
se o PDF não couber no A4. Nesses casos a rotina **não** deve criar o rascunho: o caso
vai para conferência manual, como já acontece com "SEM EMAIL".

**Ainda falta:** extrair do Certificado de Cobertura da VUMI os campos `plano`,
`dias_por_viagem`, vigência, segurados e opcionais. Isso precisa de um certificado
Travel real como amostra.
