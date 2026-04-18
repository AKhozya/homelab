# HOMELAB COMPREHENSIVE ANALYSIS

**Cluster**: K3s (staging) - **3 nodes** (1 control-plane, 2 workers)
**Node IPs** (static DHCP): gmk-k3s-control-plane=192.168.1.127, worker-node=192.168.1.129, worker-node-2=192.168.1.126
**Infrastructure**: GitOps (Flux), CloudNativePG, Percona MySQL, Monitoring Stack, SSO (Authentik), Cloudflare Tunnel
**Code Review**: 2026-04-02 - Full codebase scan (94/100, A)

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

**Key facts**: 0 P0/P1. 40 NetworkPolicies. 51 SOPS secrets. 10 Kyverno policies (7 enforce, 3 audit, 0 violations). 100% PSS, NetworkPolicy, HSTS, SSO, image pin coverage.

---

## APPS (18 total)

| App | OIDC/SSO | Notes |
|-----|----------|-------|
| Homepage | - | Dashboard |
| Uptime Kuma | - | Uptime monitor, MySQL |
| Authentik | Provider | SSO platform, PostgreSQL + Redis |
| AdGuard Home | - | DNS filter |
| Stirling PDF | OIDC | PDF toolkit |
| HomeHub | - | Family dashboard, local only |
| Grafana | OIDC | Monitoring dashboard |
| Immich | OIDC | Photo mgmt |
| Paperless-NGX | OIDC | Doc mgmt |
| Home Assistant | OIDC | Smart home, MariaDB |
| LinkWarden | OIDC | Bookmarks + Meilisearch |
| Mealie | OIDC | Recipes |
| N8N | Enterprise | Automation (SSO needs Enterprise) |
| Audiobookshelf | OIDC | Audiobook library |
| Obsidian | - | CouchDB sync |
| PriceBuddy | - | Price track, MariaDB |
| SearXNG | - | Privacy search |
| Claude Telegram | - | AI bot (Agent SDK), Telegram DM only |

---

## DATABASES

| Engine | Replicas | HA | Proxy | Key Apps |
|--------|----------|-----|-------|----------|
| PostgreSQL (CNPG) | 2 | Streaming repl | PgBouncer | Authentik, Immich, Paperless, Grafana, N8N, Mealie, LinkWarden, Audiobookshelf |
| MySQL (Percona) | 2 | Async repl | HAProxy | Home Assistant, Uptime Kuma, PriceBuddy |
| Redis | 1 | No (cache) | - | Authentik, Paperless, Immich |
| CouchDB | 1 | No (single user) | - | Obsidian sync |

---

## BACKUPS

- PG 3:00 AM, CouchDB 3:05 AM, PVC 3:10 AM, MySQL 3:15 AM (30-day retention)
- Replication 3:30 AM: worker-node-2 (SSH) → NAS (rsync daemon, 500GB cap)
- Validate: SHA256 + tar integrity + size + age, Telegram failure-only alerts

---

## MONITORING

- **VictoriaMetrics**: VMSingle + VMAgent + VMOperator, ~113k series, ~487Mi total (71% RAM save vs Prometheus)
- **Grafana**: Dashboards + OIDC
- **Loki + Alloy**: Log aggregation (DaemonSet)
- **Alertmanager**: Telegram alerts
- **Popeye**: Weekly CronJob (Sun 6 AM), score 100/100
- **Kyverno**: Daily violation summaries

---

## EXTERNAL ACCESS

**Cloudflare Tunnel** (10 services): authentik, couchdb, audiobooks, linkwarden, stirling-pdf, mealie, paperless, immich, n8n, search
**Internal**: AdGuard Home local DNS, Traefik Ingress
**Domain**: h0melab.work

---

## STORAGE

- worker-node: 4.22TB LVM (2 NVMe SSDs), all 19 PVCs migrated
- worker-node-2: 863GB extra
- NAS: Zettlab 6 Ultra (14TB, 500GB backup cap)

---

## REBUILDERD (Arch Linux Contribution)

- worker-node: 6 CPU, 32GB RAM cap, 24/7
- worker-node-2: 4 CPU, 14GB RAM cap, 24/7
- Build timeout: 48h, Sun 08:00 cleanup timer

