# 🏗️ HOMELAB COMPREHENSIVE ANALYSIS
## Staff DevOps Engineer Assessment

**Assessment Date**: 2025-10-18 (Updated: 2026-03-07)
**Cluster**: K3s (staging) - **3 nodes** (1 control-plane, 2 workers)
**Node IPs** (static DHCP, router-assigned by MAC): gmk-k3s-control-plane=192.168.1.127, worker-node=192.168.1.129, worker-node-2=192.168.1.126
**Infrastructure**: GitOps (Flux), CloudNativePG, Percona MySQL, Monitoring Stack, SSO (Authentik), Cloudflare Tunnel
**Responsibility Level**: ⚠️ **CRITICAL** - Production-equivalent personal infrastructure
**Code Review**: 2026-03-07 - Full codebase analysis (94/100, A) — previous: 2026-02-20 (93/100, A)
**Historical Archive**: [HOMELAB_HISTORY.md](./HOMELAB_HISTORY.md) - Completed tasks & changelog (Oct-Dec 2025)

---

## 📊 EXECUTIVE SUMMARY

### Overall Grade: **A+ (97/100) - Excellent** ⬆️

**Strengths** ✅
- Solid GitOps foundation with Flux
- Comprehensive monitoring (Prometheus, Grafana, Loki, Alertmanager) - **HA enabled** (2 replicas with anti-affinity) ⭐
- **🆕 Popeye - Cluster health monitoring (A grade, 100/100 score)** ⭐ (2025-10-27, Updated: 2026-01-09)
  - **Weekly CronJob**: Sunday 6 AM automated health scans ⬆️
  - **Score**: 100/100 after orphaned RBAC cleanup
  - **Status**: Clean cluster state, automated monitoring
- **🆕 Kyverno - Kubernetes-native policy enforcement (10 policies: 7 Enforce + 3 Audit, daily alerts)** ⭐ (2025-10-27, Updated: 2025-12-18)
  - **Enforced policies:** disallow-privilege-escalation, require-drop-all-capabilities, require-labels, disallow-host-namespaces, **require-non-default-serviceaccount** ✅, **require-seccomp-runtimedefault** ✅ (0 violations)
  - **Audit policies:** require-resource-limits (**0 violations**) ✅
  - **Phase 1 Complete (2025-10-28):** Service account remediation - 31 pods migrated, 16 custom SAs created, enforce mode enabled ✅
  - **Phase 2 Complete (2025-10-28):** Seccomp profiles - 23 workloads with RuntimeDefault, enforce mode enabled ✅
  - **Phase 3 Complete (2025-12-18):** Resource limits - Percona operator limits added, 0 violations ✅
  - **Enforcement strategy:** Phased approach with zero-risk policies enforced first
  - **Monitoring:** Daily violation summaries via Prometheus/Telegram
  - **Security posture:** ~68% seccomp RuntimeDefault, ~76% non-root pods
