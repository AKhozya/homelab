# 💾 HOMELAB BACKUP STRATEGY

**Last Updated:** 2025-10-23
**Status:** ✅ **FULLY OPERATIONAL**
**Priority:** **P0 - CRITICAL** (Implemented and tested)

---

## 🎯 BACKUP OBJECTIVES

**Recovery Point Objective (RPO):** 24 hours (daily automated backups)
**Recovery Time Objective (RTO):** 2-4 hours (time to restore cluster from backups)

**What We're Protecting:**
1. 🔴 **CRITICAL**: Authentik database (all OIDC configs + user data)
2. 🔴 **CRITICAL**: SOPS age encryption key (needed to decrypt all other secrets)
3. 🟡 **HIGH**: Application databases (Immich, Paperless, Grafana, etc.)
4. 🟡 **HIGH**: User data (photos, documents, configs)
5. 🟢 **MEDIUM**: Application state (Home Assistant, CouchDB)

---

## 📊 CURRENT STATE - FULLY OPERATIONAL ✅

### Automated Backup System (Deployed as of 2025-10-23)

| Backup Type | Schedule | Namespace | Retention | Compression | Status |
|------------|----------|-----------|-----------|-------------|--------|
| **PostgreSQL** | 2:00 AM daily | databases | 30 days | gzip (tar.gz) | ✅ Operational |
| **CouchDB** | 2:30 AM daily | couchdb | 30 days | gzip (tar.gz) | ✅ Operational |
| **PVC** | 3:00 AM daily | kube-system | 3 days | gzip (tar.gz) | ✅ Operational |
| **Kubernetes Secrets** | Manual (monthly) | N/A | In `.backup/` | Unencrypted JSON | ✅ Scripts ready |

### What's Protected (GitOps + Automated Backups)

✅ **In Git (Infrastructure as Code):**
- Kubernetes manifests (deployments, services, ingress)
- ConfigMaps (Home Assistant configuration.yaml, etc.)
- Secrets (SOPS-encrypted with age)
- Network policies, RBAC
- OIDC environment variable configs

✅ **Automated Daily Backups:**
- **PostgreSQL databases** (10 databases: authentik, immich, paperless, grafana, linkding, mealie, wallabag, audiobookshelf, n8n, app)
- **CouchDB databases** (obsidian-personal)
- **Critical PVCs:**
  - `home-assistant-data-pvc` - Home Assistant config + SQLite DB
  - `immich-library` - Photos/videos (60.6GB)
  - `paperless-data-pvc` - Document files
  - `couchdb-storage` - Obsidian sync data
  - `audiobookshelf-audiobooks` + `audiobookshelf-podcasts`

✅ **Manual Secret Backups (Scripts in `.backup/`):**
- SOPS age encryption key (CRITICAL!)
- Cloudflare API tokens
- Database credentials (PostgreSQL admin, Redis, all app DB users)
- Application secrets (admin credentials, API keys, env vars)
- **NEW:** OIDC integration secrets (8 applications)

---

## 🛠️ BACKUP IMPLEMENTATION DETAILS

### 1. PostgreSQL Automated Backups

**File:** `infrastructure/configs/staging/databases/postgres/postgres-backup-cronjob.yaml`

**Implementation:**
- CronJob runs daily at 2:00 AM
- Uses `pg_dump -F c` (custom format) for each database
- Auto-discovers databases (excludes system databases)
- Compresses entire backup directory with `tar -czf` (gzip)
- **Generates SHA256 checksum** for backup integrity verification
- Stores at `/mnt/k8s-backup/postgres/` on worker node

**Results:**
- **10 databases** backed up successfully
- **Total compressed size:** 43.3MB (with gzip)
- **Duration:** ~40 seconds
- **Authentik database:** 2.3MB (contains all OIDC configs!)

**Storage:** 30-day retention = ~1.3GB total

