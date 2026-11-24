#!/usr/bin/env bash
# Build elastic/package-registry from source and assemble dist/epr/ with
# the binary, config and a systemd unit. No binaries are published upstream,
# so this requires git and go (both provided via mise).
set -euo pipefail

EPR_VERSION="${EPR_VERSION:-latest}"
OUT_DIR="$(realpath -m "${OUT_DIR:-dist/epr}")"
BUILD_DIR="$(realpath -m "${BUILD_DIR:-.build}")"

for tool in git go curl; do
  command -v "$tool" >/dev/null || { echo "error: '$tool' not found (mise install?)" >&2; exit 1; }
done

if [[ "$EPR_VERSION" == "latest" ]]; then
  EPR_VERSION=$(curl -fsSL https://api.github.com/repos/elastic/package-registry/releases/latest \
    | grep -oP '"tag_name":\s*"\K[^"]+')
  echo "== resolved latest package-registry release: $EPR_VERSION"
fi

src="$BUILD_DIR/package-registry"
if [[ ! -d "$src/.git" ]]; then
  echo "== cloning package-registry $EPR_VERSION"
  mkdir -p "$BUILD_DIR"
  git clone --depth 1 --branch "$EPR_VERSION" \
    https://github.com/elastic/package-registry "$src"
else
  echo "== reusing existing clone at $src"
fi

echo "== building package-registry"
(cd "$src" && CGO_ENABLED=0 go build -trimpath -o "$OUT_DIR/bin/package-registry" .)

mkdir -p "$OUT_DIR/packages"
cp files/epr/config.yml files/epr/epr.service "$OUT_DIR/"

echo "== wrote $OUT_DIR:"
echo "   bin/package-registry  ($EPR_VERSION)"
echo "   config.yml, epr.service, packages/"
echo "   drop integration zips into packages/ (task download:integrations)"
