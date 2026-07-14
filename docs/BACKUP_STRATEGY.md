# Homelab Backup Strategy

**Last Updated:** 2026-07-03
**Status:** Fully operational (NAS replication active)

---

## Philosophy

Every database is backed up with a plain logical dump — `pg_dump`-style exports per engine — rather than continuous point-in-time recovery (PITR). For homelab data volumes (a few GB of databases, daily change measured in megabytes) a nightly logical dump is the right-sized choice: it is simple to reason about, trivial to inspect, and restores into any compatible engine version without WAL replay machinery. There is deliberately NO WAL archiving / barman / continuous PG backup — CNPG streaming replication is HA, not a backup layer. Backups run nightly on a fixed schedule, each archive carries a SHA256 checksum for integrity, and one replication CronJob on worker-node fans the result out to a NAS (30-day history) and to worker-node-2 as a single-day safety net. Every restore path is documented end to end.

## Backup Objectives

**RPO (worst-case data loss):** up to 24h — backups run once nightly.
**RTO (time to restore):** ~30 min for a full rebuild — mostly rsync pull from the NAS plus per-engine restore.

### RTO / RPO by Data Tier

| Data tier | Backup cadence | Retention | RPO (worst-case loss) | RTO (restore target) |
|---|---|---|---|---|
| **PostgreSQL** (CloudNativePG, 2 instances) | Nightly 03:00 | 30 days | up to ~24h | minutes–hours; manual `pg_restore` from dump |
| **MySQL** (Percona, 2 instances) | Nightly 03:15 | 30 days | up to ~24h | minutes–hours; manual `mysql <` import from dump |
| **CouchDB** (2 active-active) | Nightly 03:05 | 30 days | up to ~24h | minutes–hours; manual `couchrestore` from dump |
| **App PVCs** (Home Assistant, Paperless, Audiobookshelf, etc.) | Nightly 03:10 | 30 days | up to ~24h | minutes–hours; scale down, untar, scale up |
| **Off-node replication** (fan-out from worker-node) → NAS + worker-node-2 | Nightly 03:30 | NAS 30 days (500GB cap); worker-2 = today only | n/a (copies the above) | rsync pull, then restore per tier |

Redis is cache and queue/broker only and is **not** backed up by design — see the "What's NOT backed up" table below.

**Protection Tiers:**
1. **CRITICAL**: Authentik DB (all OIDC configs + user data)
2. **CRITICAL**: SOPS age key (decrypts all other secrets)
3. **HIGH**: App DBs (Immich, Paperless, Grafana, etc.)
4. **HIGH**: User data (docs, configs)
5. **MEDIUM**: App state (Home Assistant, CouchDB)

---

## Current State

### Automated Backup System

| Backup Type | Schedule | Namespace | Retention | Status |
|------------|----------|-----------|-----------|--------|
| **PostgreSQL** | 3:00 AM daily | databases | 30 days | Operational |
| **CouchDB** | 3:05 AM daily | couchdb | 30 days | Operational |
| **PVC** | 3:10 AM daily | kube-system | 30 days | Operational |
| **MySQL** | 3:15 AM daily | databases | 30 days | Operational |
| **Replication** | 3:30 AM daily | backup-replication | NAS: 30 days, worker-2: today | Operational |
| **Secrets** | Manual (monthly) | N/A | In `.backup/` | Scripts ready |

### Backup Flow

```
3:00 AM  PostgreSQL backup → /mnt/k8s-storage/backups/postgres/
3:05 AM  CouchDB backup    → /mnt/k8s-storage/backups/couchdb/
3:10 AM  PVC backup        → /mnt/k8s-storage/backups/pvc/
3:15 AM  MySQL backup      → /mnt/k8s-storage/backups/mysql/
3:30 AM  Replication CronJob (runs on worker-node, FAN-OUT to both targets):
         Step 2: worker-node → worker-node-2 (--delete, today's backup only — safety net)
         Step 3: worker-node → NAS (no --delete, 30-day history)
         Step 4: Verify NAS
         Step 5: Clean source on worker-node + prune NAS to 30d/keep-2 immich
```

