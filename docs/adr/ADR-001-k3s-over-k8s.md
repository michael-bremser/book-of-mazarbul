# ADR-001: k3s over full Kubernetes

**Status:** Accepted  
**Date:** 2026-05-31  
**Author:** Mike

---

## Context

The stack requires a Kubernetes cluster running across homelab nodes — a Proxmox cluster with two Lenovo M70q machines (Nogrod, Belegost) and a Ryzen workstation. The cluster will run a RAG pipeline for personal financial data: Ollama, ChromaDB, Open WebUI, and n8n.

Two options were evaluated: full upstream Kubernetes (kubeadm) or k3s (lightweight Kubernetes by Rancher).

---

## Decision

**Use k3s.**

---

## Options Considered

### Option A — Full Kubernetes (kubeadm)

The upstream Kubernetes distribution, installed via kubeadm.

**Pros:**
- Identical to production enterprise environments
- No abstraction layer between you and upstream k8s primitives
- Maximum compatibility with all tooling

**Cons:**
- Control plane alone consumes ~2–3GB RAM across its components (API server, etcd, scheduler, controller manager as separate processes)
- Significantly more complex to bootstrap — kubeadm init, CNI installation, token management
- Heavier operational overhead for a homelab with modest hardware (32GB per node)
- Overkill for a two-node + one workstation cluster

### Option B — k3s

A CNCF-certified lightweight Kubernetes distribution. Packages the entire control plane into a single binary (~100MB). Designed for edge, IoT, and resource-constrained environments.

**Pros:**
- Single binary install — `curl | sh` bootstrap
- Control plane uses ~512MB RAM vs ~2–3GB for full k8s
- Ships with a working CNI (Flannel) and a local storage provisioner out of the box
- 100% Kubernetes API compliant — every kubectl command, every manifest, every concept transfers directly to full k8s
- Used in production at scale (Rancher, many edge deployments)
- Well-supported in Kubecraft curriculum

**Cons:**
- Bundles Traefik and ServiceLB by default — must be disabled at install time if not wanted (see ADR-002)
- Slight abstraction from upstream — etcd is replaced by SQLite by default (switchable to etcd for HA)
- Not what you'd install on a large enterprise cluster

---

## Reasoning

The hardware constraint is real — 32GB per node means the control plane overhead of full k8s is meaningful. k3s's ~512MB footprint leaves the nodes free for actual workloads.

More importantly: k3s is fully Kubernetes API compliant. Every manifest written for this project runs unchanged on a full k8s cluster. Every concept learned — StatefulSets, PVCs, taints, Ingress, RBAC — is identical. k3s is not a different thing; it is Kubernetes, packaged differently.

The Kubecraft curriculum covers k3s explicitly. Running it here means coursework and homelab reinforce each other directly.

The one genuine tradeoff is etcd. k3s uses SQLite by default, which is not suitable for multi-master HA. For a single control plane node (Nogrod) this is irrelevant. If the project later expands to a multi-master setup, migrating to embedded etcd is a supported k3s operation.

---

## Consequences

- k3s installed on Nogrod as the control plane node
- Belegost and the workstation join as worker nodes via `k3s agent`
- Traefik and ServiceLB disabled at install time (see ADR-002)
- All manifests written to standard Kubernetes API — portable to full k8s without modification
- SQLite datastore is acceptable for single control plane node; revisit if adding a second control plane
