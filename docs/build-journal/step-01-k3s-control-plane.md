# Build Journal — Step 1: k3s Control Plane on Nogrod

**Date:** 6/2/2026  
**Node:** k3s-control VM on Nogrod — SSH to 10.28.99.40  
**Status:** [x] Complete

---

## Objective

Bootstrap the k3s control plane on Nogrod. This is the foundation — nothing else in the cluster exists until this node is running and healthy.

---

## Pre-flight Checks

Before running the install command, verify:

- [x] Nogrod is reachable on the network (`ping 10.28.99.11`)
- [x] SSH access working (`ssh user@10.28.99.40`)
- [x] At least 2GB free RAM (`free -h`)
- [x] At least 10GB free disk on `/var/lib/rancher` (`df -h`)
- [x] Hostname set correctly (`hostnamectl` should show `k3s-control`)

---

## Command

```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --disable traefik \
  --disable servicelb \
  --node-name k3s-control 
```

**Why each flag:**
- `--disable traefik` — we use nginx Ingress instead (see ADR-002)
- `--disable servicelb` — disables k3s's built-in load balancer to avoid conflicts
- `--node-name k3s-control` 

---

## Verification

```bash
# 1. k3s service is running
sudo systemctl status k3s

# 2. Node shows as Ready
sudo kubectl get nodes

# 3. Control plane pods are running
sudo kubectl get pods -n kube-system

# 4. Save the join token for Step 2
sudo cat /var/lib/rancher/k3s/server/node-token
```

###  Actual output — `kubectl get nodes`
```
NAME          STATUS   ROLES           AGE     VERSION                                                                                      │
k3s-control   Ready    control-plane   4m42s   v1.35.5+k3s1
```

### Actual output — `kubectl get pods -n kube-system`
All pods running 

---

## What I Observed

When I checked free storage I noticed that the install had not utilized all 40gb of what I had allocated. It seems like ubuntu does this to allow the user to map extra storage if needed. I'm not sure if I missed something in the installer but I ran two commands to extend the LVM 

```
sudo lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv
sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv

```

---


## Issues Encountered
See above. Had to fix storage 

---

## Notes

- The node-token saved above is a secret. In a real environment this would go into a secrets manager. For now, keep it somewhere safe — you need it to join Belegost in Step 2.
- k3s writes its kubeconfig to `/etc/rancher/k3s/k3s.yaml`. To use kubectl from your laptop, copy this file to `~/.kube/config` and update the server IP from `127.0.0.1` to `10.28.99.40`.
- The control plane node (Nogrod) has a taint by default that prevents application workloads from scheduling here. That's correct — Nogrod runs the cluster, it doesn't run your apps.

---

## Next Step

[Step 2 — Join Belegost as worker node](step-02-belegost-worker.md)
