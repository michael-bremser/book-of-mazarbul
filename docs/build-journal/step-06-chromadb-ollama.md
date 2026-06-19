# Build Journal — Step 6: Deploy ChromaDB and Ollama

**Date:** _fill in when complete_  
**Node:** Gundabad (kubectl), workloads land on k3s-worker (ChromaDB) and Gundabad (Ollama)  
**Status:** [ ] Complete

---

## Objective

Deploy the two stateful core services: ChromaDB (the vector store) on k3s-worker, and Ollama (GPU inference) on Gundabad. Both are StatefulSets with PVCs backed by Aglarond NFS. After this step the RAG pipeline has a place to store embeddings and a model to generate them — the application tier (n8n, Open WebUI) in Step 7 depends on both being up.

---

## Why These Two First

See ADR-004 (StatefulSet decisions) and ADR-005 (NFS storage backend).

ChromaDB and Ollama are the data and compute foundation. n8n can't embed anything without Ollama, and it can't store anything without ChromaDB. Open WebUI proxies to Ollama. So both go in before the application tier. They're independent of each other, so the order within this step doesn't matter — ChromaDB just happens to be the simpler one.

Both are **StatefulSets** because both hold state that must survive pod restarts: ChromaDB stores every embedding (losing it means re-ingesting all documents), Ollama stores multi-GB model files (losing them means re-downloading on every restart). See ADR-004 for the full reasoning per service.

---

## What's Actually Happening

- **ChromaDB** runs on k3s-worker (no GPU toleration, so the scheduler keeps it off Gundabad). Its PVC on `aglarond-nfs` holds the vector store. This is the most critical data in the stack.
- **Ollama** runs on Gundabad only. The node taint from Step 5 (`nvidia-gpu=true:NoSchedule`) repels everything else; Ollama carries the matching toleration and requests `nvidia.com/gpu: 1`, which only Gundabad advertises. Its PVC holds the model files.
- Both expose a **headless Service** (`clusterIP: None`) that other pods reach by name — `chromadb:8000`, `ollama:11434`.

> **Note on Ollama + NFS:** model files live on Aglarond NFS, not local disk. ADR-005 accepted this tradeoff — model serving isn't NFS-latency-bound, and keeping models on Aglarond means they survive a Gundabad rebuild. If first-token latency ever looks NFS-bound, this is the first thing to re-evaluate.

> **Note on Gundabad being off:** Ollama's pod will show `Pending`/evicted whenever Gundabad is powered down. That's expected — Step 8 (WoL) is what wakes Gundabad on demand and the idle timeout shuts it back down. Don't treat a Pending Ollama pod as a failure when Gundabad is off.

---

## Pre-flight Checks

- [ ] kubectl context is `beleriand` (`kubectl config current-context`)
- [ ] `aglarond-nfs` StorageClass exists and is default (`kubectl get storageclass`)
- [ ] Gundabad shows `nvidia.com/gpu: 1` allocatable (`kubectl describe node gundabad | grep -A6 Allocatable`) — from Step 5
- [ ] Gundabad is powered on for this step (so the Ollama pod can actually schedule and pull a model)
- [ ] `mazarbul` namespace exists (created below if not)

---

## Namespace

```bash
kubectl create namespace mazarbul
```

Manifest equivalent for `manifests/namespaces/mazarbul.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mazarbul
```

---

## ChromaDB

`manifests/chroma/chromadb.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: chromadb
  namespace: mazarbul
spec:
  clusterIP: None          # headless — clients resolve chromadb:8000 to the pod
  selector:
    app: chromadb
  ports:
  - port: 8000
    targetPort: 8000
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: chromadb
  namespace: mazarbul
spec:
  serviceName: chromadb
  replicas: 1
  selector:
    matchLabels:
      app: chromadb
  template:
    metadata:
      labels:
        app: chromadb
    spec:
      containers:
      - name: chromadb
        image: chromadb/chroma:latest    # PIN to a released version — :latest will bite a StatefulSet
        ports:
        - containerPort: 8000
        env:
        - name: IS_PERSISTENT
          value: "TRUE"
        - name: PERSIST_DIRECTORY
          value: /data
        - name: ANONYMIZED_TELEMETRY
          value: "FALSE"
        volumeMounts:
        - name: chroma-data
          mountPath: /data
        readinessProbe:
          httpGet:
            path: /api/v1/heartbeat
            port: 8000
          initialDelaySeconds: 10
          periodSeconds: 10
  volumeClaimTemplates:
  - metadata:
      name: chroma-data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: aglarond-nfs
      resources:
        requests:
          storage: 10Gi
```

