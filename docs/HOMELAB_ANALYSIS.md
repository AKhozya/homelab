# System Overview

A snapshot of what runs in the cluster and how it's postured. For *why* it's built this way see [ARCHITECTURE.md](ARCHITECTURE.md); for the change log see [HOMELAB_HISTORY.md](HOMELAB_HISTORY.md); for per-subsystem structure see [subsystems/](subsystems/).

**Cluster:** K3s `v1.37.0+k3s1`, single-environment **production** (no staging — a merge to `main` deploys straight to prod), 4 Arch Linux nodes (1 control-plane + 2 workers + 1 GPU-worker VM `immich-vm` on the NAS, joined 2026-07-10, dedicated to Immich via a NoSchedule taint since 2026-09-06), static-DHCP IPv4.

## Platform facts

- **17** applications across **29** namespaces in git (33 live incl. k8s system namespaces)
- **68** NetworkPolicy resources live (54 raw manifests in git — operator- and component-generated policies make up the delta) — default-deny posture; presence enforced by Kyverno
- **12** Kyverno CEL `ValidatingPolicy` resources (policies.kyverno.io/v1) — **all Deny-enforcing**, sole policy engine since 2026-07-12 (kyverno.io/v1 ClusterPolicies deleted after 8-day parity soak; live admission attribution proven per-policy). `require-networkpolicy` matches controllers directly with autogen off (autogen rewrites void top-level-metadata checks)
- **59** SOPS-encrypted Secrets in git — no plaintext secret in Git
- **12** HelmReleases (live = git) — drift detection enabled, with targeted timeouts; rollback on all but immich, which retries a failed upgrade (RetryOnFailure) because rollback cannot reverse its DB migrations
- **3** PriorityClasses (critical / standard / batch) — every workload annotated except `rustdesk`, `warp-beacon` and the `intel-gpu-plugin` DaemonSet (live, 2026-09-28)
- Monthly image-CVE scan: the `trivy-scan` CronJob, on the 1st at 08:00 UTC (replaced the always-on trivy-operator 2026-07-14)
- **PSS:** 12 namespaces `restricted`, 10 `baseline`, 6 `privileged` (each justified — GPU, hostPath, host-network)

## Applications

The 17 apps, with namespace, storage, database, SSO and external access, are listed in [subsystems/apps.md](subsystems/apps.md). The claude-telegram bot's RBAC boundary, set 2026-08-06 (`apps/claude-telegram/rbac.yaml`):

| Access | Scope |
|---|---|
| read | cluster-wide |
| delete | `pods`, `replicasets`, PolicyReports, ClusterPolicyReports |
| `pods/exec` | 13 namespaces: not its own, not `monitoring`, and not backup-replication, n8n, trivy-scan or home-assistant, because the bot made no exec calls there. Egress is not the boundary (`infrastructure/configs/claude-telegram-rbac/rolebindings.yaml`) |
| `services/proxy` `get` | `monitoring`: vmsingle, vmalert and Alertmanager only |
| Job create and delete | `popeye` only |
| workload patch | none |
| node SSH | the read-only `agent-diag` forced command |

## Databases

| Engine | Replicas | HA | Proxy | Key apps |
|---|---|---|---|---|
| PostgreSQL (CloudNativePG) | 2 | Streaming replication | PgBouncer for Linkwarden, Mealie, n8n and Paperless; Immich, Authentik and Blocky connect directly | Authentik, Blocky, Immich, Linkwarden, Mealie, n8n, Paperless |
| MySQL (Percona) | 2 | Async replication | HAProxy | Home Assistant, Uptime Kuma, PriceBuddy |
| Redis (OT-operator) | 1 master + 1 replica + 3 Sentinels | Sentinel quorum (2 of 3) | Static master Service (Sentinel-elected) | Paperless, Immich, Blocky |
| CouchDB | 2 | Active-active | — | Obsidian sync |

DB role name = app name. Postgres roles and databases come from CNPG (`managed.roles` in `cluster.yaml`, `Database` CRs). Percona has no user CRD: MySQL users come from SQL (`docs/disaster-recovery/mysql-create-dbs.sql` on a rebuild). Never drop a database by hand or force-delete a DB pod.

## Backups

- Per-engine logical dumps overnight: Postgres 03:00, CouchDB 03:05, PVCs 03:10, MySQL 03:15. The NAS keeps **30 days**; the nodes run no local age sweep.
- 03:30 replication CronJob on worker-node → NAS (rsync daemon :50555, 30-day history, 500 GB cap). W2 today-only safety leg removed 2026-07-17.
- **Immich library** (weekly, Sun 03:00 UTC): `immich-backup` on **worker-node-2** pulls the NAS-resident library (rsync `personal_folder` module) → tar+sha on W2 + push to the NAS `akhozya-pool1` pool = 2 physical copies on different filesystems, keep-2 each. (W1 `immich-library` PVC decommissioned 2026-07-14, commit `a32f6ef8`.)
- Replication validates all 17 artifacts every night (3 DB dumps, 14 PVC archives: SHA-256 + tar + size + age). If one type fails, the other types still reach the NAS, the failed type stays on worker-node, and the Job fails. `PVC_EXPECTED=14` in backup-replication must match `CRITICAL_PVCS` in pvc-backup. backup-replication and pvc-backup run once, with no retry (`54b4069a`, `dca36ccf`). Telegram alerts go out on failure only.

