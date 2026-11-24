#!/usr/bin/env bash
# Build the "distribution" style EPR image (package-registry + all
# downloaded integration packages baked in) using buildah running as a
# container, then export it as a docker-archive tar for the offline side.
set -euo pipefail

STACK_VERSION="${STACK_VERSION:?STACK_VERSION is required}"
CONTAINER_PLATFORM="${CONTAINER_PLATFORM:-linux/amd64}"
EPR_VERSION="${EPR_VERSION:-latest}"
PACKAGES_DIR="$(realpath -m "${PACKAGES_DIR:-dist/epr/packages}")"
OUT_DIR="$(realpath -m "${OUT_DIR:-dist/containers}")"
BUILDAH_IMAGE="${BUILDAH_IMAGE:-quay.io/buildah/stable:latest}"

command -v docker >/dev/null || { echo "error: docker not found (needed to run buildah)" >&2; exit 1; }

shopt -s nullglob
zips=("$PACKAGES_DIR"/*.zip)
((${#zips[@]})) || { echo "error: no packages in $PACKAGES_DIR — run task download:integrations" >&2; exit 1; }

mkdir -p "$OUT_DIR"
tar_name="elastic-epr-${STACK_VERSION}"
# no exists-skip: tar name doesn't reflect changing package contents — always rebuild

if [[ "$EPR_VERSION" == "latest" ]]; then
  EPR_VERSION=$(curl -fsSL https://api.github.com/repos/elastic/package-registry/releases/latest \
    | grep -oP '"tag_name":\s*"\K[^"]+')
fi
BASE_IMAGE="docker.elastic.co/package-registry/package-registry:${EPR_VERSION}"
IMAGE_NAME="elastic-epr:${STACK_VERSION}"

echo "== building $IMAGE_NAME from $BASE_IMAGE + ${#zips[@]} packages ($CONTAINER_PLATFORM)"

# buildah runs in a container; --privileged is required for its userns
# containers. build+push must happen in one invocation since image
# storage lives inside the buildah container.
docker run --rm --privileged -v "$PWD:/work:Z" -v "$OUT_DIR:/out:Z" -w /work "$BUILDAH_IMAGE" \
  sh -c "buildah bud --platform $CONTAINER_PLATFORM \
         --build-arg BASE_IMAGE=$BASE_IMAGE \
         -t $IMAGE_NAME -f files/epr/Containerfile dist/epr \
       && buildah push $IMAGE_NAME docker-archive:/out/$tar_name.tar:$IMAGE_NAME"

gzip -f "$OUT_DIR/$tar_name.tar"
echo "== wrote $OUT_DIR/$tar_name.tar.gz"
echo "   load with: gunzip -c $tar_name.tar.gz | docker load"
