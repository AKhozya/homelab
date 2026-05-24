# Design: Replace AdGuard Home with Blocky DNS

**Date**: 2026-04-26
**Status**: Approved (awaiting written-spec review)
**Phase**: 2 of 2 (depends on Phase 1 — Redis HA)

## Problem

AdGuard Home runs as **two independent Deployments** (`adguard-home-w1`, `adguard-home-w2`), each node-pinned to a worker, each with its own PVC, web ingress, certificate, and configuration sync burden. AdGuard's design is single-instance — the dual deployment is a workaround, not native HA. Updates require coordinated manual steps; configuration drift between instances must be prevented manually.

Goal: replace with a DNS resolver that natively supports replicas + shared cache, simplifying ops and enabling real Kubernetes rolling updates.

## Solution Summary

Migrate to **Blocky** (Go-based DNS filter) running as a **single Deployment with 2 replicas**, hard pod anti-affinity per worker, native rolling updates, shared Redis for cache + state sync, and PostgreSQL for query log.

## Out of Scope

- **Phase 1 (Redis HA)**: separate spec. Blocky depends on it but does not bundle it. Phase 1 = K8s-native Redis operator (Spotahome or OT-CONTAINER-KIT, evaluated in its own spec) deploying 1 master + 1 replica + operator-managed failover, mirroring CNPG/Percona pattern.
- **DoH/DoT to clients**: Blocky exposes only plain DNS port 53 to LAN clients. Encrypted DNS used only on upstream (Blocky → public resolvers). Adding client-facing DoH/DoT is a separate change.
- **Per-client filtering groups**: not used today, not added now.
- **Worker-node-2 IPv6 connectivity**: w2 is missing global IPv6 — flagged as separate networking fix (not blocking Blocky migration; `connectIPVersion: dual` makes Blocky tolerant).

## Architecture

### Topology

```
Router DHCP option 6: 192.168.1.129 (primary), 192.168.1.126 (secondary)
                               |                          |
                       +-------+-------+         +--------+-------+
                       | K3s servicelb |         | K3s servicelb  |
                       | Local policy  |         | Local policy   |
                       |     W1        |         |      W2        |
                       +-------+-------+         +--------+-------+
                               |                          |
                               v                          v
                       +-----------------------------------------+
                       |      Deployment: blocky (replicas=2)    |
                       |      hard anti-affinity hostname        |
                       |      nodeAffinity W1+W2                 |
                       |      RollingUpdate maxSurge=0/maxUnav=1 |
                       +------+-------------------------+--------+
                              |                         |
                       +------v-----+            +------v-------+
                       |   Redis    |            |     CNPG     |
                       |  (Phase 1: |            |  blocky DB   |
                       |  HA op)    |            | (query log)  |
                       +------------+            +--------------+
                       cache + state sync         7-day audit log
```

### Decisions and Rationale

| Decision | Choice | Rationale |
|---|---|---|
| Service exposure | K3s servicelb, 2 Services per worker, `externalTrafficPolicy: Local` | Reuses existing 192.168.1.129/126 IPs. Zero client-side changes (router DHCP, Mac resolver script, claude-telegram hostAliases all unchanged). Preserves source IP for query log. |
| Replica topology | 1 Deployment, replicas=2, hard anti-affinity hostname, nodeAffinity W1+W2 | Single source of truth, native k8s rolling, predictable IPs. |
| Update strategy | `RollingUpdate maxSurge=0 maxUnavailable=1` | Required because hard anti-affinity blocks surge (no node available). 1 pod cycles at a time; other IP keeps serving via router fallback. Same per-IP outage profile as today's `Recreate`, but via real k8s rolling. |
| Cache + state sync | Shared Redis (databases ns), DB index 1, ACL user `blocky`, channel `blocky_sync_enabled` | Reuses existing Redis. Different DB index isolates keys. Distinct pub/sub channel avoids Authentik collision. Memory headroom: Redis at 9MB used of 480MB cap. Phase 1 makes Redis HA. |
| Query log | PostgreSQL (CNPG `main-postgres`), **direct primary endpoint** (not PgBouncer pooler), 7-day retention | Use case = debugging. Best UX = SQL queries. Direct endpoint avoids PgBouncer transaction pool mode (`poolMode: transaction`) which breaks prepared statements used by Go's `lib/pq`. Auto-pruned by Blocky's `logRetentionDays`. |
| DoH/DoT to clients | Not implemented | Marginal value on trusted LAN; high config cost (TCP passthrough, cert mgmt, port conflicts). Plain port 53 only. |
| Web UI | Removed | Blocky has no built-in admin UI. Stats via Grafana (Prometheus + Postgres dashboards). Log search via Grafana Loki + Postgres. |
| Blocklists | HaGeZi Multi (replaces AdGuard filter), HaGeZi Pro++, HaGeZi TIF, OISD Big | 3 of 4 work as-is in Blocky. AdGuard's `filter_1.txt` uses AdGuard-specific syntax (silently dropped by Blocky); HaGeZi Multi is the canonical Blocky-compatible equivalent. |
| Custom DNS for `h0melab.work` | `customDNS.mapping` (auto-covers subdomains) | Verified: Blocky auto-resolves all subdomains of mapped domains. Mirrors AdGuard `||h0melab.work^` rule cleanly. |
| IPv6 outbound preference | `connectIPVersion: dual` | Mirrors AdGuard `bootstrap_prefer_ipv6: true` intent without strict v6 requirement. Tolerant of w2's missing IPv6. |

