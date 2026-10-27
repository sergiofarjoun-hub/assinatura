#!/usr/bin/env python3
"""Gera o onboarding personalizado VUMI Travel VIP (PDF + texto do e-mail).

Uso:
    python3 gerar_onboarding.py cliente.json [--saida DIR] [--so-html]

cliente.json pode ser um objeto (um cliente) ou uma lista. Campos em
exemplos/cliente-exemplo.json. Para cada cliente gera, em DIR (padrão ./saida):
    Onboarding_VUMI_Travel_VIP_<Nome>.html / .pdf
    Onboarding_VUMI_Travel_VIP_<Nome>.email.txt   (assunto + corpo)
"""
import argparse
import base64
import json
import re
import subprocess
import sys
import unicodedata
from datetime import date
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, StrictUndefined

AQUI = Path(__file__).resolve().parent
MESES = ["jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"]
# Condições de Cobertura Travel VIP 2026
LIMITE_PADRAO, LIMITE_70 = "US$ 5.000.000", "US$ 500.000"
CANCELAMENTO = {"simples": "2.500", "anual": "1.500"}
PARTICULAS = {"da", "das", "de", "do", "dos", "e"}
# país de residência -> (preposição "de", preposição "em"); padrão Brasil
PAISES = {
    "Brasil": ("do Brasil", "no Brasil"),
    "Portugal": ("de Portugal", "em Portugal"),
    "Emirados Árabes Unidos": ("dos Emirados Árabes Unidos", "nos Emirados Árabes Unidos"),
    "Estados Unidos": ("dos Estados Unidos", "nos Estados Unidos"),
}


def nome_proprio(nome):
    """'MARIA DA SILVA' -> 'Maria da Silva' (partículas em minúsculo)."""
    return " ".join(p if i and p in PARTICULAS else p.capitalize()
                    for i, p in enumerate(nome.lower().split()))


def data_br(iso):
    d = date.fromisoformat(iso)
    return f"{d.day:02d}/{MESES[d.month - 1]}/{d.year}"


def idade_em(nasc, ref):
    n, r = date.fromisoformat(nasc), date.fromisoformat(ref)
    return r.year - n.year - ((r.month, r.day) < (n.month, n.day))


def slug(nome):
    s = unicodedata.normalize("NFKD", nome).encode("ascii", "ignore").decode()
    return re.sub(r"[^A-Za-z0-9]+", "_", s).strip("_")


def validar(c):
    faltando = [k for k in ("titular", "apolice", "plano", "vigencia_inicio", "vigencia_fim") if not c.get(k)]
    if faltando:
        raise ValueError(f"campos obrigatórios ausentes: {', '.join(faltando)}")
    if c["plano"] not in ("anual", "simples"):
        raise ValueError("plano deve ser 'anual' ou 'simples'")
    if c["plano"] == "anual" and c.get("dias_por_viagem") not in (30, 45, 90):
        raise ValueError("plano anual exige dias_por_viagem = 30, 45 ou 90")


def contexto(c):
    validar(c)
    segurados = c.get("segurados") or [{"nome": c["titular"]}]
    ini = c["vigencia_inicio"]
    for s in segurados:
        s["idade"] = idade_em(s["nascimento"], ini) if s.get("nascimento") else None
    com_70 = [nome_proprio(s["nome"].split()[0]) for s in segurados if s["idade"] is not None and s["idade"] >= 70]
    todos_70 = bool(com_70) and len(com_70) == len(segurados)
    op = c.get("opcionais", {})
    pais = c.get("pais_residencia", "Brasil")
    pais_de, pais_em = PAISES.get(pais, (f"de {pais}", f"em {pais}"))
    plano_txt = (f"Anual · até {c['dias_por_viagem']} dias por viagem" if c["plano"] == "anual"
                 else "Viagem simples")
    return {
        **c,
        "primeiro_nome": nome_proprio(c["titular"].split()[0]),
        "titular": nome_proprio(c["titular"]),
        "segurados": segurados,
        "segurados_txt": ", ".join(nome_proprio(s["nome"]) for s in segurados),
        "outros_nomes": ", ".join(nome_proprio(s["nome"].split()[0]) for s in segurados[1:]),
        "plano_txt": plano_txt,
        "vigencia_txt": f"{data_br(ini)} a {data_br(c['vigencia_fim'])}",
        "fim_txt": data_br(c["vigencia_fim"]),
        "limite_txt": LIMITE_70 if todos_70 else (LIMITE_PADRAO + (" (US$ 500 mil a partir de 70 anos)" if com_70 else "")),
        "algum_70": bool(com_70),
        "nomes_70": ", ".join(com_70),
        "op_nao_medicos": bool(op.get("nao_medicos")),
        "op_cancelamento": bool(op.get("cancelamento")),
        "cancelamento_limite": CANCELAMENTO[c["plano"]],
        "pais_de": pais_de,
        "pais_em": pais_em,
        # numeração dos "passo a passo": 1 emergência, depois só as páginas que existem
        "n_cancelamento": 2 + bool(op.get("nao_medicos")),
        "n_reembolso": 2 + bool(op.get("nao_medicos")) + bool(op.get("cancelamento")),
    }


