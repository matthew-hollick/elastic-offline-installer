#!/usr/bin/env bash
# Download Elastic stack artifacts into the canonical
# artifacts.elastic.co/downloads/ layout so the output directory can be
# served directly as the Elastic Artifact Registry (the Fleet "agent
# binary download source" and endpoint artifact repository).
#
# Layout produced:
#   <OUT_DIR>/elasticsearch/elasticsearch-<v>-<arch>.deb
#   <OUT_DIR>/kibana/kibana-<v>-<arch>.deb
#   <OUT_DIR>/beats/elastic-agent/elastic-agent-<v>-linux-x86_64.tar.gz
#   <OUT_DIR>/fleet-server/fleet-server-<v>-windows-x86_64.zip
#   ... every file accompanied by .sha512 and .asc
#
# The prefix list follows Elastic's own air-gapped reference script:
# https://www.elastic.co/docs/deploy-manage/deploy/self-managed/air-gapped-install
set -euo pipefail

STACK_VERSION="${STACK_VERSION:?STACK_VERSION is required}"
TARGET_ARCH="${TARGET_ARCH:-amd64}"   # deb arch of the target servers
OUT_DIR="${OUT_DIR:-dist/ear}"
BASE="https://artifacts.elastic.co/downloads"

# Elastic uses different arch suffixes for debs vs tarballs.
case "$TARGET_ARCH" in
  amd64) TAR_ARCH="x86_64" ;;
  arm64) TAR_ARCH="arm64" ;;
  *) echo "error: unsupported TARGET_ARCH '$TARGET_ARCH' (amd64|arm64)" >&2; exit 1 ;;
esac

# Agent-downloadable components (needed at runtime for integrations,
# agent self-upgrades and Elastic Defend — not just for installation).
LINUX_PREFIXES=(
  apm-server/apm-server
  beats/auditbeat/auditbeat
  beats/elastic-agent/elastic-agent
  beats/filebeat/filebeat
  beats/heartbeat/heartbeat
  beats/metricbeat/metricbeat
  beats/osquerybeat/osquerybeat
  beats/packetbeat/packetbeat
  cloudbeat/cloudbeat
  endpoint-dev/endpoint-security
  fleet-server/fleet-server
)
# Windows components. cloudbeat is linux-only (404s on windows builds);
# winlogbeat is windows-only. Verified against artifacts.elastic.co.
WINDOWS_PREFIXES=(
  apm-server/apm-server
  beats/auditbeat/auditbeat
  beats/elastic-agent/elastic-agent
  beats/filebeat/filebeat
  beats/heartbeat/heartbeat
  beats/metricbeat/metricbeat
  beats/osquerybeat/osquerybeat
  beats/packetbeat/packetbeat
  beats/winlogbeat/winlogbeat
  endpoint-dev/endpoint-security
  fleet-server/fleet-server
)

# .deb packages for the Ubuntu servers themselves.
DEB_PREFIXES=(
  elasticsearch/elasticsearch
  kibana/kibana
  beats/elastic-agent/elastic-agent
  logstash/logstash
)

fetch() {
  local url="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" ]]; then
    echo "  exists: ${dest#$OUT_DIR/}"
  else
    echo "  downloading: $(basename "$dest")"
    curl -fsSL --retry 3 -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
  fi
}

download() {
  local path="$1"
  fetch "$BASE/$path"        "$OUT_DIR/$path"
  fetch "$BASE/$path.sha512" "$OUT_DIR/$path.sha512"
  fetch "$BASE/$path.asc"    "$OUT_DIR/$path.asc"
}

echo "== stack $STACK_VERSION, target arch $TARGET_ARCH -> $OUT_DIR"

for p in "${LINUX_PREFIXES[@]}";   do download "$p-${STACK_VERSION}-linux-${TAR_ARCH}.tar.gz"; done
for p in "${WINDOWS_PREFIXES[@]}"; do download "$p-${STACK_VERSION}-windows-x86_64.zip"; done
for p in "${DEB_PREFIXES[@]}";     do download "$p-${STACK_VERSION}-${TARGET_ARCH}.deb"; done

# Elastic's release signing key — lets the offline side verify the .asc
# signatures carried alongside every artifact.
fetch "https://artifacts.elastic.co/GPG-KEY-elasticsearch" "$OUT_DIR/GPG-KEY-elasticsearch"

# GeoIP databases. Elasticsearch's geoip downloader polls a JSON manifest
# (ingest.geoip.downloader.endpoint); air-gapped clusters need a mirror.
# The upstream manifest's `url` fields are short-lived signed R2 URLs, so
# we fetch the .tgz files now and rewrite the manifest to point at the EAR
# (host left as __EAR_HOST__ — sed it at deploy time).
echo "== geoip databases"
geo_dir="$OUT_DIR/geoip"
mkdir -p "$geo_dir"
manifest=$(curl -fsSL --retry 3 "https://geoip.elastic.co/v1/database?elastic_geoip_service_tos=agree")
while IFS=$'\t' read -r name url md5; do
  fetch "$url" "$geo_dir/$name"
  echo "$md5  $geo_dir/$name" | md5sum -c - >/dev/null \
    || { echo "error: md5 mismatch on $name" >&2; rm -f "$geo_dir/$name"; exit 1; }
done < <(echo "$manifest" | python3 -c '
import json, sys
for e in json.load(sys.stdin):
    if e["name"].endswith(".tgz"):      # ES consumes .tgz; skip the bulky CSV zips
        print(e["name"], e["url"], e["md5_hash"], sep="\t")
')
echo "$manifest" | python3 -c '
import json, sys
es = [e for e in json.load(sys.stdin) if e["name"].endswith(".tgz")]
for e in es:
    e["url"] = "https://__EAR_HOST__/geoip/" + e["name"]
print(json.dumps(es, indent=1))
' > "$geo_dir/database.json"
echo "  wrote geoip/database.json (rewrite __EAR_HOST__ at deploy)"

echo "== verifying sha512 checksums"
cd "$OUT_DIR"
find . -name '*.sha512' -execdir sha512sum -c {} +
echo "== all artifacts verified in $OUT_DIR"
