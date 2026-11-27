#!/usr/bin/env bash
# Build the Elastic documentation site with Elastic's own docs-builder, run in
# a container (files/docs/Containerfile — the released linux/amd64 AOT binary,
# no source build, no .NET SDK).
#
#   ./scripts/build_docs.sh             # image, clone, build, sync to OUT_DIR
#   DOCS_CLONE=0 ./scripts/build_docs.sh  # reuse existing checkouts (fast loop)
#
# linux/amd64 hosts only — Elastic publishes no arm64 binary and the x64 one
# segfaults under qemu-user. Intended host: WSL2 on the Windows server.
#
# Flow (mirrors upstream dev.sh): `assembler config init` fetches the central
# repo list, `assembler clone` pulls the content repositories into
# $TMPDIR/elastic/docs-builder/checkouts (we point TMPDIR into WORK_DIR so
# checkouts persist — re-runs fetch only changed refs), then `assembler build`
# emits the site under <workdir>/.artifacts/ which we sync into OUT_DIR. The
# `--environment air-gapped` target sets upstream's AIR_GAPPED feature flag —
# the same profile they use for disconnected builds (no indexing/search hooks).
#
# Private repos are skipped by default (DOCKER-style flag
# --skip-private-repositories). If GITHUB_TOKEN is set it is used for the
# git@->https rewrite instead, so private repos clone too.
#
# Env knobs:
#   DOCS_BUILDER_VERSION  tool/image tag (default 1.84.0 — keep pinned)
#   DOCS_ENVIRONMENT      assembler.yml environment (default air-gapped)
#   DOCS_IMAGE            image name override
#   DOCS_CLONE            0 to skip the clone phase (default 1)
#   SKIP_PRIVATE          0 to allow private repos (needs GITHUB_TOKEN; default 1)
#   GITHUB_TOKEN          optional — lets private repos clone over https
#   WORK_DIR              clone/build state (default .build/docs-work)
#   OUT_DIR               final site root (default dist/ear)
set -euo pipefail

DOCS_BUILDER_VERSION="${DOCS_BUILDER_VERSION:-1.84.0}"
DOCS_ENVIRONMENT="${DOCS_ENVIRONMENT:-air-gapped}"
DOCS_IMAGE="${DOCS_IMAGE:-docs-builder-offline:$DOCS_BUILDER_VERSION}"
DOCS_CLONE="${DOCS_CLONE:-1}"
SKIP_PRIVATE="${SKIP_PRIVATE:-1}"
WORK_DIR="$(realpath -m "${WORK_DIR:-.build/docs-work}")"
OUT_DIR="$(realpath -m "${OUT_DIR:-dist/ear}")"
CONTAINERFILE="$(dirname "$(realpath "$0")")/../files/docs/Containerfile"

# The released binary is x86_64 only; it crashes under qemu-user emulation.
[[ "$(uname -m)" == "x86_64" ]] || {
  echo "error: docs-builder is amd64-only (host is $(uname -m) — run on the WSL/Windows box)" >&2
  exit 1
}
command -v docker >/dev/null || { echo "error: docker not found" >&2; exit 1; }
mkdir -p "$WORK_DIR" "$OUT_DIR"

if ! docker image inspect "$DOCS_IMAGE" >/dev/null 2>&1; then
  echo "== building $DOCS_IMAGE (docs-builder $DOCS_BUILDER_VERSION, linux/amd64)"
  docker build --platform linux/amd64 \
    --build-arg "DOCS_BUILDER_VERSION=$DOCS_BUILDER_VERSION" \
    -t "$DOCS_IMAGE" -f "$CONTAINERFILE" "$(dirname "$CONTAINERFILE")"
fi

# git origins are git@github.com: — rewrite to https (with token if provided),
# the same trick upstream's dev.sh uses; the image has no ssh client.
token="${GITHUB_TOKEN:-}"
git_env=(
  -e GIT_CONFIG_COUNT=1
  -e "GIT_CONFIG_KEY_0=url.https://${token:+oauth2:$token@}github.com/.insteadOf"
  -e "GIT_CONFIG_VALUE_0=git@github.com:"
)

run() {
  # The tool roots its app data under the temp dir (config clone, repo
  # checkouts) — TMPDIR=/work/tmp persists all of it across runs so clones
  # are incremental. Build output goes to <cwd>/.artifacts (also /work).
  docker run --rm --platform linux/amd64 \
    --user "$(id -u):$(id -g)" -e HOME=/work -e TMPDIR=/work/tmp "${git_env[@]}" \
    -v "$WORK_DIR:/work" -w /work \
    "$DOCS_IMAGE" "$@"
}

extra=()
[[ "$SKIP_PRIVATE" == "1" ]] && extra+=(--skip-private-repositories)

echo "== docs-builder assembler config init (fetch central repo list)"
run assembler config init "${extra[@]}"

if [[ "$DOCS_CLONE" == "1" ]]; then
  echo "== docs-builder assembler clone --environment $DOCS_ENVIRONMENT"
  run assembler clone --environment "$DOCS_ENVIRONMENT" "${extra[@]}"
fi

echo "== docs-builder assembler build --environment $DOCS_ENVIRONMENT"
run assembler build --environment "$DOCS_ENVIRONMENT" "${extra[@]}"

# output dir name differs across releases (.artifacts/docs per --help;
# .artifacts/assembly in some versions) — accept whichever exists.
assembly=""
for d in "$WORK_DIR/.artifacts/docs" "$WORK_DIR/.artifacts/assembly"; do
  [[ -d "$d" ]] && assembly="$d" && break
done
[[ -n "$assembly" ]] || { echo "error: no build output under $WORK_DIR/.artifacts/" >&2; exit 1; }
[[ -d "$assembly/docs" ]] || echo "warn: expected a docs/ path-prefix dir in the assembly output — layout may need checking"

echo "== syncing site -> $OUT_DIR"
cp -a "$assembly/." "$OUT_DIR/"
echo "== done. Serve dist/ear as www.elastic.co to make the doc links resolve."
