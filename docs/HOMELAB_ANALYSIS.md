# HOMELAB COMPREHENSIVE ANALYSIS

**Cluster**: K3s (staging) - **3 nodes** (1 control-plane, 2 workers)
**Node IPs** (static DHCP): gmk-k3s-control-plane=192.168.1.127, worker-node=192.168.1.129, worker-node-2=192.168.1.126
**Infrastructure**: GitOps (Flux), CloudNativePG, Percona MySQL, Monitoring Stack, SSO (Authentik), Cloudflare Tunnel
**Code Review**: 2026-04-02 - Full codebase analysis (94/100, A)

---

## CURRENT STATE

**Overall Grade: A+ (97/100)**

| Category | Score |
|----------|-------|
| Security | 98/100 |
| Backup/DR | 98/100 |
| Maintainability | 95/100 |
| Performance | 94/100 |
| Best Practices | 92/100 |
| Database | 90/100 |
| Infrastructure | 88/100 |

**Key facts**: 0 P0/P1. 40 NetworkPolicies. 51 SOPS secrets. 10 Kyverno policies (7 enforce, 3 audit, 0 violations). 100% PSS, NetworkPolicy, HSTS, SSO, image pinning coverage.

---

## APPS (18 total)

| App | OIDC/SSO | Notes |
|-----|----------|-------|
| Homepage | - | Dashboard |
| Uptime Kuma | - | Uptime monitoring, MySQL |
| Authentik | Provider | SSO Platform, PostgreSQL + Redis |
| AdGuard Home | - | DNS filtering |
| Stirling PDF | OIDC | PDF toolkit |
| HomeHub | - | Family dashboard, local only |
| Grafana | OIDC | Monitoring dashboard |
| Immich | OIDC | Photo management |
| Paperless-NGX | OIDC | Document management |
| Home Assistant | OIDC | Smart home, MariaDB |
| LinkWarden | OIDC | Bookmark manager + Meilisearch |
| Mealie | OIDC | Recipe manager |
| N8N | Enterprise | Automation (SSO needs Enterprise) |
| Audiobookshelf | OIDC | Audiobook library |
| Obsidian | - | CouchDB sync |
| PriceBuddy | - | Price tracking, MariaDB |
| SearXNG | - | Privacy search engine |
| Claude Telegram | - | AI assistant bot (Agent SDK), Telegram DM only |

---

## DATABASES

| Engine | Replicas | HA | Proxy | Key Apps |
|--------|----------|-----|-------|----------|
| PostgreSQL (CNPG) | 2 | Streaming replication | PgBouncer | Authentik, Immich, Paperless, Grafana, N8N, Mealie, LinkWarden, Audiobookshelf |
| MySQL (Percona) | 2 | Async replication | HAProxy | Home Assistant, Uptime Kuma, PriceBuddy |
| Redis | 1 | No (cache) | - | Authentik, Paperless, Immich |
| CouchDB | 1 | No (single user) | - | Obsidian sync |

---

## BACKUPS

- PG daily 3:00 AM, CouchDB 3:05 AM, PVC 3:10 AM, MySQL 3:15 AM (30-day retention)
- Replication 3:30 AM: worker-node-2 (SSH) → NAS (rsync daemon, 500GB limit)
- Validation: SHA256 + tar integrity + size + age, Telegram failure-only alerts

---

## MONITORING

- **VictoriaMetrics**: VMSingle + VMAgent + VMOperator, ~113k series, ~487Mi total (71% RAM savings vs Prometheus)
- **Grafana**: Dashboards + OIDC
- **Loki + Alloy**: Log aggregation (DaemonSet)
- **Alertmanager**: Telegram notifications
- **Popeye**: Weekly CronJob (Sunday 6 AM), score 100/100
- **Kyverno**: Daily violation summaries

---

## EXTERNAL ACCESS

**Cloudflare Tunnel** (10 services): authentik, couchdb, audiobooks, linkwarden, stirling-pdf, mealie, paperless, immich, n8n, search
**Internal**: AdGuard Home local DNS, Traefik Ingress
**Domain**: h0melab.work

---

## STORAGE

- worker-node: 4.22TB LVM (2 NVMe SSDs), all 19 PVCs migrated
- worker-node-2: 863GB extra storage
- NAS: Zettlab 6 Ultra (14TB, 500GB backup limit)

---

## REBUILDERD (Arch Linux Contribution)

- worker-node: 6 CPU, 32GB RAM limit, 24/7
- worker-node-2: 4 CPU, 14GB RAM limit, 24/7
- Build timeout: 48h, Sunday 08:00 cleanup timer

---

## PENDING ITEMS

| Item | Target | Priority |
|------|--------|----------|
| Remove worker-node-2 replication step | ~May 20, 2026 | P2 |
| n8n PgBouncer `statement_timeout` fix — re-check #25705 | May 2026 | P3 |
| High-priority secret rotation (PG: authentik/immich/n8n, MySQL: HA, Redis: immich) | 2026-07-01 | P1 |
| Re-evaluate HA OIDC when hass-oidc-auth stable releases | Backlog | P3 |
| Add PodDisruptionBudgets for HA workloads | Backlog | P3 |
| Migrate existing node cleanup cron/timer jobs to `node-maintenance` user ownership (after node auto-update PR merges) | Backlog | P3 |

**Next Review**: 2026-05-04 (Monthly)

---

## CHANGELOG

*Monthly reviews, detailed changelog, completed items: [HOMELAB_HISTORY.md](./HOMELAB_HISTORY.md) and `git log --all -- docs/HOMELAB_ANALYSIS.md`*

**Recent highlights** (2026):
- 2026-04-18: Automated weekly node updates deployed — Sat 04:30 UTC, Ansible-driven, dedicated node-maintenance user, SOPS-encrypted SSH key, Telegram notifications
- 2026-04-13: All 3 nodes → zsh + chezmoi dotfiles (portable .zshrc template, modern CLI tools)
- 2026-04-11: Claude Telegram bot deployed (Agent SDK, fork of linuz90/claude-telegram-bot)
- 2026-04-09: VictoriaMetrics migration (71% RAM savings)
- 2026-04-02: April monthly review, full secrets rotation
- 2026-03-16: SearXNG deployment, Authentik-CF Access IdP integration
- 2026-03-11: NetworkPolicy K8s API egress audit (fixed Loki, Traefik, Homepage)
- 2026-03-09: Unified setup-node.sh, comprehensive node audit
- 2026-03-07: March code review (94/100), 4 new NetworkPolicies