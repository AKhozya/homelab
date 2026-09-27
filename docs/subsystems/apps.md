# Apps Codemap

Application stacks, one dir each under `apps/<name>/` (flat, single-env). Image versions: pinned in each app's `deployment.yaml` / `release.yaml`.

| App | NS | Storage | DB | OIDC | External | Notes |
|-----|-----|---------|-----|------|----------|-------|
| **homepage** | homepage | configmap | — | forward-auth | int | Dashboard; Authentik proxy provider on the embedded outpost (callback Ingress lives in the `authentik` ns) |
| **uptime-kuma** | uptime-kuma | PVC | MySQL | — | int | Probes 30+ targets; rootless image |
| **authentik** | authentik | configmap | PostgreSQL | provider | both | SSO; passkey-first Conditional UI; no Redis (in-memory cache) |
| **blocky** | blocky | none (Secret config) | PG `blocky` (query log) + Redis HA db1 | — | LAN DNS :53 | 2 replicas, single LB Service on W1+W2 IPs; LAN clients only — nodes + CoreDNS use public DNS |
| **stirling-pdf** | stirling-pdf | PVC | — | OIDC | both | PDF tools; `-fat` image variant |
| **homehub** | homehub | PVC | — | — | int | Family dashboard |
| **immich** | immich | NAS library (virtiofs hostPath) | PostgreSQL + Redis (static master Service) | OIDC | both | Helm chart `immich` (`apps/immich/release.yaml`); server + ML pods on `immich-vm` (dedicated node, taint `homelab/dedicated=immich`); ML inference on the iGPU via the `-openvino` image (2026-09-06) |
| **paperless-ngx** | paperless-ngx | PVC | PostgreSQL + Redis (static master Service) | OIDC | both | Doc mgmt |
| **home-assistant** | home-assistant | PVC | MySQL | OIDC | int | Smart home; not in Cloudflare tunnel config (verified 2026-07-16 from SOPS) |
| **linkwarden** | linkwarden | PVC + Meilisearch PVC | PostgreSQL | OIDC | both | Bookmarks |
| **mealie** | mealie | PVC | PostgreSQL | OIDC | both | Recipes |
| **n8n** | n8n | PVC | PostgreSQL | — (native user mgmt; SSO is Enterprise-only) | both | Workflow automation |
| **audiobookshelf** | audiobookshelf | 2 PVCs | sqlite | OIDC | both | Audio library |
| **obsidian** | obsidian | — | CouchDB (`databases` ns) | — | both | LiveSync (LAN-only client cert); external hostname is `couchdb.h0melab.work` |
| **pricebuddy** | pricebuddy | PVC | MySQL | — | int | Price tracking; sidecars `seleniumbase-scrapper` (CI image-pin allowlisted — upstream has no patch tags) + `apprise` |
| **claude-telegram** | claude-telegram | PVC 2Gi (`claude-telegram-home-pvc`: dotfiles, checkouts, plugin + Codex state) | — | — | TG only | AI bot; HTTP `/trigger` loopback hook. RBAC is per-namespace, not cluster-wide — see `apps/claude-telegram/rbac.yaml` |
| **rustdesk** | rustdesk | PVC (100Mi, ed25519 key + sqlite) | — | — | LAN :21115-21117 | Self-hosted remote desktop (hbbs+hbbr, 1 pod/2 containers); single mixed-proto LB on W1 (192.168.1.129); `-k _` gates only the connect-to-peer path, NOT registration or the CVE-670 UDP-reflection handlers; LAN-only (21116/UDP can't traverse tunnel) |

External = hostname entry in the central Cloudflare tunnel config — see [networking.md](networking.md), never a second Ingress. Grafana (monitoring ns) is also OIDC + dual-ingress — see [monitoring.md](monitoring.md).

## Key infrastructure namespaces (not "apps")
- `databases` — CNPG (`main-postgres`), Percona Server for MySQL (`main-mysql` — single-master + replica + HAProxy + 3-node Orchestrator; **not** PXC), CouchDB STS, Redis HA (OT-CONTAINER-KIT: RedisReplication 1+1 + RedisSentinel 3). Detail: [databases.md](databases.md)
- `monitoring` — VM stack (vmsingle, vmagent, vmalert), Grafana (PVC, sqlite, OIDC, dual-ingress), Alertmanager, kube-state-metrics, node-exporter (kube-prometheus-stack chart trimmed — no Prometheus pod)
- `loki` — Loki + Alloy (own namespace, not monitoring)
- `traefik` — ingress controller + shared middleware CRDs
- `cert-manager`, `cloudflare-tunnel`, `kyverno`
- `backup-replication` — daily rsync to the NAS; weekly immich backup. The W1→W2 safety-net leg was removed 2026-07-17 (NAS leg validated), so this is a single destination now
- `popeye` — weekly cluster scan; `trivy-scan` — monthly image-CVE scan

## Shared service patterns
- All app ingress use middleware chain: `traefik-redirect-https@kubernetescrd,traefik-security-headers@kubernetescrd,traefik-rate-limit-{standard|high-frequency}@kubernetescrd,traefik-csp-{inline|permissive}-enforced@kubernetescrd` (middlewares in `traefik` ns). homepage inserts `traefik-authentik-forward-auth@kubernetescrd` **after** rate-limit — a 401 or redirect short-circuits the chain, so auth placed earlier would leave login attempts unthrottled
- CSP tiers (enforced): `csp-inline-enforced` (self + unsafe-inline, no eval) — audiobookshelf, homehub, homepage, mealie, paperless-ngx; `csp-permissive-enforced` (+unsafe-eval, explicit opt-in for eval/wasm) — authentik, home-assistant, immich, linkwarden, n8n, pricebuddy, stirling-pdf, uptime-kuma; `csp-strict-enforced` (self only) — couchdb/Fauxton. Global `csp` default = inline tier so new apps can't silently inherit unsafe-eval. `report-uri` omitted everywhere (a cluster-internal report sink is browser-unreachable) — verify CSP via browser console, not Loki.
- Rate limits: `rate-limit-standard` `average: 300` / `period: 1m`, burst 150 (default); `rate-limit-high-frequency` `average: 600` / `period: 1m`, burst 300 (home-assistant, immich, n8n). Both carry an explicit `period` — without it `average` is per **second**, which is how the earlier "100/min" and "200/min" comments were really enforcing 6000/min and 12000/min (fixed 2026-07-03).
- **authentik carries no rate-limit middleware at all** — its chain is redirect-https, security-headers, csp-permissive-enforced. Throttling the SSO provider breaks the auth flow for every app behind it.
- Image-pin CI gate: `scripts/ci/image-pin-audit.sh` in `validate.yaml` enforces `major.minor.patch` on every image (Kyverno only catches `:latest`/no-tag); allowlist inside the script (`postgres*`, `seleniumbase-scrapper`)
- DB usernames = app name (CNPG `managed.roles` for PG, ACL for Redis, GRANT for MySQL)
- DB endpoints: `main-postgres-rw-pooler.databases.svc.cluster.local:5432` (PgBouncer), `main-mysql-haproxy.databases.svc.cluster.local:3306` (HAProxy), `redis-replication-master.databases.svc.cluster.local:6379` (static master — paperless, blocky, immich)
