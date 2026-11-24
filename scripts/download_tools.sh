#!/usr/bin/env bash
# Download the Elastic support-diagnostics distribution — the tool
# Elastic Support asks for when capturing full cluster/platform state.
# Lands in dist/tools/ (unzip on any node with a JRE and run
# support-diagnostics.sh).
set -euo pipefail

DIAG_VERSION="${DIAG_VERSION:-latest}"
OUT_DIR="$(realpath -m "${OUT_DIR:-dist/tools}")"

if [[ "$DIAG_VERSION" == "latest" ]]; then
  DIAG_VERSION=$(curl -fsSL https://api.github.com/repos/elastic/support-diagnostics/releases/latest \
    | grep -oP '"tag_name":\s*"\K[^"]+')
fi
ver="${DIAG_VERSION#v}"
echo "== support-diagnostics $DIAG_VERSION"

zip="diagnostics-${ver}-dist.zip"
base="https://github.com/elastic/support-diagnostics/releases/download/${DIAG_VERSION}"

mkdir -p "$OUT_DIR"
if [[ -f "$OUT_DIR/$zip" ]]; then
  echo "  exists: $zip"
else
  curl -fsSL --retry 3 -o "$OUT_DIR/$zip.part" "$base/$zip"
  mv "$OUT_DIR/$zip.part" "$OUT_DIR/$zip"
fi
curl -fsSL --retry 3 -o "$OUT_DIR/$zip.sha256" "$base/$zip.sha256"

echo "== verifying sha256"
(cd "$OUT_DIR" && sha256sum -c "$zip.sha256")
