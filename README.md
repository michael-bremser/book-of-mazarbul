# 🧠 Private AI Financial Assistant — Homelab K8s Stack

> A fully local, air-gapped AI stack for personal finance analysis. Built on a k3s Kubernetes cluster running in Proxmox VMs across a homelab cluster. No data leaves the network.

---

## What This Is

A production-pattern Kubernetes deployment of a RAG (Retrieval-Augmented Generation) pipeline for personal financial data. Bank statements, credit card PDFs, and budgets are ingested, embedded, and stored locally. A local LLM answers questions about them — privately, without any cloud API.

Built as a hands-on DevOps learning project aligned with the [Kubecraft](https://kubecraft.dev) career accelerator curriculum.

---

## Why It Exists

Two goals:

1. **Daily utility** — a private financial assistant that actually gets used, with real data, answering real questions
2. **Career development** — every component is a deliberate teaching moment. This isn't a tutorial clone. Architecture decisions are documented, rationale is written down, and the build journal captures what broke and why

---

## Naming Convention

All names follow a Middle-earth Dwarf lore theme — kingdoms, peaks, craftsmen, and gatekeepers of the deep places.

---

## Stack

| Name | Component | Role | K8s Primitive |
|------|-----------|------|---------------|
| **Ollama** | [Ollama](https://ollama.com) | Local LLM inference (GPU) | StatefulSet |
| **ChromaDB** | [ChromaDB](https://www.trychroma.com) | Vector store (RAG memory) | StatefulSet |
| **Open WebUI** | [Open WebUI](https://github.com/open-webui/open-webui) | Chat interface | Deployment |
| **n8n** | [n8n](https://n8n.io) | Ingestion pipeline & automation | StatefulSet |
| **nginx Ingress** | nginx Ingress | Traffic routing | DaemonSet |
| **Prometheus** | Prometheus | Metrics collection | Deployment |
| **Grafana** | Grafana | Dashboards & alerting | Deployment |
| **Cloudflare Tunnel** | Cloudflare Tunnel | Remote webhook access (Phase 3) | — |

---

## Infrastructure

| Name | Thing | Hardware | Role |
|------|-------|----------|------|
| **Nogrod** | Proxmox node | Lenovo M70q · i3-10100T · 32GB DDR4 | Hypervisor — hosts nogrod-cp |
| **Belegost** | Proxmox node | Lenovo M70q · i3-10100T · 32GB DDR4 | Hypervisor — hosts belegost-worker |
| **nogrod-cp** | k3s VM on Nogrod | 4 vCPU · 8GB RAM · 40GB disk · Ubuntu 24.04 | k3s control plane |
| **belegost-worker** | k3s VM on Belegost | 4 vCPU · 12GB RAM · 40GB disk · Ubuntu 24.04 | k3s worker — general workloads |
| Workstation | k3s bare metal worker | Ryzen 5600X · RTX 3080 Ti · 64GB DDR4 | k3s worker — GPU (Ollama only) |
| **Aglarond** | TrueNAS | ZFS · NFS export | Persistent storage — all PVCs |
| **Khazad-dûm** | pfSense | — | Router, firewall, internal DNS |

---

## Cluster Topology

```
┌─────────────────────────────────────────────────────────────────┐
│                        Proxmox Cluster                          │
│                                                                 │
│  Nogrod (<proxmox-nogrod-ip>)              Belegost (<proxmox-belegost-ip>)      │
│  ┌───────────────────────┐         ┌───────────────────────┐   │
│  │  Proxmox Host         │         │  Proxmox Host         │   │
│  │  ┌─────────────────┐  │         │  ┌─────────────────┐  │   │
│  │  │  nogrod-cp VM  │  │         │  │ belegost-worker VM │  │   │
│  │  │  Control Plane  │  │         │  │  Worker Node    │  │   │
│  │  │  <control-plane-ip>    │  │         │  │  <worker-ip>    │  │   │
│  │  └─────────────────┘  │         │  │  ChromaDB           │  │   │
│  └───────────────────────┘         │  │  Open WebUI         │  │   │
│                                    │  │  n8n                │  │   │
│                                    │  │  nginx Ingress      │  │   │
│                                    │  │  Prometheus         │  │   │
│                                    │  │  Grafana            │  │   │
│                                    │  └─────────────────┘  │   │
│                                    └───────────────────────┘   │
│                                                                 │
│  Workstation (bare metal GPU worker)                            │
│  Ryzen 5600X · RTX 3080 Ti · 64GB DDR4                        │
│  Ollama — tainted, not always-on                        │
└─────────────────────────────────────────────────────────────────┘
                             │
                             │ NFS
                             ▼
                  Aglarond (TrueNAS)
                  ZFS persistent storage
                  All PVCs backed here
                             │
                  DNS & routing via
                  Khazad-dûm (pfSense)
```

**Key design principle:** compute and storage are fully decoupled. The k3s cluster can be rebuilt from scratch without touching data on Aglarond. The hypervisor layer is transparent to the cluster — swap Proxmox for anything else without changing a single manifest.

---

## Data Flow

```
You drop a PDF (from laptop, phone, or drop folder)
      │
      ▼
n8n detects it — file watch / webhook / cron / manual
      │
      ▼
n8n parses + chunks the document
      │
      ▼ (queued with retry if Ollama offline)
Ollama generates embeddings
      │
      ▼
ChromaDB stores vectors on Aglarond (NFS PVC)
      │
      ▼
You ask a question in Open WebUI
      │
      ▼
ChromaDB retrieves relevant chunks
      │
      ▼
Ollama generates answer with context
      │
      ▼
Answer rendered in Open WebUI
```

---

## Offline / Queue Behavior

The workstation running Ollama is not always-on. The stack is designed for this:

- ChromaDB, n8n, and Open WebUI run continuously on belegost-worker
- n8n queues ingestion jobs with configurable retry when Ollama is unreachable
- A k8s readiness probe on the Ollama pod ensures n8n only retries once the model is fully loaded
- On workstation boot, the backlog processes automatically with no manual intervention

You can trigger pipelines from a laptop or phone at any time via webhook to n8n. Documents will be indexed the next time the workstation is on.

---

## Build Phases

### Phase 0 — Infrastructure
- Proxmox VMs provisioned: nogrod-cp on Nogrod, belegost-worker on Belegost
- VM specs: Ubuntu 24.04 LTS, 4 vCPU, 8–12GB RAM, 40GB disk
- Network: VLAN-aware, static IPs assigned

### Phase 1 — Core Stack ✅ In Progress
- k3s control plane on nogrod-cp
- k3s worker on belegost-worker
- Workstation joined as bare metal GPU worker
- NFS StorageClass pointed at Aglarond
- Ollama, ChromaDB, Open WebUI, n8n deployed
- nginx Ingress (nginx Ingress) + local DNS via Khazad-dûm

### Phase 2 — Observability
- Prometheus + Grafana
- Ollama GPU utilisation metrics
- n8n job success/failure alerting
- PVC storage usage dashboards
- Readiness and liveness probes on all services

### Phase 3 — Remote Access
- Cloudflare Tunnel exposing n8n webhook endpoint only
- Trigger ingestion pipelines from anywhere
- Ollama, ChromaDB, Open WebUI remain fully internal
- Zero open ports on the router

### Phase 4 — Future Consideration
- Evaluate Talos Linux as hypervisor replacement
- Immutable, API-driven OS purpose-built for Kubernetes nodes
- Migration path: reprovision VMs, rejoin nodes — manifests unchanged

---

## Repository Structure

```
/                                    # The Book of Mazarbul
├── README.md
├── docs/
│   ├── adr/                         # Architecture Decision Records
│   │   ├── ADR-001-k3s-over-k8s.md
│   │   ├── ADR-002-nginx-over-traefik.md
│   │   ├── ADR-003-vms-over-bare-metal.md
│   │   ├── ADR-004-statefulset-decisions.md
│   │   └── ADR-005-nfs-storage-backend.md
│   └── build-journal/               # Placeholder — journal kept in Obsidian
│       └── .gitkeep
├── manifests/
│   ├── namespaces/
│   ├── storage/                     # StorageClass, PV, PVC
│   ├── aule/                        # Ollama
│   ├── mim/                         # ChromaDB
│   ├── the-gate/                    # Open WebUI
│   ├── narvi/                       # n8n
│   ├── the-bridge/                  # nginx Ingress
│   └── observability/               # Prometheus + Grafana
└── scripts/
```

---

## Architecture Decisions

All major decisions are documented as Architecture Decision Records in `/docs/adr/`. Each ADR captures the context, the options considered, the decision made, and the reasoning. See [ADR-001](docs/adr/ADR-001-k3s-over-k8s.md) to start.

---

## DevOps Concepts Covered

| Concept | Where |
|---------|-------|
| VM isolation of cluster from hypervisor | nogrod-cp + belegost-worker in Proxmox |
| StatefulSet vs Deployment | ChromaDB, n8n, Ollama vs Open WebUI |
| Taints & Tolerations | GPU node scheduling for Ollama |
| NodeSelector / Affinity | Workload placement |
| PersistentVolume + PVC | NFS-backed storage on Aglarond |
| ClusterIP Services | Internal DNS between services |
| Ingress + TLS | nginx Ingress (nginx Ingress) |
| DaemonSet | NVIDIA device plugin, nginx Ingress |
| ConfigMap + Secret | Service configuration, credentials |
| Readiness / Liveness Probes | Ollama model-ready detection |
| Prometheus + Grafana | Prometheus + Grafana |
| Cloudflare Tunnel | Cloudflare Tunnel — secure external access |

---

## Network

- **Router/Firewall:** Khazad-dûm (pfSense)
- **Internal DNS:** `the-gate.local`, `narvi.local`, `mithril-hall.local`
- **VLANs:** Cluster nodes on lab VLAN
- **No internet egress** from cluster workloads

---

*Built with [Kubecraft](https://kubecraft.dev). All financial data stays local.*