## Components

### Manifests (created)

```
apps/base/blocky/
  namespace.yaml
  serviceaccount.yaml
  configmap.yaml             # blocky config (non-secret)
  secret.yaml                # SOPS — Redis pass + PG pass
  deployment.yaml            # 1 Deployment, 2 replicas, anti-affinity
  service-dns-w1.yaml        # LoadBalancer, Local policy, lands W1 -> 192.168.1.129
  service-dns-w2.yaml        # LoadBalancer, Local policy, lands W2 -> 192.168.1.126
  service-metrics.yaml       # ClusterIP, port 4000, for ServiceMonitor
  networkpolicy.yaml
  kustomization.yaml

apps/staging/blocky/
  kustomization.yaml         # references base, env-specific patches
  cnpg-database.yaml         # CNPG Database CR for "blocky" DB

infrastructure/configs/staging/resource-governance/small-tier/
  blocky.yaml                # LimitRange + ResourceQuota

monitoring/configs/staging/blocky/
  servicemonitor.yaml
  prometheusrule.yaml
  dashboard-blocky.yaml      # ConfigMap with grafana_dashboard label
  dashboard-blocky-querylog.yaml
  kustomization.yaml
```

### Manifests (modified)

```
apps/staging/kustomization.yaml                              # add blocky/, remove adguard-home/
infrastructure/configs/staging/resource-governance/kustomization.yaml  # add small-tier/blocky.yaml, remove small-tier/adguard-home.yaml
infrastructure/configs/base/databases/redis/networkpolicy.yaml  # add ingress from blocky ns
infrastructure/configs/base/databases/redis/acl-configmap.yaml  # add `blocky` ACL user
infrastructure/configs/base/databases/redis/secret.yaml  # add `blocky-password` SOPS-encrypted (Phase 1 may already do this)
scripts/macos/setup-h0melab-resolver.sh                      # update header comment AdGuard -> Blocky
scripts/macos/README.md                                      # update doc
docs/HOMELAB_ANALYSIS.md                                     # apps table row, HA section
docs/HOMELAB_HISTORY.md                                      # append migration entry
~/.local/bin/setup-h0melab-resolver                          # chezmoi'd dotfile, sync after edit
```

### Manifests (removed after soak)

```
apps/base/adguard-home/                                      # all files
apps/staging/adguard-home/                                   # all files
infrastructure/configs/staging/resource-governance/small-tier/adguard-home.yaml
```

## Configuration

### Blocky config (ConfigMap)