- **🆕 Centralized SSO with Authentik** ⭐
- **🆕 Cloudflare Tunnel for secure external access** ⭐
- **🆕 Dual-Access Pattern: Traefik Ingress + Cloudflare Tunnel** ⭐
- **🆕 AdGuard Home for local DNS management** ⭐
- **🆕 Let's Encrypt TLS certificates for all services** ⭐
- **🆕 Uptime monitoring with Uptime Kuma** ⭐
- **🆕 4.22TB LVM Storage on Worker Node** ⭐
- **✅ Complete PVC Migration to LVM** - All 19 PVCs migrated ⭐
- **✅ Multi-PV LVM** - 3 physical volumes across 2 NVMe SSDs ⭐
- Secrets management with SOPS/age
- Automated dependency updates (Renovate)
- **Complete NetworkPolicy coverage** (16 apps + 5 infra namespaces) ⬆️
- **Clean namespace separation - no resource leaks**
- CloudNativePG for managed PostgreSQL (2-node HA) with PgBouncer pooler
- **🆕 Percona MySQL Operator** for MySQL (2-node async replication) with HAProxy ⭐
- **🆕 3-Node Cluster** - worker-node-2 added (2025-12-15) ⭐
- **🆕 Rebuilderd - Arch Linux Contribution** ⭐ (2025-12-24, Updated: 2026-02-27)
  - Reproducible build verification for Arch Linux packages
  - worker-node: 1 worker, 6 CPU (600%), 32GB RAM, **24/7**
  - worker-node-2: 1 worker, 4 CPU (400%), 14GB RAM, **24/7**
  - Build timeout: 48 hours (for large packages like chromium)
  - LVM-backed storage for builds
  - **Monitoring**: Node-exporter textfile collector, 5-min metrics update, 2 Prometheus alerts ⭐
  - CPU/RAM quota fix: archlinux-repro passes limits to nspawn containers (upstream [PR #143](https://github.com/archlinux/archlinux-repro/pull/143) merged)
  - Kernel watchdog: nmi_watchdog + softlockup/hardlockup panic enabled for crash detection
- Default credential elimination on all apps
- **🆕 Node-Level Security Hardening** ⭐ (2026-02-12, Updated: 2026-03-09)
  - **SSH**: Post-quantum kex (mlkem768x25519), strong ciphers (chacha20/aes-gcm), ETM MACs only
  - **Kernel**: secure_redirects=0, log_martians=1, unprivileged_bpf_disabled=1
  - **Kubelet**: streamingConnectionIdleTimeout=5m (CIS benchmark)
  - **K3s Secrets-at-Rest**: AES-CBC encryption enabled (control-plane)
  - **K3s ExecStartPost**: Re-applies log_martians + secure_redirects after flannel/cni interface creation
  - **Watchdog**: softlockup_panic + hardlockup_panic for auto-reboot on lockup
  - **NVMe/SSD**: APST disabled, PCIe ASPM off, SATA ALPM max_performance
  - **Coverage**: All 3 nodes hardened, unified setup-node.sh for rebuilds
- **🆕 Comprehensive Security Headers & Protections** ⭐ (2025-10-30)
  - **Phase 1 (Completed)**: Safe security headers (X-Content-Type-Options, X-Frame-Options, Referrer-Policy, Permissions-Policy)
  - **Phase 2 (Completed)**: HSTS deployment - Dual layer (Cloudflare edge: 1 month, Traefik origin: 1 week)
  - **Phase 3 (Completed)**: Rate limiting with monitoring - Standard (100/min + 150 burst), High-frequency (200/min + 300 burst)
  - **Phase 4 (Completed)**: CSP enforcement mode (deployed 2025-10-31, 43 days production, zero violations)
  - **Coverage**: All 17 services (14 apps + Grafana + AlertManager + CouchDB)
  - **Monitoring**: 6 Prometheus alerts for rate limiting (attack detection, false positive detection)
  - **HSTS Complete**: ✅ Step 3 deployed 2026-01-09 (max-age=1 year)

**Critical Gaps (from 2025-10-27 Comprehensive Review)** 🔴
- ✅ **Backup replication to NAS + worker-node-2** (P0-CRITICAL) - COMPLETED (2026-02-06) - rsync CronJob at 3:30 AM daily
- ✅ **PostgreSQL NetworkPolicy** (P0-CRITICAL) - COMPLETED (2025-10-27)
- ✅ **Duplicate cert-manager ClusterIssuers** (P0-CRITICAL) - COMPLETED (2025-10-27)
- ❌ **CNPG WAL archiving** (P0-CRITICAL) - REMOVED (Not Implementing - pg_dump acceptable)
- ❌ **Pod anti-affinity for PostgreSQL** (P1-HIGH) - NOT APPLICABLE (single worker node)
- ✅ **PostgreSQL TLS** (P1-HIGH) - ALREADY IMPLEMENTED (all apps using TLS)
- ✅ **Traefik health checks** (P1-HIGH) - ALREADY IMPLEMENTED (15/15 apps)
- ✅ **Scattered middleware** (P1-HIGH) - COMPLETED (centralized)
- ⚠️ **Overly permissive Redis ACLs** (P1-HIGH) - VALID BUT NOT FIXABLE (apps don't support prefixes)
- ⏸️ **Automated backup validation** (P1-HIGH) - DEFERRED to Q1 2026 (homelab stabilization needed)
- 📋 **Total Findings**: 36 issues (2 P0 completed, 1 P0 deferred, 1 P0 removed, 6 P1 completed, 1 P1 N/A, 1 P1 accepted, 1 P1 removed, 1 P1 deferred, 15 P2, 8 P3)

**Vulnerability Scanning** 🔍
- ❌ **Trivy Operator - REMOVED** (2025-12-06)
  - **Rationale**: Limited actionable value for homelab with Renovate-managed updates
  - **Issues Found**:
    - Most vulnerabilities (~70%) have no fix available (OS-level: zlib, sqlite, curl)
    - Fixable vulnerabilities require upstream image rebuilds (outside user control)
    - Renovate already handles updates to latest versions automatically
    - Findings were informational only - no actionable remediation possible
  - **Alternative Strategy**: Renovate bot for automated dependency updates + GitHub security advisories
  - **Cost-Benefit**: Trivy generated noise without enabling action - removal simplifies infrastructure

**Backup Infrastructure** ✅
- ✅ PostgreSQL daily backups (3:00 AM, 30-day retention)
- ✅ CouchDB daily backups (3:05 AM, 30-day retention)
- ✅ PVC daily backups (3:10 AM, 7-day retention) - Immich excluded (photos can be re-uploaded, DB in PostgreSQL)
- ✅ MySQL daily backups (3:15 AM, 30-day retention, SHA256 checksums) ⭐
- ✅ **Backup replication to NAS** (3:30 AM, rsync daemon, NAS accumulates full history, 500GB limit) ⭐
- ✅ **Backup replication to worker-node-2** (3:30 AM, rsync over SSH, today's backup only, temporary safety net until ~May 20) ⭐
- ✅ **Replication order**: worker-node-2 first (SSH, reliable), NAS second (rsync daemon) ⭐
- ✅ Disaster recovery scripts complete (`.backup/` directory)
- ✅ **Automated backup validation** (daily, SHA256 + tar integrity + size + age, Telegram failure-only reports) ⭐
- ✅ Storage optimized: 2.6GB per node (was 580GB before Immich exclusion)

---

## 🎯 CRITICAL ACTION ITEMS

**Last Updated**: 2026-03-09 (Monthly Review)
**Source**: HOMELAB_REVIEW_2025_12_17 (archived, see git history)
**Completed Items**: See [HOMELAB_HISTORY.md](./HOMELAB_HISTORY.md) for detailed completed task archive

### 🔍 March 2026 Monthly Review

**Review Date**: 2026-03-06
**Reviewer**: Staff DevOps/SRE + Staff Software Developer
**Overall Status**: ✅ **HEALTHY** - All systems nominal

#### Infrastructure Health (Staff DevOps/SRE Perspective)

| Component | Status | Details |
|-----------|--------|---------|
| **Nodes** | ✅ 3/3 Ready | K3s v1.35.2, Kernel 6.18.16-lts |
| **Control Plane** | ✅ Healthy | 23% CPU, 13% memory |
| **worker-node** | ✅ Healthy | 20% CPU, 33% memory (rebuilderd active) |
| **worker-node-2** | ✅ Healthy | 31% CPU, 38% memory (rebuilderd active) |
| **Pods** | ✅ 82 Running | 0 CrashLoop, 7 Completed jobs |
| **PostgreSQL** | ✅ 2/2 Ready | v18.3 |
| **MySQL** | ✅ 2/2 Ready | Async replication, no lag |
| **CouchDB** | ✅ 2/2 Running | StatefulSet in databases namespace |
| **Redis** | ✅ 1/1 Running | v8.6.1 |
| **Prometheus** | ✅ 70-79% memory | 90k active series, 905Mi+1025Mi/1300Mi |
| **Alerts** | ✅ None firing | Clean alert state |
| **Backups** | ✅ All successful | NAS + worker-node-2 replication working |
| **Certificates** | ✅ 19/19 Ready | 71+ days until expiration |
| **Flux/GitOps** | ✅ All healthy | All 6 kustomizations reconciled |
| **Scrape Targets** | ✅ 49 active | 0 down |
| **Kyverno** | ✅ 0 violations | Clean |
| **Stale ReplicaSets** | ✅ 0 | Cleaned 4 stale RS this session |

#### Prometheus

- **TSDB Head**: 278k series (includes stale series from kernel reboots + Traefik restarts)
- **Active Series by Job**: ~90k (healthy, down from Feb's 111k)
- **Memory**: 905Mi + 1025Mi / 1300Mi each (70-79%)
- **Top Cardinality**: kubelet 35k (39%), apiserver 17k (19%), kube-state-metrics 10k (11%)
- **Scrape Targets**: 49 active, 0 down

#### Storage

| Location | Used | Total | Usage |
|----------|------|-------|-------|
| worker-node `/mnt/k8s-storage` | 413GB | 4.2TB | 11% |
| worker-node-2 `/mnt/extra-storage` | 319GB | 863GB | 39% |

#### n8n PgBouncer statement_timeout (#25705)

- **Status**: Still **OPEN** upstream (triage:pending, Linear GHC-6809)
- **Last activity**: 2026-02-18 (5 comments, no n8n team fix planned)
- **Our workaround**: `DB_POSTGRESDB_STATEMENT_TIMEOUT=0` in deployment — still needed
- **Re-check**: May 2026

#### CSP Policy Update (2026-03-06)

- Added `worker-src blob: 'self'`, `connect-src blob: data:`, `img-src blob:` to global CSP
- **Reason**: Stirling PDF v2.6.0 uses PDF.js web workers, OpenCV.js WASM, canvas blob thumbnails
- **Scope**: Global (all 17 apps), minimal security risk (blob:/data: are locally-generated)
- **Traefik quirk**: Middleware CRD header changes require `rollout restart` to take effect

#### Pending Scheduled Items

| Item | Target Date | Priority |
|------|-------------|----------|
| Remove worker-node-2 replication step | ~May 20, 2026 | P2 |
| ECC session regex fix — check if [#299](https://github.com/affaan-m/everything-claude-code/issues/299) addressed | March 17, 2026 | P3 |
| n8n PgBouncer `statement_timeout` fix — re-check [#25705](https://github.com/n8n-io/n8n/issues/25705) | May 2026 | P3 |
| Re-evaluate VictoriaMetrics | April 2026 | P3 |

**Next Review**: 2026-04-06 (Monthly)

### 🔍 February 2026 Monthly Review

**Review Date**: 2026-02-07
**Reviewer**: Staff DevOps/SRE + Staff Software Developer
**Overall Status**: ✅ **HEALTHY** - Excellent state, minor housekeeping done

#### Infrastructure Health (Staff DevOps/SRE Perspective)

| Component | Status | Details |
|-----------|--------|---------|
| **Nodes** | ✅ 3/3 Ready | K3s v1.35.2, Kernel 6.18.16-lts |
| **Control Plane** | ✅ Healthy | 15% CPU, 19% memory |
| **worker-node** | ✅ Healthy | 19% CPU, 26% memory (rebuilderd active) |
| **worker-node-2** | ✅ Healthy | 8% CPU, 18% memory |
| **Pods** | ✅ 81 Running | 0 CrashLoop, 15 Completed jobs |
| **PostgreSQL** | ✅ 2/2 Ready | v18.3 (upgraded from 18.2, 2026-02-26) |
| **MySQL** | ✅ 2/2 Ready | Async replication, HAProxy active |
| **CouchDB** | ✅ 2/2 Running | StatefulSet in databases namespace |
| **Redis** | ✅ 1/1 Running | v8.6.0 (upgraded from 8.2.2, 2026-02-20) |
| **Prometheus** | ✅ 72% memory | 121k series, 941Mi/1300Mi (improved from 244k/87%) |
| **Alerts** | ✅ None firing | Clean alert state |
| **Backups** | ✅ All successful | NAS + worker-node-2 replication working |
| **Certificates** | ✅ All Ready | 36-86 days until expiration |
| **Flux/GitOps** | ✅ All healthy | All 6 kustomizations reconciled |
| **Resource Governance** | ✅ Complete | 27 quotas, 26 limitranges |
| **Stale ReplicaSets** | ✅ 0 | Cleaned 87 stale RS this session |

#### Prometheus Improvement

- **Series Count**: 111k (↓ 54% from 244k in Jan review)
- **Memory**: 924Mi / 1300Mi (71%, ↓ from 87%)
- **Replicas**: 2 HA (924Mi + 775Mi)
- **Scrape Targets**: 49

#### Popeye Health Scan

- **Score**: 86/100 (B grade) - down from 100/100
- **Cause**: Mostly false positives from K3s and Percona operator
- **False Positives** (not actionable):
  - 4 kube-system services with no pods (K3s doesn't run controller-manager/etcd/proxy/scheduler as pods)
  - 5 MySQL operator services with unmatched ports (operator-managed, normal)
  - 5 orphaned ClusterRoleBindings (Flux image controllers not installed, K3s system)
- **Actionable**: config-reloader sidecars missing resource limits (Prometheus + Alertmanager) - P3

#### Kyverno Violations

- **6 violations**: All `require-resource-limits` with null/null namespace (stale ephemeral pod reports)
- **Status**: Not actionable - same as previous reviews

#### Storage

| Location | Used | Total | Usage |
|----------|------|-------|-------|
| worker-node `/mnt/k8s-storage` | 753GB | 4.2TB | 19% |
| worker-node-2 `/mnt/extra-storage` | 204GB | 863GB | 25% |
| worker-node-2 backups | 137MB | - | Today's backup only |
| worker-node-2 repro (rebuilderd) | 34GB | - | Build artifacts |

#### Uptime Kuma Monitors

- **28 monitors**: All current (wallabag/linkding stale monitors already removed)
- **NAS Zettlab** monitor added (id=38)

#### Pending Scheduled Items

| Item | Target Date | Priority |
|------|-------------|----------|
| Remove worker-node-2 replication step | ~May 20, 2026 | P2 |
| ~~Migrate Promtail to Grafana Alloy~~ | ~~Before March 2, 2026~~ | ✅ Done |
| Re-evaluate VictoriaMetrics | April 2026 | P3 |
| ~~LTS kernel 6.18~~ | ~~TBD~~ | ✅ Done (6.18.16-lts on all 3 nodes) |
| ~~Authentik worker memory fix — check if [#20537](https://github.com/goauthentik/authentik/issues/20537) landed in 2026.2.x, reduce worker limit 1500Mi→800Mi~~ | ~~March 8, 2026~~ | ✅ Done (v2026.2.1 fixed, reverted to 1200Mi) |
| ~~n8n PgBouncer `statement_timeout` fix — check [#25705](https://github.com/n8n-io/n8n/issues/25705)~~ | ~~March 2026~~ | ✅ Checked (still open, workaround stays) |
| n8n PgBouncer `statement_timeout` fix — re-check [#25705](https://github.com/n8n-io/n8n/issues/25705), remove workaround if fixed upstream | May 2026 | P3 |
| ~~Home Assistant: audit legacy template entities~~ | ~~Before June 2026~~ | ✅ Verified compliant (no legacy templates in config) |
| ~~Authentik: update `/media` mount to `/data/media`~~ | ~~Next Authentik upgrade~~ | ✅ Done |
| ~~Immich: remove unrecognized `PUBLIC_IMMICH_SERVER_URL` env var~~ | ~~Next Immich change~~ | ✅ Done |
| ~~Linkwarden: update Playwright `chromium_headless_shell-1200` path~~ | ~~On Playwright version bump~~ | ✅ Done (version-agnostic wildcard) |

**Monthly Review Checklist** (for next review):
- [x] ~~Helm chart deprecation audit~~ ✅ Completed (2026-02-07) - 2 commits, Kyverno + CouchDB fixes
- [x] ~~Promtail EOL migration status~~ ✅ Migrated to Alloy (2026-02-07)

**Next Review**: 2026-04-06 (Monthly)

---

### 🔍 January 2026 Comprehensive Review

**Review Date**: 2026-01-09
**Reviewer**: Staff DevOps/SRE + Staff Software Developer
**Overall Status**: ✅ **HEALTHY** - Minor gaps identified

#### Infrastructure Health (Staff DevOps/SRE Perspective)

| Component | Status | Details |
|-----------|--------|---------|
| **Nodes** | ✅ 3/3 Ready | K3s v1.35.2, Kernel 6.18.16-lts |
| **Control Plane** | ✅ Healthy | 14% CPU, 17% memory |
| **worker-node** | ✅ Healthy | 20% CPU, 24% memory (rebuilderd active) |
| **worker-node-2** | ✅ Healthy | 22% CPU, 40% memory (tensorflow building) |
| **Pods** | ✅ 82 Running | 0 CrashLoop, 48 Completed jobs |
| **PostgreSQL** | ✅ 2/2 Ready | Cluster in healthy state |
| **MySQL** | ✅ 2/2 Ready | Async replication, HAProxy active |
| **CouchDB** | ✅ 2/2 Running | StatefulSet in databases namespace |
| **Redis** | ✅ 1/1 Running | Cache healthy |
| **Prometheus** | ⚠️ 87% memory | 244k series, 1125Mi/1300Mi |
| **Alerts** | ✅ None firing | Clean alert state |
| **Backups** | ✅ All successful | Replication to worker-node-2 working |
| **Certificates** | ✅ All Ready | 60+ days until expiration |
| **Flux/GitOps** | ✅ All healthy | All kustomizations reconciled |
| **Resource Governance** | ✅ Complete | 26 quotas, 25 limitranges |

#### Security Gaps Found (P2-MEDIUM) - ✅ ALL RESOLVED

| Issue | Namespace | Impact | Status |
|-------|-----------|--------|--------|
| ~~Missing NetworkPolicy~~ | cloudflare-tunnel | Low | ✅ Fixed (8c9bd9b) |
| ~~Missing NetworkPolicy~~ | csp-reporter | Low | ✅ Fixed (8c9bd9b) |
| ~~Missing NetworkPolicy~~ | loki | Medium | ✅ Fixed (8c9bd9b) |
| ~~Missing NetworkPolicy~~ | obsidian | Low | ✅ Fixed (8c9bd9b) |
| ~~Missing NetworkPolicy~~ | traefik | Medium | ✅ Fixed (8c9bd9b) |
| ~~Popeye not scheduled~~ | popeye | Low | ✅ Fixed - Weekly CronJob (8c9bd9b) |

#### Kyverno Policy Violations (Audit Mode - Informational) - ✅ ALL RESOLVED

| Namespace | Policy | Reason | Status |
|-----------|--------|--------|--------|
| backup-replication | require-non-root | rsync needs root | ✅ Exclusion added (8c9bd9b) |
| loki | require-resource-limits | Sidecar missing limits | ✅ Fixed (0510d1d) |
| monitoring | require-resource-limits | Stale ReplicaSets | ✅ Not actionable - old pods |

#### Known Privileged Workloads (Documented Exceptions)

| Workload | Reason | Mitigation |
|----------|--------|------------|
| immich-server | GPU transcoding (VAAPI) | NetworkPolicy, namespace isolation |
| adguard-home | Port 53 binding | NetworkPolicy, dedicated namespace |
| alloy | Host log access (K8s API) | DaemonSet, RBAC-scoped |
| home-assistant | Hardware integrations | NetworkPolicy, capability restrictions |

#### Code Quality (Staff Software Developer Perspective)

| Check | Status | Notes |
|-------|--------|-------|
| Image tags | ✅ All pinned | No :latest or floating tags (fixed 2026-02-20) |
| Security headers | ✅ 100% coverage | All ingresses have middleware |
| Stale ReplicaSets | ✅ 0 found | Clean cluster state |
| Job cleanup | ✅ 13 total | Normal backup job history |
| DRY violations | ⚠️ Acceptable | Documented as intentional for homelab |

#### Prometheus Cardinality Watch

- **Series Count**: 244,658 (↑ from last review)
- **Memory**: 1125Mi / 1300Mi (87%)
- **Action**: Monitor - consider metric drops if >260k

#### Rebuilderd Contribution Status

| Node | Current Build | Progress | ETA |
|------|---------------|----------|-----|
| worker-node | rocfft → next | ✅ Completed | Picking next |
| worker-node-2 | tensorflow 2.20.0 | 57% (20,313/35,367) | ~17:00 UTC |

#### Action Items from This Review

| Priority | Item | Effort | Status |
|----------|------|--------|--------|
| P2 | Add NetworkPolicy to cloudflare-tunnel | 30 min | ✅ Done (8c9bd9b) |
| P2 | Add NetworkPolicy to loki | 30 min | ✅ Done (8c9bd9b) |
| P2 | Add NetworkPolicy to traefik | 30 min | ✅ Done (8c9bd9b) |
| P2 | Add NetworkPolicy to csp-reporter | 15 min | ✅ Done (8c9bd9b) |
| P2 | Add NetworkPolicy to obsidian | 15 min | ✅ Done (8c9bd9b) |
| P3 | Add Popeye CronJob (weekly) | 15 min | ✅ Done (8c9bd9b) |
| P3 | Add Kyverno exclusion for backup-replication | 10 min | ✅ Done (8c9bd9b) |
| P3 | Fix loki-sc-rules sidecar resources | 10 min | ✅ Done (0510d1d) |
| INFO | Investigate null resource-limit violations | 15 min | ✅ Done - stale reports from old ReplicaSets |

---

### 🔍 Code Review Findings (2026-03-07)

**Overall Score**: 94/100 (A) — up from 93/100 in February 2026

| Category | Score | Change | Notes |
|----------|-------|--------|-------|
| Project Structure | 95/100 | = | Clean GitOps, base/staging pattern |
| Kubernetes Patterns | 93/100 | +1 | Flux healthChecks, removed force:true |
| Database Infrastructure | 92/100 | = | PG+MySQL HA, pooler, managed roles |
| Monitoring Stack | 90/100 | = | Inhibit rules added, duplicate alert removed |
| Security Implementation | 96/100 | +2 | 4 new NetworkPolicies, 100% namespace coverage |
| Backup & DR | 96/100 | = | NAS replication, validation pipeline |
| Code Quality (DRY) | 78/100 | = | DRY violations accepted for homelab simplicity |
| Documentation | 91/100 | +1 | Analysis doc kept current |

#### Findings Implemented (March 2026)

| # | Finding | Severity | Status |
|---|---------|----------|--------|
| 1 | Missing NetworkPolicy for cert-manager, kyverno, percona-mysql, backup-replication | P1 | ✅ Fixed (4 policies, pod CIDR + container ports) |
| 2 | No Alertmanager inhibit rules (alert storms) | P1 | ✅ Fixed (3 rules: NodeDown, severity, InfoInhibitor) |
| 3 | Duplicate AlertmanagerNotificationsFailing alert | P1 | ✅ Fixed (removed, kept percentage-based) |
| 4 | Missing Flux healthChecks on infrastructure-controllers | P1 | ✅ Fixed (cert-manager-webhook, kyverno-admission-controller) |
| 5 | `force: true` on apps Kustomization | P1 | ✅ Fixed (removed) |
| 6 | Percona HelmRepository 24h refresh interval | P1 | ✅ Fixed (24h -> 6h) |
| 7 | cert-manager floating chart version 1.19.x | P1 | ✅ Fixed (pinned to 1.19.4) |
| 8 | Homepage ClusterRole reads all secrets cluster-wide | P1 | ⚠️ Accepted (required for K8s service discovery, documented) |
| 9 | No runbook_url on 111 custom alerts | P2 | ❌ Won't do (no runbooks exist, URLs would point nowhere) |
| 10 | 9 PVCs missing storageClassName: local-path | P2 | ✅ Fixed (9 PVCs + immich storageClass→storageClassName typo) |
| 11 | CPUThrottlingHigh uses hardcoded worker IPs | P2 | ✅ Fixed (cadvisor: node label, node-exporter: node_uname_info join) |
| 12 | Backup cleanup runs inside backup jobs | P2 | ❌ Accepted (low risk for homelab, cleanup is fast) |
| 13 | DRY violations (security contexts, probes, annotations) | P3 | ❌ Accepted (homelab simplicity) |

#### Previous Review Findings (2026-02-20)

#### Findings Implemented

| # | Finding | Severity | Status |
|---|---------|----------|--------|
| 1 | Alertmanager `chat_id` in plain YAML | P1 | ⚠️ Accepted (no `chat_id_file` in Alertmanager, commented) |
| 2 | `StrictHostKeyChecking=no` in backup SSH | P1 | ✅ Fixed (ConfigMap known hosts, `StrictHostKeyChecking=yes`) |
| 3 | PVC backup `hostNetwork: true` unnecessary | P1 | ✅ Fixed (removed) |
| 5 | Duplicated Prometheus metric relabelings | P2 | ✅ Documented (cross-reference comment) |
| 6 | Redis `readOnlyRootFilesystem: false` | P2 | ✅ Fixed (enabled + emptyDir /tmp) |
| 7 | Alertmanager `group_interval: 10s` too aggressive | P2 | ✅ Fixed (10s → 5m) |
| 8 | Telegram truncation missing count | P2 | ✅ Fixed (shows hidden alert count) |
| 9 | CF tunnel YAML parser fragile | P2 | ⏸️ Deferred (add validation later) |
| 10 | PG instance count discrepancy in docs | P2 | ✅ Fixed (3 → 2) |
| 11 | MySQL buffer pool discrepancy in docs | P2 | ✅ Verified (changelog entries correct) |
| 12 | PVC backup `cd` mid-script | P3 | ✅ Fixed (subshell) |
| 13 | Loki chart stale pin comment | P3 | ✅ Fixed (updated comment) |
| 14 | Meilisearch `readOnlyRootFilesystem` | P3 | ✅ Fixed (enabled + emptyDir /tmp) |
| 15 | Backup `successfulJobsHistoryLimit` | P3 | ❌ Declined (history useful for debugging) |
| 16 | Renovate groups all Helm charts | P3 | ✅ Fixed (removed catch-all group) |

### ✅ Completed P0-CRITICAL Items (Summary)

| Item | Date | Commit | Notes |
|------|------|--------|-------|
| PostgreSQL NetworkPolicy | 2025-10-27 | a80d4bf | Restricts DB access to app namespaces |
| cert-manager ClusterIssuers | 2025-10-27 | 2cb9e78 | Removed duplicate, kept single source |
| CNPG WAL Archiving | N/A | - | ❌ Not implementing (pg_dump acceptable) |

### 🛡️ SECURITY HARDENING (Active)

#### ✅ **Node-Level Hardening** - COMPLETED (2026-02-12)
   - **SSH**: Post-quantum kex (mlkem768x25519-sha256), strong ciphers only (chacha20-poly1305, aes256-gcm, aes128-gcm), ETM MACs only, ed25519/rsa-sha2 host keys
   - **Kernel sysctls**: `secure_redirects=0` (prevent MITM), `log_martians=1` (detect spoofing), `unprivileged_bpf_disabled=1` (block unprivileged BPF)
   - **Kubelet**: `streamingConnectionIdleTimeout=5m` (was 4h default, CIS benchmark)
   - **K3s Secrets-at-Rest**: AES-CBC encryption enabled on control-plane (`k3s secrets-encrypt rotate-keys`)
   - **Coverage**: All 3 nodes (SSH, kernel, kubelet), control-plane (secrets encryption)
   - **Scripts**: `docs/scripts/setup-node.sh` (all hardening), `/tmp/harden-node.sh` (applied to existing nodes)
   - **Commits**: b9211fc0, ec68a7c7, b563df44

#### ✅ **HSTS Max-Age Optimization** - COMPLETED (2026-01-09)
   - **Final**: `max-age=31536000` (1 year) on all 17 ingresses
   - **Gradual Rollout**: ✅ Step 1 (1mo) → ✅ Step 2 (6mo) → ✅ Step 3 (1yr)
   - **Commits**: 5e109cd, 793a247

#### ✅ **Secrets Audit** - PASSED (2026-02-20)
   - **Scope**: Full repository scan - 51 Secret YAML files, all scripts, docs, and configs
   - **Result**: No plaintext secrets found in git-tracked files
   - **SOPS**: All 51 Secret files encrypted with AES256-GCM/age
   - **Scripts**: Use `kubectl get` / placeholders only, no hardcoded values
   - **Gitignore**: `.backup/`, `*.agekey`, `*.key`, `*.pem`, `.env` all excluded
   - **No history rewrite needed**

#### ✅ CSP Enforcement - COMPLETED (2025-10-31)
   - 43 days in production, zero violations, 85 automated tests passed

---

### ⚠️ P1-HIGH (Active Items Only)

#### ✅ **Migrate Promtail to Grafana Alloy** - COMPLETED (2026-02-07)
   - **Status**: ✅ COMPLETED - Alloy v1.12.1 (chart 1.5.1) deployed, Promtail removed
   - **Priority**: ~~P1-HIGH~~ COMPLETED (24 days ahead of EOL deadline)
   - **Details**: Grafana Alloy DaemonSet on all 3 nodes, `loki.source.kubernetes` for K8s API-based log tailing
   - **Labels**: namespace, pod, container, node_name, app (same as Promtail)
   - **Alerts**: AlloyDown, AlloyLogDeliveryFailing (replaced PromtailDown, PromtailTargetsMissing)
   - **Dashboard**: Updated to show Alloy metrics and pod selectors
   - **Commits**: 70371693, 4c6e8b27, 3d710ff7, 216f317e

#### ✅ **Automated Backup Validation Testing** - COMPLETED (2026-02-06)
   - Daily automated validation: SHA256 checksum, tar integrity, size thresholds, age checks
   - Telegram daily report with per-backup status (pass/fail per type)
   - Integrated into backup-replication CronJob (Step 4, before source cleanup)
   - Checks: PostgreSQL >1MB, CouchDB >100KB, MySQL >100KB, PVC >100KB, age <25h

#### ✅ **Kyverno Phase 3: Resource Limits** - COMPLETED (2025-12-18)
   - **0 violations** as of 2025-12-18 (was 22 on 2025-12-17)
   - Fixed by adding resource limits to Percona MySQL operator HelmRelease
   - All non-system pods now have resource limits
   - Commits: f67f9ba (operator limits), 5e28d3e (original fix)

### ✅ Completed P1-HIGH Items (Summary)

| Item | Date | Status | Commits |
|------|------|--------|---------|
| Pod Anti-Affinity PostgreSQL | 2025-10-29 | ✅ 2 instances, required anti-affinity | cbc71d0 |
| CNPG Port 8000 Binding | 2025-10-30 | ✅ Resolved - worker-node only | [#9013](https://github.com/cloudnative-pg/cloudnative-pg/issues/9013) |
| PostgreSQL TLS | 2025-10-27 | ✅ Already implemented | - |
| Redis Backup | - | ❌ Not implementing (cache only) | - |
| Flux Timeout Standardization | 2025-10-27 | ✅ All 6 kustomizations 45s | 4cc2834 |
| Traefik Health Checks | 2025-10-27 | ✅ 15/15 apps compliant | - |
| HA Critical Components | 2025-10-29 | ✅ 2 replicas across nodes | e07474a |
| Scattered Middleware | 2025-10-27 | ✅ Centralized to traefik ns | 9a9ebce |
| Redis ACLs | 2025-10-27 | ⚠️ Accepted (apps don't support prefixes) | - |
| Kyverno Phase 1 (Service Accounts) | 2025-10-28 | ✅ Enforce mode, 31 pods | 584d3a1 |
| Kyverno Phase 2 (Seccomp) | 2025-10-28 | ✅ Enforce mode, 23 workloads | 8eaf7ea |

---

### 📋 P2-MEDIUM (Active Items Only)

| Pending Item | Effort | Priority |
|--------------|--------|----------|
| ~~Deploy Velero for cluster backups~~ | ~~4-6h~~ | ❌ Declined |
| ~~Implement backup immutability (S3 object lock/ZFS)~~ | ~~2-4h~~ | ❌ Declined |
| ~~SOPS multi-key encryption~~ | ~~4h~~ | ❌ Declined |

**Velero - DECLINED** (2026-02-06): Flux GitOps already reconstructs all cluster state (RBAC, CRDs, ConfigMaps, namespaces) from Git. Databases have dedicated daily backups with SHA256 validation. PVCs have daily backups. Velero would only help with non-Git stateful resources, which are all already covered. Not worth the operational overhead for a homelab.

**Backup Immutability - DECLINED** (2026-02-06): NAS rsync daemon runs without `--delete`, making backups append-only by design. Remote deletion not possible via rsync protocol. NAS web UI is the only way to delete, requiring physical network access + credentials. For a homelab on a local network, the risk of backup tampering is negligible. S3 object lock would require cloud storage; ZFS would require NAS OS changes (not supported on Zettlab).

**SOPS Multi-Key - DECLINED** (2026-02-06): Multi-key is for team environments where multiple people need independent decryption (e.g., separate keys for CI/CD, teammates). Single operator with one age key stored in 1Password. No CI/CD pipeline needing its own key. Adding complexity for no benefit.

#### 🔒 **ReadOnlyRootFilesystem Security Hardening** (P2-MEDIUM) - PHASE 1-3 COMPLETE ✅

**Investigation Date**: 2025-12-18
**Implementation Date**: 2025-12-18 (Phase 1+2), 2025-12-23 (Phase 3)
**Current State**: 15/16 apps have readOnlyRootFilesystem enabled (was 3, +12 containers hardened)
**Goal**: Maximize containers with read-only root filesystems to reduce attack surface

##### ✅ **Tier 1: COMPLETED** (2025-12-18)

| App | Container | Status | Commit |
|-----|-----------|--------|--------|
| **paperless-ngx** | main | ✅ Enabled | e1d5e5b |
| **authentik-server** | server | ✅ Enabled | 3c1fddb |
| **authentik-worker** | worker | ✅ Enabled | 5213a69 |

##### ✅ **Tier 2: COMPLETED** (2025-12-18)

| App | Container | Changes | Commit |
|-----|-----------|---------|--------|
| **csp-reporter** | main | Added /tmp emptyDir, full security hardening | 48ba5fc |
| **homepage** | main | Added /tmp emptyDir, automountServiceAccountToken: false | 9e04864 |
| **homehub** | main | Added /tmp emptyDir | d8da2a0 |
| **uptime-kuma** | main | Added /tmp emptyDir, runAsNonRoot to pod spec | 2034718 |

**Verification**: All 7 apps restarted, init containers tested, setup jobs re-run, CSP reports confirmed working

##### ✅ **Tier 3: COMPLETED** (2025-12-23)

| App | Container | Changes | Commit |
|-----|-----------|---------|--------|
| **linkwarden** | main | Already had emptyDirs for /tmp, /app/.next/cache, /home/node/.cache | 3d4d533 |
| **immich-ml** | main | Added /tmp emptyDir via persistence section | 3d4d533 |
| **immich-proxy** | nginx | Added /tmp emptyDir via postRenderer patch (advancedMounts doesn't work) | 3d4d533 |

**Verification**: All 3 apps tested - linkwarden SSO works, immich API responds, nginx proxy /tmp writable

##### ❌ **Tier 4: Not Feasible**

| App | Reason | Mitigation |
|-----|--------|------------|
| **pricebuddy** (scraper) | Selenium writes browser data in many locations | Container isolation, NetworkPolicy |
| **pricebuddy** (apprise) | Runs as root, writes to /config | emptyDir already used, root required |
| **stirling-pdf** | Comment: "needs to write temp files and modify system configs" | Has many emptyDir, needs root for nginx/PDF processing |
| **adguard-home** | Runs as root for port 53, writes to multiple locations | Container isolation, PVC for data |
| **home-assistant** | Runs as root, writes plugins/states/custom components everywhere | Official limitation, many capabilities required |
| **immich-server** | Runs as privileged for GPU transcoding | Required for VAAPI hardware acceleration |
| **grafana** | Helm chart complexity, multiple sidecars | Would require extensive chart customization |

##### 📋 **Implementation Summary**

**Phase 1** (Tier 1 - Zero Risk): ✅ **COMPLETED 2025-12-18**
- Enabled on paperless-ngx, authentik-server, authentik-worker
- Commits: e1d5e5b, 3c1fddb, 5213a69

**Phase 2** (Tier 2 - Low Risk): ✅ **COMPLETED 2025-12-18**
- Added /tmp emptyDir to csp-reporter, homepage, homehub, uptime-kuma
- Commits: 48ba5fc, 9e04864, d8da2a0, 2034718

**Phase 3** (Tier 3 - Medium Risk): ✅ **COMPLETED 2025-12-23**
- Enabled on linkwarden, immich-ml, immich-proxy (nginx sidecar)
- Key finding: Immich HOST env var bug - nginx proxy sidecar required
- Key finding: bjw-s chart advancedMounts doesn't work - used postRenderer instead
- Commits: 3d4d533

**Outcome**: 13 containers with readOnlyRootFilesystem (was 3, +10 hardened)
**Security Benefit**: Reduced attack surface, prevents runtime filesystem tampering

### ✅ Completed P2-MEDIUM Items (Summary)

| Item | Date | Status |
|------|------|--------|
| PVC storageClassName + alert hardcoded IPs | 2026-03-07 | ✅ 9 PVCs fixed, immich typo fixed, CPUThrottlingHigh/NodeMemoryMajorPagesFaults use hostnames |
| ReadOnlyRootFilesystem Phase 1-3 | 2025-12-23 | ✅ 10 apps hardened (paperless, authentik×2, csp-reporter, homepage, homehub, uptime-kuma, linkwarden, immich-ml, immich-proxy) |
| Backup Integrity Checks (SHA256) | 2025-10-31 | ✅ All backups generate checksums |
| GPG Secrets Encryption | 2025-10-31 | ✅ AES256 with interactive passphrase |
| Rate Limiting Middleware | 2025-10-31 | ✅ 100% coverage (17 ingresses) |
| Security Headers | 2025-10-31 | ✅ 100% coverage (HSTS, CSP, etc.) |
| PgBouncer Pooler | 2025-10-31 | ✅ All apps using pooler correctly |
| CREATEDB Permissions | 2025-10-31 | ✅ Accepted (required for migrations) |
| Single Redis/CouchDB | 2025-10-31 | ✅ Documented as intentional |
| LoadBalancer Docs | 2025-10-29 | ✅ K3s ServiceLB documented |
| Cloudflare Health Checks | 2025-10-31 | ✅ Already configured |
| NetworkPolicy Egress | 2025-11-02 | ✅ Validated as correct |
| Prometheus Resource Alerts | 2025-10-31 | ✅ 5 new alerts added |

---

### 📋 P3-LOW (Active Items Only)

| Pending Item | Priority | Status |
|--------------|----------|--------|
| Re-evaluate VictoriaMetrics (workaround available) | P3 | ⏸️ April 2026 |
| n8n PgBouncer `statement_timeout` re-check | P3 | ⏸️ May 2026 |
| ~~Prometheus/Alertmanager config-reloader resource limits~~ | ~~P3~~ | ❌ Won't do (chart-managed sidecars, <10Mi RAM) |
| ~~Backup alert grouping to Telegram thread~~ | ~~P3~~ | ❌ Won't do (~1 alert/month, not worth complexity) |
| ~~Grafana dashboards for app metrics~~ | ~~P3~~ | ❌ Won't do (apps don't expose custom metrics) |
| ~~PrometheusRules for custom app metrics~~ | ~~P3~~ | ❌ Won't do (no custom app metrics exist) |

### ✅ Completed P3-LOW Items (Summary)

| Item | Date | Status |
|------|------|--------|
| PVC Backup Retention (7 days) | 2025-10-31 | ✅ Increased from 3 to 7 days |
| Secrets Rotation Docs | 2025-10-31 | ✅ Complete tracking in SECRETS_ROTATION.md |
| SSH Key Backup Location | 2025-10-31 | ✅ Documented (1Password) |
| Resource Quotas | 2025-10-31 | ✅ 25 quotas deployed |
| LimitRanges | 2025-10-31 | ✅ 25 LimitRanges deployed |

---

### 📅 DEFERRED TASKS (February 2026)

#### 37. **Offsite Backup Replication to NAS** ✅ COMPLETED
   - **Status**: ✅ COMPLETED - NAS replication fully operational (2026-02-06)
   - **Priority**: ~~P0-CRITICAL~~ COMPLETED
   - **Hardware**: Zettlab 6 Ultra (14TB usable)
   - **Constraint**: Runs its own OS, Docker only (no K8s), **no SSH access**
   - **NAS Storage Limit**: **500GB** allocated for homelab backups (current usage: 2.6GB)
   - **Current RPO**: 24 hours (daily replication at 3:30 AM)
   - **Current RTO**: ~30 minutes (restore from NAS or worker-node-2)
   - **Replication Strategy**: NAS is primary backup store, worker-node-2 is temporary safety net
     - Worker-1: creates backups → syncs to NAS + worker-2 → cleaned after replication
     - NAS: accumulates full backup history (no `--delete`, ~190 days at 2.6GB/day)
     - Worker-2: mirrors source with `--delete` (today's backup only, temporary until ~May 20, 2026)
     - NAS connection: rsync daemon protocol, port 50555, SOPS secret (`nas-rsync-credentials`)
     - NAS limitation: module root is read-only, writes go to `backups/homelab/` subfolder
     - **500GB hard limit**: NAS storage allocation, manual pruning via NAS web UI when needed
     - **Alerts**: 400GB warning, 450GB critical (in job logs)
   - **Action**:
     1. ✅ NAS hardware arrived and initial setup (2026-02-05)
     2. ✅ Configure NAS on local network (IP: 192.168.1.136, rsync port 50555)
     3. ✅ Create SOPS-encrypted secret for rsync user/password
     4. ✅ Configure backup replication CronJob (daily at 3:30 AM, rsync daemon protocol)
     5. ✅ Test backup replication (2.6GB transferred, sizes verified)
     6. ✅ Update disaster recovery documentation (README.md, BACKUP_STRATEGY.md, secrets scripts)
   - **TODO**: Remove worker-node-2 replication after extended safety period (~May 20, 2026)
   - **Files**: `infrastructure/configs/staging/backup-replication/` (cronjob.yaml, nas-rsync-secret.yaml)
   - **Benefit**: Protects against node hardware failure (NAS = full history, worker-node-2 = today's safety net)

#### 38. **Second Worker Node** 🖥️ ✅ COMPLETED
   - **Status**: ✅ DEPLOYED - 2025-12-15 (ahead of schedule!)
   - **Priority**: ~~P1-HIGH~~ COMPLETED
   - **Node Details**:
     - **Hostname**: worker-node-2 (192.168.1.126)
     - **User**: z3us
     - **Hardware**: 30GB RAM, 1TB NVMe (system) + 3.6TB NVMe (k8s-storage)
     - **Kernel**: 6.18.16-1-lts
     - **K3s**: v1.35.2+k3s1
   - **Storage**: 3.6TB LVM (`k8s-storage` VG) - 1% used
   - **Current Workloads** (31 pods):
     - PostgreSQL replica (main-postgres-11)
     - CouchDB replica (couchdb-couchdb-0)
     - MySQL replica (main-mysql-mysql-0) + HAProxy + Orchestrator
     - Promtail, Loki canary, system pods
   - **Swap**: ✅ 16GB LVM swap configured (2025-12-18)
   - **LVM Resize** (2025-12-18):
     - Root: 20GB → 50GB (21% used)
     - Home: 932GB → 10GB
     - Swap: 16GB (new LV)
     - Extra: 863GB at /mnt/extra-storage
   - **Remaining Tasks**: ✅ All completed (2025-12-18)
     - ✅ **Monitoring HA enabled** - Prometheus/Alertmanager 2 replicas with anti-affinity
     - ✅ **Uptime Kuma monitors** - Already configured (SSH + kubelet monitors)
     - ✅ **AdGuard Home DNS** - Added 192.168.1.126 to DNS rewrites
   - **Documentation**: SECOND_WORKER_NODE_SETUP.md (archived, see git history)

#### 39. **Switch to LTS Kernel 6.18** 🐧 ✅ COMPLETED
   - **Status**: ✅ COMPLETED - 2026-03-06
   - **Priority**: ~~P2-MEDIUM~~ COMPLETED
   - **Result**: All 3 nodes switched from mainline `linux` (6.19.6) to `linux-lts` (6.18.16)
   - **K3s**: Upgraded v1.35.1 → v1.35.2 simultaneously
   - **Procedure Used**: Two-phase approach (install LTS → reboot → verify → remove mainline)
   - **Boot Entries**: systemd-boot entries created from existing ones, fallback initramfs enabled
   - **Benefit**: Long-term stability, security backports until Dec 2027

#### 40. **Re-evaluate VictoriaMetrics** 📊 DEFERRED
   - **Status**: DEFERRED - Bug closed without fix, workaround available
   - **Priority**: P3-LOW (optimization opportunity)
   - **Target Date**: April 2026
   - **Background**:
     - Attempted migration on 2025-11-15, aborted due to bug
     - Issue: `metricRelabelConfigs` not functioning in VMNodeScrape/VMServiceScrape
     - Result: VictoriaMetrics collected 48% MORE series than Prometheus (defeating purpose)
   - **Bug Tracking**:
     - GitHub Issue: [#9951](https://github.com/VictoriaMetrics/VictoriaMetrics/issues/9951) - **CLOSED** (2026-01-05, inactivity - not fixed)
     - Maintainer requested VMAgent CR + VMServiceScrape config, reporter never provided
     - **Workaround confirmed by reporter**: Use BOTH `relabelConfig` + `metricRelabelConfig` together
   - **Action in April 2026**:
     1. Test workaround: configure both relabelConfig + metricRelabelConfig for metric drops
     2. Deploy VictoriaMetrics in test namespace
     3. Compare series count vs Prometheus
     4. If workaround works, plan migration
   - **Expected Benefits** (if workaround works):
     - ~2-5x RAM reduction
     - ~7x disk reduction (zstd compression)
     - Native downsampling for long retention
   - **Current Mitigation**: Prometheus retention at 90d, 72% memory (941Mi/1300Mi), 121k series
   - **Note**: DO NOT NAG UNTIL APRIL 2026

---

## 🛠️ NODE MANAGEMENT SCRIPTS

Scripts for node-level configuration stored in `docs/scripts/`. Run manually when needed.

### Unified Node Setup (`setup-node.sh`)

**Single script for all node types** — auto-detects control-plane vs worker, Intel vs AMD.

| Run Command | Any Node |
|-------------|----------|
| `sudo bash setup-node.sh` | Auto-detects node type and CPU |

**What it configures (5 sections):**

1. **Packages & Firmware**: smartmontools, inetutils, intel-ucode/amd-ucode, linux-firmware, AUR firmware
2. **Performance**: CPU governor (powersave + balance_power EPP), BBR, TCP tuning, conntrack, SSD no-sleep
3. **Security**: Unified kernel/fs/network hardening (50+ sysctls), watchdog, SSH post-quantum kex, NVMe APST off
4. **K3s Config**: config.yaml + kubelet.yaml (auto control-plane vs worker)
5. **System Services**: Graceful shutdown (120s), journald (500MB/2wk), systemd timeouts, K3s ExecStartPost overrides

**Key files deployed:**
- `/etc/sysctl.d/99-unified-hardening.conf` — kernel, filesystem, network hardening
- `/etc/sysctl.d/99-watchdog.conf` — soft/hard lockup panic
- `/etc/sysctl.d/99-k8s-performance.conf` — BBR, conntrack, inotify, TCP buffers
- `/etc/ssh/sshd_config.d/99-hardening.conf` — post-quantum kex, strong ciphers/MACs
- `/etc/rancher/k3s/config.yaml` — K3s node config
- `/etc/rancher/k3s/kubelet.yaml` — kubelet shutdown, eviction, log rotation
- `/etc/systemd/system/${K3S_SERVICE}.service.d/network-hardening.conf` — re-apply sysctls after K3s interface creation
- `/etc/systemd/system/${K3S_SERVICE}.service.d/conntrack-fix.conf` — override kube-proxy conntrack
- `/etc/tmpfiles.d/cpu-power-settings.conf` — persistent CPU governor + EPP

**Status** (2026-03-09): ✅ All 3 nodes configured, verified post-reboot

### Performance Optimization
Now unified into `setup-node.sh` (auto-detects node type and CPU vendor).

**What they configure:**
- CPU governor → `powersave` (efficient baseline, EPP balance_power, boost enabled, persists via tmpfiles.d)
- `fs.inotify.max_user_instances` → 8192 (more containers)
- `fs.inotify.max_user_watches` → 1048576 (more file watches)
- TCP congestion → BBR (better throughput)
- TCP buffers → 16MB (high throughput)
- `net.netfilter.nf_conntrack_max` → 1048576 (K8s services)
- `vm.swappiness` → 10 (prefer RAM over swap)
- `vm.dirty_ratio` → 10/5 (faster SSD writeback)

**Status** (2025-12-20): ✅ All 3 nodes optimized (BBR, TCP tuning, CPU performance governor)

---

## 📈 CURRENT METRICS

**Health Score: 97/100** (A+ Grade) - Updated 2026-02-12
- **Security**: 98/100 (A+) ✅ - 100% PSS, 100% NetworkPolicy, SSH hardened, secrets-at-rest encrypted, kernel hardened ⬆️
- **Backup/DR**: 98/100 (A+) ✅ - Daily backups + NAS/worker-2 replication + automated validation
- **Database**: 90/100 (A) ✅ - PostgreSQL HA + MySQL HA, NetworkPolicy, TLS
- **Infrastructure**: 88/100 (A-) ✅ - Flux/Traefik solid, all controllers healthy
- **Maintainability**: 95/100 (A) ✅ - Excellent docs, GitOps-driven
- **Best Practices**: 92/100 (A) ✅ - Popeye scheduled, Kyverno enforced, resource governance
- **Performance**: 94/100 (A) ✅ - Prometheus series 244k→111k, memory 87%→71%

**Overall Grade**: A+ (97/100) ⬆️
- **Critical Issues**: 0 P0 issues ✅
- **High Priority**: 0 P1 active ✅
- **Active P2**: Remove worker-node-2 replication (~May 20)
- **Active P3**: VictoriaMetrics re-evaluation (April 2026), n8n statement_timeout (May 2026)

**Security Achievements** ✅:
- **100% Pod Security Standards** (Apps: 11 restricted, 4 baseline, 1 privileged | Jobs: 5 restricted, 1 baseline)
- **100% NetworkPolicy Coverage** (16 apps + 5 infra namespaces)
- **100% SOPS Encryption** for secrets
- **100% Image Version Pinning** (no :latest or floating tags, all pinned to semver) ⬆️
- **100% SSO Coverage** (8/8 applicable apps)
- **100% HSTS Coverage** (max-age 1 year on all 17 ingresses)
- **100% Node Hardening** (SSH post-quantum kex, kernel sysctls, kubelet CIS) ⬆️
- **K3s Secrets-at-Rest Encryption** (AES-CBC on control-plane) ⬆️
- **Popeye Weekly Health Scan** (Sunday 6 AM)

**Resolved Critical Gaps** ✅:
- ✅ Backup replication to NAS + worker-node-2 (completed 2026-02-06)
- ✅ PostgreSQL NetworkPolicy (completed 2025-10-27)
- ✅ Duplicate cert-manager ClusterIssuers (completed 2025-10-27)
- ✅ All infrastructure NetworkPolicies (completed 2026-01-09)

---

## 📱 CURRENT APPS (16 total)

| App | Status | Security | OIDC/SSO | Notes |
|-----|--------|----------|----------|-------|
| **Homepage** | ✅ Running | ✅ NetworkPolicy | - | **Dashboard - Single pane of glass** ⭐ |
| **Uptime Kuma** 🆕 | ✅ Running | ✅ NetworkPolicy | - | **Uptime monitoring** - MySQL, Automated setup ⭐ |
| **Authentik** 🆕 | ✅ Running | ✅ NetworkPolicy | ✅ Provider | **SSO Platform** - PostgreSQL + Redis ⭐ |
| **AdGuard Home** 🆕 | ✅ Running | ✅ NetworkPolicy | - | **DNS filtering** - Local DNS resolution ⭐ |
| **Stirling PDF** 🆕 | ✅ Running | ✅ NetworkPolicy | ✅ OIDC | **PDF toolkit** - Cloudflare Tunnel + internal access ⭐ |
| **HomeHub** 🆕 | ✅ Running | ✅ NetworkPolicy | - | **Family dashboard** - Local only, no auth ⭐ |
| **Grafana** | ✅ Running | ✅ NetworkPolicy | ✅ OIDC | Monitoring dashboard, Authentik SSO ⭐ |
| **Immich** 🆕 | ✅ Running | ✅ NetworkPolicy | ✅ OIDC | Photo management, Web UI config ⭐ |
| **Paperless-NGX** 🆕 | ✅ Running | ✅ NetworkPolicy | ✅ OIDC | Document management, env var config ⭐ |
| **Home Assistant** 🆕 | ✅ Running | ✅ NetworkPolicy | ✅ OIDC | Smart home, MariaDB, hass-oidc-auth, GitOps install ⭐ |
| **LinkWarden** 🆕 | ✅ Running | ✅ NetworkPolicy | ✅ OIDC | **Bookmark manager + Meilisearch** - Replaces Linkding & Wallabag ⭐ |
| Mealie | ✅ Running | ✅ NetworkPolicy | ✅ OIDC | User provision + OIDC (env var) ⭐ |
| N8N | ✅ Running | ✅ NetworkPolicy | ❌ Enterprise | User provision ✅, SSO requires Enterprise |
| Audiobookshelf | ✅ Running | ✅ NetworkPolicy | ✅ OIDC | Web UI config ⭐ |
| Obsidian | ✅ Running | ✅ NetworkPolicy | - | CouchDB sync |
| **PriceBuddy** 🆕 | ✅ Running | ✅ NetworkPolicy | - | **Price tracking** - MariaDB, Apprise Telegram notifications ⭐ |

**Security Coverage: 15/15 apps (100%)** ✅
**SSO Coverage: 8/8 applicable apps (100%)** ⭐
- **8 apps with OIDC**: Grafana, Immich, Paperless-NGX, Home Assistant, Mealie, LinkWarden, Audiobookshelf, Stirling PDF
- **6 apps local-only/monitoring**: Homepage, Uptime Kuma, AdGuard Home, HomeHub, Obsidian, N8N*
- **1 app (N8N)**: Requires Enterprise plan for SSO
- **Note**: Authentik is the SSO provider (not counted as consumer)

---

## 💾 STORAGE INFRASTRUCTURE

### Worker Node Storage Configuration

**Multi-SSD LVM Setup - k8s-storage (4.22TB Total):**

**Physical Volumes:**
1. **4TB NVMe SSD** (`/dev/nvme1n1`): 3.64 TiB
   - Model: WD_BLACK SN7100 4TB
   - 100% dedicated to LVM
2. **1TB NVMe SSD** (`/dev/nvme0n1p6`): 466 GB
   - Model: WD_BLACK SN7100 1TB
   - Partition 6 added to LVM pool
3. **1TB NVMe SSD** (`/dev/nvme0n1p7`): 132 GB
   - Model: WD_BLACK SN7100 1TB
   - Partition 7 - Unallocated space added to LVM

**Logical Configuration:**
- 📊 Volume Group: `k8s-storage` (4.22 TiB total)
- 💾 Logical Volume: `k8s-data` (4.22 TiB)
- 📍 Mount Point: `/mnt/k8s-storage`
- 📈 Current Usage: **2.1MB / 4.2TB (<1%)**
- 📦 Available: **4.2 TiB for growth**
- ✅ **Migrated**: All 19 PVCs migrated to LVM storage

**1TB System Disk (nvme0n1) - Remaining Partitions:**
- `p1`: 1GB - `/boot` (EFI)
- `p2`: 50GB - `/` (root) - 2.2GB used
- `p3`: 32GB - swap
- `p4`: 50GB - `/home` - 306MB used
- `p5`: 200GB - `/var` - 4.6GB used (old PVCs cleaned up)
- `p6`: 466GB - **LVM** (added to k8s-storage VG)
- `p7`: 132GB - **LVM** (added to k8s-storage VG)

**Storage Strategy:**
- ✅ **Migration Complete**: All 19 PVCs migrated to 4.2TB LVM storage
- ✅ **Cleanup Complete**: Old PVCs and backups removed (~52GB reclaimed)
- ✅ **Expansion Complete**: All available space added to LVM (+132GB)
- 🎯 **Capacity**: 4.2TB available for massive growth
- 💪 **Performance**: Multi-PV LVM spans 2 NVMe SSDs (3 partitions)
- 🔮 **NAS**: Zettlab 6 Ultra (14TB, 500GB backup limit) - operational (2026-02-06)

---

## 🔧 MISSING CRITICAL APPS

**High Priority:**
1. ~~Homepage/Heimdall - Dashboard~~ ✅ **COMPLETED**
2. ~~Authentik/Authelia - SSO~~ ✅ **COMPLETED**
3. ~~Uptime Kuma - Uptime monitoring~~ ✅ **COMPLETED**
4. ~~Paperless-NGX - Document management~~ ✅ **COMPLETED**
5. ~~Immich - Photo management~~ ✅ **COMPLETED**

**Medium Priority:**
6. ~~Trivy Operator - Vulnerability scanning~~ ✅ **COMPLETED** (2025-10-27)
7. ~~Popeye - Cluster sanitizer~~ ✅ **COMPLETED** (2025-10-27)
8. ~~Kyverno - Policy enforcement~~ ✅ **COMPLETED** (2025-10-27)
9. FreshRSS/Miniflux - RSS reader
10. Gitea - Lightweight self-hosted Git with CI/CD (10x lighter than GitLab)
11. K8up - Lightweight Kubernetes backup operator (Restic-based, lighter than Velero)
12. ~~External-DNS - DNS automation~~ ✅ **REMOVED** (AdGuard Home handles local DNS)

**Note**: Password management handled by 1Password (commercial service)

---

## 🌐 EXTERNAL ACCESS & DNS INFRASTRUCTURE

### Cloudflare Tunnel Configuration

**Zero Trust Network Access:**
- **Tunnel ID**: ***REMOVED-CF-TUNNEL-UUID***
- **Tunnel Name**: homelab-gitops
- **Zone**: h0melab.work (Zone ID: 082e62c3fe08e1fc9e059a7edc43221f)
- **Management**: Cloudflare Dashboard/API (NOT ConfigMap-based)
- **Namespace**: cloudflare-tunnel

**Active Services (9):**
1. authentik.h0melab.work → Authentik (port 9000)
2. couchdb.h0melab.work → CouchDB (port 5984)
3. audiobooks.h0melab.work → Audiobookshelf (port 3005)
4. linkwarden.h0melab.work → LinkWarden (port 3000)
5. stirling-pdf.h0melab.work → Stirling PDF (port 8080)
6. mealie.h0melab.work → Mealie (port 9000)
7. paperless.h0melab.work → Paperless-NGX (port 8000)
8. immich.h0melab.work → Immich (port 8080)
9. n8n.h0melab.work → N8N (port 5678) ⭐ NEW

**Configuration Details:**
- **Deployment**: infrastructure/configs/staging/cloudflare/cloudflared.yaml
- **ConfigMap**: Reference-only (tunnel config, metrics endpoint)
- **Ingress Routes**: Managed via Cloudflare Dashboard Zero Trust section
- **Important**: ConfigMap does NOT contain ingress/service routes (API-managed)

**DNS Strategy:**
- **External services (via Cloudflare Tunnel)**: CNAME records pointing to tunnel (e.g., authentik → ***REMOVED-CF-TUNNEL-UUID***.cfargotunnel.com)
- **Internal services**: AdGuard Home for local DNS resolution
- **Proxied**: All tunnel CNAMEs proxied through Cloudflare (orange cloud)

### AdGuard Home Configuration

**Local DNS Resolution:**
- **Namespace**: adguard-home
- **Purpose**: Local DNS server for internal homelab services
- **Access**: adguard.h0melab.work (Traefik Ingress, internal only)
- **Features**:
  - Local DNS records for internal services (no external Cloudflare API dependency)
  - DNS filtering and ad blocking
  - Query logging and statistics
  - Fast local resolution

**DNS Resolution Flow:**
- **Tunnel services** (9 apps): Internet → Cloudflare DNS → Cloudflare Tunnel → Service
- **Internal services**: Local network → AdGuard Home → Traefik Ingress → Service
- **Benefit**: Fast local DNS, no Cloudflare API rate limits, simplified architecture

### NetworkPolicy Considerations

**Dual-Access Pattern:**
Apps accessible via both internal (Traefik) and external (Cloudflare Tunnel) require TWO ingress rules:

```yaml
ingress:
  # Internal access via Traefik
  - from:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: traefik
    ports:
      - protocol: TCP
        port: 9000
  # External access via Cloudflare Tunnel
  - from:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: cloudflare-tunnel
    ports:
      - protocol: TCP
        port: 9000
```

**Example**: Authentik NetworkPolicy includes both traefik and cloudflare-tunnel namespaces

---

## 🗄️ DATABASE INFRASTRUCTURE

### CloudNativePG (CNPG) - PostgreSQL

**Cluster Configuration:**
- **Name**: main-postgres
- **Replicas**: 2 (HA configuration) ⭐
- **Version**: PostgreSQL 18.3
- **Namespace**: databases
- **HA Validation**: ✅ Proven during WAL corruption incident (2025-10-26)
  - Lost 1 replica (main-postgres-1) to checkpoint corruption
  - Cluster remained operational with 2 healthy replicas
  - Zero downtime, zero data loss
  - Auto-recovery: CNPG created main-postgres-4 as replacement

**Connection Methods:**
1. **Direct Connection** (not recommended for apps):
   - Service: main-postgres-rw.databases.svc.cluster.local:5432
   - Use case: Administrative tasks, migrations

2. **PgBouncer Pooler** (recommended for apps):
   - Service: main-postgres-rw-pooler.databases.svc.cluster.local:5432
   - Pool mode: transaction
   - Max connections: Configured per database
   - Use case: Application connections

**Databases (10):**
- authentik, immich, paperless, grafana, linkding, mealie, wallabag, audiobookshelf, n8n, app

**Pooler Benefits:**
- Connection pooling reduces overhead
- Better resource utilization
- Prevents connection exhaustion
- Automatic failover handling

**Pooler Setup:**
- User credentials: Created via CloudNativePG Pooler CRD
- Role creation: Handled by CNPG operator
- Secret management: Auto-generated by CNPG
- **Important**: Delete stale secrets if pooler role creation fails

**Apps Using Pooler:**
- Authentik (AUTHENTIK_POSTGRESQL__HOST: main-postgres-rw-pooler.databases.svc.cluster.local)
- All other apps configured similarly

### Database Monitoring

**PostgreSQL (CloudNativePG):**
- **Method**: PodMonitor (metrics exposed on pods, not services)
- **Namespace**: databases
- **Label Selector**: cnpg.io/cluster: main-postgres
- **Targets**: 6 pods (3 database + 3 pooler)
- **Port**: 9187 (metrics endpoint)
- **Metrics**: 133 CNPG-specific metrics
- **Key Metrics**: cnpg_backends_total, cnpg_collector_nodes_used, pg_stat_database metrics
- **Alerts**: 7 alerts (down, pod not running, connection failure, too many connections, replication lag, deadlocks, high rollback rate)

**Redis:**
- **Method**: ServiceMonitor + redis-exporter sidecar
- **Namespace**: databases
- **Exporter**: oliver006/redis_exporter:v1.81.0-alpine
- **Port**: 9121 (exporter metrics)
- **Resources**: 10m CPU, 32Mi memory
- **Service Label**: app: redis (required for ServiceMonitor discovery)
- **Key Metrics**: redis_uptime_in_seconds, redis_connected_clients, redis_memory_used_bytes
- **Alerts**: 7 alerts (down, pod not running, high memory, rejected connections, too many connections, slow queries, connection failure)
- **NetworkPolicy**: Allows monitoring namespace access on port 9121

**CouchDB:**
- **Method**: ServiceMonitor with built-in Prometheus endpoint
- **Namespace**: couchdb
- **Endpoint**: /_node/_local/_prometheus (port 5984)
- **Authentication**: Basic auth via couchdb-couchdb secret
- **Metrics**: 236 built-in CouchDB metrics
- **Key Metrics**: couchdb_httpd_requests_total, couchdb_database_reads_total
- **Alerts**: 2 alerts (down, pod not running)

**Storage Monitoring:**
- **PVC Capacity**: Alerts at 80% (warning) and 90% (critical) usage
- **Current State**: 8% usage, 3.7TB free of 4.2TB total
- **Behavior**: local-path-provisioner shares node disk (no per-PVC quotas)
- **Additional Alerts**: <1GB free (critical), >85% inodes (warning)

**Alert Discovery:**
- **PrometheusRule**: homelab-alerts (monitoring namespace)
- **Required Label**: release: kube-prometheus-stack
- **Alert Groups**: database-alerts, redis-alerts, couchdb-alerts
- **Total Alerts**: 16 database-specific alerts

### Database Replication Strategy

**PostgreSQL (2 Replicas)**: ✅ **High Availability Required**
- **Usage**: Critical application data (Authentik, Immich, Paperless, Grafana, etc.)
- **Replicas**: 2 instances (1 primary, 1 standby)
- **Replication**: Streaming replication with WAL shipping
- **Failover**: Automatic via CNPG operator
- **Why HA**: Critical data, zero data loss requirement, automatic recovery
- **Validation**: Proven during 2025-10-26 corruption incident (zero downtime, zero data loss)

**Redis (Single Instance)**: ✅ **Decision: NO Replication**
- **Usage**: Session cache, job queues (Authentik, Paperless, Immich)
- **Current Setup**: 1 instance with PVC persistence
- **Why Single Instance**:
  - Cache/ephemeral data - acceptable to lose on restart
  - Apps handle Redis restarts gracefully (session re-login, job retry)
  - Session timeout acceptable for homelab (not business-critical)
  - Redis Sentinel/manual failover adds significant complexity
  - 2x memory overhead (cache duplicated) not justified
  - Job queues auto-retry on reconnect
- **Mitigation**:
  - PVC for persistence (survives pod restarts)
  - Proper resource limits configured (200m CPU, 64Mi memory)
  - Daily backups via postgres-backup (captures app state)
- **Acceptable Downtime**: 5-10 seconds during restarts (pod recreation)

**CouchDB (Single Instance)**: ✅ **Decision: NO Replication**
- **Usage**: Obsidian note sync (single user, personal notes)
- **Current Setup**: 1 instance with PVC persistence
- **Why Single Instance**:
  - Single-user use case (not multi-tenant)
  - Sync downtime acceptable for homelab (5-10 min during upgrades)
  - Daily backups already implemented (couchdb-backup@3:05am, 30-day retention)
  - CouchDB clustering requires complex multi-master configuration
  - 3x storage overhead for full replication (3 copies of all data)
  - Replication overhead (network traffic, CPU for conflict resolution)
- **Mitigation**:
  - Daily automated backups with 30-day retention
  - Upgrade during off-hours (minimal user impact)
  - Fast recovery from backup if needed
- **Acceptable Downtime**: 5-10 minutes during scheduled maintenance

**MySQL (2 Replicas)**: ✅ **High Availability with Percona Async Replication**
- **Usage**: Application data for Home Assistant, Uptime Kuma, PriceBuddy
- **Cluster Type**: Percona Server for MySQL with async replication
- **Replicas**: 2 instances (primary-replica with Orchestrator failover)
- **Version**: MySQL 8.4.6 (Percona Server)
- **Operator**: Percona Operator for MySQL (PS) v1.0.0
- **Replication**: Async (traditional MySQL replication)
- **Failover**: Automatic via Percona Orchestrator (3 replicas, one per node for HA)
- **Proxy**: HAProxy for connection routing (port 3306)
- **Why HA**: Critical application data, automatic failover, more stable than Oracle operator
- **Architecture**: Matches PostgreSQL pattern (base = infrastructure, staging = app-specific resources)
- **Databases**: 3 databases (homeassistant, uptimekuma, pricebuddy)
- **Backups**: Daily automated backups (3:15 AM, 30-day retention, SHA256 checksums)
- **Migration Date**: 2025-12-16 (migrated from Oracle MySQL InnoDB Cluster)
- **Migration Reason**: Oracle MySQL Operator had persistent issues with Group Replication, RBAC, and auto-recovery
- **Storage**: 20Gi per replica (local-path PVCs on worker node)
- **NetworkPolicy**: Restricts access to app namespaces + monitoring (port 3306)
- **Connection Pattern**: HAProxy (main-mysql-haproxy.databases.svc.cluster.local:3306)
- **Components**:
  - MySQL: 2 replicas (async replication)
  - Orchestrator: 3 replicas (one per node for HA during rolling updates)
  - HAProxy: 2 replicas for connection routing
  - Toolkit: pt-heartbeat sidecar for replication monitoring
- **Known Limitations**:
  - Replication password must be ≤32 characters (MySQL limitation)
  - HAProxy admin port (33062) probe may fail; main port (3306) works fine
- **Operator Brittleness**: ⚠️ Manual intervention often required during recovery
  - See [MYSQL_OPERATOR_ANALYSIS.md](./MYSQL_OPERATOR_ANALYSIS.md) for detailed runbook
  - Common issues: clone.lock cleanup, stale IPs, read_only state, errant GTIDs
  - Alternative considered: MOCO operator (evaluate if incidents >1/month)
- **Known Issue**: PriceBuddy start-app.sh uses `nc` without `-z` flag causing startup hang
  - **Workaround**: ConfigMap override with fixed script
  - **Upstream**: [Issue #101](https://github.com/jez500/pricebuddy/issues/101) / [PR #102](https://github.com/jez500/pricebuddy/pull/102)
  - **TODO**: Remove workaround when PR #102 merged

**Summary**:
- **Critical data (PostgreSQL)**: 2 replicas, HA, zero downtime
- **Critical data (MySQL)**: 2 replicas, Percona async replication, Orchestrator failover
- **Cache/ephemeral (Redis)**: Single instance, restart tolerance acceptable
- **Personal sync (CouchDB)**: Single instance, backup-based recovery acceptable

---

**Last Updated**: 2026-03-09
**Next Review**: 2026-04-06 (Monthly)

---

## 📝 CHANGELOG (Recent)

*For older entries, see [HOMELAB_HISTORY.md](./HOMELAB_HISTORY.md)*

### 2026-03-11 (NetworkPolicy K8s API Egress Audit) 🔒
- ✅ **Loki crash-loop fixed**: `loki-sc-rules` sidecar (kiwigrid/k8s-sidecar) couldn't reach K8s API ⭐
  - Root cause: loki NetworkPolicy (added Jan 9) missing K8s API egress (192.168.1.127:6443)
  - Went undetected because pod wasn't restarted since before policy was applied
  - Exposed by Renovate Loki chart update to v6.54.0 which recreated the pod
- ✅ **Traefik NetworkPolicy fixed**: Missing K8s API egress (ticking time bomb) ⭐
  - Traefik was working via stale HTTP/2 watch connections from startup race window
  - `wget` from inside pod confirmed "Connection refused" on 10.43.0.1:443
  - If API watch dropped (API restart, network hiccup), ALL routing would break
- ✅ **Homepage NetworkPolicy fixed**: Removed stale `component: apiserver` pod selector ⭐
  - Old rule had `port: 443` to `namespaceSelector: {}` — doesn't match after kube-proxy DNAT (port becomes 6443)
  - Replaced with explicit `192.168.1.127:6443` rule
- ✅ **Full audit**: 40 NetworkPolicies across all namespaces checked, all other policies confirmed correct
  - cert-manager, kyverno, percona-mysql, databases, monitoring, flux-system — all have proper API egress
- ℹ️ **Key learning**: Existing TCP connections survive NetworkPolicy changes (conntrack ESTABLISHED). Always restart pods after adding/modifying NetworkPolicies to verify.
- 📋 **Commits**: acea8f23, e84b2705

### 2026-03-09 (Comprehensive Node Audit & Hardening) 🔒
- ✅ **Full Arch Linux audit across all 3 nodes** — 18 findings identified and fixed ⭐
- ✅ **Unified setup-node.sh**: Single script replaces per-node scripts (auto-detects CP/worker, Intel/AMD)
  - Added: smartmontools, inetutils, journald config, PermitEmptyPasswords, amd_pstate boot param
  - Added: SSD/NVMe power saving disabled (APST, ASPM, ALPM)
  - Added: Watchdog config (softlockup_panic, hardlockup_panic)
  - Added: K3s ExecStartPost for network hardening re-apply
  - Cleaned: Old cpu-governor.conf, 51-kptr-restrict.conf, 99-security-hardening.conf
- ✅ **Sysctl hardening fix**: secure_redirects=0 added to unified-hardening.conf (was missing after old file removal)
- ✅ **K3s ExecStartPost**: log_martians + secure_redirects re-applied after flannel/cni interface creation
  - Root cause: systemd-sysctl runs before K3s, new interfaces reset network sysctls
- ✅ **Worker-node-2 fixes**: hostname (worker-node2→worker-node-2), pacman (ParallelDownloads 10), fstab (noatime)
- ✅ **Worker-node fixes**: networkd-wait-online interface (enp3s0→enp4s0), stale tmpfiles cleanup
- ✅ **Control-plane fixes**: stale 51-kptr-restrict.conf removed, cpu tmpfiles renamed
- ✅ **Rolling reboot**: W2 → W1 → CP, all verified post-reboot
- ✅ **Cluster health**: 3/3 nodes Ready, 81 running pods, 0 alerts, 0 stale RS after cleanup

### 2026-03-07 (March 2026 Code Review - 94/100, A) 📋
- **Full Codebase Review**: Score improved 93/100 -> 94/100 (+1 point) via 6 parallel agents
- **NetworkPolicy**: Added for cert-manager, kyverno, percona-mysql, backup-replication (4 namespaces)
  - Key learning: K3s API server connects to webhooks via pod CIDR (10.42.0.0/16), not node IPs
  - Container ports (kyverno 9443, cert-manager 10250), NOT Service ports (443)
- **Alertmanager**: Added inhibit rules to suppress alert storms during node outages
  - NodeDown suppresses warning/info severity alerts on same instance
  - Critical severity suppresses warning for same namespace/alertname
  - InfoInhibitor suppresses info severity
- **Alertmanager**: Removed duplicate AlertmanagerNotificationsFailing (kept percentage-based AlertmanagerFailedToSendAlerts)
- **Flux**: Added healthChecks to infrastructure-controllers (cert-manager-webhook, kyverno-admission-controller)
- **Flux**: Increased infrastructure-controllers timeout 45s -> 5m (webhook startup tolerance)
- **Flux**: Removed force: true from apps Kustomization (prevents operator field conflicts)
- **Helm**: Pinned cert-manager chart 1.19.x -> 1.19.4 (prevent silent drift, enable Renovate tracking)
- **Helm**: Standardized Percona HelmRepository interval 24h -> 6h (consistent with all other repos)
- **Security**: Documented Homepage ClusterRole secrets access as accepted risk
- **Findings**: 8 P1, 12 P2, 10 P3 - all P1 fixed, 2 P2 fixed, 2 P2 accepted/won't do, rest deferred
- **P2 Fixes**:
  - 9 PVCs missing `storageClassName: local-path` (pricebuddy, adguard, paperless, uptime-kuma, mealie, audiobookshelf×4) + immich `storageClass`→`storageClassName` typo
  - CPUThrottlingHigh: replaced hardcoded IPs with `node` label filter (`node!~"worker-node|worker-node-2"`)
  - NodeMemoryMajorPagesFaults: replaced hardcoded IPs with `node_uname_info` hostname join
  - runbook_url: won't do (no runbooks exist); backup cleanup: accepted (low risk)
- Commits: cd27a2e9, 21cb1e48

### 2026-03-06 (LTS Kernel + K3s Upgrade) 🐧
- ✅ **Kernel: mainline 6.19.6 → LTS 6.18.16** on all 3 nodes ⭐
  - Two-phase approach: install LTS alongside mainline → reboot → verify → remove mainline
  - Rolling order: worker-node-2 → worker-node → control-plane
  - Fallback initramfs enabled on all nodes (mkinitcpio preset updated)
  - Boot entries created from existing ones (preserves per-node kernel params)
  - Mainline `linux` package fully removed after LTS confirmed working
  - Benefit: LTS stability, security backports until Dec 2027
- ✅ **K3s: v1.35.1 → v1.35.2** on all 3 nodes ⭐
  - Control-plane upgraded first (API server before agents)
  - Agent upgrade script auto-reads URL/token from service env file
- ✅ **All pods healthy, 0 alerts firing after upgrade**

### 2026-02-28 (Traefik Alert Fixes) 🔔
- ✅ **Fixed all Traefik & rate-limit alerts using wrong `service` label** ⭐
  - **Root cause**: Prometheus renames app-exported `service` label to `exported_service` (collision with scrape target label). All alerts used `service` (always `traefik-metrics`) instead of `exported_service` (actual backend name)
  - **Impact**: TraefikHighLatency showed generic "traefik-metrics" instead of backend name; 6 rate-limit alerts could **never match** specific services (Authentik, CouchDB, N8N, Immich)
  - **Fixed alerts (8)**: TraefikHighLatency, TraefikHighErrorRate, RateLimitHighRejectionRate, RateLimitPossibleBruteForce, RateLimitCouchDBSyncBlocked, RateLimitAPIClientsBlocked, RateLimitPersistentRejections, RateLimitSuddenSpike
  - **WebSocket exclusion**: TraefikHighLatency now filters `code=~"[1-5].."` (excludes code=0 WebSocket connections which are long-lived by design)
  - **Removed dead alert**: TraefikBackendDown (`traefik_service_server_up` metric not exposed by Traefik)
  - **Alert trigger**: CouchDB Obsidian long-poll (`_changes` feed) + transient Grafana 502s pushed p99 >2s
- ✅ **Deferred VictoriaMetrics re-evaluation**: Feb 2026 → April 2026
- 📋 **Commits**: e9881a50, 90e55ace

### 2026-02-27 (Rebuilderd Monitoring Alerts) 📊
- ✅ **Rebuilderd monitoring via node-exporter textfile collector** ⭐
  - **Metrics**: `rebuilderd_worker_active`, `rebuilderd_builds_good_total`, `rebuilderd_builds_bad_total`, `rebuilderd_builds_total`
  - **Collection**: systemd timer every 5 minutes, parses journalctl for last hour
  - **Alerts**: `RebuilderdWorkerDown` (10m critical), `RebuilderdHighFailureRate` (>80% BAD with ≥10 builds, 30m warning)
  - **Motivation**: Worker-node crash-looped 18 hours (21,935 restarts) due to TOML config error, completely unnoticed
  - **Node-exporter**: textfile collector enabled with `DirectoryOrCreate` hostPath mount
  - **Scripts**: Metrics exporter integrated into `setup-rebuilderd-worker-*.sh` (not a separate file)
- 📋 **Commits**: 38925637

### 2026-02-26 (Kernel Update & Rebuilderd 24/7) 🐧
- ✅ **Kernel Updated**: 6.18.9-arch1-2 → **6.18.13-arch1-1** on all 3 nodes ⭐
  - Rolling reboot: worker-2 → worker-1 → control-plane
  - All nodes Ready, 0 alerts after reboot, 7 stale RS cleaned
- ✅ **Rebuilderd worker-node switched to 24/7**: Removed 09:00-23:00 schedule ⭐
  - Both workers now run 24/7 with boot timer (10 min after reboot)
  - Fixed build timeout: was default 24h (config from Aug 2025 predated change), now 48h
  - Chromium build (145.0.7632.116) timed out at 24h (84% complete, 46376/55332 steps)
- ✅ **PostgreSQL Upgrade**: 18.2 → **18.3** (CNPG rolling update, zero downtime) ⭐
  - Replica updated first, then primary in-place restart
  - Replication lag: 0 bytes after completion
- ✅ **Renovate CNPG Fix**: Added custom regex manager for `imageName` field ⭐
  - Kubernetes manager doesn't detect CRD-specific fields like CNPG's `imageName`
  - Custom regex manager now tracks `ghcr.io/cloudnative-pg/postgresql` versions
  - Future PostgreSQL updates will get proper Renovate PRs
- ✅ **Full Database Maintenance**: All 3 engines optimized ⭐
  - **PostgreSQL**: VACUUM ANALYZE + VACUUM FULL + REINDEX on all 9 databases
  - **MySQL**: ANALYZE + OPTIMIZE on all 3 databases (69 tables total)
  - **CouchDB**: Compaction on both databases (obsidian-personal 33.9%→0.7% fragmentation)
  - Authentik + Paperless rollout-restarted (stale PgBouncer connections after PG upgrade)
  - 6 stale ReplicaSets + 8 completed pods cleaned
- 📋 **Commits**: 4baebd4d, 56bd4cb7, 858447f9

### 2026-02-22 (Health Check & Cleanup) 🔍
- ✅ **Comprehensive Health Check**: All systems healthy, no critical issues ⭐
  - **K3s**: v1.35.1+k3s1 (latest stable), Kernel 6.18.13-arch1-1
  - **Pods**: 81 Running, 0 CrashLoop, 0 alerts firing (Watchdog only)
  - **Databases**: PostgreSQL 2/2 healthy, MySQL 2/2 (lag 0s), CouchDB 2/2, Redis running
  - **Prometheus**: 121k series, 941Mi/1300Mi (72%)
  - **Certificates**: All valid, closest expiry Mar 25 (adguard-home, 31 days)
  - **Backups**: All passed (SHA256 + tar + size + age), NAS + worker-node-2 replication OK
  - **Helm Charts**: All 10 at latest versions, no open Renovate PRs
  - **Kyverno**: 0 violations
- ✅ **Linkwarden Cache Path Fixed**: `/app/.next/cache` → `/data/apps/web/.next/cache` ⭐
  - App runs from `/data/apps/web/`, emptyDir was mounted at wrong path
  - Caused `ENOENT: no such file or directory, mkdir '/data/apps/web/.next/cache'` errors
- ✅ **Cleanup**: 7 stale ReplicaSets deleted, `separated/` audio processing dir removed
- ✅ **mcp-memory-service Updated**: 10.17.0 → 10.17.14 (14 patch versions)
- ✅ **Docs Updated**: K3s v1.35.0→v1.35.1, Kernel 6.18.7→6.18.9, linux-lts 6.12.68→6.12.74, Prometheus 111k→121k, Alloy v1.12.1→v1.13.0
- ⚠️ **Authentik Warning**: "No providers assigned to this outpost" every 5 min — needs admin UI config
- ℹ️ **Cosmetic Issues** (no fix needed):
  - Audiobookshelf: Internal init check logs "already has root user" every ~6 min
  - Stirling PDF: ResourceMonitor oscillates OK↔CRITICAL (Java GC CPU spikes, memory fine at 22%)
  - HA Met.no: Transient DNS errors, self-resolved
  - CF Tunnel CouchDB: Long-poll `_changes` stream cancellations (normal for Obsidian sync)

### 2026-02-21 (Rebuilderd OOM → MySQL Crash Fix) 🔧
- ✅ **Root Cause Found**: Rebuilderd DPDK build OOM killed MySQL pods on worker-node-2 ⭐
  - `lto1-ltrans` (GCC LTO linker) exceeded 18GB memory limit in nspawn container
  - Cgroup `/machine.slice/dpdk1926193.scope`: 19.5GB usage, 228,266 failed allocations
  - OOM killer triggered at 20:40:30 UTC, killing MySQL containers as collateral
  - MySQL crash-looped 6 times before stabilizing (~7 minutes recovery)
  - Percona image bump (Feb 16 commit 4a1f9110) applied opportunistically during pod recreation
- ✅ **Fix**: Reduced worker-node-2 MAX_MEMORY 18GB → 14GB ⭐
  - `MemoryMax=14G`, `MemoryHigh=13G`, `MAX_MEMORY=14G` (cgroup + nspawn)
  - Leaves ~16GB for K8s pods; large LTO builds fail inside cgroup instead of pressuring system
  - Script updated: `docs/scripts/setup-rebuilderd-worker-2.sh`
- ✅ **Bump**: Increased worker-node MAX_MEMORY 24GB → 32GB ⭐
  - 13 OOM kills in last 24h (python-triton ~40GB, openvdb ~34GB, zed ~34GB) — all contained in cgroup, no K8s impact
  - K8s actual usage: 13.5GB of 61GB total — plenty of headroom
  - `MemoryMax=32G`, `MemoryHigh=31G`, `MAX_MEMORY=32G` (cgroup + nspawn)
  - Script updated: `docs/scripts/setup-rebuilderd-worker-1.sh`
- ✅ **Swap spillover enabled**: Builds use swap instead of OOM killing ⭐
  - worker-node: `MemorySwapMax=16G` (32GB RAM + 16GB swap = 48GB effective)
  - worker-node-2: `MemorySwapMax=8G` (14GB RAM + 8GB swap = 22GB effective)
  - Leaves half of each node's swap for K8s and system use

### 2026-02-20 (Image Tag Pinning & Database Updates) 📌
- ✅ **PostgreSQL Upgrade**: 18.1 → 18.2 (CNPG rolling update, zero downtime) ⭐
- ✅ **Redis Upgrade**: 8.2.2 → 8.6.0 (was silently drifting on floating `8-alpine` tag) ⭐
- ✅ **Floating Tags Pinned**: 15 image references across 13 files pinned to exact versions ⭐
  - `alpine:3.23` → `3.23.3` (6 refs in backup/replication jobs)
  - `busybox:1.37` → `1.37.0` (2 refs in homehub, adguard-home)
  - `node:24-alpine` → `24.13.1-alpine` (2 refs in csp-reporter, couchdb-backup)
  - `python:3.14-slim` → `3.14.3-slim` (2 refs in mealie, uptime-kuma jobs)
  - `postgres:18-alpine` → `18.2-alpine` (1 ref in postgres-backup)
  - `redis:8-alpine` → `8.6.0-alpine` (2 refs in redis statefulset)
- ✅ **Root cause**: Renovate can't track floating tags (tag name never changes → no PR created)
- ✅ **All 10 PG/Redis consumer apps** rollout-restarted and verified healthy
- ✅ **Intentionally floating**: CNPG helper images (`18-minimal-trixie`, `18-standard-trixie`) for psql jobs — no action needed
- 📋 **Commits**: 456163b0

### 2026-02-20 (February Code Review - 93/100, A) 📋
- ✅ **Full Codebase Review**: Score improved 89/100 → 93/100 (+4 points) ⭐
- ✅ **Security**: Removed `hostNetwork: true` from PVC backup (unnecessary network access)
- ✅ **Security**: SSH host key verification hardened (ConfigMap known hosts, `StrictHostKeyChecking=yes`)
- ✅ **Security**: Redis + Meilisearch `readOnlyRootFilesystem` enabled (emptyDir /tmp)
- ✅ **Alerting**: `group_interval` 10s → 5m (prevents Telegram flood during incidents)
- ✅ **Alerting**: Truncation message now shows hidden alert count
- ✅ **Docs**: Fixed PostgreSQL instance count (3 → 2 throughout)
- ✅ **Maintenance**: PVC backup checksum uses subshell (prevents working directory leak)
- ✅ **Maintenance**: Renovate Helm catch-all group removed (per-chart PRs now)
- ✅ **Maintenance**: Loki chart pin comment updated (stale bug reference)
- ✅ **Maintenance**: Cross-reference comment for duplicated metric relabelings
- ⚠️ **Accepted**: Alertmanager `chat_id` in plain YAML (no `chat_id_file` support)
- ⏸️ **Deferred**: CF tunnel YAML parser hardening, pre-built backup image
- 📊 **Findings**: 3 P1, 8 P2, 6 P3 — 12 fixed, 2 accepted, 2 deferred, 1 declined

### 2026-02-20 (Codebase Review Fixes) 🔧
- ✅ **CouchDB Alert Namespace Fix**: Changed `namespace="couchdb"` → `namespace="databases"` in CouchDBPodNotRunning alert ⭐
  - Alert was never matching (CouchDB runs in databases namespace, not couchdb)
- ✅ **NetworkPolicy Egress Hardened**: Alloy + Popeye restricted from `0.0.0.0/0` to `192.168.1.127/32` for K8s API ⭐
  - Matches existing Grafana/Prometheus pattern
- ✅ **Homepage ALLOWED_HOSTS**: Restricted from `*` to `home.h0melab.work` (prevents host header injection)
- ✅ **MySQL Kustomization Path**: Fixed inconsistent relative path (4→3 levels, matches postgres/redis/couchdb siblings)
- ✅ **Worker-node-2 Backup**: Extended safety period to ~May 20, 2026 (was ~Feb 13)
- ✅ **Docs Cleanup**: Deleted 18 obsolete doc files (-6,164 lines)
- 📋 **Commits**: 4053675e

### 2026-02-20 (Cloudflare Tunnel GitOps Sync & Secrets Audit) ☁️
- ✅ **CF Tunnel Init Container**: Syncs Git config to CF API on every pod start ⭐
  - Shell parser extracts ingress rules from YAML, PUTs JSON to CF Tunnel Configurations API
  - Image: `curlimages/curl:8.12.1`, readOnlyRootFilesystem, runAsNonRoot, drop ALL
  - Runs as init container — sync before cloudflared starts, fails pod if sync fails
  - Workflow: Edit SOPS config → commit → push → Flux reconciles → rollout restart → synced
  - Commits: fa963b83, 257708e9
- ✅ **Secrets Audit**: Full repo scan — no plaintext secrets in git ⭐
  - 51 Secret YAML files all SOPS-encrypted (AES256-GCM/age)
  - Scripts, docs, configs — no hardcoded credentials
  - `.gitignore` properly excludes `.backup/`, keys, `.env`
  - No git history rewrite needed

### 2026-02-12 (Node Security Hardening) 🔒
- ✅ **SSH Hardening**: Post-quantum kex, strong ciphers/MACs only on all 3 nodes ⭐
  - KexAlgorithms: mlkem768x25519-sha256, curve25519-sha256
  - Ciphers: chacha20-poly1305, aes256-gcm, aes128-gcm (no CBC, no 3DES)
  - MACs: hmac-sha2-512-etm, hmac-sha2-256-etm (no MD5, no SHA1, no non-ETM)
  - HostKeyAlgorithms: ssh-ed25519, rsa-sha2-512, rsa-sha2-256 (no DSA, no ECDSA)
  - Config: `/etc/ssh/sshd_config.d/99-hardening.conf`
- ✅ **Kernel Sysctl Hardening**: Applied to all 3 nodes ⭐
  - `net.ipv4.conf.all.secure_redirects=0` (prevent MITM route injection)
  - `net.ipv4.conf.all.log_martians=1` (detect spoofed source addresses)
  - `kernel.unprivileged_bpf_disabled=1` (block unprivileged BPF access; Arch kernel has BPF_JIT_ALWAYS_ON + BPF_UNPRIV_DEFAULT_OFF compiled-in)
  - Config: `/etc/sysctl.d/99-security-hardening.conf`
- ✅ **Kubelet Streaming Timeout**: Reduced from 4h to 5m on all 3 nodes ⭐
  - CIS Kubernetes Benchmark recommendation
  - Config: `/etc/rancher/k3s/kubelet.yaml`
- ✅ **K3s Secrets-at-Rest Encryption**: AES-CBC enabled on control-plane ⭐
  - Correct procedure: `enable` → add flag → restart → `rotate-keys` → restart
  - Active key: `aescbckey-2026-02-12T22:27:05Z`
  - All existing secrets re-encrypted
  - Config flag: `secrets-encryption: true` in `/etc/rancher/k3s/config.yaml`
- ✅ **K3s Config References Updated**: `docs/setup/` configs now include kubelet-arg and secrets-encryption
- ✅ **K3s Optimization**: conntrack ExecStartPost drop-in, eviction thresholds, log rotation (earlier session)
- ✅ **Rebuilderd Fix**: Implicit config deprecation warning resolved on both nodes
- 📊 **Score**: Security 96→98/100, Overall 96→97/100
- 📋 **Commits**: 178a84ee, 39e3f14d, 052fce9a, b9211fc0, ec68a7c7, b563df44

### 2026-02-07 (Promtail → Grafana Alloy Migration) 🔄
- ✅ **Promtail Replaced with Grafana Alloy**: Full migration completed 24 days ahead of EOL deadline ⭐
  - **Chart**: grafana/alloy v1.5.1 (app v1.12.1) — replaces promtail 6.17.1 (EOL March 2, 2026)
  - **Config**: `loki.source.kubernetes` — tails logs via K8s API (no hostPath mounts needed)
  - **Labels**: namespace, pod, container, node_name, app (same enrichment as Promtail)
  - **Resources**: 50m/200m CPU, 256Mi/512Mi memory (DaemonSet, 3 pods)
  - **Metrics port**: 12345 (was 3101 for Promtail)
  - **Metric prefix**: `loki_write_*` (e.g., `loki_write_sent_bytes_total`, `loki_write_dropped_entries_total`)
- ✅ **Alerts Updated**: PromtailDown → AlloyDown, PromtailTargetsMissing → AlloyLogDeliveryFailing
- ✅ **Dashboard Updated**: All Promtail references replaced with Alloy metrics and selectors
- ✅ **NetworkPolicy Updated**: Renamed promtail-network-policy → alloy-network-policy, port 12345
- ✅ **Kyverno**: loki namespace exclusion still covers Alloy (namespace-level, no change needed)
- 📋 **Commits**: 70371693, 4c6e8b27, 3d710ff7, 216f317e

### 2026-02-07 (Helm Chart Deprecation Audit) 🔧
- ✅ **Helm Chart Deprecation Audit**: Audited all 10 HelmReleases for deprecated fields ⭐
  - **cert-manager**: `installCRDs: true` → `crds: { enabled: true, keep: true }` (deprecated since v1.15.0)
  - **Loki**: Removed deprecated `grafanaAgent: installOperator: false` from selfMonitoring
  - **Alertmanager**: Migrated `match:`/`match_re:` → `matchers:` list syntax (deprecated since v0.22+)
  - **Grafana `rbac.pspEnabled`**: Cosmetic only (PSP removed K8s 1.25+), no fix needed
- ✅ **Promtail → Alloy Migration Complete**: Promtail removed, Alloy v1.12.1 deployed ⭐
  - Grafana Alloy DaemonSet on all 3 nodes using `loki.source.kubernetes` (K8s API)
  - Labels: namespace, pod, container, node_name, app (matches Promtail)
  - NetworkPolicy, alerts, dashboard all updated
  - Commits: 70371693, 4c6e8b27, 3d710ff7, 216f317e
- ✅ **Monthly Helm Audit Checklist**: Added to review template for recurring checks

### 2026-02-07 (Monthly Review + Cleanup) 🔍
- ✅ **February Monthly Review Complete**: All systems healthy, A+ maintained ⭐
  - **Infrastructure**: All 3 nodes healthy, 81 running pods, 0 alerts firing
  - **Databases**: PostgreSQL 2/2, MySQL 2/2, CouchDB 2/2, Redis 1/1 - all healthy
  - **Prometheus**: Series 244k→111k (54% reduction), memory 87%→71% (improved)
  - **Certificates**: All valid, 36-86 days until expiration
  - **Popeye**: 86/100 (B) - mostly K3s/Percona false positives, config-reloader limits P3
- ✅ **Stale ReplicaSets Cleaned**: 87 stale RS deleted across 17 namespaces
- ✅ **Replication Order Swapped**: worker-node-2 first (SSH), NAS second (rsync daemon)
  - More reliable destination runs first, ensuring at least one copy on failure
  - Commit: 54f1e2b
- ✅ **CLAUDE.md Updated**: Fixed MySQL secret name, CouchDB namespace, added parallel tool call docs
- ✅ **Uptime Kuma**: 28 monitors verified current, NAS Zettlab monitor active
- 📋 **LTS Kernel**: Arch `linux-lts` still at 6.12.74 (not 6.18), continue waiting

### 2026-02-06 (Automated Backup Validation) 💾
- ✅ **Automated Backup Validation**: Daily integrity checks integrated into replication CronJob ⭐
  - **Checks**: SHA256 checksum, tar integrity, minimum size thresholds, file age (<25h)
  - **Thresholds**: PostgreSQL >1MB, CouchDB >100KB, MySQL >100KB, PVC >100KB
  - **Telegram**: Failure-only notifications (silent on success)
  - **Replication trap**: Sends Telegram alert with failed step name if rsync fails
  - **Flow**: Sync worker-2 → Sync NAS → Verify NAS → Validate backups → Clean source → Check NAS storage
  - **Tested**: Corrupted backup (SHA256/tar/size FAIL), missing backup (MISSING), NAS unreachable (trap)
  - **Files**: `infrastructure/configs/staging/backup-replication/` (cronjob.yaml, backup-telegram-secret.yaml)
- ✅ **Score Update**: Overall 94→96/100 (A+), Backup/DR 95→98/100
  - P1 "Automated Backup Validation" completed (was last remaining P1)
  - 0 P0, 0 P1 active issues
- 📋 **Commits**: 7c3235e (validation + telegram), 6326b3b (failure trap), b1280e8 (failure-only notifications)

### 2026-01-09 (Comprehensive Review + HSTS Final) 🔍
- ✅ **Comprehensive Homelab Review Complete**: Staff DevOps/SRE + Software Developer perspective ⭐
  - **Infrastructure**: All 3 nodes healthy, K3s v1.35.0, Kernel 6.18.3
  - **Databases**: PostgreSQL 2/2, MySQL 2/2, CouchDB 2/2, Redis 1/1 - all healthy
  - **Monitoring**: Prometheus at 87% memory (244k series), no alerts firing
  - **Backups**: All jobs successful, replication to worker-node-2 working
  - **Security Gaps Found**: 5 namespaces missing NetworkPolicy (P2)
  - **Code Quality**: All image tags pinned, 100% security headers coverage
  - **Next Review**: 2026-02-09
- ✅ **HSTS Step 3 Complete**: Increased max-age from 6 months to 1 year ⭐
  - `max-age=31536000` (1 year) deployed on all 17 ingresses
  - Gradual rollout complete: 1mo (Oct) → 6mo (Nov) → 1yr (Jan)
  - Files: traefik + monitoring security-headers-middleware.yaml

### 2026-01-26 (Rebuilderd Config Updates) ⚙️
- ✅ **Build Timeout Increased**: 24 hours → 48 hours (172800 seconds) ⭐
  - **Reason**: python-aotriton build was at 65% (106,500/163,981) when 24h timeout hit
  - **Estimate**: ~13 hours remaining, 48h provides comfortable margin
  - **Both nodes**: Timeout configured in /etc/rebuilderd-worker.conf
- ✅ **worker-node-2 Schedule Changed**: 09:00-23:00 → 24/7 ⭐
  - **Reason**: Dedicated to rebuilderd, no need for schedule
  - **Implementation**: Removed start/stop timers, boot timer starts service 10 min after reboot
  - **worker-node**: Also switched to 24/7 (2026-02-26)
- 📋 **Scripts Updated**: `setup-rebuilderd-worker-1.sh`, `setup-rebuilderd-worker-2.sh`

### 2026-01-06 (Rebuilderd Schedule Change) 🕐
- ✅ **Schedule Changed**: 24/7 → 09:00-23:00 daily (14 hours) ⭐
  - **Both nodes**: worker-node (600% CPU) and worker-node-2 (400% CPU)
  - **Rationale**: Reduce resource contention during off-hours
  - **Implementation**: Replaced boot timer with start/stop timers
  - **Graceful shutdown**: TimeoutStopSec=7200 allows current builds to complete
  - **Scripts Updated**: `setup-rebuilderd-worker-1.sh`, `setup-rebuilderd-worker-2.sh`

