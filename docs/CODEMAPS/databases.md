# Databases Codemap

All in `databases` namespace except CouchDB extras in `obsidian` (client side) and the `ps-operator` MySQL operator in `percona-mysql` ns.

## PostgreSQL — CloudNativePG (CNPG)
- **Operator**: helm `cloudnative-pg` 0.28.2 → controller `cnpg-operator-cloudnative-pg` image `ghcr.io/cloudnative-pg/cloudnative-pg:1.29.1` (2 replicas, anti-affinity, in `databases` ns)
- **Cluster**: `main-postgres` (1 primary + 1 replica on workers, no CP scheduling, hard pod anti-affinity)
- **Pods**: `main-postgres-{N}` (sequential numbering, current 11+12 after upgrades)
- **Storage**: 10Gi PVC per instance (`local-path`)
- **Connection pooler**: PgBouncer Deployment `main-postgres-rw-pooler` (2 replicas, image `ghcr.io/cloudnative-pg/pgbouncer:1.25.1`)
- **Backup**: WAL streaming + daily logical pg_dump CronJob (auto-discovers DBs via `pg_database`)
- **Versioning**: pinned `ghcr.io/cloudnative-pg/postgresql:18.4-standard-trixie`
- **Managed roles** (in `cluster.yaml` `spec.managed.roles`, 8 total):
  - `postgres-admin` (superuser, used by backup + extension jobs)
  - `n8n`, `mealie`, `authentik`, `paperless`, `immich`, `linkwarden`, `blocky` (login + createdb)
- **Reload trigger**: Secret label `cnpg.io/reload: "true"` for password updates (NOT role creation)

## MySQL — Percona Server for MySQL
- **Operator**: helm `ps-operator` 1.1.x in `percona-mysql` ns, watches all ns. Image `percona/percona-server-mysql-operator:1.1.0`
- **Cluster CR**: `ps.percona.com/v1` `PerconaServerMySQL/main-mysql` (clusterType `async`, autoRecovery on)
- **MySQL pods**: `main-mysql-mysql-{0,1}` (size 2, anti-affinity, 20Gi PVC each). Image `percona/percona-server:8.4.8-8.1`
- **HAProxy pods**: `main-mysql-haproxy-{0,1}` (size 2, anti-affinity). Image `percona/haproxy:2.8.18`
- **Orchestrator pods**: `main-mysql-orc-{0,1,2}` (size 3, spread across CP+W1+W2 with CP toleration, async failover quorum). Image `percona/percona-orchestrator:3.2.6-19`
- **Toolkit sidecar**: `percona/percona-toolkit:3.7.1` in MySQL pods
- **Apps**: `uptimekuma`, `homeassistant`, `pricebuddy` (auto-discovered backup)
- **Versioning**: regex `^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(-(?<build>\d+)\.(?<revision>\d+))?$`
- **Root pwd**: `mysql-cluster-secrets/root` Secret (NOT `main-mysql-secrets`)
- **Update strategy**: SmartUpdate (replicas first, primary last) — requires orchestrator
- **Gotcha**: `skip-replica-start` in `[mysqld]` config — operator bug workaround (primary retains stale replica config from PVC, breaks HAProxy health check otherwise)

## Redis HA — OT-CONTAINER-KIT operator
- **Operator**: helm `redis-operator` 0.24.0, image `quay.io/opstreelabs/redis-operator:v0.24.0`
- **RedisReplication CR**: 2 pods (master + replica, anti-affinity'd W1+W2) — image `quay.io/opstree/redis:v8.6.2`
- **RedisSentinel CR**: 3 sentinels (CP+W1+W2, with CP toleration, quorum 2/3) — image `quay.io/opstree/redis-sentinel:v8.6.2`
- **Exporter**: `quay.io/opstree/redis-exporter:v1.83.0` per replication pod
- **Pod label**: `app=redis-replication` and `app=redis-sentinel-sentinel` (NOT `app=redis-sentinel`)
- **Storage**: 5Gi PVC per replication pod (RDB snapshots, NOT backed up — cache + transient queues)
- **ACL**: SOPS Secret `redis-acl-secret` mounted at `/etc/redis/user.acl`
  - Users: `default` (on nopass for liveness), `admin`, `paperless`, `immich`, `blocky`
- **Required config**: `protected-mode no` (nopass + cross-ns access), `readOnlyRootFilesystem: false` (entrypoint writes /etc/redis/redis.conf)
- **Client modes**:
  - **Static master Service**: paperless, blocky → always correct (operator-controlled)
  - **Sentinel discovery via REDIS_URL**: immich (`REDIS_URL=ioredis://<base64-json>`)
- **Failover behavior**: Sentinel elects in ~15s; OT operator restores original topology on master pod recovery → Sentinel may have stale view ~5min until manual reset (documented gotcha)
- **Schema notes**: v1beta2 has no `spec.kubernetesConfig.serviceType`; sentinel password uses `secretKeyRef` (EnvVarSource) not flat fields

## CouchDB
- **Chart**: helm `couchdb` 4.6.x → STS `couchdb-couchdb` (clusterSize 2, image `couchdb:3.5.1`)
- **Pods**: `couchdb-couchdb-{0,1}` in `databases` ns
- **Auth**: Basic (admin from `couchdb-credentials` Secret)
- **Backup**: daily HTTP-based dump CronJob (auto-discovers via `_all_dbs`)
- **Client (obsidian)**: separate `obsidian/couchdb-credentials` Secret with read-only user

## Backup CronJobs
| Job | Namespace | Schedule | Auto-discovers? |
|-----|-----------|----------|-----------------|
| `postgres-backup` | databases | 03:00 daily | YES (`pg_database` excluding system) |
| `couchdb-backup` | databases | 03:05 daily | YES (`_all_dbs`) |
| `pvc-backup` | kube-system | 03:10 daily | NO — explicit list in CRITICAL_PVCS |
| `mysql-backup` | databases | 03:15 daily | YES (`SHOW DATABASES` excluding system) |
| `immich-backup` | kube-system | Sun 03:00 weekly | NO — single PVC (62GB photos), 2-pass tar+sha256, keep-2 retention |
| `backup-replication` | databases | 03:30 daily | NO — rsync flat /mnt/k8s-storage/backups/ |
| `postgres-update-extensions` | databases | 06:00 weekly Sun | runs `ALTER EXTENSION ... UPDATE` |
| `popeye` | monitoring | 06:00 weekly Sun | cluster scan |

## Database resource sizing
- **databases ns quota**: 20 CPU lim, 20Gi mem lim, 50 services (bumped Phase 1 for OT operator's 6+3 svc per CR)
- **PG**: 250m/512Mi req, 1000m/2Gi lim per instance
- **MySQL (mysqld)**: 100m/768Mi req, 1000m/1536Mi lim per node (innodb buffer pool 256M)
- **MySQL (HAProxy)**: 50m/64Mi req, 500m/128Mi lim per pod
- **MySQL (orchestrator)**: 50m/64Mi req, 500m/192Mi lim per pod (bumped 2026-01-11 throttling + 2025-12-30 OOM)
- **Redis replication**: 50m/128Mi req, 400m/512Mi lim per pod
- **Redis sentinel**: 10m/32Mi req, 200m/64Mi lim per pod
- **CNPG operator**: 100m/128Mi req, 500m/512Mi lim
- **ps-operator**: 50m/128Mi req, 200m/256Mi lim
- **redis-operator**: 50m/128Mi req, 200m/256Mi lim
- ⚠️ **Tier quotas may block rolling updates** (need 2x during rollout). Temp increase quota if a rolling update stalls on `exceeded quota`.
