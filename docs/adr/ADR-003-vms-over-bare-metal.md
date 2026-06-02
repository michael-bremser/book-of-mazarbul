# ADR-003: k3s Nodes Run in Proxmox VMs, Not on Proxmox Hosts Directly

**Status:** Accepted  
**Date:** 2026-05-31  
**Author:** Mike

---

## Context

The homelab runs a three-node Proxmox cluster. k3s needs to be installed somewhere on this hardware. The question is whether k3s runs directly on the Proxmox host OS or inside VMs provisioned by Proxmox.

A third node (the workstation running a Ryzen 5600X and RTX 3080 Ti) is not part of the Proxmox cluster and runs k3s directly as a bare metal worker. GPU passthrough to a Proxmox VM is complex and adds a layer of indirection with no benefit for a single-purpose GPU workload.

---

## Decision

**Run k3s control plane and general worker nodes inside Proxmox VMs. Run the GPU worker node (workstation) on bare metal directly.**

---

## Options Considered

### Option A — k3s directly on Proxmox host OS

Install k3s on the Proxmox host itself alongside the hypervisor.

**Pros:**
- No VM provisioning step — faster to get started
- Full hardware access without virtualization layer

**Cons:**
- Proxmox and k3s share the same OS, same network stack, same process space — two complex systems interfering with each other
- Proxmox manages its own networking (bridges, VLANs) and k3s does the same — conflicts are common and hard to debug
- No snapshot capability — if k3s corrupts something at the OS level, the Proxmox host is affected
- Not how any production environment works — bad habits formed early
- Proxmox explicitly discourages running workloads directly on the host

### Option B — k3s inside Proxmox VMs (chosen)

Provision Ubuntu VMs on each Proxmox node. Install k3s inside those VMs.

**Pros:**
- Clean separation — Proxmox manages hardware, VMs manage workloads. Each layer does one job
- VM snapshots before risky operations (k3s upgrades, config changes) — instant rollback
- Cluster is fully portable — the hypervisor is invisible to k3s. Swap Proxmox for Talos, bare metal, or cloud VMs without changing a single manifest
- Mirrors how cloud Kubernetes works (EKS, GKE, AKS all run nodes as VMs)
- Standard, well-documented pattern

**Cons:**
- Extra provisioning step before k3s install
- Small virtualization overhead (~5% CPU, minimal RAM)
- VM networking adds one more layer to understand

### Option C — GPU passthrough to a Proxmox VM for the workstation

Run the GPU worker node as a Proxmox VM with the RTX 3080 Ti passed through via VFIO.

**Pros:**
- Consistent — all nodes would be VMs

**Cons:**
- GPU passthrough (VFIO/IOMMU) is complex to configure and fragile
- The workstation is dedicated to Ollama — there is no benefit to virtualizing it
- Passthrough adds a debugging layer between k3s GPU scheduling and the physical GPU
- The workstation is not always-on and not part of the Proxmox cluster — treating it differently is correct

---

## Reasoning

The VM approach isolates concerns correctly. Proxmox's job is hardware management and VM lifecycle. k3s's job is container orchestration. Mixing them on the same OS creates a maintenance surface where problems in one system affect the other.

The portability argument is significant. Because k3s runs in standard VMs with standard network interfaces, the hypervisor is completely transparent to the cluster. Migrating to Talos Linux, bare metal, or a cloud provider in the future means provisioning new compute and rejoining nodes — zero changes to manifests, StorageClasses, or application configuration. This is the correct abstraction boundary.

The workstation is the correct exception. It has a GPU that Ollama needs direct access to. GPU passthrough to a VM works but adds meaningful complexity for no benefit — the workstation runs one workload (Ollama) and there is no reason to abstract the hardware away from it.

---

## VM Specifications

| VM | Host | vCPU | RAM | Disk | OS |
|----|------|------|-----|------|----|
| nogrod-cp | Nogrod | 4 | 8GB | 40GB | Ubuntu 24.04 LTS |
| belegost-worker | Belegost | 4 | 12GB | 40GB | Ubuntu 24.04 LTS |

Remaining host RAM (24GB on Nogrod, 20GB on Belegost after upgrade to 32GB) stays available for Proxmox overhead and future VMs.

---

## Consequences

- Step 0.75 added to build order: provision VMs in Proxmox before k3s install
- All k3s manifests written to standard Kubernetes API — portable to any infrastructure
- Workstation joins cluster as a bare metal node — no Proxmox involvement
- Future hypervisor migration (e.g. Talos) is a VM reprovisioning exercise, not a cluster rebuild
- ADR to be revisited if Proxmox is replaced — VM spec carries forward regardless of hypervisor
