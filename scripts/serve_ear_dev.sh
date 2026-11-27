#!/usr/bin/env bash
# Dev-only EAR: serve dist/ear on a local port — same docroot semantics as
# the production Caddyfile (files/ear/Caddyfile), minus TLS and hostnames.
#
#   ./scripts/serve_ear_dev.sh        # then open http://localhost:9988/
#
# Everything under dist/ear (downloads/, geoip/, feeds/, GPG key) serves
# verbatim with directory browse enabled — handy for poking the EAR layout.
#
# Knobs: PORT (default 9988), CADDY (path to binary — uses dist/web/bin/caddy
# if present, else PATH).
set -euo pipefail

PORT="${PORT:-9988}"
ROOT="$(realpath -m "${OUT_DIR:-dist/ear}")"
CADDY="${CADDY:-}"

if [[ -z "$CADDY" ]]; then
  for c in dist/web/bin/caddy "$(command -v caddy || true)"; do
    [[ -n "$c" && -x "$c" ]] && CADDY="$c" && break
  done
fi
[[ -n "$CADDY" ]] || { echo "error: no caddy binary — run task download:webserver" >&2; exit 1; }
[[ -d "$ROOT" ]] || { echo "error: $ROOT not found — run task download:ear" >&2; exit 1; }

conf="$(mktemp /tmp/ear-dev.XXXXXX.caddyfile)"
trap 'rm -f "$conf"' EXIT
cat > "$conf" <<EOF
{
	auto_https off
}

:$PORT {
	root * $ROOT
	encode zstd gzip
	file_server browse
}
EOF

echo "== serving $ROOT on http://localhost:$PORT"
echo "   ctrl-c to stop"
exec "$CADDY" run --adapter caddyfile --config "$conf"
