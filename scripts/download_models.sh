#!/usr/bin/env bash
# Download ML trained-model artifacts into dist/ear/models/ so the EAR can
# serve them as the xpack.ml.model_repository for an air-gapped cluster
# (Elastic's documented alternative to ml-models.elastic.co).
#
# Each model is three files: <id>.metadata.json, <id>.pt, <id>.vocab.json.
# The .pt is sha256-verified against the metadata manifest.
#
#   ML_MODELS="elser_model_2_linux-x86_64 rerank-v1" ./scripts/download_models.sh
#
# Available models (verified against ml-models.elastic.co):
#   elser_model_2_linux-x86_64        ~275 MB  ELSER v2, Intel-optimized
#   elser_model_2                    ~438 MB  ELSER v2, cross-platform (arm too)
#   multilingual-e5-small_linux-x86_64 ~423 MB  non-English dense embeddings
#   multilingual-e5-small            ~482 MB  cross-platform
#   rerank-v1                        ~777 MB  Elastic reranker
set -euo pipefail

ML_MODELS="${ML_MODELS:-elser_model_2_linux-x86_64}"
OUT_DIR="$(realpath -m "${OUT_DIR:-dist/ear/models}")"
BASE="https://ml-models.elastic.co"

mkdir -p "$OUT_DIR"

for model in $ML_MODELS; do
  echo "== $model"
  for ext in metadata.json vocab.json pt; do
    dest="$OUT_DIR/$model.$ext"
    if [[ -f "$dest" ]]; then
      echo "  exists: $model.$ext"
    else
      echo "  downloading: $model.$ext"
      curl -fsSL --retry 3 -o "$dest.part" "$BASE/$model.$ext"
      mv "$dest.part" "$dest"
    fi
  done

  # verify the model weights against the sha256 published in the manifest
  sha=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["sha256"])' \
        < "$OUT_DIR/$model.metadata.json")
  echo "$sha  $OUT_DIR/$model.pt" | sha256sum -c -
done

echo "== done. Serve $OUT_DIR and set xpack.ml.model_repository on each node"
