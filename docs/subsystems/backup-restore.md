# Backup and restore map

The policy (schedules, retention, recovery targets) is in [BACKUP_STRATEGY.md](../BACKUP_STRATEGY.md); the procedures are in the [DR runbook](../disaster-recovery/README.md). This map covers the mechanics.

## Backup layers

| Layer | What | Schedule (UTC) | Auto-discover |
|-------|------|----------------|---------------|
| **PG logical** | `pg_dump -F c` per DB (CNPG) | 03:00 daily | YES (`pg_database`) |
| **CouchDB logical** | `@cloudant/couchbackup` per DB | 03:05 daily | YES (`/_all_dbs`) |
| **PVC tarballs** | Filesystem snapshots of stateful PVCs | 03:10 daily | NO — CRITICAL_PVCS list in `infrastructure/configs/backup/pvc-backup-cronjob.yaml` |
| **MySQL logical** | `mysqldump --single-transaction` per DB (via HAProxy) | 03:15 daily | YES (`SHOW DATABASES`) |
| **PG streaming replication** | CNPG 2-instance — HA only, NOT a backup layer (no WAL/PITR by decision) | continuous | n/a |
| **Immich library** | Uncompressed tar of the NAS-resident library — `immich-backup` CronJob on **W2** pulls via the NAS `personal_folder` rsync module, tars locally, pushes to the NAS `akhozya-pool1` pool | Sun 03:00 weekly | keep-2 on both W2 + NAS pool |
| **Replication** | rsync W1 → NAS + validation + retention prune | 03:30 daily | n/a (path-agnostic) |
| **SOPS Secrets** | Encrypted in git | every commit | n/a |
| **DR scripts** | `.backup/secrets-{backup,restore}.sh` | manual | partial (explicit list) |

All backup CronJobs set `startingDeadlineSeconds: 3600`. `immich-backup` shares the NAS rsync credentials and egress NetworkPolicy of the `backup-replication` namespace.

| CronJob | Namespace | Retries |
|---|---|---|
| `backup-replication` | `backup-replication` | none: `backoffLimit: 0`, `restartPolicy: Never` |
| `pvc-backup` | `kube-system` | none: `backoffLimit: 0`, `restartPolicy: Never` |
| postgres, mysql | `databases` | `backoffLimit: 2` |
| `immich-backup` | `backup-replication` | `backoffLimit: 2` |
| couchdb | `databases` | `backoffLimit: 6` |

## PVC backup
Whitelist (CRITICAL_PVCS) + `nodeSelector: worker-node` + `hostPath /mnt/k8s-storage/backups/pvc`: `infrastructure/configs/backup/pvc-backup-cronjob.yaml`. Compression gzip, except `audiobookshelf-{audiobooks,podcasts}` = uncompressed tar (already-compressed media). Retention: there is no local age sweep. `backup-replication` deletes a type's local files on the night that type passes validation and reaches the NAS. The NAS keeps 30 days.

