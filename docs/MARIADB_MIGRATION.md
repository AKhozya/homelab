# MariaDB Migration Guide

## Overview

This document describes the migration of applications from SQLite to MariaDB Galera cluster in the homelab infrastructure.

## MariaDB Architecture

### Cluster Configuration

- **Operator**: mariadb-operator v0.37.1
- **Cluster Type**: Galera (multi-master synchronous replication)
- **Replicas**: 2 instances
- **Version**: MariaDB 11.6
- **High Availability**: Active-active replication with automatic failover
- **Storage**: 10Gi per replica (local-path PVCs on worker node)

### Infrastructure Layout

```
infrastructure/
├── controllers/base/databases/mariadb/     # Operator deployment
│   ├── crds-helmrelease.yaml              # Custom Resource Definitions
│   ├── helmrelease.yaml                   # Operator Helm chart
│   └── helmrepository.yaml                # Chart repository
│
├── configs/base/databases/mariadb/         # Base cluster config
│   ├── mariadb.yaml                       # MariaDB CRD (cluster definition)
│   ├── root-password.yaml                 # SOPS-encrypted root password
│   ├── networkpolicy.yaml                 # Network isolation
│   └── serviceaccount.yaml                # Kubernetes service account
│
└── configs/staging/databases/mariadb/      # App-specific configs
    ├── mariadb-jobs-serviceaccount.yaml   # Backup job service account
    ├── mariadb-backup-cronjob.yaml        # Daily backups (3:15 AM)
    │
    # Home Assistant
    ├── ha-mariadb-credentials.yaml        # SOPS-encrypted credentials
    ├── ha-user.yaml                       # User CRD
    ├── ha-database.yaml                   # Database CRD
    └── ha-grant.yaml                      # Grant CRD
    │
    # Discount Bandit
    ├── discount-bandit-credentials.yaml   # SOPS-encrypted credentials
    ├── discount-bandit-user.yaml          # User CRD
    ├── discount-bandit-database.yaml      # Database CRD
    └── discount-bandit-grant.yaml         # Grant CRD
    │
    # Uptime Kuma
    ├── uptime-kuma-mariadb-credentials.yaml  # SOPS-encrypted credentials
    ├── uptime-kuma-user.yaml              # User CRD
    ├── uptime-kuma-database.yaml          # Database CRD
    └── uptime-kuma-grant.yaml             # Grant CRD
```

**Pattern Match with PostgreSQL**: The MariaDB structure follows the same pattern as PostgreSQL:
- **Base directory**: Infrastructure components only (cluster, root password, NetworkPolicy)
- **Staging directory**: App-specific resources (databases, users, credentials, backups)

## Migrated Applications

### 1. Home Assistant (2025-11-23)

**Migration Type**: Fresh start (no data migration needed)
- **Database**: `homeassistant` (utf8mb4, utf8mb4_unicode_ci)
- **User**: `homeassistant` (all privileges)
- **Reason**: Home Assistant handles DB schema automatically, SQLite history not needed

**Configuration**:
```yaml
# apps/base/home-assistant/deployment.yaml
env:
  - name: DB_URL
    value: "mysql://homeassistant:PASSWORD@main-mariadb-primary.databases.svc.cluster.local:3306/homeassistant?charset=utf8mb4"
```

**Result**: ✅ Successfully migrated, 42 tables created automatically

### 2. Discount Bandit (2025-11-23)

**Migration Type**: Fresh start (no data migration needed)
- **Database**: `discountbandit` (utf8mb4, utf8mb4_unicode_ci)
- **User**: `discountbandit` (all privileges)
- **Reason**: New deployment, no existing data

**Configuration**:
```yaml
# apps/base/discount-bandit/deployment.yaml
env:
  - name: DB_CONNECTION
    value: "mysql"
  - name: DB_HOST
    value: "main-mariadb-primary.databases.svc.cluster.local"
  - name: DB_DATABASE
    value: "discountbandit"
```

**Result**: ✅ Successfully migrated, Laravel migrations created schema

### 3. Uptime Kuma (2025-11-24)

