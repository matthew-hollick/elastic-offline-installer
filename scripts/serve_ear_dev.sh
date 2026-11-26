#!/usr/bin/env bash
# Dev-only EAR: serve dist/ on a local port with the same URL semantics as
# the production Caddyfile (files/ear/Caddyfile), minus TLS and hostnames.
#
#   ./scripts/serve_ear_dev.sh        # then open http://localhost:9988/docs
#
# Mirrors what the www.elastic.co vhost does: extensionless doc URLs resolve
# to the .html files wget stores (try_files), / redirects to /docs, and the
# legacy /guide/en/<book>/* links redirect to the matching /docs section.
# Everything else under dist/ear (downloads/, geoip/, feeds/, GPG key)
# serves verbatim — handy for poking the whole EAR layout, not just docs.
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
[[ -d "$ROOT" ]] || { echo "error: $ROOT not found — run task download:ear (and download:docs* for docs)" >&2; exit 1; }

conf="$(mktemp /tmp/ear-dev.XXXXXX.caddyfile)"
trap 'rm -f "$conf"' EXIT
cat > "$conf" <<EOF
{
	auto_https off
}

:$PORT {
	root * $ROOT
	encode zstd gzip
	redir /guide/en/elasticsearch/* /docs/reference/elasticsearch 301
	redir /guide/en/kibana/* /docs/reference/kibana 301
	redir /guide/en/fleet/* /docs/reference/fleet 301
	redir /guide/en/security/* /docs/solutions/security 301
	redir /guide/en/logstash/* /docs/reference/logstash 301
	redir /guide/en/beats/* /docs/reference/beats 301
	redir /guide/en/* /docs 301
	redir /guide/* /docs 301
	@root path /
	redir @root /docs 302
	try_files {path} {path}.html {path}/index.html
	file_server browse
}
EOF

echo "== serving $ROOT on http://localhost:$PORT  (docs at /docs, search at /docs/search)"
echo "   ctrl-c to stop"
exec "$CADDY" run --adapter caddyfile --config "$conf"
