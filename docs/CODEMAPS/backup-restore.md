# Backup / Restore Codemap

## Backup Layers

| Layer | What | Schedule | Auto-discover |
|-------|------|----------|---------------|
| **DB logical** (PG/MySQL/CouchDB) | Per-DB SQL dumps | 03:00-03:15 daily | YES |
| **PVC tarballs** | Filesystem snapshots of stateful PVCs | 03:10 daily | NO (CRITICAL_PVCS list) |
| **PG WAL** | Continuous (CNPG) | continuous | YES |
| **Replication** | rsync W1 → W2 → NAS | 03:30 daily | n/a (path-agnostic) |
| **SOPS Secrets** | Encrypted in git | every commit | n/a (file-based) |
| **Disaster recovery scripts** | `.backup/secrets-{backup,restore}.sh` | manual | partial (explicit list) |

## PVC Backup CRITICAL_PVCS list
- home-assistant/home-assistant-data-pvc
- paperless-ngx/paperless-data-pvc
- audiobookshelf/{audiobookshelf-audiobooks,audiobookshelf-podcasts}
- homehub/homehub-data-pvc
- stirling-pdf/stirling-pdf-configs-pvc
- uptime-kuma/uptime-kuma-data-pvc
- linkwarden/{linkwarden-data,meilisearch-data}
- pricebuddy/pricebuddy-storage

**Excluded by design:**
- Immich library (62GB/day photos — re-uploadable; DB has metadata)
- Redis HA PVCs (cache + transient queues; ACL in SOPS git)
- Blocky (no PVC; config in Secret, query log in PG `blocky` DB)

## Replication topology
```
W1 PVCs/backups (source)
  ↓ rsync --delete (SSH)
W2 /mnt/extra-storage/backups
  ↓ rsync (no --delete) port 50555
NAS Zettlab 6 Ultra (192.168.1.136, 500GB warn 400/crit 450)
```
Worker-2 is **temp safety net** — remove ~2026-05-20.

## NAS quirks
- Rsync daemon (no SSH)
- No `--delete` (destination retains forever; manual prune via web UI)
- `RSYNC_PASSWORD` MUST be exported as env var
- `--delete` + source cleanup = data loss if run on NAS path

## Disaster Recovery Scripts (`.backup/`)
**Excluded from git** (`.gitignore`). Force-add when committing edits.

### secrets-backup.sh — covers
- SOPS age key (CRITICAL — needed to decrypt git secrets)
- Cloudflare API + tunnel + mgmt token
- Grafana, Telegram (monitoring)
- Database secrets:
  - `redis-passwords` (admin/immich/paperless/blocky)
  - `redis-acl-secret` (HA Redis ACL)
  - `postgres-admin-user` + 7 app DB users (incl. `blocky-db-user`)
  - `mysql-cluster-secrets` + app credentials (uptime-kuma, pricebuddy, HA)
- App secrets (17 apps incl. blocky-config, claude-telegram bundle, immich-redis-url)
- Backup replication SSH key + NAS rsync creds
- OIDC: only `grafana-oidc` standalone; rest embedded in app secrets

### secrets-restore.sh — sequence
1. Restore SOPS age key first (gates all encrypted-secret reconciliation)
2. Cluster-level: Cloudflare, Flux
3. Per-namespace: create ns + apply Secret (idempotent via `--dry-run=client | apply -f -`)
4. Optional restoration with `[ -f ... ] && kubectl apply` for deprecated/optional secrets

### Encryption flow
- GPG AES256 symmetric, passphrase prompted (or `GPG_PASSPHRASE` env)
- Output: `secrets-backup-YYYYMMDD_HHMMSS.tar.gz.gpg`
- Unencrypted dir auto-removed post-encryption

## Decommissioned (no longer in scripts)
- AdGuard Home (replaced by Blocky)
- SearXNG (decommissioned)
- Wallabag, Linkding (replaced by LinkWarden)
- Authentik Redis (Authentik moved to in-memory cache)

## Verification
- Manual run: `kubectl create job -n kube-system --from=cronjob/pvc-backup pvc-backup-manual-$(date +%s)`
- Last test: 2026-04-26 — 10/10 PVCs successful, 55MB total
- Backup-monitoring Grafana dashboard: `monitoring/configs/staging/grafana-dashboards/backup-monitoring-dashboard.yaml`
