# ADR-007: Deferred Batch Ingestion and Idle-Timeout GPU Power Management

**Status:** Accepted  
**Date:** 2026-06-14  
**Author:** Mike

---

## Context

Gundabad (the GPU worker, RTX 3080 Ti, running Ollama) is not always-on. It is also the daily-driver workstation. The stack needs GPU inference for two distinct kinds of work:

1. **Interactive queries** — you ask Open WebUI a question and want an answer now
2. **Document ingestion** — n8n parses, chunks, and embeds dropped PDFs into ChromaDB

ADR-006 establishes *how* Gundabad gets woken (pfSense WoL API). This ADR addresses *when* it gets woken and shut down, and how ingestion work is scheduled.

Without a deliberate policy, two failure modes appear. Either Gundabad is woken and shut down on every single job — power-cycling the hardware constantly and paying the boot + OS init + model-load cost over and over — or it gets woken and never shut down, defeating the point of having it off. Naively shutting down "when the queue is empty" causes exactly the first failure: a PDF drop wakes it, it processes, shuts down, and a second drop thirty seconds later wakes it right back up.

---

## Decision

- **Wake on-demand** for interactive queries — Gundabad boots when a query needs it.
- **Shut down via idle timeout**, not immediately — only after the job queue has been empty for a continuous window, with a minimum-uptime guard after boot.
- **Defer schedulable work to a nightly batch run.** PDF ingestion and embedding are queued to a staging folder during the day and processed in a single overnight cycle. Interactive queries stay immediate.

---

## Options Considered

### Decision 1 — Shutdown timing

**Option A — Immediate shutdown when queue empties**
- *Pros:* minimal power draw; simplest shutdown logic
- *Cons:* power-cycle churn; repeatedly wastes boot/model-load overhead; races where a new job lands moments after shutdown begins

**Option B — Idle timeout (chosen)**
- *Pros:* avoids churn; amortizes boot cost across bursts of work; a new job during the window resets the clock and reuses the running instance
- *Cons:* some idle power draw during the window; needs a separate scheduled workflow to evaluate idleness

**Option C — Never auto-shutdown / leave on**
- *Pros:* zero latency, simplest of all
- *Cons:* 24/7 draw on a workstation-class GPU; defeats the entire reason Gundabad isn't in the always-on tier

### Decision 2 — Ingestion timing

**Option A — Real-time ingestion (wake on every drop)**
- *Pros:* documents queryable immediately
- *Cons:* wakes Gundabad constantly for work that has no real-time requirement; maximum churn

**Option B — Deferred nightly batch (chosen)**
- *Pros:* collapses all ingestion boot/run/shutdown overhead into one cycle per day; matches the actual urgency of the work (none); staging folder doubles as a visible, durable queue
- *Cons:* a document dropped today isn't queryable until the next morning — eventual consistency, not immediate

**Option C — Fixed-interval polling (e.g. every few hours)**
- *Pros:* middle ground; bounded staleness
- *Cons:* more wake cycles than nightly for no real benefit, since the work genuinely isn't time-sensitive

---

## Reasoning

The workload is bursty and almost entirely non-urgent. A bank statement dropped today does not need to be queryable until you actually ask about it — which in practice is days or weeks later. Treating ingestion as real-time would wake Gundabad constantly to serve a deadline that doesn't exist.

Boot, OS init, and model load are real overhead paid on every cold start. Repeatedly cycling the machine wastes that overhead and is harder on hardware than a single daily cycle or sustained operation. Batching ingestion into one nightly run pays the cold-start cost once per day instead of once per dropped file.

Separating the two workloads lets each get the right treatment. Interactive queries are the only thing a human waits on, so they keep on-demand wake and accept the cold-start latency as the price of an off-by-default GPU. Ingestion, which no human waits on, is deferred.

The idle timeout exists to handle the interactive case gracefully: a burst of questions keeps Gundabad up and reuses the loaded model, and it only powers down once you've actually stopped. The minimum-uptime guard prevents the shutdown cron from catching a machine that just booted before it has done any useful work.

The staging folder on Aglarond NFS is the ingestion queue. It needs no database: it's simple, it's visible (you can see exactly what's pending by listing the directory), and it's durable. A file that fails mid-batch stays in staging and is retried automatically on the next night's run.

---

## Consequences

- **Three n8n workflows** govern this behavior:
  1. *On-demand wake* — fired by an interactive request; wakes Gundabad (ADR-006), polls Ollama readiness, dispatches the job
  2. *Idle-timeout shutdown* — scheduled cron; shuts Gundabad down only if the queue has been empty for the configured window **and** Gundabad has been up longer than the minimum-uptime guard
  3. *Nightly batch ingestion* — scheduled cron; skips entirely if the staging folder is empty, otherwise wakes Gundabad, processes all pending files in sequence, and lets the idle timeout handle shutdown
- **Staging/archive folder structure** on Aglarond NFS: dropped files land in `staging/`, processed files move to `archive/`, failures remain in `staging/` for automatic retry
- **Configurable values**, tuned later from observed behavior:
  - Idle-timeout window (starting point: 30 minutes)
  - Minimum-uptime guard before shutdown is permitted
  - Batch run time (starting point: overnight, low-activity hours)
- **Ingestion is asynchronous and eventually-consistent.** Documents become queryable after the next batch run, not on drop. This is an explicit, accepted property of the system, not a bug
- **Interactive latency includes cold-start time** when Gundabad is off. Accepted as the cost of keeping the GPU off by default
- The README "Offline / Queue Behavior" section is superseded by this active model. n8n now *drives* Gundabad's power state rather than passively waiting for it to come online
