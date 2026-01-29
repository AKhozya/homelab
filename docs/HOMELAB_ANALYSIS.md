# 🏗️ HOMELAB COMPREHENSIVE ANALYSIS
## Staff DevOps Engineer Assessment

**Assessment Date**: 2025-10-18 (Updated: 2026-01-29)
**Cluster**: K3s (staging) - **3 nodes** (1 control-plane, 2 workers)
**Infrastructure**: GitOps (Flux), CloudNativePG, Percona MySQL, Monitoring Stack, SSO (Authentik), Cloudflare Tunnel
**Responsibility Level**: ⚠️ **CRITICAL** - Production-equivalent personal infrastructure
**Last Comprehensive Review**: 2025-12-17 ([HOMELAB_REVIEW_2025_12_17.md](./HOMELAB_REVIEW_2025_12_17.md))
**Code Review**: 2025-12-23 ([CODE_REVIEW_2025_12_23.md](./CODE_REVIEW_2025_12_23.md)) - Full codebase analysis (89/100, A-)
**Previous Review**: 2025-10-27 ([COMPREHENSIVE_CODEBASE_REVIEW.md](./COMPREHENSIVE_CODEBASE_REVIEW.md))
**Historical Archive**: [HOMELAB_HISTORY.md](./HOMELAB_HISTORY.md) - Completed tasks & changelog (Oct-Nov 2025)

---

## 📊 EXECUTIVE SUMMARY

