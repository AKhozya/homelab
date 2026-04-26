# Design: Redis HA via OT-CONTAINER-KIT Operator

**Date**: 2026-04-26
**Status**: Approved (awaiting written-spec review)
**Phase**: 1 of 2 (prerequisite for Blocky migration spec `2026-04-26-blocky-migration-design.md`)

## Problem

Existing Redis runs as a single-pod StatefulSet (`redis-0`). It serves Immich (76 client connections — cache + BullMQ workers) and Paperless-ngx (8 connections — cache + Celery broker). Authentik does NOT use Redis (verified — no `AUTHENTIK_REDIS__*` env vars set; default config has `cache.url: ""` empty, runs in-memory cache + file channels).

Single pod = single point of failure. Pod restart, node drain, or PVC issue = total Redis outage. Phase 2 (Blocky migration) introduces another Redis-dependent client, increasing the cost of an outage.

Goal: replace with operator-managed HA Redis (1 master + 1 replica + 3 Sentinels) that survives single-pod or single-node failure with automatic failover.

## Solution Summary

Deploy **OT-CONTAINER-KIT redis-operator** via Flux HelmRelease. Create `RedisReplication` CR (clusterSize: 2 = 1 master + 1 replica) and `RedisSentinel` CR (clusterSize: 3) in the `databases` namespace, alongside the existing single-pod Redis. Cut over Immich and Paperless-ngx to the new endpoints in a single window, then decommission the old StatefulSet. Add `blocky` ACL user as the final commit, unblocking Phase 2.

## Out of Scope

