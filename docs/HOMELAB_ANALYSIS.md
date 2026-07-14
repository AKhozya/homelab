# System Overview

A snapshot of what runs in the cluster and how it's postured. For *why* it's built this way see [ARCHITECTURE.md](ARCHITECTURE.md); for the change log see [HOMELAB_HISTORY.md](HOMELAB_HISTORY.md); for per-subsystem structure see [CODEMAPS/](CODEMAPS/).

**Cluster:** K3s `v1.36.2+k3s1`, single-environment **production** (no staging — a merge to `main` deploys straight to prod), 4 Arch Linux nodes (1 control-plane + 2 workers + 1 GPU-worker VM `immich-vm` on the NAS, joined 2026-07-10), static-DHCP IPv4.

## Platform at a glance

| Area | Status |
|---|---|
| **Security** | Pod Security Standards enforced; 12 Kyverno CEL ValidatingPolicies (all Deny-enforcing); default-deny NetworkPolicies; secrets SOPS-encrypted in Git; monthly image-CVE scan (trivy CronJob, 1st 04:00 UTC — replaced always-on trivy-operator 2026-07-14) |
| **Backup / DR** | Daily logical backups (Postgres, MySQL, CouchDB, app PVCs), 30-day retention, off-node + NAS replication, documented restore runbook |
| **Observability** | VictoriaMetrics + Grafana + Loki/Alloy; Alertmanager → Telegram; weekly Popeye hygiene scan |
| **Networking** | Dual ingress (LAN Traefik + Cloudflare Tunnel), zero inbound ports, Blocky DNS + ad-block |
| **Automation** | Flux GitOps reconcile; Renovate dependency PRs; CI validation gate; ansible-driven node maintenance |
| **HA** | Postgres primary+replica, MySQL async replication, Redis Sentinel quorum, CouchDB active-active; single control-plane (deliberate — see ARCHITECTURE trade-offs) |

## Platform facts

- **16** applications across **28** namespaces in git (32 live incl. k8s system namespaces)
- **66** NetworkPolicy resources live (52 raw manifests in git — operator- and component-generated policies make up the delta) — default-deny posture; presence enforced by Kyverno
- **12** Kyverno CEL `ValidatingPolicy` resources (policies.kyverno.io/v1) — **all Deny-enforcing**, sole policy engine since 2026-07-12 (kyverno.io/v1 ClusterPolicies deleted after 8-day parity soak; live admission attribution proven per-policy). `require-networkpolicy` matches controllers directly with autogen off (autogen rewrites void top-level-metadata checks)
- **51** SOPS-encrypted secrets in git — no plaintext secret in Git
- **13** HelmReleases (live = git) — drift detection enabled, with targeted timeouts + rollback
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
| claude-telegram | — | Telegram bot bridge for ops (Claude engine + Codex review gate) |

## Databases

| Engine | Replicas | HA | Proxy | Key apps |
|---|---|---|---|---|
| PostgreSQL (CloudNativePG) | 2 | Streaming replication | PgBouncer | Authentik, Immich, Paperless, Grafana, n8n, Mealie, Linkwarden, Audiobookshelf |
| MySQL (Percona) | 2 | Async replication | HAProxy | Home Assistant, Uptime Kuma, PriceBuddy |
| Redis (OT-operator) | 1 master + 1 replica + 3 Sentinels | Sentinel quorum (2 of 3) | Static master Service (Sentinel-elected) | Paperless, Immich |
| CouchDB | 2 | Active-active | — | Obsidian sync |

DB role name = app name. Provisioning goes through the operator CRDs (CNPG `Database` / Percona `User`) — never direct SQL drops or force-deleted pods.

## Backups