**Excluded by design** (the *why* matters — re-justify before re-adding):
- `immich/immich-ml-cache` (`apps/immich/ml-cache-pvc.yaml`) — regenerable ML cache (library PVC gone — NAS-resident since the Path-B cutover, covered by the weekly W2 job above)
- `uptime-kuma` — emptyDir, state in MySQL
- `claude-telegram/claude-telegram-home-pvc` — session-only state, bot rebuilds on restart
- `loki/storage-loki-0`, `monitoring/vmsingle-vmsingle` — log/metric buffers, ephemeral
- `stirling-pdf/stirling-pdf-{pipeline,tessdata}-pvc` — runtime + downloadable model data
- Redis HA PVCs — cache + queue/broker only (DB0 = BullMQ/Celery/Django sessions, DB1 = TTL'd cache)
- Blocky — no PVC; config in Secret, query log in PG `blocky` DB

## Replication topology
Source: `infrastructure/configs/backup-replication/cronjob.yaml` (script inline; NAS rsync creds + Telegram = SOPS secrets alongside).
```text
W1 /mnt/k8s-storage/backups
  └─ rsync (no --delete, --exclude='/immich/') :50555 (rsync daemon)
       → NAS (192.168.1.136, /akhozya-pool1/backups/homelab/) — 30-day history; 500GB cap (warn 400 / crit 450)
```
Validate BEFORE the sync, per type, then push to the NAS, then clean the source on W1. Immich is not a W1 source: the W2 job writes it and pushes it straight to the NAS pool.

| Type | Validation |
|---|---|
| postgres, couchdb, mysql | newest archive: age under 26 h (whole-hour age ≤ 25), SHA-256 if a `.sha256` exists, tar integrity, size floor (1 MiB, 20 KiB, 100 KiB) |
| pvc | every archive in the newest `pvc/<timestamp>/`: age under 26 h (whole-hour age ≤ 25), a `.sha256` that matches, tar integrity; the count must equal `PVC_EXPECTED` (14, the number of CRITICAL_PVCS entries). No size floor beyond 1 byte: a near-empty PVC gives a 4 KB archive. |

| Outcome | Effect |
|---|---|
| If a type fails | Replication skips that type and keeps its local files for the next night. The other types still sync and are cleaned. The Job still exits 1 and sends the Telegram report. |
| If every type fails | The run stops before the sync. |

**`--exclude='/immich/'` is load-bearing — do not drop it when editing the Step 2 rsync.** immich-backup owns that destination path; without the exclude, replication re-uploads whatever stale generations sit under W1's `immich/` (Step 4's `rm -rf` covers only postgres/couchdb/mysql/pvc) and Step 4b's keep-2 deletes them minutes later — 129G/night, both ways, for as long as the directory exists (`5f76db93`, verified 2026-07-28: 129 GiB → 120 MiB). The **leading slash anchors it to the transfer root**: unanchored `immich/` would also match a future `pvc/<ts>/immich/`. The exclude is on the *transfer* only — Step 4b still prunes the NAS immich pool to keep-2, which is the sole retention on that path (immich-backup's own keep-2 sweeps only its W2 copies). The NAS is the only destination.

