#!/usr/bin/env bash
# Mirror the Elastic documentation site (https://www.elastic.co/docs/) so the
# EAR's www.elastic.co vhost can serve it inside the air-gap — see
# files/ear/Caddyfile.
#
# Rather than rebuilding the site from source (elastic/docs-builder is a
# .NET tool shipped only as linux-x64, fragile under emulation), we mirror
# the fully pre-rendered static HTML Elastic already publishes. The page
# list comes from Elastic's own sitemap — deterministic, complete, and
# scoped to /docs/ — and wget fetches each page plus its same-host page
# requisites (/docs/_static assets, per-page images). Page links are
# absolute to www.elastic.co or root-relative — both resolve correctly when
# the tree is served as that hostname, so no link rewriting is needed (and
# -k would disable -nc, breaking incremental re-runs).
#
# Layout produced — URI paths preserved 1:1:
#   <OUT_DIR>/docs/get-started/the-stack.html
#   <OUT_DIR>/docs/api/cloud/....html
#   <OUT_DIR>/docs/_static/main-<hash>.js
#   <OUT_DIR>/docs/<section>/images/*.svg|png
#
# Won't work offline (expected): site search (server-side API), analytics /
# captcha / shared-nav JS (third-party hosts), and links that leave
# elastic.co (github.com, cloud.elastic.co).
#
# Knobs:
#   DOCS_SCOPE     extended regex the sitemap URLs must match.
#                  default mirrors all of /docs/ (~14.7k pages, ~1-2 GB).
#                  e.g. DOCS_SCOPE='/docs/(reference|solutions|deploy-manage)/'
#   DOCS_PARALLEL  concurrent fetch workers (default 4 — the site is behind
#                  a CDN, stay polite)
#   DOCS_WAIT      seconds each worker sleeps between requests (default 0.2)
#
# Re-runs are incremental: wget -nc skips pages/assets already on disk, and
# `task manifest:diff` / package:delta pick up whatever is new.
set -euo pipefail

OUT_DIR="$(realpath -m "${OUT_DIR:-dist/ear}")"
WORK_DIR="$(realpath -m "${WORK_DIR:-.build/docs-work}")"
DOCS_SCOPE="${DOCS_SCOPE:-^https://www\.elastic\.co/docs/}"
DOCS_PARALLEL="${DOCS_PARALLEL:-4}"
DOCS_WAIT="${DOCS_WAIT:-0.2}"
BASE="https://www.elastic.co"

command -v wget >/dev/null || { echo "error: wget not found" >&2; exit 1; }
mkdir -p "$OUT_DIR" "$WORK_DIR"

# --- sitemap -> url list ----------------------------------------------------
# sitemap.xml is an index pointing at sitemap-docs.xml + sitemap-api.xml.
urls_all="$WORK_DIR/urls-all.txt"
urls="$WORK_DIR/urls.txt"
: > "$urls_all"
for s in sitemap-docs sitemap-api; do
  echo "== fetching $BASE/docs/$s.xml"
  curl --retry 3 -fsSL "$BASE/docs/$s.xml" |
    grep -oE "<loc>[^<]+" | sed 's/<loc>//' >> "$urls_all"
done
# /docs landing page isn't in the sitemap
grep -qx "$BASE/docs" "$urls_all" || echo "$BASE/docs" >> "$urls_all"
grep -E "$DOCS_SCOPE" "$urls_all" > "$urls"

# Incremental: drop URLs whose page is already mirrored. -nc alone can't do
# this — it checks the pre-extension filename, so "…/the-stack" re-downloads
# even though the-stack.html exists. Upstream page content is mutable, so a
# page already on disk isn't revalidated (matches the -nc semantics below).
# Delete a page's .html to force its refetch.
todo="$WORK_DIR/urls-todo.txt"
while IFS= read -r u; do
  rel="${u#"$BASE"}"                     # /docs/get-started/the-stack
  page="$OUT_DIR${rel}.html"
  idx="$OUT_DIR${rel}/index.html"
  [[ -f "$page" || -f "$idx" ]] || echo "$u"
done < "$urls" > "$todo"
echo "== $(wc -l < "$urls") of $(wc -l < "$urls_all") sitemap URLs match DOCS_SCOPE; $(wc -l < "$todo") to fetch"

# --- parallel mirror ----------------------------------------------------------
# Split the list across workers; each wget -p fetches page requisites itself.
# -nc makes re-runs skip existing files, so a second run only pulls new pages.
rm -f "$WORK_DIR"/chunk-*
split -n "l/$DOCS_PARALLEL" "$todo" "$WORK_DIR/chunk-"

pids=()
for c in "$WORK_DIR"/chunk-*; do
  wget -nv -nc -E -p -nH -P "$OUT_DIR" \
       --wait="$DOCS_WAIT" -i "$c" > "$c.log" 2>&1 &
  pids+=($!)
done
rc=0
for p in "${pids[@]}"; do wait "$p" || rc=1; done

# wget saves assets whose URLs carry ?query cache-busters under literal names
# like "logo.svg?v=abc123". Caddy strips the query when serving, so the file
# must also exist at the clean name — copy rather than move: keeping the
# ?-named file too lets -nc skip the asset on re-runs. Links are %3F-encoded
# in fetched pages; decode them to the clean name.
find "$OUT_DIR" -type f -name '*\?*' | while IFS= read -r f; do
  cp -f "$f" "${f%%\?*}"
done
find "$OUT_DIR" -name '*.html' -exec sed -i 's/%3F[^"'"'"')]*//g' {} +

# https://www.elastic.co/docs is fetched to <OUT_DIR>/docs.html — a sibling of
# the docs/ tree. Move it inside as index.html so /docs resolves to it.
if [[ -f "$OUT_DIR/docs.html" && -d "$OUT_DIR/docs" ]]; then
  mv -f "$OUT_DIR/docs.html" "$OUT_DIR/docs/index.html"
fi
# wget's per-worker logs accumulate errors; surface them but don't fail the
# mirror on a handful of 404s (upstream itself has dead links).
grep -hE "ERROR|unable|failed" "$WORK_DIR"/chunk-*.log | sort | uniq -c | sort -rn | head -20 || true
[[ $rc -eq 0 ]] || echo "warning: some pages failed to fetch (see $WORK_DIR/chunk-*.log); re-run to retry" >&2

echo "== done: $(find "$OUT_DIR/docs" -name '*.html' | wc -l) pages in $OUT_DIR/docs"
du -sh "$OUT_DIR/docs" | awk '{print "   size:", $1}'