- Per-engine logical dumps overnight: Postgres 03:00, CouchDB 03:05, PVCs 03:10, MySQL 03:15 — **30-day retention**.
- 03:30 replication CronJob on worker-node — fan-out: → NAS (rsync daemon :50555, 30-day history, 500 GB cap) AND → worker-node-2 (today-only safety copy, removal ~2026-07-20).
- **Immich library** (weekly, Sun 03:00 UTC): `immich-backup` on **worker-node-2** pulls the NAS-resident library (rsync `personal_folder` module) → tar+sha on W2 + push to the NAS `akhozya-pool1` pool = 2 physical copies on different filesystems, keep-2 each. (W1 `immich-library` PVC decommissioned 2026-07-14 — see HISTORY.)
- Every backup validated (SHA-256 + tar + size + age); failure-only Telegram alerts.

## Monitoring

- **VictoriaMetrics** — VMSingle + VMAgent + VMOperator; ~113k active series at ~487 MiB (≈71% RAM saving vs Prometheus on the same scrape set).
- **Grafana** — dashboards, OIDC login.
- **Loki + Grafana Alloy** — log aggregation (DaemonSet).
- **Alertmanager** — Telegram alerts.
- **Popeye** — weekly cluster-hygiene scan.
- **Kyverno** — daily policy-violation digest via `KyvernoPolicyViolationsDailySummary` VMRule (no CronJob).

## External access

- **Cloudflare Tunnel** fronts the internet-reachable apps (Authentik, CouchDB, Audiobookshelf, Linkwarden, Stirling-PDF, Mealie, Paperless, Immich, n8n) — outbound-initiated, so the router opens zero inbound ports.
- **Internal:** Blocky serves LAN-client DNS; Traefik terminates internal ingress. Cluster DNS is a `coredns-ha` DaemonSet (1 replica/node) behind `10.43.0.10`.
- **Domain:** `h0melab.work` (TLS via cert-manager DNS-01).

## Storage

- worker-node: 4.22 TB LVM (2 NVMe SSDs) — hosts the bulk of app PVCs.
- worker-node-2: 863 GB extra storage.
- NAS: 15 TB pool (the 500 GB figure is a soft self-limit inside the replication job, not a quota) — `zl-nas`, ZettLab/zettOS (Debian 12) at `192.168.1.136`. Out-of-cluster backup sink; admin SSH on `:56634` (key-based, sudo password-gated). The appliance itself is not a K3s node and not in ansible/k3s scope (the `immich-vm` K3s worker is a VM hosted on it).

Storage is node-local (`local-path-provisioner`) — no distributed storage layer by choice; durability comes from the backup chain, not replicated volumes.

## Maintenance

The cluster is reviewed monthly (security scans, policy reports, alert/backup/cert health, dependency freshness). The full changelog lives in [HOMELAB_HISTORY.md](HOMELAB_HISTORY.md); every change is a commit, so `git log` is the audit trail.

### Upcoming deadlines

Forward calendar of dated obligations. [SECRETS_ROTATION.md](SECRETS_ROTATION.md) is authoritative for rotation specifics; this table is the at-a-glance roll-up. Recurring timers (sync 10 min, drift-heal 03:00, weekly update Sat, security scan 1st) are not listed.