(Step numbers match `infrastructure/configs/backup-replication/cronjob.yaml`.)

### What's Protected (GitOps + Auto Backups)

**In Git (IaC):**
- K8s manifests (deployments, services, ingress)
- ConfigMaps (HA configuration.yaml, etc.)
- Secrets (SOPS-encrypted, age)
- NetworkPolicies, RBAC
- OIDC env var configs

**Auto Daily Backups:**
- **PostgreSQL DBs** (authentik, immich, paperless, grafana, linkwarden, mealie, audiobookshelf, n8n, app)
- **MySQL DBs** (homeassistant, uptimekuma, pricebuddy)
- **CouchDB DBs** (obsidian-personal)
- **Critical PVCs** (per `pvc-backup-cronjob.yaml`):
  - `home-assistant/home-assistant-data-pvc` — HA config
  - `paperless-ngx/paperless-data-pvc` — doc files
  - `audiobookshelf/audiobookshelf-audiobooks` + `-podcasts` + `-config` + `-metadata`
  - `homehub/homehub-data-pvc`
  - `stirling-pdf/stirling-pdf-configs-pvc`
  - `linkwarden/linkwarden-data` + `meilisearch-data`
  - `pricebuddy/pricebuddy-storage`
  - `mealie/mealie-data-pvc`
  - `n8n/n8n-data-pvc`

**Auto Weekly Backups** (separate CronJob `immich-backup`, `backup-replication` ns, **worker-node-2**, Sunday 03:00 UTC):
- **Immich library** (~61G, NAS-resident since the 2026-07-12 Path-B cutover — no longer a PVC) — W2 pulls the live library from the NAS (`personal_folder` rsync module) → uncompressed tar+sha on W2 (`/mnt/extra-storage/immich-backup/`, jpeg already compressed) → push to the NAS `akhozya-pool1` pool. **Two physical copies** (W2 + NAS pool), retention keep-2 each (≈ 2 weeks).

**What's NOT backed up (by design)** — 2026-05-22 audit:
| Resource | Reason |
|---|---|
| `redis-replication` PVCs (DB0 + DB1) | Cache + queue/broker only. DB0 = BullMQ + Celery + Django sessions (recoverable on restart). DB1 = all-TTL'd cache. No durable user data. Redis HA (2 replicas + 3 sentinels + RDB+AOF) handles single-pod loss. |
| `immich/immich-machine-learning` | Regenerable ML model cache. |
| `claude-telegram/claude-telegram-home-pvc` | Session-only state. Bot self-rebuilds on restart; secrets in SOPS. |
| `loki/storage-loki-0`, `monitoring/vmsingle-vmsingle` | Log/metric buffers, ephemeral. |
| `stirling-pdf/stirling-pdf-pipeline-pvc`, `-tessdata-pvc` | Runtime + downloadable model data. |
| `uptime-kuma` | Removed 2026-05-22; UK switched to emptyDir, state lives in MySQL. |

**Retention policy** (set 2026-05-22):
- W1 source: 30 days local (`find -mtime +30 -delete` in pvc-backup post-run).
- W2 safety mirror: today's only (`rsync --delete`).
- NAS: 30d for daily backups (postgres/mysql/couchdb/pvc) + keep-2 for immich (`backup-replication` Step 5b prune via `rsync --delete` against empty source per old dir; soft-fail if daemon refuses delete → manual NAS UI prune).

**Backup Replication (3 copies, fan-out from worker-node — NOT a serial W1→W2→NAS chain):**
- **NAS** (Zettlab 6 Ultra, 192.168.1.136): 30-day history, rsync daemon port 50555
- **worker-node-2** (192.168.1.126): today's backup only (temp safety net until ~2026-07-20)
- Source on worker-node cleaned after replication success

