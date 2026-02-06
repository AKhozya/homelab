# 💾 HOMELAB BACKUP STRATEGY

**Last Updated:** 2026-02-06
**Status:** ✅ **FULLY OPERATIONAL** (with NAS replication)
**Priority:** **P0 - CRITICAL** (Implemented and tested)

---

## 🎯 BACKUP OBJECTIVES

**Recovery Point Objective (RPO):** 24 hours (daily automated backups)
**Recovery Time Objective (RTO):** ~30 minutes (restore from NAS or worker-node-2)

**What We're Protecting:**
1. 🔴 **CRITICAL**: Authentik database (all OIDC configs + user data)
2. 🔴 **CRITICAL**: SOPS age encryption key (needed to decrypt all other secrets)
3. 🟡 **HIGH**: Application databases (Immich, Paperless, Grafana, etc.)
4. 🟡 **HIGH**: User data (documents, configs)
5. 🟢 **MEDIUM**: Application state (Home Assistant, CouchDB)

---

## 📊 CURRENT STATE - FULLY OPERATIONAL ✅

### Automated Backup System

| Backup Type | Schedule | Namespace | Retention | Status |
|------------|----------|-----------|-----------|--------|
| **PostgreSQL** | 3:00 AM daily | databases | 30 days | ✅ Operational |
| **CouchDB** | 3:05 AM daily | couchdb | 30 days | ✅ Operational |
| **PVC** | 3:10 AM daily | kube-system | 7 days | ✅ Operational |
| **MySQL** | 3:15 AM daily | databases | 30 days | ✅ Operational |
| **Replication** | 3:30 AM daily | backup-replication | NAS: unlimited, worker-2: today | ✅ Operational |
| **Secrets** | Manual (monthly) | N/A | In `.backup/` | ✅ Scripts ready |

### Backup Flow

```
3:00 AM  PostgreSQL backup → /mnt/k8s-storage/backups/postgres/
3:05 AM  CouchDB backup    → /mnt/k8s-storage/backups/couchdb/
3:10 AM  PVC backup        → /mnt/k8s-storage/backups/pvc/
3:15 AM  MySQL backup      → /mnt/k8s-storage/backups/mysql/
3:30 AM  Replication CronJob:
         Step 1: worker-node → NAS (no --delete, accumulates full history)
         Step 2: worker-node → worker-node-2 (--delete, today's backup only)
         Step 3: Verify NAS
         Step 4: Clean source on worker-node
         Step 5: Check NAS storage (500GB limit)
```

### What's Protected (GitOps + Automated Backups)

✅ **In Git (Infrastructure as Code):**
- Kubernetes manifests (deployments, services, ingress)
- ConfigMaps (Home Assistant configuration.yaml, etc.)
- Secrets (SOPS-encrypted with age)
- Network policies, RBAC
- OIDC environment variable configs

✅ **Automated Daily Backups:**
- **PostgreSQL databases** (authentik, immich, paperless, grafana, linkwarden, mealie, audiobookshelf, n8n, app)
- **MySQL databases** (homeassistant, uptimekuma, pricebuddy)
- **CouchDB databases** (obsidian-personal)
- **Critical PVCs:**
  - `home-assistant-data-pvc` - Home Assistant config
  - `paperless-data-pvc` - Document files
  - `couchdb-storage` - Obsidian sync data
  - `audiobookshelf-audiobooks` + `audiobookshelf-podcasts`
  - Note: Immich photos excluded (can re-upload from source devices, DB in PostgreSQL)

✅ **Backup Replication (3 copies):**
- **NAS** (Zettlab 6 Ultra, 192.168.1.136): Full backup history, rsync daemon port 50555
- **worker-node-2** (192.168.1.126): Today's backup only (temporary safety net until ~Feb 13, 2026)
- Source on worker-node cleaned after successful replication

✅ **Manual Secret Backups (Scripts in `.backup/`):**
- SOPS age encryption key (CRITICAL!)
- Cloudflare API tokens
- Database credentials (PostgreSQL admin, Redis, MySQL cluster, all app DB users)
- Application secrets (admin credentials, API keys, env vars)
- OIDC integration secrets (8 applications)
- Backup replication credentials (SSH key, NAS rsync)

