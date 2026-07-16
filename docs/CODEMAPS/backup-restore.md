# Backup / Restore Codemap

## Backup layers

| Layer | What | Schedule (UTC) | Auto-discover |
|-------|------|----------------|---------------|
| **PG logical** | `pg_dump -F c` per DB (CNPG) | 03:00 daily | YES (`pg_database`) |
| **CouchDB logical** | `@cloudant/couchbackup` per DB | 03:05 daily | YES (`/_all_dbs`) |
| **PVC tarballs** | Filesystem snapshots of stateful PVCs | 03:10 daily | NO — CRITICAL_PVCS list in `infrastructure/configs/backup/pvc-backup-cronjob.yaml` |
| **MySQL logical** | `mysqldump --single-transaction` per DB (via HAProxy) | 03:15 daily | YES (`SHOW DATABASES`) |
| **PG streaming replication** | CNPG 2-instance — HA only, NOT a backup layer (no WAL/PITR by decision) | continuous | n/a |
| **Immich library** | Uncompressed tar of the NAS-resident library — `immich-backup` CronJob on **W2** pulls via the NAS `personal_folder` rsync module, tars locally, pushes to the NAS `akhozya-pool1` pool | Sun 03:00 weekly | keep-2 on both W2 + NAS pool |
| **Replication** | rsync fan-out from W1: → W2 (safety net) AND → NAS + validation + retention prune | 03:30 daily | n/a (path-agnostic) |
| **SOPS Secrets** | Encrypted in git | every commit | n/a |
| **DR scripts** | `.backup/secrets-{backup,restore}.sh` | manual | partial (explicit list) |

Namespaces: PG/MySQL/CouchDB CronJobs in `databases`; PVC CronJob in `kube-system`; `immich-backup` + replication in `backup-replication` (immich shares the NAS rsync creds + egress NP there). All backup CronJobs: `startingDeadlineSeconds: 600` + `backoffLimit: 2` (couchdb keeps `backoffLimit: 6`).

## PVC backup
Whitelist (CRITICAL_PVCS) + `nodeSelector: worker-node` + `hostPath /mnt/k8s-storage/backups/pvc`: `infrastructure/configs/backup/pvc-backup-cronjob.yaml`. Compression gzip, except `audiobookshelf-{audiobooks,podcasts}` = uncompressed tar (already-compressed media). Retention 30 days local (matches NAS).

