# Build Journal — Step 3: NFS StorageClass → Aglarond

**Date:** 6/4/2026 
**Node:** Gundabad (kubectl) + Aglarond (TrueNAS)  
**Status:** [x] Complete

---

## Objective

Configure a Kubernetes StorageClass backed by Aglarond (TrueNAS NFS). This is the storage foundation for the entire stack — every stateful service (Chroma, n8n, Ollama) will request persistent volumes through this StorageClass. No PVC should ever be created before this step is complete and verified.

---

## Why This Step Comes Before Any Workloads

This is the most important architectural principle of the stack: **decouple compute from storage**. 

If you deploy Chroma first and storage second, Chroma will start with ephemeral storage and you'll lose data when the pod restarts. Getting storage right before anything touches a disk means every workload is persistent from day one — no retrofitting, no data loss.

---

## How Kubernetes Storage Works

Three objects, always in this order:

```
StorageClass → PersistentVolume (PV) → PersistentVolumeClaim (PVC)
```

- **StorageClass** — defines *how* storage is provisioned. In this case: NFS, pointing at Aglarond. Created once, used by everything.
- **PersistentVolume (PV)** — represents actual storage capacity. Can be created manually (static) or automatically by a provisioner (dynamic).
- **PersistentVolumeClaim (PVC)** — a pod's request for storage. "I need 5GB with ReadWriteOnce access." Kubernetes matches it to a PV.

We'll use the **NFS Subdir External Provisioner** — a k8s-native provisioner that automatically creates a subdirectory on your NFS share for each PVC. Dynamic provisioning means you never manually create PVs — just write a PVC and the provisioner handles the rest.

---

## Pre-flight: Aglarond NFS Setup

Before touching Kubernetes, the NFS export needs to exist on TrueNAS.

### On Aglarond (TrueNAS UI):

1. Create a dataset for Kubernetes PVs:
   ```
   Datasets → Add Dataset
   Name: k8s-pvs
   Parent: MainPool
   ```
   Full path will be: `MainPool/k8s-pvs`

2. Create an NFS share:
   ```
   Shares → NFS → Add
   Path: /mnt/MainPool/k8s-pvs
   ```
   
   Under Advanced Options:
   - **Maproot User:** `root`
   - **Maproot Group:** `wheel`
   - **Authorized Hosts/Networks:** `10.28.99.0/24`

3. Make sure the NFS service is running:
   ```
   System → Services → NFS → Running
   ```

### Verify from k3s-control:

```bash
# Install NFS client tools on both VMs
sudo apt install nfs-common -y

# Test the mount
sudo mount -t nfs 10.28.11.10:/mnt/MainPool/k8s-pvs /mnt
df -h | grep mnt

Unmount when verified
sudo umount /mnt
```

> **Note:** Run the nfs-common install on both k3s-control and k3s-worker. Every node that might run a pod with an NFS-backed PVC needs the NFS client tools installed or the pod will fail to start.

---

## Install the NFS Subdir External Provisioner

We'll install it via Helm. Helm is a package manager for Kubernetes. A Helm chart is a pre-packaged set of manifests with configurable values.

### Install Helm:

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

### Add the NFS provisioner Helm repo:

```bash
helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
helm repo update
```

### Create a namespace for the provisioner:

```bash
kubectl create namespace nfs-provisioner
```

### Install the provisioner:

```bash
helm install nfs-subdir-external-provisioner \
  nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
  --namespace nfs-provisioner \
  --create-namespace \
  --set nfs.server=10.28.11.10 \
  --set nfs.path=/mnt/MainPool/k8s-pvs \
  --set storageClass.name=aglarond-nfs \
  --set storageClass.defaultClass=true
```

**What each value does:**
- `nfs.server` — IP of Aglarond (TrueNAS VM on V11 Glittering Caves)
- `nfs.path` — the NFS export path
- `storageClass.name=aglarond-nfs` — the StorageClass name you'll reference in PVCs
- `storageClass.defaultClass=true` — makes this the default StorageClass so PVCs without an explicit class get it automatically

```
#This is the output showing install complete
NAME: nfs-subdir-external-provisioner
LAST DEPLOYED: Thu Jun  4 10:40:42 2026
NAMESPACE: nfs-provisioner
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
TEST SUITE: None
```
---

## Verification

```bash
# Provisioner pod should be Running
kubectl get pods -n nfs-provisioner

# StorageClass should exist and show as default
kubectl get storageclass

# Expected output:
# NAME             PROVISIONER   RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
# aglarond-nfs     cluster.local/nfs-subdir...   Delete   Immediate   true   Xm
```

### Test with a real PVC:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nfs-test
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
  storageClassName: aglarond-nfs
EOF
```

Check it bound:

```bash
kubectl get pvc nfs-test
# STATUS should be Bound, not Pending
# Actual Status
#NAME       STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
#nfs-test   Bound    pvc-0e517f8d-47d0-4b93-a4c1-8ee9073844ff   1Gi        RWX            aglarond-nfs   <unset>                 11s

```


Check a directory was created on Aglarond — in TrueNAS UI browse to `MainPool/k8s-pvs` and you should see a new subdirectory.

Clean up the test PVC when done:

```bash
kubectl delete pvc nfs-test
```

---

## What I Observed


---

## What I Learned

- _What is the difference between static and dynamic provisioning? 
    Static Provisioning is done by the admin when they set PVs ahead of time. Dynamic provisioning is done by the provisioner pod that was installed when a PVC is submitted.
- _What does ReadWriteMany vs ReadWriteOnce mean and when does it matter?
   This sets access modes. Many means any pod can access the pv and once means only a single node can access. NFS supports ReadWriteMany which makes it a good option for workloads that schedule across many nodes. 
- _What happens to the data on Aglarond when a PVC is deleted? 
    It depends on the reclaim policy. The way I set it up here means that once the data is released it is deleted. If retain is used the previous claimaints data remains. The provisioner used here will keep with an archived prefix even when using the Delete policy.
- _What is Helm and how is it different from kubectl apply? Helm runs on the workstation as a client binary. It uses kubectl and generates manifests that are applied to the cluster. Helm is a package manager. 

---

## Issues Encountered

TrueNas UI doesn't show empty files so when I went to check that the test pvc has created a folder nothing will show up. I instead use kubectl describe to see if the path had been passed into the yaml and it confirmed that it was.

---

## Notes

- The NFS provisioner runs as a pod in the cluster. If it crashes, new PVCs won't provision — but existing mounted volumes keep working. 
- `storageClass.defaultClass=true` means any PVC that doesn't specify a StorageClass will use this one. That's fine for this stack since everything goes to Aglarond.
- The `ReclaimPolicy: Delete` means when a PVC is deleted, the subdirectory on Aglarond is also deleted. For production data you'd use `Retain`. We'll set `Retain` explicitly on stateful workload PVCs (Chroma, n8n) as an extra safety net.
- Aglarond's ZFS snapshots are your real safety net regardless of reclaim policy. Configure a snapshot schedule on `MainPool/k8s-pvs` in TrueNAS if you haven't already.

---

## Next Step

Step 4 — NVIDIA Device Plugin + Join Workstation as GPU Worker Node