```yaml
ports:
  dns: 53
  http: 4000

connectIPVersion: dual

upstreams:
  init:
    strategy: blocking
  groups:
    default:
      - https://security.cloudflare-dns.com/dns-query
      - https://dns.quad9.net/dns-query

bootstrapDns:
  - upstream: 1.1.1.2
  - upstream: 1.0.0.2
  - upstream: 9.9.9.9
  - upstream: 149.112.112.112
  - upstream: 2606:4700:4700::1112
  - upstream: 2606:4700:4700::1002
  - upstream: 2620:fe::fe
  - upstream: 2620:fe::9

conditional:
  mapping:
    cluster.local: 10.43.0.10

customDNS:
  customTTL: 1h
  filterUnmappedTypes: true
  mapping:
    h0melab.work: 192.168.1.129,192.168.1.126

blocking:
  denylists:
    default:
      - https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/multi.txt
      - https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/pro.plus.txt
      - https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/tif.txt
      - https://big.oisd.nl/
  clientGroupsBlock:
    default:
      - default
  blockType: zeroIp
  blockTTL: 30s
  loading:
    refreshPeriod: 24h

caching:
  minTime: 60s
  maxTime: 0
  prefetching: true
  prefetchExpires: 2h
  prefetchThreshold: 5

redis:
  address: redis.databases.svc.cluster.local:6379
  username: blocky
  password: ${REDIS_PASSWORD}
  database: 1
  required: false
  connectionAttempts: 5
  connectionCooldown: 3s

queryLog:
  type: postgresql
  target: postgres://blocky:${PG_PASSWORD}@main-postgres-rw.databases.svc.cluster.local:5432/blocky?sslmode=require
  logRetentionDays: 7
  flushInterval: 30s
  fields:
    - clientIP
    - clientName
    - responseReason
    - responseAnswer
    - question
    - duration

prometheus:
  enable: true
  path: /metrics

log:
  level: info
  format: json

minTlsServeVersion: "1.3"
```

### Pod security

```yaml
spec:
  template:
    spec:
      serviceAccountName: blocky
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 100
        runAsGroup: 100
        fsGroup: 100
        seccompProfile: {type: RuntimeDefault}
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - {key: kubernetes.io/hostname, operator: In, values: [worker-node, worker-node-2]}
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - topologyKey: kubernetes.io/hostname
              labelSelector: {matchLabels: {app: blocky}}
      containers:
        - name: blocky
          image: spx01/blocky:v0.29.0     # latest stable as of 2026-04-26 (verify before commit)
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            capabilities:
              add: ["NET_BIND_SERVICE"]
              drop: ["ALL"]
          ports:
            - {containerPort: 53, name: dns-tcp, protocol: TCP}
            - {containerPort: 53, name: dns-udp, protocol: UDP}
            - {containerPort: 4000, name: http, protocol: TCP}
          env:
            - {name: REDIS_PASSWORD, valueFrom: {secretKeyRef: {name: blocky-secrets, key: redis-password}}}
            - {name: PG_PASSWORD,    valueFrom: {secretKeyRef: {name: blocky-secrets, key: pg-password}}}
          resources:
            requests: {cpu: "50m", memory: "128Mi"}
            limits:   {cpu: "500m", memory: "512Mi"}
          livenessProbe:
            httpGet: {path: /, port: 4000}
            initialDelaySeconds: 30
            periodSeconds: 30
            failureThreshold: 3
          readinessProbe:
            httpGet: {path: /, port: 4000}
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 3
          startupProbe:
            httpGet: {path: /, port: 4000}
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 30
          volumeMounts:
            - {name: tmp, mountPath: /tmp}
            - {name: config, mountPath: /app/config.yml, subPath: config.yml, readOnly: true}
      volumes:
        - {name: tmp, emptyDir: {sizeLimit: 64Mi}}
        - {name: config, configMap: {name: blocky-config}}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 0
      maxUnavailable: 1
```

### NetworkPolicy

```yaml
podSelector: {matchLabels: {app: blocky}}
policyTypes: [Ingress, Egress]

ingress:
  - ports: [{protocol: TCP, port: 53}, {protocol: UDP, port: 53}]
  - from: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: monitoring}}}]
    ports: [{protocol: TCP, port: 4000}]

egress:
  # CoreDNS for cluster.local
  - to: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}},
          podSelector: {matchLabels: {k8s-app: kube-dns}}}]
    ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
  # Redis (databases ns)
  - to: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: databases}},
          podSelector: {matchLabels: {app.kubernetes.io/name: redis}}}]
    ports: [{protocol: TCP, port: 6379}]
  # CNPG primary (direct, not via pooler — see note in queryLog section)
  - to: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: databases}},
          podSelector: {matchLabels: {cnpg.io/cluster: main-postgres}}}]
    ports: [{protocol: TCP, port: 5432}]
  # Upstream DNS resolvers
  - to:
      - {ipBlock: {cidr: 1.1.1.2/32}}
      - {ipBlock: {cidr: 1.0.0.2/32}}
      - {ipBlock: {cidr: 9.9.9.9/32}}
      - {ipBlock: {cidr: 149.112.112.112/32}}
      - {ipBlock: {cidr: 2606:4700:4700::1112/128}}
      - {ipBlock: {cidr: 2606:4700:4700::1002/128}}
      - {ipBlock: {cidr: 2620:fe::fe/128}}
      - {ipBlock: {cidr: 2620:fe::9/128}}
    ports:
      - {protocol: UDP, port: 53}
      - {protocol: TCP, port: 53}
      - {protocol: TCP, port: 853}
  # HTTPS for DoH + blocklist downloads (CDNs cannot be IP-pinned)
  - ports: [{protocol: TCP, port: 443}]
```