**Retention prune (after validate + clean):**
- 30d postgres/mysql/couchdb — `prune_nas_file()`: rsync include-filter file-prune against empty source, targets `<cat>/<cat>_YYYYMMDD_HHMMSS.tar.gz` older than 30d
- 30d pvc dirs — `prune_nas_dir()`: rsync `-r --delete` from empty dir into `pvc/YYYYMMDD_HHMMSS/` subpaths older than 30d
- keep-2 immich — sort `immich/YYYYMMDD_HHMMSS/` descending, prune all but newest 2
- If a prune fails, the other prunes still run. The copy to the NAS has already succeeded. The run fails, and the report counts the failed prunes. Use the NAS UI to delete the files or directories that those prunes targeted; the Job log names them.
- Triple-safe against immich loss: file-prune regex requires a single `/` + DB-category allow-list (immich paths have two `/`s and aren't in `(postgres|mysql|couchdb)`)

Failure handling: trap on EXIT sends Telegram with `CURRENT_STEP`; success is silent.

## NAS quirks
- Backups go over the rsync daemon (port 50555), not SSH; auth via the `RSYNC_PASSWORD` env var. The NAS also has admin SSH on 56634, which the backup jobs do not use.
- Push uses no `--delete` (NAS accumulates history); retention only via the prune step
- Layout: `postgres/`, `mysql/`, `couchdb/` hold FLAT files `<cat>_YYYYMMDD_HHMMSS.tar.gz`; `pvc/` and `immich/` hold nested DIRS — the file-vs-dir distinction is what the prune regex keys on

## DB backup mechanics
Images pinned in each CronJob manifest (`infrastructure/configs/databases/*/`, `infrastructure/configs/backup/`).
- **Postgres:** host `main-postgres-rw`, user `postgres-admin`, format custom (`-F c`), excludes only the `postgres` DB
- **MySQL:** host `main-mysql-haproxy:3306`, user `root` (from `mysql-cluster-secrets`), excludes `information_schema`/`mysql`/`performance_schema`/`sys`; the client image tracks the server's minor line, because `renovate.json` limits its updates to that line
- **CouchDB:** npm-installs `@cloudant/couchbackup` per run, host `couchdb-couchdb.databases:5984`, `wait-for-couchdb` initContainer (30 × 2s), excludes `_*` system DBs
- Each DB backup: tar.gz + SHA256, no local age sweep (`backup-replication` deletes the local files after it verifies the NAS copy; the NAS keeps 30 days), `successfulJobsHistoryLimit: 7`, `concurrencyPolicy: Forbid`, `nodeSelector: worker-node`, `hostPath /mnt/k8s-storage/backups/<engine>`

## DR scripts (`.backup/`)
The scripts are tracked in Git; `.gitignore` excludes only their output (`.backup/secrets/`, the `.tar.gz.gpg` archives, `ENV_VARS.md`). Runbook: `docs/disaster-recovery/README.md`.

### secrets-backup.sh covers
- **CRITICAL:** SOPS age key (gates Flux decrypt of everything)
- **Cloudflare:** API token (cert-manager), tunnel credentials + config, mgmt API token
- **Monitoring:** Grafana admin, Alertmanager Telegram, VMAgent couchdb auth mirror
- **DB:** `redis-passwords` + `redis-acl-secret`; `postgres-admin-user` + PG app users (authentik, immich, linkwarden, mealie, n8n, paperless, blocky); `mysql-cluster-secrets` + uptime-kuma, pricebuddy
- **App secrets:** all apps with secrets (homepage = none by design, config in git ConfigMap)
- **Backup replication:** NAS rsync creds + Telegram
- **OIDC:** only `grafana-oidc` standalone; rest embedded in app secrets; immich/audiobookshelf store OIDC in their internal DB via web UI

New app checklist: add its secrets here or record why not.

### secrets-restore.sh sequence
1. Auto-find latest `secrets-backup-*.tar.gz.gpg` → prompt passphrase → decrypt + extract
2. SOPS age key first (gates encrypted-secret reconciliation)
3. Cluster-level: cert-manager, cloudflare-tunnel, flux-system (optional)
4. Monitoring → databases (Redis + PG users + MySQL) → per-app namespaces
5. Optional secrets via `[ -f ... ] && kubectl apply`
6. Idempotent via `kubectl create ns --dry-run=client | apply -f -`

### Encryption flow
GPG AES256 symmetric (passphrase prompt or `GPG_PASSPHRASE`); output `secrets-backup-YYYYMMDD_HHMMSS.tar.gz.gpg`; `jq` strips resourceVersion/uid/creationTimestamp/managedFields pre-encrypt; unencrypted dir auto-removed; plaintext `*.txt` extracts for fast lookup (cloudflare API, grafana admin, telegram bot, redis-immich, redis-blocky).

## Verification
- Manual run: `kubectl create job -n kube-system --from=cronjob/pvc-backup pvc-backup-manual-$(date +%s)`
- Drill: the `backup-restore-drill` skill. The 2026-05-22 test checked every archive (all PVCs, the 4 database types and Immich: checksums and tar listings); it did not extract them. Timing anchors: Immich 62.5G = tar 187 s + sha256 914 s ≈ 18 min; replication with a heavy prune ≈ 102 s. The CouchDB restore was drilled end to end on 2026-07-24 (runbook).
- Replication validates 4 backup types daily; failure → Telegram with the failed step
- Grafana dashboard: `monitoring/configs/grafana-dashboards/backup-monitoring-dashboard.yaml`
