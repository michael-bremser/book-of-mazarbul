# ADR-002: nginx Ingress over Traefik

**Status:** Accepted  
**Date:** 2026-05-31  
**Author:** Mike

---

## Context

k3s ships with Traefik as its default Ingress controller, installed automatically at bootstrap unless explicitly disabled. An Ingress controller is required to route external HTTP/HTTPS traffic to internal ClusterIP services — in this project, Open WebUI and n8n.

The decision is which Ingress controller to use, and whether to keep k3s's default.

---

## Decision

**Use nginx Ingress Controller. Disable Traefik at k3s install time.**

---

## Options Considered

### Option A — Keep Traefik (k3s default)

Accept k3s's bundled Traefik installation.

**Pros:**
- Zero additional setup — already running after k3s bootstrap
- Good automatic TLS via Let's Encrypt built in
- Clean dashboard UI
- Genuinely production-capable

**Cons:**
- Uses its own CRDs: `IngressRoute`, `Middleware`, `TLSOption` — not standard Kubernetes Ingress resources
- Kubecraft curriculum and CKA/CKAD exam teach standard `networking.k8s.io/v1 Ingress` — Traefik's abstractions are a parallel track that diverges from the canonical learning path
- Installed before it was consciously chosen — running infrastructure you didn't deliberately configure is a bad habit to form early
- Harder to cleanly remove after the fact if the decision is reversed

### Option B — nginx Ingress Controller

Install the nginx Ingress Controller (kubernetes/ingress-nginx) after disabling Traefik.

**Pros:**
- Uses standard `networking.k8s.io/v1 Ingress` resources — the same spec taught in Kubecraft, CKA, and used across the industry
- Explicitly installed and configured — every line of config is understood
- Most widely deployed Ingress controller in production Kubernetes environments
- Direct alignment with Kubecraft module content

**Cons:**
- Requires `--disable traefik` flag at k3s install time — cannot be cleanly removed after first boot
- No built-in Let's Encrypt (cert-manager handles this separately, which is the correct separation of concerns)
- Slightly more setup than accepting the default

---

## Reasoning

The core issue is learning path alignment. Traefik's `IngressRoute` CRD is a different mental model from standard Kubernetes Ingress. Learning Traefik first means unlearning it when the Kubecraft modules cover nginx-style Ingress resources. Starting with nginx means every hour spent on Ingress configuration directly reinforces the curriculum.

The second issue is intentionality. A component that installs itself before you understand it is not a component you own. Disabling Traefik and installing nginx deliberately means understanding what's running and why.

Traefik is not a wrong choice — it has genuine advantages for homelab use, particularly automatic TLS. It is the wrong choice *at this stage* of the learning path. Revisiting it after the Kubecraft Ingress modules is reasonable and the swap is straightforward.

---

## Consequences

- `--disable traefik --disable servicelb` added to k3s server install command
- nginx Ingress Controller installed as a DaemonSet in Phase 1
- Standard `Ingress` resources used throughout — no Traefik CRDs
- TLS handled by cert-manager when needed (Phase 1: self-signed or local CA; Phase 3: Cloudflare for external endpoint)
- Local DNS overrides (`webui.local`, `n8n.local`, `grafana.local`) configured on Khazad-dûm (pfSense)
- Traefik remains a candidate for Phase 3+ once nginx patterns are solid
