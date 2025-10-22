# 💾 HOMELAB BACKUP STRATEGY

**Last Updated:** 2025-10-22
**Status:** 🚨 **NEEDS IMPLEMENTATION**
**Priority:** **P0 - CRITICAL**

---

## 🎯 BACKUP OBJECTIVES

**Recovery Point Objective (RPO):** 24 hours (daily backups)
**Recovery Time Objective (RTO):** 4 hours (time to restore cluster)

**What We're Protecting:**
1. 🔴 **CRITICAL**: Authentik database (all OIDC configs)
2. 🟡 **HIGH**: Application databases (Immich, Paperless, Grafana)
3. 🟡 **HIGH**: User data (photos, documents, configs)
4. 🟢 **MEDIUM**: Application state (Home Assistant, etc.)

---

## 📊 CURRENT STATE

### What's Protected (GitOps)

✅ **Already in Git:**
- Infrastructure code (deployments, services, ingress)
- ConfigMaps (Home Assistant configuration.yaml, etc.)
- Secrets (SOPS-encrypted)
- Network policies
- OIDC environment variable configs

### What's NOT Protected (Needs Backup)

❌ **Databases (PostgreSQL):**
```
main-postgres (CloudNativePG cluster - 3x10Gi)
├─ authentik (CRITICAL - all OIDC configs!)
├─ immich (photos metadata + OIDC Web UI config)
├─ paperless (documents index)
├─ grafana (dashboards + OIDC config)
├─ linkding (bookmarks)
└─ mealie (recipes)
```

❌ **Application Data (PVCs):**
```
CRITICAL:
- home-assistant-data-pvc (10Gi) - SQLite DB, automations
- immich-library (300Gi) - Photos/videos
- paperless-data-pvc (100Gi) - Document files

HIGH:
- couchdb (30Gi) - Obsidian sync
- audiobookshelf-* (30Gi total) - Audiobooks/podcasts

MEDIUM:
- Other app PVCs (state, configs)
```

❌ **Redis State:**
```
- redis-0 (5Gi) - Authentik cache/sessions
```

---

## 🔥 DISASTER SCENARIOS

### Scenario 1: Complete Cluster Loss

**Without Backups:**
1. ❌ Lose all Authentik OIDC configurations → Reconfigure 7 apps manually
2. ❌ Lose Immich OIDC Web UI config → Reconfigure manually
3. ❌ Lose Grafana OIDC config → Reconfigure manually
4. ❌ Lose Audiobookshelf OIDC config → Reconfigure manually
5. ❌ Lose all Home Assistant automations/history
6. ❌ Lose all application data

**Recovery Time:** 8-16 hours of manual reconfiguration

**With Backups:**
1. ✅ Restore PostgreSQL from backup → All OIDC configs restored
2. ✅ Restore PVCs from backup → All data restored
3. ✅ GitOps redeploys infrastructure → All apps running

**Recovery Time:** 2-4 hours (mostly restore time)

### Scenario 2: Database Corruption

**Without Backups:**
- ❌ Lose Authentik database → Reconfigure all OIDC
- ❌ Lose app databases → Lose metadata, configs

**With Backups:**
- ✅ Restore from last good backup (< 24h old)
- ✅ Minimal data loss

### Scenario 3: Accidental Deletion

**Without Backups:**
- ❌ Accidentally delete namespace → All configs lost

**With Backups:**
- ✅ Restore from backup

---

## 🛠️ BACKUP IMPLEMENTATION

### Phase 1: PostgreSQL Backups (CRITICAL - Do First)

#### CloudNativePG Backup to Local Storage

**Target:** `/mnt/k8s-backup` (on worker node with 4.2TB storage)

**Configuration:**

```yaml
# infrastructure/base/databases/postgres-cluster.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: main-postgres
  namespace: databases
spec:
  instances: 3

  # ADD THIS SECTION:
  backup:
    barmanObjectStore:
      destinationPath: file:///backup/postgres
      serverName: main-postgres
      wal:
        compression: gzip
        maxParallel: 2
      data:
        compression: gzip

    retentionPolicy: "30d"  # Keep 30 days of backups

  # ADD VOLUME FOR BACKUP STORAGE:
  storage:
    size: 10Gi
    storageClass: local-path

  # BACKUP VOLUME (new):
  additionalVolumes:
    - name: backup-storage
      hostPath:
        path: /mnt/k8s-backup/postgres
        type: DirectoryOrCreate

  # MOUNT BACKUP VOLUME:
  additionalVolumeMounts:
    - name: backup-storage
      mountPath: /backup
```

**Scheduled Backups:**