### Resource governance

```yaml
LimitRange:
  default: {cpu: 500m, memory: 512Mi}
  defaultRequest: {cpu: 50m, memory: 128Mi}
  max: {cpu: 2000m, memory: 2Gi}
  min: {cpu: 10m, memory: 16Mi}
ResourceQuota:
  requests.cpu: "1"
  requests.memory: 1Gi
  limits.cpu: "3"
  limits.memory: 4Gi
  pods: "10"
  services: "5"
  persistentvolumeclaims: "1"
```

## Compliance Verification

### Kyverno policies (all currently active)

`blocky` namespace is NOT excluded from any policy. Each Enforce policy is satisfied by the design:

| Policy | Mode | Design satisfies | How |
|---|---|---|---|
| `require-labels` | Enforce | yes | Pod template carries `app: blocky` |
| `disallow-latest-tag` | Enforce | yes | Image pinned to `spx01/blocky:v0.29.0` (verify exact latest stable at implementation) |
| `disallow-privilege-escalation` | Enforce | yes | `allowPrivilegeEscalation: false` on container |
| `require-drop-all-capabilities` | Enforce | yes | `capabilities.drop: [ALL]`. Adding `NET_BIND_SERVICE` does not violate (policy only validates `drop` contains `ALL`) |
| `require-non-default-serviceaccount` | Enforce | yes | Dedicated `blocky` ServiceAccount, `automountServiceAccountToken: false` |
| `require-seccomp-runtimedefault` | Enforce | yes | `seccompProfile.type: RuntimeDefault` at pod level |
| `require-non-root` | Audit | yes | `runAsNonRoot: true`, `runAsUser: 100`, `runAsGroup: 100` |
| `require-resource-limits` | Audit | yes | requests + limits on container; no init containers |
| `disallow-host-namespaces` | Enforce | yes | no hostNetwork, hostPID, hostIPC |
| `disallow-host-path` | Audit | yes | only emptyDir, configMap, secret volumes |

### Pod Security Standards (PSS Restricted equivalent)

Pod meets PSS Restricted: non-root, read-only root FS with `/tmp` emptyDir (per CLAUDE.md invariant), drop ALL caps + only NET_BIND_SERVICE, seccomp RuntimeDefault, no host namespaces, no privileged.

### Ingress / egress matrix

Defined in `apps/base/blocky/networkpolicy.yaml`:

**Ingress allowed:**
- DNS port 53 TCP+UDP from any source (LAN clients via servicelb).
- Metrics port 4000 TCP from `monitoring` ns only.

**Egress allowed:**
- CoreDNS (`kube-system` ns, label `k8s-app: kube-dns`) on 53 TCP+UDP — required for resolving `redis.databases.svc.cluster.local`, `main-postgres-rw-pooler.databases.svc.cluster.local`.
- Redis (`databases` ns, label `app.kubernetes.io/name: redis`) on 6379 TCP.
- CNPG via PgBouncer (`databases` ns, label `cnpg.io/cluster: main-postgres`) on 5432 TCP.
- Public DNS resolvers (Cloudflare 1.1.1.2, 1.0.0.2; Quad9 9.9.9.9, 149.112.112.112; IPv6 equivalents) on 53 TCP+UDP and 853 TCP.
- HTTPS port 443 TCP to any (DoH upstreams + blocklist downloads from jsdelivr/OISD/HaGeZi CDNs — IP-pinning impractical for CDN-fronted services).

**Cross-namespace policy updates required:**
- `databases/redis-network-policy`: add ingress from `blocky` ns selector on port 6379 TCP. Modified file: `infrastructure/configs/staging/databases/redis-network-policy.yaml`.
- CNPG cluster's auto-generated NetworkPolicy: verify it accepts traffic from `blocky` ns. Most CNPG defaults allow any ns; if not, add allow-list entry.

