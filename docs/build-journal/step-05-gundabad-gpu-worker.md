# Build Journal — Step 5: Join Gundabad as Bare Metal GPU Worker Node

**Date:** _fill in when complete_  
**Node:** Gundabad (bare metal — Ryzen 5600X · RTX 3080 Ti · 64GB DDR4)  
**Status:** [ ] Complete

---

## Objective

Join Gundabad to the k3s cluster as a bare metal worker node. Install the NVIDIA device plugin so the GPU is advertised as a schedulable resource. Apply a taint to the node so only GPU workloads (Ollama) land there. Verify the GPU is visible to the Kubernetes scheduler before deploying any workload that depends on it.

---

## Why Bare Metal and Not a VM

See ADR-003. GPU passthrough to a Proxmox VM (VFIO/IOMMU) adds significant complexity for no benefit — Gundabad runs one workload (Ollama) and there is no reason to abstract the GPU away from it. Bare metal gives Ollama direct access to the RTX 3080 Ti with no virtualization layer.

---

## What's Actually Happening

Joining Gundabad to the cluster is the same `k3s agent` join as Belegost in Step 2. The difference is what comes after:

1. **NVIDIA device plugin** — a DaemonSet that runs on GPU nodes and advertises `nvidia.com/gpu` as a resource to the scheduler. Without it, Kubernetes doesn't know the GPU exists and can't schedule GPU workloads.
2. **Taint** — marks Gundabad so the scheduler won't place non-GPU pods there. Only pods with the matching toleration (Ollama) will land on Gundabad.
3. **Resource request** — Ollama's pod spec will request `nvidia.com/gpu: 1`, which the scheduler uses to find a node that has that resource available.

---

## Pre-flight Checks

- [ ] NVIDIA drivers installed on Gundabad (`nvidia-smi` returns output)
- [ ] NVIDIA Container Toolkit installed (`nvidia-ctk --version`)
- [ ] k3s-control is reachable from Gundabad (`ping 10.28.99.40`)
- [ ] You have the node-token from Step 1 (`sudo cat /var/lib/rancher/k3s/server/node-token` on k3s-control)
- [ ] kubectl context is set to finai on Gundabad (`kubectl config current-context`)

---

## Install NVIDIA Drivers (if not already installed)

```bash
# Check if drivers are already installed
nvidia-smi

# If not installed, add the NVIDIA repo and install
sudo apt install -y ubuntu-drivers-common
sudo ubuntu-drivers autoinstall
sudo reboot
```

After reboot verify:
```bash
nvidia-smi
```

You should see the RTX 3080 Ti listed with driver version and CUDA version.

---

## Install NVIDIA Container Toolkit

The NVIDIA Container Toolkit allows containers to access the GPU. Required before k3s can use it.

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt update
sudo apt install -y nvidia-container-toolkit
```

Configure it for k3s (which uses containerd):

```bash
sudo nvidia-ctk runtime configure --runtime=containerd --config=/var/lib/rancher/k3s/agent/etc/containerd/config.toml
```

---

## Join Gundabad to the Cluster

```bash
curl -sfL https://get.k3s.io | K3S_URL=https://10.28.99.40:6443 K3S_TOKEN=<NODE_TOKEN> sh -s - agent --node-name gundabad
```

Verify from Gundabad:

```bash
kubectl get nodes
```

Gundabad should show as `Ready` alongside k3s-control and k3s-worker.

---

## Taint the Node

Taint Gundabad so only GPU-tolerating pods schedule here:

```bash
kubectl taint node gundabad nvidia-gpu=true:NoSchedule
```

**What this means:** any pod without `tolerations: nvidia-gpu=true:NoSchedule` will be rejected from Gundabad. Ollama's manifest will include this toleration. Everything else runs on k3s-worker.

Verify the taint:

```bash
kubectl describe node gundabad | grep Taint
```

---

## Install NVIDIA Device Plugin

The device plugin runs as a DaemonSet and advertises the GPU to the scheduler. Apply the official manifest:

```bash
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.0/nvidia-device-plugin.yml
```

> **Note:** Check for a newer version of the device plugin at https://github.com/NVIDIA/k8s-device-plugin/releases before running this command.

The device plugin pod will only schedule on nodes with a GPU — in this cluster that's Gundabad only.

---

## Verification

```bash
# Device plugin pod should be Running on gundabad
kubectl get pods -n kube-system -o wide | grep nvidia

# GPU should be listed as an allocatable resource
kubectl describe node gundabad | grep -A 10 Allocatable
```

Expected output in Allocatable section:
```
nvidia.com/gpu:  1
```

### Test GPU scheduling with a temporary pod

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
spec:
  restartPolicy: Never
  tolerations:
  - key: nvidia-gpu
    value: "true"
    effect: NoSchedule
  containers:
  - name: gpu-test
    image: nvidia/cuda:12.0-base-ubuntu22.04
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1
EOF
```

Check the pod completed and logs show GPU info:

```bash
kubectl get pod gpu-test
kubectl logs gpu-test
```

Clean up:

```bash
kubectl delete pod gpu-test
```

---

## What I Observed

_Fill in when you run it:_

```
# Paste actual output here
```

---

## What I Learned

_Fill in after completion. Examples:_
- _What is a DaemonSet and why is the device plugin deployed as one?_
- _What is the difference between a taint and a label?_
- _What happens if a pod requests nvidia.com/gpu: 1 but no node has it available?_
- _What does the NVIDIA Container Toolkit actually do at the container runtime level?_

---

## Issues Encountered

| Issue | Cause | Fix |
|-------|-------|-----|
| | | |

---

## Notes

- Gundabad is not always-on. When it's off, the node will show `NotReady` in kubectl — that's expected and not an error. Pods that were running on Gundabad (Ollama) will be evicted after the node is offline long enough, but n8n's retry queue handles this gracefully.
- The taint is applied manually here. In a GitOps setup (Phase 4) this would be managed declaratively.
- The NVIDIA device plugin version should match your CUDA driver version. Check compatibility at https://github.com/NVIDIA/k8s-device-plugin

---

## Next Step

Step 6 — Deploy ChromaDB (StatefulSet + PVC)
