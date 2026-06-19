# Build Journal — Step 7: Deploy n8n + Open WebUI and Expose via nginx Ingress

**Date:** _fill in when complete_  
**Node:** Gundabad (kubectl), workloads land on k3s-worker  
**Status:** [ ] Complete

---

## Objective

Deploy the application tier — n8n (ingestion/automation) and Open WebUI (chat frontend) — then put nginx Ingress in front of the cluster with TLS via cert-manager and local DNS overrides on Khazad-dûm. After this step the stack is reachable at friendly names (`open-webui.local`, `n8n.local`) and the Phase 1 core stack is complete.

---

## Why This Order

See ADR-002 (nginx over Traefik) and ADR-004 (StatefulSet decisions).

n8n and Open WebUI both depend on Step 6: n8n embeds via Ollama and stores vectors in ChromaDB; Open WebUI proxies chat to Ollama. So the data/inference tier had to exist first. Ingress comes last because there's nothing to route to until the services are up.

- **n8n → StatefulSet.** It holds workflow definitions, credentials, and queued job state in a local SQLite DB. Losing that loses the automation. (ADR-004)
- **Open WebUI → Deployment.** Stateless frontend. It mounts a PVC for conversation history, but the pod itself is interchangeable — any replica can mount the same volume. (ADR-004)

---

## What's Actually Happening

All three pieces land on k3s-worker (no GPU toleration). nginx Ingress terminates external HTTP/HTTPS and routes by hostname to the right ClusterIP service. Because ServiceLB was disabled at k3s install (ADR-001/002) and there's no cloud load balancer, the ingress controller runs as a **DaemonSet using hostPorts** — it binds 80/443 directly on the node, and DNS points the `.local` names at that node's IP.

cert-manager issues certs. In Phase 1 that's a self-signed local issuer — internal-only, no public CA needed. Phase 3 adds Cloudflare for the one external endpoint.

---

## Pre-flight Checks

- [ ] Step 6 complete — ChromaDB and Ollama pods Running, Services resolve
- [ ] kubectl context is `beleriand`
- [ ] Helm installed on Gundabad (`helm version`)
- [ ] Decide the node that owns the ingress hostPort (k3s-worker, `10.28.99.41`) — DNS will point here

---

## n8n

`manifests/n8n/n8n.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: n8n
  namespace: mazarbul
spec:
  clusterIP: None
  selector:
    app: n8n
  ports:
  - port: 5678
    targetPort: 5678
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: n8n
  namespace: mazarbul
spec:
  serviceName: n8n
  replicas: 1
  selector:
    matchLabels:
      app: n8n
  template:
    metadata:
      labels:
        app: n8n
    spec:
      containers:
      - name: n8n
        image: n8nio/n8n:latest        # PIN to a released version
        ports:
        - containerPort: 5678
        env:
        - name: N8N_HOST
          value: n8n.local
        - name: N8N_PORT
          value: "5678"
        - name: N8N_PROTOCOL
          value: https
        - name: WEBHOOK_URL
          value: https://n8n.local/     # revisit in Phase 3 when Cloudflare Tunnel fronts webhooks
        - name: GENERIC_TIMEZONE
          value: America/Los_Angeles
        volumeMounts:
        - name: n8n-data
          mountPath: /home/node/.n8n
        readinessProbe:
          httpGet:
            path: /healthz
            port: 5678
          initialDelaySeconds: 15
          periodSeconds: 10
  volumeClaimTemplates:
  - metadata:
      name: n8n-data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: aglarond-nfs
      resources:
        requests:
          storage: 5Gi
```

```bash
kubectl apply -f manifests/n8n/n8n.yaml
```

> n8n defaults to SQLite on the mounted volume (ADR-004) — no external DB needed at this scale. The pfSense API key and Gundabad SSH key from Step 8 get configured later inside n8n's credential store, not in this manifest.

---

## Open WebUI

`manifests/open-webui/open-webui.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: open-webui-data
  namespace: mazarbul
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: aglarond-nfs
  resources:
    requests:
      storage: 2Gi
---
apiVersion: v1
kind: Service
metadata:
  name: open-webui
  namespace: mazarbul
spec:
  selector:
    app: open-webui
  ports:
  - port: 80
    targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: open-webui
  namespace: mazarbul
spec:
  replicas: 1
  selector:
    matchLabels:
      app: open-webui
  template:
    metadata:
      labels:
        app: open-webui
    spec:
      containers:
      - name: open-webui
        image: ghcr.io/open-webui/open-webui:main   # PIN to a released tag, not main
        ports:
        - containerPort: 8080
        env:
        - name: OLLAMA_BASE_URL
          value: http://ollama.mazarbul.svc.cluster.local:11434
        volumeMounts:
        - name: data
          mountPath: /app/backend/data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: open-webui-data
```

