#!/usr/bin/env bash
# STAGED — not executed by the replan. Installing Ollama needs your approval
# (Bucket B) because ollama-cuda pulls in the `cuda` package via pacman:
# a ~770MB download and a real system change on the daily driver, distinct
# from — and heavier than — the llama.cpp path, which deliberately avoids
# any CUDA toolkit install by using the Vulkan build instead (see
# scripts/fetch-llama-cpp.sh). This is NOT a driver or kernel package, so it
# doesn't trip that specific guardrail, but it's substantial enough that it
# shouldn't happen without a yes.
#
# What this does, in order:
#   1. pacman -S ollama-cuda        (needs sudo; pulls `cuda` as a dependency)
#   2. systemctl enable --now ollama.service   (unit is shipped by the package)
#   3. Import the already-downloaded, checksum-verified GGUF via a Modelfile,
#      rather than re-pulling a possibly-different quant from Ollama's
#      registry — one copy of the weights, known provenance.
#   4. Smoke-test via the local API.
set -euo pipefail

MODEL_GGUF="/media/SSD_1/llm-models/Qwen3-14B-Q4_K_M.gguf"
MODEL_NAME="qwen3-14b-q4km"

if [ ! -f "$MODEL_GGUF" ]; then
  echo "Expected model not found at $MODEL_GGUF — run the model download step first." >&2
  exit 1
fi

echo "== Installing ollama-cuda (pulls the 'cuda' package — confirm this is wanted) =="
sudo pacman -S --needed ollama-cuda

echo "== Enabling the shipped systemd unit =="
sudo systemctl enable --now ollama.service
sleep 2
systemctl is-active --quiet ollama.service || { echo "ollama.service did not start" >&2; exit 1; }

echo "== Importing $MODEL_GGUF as '$MODEL_NAME' =="
MODELFILE=$(mktemp)
echo "FROM $MODEL_GGUF" > "$MODELFILE"
ollama create "$MODEL_NAME" -f "$MODELFILE"
rm -f "$MODELFILE"

echo "== Smoke test =="
curl -sS http://127.0.0.1:11434/api/generate -d "{
  \"model\": \"$MODEL_NAME\",
  \"prompt\": \"Reply with exactly the word: ready\",
  \"stream\": false
}"

echo
echo "Ollama installed, model imported, API responding on :11434."
