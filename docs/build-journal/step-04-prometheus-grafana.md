# Build Journal — Step 4: Prometheus + Grafana (Observability Stack)

**Date:** _fill in when complete_  
**Node:** Gundabad (kubectl)  
**Status:** [ ] Complete

---

## Objective

Deploy Prometheus and Grafana to the cluster using the kube-prometheus-stack Helm chart. This gives you metrics collection, dashboards, and alerting before any application workloads are deployed — meaning you can observe the cluster itself and then watch each new service come online.

---

## Why Observability Before Application Workloads

You can't operate what you can't see. Deploying Prometheus first means:

- Cluster health metrics are captured from day one
- When Ollama, ChromaDB, and n8n deploy, you immediately have visibility into their resource usage
- If something breaks during deployment, you have data to diagnose it
- Grafana dashboards are available to verify NFS storage usage as PVCs are created

---

## What's Actually Happening

**Prometheus** scrapes metrics endpoints from Kubernetes components and your workloads on a configurable interval (default 15s). It stores time-series data in its own TSDB (time-series database) — backed by a PVC on Aglarond so metrics survive pod restarts.

**Grafana** queries Prometheus and renders dashboards. It also needs a PVC for its dashboard definitions and datasource config.

**kube-prometheus-stack** is a Helm chart that bundles both together along with:
- Alertmanager — handles alert routing and notifications
- kube-state-metrics — exposes Kubernetes object state as metrics
- node-exporter — exposes host-level metrics (CPU, RAM, disk) from each node

---

## Pre-flight Checks

- [ ] NFS StorageClass `aglarond-nfs` is the cluster default (`kubectl get storageclass`)
- [ ] Helm is installed on Gundabad (`helm version`)
- [ ] kubectl context is set to finai (`kubectl config current-context`)

---

## Create Namespace

```bash
kubectl create namespace monitoring
```

---

## Add the Helm Repo

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

---

## Install kube-prometheus-stack

```bash
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=aglarond-nfs \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.accessModes[0]=ReadWriteOnce \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=10Gi \
  --set grafana.persistence.enabled=true \
  --set grafana.persistence.storageClassName=aglarond-nfs \
  --set grafana.persistence.size=2Gi \
  --set grafana.adminPassword=changeme
```

**What each value does:**
- `prometheus...storageSpec` — tells Prometheus to use a PVC on `aglarond-nfs` for its TSDB. 10GB is plenty for a homelab
- `grafana.persistence` — enables a PVC for Grafana's config and dashboards on `aglarond-nfs`
- `grafana.adminPassword` — sets the Grafana admin password. Change this to something real before deploying

> **Note:** Change `changeme` to a real password before running this command. Don't commit the actual password to the repo.

---

## Verification

```bash
# All pods should be Running
kubectl get pods -n monitoring

# PVCs should be Bound
kubectl get pvc -n monitoring

# Services should be present
kubectl get svc -n monitoring
```

### Expected pods
```
alertmanager-kube-prometheus-stack-alertmanager-0   Running
kube-prometheus-stack-grafana-xxx                   Running
kube-prometheus-stack-kube-state-metrics-xxx        Running
kube-prometheus-stack-operator-xxx                  Running
kube-prometheus-stack-prometheus-node-exporter-xxx  Running
prometheus-kube-prometheus-stack-prometheus-0       Running
```

---

## Access Grafana

Grafana is not yet exposed via Ingress (that comes in a later step). For now use port-forward:

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

Open `http://localhost:3000` in your browser. Login with `admin` and the password you set above.

---

## Dashboards to Import

The kube-prometheus-stack comes with built-in dashboards. Worth exploring:

- **Kubernetes / Compute Resources / Cluster** — overall cluster CPU and RAM
- **Kubernetes / Compute Resources / Node** — per-node resource usage (Nogrod, Belegost, Gundabad when joined)
- **Kubernetes / Persistent Volumes** — PVC usage — useful for watching Aglarond storage grow as workloads deploy
- **Node Exporter / Nodes** — host-level metrics

---

## What I Observed

_Fill in when you run it:_

```
# Paste actual output here
```

---

## What I Learned

_Fill in after completion. Examples:_
- _What is a ServiceMonitor and how does Prometheus discover what to scrape?_
- _What is the difference between Prometheus scraping and push-based metrics?_
- _What does kube-state-metrics expose that node-exporter doesn't?_
- _What is Alertmanager and how does it relate to Prometheus alerts?_

---

## Issues Encountered

| Issue | Cause | Fix |
|-------|-------|-----|
| | | |

---

## Notes

- The kube-prometheus-stack chart is large — it deploys a lot of components. Give it 2-3 minutes for all pods to reach Running state.
- Grafana's default admin username is `admin`.
- The port-forward approach is temporary. Grafana will get a proper Ingress resource when we configure nginx Ingress in a later step.
- node-exporter runs as a DaemonSet — one pod per node. Once Gundabad joins the cluster as a worker node, a node-exporter pod will automatically schedule there too.

---

## Next Step

Step 5 — NVIDIA Device Plugin + Join Gundabad as GPU Worker Node