```bash
kubectl apply -f manifests/open-webui/open-webui.yaml
```

> A Deployment uses a standalone PVC, not a volumeClaimTemplate — that's the StatefulSet/Deployment difference from ADR-004 in concrete form. With a single replica on `aglarond-nfs` (RWO) this is clean. If you ever scale to >1 replica, the PVC would need ReadWriteMany.

---

## cert-manager (self-signed, Phase 1)

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true
```

`manifests/ingress/selfsigned-issuer.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
```

```bash
kubectl apply -f manifests/ingress/selfsigned-issuer.yaml
```

> Self-signed means browsers will warn — acceptable for an internal-only Phase 1. A local CA (issue a CA once, trust it on your devices) is the cleaner next move if the warnings annoy you. Public certs are out of scope until Phase 3 / Cloudflare.

---

## nginx Ingress Controller

ServiceLB is disabled, so run the controller as a DaemonSet binding hostPorts on the node:

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.kind=DaemonSet \
  --set controller.hostPort.enabled=true \
  --set controller.service.enabled=false
```

This binds 80/443 on whatever node(s) the DaemonSet runs. The ingress endpoint is the node IP — `10.28.99.41` (k3s-worker).

---

## Ingress Resources

`manifests/ingress/mazarbul-ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: open-webui
  namespace: mazarbul
  annotations:
    cert-manager.io/cluster-issuer: selfsigned
spec:
  ingressClassName: nginx
  tls:
  - hosts: [open-webui.local]
    secretName: open-webui-tls
  rules:
  - host: open-webui.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: open-webui
            port:
              number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: n8n
  namespace: mazarbul
  annotations:
    cert-manager.io/cluster-issuer: selfsigned
spec:
  ingressClassName: nginx
  tls:
  - hosts: [n8n.local]
    secretName: n8n-tls
  rules:
  - host: n8n.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: n8n
            port:
              number: 5678
```

```bash
kubectl apply -f manifests/ingress/mazarbul-ingress.yaml
```

> Standard `networking.k8s.io/v1 Ingress` resources — no Traefik CRDs (ADR-002). Grafana from Step 4 can get a matching `grafana.local` Ingress here too, retiring its port-forward.

---

## Local DNS on Khazad-dûm

The `.local` names resolve via pfSense, pointing at the ingress node:

- `Services → DNS Resolver → General Settings → Host Overrides`
- Add `open-webui.local`, `n8n.local` (and `grafana.local`) → `10.28.99.41`

> Pi-hole at 10.28.99.20 is the network's internal DNS (per topology). If clients resolve through Pi-hole rather than directly against pfSense, add the host overrides there (Local DNS → DNS Records) instead — or forward `.local` from Pi-hole to pfSense. Confirm which resolver your VLAN actually hands out before assuming.

---

## Verification

```bash
# All app-tier pods Running
kubectl get pods -n mazarbul

# Ingress controller DaemonSet up, ingresses have an address
kubectl get pods -n ingress-nginx -o wide
kubectl get ingress -n mazarbul

# Certs issued
kubectl get certificate -n mazarbul

# From a client on the network:
curl -k https://open-webui.local
curl -k https://n8n.local/healthz
```

Open `https://open-webui.local` in a browser, confirm it loads and can see the Ollama model pulled in Step 6. Open `https://n8n.local`, confirm the editor loads and persists a test workflow across a pod restart.

---

## What I Observed

_Fill in when you run it:_

```
# Paste actual output here
```

---

## What I Learned

_Fill in after completion. Examples:_
- _Why does the ingress controller need hostPort here instead of a LoadBalancer Service?_
- _What does cert-manager's ClusterIssuer actually do when an Ingress references it via annotation?_
- _Why is Open WebUI a Deployment with a standalone PVC while n8n is a StatefulSet with a volumeClaimTemplate?_
- _Where does DNS resolution actually happen for open-webui.local — Pi-hole, pfSense, or both?_

---

## Issues Encountered

| Issue | Cause | Fix |
|-------|-------|-----|
|       |       |     |

---

## Notes

- This completes the Phase 1 core stack. Step 8 (WoL power management) is the next piece and depends on both n8n (the workflow engine) and Ollama's readiness endpoint being in place.
- The `WEBHOOK_URL` on n8n is set for the internal name now. Phase 3 (Cloudflare Tunnel) changes this for the externally-reachable webhook endpoint only — everything else stays internal.
- Self-signed TLS is a deliberate Phase 1 shortcut. Note it here so it's a conscious revisit, not a forgotten loose end.

---

## Next Step

[Step 8 — WoL Power Management & Deferred Batch Ingestion](step-08-wol-power-management.md)
