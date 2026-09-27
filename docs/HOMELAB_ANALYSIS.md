# System Overview

A snapshot of what runs in the cluster and how it's postured. For *why* it's built this way see [ARCHITECTURE.md](ARCHITECTURE.md); for the change log see [HOMELAB_HISTORY.md](HOMELAB_HISTORY.md); for per-subsystem structure see [subsystems/](subsystems/).

**Cluster:** K3s `v1.37.0+k3s1`, single-environment **production** (no staging — a merge to `main` deploys straight to prod), 4 Arch Linux nodes (1 control-plane + 2 workers + 1 GPU-worker VM `immich-vm` on the NAS, joined 2026-07-10, dedicated to Immich via a NoSchedule taint since 2026-09-06), static-DHCP IPv4.

## Platform facts

- **17** applications across **29** namespaces in git (33 live incl. k8s system namespaces)
- **68** NetworkPolicy resources live (54 raw manifests in git — operator- and component-generated policies make up the delta) — default-deny posture; presence enforced by Kyverno
- **12** Kyverno CEL `ValidatingPolicy` resources (policies.kyverno.io/v1) — **all Deny-enforcing**, sole policy engine since 2026-07-12 (kyverno.io/v1 ClusterPolicies deleted after 8-day parity soak; live admission attribution proven per-policy). `require-networkpolicy` matches controllers directly with autogen off (autogen rewrites void top-level-metadata checks)
- **58** SOPS-encrypted Secrets in git — no plaintext secret in Git
- **12** HelmReleases (live = git) — drift detection enabled, with targeted timeouts + rollback
- **3** PriorityClasses (critical / standard / batch) — every workload annotated
- Monthly image-CVE scan: the `trivy-scan` CronJob, on the 1st at 08:00 UTC (replaced the always-on trivy-operator 2026-07-14)
- **PSS:** 12 namespaces `restricted`, 10 `baseline`, 6 `privileged` (each justified — GPU, hostPath, host-network)

## Applications

The 17 apps, with namespace, storage, database, SSO and external access, are listed in [subsystems/apps.md](subsystems/apps.md). The claude-telegram bot's RBAC boundary, set 2026-08-06 (`apps/claude-telegram/rbac.yaml`):

| Access | Scope |
|---|---|
| read | cluster-wide |
| delete | `pods`, `replicasets`, PolicyReports, ClusterPolicyReports |
| `pods/exec` | 14 namespaces: not its own, and not the four with 0.0.0.0/0 egress |
| Job create and delete | `popeye` only |
| workload patch | none |
| node SSH | the read-only `agent-diag` forced command |

## Databases

| Engine | Replicas | HA | Proxy | Key apps |
|---|---|---|---|---|
| PostgreSQL (CloudNativePG) | 2 | Streaming replication | PgBouncer | Authentik, Blocky, Immich, Linkwarden, Mealie, n8n, Paperless |
| MySQL (Percona) | 2 | Async replication | HAProxy | Home Assistant, Uptime Kuma, PriceBuddy |
| Redis (OT-operator) | 1 master + 1 replica + 3 Sentinels | Sentinel quorum (2 of 3) | Static master Service (Sentinel-elected) | Paperless, Immich, Blocky |
| CouchDB | 2 | Active-active | — | Obsidian sync |

DB role name = app name. Postgres roles and databases come from CNPG (`managed.roles` in `cluster.yaml`, `Database` CRs). Percona has no user CRD: MySQL users come from SQL (`docs/disaster-recovery/mysql-create-dbs.sql` on a rebuild). Never drop a database by hand or force-delete a DB pod.

## Backups

- Per-engine logical dumps overnight: Postgres 03:00, CouchDB 03:05, PVCs 03:10, MySQL 03:15 — **30-day retention**.
- 03:30 replication CronJob on worker-node → NAS (rsync daemon :50555, 30-day history, 500 GB cap). W2 today-only safety leg removed 2026-07-17.
- **Immich library** (weekly, Sun 03:00 UTC): `immich-backup` on **worker-node-2** pulls the NAS-resident library (rsync `personal_folder` module) → tar+sha on W2 + push to the NAS `akhozya-pool1` pool = 2 physical copies on different filesystems, keep-2 each. (W1 `immich-library` PVC decommissioned 2026-07-14 — see HISTORY.)
- Every backup validated (SHA-256 + tar + size + age); failure-only Telegram alerts.

## Monitoring

- **VictoriaMetrics** — VMSingle + VMAgent + VMOperator; ~113k active series at ~487 MiB (git first records this figure on 2026-04-09; ≈71% RAM saving vs Prometheus on the same scrape set). Operator chart pinned ≥0.67.1 — 0.67.0 omitted a `networkpolicies` grant operator v0.74.0 needs on every reconcile, and without it the operator parks silently while looking healthy (2026-07-31, see HISTORY). Do not pin back to 0.67.0.
- **kube-prometheus-stack** — runs for Grafana, Alertmanager, kube-state-metrics and node-exporter only. `prometheus.enabled: false` and every VM prometheus-converter is off, so the chart's ServiceMonitors are inert and vmagent scrapes through the hand-written VMServiceScrapes in `monitoring/configs/`. Chart 90.0.0 refuses to render if an enabled control-plane component keeps its default `serviceMonitor.authorization` (2026-09-07, see HISTORY).
- **Grafana** — dashboards, OIDC login.
- **Loki + Grafana Alloy** — log aggregation (DaemonSet).
- **Alertmanager** — Telegram alerts.
- **Popeye** — weekly cluster-hygiene scan.
- **Kyverno** — `KyvernoAdmissionControllerDown` availability alert. There is no policy-violation digest: the `KyvernoPolicyViolationsDailySummary` VMRule this file used to claim does not exist in git or in the cluster.

