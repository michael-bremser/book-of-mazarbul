# ADR-006: Cross-VLAN Wake-on-LAN via pfSense REST API

**Status:** Accepted  
**Date:** 2026-06-14  
**Author:** Mike

---

## Context

The ingestion pipeline needs to power Gundabad on programmatically before dispatching Ollama inference jobs. Gundabad (the GPU worker) lives on VLAN 20. n8n — the thing that needs to trigger the wake — runs on the k3s cluster on VLAN 99. The two VLANs are routed at Layer 3 by Khazad-dûm (pfSense CE) but isolated at Layer 2.

Wake-on-LAN magic packets are Layer 2 broadcasts. They do not route across VLANs. A magic packet originated by n8n on VLAN 99 never reaches Gundabad's broadcast domain on VLAN 20. Something has to put the packet onto VLAN 20's broadcast domain, and n8n needs a way to trigger that over the network.

---

## Decision

**Use the pfSense REST API package's Wake-on-LAN endpoint on Khazad-dûm. n8n triggers it with a single authenticated HTTP POST. No relay VM, no directed-broadcast forwarding.**

---

## Options Considered

### Option A — Directed broadcast forwarding on pfSense

Enable directed broadcasts on pfSense and write a firewall rule to forward the L2 broadcast from VLAN 99 to VLAN 20.

**Pros:**
- No additional service or package
- n8n could broadcast the packet itself

**Cons:**
- Requires enabling directed broadcasts — a global weakening of L2 isolation to solve one narrow need
- Directed broadcast forwarding is a well-known amplification/abuse vector; turning it on is a security smell
- Still need something to actually originate and address the packet on a schedule — doesn't give a clean programmatic trigger by itself
- Fiddly rule maintenance for a one-packet job

### Option B — Dedicated WoL relay/proxy VM on VLAN 20

Stand up a small always-on VM on VLAN 20. n8n hits an HTTP endpoint on the relay; the relay broadcasts the magic packet locally on its own VLAN.

**Pros:**
- Conceptually simple — relay is on the same broadcast domain as Gundabad, so the broadcast just works
- Clean HTTP trigger for n8n

**Cons:**
- Another always-on VM to provision, patch, monitor, and back up — a whole failure domain for a one-line job
- Directly contradicts the "don't run a VM for something the firewall already does" posture (same reasoning driving the planned Barazinbar retirement)
- Adds a node whose only job is to forward a single UDP packet

### Option C — pfSense REST API WoL endpoint (chosen)

Install the community pfSense REST API package on Khazad-dûm. n8n calls its WoL endpoint; pfSense sends the magic packet out its own VLAN 20 interface.

**Pros:**
- pfSense already has an interface on every VLAN — it is the router. It can originate the magic packet directly onto VLAN 20's broadcast domain. The L2 routing problem is eliminated at the source instead of worked around
- pfSense is already always-on — no new infrastructure, no new failure domain
- Clean, authenticated HTTP API: `POST /api/v2/services/wake_on_lan/send` with interface + MAC
- Supports API key / JWT auth and per-endpoint privilege scoping
- Bonus: gives a general pfSense automation surface for future use (DHCP leases, status, config backup)

**Cons:**
- Unofficial community package — not affiliated with or supported by Netgate
- Adds an API attack surface to the firewall (mitigated below)
- Package build is version-specific — compatibility with the installed pfSense version must be checked on every pfSense upgrade

---

## Reasoning

pfSense is the one device already present on both VLANs and already always-on. Using it to originate the magic packet solves the Layer 2 problem at its root: the packet is born on the correct broadcast domain. Every other option works *around* the L2 boundary instead of using the device that already straddles it.

The relay VM solves the same problem but pays for it with a permanent maintenance burden and an extra failure domain — for a job that is fundamentally one UDP packet. That is the same logic that retires Barazinbar once pfSense can do its job: don't run a VM for something the firewall already does natively.

Directed broadcast forwarding is the worst of the three. It degrades the network's L2 isolation globally to serve one narrow need, and still doesn't hand n8n a clean trigger.

The real cost of the chosen option is a community package running on the firewall. That is a deliberate, bounded tradeoff, mitigated by scoping the API user to the WoL endpoint only, requiring key-based auth, and firewalling API access down to the n8n host.

---

## Consequences

- pfSense REST API package installed on Khazad-dûm (version matched to the installed pfSense CE build)
- A dedicated API user/key scoped to the WoL endpoint privilege only — **not** `page-all`
- A firewall rule restricts REST API access to the n8n host (or the cluster's egress source) only
- n8n calls `POST /api/v2/services/wake_on_lan/send` with the VLAN 20 interface name and Gundabad's MAC
- The pfSense API package version must be re-verified against the pfSense version on every firewall upgrade — this is now an upgrade checklist item
- The pfSense API is now in the inference pipeline's critical path. If the API is unavailable, on-demand wake fails and an interactive query degrades to "Gundabad is off." The batch path is unaffected — it simply retries on its next scheduled run
- Gundabad's NIC and BIOS must be configured for WoL (BIOS power-on-by-network enabled; NIC `wol g` set persistently). See build journal Step 08
