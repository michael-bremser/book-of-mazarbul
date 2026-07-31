# Build Journal — Step 5 (Experiment): Gundabad as a Kubernetes GPU Worker

**Date:** _fill in when run_
**Node:** Gundabad (bare metal — Ryzen 5600X · RTX 3080 Ti · 64GB DDR4... _wait, 32GB, see `docs/sizing.md`_)
**Status:** [ ] Not run — deferred to after 2026-08-19 CKAD exam

---

> **This is not a production step.** As of 2026-07-31, Ollama runs bare metal on
> Gundabad and the cluster consumes it via an ExternalName Service — see the
> superseded note on ADR-003 and the pending ADR that replaces it. Gundabad does
> **not** join the cluster in the current architecture: it is not always-on, and
> a workstation that's a k8s node half the time creates `NotReady` churn and
> eviction noise that teach bad instincts.
>
> This step survives anyway, repurposed as a **deliberate, timeboxed
> experiment** (~2-3 hours), not a build step in the critical path. The goal is
> resume-relevant: hands-on GPU resource scheduling — taints, tolerations, the
> NVIDIA device plugin — are skills worth having evidence for, and the ADR that
> rejects this path for production is stronger if it rejects something actually
> measured rather than something never attempted.
>
> **Rule for this experiment: it ends the way it started.** Section "Teardown"
> below is not optional cleanup, it's the point — Gundabad leaves this exercise
> exactly as available to the desktop as it was going in, and beleriand goes back
> to zero GPU nodes.

---

## Objective

Join Gundabad to beleriand as a bare-metal Kubernetes worker node, install the
NVIDIA device plugin, taint the node, and schedule a GPU pod — purely to gain
and document direct experience with GPU resource scheduling. Then tear all of
it down and confirm the cluster and Gundabad both return to their current
state. This does **not** replace bare-metal Ollama; it runs alongside it as an
isolated, time-boxed exercise.

---

## Why This Is Worth Doing At All (Given It's Not Production)

See ADR-003 for why GPU passthrough into a Proxmox VM was rejected — that
reasoning is unaffected by this change. The open question this experiment
answers is different: not "should Ollama run as a k8s workload" (answer: no,
settled) but "have I actually operated a GPU-scheduled Kubernetes workload"
(answer: not yet). The device plugin, taints/tolerations, and `nvidia.com/gpu`
resource requests are common in real ML platform work and are absent from the
rest of this repo's design. Doing this once, deliberately, closes that gap
without changing the production architecture.

---

## Pre-flight Checks

- [ ] NVIDIA drivers installed on Gundabad (`nvidia-smi` returns output — confirmed already, driver 610.43.03)
- [ ] NVIDIA Container Toolkit installed (`nvidia-ctk --version`)
- [ ] beleriand's control plane is reachable from Gundabad (`nc -zv 10.28.99.40 6443` — confirmed reachable across VLANs via pfSense)
- [ ] You have the node-token from beleriand's control plane (`sudo cat /var/lib/rancher/k3s/server/node-token` on `k3s-control`)
- [ ] `kubectl config current-context` on Gundabad is `beleriand`
- [ ] Nothing important is running that would be disrupted by a `k3s agent` process consuming CPU/network on the desktop for the duration of the experiment

---

## Install NVIDIA Container Toolkit (Manjaro / Arch, not apt)

The build journal previously listed Ubuntu `apt` commands. Gundabad runs
Manjaro — corrected to `pacman`:

```bash
# NVIDIA Container Toolkit is in the AUR
yay -S nvidia-container-toolkit
# or, if yay isn't installed:
paru -S nvidia-container-toolkit
```

Configure it for k3s (which uses containerd):

```bash
sudo nvidia-ctk runtime configure --runtime=containerd --config=/var/lib/rancher/k3s/agent/etc/containerd/config.toml
```

---

## Join Gundabad to beleriand