**Migration Type**: Custom Python script (selective data migration)
- **Database**: `uptimekuma` (utf8mb4, utf8mb4_unicode_ci)
- **User**: `uptimekuma` (all privileges)
- **Reason**: Preserve user account, monitors, and settings while discarding heartbeat history

**Migration Script**:
- **Location**: `apps/base/uptime-kuma/sqlite-to-mariadb-migration-job.yaml` (one-time job, deleted after migration)
- **Method**: Python sqlite3 → pymysql conversion
- **Tables Migrated**: 22 tables (user, monitor, notification, setting, etc.)
- **Tables Excluded**: 5 tables (heartbeat, stat_daily, stat_hourly, stat_minutely, notification_sent_history)
- **Security**: PSS-compliant (no root, runAsUser: 1000)

**Data Migrated**:
- ✅ 1 user account (with 2FA settings)
- ✅ 21 monitors
- ✅ 13 settings
- ❌ 44,433 heartbeat rows (skipped - not needed)

**Key Challenge**: SQLite reserved keyword handling
- **Issue**: `group` table failed with "syntax error"
- **Solution**: Escape table names with double quotes in SQLite queries: `SELECT * FROM "group"`

**Configuration**:
```yaml
# apps/base/uptime-kuma/deployment.yaml
env:
  - name: UPTIME_KUMA_DB_TYPE
    value: "mariadb"
  - name: UPTIME_KUMA_DB_HOSTNAME
    value: "main-mariadb-primary.databases.svc.cluster.local"
  - name: UPTIME_KUMA_DB_NAME
    value: "uptimekuma"
```

**Result**: ✅ Successfully migrated, all monitors and users preserved

## Migration Decision Matrix

| Application | Migration Type | Reason |
|-------------|---------------|--------|
| Home Assistant | Fresh start | DB schema auto-managed, history not critical |
| Discount Bandit | Fresh start | New deployment, no existing data |
| Uptime Kuma | Custom script | Preserve user/monitors, skip heartbeat history |

## Backup Strategy

### Daily Automated Backups

**Schedule**: 3:15 AM daily (15 minutes after PostgreSQL backups)

**Backup Process**:
1. **Auto-discovery**: Discover all user databases (exclude system databases)
2. **Backup**: `mariadb-dump --single-transaction --routines --triggers --events`
3. **Compression**: tar.gz (typically ~75% size reduction)
4. **Integrity**: SHA256 checksum generated for each backup
5. **Retention**: 30-day retention policy
6. **Storage**: `/mnt/k8s-storage/backups/mariadb/` on worker node

**Example Backup**:
```
Backup ID: 20251124_231703
Databases: discountbandit (228K), homeassistant (72K), uptimekuma (324K)
Compressed: 108K (83% compression)
Checksum: d2a97b5158ded1ed0843f8f7233709bcb51896e864a8635ff819f2810bd98d05
```

**Backup CronJob**: `infrastructure/configs/staging/databases/mariadb/mariadb-backup-cronjob.yaml`

### Secret Backup

MariaDB secrets are included in the cluster-wide secret backup:

**Secrets Backed Up**:
- `mariadb-root` - Root password
- `ha-mariadb-credentials` - Home Assistant database credentials
- `discount-bandit-mariadb-credentials` - Discount Bandit database credentials
- `uptime-kuma-mariadb-credentials` - Uptime Kuma database credentials

**Backup Script**: `.backup/secrets-backup.sh`
**Restore Script**: `.backup/secrets-restore.sh`

**Encryption**: GPG AES256 with interactive passphrase

## Connection Patterns

### Application Connection

All applications connect directly to the primary instance (no pooler needed for MariaDB Galera):

```yaml
Host: main-mariadb-primary.databases.svc.cluster.local
Port: 3306
Database: <app-database>
User: <app-user>
Password: <from secret>
```

**Why No Pooler?**
- MariaDB Galera uses multi-master replication (all nodes are writable)
- Connection pooling less critical than with PostgreSQL single-primary
- Applications typically use built-in connection pooling (Laravel, Django, etc.)

### NetworkPolicy

