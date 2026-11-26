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
# Offline search is added at the end: a Pagefind static index (no server —
# searching runs entirely in the browser) plus an injected search page at
# /docs/search and a search link on every mirrored page.
#
# Won't work offline (expected): analytics / captcha / shared-nav JS
# (third-party hosts) and links that leave elastic.co (github.com,
# cloud.elastic.co).
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
PAGEFIND_VERSION="${PAGEFIND_VERSION:-1.6.0}"
DOCS_SEARCH="${DOCS_SEARCH:-1}"        # 0 disables the pagefind index step
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
# the /docs landing page rides along regardless of scope
[[ -f "$OUT_DIR/docs/index.html" ]] || echo "$BASE/docs" >> "$todo"
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

# --- offline search (Pagefind) ----------------------------------------------
# Upstream's search is a server-side API — dead in the air-gap. Pagefind
# builds a static index from the mirrored HTML; searching then happens
# entirely in the browser with no backend. DOCS_SEARCH=0 skips this.
if [[ "$DOCS_SEARCH" == "1" ]]; then
  case "$(uname -m)" in
    x86_64|amd64)  PF_ARCH=x86_64 ;;
    aarch64|arm64) PF_ARCH=aarch64 ;;
    *) echo "warning: no pagefind binary for $(uname -m); skipping index" >&2; PF_ARCH="" ;;
  esac
  if [[ -n "$PF_ARCH" ]]; then
    PF_BIN="$WORK_DIR/pagefind/pagefind"
    if [[ ! -x "$PF_BIN" ]]; then
      mkdir -p "$WORK_DIR/pagefind"
      pf_url="https://github.com/CloudCannon/pagefind/releases/download/v${PAGEFIND_VERSION}/pagefind-v${PAGEFIND_VERSION}-${PF_ARCH}-unknown-linux-musl.tar.gz"
      echo "== downloading $pf_url"
      curl --retry 3 -fsSL "$pf_url" | tar -xz -C "$WORK_DIR/pagefind"
      chmod +x "$PF_BIN"
    fi
    echo "== indexing docs for offline search (pagefind $PAGEFIND_VERSION)"
    "$PF_BIN" --site "$OUT_DIR/docs" >/dev/null

    # A dedicated search page at /docs/search — upstream has no page there.
    cat > "$OUT_DIR/docs/search.html" <<'SEARCH_EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Search — Elastic Docs (offline mirror)</title>
<link href="/docs/pagefind/pagefind-ui.css" rel="stylesheet">
<style>
  body { max-width: 46rem; margin: 2rem auto; padding: 0 1rem;
         font-family: Inter, system-ui, sans-serif; color: #1a1a1a; }
  .note { background: #fff3cd; border: 1px solid #ffe69c; border-radius: 6px;
          padding: .6rem .9rem; font-size: .9rem; margin-bottom: 1.5rem; }
</style>
</head>
<body>
<h1>Search the docs</h1>
<p class="note">Offline mirror — searches only the mirrored pages, in your
browser. The upstream site's own search box does not work offline.</p>
<div id="search"></div>
<script src="/docs/pagefind/pagefind-ui.js"></script>
<script>
  new PagefindUI({ element: "#search", bundlePath: "/docs/pagefind/",
                   showSubResults: true, showImages: false });
</script>
</body>
</html>
SEARCH_EOF

    # The mirrored pages' built-in search button is dead offline; give every
    # page a working link to ours (idempotent — skipped when marker present).
    # grep -L exits 1 when a batch has nothing to report, which xargs turns
    # into 123 — hence the || true.
    find "$OUT_DIR/docs" -name '*.html' ! -name 'search.html' -print0 |
      xargs -0 grep -L 'id="offline-docs-search"' |
      xargs -r sed -i 's|</body>|<a id="offline-docs-search" href="/docs/search" style="position:fixed;right:1rem;bottom:1rem;z-index:9999;background:#0b64dd;color:#fff;padding:.45rem .8rem;border-radius:6px;font:14px/1.4 system-ui,sans-serif;text-decoration:none;box-shadow:0 1px 4px rgba(0,0,0,.3)">Search docs</a></body>|' || true
  fi
fi

echo "== done: $(find "$OUT_DIR/docs" -name '*.html' | wc -l) pages in $OUT_DIR/docs"
du -sh "$OUT_DIR/docs" | awk '{print "   size:", $1}'