**Restore procedure:**
```bash
# Verify backup integrity
sha256sum -c /mnt/k8s-backup/postgres/postgres_YYYYMMDD_HHMMSS.tar.gz.sha256

# Extract latest backup
tar -xzf /mnt/k8s-backup/postgres/postgres_YYYYMMDD_HHMMSS.tar.gz

# Restore specific database
kubectl exec -n databases main-postgres-1 -- \
  pg_restore -U postgres -d authentik -c /path/to/authentik.dump
```

---

### 2. CouchDB Automated Backups

**File:** `infrastructure/configs/staging/databases/couchdb/couchdb-backup-cronjob.yaml`

**Implementation:**
- CronJob runs daily at 2:30 AM
- Uses `@cloudant/couchbackup` npm package
- Auto-discovers databases (excludes system databases)
- Exports each database to `.couchbackup` format
- Compresses with `tar -czf` (gzip)
- **Generates SHA256 checksum** for backup integrity verification
- Stores at `/mnt/k8s-backup/couchdb/` on worker node

**Results:**
- **obsidian-personal:** 3.1MB (compressed)
- **Duration:** ~40 seconds

**Storage:** 30-day retention = ~90MB total

**Restore procedure:**
```bash
# Verify backup integrity
sha256sum -c /mnt/k8s-backup/couchdb/couchdb_YYYYMMDD_HHMMSS.tar.gz.sha256

# Extract backup
tar -xzf /mnt/k8s-backup/couchdb/couchdb_YYYYMMDD_HHMMSS.tar.gz

# Restore database
cat obsidian-personal.couchbackup | couchrestore \
  --url http://admin:PASSWORD@couchdb:5984 \
  --db obsidian-personal
```

---

### 3. PVC Automated Backups

**File:** `infrastructure/configs/staging/backup/pvc-backup-cronjob.yaml`

**Implementation:**
- CronJob runs daily at 3:10 AM (after database backups)
- Uses `tar -czf` for direct compression (no complex pipelines)
- Backs up critical PVCs only (not all PVCs)
- **Generates SHA256 checksum** for each backup file for integrity verification
- Stores at `/mnt/k8s-backup/pvc/YYYYMMDD_HHMMSS/` on worker node
- Organized by namespace

**Backed up PVCs:**
- `home-assistant/home-assistant-data-pvc` - 52.8M → 18.1M (66% compression, 1s)
- `immich/immich-library` - 60.6GB → ~46GB (24% compression for photos/videos)
- `paperless-ngx/paperless-data-pvc`
- `couchdb/database-storage-couchdb-couchdb-0`
- `audiobookshelf/audiobookshelf-audiobooks`
- `audiobookshelf/audiobookshelf-podcasts`

**Results:**
- **Duration:** ~30-60 minutes (mostly Immich library)
- **Resource usage:** 1 core CPU / 48Mi memory (very efficient!)
- **Resources allocated:** 2 cores / 512Mi (plenty of headroom)

**Storage:** 3-day retention = ~138GB total

**Restore procedure:**
```bash
# Verify backup integrity
cd /mnt/k8s-backup/pvc/YYYYMMDD_HHMMSS/home-assistant
sha256sum -c home-assistant-data-pvc.tar.gz.sha256

# Stop application
kubectl scale deployment/home-assistant -n home-assistant --replicas=0

# Extract and restore
tar -xzf home-assistant-data-pvc.tar.gz -C /mnt/k8s-storage/pvc-XXXXX/

# Restart application
kubectl scale deployment/home-assistant -n home-assistant --replicas=1
```

---

### 4. Kubernetes Secrets Manual Backups

**Files:** `.backup/secrets-backup.sh` and `.backup/secrets-restore.sh`