```bash
curl -sfL https://get.k3s.io | K3S_URL=https://10.28.99.40:6443 K3S_TOKEN=<NODE_TOKEN> sh -s - agent --node-name gundabad
```

Verify from Gundabad:

```bash
kubectl get nodes
```

Gundabad should show as `Ready` alongside `k3s-control` and `k3s-worker`.

---

## Taint the Node

```bash
kubectl taint node gundabad nvidia-gpu=true:NoSchedule
```

**What this means:** any pod without a matching toleration is rejected from
Gundabad. Only the GPU test pod below (and, if it existed, Ollama) would
tolerate it. Everything else stays on `k3s-control`/`k3s-worker`.

Verify:

```bash
kubectl describe node gundabad | grep Taint
```

---

## Install NVIDIA Device Plugin

```bash
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.0/nvidia-device-plugin.yml
```

> Check for a newer release at https://github.com/NVIDIA/k8s-device-plugin/releases before running this — v0.14.0 may be stale by the time this runs.

---

## Verification

```bash
kubectl get pods -n kube-system -o wide | grep nvidia
kubectl describe node gundabad | grep -A 10 Allocatable
```

Expected in Allocatable:
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

```bash
kubectl get pod gpu-test
kubectl logs gpu-test
```

---

## Teardown (mandatory, not optional)

This is the part that makes the experiment safe to run without supervision
concerns bleeding into the rest of the stack. Every step below must complete
before the experiment is considered done.

```bash
# 1. Remove the test pod
kubectl delete pod gpu-test

# 2. Remove the device plugin DaemonSet
kubectl delete -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.0/nvidia-device-plugin.yml

# 3. Remove the taint
kubectl taint node gundabad nvidia-gpu=true:NoSchedule-

# 4. Drain and remove Gundabad from the cluster
kubectl drain gundabad --ignore-daemonsets --delete-emptydir-data
kubectl delete node gundabad

# 5. On Gundabad: uninstall the k3s agent
sudo /usr/local/bin/k3s-agent-uninstall.sh

# 6. Confirm Gundabad is no longer a cluster member
kubectl config use-context beleriand
kubectl get nodes   # should show only k3s-control, k3s-worker
```

### Post-teardown verification

- [ ] `kubectl get nodes` on beleriand shows exactly 2 nodes, neither is Gundabad
- [ ] `systemctl status k3s-agent` on Gundabad reports not-found (uninstalled)
- [ ] `nvidia-smi` on Gundabad still works and shows the desktop GPU processes, undisturbed
- [ ] Bare-metal Ollama (if installed by then) still responds on `:11434`

---

## What I Observed

_Fill in when run:_

```
# Paste actual output here
```

---

## What I Learned

_Fill in after completion. Examples:_
- _What does the NVIDIA Container Toolkit actually do at the container runtime level, and how is that different from what happens with bare-metal Ollama + CUDA directly?_
- _What's the operational cost of a taint/toleration model versus an ExternalName — in terms of what you have to maintain, not just what you can express?_
- _Would you make the same production call again, now that you've done both?_

---

## Issues Encountered

| Issue | Cause | Fix |
|-------|-------|-----|
| | | |

---

## Notes

- This step is intentionally disconnected from the main build sequence. It does
  not block or gate anything else in the repo, and nothing later depends on it
  having been run.
- The NVIDIA device plugin version should match the CUDA driver version. Check
  compatibility at https://github.com/NVIDIA/k8s-device-plugin before running.
- If this experiment changes your mind about the production architecture, that's
  a real outcome — but it's an architecture decision, and per the project's
  guardrails, that gets made deliberately with a new ADR, not by leaving the
  experiment's state in place.

---

## Next Step

Not sequential — this experiment can run any time after 2026-08-19, independent
of the rest of the stack. The actual next production step is bare-metal Ollama
installation on Gundabad (Bucket B: needs one approval, see the replan plan).
