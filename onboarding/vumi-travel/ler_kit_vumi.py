#!/usr/bin/env python3
"""Lê o Welcome Kit da VUMI Travel VIP e monta o JSON do cliente para o gerar_onboarding.

Uso:
    python3 ler_kit_vumi.py <kit> [--json saida.json]

<kit> pode ser:
  - o JSON do Gmail com o e-mail em formato RAW (get_message messageFormat=RAW),
  - um arquivo .eml,
  - ou uma pasta com os PDFs do kit (Application_*.pdf e Certificate_of_Coverage_*.pdf).

Fonte principal: a Application (checkboxes de opção/opcionais, datas, país, segurados,
agente). O Certificate of Coverage confere opção, opcionais e vigência; se discordar,
para com erro (caso vai para conferência manual, nunca chuta).
"""
import argparse
import base64
import email
import json
import re
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

AQUI = Path(__file__).resolve().parent
AGENTES = AQUI / "agentes" / "agentes.json"
PAISES = {"Brazil": "Brasil", "United Arab Emirates": "Emirados Árabes Unidos",
          "United States": "Estados Unidos", "Portugal": "Portugal", "Spain": "Espanha",
          "United Kingdom": "Reino Unido", "Argentina": "Argentina", "Uruguay": "Uruguai"}


class KitInvalido(ValueError):
    pass


def extrair_pdfs(kit, destino):
    """Grava os PDFs do kit em `destino` e devolve (application, certificate)."""
    kit = Path(kit)
    if kit.is_dir():
        pasta = kit
    else:
        dados = kit.read_bytes()
        if kit.suffix != ".eml":
            raw = json.loads(dados)["raw"]
            dados = base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4))
        pasta = Path(destino)
        for parte in email.message_from_bytes(dados).walk():
            nome = parte.get_filename()
            if nome and nome.lower().endswith(".pdf"):
                seguro = re.sub(r"[^A-Za-z0-9._-]", "_", nome)
                (pasta / seguro).write_bytes(parte.get_payload(decode=True))
    app = sorted(pasta.glob("Application*.pdf"))
    cert = sorted(pasta.glob("Certificate*.pdf"))
    if not app or not cert:
        raise KitInvalido("kit sem Application e/ou Certificate of Coverage em PDF")
    return app[0], cert[0]


def texto(pdf, primeira=None, ultima=None):
    cmd = ["pdftotext", "-layout"]
    if primeira:
        cmd += ["-f", str(primeira), "-l", str(ultima or primeira)]
    return subprocess.run(cmd + [str(pdf), "-"], capture_output=True, text=True, check=True).stdout


def _iso_us(d):            # 10/31/2026 -> 2026-10-31
    return datetime.strptime(d, "%m/%d/%Y").date().isoformat()


def _iso_extenso(d):       # October 31, 2026 -> 2026-10-31
    return datetime.strptime(d.strip(), "%B %d, %Y").date().isoformat()


def _campo(rotulo, txt):
    m = re.search(rf"{rotulo}\s*(.+)", txt)
    return m.group(1).strip() if m else None


def ler_application(txt):
    marcados = re.findall(r"☑\s*([A-Za-z][A-Za-z0-9 -]*?)(?=\s{2,}|☐|☑|$)", txt, re.M)
    marcados = [m.strip() for m in marcados]
    opcao = next((m for m in marcados if re.fullmatch(r"Single|Annual (30|45|90)", m)), None)
    if not opcao:
        raise KitInvalido("opção do plano (Single/Annual 30/45/90) não marcada na Application")

    # 1ª linha de valores após "Email address:" → e-mail na 1ª coluna
    m = re.search(r"Email address:.*\n\s*(\S+@\S+)", txt)
    email_cli = m.group(1) if m else None
    # nascimento do titular: 1ª data do bloco do solicitante (o cabeçalho quebra linha
    # conforme o tamanho do nome, então não dá para depender da posição)
    m = re.search(r"Applicant Information(.*?)Address:", txt, re.S)
    d = re.search(r"\b(\d{2}/\d{2}/\d{4})\b", m.group(1)) if m else None
    nasc_titular = _iso_us(d.group(1)) if d else None

    # acompanhantes/dependentes: linha "Nome Completo      #1" e, nas linhas seguintes,
    # a 1ª data mm/dd/aaaa é o nascimento
    companheiros, linhas = [], txt.splitlines()
    for i, linha in enumerate(linhas):
        m = re.match(r"^\s*(\S.*?)\s{2,}#\d+\s*$", linha)
        if not m:
            continue
        nasc = None
        for prox in linhas[i + 1:i + 6]:
            d = re.search(r"\b(\d{2}/\d{2}/\d{4})\b", prox)
            if d:
                nasc = _iso_us(d.group(1))
                break
        companheiros.append({"nome": m.group(1).strip(), "nascimento": nasc})

    agente = re.search(r"As an agent,\s*(\d+)\s*-\s*(.+?),", txt)
    return {
        "opcao": opcao,
        "nao_medicos": "Non-medical" in marcados,
        "cancelamento": "Trip cancellation" in marcados,
        "inicio": _iso_us(_campo("Coverage start date:", txt)),
        "fim": _iso_us(_campo("Coverage end date:", txt)),
        "pais": (_campo("Country of residence:", txt) or "Brazil"),
        "email": email_cli,
        "nasc_titular": nasc_titular,
        "companheiros": companheiros,
        "agente_codigo": agente.group(1) if agente else None,
        "agente_nome_vumi": agente.group(2).strip() if agente else None,
    }