**Ingress Rules**:
- Application namespaces (kustomize.toolkit.fluxcd.io/name=apps)
- Monitoring namespace (Prometheus metrics on port 9187)
- Intra-cluster replication (ports 3306, 4444, 4567, 4568)

**Egress Rules**:
- DNS (port 53)
- Galera replication

**File**: `infrastructure/configs/base/databases/mariadb/networkpolicy.yaml`

## Monitoring

### ServiceMonitor

**Metrics Endpoint**: Port 9187 (mariadb-operator exposes Prometheus metrics)

**Key Metrics**:
- `mariadb_up` - MariaDB instance availability
- `mariadb_wsrep_cluster_size` - Galera cluster size (should be 2)
- `mariadb_wsrep_cluster_status` - Cluster status (Primary)
- `mariadb_wsrep_ready` - Node readiness
- `mariadb_global_status_*` - Standard MariaDB metrics

### Alerts

**Configured Alerts** (not yet deployed):
- MariaDB instance down
- Galera cluster size < 2 (node failure)
- Galera cluster not Primary (split-brain)
- Replication lag > 10s
- Too many connections (> 80%)
- High query rate or slow queries

**Future**: Deploy PrometheusRule for MariaDB alerts

## Disaster Recovery

### Restore from Backup

1. **Restore secrets** (if fresh cluster):
   ```bash
   cd .backup
   ./secrets-restore.sh
   ```

2. **Wait for MariaDB cluster to be ready**:
   ```bash
   kubectl get mariadb -n databases main-mariadb
   # Wait for STATUS: Ready
   ```

3. **Restore databases from backup**:
   ```bash
   # Find latest backup
   BACKUP=$(ls -t /mnt/k8s-storage/backups/mariadb/mariadb_*.tar.gz | head -1)

   # Verify checksum
   sha256sum -c ${BACKUP}.sha256

   # Extract backup
   tar -xzf ${BACKUP} -C /tmp

   # Restore each database
   for DB in discountbandit homeassistant uptimekuma; do
     kubectl exec -n databases main-mariadb-0 -- mariadb \
       -u root -p$(kubectl get secret -n databases mariadb-root -o jsonpath='{.data.password}' | base64 -d) \
       ${DB} < /tmp/$(basename ${BACKUP} .tar.gz)/${DB}.sql
   done
   ```

4. **Restart applications**:
   ```bash
   kubectl rollout restart deployment -n home-assistant
   kubectl rollout restart deployment -n discount-bandit
   kubectl rollout restart deployment -n uptime-kuma
   ```

### Common Issues

#### Issue: "Access denied for user"

**Solution**: Verify credentials secret exists and matches username
```bash
kubectl get secret -n databases <app>-mariadb-credentials -o jsonpath='{.data.password}' | base64 -d
```

#### Issue: "Unknown database"

**Solution**: Database CRD not yet created by operator
```bash
kubectl get database -n databases
# Wait for database to be created
```

#### Issue: "Can't connect to MySQL server"

**Solution**: Check MariaDB cluster status
```bash
kubectl get mariadb -n databases main-mariadb
kubectl get pods -n databases -l app.kubernetes.io/name=mariadb
```

## Future Enhancements

### Potential Future Migrations

Applications still using SQLite that could migrate to MariaDB:
- **None** - All SQLite apps have been migrated to either MariaDB or PostgreSQL

### Monitoring Improvements

- [ ] Deploy PrometheusRule for MariaDB-specific alerts
- [ ] Add Grafana dashboard for MariaDB Galera metrics
- [ ] Configure backup job failure alerts

### Performance Tuning

Current configuration uses MariaDB operator defaults. Future tuning opportunities:
- InnoDB buffer pool size (based on actual workload)
- Max connections (currently defaults)
- Query cache configuration
- Replication performance settings

## References

- **MariaDB Operator Docs**: https://github.com/mariadb-operator/mariadb-operator
- **Galera Cluster Docs**: https://galeracluster.com/library/documentation/
- **PostgreSQL Comparison**: `infrastructure/configs/staging/databases/postgres/` (same architectural pattern)
- **Backup Strategy**: `docs/BACKUP_STRATEGY.md`
- **Secrets Management**: `.backup/README.md`