| Due | Item |
|---|---|
| ~~2026-07-14~~ ✅ | Immich Path-B follow-up (T7) DONE 2026-07-14 (`4628800d` + `a32f6ef8`): backup re-topology (immich-backup → W2 producer, pulls NAS library → tar on W2 + NAS `akhozya-pool1` pool, keep-2 each; Codex 3 rounds) + W1 `immich-library` PVC decommissioned (PV `pvc-495129ee` + 61G reclaimed via local-path Delete). Gate: live 60.6G tar, NAS-pool `sha256 -c` OK. Soak waived ~40h/48h (repoint reversible, touches only backup cronjob). See HISTORY |
| ~~2026-07-04~~ ✅ | Monthly review + quarterly automation audit DONE 2026-07-04 (see HISTORY). Watches CLOSED: Authentik client-hints (2026.5.3 live), passkey lockout, UR2 vmalert, mysql-proxy POP-1100/1110 (accepted cosmetic). Still watched monthly: n8n #25705 (workaround PROVEN still required at 2.28.6), k8s-sidecar#531 (loki probes stay disabled), Stirling#6211 |
| ~~2026-07-05~~ ✅ | immich-backup Sunday slot VERIFIED firing — `lastSuccessfulTime 2026-07-12T03:07Z` (closed 2026-07-12) |
| ~~2026-07-08~~ ✅ | security-scan ExecStopPost failure-notify SHIPPED 2026-07-12 (`89cd65b3`): missing lynis/rkhunter now exit 1, unit ExecStopPost fires telegram-notify on any failure, script+creds distributed to workers via security_scan role (was CP-only — every worker notify path silently dead). Node-side apply at drift-heal 03:00 UTC, verify next day. trivy soak CLOSED 2026-07-10 (#2859 cache-lock churn benign, concurrency 2→1) |
| 2026-07 (unscheduled) | Remaining deferred: monitoring-ns Traefik middleware fork (necessary namespaced duplication — low priority); offsite backup (owner decision — accepted, documented-only). **Done 2026-07-03** (main `d771464d`): Percona `crVersion`→1.2.0 (SmartUpdate roll, matched operator chart already at 1.2.0); ClusterIssuer→`letsencrypt-prod` (16 certs re-issued, was already prod ACME); Redis/CouchDB instance CRs → configs layer (gapless prune:disabled move); csp-reporter GC'd — see HISTORY |
| ~~2026-07-06~~ ✅ | Resource right-sizing pass DONE 2026-07-12 (`d4d21e18` + `6cd4c036`): 12 workloads' requests raised to 7d p95 (stirling-pdf 1408Mi, n8n 448Mi, blocky 256Mi, apprise 224Mi, paperless 704Mi, trivy-operator 640Mi, vmsingle 768Mi, vm-operator 160Mi; mysql 896Mi, orchestrator/haproxy cpu 160m, sentinel cpu 50m). Named candidates closed earlier: reports-controller limit 300m→500m + redis-operator 400m (`c214e0cd` 2026-07-04). immich excluded (Path B soak to ~07-14). Residual CLOSED 2026-07-13: reports-controller avg throttle 56.6%→10.6% post-VP-migration, but hourly scan spikes still max 48% ≥ gate 25% → limits.cpu 500m→800m. Chronic burst-throttlers (authentik-worker 37%, redis-replication-master 32%, claude-telegram 30%) = pre-existing 7d baseline, p95 usage ≪ limit — cosmetic, no action |
| ~2026-07-20 | Worker-2 backup replication-step drop / temp safety-net removal (postponed +2mo from 2026-05-22) |
| ~~≥2026-07-11~~ ✅ | Kyverno CP→VP migration **Phases 2-4 DONE 2026-07-12** (`abf5d2c5` Deny flip → CP delete → `fc45be04` canary+parity retire): 8-day parity soak clean, Gate A (canary dry-run deny) + Gate B (per-policy live admission, 12/12 attributed despite fine-grained webhook short-circuit / PSA / LimitRange interplay) passed. Codex catch: autogen rewrites `object.metadata` to pod-template path, voiding deletionTimestamp checks — `require-networkpolicy` now direct controller match + autogen off. See HISTORY 2026-07-12 |
| ~~2026-10~~ ✅ | `kyverno.io/v1` ClusterPolicy removal deadline (Kyverno 1.20, ~Oct 2026) MET EARLY 2026-07-12 — zero ClusterPolicies remain; kyverno chart bumps shipping 1.20 no longer held |
| 2026-10-01 | 180-day secret rotation — ALL scheduled secrets: PG/MySQL/Redis, CouchDB, OIDC, Authentik Django key (90-day High tier retired 2026-07-02, ex-High folded in; Redis admin+blocky follow 2026-10-26) |
| 2026-12-18 | `backup-replication-ssh` key rotation |
| 2026-12-31 | `cloudflare-tunnel-mgmt-token` rotation |
