---
name: backup-restore-drill
description: Use for the MONTHLY single-DB test restore or the QUARTERLY full DR restore drill (BACKUP_STRATEGY.md verification checklist), or when the user asks to "test restore", "verify backups actually restore", "DR drill". Monthly restores go to scratch namespaces, quarterly full-DR to spare hardware — the prod cluster is never a restore target. Evidence-capture built in.
user-invocable: false
---

# Backup restore drill

Authoritative mechanics: `docs/BACKUP_STRATEGY.md` (per-engine restore commands) + `docs/disaster-recovery/README.md` (full DR runbook, secret decrypt, restore ordering). This skill = drill orchestration + safety rails + evidence; do NOT restate the runbook.

## Hard rails

- **Scratch namespace only** (`drill-<engine>-<date>`), delete after. NEVER restore over `databases`/app namespaces — single env = prod.
- **No app cutover.** Drill validates data, not traffic. Don't repoint Services/apps at drill DBs.
- Backups live on NAS `…/backups/homelab` (rsyncd, uid=akhozya, readable no-sudo); the worker-node → NAS replication has no second copy. Recency is by **NAME not mtime** (memory `[[reference_nas]]`).
- Verify the dump BEFORE restoring: SHA-256 + tar-list (recipe in `[[reference_nas]]`); a partial dump restoring "successfully" = false confidence.

## Monthly — one-DB test restore

1. Pick engine round-robin (PG → MySQL → CouchDB → PVC across months; note last-drilled in ANALYSIS pending table).
2. Fetch latest dump from NAS, checksum-verify.
3. Scratch restore: spin minimal single-instance DB pod in the drill ns (plain container, NOT operator CR — no CNPG/Percona churn), load dump.
   Every Kyverno ValidatingPolicy in `infrastructure/configs/kyverno-policies/` runs in Deny.
   No policy excludes the scratch ns. If the ns or pod misses any row below, Kyverno rejects the pod:

   | Policy | What the drill needs |
   |---|---|
   | `require-networkpolicy` | at least one NetworkPolicy in the drill ns, created before the pod (a deny-all ingress + egress NP fits: the drill needs no traffic) |
   | `require-non-default-serviceaccount` | a dedicated ServiceAccount |
   | `require-labels` | an `app` or `app.kubernetes.io/name` label |
   | `require-resource-limits` | cpu + memory limits on every container, init included |
   | `require-non-root`, `require-readonly-rootfs`, `require-seccomp-runtimedefault`, `require-drop-all-capabilities`, `disallow-privilege-escalation` | `runAsNonRoot` with the image's DB uid, `readOnlyRootFilesystem: true` plus emptyDir mounts for the data dir, socket dir and `/tmp`, `seccompProfile: {type: RuntimeDefault}`, `capabilities.drop: [ALL]`, `allowPrivilegeEscalation: false` |
   | `disallow-latest-tag` | a pinned image tag |

   `runAsNonRoot` also means the DB process cannot write a root-owned emptyDir. Set the pod-level
   `securityContext.fsGroup` (and `runAsUser`/`runAsGroup`) to the image's DB ids, so the kubelet
   makes the emptyDir mounts group-writable. The mount point itself stays root-owned. PostgreSQL's
   `initdb` must own its data dir. So point `PGDATA` at a subdirectory of the mount (for example
   `/var/lib/postgresql/data/pgdata`).

   | Image (variant checked in its upstream Dockerfile) | uid:gid |
   |---|---|
   | `postgres:17-bookworm` (Debian; the Alpine variants use other ids) | 999:999 |
   | `mysql:8.4-oracle` | 999:999 |
   | `couchdb:3.4.3` | 5984:5984 |
4. Validate: row/doc counts vs source (`SELECT count(*)` on 2-3 biggest tables / `_all_dbs` doc counts), schema present, one known-recent record exists (proves dump fresh, not stale husk).
5. Teardown ns. Record evidence.

## Quarterly — full DR drill

Follow `docs/disaster-recovery/README.md` § Full Recovery on **spare cluster/hardware ONLY** — it restores secrets into real namespaces and bootstraps Flux, so it can never run against the prod cluster (scratch namespaces are the monthly-drill tool, invalid here). Order: secrets decrypt (age key from 1Password) → secrets BEFORE Flux bootstrap → per-engine restores → app-level spot checks (login page, one recent record). No cutover of prod traffic.

## Evidence (mandatory — a drill without a record didn't happen)

Append to `docs/HOMELAB_HISTORY.md`: date, engine(s), dump filename + SHA, validation counts, wall time, anything broken. A failed drill = incident: root-cause via `/k8s-diagnostics`, fix the backup chain, re-drill.