**Manual Secret Backups (Scripts `.backup/`):**
- SOPS age key (CRITICAL)
- Cloudflare API tokens
- DB creds (PostgreSQL admin, Redis, MySQL cluster, all app DB users)
- App secrets (admin creds, API keys, env vars)
- OIDC integration secrets (8 apps)
- Backup replication creds (SSH key, NAS rsync)

---

## BACKUP IMPLEMENTATION DETAILS

### 1. PostgreSQL Automated Backups

**File:** `infrastructure/configs/databases/postgres/postgres-backup-cronjob.yaml`

**Implementation:**
- CronJob daily 3:00 AM
- `pg_dump -F c` (custom format) per DB
- Auto-discovers DBs (excludes system DBs)
- Compresses entire backup dir `tar -czf` (gzip)
- **Generates SHA256 checksum** for integrity verify
- Stores `/mnt/k8s-storage/backups/postgres/` on worker node

**Storage:** 30-day retention = ~1.3GB total

**Restore procedure:**
```bash
# Verify backup integrity
sha256sum -c /mnt/k8s-storage/backups/postgres/postgres_YYYYMMDD_HHMMSS.tar.gz.sha256

# Extract latest backup
tar -xzf /mnt/k8s-storage/backups/postgres/postgres_YYYYMMDD_HHMMSS.tar.gz -C /tmp

# Restore specific database
kubectl exec -n databases main-postgres-1 -- \
  pg_restore -U postgres -d authentik -c --if-exists \
  /tmp/postgres_YYYYMMDD_HHMMSS/authentik.dump
```

---

### 2. CouchDB Automated Backups

**File:** `infrastructure/configs/databases/couchdb/couchdb-backup-cronjob.yaml`

**Implementation:**
- CronJob daily 3:05 AM
- `@cloudant/couchbackup` npm package
- Auto-discovers DBs (excludes system DBs)
- Exports each DB to `.couchbackup` format
- Compresses `tar -czf` (gzip)
- **SHA256 checksum** for integrity
- Stores `/mnt/k8s-storage/backups/couchdb/` on worker node

**Storage:** 30-day retention = ~90MB total

**Restore procedure:**
```bash
# Verify backup integrity
sha256sum -c /mnt/k8s-storage/backups/couchdb/couchdb_YYYYMMDD_HHMMSS.tar.gz.sha256

# Extract backup
tar -xzf /mnt/k8s-storage/backups/couchdb/couchdb_YYYYMMDD_HHMMSS.tar.gz -C /tmp

# Restore database
cat /tmp/*/obsidian-personal.couchbackup | couchrestore \
  --url http://admin:PASSWORD@couchdb:5984 \
  --db obsidian-personal
```

---

### 3. PVC Automated Backups

**File:** `infrastructure/configs/backup/pvc-backup-cronjob.yaml`

**Implementation:**
- CronJob daily 3:10 AM (after DB backups)
- `tar -czf` direct compression
- Critical PVCs only (not all)
- **SHA256 checksum** per file
- Stores `/mnt/k8s-storage/backups/pvc/YYYYMMDD_HHMMSS/` on worker node

**Backed up PVCs** (13 — source of truth: `CRITICAL_PVCS` var in `pvc-backup-cronjob.yaml`):
- `home-assistant/home-assistant-data-pvc`, `paperless-ngx/paperless-data-pvc`
- `audiobookshelf/audiobookshelf-{audiobooks,podcasts,config,metadata}`
- `homehub/homehub-data-pvc`, `stirling-pdf/stirling-pdf-configs-pvc`
- `linkwarden/linkwarden-data`, `linkwarden/meilisearch-data`
- `pricebuddy/pricebuddy-storage`, `mealie/mealie-data-pvc`, `n8n/n8n-data-pvc`
- No CouchDB PVC — CouchDB has its own dump CronJob
- Note: the Immich library is NAS-resident (no longer a PVC) — backed up by the separate weekly `immich-backup` CronJob (W2 producer → NAS pool)

