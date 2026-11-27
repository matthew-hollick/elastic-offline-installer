#!/usr/bin/env bash
# Export the managed container set for the offline site.
#
# CONTAINERS is a newline-separated list of 4-tuples (see the Taskfile var):
#   <project>:<local-name>:<upstream-ref>:<tag>
#     project     -> dist/containers/<project>/ AND the Harbor project on push
#     local-name  -> file <local>-<tag>.tar.gz AND the Harbor repo name
#     upstream-ref-> registry/repo/path (no tag)
#     tag         -> literal tag
#
# skopeo (running as a container) does the pulling and emits docker-archive
# tars `docker load` can consume. The tool image itself can't pull itself, so
# it's fetched with a plain `docker pull` bootstrap first. Custom-built images
# (elastic-epr) land in the same per-project dirs via
# download:containers:custom:* tasks.
#
# Files <local>-<tag>.tar.gz under OUT_DIR/<project>/ are skipped, so re-runs
# only fetch what's missing. CONTAINER_PLATFORM selects the bundle arch.
set -euo pipefail

OUT_DIR="$(realpath -m "${OUT_DIR:-dist/containers}")"
CONTAINERS="${CONTAINERS:?CONTAINERS is required (PROJECT:LOCAL:UPSTREAM:TAG per line)}"
CONTAINER_PLATFORM="${CONTAINER_PLATFORM:-linux/amd64}"
SKOPEO_IMAGE="${SKOPEO_IMAGE:-quay.io/skopeo/stable:latest}"

command -v docker >/dev/null || { echo "error: docker not found (needed to run skopeo)" >&2; exit 1; }
mkdir -p "$OUT_DIR"

echo "== pulling skopeo tool image: $SKOPEO_IMAGE"
docker pull --quiet "$SKOPEO_IMAGE" >/dev/null

os="${CONTAINER_PLATFORM%%/*}"
arch="${CONTAINER_PLATFORM##*/}"

while IFS= read -r line; do
  line="${line%%#*}"; line="${line//[[:space:]]/}"
  [[ -z "$line" ]] && continue
  # 4-tuple: project = 1st field, local = 2nd, tag = last, upstream = middle
  # (upstream may itself contain ':' if the registry carries a port).
  tag="${line##*:}"; rest="${line%:*}"
  project="${rest%%:*}"; rest="${rest#*:}"
  local_name="${rest%%:*}"; upstream="${rest#*:}"
  img="$upstream:$tag"

  dest_dir="$OUT_DIR/$project"
  mkdir -p "$dest_dir"
  name="$local_name-$tag"
  if [[ -f "$dest_dir/$name.tar.gz" ]]; then
    echo "exists: $project/$name.tar.gz"
    continue
  fi
  echo "exporting: $img -> $project/$name.tar.gz"
  rm -f "$dest_dir/$name.tar"
  docker run --rm -v "$dest_dir:/out:Z" "$SKOPEO_IMAGE" \
    copy --quiet --retry-times 3 --override-os "$os" --override-arch "$arch" \
    "docker://$img" "docker-archive:/out/$name.tar:$img"
  gzip -c "$dest_dir/$name.tar" > "$dest_dir/$name.tar.gz.part" \
    && mv "$dest_dir/$name.tar.gz.part" "$dest_dir/$name.tar.gz"
  rm -f "$dest_dir/$name.tar"
done <<< "$CONTAINERS"

echo "== done. Load on the target with: gunzip -c <file>.tar.gz | docker load"
