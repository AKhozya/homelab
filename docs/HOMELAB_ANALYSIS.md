# System Overview

A snapshot of what runs in the cluster and how it's postured. For *why* it's built this way see [ARCHITECTURE.md](ARCHITECTURE.md); for the change log see [HOMELAB_HISTORY.md](HOMELAB_HISTORY.md); for per-subsystem structure see [CODEMAPS/](CODEMAPS/).

**Cluster:** K3s `v1.36.1+k3s1`, single-environment **production** (no staging — a merge to `main` deploys straight to prod), 3 Arch Linux nodes (1 control-plane + 2 workers), static-DHCP IPv4.

## Platform at a glance

| Area | Status |
|---|---|
| **Security** | Pod Security Standards enforced; 12 Kyverno policies (9 Enforce, 3 in Audit soak); default-deny NetworkPolicies; secrets SOPS-encrypted in Git |
| **Backup / DR** | Daily logical backups (Postgres, MySQL, CouchDB, app PVCs), 30-day retention, off-node + NAS replication, documented restore runbook |
| **Observability** | VictoriaMetrics + Grafana + Loki/Alloy; Alertmanager → Telegram; weekly Popeye hygiene scan |
| **Networking** | Dual ingress (LAN Traefik + Cloudflare Tunnel), zero inbound ports, Blocky DNS + ad-block |
| **Automation** | Flux GitOps reconcile; Renovate dependency PRs; CI validation gate; ansible-driven node maintenance |
| **HA** | Postgres primary+replica, MySQL async replication, Redis Sentinel quorum, CouchDB active-active; single control-plane (deliberate — see ARCHITECTURE trade-offs) |

## Platform facts

- **16** applications across **28** namespaces
- **64** NetworkPolicy resources — default-deny posture; presence enforced by Kyverno
- **12** Kyverno `ClusterPolicy` resources — **9 Enforce, 3 in Audit** soak
- **53** SOPS-encrypted secrets — no plaintext secret in Git
- **13** HelmReleases — drift detection enabled, with targeted timeouts + rollback
- **3** PriorityClasses (critical / standard / batch) — every workload annotated
- **PSS:** 12 namespaces `restricted`, 9 `baseline`, 6 `privileged` (each justified — GPU, hostPath, host-network)

## Applications (16)

> Grafana is monitoring infrastructure, not a listed app.

| App | SSO | Notes |
|---|---|---|
| Authentik | Provider | Identity provider; PostgreSQL backend; passkey-first login |
| Home Assistant | OIDC | Smart home; MySQL |
| Immich | OIDC | Photo & video management; GPU-accelerated ML |
| Audiobookshelf | OIDC | Audiobook & podcast library |
| Paperless-NGX | OIDC | Document archive with OCR |
| Linkwarden | OIDC | Bookmarks + Meilisearch |
| Mealie | OIDC | Recipe manager |
| n8n | OIDC | Workflow automation |
| Stirling-PDF | OIDC | PDF toolkit |
| Homepage | — | Services dashboard |
| HomeHub | — | Family start page (LAN only) |
| Obsidian | — | Notes sync (CouchDB LiveSync) |
| Uptime Kuma | — | Uptime monitor; MySQL |
| PriceBuddy | — | Price tracker; MySQL |
| Blocky | — | DNS resolver + ad-block; HA (2 replicas, W1+W2); serves LAN clients only |
| claude-telegram | — | Telegram bot bridge for ops |

## Databases

| Engine | Replicas | HA | Proxy | Key apps |
|---|---|---|---|---|
| PostgreSQL (CloudNativePG) | 2 | Streaming replication | PgBouncer | Authentik, Immich, Paperless, Grafana, n8n, Mealie, Linkwarden, Audiobookshelf |
| MySQL (Percona) | 2 | Async replication | HAProxy | Home Assistant, Uptime Kuma, PriceBuddy |
| Redis (OT-operator) | 1 master + 1 replica + 3 Sentinels | Sentinel quorum (2 of 3) | Sentinel / static master Service | Paperless, Immich |
| CouchDB | 2 | Active-active | — | Obsidian sync |

DB role name = app name. Provisioning goes through the operator CRDs (CNPG `Database` / Percona `User`) — never direct SQL drops or force-deleted pods.

## Backups

- Per-engine logical dumps overnight: Postgres 03:00, CouchDB 03:05, PVCs 03:10, MySQL 03:15 — **30-day retention**.
- 03:30 replication: worker-node-2 → NAS (rsync daemon, 500 GB cap).
- Every backup validated (SHA-256 + tar + size + age); failure-only Telegram alerts.

## Monitoring

- **VictoriaMetrics** — VMSingle + VMAgent + VMOperator; ~113k active series at ~487 MiB (≈71% RAM saving vs Prometheus on the same scrape set).
- **Grafana** — dashboards, OIDC login.
- **Loki + Grafana Alloy** — log aggregation (DaemonSet).
- **Alertmanager** — Telegram alerts.
- **Popeye** — weekly cluster-hygiene scan.
- **Kyverno** — daily policy-violation digest.

## External access

- **Cloudflare Tunnel** fronts the internet-reachable apps (Authentik, CouchDB, Audiobookshelf, Linkwarden, Stirling-PDF, Mealie, Paperless, Immich, n8n) — outbound-initiated, so the router opens zero inbound ports.
- **Internal:** Blocky serves LAN-client DNS; Traefik terminates internal ingress. Cluster DNS is a `coredns-ha` DaemonSet (1 replica/node) behind `10.43.0.10`.
- **Domain:** `h0melab.work` (TLS via cert-manager DNS-01).

## Storage

- worker-node: 4.22 TB LVM (2 NVMe SSDs) — hosts the bulk of app PVCs.
- worker-node-2: 863 GB extra storage.
- NAS: 14 TB (500 GB backup cap).

Storage is node-local (`local-path-provisioner`) — no distributed storage layer by choice; durability comes from the backup chain, not replicated volumes.

## Reproducible-build contribution

Both workers run [rebuilderd](https://github.com/kpcyrd/rebuilderd) 24/7, independently rebuilding Arch Linux packages and attesting whether they reproduce bit-for-bit — a contribution to the [Arch reproducible-builds](https://reproducible.archlinux.org/) effort using otherwise-idle homelab capacity.

## Maintenance

The cluster is reviewed monthly (security scans, policy reports, alert/backup/cert health, dependency freshness). The full changelog lives in [HOMELAB_HISTORY.md](HOMELAB_HISTORY.md); every change is a commit, so `git log` is the audit trail.
