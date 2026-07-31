# Build Journal — Step 6: Bare-Metal Ollama on Gundabad

**Date:** 2026-07-31
**Node:** Gundabad (bare metal — Ryzen 5600X · RTX 3080 Ti · 32GB DDR4 · Manjaro)
**Status:** [x] Run — `ollama-cuda` installed, model loaded, benchmarked

---

## Objective

Install Ollama on Gundabad as a bare-metal service (no container, no cluster
membership), load the already-downloaded and checksum-verified Qwen3-14B
Q4_K_M as the default daily-driver model, and confirm it answers over the
local API. This is the step that turns the replan from preparation into a
working inference endpoint.

---

## Why This Needs Approval First

`ollama-cuda` on Manjaro/Arch depends on the `cuda` package — roughly 770MB
and a real addition to this daily-driver system. It is not a driver or
kernel package, so it doesn't trip that specific guardrail, but it's
substantial enough that it shouldn't happen without a yes. See
`scripts/install-ollama.sh` for exactly what this step runs.

---

## Pre-flight Checks

- [x] `nvidia-smi` shows the RTX 3080 Ti healthy (confirmed already: driver 610.43.03, CUDA UMD 13.3)
- [x] `/media/SSD_1/llm-models/Qwen3-14B-Q4_K_M.gguf` exists and passed its checksum on download — sha256 `500a8806e85ee9c83f3ae08420295592451379b4f8cf2d0f41c15dffeb6b81f0`, matches the hash published by `Qwen/Qwen3-14B-GGUF` on Hugging Face
- [x] No other process is holding significant VRAM (`nvidia-smi` — desktop baseline is ~1.4GB)
- [x] `pacman -Si ollama-cuda` confirms the version and the `cuda` dependency you're approving — 0.32.1-1, 770MB download

---

## What's Actually Happening

`ollama-cuda` is a native Arch/Manjaro package (`extra` repo), which means it
ships its own systemd unit (`/usr/lib/systemd/system/ollama.service`) —
no custom unit needs to be written for this, unlike the MoE experiment lane
in `scripts/systemd/llama-server.service`.

Rather than `ollama pull qwen3:14b` — which would fetch a second, possibly
differently-quantized copy from Ollama's own registry — this step imports
the GGUF already downloaded and verified against Qwen's official
`Qwen/Qwen3-14B-GGUF` repo, via a `Modelfile`. One copy of the weights, known
provenance, matches the arithmetic in `docs/sizing.md`.

---

## Commands

```bash
./scripts/install-ollama.sh
```

That script, in order:
1. `sudo pacman -S --needed ollama-cuda`
2. `sudo systemctl enable --now ollama.service`
3. Imports `/media/SSD_1/llm-models/Qwen3-14B-Q4_K_M.gguf` as `qwen3-14b-q4km`
4. Smoke-tests via `curl` against the local API

---

## Verification

```bash
systemctl status ollama.service
curl -s http://127.0.0.1:11434/api/tags | jq .
curl -s http://127.0.0.1:11434/api/generate -d '{
  "model": "qwen3-14b-q4km",
  "prompt": "Reply with exactly the word: ready",
  "stream": false
}'
nvidia-smi   # confirm VRAM usage matches the ~9-10GB estimate in docs/sizing.md
```

Then, once satisfied it's stable, run the benchmark to get a real number
instead of the estimate:

```bash
scripts/bench-model.sh /media/SSD_1/llm-models/Qwen3-14B-Q4_K_M.gguf
```

---

## What I Observed

```
$ ollama list
NAME                     ID              SIZE      MODIFIED
qwen3-14b-q4km:latest    9aa7d8c9138a    9.0 GB    ...

$ curl -s http://127.0.0.1:11434/api/generate -d '{"model":"qwen3-14b-q4km","prompt":"Reply with exactly the word: ready","stream":false}'
# responded correctly (with visible <think> reasoning first, then "ready" — expected for this model)

$ nvidia-smi --query-gpu=memory.used,memory.total --format=csv
10484 MiB, 12288 MiB     # Ollama holding ~9.2GB + ~1.2GB desktop baseline

Bench (scripts/bench-model.sh, Ollama unloaded first via `ollama stop` to free the
card — llama-bench loads its own copy and won't share VRAM with a running Ollama
instance):

| model                    |    size | params | backend | ngl | test  | t/s              |
| ------------------------ | ------: | -----: | ------- | --: | ----- | ----------------: |
| qwen3 14B Q4_K - Medium  | 8.38 GiB | 14.77 B | Vulkan  |  -1 | pp512 | 2853.31 ± 12.83  |
| qwen3 14B Q4_K - Medium  | 8.38 GiB | 14.77 B | Vulkan  |  -1 | tg128 |    80.38 ± 1.05  |

Peak VRAM during bench: 9857 MiB. Peak RSS: 9555652 KiB.
```

---

## What I Learned

- Actual VRAM usage (~9.2-9.9GB) landed right in the range `docs/sizing.md` estimated —
  no surprises there.
- Generation speed: ~80 tok/s, comfortably fast for interactive daily-driver use on
  this card. Prompt processing (~2850 tok/s) is well clear of being a bottleneck.
- `ollama stop <model>` unloads a model from VRAM without touching the systemd unit —
  useful for freeing the card for llama-bench (which loads its own copy and doesn't
  share with a running Ollama instance) without needing sudo to stop/start the service.
- Default context in `ollama ps` shows 4096 — worth revisiting against the KV-cache
  arithmetic in `docs/sizing.md` before relying on longer contexts day to day.

---

## Issues Encountered

| Issue | Cause | Fix |
|-------|-------|-----|
| Model download corrupted on resume (file grew ~812MB past expected size) | Killing the first backgrounded `wget` only killed the shell wrapper PID, not the actual `wget` child process; a second `wget -c` was then started against the same output file, and both processes appended to it concurrently | Verified via `ps aux`, killed the leftover child, deleted the corrupted partial, re-downloaded clean in one process, verified sha256 against Hugging Face's published hash before importing |
| `sudo` in `install-ollama.sh` can't read a password through this session (no real tty, even via the `!` interactive prefix) | Environment constraint, not a bug | User ran the two sudo-requiring lines (`pacman -S ollama-cuda`, `systemctl enable --now ollama.service`) directly in their own terminal; the rest of the script (model import, smoke test) doesn't need sudo and ran normally |

---

## Notes

- Gundabad is not always-on. `ollama.service` will simply not be running
  when the machine is off — nothing on beleriand currently queues or retries
  against it (see the "Offline / Availability Behavior" section of the
  README; that's an open monitoring/design question, not yet solved).
- This step does not touch beleriand or Kubernetes at all. The ExternalName
  Service that lets the cluster consume this endpoint is separate work —
  see Next Step below.

---

## Next Step

Step 7 — ExternalName Service on beleriand, pointing at Gundabad's stable
DHCP-reserved address. **This is Bucket C, not staged here on purpose:**
the manifest itself, its placement in the repo, and any Flux/GitOps wiring
around it are yours to write.
