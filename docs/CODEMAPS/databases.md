# Databases Codemap

All in `databases` namespace except CouchDB extras in `obsidian` (client side).

## PostgreSQL — CloudNativePG (CNPG)
- **Cluster**: `main-postgres` (1 primary + 1 replica on workers, no CP scheduling)
- **Pods**: `main-postgres-{N}` (sequential numbering, current 11+12 after upgrades)
- **Storage**: 10Gi PVC per instance
- **Connection pooler**: PgBouncer Deployment `main-postgres-rw-pooler` (2 replicas)
- **Backup**: WAL streaming + daily logical pg_dump CronJob (auto-discovers DBs via `\l`)
- **Versioning**: pinned `18.3-standard-trixie` (helpers float `18-*-trixie`)
- **Managed roles** (in `cluster.yaml` `spec.managed.roles`):
  - `postgres-admin` (superuser)
  - `n8n`, `mealie`, `authentik`, `paperless`, `immich`, `linkwarden`, `blocky`
- **Reload trigger**: Secret label `cnpg.io/reload: "true"` for password updates (NOT role creation)

## MySQL — Percona XtraDB Cluster
- **Cluster**: `main-mysql` (3 nodes via PXC operator)
- **Pods**: `main-mysql-mysql-{0,1,2}`
- **HAProxy**: 2 HAProxy pods front the cluster
- **Apps**: `uptimekuma`, `homeassistant`, `pricebuddy` (auto-discovered backup)
- **Versioning**: regex `^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(-(?<build>\d+)\.(?<revision>\d+))?$`
- **Root pwd**: `mysql-cluster-secrets/root` Secret (NOT `main-mysql-secrets`)

## Redis HA — OT-CONTAINER-KIT operator v0.24.0
- **RedisReplication CR**: 1 master + 1 replica (anti-affinity'd W1+W2)
- **RedisSentinel CR**: 3 sentinels (CP+W1+W2, with CP toleration), quorum 2/3
- **Image**: `quay.io/opstree/redis:v8.6.2`
- **Pod label**: `app=redis-replication` and `app=redis-sentinel-sentinel` (NOT `app=redis-sentinel`)
- **Storage**: 5Gi PVC per replication pod (RDB snapshots, NOT backed up — cache + transient queues)
- **ACL**: SOPS Secret `redis-acl-secret` mounted at `/etc/redis/user.acl`
  - Users: default (on nopass for liveness), admin, paperless, immich, blocky
- **Required config**: `protected-mode no` (nopass + cross-ns access), `readOnlyRootFilesystem: false` (entrypoint writes /etc/redis/redis.conf)
- **Client modes**:
  - **Static master Service**: paperless, blocky → always correct (operator-controlled)
  - **Sentinel discovery via REDIS_URL**: immich (`REDIS_URL=ioredis://<base64-json>`)
- **Failover behavior**: Sentinel elects in ~15s; OT operator restores original topology on master pod recovery → Sentinel may have stale view ~5min until manual reset (documented gotcha)
- **Plan-vs-actual schema drift fixed**: v1beta2 has no `spec.kubernetesConfig.serviceType`; sentinel password uses `secretKeyRef` (EnvVarSource) not flat fields

## CouchDB
- **STS**: `couchdb-couchdb-0` in `databases` ns
- **Auth**: Basic (admin from `couchdb-credentials` Secret)
- **Backup**: daily HTTP-based dump CronJob (auto-discovers via `_all_dbs`)
- **Client (obsidian)**: separate `obsidian/couchdb-credentials` Secret with read-only user

## Backup CronJobs
| Job | Schedule | Auto-discovers? |
|-----|----------|-----------------|
| `postgres-backup` | 03:00 daily | YES (`\l` excluding system) |
| `mysql-backup` | 03:15 daily | YES (`SHOW DATABASES` excluding system) |
| `couchdb-backup` | 03:05 daily | YES (`_all_dbs`) |
| `pvc-backup` | 03:10 daily | NO — explicit list in CRITICAL_PVCS |
| `backup-replication` | 03:30 daily | NO — rsync flat /mnt/k8s-storage/backups/ |
| `postgres-update-extensions` | 06:00 weekly Sun | runs ALTER EXTENSION ... UPDATE |
| `popeye` | 06:00 weekly Sun | cluster scan |

## Database resource sizing
- **databases ns quota**: 20 CPU lim, 20Gi mem lim, 50 services (bumped Phase 1 for OT operator's 6+3 svc per CR)
- **PG**: 250m/512Mi req, 1000m/2Gi lim per instance
- **MySQL**: 2Gi req / 4Gi lim per node
- **Redis HA**: 128Mi req / 512Mi lim per pod (8 pods total = ~4Gi)
- ⚠️ **Tier quotas may block rolling updates** (need 2x during rollout). Temp increase quota if a rolling update stalls on `exceeded quota`.
