#!/usr/bin/env bash
# STAGED — not run as part of the replan. Benchmarking the 14B tier is
# Bucket B (needs Ollama installed first). Benchmarking the MoE tier is
# Bucket C outright (see docs/sizing.md — SwapTotal is 0, an unsupervised
# OOM-prone run doesn't belong unattended even with MemoryMax as a backstop).
#
# Uses llama.cpp's own llama-bench for the tokens/sec measurement (prompt
# processing and text generation, GPU-resident or with --n-cpu-moe offload)
# and samples nvidia-smi + /proc in the background for peak VRAM and peak
# RSS across the run. Appends one row per run to results.csv so multiple
# --n-cpu-moe values, context sizes, etc. can be compared over time.
#
# Usage:
#   scripts/bench-model.sh <path-to-gguf> [-- extra llama-bench args]
#
# Example (14B, fully GPU-resident):
#   scripts/bench-model.sh /media/SSD_1/llm-models/Qwen3-14B-Q4_K_M.gguf
#
# Example (MoE experiment, tuning --n-cpu-moe):
#   scripts/bench-model.sh /media/SSD_1/llm-models/Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf -- --n-cpu-moe 20
set -euo pipefail

LLAMA_BENCH="$HOME/bin/llama.cpp/current/llama-bench"
RESULTS_CSV="$(dirname "$0")/bench-results.csv"

if [ $# -lt 1 ]; then
  echo "Usage: $0 <path-to-gguf> [-- extra llama-bench args]" >&2
  exit 1
fi

MODEL_PATH="$1"
shift
EXTRA_ARGS=()
if [ "${1:-}" = "--" ]; then
  shift
  EXTRA_ARGS=("$@")
fi

if [ ! -f "$MODEL_PATH" ]; then
  echo "Model not found: $MODEL_PATH" >&2
  exit 1
fi
if [ ! -x "$LLAMA_BENCH" ]; then
  echo "llama-bench not found at $LLAMA_BENCH — run scripts/fetch-llama-cpp.sh first" >&2
  exit 1
fi

if [ ! -f "$RESULTS_CSV" ]; then
  echo "timestamp,model,extra_args,peak_vram_mib,peak_rss_kib,llama_bench_output_file" > "$RESULTS_CSV"
fi

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT_DIR="$(dirname "$0")/bench-runs"
mkdir -p "$OUT_DIR"
RAW_OUT="$OUT_DIR/${TIMESTAMP}.txt"
VRAM_LOG=$(mktemp)
RSS_LOG=$(mktemp)
trap 'rm -f "$VRAM_LOG" "$RSS_LOG"' EXIT

echo "== Running llama-bench on $MODEL_PATH =="
"$LLAMA_BENCH" -m "$MODEL_PATH" "${EXTRA_ARGS[@]}" > "$RAW_OUT" 2>&1 &
BENCH_PID=$!

# Background sampler: system-wide VRAM (MiB) and llama-bench's own peak RSS
# (VmHWM from /proc, KiB) every 2s while the benchmark runs. No dependency
# on the `time` package, which isn't installed and won't be added as a side
# effect of running a benchmark script.
(
  while kill -0 "$BENCH_PID" 2>/dev/null; do
    nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits >> "$VRAM_LOG" 2>/dev/null || true
    awk '/VmHWM/ {print $2}' "/proc/$BENCH_PID/status" >> "$RSS_LOG" 2>/dev/null || true
    sleep 2
  done
) &
SAMPLER_PID=$!

wait "$BENCH_PID"
kill "$SAMPLER_PID" 2>/dev/null || true
cat "$RAW_OUT"

PEAK_VRAM=$(sort -n "$VRAM_LOG" | tail -1)
PEAK_RSS=$(sort -n "$RSS_LOG" | tail -1)

EXTRA_ARGS_STR="${EXTRA_ARGS[*]:-none}"
echo "${TIMESTAMP},${MODEL_PATH},\"${EXTRA_ARGS_STR}\",${PEAK_VRAM:-unknown},${PEAK_RSS:-unknown},${RAW_OUT}" >> "$RESULTS_CSV"

echo
echo "Recorded to $RESULTS_CSV"
echo "Peak VRAM: ${PEAK_VRAM:-unknown} MiB, Peak RSS: ${PEAK_RSS:-unknown} KiB"
