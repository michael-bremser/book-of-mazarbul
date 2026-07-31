# Build Journal — Step 6: Bare-Metal Ollama on Gundabad

**Date:** _fill in when run_
**Node:** Gundabad (bare metal — Ryzen 5600X · RTX 3080 Ti · 32GB DDR4 · Manjaro)
**Status:** [ ] Not run — Bucket B, waiting on approval to install `ollama-cuda`

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

- [ ] `nvidia-smi` shows the RTX 3080 Ti healthy (confirmed already: driver 610.43.03, CUDA UMD 13.3)
- [ ] `/media/SSD_1/llm-models/Qwen3-14B-Q4_K_M.gguf` exists and passed its checksum on download
- [ ] No other process is holding significant VRAM (`nvidia-smi` — desktop baseline is ~1.4GB)
- [ ] `pacman -Si ollama-cuda` confirms the version and the `cuda` dependency you're approving

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

_Fill in when run:_

```
# Paste actual output here — tokens/sec from bench-model.sh, actual VRAM
# usage from nvidia-smi, context length actually usable before OOM/failure
```

---

## What I Learned

_Fill in after completion. Examples:_
- _How close did actual VRAM usage come to the docs/sizing.md estimate?_
- _What's the actual usable context length with Q8 KV cache quantization enabled vs. not?_
- _What happens to the desktop's own GPU usage (compositor, browser) when Ollama is holding ~9GB?_

---

## Issues Encountered

| Issue | Cause | Fix |
|-------|-------|-----|
| | | |

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
