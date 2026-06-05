# Backup / Restore Codemap

## Backup Layers

| Layer | What | Schedule (UTC) | Auto-discover |
|-------|------|----------------|---------------|
| **PG logical** | `pg_dump -F c` per DB (CNPG) | 03:00 daily | YES (`pg_database` query) |
| **CouchDB logical** | `@cloudant/couchbackup` per DB | 03:05 daily | YES (`/_all_dbs`) |
| **PVC tarballs** | Filesystem snapshots of stateful PVCs | 03:10 daily | NO (CRITICAL_PVCS list) |
| **MySQL logical** | `mysqldump --single-transaction` per DB (Percona via HAProxy) | 03:15 daily | YES (`SHOW DATABASES`) |
| **PG WAL** | Continuous (CNPG) | continuous | YES |
| **Immich library** | Uncompressed tar of 62.5G photo PVC (separate `immich-backup` CronJob) | Sunday 03:00 weekly | n/a (single PVC) |
| **Replication** | rsync W1 → W2 → NAS + validation + retention prune | 03:30 daily | n/a (path-agnostic) |
| **SOPS Secrets** | Encrypted in git | every commit | n/a (file-based) |
| **Disaster recovery scripts** | `.backup/secrets-{backup,restore}.sh` | manual | partial (explicit list) |

Namespaces: PG/MySQL/CouchDB cronjobs in `databases`; PVC + immich cronjobs in `kube-system`; replication in `backup-replication`.

All 6 backup CronJobs: `startingDeadlineSeconds: 600` + `backoffLimit: 2` (couchdb keeps `backoffLimit: 6`) — Wave 10 hardening `d8ef6891` 2026-05-24.

## PVC Backup CRITICAL_PVCS list
Source: `infrastructure/configs/backup/pvc-backup-cronjob.yaml` (13 entries, 10 apps — updated 2026-05-22).
- `home-assistant/home-assistant-data-pvc`
- `paperless-ngx/paperless-data-pvc`
- `audiobookshelf/audiobookshelf-audiobooks`
- `audiobookshelf/audiobookshelf-podcasts`
- `audiobookshelf/audiobookshelf-config`
- `audiobookshelf/audiobookshelf-metadata`
- `homehub/homehub-data-pvc`
- `stirling-pdf/stirling-pdf-configs-pvc`
- `linkwarden/linkwarden-data`
- `linkwarden/meilisearch-data`
- `pricebuddy/pricebuddy-storage`
- `mealie/mealie-data-pvc`
- `n8n/n8n-data-pvc`

**Compression:** gzip default; `audiobookshelf-{audiobooks,podcasts}` = uncompressed tar (already-compressed media).
**Retention:** 30 days W1 local (matches NAS, set 2026-05-22; was 7d prior).
**Storage:** `hostPath /mnt/k8s-storage/backups/pvc` (worker-node), `nodeSelector: worker-node`.

