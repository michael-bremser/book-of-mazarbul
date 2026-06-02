# Build Journal — Step 0.75: Provision Proxmox VMs

**Date:** _fill in when complete_  
**Nodes:** Nogrod (10.28.99.11), Belegost (10.28.99.12)  
**Status:** [ ] Complete

---

## Objective

Provision two Ubuntu VMs in Proxmox — one on Nogrod for the k3s control plane, one on Belegost for the k3s worker node. These VMs are the actual machines k3s will run on. The Proxmox hosts themselves stay clean.

---

## Why VMs and Not the Proxmox Host Directly

See ADR-003. Short version: Proxmox and k3s both manage networking and processes. Running them on the same OS causes conflicts and makes both harder to troubleshoot. VMs give you a clean separation, snapshot capability, and a portable cluster that doesn't care what hypervisor is underneath.

---

## VM Specifications

| VM | Host | vCPU | RAM | Disk | OS | Purpose |
|----|------|------|-----|------|----|---------|
| k3s-control | Nogrod | 4 | 8GB | 40GB | Ubuntu 24.04 LTS | k3s control plane |
| k3s-worker | Belegost | 4 | 12GB | 40GB | Ubuntu 24.04 LTS | k3s general worker |

---

## Steps — Nogrod (repeat for Belegost with worker specs)

### 1. ISO Location

ISO is stored on Aglarond, which is connected to all Proxmox nodes. When selecting the ISO during VM creation, choose Aglarond from the storage dropdown and select the Ubuntu 24.04 LTS server ISO.

### 2. Create the VM

```
Datacenter → Nogrod → Create VM
```

Settings:
- **Name:** `k3s-control`
- **OS:** Ubuntu 24.04 ISO from Aglarond storage
- **System:** leave defaults (BIOS: SeaBIOS, SCSI controller: VirtIO SCSI)
- **Disk:** 40GB, storage: local-lvm, bus: VirtIO
- **CPU:** 4 cores
- **RAM:** 8192 MB (8GB) — no ballooning
- **Network:** VirtIO, bridge: vmbr0, VLAN tag: 99

### 3. Install Ubuntu

Start the VM and open the console. Ubuntu Server install:

- Language: English
- Network: configure static IP
  - **k3s-control:** `10.28.99.40/24`, gateway `10.28.99.1`, DNS `10.28.99.1`
  - **k3s-worker:** `10.28.99.41/24`, gateway `10.28.99.1`, DNS `10.28.99.1`
- Storage: use entire disk, LVM
- Profile: set username and password, hostname matches VM name (`k3s-control` / `k3s-worker`)
- **Enable OpenSSH server: yes**
- Snaps: skip everything

### 4. Post-install configuration

> **Note:** k3s handles most of these steps automatically at install time. Running them manually first isn't strictly required — but doing it consciously means you understand what k3s is relying on. If something breaks later, you'll know the prerequisites are already met. These are also the same steps you'd run manually on any Kubernetes distribution that *doesn't* handle them for you (kubeadm, RKE2, etc.).

SSH into each VM and run:

```bash
# Update packages
sudo apt update && sudo apt upgrade -y

# Set hostname explicitly
sudo hostnamectl set-hostname k3s-control   # or k3s-worker on Belegost

# Disable swap — Kubernetes requires this
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Verify swap is off
free -h   # Swap line should show 0

# Enable required kernel modules
sudo modprobe overlay
sudo modprobe br_netfilter

# Make them persistent
cat <<EOF | sudo tee /etc/modules-load.d/k3s.conf
overlay
br_netfilter
EOF

# Required sysctl settings for k8s networking
cat <<EOF | sudo tee /etc/sysctl.d/k3s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

### 5. Take a snapshot

Before installing k3s, snapshot both VMs in Proxmox. Name it `pre-k3s-install`. If anything goes wrong during k3s setup, you have a clean restore point.

```
Proxmox UI → VM → Snapshots → Take Snapshot
Name: pre-k3s-install
```

---

## Verification

- [x] Both VMs reachable via SSH from your laptop
- [x] `k3s-control` at `10.28.99.40`, `k3s-worker` at `10.28.99.41`
- [x] Hostnames correct (`hostnamectl`)
- [x] Swap disabled (`free -h`)
- [x] Kernel modules loaded (`lsmod | grep -E 'overlay|br_netfilter'`)
- [x] Snapshots taken on both VMs

---

## What I Observed

This being my first deployment outside of learning in class, this has been a enlightening process. A lot of the skills that I learned from linux commands, tmux, and vim really get to come together finally. 
I also noticed that the snapshot for the worker node went up to 7gb while the control node finished really quickly. Not sure why but I think its important to note.

```
# Paste relevant output here
```

---

## What I Learned

Kubernetes does not seem like to like having a swap file setup. It seems like that is because the control plane doesn't want anything that is not directly under its control. If a pod uses up too much RAM then it should get an OOM reponse instead of being able to dip into swap. 

---

## Issues Encountered

| Issue | Cause | Fix |
|-------|-------|-----|
| | | |

---

## Next Step

[Step 1 — k3s control plane on k3s-control VM](step-01-k3s-control-plane.md)
