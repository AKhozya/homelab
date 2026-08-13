# Databases Codemap

All in `databases` namespace except the ps-operator (MySQL) in `percona-mysql` ns and obsidian's client-side CouchDB creds. Operators: `infrastructure/controllers/databases/<engine>/`; cluster CRs + config: `infrastructure/configs/databases/<engine>/`. Versions: pinned there.

**HR resilience**: all 4 DB HelmReleases (cnpg-operator, ps-operator, redis-operator, couchdb) set `driftDetection: enabled` + `rollback.cleanupOnFail: true`.

Backup CronJobs (schedules, auto-discovery, mechanics): [backup-restore.md](backup-restore.md).

## PostgreSQL — CloudNativePG (CNPG)
- **Operator**: `cnpg-operator` (2 replicas, hard anti-affinity, `databases` ns; chart in `controllers/databases/postgres/release.yaml`)
- **Operator placement**: soft nodeAffinity `NotIn worker-node-2` (weight 100) + CP toleration → pair lands CP+W1. Toleration is load-bearing: without it, replicaCount 2 + hard anti-affinity forces one replica onto W2 (preference = dead config). Why: an operator leader on a flaky node once probed the healthy W1 primary across that node's broken VXLAN → spurious failover into the broken node.
- **Cluster**: `main-postgres` (`configs/databases/postgres/cluster.yaml` — 1 primary + 1 replica on workers, no CP scheduling, hard pod anti-affinity). `failoverDelay: 30` (default 0 = instant) — rides out 1-10s probe blips at the cost of +30s RTO on genuine primary death.
- **Pods**: `main-postgres-{N}` (sequential numbering climbs across upgrades)
- **Pooler**: PgBouncer Deployment `main-postgres-rw-pooler` (2 replicas; `configs/databases/postgres/pooler.yaml` — separate CR from the Cluster)
- **Backup**: daily logical pg_dump ONLY (auto-discovers via `pg_database`) — **no WAL archiving/PITR by decision**; streaming replication = HA, not backup
- **Managed roles** (`cluster.yaml` `spec.managed.roles`): `postgres-admin` (superuser — backup + extension jobs) + per-app login roles `n8n`, `mealie`, `authentik`, `paperless`, `immich`, `linkwarden`, `blocky`
- **Extension updates** (immich DB): `immich-init-extensions` Job on every CNPG image bump + `postgres-update-extensions` CronJob daily 06:00 UTC, both running one shared `update-extensions.sh` from the `postgres-extension-update` ConfigMap (`configMapGenerator`, so a script edit re-hashes the name and Flux re-creates the forced Job). Immich cannot raise pgvector itself — it connects as `immich`, which does not own the extension, and PG 18 has no `ALTER EXTENSION … OWNER TO`. The Job waits for the primary to report its own image's `server_version` first, or it reads the outgoing primary's catalogue (see HOMELAB_HISTORY 2026-08-13)
- **Reload trigger**: Secret label `cnpg.io/reload: "true"` for password updates (NOT role creation)

## MySQL — Percona Server for MySQL
- **Operator**: `ps-operator` in `percona-mysql` ns, watches all ns (`controllers/databases/mysql/helmrelease.yaml`)
- **Cluster CR**: `ps.percona.com/v1` `PerconaServerMySQL/main-mysql` (`configs/databases/mysql/cluster.yaml` — clusterType `async`, autoRecovery on)
- **Pods**: `main-mysql-mysql-{0,1}` (anti-affinity), `main-mysql-haproxy-{0,1}`, `main-mysql-orc-{0,1,2}` (spread CP+W1+W2 with CP toleration — async failover quorum)
- **Apps**: `uptimekuma`, `homeassistant`, `pricebuddy`
- **Root pwd**: `mysql-cluster-secrets/root` Secret (NOT `main-mysql-secrets`)
- **Update strategy**: SmartUpdate (replicas first, primary last) — requires orchestrator
- **Gotcha**: `skip-replica-start` in `[mysqld]` config — operator bug workaround (primary retains stale replica config from PVC, breaks HAProxy health check otherwise)

