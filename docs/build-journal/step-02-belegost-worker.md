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

The control plane (Nogrod) never runs your workloads. It just decides where they go and watches that they stays healthy. Belegost does the actual work.

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

Run these from Gundabad or k3s-control:

```bash
# Both nodes should show as Ready
kubectl get nodes

# Worker shows no roles by default — label it for readability
kubectl label node k3s-worker node-role.kubernetes.io/worker=worker

# Check nodes again
kubectl get nodes
```

---

## kubectl from Gundabad

Rather than SSHing into k3s-control every time, set up kubectl on Gundabad:

```bash
# On k3s-control, get the kubeconfig
sudo cat /etc/rancher/k3s/k3s.yaml
```

Copy that file to Gundabad and save it as `~/.kube/k3s-beleriand.yaml`. Before merging, fix the server IP and rename all default entries to avoid collisions with existing cluster configs:

```bash
# On k3s-control — fix the server IP before copying
sudo cat /etc/rancher/k3s/k3s.yaml | sed 's/127.0.0.1/10.28.99.40/' > ~/k3s-beleriand.yaml

# Copy to Gundabad
scp user@10.28.99.40:~/k3s-beleriand.yaml ~/.kube/k3s-beleriand.yaml

# Rename all default entries to avoid collision on merge
sed -i 's/name: default/name: beleriand/g' ~/.kube/k3s-beleriand.yaml
sed -i 's/cluster: default/cluster: beleriand/g' ~/.kube/k3s-beleriand.yaml
sed -i 's/user: default/user: beleriand-admin/g' ~/.kube/k3s-beleriand.yaml

# Merge with existing config
KUBECONFIG=~/.kube/config:~/.kube/k3s-beleriand.yaml kubectl config view --flatten > ~/.kube/merged.yaml
mv ~/.kube/merged.yaml ~/.kube/config

# Manually verify the beleriand context points at the right cluster and user
vim ~/.kube/config

# Switch to the new context and verify
kubectl config use-context beleriand
kubectl get nodes
```

> **Key lesson:** k3s always names its kubeconfig entries `default`. Always rename them before merging or you'll get silent collisions that are painful to debug. `default` is not a safe name for anything in a multi-cluster kubeconfig.

---

## What I Observed

This is the first time I have had multiple clusters that I am administrating so instead of a fresh kube config I had to merge them together and that was tricky.

---

## What I Learned

I rediscovered the power of the sed command. When merging the new cluster into my existing config file I forgot to edit the new config file first and that caused a LOT of collisions. Basically I needed to use sed to change the control node address in the new config first. I then moved that new file onto my workstation and renamed all the uses of "default". I used the built in merge tool and made sure the new config file had the correct naming schemes.

Amazing learning lesson! Default is going to always be put there so make sure to change it off that to avoid collisions.

---

## Issues Encountered

| Issue | Cause | Fix |
|-------|-------|-----|
| Both nodes had incorrect time and were not syncing to NTP | NTP not enabled by default on fresh Ubuntu install | `sudo timedatectl set-ntp true && sudo systemctl restart systemd-timesyncd && sudo timedatectl set-timezone America/Los_Angeles` |
| kubeconfig merge caused context collisions | k3s names all entries `default` — collided with existing cluster | Renamed all entries with sed before merging, then manually verified context pointed at correct cluster and user in vim |

---

## Notes

- The node-token is a long string — copy it carefully. A single missing character and the join will fail with an authentication error.
- The worker node label (`node-role.kubernetes.io/worker=worker`) is cosmetic — it just makes kubectl output more readable. k3s doesn't apply it automatically the way it does for the control plane role.
- After this step you have a functional two-node cluster. No workloads yet, but the foundation is there.

---

## Next Step

[Step 3 — Configure NFS StorageClass pointed at Aglarond](step-03-nfs-storageclass.md)