```yaml
# infrastructure/base/databases/postgres-backup-schedule.yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: daily-backup
  namespace: databases
spec:
  schedule: "0 2 * * *"  # 2 AM daily
  backupOwnerReference: self
  cluster:
    name: main-postgres
  immediate: true  # Take first backup immediately
```

**Manual Backup (for testing):**

```bash
# Trigger immediate backup
kubectl cnpg backup main-postgres -n databases

# List backups
kubectl get backups -n databases

# Check backup status
kubectl describe backup <backup-name> -n databases
```

#### Alternative: Simple pg_dump Backup Job

If CloudNativePG backup is complex, use this simpler approach:

```yaml
# infrastructure/base/databases/postgres-backup-job.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: postgres-backup
  namespace: databases
spec:
  schedule: "0 2 * * *"  # 2 AM daily
  successfulJobsHistoryLimit: 7
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: backup
              image: postgres:16
              command:
                - /bin/bash
                - -c
                - |
                  set -e
                  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
                  BACKUP_DIR="/backup/$TIMESTAMP"
                  mkdir -p "$BACKUP_DIR"

                  # Backup all databases
                  for DB in authentik immich paperless grafana linkding mealie; do
                    echo "Backing up $DB..."
                    PGPASSWORD="$POSTGRES_PASSWORD" pg_dump \
                      -h main-postgres-rw.databases.svc.cluster.local \
                      -U postgres \
                      -d "$DB" \
                      -F c \
                      -f "$BACKUP_DIR/${DB}.dump"
                  done

                  # Compress backup
                  cd /backup
                  tar -czf "postgres_${TIMESTAMP}.tar.gz" "$TIMESTAMP"
                  rm -rf "$TIMESTAMP"

                  # Keep only last 30 days
                  find /backup -name "postgres_*.tar.gz" -mtime +30 -delete

                  echo "Backup complete: postgres_${TIMESTAMP}.tar.gz"
              env:
                - name: POSTGRES_PASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: main-postgres-superuser
                      key: password
              volumeMounts:
                - name: backup-storage
                  mountPath: /backup
          volumes:
            - name: backup-storage
              hostPath:
                path: /mnt/k8s-backup/postgres
                type: DirectoryOrCreate
```

**To restore a database:**

```bash
# Copy backup from node
kubectl cp databases/postgres-backup-xxx:/backup/postgres_20251022_020000.tar.gz ./backup.tar.gz

# Extract
tar -xzf backup.tar.gz

# Restore specific database
kubectl exec -n databases main-postgres-1 -- pg_restore \
  -U postgres \
  -d authentik \
  -c \
  --if-exists \
  /path/to/authentik.dump
```

---

### Phase 2: PVC Backups (Critical Data)

#### Option A: Velero (Recommended for Production)

**Install Velero:**

```bash
# Add Velero Helm repo
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm repo update

# Install Velero with local storage
helm install velero vmware-tanzu/velero \
  --namespace velero \
  --create-namespace \
  --set configuration.provider=aws \
  --set configuration.backupStorageLocation.bucket=k3s-backups \
  --set configuration.backupStorageLocation.config.region=minio \
  --set configuration.backupStorageLocation.config.s3ForcePathStyle=true \
  --set configuration.backupStorageLocation.config.s3Url=http://minio.minio.svc.cluster.local:9000 \
  --set initContainers[0].name=velero-plugin-for-aws \
  --set initContainers[0].image=velero/velero-plugin-for-aws:v1.9.0 \
  --set initContainers[0].volumeMounts[0].mountPath=/target \
  --set initContainers[0].volumeMounts[0].name=plugins
```

**Daily Backup Schedule:**

```yaml
# infrastructure/base/velero/backup-schedule.yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: daily-full-backup
  namespace: velero
spec:
  schedule: "0 3 * * *"  # 3 AM daily
  template:
    ttl: 720h  # 30 days
    includedNamespaces:
      - home-assistant
      - immich
      - paperless-ngx
      - authentik
      - databases
      - audiobookshelf
      - couchdb
    snapshotVolumes: true
```

#### Option B: Simple rsync Backup Script (Quick Start)