---

## 🛠️ BACKUP IMPLEMENTATION DETAILS

### 1. PostgreSQL Automated Backups

**File:** `infrastructure/configs/staging/databases/postgres/postgres-backup-cronjob.yaml`

**Implementation:**
- CronJob runs daily at 3:00 AM
- Uses `pg_dump -F c` (custom format) for each database
- Auto-discovers databases (excludes system databases)
- Compresses entire backup directory with `tar -czf` (gzip)
- **Generates SHA256 checksum** for backup integrity verification
- Stores at `/mnt/k8s-storage/backups/postgres/` on worker node

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

**File:** `infrastructure/configs/staging/databases/couchdb/couchdb-backup-cronjob.yaml`

**Implementation:**
- CronJob runs daily at 3:05 AM
- Uses `@cloudant/couchbackup` npm package
- Auto-discovers databases (excludes system databases)
- Exports each database to `.couchbackup` format
- Compresses with `tar -czf` (gzip)
- **Generates SHA256 checksum** for backup integrity verification
- Stores at `/mnt/k8s-storage/backups/couchdb/` on worker node

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

**File:** `infrastructure/configs/staging/backup/pvc-backup-cronjob.yaml`

**Implementation:**
- CronJob runs daily at 3:10 AM (after database backups)
- Uses `tar -czf` for direct compression
- Backs up critical PVCs only (not all PVCs)
- **Generates SHA256 checksum** for each backup file
- Stores at `/mnt/k8s-storage/backups/pvc/YYYYMMDD_HHMMSS/` on worker node

**Backed up PVCs:**
- `home-assistant/home-assistant-data-pvc` - HA config + state
- `paperless-ngx/paperless-data-pvc` - Documents
- `couchdb/database-storage-couchdb-couchdb-0` - CouchDB data
- `audiobookshelf/audiobookshelf-audiobooks` + `audiobookshelf-podcasts`
- Note: Immich `immich-library` excluded (photos re-uploadable, DB backed up via PostgreSQL)

**Storage:** 7-day retention = ~3GB total (after Immich exclusion)

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

**File:** `infrastructure/configs/staging/databases/mysql/mysql-backup-cronjob.yaml`

**Implementation:**
- CronJob runs daily at 3:15 AM
- Uses `mysqldump` for each database
- **Generates SHA256 checksum** for backup integrity verification
- Stores at `/mnt/k8s-storage/backups/mysql/` on worker node

**Databases:** homeassistant, uptimekuma, pricebuddy

**Storage:** 30-day retention = ~30MB total

**Restore procedure:**
```bash
# Verify backup integrity
sha256sum -c /mnt/k8s-storage/backups/mysql/mysql_YYYYMMDD_HHMMSS.tar.gz.sha256

# Extract backup
tar -xzf /mnt/k8s-storage/backups/mysql/mysql_YYYYMMDD_HHMMSS.tar.gz -C /tmp

# Get root password
MYSQL_ROOT_PWD=$(kubectl get secret -n databases main-mysql-secrets -o jsonpath='{.data.root}' | base64 -d)

# Restore specific database
kubectl exec -n databases main-mysql-mysql-0 -- \
  mysql -uroot -p${MYSQL_ROOT_PWD} homeassistant < /tmp/*/mysql_homeassistant.sql
```

---

### 5. Backup Replication to NAS + worker-node-2

**File:** `infrastructure/configs/staging/backup-replication/cronjob.yaml`

**Implementation:**
- CronJob runs daily at 3:30 AM (after all backups complete by ~3:16 AM)
- Step 1: rsync to NAS (no `--delete`, NAS accumulates full backup history)
- Step 2: rsync to worker-node-2 (`--delete`, keeps only current backup as safety net)
- Step 3: Verify NAS data via rsync list
- Step 4: Clean source on worker-node (data is on NAS + worker-node-2)
- Step 5: Check NAS storage (warn 400GB, critical 450GB, hard limit 500GB)

**NAS Details:**
- **Hardware:** Zettlab 6 Ultra (14TB usable)
- **IP:** 192.168.1.136, rsync daemon port 50555
- **Module:** `akhozya`, path `backups/homelab/`
- **Auth:** rsync user/password (SOPS secret `nas-rsync-credentials`)
- **Storage limit:** 500GB for homelab backups (~190 days at 2.6GB/day)
- **Pruning:** Manual via NAS web UI (no SSH access)