def email(ctx):
    assunto = (f"Bem-vindo(a) à VUMI Travel VIP — {ctx['titular']} — Apólice {ctx['apolice']}"
               " | Sessão de Onboarding | HAMSA")
    extras = []
    if ctx["op_nao_medicos"]:
        extras.append("   - O que fazer se a mala não chegar, o voo atrasar ou você perder a conexão")
    if ctx["op_cancelamento"]:
        extras.append("   - Como acionar o cancelamento de viagem")
    corpo = "\n".join([
        f"Prezado(a) {ctx['primeiro_nome']},",
        "",
        f"Parabéns pela sua apólice VUMI Travel VIP nº {ctx['apolice']}!",
        "",
        f"Anexamos um guia feito para o seu plano ({ctx['plano_txt']}) que mostra, passo a passo:",
        "",
        "   - O que fazer em uma emergência médica durante a viagem",
        *extras,
        "   - Como a HAMSA cuida do seu reembolso, sem dor de cabeça",
        "   - Os contatos de emergência do seguro viagem (diferentes dos do seguro saúde)",
        "",
        "Nos próximos dias, a VUMI também envia o Kit de Boas-Vindas (certificado e carteirinha)"
        " e as Credenciais de Boas-Vindas (login do app Travel VIP).",
        "",
        "A HAMSA está aqui como seu primeiro telefonema para qualquer dúvida. Não hesite em nos contactar!",
    ])
    return assunto, corpo


# Fontes estáticas locais: com web fonts variáveis o Chromium embute dezenas de
# fontes Type 3 e o PDF passa de 700 KB (pesado para anexo de e-mail).
FONTES = "\n".join(
    f"@font-face{{font-family:'{fam}';font-weight:{peso};src:url('{(AQUI / 'fonts' / arq).as_uri()}') format('truetype');}}"
    for fam, peso, arq in [("Inter", 400, "Inter-Regular.ttf"), ("Inter", 500, "Inter-SemiBold.ttf"),
                           ("Inter", 600, "Inter-SemiBold.ttf"), ("Inter", 700, "Inter-Bold.ttf"),
                           ("Playfair Display", 600, "PlayfairDisplay-Bold.ttf"),
                           ("Playfair Display", 700, "PlayfairDisplay-Bold.ttf")])
LOGO = "data:image/jpeg;base64," + base64.b64encode((AQUI / "hamsa-simbolo-navy.jpg").read_bytes()).decode()


def eh_travel(apolice):
    """Apólices VUMI Travel VIP começam com 7150 (as de saúde VUMI, com 8000)."""
    return re.sub(r"\D", "", str(apolice)).startswith("7150")


def gerar(cliente, saida, pdf=True):
    """Ponto de entrada para a rotina de Kits de Boas-Vindas.

    Recebe o dict do cliente (formato de exemplos/cliente-exemplo.json) e devolve
    {"pdf", "html", "assunto", "corpo"}. Levanta ValueError se faltar dado e
    CalledProcessError se o PDF não couber no A4: nesses casos, não criar o rascunho.
    """
    saida = Path(saida)
    saida.mkdir(parents=True, exist_ok=True)
    env = Environment(loader=FileSystemLoader(AQUI), undefined=StrictUndefined, autoescape=True)
    ctx = contexto(dict(cliente))
    base = saida / f"Onboarding_VUMI_Travel_VIP_{slug(ctx['titular'])}"
    html = base.with_suffix(".html")
    html.write_text(env.get_template("template.html.j2").render(c=ctx, logo=LOGO, fontes=FONTES), encoding="utf-8")
    assunto, corpo = email(ctx)
    base.with_suffix(".email.txt").write_text(f"Assunto: {assunto}\n\n{corpo}\n", encoding="utf-8")
    arquivo_pdf = base.with_suffix(".pdf")
    if pdf:
        subprocess.run(["node", str(AQUI / "render_pdf.js"), str(html), str(arquivo_pdf)], check=True)
    return {"pdf": arquivo_pdf if pdf else None, "html": html, "assunto": assunto, "corpo": corpo}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("entrada")
    ap.add_argument("--saida", default=str(AQUI / "saida"))
    ap.add_argument("--so-html", action="store_true", help="não gera o PDF")
    a = ap.parse_args()

    dados = json.loads(Path(a.entrada).read_text(encoding="utf-8"))
    clientes = dados if isinstance(dados, list) else [dados]

    erros = 0
    for c in clientes:
        try:
            r = gerar(c, a.saida, pdf=not a.so_html)
        except (ValueError, subprocess.CalledProcessError) as e:
            print(f"ERRO {c.get('apolice', '?')} {c.get('titular', '?')}: {e}", file=sys.stderr)
            erros += 1
            continue
        print(f"OK  {c['apolice']}  -> {r['html'].stem}")
    sys.exit(1 if erros else 0)


if __name__ == "__main__":
    main()
