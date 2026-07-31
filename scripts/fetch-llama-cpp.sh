#!/usr/bin/env bash
# Fetches and verifies a llama.cpp release build for the MoE experiment lane.
#
# No official Linux+CUDA prebuilt exists upstream — ggml-org only ships a
# CUDA build for Windows. The Vulkan build is used instead: it runs on the
# same GPU through the Vulkan compute API rather than CUDA, needs no CUDA
# toolkit and no compiler toolchain (avoiding gcc 16.1.1 vs CUDA support
# risk on this Manjaro install), and Gundabad already has a working Vulkan
# runtime + NVIDIA ICD with no packages added. Confirmed working:
# `llama-server --list-devices` correctly enumerates the RTX 3080 Ti.
#
# Idempotent and reversible: re-running re-verifies or re-fetches; removing
# ~/bin/llama.cpp undoes it completely.
set -euo pipefail

RELEASE_TAG="b10210"
ASSET="llama-b10210-bin-ubuntu-vulkan-x64.tar.gz"
EXPECTED_SHA256="a33286506201e59aef9a738eafe7e6406b4078d033f0b9c25c347a819507fe86"
DEST_ROOT="$HOME/bin/llama.cpp"
BUILD_DIR="$DEST_ROOT/llama-${RELEASE_TAG}"

if [ -x "$BUILD_DIR/llama-server" ]; then
  echo "Already present: $BUILD_DIR"
else
  mkdir -p "$DEST_ROOT"
  tmpfile=$(mktemp)
  trap 'rm -f "$tmpfile"' EXIT

  curl -L --fail --retry 3 --retry-delay 5 -o "$tmpfile" \
    "https://github.com/ggml-org/llama.cpp/releases/download/${RELEASE_TAG}/${ASSET}"

  actual_sha256=$(sha256sum "$tmpfile" | awk '{print $1}')
  if [ "$actual_sha256" != "$EXPECTED_SHA256" ]; then
    echo "SHA256 MISMATCH: expected $EXPECTED_SHA256, got $actual_sha256" >&2
    exit 1
  fi

  tar -xzf "$tmpfile" -C "$DEST_ROOT"
  echo "Extracted to $BUILD_DIR"
fi

ln -sfn "$BUILD_DIR" "$DEST_ROOT/current"
echo "Symlinked: $DEST_ROOT/current -> $BUILD_DIR"

"$DEST_ROOT/current/llama-server" --version
"$DEST_ROOT/current/llama-server" --list-devices