**worker-node-2 Details:**
- **IP:** 192.168.1.126, SSH port 65300
- **Path:** `/mnt/extra-storage/backups/`
- **Auth:** SSH key (SOPS secret `backup-replication-ssh-key`)
- **Temporary:** Safety net until ~Feb 13, 2026

**Recovery from NAS:**
```bash
# On worker-node (or any machine on local network)
export RSYNC_PASSWORD='<nas-rsync-password>'
rsync -avz --port=50555 \
  rsync://akhozya@192.168.1.136/akhozya/backups/homelab/ \
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
- 🔑 **CRITICAL:** SOPS age encryption key (needed for Flux to decrypt everything)
- 🌐 Cloudflare API token & tunnel credentials
- 📊 Grafana admin secret
- 📱 Alertmanager Telegram bot token
- 🗄️ PostgreSQL admin user + all app database users
- 🗄️ MySQL cluster secrets + app credentials
- 🗄️ Redis passwords
- 📱 All application secrets (13 applications)
- 🔐 OIDC integration secrets (audiobookshelf, grafana, home-assistant, immich, mealie, n8n, paperless-ngx, stirling-pdf)
- 🔑 Backup replication credentials (SSH key + NAS rsync)

**What's NOT backed up (already stored securely):**
- 🔑 **SSH keys**: **Already stored in 1Password** ✅
- 📦 **Local SOPS age key**: **Already stored in 1Password** ✅

**Encryption:** 🔐 **GPG AES256 with interactive passphrase**

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
flux bootstrap github --owner=AKhozya --repository=homelab --path=clusters/staging --personal
```

---

## 📈 STORAGE PROJECTIONS

### Current Usage with gzip Compression

| Backup | Size/Day | Retention | Total Storage |
|--------|----------|-----------|---------------|
| PostgreSQL | ~50 MB | 30 days | **~1.5 GB** |
| CouchDB | ~3 MB | 30 days | **~90 MB** |
| MySQL | ~1 MB | 30 days | **~30 MB** |
| PVC | ~400 MB | 7 days | **~3 GB** |
| **Local Total** | | | **~5 GB / 4.2 TB** ✅ |
| **NAS (accumulated)** | ~2.6 GB | unlimited | **~500 GB limit** |

**Local storage:** 4.2 TB on `/mnt/k8s-storage` — backups use <1%
**NAS storage:** 500 GB limit — ~190 days before pruning needed at current rate

---

## 🔥 DISASTER SCENARIOS

### Scenario 1: Complete Cluster Loss

**Without Backups:**
1. ❌ Lose all Authentik OIDC configurations → Reconfigure 8 apps manually
2. ❌ Lose all application databases → Immich metadata, Paperless documents index
3. ❌ Lose all Home Assistant automations/history
4. ❌ Lose SOPS age key → Cannot decrypt any secrets, full reconfiguration needed

**Recovery Time:** 16-24 hours of manual reconfiguration

**With Backups (Current System):**
1. ✅ Restore SOPS age key → Enables Flux to decrypt all secrets
2. ✅ Pull backups from NAS → All databases and PVC data available
3. ✅ Restore PostgreSQL + MySQL → All OIDC configs + databases restored
4. ✅ Restore PVCs → All user data restored (documents, configs)
5. ✅ GitOps redeploys infrastructure → All apps running

**Recovery Time:** ~30 minutes (mostly rsync from NAS + restore time)

### Scenario 2: Single Node Failure

