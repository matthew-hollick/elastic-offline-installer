#!/usr/bin/env bash
# Push every dist/containers/*.tar.gz to a Harbor registry.
#
# Each docker-archive loads under its original upstream ref; it's then
# retagged to <registry>/<project>/<repo-path-minus-registry-host>:<tag>:
#   docker.elastic.co/elastic-agent/elastic-agent:9.5.7
#     -> harbor.local/library/elastic-agent/elastic-agent:9.5.7
#   aquasec/trivy:0.76.2      -> harbor.local/library/aquasec/trivy:0.76.2
# Harbor allows nested repository names, so upstream provenance is kept.
#
#   HARBOR=harbor.local HARBOR_PROJECT=elastic ./push_containers.sh dist/containers
#   ./push_containers.sh --registry harbor.local --project elastic --user robot\$ci --password-stdin
#
# If the Harbor CA isn't trusted system-wide, configure docker's
# insecure-registries or install the CA — docker push uses the daemon's
# trust store, not this script's flags.
set -euo pipefail

SRC="dist/containers"
REGISTRY="${HARBOR:-}"
PROJECT="${HARBOR_PROJECT:-library}"
USER_="" PASS_="" DRY=""

usage() { grep '^#' "$0" | sed 's/^#//;s/^!.*//' | head -12; exit "${1:-0}"; }

while (($#)); do case "$1" in
  -r|--registry) REGISTRY="$2"; shift 2;;
  -p|--project)  PROJECT="$2";  shift 2;;
  -u|--user)     USER_="$2";    shift 2;;
  -P|--password) PASS_="$2";    shift 2;;
  --password-stdin) PASS_="$(cat)"; shift;;
  -n|--dry-run)  DRY=1; shift;;
  -h|--help)     usage;;
  -*)            echo "unknown flag $1" >&2; usage 1;;
  *)             SRC="$1"; shift;;
esac; done

[[ -n "$REGISTRY" ]] || { echo "error: --registry or HARBOR required" >&2; exit 1; }
[[ -d "$SRC" ]] || { echo "error: $SRC not found — run 'task download:containers' first" >&2; exit 1; }
command -v docker >/dev/null || { echo "error: docker not found" >&2; exit 1; }
shopt -s nullglob

if [[ -n "$USER_" ]]; then
  echo "$PASS_" | docker login "$REGISTRY" -u "$USER_" --password-stdin
fi

for tar in "$SRC"/*.tar.gz; do
  # the archive loads under its original upstream name
  loaded="$(gunzip -c "$tar" | docker load 2>&1 | sed -n 's/^Loaded image: //p' | tail -1)"
  [[ -n "$loaded" ]] || { echo "warn: no image name in $(basename "$tar"), skipping" >&2; continue; }

  # strip the registry host (first path component with a . or :) if present
  first="${loaded%%/*}"
  if [[ "$first" == *.* || "$first" == *:* || "$first" == localhost ]]; then
    path="${loaded#*/}"
  else
    path="$loaded"   # docker.io short name — keep repo path as-is
  fi
  dest="$REGISTRY/$PROJECT/$path"

  echo "== $(basename "$tar")"
  echo "   $loaded  ->  $dest"
  if [[ -z "$DRY" ]]; then
    docker tag "$loaded" "$dest"
    docker push "$dest"
  fi
done
echo "== done${DRY:+ (dry-run, nothing pushed)}"