## Monitoring

- **VictoriaMetrics** — VMSingle + VMAgent + VMOperator; ~113k active series at ~487 MiB (git first records this figure on 2026-04-09; ≈71% RAM saving vs Prometheus on the same scrape set). Operator chart pinned ≥0.67.1 — 0.67.0 omitted a `networkpolicies` grant operator v0.74.0 needs on every reconcile, and without it the operator parks silently while looking healthy (2026-07-31, commit `63c456a2`). Do not pin back to 0.67.0.
- **kube-prometheus-stack** — runs for Grafana, Alertmanager, kube-state-metrics and node-exporter only. `prometheus.enabled: false` and every VM prometheus-converter is off, so the chart's ServiceMonitors are inert and vmagent scrapes through the hand-written VMServiceScrapes in `monitoring/configs/`. Chart 90.0.0 refuses to render if an enabled control-plane component keeps its default `serviceMonitor.authorization` (2026-09-07, commit `b46d0803`).
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

The cluster is reviewed monthly (security scans, policy reports, alert/backup/cert health, dependency freshness). The agent skills and rules that run these reviews are copied into [agents/](../agents/README.md), and the review runs `scripts/sync-agents.sh --check` to catch a stale copy. [HOMELAB_HISTORY.md](HOMELAB_HISTORY.md) holds the last three months of changes; every change is a commit, so `git log` is the full audit trail.

Worker self-heal watchdogs: `clusterip_heal` (post-reboot kube-proxy DNAT wedge → k3s-agent restart) and `node_isolation_heal` (CP-isolation ladder — k3s-agent restart at 6 min, staggered self-reboot 15/23 min as last resort; **ACTIVE** since 2026-07-23 after a 13-day dry-run soak). Their k3s-agent restarts are flock-serialized via a shared cooldown; phase2 maintenance reboots set a worker-local hold so orchestrated reboots never count as isolation.

### Upcoming deadlines

Forward calendar of dated obligations. [SECRETS_ROTATION.md](SECRETS_ROTATION.md) is authoritative for rotation specifics; this table is the at-a-glance roll-up. Recurring timers (sync 10 min, drift-heal 03:00 and 15:00, weekly update Sat, security scan 1st) are not listed.

| Due | Item |
|---|---|
| unscheduled | Deferred: monitoring-ns Traefik middleware fork (necessary namespaced duplication — low priority); offsite backup (owner decision — accepted, documented-only); the SP5 carried-forward items: the control-plane first-start drill, the sshd drop-in rename ([plan, SP5](plans/2026-09-26-open-source-prep.md)) |
| monthly review | Upstream watches: n8n PR #27295 (sets `statement_timeout` with `SET`; issue #25705 closed 2026-07-14 but the PR is unmerged, so `DB_POSTGRESDB_STATEMENT_TIMEOUT=0` stays), Stirling#6211 (open; re-measure memory on 3.0.2, deployed 2026-10-02) |
| 2026-11 (monthly review) | Fix: the heal-watchdog alerts fire on `==1` only, so they miss a dead script |
| 2026-11 (monthly review) | Re-measure Stirling memory on 3.0.2 (Stirling#6211) |
| 2026-10-31 | First certificate renewals with the Cloudflare token rotated 2026-09-28 (`52ce08aa`). After that date, `kubectl get certificates -A -o json \| jq -r '[.items[].status.notAfter] \| min'` must print a date later than `2026-11-30T20:27:49Z`, every certificate must be `True`, and `kubectl get challenges -A` must find none. If the earliest date has not moved, renewal did not happen and the token is not yet proven: read the cert-manager log and the Certificate, Order and Challenge events before blaming the token |
| 2026-12-31 | `cloudflare-tunnel-mgmt-token` rotation |
| 2027-01-30 | `gh-homelab` deploy key rotation (in the `claude-telegram-ssh` Secret). The only key the bot holds that can write to this repo, so a push with it is a deploy inside 5 min — 180 days, not the annual cadence the read-only deploy keys get |
| 2027-03-31 | 180-day secret rotation — every row in SECRETS_ROTATION.md that shows 2027-03-31 (the 2026-10-02 batch). Run it with the `secrets-rotation` skill. Blocky's PostgreSQL user keeps its own date (2026-12-05) |