**Verification before cutover:**
- `kubectl get clusterpolicy -o name` matches expected list (10 policies).
- `kubectl apply --dry-run=server -k apps/staging/blocky/` returns no Kyverno admission errors.
- `kubectl get policyreport -A | grep blocky` after deploy: zero `result: fail` entries for the namespace.

## Observability

### Prometheus metrics scraped (native Blocky)

- `blocky_query_total{client,type,response_type,reason}`
- `blocky_request_duration_seconds` (histogram)
- `blocky_response_total{client,reason,response_code}`
- `blocky_blocking_enabled`
- `blocky_cache_entry_count`, `blocky_cache_hit_count`, `blocky_cache_miss_count`
- `blocky_blacklist_cache` (entries per group)
- `blocky_failed_downloads_total`
- Standard Go runtime + process metrics

### Grafana dashboards

1. **Blocky DNS overview** — community dashboard ID `13768` (vet first, import as ConfigMap)
2. **Blocky query log analytics** — custom Postgres dashboard, panels:
   - Top 20 blocked domains (24h)
   - Top 20 querying clients (24h)
   - Block rate % over time
   - Query volume per client over time

### PrometheusRule alerts

- `BlockyDown` — pod down >2m (critical, per-instance)
- `BlockyAllReplicasDown` — both pods down >1m (critical)
- `BlockyHighErrorRate` — >5% non-NOERROR/NXDOMAIN responses for 10m (warning)
- `BlockyBlocklistRefreshFailing` — refresh failures in last hour, persists 30m (warning)
- `BlockyHighLatency` — p95 query latency >100ms for 10m (warning)

### Uptime Kuma

Replace AdGuard web port 80 probe with **DNS monitor** type: `dig @192.168.1.129 google.com` and `dig @192.168.1.126 google.com`.

### Logs

- Blocky `log.format: json` -> stdout -> Alloy -> Loki
- Loki labels: `namespace=blocky`, `pod=blocky-xxx`
- Grafana log search supports JSON field extraction

## Cutover Plan

### Pre-cutover (no client impact)

1. Phase 1 complete: Redis HA operator deployed, `blocky` ACL user provisioned in `redis-acl` ConfigMap, password committed to `redis-passwords` SOPS secret as `blocky-password`.
2. CNPG `Database` CR for `blocky` DB created in `databases` ns; `blocky` PostgreSQL role + password in SOPS; verify role can `CREATE TABLE` on the DB (Blocky auto-creates `log_entries` table).
3. Update `infrastructure/configs/staging/databases/redis-network-policy.yaml`: add ingress from `blocky` ns on port 6379.
4. Commit Blocky manifests under `apps/base/blocky/` and `apps/staging/blocky/`. **Do not** add reference in `apps/staging/kustomization.yaml` yet.
5. Local validate: `kubectl apply --dry-run=server -k apps/staging/blocky/`.
6. Wire ServiceMonitor + PrometheusRule + dashboards + Uptime Kuma DNS probe (probe still uses 192.168.1.129/126; will work post-cutover automatically).

### Cutover (DNS unavailable 0-5 min worst case)

7. Edit `apps/staging/kustomization.yaml`: add `- ../base/blocky` (or appropriate path), remove `- ../base/adguard-home`.
8. `git add -A && git commit -m "feat(blocky): replace adguard with blocky"`
9. `git push`
10. `fr` (full reconcile)
11. Watch: AdGuard pods Terminating -> Blocky pods Pending -> ContainerCreating -> Running -> Ready. K3s svclb assigns LB IPs to nodes hosting Ready pods (192.168.1.129/126).
12. Verify (sequential — fragile commands, do not parallel):
    - `kubectl get pods -n blocky` -> 2 Running, both Ready
    - `kubectl logs -n blocky -l app=blocky --tail=50` -> blocklists loaded, no errors, Redis connected, Postgres connected
    - `dig @192.168.1.129 google.com` -> resolves
    - `dig @192.168.1.129 doubleclick.net` -> 0.0.0.0 (blocked)
    - `dig @192.168.1.129 grafana.h0melab.work` -> 192.168.1.129/126
    - `dig @192.168.1.126 google.com` -> resolves
    - LAN client browser: `https://grafana.h0melab.work` loads (customDNS rewrite OK)
    - `kubectl exec -n databases main-postgres-1 -- psql -U postgres -d blocky -c "SELECT count(*) FROM log_entries"` -> rows growing
    - Prometheus: `up{job="blocky"} == 1` -> 2 instances

