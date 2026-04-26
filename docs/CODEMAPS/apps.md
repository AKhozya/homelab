# Apps Codemap

17 application stacks. All in `apps/base/<name>/` (shared base) + `apps/staging/<name>/` (env overlay).

| App | NS | Storage | DB | OIDC | External | Notes |
|-----|-----|---------|-----|------|----------|-------|
| **homepage** | homepage | configmap | — | — | int | Dashboard |
| **uptime-kuma** | uptime-kuma | PVC | MySQL | — | int | Probes 30+ targets |
| **authentik** | authentik | configmap | PostgreSQL | provider | both | SSO, passkey-first |
| **blocky** | blocky | none (Secret config) | PG `blocky` (query log) + Redis HA db1 | — | LAN DNS :53 | 2 replicas, single LB Service .126+.129 |
| **stirling-pdf** | stirling-pdf | PVC | — | OIDC | both | PDF tools |
| **homehub** | homehub | PVC | — | — | int | Family dashboard |
| **grafana** | monitoring | PVC | sqlite | OIDC | both | Monitoring UI |
| **immich** | immich | PVC (62GB photos) | PostgreSQL | OIDC | both | Photo mgmt; Sentinel via REDIS_URL |
| **paperless-ngx** | paperless-ngx | PVC | PostgreSQL + Redis HA (static master Service) | OIDC | both | Doc mgmt |
| **home-assistant** | home-assistant | PVC | MySQL | OIDC | both | Smart home |
| **linkwarden** | linkwarden | PVC + Meilisearch PVC | PostgreSQL | OIDC | both | Bookmarks |
| **mealie** | mealie | PVC | PostgreSQL | OIDC | both | Recipes |
| **n8n** | n8n | PVC | PostgreSQL | Enterprise OIDC | both | Workflow automation |
| **audiobookshelf** | audiobookshelf | 2 PVCs | sqlite | OIDC | both | Audio library |
| **obsidian** | obsidian | — | CouchDB (`databases` ns) | — | both | LiveSync (LAN-only client cert) |
| **pricebuddy** | pricebuddy | PVC | MySQL | — | int | Price tracking |
| **claude-telegram** | claude-telegram | none | — | — | TG only | AI bot (Agent SDK) |

## Key infrastructure namespaces (not "apps")
- `databases` — CNPG (`main-postgres`), Percona MySQL (`main-mysql`), CouchDB STS, Redis HA (RedisReplication 2 + RedisSentinel 3 via OT-CONTAINER-KIT operator)
- `monitoring` — VM stack (vmsingle, vmagent, vmalert), Grafana, Alertmanager, Loki, Alloy
- `cert-manager`, `cloudflare-tunnel`, `traefik`, `kyverno`, `csp-reporter`
- `backup-replication` — daily rsync to W2 + NAS
- `popeye` — weekly cluster scan

## Shared service patterns
- All app ingress use middleware chain: `traefik-redirect-https@kubernetescrd,traefik-security-headers@kubernetescrd`
- Rate limits: 200/min default, 500/min heavy (n8n, immich, HA), none on authentik
- DB usernames = app name (CNPG `managed.roles` for PG, ACL for Redis, GRANT for MySQL)
- DB endpoints: `main-postgres-rw-pooler.databases.svc.cluster.local:5432` (PgBouncer), `main-mysql-haproxy.databases.svc.cluster.local:3306` (HAProxy), `redis-replication-master.databases.svc.cluster.local:6379` (static for Paperless/Blocky), Sentinel for Immich
