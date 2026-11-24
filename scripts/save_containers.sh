#!/usr/bin/env bash
# Export container images for the offline site.
#
# Fetches are done with skopeo running as a container (quay.io/skopeo/stable),
# writing docker-archive tars that `docker load` can consume. The buildah
# image is exported too, so the buildah/skopeo toolchain itself can be
# loaded and used on the offline side.
set -euo pipefail

STACK_VERSION="${STACK_VERSION:?STACK_VERSION is required}"
SNMP_EXPORTER_VERSION="${SNMP_EXPORTER_VERSION:-v0.31.0}"
CONTAINER_PLATFORM="${CONTAINER_PLATFORM:-linux/amd64}"
OUT_DIR="$(realpath -m "${OUT_DIR:-dist/containers}")"
SKOPEO_IMAGE="${SKOPEO_IMAGE:-quay.io/skopeo/stable:latest}"
BUILDAH_IMAGE="${BUILDAH_IMAGE:-quay.io/buildah/stable:latest}"

command -v docker >/dev/null || { echo "error: docker not found (needed to run skopeo)" >&2; exit 1; }
mkdir -p "$OUT_DIR"

# Payload images plus the tool images themselves.
images=(
  "docker.elastic.co/elastic-agent/elastic-agent:${STACK_VERSION}"
  "docker.elastic.co/logstash/logstash:${STACK_VERSION}"
  "docker.elastic.co/elastic-maps-service/elastic-maps-server-ubi:${STACK_VERSION}"
  "prom/snmp-exporter:${SNMP_EXPORTER_VERSION}"
  "$SKOPEO_IMAGE"
  "$BUILDAH_IMAGE"
)

echo "== pulling skopeo tool image"
docker pull --quiet "$SKOPEO_IMAGE" >/dev/null

os="${CONTAINER_PLATFORM%%/*}"
arch="${CONTAINER_PLATFORM##*/}"

for img in "${images[@]}"; do
  # name the tar <repo>-<tag>; prefix the repo dir when the basename
  # alone is ambiguous (e.g. quay.io/{skopeo,buildah}/stable:latest)
  repo="$(basename "${img%%:*}")"
  tag="${img##*:}"
  name="$repo-$tag"
  parent="$(basename "$(dirname "$img")")"
  [[ "$parent" != "$repo" ]] && name="$parent-$name"
  if [[ -f "$OUT_DIR/$name.tar.gz" ]]; then
    echo "exists: $name.tar.gz"
    continue
  fi
  echo "exporting: $img"
  docker run --rm -v "$OUT_DIR:/out:Z" "$SKOPEO_IMAGE" \
    copy --quiet --override-os "$os" --override-arch "$arch" \
    "docker://$img" "docker-archive:/out/$name.tar:$img"
  # gzip to .part and rename so a kill mid-gzip can't leave a truncated
  # tar.gz that the exists-check would skip forever
  gzip -c "$OUT_DIR/$name.tar" > "$OUT_DIR/$name.tar.gz.part" \
    && mv "$OUT_DIR/$name.tar.gz.part" "$OUT_DIR/$name.tar.gz"
  rm -f "$OUT_DIR/$name.tar"
done

echo "== done. Load on the target with: gunzip -c <file>.tar.gz | docker load"
