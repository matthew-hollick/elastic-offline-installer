#!/usr/bin/env bash
# Download the Caddy webserver (single static binary) for the EAR and
# assemble dist/web/ with the Caddyfile and systemd unit.
set -euo pipefail

CADDY_VERSION="${CADDY_VERSION:-latest}"
TARGET_ARCH="${TARGET_ARCH:-amd64}"   # caddy uses Go arch names directly
OUT_DIR="$(realpath -m "${OUT_DIR:-dist/web}")"

case "$TARGET_ARCH" in
  amd64|arm64) GO_ARCH="$TARGET_ARCH" ;;
  *) echo "error: unsupported TARGET_ARCH '$TARGET_ARCH' (amd64|arm64)" >&2; exit 1 ;;
esac

if [[ "$CADDY_VERSION" == "latest" ]]; then
  CADDY_VERSION=$(curl -fsSL https://api.github.com/repos/caddyserver/caddy/releases/latest \
    | grep -oP '"tag_name":\s*"\K[^"]+')
fi
ver="${CADDY_VERSION#v}"
echo "== caddy $CADDY_VERSION (linux/$GO_ARCH)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
base="https://github.com/caddyserver/caddy/releases/download/${CADDY_VERSION}"
tarball="caddy_${ver}_linux_${GO_ARCH}.tar.gz"

curl -fsSL --retry 3 -o "$tmp/$tarball" "$base/$tarball"
curl -fsSL --retry 3 -o "$tmp/checksums.txt" "$base/caddy_${ver}_checksums.txt"

echo "== verifying sha512"
(cd "$tmp" && grep "  $tarball\$" checksums.txt | sha512sum -c -)

mkdir -p "$OUT_DIR/bin"
tar -xzf "$tmp/$tarball" -C "$OUT_DIR/bin" caddy
chmod +x "$OUT_DIR/bin/caddy"
cp files/ear/Caddyfile files/ear/ear.service "$OUT_DIR/"

# TLS material is NOT staged here — certificates are issued inside the
# offline environment and installed on the target at deploy time into
# /opt/ear-web/tls/ (see ear.service setup comments).

echo "== wrote $OUT_DIR:"
echo "   bin/caddy ($CADDY_VERSION), Caddyfile, ear.service"
