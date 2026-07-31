# ADR-004: StatefulSet vs Deployment for Each Service

**Status:** Accepted  
**Date:** 2026-06-02  
**Author:** Mike

---

## Context

The stack has four application services: Ollama, ChromaDB, n8n, and Open WebUI. Kubernetes offers multiple workload primitives for running containers. The two relevant ones here are Deployment and StatefulSet. The wrong choice means either lost data or unnecessary operational complexity.

---

## Decision

- **Ollama** → StatefulSet
- **ChromaDB** → StatefulSet
- **n8n** → StatefulSet
- **Open WebUI** → Deployment

---

## The Difference That Matters

**Deployment** — pods are interchangeable. If one dies, a new one is created with a new identity. No stable hostname, no ordered startup/shutdown. Designed for stateless workloads where any replica can serve any request.

**StatefulSet** — pods have stable, persistent identity. Each pod gets a predictable hostname (`pod-0`, `pod-1`), ordered startup and shutdown, and its own PersistentVolumeClaim that follows it if it's rescheduled. Designed for workloads that have state that must survive pod restarts.

The key question for each service: *does this pod need to remember who it is across restarts?*

---

## Decision Per Service

### Ollama → StatefulSet

> **Superseded 2026-07-31.** Ollama no longer runs in the cluster at all. It runs bare metal on Gundabad and is consumed as an external dependency via an ExternalName Service. See the replan context in `docs/sizing.md` and the pending ADR superseding ADR-003. The section below is kept for history, not as current design.

Ollama downloads and stores large model files (several GB each) to a local volume. If the pod is recreated with a new identity and a fresh volume, it downloads the model again on every restart — slow and wasteful. A StatefulSet with a PVC means the model files persist across pod restarts. The pod always comes back as `ollama-0` with the same volume attached.

Additionally, Ollama runs on Gundabad (the GPU worker node) via a taint/toleration. A stable pod identity makes scheduling predictable.

### ChromaDB → StatefulSet

ChromaDB is a vector database. It stores embeddings of all ingested financial documents on disk. If the pod restarts with ephemeral storage, all embeddings are lost — every document would need to be re-ingested. A StatefulSet with a PVC on Aglarond means the vector store survives pod restarts, node reboots, and cluster rebuilds.

This is the most critical StatefulSet in the stack. Losing ChromaDB data means losing all indexed financial history.

### n8n → StatefulSet

n8n stores workflow definitions, execution history, credentials, and queued job state in a local SQLite database (or Postgres, but SQLite is the default). If the pod restarts with a fresh volume, all workflows are lost and any queued ingestion jobs are dropped. A StatefulSet with a PVC ensures workflow state, credentials, and the job queue persist across restarts.

n8n is the ingestion pipeline operator — losing its state means losing the automation that makes the stack useful daily.

### Open WebUI → Deployment

Open WebUI is a stateless frontend. It holds no financial data and no application state of its own — it's a browser-based chat interface that proxies requests to Ollama. Conversation history is stored in a volume, but the pod itself is interchangeable. If it restarts, nothing is lost and the user just refreshes the browser.

A Deployment is correct here. It's simpler, easier to update, and stateless frontends don't benefit from the stable identity that StatefulSets provide.

> Note: Open WebUI does mount a volume for conversation history. That volume is a PVC, but the pod itself doesn't need stable identity to use it — any replica can mount the same volume. This is different from ChromaDB and n8n where the pod's identity and its data are tightly coupled.

---

## Consequences

- Three StatefulSets (Ollama, ChromaDB, n8n) with PVCs backed by Aglarond NFS
- One Deployment (Open WebUI) with a PVC for conversation history
- All PVCs use the `aglarond-nfs` StorageClass
- StatefulSet PVCs use `ReclaimPolicy: Retain` — data is not deleted when the PVC is deleted
- Understanding this distinction is directly applicable to CKA/CKAD exam content and production Kubernetes work