def ler_certificado(txt):
    titular = re.search(r"Dear\s+(.+?),", txt)
    periodo = re.search(r"Coverage period:\s*(.+?)\s+-\s+(.+?)\s*$", txt, re.M)
    if not (titular and periodo):
        raise KitInvalido("Certificate of Coverage sem titular ou vigência na 1ª página")
    return {
        "titular": titular.group(1).strip(),
        "apolice": _campo("Policy number:", txt),
        "opcao": _campo("Option:", txt),
        "riders": _campo("Riders:", txt),
        "inicio": _iso_extenso(periodo.group(1)),
        "fim": _iso_extenso(periodo.group(2)),
    }


def montar_cliente(app, cert, agentes):
    # conferência cruzada Application x Certificate
    if cert["opcao"].replace(" Trip", "") != app["opcao"]:
        raise KitInvalido(f"opção diverge: Application '{app['opcao']}' x Certificate '{cert['opcao']}'")
    if (cert["inicio"], cert["fim"]) != (app["inicio"], app["fim"]):
        raise KitInvalido("vigência diverge entre Application e Certificate")
    riders = (cert["riders"] or "").lower()
    if riders in ("n/a", "", "none"):
        if app["nao_medicos"] or app["cancelamento"]:
            raise KitInvalido("Application marca opcional mas o Certificate diz Riders: N/A")
    else:
        if ("non" in riders and "medical" in riders) != app["nao_medicos"] or \
           ("cancel" in riders) != app["cancelamento"]:
            raise KitInvalido(f"opcionais divergem: Certificate '{cert['riders']}'")

    anual = app["opcao"].startswith("Annual")
    cliente = {
        "titular": cert["titular"],
        "apolice": cert["apolice"],
        "email": app["email"],
        "plano": "anual" if anual else "simples",
        "vigencia_inicio": app["inicio"],
        "vigencia_fim": app["fim"],
        "pais_residencia": PAISES.get(app["pais"], app["pais"]),
        "segurados": [{"nome": cert["titular"], "nascimento": app["nasc_titular"]}] + app["companheiros"],
        "opcionais": {"nao_medicos": app["nao_medicos"], "cancelamento": app["cancelamento"]},
    }
    if anual:
        cliente["dias_por_viagem"] = int(app["opcao"].split()[1])
    ag = agentes.get(app["agente_codigo"] or "")
    if ag and not ag.get("hamsa"):
        cliente["agente"] = {k: v for k, v in ag.items() if k not in ("nome_vumi", "hamsa")}
        if cliente["agente"].get("logo"):
            cliente["agente"]["logo"] = str(AGENTES.parent / cliente["agente"]["logo"])
    elif not ag:
        print(f"AVISO: agente VUMI {app['agente_codigo']} ({app['agente_nome_vumi']}) não está em "
              f"{AGENTES.name}: o guia sai sem os dados do corretor", file=sys.stderr)
    return cliente


def ler_kit(kit):
    agentes = json.loads(AGENTES.read_text(encoding="utf-8")) if AGENTES.exists() else {}
    with tempfile.TemporaryDirectory() as tmp:
        app_pdf, cert_pdf = extrair_pdfs(kit, tmp)
        app = ler_application(texto(app_pdf))
        cert = ler_certificado(texto(cert_pdf, 1))
    return montar_cliente(app, cert, agentes)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("kit")
    ap.add_argument("--json", help="grava o JSON do cliente neste arquivo")
    a = ap.parse_args()
    try:
        cliente = ler_kit(a.kit)
    except KitInvalido as e:
        print(f"CONFERÊNCIA MANUAL: {e}", file=sys.stderr)
        sys.exit(2)
    saida = json.dumps(cliente, ensure_ascii=False, indent=2)
    if a.json:
        Path(a.json).write_text(saida + "\n", encoding="utf-8")
    print(saida)


if __name__ == "__main__":
    main()
