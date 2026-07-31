# Sizing — VRAM, KV Cache, and Model Tiers

**Date:** 2026-07-31
**Machine:** Gundabad — RTX 3080 Ti (12GB VRAM), Ryzen 5600X, 32GB DDR4, 0B swap

This records the arithmetic behind the two model tiers so it isn't
rediscovered later. It supersedes an earlier assumption of 64GB DDR4 on
Gundabad — actual `MemTotal` is 32772380 kB (~31.25 GiB usable).

---

## Default tier: 14B-class, Q4_K_M, GPU-resident

```
12288 MiB total VRAM
-  ~2000 MiB desktop headroom (KDE + Firefox; 1355 MiB measured at idle, grows)
= ~10.2 GB available to the model

Qwen3-14B Q4_K_M weights                          ~9.0 GB
Remaining for KV cache                            ~1.2 GB

KV cache size (Qwen3-14B: 40 layers, 8 KV heads, head_dim 128):
  fp16 KV   ~160 KB/token  ->  ~8k context
  q8_0 KV    ~80 KB/token  -> ~16k context
```

**Conclusion:** 12GB alongside a live desktop is tight for a 14B model. Q8 KV
cache quantization is not optional if context beyond ~8k tokens is wanted —
it roughly doubles usable context for the same VRAM budget.

---

## Experiment tier: 30B-class MoE, Q4_K_M, `--n-cpu-moe`

A 30B-class MoE at Q4_K_M is roughly 17–18GB of weights. With ~10.2GB of
usable VRAM and ~26GB of free system RAM, it fits numerically: attention and
shared layers on GPU, routed experts parked in system RAM via llama.cpp's
`--n-cpu-moe`.

**Throughput is bandwidth-bound, not capacity-bound.** DDR4-3200 dual-channel
delivers roughly 45–51 GB/s. For a model with ~3B active parameters per
token, that works out to roughly 10–20 tok/s — usable, not fast.

**The real risk is not loading, it's `SwapTotal: 0`.** With no swap
configured, a footprint misjudgment doesn't degrade gracefully — the kernel
OOM killer picks a victim, and on a daily-driver desktop that victim may not
be the model process. This is why the MoE tier is an experiment lane, never
the default, and why the drafted `llama-server.service` sets
`MemoryMax=`/`MemoryHigh=` — an overrun is then killed as the offending
systemd unit instead of the OOM killer choosing from the live desktop
session.

---

## Hardware upgrade paths (recorded, not recommended for now)

More system RAM buys **safety, not speed**. CPU-offload throughput is bounded
by memory *bandwidth*, which capacity increases do not change.

| Path | Bandwidth | Capacity | What it actually fixes |
|---|---|---|---|
| RTX 3080 Ti (current) | ~912 GB/s | 12GB | — binding constraint |
| 32→64GB DDR4 | ~48 GB/s (unchanged) | 64GB | OOM risk only; no speedup |
| 24GB card (e.g. used 3090) | ~936 GB/s | 24GB | Context length **and** MoE on-GPU residency |
| Unified memory (Apple M-series, Strix Halo) | ~256–800 GB/s | 64–128GB | Large MoE specifically |

The binding constraint today is **context length on the 14B default**, and
KV cache for a GPU-resident model lives in VRAM — system RAM cannot address
it. If one upgrade is ever made, more VRAM is the one that solves both the
context-length problem and the MoE-residency problem at once. This is a
record for future reference, not a purchase recommendation.