```yaml
# infrastructure/base/backup/pvc-backup-job.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pvc-backup
  namespace: kube-system
spec:
  schedule: "0 3 * * *"  # 3 AM daily
  successfulJobsHistoryLimit: 7
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          hostNetwork: true
          containers:
            - name: backup
              image: alpine:3.21
              command:
                - /bin/sh
                - -c
                - |
                  set -e
                  apk add --no-cache rsync

                  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
                  BACKUP_ROOT="/mnt/k8s-backup/pvc/$TIMESTAMP"

                  echo "Starting PVC backup to $BACKUP_ROOT"

                  # Backup critical PVCs
                  for PVC in \
                    home-assistant/home-assistant-data-pvc \
                    immich/immich-library \
                    paperless-ngx/paperless-data-pvc \
                    couchdb/database-storage-couchdb-couchdb-0 \
                    audiobookshelf/audiobookshelf-audiobooks \
                    audiobookshelf/audiobookshelf-podcasts; do

                    NAMESPACE=$(echo $PVC | cut -d/ -f1)
                    PVC_NAME=$(echo $PVC | cut -d/ -f2)
                    SOURCE="/mnt/k8s-storage/pvc-*${PVC_NAME}*"
                    DEST="$BACKUP_ROOT/$NAMESPACE/$PVC_NAME"

                    echo "Backing up $PVC..."
                    mkdir -p "$DEST"
                    rsync -a --delete "$SOURCE/" "$DEST/" || echo "Warning: $PVC backup failed"
                  done

                  # Create manifest
                  echo "Backup completed: $TIMESTAMP" > "$BACKUP_ROOT/MANIFEST.txt"
                  date >> "$BACKUP_ROOT/MANIFEST.txt"
                  du -sh "$BACKUP_ROOT" >> "$BACKUP_ROOT/MANIFEST.txt"

                  # Keep only last 7 days (daily backups are large)
                  find /mnt/k8s-backup/pvc -maxdepth 1 -type d -mtime +7 -exec rm -rf {} \;

                  echo "Backup complete!"
              volumeMounts:
                - name: k8s-storage
                  mountPath: /mnt/k8s-storage
                  readOnly: true
                - name: backup-storage
                  mountPath: /mnt/k8s-backup
          volumes:
            - name: k8s-storage
              hostPath:
                path: /mnt/k8s-storage
                type: Directory
            - name: backup-storage
              hostPath:
                path: /mnt/k8s-backup
                type: DirectoryOrCreate
```

---

### Phase 3: Authentik Configuration Export (Extra Safety)

**Export Authentik config to YAML (for version control):**

```bash
# Export all Authentik configuration
kubectl exec -n authentik deployment/authentik-server -- \
  ak export > authentik-export-$(date +%Y%m%d).yaml

# Commit to git (encrypted with SOPS)
sops -e authentik-export-$(date +%Y%m%d).yaml > \
  apps/staging/authentik/backup/authentik-export-$(date +%Y%m%d).yaml.enc

git add apps/staging/authentik/backup/
git commit -m "Backup: Authentik configuration export"
git push
```

**To restore Authentik config:**

```bash
# Decrypt and import
sops -d apps/staging/authentik/backup/authentik-export-YYYYMMDD.yaml.enc | \
  kubectl exec -i -n authentik deployment/authentik-server -- \
  ak import --replace
```

---

## 📅 BACKUP SCHEDULE

| What | Method | Frequency | Retention | Storage |
|------|--------|-----------|-----------|---------|
| **PostgreSQL** | pg_dump or CNPG | Daily 2 AM | 30 days | `/mnt/k8s-backup/postgres` |
| **Critical PVCs** | rsync or Velero | Daily 3 AM | 7 days | `/mnt/k8s-backup/pvc` |
| **Authentik Config** | ak export | Weekly | In git | Git repo (encrypted) |
| **Redis** | Not backed up | - | - | Ephemeral (sessions only) |

**Storage Requirements:**
- PostgreSQL: ~5GB (compressed, 30 days)
- PVCs: ~450GB x 7 days = ~3TB (with compression ~1.5TB)
- Total: ~1.5TB storage needed

**Available Storage:** 4.2TB on `/mnt/k8s-storage` ✅

---

## 🔄 RESTORE PROCEDURES

### Full Cluster Rebuild from Backups

**Scenario:** Complete cluster loss, need to rebuild from scratch.

**Prerequisites:**
- Backups available at `/mnt/k8s-backup`
- Git repo with infrastructure code
- SOPS age key for secrets

**Steps:**

1. **Rebuild K3s Cluster:**
   ```bash
   # Reinstall K3s (assuming OS is intact)
   # Follow original setup procedure
   ```

2. **Restore Flux:**
   ```bash
   # Bootstrap Flux
   flux bootstrap github \
     --owner=AKhozya \
     --repository=homelab \
     --path=clusters/staging \
     --personal
   ```

3. **Wait for Infrastructure to Deploy:**
   ```bash
   # Wait for PostgreSQL cluster to be ready
   kubectl wait --for=condition=ready cluster/main-postgres -n databases --timeout=600s
   ```

