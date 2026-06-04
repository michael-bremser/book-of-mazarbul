# ADR-005: NFS on Aglarond as the Storage Backend

**Status:** Accepted  
**Date:** 2026-06-02  
**Author:** Mike

---

## Context

The stack has three StatefulSets (Ollama, ChromaDB, n8n) and one Deployment (Open WebUI) that all require persistent storage. Kubernetes needs a StorageClass to provision PersistentVolumes for these workloads. The choice of storage backend determines data durability, performance, operational complexity, and what happens to data when the cluster is rebuilt.

The homelab has an existing TrueNAS node (Aglarond) with a ZFS pool, connected to all Proxmox nodes and accessible on the network.

---

## Decision

**Use NFS backed by Aglarond (TrueNAS ZFS) as the storage backend. Provision via the NFS Subdir External Provisioner.**

---

## Options Considered

### Option A — local-path (k3s default)

k3s ships with a local-path provisioner that creates PVs as directories on the node's local disk.

**Pros:**
- Zero configuration — works out of the box
- Fast I/O (local disk)

**Cons:**
- Data lives on the node. If the node is rebuilt, data is lost
- Pods with local-path PVCs are pinned to the node where the data lives — can't be rescheduled to another node
- No redundancy, no snapshots, no backup integration
- Completely violates the compute/storage separation principle — the cluster and its data are coupled

### Option B — Longhorn

A distributed block storage system for Kubernetes. Replicates data across nodes for redundancy.

**Pros:**
- Highly available — data replicated across nodes
- Kubernetes-native with a good UI
- Supports snapshots and backups

**Cons:**
- Requires at least three nodes for meaningful redundancy — with two worker nodes (k3s-worker and Gundabad) replication is limited
- Significant resource overhead (CPU and RAM) on each node for the storage daemon
- Adds a complex distributed system to maintain alongside the cluster
- Overkill for a two-node homelab cluster where Aglarond already provides redundancy via ZFS

### Option C — NFS on Aglarond (chosen)

Mount a ZFS dataset on Aglarond as an NFS share. Use the NFS Subdir External Provisioner to dynamically create subdirectories for each PVC.

**Pros:**
- Data lives on Aglarond — completely independent of the k3s cluster. Rebuild the entire cluster, data is untouched
- ZFS on TrueNAS provides checksumming, compression, and snapshots — real data integrity without any cluster-level configuration
- Dynamic provisioning via the NFS Subdir External Provisioner — write a PVC, get a volume automatically
- Pods can be scheduled on any node — no data locality constraint
- Aglarond is already running and connected to all nodes — no new infrastructure required
- ReadWriteMany access mode supported — multiple pods can mount the same volume simultaneously if needed

**Cons:**
- Network I/O — slightly slower than local disk for write-heavy workloads. Acceptable for this stack (ChromaDB embeddings, n8n workflows, Ollama model files are not high-throughput workloads)
- NFS is a single point of failure — if Aglarond goes down, pods with mounted PVCs will hang. Mitigated by ZFS redundancy on Aglarond itself

---

## Reasoning

The fundamental requirement is that data survives cluster rebuilds. Gundabad (the workstation) is not always-on. The k3s VMs are intentionally disposable — they can be snapshotted and rolled back. Any storage solution that ties data to a node or to the cluster itself fails this requirement.

Aglarond is the correct home for persistent data. It exists independently of the cluster, runs ZFS for data integrity, and is already mounted and accessible across the network. NFS is the standard protocol for this pattern and the NFS Subdir External Provisioner is a well-maintained, CNCF-supported solution.

The performance tradeoff (NFS vs local disk) is acceptable for this workload. ChromaDB vector queries, n8n workflow state, and Ollama model serving are not I/O bottlenecked by NFS latency. If performance becomes an issue for a specific workload in the future, that workload can be evaluated independently.

---

## Consequences

- NFS Subdir External Provisioner installed via Helm in the `nfs-provisioner` namespace
- StorageClass named `aglarond-nfs` — set as the cluster default
- All PVCs use `aglarond-nfs` unless explicitly overridden
- StatefulSet PVCs use `ReclaimPolicy: Retain` — subdirectories on Aglarond are not deleted when PVCs are removed
- ZFS snapshot schedule configured on `MainPool/k8s-pvs` on Aglarond for point-in-time recovery
- NFS client tools (`nfs-common`) installed on all cluster nodes
