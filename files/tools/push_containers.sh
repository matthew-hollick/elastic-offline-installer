#!/usr/bin/env bash
# Push every dist/containers/<project>/*.tar.gz to a Harbor registry.
#
# Each tar lives in a per-project dir named for its Harbor project; the
# loaded image is retagged flat under it:
#   dist/containers/security/trivy-0.76.2.tar.gz
#     -> harbor.local/security/trivy:0.76.2
#   dist/containers/elastic/elastic-epr-9.5.7.tar.gz   (custom-built)
#     -> harbor.local/elastic/elastic-epr:9.5.7
# Tars directly under dist/containers/ (legacy layout) go to --project.
#
#   HARBOR=harbor.local ./push_containers.sh dist/containers
#   ./push_containers.sh --registry harbor.local --project fallback --user robot\$ci --password-stdin
#
# If the Harbor CA isn't trusted system-wide, configure docker's
# insecure-registries or install the CA — docker push uses the daemon's
# trust store, not this script's flags.
set -euo pipefail

SRC="dist/containers"
REGISTRY="${HARBOR:-}"
PROJECT="${HARBOR_PROJECT:-library}"
USER_="" PASS_="" DRY=""

usage() { grep '^#' "$0" | sed 's/^#//;s/^!.*//' | head -13; exit "${1:-0}"; }

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

push_tar() {
  local tar="$1" project="$2" loaded tag base local_name dest
  # the archive loads under its original upstream name
  loaded="$(gunzip -c "$tar" | docker load 2>&1 | sed -n 's/^Loaded image: //p' | tail -1)"
  [[ -n "$loaded" ]] || { echo "warn: no image name in $(basename "$tar"), skipping" >&2; return; }

  tag="${loaded##*:}"
  base="$(basename "$tar" .tar.gz)"
  local_name="${base%-"$tag"}"   # strip -<tag> suffix -> the LOCAL_NAME it was saved as
  [[ -n "$local_name" && "$local_name" != "$base" ]] \
    || local_name="${base%-latest}"  # last resort for unparseable names
  dest="$REGISTRY/$project/$local_name:$tag"

  echo "== ${project}/$(basename "$tar")"
  echo "   $loaded  ->  $dest"
  if [[ -z "$DRY" ]]; then
    docker tag "$loaded" "$dest"
    docker push "$dest"
  fi
}

# per-project subdirs: dir name IS the Harbor project
for dir in "$SRC"/*/; do
  project="$(basename "$dir")"
  for tar in "$dir"*.tar.gz; do
    push_tar "$tar" "$project"
  done
done
# root-level tars (legacy flat layout) -> --project
for tar in "$SRC"/*.tar.gz; do
  push_tar "$tar" "$PROJECT"
done
echo "== done${DRY:+ (dry-run, nothing pushed)}"
