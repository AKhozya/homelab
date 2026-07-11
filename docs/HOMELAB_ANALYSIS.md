# System Overview

A snapshot of what runs in the cluster and how it's postured. For *why* it's built this way see [ARCHITECTURE.md](ARCHITECTURE.md); for the change log see [HOMELAB_HISTORY.md](HOMELAB_HISTORY.md); for per-subsystem structure see [CODEMAPS/](CODEMAPS/).

**Cluster:** K3s `v1.36.1+k3s1`, single-environment **production** (no staging — a merge to `main` deploys straight to prod), 3 Arch Linux nodes (1 control-plane + 2 workers), static-DHCP IPv4.

## Platform at a glance

| Area | Status |
|---|---|
| **Security** | Pod Security Standards enforced; 12 Kyverno policies (all Enforce); default-deny NetworkPolicies; secrets SOPS-encrypted in Git; in-cluster image-CVE scanning (trivy-operator) |
| **Backup / DR** | Daily logical backups (Postgres, MySQL, CouchDB, app PVCs), 30-day retention, off-node + NAS replication, documented restore runbook |
| **Observability** | VictoriaMetrics + Grafana + Loki/Alloy; Alertmanager → Telegram; weekly Popeye hygiene scan |
| **Networking** | Dual ingress (LAN Traefik + Cloudflare Tunnel), zero inbound ports, Blocky DNS + ad-block |
| **Automation** | Flux GitOps reconcile; Renovate dependency PRs; CI validation gate; ansible-driven node maintenance |
| **HA** | Postgres primary+replica, MySQL async replication, Redis Sentinel quorum, CouchDB active-active; single control-plane (deliberate — see ARCHITECTURE trade-offs) |

## Platform facts

- **16** applications across **28** namespaces in git (32 live incl. k8s system namespaces)
- **66** NetworkPolicy resources live (52 raw manifests in git — operator- and component-generated policies make up the delta) — default-deny posture; presence enforced by Kyverno
- **12** Kyverno `ClusterPolicy` resources — **all 12 Enforce** (per-rule `validate.failureAction`; require-labels/-non-root/-seccomp promoted from Audit 2026-07-03). Dual-running since 2026-07-04: **13** CEL `ValidatingPolicy` resources (12 Audit twins + `vp-canary` Deny) soaking for the kyverno.io/v1 removal migration — see deadlines
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
- NAS: 14 TB (500 GB backup cap) — `zl-nas`, ZettLab/zettOS (Debian 12) at `192.168.1.136`. Out-of-cluster backup sink; admin SSH on `:56634` (key-based, sudo password-gated). Not a K3s node, not in ansible/k3s scope.

Storage is node-local (`local-path-provisioner`) — no distributed storage layer by choice; durability comes from the backup chain, not replicated volumes.

## Maintenance

The cluster is reviewed monthly (security scans, policy reports, alert/backup/cert health, dependency freshness). The full changelog lives in [HOMELAB_HISTORY.md](HOMELAB_HISTORY.md); every change is a commit, so `git log` is the audit trail.

### Upcoming deadlines

Forward calendar of dated obligations. [SECRETS_ROTATION.md](SECRETS_ROTATION.md) is authoritative for rotation specifics; this table is the at-a-glance roll-up. Recurring timers (sync 10 min, drift-heal 03:00, weekly update Sat, security scan 1st) are not listed.

