# 🧠 Book of Mazarbul — Self-Hosted AI Stack

> A private, local-first AI stack for personal use — financial analysis, homelab monitoring, and other focused tasks — running against a self-hosted LLM. No data leaves the network.

---

## What This Is

A generalist local AI assistant, deliberately scoped by task rather than by a
single use case. It started as a RAG pipeline for personal finance and has
broadened: the inference layer comes first and is built to support several
task-focused areas over time (financial document analysis, homelab
observability, general Q&A), rather than being hard-wired to one pipeline.

Built as a hands-on DevOps learning project aligned with the
[Kubecraft](https://kubecraft.dev) career accelerator curriculum.

---

## Why It Exists

Two goals:

1. **Daily utility** — a private assistant that actually gets used, starting
   with inference you control end to end
2. **Career development** — every component is a deliberate teaching moment.
   Architecture decisions are documented, rationale is written down, and the
   build journal captures what broke and why

---

## Naming Convention

Infrastructure nodes follow a Middle-earth Dwarf lore theme. Personal devices
and workstations follow Middle-earth naming broadly. Kubernetes services use
component names only.

---

## Architecture

**Inference is external to the cluster, not a workload in it.** Gundabad is a
daily-driver workstation, not a dedicated, always-on machine — modeling it as
a Kubernetes node produces `NotReady` churn and eviction noise for no benefit.
Instead:

- **Ollama runs bare metal** on Gundabad (Manjaro, CUDA, RTX 3080 Ti). No GPU
  passthrough into a VM, no in-cluster GPU scheduling.
- **beleriand reaches it as an ExternalName Service.** From the cluster's
  point of view, inference is an external dependency it consumes, the same
  category as a third-party API — just self-hosted and on the LAN.
- **Persistent data and backups land on Aglarond over NFS**, independent of
  both the cluster and Gundabad.

This is a deliberate departure from an earlier design (see the superseded
note on ADR-003) that ran Ollama as a tainted, GPU-scheduled StatefulSet on a
Gundabad joined to the cluster. That path is preserved, not deleted, as a
timeboxed post-exam learning exercise — see
`docs/build-journal/step-05-gundabad-gpu-worker.md`.

### Model tiers

| Tier | Model | Quant | Role |
|------|-------|-------|------|
| Default | 14B-class (Qwen3-14B) | Q4_K_M | Daily driver, fully GPU-resident |
| Experiment | 30B-class MoE | Q4_K_M | `llama.cpp --n-cpu-moe`, routed experts in system RAM |

The MoE tier is not a default — it is bandwidth-bound on Gundabad's DDR4 and,
with zero swap configured, a footprint misjudgment risks the desktop session
rather than degrading gracefully. See `docs/sizing.md` for the VRAM/KV-cache
arithmetic behind both tiers.

---

## Infrastructure

| Name | Role | Notes |
|------|------|-------|
| **beleriand** | k3s production cluster | Two nodes: `k3s-control` (10.28.99.40), `k3s-worker` (10.28.99.41). Consumes inference, does not serve it. |
| **Gundabad** | Workstation — bare-metal inference host | Ryzen 5600X · RTX 3080 Ti (12GB VRAM) · 32GB DDR4 · Manjaro. Daily driver, not always-on, not a cluster member. |
| **Aglarond** | TrueNAS on the Proxmox cluster | ZFS pool, NFS export. `aglarond-nfs` is (one of two, currently — see `docs/findings-2026-07-31.md`) default StorageClasses on beleriand. |

---

## Data Flow (current scope)

```
You ask a question (Open WebUI, or direct API call)
      │
      ▼
Request reaches Gundabad — bare-metal Ollama, CUDA, RTX 3080 Ti
      │
      ▼
Ollama generates a response
      │
      ▼
Answer returned to the caller
```

Retrieval-augmented pieces (ChromaDB, ingestion via n8n) are not yet built.
They remain on the board as task-focused extensions — see Scope below — not
as scheduled work.

---

## Offline / Availability Behavior

Gundabad is not always-on. Anything that depends on inference must tolerate
it being unreachable:

- beleriand's ExternalName Service resolves to Gundabad; when Gundabad is
  off, requests fail rather than queue — there is currently no queuing layer
  (n8n) in front of it
- No readiness/liveness probing exists yet across the ExternalName boundary;
  this is one of the monitoring decisions still open (Bucket C — see the
  project's replan notes)

---

## Scope

**Built or in progress:**
- Bare-metal Ollama on Gundabad, GPU-resident 14B-class inference
- ExternalName consumption pattern from beleriand
- NFS-backed persistent storage on Aglarond
- Prometheus + Grafana (kube-prometheus-stack) on beleriand

**On the board, not scheduled:**
- Additional task-focused areas (financial document RAG, homelab
  observability queries) built against the same inference layer
- ChromaDB, n8n, Open WebUI, Cloudflare Tunnel — useful if/when a given task
  area needs them, not committed to as a fixed pipeline
- GitOps migration via Flux (Flux is not yet bootstrapped on beleriand — it
  currently reconciles a separate cluster, `learning`, via a different repo)

---

## Repository Structure

```
/
├── README.md
├── docs/
│   ├── adr/                         # Architecture Decision Records
│   ├── build-journal/               # Step-by-step build notes
│   ├── sizing.md                    # VRAM/KV-cache/model-tier arithmetic
│   ├── findings-2026-07-31.md       # Known defects found during the replan
│   └── monitoring-options.md        # Monitoring facts, not decisions
├── manifests/                       # Kubernetes manifests (none written yet)
└── scripts/                         # Install scripts, systemd units, benchmarks
```

---

## Architecture Decisions

All major decisions are documented as Architecture Decision Records in
`/docs/adr/`. Each ADR captures the context, the options considered, the
decision made, and the reasoning. Start at
[ADR-001](docs/adr/ADR-001-k3s-over-k8s.md).

Note: ADR-003 and the Ollama section of ADR-004 predate the shift to
bare-metal inference and are marked superseded in place — the historical
reasoning is kept, not deleted.

---

## Build Journal

Step-by-step build notes live in `/docs/build-journal/`. Each entry covers
what was done, what was learned, and what broke. Written during the build,
not after.

---

## DevOps Concepts Covered

| Concept | Where |
|---------|-------|
| VM isolation of cluster from hypervisor | beleriand's control/worker nodes |
| ExternalName Services | Cluster consumption of an out-of-cluster dependency |
| NodeSelector / Affinity, Taints & Tolerations, GPU device plugin | `step-05` experiment (timeboxed, not production) |
| PersistentVolume + PVC | NFS-backed storage on Aglarond |
| Prometheus + Grafana | Metrics, dashboards, alerting |
| SOPS + age | Secret encryption at rest in Git |
| GitOps + Flux | Not yet bootstrapped on beleriand — future work |

---

*Built with [Kubecraft](https://kubecraft.dev). All data stays local.*
