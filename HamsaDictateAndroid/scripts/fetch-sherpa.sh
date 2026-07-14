#!/usr/bin/env bash
# Baixa o AAR oficial do sherpa-onnx (classes Kotlin + libs nativas) para
# app/libs/. Rode uma vez antes do primeiro build local.
set -euo pipefail

VERSION="1.13.2"
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VERSION}/sherpa-onnx-${VERSION}.aar"
DEST="$(dirname "$0")/../app/libs/sherpa-onnx.aar"

mkdir -p "$(dirname "$DEST")"
echo "Baixando sherpa-onnx v${VERSION}…"
curl -sSL -o "$DEST" "$URL"
ls -lh "$DEST"
