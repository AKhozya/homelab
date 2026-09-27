---
name: db-operations
description: Use for safe homelab database operations on PostgreSQL (CNPG), MySQL (Percona), CouchDB, Redis. Connection patterns via PgBouncer/HAProxy, kubectl exec admin queries via primary pods, replication checks, backups.
user-invocable: false
---

# Database Operations Skill

## Connection Patterns

### PostgreSQL

**In-cluster app DSN (PgBouncer pooler — apps connect here)**:
```
postgresql://<user>:<password>@main-postgres-rw-pooler.databases.svc.cluster.local:5432/<database>
```
The pooler is PgBouncer — no `psql` binary inside the pod, do not exec into it.

**Admin queries via helper (primary auto-discovered)**:
CNPG renumbers pods — never hardcode `main-postgres-1`. Use the script:
```bash
bash ~/.agents/skills/db-operations/scripts/pg-primary.sh                       # print primary pod
bash ~/.agents/skills/db-operations/scripts/pg-primary.sh exec <db> -c "QUERY"  # one-shot
bash ~/.agents/skills/db-operations/scripts/pg-primary.sh shell <db>            # interactive psql

# Override cluster/ns: PG_CLUSTER=... PG_NS=... bash .../pg-primary.sh ...
```

### MySQL

**In-cluster app DSN (HAProxy — auto-routes to primary, survives failover)**:
```
mysql://<user>:<password>@main-mysql-haproxy.databases.svc.cluster.local:3306/<database>
```

**Admin queries via helper (password + HAProxy auto-wired)**:
PerconaServerMySQL `.status` does NOT expose primary; HAProxy routes regardless. Use the script:
```bash
bash ~/.agents/skills/db-operations/scripts/mysql-exec.sh <db> "SELECT NOW()"
bash ~/.agents/skills/db-operations/scripts/mysql-exec.sh --shell <db>
bash ~/.agents/skills/db-operations/scripts/mysql-exec.sh <db> "SHOW REPLICA STATUS\\G"
```

### CouchDB (multi-master cluster, ns: `databases`)
All cluster nodes accept writes — no primary. Pods: `couchdb-couchdb-{0,1}`. Use `sts/couchdb-couchdb` (kubectl picks first pod). NOTE: ns is `databases`, NOT `couchdb` (verified live 2026-05-16).
```bash
# Scripted (resolves admin creds from secret, never echoes them):
bash ~/.agents/skills/db-operations/scripts/couchdb-exec.sh /_up
bash ~/.agents/skills/db-operations/scripts/couchdb-exec.sh /_membership
bash ~/.agents/skills/db-operations/scripts/couchdb-exec.sh -X POST /<db>/_compact -H 'Content-Type: application/json'
```
The script wraps `kubectl exec` + `curl` against `localhost:5984`; for cluster-aware calls target
the headless Service instead (`http://couchdb-couchdb.databases.svc.cluster.local:5984` — DNS
returns all pod IPs). Don't hand-inline `-u <user>:<password>` — the script resolves creds without
echoing them.
```bash
# Local port-forward fallback (creds from secret `couchdb-couchdb`, ns `databases`)
ADMIN=$(kubectl get secret -n databases couchdb-couchdb -o jsonpath='{.data.adminUsername}' | base64 -d)
PW=$(kubectl get secret -n databases couchdb-couchdb -o jsonpath='{.data.adminPassword}' | base64 -d)
kubectl port-forward -n databases svc/couchdb-couchdb 5984:5984 &
curl -s -u "$ADMIN:$PW" http://localhost:5984/<database>/_all_docs
```

### Redis (Sentinel + OT operator, ns: `databases`)
Pods: `redis-replication-0/1` (data), `redis-sentinel-sentinel-0/1/2` (sentinels). Master moves on failover — never hardcode pod-0 as master. Script discovers via Sentinel quorum:
```bash
bash ~/.agents/skills/db-operations/scripts/redis-master.sh                # print master IP (Sentinel, authoritative)
bash ~/.agents/skills/db-operations/scripts/redis-master.sh --label        # print master pod name (label, faster, may lag failover briefly)
bash ~/.agents/skills/db-operations/scripts/redis-master.sh info           # INFO replication
bash ~/.agents/skills/db-operations/scripts/redis-master.sh exec SET k v   # arbitrary command
bash ~/.agents/skills/db-operations/scripts/redis-master.sh exec GET k

# Reads via replica Service (load-balanced) still raw:
PW=$(kubectl get secret -n databases redis-passwords -o jsonpath='{.data.admin-password}' | base64 -d)
kubectl exec -n databases sts/redis-replication -- \
  redis-cli -h redis-replication-replica -a "$PW" GET key

# Secret topology (verified live 2026-05-16):
#   redis-passwords: per-app keys: admin-password, blocky-password, immich-password, paperless-password
#   redis-acl-secret: ACL for operator-managed Redis

# Operator/Sentinel split-brain caveat: see gotchas.md
```

## Operations — load `reference-ops.md`

For these ops, load `reference-ops.md` (full command sets there) — they aren't needed on a plain connect:

| Operation | `reference-ops.md` § |
|---|---|
| Backup status (cronjobs/jobs/files) + backup schedules | Backup Verification |
| Replication status per engine (CNPG / Percona / CouchDB / Redis Sentinel) | Replication Status |
| Create DB (CNPG Database CRD) / safe restart / scale | Common Operations |

## Safety Rules
1. **Never** DROP TABLE/DATABASE directly - use K8s CRDs
2. **Never** force-delete DB pods (`--force --grace-period=0`)
3. **Always** `kubectl rollout restart` for DB restarts — **from a workstation**. The bot cannot:
   it lost workload `patch` on 2026-08-06, and the delete-pod substitute used elsewhere is NOT
   available here because AGENTS.md forbids force-deleting DB pods. Hand DB restarts to an operator.
4. **Always** verify backups before destructive ops
5. **DB usernames** = app name (authentik, immich, paperless, etc.)

## Credential Access
```bash
# PostgreSQL credentials (SOPS encrypted; flat layout, filename varies per app —
# secret.yaml / *-env-secret.yaml / *-db-password-secret.yaml). Find the file first:
git -C ~/source-code/homelab grep -l 'ENC\[' -- 'apps/<app>/'
sops -d apps/<app>/<secret-file>.yaml

# MySQL root password (from cluster secret)
kubectl get secret -n databases mysql-cluster-secrets -o jsonpath='{.data.root}' | base64 -d

# MySQL app credentials (SOPS encrypted; flat layout)
sops -d apps/<app>/mysql-credentials.yaml   # e.g. apps/pricebuddy, apps/uptime-kuma

# Redis admin password (ops use; per-app keys — see Secret topology above)
kubectl get secret -n databases redis-passwords -o jsonpath='{.data.admin-password}' | base64 -d

# CouchDB credentials (ns is `databases`, NOT `couchdb`)
kubectl get secret -n databases couchdb-couchdb -o jsonpath='{.data.adminPassword}' | base64 -d
```

## See also

- `/db-primary-pin` — switchover DB primary to a specific node (CNPG / Percona / Redis).
- `/cnpg-full-roll` — fully roll CNPG instances when a spec change isn't auto-rolled (e.g. priorityClassName on v1.29.x).
- `~/.agents/skills/_shared/audit-priority-class.sh` — pod priorityClass enumeration + gap finder.

## Tools Allowed
- `Bash(kubectl *)`
- `Bash(ssh *)`
- `Read`
