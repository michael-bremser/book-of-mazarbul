# Build Journal — Step 2: Join Belegost as Worker Node

**Date:** 6/2/2026  
**Node:** k3s-worker VM on Belegost — SSH to 10.28.99.41  
**Status:** [x] Complete

---

## Objective

Join the k3s-worker VM on Belegost to the cluster as a general worker node. After this step the cluster has two nodes — a control plane on Nogrod and a worker on Belegost. General workloads (ChromaDB, Open WebUI, n8n, nginx Ingress, Prometheus, Grafana) will schedule here.

---

## What's Actually Happening

When a node joins a k3s cluster it runs `k3s agent` instead of `k3s server`. The agent:

- Connects to the control plane API server on k3s-control (`10.28.99.40:6443`)
- Authenticates using the node-token from Step 1
- Starts the kubelet — the process that runs on every node and takes instructions from the control plane
- Starts kube-proxy — handles network rules for Service routing on this node
- Pulls and runs whatever pods the scheduler assigns to it

The control plane (Nogrod) never runs your workloads. It just decides where they go and watches that they stay healthy. Belegost does the actual work.

---

## Pre-flight Checks

- [x] SSH into k3s-worker VM (`ssh user@10.28.99.41`)
- [x] k3s-control is reachable from k3s-worker (`ping 10.28.99.40`)
- [x] Port 6443 is reachable — this is the Kubernetes API server port (`curl -k https://10.28.99.40:6443`)
- [x] You have the node-token from Step 1 (`sudo cat /var/lib/rancher/k3s/server/node-token` on k3s-control)
- [x] Disk space healthy (`df -h` — expand LVM if needed, same as Step 1)
- [x] Swap is off (`free -h`)

---

## LVM Fix (if needed)

Same issue as Step 1 — Ubuntu LVM may not use the full disk:

```bash
sudo lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv
sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
df -h
```

---

## Command

Run this on the k3s-worker VM. Replace `<NODE_TOKEN>` with the token from k3s-control:

```bash
  curl -sfL https://get.k3s.io | K3S_URL=https://10.28.99.40:6443 K3S_TOKEN=<NODE_TOKEN> sh -s - agent --node-name k3s-worker
```

**Why each part:**
- `K3S_URL` — tells the agent where the control plane API server is
- `K3S_TOKEN` — authenticates this node to the cluster. Without this the control plane rejects the join request
- `agent` — runs k3s in agent mode, not server mode. No control plane components, just kubelet and kube-proxy
- `--node-name k3s-worker` — sets the node name to match our naming convention

---

## Verification

Run these from k3s-control (not from the worker):

```bash
# Both nodes should show as Ready
sudo kubectl get nodes

# Worker should show no roles yet — that's normal
# You can label it manually if you want
sudo kubectl label node k3s-worker node-role.kubernetes.io/worker=worker

# Check nodes again
sudo kubectl get nodes
```

---

## kubectl from Your Laptop

Rather than SSHing into k3s-control every time, set up kubectl on your laptop (or Gundabad):

```bash
# On k3s-control, get the kubeconfig
sudo cat /etc/rancher/k3s/k3s.yaml
```

Copy that file to your local machine at `~/.kube/config` and change the server line from:
```
server: https://127.0.0.1:6443
```
to:
```
server: https://10.28.99.40:6443
```

Then verify from your laptop:
```bash
kubectl get nodes
```

---

## What I Observed

This is the first time I have had multiple clusters that I am adminstrating so instead of a fresh kube config I had to merge them together and that was tricky. I'll post the details in a seperate section.

---

## What I Learned

I rediscovered the power of the sed command. When merging the the new cluster into my existing config file I forgot to edit the new config file first and that caused a LOT of collisions. I'll post how I fixed it below. Basically I needed to use sed to change the control node address in the new config first. I then moved that new file onto my workstation and renamed all the uses of "default".
I used the built in merge tool and made sure the new config file had the correct naming schemes. 
Amazing learning lesson! Default is going to always be put there so make sure to change it off that to avoid collisions.

```bash
# On k3s-control — fix the server IP before copying
sudo cat /etc/rancher/k3s/k3s.yaml | sed 's/127.0.0.1/10.28.99.40/' > ~/k3s-finai.yaml

# Copy to Gundabad
scp user@10.28.99.40:~/k3s-finai.yaml ~/.kube/k3s-finai.yaml

# Rename all default entries in the file to avoid collision
sed -i 's/name: default/name: finai/g' ~/.kube/k3s-finai.yaml
sed -i 's/cluster: default/cluster: finai/g' ~/.kube/k3s-finai.yaml
sed -i 's/user: default/user: finai-admin/g' ~/.kube/k3s-finai.yaml

# Merge with existing config
KUBECONFIG=~/.kube/config:~/.kube/k3s-finai.yaml kubectl config view --flatten > ~/.kube/merged.yaml
mv ~/.kube/merged.yaml ~/.kube/config

# Manually fix the finai context in vim to point at the right cluster/user
vim ~/.kube/config

# Switch to the new context and verify
kubectl config use-context finai
kubectl get nodes
```

---

## Issues Encountered
Both nodes had the incorrect time and were not syncing to NTP correctly. 
```bash
sudo timedatectl set-ntp true
sudo systemctl restart systemd-timesyncd
sudo timedatectl set-timezone America/Los_Angeles
timedatectl
```
---

## Notes

- The node-token is a long string — copy it carefully. A single missing character and the join will fail with an authentication error.
- The worker node label (`node-role.kubernetes.io/worker=worker`) is cosmetic — it just makes kubectl output more readable. k3s doesn't apply it automatically the way it does for the control plane role.
- After this step you have a functional two-node cluster. No workloads yet, but the foundation is there.

---

## Next Step

Step 3 — Configure NFS StorageClass pointed at Aglarond
