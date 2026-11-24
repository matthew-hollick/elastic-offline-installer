#!/usr/bin/env bash
# Download ML trained-model artifacts into dist/ear/models/ so the EAR can
# serve them as the xpack.ml.model_repository for an air-gapped cluster
# (Elastic's documented alternative to ml-models.elastic.co).
#
# Each model is three files: <id>.metadata.json, <id>.pt, <vocab-file>.
# metadata.json is always refreshed — it carries the sha256/size the .pt
# must match, so an upstream change re-downloads the weights.
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
read -ra models <<< "$ML_MODELS"
((${#models[@]})) || { echo "error: ML_MODELS is empty" >&2; exit 1; }

fetch() {
  local url="$1" dest="$2"
  echo "  downloading: $(basename "$dest")"
  curl -fsSL --retry 3 -o "$dest.part" "$url"
  mv "$dest.part" "$dest"
}

for model in "${models[@]}"; do
  echo "== $model"

  # always refresh the manifest — it's tiny and carries the .pt checksum
  meta="$OUT_DIR/$model.metadata.json"
  fetch "$BASE/$model.metadata.json" "$meta"
  read -r sha vocab < <(python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d["sha256"], d.get("vocabulary_file") or "")
' < "$meta")
  vocab="${vocab:-$model.vocab.json}"

  pt="$OUT_DIR/$model.pt"
  # an existing .pt must still match the fresh manifest's sha256,
  # otherwise it is stale/corrupt and gets re-downloaded
  if [[ -f "$pt" ]] && ! echo "$sha  $pt" | sha256sum -c - >/dev/null 2>&1; then
    rm -f "$pt"
  fi

  for f in "$vocab" "$model.pt"; do
    dest="$OUT_DIR/$(basename "$f")"
    if [[ -f "$dest" ]]; then
      echo "  exists: $(basename "$dest")"
    else
      fetch "$BASE/$f" "$dest"
    fi
  done

  echo "$sha  $pt" | sha256sum -c -
done

echo "== done. Serve $OUT_DIR and set xpack.ml.model_repository on each node"