**What's backed up:**
- 🔑 **CRITICAL:** SOPS age encryption key (needed for Flux to decrypt everything)
- 🌐 Cloudflare API token & tunnel credentials
- 📊 Grafana admin secret
- 📱 Alertmanager Telegram bot token
- 🗄️ PostgreSQL admin user credentials
- 🗄️ Redis passwords
- 🗄️ All application database user credentials (authentik, immich, linkding, mealie, n8n, paperless, wallabag)
- 📱 All application secrets (25+ applications)
- 🔐 **NEW:** OIDC integration secrets (audiobookshelf, grafana, home-assistant, immich, linkding, mealie, n8n, paperless-ngx)

**What's NOT backed up (already stored securely):**
- 🔑 **SSH keys**: **Already stored in 1Password** ✅
  - **Not on disk** - 1Password SSH agent manages keys securely
  - **Critical for**: Git operations, cluster access, Flux GitHub integration
  - **No backup needed** - 1Password is the source of truth
- 📦 **Local SOPS age key**: **Already stored in 1Password** ✅
  - **Also at**: `~/.config/sops/age/keys.txt` (local copy)
  - **No backup needed** - 1Password is the source of truth

**Encryption:** 🔐 **GPG AES256 with interactive passphrase**
- Script prompts for passphrase during backup
- No hardcoded defaults for security
- Passphrase confirmation to prevent typos
- Backups saved as `.tar.gz.gpg` encrypted archives

**Usage:**
```bash
# Create backup (run monthly or before major changes)
cd .backup
./secrets-backup.sh

# You'll be prompted:
# - Enter passphrase: [hidden]
# - Confirm passphrase: [hidden]
#
# Output: secrets-backup-YYYYMMDD_HHMMSS.tar.gz.gpg
# ⚠️ Store passphrase in 1Password!
```

**Restore procedure:**
```bash
# Run BEFORE bootstrapping Flux on fresh cluster
cd .backup
./secrets-restore.sh

# The script will:
# 1. Automatically find latest encrypted backup
# 2. Prompt for passphrase to decrypt
# 3. Restore all secrets to cluster
#
# Then bootstrap Flux
flux bootstrap github --owner=AKhozya --repository=homelab --path=clusters/staging --personal
```

---

## 📈 STORAGE PROJECTIONS

### Current Usage with gzip Compression

| Backup | Size/Day | Retention | Total Storage |
|--------|----------|-----------|---------------|
| PostgreSQL | 43 MB | 30 days | **1.3 GB** |
| CouchDB | 3 MB | 30 days | **90 MB** |
| PVC | 46 GB | 3 days | **138 GB** |
| **TOTAL** | | | **~139 GB / 4.2 TB** ✅ |

**Available storage:** 4.2 TB on `/mnt/k8s-storage`
**Used by backups:** 139 GB (3.3%)
**Plenty of room for growth!** ✅

### Why gzip instead of zstd ultra?

**Compression comparison:**

| Backup Type | gzip size | zstd ultra size | Difference | Trade-off |
|-------------|-----------|-----------------|------------|-----------|
| PostgreSQL | 43.3MB | ~25MB | +18MB | Acceptable |
| CouchDB | 3.1MB | ~1.5MB | +1.6MB | Negligible |
| PVC | ~46GB | ~34GB | +12GB | Worth simplicity |
| **Total extra storage** | | | **~32GB** | **0.76% of 4.2TB** |

**Decision:** Trading 32GB storage (0.76% of total) for massive complexity reduction is absolutely worth it.

**Complexity removed by using gzip:**
- ❌ No zstd installation (45+ lines of initContainer code)
- ❌ No elevated permissions for package installation
- ❌ No volume sharing for binaries
- ❌ No broken pipe issues from pv
- ❌ No subshell variable scoping problems

**Result:** Simple, standard `tar -czf` compression with built-in tools only.

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
2. ✅ Restore PostgreSQL → All OIDC configs + databases restored (authentik, immich, etc.)
3. ✅ Restore PVCs → All user data restored (photos, documents, configs)
4. ✅ GitOps redeploys infrastructure → All apps running

**Recovery Time:** 2-4 hours (mostly restore time)

### Scenario 2: Database Corruption