**worker-node failure:**
- ✅ Backups on NAS (full history) and worker-node-2 (today's backup)
- ✅ Rebuild node, rejoin cluster, restore from NAS
- ✅ Database replicas on worker-node-2 continue serving reads

**worker-node-2 failure:**
- ✅ Safety net only — NAS has full backup history
- ✅ Rebuild node, rejoin cluster, Flux redeploys replicas

### Scenario 3: Database Corruption

**With Backups:**
- ✅ Restore from last good backup on NAS (< 24h old)
- ✅ Minimal data loss (max 24 hours)
- ✅ All OIDC configs preserved

### Scenario 4: Accidental Deletion

**With Backups:**
- ✅ Restore specific application from backup
- ✅ Restore specific database from PostgreSQL/MySQL backup
- ✅ Restore PVC data from timestamped backup on NAS

---

## 🔄 COMPLETE DISASTER RECOVERY PROCEDURE

### Full Cluster Rebuild from Scratch

**Prerequisites:**
- NAS accessible at 192.168.1.136 (or worker-node-2 at 192.168.1.126)
- Secret backups in `.backup/` (encrypted GPG archive)
- Git repo with infrastructure code
- SOPS age key backup (in `.backup/` or 1Password)

**Recovery Steps:**

#### 1. Rebuild K3s Cluster

**On control-plane node (192.168.1.127):**
```bash
curl -sfL https://get.k3s.io | sh -
sudo cat /var/lib/rancher/k3s/server/node-token
```

**On worker-node (192.168.1.129):**
```bash
export K3S_URL=https://192.168.1.127:6443
export K3S_TOKEN=<token-from-control-plane>
curl -sfL https://get.k3s.io | sh -
```

**On worker-node-2 (192.168.1.126):**
```bash
export K3S_URL=https://192.168.1.127:6443
export K3S_TOKEN=<token-from-control-plane>
curl -sfL https://get.k3s.io | sh -
```

**Get kubeconfig:**
```bash
sudo cat /etc/rancher/k3s/k3s.yaml
# Copy to ~/.kube/config and update server IP
```

#### 2. Configure Firewall

```bash
# On all 3 nodes
sudo ufw allow from 192.168.1.0/24
```

#### 3. Restore ALL Secrets (BEFORE Flux)

```bash
cd .backup
./secrets-restore.sh
```

This restores:
- SOPS age encryption key (CRITICAL - needed by Flux)
- All infrastructure secrets (Cloudflare, Grafana, Telegram)
- All database credentials (PostgreSQL, MySQL, Redis)
- All application secrets
- All OIDC integration secrets
- Backup replication credentials (SSH key + NAS rsync)

#### 4. Bootstrap Flux

```bash
flux bootstrap github \
  --owner=AKhozya \
  --repository=homelab \
  --path=clusters/staging \
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
  rsync://akhozya@192.168.1.136/akhozya/backups/homelab/ \
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

MYSQL_ROOT_PWD=$(kubectl get secret -n databases main-mysql-secrets -o jsonpath='{.data.root}' | base64 -d)

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
  kubectl exec -i -n couchdb couchdb-couchdb-0 -- \
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

**Total Recovery Time:** ~30 minutes

---

## 🔍 MONITORING BACKUPS

### Check Backup Status

```bash
# View CronJobs
kubectl get cronjobs -A | grep backup

# Check last run
kubectl get jobs -A | grep backup

# View logs
kubectl logs -n databases job/postgres-backup-XXXXX
kubectl logs -n couchdb job/couchdb-backup-XXXXX
kubectl logs -n kube-system job/pvc-backup-XXXXX
kubectl logs -n databases job/mysql-backup-XXXXX
kubectl logs -n backup-replication job/backup-replication-XXXXX

# Check backup storage on worker-node
du -sh /mnt/k8s-storage/backups/*/

# Check NAS storage
export RSYNC_PASSWORD='<nas-rsync-password>'
rsync --port=50555 -r --list-only \
  rsync://akhozya@192.168.1.136/akhozya/backups/homelab/ | head -20
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

## 📅 BACKUP SCHEDULE SUMMARY

| What | When | Where | Retention | Replication |
|------|------|-------|-----------|-------------|
| **PostgreSQL** | Daily 3:00 AM | `/mnt/k8s-storage/backups/postgres/` | 30 days | NAS + worker-2 |
| **CouchDB** | Daily 3:05 AM | `/mnt/k8s-storage/backups/couchdb/` | 30 days | NAS + worker-2 |
| **PVC** | Daily 3:10 AM | `/mnt/k8s-storage/backups/pvc/` | 7 days | NAS + worker-2 |
| **MySQL** | Daily 3:15 AM | `/mnt/k8s-storage/backups/mysql/` | 30 days | NAS + worker-2 |
| **Replication** | Daily 3:30 AM | NAS + worker-node-2 | NAS: unlimited | - |
| **Secrets** | Manual (monthly) | `.backup/` | Encrypted GPG | Store in 1Password |

---

## ✅ VERIFICATION CHECKLIST

**Daily (automated):**
- ✅ PostgreSQL backup job completes successfully
- ✅ CouchDB backup job completes successfully
- ✅ PVC backup job completes successfully
- ✅ MySQL backup job completes successfully
- ✅ Backup replication to NAS + worker-node-2 completes
- ✅ Backup storage utilization < 70%

**Monthly (manual):**
- ✅ Run secrets backup script
- ✅ Store secrets backup securely (1Password, encrypted USB)
- ✅ Test restore of one database (verify backups are valid)
- ✅ Review backup logs for any errors
- ✅ Check NAS storage usage (warn 400GB, critical 450GB)

**Quarterly (validation):**
- ✅ Full disaster recovery test in staging environment
- ✅ Verify all applications restore correctly
- ✅ Update disaster recovery documentation if needed

---

## 💡 FUTURE ENHANCEMENTS

### ✅ NAS Offsite Backup - COMPLETED (2026-02-06)

- ✅ Rsync backups to NAS daily at 3:30 AM
- ✅ NAS accumulates full history (no `--delete`)
- ✅ 500GB storage allocation (~190 days at current rate)
- ✅ Manual pruning via NAS web UI when needed
- ✅ worker-node-2 as temporary safety net

### Remaining Enhancements

1. **Automated Backup Validation (P1):**
   - Automated restore testing
   - Integrity checks beyond SHA256
   - Alert if backups are corrupted
   - Target: February 2026

2. **Monitoring Integration (P2):**
   - Prometheus metrics for backup job success/failure
   - Grafana dashboard for backup monitoring (partially done)
   - Alertmanager alerts if backup jobs fail

---

## 📝 CHANGELOG

### 2026-02-06: NAS Backup Replication
- ✅ Added NAS (Zettlab 6 Ultra) as primary backup destination
- ✅ Added worker-node-2 as temporary safety net (until ~Feb 13, 2026)
- ✅ Backup replication CronJob at 3:30 AM daily
- ✅ NAS accumulates full history, worker-node-2 mirrors today only
- ✅ Source cleaned after successful replication
- ✅ NAS storage monitoring (warn 400GB, critical 450GB)
- ✅ Updated disaster recovery procedures with NAS/worker-2 restore paths
- ✅ Added nas-rsync-credentials to secrets backup/restore scripts
- ✅ Reduced RTO from 2-4 hours to ~30 minutes

### 2025-12-18: MySQL Backups and Immich Exclusion
- ✅ Added MySQL automated backups (3:15 AM, homeassistant/uptimekuma/pricebuddy)
- ✅ Excluded Immich from PVC backups (photos re-uploadable, DB in PostgreSQL)
- ✅ Storage reduced from ~323GB to ~5GB per retention cycle
- ✅ Updated backup schedule times (3:00/3:05/3:10/3:15 AM)

### 2025-10-31: SHA256 Checksums and Documentation Updates
- ✅ Added SHA256 checksum generation to PVC backup script
- ✅ All three backup systems now generate SHA256 checksums
- ✅ Documented SSH keys and SOPS age key in 1Password
- ✅ Updated restore procedures to include SHA256 verification
- ✅ Verified GPG encryption with interactive passphrase

### 2025-10-23: Backups Fully Operational
- ✅ PostgreSQL automated backups implemented and tested
- ✅ CouchDB automated backups implemented and tested
- ✅ PVC automated backups implemented and tested
- ✅ Simplified from zstd ultra to gzip
- ✅ Added 8 OIDC secrets to backup scripts

### 2025-10-22: Initial Assessment
- ❌ No backups configured
- ❌ 4.2TB storage available but unused
- 🚨 Risk: Complete data loss if cluster fails

---

**Document Owner:** Alexander Khozya
**Next Review:** 2026-02-09 (monthly review cycle)
**Status:** ✅ FULLY OPERATIONAL - All P0 requirements met, NAS replication active