| Due | Item |
|---|---|
| ~~2026-07-04~~ ✅ | Monthly review + quarterly automation audit DONE 2026-07-04 (see HISTORY). Watches CLOSED: Authentik client-hints (2026.5.3 live), passkey lockout, UR2 vmalert, mysql-proxy POP-1100/1110 (accepted cosmetic). Still watched monthly: n8n #25705 (workaround PROVEN still required at 2.28.6), k8s-sidecar#531 (loki probes stay disabled), Stirling#6211 |
| 2026-07-05 | Verify immich-backup 03:00 UTC Sunday slot fires (06-28 slot missed pre-hardening; sds now 3600) |
| 2026-07-08 | security-scan service ExecStopPost failure-notify (quarterly-audit silent-failure fix). trivy-operator installed EARLY 2026-07-04 (`dfeb0153`) — first sweep found criticals; triage via TrivyCriticalVulnerabilities alert + `kubectl get vulnerabilityreports -A`. **trivy soak ends here too**: scan-job `Error` churn = upstream #2859 shared-cache lock race on multi-container pods (verified live 07-04: `cache may be in use by another process: timeout`; retries converge, reports fill in — benign). Checkpoint: reports exist for multi-container workloads (authentik, immich) + churn not worsening → close soak, add gotcha to memory; reports STALLED → flip `operator.builtInTrivyServer: true` (central DB, kills per-job cache race) |
| 2026-07 (unscheduled) | Remaining deferred: monitoring-ns Traefik middleware fork (necessary namespaced duplication — low priority); offsite backup (owner decision — accepted, documented-only). **Done 2026-07-03** (main `d771464d`): Percona `crVersion`→1.2.0 (SmartUpdate roll, matched operator chart already at 1.2.0); ClusterIssuer→`letsencrypt-prod` (16 certs re-issued, was already prod ACME); Redis/CouchDB instance CRs → configs layer (gapless prune:disabled move); csp-reporter GC'd — see HISTORY |
| 2026-07-06 | Resource right-sizing pass. Named candidates (throttling since 07-04, warning-class): `kyverno-reports-controller` 232m sustained vs 300m limit — VP dual-run doubled report writes, undersized limit risks stale polr → parity-gate data (bump vs 7d `max_over_time`, likely ~600m); `redis-operator` burst-clipping 200m cap (84m avg, cosmetic). Popeye POP-109/110 bulk feeds the rest |
| ~2026-07-20 | Worker-2 backup replication-step drop / temp safety-net removal (postponed +2mo from 2026-05-22) |
| ≥2026-07-11 | Kyverno CP→VP migration **Phase 2/3**: Phase 1 shipped 2026-07-04 — 12 CEL `ValidatingPolicy` twins (Audit) + `vp-canary` (Deny) dual-running against the Enforce CPs; **soak started 2026-07-04, ≥1 week** (covers weekly CronJobs). Phase 2 = run `docs/scripts/kyverno-vp-parity.sh` (classes 1/2/3 must be empty; class 2e lists FAILs from strengthened VP controller coverage — real violations, fix the workload; known-benign: require-resource-limits cp=2/vp=1 + the 5 selector-exclude CPs report Pod-only [autogen suppressed], their VP twins check controllers too) + `kubectl get vpol <name> -o jsonpath='{.status.autogen}'` lists 6 controllers on the 11 autogen pod policies (all twins except require-non-default-serviceaccount [direct controller match]; require-networkpolicy twin autogen enabled 2026-07-04 — CP had it live all along). Phase 3 = flip VPs `[Audit]`→`[Deny]` (commit 1, Gate A incl. canary-VP dry-run rejection) then delete CPs (commit 2, Gate B per-policy dry-run) — **CP-deletion target ≤2026-07-18** (parity-clean week + buffer; hard ceiling stays the ~Oct-2026 row). Phase 4 = tooling (scan-violations cpol→vpol, kyverno-policy-promotion skill), delete canary |
| ~2026-10 (before Kyverno chart ships v1.20) | `kyverno.io/v1` ClusterPolicy kind deprecated since Kyverno 1.17; removal planned 1.20 (~Oct 2026). Phases 2-4 above must land BEFORE accepting any kyverno chart bump that ships 1.20. Until migrated: hold such Renovate PRs |
| 2026-10-01 | 180-day secret rotation — ALL scheduled secrets: PG/MySQL/Redis, CouchDB, OIDC, Authentik Django key (90-day High tier retired 2026-07-02, ex-High folded in; Redis admin+blocky follow 2026-10-26) |
| 2026-12-18 | `backup-replication-ssh` key rotation |
| 2026-12-31 | `cloudflare-tunnel-mgmt-token` rotation |