4. **Restore PostgreSQL Databases:**
   ```bash
   # Find latest backup
   LATEST_BACKUP=$(ls -t /mnt/k8s-backup/postgres/*.tar.gz | head -1)

   # Extract
   tar -xzf $LATEST_BACKUP -C /tmp

   # Restore each database
   for DB in authentik immich paperless grafana linkding mealie; do
     echo "Restoring $DB..."
     kubectl exec -n databases main-postgres-1 -- \
       pg_restore -U postgres -d $DB -c --if-exists \
       /tmp/$(basename $LATEST_BACKUP .tar.gz)/${DB}.dump
   done
   ```

5. **Restore PVCs:**
   ```bash
   # Find latest PVC backup
   LATEST_PVC_BACKUP=$(ls -td /mnt/k8s-backup/pvc/* | head -1)

   # Stop applications (suspend Flux)
   flux suspend kustomization apps

   # Delete existing PVCs
   kubectl delete pvc -n home-assistant home-assistant-data-pvc
   kubectl delete pvc -n immich immich-library
   # ... etc

   # Copy backup data to PVC locations
   rsync -a $LATEST_PVC_BACKUP/ /mnt/k8s-storage/

   # Resume Flux (recreate PVCs and pods)
   flux resume kustomization apps
   ```

6. **Verify Applications:**
   ```bash
   # Check all pods are running
   kubectl get pods -A

   # Test Authentik login
   curl -I https://authentik.h0melab.work

   # Test OIDC apps (Grafana, Immich, etc.)
   ```

**Recovery Time Estimate:** 2-4 hours

---

## 🚀 IMMEDIATE ACTION PLAN

### This Week (Critical):

1. ✅ **Create backup directories:**
   ```bash
   ssh worker-node
   sudo mkdir -p /mnt/k8s-backup/{postgres,pvc}
   sudo chown -R 1000:1000 /mnt/k8s-backup
   ```

2. ✅ **Deploy PostgreSQL backup CronJob:**
   - Create `infrastructure/base/databases/postgres-backup-job.yaml`
   - Commit and push to git
   - Trigger manual backup to test

3. ✅ **Deploy PVC backup CronJob:**
   - Create `infrastructure/base/backup/pvc-backup-job.yaml`
   - Commit and push to git
   - Trigger manual backup to test

4. ✅ **Export Authentik config:**
   ```bash
   kubectl exec -n authentik deployment/authentik-server -- ak export > authentik-backup.yaml
   # Encrypt and store in git
   ```

5. ✅ **Document restore procedure:**
   - Test restore on non-critical DB
   - Update this document with actual steps

### Next Week:

6. **Set up monitoring for backups:**
   - Alert if backup jobs fail
   - Alert if backup storage fills up

7. **Consider Velero for production-grade backups**

8. **Set up offsite backup to 24TB NAS** (when available)

---

## 📊 BACKUP MONITORING

### Check Backup Status

```bash
# Check backup jobs
kubectl get cronjobs -n databases
kubectl get cronjobs -n kube-system

# View recent backup logs
kubectl logs -n databases job/postgres-backup-xxx
kubectl logs -n kube-system job/pvc-backup-xxx

# Check backup storage usage
ssh worker-node "du -sh /mnt/k8s-backup/*"

# List backups
ssh worker-node "ls -lh /mnt/k8s-backup/postgres/"
ssh worker-node "ls -lh /mnt/k8s-backup/pvc/"
```

### Backup Health Metrics

**Target:**
- ✅ Daily successful backups (postgres + pvc)
- ✅ Backup size trends monitored
- ✅ Storage utilization < 70%
- ✅ Restore tested monthly

---

## 💡 FUTURE ENHANCEMENTS

### When 24TB NAS is Available:

1. **Offsite Backup:**
   - Rsync backups to NAS nightly
   - Keep longer retention (90 days)
   - True disaster recovery

2. **Backup Verification:**
   - Automated restore testing
   - Integrity checks

3. **Application-Level Backups:**
   - Immich: Built-in backup features
   - Paperless: Export to backup location
   - Home Assistant: Snapshot automation

---

## 📝 BACKUP LOG

### 2025-10-22: Initial Assessment
- ❌ No backups configured
- ❌ 4.2TB storage available but unused
- 🚨 **Risk:** Complete data loss if cluster fails
- 📋 **Action:** Implement backup strategy immediately

---

**Document Owner:** Alexander Khozya
**Next Review:** 2025-11-22 (after backups are operational)
**Status:** 🚨 NEEDS IMPLEMENTATION - PRIORITY 0