**With Backups:**
- ✅ Restore from last good backup (< 24h old)
- ✅ Minimal data loss (max 24 hours)
- ✅ All OIDC configs preserved

### Scenario 3: Accidental Deletion

**With Backups:**
- ✅ Restore specific application from backup
- ✅ Restore specific database from PostgreSQL backup
- ✅ Restore PVC data from timestamped backup

---

## 🔄 COMPLETE DISASTER RECOVERY PROCEDURE

### Full Cluster Rebuild from Scratch

**Prerequisites:**
- Backups available at `/mnt/k8s-backup/`
- Secret backups in `.backup/secrets/`
- Git repo with infrastructure code
- SOPS age key backup

**Recovery Steps:**

#### 1. Rebuild K3s Cluster

**On control-plane node (192.168.1.127):**
```bash
curl -sfL https://get.k3s.io | sh -
sudo cat /var/lib/rancher/k3s/server/node-token
```

**On worker node (192.168.1.129):**
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
# On both nodes
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
- All database credentials
- All application secrets
- All OIDC integration secrets

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

#### 6. Restore PostgreSQL Databases

```bash
# Find latest backup
LATEST_BACKUP=$(ls -t /mnt/k8s-backup/postgres/postgres_*.tar.gz | head -1)

# Extract
tar -xzf $LATEST_BACKUP -C /tmp

# Restore each database
for DB in authentik immich paperless grafana linkding mealie wallabag audiobookshelf n8n app; do
  echo "Restoring $DB..."
  kubectl exec -n databases main-postgres-1 -- \
    pg_restore -U postgres -d $DB -c --if-exists \
    /tmp/$(basename $LATEST_BACKUP .tar.gz)/${DB}.dump
done
```

#### 7. Restore CouchDB

```bash
# Find latest backup
LATEST_COUCHDB=$(ls -t /mnt/k8s-backup/couchdb/couchdb_*.tar.gz | head -1)

# Extract
tar -xzf $LATEST_COUCHDB -C /tmp

# Restore database (adjust credentials from restored secrets)
cat /tmp/*/obsidian-personal.couchbackup | \
  kubectl exec -i -n couchdb couchdb-couchdb-0 -- \
  couchrestore --url http://admin:PASSWORD@localhost:5984 --db obsidian-personal
```

#### 8. Restore PVCs

```bash
# Find latest PVC backup
LATEST_PVC=$(ls -td /mnt/k8s-backup/pvc/* | head -1)

# For each critical PVC:
# 1. Stop application
kubectl scale deployment/home-assistant -n home-assistant --replicas=0

# 2. Extract backup to PVC location
tar -xzf $LATEST_PVC/home-assistant/home-assistant-data-pvc.tar.gz \
  -C /mnt/k8s-storage/pvc-XXXXX/

# 3. Restart application
kubectl scale deployment/home-assistant -n home-assistant --replicas=1

# Repeat for: immich, paperless-ngx, couchdb, audiobookshelf
```

#### 9. Verify Applications

```bash
# Check all pods are running
kubectl get pods -A

# Test applications
curl -I https://authentik.h0melab.work
curl -I https://grafana.h0melab.work
curl -I https://immich.h0melab.work

# Test OIDC login on all apps
```

**Total Recovery Time:** 2-4 hours

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

# Check backup storage usage
kubectl debug node/worker-node -it --image=alpine:3.22 -- \
  sh -c "du -sh /host/mnt/k8s-backup/*"

# List backups
kubectl debug node/worker-node -it --image=alpine:3.22 -- \
  sh -c "ls -lh /host/mnt/k8s-backup/postgres/"
```

### Manual Backup Trigger (for testing)

```bash
# PostgreSQL
kubectl create job --from=cronjob/postgres-backup postgres-backup-manual -n databases

# CouchDB
kubectl create job --from=cronjob/couchdb-backup couchdb-backup-manual -n couchdb

# PVC
kubectl create job --from=cronjob/pvc-backup pvc-backup-manual -n kube-system