## Redis HA — OT-CONTAINER-KIT operator
- **Operator**: `redis-operator` (`controllers/databases/redis-operator/release.yaml`); CRs in `configs/databases/redis-ha/`
- **RedisReplication**: 2 pods (master + replica, anti-affinity'd W1+W2); **RedisSentinel**: 3 (CP+W1+W2 with CP toleration, quorum 2/3)
- **Pod labels**: `app=redis-replication` and `app=redis-sentinel-sentinel` (NOT `app=redis-sentinel`)
- **Storage**: PVC per replication pod holds RDB snapshots — NOT backed up (cache + transient queues)
- **ACL**: SOPS Secret `redis-acl-secret` mounted at `/etc/redis/user.acl`; users `default` (on nopass for liveness), `admin`, `paperless`, `immich`, `blocky`
- **Required config**: `protected-mode no` (nopass + cross-ns access), `readOnlyRootFilesystem: false` (entrypoint writes /etc/redis/redis.conf)
- **Client mode**: static master Service only — paperless, blocky, immich connect to `redis-replication-master` (selector `redis-role=master`); operator repoints it on failover. immich uses `REDIS_URL=ioredis://<base64-json>` with a plain `{host:redis-replication-master…}` body. No Sentinel client discovery — ioredis Sentinel passive detection hung on a half-open dead-master socket after reboot (see HOMELAB_HISTORY 2026-06-28).
- **Failover behavior**: Sentinel elects in ~15s; operator restores original topology on master pod recovery → Sentinel may hold a stale view ~5min until manual reset
- **Schema gotchas**: v1beta2 has no `spec.kubernetesConfig.serviceType`; sentinel password uses `secretKeyRef` (EnvVarSource), not flat fields

## CouchDB
- **Chart**: `couchdb` → STS `couchdb-couchdb`, pods `couchdb-couchdb-{0,1}` (`configs/databases/couchdb/release.yaml`)
- **Auth**: Basic (admin from `couchdb-credentials` Secret); obsidian uses a separate read-only `obsidian/couchdb-credentials`
- **Backup**: daily HTTP dump (auto-discovers via `_all_dbs`)

## Resources / quotas
Requests/limits live in each CR/HelmRelease; `databases` ns ResourceQuota in `configs/databases/`. ⚠️ **Tier quotas may block rolling updates** (rollouts need ~2x transiently) — temp-bump the quota if a rollout stalls on `exceeded quota`.

## Scheduling tier
All data-plane DB pods + all 4 operators run `priorityClassName: homelab-critical`. Field paths differ per engine:
- **CNPG**: `Cluster.spec.priorityClassName` (instances) + `Pooler.spec.template.spec.priorityClassName` (separate CR — edit both) + operator HR `values.priorityClassName`
- **Percona**: per-component on the CR — `spec.mysql.priorityClassName`, `spec.orchestrator.priorityClassName`, `spec.proxy.haproxy.priorityClassName` (no top-level field); ps-operator HR needs a `postRenderers` JSON6902 patch (chart omits the template hook)
- **CouchDB**: chart `values.priorityClassName`
- **Redis**: `RedisReplication.spec.priorityClassName` + `RedisSentinel.spec.priorityClassName` + operator HR `values.priorityClassName`

mysql-exporter is `homelab-standard` — not data plane, preempts safely.

**Restart triggers** (priorityClassName change isn't a rolling-update trigger on every operator):
- CNPG: `kubectl cnpg restart <cluster>` (replicas) + `kubectl cnpg promote <cluster> <pod>` (primary)
- Percona: auto-rolls on operator reconcile (SmartUpdate)
- CouchDB / Redis CRs: operator rolling-update on apply
- Pooler: `deploymentStrategy: RollingUpdate` auto-handles

**DB primary node-pinning** (best-effort, manual): target = W1 (more performant); use the `db-primary-pin` skill (`kubectl cnpg promote` / orchestrator graceful takeover). Redis master is NOT pinnable — operator repairs topology itself.
