# Backup / Restore Codemap

## Backup Layers

| Layer | What | Schedule (UTC) | Auto-discover |
|-------|------|----------------|---------------|
| **PG logical** | `pg_dump -F c` per DB (CNPG) | 03:00 daily | YES (`pg_database` query) |
| **CouchDB logical** | `@cloudant/couchbackup` per DB | 03:05 daily | YES (`/_all_dbs`) |
| **PVC tarballs** | Filesystem snapshots of stateful PVCs | 03:10 daily | NO (CRITICAL_PVCS list) |
| **MySQL logical** | `mysqldump --single-transaction` per DB (Percona via HAProxy) | 03:15 daily | YES (`SHOW DATABASES`) |
| **PG WAL** | Continuous (CNPG) | continuous | YES |
| **Replication** | rsync W1 → W2 → NAS + validation | 03:30 daily | n/a (path-agnostic) |
| **SOPS Secrets** | Encrypted in git | every commit | n/a (file-based) |
| **Disaster recovery scripts** | `.backup/secrets-{backup,restore}.sh` | manual | partial (explicit list) |

Namespaces: PG/MySQL/CouchDB cronjobs in `databases`; PVC cronjob in `kube-system`; replication in `backup-replication`.

## PVC Backup CRITICAL_PVCS list
Source: `infrastructure/configs/staging/backup/pvc-backup-cronjob.yaml` (10 entries, 8 apps).
- `home-assistant/home-assistant-data-pvc`
- `paperless-ngx/paperless-data-pvc`
- `audiobookshelf/audiobookshelf-audiobooks`
- `audiobookshelf/audiobookshelf-podcasts`
- `homehub/homehub-data-pvc`
- `stirling-pdf/stirling-pdf-configs-pvc`
- `uptime-kuma/uptime-kuma-data-pvc`
- `linkwarden/linkwarden-data`
- `linkwarden/meilisearch-data`
- `pricebuddy/pricebuddy-storage`

**Compression:** gzip default; `audiobookshelf-{audiobooks,podcasts}` = uncompressed tar (already-compressed media).
**Retention:** 7 days local (vs. 30 days for DB dumps).
**Storage:** `hostPath /mnt/k8s-storage/backups/pvc` (worker-node), `nodeSelector: worker-node`.

**Excluded by design:**
- Immich library (~62GB/day photos — re-uploadable; DB has metadata)
- Redis HA PVCs (cache + transient queues; ACL in SOPS git)
- Blocky (no PVC; config in Secret, query log in PG `blocky` DB)

## Replication topology
```
W1 PVCs/backups (source: /mnt/k8s-storage/backups)
  ↓ rsync --delete (SSH port 65300, key-based)
W2 /mnt/extra-storage/backups (z3us@192.168.1.126)
  ↓ rsync (no --delete) port 50555 (rsync daemon)
NAS Zettlab 6 Ultra (192.168.1.136, /akhozya-pool1/backups/homelab/)
  500GB hard limit (warn 400GB / crit 450GB)
```
After NAS push: validate (4 types: postgres/couchdb/mysql/pvc — age <25h, SHA256, tar integrity, min size), then **clean source on W1**. Worker-2 still in chain — temp safety net, **remove ~2026-05-20 (still pending)**.

Failure handling: trap on EXIT sends Telegram failure with `CURRENT_STEP` label; success path is silent (no Telegram on OK).

## NAS quirks
- Rsync daemon (no SSH); auth via `RSYNC_PASSWORD` env var
- No `--delete` (destination retains forever; manual prune via web UI)
- `--delete` + source cleanup = data loss if accidentally run on NAS path
- NAS module path: `akhozya-pool1/backups/homelab/`

## DB Backup mechanics
- **Postgres:** image `postgres:18.3-alpine`, host `main-postgres-rw`, user `postgres-admin`, format custom (`-F c`), excludes `postgres` DB only.
- **MySQL:** image `mysql:8.4.8` (pinned to 8.4.x for Percona Server 8.4.6, Renovate ignore), host `main-mysql-haproxy:3306`, user `root` (from `mysql-cluster-secrets`), excludes `information_schema`/`mysql`/`performance_schema`/`sys`.
- **CouchDB:** image `node:24.15.0-alpine`, npm-installs `@cloudant/couchbackup` per run, host `couchdb-couchdb.databases:5984`, has `wait-for-couchdb` initContainer (30 retries × 2s), excludes `_*` system DBs.
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

**Coverage check:** all 17 apps in cluster mapped to script entries (incl. recently-added blocky, claude-telegram, pricebuddy). No app-secret gaps observed.

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
- Last test: 2026-04-26 — 10/10 PVCs successful, 55MB total
- Replication validates 4 backup types daily; failure → Telegram with failed step
- Backup-monitoring Grafana dashboard: `monitoring/configs/staging/grafana-dashboards/backup-monitoring-dashboard.yaml`