**Excluded by design** (the *why* matters — re-justify before re-adding):
- `immich/immich-machine-learning` — regenerable ML cache (library PVC gone — NAS-resident since the Path-B cutover, covered by the weekly W2 job above)
- `uptime-kuma` — emptyDir, state in MySQL
- `claude-telegram/claude-telegram-home-pvc` — session-only state, bot rebuilds on restart
- `loki/storage-loki-0`, `monitoring/vmsingle-vmsingle` — log/metric buffers, ephemeral
- `stirling-pdf/stirling-pdf-{pipeline,tessdata}-pvc` — runtime + downloadable model data
- Redis HA PVCs — cache + queue/broker only (DB0 = BullMQ/Celery/Django sessions, DB1 = TTL'd cache)
- Blocky — no PVC; config in Secret, query log in PG `blocky` DB

## Replication topology
Source: `infrastructure/configs/backup-replication/cronjob.yaml` (script inline; SSH key + NAS rsync creds + Telegram = SOPS secrets alongside).
```text
W1 /mnt/k8s-storage/backups — FAN-OUT, both syncs from W1:
  ├─ rsync --delete (SSH :65300, key-based)
  │    → W2 /mnt/extra-storage/backups (z3us@192.168.1.126) — today only, safety net
  └─ rsync (no --delete) :50555 (rsync daemon)
       → NAS (192.168.1.136, /akhozya-pool1/backups/homelab/) — 30-day history; 500GB cap (warn 400 / crit 450)
```
After NAS push: validate (postgres/couchdb/mysql/pvc — age <25h, SHA256, tar integrity, min size), then clean source on W1. Immich is not a W1 source — produced on W2, pushed straight to the NAS pool. W2-step removal deadline: HOMELAB_ANALYSIS.md.

**Retention prune (after validate + clean):**
- 30d postgres/mysql/couchdb — `prune_nas_file()`: rsync include-filter file-prune against empty source, targets `<cat>/<cat>_YYYYMMDD_HHMMSS.tar.gz` older than 30d
- 30d pvc dirs — `prune_nas_dir()`: rsync `-r --delete` from empty dir into `pvc/YYYYMMDD_HHMMSS/` subpaths older than 30d
- keep-2 immich — sort `immich/YYYYMMDD_HHMMSS/` descending, prune all but newest 2
- Soft-fail (`|| true`) on rsync errors so prune issues don't break replication; NAS UI prune is the fallback
- Triple-safe against immich loss: file-prune regex requires a single `/` + DB-category allow-list (immich paths have two `/`s and aren't in `(postgres|mysql|couchdb)`)

Failure handling: trap on EXIT sends Telegram with `CURRENT_STEP`; success is silent.

## NAS quirks
- Rsync daemon (no SSH); auth via `RSYNC_PASSWORD` env var
- Push uses no `--delete` (NAS accumulates history); retention only via the prune step
- Layout: `postgres/`, `mysql/`, `couchdb/` hold FLAT files `<cat>_YYYYMMDD_HHMMSS.tar.gz`; `pvc/` and `immich/` hold nested DIRS — the file-vs-dir distinction is what the prune regex keys on

## DB backup mechanics
Images pinned in each CronJob manifest (`infrastructure/configs/databases/*/`, `infrastructure/configs/backup/`).
- **Postgres:** host `main-postgres-rw`, user `postgres-admin`, format custom (`-F c`), excludes only the `postgres` DB
- **MySQL:** host `main-mysql-haproxy:3306`, user `root` (from `mysql-cluster-secrets`), excludes `information_schema`/`mysql`/`performance_schema`/`sys`; client image pinned to the server's 8.4.x line (Renovate ignore)
- **CouchDB:** npm-installs `@cloudant/couchbackup` per run, host `couchdb-couchdb.databases:5984`, `wait-for-couchdb` initContainer (30 × 2s), excludes `_*` system DBs
- All 3: tar.gz + SHA256, 30-day retention (`find -mtime +30 -delete`), `successfulJobsHistoryLimit: 7`, `concurrencyPolicy: Forbid`, `nodeSelector: worker-node`, `hostPath /mnt/k8s-storage/backups/<engine>`

## DR scripts (`.backup/`)
**Excluded from git** (`.gitignore`) — force-add when committing edits. Runbook: `.backup/README.md`.

### secrets-backup.sh covers
- **CRITICAL:** SOPS age key (gates Flux decrypt of everything)
- **Cloudflare:** API token (cert-manager), tunnel credentials + config, mgmt API token
- **Monitoring:** Grafana admin, Alertmanager Telegram, VMAgent couchdb auth mirror
- **DB:** `redis-passwords` + `redis-acl-secret`; `postgres-admin-user` + PG app users (authentik, immich, linkwarden, mealie, n8n, paperless, blocky); `mysql-cluster-secrets` + uptime-kuma, pricebuddy
- **App secrets:** all apps with secrets (homepage = none by design, config in git ConfigMap)
- **Backup replication:** SSH key + NAS rsync creds + Telegram
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
- Full-pipeline drill: `backup-restore-drill` skill. Last full test 2026-05-22 — all PVCs + 4 DB types + immich OK; expectation anchors: immich 62.5G = tar 187s + sha256 914s ≈ 18m; replication with heavy prune ≈ 102s
- Replication validates 4 backup types daily; failure → Telegram with the failed step
- Grafana dashboard: `monitoring/configs/grafana-dashboards/backup-monitoring-dashboard.yaml`