**Excluded by design (audit 2026-05-22):**
- `immich/immich-library` — 62.5G photos; separate `immich-backup` weekly CronJob with keep-2 retention
- `immich/immich-machine-learning` — regenerable ML cache
- `uptime-kuma/uptime-kuma-data-pvc` — UK switched to emptyDir, state in MySQL (removed from whitelist 2026-05-22)
- `claude-telegram/claude-telegram-home-pvc` — session-only state, bot rebuilds on restart
- `loki/storage-loki-0`, `monitoring/vmsingle-vmsingle` — log/metric buffers, ephemeral
- `stirling-pdf/stirling-pdf-{pipeline,tessdata}-pvc` — runtime + downloadable model data
- Redis HA PVCs — cache + queue/broker only (DB0 = BullMQ/Celery/Django sessions, DB1 = TTL'd cache); see BACKUP_STRATEGY.md § "What's NOT backed up"
- Blocky — no PVC; config in Secret, query log in PG `blocky` DB

## Replication topology
Source: `infrastructure/configs/backup-replication/cronjob.yaml` (script inline in CronJob; SSH key + NAS rsync creds + Telegram = SOPS secrets alongside).
```
W1 PVCs/backups (source: /mnt/k8s-storage/backups)
  ↓ rsync --delete (SSH port 65300, key-based)
W2 /mnt/extra-storage/backups (z3us@192.168.1.126)
  ↓ rsync (no --delete) port 50555 (rsync daemon)
NAS Zettlab 6 Ultra (192.168.1.136, /akhozya-pool1/backups/homelab/)
  500GB hard limit (warn 400GB / crit 450GB)
```
After NAS push: validate (4 types: postgres/couchdb/mysql/pvc — age <25h, SHA256, tar integrity, min size), then **clean source on W1** (except `immich/` which is kept for keep-2 retention). Worker-2 still in chain (verified 2026-06-05, pending) — drop W2 replication step **~2026-07-20** (HOMELAB_ANALYSIS P2); temp safety net removal **~2026-07-22** (postponed 2026-05-22 +2mo).

**Retention enforcement (Step 5b, set 2026-05-22):** NAS prune runs after validate + clean source.
- **30d for postgres/mysql/couchdb** — `prune_nas_file()`: file-prune via rsync filter `--include=<file> --include=<file>.sha256 --exclude='*'` against empty source. Targets `<cat>/<cat>_YYYYMMDD_HHMMSS.tar.gz` pattern with date > 30d threshold.
- **30d for pvc dirs** — `prune_nas_dir()`: rsync `-r --delete` from empty dir to target subpath; clears contents of >30d-old `pvc/YYYYMMDD_HHMMSS/` dirs.
- **keep-2 for immich** — sort `immich/YYYYMMDD_HHMMSS/` dirs descending, prune all but newest 2 via `prune_nas_dir`.
- Soft-fail (`|| true`) on rsync errors so prune issues don't break replication; manual NAS UI prune is fallback.
- Triple-safe against immich data loss: file-prune regex requires single `/` + DB-category allow-list (immich path has two `/`s and isn't in `(postgres|mysql|couchdb)`).

Failure handling: trap on EXIT sends Telegram failure with `CURRENT_STEP` label; success path is silent (no Telegram on OK).

## NAS quirks
- Rsync daemon (no SSH); auth via `RSYNC_PASSWORD` env var
- Replication push step uses no `--delete` (NAS accumulates history); retention via Step 5b prune above
- NAS module path: `akhozya-pool1/backups/homelab/`
- Layout: `postgres/`, `mysql/`, `couchdb/` store FLAT files `<cat>_YYYYMMDD_HHMMSS.tar.gz`; `pvc/` and `immich/` store nested DIRS `<cat>/YYYYMMDD_HHMMSS/...` (file-vs-dir distinction matters for prune regex — bug found + fixed 2026-05-22).

## DB Backup mechanics
- **Postgres:** image `postgres:18.4-alpine`, host `main-postgres-rw`, user `postgres-admin`, format custom (`-F c`), excludes `postgres` DB only.
- **MySQL:** image `mysql:8.4.8` (pinned to 8.4.x for Percona Server 8.4.6, Renovate ignore), host `main-mysql-haproxy:3306`, user `root` (from `mysql-cluster-secrets`), excludes `information_schema`/`mysql`/`performance_schema`/`sys`.
- **CouchDB:** image `node:24.16.0-alpine`, npm-installs `@cloudant/couchbackup` per run, host `couchdb-couchdb.databases:5984`, has `wait-for-couchdb` initContainer (30 retries × 2s), excludes `_*` system DBs.
- All 3: tar.gz + SHA256, 30-day retention via `find -mtime +30 -delete`, `successfulJobsHistoryLimit: 7`, `concurrencyPolicy: Forbid`, `nodeSelector: worker-node`, `hostPath /mnt/k8s-storage/backups/<engine>`.

## Disaster Recovery Scripts (`.backup/`)
**Excluded from git** (`.gitignore`). Force-add when committing edits.

### secrets-backup.sh — covers
- **CRITICAL:** SOPS age key (gates Flux decrypt of all encrypted secrets)
- **Cloudflare:** API token (cert-manager), tunnel credentials, tunnel config, **mgmt API token (expiry 2026-12-31)**
- **Monitoring:** Grafana admin, Alertmanager Telegram, monitoring/`couchdb-couchdb` (VMAgent auth mirror, optional)
- **DB secrets:**
  - `redis-passwords` (admin/immich/paperless/blocky) + `redis-acl-secret` (HA Redis, optional)
  - `postgres-admin-user` + 7 PG app users: authentik, immich, linkwarden, mealie, n8n, paperless, blocky
  - `mysql-cluster-secrets` (Percona root/repl/xtrabackup) + 2 app creds: uptime-kuma, pricebuddy
- **App secrets (covered):** authentik, immich (admin + db-password + redis-url), home-assistant (admin + secrets), n8n (env + user), mealie (env + user), paperless-ngx (env), linkwarden + meilisearch, audiobookshelf, uptime-kuma (admin + mysql), stirling-pdf (env + custom-settings), homehub, blocky-config, claude-telegram (env + ssh + chezmoi), pricebuddy (secrets + mysql + telegram), obsidian couchdb-admin/couchdb-credentials, databases/couchdb-couchdb
- **Backup replication:** SSH key + NAS rsync creds + Telegram (`backup-telegram`)
- **OIDC:** only `grafana-oidc` standalone; rest embedded in app secrets (paperless/mealie env, HA secrets.yaml, stirling custom-settings, linkwarden main); immich/audiobookshelf store OIDC in internal DB via web UI

**Coverage check:** 15 of 16 apps mapped to script entries (homepage = no secrets by design, config in git ConfigMap). No app-secret gaps observed (re-verified 2026-06-05).

### secrets-restore.sh — sequence
1. Auto-find latest `secrets-backup-*.tar.gz.gpg` → prompt passphrase → decrypt + extract
2. SOPS age key first (gates encrypted-secret reconciliation)
3. Cluster-level: cert-manager (Cloudflare API), cloudflare-tunnel (creds + config + mgmt token), flux-system (optional)
4. Monitoring → databases (Redis + PG users + MySQL) → per-app namespaces
5. Optional restoration with `[ -f ... ] && kubectl apply` for deprecated/optional secrets
6. Idempotent via `kubectl create ns --dry-run=client | apply -f -`

### Encryption flow
- GPG AES256 symmetric, passphrase prompted (or `GPG_PASSPHRASE` env)
- Output: `secrets-backup-YYYYMMDD_HHMMSS.tar.gz.gpg`
- JSON cleanup pre-encrypt: `jq` strips resourceVersion/uid/creationTimestamp/managedFields
- Unencrypted dir auto-removed post-encryption
- Plaintext extracts (`*.txt`) for fast lookup: cloudflare API, grafana admin, telegram bot, redis-immich, redis-blocky

## Decommissioned (no longer in scripts)
- AdGuard Home (replaced by Blocky)
- SearXNG (decommissioned)
- Wallabag, Linkding (replaced by LinkWarden)
- Authentik Redis (Authentik moved to in-memory cache)

## Verification
- Manual run: `kubectl create job -n kube-system --from=cronjob/pvc-backup pvc-backup-manual-$(date +%s)`
- Last test: 2026-05-22 — full pipeline tested, all 13 PVCs + 4 DB types + immich weekly successful. immich timing: tar 187s + sha256 914s = 18m21s total for 62.5G. Replication w/ heavy prune: 102s including ~450 file deletes + ~50 dir deletes from NAS.
- Live check 2026-06-05: all 6 CronJobs present, unsuspended, last-schedule on time (dailies ran <11h ago; immich Sunday ran 2026-05-31).
- Replication validates 4 backup types daily; failure → Telegram with failed step
- Backup-monitoring Grafana dashboard: `monitoring/configs/grafana-dashboards/backup-monitoring-dashboard.yaml`
