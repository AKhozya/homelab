# System Overview

A snapshot of what runs in the cluster and how it's postured. For *why* it's built this way see [ARCHITECTURE.md](ARCHITECTURE.md); for the change log see [HOMELAB_HISTORY.md](HOMELAB_HISTORY.md); for per-subsystem structure see [CODEMAPS/](CODEMAPS/).

**Cluster:** K3s `v1.37.0+k3s1`, single-environment **production** (no staging — a merge to `main` deploys straight to prod), 4 Arch Linux nodes (1 control-plane + 2 workers + 1 GPU-worker VM `immich-vm` on the NAS, joined 2026-07-10, dedicated to Immich via a NoSchedule taint since 2026-09-06), static-DHCP IPv4.

## Platform at a glance

| Area | Status |
|---|---|
| **Security** | Pod Security Standards enforced; 12 Kyverno CEL ValidatingPolicies (all Deny-enforcing); default-deny NetworkPolicies; secrets SOPS-encrypted in Git; monthly image-CVE scan (trivy CronJob, 08:00 UTC — 8th for August 2026, back to the 1st after; replaced always-on trivy-operator 2026-07-14) |
| **Backup / DR** | Daily logical backups (Postgres, MySQL, CouchDB, app PVCs), 30-day retention, off-node + NAS replication, documented restore runbook |
| **Observability** | VictoriaMetrics + Grafana + Loki/Alloy; Alertmanager → Telegram; weekly Popeye hygiene scan |
| **Networking** | Dual ingress (LAN Traefik + Cloudflare Tunnel), zero inbound ports, Blocky DNS + ad-block |
| **Automation** | Flux GitOps reconcile; Renovate dependency PRs; CI validation (signal, not a merge gate — branch protection unavailable on the Free plan); ansible-driven node maintenance |
| **HA** | Postgres primary+replica, MySQL async replication, Redis Sentinel quorum, CouchDB active-active; single control-plane (deliberate — see ARCHITECTURE trade-offs) |

## Platform facts

- **17** applications across **29** namespaces in git (33 live incl. k8s system namespaces)
- **66** NetworkPolicy resources live (52 raw manifests in git — operator- and component-generated policies make up the delta) — default-deny posture; presence enforced by Kyverno
- **12** Kyverno CEL `ValidatingPolicy` resources (policies.kyverno.io/v1) — **all Deny-enforcing**, sole policy engine since 2026-07-12 (kyverno.io/v1 ClusterPolicies deleted after 8-day parity soak; live admission attribution proven per-policy). `require-networkpolicy` matches controllers directly with autogen off (autogen rewrites void top-level-metadata checks)
- **51** SOPS-encrypted secrets in git — no plaintext secret in Git
- **13** HelmReleases (live = git) — drift detection enabled, with targeted timeouts + rollback
- **3** PriorityClasses (critical / standard / batch) — every workload annotated
- **PSS:** 12 namespaces `restricted`, 9 `baseline`, 6 `privileged` (each justified — GPU, hostPath, host-network)

## Applications (17)

> Grafana is monitoring infrastructure, not a listed app.