## External access

- **Cloudflare Tunnel** fronts the internet-reachable apps (Authentik, CouchDB, Audiobookshelf, Linkwarden, Stirling-PDF, Mealie, Paperless, Immich, n8n) — outbound-initiated, so the router opens zero inbound ports.
- **Internal:** Blocky serves LAN-client DNS; Traefik terminates internal ingress. Cluster DNS is a `coredns-ha` DaemonSet behind `10.43.0.10`: one pod on each node except `immich-vm`, whose taint it does not tolerate.
- **Domain:** `h0melab.work` (TLS via cert-manager DNS-01).
- **WARP device profiles:** Zero Trust managed-network beacon at `192.168.1.129:18443` (LAN-only TLS endpoint, `apps/rustdesk/beacon-*`) auto-switches every enrolled device — home = "Home LAN - direct" (tunnel nothing), away = Default (tunneled `.129/32` for remote RustDesk).

## Storage

- worker-node: 4.22 TB LVM (2 NVMe SSDs) — hosts the bulk of app PVCs.
- worker-node-2: 863 GB extra storage.
- NAS: 15 TB pool (git first records this figure on 2026-07-13; the 500 GB figure is a soft self-limit inside the replication job, not a quota) — `zl-nas`, ZettLab/zettOS (Debian 12) at `192.168.1.136`. Out-of-cluster backup sink; admin SSH on `:56634` (key-based, sudo password-gated). The appliance itself is not a K3s node and not in ansible/k3s scope (the `immich-vm` K3s worker is a VM hosted on it).

Storage is node-local (`local-path-provisioner`) — no distributed storage layer by choice; durability comes from the backup chain, not replicated volumes.

## Maintenance

The cluster is reviewed monthly (security scans, policy reports, alert/backup/cert health, dependency freshness). The agent skills and rules that run these reviews are copied into [agents/](../agents/README.md), and the review runs `scripts/sync-agents.sh --check` to catch a stale copy. The full changelog lives in [HOMELAB_HISTORY.md](HOMELAB_HISTORY.md); every change is a commit, so `git log` is the audit trail.

Worker self-heal watchdogs: `clusterip_heal` (post-reboot kube-proxy DNAT wedge → k3s-agent restart) and `node_isolation_heal` (CP-isolation ladder — k3s-agent restart at 6 min, staggered self-reboot 15/23 min as last resort; **ACTIVE** since 2026-07-23 after a 13-day dry-run soak). Their k3s-agent restarts are flock-serialized via a shared cooldown; phase2 maintenance reboots set a worker-local hold so orchestrated reboots never count as isolation.

### Upcoming deadlines

Forward calendar of dated obligations. [SECRETS_ROTATION.md](SECRETS_ROTATION.md) is authoritative for rotation specifics; this table is the at-a-glance roll-up. Recurring timers (sync 10 min, drift-heal 03:00 and 15:00, weekly update Sat, security scan 1st) are not listed.

| Due | Item |
|---|---|
| unscheduled | Deferred: monitoring-ns Traefik middleware fork (necessary namespaced duplication — low priority); offsite backup (owner decision — accepted, documented-only) |
| monthly review | Upstream watches: n8n #25705 (workaround still required at 2.28.6, checked 2026-07-04), k8s-sidecar#531 (loki probes stay disabled), Stirling#6211 |
| 2026-10 (monthly review) | **Immich ML + immich-vm memory re-check.** The ML container serves clip, ocr and facial-recognition and caches each 300s, so size it for their sum: measured 2026-09-07 at 4984Mi with all three resident, limit 7Gi (`1034951d`). Sizing it from CLIP alone gave 5Gi and OOM-killed the gunicorn WORKER, which gunicorn respawns — `restartCount` stays 0, so `ContainerOOMKilled` never fires and OCR/face jobs just drop connections. Query `max_over_time` for the ML container working set and for immich-vm node memory (VMSingle per Phase 3), scoped to **after 2026-09-07**: a flat 30d window spans the CPU-path and 5Gi periods and the model swap, so its max describes a shape the cluster no longer runs. Decide: ML peak >80% of 7Gi → raise the limit; node peak sustained >80% of 11949Mi → bump the VM to 14Gi, which also clears the 113% limit overcommit (13338Mi of 11849Mi allocatable). Node was 6529Mi (55%) at the 2026-09-07 peak with 6.2Gi free, so neither is expected yet. A VM RAM change needs a host-side restart on the GPU-reset-bug machine — not free. Research: `docs/plans/2026-09-07-immich-ml-followups-research.md` |
| 2026-10-01 | 180-day secret rotation — ALL scheduled secrets: PG/MySQL/Redis, CouchDB, OIDC, Authentik Django key (90-day High tier retired 2026-07-02, ex-High folded in; Redis admin+blocky follow 2026-10-26) |
| 2026-12-31 | `cloudflare-tunnel-mgmt-token` rotation |
| 2027-01-30 | `gh-homelab` deploy key rotation (in the `claude-telegram-ssh` Secret). The only key the bot holds that can write to this repo, so a push with it is a deploy inside 5 min — 180 days, not the annual cadence the read-only deploy keys get |
