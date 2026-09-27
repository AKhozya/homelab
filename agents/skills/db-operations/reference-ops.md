# DB Operations — backup / replication / common-ops recipes

Loaded on demand from `db-operations/SKILL.md`. Each section = one operation's full command set. SKILL.md holds connection patterns + safety + credential access; load this when you actually do a backup check, replication check, or create/restart/scale.

## Backup Verification

### Check Status
```bash
# List backup jobs
kubectl get cronjobs -n databases

# Recent backup job status
kubectl get jobs -n databases --sort-by=.metadata.creationTimestamp | tail -5

# Check backup files on worker node
ssh -p 65300 akhozya@worker-node "ls -la /mnt/k8s-storage/backups/"

# Check replication to worker-node-2
ssh -p 65300 z3us@worker-node-2 "ls -la /mnt/extra-storage/backups/"
```

### Schedules
- **PostgreSQL**: 3:00 AM daily, 30-day retention
- **CouchDB**: 3:05 AM daily, 30-day retention
- **MySQL**: 3:15 AM daily, 30-day retention
- **PVC**: 3:10 AM daily, 30-day retention (matches NAS retention policy 2026-05-22)
- **Replication**: 3:30 AM daily, FAN-OUT: NAS (primary sink) + worker-node-2 (safety net; W2 leg removal planned ~2026-07-20 — see cronjob TODO)

## Replication Status

### PostgreSQL (CNPG)
```bash
kubectl get cluster -n databases main-postgres -o jsonpath='{.status.instances}'
kubectl get pods -n databases -l cnpg.io/cluster=main-postgres -o wide
```

### MySQL (Percona)
```bash
kubectl exec -n databases sts/main-mysql-mysql -- \
  mysql -h main-mysql-haproxy -uroot -p"$MYSQL_ROOT_PW" -e "SHOW REPLICA STATUS\G" | grep -E "(Replica_IO|Replica_SQL|Seconds_Behind)"   # MySQL 8 field names — Slave_* matches nothing
```

### CouchDB (StatefulSet, multi-master, ns: `databases`)
```bash
kubectl get pods -n databases -l app=couchdb -o wide
# Cluster membership / replication health
kubectl exec -n databases sts/couchdb-couchdb -- \
  curl -s -u <admin>:<password> http://localhost:5984/_membership
```

### Redis (Sentinel) — use helper
```bash
bash ~/.agents/skills/db-operations/scripts/redis-master.sh info   # INFO replication on current master
```
Or raw via Sentinel API:
```bash
PW=$(kubectl get secret -n databases redis-passwords -o jsonpath='{.data.admin-password}' | base64 -d)
kubectl exec -n databases sts/redis-sentinel-sentinel -- \
  redis-cli -p 26379 SENTINEL master myMaster | head -20
```
NOTE: `| head -1` under `set -o pipefail` SIGPIPE-kills upstream — use `| awk 'NR==1'` if scripting.

## Common Operations

### Create New Database (PostgreSQL)
```yaml
# Use CNPG Database CRD
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: newdb
  namespace: databases
spec:
  cluster:
    name: main-postgres
  name: newdb
  owner: newuser
```

### Restart Database Pod (Safe)
```bash
# WORKSTATION ONLY — the bot has no workload patch since 2026-08-06, and delete-pod is not a
# substitute for databases (AGENTS.md: no force-delete of DB pods).
kubectl rollout restart statefulset/<name> -n databases
```

### Scale Database
```bash
# PostgreSQL
kubectl patch cluster main-postgres -n databases --type merge -p '{"spec":{"instances":3}}'

# MySQL
kubectl patch ps main-mysql -n databases --type merge -p '{"spec":{"mysql":{"size":3}}}'
```