| App | SSO | Notes |
|---|---|---|
| Authentik | Provider | Identity provider; PostgreSQL backend; passkey-first login |
| Home Assistant | OIDC | Smart home; MySQL |
| Immich | OIDC | Photo & video management; Intel QSV transcoding and OpenVINO ML inference on the immich-vm iGPU |
| Audiobookshelf | OIDC | Audiobook & podcast library |
| Paperless-NGX | OIDC | Document archive with OCR |
| Linkwarden | OIDC | Bookmarks + Meilisearch |
| Mealie | OIDC | Recipe manager |
| n8n | — | Workflow automation; native user management (n8n SSO is an Enterprise feature) |
| Stirling-PDF | OIDC | PDF toolkit |
| Homepage | Forward-auth | Services dashboard; Authentik proxy provider on the embedded outpost, not OIDC |
| HomeHub | — | Family start page (LAN only) |
| Obsidian | — | Notes sync (CouchDB LiveSync) |
| Uptime Kuma | — | Uptime monitor; MySQL |
| PriceBuddy | — | Price tracker; MySQL |
| Blocky | — | DNS resolver + ad-block; HA (2 replicas, W1+W2); serves LAN clients only |
| claude-telegram | — | Telegram bot bridge for ops (Claude engine + Codex review gate). RBAC boundary as of 2026-08-06: cluster-wide READ plus `pods`/`replicasets` delete; `pods/exec` in 14 namespaces (not its own, and not the four with 0.0.0.0/0 egress); Job creation in `popeye` only; **no workload patch anywhere**. Node SSH is the `agent-diag` forced command, read-only. Since 1.32.0 (2026-08-07): livenessProbe = poll-heartbeat freshness (wedged poller self-heals ~13min) and console output redacts the bot/trigger/OAuth secrets |
| RustDesk | — | Self-hosted remote desktop relay (hbbs + hbbr); LAN-only on the W1 LoadBalancer, deny-all egress |

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
- 03:30 replication CronJob on worker-node → NAS (rsync daemon :50555, 30-day history, 500 GB cap). W2 today-only safety leg removed 2026-07-17.
- **Immich library** (weekly, Sun 03:00 UTC): `immich-backup` on **worker-node-2** pulls the NAS-resident library (rsync `personal_folder` module) → tar+sha on W2 + push to the NAS `akhozya-pool1` pool = 2 physical copies on different filesystems, keep-2 each. (W1 `immich-library` PVC decommissioned 2026-07-14 — see HISTORY.)
- Every backup validated (SHA-256 + tar + size + age); failure-only Telegram alerts.

## Monitoring

- **VictoriaMetrics** — VMSingle + VMAgent + VMOperator; ~113k active series at ~487 MiB (≈71% RAM saving vs Prometheus on the same scrape set). Operator chart pinned ≥0.67.1 — 0.67.0 omitted a `networkpolicies` grant operator v0.74.0 needs on every reconcile, and without it the operator parks silently while looking healthy (2026-07-31, see HISTORY). Do not pin back to 0.67.0.
- **kube-prometheus-stack** — runs for Grafana, Alertmanager, kube-state-metrics and node-exporter only. `prometheus.enabled: false` and every VM prometheus-converter is off, so the chart's ServiceMonitors are inert and vmagent scrapes through the hand-written VMServiceScrapes in `monitoring/configs/`. Chart 90.0.0 refuses to render if an enabled control-plane component keeps its default `serviceMonitor.authorization` (2026-09-07, see HISTORY).
- **Grafana** — dashboards, OIDC login.
- **Loki + Grafana Alloy** — log aggregation (DaemonSet).
- **Alertmanager** — Telegram alerts.
- **Popeye** — weekly cluster-hygiene scan.
- **Kyverno** — `KyvernoAdmissionControllerDown` availability alert. There is no policy-violation digest: the `KyvernoPolicyViolationsDailySummary` VMRule this file used to claim does not exist in git or in the cluster.

## External access

- **Cloudflare Tunnel** fronts the internet-reachable apps (Authentik, CouchDB, Audiobookshelf, Linkwarden, Stirling-PDF, Mealie, Paperless, Immich, n8n) — outbound-initiated, so the router opens zero inbound ports.
- **Internal:** Blocky serves LAN-client DNS; Traefik terminates internal ingress. Cluster DNS is a `coredns-ha` DaemonSet (1 replica/node) behind `10.43.0.10`.
- **Domain:** `h0melab.work` (TLS via cert-manager DNS-01).
- **WARP device profiles:** Zero Trust managed-network beacon at `192.168.1.129:18443` (LAN-only TLS endpoint, `apps/rustdesk/beacon-*`) auto-switches every enrolled device — home = "Home LAN - direct" (tunnel nothing), away = Default (tunneled `.129/32` for remote RustDesk).

## Storage

- worker-node: 4.22 TB LVM (2 NVMe SSDs) — hosts the bulk of app PVCs.
- worker-node-2: 863 GB extra storage.
- NAS: 15 TB pool (the 500 GB figure is a soft self-limit inside the replication job, not a quota) — `zl-nas`, ZettLab/zettOS (Debian 12) at `192.168.1.136`. Out-of-cluster backup sink; admin SSH on `:56634` (key-based, sudo password-gated). The appliance itself is not a K3s node and not in ansible/k3s scope (the `immich-vm` K3s worker is a VM hosted on it).

Storage is node-local (`local-path-provisioner`) — no distributed storage layer by choice; durability comes from the backup chain, not replicated volumes.

## Maintenance

