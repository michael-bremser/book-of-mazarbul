# Monitoring Options — Facts, Not Decisions

**Date:** 2026-07-31

This is research, not a recommendation. Monitoring choices (which exporter,
what gets scraped, alert thresholds) are listed as Bucket C in the replan —
they're decisions, not mechanics, and they're yours to make. This exists so
that decision doesn't start from a blank page.

---

## 1. What Ollama's own API exposes

Checked against Ollama's own API documentation (`docs/api.md` in the
`ollama/ollama` repo). There is **no native `/metrics` Prometheus endpoint**.
What exists instead:

| Endpoint | Gives you |
|---|---|
| `GET /api/ps` | Currently loaded models, their VRAM footprint (`size_vram`), and time until auto-unload |
| `GET /api/version` | Version string — useful as a liveness signal |
| `GET /api/tags` | Locally available models |

`/api/ps` is the closest thing to a metrics endpoint Ollama ships — it's
JSON, not Prometheus exposition format, so anything scraping it needs to be
translated first.

---

## 2. Existing community Prometheus exporters for Ollama

A few exist; none evaluated in depth, just surfaced by a GitHub search
(sorted by stars, 2026-07-31):

| Project | Stars | Notes |
|---|---|---|
| `frcooper/ollama-exporter` | 45 | Most-starred of the search results |
| `mikeh-22/ollama-exporter` | 1 | Explicitly supports NVIDIA via `pynvml` and AMD via sysfs |
| `lucavb/ollama-exporter` | 1 | Models, memory usage, API health |
| `evandhoffman/ollama-prometheus-exporter` | 1 | Also acts as a reverse proxy, tracks token metrics |

None of these are official or widely adopted (star counts are low across
the board) — this is a thin ecosystem, not a "pick the standard one"
situation.

---

## 3. GPU-level metrics options (Gundabad is not a cluster node)

Because Gundabad isn't a Kubernetes node, the usual in-cluster pattern
(NVIDIA DCGM exporter as a DaemonSet, scraped automatically) doesn't apply
directly. Options that run standalone on a non-cluster host:

- **`nvidia_gpu_exporter`** (community, `utkuozdemir/nvidia_gpu_exporter`) —
  wraps `nvidia-smi` output, single static binary, no Docker required,
  default port `9835`.
- **DCGM Exporter** (NVIDIA official) — more comprehensive metrics, but
  normally distributed as a container image; running it standalone on
  bare metal means either Docker or extracting the binary from the image.
  Default port `9400`.
- **Roll a script against `nvidia-smi --query-gpu=... --format=csv`** on a
  cron/timer, push or expose in Prometheus text format via a tiny HTTP
  wrapper (e.g. `python3 -m http.server` serving a file node-exporter's
  textfile collector could also read, if node-exporter were installed here —
  it currently isn't).

All three are facts about what's available, not a ranking.

---

## 4. Network reachability (Gundabad → beleriand's Prometheus)

Gundabad is on V20 (`10.28.20.10/24`), beleriand's nodes are on V99
(`10.28.99.x`). This path is confirmed working today — the k3s control
plane port (`:6443`) is reachable via pfSense, and Gundabad's address is a
DHCP reservation, not floating.

Whatever port a monitoring exporter binds (`9835`, `9400`, or something
custom) is a **different port than `:6443`**, and pfSense rules are
per-port — the existing rule does not cover it. A new rule would be needed
regardless of which exporter is chosen. This is a router/firewall change,
which is why it's Bucket C even though the pfSense/DHCP setup in general is
already done.

---

## 5. How Prometheus Operator (kube-prometheus-stack) scrapes external targets

The stack already running in `monitoring` on beleriand is Prometheus
Operator-based, which has a few established patterns for scraping something
outside the cluster:

- **`additionalScrapeConfigs`** — a raw Prometheus scrape config block passed
  through the Helm values, referencing an external `10.28.20.10:<port>`
  target directly. No cluster objects needed beyond the Helm value change.
- **`ScrapeConfig` CRD** (Prometheus Operator, if the installed version
  supports it) — the CRD-native way to express the same thing declaratively,
  fits a GitOps/Flux workflow better than a Helm values blob.
- **A `Service` of type `ExternalName` (or a headless `Service` +
  manually-managed `Endpoints`) fronted by a `ServiceMonitor`** — makes the
  external target look like a normal in-cluster scrape target to Prometheus
  Operator's usual discovery mechanism. More moving parts, more consistent
  with how the rest of the stack (if it grows) would be monitored.

All three are real, supported patterns — the choice affects how much this
looks like "one special case" versus "the same pattern as everything else,"
which is a judgment call, not a technical constraint.

---

## Not covered here

Readiness/liveness signaling across the ExternalName boundary (what happens
when Gundabad is off and something tries to reach it) is flagged as an open
question in the README's "Offline / Availability Behavior" section — it's
adjacent to monitoring but is really a request-handling design question, not
purely a metrics one.
