#!/usr/bin/env bash
# Run the Cinc Auditor smoke tests against the deployed endpoints.
#
#   ./run.sh                     # uses inputs.yml next to this script
#   ./run.sh /path/to/inputs.yml
#   AUDITOR_IMAGE=<ref> ./run.sh # different image/tag
#
# If the auditor image isn't loaded yet, it's loaded from the bundle's
# containers/ dir (sibling of audit/). Any extra args are passed through
# to `cinc-auditor exec` (e.g. --reporter cli junit:report.xml).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${AUDITOR_IMAGE:-cincproject/auditor:7.3.4}"

if [[ "${1:-}" != "" && -f "${1:-}" ]]; then
  INPUTS="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
  shift
else
  INPUTS="$HERE/inputs.yml"
fi

if [[ ! -f "$INPUTS" ]]; then
  echo "error: $INPUTS not found" >&2
  echo "       cp \"$HERE/inputs.example.yml\" \"$HERE/inputs.yml\" and fill it in" >&2
  exit 1
fi

command -v docker >/dev/null || { echo "error: docker not found" >&2; exit 1; }

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  # same name scheme as save_containers.sh: <parent>-<repo>-<tag>
  repo="$(basename "${IMAGE%%:*}")"; tag="${IMAGE##*:}"
  parent="$(basename "$(dirname "$IMAGE")")"
  name="$repo-$tag"; [[ "$parent" != "$repo" ]] && name="$parent-$name"
  tar="$(dirname "$HERE")/containers/$name.tar.gz"
  if [[ -f "$tar" ]]; then
    echo "== loading $IMAGE from $(basename "$tar")"
    gunzip -c "$tar" | docker load
  else
    echo "error: image $IMAGE not loaded and $tar missing" >&2
    echo "       load it first:  gunzip -c <tar> | docker load" >&2
    exit 1
  fi
fi

exec docker run --rm --network host \
  -v "$HERE:/profile:ro" \
  -v "$INPUTS:/inputs.yml:ro" \
  "$IMAGE" exec /profile --no-create-lockfile --input-file /inputs.yml "$@"
