# Build Journal — Step 08: WoL Power Management & Deferred Batch Ingestion

**Date:** _TBD_  
**Nodes:** Khazad-dûm (pfSense), Gundabad (10.28.20.x), k3s-worker (n8n)  
**Status:** [ ] Planned

> **Step number is provisional.** This slots in after n8n is deployed (Phase 1) and Gundabad has joined as a GPU worker. Renumber when the intervening steps (NVIDIA device plugin, Gundabad join) are written.

---

## Objective

Make n8n able to power Gundabad on across the VLAN 20 / VLAN 99 boundary, poll it until Ollama is ready, and shut it down on an idle timeout. Then defer non-urgent PDF ingestion to a nightly batch run instead of waking Gundabad on every dropped file.

Implements **ADR-006** (cross-VLAN WoL via pfSense REST API) and **ADR-007** (deferred batch ingestion + idle-timeout power management).

---

## What's Actually Happening

WoL magic packets are Layer 2 broadcasts and don't route between VLANs. Khazad-dûm is the one device on both VLAN 99 and VLAN 20, so it originates the magic packet directly on Gundabad's broadcast domain. n8n never touches Layer 2 — it makes one authenticated HTTP POST to the pfSense REST API, and pfSense does the broadcast.

Power lifecycle is driven by three n8n workflows: on-demand wake (interactive), idle-timeout shutdown (cron), and nightly batch ingestion (cron). The staging folder on Aglarond is the ingestion queue — no database.

---

## Part A — pfSense REST API + WoL endpoint

### 1. Confirm pfSense version

```bash
# On Khazad-dûm (Diagnostics > Command Prompt, or SSH)
cat /etc/version
```

Match the package build to this version — installing a mismatched build can destabilize the firewall.

### 2. Install the REST API package

```bash
# Replace the version in the filename with YOUR pfSense version
pkg-static add https://github.com/pfrest/pfSense-pkg-RESTAPI/releases/latest/download/pfSense-<VERSION>-pkg-RESTAPI.pkg
```

### 3. Enable and scope it

- `System → REST API` — enable the API
- Create a dedicated local user for n8n (e.g. `n8n-wol`)
- Scope its privileges to the WoL endpoint only — **not** `page-all`
- Generate an API key for that user (`System → User Manager → [user]`)

### 4. Lock down access

Add a firewall rule allowing REST API access (HTTPS to Khazad-dûm) **only** from the n8n host / cluster egress source. The API surface on the firewall should not be reachable from the general network.

### 5. Find the VLAN 20 interface name

`Interfaces → Assignments` — note the internal name pfSense uses for VLAN 20 (e.g. `opt1`, `vlan20`). The WoL call needs this, not the VLAN number.

### Verify the endpoint manually

```bash
curl -sk -X POST https://10.28.99.1/api/v2/services/wake_on_lan/send \
  -H "X-API-Key: <API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"interface":"<vlan20-iface>","mac":"<gundabad-mac>"}'
```

Gundabad (powered off, WoL configured per Part B) should boot.

---

## Part B — WoL on Gundabad

### 1. BIOS/UEFI

Enable wake-on-network (often "Power On By PCI-E" / "Resume By LAN" on AMD boards), under power management. Without this, nothing downstream matters.

### 2. NIC — enable and persist

```bash
# Find the interface and check current state
ip link show
sudo ethtool <interface> | grep Wake-on    # want: Wake-on: g

# Enable magic-packet WoL
sudo ethtool -s <interface> wol g
```

Persist across reboots with a systemd unit — `/etc/systemd/system/wol.service`:

```ini
[Unit]
Description=Enable Wake on LAN
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/ethtool -s <interface> wol g
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable wol.service
sudo systemctl start wol.service
```

### 3. SSH key for n8n shutdown

n8n shuts Gundabad down over SSH (VLAN 99 → VLAN 20 is routed L3, no special handling). Add n8n's public key to Gundabad and confine the account to the shutdown command (sudoers `NOPASSWD` on `shutdown` only, ideally a dedicated user). Store the private key in n8n's credential store.

---

## Part C — n8n workflows

### Workflow 1 — On-demand wake (interactive)

```
[Trigger: interactive job needs GPU]
   → [HTTP Request: POST pfSense /api/v2/services/wake_on_lan/send]
   → [Wait + Poll: GET http://<gundabad-ip>:11434/ , continueOnFail, 10–15s interval]
        loop until 200 OR timeout ceiling
   → [Dispatch job to Ollama]
```

The poll against Ollama's port is the readiness gate — don't dispatch until it answers. Set a hard timeout so a failed boot doesn't hang the workflow.

### Workflow 2 — Idle-timeout shutdown (cron)

```
[Cron: every few minutes]
   → [Check: is Gundabad up?]  (ping / Ollama probe)
        down → exit
   → [Check: queue empty AND last job completed > IDLE_WINDOW ago?]
        no → exit
   → [Check: Gundabad uptime > MIN_UPTIME guard?]
        no → exit
   → [SSH: sudo shutdown -h now]
```

The main pipeline never shuts Gundabad down. This cron is the only thing that does. Start with `IDLE_WINDOW = 30 min`; tune from observed behavior.

### Workflow 3 — Nightly batch ingestion (cron)

```
[Cron: overnight]
   → [List staging/ on Aglarond]
        empty → exit (do NOT wake Gundabad)
   → [HTTP Request: POST pfSense WoL]  (reuse Workflow 1's wake+poll)
   → [Process each pending file in sequence: parse → chunk → embed → ChromaDB]
   → [Move processed file staging/ → archive/]   (failures stay in staging/ for retry)
   → [Idle timeout (Workflow 2) handles shutdown]
```

Daytime drops do **not** wake Gundabad — n8n just moves the file into `staging/` and stops.

---

## Folder layout on Aglarond

```
<dataset>/ingest/
  ├── staging/    # dropped, pending — this is the queue
  └── archive/    # successfully ingested
```

---

## Verification

- [ ] pfSense version confirmed, matching package installed
- [ ] API user scoped to WoL endpoint only, key generated
- [ ] Firewall rule restricts API to n8n host only
- [ ] Manual `curl` to the WoL endpoint boots Gundabad
- [ ] `ethtool` shows `Wake-on: g` and survives a reboot
- [ ] n8n SSH shutdown works against Gundabad's VLAN 20 IP
- [ ] On-demand workflow wakes + polls + dispatches end to end
- [ ] Idle-timeout cron shuts down only after the window, respects min-uptime guard
- [ ] Batch cron skips cleanly when staging/ is empty
- [ ] Batch cron processes a test file and moves it to archive/

---

## What I Observed

_TBD during build._

---

## What I Learned

_TBD during build._

---

## Issues Encountered

| Issue | Cause | Fix |
|-------|-------|-----|
|       |       |     |

---

## Next Step

_TBD._
