# DB Operations — backup / replication / common-ops recipes

Loaded on demand from `db-operations/SKILL.md`. Each section = one operation's full command set. SKILL.md holds connection patterns + safety + credential access; load this when you actually do a backup check, replication check, or create/restart/scale.

## Backup Verification

### Check Status
```bash
# List backup jobs
kubectl get cronjobs -n databases

# Recent backup job status
kubectl get jobs -n databases --sort-by=.metadata.creationTimestamp | tail -5

# Check backup files on worker node (if the NAS copy verifies, Step 4 of backup-replication deletes them)
ssh -p 65300 akhozya@worker-node "ls -la /mnt/k8s-storage/backups/"
```

### Schedules
| Job | Time (daily) | Notes |
|---|---|---|
| PostgreSQL | 3:00 AM | 30-day retention |
| CouchDB | 3:05 AM | 30-day retention |
| PVC | 3:10 AM | 30-day retention (matches NAS retention policy 2026-05-22) |
| MySQL | 3:15 AM | 30-day retention |
| Replication | 3:30 AM | worker-node → NAS only (`infrastructure/configs/backup-replication/cronjob.yaml`) |

## Replication Status

### PostgreSQL (CNPG)
```bash
kubectl get cluster -n databases main-postgres -o jsonpath='{.status.instances}'
kubectl get pods -n databases -l cnpg.io/cluster=main-postgres -o wide
```

### MySQL (Percona)
Ask each mysql pod on `127.0.0.1`, not HAProxy. HAProxy routes to the primary, and the primary
returns an empty set for `SHOW REPLICA STATUS`, which looks healthy. The replica returns the rows.
The pod reads the root password from its own mounted users secret, so it appears in no argv,
neither kubectl's on this host nor mysql's in the pod. MySQL 8.4 deprecates `MYSQL_PWD` but still honours it.
```bash
rc=0
pods=$(kubectl get pods -n databases -l app.kubernetes.io/instance=main-mysql,app.kubernetes.io/name=mysql -o name) || pods=""
[ -n "$pods" ] || { echo "ERROR: no mysql pods listed — replication NOT checked"; rc=1; }
while IFS= read -r p; do
  [ -n "$p" ] || continue
  # shellcheck disable=SC2016 # expands inside the pod
  if ! out=$(kubectl exec -n databases "$p" -c mysql -- bash -c \
    'MYSQL_PWD=$(</etc/mysql/mysql-users-secret/root); export MYSQL_PWD; exec mysql -h 127.0.0.1 -uroot -e "SHOW REPLICA STATUS\G"'); then
    echo "== $p: query FAILED"
    rc=1
  elif [ -z "$out" ]; then
    echo "== $p: no replica status (the primary)"
  else
    echo "== $p (replica)"
    printf '%s\n' "$out" | grep -E "(Replica_IO|Replica_SQL|Seconds_Behind)"   # MySQL 8 field names — Slave_* matches nothing
  fi
done <<<"$pods"   # not `for p in $pods`: zsh does not word-split an unquoted variable
[ "$rc" = 0 ]   # the snippet's status: non-zero if discovery or any query failed
```
| Output | Meaning |
|---|---|
| one "(the primary)" line and one "(replica)" block with both threads `Yes` | healthy |
| two "(the primary)" lines | no replication: neither pod replicates |
| two "(replica)" blocks | no primary: each pod replicates from the other (2026-09-12 incident) |
| "query FAILED" or the ERROR line | replication NOT checked |

### CouchDB (StatefulSet, multi-master, ns: `databases`)
```bash
kubectl get pods -n databases -l app=couchdb -o wide
# Cluster membership / replication health
bash ~/.agents/skills/db-operations/scripts/couchdb-exec.sh /_membership   # creds on stdin, not argv
```

### Redis (Sentinel) — use helper
```bash
bash ~/.agents/skills/db-operations/scripts/redis-master.sh info   # INFO replication on current master
```
Or raw via Sentinel API:
```bash
kubectl exec -n databases sts/redis-sentinel-sentinel -- \
  redis-cli -p 26379 SENTINEL master myMaster | head -20   # sentinel port: no password
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
WORKSTATION ONLY. The bot has no workload `patch` since 2026-08-06.
Never force-delete a DB pod (`--force`, `--grace-period=0`; AGENTS.md). A graceful delete is the
Redis method only, as the table says.

| Engine | Restart method |
|---|---|
| PostgreSQL (CNPG) | CNPG owns the pods directly, so there is no StatefulSet to restart. Use `bash ~/.agents/skills/cnpg-full-roll/scripts/roll.sh databases main-postgres` |
| Redis (opstree operator) | NEVER `rollout restart` its StatefulSets: the `restartedAt` template annotation restarts the operator's non-convergent reconcile loop (2026-07-17 incident, upstream OT-CONTAINER-KIT/redis-operator#1840). Restart by graceful `kubectl delete pod -n databases <pod>`, one pod at a time, the replica before the current master (`redis-master.sh --label` names it). Before the next pod, wait until the new pod is Ready and `redis-master.sh info` shows `connected_slaves:1` with `slave0:…,state=online` (a replica still syncing reports another state and is no failover target). Never `--force` |
| MySQL (Percona) | Restart it through its CR in Git; see MySQL restart below. `cluster-roll` keeps Percona in SKIP |
| CouchDB (Helm, 2 replicas) | `kubectl rollout restart statefulset/couchdb-couchdb -n databases`, then confirm `/_membership` lists both nodes before anything else touches it |

#### MySQL restart

Restart MySQL through its CR in Git, never on the pods.

| Source | Fact |
|---|---|
| operator v1.2.0, `pkg/mysql/mysql.go` | the operator merges `spec.mysql.annotations` into the MySQL pod template, so a new value gives the StatefulSet a new revision |
| operator v1.2.0, `pkg/controller/ps/upgrade.go` (`stsChanged`, `smartUpdate`) | if any pod's `controller-revision-hash` differs from the StatefulSet's update revision, the operator deletes the secondary pods one at a time, switches the primary over, then deletes the old primary |
| same file | if a backup runs or any MySQL pod is not ready, the operator waits. It retries on the next reconcile |
| v1.2.0 docs "About upgrades"; release note K8SPS-683 | the primary restarts last, after an explicit switchover |

1. Record both pods' UIDs:
   `kubectl -n databases get pods -l 'app.kubernetes.io/instance=main-mysql,app.kubernetes.io/name=mysql' -o 'custom-columns=NAME:.metadata.name,UID:.metadata.uid,READY:.status.containerStatuses[*].ready' --no-headers`
2. Outside the nightly MySQL backup (03:15 UTC), in `infrastructure/configs/databases/mysql/cluster.yaml`, set
   `spec.mysql.annotations.homelab/restarted-at` to the current UTC time, and deploy it with
   `/gitops-workflow`.
3. Run the step 1 command until both pods show new UIDs and `true,true`. The cluster reads `ready`
   and writable before the restart too, so only the new UIDs prove it happened.
4. Then check `kubectl -n databases get ps main-mysql -o jsonpath='{.status.state}'` prints
   `ready`, and `mysql-exec.sh mysql "SELECT @@read_only"` prints `0` through HAProxy.

### Scale Database
Edit the CR in Git and deploy it with `/gitops-workflow`. A live patch on these CRs is a
GitOps violation, and Flux reverts it on the next reconcile.

| Engine | File | Field |
|---|---|---|
| PostgreSQL | `infrastructure/configs/databases/postgres/cluster.yaml` | `spec.instances` |
| MySQL | `infrastructure/configs/databases/mysql/cluster.yaml` | `spec.mysql.size` |
