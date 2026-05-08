# Apps Codemap

16 application stacks. All in `apps/base/<name>/` (shared base) + `apps/staging/<name>/` (env overlay).

| App | NS | Storage | DB | OIDC | External | Notes |
|-----|-----|---------|-----|------|----------|-------|
| **homepage** | homepage | configmap | — | — | int | Dashboard (v1.12.3) |
| **uptime-kuma** | uptime-kuma | PVC | MySQL | — | int | Probes 30+ targets (2.3.2-rootless) |
| **authentik** | authentik | configmap | PostgreSQL | provider | both | SSO, passkey-first Conditional UI (2026.2.2) |
| **blocky** | blocky | none (Secret config) | PG `blocky` (query log) + Redis HA db1 | — | LAN DNS :53 | 2 replicas, single LB Service .126+.129 (v0.29.0) |
| **stirling-pdf** | stirling-pdf | PVC | — | OIDC | both | PDF tools (2.10.1-fat); 2.10.x ~36% RSS regression vs 2.9.2 |
| **homehub** | homehub | PVC | — | — | int | Family dashboard (0.2.3) |
| **immich** | immich | PVC (62GB photos) | PostgreSQL | OIDC | both | Helm chart `immich` 0.11.1, image v2.7.5; Sentinel via REDIS_URL |
| **paperless-ngx** | paperless-ngx | PVC | PostgreSQL + Redis HA (static master Service) | OIDC | both | Doc mgmt (2.20.15) |
| **home-assistant** | home-assistant | PVC | MySQL | OIDC | both | Smart home (2026.5.0) |
| **linkwarden** | linkwarden | PVC + Meilisearch PVC | PostgreSQL | OIDC | both | Bookmarks (v2.14.1) |
| **mealie** | mealie | PVC | PostgreSQL | OIDC | both | Recipes (v3.17.0) |
| **n8n** | n8n | PVC | PostgreSQL | — (native user mgmt) | both | Workflow automation (2.19.5; community edition — SSO is Enterprise-only) |
| **audiobookshelf** | audiobookshelf | 2 PVCs | sqlite | OIDC | both | Audio library (2.34.0) |
| **obsidian** | obsidian | — | CouchDB (`databases` ns) | — | both | LiveSync (LAN-only client cert) |
| **pricebuddy** | pricebuddy | PVC | MySQL | — | int | Price tracking (v1.0.46) |
| **claude-telegram** | claude-telegram | none | — | — | TG only | AI bot (Agent SDK, 1.16); HTTP /trigger loopback hook |

## Key infrastructure namespaces (not "apps")
- `databases` — CNPG (`main-postgres`), Percona Server for MySQL via ps-operator 1.1.x (`main-mysql` — single-master + replica + HAProxy + 3-node Orchestrator; **not** PXC), CouchDB STS, Redis HA via OT-CONTAINER-KIT operator (RedisReplication 1+1 master/replica + RedisSentinel 3, since 2026-04-26 cutover)
- `monitoring` — VM stack (vmsingle, vmagent, vmalert), Grafana (PVC, sqlite, OIDC, dual-ingress, monitoring UI), Alertmanager, kube-state-metrics, node-exporter (kube-prometheus-stack chart trimmed — no Prometheus pod)
- `loki` — Loki helm 7.0.0 + Alloy 1.8.1 (own namespace, not monitoring)
- `traefik` — ingress controller (own namespace) + shared middleware CRDs
- `cert-manager`, `cloudflare-tunnel`, `kyverno`, `csp-reporter`
- `backup-replication` — daily rsync to W2 + NAS
- `popeye` — weekly cluster scan

## Shared service patterns
- All app ingress use middleware chain: `traefik-redirect-https@kubernetescrd,traefik-security-headers@kubernetescrd,traefik-rate-limit-{standard|high-frequency}@kubernetescrd,traefik-csp@kubernetescrd` (middlewares live in `traefik` ns)
- Rate limits: `rate-limit-standard` 100/min avg, burst 150 (default); `rate-limit-high-frequency` 200/min avg, burst 300 (immich, n8n, home-assistant, paperless-ngx); applied to all apps including authentik
- DB usernames = app name (CNPG `managed.roles` for PG, ACL for Redis, GRANT for MySQL)
- DB endpoints: `main-postgres-rw-pooler.databases.svc.cluster.local:5432` (PgBouncer), `main-mysql-haproxy.databases.svc.cluster.local:3306` (HAProxy), `redis-replication-master.databases.svc.cluster.local:6379` (static for Paperless/Blocky), Sentinel for Immich