- **Phase 2 (Blocky migration)**: separate spec. Blocky becomes a Redis client only after Phase 1 completes.
- **Authentik reconfiguration**: Authentik does not use Redis. No change needed.
- **Redis 8 upgrade**: stay on Redis 7.x (OT operator's stable image). Future upgrade is separate.
- **Soak window**: explicitly removed at user direction. Single migration window, no multi-day soak (cache + queue workloads tolerate restart).
- **Persistence upgrade (AOF)**: keep RDB-only with `save 60 1` to match current behavior.

## Out of Decision (locked early in brainstorm)

- Operator: **OT-CONTAINER-KIT** (chosen over Spotahome due to fresher releases — OT v0.24.0 March 2026 vs Spotahome v1.2.4 Dec 2022 stable / v1.3.0-rc1 Aug 2024 RC; better multi-user ACL support via `acl.secret.secretName`).
- Topology: 1 master + 1 replica + 3 Sentinels (lightweight quorum without bloating data pod count).
- No Redis Cluster mode (sharding not needed for cache/queue workload).
- No KeyDB/Dragonfly swap (active-replica conflict resolution risks queue message loss).

## Architecture

### Topology

```
                       +------------------------------+
                       | HelmRelease redis-operator   |
                       | (infrastructure/controllers) |
                       | watches:                     |
                       |  - RedisReplication CR       |
                       |  - RedisSentinel CR          |
                       +--------------+---------------+
                                      | deploys + manages
                       +--------------+----------------+
                       |                               |
              +--------v---------+           +--------v---------+
              | RedisReplication |           |  RedisSentinel   |
              |  clusterSize: 2  |           |  clusterSize: 3  |
              |  (1 master +     |<--watches-+  (1 per node     |
              |   1 replica)     |           |   CP+W1+W2)      |
              |  on W1 + W2      |           |                  |
              +------------------+           +------------------+

  Operator-created Services:
    redis-replication-master  (selector role=master, auto-rewritten on failover)
    redis-replication-replica (selector role=slave)
    redis-replication-headless (all data pods, for Sentinel discovery)
    redis-sentinel-sentinel   (port 26379)

  Client routing:
    Immich   -> Sentinel (REDIS_URL=ioredis://<base64-json> -> redis-sentinel-sentinel:26379)
    Paperless-> Static master (redis://...@redis-replication-master:6379)
    Blocky   -> Sentinel (redis.sentinelAddresses native config)
```

### Decisions and Rationale

| Decision | Choice | Rationale |
|---|---|---|
| Operator | OT-CONTAINER-KIT redis-operator (HelmRelease via Flux) | Active maintenance (v0.24.0 March 2026, 976 commits, 28 releases). Multi-user ACL via Secret. Mature CRDs (RedisReplication, RedisSentinel separate). |
| Topology | 1 master + 1 replica + 3 Sentinels | Minimum viable HA with safe quorum (2/3). Sentinels are lightweight (~10-15MB RAM each). 2-replica data tier matches user preference. |
| Sentinel placement | Hard anti-affinity hostname, 1 per node (CP+W1+W2) | Survives any single-node loss. Quorum holds on remaining 2 nodes. |
| Data pod placement | Hard anti-affinity hostname, nodeAffinity W1+W2 | Predictable IPs. CP free of Redis data load. Mirrors existing app pattern. |
| Client connection model | Mixed: Sentinel (Immich, Blocky) + static master Service (Paperless) | Paperless does not support Sentinel (feature request #3088 closed/locked Mar 2025). Operator's `redis-replication-master` Service auto-rewrites endpoints on failover. Immich and Blocky have native Sentinel support. |
| Migration approach | Parallel deploy + client cutover + immediate decommission (no soak) | Cache + queue workloads tolerate brief restart. Apps' retry logic handles in-flight items. ~30s per-app outage. Single window, ~30-60 min total. |
| Persistence | RDB only, `save 60 1` | Matches current. Replication protects against single-pod loss; AOF cost unjustified for cache class. |
| Storage size | 5Gi PVC per data pod (`local-path`) | Current usage is 9MB; max possible (RDB at full `maxmemory: 480MB`) ~600MB. 5Gi has 8x headroom. |
| ACL | Pre-rendered into SOPS Secret with literal passwords (key `user.acl`) | OT operator expects Secret format. Existing `redis-acl` ConfigMap pattern (with env-var substitution) does not work with operator. |
| Service account | Explicit `serviceAccountName` per CR (`redis-replication`, `redis-sentinel`) | Verified field exists in OT v1beta2 CRD spec. Required to satisfy `require-non-default-serviceaccount` Kyverno enforce policy. |
| `/tmp` writable mount | `emptyDir: {sizeLimit: 64Mi}` (disk-backed) | Required for `readOnlyRootFilesystem: true` PSS Restricted compliance. Disk-backed avoids stealing from pod memory limit. |

## Components

### Files created

```
infrastructure/controllers/base/databases/redis-operator/
  release.yaml                    # Flux HelmRelease for ot-helm/redis-operator
  kustomization.yaml

infrastructure/controllers/base/databases/redis-ha/
  serviceaccount.yaml             # redis-replication SA + redis-sentinel SA
  redis-config-cm.yaml            # ConfigMap with --save 60 1, --maxmemory, --maxmemory-policy
  acl-secret.yaml                 # SOPS — user.acl with literal passwords
  redis-replication.yaml          # RedisReplication CR (clusterSize 2)
  redis-sentinel.yaml             # RedisSentinel CR (clusterSize 3)
  networkpolicy.yaml              # NP for new HA pods
  kustomization.yaml

infrastructure/configs/base/databases/redis-ha/
  kustomization.yaml              # mirrors base if any env-specific overrides

monitoring/configs/staging/redis-ha/
  prometheusrule.yaml             # 8 HA-specific alerts
  dashboard-redis-ha.yaml         # ConfigMap with grafana_dashboard label
  kustomization.yaml
```

(Note: `infrastructure/configs/staging/databases/redis-ha/` may be unnecessary if `controllers/base/databases/redis-ha/` is referenced directly via `controllers/staging/databases/kustomization.yaml`. Path layout to be finalized in implementation plan against the existing convention used for `redis/` today.)

If a HelmRepository for `ot-helm` does not already exist in `flux-system`, add `infrastructure/controllers/base/sources/ot-helm-repository.yaml` (or wherever HelmRepositories live).

### Files modified

```
infrastructure/controllers/base/databases/kustomization.yaml         # add redis-ha (new), keep redis (legacy) until decommission
infrastructure/configs/staging/databases/kustomization.yaml          # add redis-ha refs
apps/base/immich/release.yaml                                        # replace REDIS_HOSTNAME/PORT/USERNAME/PASSWORD with REDIS_URL secret ref
apps/base/immich/networkpolicy.yaml                                  # egress label app=redis -> [redis-replication, redis-sentinel]
apps/base/paperless-ngx/networkpolicy.yaml                           # egress label app=redis -> redis-replication
apps/staging/paperless-ngx/paperless-env-secret.yaml                 # PAPERLESS_REDIS URL change
apps/staging/immich/                                                 # new SOPS secret immich-redis-url with ioredis://<base64-json>
infrastructure/configs/base/databases/redis/networkpolicy.yaml       # (optional) tighten or leave during migration window
```

### Files removed (decommission commit, same window)

```
infrastructure/controllers/base/databases/redis/                     # entire dir (StatefulSet, service, sa)
infrastructure/configs/base/databases/redis/                         # entire dir (NP, ACL ConfigMap, secret, ServiceMonitor) — replaced by redis-ha
```

### Manual cleanup (one-time)

```bash
kubectl delete pvc -n databases data-redis-0    # if not GC'd by StatefulSet removal
```

## Configuration

### HelmRelease (operator)

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: redis-operator
  namespace: databases
spec:
  interval: 30m
  chart:
    spec:
      chart: redis-operator
      version: "0.20.x"      # latest stable as of 2026-04-26 - verify exact version at impl
      sourceRef:
        kind: HelmRepository
        name: ot-helm
        namespace: flux-system
  values:
    replicas: 1
    resources:
      requests: {cpu: 50m, memory: 128Mi}
      limits:   {cpu: 200m, memory: 256Mi}
    serviceMonitor:
      enabled: true
```

### RedisReplication CR

```yaml
apiVersion: redis.redis.opstreelabs.in/v1beta2
kind: RedisReplication
metadata:
  name: redis-replication
  namespace: databases
spec:
  clusterSize: 2
  serviceAccountName: redis-replication
  podSecurityContext:
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    runAsNonRoot: true
    seccompProfile: {type: RuntimeDefault}
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    runAsNonRoot: true
    capabilities: {drop: ["ALL"]}
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - {key: kubernetes.io/hostname, operator: In, values: [worker-node, worker-node-2]}
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - topologyKey: kubernetes.io/hostname
          labelSelector: {matchLabels: {app: redis-replication}}
  kubernetesConfig:
    image: quay.io/opstree/redis:v7.4.0    # verify latest stable v7.x at impl
    imagePullPolicy: IfNotPresent
    serviceType: ClusterIP
    resources:
      requests: {cpu: 50m, memory: 128Mi}
      limits:   {cpu: 400m, memory: 512Mi}
  redisConfig:
    additionalRedisConfig: redis-ha-config
  acl:
    secret:
      secretName: redis-acl-secret
  redisExporter:
    enabled: true
    image: quay.io/opstree/redis-exporter:v1.82.0
    imagePullPolicy: IfNotPresent
    resources:
      requests: {cpu: 10m, memory: 32Mi}
      limits:   {cpu: 300m, memory: 64Mi}
    serviceMonitor:
      enabled: true
  storage:
    volumeClaimTemplate:
      spec:
        storageClassName: local-path
        accessModes: ["ReadWriteOnce"]
        resources:
          requests: {storage: 5Gi}
  pdb:
    enabled: true
    minAvailable: 1
```

### RedisSentinel CR

```yaml
apiVersion: redis.redis.opstreelabs.in/v1beta2
kind: RedisSentinel
metadata:
  name: redis-sentinel
  namespace: databases
spec:
  clusterSize: 3
  serviceAccountName: redis-sentinel
  podSecurityContext:
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    runAsNonRoot: true
    seccompProfile: {type: RuntimeDefault}
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    runAsNonRoot: true
    capabilities: {drop: ["ALL"]}
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - topologyKey: kubernetes.io/hostname
          labelSelector: {matchLabels: {app: redis-sentinel}}
  pdb:
    enabled: true
    minAvailable: 2
  redisSentinelConfig:
    redisReplicationName: redis-replication
    quorum: "2"
    parallelSyncs: "1"
    failoverTimeout: "10000"
    downAfterMilliseconds: "5000"
    redisReplicationPassword:
      secretName: redis-passwords
      key: admin-password
  kubernetesConfig:
    image: quay.io/opstree/redis-sentinel:v7.4.0
    imagePullPolicy: IfNotPresent
    resources:
      requests: {cpu: 10m, memory: 32Mi}
      limits:   {cpu: 100m, memory: 64Mi}
    serviceMonitor:
      enabled: true
```

### redis-ha-config ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: redis-ha-config
  namespace: databases
data:
  redis-additional.conf: |
    save 60 1
    maxmemory 480mb
    maxmemory-policy noeviction
    loglevel warning
```

### redis-acl-secret (SOPS-encrypted)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: redis-acl-secret
  namespace: databases
type: Opaque
stringData:
  user.acl: |
    user default off nopass ~* &* +@all
    user admin on >ACTUAL_ADMIN_PASS_LITERAL ~* &* +@all
    user paperless on >ACTUAL_PAPERLESS_PASS_LITERAL ~* &* +@all -@dangerous +keys +flushdb +info
    user immich on >ACTUAL_IMMICH_PASS_LITERAL ~* &* +@all -@dangerous +keys +flushdb +info
    user blocky on >ACTUAL_BLOCKY_PASS_LITERAL ~* &* +@all -@dangerous +keys +info
```

Passwords mirror existing literals from `redis-passwords` SOPS secret (decrypt to read). New `blocky-password` generated as part of Phase 1e. Encrypt with `sops -e -i`.

### NetworkPolicy

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: redis-ha-network-policy
  namespace: databases
spec:
  podSelector:
    matchExpressions:
      - {key: app, operator: In, values: [redis-replication, redis-sentinel]}
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: paperless-ngx}}
        - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: immich}}
        - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: blocky}}
        - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: uptime-kuma}}
        - podSelector: {}
      ports:
        - {protocol: TCP, port: 6379}
    - from:
        - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: immich}}
        - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: blocky}}
        - podSelector: {}
      ports:
        - {protocol: TCP, port: 26379}
    - from:
        - podSelector:
            matchExpressions:
              - {key: app, operator: In, values: [redis-replication, redis-sentinel]}
      ports:
        - {protocol: TCP, port: 6379}
        - {protocol: TCP, port: 26379}
    - from:
        - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: monitoring}}
      ports:
        - {protocol: TCP, port: 9121}
  egress:
    - to:
        - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}
          podSelector: {matchLabels: {k8s-app: kube-dns}}
      ports:
        - {protocol: UDP, port: 53}
        - {protocol: TCP, port: 53}
    - to:
        - podSelector:
            matchExpressions:
              - {key: app, operator: In, values: [redis-replication, redis-sentinel]}
      ports:
        - {protocol: TCP, port: 6379}
        - {protocol: TCP, port: 26379}
```

### Client app updates

**Immich** (`apps/base/immich/release.yaml`):
- Remove env: `REDIS_HOSTNAME`, `REDIS_PORT`, `REDIS_USERNAME`, `REDIS_PASSWORD`
- Add env: `REDIS_URL` from new SOPS secret `immich-redis-url` (key `redis-url`)
- Value format: `ioredis://<base64-encoded-JSON>` where JSON is:
  ```json
  {
    "sentinels": [
      {"host": "redis-sentinel-sentinel.databases.svc.cluster.local", "port": 26379}
    ],
    "name": "myMaster",
    "username": "immich",
    "password": "<immich-redis-password>"
  }
  ```
  Encode: `cat config.json | base64 -w0`. Prefix with `ioredis://`. Encrypt the resulting URL into `immich-redis-url` SOPS secret.

**Paperless-ngx** (`apps/staging/paperless-ngx/paperless-env-secret.yaml`):
- Change `PAPERLESS_REDIS` value from `redis://paperless:PASS@redis.databases.svc.cluster.local:6379` to `redis://paperless:PASS@redis-replication-master.databases.svc.cluster.local:6379` (host change only; password unchanged).

**NetworkPolicy egress label updates**:
- `apps/base/immich/networkpolicy.yaml`: replace `app: redis` with `matchExpressions: [{key: app, operator: In, values: [redis-replication, redis-sentinel]}]` on the relevant egress block, add port 26379.
- `apps/base/paperless-ngx/networkpolicy.yaml`: replace `app: redis` with `app: redis-replication` (port 6379 only).

## Compliance Verification

### Kyverno policies (databases ns NOT excluded from any policy)

| Policy | Mode | Design satisfies | Mechanism |
|---|---|---|---|
| `require-labels` | Enforce | yes | OT operator sets `app: redis-replication` / `app: redis-sentinel` labels |
| `disallow-latest-tag` | Enforce | yes | Pin `quay.io/opstree/redis:v7.4.0`, `quay.io/opstree/redis-sentinel:v7.4.0`, `quay.io/opstree/redis-exporter:v1.82.0`, operator chart version `0.20.x` |
| `disallow-privilege-escalation` | Enforce | yes | `securityContext.allowPrivilegeEscalation: false` |
| `require-drop-all-capabilities` | Enforce | yes | `capabilities.drop: [ALL]` |
| `require-non-default-serviceaccount` | Enforce | yes | Explicit `serviceAccountName: redis-replication` and `redis-sentinel` per CR. Field verified in OT `api/redisreplication/v1beta2/redisreplication_types.go` and `redissentinel_types.go` |
| `require-seccomp-runtimedefault` | Enforce | yes | `seccompProfile.type: RuntimeDefault` at pod level |
| `require-non-root` | Audit | yes | `runAsNonRoot: true`, `runAsUser: 1000` |
| `require-resource-limits` | Audit | yes | requests + limits on data, sentinel, exporter, operator |
| `disallow-host-namespaces` | Enforce | yes | OT does not use host namespaces |
| `disallow-host-path` | Audit | yes | only PVC + emptyDir volumes |

### Pod Security Standards

Each pod meets PSS Restricted: non-root, read-only root FS with `/tmp` emptyDir 64Mi, drop ALL caps, seccomp RuntimeDefault, no host namespaces, no privileged.

### Resource governance verification

`databases` ns existing LimitRange + ResourceQuota must accommodate +5 pods (~150m CPU + 416Mi memory requests, ~1.7 core + 1.34Gi limits). Implementation plan verifies via `kubectl describe resourcequota` and bumps quota if blocked.

## Observability

### Prometheus metrics

Native via redis-exporter sidecar (port 9121). OT operator's `redisExporter.serviceMonitor.enabled: true` generates ServiceMonitor automatically (no manual ServiceMonitor needed).

Key metrics:
- `redis_up`, `redis_uptime_in_seconds`
- `redis_connected_clients`, `redis_blocked_clients`
- `redis_memory_used_bytes`, `redis_memory_max_bytes`
- `redis_commands_total{cmd}`
- `redis_connected_slaves`, `redis_master_repl_offset`, `redis_master_last_io_seconds_ago`
- `redis_keyspace_keys{db}`, `redis_keyspace_keys_expiring`

Sentinel metrics (limited):
- `redis_sentinel_master_status`, `redis_sentinel_known_slaves`, `redis_sentinel_known_sentinels`

### PrometheusRule alerts

| Alert | Condition | Severity |
|---|---|---|
| `RedisHADown` | 1+ Redis pod down >2m | warning (replica still serves) |
| `RedisHAAllDown` | All Redis pods down >1m | critical |
| `RedisHASentinelDown` | 1+ Sentinel pod down >2m | warning |
| `RedisHASentinelQuorumLost` | <2 Sentinels up >1m | critical |
| `RedisHAReplicationBroken` | master.connected_slaves <1 for 5m | warning |
| `RedisHAReplicationLag` | last_io_seconds_ago >10s for 5m | warning |
| `RedisHAMemoryHigh` | used/max >85% for 10m | warning |
| `RedisHAClientReconnectStorm` | rate(connected_clients) >50 for 5m | warning |

### Grafana dashboard

Existing redis dashboard (if present) keeps working — metric names unchanged. Add HA-specific panels: master/replica role indicator, Sentinel quorum status, replication lag, failover events.

### Uptime Kuma

Replace existing TCP probe to `redis.databases.svc.cluster.local:6379` with two probes:
- `redis-replication-master.databases.svc.cluster.local:6379`
- `redis-sentinel-sentinel.databases.svc.cluster.local:26379`

### Logs

Stdout from redis + sentinel pods captured by Alloy → Loki. Loki labels: `namespace=databases`, `app=redis-replication` / `app=redis-sentinel`.

## Cutover Plan

No soak. Single window, sequential commits. Total ~30-60 min.

### Phase 1a — Operator install (commits 1-3, no client impact)

1. Add `ot-helm` HelmRepository in `flux-system` (if missing).
2. Add `redis-operator` HelmRelease.
3. Verify: `kubectl get crd | grep redis.redis.opstreelabs.in` shows 4 CRDs registered. Operator pod Ready.

### Phase 1b — Deploy HA cluster alongside old Redis (commits 4-7, no client impact)

4. Create SAs (`redis-replication`, `redis-sentinel`) + `redis-acl-secret` (SOPS) + `redis-ha-config` ConfigMap.
5. Apply `RedisReplication` CR → 2 pods Ready, master elected.
6. Apply `RedisSentinel` CR → 3 sentinels Ready, quorum reached.
7. Apply `redis-ha-network-policy`.

**Verification before cutover** (sequential — Bash parallel cancels siblings on failure):
```bash
PASS=$(kubectl get secret -n databases redis-passwords -o jsonpath='{.data.admin-password}' | base64 -d)

kubectl exec -n databases redis-replication-0 -c redis -- redis-cli --user admin -a "$PASS" --no-auth-warning INFO replication
# expect: role:master, connected_slaves:1

kubectl exec -n databases redis-replication-1 -c redis -- redis-cli --user admin -a "$PASS" --no-auth-warning INFO replication
# expect: role:slave, master_link_status:up

kubectl exec -n databases redis-sentinel-0 -c sentinel -- redis-cli -p 26379 SENTINEL MASTERS
# expect: 1 master, num-sentinels: 3, quorum: 2

# ACL users functional
PAPERLESS_PASS=$(kubectl get secret -n databases redis-passwords -o jsonpath='{.data.paperless-password}' | base64 -d)
IMMICH_PASS=$(kubectl get secret -n databases redis-passwords -o jsonpath='{.data.immich-password}' | base64 -d)
kubectl exec -n databases redis-replication-0 -c redis -- redis-cli --user paperless -a "$PAPERLESS_PASS" --no-auth-warning PING
# expect: PONG
kubectl exec -n databases redis-replication-0 -c redis -- redis-cli --user immich -a "$IMMICH_PASS" --no-auth-warning PING
# expect: PONG

kubectl get endpoints -n databases redis-replication-master    # expect: 1 IP
kubectl get endpoints -n databases redis-sentinel-sentinel     # expect: 3 IPs
```

If any check fails: stop, diagnose. Old Redis still serving — no impact.

### Phase 1c — Client cutover (commits 8-9, brief Immich/Paperless reconnect)

8. Cutover commit:
   - Edit Immich `release.yaml`: replace `REDIS_HOSTNAME/PORT/USERNAME/PASSWORD` with `REDIS_URL` env from new `immich-redis-url` SOPS secret.
   - Add `apps/staging/immich/immich-redis-url-secret.yaml` (SOPS).
   - Edit Paperless `paperless-env-secret.yaml`: change `PAPERLESS_REDIS` host to `redis-replication-master.databases.svc.cluster.local`.
   - Edit `apps/base/immich/networkpolicy.yaml`: egress label app: redis -> matchExpressions [redis-replication, redis-sentinel]; add port 26379.
   - Edit `apps/base/paperless-ngx/networkpolicy.yaml`: egress label app: redis -> app: redis-replication.
9. `git push && fr`. Watch app pods restart.

**Verification post-cutover**:
- Immich UI loads, queues processing.
- Paperless UI loads, document upload triggers OCR.
- Logs clean: `kubectl logs -n immich deploy/immich-server | grep -iE "redis|connection"` shows successful Sentinel handshake.
- Old Redis client count near zero, new Redis client counts populated:
  ```bash
  kubectl exec -n databases redis-0 -c redis -- redis-cli --user admin -a "$PASS" --no-auth-warning CLIENT LIST | wc -l
  # expect: ~1
  kubectl exec -n databases redis-replication-0 -c redis -- redis-cli --user admin -a "$PASS" --no-auth-warning CLIENT LIST | awk -F'[ =]' '{for(i=1;i<=NF;i++) if($i=="user") print $(i+1)}' | sort | uniq -c
  # expect: paperless ~8, immich ~76
  ```

If broken: `git revert <cutover-commit> && git push && fr`. Apps revert to old Redis URL. ~5 min total.

### Phase 1d — Decommission (commit 10, no client impact)

10. Remove old Redis manifests:
    - `git rm -r infrastructure/controllers/base/databases/redis/`
    - `git rm -r infrastructure/configs/base/databases/redis/`
    - Update parent `kustomization.yaml` files to remove `redis` references.
    - Commit `chore(redis): remove legacy single-pod after HA cutover`.
    - `git push && fr`.

11. Verify: `kubectl get pods -n databases | grep "^redis-0"` is empty.

12. Manual cleanup if needed: `kubectl delete pvc -n databases data-redis-0`.

### Phase 1e — Add `blocky` ACL user (commit 11, prepares Phase 2)

13. Generate Blocky Redis password: `openssl rand -base64 32 | tr -d '\n='`.
14. Add `blocky-password` to `redis-passwords` SOPS secret.
15. Add `user blocky on >LITERAL ~* &* +@all -@dangerous +keys +info` line to `redis-acl-secret` SOPS file.
16. Commit `feat(redis): add blocky ACL user` + reconcile.
17. Verify: `kubectl exec -n databases redis-replication-0 -c redis -- redis-cli --user blocky -a "$BLOCKY_PASS" --no-auth-warning PING` returns `PONG`.

This unblocks Phase 2.

### Rollback boundaries

| Stage | Rollback method | Rollback time |
|---|---|---|
| 1a-1b (HA deploy, no client cutover) | `git revert` operator + CR commits, or leave operator installed (idle) | <5 min |
| 1c (client cutover failed) | `git revert` cutover commit → apps revert to old Redis URL | <5 min |
| 1d (post-decommission) | `git revert` decommission + cutover → restore old Redis StatefulSet from git → re-encrypted PVC contents lost | More invasive — requires Immich/Paperless to rebuild caches |

## Risk Register

| Risk | Likelihood | Mitigation |
|---|---|---|
| OT operator quirks at v0.24.0 (newer release) | Medium | Phase 1a deploys operator standalone first; only Phase 1b creates CRs. Operator failure caught early without client impact. |
| ACL secret format incompatible with operator | Low | Verified: OT example `acl_config/replication.yaml` shows exact `acl.secret.secretName` + Secret with key `user.acl` pattern. Mirror exactly. |
| Sentinel quorum doesn't form | Low | `redis-sentinel-sentinel.databases.svc.cluster.local` connects to operator-managed StatefulSet. Anti-affinity hard ensures 3 distinct nodes. Verify in Phase 1b. |
| Immich `ioredis://<base64-json>` URL syntax issue | Medium | Verified in Immich docs. Plan task generates JSON, base64-encodes, encrypts. Test connection in dry-run shell before cutover. |
| Paperless static master Service stale on failover | Low | OT operator updates pod role label on Sentinel-driven failover, Service endpoints refresh automatically. ~10-30s reconnect. Cache+Celery tolerates. |
| `redis-replication-master` Service does not exist (operator naming differs) | Low | Verified in OT `internal/k8sutils/redis-replication.go`: `cr.MasterService()` creates a per-master ClusterIP Service. Plan task verifies after deploy. |
| Operator pod creates child pods with default SA | Low | CR spec `serviceAccountName` field verified in OT v1beta2 source. Explicit SAs created in Phase 1b. |
| Redis 7.4.0 image availability / tag drift | Low | `quay.io/opstree/redis:v7.4.0` listed in operator examples. Plan task verifies tag exists at impl. |
| ResourceQuota in `databases` ns rejects new pods | Medium | Plan task `kubectl describe resourcequota -n databases` before cutover; bump if needed in same commit. |
| Old `data-redis-0` PVC lingers after StatefulSet delete | Low | StatefulSet PVC retention is `retain` by default. Plan documents manual delete step. |
| Blocky ACL user accidentally added before Phase 2 deploys Blocky | None — by design | Phase 1e is the last commit. Pre-creates the user so Phase 2 starts cleanly. |

## Success Criteria

- Operator + 2 Redis data pods + 3 Sentinels Running and Ready in `databases` ns.
- Sentinel `SENTINEL MASTERS` shows 1 master, 3 sentinels, quorum 2.
- Immich and Paperless connected to new endpoints (verified via CLIENT LIST counts and app logs).
- Old `redis-0` pod removed; old manifests removed from git.
- Triggered failover test (kill master pod) succeeds: replica promoted within ~10s, apps reconnect cleanly.
- All 8 PrometheusRule alerts evaluate (no firing critical alerts).
- Kyverno reports no policy failures: `kubectl get policyreport -n databases | grep -i fail` returns nothing for new resources.
- `blocky` ACL user provisioned and PING returns PONG.

## Failover Smoke Test (post-cutover, before declaring done)

```bash
# Identify current master
kubectl get pods -n databases -l app=redis-replication --show-labels | grep role=master

# Delete master pod (Sentinel will promote replica)
kubectl delete pod -n databases <master-pod-name>

# Within ~10 seconds:
kubectl get pods -n databases -l app=redis-replication --show-labels | grep role=master
# expect: different pod name now has role=master

# Verify Service endpoint moved
kubectl get endpoints -n databases redis-replication-master -o jsonpath='{.subsets[*].addresses[*].ip}'

# App-level check
curl -sI https://immich.h0melab.work/  # expect: 200
curl -sI https://paperless.h0melab.work/  # expect: 200
```

If failover succeeds and apps remain functional, Phase 1 is complete.

## Follow-ups

- 1-month review of operator stability (already on monthly review checklist via HOMELAB_ANALYSIS PENDING ITEMS).
- Phase 2 (Blocky migration) starts after Phase 1 success criteria met.
- Future: investigate Redis 8 upgrade path via OT operator when stable.
