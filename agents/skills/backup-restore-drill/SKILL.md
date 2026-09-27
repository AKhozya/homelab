---
name: backup-restore-drill
description: Use for the MONTHLY single-DB test restore or the QUARTERLY full DR restore drill (BACKUP_STRATEGY.md verification checklist), or when the user asks to "test restore", "verify backups actually restore", "DR drill". Monthly restores go to scratch namespaces, quarterly full-DR to spare hardware — the prod cluster is never a restore target. Evidence-capture built in.
user-invocable: false
---

# Backup restore drill

Authoritative mechanics: `docs/BACKUP_STRATEGY.md` (per-engine restore commands) + `.backup/README.md` (full DR runbook, secret decrypt, restore ordering). This skill = drill orchestration + safety rails + evidence; do NOT restate the runbook.

## Hard rails

- **Scratch namespace only** (`drill-<engine>-<date>`), delete after. NEVER restore over `databases`/app namespaces — single env = prod.
- **No app cutover.** Drill validates data, not traffic. Don't repoint Services/apps at drill DBs.
- Backups live on NAS `…/backups/homelab` (rsyncd, uid=akhozya, readable no-sudo) and W2 (today-only copy, removal ~2026-07-20). Recency is by **NAME not mtime** (memory `[[reference_nas]]`).
- Verify the dump BEFORE restoring: SHA-256 + tar-list (recipe in `[[reference_nas]]`); a partial dump restoring "successfully" = false confidence.

## Monthly — one-DB test restore

1. Pick engine round-robin (PG → MySQL → CouchDB → PVC across months; note last-drilled in ANALYSIS pending table).
2. Fetch latest dump from NAS, checksum-verify.
3. Scratch restore: spin minimal single-instance DB pod in the drill ns (plain container, NOT operator CR — no CNPG/Percona churn), load dump.
4. Validate: row/doc counts vs source (`SELECT count(*)` on 2-3 biggest tables / `_all_dbs` doc counts), schema present, one known-recent record exists (proves dump fresh, not stale husk).
5. Teardown ns. Record evidence.

## Quarterly — full DR drill

Follow `.backup/README.md` § Full Recovery on **spare cluster/hardware ONLY** — it restores secrets into real namespaces and bootstraps Flux, so it can never run against the prod cluster (scratch namespaces are the monthly-drill tool, invalid here). Order: secrets decrypt (age key from 1Password) → secrets BEFORE Flux bootstrap → per-engine restores → app-level spot checks (login page, one recent record). No cutover of prod traffic.

## Evidence (mandatory — a drill without a record didn't happen)

Append to `docs/HOMELAB_HISTORY.md`: date, engine(s), dump filename + SHA, validation counts, wall time, anything broken. A failed drill = incident: root-cause via `/k8s-diagnostics`, fix the backup chain, re-drill.