**Storage:** 30-day retention

**Restore procedure:**
```bash
# Verify backup integrity
cd /mnt/k8s-storage/backups/pvc/YYYYMMDD_HHMMSS/home-assistant
sha256sum -c home-assistant-data-pvc.tar.gz.sha256

# Stop application
kubectl scale deployment/home-assistant -n home-assistant --replicas=0

# Extract and restore
tar -xzf home-assistant-data-pvc.tar.gz -C /mnt/k8s-storage/pvc-XXXXX/

# Restart application
kubectl scale deployment/home-assistant -n home-assistant --replicas=1
```

---

### 4. MySQL Automated Backups

**File:** `infrastructure/configs/databases/mysql/mysql-backup-cronjob.yaml`

**Implementation:**
- CronJob daily 3:15 AM
- `mysqldump` per DB
- **SHA256 checksum** for integrity
- Stores `/mnt/k8s-storage/backups/mysql/` on worker node

**Databases:** homeassistant, uptimekuma, pricebuddy

**Storage:** 30-day retention = ~30MB total

**Restore procedure:**
```bash
# Verify backup integrity
sha256sum -c /mnt/k8s-storage/backups/mysql/mysql_YYYYMMDD_HHMMSS.tar.gz.sha256

# Extract backup
tar -xzf /mnt/k8s-storage/backups/mysql/mysql_YYYYMMDD_HHMMSS.tar.gz -C /tmp

# Get root password
MYSQL_ROOT_PWD=$(kubectl get secret -n databases mysql-cluster-secrets -o jsonpath='{.data.root}' | base64 -d)

# Restore specific database
kubectl exec -n databases main-mysql-mysql-0 -- \
  mysql -uroot -p${MYSQL_ROOT_PWD} homeassistant < /tmp/*/mysql_homeassistant.sql
```

---

### 5. Backup Replication to NAS + worker-node-2

**File:** `infrastructure/configs/backup-replication/cronjob.yaml`