The cluster is reviewed monthly (security scans, policy reports, alert/backup/cert health, dependency freshness). The full changelog lives in [HOMELAB_HISTORY.md](HOMELAB_HISTORY.md); every change is a commit, so `git log` is the audit trail.

Worker self-heal watchdogs: `clusterip_heal` (post-reboot kube-proxy DNAT wedge → k3s-agent restart) and `node_isolation_heal` (CP-isolation ladder — k3s-agent restart at 6 min, staggered self-reboot 15/23 min as last resort; **ACTIVE** since 2026-07-23 after a 13-day dry-run soak). Their k3s-agent restarts are flock-serialized via a shared cooldown; phase2 maintenance reboots set a worker-local hold so orchestrated reboots never count as isolation.

### Upcoming deadlines

Forward calendar of dated obligations. [SECRETS_ROTATION.md](SECRETS_ROTATION.md) is authoritative for rotation specifics; this table is the at-a-glance roll-up. Recurring timers (sync 10 min, drift-heal 03:00, weekly update Sat, security scan 1st — 9th for August 2026) are not listed.

| Due | Item |
|---|---|
| ~~2026-07-14~~ ✅ | Immich Path-B follow-up (T7) DONE 2026-07-14 (`4628800d` + `a32f6ef8`): backup re-topology (immich-backup → W2 producer, pulls NAS library → tar on W2 + NAS `akhozya-pool1` pool, keep-2 each; Codex 3 rounds) + W1 `immich-library` PVC decommissioned (PV `pvc-495129ee` + 61G reclaimed via local-path Delete). Gate: live 60.6G tar, NAS-pool `sha256 -c` OK. Soak waived ~40h/48h (repoint reversible, touches only backup cronjob). See HISTORY |
| ~~2026-07-04~~ ✅ | Monthly review + quarterly automation audit DONE 2026-07-04 (see HISTORY). Watches CLOSED: Authentik client-hints (2026.5.3 live), passkey lockout, UR2 vmalert, mysql-proxy POP-1100/1110 (accepted cosmetic). Still watched monthly: n8n #25705 (workaround PROVEN still required at 2.28.6), k8s-sidecar#531 (loki probes stay disabled), Stirling#6211 |
| ~~2026-07-05~~ ✅ | immich-backup Sunday slot VERIFIED firing — `lastSuccessfulTime 2026-07-12T03:07Z` (closed 2026-07-12) |
| ~~2026-07-08~~ ✅ | security-scan ExecStopPost failure-notify SHIPPED 2026-07-12 (`89cd65b3`): missing lynis/rkhunter now exit 1, unit ExecStopPost fires telegram-notify on any failure, script+creds distributed to workers via security_scan role (was CP-only — every worker notify path silently dead). Node-side apply at drift-heal 03:00 UTC, verify next day. trivy soak CLOSED 2026-07-10 (#2859 cache-lock churn benign, concurrency 2→1) |
| 2026-07 (unscheduled) | Remaining deferred: monitoring-ns Traefik middleware fork (necessary namespaced duplication — low priority); offsite backup (owner decision — accepted, documented-only). **Done 2026-07-03** (main `d771464d`): Percona `crVersion`→1.2.0 (SmartUpdate roll, matched operator chart already at 1.2.0); ClusterIssuer→`letsencrypt-prod` (16 certs re-issued, was already prod ACME); Redis/CouchDB instance CRs → configs layer (gapless prune:disabled move); csp-reporter GC'd — see HISTORY |
| ~~2026-07-06~~ ✅ | Resource right-sizing pass DONE 2026-07-12 (`d4d21e18` + `6cd4c036`): 12 workloads' requests raised to 7d p95 (stirling-pdf 1408Mi, n8n 448Mi, blocky 256Mi, apprise 224Mi, paperless 704Mi, trivy-operator 640Mi, vmsingle 768Mi, vm-operator 160Mi; mysql 896Mi, orchestrator/haproxy cpu 160m, sentinel cpu 50m). Named candidates closed earlier: reports-controller limit 300m→500m + redis-operator 400m (`c214e0cd` 2026-07-04). immich excluded (Path B soak to ~07-14). Residual CLOSED 2026-07-13: reports-controller avg throttle 56.6%→10.6% post-VP-migration, but hourly scan spikes still max 48% ≥ gate 25% → limits.cpu 500m→800m. Chronic burst-throttlers (authentik-worker 37%, redis-replication-master 32%, claude-telegram 30%) = pre-existing 7d baseline, p95 usage ≪ limit — cosmetic, no action |
| ~~2026-07-20~~ ✅ | Worker-2 backup replication-step drop DONE 2026-07-17 (early): W2 sync step + SSH setup removed from `backup-replication/cronjob.yaml` (steps renumbered), `backup-replication-ssh-key` Secret + `ssh-known-hosts` ConfigMap deleted (Flux prune), NP W2:65300 egress rule dropped, DR scripts + docs updated. NAS = sole replication sink. Stale W2 copy at `/mnt/extra-storage/backups/` cleaned manually |
| ~~≥2026-07-11~~ ✅ | Kyverno CP→VP migration **Phases 2-4 DONE 2026-07-12** (`abf5d2c5` Deny flip → CP delete → `fc45be04` canary+parity retire): 8-day parity soak clean, Gate A (canary dry-run deny) + Gate B (per-policy live admission, 12/12 attributed despite fine-grained webhook short-circuit / PSA / LimitRange interplay) passed. Codex catch: autogen rewrites `object.metadata` to pod-template path, voiding deletionTimestamp checks — `require-networkpolicy` now direct controller match + autogen off. See HISTORY 2026-07-12 |
| ~~2026-10~~ ✅ | `kyverno.io/v1` ClusterPolicy removal deadline (Kyverno 1.20, ~Oct 2026) MET EARLY 2026-07-12 — zero ClusterPolicies remain; kyverno chart bumps shipping 1.20 no longer held |
| 2026-08-08 / 09 | **August-only shift** (owner request): monthly review (watches n8n #25705, k8s-sidecar#531, Stirling#6211 — the vm-operator RBAC watch closed same-day 2026-07-31, chart 0.67.1) and trivy image-CVE scan on the **8th**; node security scan on the **9th**. **Revert after the 9th**: `monitoring/configs/trivy-scan/cronjob.yaml` schedule → `0 8 1 * *`; `security_scan` role timer → `OnCalendar=*-*-01` + `Persistent=true`. The scan sits on the 9th because 08-01 and 08-08 are both Saturdays and the Sat 04:30 UTC reboot lands inside its 04:00-05:00 window — tolerable at `Persistent=true`, which catches a missed run up on the next boot, but not while shifted to `Persistent=false`. Trivy is a CronJob, so a node reboot reschedules it rather than losing it. If the revert is missed, both keep running monthly on their shifted day — no scan is skipped |
| 2026-10 (monthly review) | **Immich ML + immich-vm memory re-check.** The ML container serves clip, ocr and facial-recognition and caches each 300s, so size it for their sum: measured 2026-09-07 at 4984Mi with all three resident, limit 7Gi (`1034951d`). Sizing it from CLIP alone gave 5Gi and OOM-killed the gunicorn WORKER, which gunicorn respawns — `restartCount` stays 0, so `ContainerOOMKilled` never fires and OCR/face jobs just drop connections. Query `max_over_time` for the ML container working set and for immich-vm node memory (VMSingle per Phase 3), scoped to **after 2026-09-07**: a flat 30d window spans the CPU-path and 5Gi periods and the model swap, so its max describes a shape the cluster no longer runs. Decide: ML peak >80% of 7Gi → raise the limit; node peak sustained >80% of 11949Mi → bump the VM to 14Gi, which also clears the 113% limit overcommit (13338Mi of 11849Mi allocatable). Node was 6529Mi (55%) at the 2026-09-07 peak with 6.2Gi free, so neither is expected yet. A VM RAM change needs a host-side restart on the GPU-reset-bug machine — not free. Research: `docs/plans/2026-09-07-immich-ml-followups-research.md` |
| 2026-10-01 | 180-day secret rotation — ALL scheduled secrets: PG/MySQL/Redis, CouchDB, OIDC, Authentik Django key (90-day High tier retired 2026-07-02, ex-High folded in; Redis admin+blocky follow 2026-10-26) |
| 2026-12-31 | `cloudflare-tunnel-mgmt-token` rotation |
| 2027-01-30 | `gh-homelab` deploy key rotation (in the `claude-telegram-ssh` Secret). The only key the bot holds that can write to this repo, so a push with it is a deploy inside 5 min — 180 days, not the annual cadence the read-only deploy keys get |
