#!/usr/bin/env bash
# Download Elastic stack artifacts into a canonical mirror of the two
# Elastic artifact services, so the output directory can be served
# directly as the Elastic Artifact Registry (the Fleet "agent binary
# download source") and the Endpoint Artifact Repository (Elastic Defend
# client-side detection artifacts).
#
# Layout produced — URI paths preserved 1:1 from upstream:
#   <OUT_DIR>/downloads/elasticsearch/elasticsearch-<v>-<arch>.deb
#   <OUT_DIR>/downloads/beats/elastic-agent/elastic-agent-<v>-linux-x86_64.tar.gz
#   <OUT_DIR>/downloads/fleet-server/fleet-server-<v>-windows-x86_64.zip
#   ... every file accompanied by .sha512 and .asc
#   <OUT_DIR>/downloads/endpoint/...  Elastic Defend artifacts (see below)
#   <OUT_DIR>/GPG-KEY-elasticsearch   (mirrors artifacts.elastic.co/GPG-KEY-elasticsearch)
#   <OUT_DIR>/geoip/, <OUT_DIR>/models/   custom mirrors, see sections below
#
# Fleet's agent-binary download source then points at
#   <scheme>://<ear-host>/downloads/
# and the Elastic Defend advanced setting
#   advanced.artifacts.global.base_url (per-OS variants)
# points at <scheme>://<ear-host>.
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
  local url="$1" dest="$2" attempt
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" ]]; then
    echo "  exists: ${dest#$OUT_DIR/}"
    return
  fi
  echo "  downloading: $(basename "$dest")"
  # -C - resumes the .part across attempts; --retry-all-errors covers
  # CURLE_RECV_ERROR (56) which --retry alone doesn't retry on
  for attempt in 1 2 3 4 5; do
    if curl -fsSL -C - --retry 2 --retry-all-errors --connect-timeout 30 \
         -o "$dest.part" "$url"; then
      mv "$dest.part" "$dest"
      return
    fi
    echo "  attempt $attempt/5 failed ($(basename "$dest")); retrying" >&2
    sleep "$((attempt * 3))"
  done
  rm -f "$dest.part"
  echo "error: download failed: $url" >&2
  return 1
}

download() {
  local path="$1"
  fetch "$BASE/$path"        "$OUT_DIR/downloads/$path"
  fetch "$BASE/$path.sha512" "$OUT_DIR/downloads/$path.sha512"
  fetch "$BASE/$path.asc"    "$OUT_DIR/downloads/$path.asc"
}

echo "== stack $STACK_VERSION, target arch $TARGET_ARCH -> $OUT_DIR"

for p in "${LINUX_PREFIXES[@]}";   do download "$p-${STACK_VERSION}-linux-${TAR_ARCH}.tar.gz"; done
for p in "${WINDOWS_PREFIXES[@]}"; do download "$p-${STACK_VERSION}-windows-x86_64.zip"; done
for p in "${DEB_PREFIXES[@]}";     do download "$p-${STACK_VERSION}-${TARGET_ARCH}.deb"; done

# Elastic's release signing key — lets the offline side verify the .asc
# signatures carried alongside every artifact.
fetch "https://artifacts.elastic.co/GPG-KEY-elasticsearch" "$OUT_DIR/GPG-KEY-elasticsearch"

# Elastic Defend client-side artifacts — detection signatures, behavioral
# models, blocklists/exception lists etc. ("fingerprints" the endpoint
# agent updates continuously). These live on a separate service
# (artifacts.security.elastic.co), discovered through a versioned manifest
# zip: downloads/endpoint/manifest/artifacts-<stack-version>.zip lists
# content-addressed encrypted blobs whose filename is the sha256 of the
# stored content — the filename is the checksum.
echo "== endpoint artifacts (artifacts.security.elastic.co)"
command -v unzip >/dev/null || { echo "error: 'unzip' not found" >&2; exit 1; }
ep_base="https://artifacts.security.elastic.co"
mzip="$OUT_DIR/downloads/endpoint/manifest/artifacts-${STACK_VERSION}.zip"
fetch "$ep_base/downloads/endpoint/manifest/artifacts-${STACK_VERSION}.zip" "$mzip"
while read -r rel; do
  dest="$OUT_DIR$rel"
  fetch "$ep_base$rel" "$dest"
  echo "$(basename "$dest")  $dest" | sha256sum -c - >/dev/null \
    || { echo "error: sha256 mismatch on $rel" >&2; rm -f "$dest"; exit 1; }
done < <(unzip -p "$mzip" manifest.json | python3 -c '
import json, sys
for a in json.load(sys.stdin)["artifacts"].values():
    print(a["relative_url"])
')

# GeoIP databases. Elasticsearch's geoip downloader polls a JSON manifest
# (ingest.geoip.downloader.endpoint); air-gapped clusters need a mirror.
# The upstream manifest's `url` fields are short-lived signed R2 URLs, so
# we fetch the .tgz files now and rewrite the manifest to point at the EAR
# (host left as __EAR_BASE_URL__ — sed scheme+host in at deploy time).
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
    e["url"] = "__EAR_BASE_URL__/geoip/" + e["name"]
print(json.dumps(es, indent=1))
' > "$geo_dir/database.json"
echo "  wrote geoip/database.json (rewrite __EAR_BASE_URL__ at deploy)"

echo "== verifying sha512 checksums"
cd "$OUT_DIR"
find . -name '*.sha512' -execdir sha512sum -c {} +
echo "== all artifacts verified in $OUT_DIR"
