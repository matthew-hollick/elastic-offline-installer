#!/usr/bin/env bash
# Download support tooling for the offline site into dist/tools/:
#  - Elastic support-diagnostics (the tool Elastic Support asks for when
#    capturing full cluster/platform state — unzip on a node and run
#    support-diagnostics.sh)
#  - a Temurin JRE tarball (support-diagnostics is a Java tool; ES nodes
#    have a bundled JDK, this covers hosts that don't)
#  - the elastic-package CLI for linux/amd64, so custom integrations can
#    also be built inside the offline environment
set -euo pipefail

DIAG_VERSION="${DIAG_VERSION:-latest}"
JRE_FEATURE="${JRE_FEATURE:-21}"            # Temurin LTS feature version
ELASTIC_PACKAGE_VERSION="${ELASTIC_PACKAGE_VERSION:-latest}"
OUT_DIR="$(realpath -m "${OUT_DIR:-dist/tools}")"

mkdir -p "$OUT_DIR"

if [[ "$DIAG_VERSION" == "latest" ]]; then
  DIAG_VERSION=$(curl -fsSL https://api.github.com/repos/elastic/support-diagnostics/releases/latest \
    | grep -oP '"tag_name":\s*"\K[^"]+')
fi
ver="${DIAG_VERSION#v}"
echo "== support-diagnostics $DIAG_VERSION"

zip="diagnostics-${ver}-dist.zip"
base="https://github.com/elastic/support-diagnostics/releases/download/${DIAG_VERSION}"

if [[ -f "$OUT_DIR/$zip" ]]; then
  echo "  exists: $zip"
else
  curl -fsSL --retry 3 -o "$OUT_DIR/$zip.part" "$base/$zip"
  mv "$OUT_DIR/$zip.part" "$OUT_DIR/$zip"
fi
curl -fsSL --retry 3 -o "$OUT_DIR/$zip.sha256" "$base/$zip.sha256"

echo "== verifying sha256"
(cd "$OUT_DIR" && sha256sum -c "$zip.sha256")

# --- Temurin JRE for the target (linux/x64) -------------------------------
# Resolve the latest asset + its sha256 via the Adoptium API.
echo "== temurin JRE $JRE_FEATURE (linux/x64)"
asset=$(curl -fsSL "https://api.adoptium.net/v3/assets/latest/${JRE_FEATURE}/hotspot?architecture=x64&heap_size=normal&image_type=jre&os=linux&vendor=eclipse")
read -r jre_name jre_link jre_sum < <(echo "$asset" | python3 -c '
import json, sys
p = json.load(sys.stdin)[0]["binary"]["package"]
print(p["name"], p["link"], p["checksum"])
')
if [[ -f "$OUT_DIR/$jre_name" ]]; then
  echo "  exists: $jre_name"
else
  curl -fsSL --retry 3 -o "$OUT_DIR/$jre_name.part" "$jre_link"
  mv "$OUT_DIR/$jre_name.part" "$OUT_DIR/$jre_name"
fi
echo "$jre_sum  $OUT_DIR/$jre_name" | sha256sum -c -

# --- elastic-package CLI for the target (linux/amd64) ---------------------
# Lets custom integrations be built on the offline side too.
if [[ "$ELASTIC_PACKAGE_VERSION" == "latest" ]]; then
  ELASTIC_PACKAGE_VERSION=$(curl -fsSL https://api.github.com/repos/elastic/elastic-package/releases/latest \
    | grep -oP '"tag_name":\s*"\K[^"]+')
fi
epver="${ELASTIC_PACKAGE_VERSION#v}"
epbase="https://github.com/elastic/elastic-package/releases/download/${ELASTIC_PACKAGE_VERSION}"
eptar="elastic-package_${epver}_linux_amd64.tar.gz"
echo "== elastic-package $ELASTIC_PACKAGE_VERSION (linux/amd64)"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 3 -o "$tmp/$eptar" "$epbase/$eptar"
curl -fsSL --retry 3 -o "$tmp/checksums.txt" "$epbase/elastic-package_${epver}_checksums.txt"
line=$(grep "  $eptar\$" "$tmp/checksums.txt")
case "$(awk '{print length($1)}' <<<"$line")" in
  64)  sum=sha256sum ;;
  128) sum=sha512sum ;;
  *) echo "error: unexpected checksum format" >&2; exit 1 ;;
esac
(cd "$tmp" && echo "$line" | $sum -c -)
tar -xzf "$tmp/$eptar" -C "$OUT_DIR" elastic-package
chmod +x "$OUT_DIR/elastic-package"

# --- deploy-side helper scripts --------------------------------------------
# import_cvelist.py bulk-loads the mirrored cvelistV5 corpus (feeds/cve/) into
# an ES index for offline CVE lookup and enrich.
install -m 0755 files/tools/import_cvelist.py "$OUT_DIR/import_cvelist.py"
echo "== copied import_cvelist.py"
