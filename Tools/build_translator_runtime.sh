#!/bin/bash
# Builds a self-contained offline translator runtime into TranslatorRuntime/
# Result is copied into the .app by an Xcode build phase.
# Translation models are NOT bundled — the app downloads them on first use.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/TranslatorRuntime"
ARCH="$(uname -m)"
PY_VER="3.14.6"
PY_TAG="20260610"

if [[ "$ARCH" == "arm64" ]]; then
  PY_ARCH="aarch64-apple-darwin"
elif [[ "$ARCH" == "x86_64" ]]; then
  PY_ARCH="x86_64-apple-darwin"
else
  echo "Unsupported architecture: $ARCH" >&2
  exit 1
fi

PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PY_TAG}/cpython-${PY_VER}%2B${PY_TAG}-${PY_ARCH}-install_only.tar.gz"

echo "==> Preparing $OUT"
rm -rf "$OUT/python" "$OUT/models" "$OUT/_tmp"
mkdir -p "$OUT/models" "$OUT/_tmp"

echo "==> Downloading standalone Python ${PY_VER} ($PY_ARCH)"
curl -L --fail -o "$OUT/_tmp/python.tar.gz" "$PY_URL"
tar -xzf "$OUT/_tmp/python.tar.gz" -C "$OUT/_tmp"
mv "$OUT/_tmp/python" "$OUT/python"

echo "==> Installing ctranslate2 + sentencepiece + pymupdf"
"$OUT/python/bin/python3" -m pip install -q --upgrade pip
"$OUT/python/bin/python3" -m pip install -q "ctranslate2==4.8.1" "sentencepiece==0.2.2" "pymupdf==1.26.6"
# Drop accidental transitive tooling left by pip/resolvers (keeps the .app smaller).
"$OUT/python/bin/python3" -m pip uninstall -y \
  requests urllib3 charset-normalizer idna certifi \
  hf-xet rich typer httpx httpcore anyio click \
  markdown-it-py mdurl pygments shellingham pyyaml \
  >/dev/null 2>&1 || true

if [[ ! -f "$OUT/ct2_bridge.py" ]]; then
  echo "Missing $OUT/ct2_bridge.py" >&2
  exit 1
fi
if [[ ! -f "$OUT/model_catalog.json" ]]; then
  echo "Missing $OUT/model_catalog.json" >&2
  exit 1
fi

rm -rf "$OUT/_tmp"
echo "==> Runtime ready (Python $($OUT/python/bin/python3 -c 'import sys; print(sys.version.split()[0])')):"
du -sh "$OUT" "$OUT/python"
echo "Models are downloaded on demand into Application Support (see model_catalog.json)."
echo "Next: build the Xcode app (Copy Translator Runtime phase embeds this into the .app)."