**Implementation:**
- CronJob daily 3:30 AM on worker-node (after all backups done ~3:16 AM)
- FAN-OUT: both targets synced from the same worker-node source (not serial via W2)
- Step 2: rsync → worker-node-2 (`--delete`, today's backup only — safety net, removal ~2026-07-20)
- Step 3: rsync → NAS (no `--delete`)
- Step 4: Verify NAS data via rsync list
- Step 5: Clean source on worker-node; prune NAS to 30d daily / keep-2 immich; check NAS storage (warn 400GB, critical 450GB, hard limit 500GB)

**NAS Details:**
- **Hardware:** Zettlab 6 Ultra (14TB usable)
- **IP:** 192.168.1.136, rsync daemon port 50555
- **Module:** `akhozya-pool1`, path `backups/homelab/`
- **Auth:** rsync user/password (SOPS secret `nas-rsync-credentials`)
- **Storage limit:** 500GB homelab backups (~190 days at 2.6GB/day)
- **Pruning:** Manual via NAS web UI (no SSH access)

**worker-node-2 Details:**
- **IP:** 192.168.1.126, SSH port 65300
- **Path:** `/mnt/extra-storage/backups/`
- **Auth:** SSH key (SOPS secret `backup-replication-ssh-key`)
- **Temporary:** Safety net until ~2026-07-20 (postponed 2026-05-22 +2mo)

**Recovery from NAS:**
```bash
# On worker-node (or any machine on local network)
export RSYNC_PASSWORD='<nas-rsync-password>'
rsync -avz --port=50555 \
  rsync://akhozya@192.168.1.136/akhozya-pool1/backups/homelab/ \
  /mnt/k8s-storage/backups/
```

**Recovery from worker-node-2:**
```bash
rsync -avz -e "ssh -p 65300" \
  z3us@192.168.1.126:/mnt/extra-storage/backups/ \
  /mnt/k8s-storage/backups/
```

---

### 6. Kubernetes Secrets Manual Backups

**Files:** `.backup/secrets-backup.sh` and `.backup/secrets-restore.sh`

**What's backed up:**
- **CRITICAL:** SOPS age key (Flux decrypts everything)
- Cloudflare API token, tunnel creds + tunnel config
- Grafana admin secret
- Telegram bot tokens (Alertmanager, backup-replication, PriceBuddy)
- PostgreSQL admin user + all app DB users
- MySQL cluster secrets + app creds
- Redis passwords
- All app secrets (13 apps)
- OIDC integration secrets (audiobookshelf, grafana, home-assistant, immich, mealie, n8n, paperless-ngx, stirling-pdf)
- Backup replication creds (SSH key, NAS rsync, Telegram)

**What's NOT backed up (stored securely elsewhere):**
- **SSH keys**: in 1Password
- **Local SOPS age key**: in 1Password

**Encryption:** GPG AES256 with interactive passphrase

**Usage:**
```bash
# Create backup (run monthly or before major changes)
cd .backup
./secrets-backup.sh

# Output: secrets-backup-YYYYMMDD_HHMMSS.tar.gz.gpg
# ⚠️ Store passphrase in 1Password!
```

**Restore procedure:**
```bash
# Run BEFORE bootstrapping Flux on fresh cluster
cd .backup
./secrets-restore.sh

# Then bootstrap Flux
flux bootstrap github --owner=AKhozya --repository=homelab --path=clusters --personal
```

---

## STORAGE PROJECTIONS

### Current Usage with gzip Compression

| Backup | Size/Day | Retention | Total Storage |
|--------|----------|-----------|---------------|
| PostgreSQL | ~50 MB | 30 days | **~1.5 GB** |
| CouchDB | ~3 MB | 30 days | **~90 MB** |
| MySQL | ~1 MB | 30 days | **~30 MB** |
| PVC | ~400 MB | 30 days | **~12 GB** |
| **Local Total** | | | **~14 GB / 4.2 TB** |
| **NAS (accumulated)** | ~2.6 GB | 30 days (+ keep-2 immich) | **~500 GB limit** |

**Local storage:** 4.2 TB on `/mnt/k8s-storage` — backups use <1%
**NAS storage:** 500 GB soft limit — 30-day prune keeps usage well below it

---

## DISASTER SCENARIOS

### Scenario 1: Complete Cluster Loss

**Without Backups:**
1. Lose all Authentik OIDC configs → reconfig 8 apps manually
2. Lose all app DBs → Immich metadata, Paperless doc index
3. Lose all HA automations/history
4. Lose SOPS age key → cannot decrypt secrets, full reconfig

**Recovery Time:** 16-24h manual reconfig

**With Backups (Current System):**
1. Restore SOPS age key → Flux decrypts all secrets
2. Pull backups from NAS → all DBs + PVC data
3. Restore PostgreSQL + MySQL → all OIDC configs + DBs
4. Restore PVCs → all user data (docs, configs)
5. GitOps redeploys infra → all apps running

**Recovery Time:** ~30 min (mostly rsync from NAS + restore time)

### Scenario 2: Single Node Failure

**worker-node failure:**
- Backups on NAS (full history) + worker-node-2 (today's backup)
- Rebuild node, rejoin cluster, restore from NAS
- DB replicas on worker-node-2 keep serving reads

**worker-node-2 failure:**
- Safety net only — NAS has full history
- Rebuild node, rejoin cluster, Flux redeploys replicas

### Scenario 3: Database Corruption

**With Backups:**
- Restore from last good backup on NAS (< 24h old)
- Min data loss (max 24h)
- All OIDC configs preserved

### Scenario 4: Accidental Deletion

**With Backups:**
- Restore specific app from backup
- Restore specific DB from PostgreSQL/MySQL backup
- Restore PVC data from timestamped backup on NAS

---

## COMPLETE DISASTER RECOVERY PROCEDURE

### Full Cluster Rebuild from Scratch

**Prerequisites:**
- NAS reachable at 192.168.1.136 (or worker-node-2 at 192.168.1.126)
- Secret backups in `.backup/` (encrypted GPG archive)
- Git repo with infra code
- SOPS age key backup (in `.backup/` or 1Password)

**Recovery Steps:**

#### 1. Rebuild K3s Cluster

**Do NOT run a bare `curl | sh -`** — that installs unpinned k3s WITH bundled
Traefik + CoreDNS + helm-controller (collide with the Flux-managed ones). K3s
`config.yaml`/`kubelet.yaml` are ansible-owned and must be applied BEFORE first start.

**Per node, control-plane first:**
```bash
# 1. Bootstrap ansible stack + K3s config directory (script is bootstrap-only)
sudo bash docs/scripts/setup-node.sh
# 2. Apply ansible-owned config (k3s config, firewall, sysctls, ...)
sudo systemctl start node-maintenance-sync.service
sudo systemctl start node-maintenance-config.service
```

**On control-plane node (192.168.1.127):**
```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.36.1+k3s1" sh -
sudo cat /var/lib/rancher/k3s/server/node-token
```

**On worker-node (192.168.1.129) and worker-node-2 (192.168.1.126):**
```bash
export K3S_URL=https://192.168.1.127:6443
export K3S_TOKEN=<token-from-control-plane>
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.36.1+k3s1" sh -
```

**Get kubeconfig:**
```bash
sudo cat /etc/rancher/k3s/k3s.yaml
# Copy to ~/.kube/config and update server IP
```

#### 2. Firewall

Applied by the ansible `firewall` role in step 1 (`node-maintenance-config.service`).
No manual `ufw` commands — rules are role-managed, additive, never reset.

#### 3. Restore ALL Secrets (BEFORE Flux)

```bash
cd .backup
./secrets-restore.sh
```

Restores:
- SOPS age key (CRITICAL — Flux needs)
- All infra secrets (Cloudflare, Grafana, Telegram)
- All DB creds (PostgreSQL, MySQL, Redis)
- All app secrets
- All OIDC integration secrets
- Backup replication creds (SSH key + NAS rsync)

#### 4. Bootstrap Flux

```bash
flux bootstrap github \
  --owner=AKhozya \
  --repository=homelab \
  --path=clusters \
  --personal
```

#### 5. Wait for Infrastructure to Deploy

```bash
# Watch Flux reconcile
watch kubectl get kustomization -A

# Wait for PostgreSQL cluster
kubectl wait --for=condition=ready cluster/main-postgres -n databases --timeout=600s
```

#### 6. Pull Backups from NAS

```bash
# On worker-node
export RSYNC_PASSWORD='<nas-rsync-password>'
rsync -avz --port=50555 \
  rsync://akhozya@192.168.1.136/akhozya-pool1/backups/homelab/ \
  /mnt/k8s-storage/backups/
```

#### 7. Restore PostgreSQL Databases

```bash
LATEST_BACKUP=$(ls -t /mnt/k8s-storage/backups/postgres/postgres_*.tar.gz | head -1)
tar -xzf $LATEST_BACKUP -C /tmp

for DB in authentik immich paperless grafana linkwarden mealie audiobookshelf n8n app; do
  echo "Restoring $DB..."
  kubectl exec -n databases main-postgres-1 -- \
    pg_restore -U postgres -d $DB -c --if-exists \
    /tmp/$(basename $LATEST_BACKUP .tar.gz)/${DB}.dump
done
```

#### 8. Restore MySQL Databases

```bash
LATEST_MYSQL=$(ls -t /mnt/k8s-storage/backups/mysql/mysql_*.tar.gz | head -1)
tar -xzf $LATEST_MYSQL -C /tmp

MYSQL_ROOT_PWD=$(kubectl get secret -n databases mysql-cluster-secrets -o jsonpath='{.data.root}' | base64 -d)

for DB in homeassistant uptimekuma pricebuddy; do
  echo "Restoring $DB..."
  kubectl exec -n databases main-mysql-mysql-0 -- \
    mysql -uroot -p${MYSQL_ROOT_PWD} $DB < /tmp/*/mysql_${DB}.sql
done
```

#### 9. Restore CouchDB

```bash
LATEST_COUCHDB=$(ls -t /mnt/k8s-storage/backups/couchdb/couchdb_*.tar.gz | head -1)
tar -xzf $LATEST_COUCHDB -C /tmp

cat /tmp/*/obsidian-personal.couchbackup | \
  kubectl exec -i -n databases couchdb-couchdb-0 -- \
  couchrestore --url http://admin:PASSWORD@localhost:5984 --db obsidian-personal
```

#### 10. Restore PVCs

```bash
LATEST_PVC=$(ls -td /mnt/k8s-storage/backups/pvc/* | head -1)

# For each critical PVC:
kubectl scale deployment/home-assistant -n home-assistant --replicas=0
tar -xzf $LATEST_PVC/home-assistant/home-assistant-data-pvc.tar.gz \
  -C /mnt/k8s-storage/pvc-XXXXX/
kubectl scale deployment/home-assistant -n home-assistant --replicas=1

# Repeat for: paperless-ngx, audiobookshelf
```

#### 11. Verify Applications

```bash
kubectl get pods -A
curl -I https://authentik.h0melab.work
curl -I https://grafana.h0melab.work
curl -I https://immich.h0melab.work
# Test OIDC login on all apps
```

**Total Recovery Time:** ~30 min

---

## MONITORING BACKUPS

### Check Backup Status

```bash
# View CronJobs
kubectl get cronjobs -A | grep backup

# Check last run
kubectl get jobs -A | grep backup

# View logs
kubectl logs -n databases job/postgres-backup-XXXXX
kubectl logs -n databases job/couchdb-backup-XXXXX
kubectl logs -n kube-system job/pvc-backup-XXXXX
kubectl logs -n databases job/mysql-backup-XXXXX
kubectl logs -n backup-replication job/backup-replication-XXXXX

# Check backup storage on worker-node
du -sh /mnt/k8s-storage/backups/*/

# Check NAS storage
export RSYNC_PASSWORD='<nas-rsync-password>'
rsync --port=50555 -r --list-only \
  rsync://akhozya@192.168.1.136/akhozya-pool1/backups/homelab/ | head -20
```

### Manual Backup Trigger (for testing)

```bash
# PostgreSQL
kubectl create job --from=cronjob/postgres-backup postgres-backup-manual-$(date +%s) -n databases

# CouchDB
kubectl create job --from=cronjob/couchdb-backup couchdb-backup-manual-$(date +%s) -n couchdb

# PVC
kubectl create job --from=cronjob/pvc-backup pvc-backup-manual-$(date +%s) -n kube-system

# MySQL
kubectl create job --from=cronjob/mysql-backup mysql-backup-manual-$(date +%s) -n databases

# Replication (run AFTER backup jobs complete)
kubectl create job --from=cronjob/backup-replication backup-replication-manual-$(date +%s) -n backup-replication

# Secrets (manual script)
cd .backup
./secrets-backup.sh
```

---

## BACKUP SCHEDULE SUMMARY

| What | When | Where | Retention | Replication |
|------|------|-------|-----------|-------------|
| **PostgreSQL** | Daily 3:00 AM | `/mnt/k8s-storage/backups/postgres/` | 30 days | NAS + worker-2 |
| **CouchDB** | Daily 3:05 AM | `/mnt/k8s-storage/backups/couchdb/` | 30 days | NAS + worker-2 |
| **PVC** | Daily 3:10 AM | `/mnt/k8s-storage/backups/pvc/` | 30 days | NAS + worker-2 |
| **MySQL** | Daily 3:15 AM | `/mnt/k8s-storage/backups/mysql/` | 30 days | NAS + worker-2 |
| **Replication** (fan-out from worker-node) | Daily 3:30 AM | NAS + worker-node-2 | NAS: 30 days | - |
| **Secrets** | Manual (monthly) | `.backup/` | Encrypted GPG | Store in 1Password |

---

## VERIFICATION CHECKLIST

**Daily (automated):**
- PostgreSQL backup job done
- CouchDB backup job done
- PVC backup job done
- MySQL backup job done
- Backup replication to NAS + worker-node-2 done
- Backup storage use < 70%

**Monthly (manual):**
- Run secrets backup script
- Store secrets backup securely (1Password, encrypted USB)
- Test restore of one DB (verify backups valid)
- Review backup logs for errors
- Check NAS storage use (warn 400GB, critical 450GB)

**Quarterly (validation):**
- Full DR restore drill (single env — no staging; drill against scratch namespaces / spare hardware)
- Verify all apps restore correctly
- Update DR docs if needed

---

## FUTURE ENHANCEMENTS

### NAS Off-node Backup - COMPLETED (2026-02-06)

Note: NAS is off-NODE, not offsite — W1, W2, and NAS share one building/power/LAN.
No cloud/3-2-1 copy exists (accepted risk ceiling, see `docs/ARCHITECTURE.md`).

- Rsync backups to NAS daily 3:30 AM
- NAS keeps 30-day history (no `--delete` on sync; pruned in Step 5b)
- 500GB storage alloc
- Manual prune via NAS web UI
- worker-node-2 as temp safety net

### Remaining Enhancements

1. **Automated backup validation:**
   - Automated restore testing
   - Integrity checks beyond SHA256
   - Alert if backups corrupted
   - Target: February 2026

2. **Monitoring integration:**
   - Prometheus metrics for backup job success/fail
   - Grafana dashboard for backup monitoring (partially done)
   - Alertmanager alerts if backup jobs fail

---

## CHANGELOG

### 2026-02-06: NAS Backup Replication
- Added NAS (Zettlab 6 Ultra) as primary backup dest
- Added worker-node-2 as temp safety net (until ~Feb 13, 2026)
- Backup replication CronJob at 3:30 AM daily
- NAS accumulates full history, worker-node-2 mirrors today only
- Source cleaned after replication success
- NAS storage monitoring (warn 400GB, critical 450GB)
- Updated DR procedures with NAS/worker-2 restore paths
- Added nas-rsync-credentials to secrets backup/restore scripts
- Cut RTO 2-4h → ~30 min

### 2025-12-18: MySQL Backups and Immich Exclusion
- Added MySQL auto backups (3:15 AM, homeassistant/uptimekuma/pricebuddy)
- Excluded Immich from PVC backups (photos re-uploadable, DB in PostgreSQL)
- Storage cut ~323GB → ~5GB per retention cycle
- Updated backup schedule times (3:00/3:05/3:10/3:15 AM)

### 2025-10-31: SHA256 Checksums and Documentation Updates
- Added SHA256 checksum gen to PVC backup script
- All 3 backup systems now gen SHA256 checksums
- Documented SSH keys + SOPS age key in 1Password
- Updated restore procedures to include SHA256 verify
- Verified GPG encryption with interactive passphrase

### 2025-10-23: Backups Fully Operational
- PostgreSQL auto backups done + tested
- CouchDB auto backups done + tested
- PVC auto backups done + tested
- Simplified zstd ultra → gzip
- Added 8 OIDC secrets to backup scripts

### 2025-10-22: Initial Assessment
- No backups configured
- 4.2TB storage free but unused
- Risk: full data loss if cluster fails

---

**Document Owner:** Alexander Khozya
**Next Review:** 2026-02-09 (monthly review cycle)
**Status:** Fully operational — all critical requirements met, NAS replication active