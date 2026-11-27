#!/usr/bin/env bash
# Render the project guide to a print-ready PDF via pandoc + typst.
#
#   ./scripts/build_guide_pdf.sh
#
# Authoring stays in Markdown (README.md, GFM); pandoc translates to typst
# markup and files/docs/guide.typst supplies the designed theme — cover page,
# running headers, section pagebreaks, styled code/tables.
#
# Uses pandoc/typst from PATH when present; otherwise downloads the pinned
# musl builds into .build/bin (works on x86_64 and aarch64 alike — typst is
# a Rust binary, no .NET anywhere in this pipeline).
#
# Env knobs:
#   PANDOC_VERSION  fallback download pin (default 3.14)
#   TYPST_VERSION   fallback download pin (default 0.15.1)
#   STACK_VERSION   shown on the cover + baked into the filename
#   DOCS_INPUT      markdown source(s), space-separated (default README.md)
#   DOCS_TITLE      cover title
#   DOCS_SUBTITLE   cover subtitle
#   OUT_FILE        output pdf (default dist/docs/…-guide-<stack>.pdf)
#   BIN_DIR         tool cache (default .build/bin)
set -euo pipefail

PANDOC_VERSION="${PANDOC_VERSION:-3.14}"
TYPST_VERSION="${TYPST_VERSION:-0.15.1}"
STACK_VERSION="${STACK_VERSION:-9.5.7}"
DOCS_INPUT="${DOCS_INPUT:-README.md}"
DOCS_TITLE="${DOCS_TITLE:-Elastic Offline Installer}"
DOCS_SUBTITLE="${DOCS_SUBTITLE:-Air-gapped Elastic Stack deployment & operations guide}"
OUT_FILE="${OUT_FILE:-dist/docs/elastic-offline-installer-guide-${STACK_VERSION}.pdf}"
BIN_DIR="$(realpath -m "${BIN_DIR:-.build/bin}")"
TEMPLATE="$(realpath "$(dirname "$(realpath "$0")")/../files/docs/guide.typst")"

mkdir -p "$BIN_DIR" "$(dirname "$OUT_FILE")"

case "$(uname -m)" in
  x86_64)  pandoc_arch=amd64;  typst_arch=x86_64 ;;
  aarch64) pandoc_arch=arm64;  typst_arch=aarch64 ;;
  *) echo "error: unsupported arch $(uname -m)" >&2; exit 1 ;;
esac

fetch_tool() {
  local url="$1" dest="$2"
  echo "== fetching $url" >&2
  curl -fsSL "$url" -o "$dest.dl"
  mv "$dest.dl" "$dest"
}

ensure_tool() { # tool-name version -> echoes path
  local name="$1" ver="$2"
  local exe="$BIN_DIR/$name"
  command -v "$name" >/dev/null 2>&1 && { command -v "$name"; return; }
  if [[ ! -x "$exe" ]]; then
    if [[ "$name" == pandoc ]]; then
      fetch_tool "https://github.com/jgm/pandoc/releases/download/${ver}/pandoc-${ver}-linux-${pandoc_arch}.tar.gz" "$exe.tgz"
      tar -xzf "$exe.tgz" --strip-components=2 -C "$BIN_DIR" "pandoc-${ver}/bin/pandoc"
      rm "$exe.tgz"
    else
      fetch_tool "https://github.com/typst/typst/releases/download/v${ver}/typst-${typst_arch}-unknown-linux-musl.tar.xz" "$exe.txz"
      tar -xJf "$exe.txz" --strip-components=1 -C "$BIN_DIR" "typst-${typst_arch}-unknown-linux-musl/typst"
      rm "$exe.txz"
    fi
    chmod +x "$exe"
  fi
  echo "$exe"
}

PANDOC="$(ensure_tool pandoc "$PANDOC_VERSION")"
TYPST="$(ensure_tool typst "$TYPST_VERSION")"
echo "== pandoc: $PANDOC  ($($PANDOC --version | head -1))"
echo "== typst:  $TYPST  ($($TYPST --version))"

# Inject the theme via -V template: pandoc's typst wrapper does
# `#import "<path>": conf` — a project-rooted typst path, so we set
# typst --root to the repo and pass the root-relative file path.
repo_root="$(realpath .)"

# shellcheck disable=SC2086
"$PANDOC" $DOCS_INPUT -f gfm -t typst \
  -o "$OUT_FILE" --pdf-engine=typst \
  --pdf-engine-opt="--root=$repo_root" \
  --shift-heading-level-by=-1 \
  -V template="/${TEMPLATE#$repo_root}" \
  -V title="$DOCS_TITLE" \
  -V subtitle="$DOCS_SUBTITLE" \
  -V date="Elastic Stack $STACK_VERSION — generated $(date +%Y-%m-%d)" \
  -V toc -V toc-depth=2 \
  -V section-numbering=1.1 \
  -V papersize=a4

echo "== wrote $OUT_FILE"