### Overall Grade: **A (94/100) - Excellent** ⬆️

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
- **🆕 Rebuilderd - Arch Linux Contribution** ⭐ (2025-12-24, Updated: 2026-01-26)
  - Reproducible build verification for Arch Linux packages
  - worker-node: 1 worker, 6 CPU (600%), 18GB RAM, **09:00-23:00 daily (14h)**
  - worker-node-2: 1 worker, 4 CPU (400%), 18GB RAM, **24/7**
  - Build timeout: 48 hours (for large packages like python-aotriton)
  - LVM-backed storage for builds
  - CPU/RAM quota fix: Patched archlinux-repro to pass limits to nspawn containers ([PR #143](https://github.com/archlinux/archlinux-repro/pull/143))
  - Kernel watchdog: nmi_watchdog + softlockup/hardlockup panic enabled for crash detection
- Default credential elimination on all apps
- **🆕 Comprehensive Security Headers & Protections** ⭐ (2025-10-30)
  - **Phase 1 (Completed)**: Safe security headers (X-Content-Type-Options, X-Frame-Options, Referrer-Policy, Permissions-Policy)
  - **Phase 2 (Completed)**: HSTS deployment - Dual layer (Cloudflare edge: 1 month, Traefik origin: 1 week)
  - **Phase 3 (Completed)**: Rate limiting with monitoring - Standard (100/min + 150 burst), High-frequency (200/min + 300 burst)
  - **Phase 4 (Completed)**: CSP enforcement mode (deployed 2025-10-31, 43 days production, zero violations)
  - **Coverage**: All 17 services (14 apps + Grafana + AlertManager + CouchDB)
  - **Monitoring**: 6 Prometheus alerts for rate limiting (attack detection, false positive detection)
  - **HSTS Complete**: ✅ Step 3 deployed 2026-01-09 (max-age=1 year)

**Critical Gaps (from 2025-10-27 Comprehensive Review)** 🔴
- ✅ **Backup replication to worker-node-2** (P0-CRITICAL) - COMPLETED (2025-12-18) - rsync CronJob at 4AM daily
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
- ✅ **Backup replication to worker-node-2** (4:00 AM, rsync over SSH) ⭐ NEW
- ✅ Disaster recovery scripts complete (`.backup/` directory)
- ✅ Backup validation completed (2025-10-26)
- ✅ Storage optimized: 2.3GB per node (was 580GB before Immich exclusion)

---

## 🎯 CRITICAL ACTION ITEMS

**Last Updated**: 2026-01-09 (Comprehensive Review)
**Source**: [HOMELAB_REVIEW_2025_12_17.md](./HOMELAB_REVIEW_2025_12_17.md)
**Previous Reviews**: [COMPREHENSIVE_CODEBASE_REVIEW.md](./COMPREHENSIVE_CODEBASE_REVIEW.md)
**Completed Items**: See [HOMELAB_HISTORY.md](./HOMELAB_HISTORY.md) for detailed completed task archive

### 🔍 January 2026 Comprehensive Review (NEW)

**Review Date**: 2026-01-09
**Reviewer**: Staff DevOps/SRE + Staff Software Developer
**Overall Status**: ✅ **HEALTHY** - Minor gaps identified

#### Infrastructure Health (Staff DevOps/SRE Perspective)

| Component | Status | Details |
|-----------|--------|---------|
| **Nodes** | ✅ 3/3 Ready | K3s v1.35.0, Kernel 6.18.7-arch1-1 |
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
| promtail | Host log access | DaemonSet, read-only mounts |
| home-assistant | Hardware integrations | NetworkPolicy, capability restrictions |

#### Code Quality (Staff Software Developer Perspective)

| Check | Status | Notes |
|-------|--------|-------|
| Image tags | ✅ All pinned | No :latest tags in use |
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

**Next Review**: 2026-02-09 (Monthly)

---

### 🚨 December 2025 Review Findings

| Priority | Issue | Status | Action |
|----------|-------|--------|--------|
| P0 | worker-node-2 has no swap | ✅ FIXED | 16GB LVM swap added (2025-12-18) |
| P0 | Stale mariadb backup directory | ✅ FIXED | Archived and removed (2025-12-18) |
| P1 | Kyverno violations returned (22) | ✅ FIXED | Percona operator limits added (2025-12-18) |
| P1 | Popeye score dropped (87/100) | ✅ FIXED | Score restored to 100/100 (2025-12-18) |
| P1 | ContainerMemoryNearLimit alert | ✅ FIXED | PriceBuddy apprise limit increased (2025-12-18) |
| P1 | Monitoring not HA | ✅ FIXED | Prometheus/Alertmanager 2 replicas with anti-affinity (2025-12-18) |
| P1 | MySQL HAProxy no anti-affinity | ✅ FIXED | Added antiAffinityTopologyKey (2025-12-18) |
| P1 | AdGuard Home DNS missing worker-node-2 | ✅ FIXED | Added 192.168.1.126 to DNS rewrites (2025-12-18) |
| P2 | PVC distribution imbalanced | ✅ ACCEPTED | Expected: worker-node-2 only has DB replicas (110Gi vs 600Gi) |
| P2 | Resource governance reduced | ✅ FIXED | Added quotas for pricebuddy, backup-replication, percona-mysql (2025-12-18) |

**Full Details**: See [HOMELAB_REVIEW_2025_12_17.md](./HOMELAB_REVIEW_2025_12_17.md)

---

### 🔍 Code Review Findings (2025-12-23)

**Source**: [CODE_REVIEW_2025_12_23.md](./CODE_REVIEW_2025_12_23.md)
**Overall Score**: 89/100 (A-)

#### High Priority (This Month)

| # | Item | Effort | Impact | Status |
|---|------|--------|--------|--------|
| 41 | Add PostgreSQL egress NetworkPolicy | 30 min | Security | ✅ Done (9589c59) |
| 42 | Add Loki health alerts | 1 hour | Observability | ✅ Done (9589c59) |
| 43 | Document secrets rotation schedule | 1 hour | Security | ✅ Done (SECRETS_ROTATION.md updated) |
| 44 | Enforce `disallow-latest-tag` Kyverno policy | 15 min | Security | ✅ Done (9589c59) |
| 45 | Add Traefik service alerts | 1 hour | Observability | ✅ Done (9589c59) |

#### Medium Priority (This Quarter)

| # | Item | Effort | Impact | Status |
|---|------|--------|--------|--------|
| 46 | ~~Create Kustomize components for DRY~~ | N/A | N/A | ❌ Declined (complexity vs benefit) |
| 47 | ~~Standardize NetworkPolicy label selectors~~ | N/A | N/A | ✅ Documented as intentional design |
| 48 | Add backup monitoring Grafana dashboard | 2 hours | Observability | ✅ Done (grafana-dashboards/) |
| 49 | Document RBAC decisions per app | 2 hours | Documentation | ✅ Done (CODE_REVIEW §5.RBAC) |
| 50 | ~~Add Etcd availability alerts~~ | N/A | N/A | ❌ N/A (K3s single-master uses SQLite) |

#### DRY Refactoring Opportunities

**Status**: ❌ Declined (2025-12-23) - Complexity outweighs benefit for homelab scale.

Duplication exists but is acceptable for transparency and ease of maintenance.

---

### ✅ Completed P0-CRITICAL Items (Summary)

| Item | Date | Commit | Notes |
|------|------|--------|-------|
| PostgreSQL NetworkPolicy | 2025-10-27 | a80d4bf | Restricts DB access to app namespaces |
| cert-manager ClusterIssuers | 2025-10-27 | 2cb9e78 | Removed duplicate, kept single source |
| CNPG WAL Archiving | N/A | - | ❌ Not implementing (pg_dump acceptable) |

### 🛡️ SECURITY HARDENING (Active)

#### ✅ **HSTS Max-Age Optimization** - COMPLETED (2026-01-09)
   - **Final**: `max-age=31536000` (1 year) on all 17 ingresses
   - **Gradual Rollout**: ✅ Step 1 (1mo) → ✅ Step 2 (6mo) → ✅ Step 3 (1yr)
   - **Commits**: 5e109cd, 793a247

#### ✅ CSP Enforcement - COMPLETED (2025-10-31)
   - 43 days in production, zero violations, 85 automated tests passed

---

### ⚠️ P1-HIGH (Active Items Only)

#### ⏸️ **Automated Backup Validation Testing** - DEFERRED to February 2026
   - Manual validation (last: 2025-10-26) sufficient for now
   - Plan to implement alongside NAS setup in February 2026
   - Makes sense to validate full backup chain (local → worker-node-2 → NAS)

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
| Deploy Velero for cluster backups | 4-6h | P2 |
| Implement backup immutability (S3 object lock/ZFS) | 2-4h | P2 |
| SOPS multi-key encryption | 4h | P2 |

#### 🔒 **ReadOnlyRootFilesystem Security Hardening** (P2-MEDIUM) - PHASE 1-3 COMPLETE ✅

**Investigation Date**: 2025-12-18
**Implementation Date**: 2025-12-18 (Phase 1+2), 2025-12-23 (Phase 3)
**Current State**: 13/16 apps have readOnlyRootFilesystem enabled (was 3, +10 containers hardened)
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

| Pending Item | Priority |
|--------------|----------|
| Backup alert grouping to Telegram thread | P3 |
| Grafana dashboards for app metrics | P3 |
| PrometheusRules for custom app metrics | P3 |

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

#### 37. **Offsite Backup Replication to NAS** ⏸️ BLOCKED
   - **Status**: BLOCKED - Waiting for 24TB NAS hardware arrival (~February 25, 2026)
   - **Priority**: P0-CRITICAL (deferred until NAS available)
   - **Risk**: Complete data loss if worker node fails
   - **Impact**: All backups currently stored on single node `/mnt/k8s-storage/backups/`
   - **Current RPO**: 24 hours
   - **Current RTO**: Infinite (if node hardware fails)
   - **Mitigation**: Backup replication to worker-node-2 provides some redundancy
   - **Action**:
     1. Set up 24TB NAS on local network
     2. Configure rsync CronJob (daily at 4 AM, 1h after local backups)
     3. Test backup replication and restore procedures
     4. Update disaster recovery documentation
   - **Estimated Effort**: 4-6 hours total
     - NAS setup: 2 hours
     - rsync CronJob configuration: 1 hour
     - Testing: 1-2 hours
     - Documentation: 1 hour
   - **Target Date**: ~February 25, 2026 (upon NAS arrival)
   - **Files**: New CronJob manifest in `infrastructure/configs/staging/backup/offsite-replication.yaml`
   - **Benefit**: Protects against node hardware failure, data center disaster
   - **Note**: DO NOT NAG UNTIL LATE FEBRUARY 2026

#### 38. **Second Worker Node** 🖥️ ✅ COMPLETED
   - **Status**: ✅ DEPLOYED - 2025-12-15 (ahead of schedule!)
   - **Priority**: ~~P1-HIGH~~ COMPLETED
   - **Node Details**:
     - **Hostname**: worker-node-2 (192.168.1.126)
     - **User**: z3us
     - **Hardware**: 30GB RAM, 1TB NVMe (system) + 3.6TB NVMe (k8s-storage)
     - **Kernel**: 6.18.7-arch1-1
     - **K3s**: v1.35.0+k3s1
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
   - **Documentation**: `docs/SECOND_WORKER_NODE_SETUP.md` (used for deployment)

#### 39. **Switch to LTS Kernel 6.18** 🐧 WAITING ON ARCH
   - **Status**: ⏸️ Running mainline 6.18.6, waiting for Arch to package 6.18 LTS
   - **Priority**: P2-MEDIUM (stability improvement)
   - **Target Date**: ~~End of January 2026~~ → TBD (Arch hasn't switched yet)
   - **Current State**: All 3 nodes have mainline kernel **6.18.7-arch1-1** installed (not LTS)
   - **Blocker**: Arch `linux-lts` still at 6.12.67 (checked 2026-01-29)
     - Linux 6.18 released upstream: Nov 30, 2025 (confirmed LTS, supported until Dec 2027)
     - Arch taking longer than typical 4-8 weeks to transition LTS kernel series
     - Expected availability: Unknown - check https://archlinux.org/packages/core/x86_64/linux-lts/
   - **Scope**: All 3 nodes (control-plane, worker-node, worker-node-2)
   - **Hardware Compatibility**: ✅ Verified
     - Intel N100 (Alder Lake-N): Supported since 6.1+
     - AMD Ryzen 9 9955HX (Zen 5): Supported since 6.10+ (included in 6.18)
     - Intel I226-V (igc): Driver fixes in 6.6+
     - AMD Radeon integrated (amdgpu): Mature by 6.12+
   - **Procedure**:
     1. Check 6.18 LTS availability: `pacman -Si linux-lts | grep Version`
     2. Wait ~1 week after 6.18 appears for initial patches (6.18.1, 6.18.2)
     3. Install on control plane first: `sudo pacman -S linux-lts linux-lts-headers`
     4. Update bootloader: `sudo bootctl update`
     5. Reboot and verify: `uname -r`
     6. Repeat on worker node
     7. Keep mainline kernel installed for rollback option
   - **Benefit**: Long-term stability, 2+ year support (until Dec 2027), security backports
   - **Rollback**: Boot into mainline kernel from bootloader menu if issues
   - **Note**: Check weekly until end of January 2026

#### 40. **Re-evaluate VictoriaMetrics** 📊 DEFERRED
   - **Status**: DEFERRED - Waiting for metricRelabelConfigs bug fix
   - **Priority**: P3-LOW (optimization opportunity)
   - **Target Date**: February 2026
   - **Background**:
     - Attempted migration on 2025-11-15, aborted due to bug
     - Issue: `metricRelabelConfigs` not functioning in VMNodeScrape/VMServiceScrape
     - Result: VictoriaMetrics collected 48% MORE series than Prometheus (defeating purpose)
   - **Bug Tracking**:
     - GitHub Issue: [#9951](https://github.com/VictoriaMetrics/VictoriaMetrics/issues/9951) (still OPEN as of 2025-12-02)
     - Workaround exists (use both relabelConfig + metricRelabelConfig) but not a real fix
   - **Action in Feb 2026**:
     1. Check if issue #9951 is resolved
     2. If fixed, test VictoriaMetrics in staging with metric drops
     3. Compare series count vs Prometheus
     4. If working, plan migration for memory/disk savings
   - **Expected Benefits** (if bug fixed):
     - ~2-5x RAM reduction
     - ~7x disk reduction (zstd compression)
     - Native downsampling for long retention
   - **Current Mitigation**: Prometheus retention increased to 90d (2025-12-02)
   - **Note**: DO NOT NAG UNTIL FEBRUARY 2026

---

## 🛠️ NODE MANAGEMENT SCRIPTS

Scripts for node-level configuration stored in `docs/scripts/`. Run manually when needed.

### Graceful Node Shutdown Configuration
Configures K3s kubelet for proper pod eviction during node reboots/shutdowns.

| Script | Node | Run Command |
|--------|------|-------------|
| `graceful-shutdown-master.sh` | gmk-k3s-control-plane | `sudo bash /tmp/graceful-shutdown-master.sh` |
| `graceful-shutdown-worker-1.sh` | worker-node | `sudo bash /tmp/graceful-shutdown-worker-1.sh` |
| `graceful-shutdown-worker-2.sh` | worker-node-2 | `sudo bash /tmp/graceful-shutdown-worker-2.sh` |

**What they configure:**
- `/etc/rancher/k3s/kubelet.yaml`: KubeletConfiguration with `shutdownGracePeriod: 120s`
- `/etc/rancher/k3s/config.yaml`: References kubelet config file
- `/etc/systemd/system.conf`: `DefaultTimeoutStopSec=120s`
- systemd service override: `TimeoutStopSec=150s` (120s + buffer)

**Status** (2025-12-20):
- ✅ Control-plane: Configured (`shutdownGracePeriod: 2m0s`)
- ✅ Worker-1: Configured (`shutdownGracePeriod: 2m0s`)
- ✅ Worker-2: Configured (`shutdownGracePeriod: 2m0s`)

### Firmware Management
Installs required firmware and removes unnecessary AUR packages.

| Script | Node | Hardware |
|--------|------|----------|
| `firmware-master.sh` | gmk-k3s-control-plane | Intel N100, Intel UHD, Realtek WiFi, Intel I226-V |
| `firmware-worker-1.sh` | worker-node | AMD Ryzen 9 9955HX, AMD Radeon, MediaTek WiFi, Intel NICs |
| `firmware-worker-2.sh` | worker-node-2 | AMD Ryzen 7 8745H, AMD Radeon 780M, MediaTek WiFi |

**What they do:**
- Install required: `intel-ucode`/`amd-ucode`, `linux-firmware`, `linux-firmware-whence`
- Remove unnecessary AUR packages: `aic94xx-firmware`, `ast-firmware`, `upd72020x-fw`, `wd719x-firmware`

**Status** (2025-12-20): ✅ All 3 nodes cleaned (no reboot required)

### Performance Optimization
Applies CPU governor, kernel tuning for K8s, and network optimizations.

| Script | Node | Run Command |
|--------|------|-------------|
| `optimize-master.sh` | gmk-k3s-control-plane | `sudo bash /tmp/optimize-master.sh` |
| `optimize-worker-1.sh` | worker-node | `sudo bash /tmp/optimize-worker-1.sh` |
| `optimize-worker-2.sh` | worker-node-2 | `sudo bash /tmp/optimize-worker-2.sh` |

**What they configure:**
- CPU governor → `performance` (consistent low latency, persists via tmpfiles.d)
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

**Health Score: 94/100** (A Grade) - Updated 2026-01-09 ⬆️
- **Security**: 96/100 (A+) ✅ - 100% PSS, 100% NetworkPolicy (apps + infra namespaces)
- **Backup/DR**: 92/100 (A) ✅ - Daily backups + replication to worker-node-2
- **Database**: 90/100 (A) ✅ - PostgreSQL HA + MySQL HA, NetworkPolicy, TLS
- **Infrastructure**: 88/100 (A-) ✅ - Flux/Traefik solid, all controllers healthy
- **Maintainability**: 95/100 (A) ✅ - Excellent docs, GitOps-driven
- **Best Practices**: 92/100 (A) ✅ - Popeye scheduled, Kyverno enforced, resource governance
- **Performance**: 92/100 (A-) ✅ - Resource optimization, 91% efficiency

**Overall Grade**: A (94/100) - Up from A- (92/100) after Jan 2026 review ⬆️
- **Critical Issues**: 0 P0 issues ✅
- **High Priority**: 1 P1 deferred (automated backup validation - Q1 2026)
- **Total Findings**: All actionable items from Oct-Dec 2025 reviews completed

**Target**: 96/100 (A+) - requires automated backup validation + offsite NAS

**Security Achievements** ✅:
- **100% Pod Security Standards** (Apps: 11 restricted, 4 baseline, 1 privileged | Jobs: 5 restricted, 1 baseline)
- **100% NetworkPolicy Coverage** (16 apps + 5 infra namespaces) ⬆️
- **100% SOPS Encryption** for secrets
- **100% Image Version Pinning** (no :latest tags)
- **100% SSO Coverage** (8/8 applicable apps)
- **100% HSTS Coverage** (max-age 1 year on all 17 ingresses) ⬆️
- **Popeye Weekly Health Scan** (Sunday 6 AM) ⬆️

**Resolved Critical Gaps** ✅:
- ✅ Backup replication to worker-node-2 (completed 2025-12-18)
- ✅ PostgreSQL NetworkPolicy (completed 2025-10-27)
- ✅ Duplicate cert-manager ClusterIssuers (completed 2025-10-27)
- ✅ All infrastructure NetworkPolicies (completed 2026-01-09)

---

## 📱 CURRENT APPS (16 total)

| App | Status | Security | OIDC/SSO | Notes |
|-----|--------|----------|----------|-------|
| **Homepage** | ✅ Running | ✅ NetworkPolicy | - | **Dashboard - Single pane of glass** ⭐ |
| **Uptime Kuma** 🆕 | ✅ Running | ✅ NetworkPolicy | - | **Uptime monitoring** - MariaDB, Automated setup ⭐ |
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
- 🔮 **Future**: 24TB NAS planned for backups

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
- **Replicas**: 3 (HA configuration) ⭐
- **Version**: PostgreSQL 18.x
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
- **Exporter**: oliver006/redis_exporter:v1.66.0-alpine
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

**PostgreSQL (3 Replicas)**: ✅ **High Availability Required**
- **Usage**: Critical application data (Authentik, Immich, Paperless, Grafana, etc.)
- **Replicas**: 3 instances (1 primary, 2 standby)
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
- **Critical data (PostgreSQL)**: 3 replicas, HA, zero downtime
- **Critical data (MySQL)**: 2 replicas, Percona async replication, Orchestrator failover
- **Cache/ephemeral (Redis)**: Single instance, restart tolerance acceptable
- **Personal sync (CouchDB)**: Single instance, backup-based recovery acceptable

---

**Last Updated**: 2026-01-09
**Next Review**: 2026-02-09

---

## 📝 CHANGELOG (Recent)

*For older entries, see [HOMELAB_HISTORY.md](./HOMELAB_HISTORY.md)*

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
  - **worker-node**: Stays on 09:00-23:00 schedule (shared with k8s workloads)
- 📋 **Scripts Updated**: `setup-rebuilderd-worker-1.sh`, `setup-rebuilderd-worker-2.sh`

### 2026-01-06 (Rebuilderd Schedule Change) 🕐
- ✅ **Schedule Changed**: 24/7 → 09:00-23:00 daily (14 hours) ⭐
  - **Both nodes**: worker-node (600% CPU) and worker-node-2 (400% CPU)
  - **Rationale**: Reduce resource contention during off-hours
  - **Implementation**: Replaced boot timer with start/stop timers
  - **Graceful shutdown**: TimeoutStopSec=7200 allows current builds to complete
  - **Scripts Updated**: `setup-rebuilderd-worker-1.sh`, `setup-rebuilderd-worker-2.sh`

### 2025-12-31 (K3s Upgrade to v1.35.0) 🚀
- ✅ **K3s Cluster Upgrade**: All 3 nodes upgraded to v1.35.0+k3s1 ⭐
  - **gmk-k3s-control-plane**: v1.34.2+k3s1 → v1.35.0+k3s1
  - **worker-node**: v1.34.2+k3s1 → v1.35.0+k3s1
  - **worker-node-2**: v1.34.2+k3s1 → v1.35.0+k3s1
  - **Components**: Containerd 2.1.5-k3s1, Go 1.25.5
  - **Pods**: 104 running, all HelmReleases healthy
  - **Note**: Worker nodes require K3S_URL and K3S_TOKEN for agent install
- ✅ **Bash History Expansion Fix**: Disabled `!!` expansion to prevent sudo password issues ⭐
  - **Root Cause**: Password ending with `!!` triggered bash history expansion intermittently
  - **Fix**: Added `set +H` to ~/.bashrc on all 3 nodes
  - **Script**: `/tmp/fix-bash-history-expansion.sh`

### 2025-12-30 (Rebuilderd OOM Fix & Telegram Template Improvement) 🔧
- ✅ **Rebuilderd MAX_MEMORY Fix**: nspawn containers now properly memory-limited ⭐
  - **Root Cause**: `MemoryMax=6G` only limited rebuilderd-worker process, not child nspawn containers
  - **Analysis**: Kernel OOM killer invoked (`cc1plus invoked oom-killer`, `ld.lld` used 5.3GB RAM)
  - **Fix**: Added `Environment="MAX_CPU=..." "MAX_MEMORY=6G"` to systemd drop-in
  - **Impact**: Nspawn containers now receive `--property="MemoryMax=6G"` from archlinux-repro patch
- ✅ **Worker Configuration Updated**: Better resource allocation ⭐
  - **worker-node**: 4 → 3 workers × 400% CPU × 6GB RAM (18GB total, scheduled 2am-9am)
  - **worker-node-2**: 1 worker × 400% CPU × 18GB RAM (09:00-23:00 daily)
  - **Scripts Updated**: `docs/scripts/setup-rebuilderd-worker-1.sh`, `docs/scripts/setup-rebuilderd-worker-2.sh`
- ✅ **MySQL-0 OOMKilled Recovery**: Pod caught in rebuilderd OOM crossfire ⭐
  - **Symptom**: mysql-0 1/2 ready with 14 restarts, exit code 137 (OOMKilled)
  - **Fix**: Pod deleted and recreated, replication resumed from mysql-1
  - **Result**: Cluster healthy, 2/2 ready, 0s replication lag
- ✅ **Telegram Alert Template Improved**: Prevents HTML truncation ⭐
  - **Problem**: 34 stale PodCrashLooping alerts → 4096 char Telegram limit → broken HTML tags
  - **Fix**: New template limits to 5 alerts per message with "...and X more" summary
  - **Format**: `FIRING (34 alerts) • AlertName [namespace] summary ...and 29 more`
  - **Commit**: d336149
- ✅ **Alertmanager Queue Cleared**: Restarted to flush stale notifications
- ✅ **Kernel Watchdog Enabled** (earlier in day): Better crash detection
  - `kernel.nmi_watchdog=1`, `kernel.softlockup_panic=1`, `kernel.hardlockup_panic=1`
  - Config: `/etc/sysctl.d/99-watchdog.conf` on both nodes

### 2025-12-29 (Health Review & Rebuilderd Multi-Worker Fix) 🔍
- ✅ **Health Review Complete**: All systems healthy, no issues found ⭐
  - **Nodes**: 3/3 Ready (control-plane 19% CPU, worker-node 0%, worker-node-2 2%)
  - **PostgreSQL**: 2/2 healthy (Cluster in healthy state)
  - **MySQL**: 2/2 ready + 2 HAProxy replicas
  - **CouchDB**: 2/2 running
  - **Redis**: Running
  - **Popeye Score**: 100/100 (A grade)
  - **Kyverno Violations**: 14 (all null/null from ephemeral pods - not actionable)
  - **Alerts**: None firing
- ✅ **Rebuilderd Multi-Worker Fix**: Corrected worker count for proper CPU utilization ⭐
  - **Issue**: Timer was starting single worker (`@1`) regardless of CPU allocation
  - **Root Cause**: `-n` flag is worker name, not concurrency; 1 worker = 1 concurrent build
  - **Fix**: Start multiple worker instances for parallel builds
  - **worker-node**: 6 workers (`@1`-`@6`) for 12 CPU cores
  - **worker-node-2**: 3 workers (`@1`-`@3`) for 6 CPU cores
  - **Rationale**: ~2 cores per worker for balanced throughput (not 1:1 to avoid contention)
  - **Scripts**: `/tmp/fix-rebuilderd-worker1.sh`, `/tmp/fix-rebuilderd-worker2.sh`
- ✅ **NVMe PM Fix**: Updated setup-node.sh with tmpfiles.d for boot reliability ⭐
  - Added `/etc/tmpfiles.d/nvme-no-pm.conf` for consistent NVMe PM settings
  - Dual udev rule approach (PCI + block device trigger)
  - Applied to all 3 nodes, verified PM=on
- ✅ **Cluster Cleanup**: Deleted 13 stale ReplicaSets, 3 old jobs
- ✅ **Storage Health**:
  - worker-node: 242GB / 4.2TB (6%)
  - worker-node-2: 68GB / 863GB (9%)
  - Backup replication: ~2.5GB on worker-node-2
- 📋 **Commits**: 389585f (NVMe PM fix)

### 2025-12-26 (Rebuilderd CPU Quota Fix & Upstream PR) 🔧
- ✅ **CPU Quota Fix for nspawn Containers**: Patched archlinux-repro to pass CPU limits ⭐
  - **Problem**: nspawn containers with `--register=no` bypass parent cgroup CPU limits
  - **Solution**: Added `--property="CPUQuota=${MAX_CPU}"` to nspawn call (mirrors existing MAX_MEMORY pattern)
  - **Upstream PR**: [archlinux/archlinux-repro#143](https://github.com/archlinux/archlinux-repro/pull/143)
  - **Patch Applied**: Both worker nodes running patched version
- ✅ **3-Hour Verification Test**: CPU limits confirmed working ⭐
  - **worker-node**: Peak 39% CPU (was 99% before fix) - 1,167 packages processed
  - **worker-node-2**: Peak 33% CPU - 508 packages processed
  - **Zero CPU alerts** during test period
  - cgroup cpu.max correctly shows limits (1200000/100000, 600000/100000)
- ✅ **worker-node-2 CPU Increased**: 5 cores → 6 cores (500% → 600%)
- ✅ **Schedule Extended**: 2am-8am → 2am-9am (7 hours instead of 6)
- 🔧 **Scripts Created** (`/tmp/` on nodes):
  - `configure-rebuilderd-cpu-limit.sh` - Initial CPU limit setup
  - `test-rebuilderd-cpu-limits.sh` - Verification test script
  - `monitor-rebuilderd-3hr.sh` - 3-hour monitoring with 10-min intervals
  - `update-cpu-limit-worker2.sh` - CPU increase from 5 to 6 cores
  - `update-rebuilderd-schedule.sh` - Schedule change script
- 📋 **Commits**: Patch script in `docs/scripts/patch-archlinux-repro-cpu.sh`

### 2025-12-24 (LVM Migration & Rebuilderd Setup) 💾
- ✅ **Rebuilderd Contribution to Arch Linux**: Nightly builds for reproducible package verification ⭐
  - **Schedule**: 2:00 AM - 9:00 AM daily (7 hours)
  - **worker-node**: 2 workers, 12 CPU cores (1200%), 24GB RAM (12GB/worker)
  - **worker-node-2**: 2 workers, 6 CPU cores (600%), 18GB RAM (9GB/worker) - reduced for thermal headroom
  - **Concurrency**: Each worker = 1 build (6 cores on worker-node, 3 cores on worker-node-2)
  - **Storage**: LVM-backed builds (not tmpfs/RAM)
  - **Purpose**: Verify Arch Linux binary packages are reproducible
  - **Graceful stop**: Current build completes before timer stop
- ✅ **LVM Storage Migration - worker-node-2**: Root SSD freed ~14.5GB ⭐
  - `/var/lib/kubelet` → `/mnt/extra-storage/kubelet` (bind mount)
  - `/var/lib/rebuilderd-worker` → `/mnt/extra-storage/rebuilderd-worker` (symlink)
  - `/var/lib/repro` → `/mnt/extra-storage/repro` (symlink)
  - **Result**: Root SSD 37% → 8% used (3.5G/50G)
- ✅ **LVM Storage Migration - worker-node**: Root SSD freed ~30GB ⭐
  - `/var/lib/kubelet` → `/mnt/k8s-storage/kubelet` (bind mount)
  - `/var/lib/rebuilderd-worker` → `/mnt/k8s-storage/rebuilderd-worker` (symlink)
  - `/var/lib/repro` → `/mnt/k8s-storage/repro` (symlink)
  - **Result**: Root SSD → 6% used (2.7G/49G)
- ✅ **Disk Cleanup**: Both nodes cleaned
  - Pacman cache (paccache -rk2)
  - Journal logs (vacuum to 100MB)
  - Old swapfile removed on worker-node-2 (6.4GB)
  - Unused container images pruned
- 🔧 **Scripts Created** (`docs/scripts/`):
  - `configure-rebuilderd-storage.sh` - LVM storage config for builds
  - `migrate-to-lvm-worker1.sh` - Combined migration script
  - `migrate-rebuilderd-to-lvm.sh` - Rebuilderd data migration
  - `cleanup-kubelet-old.sh` - Stale mount cleanup
  - `analyze-disk-usage.sh` - Disk analysis utility
  - `cleanup-disk.sh` - Disk cleanup utility

### 2025-12-23 (Comprehensive Code Review) 📋
- ✅ **Full Codebase Review Completed**: 89/100 (A-) overall score ⭐
- 📊 **Category Scores**:
  - Project Structure: 95/100 (A)
  - Kubernetes Patterns: 88/100 (A-)
  - Database Infrastructure: 92/100 (A)
  - Monitoring Stack: 85/100 (B+)
  - Security Implementation: 94/100 (A)
  - Backup & DR: 96/100 (A+)
  - Code Quality (DRY): 72/100 (B-)
  - Documentation: 93/100 (A)
- 🔍 **Key Findings**:
  - 394 YAML files, 15 apps with consistent base/staging pattern
  - 100% NetworkPolicy coverage, 100% Pod Security Standards compliance
  - Enterprise-grade backup with geographic replication
  - DRY violations: 30-40% file reduction possible with Kustomize components
- 📋 **Action Items Added**: 14 new items (#41-54) across High/Medium/Low priority
- 🔧 **Top 5 High Priority**:
  1. PostgreSQL egress NetworkPolicy (30 min)
  2. Loki health alerts (1 hour)
  3. Secrets rotation documentation (1 hour)
  4. Enforce disallow-latest-tag policy (15 min)
  5. Traefik service alerts (1 hour)
- 📄 **Documentation**: [CODE_REVIEW_2025_12_23.md](./CODE_REVIEW_2025_12_23.md)

### 2025-12-23 (ReadOnlyRootFilesystem Phase 3 Complete) 🔒
- ✅ **Phase 3 Complete**: Enabled readOnlyRootFilesystem on 3 remaining Tier 3 apps ⭐
  - **linkwarden**: Already had emptyDirs for /tmp, /app/.next/cache, /home/node/.cache - just enabled flag
  - **immich-ml**: Added /tmp emptyDir via persistence section
  - **immich-proxy**: Added /tmp emptyDir via postRenderer patch
- 🔧 **Key Findings**:
  - Immich ignores HOST/IMMICH_HOST env vars (bug) - nginx proxy sidecar required
  - bjw-s chart advancedMounts doesn't work - used postRenderer JSON patch instead
- ✅ **Verification**:
  - Linkwarden: SSO login redirects to Authentik correctly
  - Immich: API responds with pong, version 2.4.1
  - All containers have writable /tmp via emptyDir
- 📊 **Outcome**: 13/16 apps now have readOnlyRootFilesystem (was 10, +3 hardened)
- 📋 **Commits**: 3d4d533

### 2025-12-22 (CouchDB Backup Reliability Fix) 💾
- ✅ **Backup Job Fixed**: 10/10 tests passed, completes in 5-7 seconds (was failing or timing out at 300s+) ⭐
- 🎯 **Root Cause**: couchbackup tool returns non-zero exit code even when data is successfully written
- 🔧 **Fix**: Check for actual JSON data in output file instead of relying on exit code
  - Changed from `if couchbackup ...; then` to `couchbackup ... || true` then check `grep -q "^\["`
  - Added `2>&1` still present but `|| true` ignores exit code
  - Success now determined by presence of JSON array lines in backup file
- 📋 **Commits**: 99191e3 (fix), 97baae4 (initial debugging with timing)
- 📊 **Test Results**: 10 sequential tests, all passed (avg 5.6 seconds)
- 🗑️ **Cleanup**: 35 test backup files removed, keeping scheduled backups only

### 2025-12-21 (Firmware Audit & Cluster Recovery) 🔧
- ✅ **Firmware Audit**: All 3 nodes verified current ⭐
  - **Control-plane (GMK NucBox G3)**: BIOS GMK_G3 (2024-10-10), AirDisk 256GB SSD (no updates)
  - **Worker-node (Minisforum MS-A2)**: BIOS 1.02 (2025-06-16, latest), WD SN7100 FW 7615M0WD (latest)
  - **Worker-node-2 (Minisforum UM870)**: BIOS 1.08 (2024-11-05, latest), Kingston+Crucial SSDs (no updates)
  - fwupd/LVFS checked - no updates available for any hardware
- ✅ **Cluster Recovery**: Kernel 6.18.1→6.18.2 reboot handled ⭐
  - 67 stale pods (Completed/Error) cleaned up cluster-wide
  - All critical services verified: cloudflare-tunnel, databases, authentik, flux
  - Uptime Kuma crash-loop alerts resolved (initial restart churn)
- ✅ **Backup Validation**: All systems healthy ⭐
  - PostgreSQL: Dec 21 03:00, 52.5MB
  - CouchDB: Dec 21 03:05, 19.2MB
  - MySQL: Dec 21 03:15, 1003KB
  - PVC: Dec 21 03:10, ~400MB
  - Replication to worker-node-2: ~2.6GB total at /mnt/extra-storage/backups/
- ✅ **Kyverno Violations Resolved**: 25 violations → 0 ⭐
  - Violations were from stale pods after kernel reboot
  - Cleaned up with pod cleanup, policy reports now show 0 violations
  - Popeye score: 100/100

### 2025-12-21 (Prometheus Metric Optimization - Round 2) 📉
- ✅ **Histogram Count/Sum Drops**: Removed orphaned count/sum metrics for already-dropped buckets ⭐
  - apiserver_request_sli_duration_seconds_(count|sum): ~1.2k series
  - apiserver_response_sizes_(count|sum): ~600 series
  - etcd_request_duration_seconds_(count|sum): ~2.8k series
  - Commits: a146b01
- ✅ **Kubelet/Workqueue/Go Runtime Drops**: Removed internal timing metrics
  - kubelet_*_bucket: ~1.5k series (internal kubelet timing)
  - workqueue_(work|queue)_duration_seconds_(count|sum): ~768 series
  - go_(gc_heap_|sched_).*_bucket, go_gc_pauses_seconds_bucket: ~1.3k series
  - Commits: c6f6ae7
- ✅ **Database Metric Drops**: Removed unused feature metrics (~880 series)
  - **PostgreSQL**: cnpg_pg_settings_setting (~570 series) - config as metrics, not useful for alerting
  - **CouchDB**: couchdb_dreyfus_* (~216 series), couchdb_nouveau_* (~48 series) - full-text search not used
  - **MySQL**: mysql_info_schema_innodb_cmp* (~50 series) - compression metrics not used
  - Commits: 6ddb2f1
- ✅ **Scrape Interval Standardization**: All custom monitors aligned to 60s
  - MySQL ServiceMonitor: 30s → 60s
  - PostgreSQL PodMonitor: 30s → 60s
  - Prometheus recording rules: 15 rule groups 30s → 60s
  - Commits: cd0dc79
- 📊 **Results**:
  - **Series count**: ~107k → 97.6k (~10% reduction)
  - **Memory**: 1021Mi / 1300Mi (78% utilization)
  - **CPU overhead**: Reduced by 50% scrape/evaluation frequency on custom monitors
- 🔧 **Files Modified**:
  - `monitoring/controllers/base/kube-prometheus-stack/release.yaml` (metric drops)
  - `infrastructure/configs/base/databases/mysql/servicemonitor.yaml` (interval + drops)
  - `infrastructure/configs/base/databases/postgres/podmonitor.yaml` (interval + drops)
  - `infrastructure/configs/base/databases/couchdb/servicemonitor.yaml` (metric drops)
  - `monitoring/configs/staging/kube-prometheus-stack/prometheus-rules.yaml` (rule intervals)

### 2025-12-20 (Node Management Scripts & Performance Optimization) 🔧
- ✅ **Graceful Node Shutdown Scripts**: Applied to all 3 nodes ⭐
  - Configures K3s kubelet with `shutdownGracePeriod: 120s`
  - Uses KubeletConfiguration file approach (K3s doesn't support shutdown flags via kubelet-arg)
  - Sets systemd `TimeoutStopSec=150s` for buffer
  - All 3 nodes verified via kubelet API (`shutdownGracePeriod: 2m0s`)
  - Commits: 2500924
- ✅ **Firmware Management Scripts**: Applied to all 3 nodes ⭐
  - **Master**: Intel N100 - keeps intel-ucode, linux-firmware
  - **Worker-1**: AMD Ryzen 9 9955HX - keeps amd-ucode, linux-firmware
  - **Worker-2**: AMD Ryzen 7 8745H - keeps amd-ucode, linux-firmware
  - Removed unnecessary AUR packages: aic94xx-firmware, ast-firmware, upd72020x-fw, wd719x-firmware
  - Commits: 79f187c
- ✅ **Performance Optimization Scripts**: Applied to all 3 nodes ⭐
  - CPU governor → `performance` (persists via tmpfiles.d)
  - TCP congestion → BBR, inotify instances → 8192
  - nf_conntrack_max → 1048576, swappiness → 10
  - Commits: aea0f83
- ✅ **mysql-exporter CPU Throttling Fixed**: Increased CPU limit 100m → 200m
  - Commit: 5d4a192
- ✅ **Post-Reboot Cleanup**: Deleted 65 stale pods after 3-node sequential reboot
  - All deployments recovered with healthy running pods
  - Transient authentik resource alerts (post-reboot spike)

### 2025-12-18 (ReadOnlyRootFilesystem Implementation - Phase 1+2) 🔒
- ✅ **Phase 1 Complete**: Enabled readOnlyRootFilesystem on 3 apps (Tier 1 - zero risk) ⭐
  - **paperless-ngx**: Already had emptyDir volumes, just enabled flag (e1d5e5b)
  - **authentik-server**: Changed from false to true (3c1fddb)
  - **authentik-worker**: Changed from false to true (5213a69)
- ✅ **Phase 2 Complete**: Enabled readOnlyRootFilesystem on 4 apps with /tmp emptyDir (Tier 2 - low risk) ⭐
  - **csp-reporter**: Added full security hardening + /tmp emptyDir (48ba5fc)
  - **homepage**: Added /tmp emptyDir + automountServiceAccountToken: false (9e04864)
  - **homehub**: Added /tmp emptyDir, removed misleading comment (d8da2a0)
  - **uptime-kuma**: Added /tmp emptyDir + runAsNonRoot to pod spec (2034718)
- ✅ **All 7 Apps Verified**:
  - Rollout restarts completed successfully
  - Init containers tested (fix-permissions, copy-config, setup-config, wait-for-server)
  - Setup jobs re-run (uptime-kuma-setup)
  - CSP reporter confirmed receiving and logging violation reports
  - Root filesystem write blocked, /tmp and PVC writes working
- ⏸️ **Phase 3 Deferred**: linkwarden, immich-ml, immich-proxy - deferred to late December 2025
- 📊 **Outcome**: 10 containers with readOnlyRootFilesystem (was 3, +7 hardened)
- 🔒 **Security Benefit**: Reduced attack surface, prevents runtime filesystem tampering
- 🔧 **Key Finding**: PVC-mounted paths remain writable regardless of readOnlyRootFilesystem setting

### 2025-12-18 (Resource Governance Completion) 📊
- ✅ **Resource Governance Gaps Fixed**: Added ResourceQuota and LimitRange for 3 namespaces ⭐
  - pricebuddy: Medium tier (2 CPU / 4Gi request, 8 CPU / 8Gi limit)
  - backup-replication: Small tier (1 CPU / 1Gi request, 2 CPU / 2Gi limit)
  - percona-mysql: Small tier (1 CPU / 2Gi request, 4 CPU / 4Gi limit)
- ✅ **PVC Distribution Decision**: Accepted as expected (worker-node-2 only has DB replicas)
  - worker-node: 25 PVCs (~600Gi) - apps and primary storage
  - worker-node-2: 4 PVCs (~110Gi) - database replicas only
  - Rationale: Rebalancing requires significant effort for minimal benefit
- ✅ **Documentation Updated**: Marked worker-node-2 remaining tasks as completed
- 📋 **Commits**: 9acda51 (resource governance files)

### 2025-12-18 (Backup Replication & Storage Optimization) 💾
- ✅ **Backup Replication to worker-node-2**: rsync CronJob at 4:00 AM daily ⭐
  - SSH key-based auth, SOPS-encrypted secret
  - Syncs postgres, couchdb, mysql, pvc backups
  - Kyverno policy exception for hostPath volumes
  - Tested: 2.3GB replicated successfully
  - Commits: cc70bba (manifests), b79d193 (Immich exclusion)
- ✅ **Immich Excluded from PVC Backups**: Saves ~500GB/node
  - Photos can be re-uploaded from source devices
  - Database (faces, albums, metadata) backed up via PostgreSQL
  - Old Immich backups cleaned up on both nodes
- ✅ **Old MariaDB Archive Deleted**: 25GB reclaimed on each node
- ✅ **Storage Reduced**: 580GB → 2.3GB per node (99.6% reduction!)
- ✅ **Backup Scripts Updated**: Fixed CouchDB namespace, added backup-replication SSH key, n8n-oidc, linkwarden-oidc

### 2025-12-18 (HA Enablement & DNS Configuration) 🔄
- ✅ **Prometheus/Alertmanager HA Enabled**: 2 replicas with hard anti-affinity ⭐
  - Prometheus pods spread across worker-node and worker-node-2
  - Alertmanager pods spread across worker-node and worker-node-2
  - Loki skipped (requires object storage for HA, SingleBinary mode)
  - Commits: release.yaml updated with replicas: 2, podAntiAffinity: "hard"
- ✅ **MySQL HAProxy Anti-Affinity Added**: Pods now spread across worker nodes
  - Added `affinity.antiAffinityTopologyKey: kubernetes.io/hostname`
  - Verified: HAProxy-0 on worker-node, HAProxy-1 on worker-node-2
- ✅ **AdGuard Home DNS Updated**: Added worker-node-2 to DNS rewrites
  - Both 192.168.1.129 and 192.168.1.126 now in `*.h0melab.work` rewrites
  - Enables DNS-based failover for internal services
  - Commit: cbf4ac6
- ✅ **Uptime Kuma Monitors Verified**: worker-node-2 already monitored
  - SSH monitor (id=34) and kubelet monitor (id=37) already active
- 🔧 **Stale Alerts Resolved**: NodeDown alerts from pod restarts during HA enablement
- 🔧 **CouchDB Backup Job**: Failed job cleaned up (backup file was created successfully)

### 2025-12-18 (December Review Remediation) 🔧
- ✅ **worker-node-2 LVM Resize**: Root disk expanded and swap added ⭐
  - Root: 20GB → 50GB (was 100% full)
  - Home: 932GB → 10GB (freed for other use)
  - Swap: 16GB LVM (new)
  - Extra: 863GB at /mnt/extra-storage
- ✅ **Kyverno Violations Fixed**: 22 → 0 violations
  - Added resource limits to Percona MySQL operator HelmRelease
  - Commit: f67f9ba
- ✅ **Popeye Score Restored**: 87/100 → 100/100
  - Deleted 13 orphaned MariaDB ClusterRoleBindings
  - Deleted orphaned CouchDB NetworkPolicy in default namespace
- ✅ **PriceBuddy Memory Alert Fixed**: Apprise container limit 210Mi → 300Mi
  - Commit: 2c68eda
- ✅ **Stale MariaDB Backup Archived**: `/mnt/k8s-storage/backups/mariadb` removed
- ✅ **Old K3s Data Cleaned**: Freed 12GB on worker-node-2 root partition
- 🔧 **Resolved Alerts**: ContainerMemoryNearLimit, PostgreSQLPodNotRunning, MySQLPodNotRunning
- 📋 **Review Reference**: [HOMELAB_REVIEW_2025_12_17.md](./HOMELAB_REVIEW_2025_12_17.md)

### 2025-12-17 (MySQL Performance Tuning & Monitoring) ⚡
- ✅ **Prometheus Monitoring Enabled**: Standalone mysqld-exporter deployment with ServiceMonitor ⭐
- ✅ **Memory Optimization**: Right-sized buffer pool (512MB) for actual 18.6MB data
- ✅ **Binlog Retention Reduced**: 30 days → 7 days (sufficient with daily backups)
- ✅ **HAProxy Resources Right-Sized**: Reduced CPU/memory to match actual usage
- ✅ **PodDisruptionBudget Added**: minAvailable=1 for safe maintenance
- ✅ **Slow Query Logging Enabled**: Threshold 2 seconds for performance debugging
- ✅ **Volume Expansion Enabled**: Dynamic storage growth without downtime
- ✅ **gracePeriod Added**: 30s on MySQL + HAProxy for smoother rolling updates
- ✅ **Renovate Ignore Fixed**: Added packageRules for MySQL backup image
- 🔧 **Technical Details**:
  - **Memory**: 768Mi request / 1536Mi limit (actual ~1100-1150Mi usage)
  - **Buffer Pool**: 512MB (was defaulting to 1GB, excessive for 18.6MB data)
  - **Exporter**: prom/mysqld-exporter:v0.16.0 with all collectors enabled
  - **HAProxy**: Reduced from 100m/128Mi to 50m/64Mi request (actual ~30m/25Mi)
  - **Binlog**: 604800 seconds (7 days) - matches backup RPO
  - **Redo Log**: 64MB (sufficient for light homelab workload)
- 📋 **Commits**: 46fd44a (binlog + HAProxy), 1eedfcc (gracePeriod)
- 📊 **Result**: Zero memory pressure alerts, metrics flowing to Prometheus

### 2025-12-17 (MySQL Cluster Recovery & Brittleness Analysis) 🔧
- ✅ **MySQL Cluster Recovered**: Manual intervention required after node scheduling changes ⭐
- ✅ **Brittleness Analysis Complete**: Documented 6 common failure modes with recovery procedures
- ✅ **Alternative Operators Evaluated**: MOCO identified as best CloudNativePG-like alternative
- 🎯 **Root Causes Identified**:
  - Clone lock file (`/var/lib/mysql/clone.lock`) not cleaned up after clone completion
  - Operator caches stale pod IPs after pod recreation
  - Read-only state not automatically enforced by Orchestrator
  - Errant GTIDs from brief writable window on replica
  - HAProxy config not updated after topology changes
- 🔧 **Manual Fixes Applied**:
  1. Restarted operator deployment to clear stale IP cache
  2. Deleted mysql-0 pod to recreate with fresh state
  3. Manually removed clone.lock file on mysql-1
  4. Deleted mysql-1 pod to re-clone and fix errant GTIDs
  5. Set correct read_only state on both nodes
- 📋 **Documentation Created**: [MYSQL_OPERATOR_ANALYSIS.md](./MYSQL_OPERATOR_ANALYSIS.md)
  - Recovery runbook for common scenarios
  - Known GitHub issues (#1099, #1097)
  - Configuration recommendations
  - Alternative operator comparison (MOCO, Oracle, Bitpoke)
- 🔄 **Final State**: mysql-0 (PRIMARY, read_only=0), mysql-1 (REPLICA, read_only=1)
- 💡 **Recommendation**: Keep current setup with documented procedures; evaluate MOCO if >1 incident/month

### 2025-12-16 (Percona MySQL Migration) 🗄️
- ✅ **Migrated from Oracle MySQL Operator to Percona Operator for MySQL** ⭐
- ✅ **All 3 apps restored and working**: Home Assistant, Uptime Kuma, PriceBuddy
- 🎯 **Reason**: Oracle MySQL Operator had persistent issues with Group Replication, RBAC, and auto-recovery
- 🔧 **Technical Details**:
  - **Cluster Type**: Percona Server for MySQL with async replication
  - **Version**: MySQL 8.4.6 (Percona Server)
  - **Operator**: Percona Operator for MySQL (PS) v1.0.0
  - **Replication**: Async (traditional MySQL replication, not Group Replication)
  - **Failover**: Percona Orchestrator (3 replicas, one per node for HA)
  - **Proxy**: HAProxy for connection routing (port 3306, replaces Router on 6446)
  - **Storage**: 20Gi per replica on local-path PVCs
  - **NetworkPolicy**: Updated all apps to use port 3306 instead of 6446
  - **Fix**: Replication password reduced from 64 to 32 chars (MySQL limitation)
- 📋 **Commits**: e81f354 (password fix), fb2da06 (NetworkPolicy fix)
- 🔄 **Migration Path**: MariaDB Galera → Oracle MySQL InnoDB → Percona Async

### 2025-12-16 (MySQL Operator Limitations Documented) 📝
- ✅ **MySQL Operator Limitations Documented**: Comprehensive analysis of mysql-operator v2.2.6 issues ⭐
- ✅ **GitOps Fix Applied**: `loose_group_replication_start_on_boot=ON` committed to cluster.yaml
- ✅ **Sidecar RBAC Fixed**: Created ClusterRole/ClusterRoleBinding for kopf framework permissions
- ✅ **Memory Limit Increased**: MySQL container 1Gi → 1536Mi (was near OOM at 99.9%)
- ✅ **Manual Backup Created**: Full MySQL dump saved to `.backup/mysql-backup-20251216_203346.tar.gz`
- 🔧 **Technical Details**:
  - **Operator Issues Identified**:
    - Metadata version mismatch (Shell 2.2.0 vs metadata 2.3.0) breaks `add_instance()`
    - ConfigMap not reconciled when `spec.mycnf` changes (requires pod delete)
    - Version lag: ships MySQL 9.1.0, not latest 9.5.x
    - No automatic bootstrap when cluster goes OFFLINE
  - **GitOps Fixes**:
    - `cluster.yaml`: Added `loose_` prefix to allow GR variable before plugin loads
    - `sidecar-rbac.yaml`: ClusterRole for kopf framework namespace/CRD permissions
  - **Decision**: Accept operator limitations; daily backups protect data; consider Percona Operator if issues persist
- 📋 **Commits**: af57092 (mycnf fix), previous session (RBAC, memory)

### 2025-12-16 (MySQL Cluster Recovery & Uptime Kuma Monitor Fixes) 🔧
- ✅ **MySQL InnoDB Cluster Recovered**: Group Replication manually restarted after cluster went OFFLINE ⭐
- ✅ **Uptime Kuma Monitors Fixed**: All 27 monitors now healthy (status=1)
- 🎯 **Root Cause**: Group Replication configured with `start_on_boot=OFF`, doesn't auto-recover after pod restarts
- 🔧 **Technical Details**:
  - **MySQL Recovery**:
    - Cluster status was OFFLINE (0 online instances) after mysql-0 container restart
    - Manual bootstrap on mysql-0: `SET GLOBAL group_replication_bootstrap_group=ON; START GROUP_REPLICATION;`
    - mysql-1 rejoined automatically after primary was bootstrapped
    - Cluster now ONLINE (2/2 instances: PRIMARY + SECONDARY)
  - **Uptime Kuma Fixes**:
    - **Paperless-NGX**: Added port 8000 to NetworkPolicy egress rules (was ECONNREFUSED)
    - **CouchDB**: Updated accepted status codes to include 401 (requires auth)
    - **Kubelets (3)**: Updated accepted status codes to include 401 (requires auth)
  - **Known Issue**: MySQL sidecar has RBAC permission issues preventing automatic cluster management
  - **Mitigation**: Manual recovery documented; consider enabling `start_on_boot=ON` in future
- 📋 **Commits**: 3fc4fc3 (NetworkPolicy fix)
- 🗄️ **Database Changes**: `UPDATE uptimekuma.monitor SET accepted_statuscodes_json='["200-299","401"]' WHERE id IN (11, 35, 36, 37);`

### 2025-12-16 (MySQL Migration from MariaDB) 🗄️
- ✅ **Migrated from MariaDB Galera to Oracle MySQL InnoDB Cluster** ⭐
- ✅ **Apps Migrated**: Home Assistant, Uptime Kuma, PriceBuddy (3 apps)
- ✅ **MySQL Router**: Connection routing via port 6446 for automatic failover
- 🎯 **Reason**: MariaDB Galera had persistent cluster formation issues
- 🔧 **Technical Details**:
  - **Cluster Type**: Oracle MySQL InnoDB Cluster with Group Replication
  - **Version**: MySQL 9.1.0 with mysql-operator
  - **Instances**: 2 replicas with required anti-affinity across worker nodes
  - **Router**: 1 replica for connection routing (port 6446)
  - **Storage**: 20Gi per replica on local-path PVCs
  - **NetworkPolicy**: Updated all apps to allow port 6446 (router) instead of 3306
  - **Backups**: Restored from MariaDB backup (2025-12-15 03:15 UTC)
- 🐛 **PriceBuddy Bug Fixed**: start-app.sh uses `nc` without `-z` flag causing hang
  - **Root Cause**: `nc` without `-z` waits for MySQL handshake data indefinitely
  - **Workaround**: ConfigMap override with fixed script (`nc -z`)
  - **Upstream**: [Issue #101](https://github.com/jez500/pricebuddy/issues/101) / [PR #102](https://github.com/jez500/pricebuddy/pull/102)
- 📋 **Commits**: 774b9d9, b71622b, c512650, 9233753, fe67ea1, b2afdde

### 2025-12-13 (Kyverno Violations Resolved & Cluster Cleanup) 🔧
- ✅ **Kyverno Phase 3 Complete**: All `require-resource-limits` violations resolved (30 → 0) ⭐
- ✅ **Popeye Health Scan**: Cluster score 100/100 (A grade), no issues found
- ✅ **Cluster Cleanup**: Deleted 25 stale ReplicaSets from rolling updates
- ✅ **Immich ResourceQuota Increased**: Fixed rolling update failures by increasing namespace quota
- 🎯 **Impact**: Zero Kyverno policy violations, clean cluster state
- 🔧 **Technical Details**:
  - **Resource Limits Added** (6 workloads):
    - `postgres-update-extensions` CronJob: 50m/200m CPU, 64Mi/256Mi memory
    - `mariadb-operator-webhook` Deployment: 20m/200m CPU, 64Mi/256Mi memory
    - `audiobookshelf-init` Job: 10m/100m CPU, 32Mi/64Mi memory
    - `home-assistant-admin-setup` Job: 10m/100m CPU, 32Mi/64Mi memory
    - `n8n-user-provision` Job: 10m/100m CPU, 32Mi/64Mi memory
    - `couchdb-init` Job: 10m/100m CPU, 32Mi/64Mi memory
  - **Jobs Verified**: All curl-based jobs complete in <20s with new limits (no OOM)
  - **Stale ReplicaSets Deleted**: 25 RS across 14 namespaces (cert-manager, monitoring, home-assistant, n8n, paperless-ngx, stirling-pdf, etc.)
  - **Immich Quota**: 18Gi → 24Gi memory limit (supports rolling updates)
- 📋 **Commits**: 393a039, 785aa5d, 7d79735, ccc0598

### 2025-12-06 (Kyverno Policy Cleanup & Documentation Update) 🔧
- ✅ **Kyverno Policy Violations Resolved**: Cleaned up all actionable policy violations ⭐
- ✅ **Image Tag Pinning**: Pinned seleniumbase-scrapper from :latest to v1.0
- ✅ **Policy Exclusions Added**: Added namespace exclusions to require-non-root policy
  - adguard-home (DNS binding requires root for port 53)
  - pricebuddy (apprise sidecar requires root for config)
  - stirling-pdf (PDF processing with user switching capabilities)
  - loki (promtail requires root to read host logs)
- ✅ **Cluster Cleanup**: Deleted 213 old ReplicaSets and 15 completed jobs
- 📅 **Second Worker Node Delay**: Updated from December 2025 to January 2026
- 📋 **Commits**: 9ab43ff, 401b62d, 6fea5cb, 5d5d615
- 🎯 **Final Kyverno Status**: 0 disallow-latest-tag, 0 require-non-root (after exclusions), 48 require-resource-limits (audit mode)

### 2025-12-06 (Trivy Operator Removal) 🗑️
- ❌ **Trivy Operator Removed**: Vulnerability scanning operator removed from homelab ⭐
- 🎯 **Reason**: Limited actionable value with Renovate-managed updates
- 🔧 **Technical Details**:
  - **Analysis**: 67 vulnerability reports analyzed - most vulnerabilities (70%+) have no fix available
  - **Categories**:
    - OS-level vulnerabilities (zlib, sqlite, curl): No fix available, embedded in upstream images
    - Application dependencies: Require upstream maintainer to rebuild images
    - Go stdlib CVEs: Require upstream Go version updates
  - **Alternative Strategy**: Renovate already handles automatic updates to latest versions
  - **Benefit**: Removes informational noise, simplifies infrastructure
  - **Kyverno Cleanup**: Removed trivy-system namespace exceptions from 4 policies
- 📋 **Files Removed**:
  - `infrastructure/controllers/base/trivy-operator/` (4 files: kustomization, namespace, release, repository)
  - `infrastructure/configs/staging/resource-governance/small-tier/trivy-system.yaml`
- 🔒 **Security Impact**: None - vulnerabilities identified were informational only (no actionable fixes)

### 2025-12-06 (Prometheus Memory Limit Increase) 📊
- ✅ **Prometheus Memory Limit Increased**: 1.1Gi → 1.3Gi due to observed peak of 913Mi ⭐
- 🎯 **Impact**: Resolved ContainerMemoryNearLimit alerts (was firing at 80%+)
- 🔧 **Technical Details**:
  - **Observed Peak**: 913Mi (7d), previously 777Mi when limit was set to 1.1Gi
  - **Old Configuration**: 800Mi request / 1100Mi limit (peak was 83% of limit)
  - **New Configuration**: 900Mi request / 1300Mi limit (peak now 70% of limit)
  - **Headroom**: Increased from 17% to 42% above observed peak
  - **Alert Threshold**: 80% (1040Mi) - well above 913Mi peak
- 📋 **Commit**: 2af6339

### 2025-12-05 (Prometheus Memory Optimization & PriceBuddy Deployment) 📊
- ✅ **Prometheus Memory Limit Reduced**: 2Gi → 1.1Gi based on 72-hour monitoring ⭐ (Later increased to 1.3Gi on 2025-12-06)
- ✅ **PriceBuddy Deployed**: New price tracking application (replaces Discount Bandit)
- 🎯 **Impact**: 900Mi memory savings, dedicated Telegram notifications for price alerts
- 🔧 **Technical Details**:
  - **Prometheus Monitoring** (72 hours, 23 data points):
    - Peak usage: 777Mi (70.6% of new 1.1Gi limit)
    - Range: 622Mi - 777Mi (stable)
    - Headroom: 323Mi (29.4% above peak)
    - Memory savings: 900Mi (2Gi → 1.1Gi)
  - **PriceBuddy Stack**:
    - Main app: jez500/pricebuddy:v1.0.40
    - Scraper sidecar: jez500/seleniumbase-scrapper:latest
    - Notifications: Apprise sidecar (caronc/apprise:1.2.6)
    - Database: MariaDB (shared cluster)
    - Telegram: Dedicated bot (@pricebuddyalertbot) and channel
  - **kube-prometheus-stack**: Updated to 79.12.0
- 📋 **Commits**: c9ee4fe (Prometheus memory), 4a3baeb (PriceBuddy Telegram)

### 2025-12-05 (Discount Bandit Removal) 🗑️
- ❌ **Application Removed**: Discount Bandit price tracking app removed from homelab
- 🎯 **Reason**: Application required too much manual maintenance and wasn't providing enough value
- 🔧 **Technical Details**:
  - Removed all Kubernetes resources (deployment, service, ingress, networkpolicy, configmaps, secrets)
  - Removed MariaDB database CRDs (database, user, grant, credentials)
  - Removed from backup cronjob, secrets backup/restore scripts
  - Removed from Homepage dashboard
  - Updated resource governance and kustomization files
- 📋 **Future Alternative**: May try [PriceBuddy](https://github.com/jez500/pricebuddy) instead
- 🔢 **App Count**: 16 → 15 applications
- 💾 **MariaDB Databases**: 3 → 2 (homeassistant, uptimekuma)

### 2025-11-30 (Arch Linux Comprehensive Hardening) 🔒
- ✅ **Lynis Score Improvement**: Both nodes improved from 71 → 76 (+5 points)
- ✅ **Headless Server Hardening**: Disabled WiFi and Bluetooth on both nodes
- ✅ **Kernel Hardening**: Additional sysctl settings (kptr_restrict, bpf_jit_harden, sysrq restrictions)
- ✅ **SSH Hardening**: AllowTcpForwarding, AllowAgentForwarding, LogLevel VERBOSE, MaxSessions
- ✅ **Protocol Blacklisting**: Disabled unused protocols (dccp, sctp, rds, tipc)
- ✅ **Security Tools Installed**: rkhunter (rootkit scanner), arch-audit (vulnerability scanner)
- ✅ **Legal Banner**: Added to /etc/issue and /etc/issue.net
- 🎯 **Impact**: Reduced attack surface on headless K3s nodes
- 🔧 **Technical Details**:
  - **Control Plane** (192.168.1.127): Intel N100, Realtek WiFi blacklisted (rtw89)
  - **Worker Node** (192.168.1.129): AMD Ryzen 9 9955HX, MediaTek WiFi blacklisted (mt7921e)
  - **GPU Drivers Kept**: Intel i915/xe and AMD amdgpu retained for hardware transcoding
  - **USB/Firewire**: NOT blacklisted per user requirement
  - **Firmware Packages**: Kept for reversibility (disabled via module blacklists)
- 📋 **Scripts Created**:
  - `/tmp/fix-critical.sh` - fstab, /boot, locale, noatime, initramfs
  - `/tmp/fix-security.sh` - sysctl hardening, lynis, SSH, paccache
  - `/tmp/fix-optimize.sh` - pacman config, hostname, journal cleanup
  - `/tmp/fix-headless.sh` - WiFi/Bluetooth module blacklisting
  - `/tmp/fix-lynis.sh` - Additional lynis recommendations
- 🐛 **Issues Fixed**:
  - egrep/fgrep deprecation warnings in rkhunter (created /etc/profile.d/grep-compat.sh)
  - FQDN missing in /etc/hosts (NAME-4404)
  - rkhunter baseline updated on both nodes
- ⚠️ **Pending**: Package vulnerabilities (libxml2, pam, openssl) waiting on upstream fixes
- 📅 **Scheduled**: LTS kernel 6.18 switch on Friday, December 5th, 2025

### 2025-11-25 (Prometheus Metric Optimization) 📉
- ✅ **High-Cardinality Metric Drop**: Reduced Prometheus storage by dropping 5 high-cardinality histogram metrics
- 🎯 **Impact**: ~18,250 fewer time series (13.5% reduction from baseline), improved memory efficiency
- 🔧 **Technical Details**:
  - **Metrics Dropped** (5 total, ~18,250 series):
    1. apiserver_request_body_size_bytes_bucket: 11,136 series (bug fix - was using wrong suffix)
    2. workqueue_work_duration_seconds_bucket: 2,258 series (90% reduced, 234 remain from operators)
    3. workqueue_queue_duration_seconds_bucket: 2,258 series (90% reduced)
    4. scheduler_plugin_execution_duration_seconds_bucket: 1,218 series
    5. prober_probe_duration_seconds_bucket: 1,380 series (required probesMetricRelabelings config)
  - **Bug Fix**: Fixed existing apiserver_request_body_size drop rule (incorrect regex pattern)
  - **Configuration Changes**:
    - Added 4 drop rules to kubeApiServer.serviceMonitor.metricRelabelings
    - Added 4 drop rules to kubelet.serviceMonitor.metricRelabelings
    - Added 1 drop rule to kubelet.serviceMonitor.probesMetricRelabelings (new section)
  - **Version Fix**: Downgraded kube-prometheus-stack 79.8.1 → 79.8.0 (79.8.1 not in Helm repo)
- 📊 **Current State**:
  - Memory: 1720Mi / 2Gi (86%, increased from 81% due to pod restarts)
  - Total series: 155,465 (up from baseline 134,809 due to new series after restart)
  - All dropped metrics verified at 0 series
- 🐛 **Issues Resolved**:
  1. apiserver_request_body_size used _bytes_bucket not _seconds_bucket suffix
  2. prober_probe metrics come from kubelet /metrics/probes endpoint (separate config needed)
  3. Chart version 79.8.1 doesn't exist in Helm repository
- 💡 **Lesson Learned**: Kubelet has 3 separate metrics endpoints requiring distinct metricRelabelings configs:
  - `/metrics` → metricRelabelings
  - `/metrics/cadvisor` → cAdvisorMetricRelabelings
  - `/metrics/probes` → probesMetricRelabelings
- 💪 **Benefits**: Reduced storage overhead for unused histogram buckets, cleaner metrics
- 📋 **File Modified**: `monitoring/controllers/base/kube-prometheus-stack/release.yaml`
- Commits: a9b3a72 (initial drops + bug fix), c2e4718 (prober_probe fix), bd787a0 (version fix)

### 2025-11-24 (MariaDB Introduction & SQLite Migration Complete) 🗄️
- ✅ **MariaDB Galera Cluster Deployed**: 2-replica high-availability cluster with mariadb-operator v0.37.1
- ✅ **3 Apps Migrated from SQLite to MariaDB**: Home Assistant, Discount Bandit, Uptime Kuma
- 🎯 **Impact**: Eliminated SQLite from homelab, all apps now use production-grade databases (PostgreSQL or MariaDB)
- 🔧 **Technical Details**:
  - **Cluster Type**: Galera multi-master synchronous replication (2 replicas)
  - **Version**: MariaDB 12.1
  - **Architecture**: Aligned with PostgreSQL pattern (base = infrastructure, staging = app-specific)
  - **Databases Created**: homeassistant, discountbandit, uptimekuma (3 databases, 3 users, 3 grants)
  - **Migration Approaches**:
    - Home Assistant: Fresh start - 42 tables auto-created by application
    - Discount Bandit: Fresh start - Laravel migrations created schema
    - Uptime Kuma: Custom Python migration script - 22 tables migrated (selective), 5 tables excluded (heartbeat history)
  - **Backup Strategy**: Daily automated backups at 3:15 AM with 30-day retention (matches PostgreSQL)
  - **NetworkPolicy**: Restricts access to app namespaces + monitoring
  - **Storage**: 10Gi per replica on local-path PVCs
  - **Connection Pattern**: Direct to primary (no pooler needed for Galera multi-master)
- 📚 **Documentation**: Created comprehensive `docs/MARIADB_MIGRATION.md` (337 lines)
- 🔒 **Security**: All 4 MariaDB secrets added to cluster-wide backup/restore scripts
- 💪 **Benefits**: Multi-master replication, automatic failover, production-grade database for all apps
- 📋 **Verification**: All 3 apps running successfully with MariaDB, zero data loss
- Commits: Multiple (backup job, architecture alignment, migration cleanup)

### 2025-11-22 (K3s Cluster Upgrade) 🚀
- ✅ **K3s Upgrade Complete**: Upgraded both nodes from v1.34.1+k3s1 to v1.34.2+k3s1
- ✅ **Control-Plane Node**: Successfully upgraded to v1.34.2+k3s1 (192.168.1.127)
- ✅ **Worker Node**: Successfully upgraded to v1.34.2+k3s1 (192.168.1.129)
- 🎯 **Impact**: Latest Kubernetes v1.34.2 with updated components (Containerd 2.1.5-k3s1, Traefik 3.5.1, CoreDNS 1.13.1)
- 🔧 **Technical Details**:
  - **Upgrade Method**: curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.34.2+k3s1 sh -
  - **Worker Node Issue**: Installation script cleared K3S_URL/K3S_TOKEN from service.env, required re-installation with token
  - **Cluster Health**: All 63 pods running, PostgreSQL cluster healthy (2/2 ready)
  - **Downtime**: ~2 minutes worker node restart, all pods recovered automatically
  - **Component Updates**: Containerd 2.1.4-k3s2 → 2.1.5-k3s1, Runc v1.3.3, Traefik v3.5.1
- 💪 **Benefits**: Bug fixes, security patches, updated container runtime
- 📋 **Verification**: Both nodes Ready, all HelmReleases healthy, Flux reconciliation successful

### 2025-11-22 (Discount Bandit Memory Fix) 🛍️
- ✅ **OOM Kill Prevention**: Increased memory limits to prevent Out of Memory kills
- 🎯 **Impact**: Pod stability restored after OOM incident at 82.8% memory usage
- 🔧 **Technical Details**:
  - **Root Cause**: Memory usage grew 33% in 6 days (477Mi → 636Mi peak)
  - **OOM Incident**: Pod killed at 82.8% of 768Mi limit (~636Mi)
  - **Fix**: Increased memory request 512Mi → 650Mi, limit 768Mi → 1Gi
  - **Current Usage**: 405Mi (39.5% of new 1Gi limit)
  - **Headroom**: 61% above previous peak (388Mi buffer)
- 📊 **Memory Growth Pattern**:
  - 2025-11-16: 477Mi (62% of 768Mi) ✅
  - 2025-11-22: 636Mi (82.8% of 768Mi) ❌ OOM killed
  - Post-fix: 405Mi (39.5% of 1Gi) ✅
- 💪 **Benefits**: Prevents future OOM kills, accommodates continued memory growth
- 📋 **Status**: Pod running healthy with 0 restarts, alert will clear on next Prometheus evaluation
- Commit: 6f094f8

### 2025-11-19 (Documentation Update) 📋
- ✅ **CSP Enforcement Status Update**: Updated executive summary to reflect CSP enforcement completion (deployed 2025-10-31, 19 days in production)
- ✅ **Review Dates Updated**: Set next general review to 2025-12-15, HSTS final rollout scheduled 2025-11-30
- ✅ **Shell Configuration**: Disabled "Last login" and "You have mail" messages via .hushlogin and MAILCHECK unset
- 🎯 **Impact**: Resolved documentation inconsistencies, cleaned up overdue review items
- Commits: chezmoi b3d3528 (dotfiles)

### 2025-11-18 (Prometheus Memory Monitoring Complete) 📊
- ✅ **68-Hour Monitoring Window Complete**: Extended observation of Prometheus memory consumption (Sat 15 Nov 23:10 - Tue 18 Nov 19:00 GMT)
- ✅ **Decision**: KEEP current 1.5Gi limit - No changes needed ⭐
- 🎯 **Impact**: Confirmed Prometheus memory allocation is appropriate with 29.2% headroom above peak usage
- 🔧 **Technical Details**:
  - **Actual Current Limit**: 1.5Gi (1536Mi) - Documentation previously stated 2.5Gi incorrectly
  - **Peak Usage**: 1088Mi (70.8% of 1.5Gi limit) observed on Mon 17 Nov 20:08 GMT
  - **Current Headroom**: 448Mi (29.2% above peak) - Adequate for metric spikes
  - **Data Collection**:
    - Attempted 18 automated measurements (every 3 hours)
    - Only 3 successful data points collected (83% failure rate)
    - Root cause: metrics-server intermittent availability (2 restarts during monitoring period)
  - **Automated Analysis**:
    - Formula: Peak × 1.3 = 1088Mi × 1.3 = 1414Mi (~1.4Gi)
    - Recommendation: Reduce from 1.5Gi → 1.4Gi (save 102Mi)
    - Decision: Rejected due to limited dataset and minimal savings (6.8% reduction)
- 📊 **Rationale for Keeping 1.5Gi**:
  - Current headroom (29.2%) adequate for metric spikes during incidents
  - Only 3 of 18 data points captured - incomplete dataset
  - Savings minimal (102Mi) not worth risk
  - Limit already optimized through previous reductions (3Gi → 2.5Gi → 1.5Gi)
- 🗑️ **Cleanup**:
  - Removed all prometheus-memory monitoring cron jobs
  - Archived scripts, logs, and analysis to `.monitoring-archive/prometheus-memory-monitoring-2025-11/`
  - Updated documentation: `PROMETHEUS_MEMORY_MONITORING.md`, `prometheus-memory-automation.md`
- 💪 **Benefits**: Validated current resource allocation, automated monitoring/analysis system proven effective
- 📋 **Archive**: All monitoring artifacts preserved in `.monitoring-archive/prometheus-memory-monitoring-2025-11/` with comprehensive README

### 2025-11-16 (Security Hardening Reviews Complete) ✅
- ✅ **HSTS Step 2 Deployment**: Increased HSTS max-age from 1 month to 6 months (Step 2/3) ⭐
- ✅ **CSP Enforcement Validation**: Confirmed CSP already in enforcement mode since 2025-10-31 (16 days, zero violations)
- ✅ **Discount Bandit Memory Evaluation**: Reviewed resource allocation, no changes needed (477Mi usage, 38% headroom)
- 🎯 **Impact**: All 3 overdue security hardening reviews addressed
- 🔧 **Technical Details**:
  - **HSTS Step 2 (Completed 2025-11-16)**:
    - Updated both security-headers middleware files
    - Changed HSTS max-age from 2628000s (1 month) → 15768000s (6 months)
    - Files: `infrastructure/controllers/base/traefik/security-headers-middleware.yaml`, `monitoring/configs/staging/kube-prometheus-stack/security-headers-middleware.yaml`
    - Deployment: GitOps via Flux reconciliation (both kustomizations succeeded)
    - Next step: Final increase to 1 year (31536000s) on 2026-01-15
  - **CSP Enforcement (Already Complete)**:
    - Enforcement mode deployed: 2025-10-31 (Commit 04df8a4)
    - Production uptime: 16 days with zero violations
    - Testing: 85 automated tests across 17 apps (100% pass rate)
    - Both middleware files use `Content-Security-Policy` header (not report-only)
    - No code changes needed, documentation updated to reflect completion
  - **Discount Bandit Memory (No Changes Needed)**:
    - Current allocation: 512Mi request / 768Mi limit
    - Current usage: 477Mi (62% of limit, 38% headroom)
    - Analysis: Memory allocation appropriate for workload
    - Conclusion: No adjustment required, healthy buffer maintained
- 📊 **Gradual HSTS Rollout Progress**:
  - ✅ Step 1 (1 month): Deployed 2025-10-31
  - ✅ Step 2 (6 months): Deployed 2025-11-16
  - ⏰ Step 3 (1 year): Target 2026-01-15 (final step)
- 💪 **Benefits**: Progressive HSTS deployment reduces risk, CSP enforcement validated with production uptime
- 📋 **Documentation**: Updated HOMELAB_ANALYSIS.md with completion status for all 3 reviews
- Commits: 793a247 (HSTS Step 2)

### 2025-11-15 (VictoriaMetrics Migration Aborted) ⚠️
- ❌ **VictoriaMetrics Migration Failed**: Aborted migration from Prometheus to VictoriaMetrics
- 🎯 **Impact**: Kept Prometheus as monitoring solution, removed all VictoriaMetrics components
- 🔧 **Technical Details**:
  - **Goal**: Reduce memory usage by switching to VictoriaMetrics (touted as more efficient)
  - **Issue Discovered**: VictoriaMetrics metricRelabelConfigs not functioning despite correct configuration
  - **Evidence**:
    - VictoriaMetrics collected 231,189 series vs Prometheus 155,749 series (+48% more)
    - API server histogram metrics NOT dropped despite proper VMNodeScrape configuration
    - Configuration showed "ConfigParsedAndApplied" status but drops didn't work
    - Prometheus successfully dropped same metrics with identical configuration
  - **Root Cause**: VictoriaMetrics operator or VMAgent bug/limitation in processing metric drops
  - **Decision**: Aborted migration - VictoriaMetrics more memory hungry than Prometheus (defeating purpose)
- 🗑️ **Cleanup Actions**:
  - Removed VictoriaMetrics HelmRelease and operator
  - Deleted all VictoriaMetrics CRDs (VMAgent, VMAlert, VMSingle, VMNodeScrape)
  - Removed VictoriaMetrics datasource from Grafana
  - Deleted migration backup documentation
  - Updated monitoring kustomization to remove VictoriaMetrics references
- 📊 **Prometheus Optimization**:
  - Current memory: 905Mi / 2.5Gi (36% utilization)
  - Series count: 188,301
  - Already optimized: 7d retention, 30s kubelet scrape, API server metric drops working
  - Conclusion: No further optimization needed, current configuration appropriate
- 💪 **Lesson Learned**: VictoriaMetrics metric drops don't work correctly - Prometheus remains superior choice
- Commits: 270aef1, 2d0bb7d, c8f68f5