```bash
kubectl apply -f manifests/chroma/chromadb.yaml
```

> Confirm the heartbeat path against the ChromaDB image version you pin — older/newer images have moved the API version prefix. If `/api/v1/heartbeat` 404s, check the image's docs for the current path.

---

## Ollama

`manifests/ollama/ollama.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: mazarbul
spec:
  clusterIP: None
  selector:
    app: ollama
  ports:
  - port: 11434
    targetPort: 11434
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ollama
  namespace: mazarbul
spec:
  serviceName: ollama
  replicas: 1
  selector:
    matchLabels:
      app: ollama
  template:
    metadata:
      labels:
        app: ollama
    spec:
      tolerations:
      - key: nvidia-gpu
        value: "true"
        effect: NoSchedule        # matches the taint from Step 5
      containers:
      - name: ollama
        image: ollama/ollama:latest   # PIN to a released version
        ports:
        - containerPort: 11434
        resources:
          limits:
            nvidia.com/gpu: 1         # pulls the pod to Gundabad — only node advertising a GPU
        volumeMounts:
        - name: ollama-models
          mountPath: /root/.ollama
        readinessProbe:
          httpGet:
            path: /api/tags
            port: 11434
          initialDelaySeconds: 15
          periodSeconds: 15
  volumeClaimTemplates:
  - metadata:
      name: ollama-models
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: aglarond-nfs
      resources:
        requests:
          storage: 50Gi             # model files are large — size for the models you plan to run
```

```bash
kubectl apply -f manifests/ollama/ollama.yaml
```

### Pull a model into the volume

The pod starts with an empty model directory. Pull a model so it persists on the PVC:

```bash
kubectl exec -n mazarbul ollama-0 -- ollama pull <model>
kubectl exec -n mazarbul ollama-0 -- ollama list
```

> **Model sizing:** Gundabad's RTX 3080 Ti has 12GB VRAM. A 7B–8B class model fits comfortably; larger models need aggressive quantization or will spill and slow down. Pick the model based on what fits — this isn't the place to guess, check the model's published memory footprint.

> **Readiness nuance:** the `/api/tags` probe only confirms the Ollama *server* is answering — not that a model is loaded into VRAM and ready to generate. That's fine here: it gates Service routing. The deeper "model actually ready" gate lives in Step 8's n8n poll, which waits on a real readiness signal before dispatching. Don't over-engineer the probe; let the pipeline handle warm-up.

---

## Verification

```bash
# ChromaDB pod Running on k3s-worker, Ollama pod Running on gundabad
kubectl get pods -n mazarbul -o wide

# Both PVCs Bound
kubectl get pvc -n mazarbul

# ChromaDB answers
kubectl exec -n mazarbul chromadb-0 -- wget -qO- http://localhost:8000/api/v1/heartbeat

# Ollama answers and lists the pulled model
kubectl exec -n mazarbul ollama-0 -- ollama list

# Service DNS resolves from another pod
kubectl run -n mazarbul dns-test --rm -it --image=busybox --restart=Never -- \
  nslookup ollama.mazarbul.svc.cluster.local
```

Confirm on Aglarond that subdirectories were provisioned for both PVCs under the NFS export.

---

## What I Observed

_Fill in when you run it:_

```
# Paste actual output here
```

---

## What I Learned

_Fill in after completion. Examples:_
- _Why does a headless Service (clusterIP: None) resolve to pod IPs instead of a virtual IP, and why does a StatefulSet want that?_
- _How does the scheduler decide Ollama lands on Gundabad — is it the toleration, the GPU resource request, or both?_
- _What happens to the Ollama pod when Gundabad powers off, and why is that not a failure?_
- _Why pin image tags on a StatefulSet specifically?_

---

## Issues Encountered

| Issue | Cause | Fix |
|-------|-------|-----|
|       |       |     |

---

## Notes

- Both StatefulSets inherit `ReclaimPolicy: Retain` behavior from the `aglarond-nfs` StorageClass (ADR-005) — deleting a PVC does not delete the data on Aglarond. Cleanup is manual and deliberate.
- ChromaDB is the single most critical data store in the stack. Confirm the ZFS snapshot schedule on Aglarond (`MainPool/k8s-pvs`, per ADR-005) actually covers its subdirectory before trusting it with real ingested data.
- Ollama on NFS is the one performance compromise in the storage design. Logged here so it's the first suspect if inference latency disappoints.

---

## Next Step

[Step 7 — Deploy n8n + Open WebUI and expose via nginx Ingress](step-07-n8n-openwebui-ingress.md)