### Post-cutover

13. Update `scripts/macos/setup-h0melab-resolver.sh` + `scripts/macos/README.md`: replace AdGuard references with Blocky in comments. IPs unchanged.
14. Sync chezmoi'd `~/.local/bin/setup-h0melab-resolver`; commit dotfiles repo.
15. Update `docs/HOMELAB_ANALYSIS.md`: apps table row (AdGuard -> Blocky), HA section (collapsed dual-deployment language), score may bump.
16. Update `docs/HOMELAB_HISTORY.md`: append migration entry.
17. Update memory files: replace AdGuard refs with Blocky equivalents; archive `feedback`/gotcha entries that no longer apply.
18. Soak 7 days. Monitor: alerts, query log row growth, blocklist refresh success, p95 latency, memory consumption.
19. After clean soak: `git rm -r apps/base/adguard-home/ apps/staging/adguard-home/ infrastructure/configs/staging/resource-governance/small-tier/adguard-home.yaml`. Commit `chore: remove adguard manifests after blocky soak`.

### Rollback (3-5 min if cutover broken)

- `git revert <cutover-commit> && git push && fr`
- Flux reconciles, AdGuard manifests reapplied, pods return on same nodes -> same IPs (192.168.1.129/126).
- AdGuard PVCs preserved (not removed until step 19) -> state restored automatically.
- Mac script unchanged -> no client action needed.

## Risk Register

| Risk | Likelihood | Mitigation |
|---|---|---|
| Blocklist downloads fail at startup -> Blocky NotReady | Medium | `init.strategy: blocking` config, jsdelivr/OISD CDNs reliable, startup probe gives 150s window |
| Redis password rotation desync between secret and ACL ConfigMap | Low | Phase 1 spec covers ACL+secret coupling; SOPS commit atomicity |
| CNPG `blocky` role lacks CREATE TABLE -> query log fails | Medium | Verify before cutover that role has DB ownership or schema CREATE grant. Implementation plan must include grant step. |
| PgBouncer transaction pool mode breaks Blocky prepared statements | High (if pooler used) | **Use direct primary endpoint** `main-postgres-rw.databases.svc.cluster.local:5432` instead of pooler. Spec config reflects this. Trade-off: no connection pooling — acceptable since 2 Blocky pods with low-volume inserts won't strain CNPG. |
| svclb does not assign 192.168.1.129/126 (race) | Low | Same servicelb as AdGuard today; manual annotation fallback if needed |
| `customDNS.mapping` subdomain auto-resolution behaves differently than expected | Low | Documented in Blocky docs; tested in cutover step 12 (`dig grafana.h0melab.work`); fallback is explicit `customDNS.zone` block |
| HaGeZi Multi false positives | Low | `whiteLists` config available per group; add as needed; OISD also has tighter scope option |
| Blocky log JSON schema differs from dashboards expectations | Low | Dashboards built for Blocky-specific schema (no AdGuard log dependency) |
| Worker-node-2 IPv6 missing -> upstream DNS via IPv4 only on w2 pod | Low | `connectIPVersion: dual` falls back to IPv4 transparently; no functional impact |

## Success Criteria

- All AdGuard manifests removed; Blocky serves DNS on 192.168.1.129 and 192.168.1.126.
- 7-day soak: zero `BlockyDown` / `BlockyAllReplicasDown` alerts excluding planned restarts.
- Blocklist refresh succeeds daily (no `BlockyBlocklistRefreshFailing`).
- p95 query latency <50ms (better than AdGuard baseline).
- Postgres `blocky.log_entries` accumulates rows; auto-prune at 7 days holds DB size <100MB.
- Memory consumption stable below 384Mi per pod (room to scale `limits` down at 1-month review).
- Native `kubectl rollout status deployment/blocky -n blocky` works for image bumps.

## Follow-ups (post-migration)

- 1-month review: tune `resources.limits.memory` based on observed peak RSS (likely scale 512Mi -> 256Mi if Blocky proves efficient as expected).
- 1-month review: K8s-native Redis operator health check (Phase 1 follow-up, separate spec).
- Future: evaluate DoH/DoT to clients if home VPN scenarios expand or guest network is added.
- Future: per-client groups if multi-user filtering needs emerge (e.g. kids' devices).
