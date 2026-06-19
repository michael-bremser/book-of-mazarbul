# Private AI Financial Assistant — Homelab K8s Stack

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

Infrastructure nodes follow a Middle-earth Dwarf lore theme. Personal devices and workstations follow Middle-earth naming broadly. Kubernetes services use component names only.

---

## Stack

| Component | Role | K8s Primitive |
|-----------|------|---------------|
| [Ollama](https://ollama.com) | Local LLM inference (GPU) | StatefulSet |
| [ChromaDB](https://www.trychroma.com) | Vector store (RAG memory) | StatefulSet |
| [Open WebUI](https://github.com/open-webui/open-webui) | Chat interface | Deployment |
| [n8n](https://n8n.io) | Ingestion pipeline & automation | StatefulSet |
| nginx Ingress | Traffic routing | DaemonSet |
| Prometheus | Metrics collection | Deployment |
| Grafana | Dashboards & alerting | Deployment |
| Cloudflare Tunnel | Remote webhook access (Phase 3) | — |

---

## Infrastructure

| Name | Thing | Hardware | Role |
|------|-------|----------|------|
| **Nogrod** | Proxmox node | Lenovo M70q · i3-10100T · 32GB DDR4 | Hypervisor — hosts k3s-control |
| **Belegost** | Proxmox node | Lenovo M70q · i3-10100T · 32GB DDR4 | Hypervisor — hosts k3s-worker |
| **k3s-control** | k3s VM on Nogrod | 4 vCPU · 8GB RAM · 40GB disk · Ubuntu 24.04 | k3s control plane · 10.28.99.40 |
| **k3s-worker** | k3s VM on Belegost | 4 vCPU · 12GB RAM · 40GB disk · Ubuntu 24.04 | k3s worker — general workloads · 10.28.99.41 |
| **Gundabad** | Workstation — bare metal GPU worker | Ryzen 5600X · RTX 3080 Ti · 64GB DDR4 | k3s worker — GPU (Ollama only) / daily driver |
| **Aglarond** | TrueNAS | ZFS · NFS export | Persistent storage — all PVCs |
| **Khazad-dûm** | pfSense | — | Router, firewall, internal DNS |

---

## Cluster Topology

```
┌─────────────────────────────────────────────────────────────────┐
│                        Proxmox Cluster                          │
│                                                                 │
│  Nogrod (10.28.99.11)              Belegost (10.28.99.12)      │
│  ┌───────────────────────┐         ┌───────────────────────┐   │
│  │  Proxmox Host         │         │  Proxmox Host         │   │
│  │  ┌─────────────────┐  │         │  ┌─────────────────┐  │   │
│  │  │  k3s-control VM │  │         │  │  k3s-worker VM  │  │   │
│  │  │  Control Plane  │  │         │  │  Worker Node    │  │   │
│  │  │  10.28.99.40    │  │         │  │  10.28.99.41    │  │   │
│  │  └─────────────────┘  │         │  │  ChromaDB       │  │   │
│  └───────────────────────┘         │  │  Open WebUI     │  │   │
│                                    │  │  n8n            │  │   │
│                                    │  │  nginx Ingress  │  │   │
│                                    │  │  Prometheus     │  │   │
│                                    │  │  Grafana        │  │   │
│                                    │  └─────────────────┘  │   │
│                                    └───────────────────────┘   │
│                                                                 │
│  Gundabad (bare metal GPU worker)                               │
│  Ryzen 5600X · RTX 3080 Ti · 64GB DDR4                        │
│  Ollama only — tainted, not always-on                           │
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
n8n moves it to staging/ on Aglarond  ── daytime: does NOT wake Gundabad
      │
      ▼  nightly batch cron — skipped if staging/ is empty
n8n wakes Gundabad via pfSense WoL API → polls Ollama readiness
      │
      ▼
n8n parses + chunks each pending document
      │
      ▼
Ollama generates embeddings
      │
      ▼
ChromaDB stores vectors on Aglarond (NFS PVC)
file moves staging/ → archive/   (failures stay in staging/ for retry)
      │
      ▼
You ask a question in Open WebUI  ── interactive: wakes Gundabad on demand
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

## Power Management & Queue Behavior

Gundabad (GPU worker) is not always-on and is also the daily-driver workstation. n8n actively manages its power state across the VLAN boundary rather than passively waiting for it to come online.

- **Cross-VLAN wake:** n8n (VLAN 99) can't broadcast a WoL magic packet to Gundabad (VLAN 20) — magic packets don't route. Instead n8n calls the pfSense REST API on Khazad-dûm, which originates the packet directly on VLAN 20. No relay VM. (See ADR-006.)
- **Interactive queries** wake Gundabad on demand, poll Ollama until the model is ready, then dispatch. Latency includes cold-start boot time — the accepted cost of an off-by-default GPU.
- **Idle-timeout shutdown:** Gundabad shuts down only after the queue has been empty for a continuous window, with a minimum-uptime guard so a fresh boot isn't caught immediately. This avoids power-cycle churn from bursty work. (See ADR-007.)
- **Document ingestion is deferred to a nightly batch.** Dropped PDFs land in a staging folder on Aglarond during the day; a single overnight run processes them all. Ingestion is asynchronous and eventually-consistent — a document is queryable the next morning, not on drop. The batch run skips entirely when nothing is pending.

The staging folder is the ingestion queue: no database, durable, and visible — list the directory to see exactly what's waiting. Files that fail mid-batch stay in staging and retry automatically on the next night's run.

---

## Build Phases

### Phase 0 — Infrastructure — Complete
- Proxmox VMs provisioned: k3s-control on Nogrod, k3s-worker on Belegost
- VM specs: Ubuntu 24.04 LTS, 4 vCPU, 8–12GB RAM, 40GB disk
- Network: VLAN 99 (Valinor), static IPs on 10.28.99.x

### Phase 1 — Core Stack — In Progress
- k3s control plane on k3s-control — done
- k3s worker on k3s-worker — done
- kubectl configured on Gundabad — done
- NFS StorageClass pointed at Aglarond
- Gundabad joined as bare metal GPU worker
- Ollama, ChromaDB, Open WebUI, n8n deployed
- nginx Ingress + local DNS via Khazad-dûm
- Cross-VLAN WoL via pfSense REST API — Gundabad power-on from n8n (ADR-006)
- Idle-timeout shutdown + nightly deferred batch ingestion (ADR-007)

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

### Phase 4 — GitOps Migration
- Migrate stack to Flux CD
- Cluster state fully defined in Git
- No manual kubectl apply or helm install
- Aligned with Kubecraft HomelabOS curriculum

### Phase 5 — Future Consideration
- Evaluate Talos Linux as hypervisor replacement
- Immutable, API-driven OS purpose-built for Kubernetes nodes
- Migration path: reprovision VMs, rejoin nodes — manifests unchanged

---

## Repository Structure

```
/
├── README.md
├── docs/
│   ├── adr/                         # Architecture Decision Records
│   │   ├── ADR-001-k3s-over-k8s.md
│   │   ├── ADR-002-nginx-over-traefik.md
│   │   ├── ADR-003-vms-over-bare-metal.md
│   │   ├── ADR-004-statefulset-decisions.md
│   │   ├── ADR-005-nfs-storage-backend.md
│   │   ├── ADR-006-cross-vlan-wol-pfsense-api.md
│   │   └── ADR-007-deferred-batch-ingestion.md
│   └── build-journal/               # Step-by-step build notes
│       ├── step-00-75-proxmox-vms.md
│       ├── step-01-k3s-control-plane.md
│       ├── step-02-belegost-worker.md
│       ├── step-03-nfs-storageclass.md
│       └── step-08-wol-power-management.md
├── manifests/
│   ├── namespaces/
│   ├── storage/                     # StorageClass, PV, PVC
│   ├── ollama/
│   ├── chroma/
│   ├── open-webui/
│   ├── n8n/
│   ├── ingress/
│   └── observability/
└── scripts/
```

---

## Architecture Decisions

All major decisions are documented as Architecture Decision Records in `/docs/adr/`. Each ADR captures the context, the options considered, the decision made, and the reasoning. See [ADR-001](docs/adr/ADR-001-k3s-over-k8s.md) to start.

Recent additions:

- [ADR-006](docs/adr/ADR-006-cross-vlan-wol-pfsense-api.md) — Cross-VLAN Wake-on-LAN via pfSense REST API
- [ADR-007](docs/adr/ADR-007-deferred-batch-ingestion.md) — Deferred batch ingestion & idle-timeout GPU power management

---

## Build Journal

Step-by-step build notes live in `/docs/build-journal/`. Each entry covers what was done, what was learned, and what broke. Written during the build — not after.

---

## DevOps Concepts Covered

| Concept | Where |
|---------|-------|
| VM isolation of cluster from hypervisor | k3s-control + k3s-worker in Proxmox |
| StatefulSet vs Deployment | ChromaDB, n8n, Ollama vs Open WebUI |
| Taints & Tolerations | GPU node scheduling for Ollama on Gundabad |
| NodeSelector / Affinity | Workload placement |
| PersistentVolume + PVC | NFS-backed storage on Aglarond |
| ClusterIP Services | Internal DNS between services |
| Ingress + TLS | nginx Ingress controller |
| DaemonSet | NVIDIA device plugin, nginx Ingress |
| ConfigMap + Secret | Service configuration, credentials |
| Readiness / Liveness Probes | Ollama model-ready detection |
| Prometheus + Grafana | Metrics, dashboards, alerting |
| Cloudflare Tunnel | Secure external access, zero open ports |
| GitOps + Flux | Phase 4 migration |
| Cross-VLAN WoL via firewall API | pfSense REST API → Gundabad power-on |
| Async / eventually-consistent pipeline | Nightly deferred batch ingestion |
| Scheduled workflows & idle-timeout control loops | n8n cron workflows for power lifecycle |
| API auth scoping & least privilege | pfSense API user scoped to WoL endpoint only |

---

## Network

- **Router/Firewall:** Khazad-dûm (pfSense)
- **Internal DNS:** `open-webui.local`, `n8n.local`, `grafana.local`
- **VLANs:** Cluster nodes on V99 (Valinor)
- **No internet egress** from cluster workloads

---

*Built with [Kubecraft](https://kubecraft.dev). All financial data stays local.*