---

## PENDING ITEMS

| Item | Target | Priority |
|------|--------|----------|
| Drop worker-node-2 replication step | ~May 20, 2026 | P2 |
| n8n PgBouncer `statement_timeout` fix — re-check #25705 | May 2026 | P3 |
| High-pri secret rotation (PG: authentik/immich/n8n, MySQL: HA, Redis: immich) | 2026-07-01 | P1 |
| Re-check HA OIDC when hass-oidc-auth stable lands | Backlog | P3 |

**Next Review**: 2026-05-04 (Monthly)

---

## CHANGELOG

*Monthly reviews, full changelog, done items: [HOMELAB_HISTORY.md](./HOMELAB_HISTORY.md) and `git log --all -- docs/HOMELAB_ANALYSIS.md`*

**Recent highlights** (2026):
- 2026-04-18: PodDisruptionBudgets added for 9 HA workloads (authentik server/worker, traefik, cloudflared, main-postgres-rw-pooler, main-mysql-haproxy, main-mysql-orc, couchdb, alertmanager). `minAvailable: 1` for 2-replica; `maxUnavailable: 1` for 3-replica (orc). CNPG/Percona/Kyverno operator-managed PDBs already covered primary pods
- 2026-04-18: Node cron/timer audit — no migration candidates. k3s-image-gc (crictl/CRI socket), logrotate (root-owned paths), repro-cleanup (rebuilderd nspawn data) all genuinely need root; rebuilderd-* already run as rebuilderd user. No plain cron anywhere. P3 item closed
- 2026-04-18: Logrotate + journald caps rollout (all 3 nodes) — `logrotate` pkg installed, `logrotate.timer` enabled, `/var/log/pacman.log` + `/var/log/node-maintenance/*` + `/var/log/security-tools/*` rotated monthly/weekly, journald drop-in `99-caps.conf` (SystemMaxUse=500M, MaxRetentionSec=30d, Compress=yes)
- 2026-04-18: Node-maintenance observability (F2/F3/F4) — Alloy `loki.source.journal` ingests `node-maintenance-phase{1,2}.service` + sync.service logs (Loki hostPath /run/log/journal + /etc/machine-id, loki ns PSS enforce=privileged); Grafana dashboard (7 panels, VM + Loki); `NodeMaintenanceMissedRun` VMRule alert (>8d threshold)
- 2026-04-18: Node-maintenance E2E stabilized — silence add/expire via `amtool` (bundled in Alertmanager pod, busybox wget lacked `--method=DELETE`); ExecStopPost fixed ($SERVICE_RESULT != "success" vs broken $EXIT_STATUS); `ansible_facts['*']` swap (ansible-core 2.24 prep); ansible.cfg enforces `inject_facts_as_vars=False`
- 2026-04-18: Weekly node auto-updates live — Sat 04:30 UTC, Ansible-driven, dedicated node-maintenance user, SOPS-encrypted SSH key, Telegram alerts. Live-tested full run (all 3 nodes); next fire 2026-04-25
- 2026-04-18: Node-maintenance auto-sync online — systemd timer on CP (`*:0/10`), pulls `main` via read-only GitHub deploy key (`/root/.ssh/homelab-deploy`), runs `install.sh --sync-only` if HEAD changed, Telegram alert on fail. Manual trigger: `sync-node-maintenance.sh`
- 2026-04-13: All 3 nodes → zsh + chezmoi dotfiles (portable .zshrc template, modern CLI tools)
- 2026-04-11: Claude Telegram bot live (Agent SDK, fork of linuz90/claude-telegram-bot)
- 2026-04-09: VictoriaMetrics migration (71% RAM save)
- 2026-04-02: April monthly review, full secrets rotation
- 2026-03-16: SearXNG deploy, Authentik-CF Access IdP integration
- 2026-03-11: NetworkPolicy K8s API egress audit (fixed Loki, Traefik, Homepage)
- 2026-03-09: Unified setup-node.sh, full node audit
- 2026-03-07: March code review (94/100), 4 new NetworkPolicies