# Secrets (manual script)
cd .backup
./secrets-backup.sh
```

---

## 📅 BACKUP SCHEDULE SUMMARY

| What | When | Where | How | Retention |
|------|------|-------|-----|-----------|
| **PostgreSQL** | Daily 2:00 AM | `/mnt/k8s-backup/postgres/` | Automated CronJob | 30 days |
| **CouchDB** | Daily 2:30 AM | `/mnt/k8s-backup/couchdb/` | Automated CronJob | 30 days |
| **PVC** | Daily 3:00 AM | `/mnt/k8s-backup/pvc/` | Automated CronJob | 3 days |
| **Secrets** | Manual (monthly) | `.backup/secrets/` | Manual script | Store securely |

---

## ✅ VERIFICATION CHECKLIST

**Daily (automated):**
- ✅ PostgreSQL backup job completes successfully
- ✅ CouchDB backup job completes successfully
- ✅ PVC backup job completes successfully
- ✅ Backup storage utilization < 70%

**Monthly (manual):**
- ✅ Run secrets backup script
- ✅ Store secrets backup securely (1Password, encrypted USB)
- ✅ Test restore of one database (verify backups are valid)
- ✅ Review backup logs for any errors

**Quarterly (validation):**
- ✅ Full disaster recovery test in staging environment
- ✅ Verify all applications restore correctly
- ✅ Update disaster recovery documentation if needed

---

## 💡 FUTURE ENHANCEMENTS

### When 24TB NAS is Available

1. **Offsite Backup (P1):**
   - Rsync backups to NAS nightly
   - Keep longer retention (90 days)
   - True disaster recovery (fire, theft, hardware failure)

2. **Backup Verification:**
   - Automated restore testing
   - Integrity checks
   - Alert if backups are corrupted

3. **Application-Level Backups:**
   - Immich: Built-in backup features
   - Paperless: Export automation
   - Home Assistant: Snapshot automation

### Monitoring Integration (P2)

- Prometheus metrics for backup job success/failure
- Grafana dashboard for backup monitoring
- Alertmanager alerts if backup jobs fail

---

## 📝 CHANGELOG

### 2025-10-31: SHA256 Checksums and Documentation Updates
- ✅ Added SHA256 checksum generation to PVC backup script (completes backup integrity checks)
- ✅ All three backup systems now generate SHA256 checksums (PostgreSQL, CouchDB, PVC)
- ✅ Documented SSH keys and SOPS age key already stored in 1Password (no backup needed)
- ✅ Updated restore procedures to include SHA256 verification steps
- ✅ Verified PgBouncer pooler usage - all apps correctly using rw-pooler
- ✅ Verified GPG encryption already implemented with interactive passphrase
- 📋 Updated HOMELAB_ANALYSIS.md to mark both tasks as complete

### 2025-10-23: Backups Fully Operational
- ✅ PostgreSQL automated backups implemented and tested (10 databases, 43.3MB)
- ✅ CouchDB automated backups implemented and tested (3.1MB)
- ✅ PVC automated backups implemented and tested (138GB/3 days)
- ✅ Simplified from zstd ultra to gzip (removed complexity, added 32GB/0.76%)
- ✅ Fixed PVC backup script (for loop, no pv pipeline)
- ✅ Optimized PVC resources (2 cores / 512Mi, actual usage: 1 core / 48Mi)
- ✅ Added 8 OIDC secrets to backup scripts
- 📋 Status changed from "NEEDS IMPLEMENTATION" to "FULLY OPERATIONAL"

### 2025-10-22: Initial Assessment
- ❌ No backups configured
- ❌ 4.2TB storage available but unused
- 🚨 Risk: Complete data loss if cluster fails
- 📋 Action: Implement backup strategy immediately

---

**Document Owner:** Alexander Khozya
**Next Review:** 2025-11-23 (monthly review cycle)
**Status:** ✅ FULLY OPERATIONAL - All P0 requirements met
