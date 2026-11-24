#!/usr/bin/env bash
# Build a custom Elastic integration from a git repo into a package zip
# that the EPR can serve.
#
#   build_integration.sh <git-url> [package-subdir] [git-ref]
#
# e.g.: ./scripts/build_integration.sh \
#         https://github.com/FortytwoM/elastic-nessus-integration nessus
#
# Uses the elastic-package CLI (downloaded once into .build/tools).
# The resulting unsigned zip lands in OUT_DIR; serving it requires the
# registry to run with -require-package-signatures=false (set in
# epr.service) since only Elastic can sign packages.
set -euo pipefail

REPO_URL="${1:?usage: $0 <git-url> [package-subdir] [git-ref]}"
SUBDIR="${2:-}"
GIT_REF="${3:-}"

ELASTIC_PACKAGE_VERSION="${ELASTIC_PACKAGE_VERSION:-latest}"
OUT_DIR="$(realpath -m "${OUT_DIR:-dist/epr/packages}")"
BUILD_DIR="$(realpath -m "${BUILD_DIR:-.build}")"
TOOLS_DIR="$BUILD_DIR/tools"
KIBANA_CONSTRAINT="${KIBANA_CONSTRAINT:-}"   # e.g. '^8.13.0 || ^9.0.0' to patch manifest

for tool in git curl tar; do
  command -v "$tool" >/dev/null || { echo "error: '$tool' not found" >&2; exit 1; }
done

# --- 1. elastic-package binary (cached in .build/tools) -------------------
case "$(uname -m)" in
  x86_64)         GO_ARCH="amd64" ;;
  aarch64|arm64)  GO_ARCH="arm64" ;;
  *) echo "error: unsupported host arch '$(uname -m)'" >&2; exit 1 ;;
esac

ep="$TOOLS_DIR/elastic-package"
if [[ ! -x "$ep" ]]; then
  if [[ "$ELASTIC_PACKAGE_VERSION" == "latest" ]]; then
    ELASTIC_PACKAGE_VERSION=$(curl -fsSL https://api.github.com/repos/elastic/elastic-package/releases/latest \
      | grep -oP '"tag_name":\s*"\K[^"]+')
  fi
  ver="${ELASTIC_PACKAGE_VERSION#v}"
  echo "== fetching elastic-package $ELASTIC_PACKAGE_VERSION (linux/$GO_ARCH)"

  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  base="https://github.com/elastic/elastic-package/releases/download/${ELASTIC_PACKAGE_VERSION}"
  tarball="elastic-package_${ver}_linux_${GO_ARCH}.tar.gz"
  curl -fsSL --retry 3 -o "$tmp/$tarball" "$base/$tarball"
  curl -fsSL --retry 3 -o "$tmp/checksums.txt" "$base/elastic-package_${ver}_checksums.txt"
  line=$(grep "  $tarball\$" "$tmp/checksums.txt")
  hashlen=$(echo "$line" | awk '{print length($1)}')
  case "$hashlen" in
    64)  sum=sha256sum ;;
    128) sum=sha512sum ;;
    *) echo "error: unexpected checksum format" >&2; exit 1 ;;
  esac
  (cd "$tmp" && echo "$line" | $sum -c -)

  mkdir -p "$TOOLS_DIR"
  tar -xzf "$tmp/$tarball" -C "$TOOLS_DIR" elastic-package
  chmod +x "$ep"
fi
echo "== elastic-package: $("$ep" version 2>/dev/null || echo unknown)"

# --- 2. clone the integration source --------------------------------------
name="$(basename "$REPO_URL" .git)"
src="$BUILD_DIR/integrations/$name"
if [[ -d "$src/.git" ]]; then
  echo "== reusing clone at $src"
else
  echo "== cloning $REPO_URL${GIT_REF:+ @$GIT_REF}"
  git clone --depth 1 ${GIT_REF:+--branch "$GIT_REF"} "$REPO_URL" "$src"
fi

pkgdir="$src${SUBDIR:+/$SUBDIR}"
[[ -f "$pkgdir/manifest.yml" ]] || { echo "error: no manifest.yml in $pkgdir" >&2; exit 1; }

# Optional: relax the declared kibana.version constraint (e.g. to allow 9.x).
if [[ -n "$KIBANA_CONSTRAINT" ]]; then
  echo "== patching kibana.version constraint -> $KIBANA_CONSTRAINT"
  sed -i -E "s#^([[:space:]]+version:[[:space:]]*['\"]?)[^'\"]+#\1${KIBANA_CONSTRAINT}#" "$pkgdir/manifest.yml"
fi

# --- 3. build the package zip ---------------------------------------------
echo "== building package in ${pkgdir#$src/}"
if ! (cd "$pkgdir" && "$ep" build); then
  echo "== strict build failed — retrying with --skip-validation"
  echo "   (community packages often fail package-spec validation;"
  echo "    the EPR may also need -disable-package-validation)"
  (cd "$pkgdir" && "$ep" build --skip-validation)
fi

# elastic-package writes build/packages under the repo root, not the package dir
zip_path=$(find "$src" -path '*/build/packages/*.zip' -type f -printf '%T@ %p\n' \
  | sort -nr | head -1 | cut -d' ' -f2-)
[[ -n "$zip_path" ]] || { echo "error: build produced no zip" >&2; exit 1; }

mkdir -p "$OUT_DIR"
cp "$zip_path" "$OUT_DIR/"
echo "== wrote $OUT_DIR/$(basename "$zip_path")"
echo "   note: unsigned package — EPR must run with -require-package-signatures=false"
