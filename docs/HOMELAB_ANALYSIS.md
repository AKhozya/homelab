# 🏗️ HOMELAB COMPREHENSIVE ANALYSIS
## Staff DevOps Engineer Assessment

**Assessment Date**: 2025-10-18 (Updated: 2025-12-13 20:00 UTC)
**Cluster**: K3s (staging)
**Infrastructure**: GitOps (Flux), CloudNativePG, Monitoring Stack, SSO (Authentik), Cloudflare Tunnel
**Responsibility Level**: ⚠️ **CRITICAL** - Production-equivalent personal infrastructure
**Last Comprehensive Review**: 2025-10-27 ([COMPREHENSIVE_CODEBASE_REVIEW.md](./COMPREHENSIVE_CODEBASE_REVIEW.md))
**Historical Archive**: [HOMELAB_HISTORY.md](./HOMELAB_HISTORY.md) - Completed tasks & changelog (Oct-Nov 2025)

---

## 📊 EXECUTIVE SUMMARY

### Overall Grade: **A- (Excellent with Critical Gaps)**

**Strengths** ✅
- Solid GitOps foundation with Flux
- Comprehensive monitoring (Prometheus, Grafana, Loki, Alertmanager)
- **🆕 Popeye - Cluster health monitoring (B grade, 82/100 score)** ⭐ (2025-10-27, Updated: 2025-11-05)
- **🆕 Kyverno - Kubernetes-native policy enforcement (10 policies: 7 Enforce + 3 Audit, daily alerts)** ⭐ (2025-10-27, Updated: 2025-10-28)
  - **Enforced policies:** disallow-privilege-escalation, require-drop-all-capabilities, require-labels, disallow-host-namespaces, **require-non-default-serviceaccount** ✅, **require-seccomp-runtimedefault** ✅ (0 violations)
  - **Audit policies:** require-resource-limits (30) - others resolved via namespace exclusions (2025-12-06)
  - **Phase 1 Complete (2025-10-28):** Service account remediation - 31 pods migrated, 16 custom SAs created, enforce mode enabled ✅
  - **Phase 2 Complete (2025-10-28):** Seccomp profiles - 23 workloads with RuntimeDefault, enforce mode enabled ✅
  - **Phase 3 Partial (2025-12-13):** Resource limits - 30 violations remain (monitoring sidecars, kube-system), audit mode ⚠️
  - **Enforcement strategy:** Phased approach with zero-risk policies enforced first
  - **Monitoring:** Daily violation summaries via Prometheus/Telegram
  - **Security posture:** ~80% Pod Security Standards (Baseline), ~65% Pod Security Standards (Restricted)
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
- **Complete NetworkPolicy coverage on all apps (13/13)**
- **Clean namespace separation - no resource leaks**
- CloudNativePG for managed PostgreSQL (3-node HA) with PgBouncer pooler
- Default credential elimination on all apps
- **🆕 Comprehensive Security Headers & Protections** ⭐ (2025-10-30)
  - **Phase 1 (Completed)**: Safe security headers (X-Content-Type-Options, X-Frame-Options, Referrer-Policy, Permissions-Policy)
  - **Phase 2 (Completed)**: HSTS deployment - Dual layer (Cloudflare edge: 1 month, Traefik origin: 1 week)
  - **Phase 3 (Completed)**: Rate limiting with monitoring - Standard (100/min + 150 burst), High-frequency (200/min + 300 burst)
  - **Phase 4 (Completed)**: CSP enforcement mode (deployed 2025-10-31, 43 days production, zero violations)
  - **Coverage**: All 17 services (14 apps + Grafana + AlertManager + CouchDB)
  - **Monitoring**: 6 Prometheus alerts for rate limiting (attack detection, false positive detection)
  - **HSTS Review**: 2026-01-15 - Step 3 final rollout (increase max-age to 1 year)

**Critical Gaps (from 2025-10-27 Comprehensive Review)** 🔴
- ⏸️ **No offsite backup replication** (P0-CRITICAL) - DEFERRED to late December 2025 (NAS delivery postponed)
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
- ✅ PVC daily backups (3:10 AM, 7-day retention)
- ✅ Disaster recovery scripts complete (`.backup/` directory)
- ✅ Backup validation completed (2025-10-26)
- ❌ **Missing**: Offsite replication, WAL archiving, automated validation

---

## 🎯 CRITICAL ACTION ITEMS

**Last Updated**: 2025-12-13 (Documentation refresh, Immich quota fix)
**Source**: [COMPREHENSIVE_CODEBASE_REVIEW.md](./COMPREHENSIVE_CODEBASE_REVIEW.md)

### 🔴 P0-CRITICAL (Immediate - This Week)

#### 1. ✅ **COMPLETED: PostgreSQL NetworkPolicy** (2025-10-27)
   - **Status**: ✅ Completed - NetworkPolicy deployed and active
   - **Risk**: Unrestricted access to all databases from any pod
   - **CVSS**: 7.5 (HIGH)
   - **Solution**: Created NetworkPolicy restricting access to app namespaces only
   - **Commit**: a80d4bf
   - **Files**: `infrastructure/configs/base/databases/postgres/networkpolicy.yaml`

#### 2. ✅ **COMPLETED: Duplicate cert-manager ClusterIssuers** (2025-10-27)
   - **Status**: ✅ Completed - Orphaned ClusterIssuer removed
   - **Risk**: Unpredictable certificate issuance, renewal failures
   - **Solution**: Deleted orphaned `controllers/base/cert-manager/clusterissuer.yaml`
   - **Commit**: 2cb9e78
   - **Files**: Removed duplicate, kept `infrastructure/configs/base/cert-manager/clusterissuer.yaml`

#### 3. ❌ **REMOVED: CNPG WAL Archiving** (Not Implementing)
   - **Decision**: Not implementing - CNPG barman requires S3/Azure/Google credentials
   - **Alternative**: Continue with existing pg_dump daily backups (24h RPO acceptable for homelab)
   - **Reason**: barmanObjectStore doesn't support local filesystem paths
   - **Future Option**: Deploy MinIO for S3-compatible local storage (P2 task if needed)
   - **Current RPO**: 24 hours (pg_dump at 3 AM) - acceptable for homelab

---

### 🛡️ SECURITY HARDENING REVIEWS (Scheduled)

#### 1. ✅ **COMPLETED: CSP Enforcement** - Enforced since 2025-10-31 ⭐
   - **Status**: ✅ **COMPLETED - CSP in enforcement mode across all 17 apps (16 days active, zero violations)**
   - **Enforcement Date**: 2025-10-31 (Commit 04df8a4)
   - **Current**: CSP enforcement mode deployed to all 17 services
     - Policy: `default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'`
     - Monitoring: csp-reporter service → Loki (`{namespace="csp-reporter"}`)
     - Header: `Content-Security-Policy` (enforcement mode, not report-only)
   - **Testing Results**: ✅ **100% pass rate (0 violations)**
     - **85 automated tests**: 17 apps × 5 scenarios (page load, JS, CSS, images, API)
     - **Baseline violations**: 0
     - **Post-enforcement violations**: 0
     - **Confidence level**: HIGH
     - **Test duration**: ~60 seconds
     - **Full report**: `docs/CSP_TEST_RESULTS.md`
   - **Production Validation**: ✅ **Zero violations after 43 days in production**
   - **Completed Tasks**:
     1. ✅ Automated testing across all apps (COMPLETE - 100% pass rate)
     2. ✅ Enabled enforcement mode (COMPLETE - deployed 2025-10-31)
     3. ✅ Monitored post-enforcement (COMPLETE - 43 days, zero violations)
   - **Files Updated**:
     - `infrastructure/controllers/base/traefik/csp-middleware.yaml`
     - `monitoring/configs/staging/kube-prometheus-stack/csp-middleware.yaml`
   - **Commits**: b8b6306, 7b2c72b, 54c8484, 04df8a4
   - **Test Script**: `csp-test.sh` (re-run anytime with `./csp-test.sh`)

#### 2. **📅 HSTS Max-Age Optimization** - Gradual Rollout (IN PROGRESS)
   - **Status**: 🔄 Step 2/3 Complete - 6 months max-age deployed (2025-11-16)
   - **Current**: Unified HSTS across all layers
     - Cloudflare Edge: `max-age=2628000` (1 month) - will update to match Traefik
     - Traefik Origin: `max-age=15768000` (6 months) ✅ **UPDATED 2025-11-16**
     - All 17 ingresses now have 6-month HSTS
   - **Gradual Rollout Plan**:
     - ✅ **Step 1**: 1 month (2628000s) - Deployed 2025-10-31
     - ✅ **Step 2**: 6 months (15768000s) - Deployed 2025-11-16
     - ⏰ **Step 3**: 1 year (31536000s) - Target: 2026-01-15 (final)
   - **Next Review**: **2026-01-15** (verify 6 months deployment stable, increase to 1 year)
   - **Files Updated**: Both traefik and monitoring security-headers middleware
   - **Commits**: 5e109cd (Step 1), 793a247 (Step 2)

---

### ⚠️ P1-HIGH (This Month)

#### 5. ⏸️ **Automated Backup Validation Testing** - DEFERRED (2025-10-27)
   - **Status**: ⏸️ Deferred until homelab infrastructure stabilizes
   - **Current State**: Manual validation testing (last: 2025-10-26) - sufficient for now
   - **Risk**: Backup corruption may go undetected between manual tests (acceptable)
   - **Reason**: Infrastructure still evolving - automation premature, could cause false alarms
   - **Future Action**: Implement quarterly CronJob after 2-3 months of stability
   - **Priority**: Deferred to Q1 2026

#### 6. ✅ **Pod Anti-Affinity for PostgreSQL** - COMPLETED (2025-10-29)
   - **Status**: ✅ True cross-node HA with required anti-affinity
   - **Final Configuration**:
     - Instances: 2 (reduced from 3 for 2-node cluster)
     - Anti-affinity: `podAntiAffinityType: "required"` (HARD constraint)
     - Topology key: `topologyKey: "kubernetes.io/hostname"`
     - Control plane tolerations enabled
   - **Current State**:
     - main-postgres-5 (Primary): worker-node ✅
     - main-postgres-6 (Replica): gmk-k3s-control-plane ✅
   - **Control Plane Impact**:
     - CPU: 774m (19%) - well within capacity
     - Memory: 4.1GB (26%) - stable
   - **Key Decisions**:
     - Required anti-affinity forces cross-node distribution (pods MUST be on different nodes)
     - 2 instances optimal for 2-node cluster (1 primary + 1 replica)
     - Local-path storage creates node-specific PVCs automatically
   - **Benefits**:
     - Worker node failure: Control plane has PostgreSQL replica + infrastructure
     - True physical HA across 2 nodes
     - Zero downtime failover capability
   - **Commits**: cbc71d0, 30c1f8a, 95fe37a, eef307d
   - **Known Issue**: CNPG port 8000 binding failure on control-plane (see below)

#### 6b. ✅ **RESOLVED: CNPG Port 8000 Binding on Control-Plane** (2025-10-30)
   - **Status**: ✅ Resolved - Restricted PostgreSQL to worker-node only
   - **Issue**: CNPG instance manager silently fails to bind status port 8000 on K3s control-plane node
   - **Root Cause**: K3s control-plane specific issue
     - Port 8000 hardcoded in CNPG (cannot be changed)
     - Logs show "Starting webserver :8000 hasTLS=true" but port never binds
     - Zero error messages - completely silent failure
     - Only affects control-plane node (worker-node works perfectly)
     - UFW firewall rules and node reboots did NOT fix
   - **Resolution**: Removed control-plane toleration, running all PostgreSQL instances on worker-node only
     - Modified `podAntiAffinityType` from "required" to "preferred" (both pods on same worker node)
     - Restored Flux health checks (working now)
     - Cluster status: **READY 2/2** - "Cluster in healthy state"
   - **Trade-off**: Lost cross-node HA but gained:
     - ✅ Full cluster monitoring (both pods port 8000 working)
     - ✅ No Flux timeout errors
     - ✅ Clean deployment without workarounds
   - **Upstream**: Bug report submitted to CNPG project https://github.com/cloudnative-pg/cloudnative-pg/issues/9013
   - **Files**: `infrastructure/configs/base/databases/postgres/cluster.yaml`, `clusters/apps.yaml`

#### 7. ✅ **PostgreSQL TLS/Encryption** - ALREADY IMPLEMENTED (2025-10-27)
   - **Status**: ✅ TLS enabled by CloudNativePG, all apps using it
   - **Evidence**: All connections show ssl=t in pg_stat_ssl view
   - **Current**: pg_hba.conf allows plaintext (host) but apps voluntarily use TLS
   - **Minor gap**: Could enforce TLS at pg_hba level (host→hostssl)
   - **Priority**: Downgraded to P3-LOW (optional enforcement)

#### 8. ❌ **Redis Backup Automation** - NOT IMPLEMENTING
   - **Status**: ❌ Not implementing - Redis used only as cache (ephemeral data)
   - **Impact**: User re-login required, jobs re-queued on pod deletion (acceptable)
   - **Current State**: RDB snapshots on PVC (sufficient for cache use case)
   - **Reason**: Redis stores only ephemeral/cache data - no persistent data requiring backup
   - **Priority**: Closed - no action needed

#### 9. ✅ **Flux Timeout Settings Standardization** - COMPLETED (2025-10-27)
   - **Status**: ✅ All 6 kustomizations standardized to 45s timeout
   - **Before**: infrastructure-controllers (5m), infrastructure-configs (10m), apps (5m), monitoring-controllers (5m), monitoring-configs (5m)
   - **After**: All kustomizations use 45s timeout (consistent)
   - **Impact**: Predictable reconciliation behavior, faster failure detection
   - **Verified**: All kustomizations READY at commit 4cc2834
   - **Commit**: 4cc2834
   - **Files**: `clusters/infrastructure.yaml`, `clusters/infrastructure-configs.yaml`, `clusters/apps.yaml`, `clusters/monitoring.yaml`

#### 10. ✅ **Traefik Health Checks** - ALREADY IMPLEMENTED (2025-10-27)
   - **Status**: ✅ 15/15 apps have readinessProbe and livenessProbe
   - **Mechanism**: Kubernetes Service endpoints automatically exclude unhealthy pods
   - **Traefik Integration**: Inherits pod health state from Kubernetes
   - **Verification**: CouchDB (/_up), Immich (/api/server/ping), PostgreSQL (pg_isready), Redis (redis-cli ping)
   - **Priority**: No action required - already compliant

#### 11. ✅ **High Availability for Critical Components** - COMPLETED (2025-10-29)
   - **Status**: ✅ Implemented - Critical infrastructure now runs across 2 physical nodes (control plane + worker)
   - **Previous State**: Traefik (1), cert-manager (1), all on worker node only
   - **Phase 1 (2025-10-29)**: Increased replicas to 2 with pod anti-affinity
     - Traefik: 2 replicas with pod anti-affinity
     - cert-manager controller: 2 replicas with pod anti-affinity
     - cert-manager webhook: 2 replicas with pod anti-affinity
     - cert-manager cainjector: 2 replicas with pod anti-affinity
     - Commits: e07474a, 898d969
   - **Phase 2 (2025-10-29)**: Enabled control plane scheduling for true HA
     - Added tolerations for `node-role.kubernetes.io/control-plane` taint
     - Components: Traefik, cert-manager (all 3 components), Cloudflare tunnel, PostgreSQL
     - Commits: 6a52f5c, cbc71d0
   - **Current State**:
     - Traefik: 2 replicas on control plane (both scheduled there during rollout)
     - cert-manager controller: 2 replicas on control plane
     - cert-manager webhook: 1 on control plane, 1 on worker ✓
     - cert-manager cainjector: 1 on control plane, 1 on worker ✓
     - Cloudflare tunnel: 1 on control plane, 1 on worker ✓
     - PostgreSQL: 2 instances with required anti-affinity - 1 on control plane (replica), 1 on worker (primary) ✓
   - **Control Plane Impact**:
     - Before: 470m CPU (11%), 3.6GB RAM (22%)
     - After (with PostgreSQL): 774m CPU (19%), 4.1GB RAM (26%)
     - Increase: +304m CPU, +500Mi RAM
     - Status: Well within capacity (4 CPUs, 16GB RAM available)
   - **Implementation Details**:
     - Pod anti-affinity: `preferredDuringSchedulingIgnoredDuringExecution` (soft constraint)
     - Topology key: `kubernetes.io/hostname` (prefer different nodes)
     - Weight: 100 (high preference for spreading)
     - PostgreSQL uses CNPG-native anti-affinity: `enablePodAntiAffinity: true`, `podAntiAffinityType: "preferred"`
   - **Benefits**:
     - ✅ True physical HA: Worker node failure won't take down all infrastructure
     - ✅ Zero downtime during Renovate updates (rolling updates)
     - ✅ Better resource utilization of idle control plane capacity
     - ✅ Future-proof for multi-worker cluster expansion
   - **Note**: Soft anti-affinity sometimes places both replicas on same node during simultaneous rollout (acceptable for homelab)

#### 12. ✅ **Scattered Middleware Configurations** - COMPLETED (2025-10-27)
   - **Status**: ✅ Centralized HTTPS redirect middleware to traefik namespace
   - **Before**: 15 duplicate middleware files across apps (140 lines of YAML)
   - **After**: Single `traefik/redirect-https` middleware
   - **Updated**: 15 ingress annotations to reference centralized middleware
   - **Benefit**: Single source of truth, easier maintenance
   - **Note**: Security headers (CSP, HSTS) remain as separate P2 task
   - **Commit**: 9a9ebce

#### 13. ⚠️ **Overly Permissive Redis ACLs** - VALID BUT NOT FIXABLE (2025-10-27)
   - **Status**: ⚠️ Accept current state - apps don't support key prefixes
   - **Attempted**: Restricted ACLs to ~authentik:*, ~paperless:*, ~immich:*
   - **Result**: Broke existing cache keys (apps don't use prefixes by default)
   - **Current**: `~* &* +@all -@dangerous -acl` (all keys, safe commands only)
   - **Mitigation**: NetworkPolicy restricts Redis access to app namespaces
   - **Priority**: Downgraded to P3-LOW (defense-in-depth, not critical)

#### 14. ✅ **Kyverno Policy Remediation - Phase 1: Service Accounts** - COMPLETED (2025-10-28)
   - **Status**: ✅ COMPLETED - require-non-default-serviceaccount policy enabled in Enforce mode
   - **Implementation**:
     - Created 16 custom ServiceAccounts (13 apps + 3 infrastructure components)
     - Updated 44 manifests (deployments, jobs, StatefulSets)
     - Migrated 31 pods to custom service accounts
     - Special fix for Immich Helm chart using Flux postRenderers
   - **Git Activity**: 7 commits (a293197 → 584d3a1)
   - **Security Impact**:
     - ✅ Eliminated default service account usage across all applications
     - ✅ Enforced least privilege principle at admission control
     - ✅ Policy now blocks insecure pods at admission webhook
   - **Testing**: All 31 pods verified running with 0 restarts, all applications functional
   - **Commit**: 584d3a1

#### 15. ✅ **Kyverno Policy Remediation - Phase 2: Seccomp Profiles** - COMPLETED (2025-10-28)
   - **Status**: ✅ COMPLETED - require-seccomp-runtimedefault policy enabled in Enforce mode
   - **Implementation**:
     - Added `seccompProfile: RuntimeDefault` to 23 workloads
     - Fixed 16 application deployments (all apps now compliant)
     - Fixed 6 infrastructure components (Trivy, Kyverno, cert-manager, databases)
     - Removed node-cleanup job (no longer needed with seccomp)
     - Removed uptime-kuma fix-permissions job (seccomp incompatible)
   - **Git Activity**: 2 commits (5a68943, 8eaf7ea)
   - **Security Impact**:
     - ✅ Enabled kernel syscall filtering across all workloads
     - ✅ Reduced attack surface via default seccomp profile
     - ✅ Policy now blocks pods without seccomp at admission webhook
   - **Testing**: All 31 pods verified running with seccomp RuntimeDefault, 0 restarts
   - **Commit**: 8eaf7ea

#### 16. ⚠️ **Kyverno Policy Remediation - Phase 3: Resource Limits** - PARTIALLY COMPLETED (2025-10-28)
   - **Status**: ⚠️ PARTIALLY COMPLETED - require-resource-limits policy remains in Audit mode
   - **Implementation**:
     - Analyzed 7-day peak resource usage from Prometheus metrics
     - Added resource limits to Immich jobs (admin-setup, init-extensions)
     - Added resource limits to Loki canary (96Mi/20m) ✅
     - Configured Prometheus stack limits (Grafana sidecars: 192Mi, config-reloaders: 64Mi)
     - Increased Trivy operator limits (1.5Gi/1000m for peak scanning workload)
   - **Git Activity**: 1 commit (5e28d3e)
   - **Helm Chart Limitations Discovered**:
     - Grafana sidecars (sc-dashboard, sc-datasources): Chart doesn't expose resource configuration
     - Prometheus/Alertmanager config-reloader: Chart doesn't support sidecar resource limits
     - Loki sc-rules sidecar: Chart doesn't support resource configuration
     - Trivy/Kyverno: Helm values keys don't match chart expectations
   - **Remaining Violations**: 14 workloads (8 monitoring sidecars, 5 kube-system, 1 Trivy)
   - **Peak Usage Data** (7 days):
     - Grafana sidecars: 143Mi peak → 192Mi configured
     - Prometheus: 1705Mi/66m peak → 2.5Gi/500m configured
     - Alertmanager: 68Mi peak → 128Mi configured
     - Trivy: 945Mi/618m peak → 1.5Gi/1000m configured
   - **Decision**: Keep policy in Audit mode - sidecars are low-resource (<150Mi peak), fixing requires Kustomize post-render patches
   - **Testing**: Main workloads (Loki canary) verified with limits applied, all pods running
   - **Commit**: 5e28d3e

---

### 📋 P2-MEDIUM (Next 3 Months)

#### 14. **Deploy Velero for Cluster-Level Backups**
   - **Benefit**: Kubernetes-native backup solution
   - **Action**: Deploy Velero with CSI snapshot support
   - **Estimated Effort**: 4-6 hours
   - **Priority**: P2-MEDIUM
   - **Status**: Already in roadmap (task #17)

#### 15. ✅ **COMPLETED: Backup Integrity Checks (SHA256)** (2025-10-31)
   - **Status**: ✅ All backup systems now generate SHA256 checksums, validated working correctly
   - **Implementation**: PostgreSQL, CouchDB, and PVC backups all generate `.sha256` files
   - **Validation Testing** (2025-10-31):
     - Created test backups for all three systems (PostgreSQL, CouchDB, PVC)
     - Ran `sha256sum -c` validation on actual backup files
     - ✅ PostgreSQL: Checksum validation PASSED
     - ✅ CouchDB: Checksum validation PASSED
     - ✅ PVC: Checksum validation PASSED (after fix)
   - **Bug Fix**: PVC backup script used absolute paths in SHA256 files, fixed to use relative paths
   - **Verification**: `sha256sum -c backup_file.tar.gz.sha256` before restore
   - **Benefit**: Detect silent data corruption during restore operations
   - **Documentation**: BACKUP_STRATEGY.md updated with SHA256 verification steps
   - **Commits**: PVC backup fix (0fbbd37)

#### 16. ✅ **COMPLETED: Encrypt Secrets Backup with GPG** (2025-10-31)
   - **Status**: ✅ GPG AES256 encryption fully implemented with interactive passphrase
   - **Implementation**: `.backup/secrets-backup.sh` and `.backup/secrets-restore.sh`
   - **Security**: Interactive passphrase prompt (no hardcoded defaults), confirmation to prevent typos
   - **Format**: Backups saved as `.tar.gz.gpg` encrypted archives
   - **Documentation**: BACKUP_STRATEGY.md lines 190-224 documents usage
   - **No action needed** - Already complete

#### 17. **Implement Backup Immutability**
   - **Benefit**: Ransomware protection via S3 object lock or ZFS snapshots
   - **Action**: Implement immutable backups
   - **Estimated Effort**: 2-4 hours
   - **Priority**: P2-MEDIUM

#### 18. ✅ **COMPLETED: Rate Limiting Middleware** (2025-10-31)
   - **Status**: ✅ 100% coverage - All 17 ingresses have rate limiting
   - **Implementation**: Two-tier rate limiting strategy
     - **Standard (11 apps)**: 100 req/sec average, 150 burst (adguard-home, audiobookshelf, homehub, homepage, linkding, mealie, paperless-ngx, stirling-pdf, uptime-kuma, wallabag, monitoring)
     - **High-frequency (5 apps)**: 200 req/sec average, 300 burst (authentik, couchdb, home-assistant, immich, n8n)
   - **Configuration**: Per-IP rate limiting (ipStrategy depth: 0)
   - **Middleware**: `traefik-rate-limit-standard`, `traefik-rate-limit-high-frequency`
   - **Benefits**: Protection against brute force attacks, API abuse prevention
   - **No action needed** - Already fully implemented

#### 19. ✅ **COMPLETED: Security Headers (CSP, HSTS)** (2025-10-31)
   - **Status**: ✅ 100% coverage - All 17 ingresses have security headers
   - **Implementation**: Comprehensive security header middleware
     - **HSTS**: `Strict-Transport-Security: max-age=604800` (1 week, enforced HTTPS)
     - **XSS Protection**: `X-Content-Type-Options: nosniff` (prevents MIME sniffing)
     - **Clickjacking**: `X-Frame-Options: SAMEORIGIN` (prevents iframe embedding)
     - **Referrer Policy**: `strict-origin-when-cross-origin` (privacy protection)
     - **Permissions Policy**: `interest-cohort=()` (blocks Google FLoC tracking)
     - **Server Fingerprinting**: `X-Powered-By: ""` (removes server version disclosure)
     - **CSP**: Content Security Policy in report-only mode (monitoring violations)
   - **Middleware**: `traefik-security-headers`, `monitoring-security-headers`
   - **Cloudflare Edge**: Additional HSTS at edge (1 month max-age) for tunnel-exposed services
   - **Benefits**: Protection against XSS, clickjacking, MIME sniffing, tracking, man-in-the-middle attacks
   - **No action needed** - Already fully implemented

#### 20. ✅ **VERIFIED: PgBouncer Pooler Usage is Correct** (2025-10-31)
   - **Status**: ✅ All apps correctly using `main-postgres-rw-pooler.databases.svc.cluster.local`
   - **Configuration**: 3 PgBouncer pooler pods running in HA mode
   - **Pooler Type**: Read-Write (rw) pooler - correct for all apps requiring write access
   - **Verified Apps**: authentik, immich, n8n, paperless, linkding, mealie, wallabag, audiobookshelf
   - **Connection Pooling**: Active and protecting PostgreSQL from connection exhaustion
   - **No action needed** - Already working correctly

#### 21. ✅ **ACCEPTED: Database User CREATEDB Permissions** (2025-10-31)
   - **Status**: ✅ Intentional architectural decision - CREATEDB privilege required and safe
   - **Research Findings** (thorough investigation):
     - **Apps with custom extensions** (genuinely need CREATEDB):
       - Immich: 6 extensions (vector, cube, earthdistance, pg_trgm, unaccent, uuid-ossp)
       - N8N: 1 extension (uuid-ossp) + schema creation
     - **Apps with only default extensions** (plpgsql only):
       - Authentik, Linkding, Mealie, Paperless, Wallabag (Django/standard migrations)
   - **Why CREATEDB is Required**:
     - Applications need `CREATE EXTENSION` privileges during migrations
     - Future app versions may add new PostgreSQL extensions
     - No mechanism to temporarily elevate privileges for upgrades
     - CloudNativePG likely grants CREATEDB automatically to database owners
   - **Migration Patterns Verified**:
     - Django apps (Authentik, Paperless, Mealie): ALTER TABLE operations only after initial setup
     - TypeORM apps (Immich, N8N): May create extensions during version upgrades
     - Breaking apps during updates is worse than over-permissioning
   - **Risk Mitigation in Place**:
     - ✅ Apps isolated via NetworkPolicies (13/13 apps)
     - ✅ Each app has dedicated database user (not shared)
     - ✅ Apps can only access their own database (PostgreSQL grants)
     - ✅ No CREATEROLE privilege (cannot create other users)
     - ✅ Daily backups protect against data loss
   - **Trade-off Analysis**: Removing CREATEDB risks breaking future migrations for marginal security gain
   - **Decision**: Accept CREATEDB as necessary operational requirement for PostgreSQL-based apps
   - **No action needed** - Current permissions are appropriate for homelab

#### 22. ✅ **DOCUMENTED: Single Instance Redis and CouchDB** (2025-10-31)
   - **Status**: ✅ Intentional architectural decision for homelab environment
   - **Decision Rationale**:
     - **Redis**: Single instance acceptable - used only for Immich cache/session data
       - Data loss impact: LOW (cache can be rebuilt, sessions regenerate)
       - Persistence: AOF enabled for durability
       - Backups: Not needed (transient cache data)
       - Recovery: Redis restarts in <10s, Immich rebuilds cache automatically
     - **CouchDB**: Single instance acceptable - used only for Obsidian sync
       - Data loss impact: LOW (primary data in local Obsidian vaults)
       - Persistence: PVC with daily backups (30-day retention)
       - Backups: Automated daily backups via `@cloudant/couchbackup` (3.1MB compressed)
       - Recovery: Restore from backup in <5 minutes
   - **Alternative Considered**: Redis Sentinel (3 nodes) + CouchDB cluster (3 nodes)
     - **Rejected**: Adds 6 pods, increases complexity, minimal benefit for homelab
     - **Cost**: 6 additional pods × 256Mi RAM = 1.5GB extra memory for marginal uptime gain
   - **Acceptable Trade-off**: Prioritize simplicity over 99.99% uptime for homelab
   - **Risk Assessment**: LOW - proper backups mitigate data loss, short recovery times acceptable

#### 23. **SOPS Single Encryption Key**
   - **Risk**: Single age key for all secrets
   - **Impact**: Key compromise = all secrets exposed
   - **Action**: Implement multi-key SOPS encryption
   - **Estimated Effort**: 4 hours (key rotation)
   - **Priority**: P2-MEDIUM

#### 24. ✅ **LoadBalancer Documentation - Using K3s ServiceLB** - COMPLETED (2025-10-29)
   - **Status**: ✅ Documented - MetalLB is NOT installed, using K3s built-in ServiceLB
   - **Discovery**: Cluster uses K3s ServiceLB (svclb) for LoadBalancer services
   - **Current State**:
     - 2 LoadBalancer services (traefik, adguard-home-dns)
     - Both services use worker node IP: 192.168.1.129
     - ServiceLB DaemonSet pods running in kube-system
   - **Documentation**: Created `infrastructure/controllers/base/servicelb/README.md`
   - **Fixed**: Removed incorrect MetalLB annotation from adguard-home service
   - **Decision**: Keep K3s ServiceLB (adequate for 2 services, zero configuration)
   - **Commit**: 0da1bd5

#### 25. ✅ **VERIFIED: Cloudflare Tunnel Health Checks Already Configured** (2025-10-31)
   - **Status**: ✅ Health checks fully configured and operational
   - **Implementation**: `infrastructure/configs/staging/cloudflare/cloudflared.yaml` lines 65-80
   - **Liveness Probe**: HTTP GET `/ready` on port 2000 (every 10s, failure threshold: 3, initial delay: 30s)
   - **Readiness Probe**: HTTP GET `/ready` on port 2000 (every 10s, failure threshold: 1, initial delay: 10s)
   - **Metrics**: Exposed on `0.0.0.0:2000` via cloudflared-metrics service
   - **Monitoring**: ServiceMonitor configured for Prometheus scraping
   - **No action needed** - Already working correctly

#### 26. **ReadOnlyRootFilesystem Only 44% Adoption**
   - **Current**: 7/16 apps use readOnlyRootFilesystem
   - **Impact**: Increased attack surface
   - **Action**: Enable for remaining 9 apps
   - **Estimated Effort**: 4-6 hours (per app)
   - **Priority**: P2-MEDIUM

#### 27. ✅ **VERIFIED: NetworkPolicy Egress Rules Are Correct** (2025-11-02)
   - **Status**: ✅ Egress rules validated as appropriate and necessary for application functionality
   - **Initial Assessment**: 13/16 apps allow HTTPS egress (0.0.0.0/0) - appeared "overly permissive"
   - **Validation Result**: All egress rules are **legitimate and required** for core application functionality
   - **Lessons Learned** (2025-11-02):
     - **Uptime Kuma** requires unrestricted HTTP/HTTPS egress:
       - Monitors external URLs exposed via Cloudflare Tunnel
       - Core function: uptime monitoring of internet-facing services
       - Restriction breaks: External service monitoring capability
     - **Stirling PDF** requires unrestricted HTTPS egress:
       - OIDC authentication flow reaches Authentik via ingress/external URL
       - Apps may access internal services via public DNS names
       - Restriction breaks: OIDC login functionality
     - **General Pattern**: Apps monitoring external services, fetching internet content, or using OIDC legitimately need port 443 egress
   - **Apps With Legitimate Internet HTTPS Egress** (13/16):
     - Uptime Kuma (external URL monitoring)
     - Stirling PDF (OIDC via ingress)
     - Immich (ML model downloads)
     - N8N (workflow automation, external APIs)
     - Mealie (recipe scraping)
     - Wallabag (article fetching)
     - Home Assistant (IoT cloud integrations)
     - AdGuard Home (blocklist updates)
     - Audiobookshelf (metadata fetching)
     - Linkding (bookmark metadata)
     - Authentik (external OIDC providers, SMTP)
     - Paperless-NGX (email, external integrations)
     - Homepage (cluster-scoped HTTPS only)
   - **Apps With Proper Restrictions** (3/16):
     - HomeHub (no internet egress, DNS only) ✅
     - Homepage (cluster-scoped HTTPS only) ✅
     - Remaining apps (legitimate internet access) ✅
   - **Testing Performed**: Attempted hardening broke both apps, reverted in commit 760d274
   - **Recommendation**: **No changes needed** - current NetworkPolicies are correct and appropriately scoped
   - **Priority**: CLOSED - Not a security issue

#### 28. ✅ **COMPLETED: Prometheus Resource Alerts** (2025-10-31)
   - **Status**: ✅ Comprehensive container resource alerts implemented
   - **Alerts Added**: 5 new alerts for container resource monitoring
     - `ContainerCPUNearLimit`: Alert when container using >80% of CPU limit (may be throttled soon)
     - `ContainerMemoryCritical`: Alert when >95% memory used (OOMKill imminent, 2min threshold)
     - `ContainerNoResourceLimits`: Info alert for containers without memory limits (30min threshold)
     - `ContainerNoResourceRequests`: Info alert for containers without memory requests (30min threshold)
   - **Existing Alerts**: Already had strong coverage
     - `ContainerMemoryNearLimit`: Alert at >80% memory usage (5min threshold)
     - `ContainerCPUThrottling`: Alert when CPU is throttled >25% (5min threshold)
     - `ContainerOOMKilled`: Alert when container killed due to OOM
   - **Benefit**: Proactive alerting before resource exhaustion causes outages
   - **File**: `monitoring/configs/staging/kube-prometheus-stack/prometheus-rules.yaml` lines 210-244

---

### 📋 P3-LOW (Nice to Have / Long Term)

#### 29. ✅ **COMPLETED: Extended PVC Backup Retention (7 days)** (2025-10-31)
   - **Status**: ✅ Increased retention from 3 to 7 days (133% increase)
   - **Implementation**: Updated pvc-backup-cronjob.yaml to keep 7 days of backups
     - Changed retention logic from `-mtime +3` to `-mtime +7`
     - Updated all documentation references to 7-day retention
   - **Storage Impact**: +184GB (138GB → 322GB, still only 7.7% of 4.2TB)
   - **Benefits**: Better disaster recovery window, more flexibility for point-in-time recovery
   - **Commit**: 0ac8028

#### 30. **Backup Alert Grouping to Dedicated Telegram Thread**
   - **Benefit**: Easier monitoring
   - **Action**: Group backup alerts
   - **Priority**: P3-LOW

#### 31. ✅ **COMPLETED: Improve Documentation for Secrets Rotation** (2025-10-31)
   - **Status**: ✅ Added complete baseline rotation tracking to SECRETS_ROTATION.md
   - **Implementation**: Populated all rotation tables with actual dates from git history
     - Database passwords: 6 secrets (2025-10-19 to 2025-10-23)
     - Redis passwords: 3 secrets (2025-10-18)
     - Application credentials: 4 secrets (2025-10-18 to 2025-10-26)
     - OIDC secrets: 7 apps (2025-10-20)
   - **Next Rotation Dates**: All calculated based on 90/180-day cycles (Jan-Apr 2026)
   - **Enhancements**: Added git audit trail section with verification commands
   - **Benefits**: Complete rotation history tracking, proactive scheduling, audit trail
   - **Commit**: ba643a8

#### 32. **Add Grafana Dashboards for App Metrics**
   - **Benefit**: Better app-level observability
   - **Action**: Create custom dashboards
   - **Priority**: P3-LOW

#### 33. ✅ **COMPLETED: Document SSH Key Backup Location** (2025-10-31)
   - **Status**: ✅ Already documented in BACKUP_STRATEGY.md (lines 195-201)
   - **Implementation**: SSH keys stored in 1Password (not on disk)
     - 1Password SSH agent manages keys securely
     - Critical for: Git operations, cluster access, Flux GitHub integration
     - No backup needed - 1Password is the source of truth
   - **Also Documented**: SOPS age key also in 1Password (lines 199-201)
   - **Benefits**: Secure key management, no local files to backup, centralized access

#### 34. **Add PrometheusRules for Custom App Metrics**
   - **Benefit**: App-specific alerting
   - **Action**: Create custom rules
   - **Priority**: P3-LOW

#### 35. ✅ **COMPLETED: Resource Quotas for All Namespaces** (2025-10-31, Tightened)
   - **Status**: ✅ 25 ResourceQuotas deployed with tightened limits based on actual usage
   - **Implementation**: Tiered approach based on real resource consumption
     - Large tier (4 namespaces): databases, immich, monitoring, loki - **3 CPU req, 6Gi RAM req, 10 CPU limit, 12Gi RAM limit**
     - Medium tier (6 namespaces): authentik, paperless-ngx, n8n, home-assistant, obsidian, couchdb - **1.5 CPU req, 4Gi RAM req, 5 CPU limit, 8Gi RAM limit**
     - Small tier (15 namespaces): All other apps and infrastructure - 2 CPU req, 4Gi RAM req, 6 CPU limit, 8Gi RAM limit
   - **Optimization**: Reduced large tier by 62% and medium tier by 62% after analyzing actual usage
   - **Current Usage**: databases (960m/3 CPU, 1.7Gi/6Gi RAM), immich (450m/3 CPU, 1.1Gi/6Gi RAM), monitoring (650m/3 CPU, 1.9Gi/6Gi RAM)
   - **Benefits**: Resource isolation, prevents runaway consumption, tighter capacity planning
   - **Commits**: 8bcf208 (initial), 6f0087c (tightened)

#### 36. ✅ **COMPLETED: LimitRanges for All Namespaces** (2025-10-31)
   - **Status**: ✅ 25 LimitRanges deployed across all app namespaces
   - **Implementation**: Consistent defaults for all namespaces
     - Default request: 100m CPU, 128Mi RAM
     - Default limit: 1000m CPU, 1Gi RAM
     - Max per container: 8 CPU, 16Gi RAM
     - Max per pod: 16 CPU, 32Gi RAM
   - **Benefits**: All new pods get resource limits automatically, prevents unbounded consumption
   - **Impact**: New pods without resource specs will get sensible defaults
   - **Commit**: 8bcf208

---

### 📅 DEFERRED TASKS (Late December 2025 - January 2026)

#### 37. **Offsite Backup Replication to NAS** ⏸️ BLOCKED
   - **Status**: BLOCKED - Waiting for 24TB NAS hardware arrival (late December 2025, delivery postponed)
   - **Priority**: P0-CRITICAL (deferred until NAS available)
   - **Risk**: Complete data loss if worker node fails
   - **Impact**: All backups currently stored on single node `/mnt/k8s-storage/backups/`
   - **Current RPO**: 24 hours
   - **Current RTO**: Infinite (if node hardware fails)
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
   - **Target Date**: Late December 2025 (upon NAS arrival)
   - **Files**: New CronJob manifest in `infrastructure/configs/staging/backup/offsite-replication.yaml`
   - **Benefit**: Protects against node hardware failure, data center disaster
   - **Note**: DO NOT NAG UNTIL LATE DECEMBER

#### 38. **Second Worker Node** 🖥️ PLANNED
   - **Status**: PLANNED - Hardware arriving January 2026 (delayed from December 2025)
   - **Priority**: P1-HIGH (enables true HA)
   - **Current State**: Single worker node (192.168.1.129) runs all application workloads
   - **Documentation** (created 2025-11-30):
     - Setup guide: `docs/SECOND_WORKER_NODE_SETUP.md`
     - Archinstall config: `docs/archinstall-worker-node.json`
     - Post-install script: `docs/worker-node-post-install.sh`
   - **Benefit**:
     - True high availability with pod anti-affinity
     - PostgreSQL replicas on separate physical nodes
     - Zero-downtime node maintenance (drain without service interruption)
     - Increased cluster capacity for future workloads
   - **Tasks Upon Arrival**:
     1. Boot Arch ISO, run archinstall (use JSON config as reference for packages)
     2. Edit `worker-node-post-install.sh` variables: NODE_IP, K3S_TOKEN, LVM_DEVICES
     3. Get K3s token from control plane: `sudo cat /var/lib/rancher/k3s/server/node-token`
     4. Run post-install script: `sudo bash worker-node-post-install.sh`
     5. Verify node joined: `kubectl get nodes`
     6. Enable required pod anti-affinity for PostgreSQL (`podAntiAffinityType: "required"`)
     7. Test node drain/failover
     8. Add worker-node-2 to: AdGuard Home DNS, ~/.ssh/config, Uptime Kuma monitors
   - **Estimated Effort**: 2-3 hours (with automated scripts)
   - **Target Date**: January 2026
   - **Unlocks**:
     - PostgreSQL `podAntiAffinityType: "required"` (currently N/A due to single node)
     - True cross-node HA for infrastructure components
     - Node drain without workload disruption
   - **Note**: DO NOT NAG UNTIL HARDWARE ARRIVES

#### 39. **Switch to LTS Kernel 6.18** 🐧 DEFERRED
   - **Status**: DEFERRED - Waiting for Arch Linux to update `linux-lts` package to 6.18
   - **Priority**: P2-MEDIUM (stability improvement)
   - **Target Date**: January-February 2026 (when Arch packages 6.18)
   - **Current State**: Both nodes running mainline kernel 6.17.9
   - **Blocker**: Arch `linux-lts` still at 6.12.61-1 (checked 2025-12-12)
     - Linux 6.18 released upstream: Nov 30, 2025 (confirmed LTS, supported until Dec 2027)
     - Arch typically takes 4-8 weeks to transition LTS kernel series
     - Expected availability: Late January to Late February 2026
   - **Scope**: Control plane (192.168.1.127) + Worker node (192.168.1.129)
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
   - **Note**: Start checking weekly from mid-January 2026

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

## 📈 CURRENT METRICS

**Health Score: 92/100** (A- Grade) - Comprehensive Review 2025-10-27
- **Security**: 94/100 (A) ✅ - 100% PSS, 100% NetworkPolicy coverage
- **Backup/DR**: 90/100 (A) ⚠️ - Good backups, missing offsite/WAL archiving
- **Database**: 67/100 (B) ⚠️ - PostgreSQL HA, missing NetworkPolicy/TLS
- **Infrastructure**: 75/100 (B+) ⚠️ - Flux/Traefik solid, cert-manager duplicates
- **Maintainability**: 95/100 (A) ✅ - Excellent docs, GitOps-driven
- **Best Practices**: 88/100 (A-) ✅ - K8s standards followed, some gaps
- **Performance**: 92/100 (A-) ✅ - Resource optimization, 91% efficiency

**Overall Grade**: A- (92/100) - Down from A+ (99/100) after comprehensive review
- **Critical Issues**: 4 P0 issues requiring immediate attention
- **High Priority**: 9 P1 issues to complete this month
- **Total Findings**: 36 actionable items (4 P0, 9 P1, 15 P2, 8 P3)

**Target**: 96/100 (A+) after addressing P0 issues (~10 hours effort)

**Security Achievements** ✅:
- **100% Pod Security Standards** (Apps: 11 restricted, 4 baseline, 1 privileged | Jobs: 5 restricted, 1 baseline)
- **100% NetworkPolicy Coverage** (16/16 apps)
- **100% SOPS Encryption** for secrets
- **100% Image Version Pinning** (no :latest tags)
- **100% SSO Coverage** (8/8 applicable apps)

**Critical Gaps Identified** (2025-10-27 Review) 🔴:
- No offsite backup replication (P0-CRITICAL)
- PostgreSQL has no NetworkPolicy (P0-CRITICAL)
- Duplicate cert-manager ClusterIssuers (P0-CRITICAL)
- No CNPG WAL archiving - 24h RPO (P0-CRITICAL)

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
- **Tunnel ID**: c2188394-85ac-402a-8025-0e404ae6004f
- **Tunnel Name**: homelab
- **Zone**: h0melab.work (Zone ID: 58eff30c44f4f96e97eebf5d5a0b34be)
- **Management**: Cloudflare Dashboard/API (NOT ConfigMap-based)
- **Namespace**: cloudflare-tunnel

**Active Services (9):**
1. home.h0melab.work → Home Assistant (port 8123)
2. grafana.h0melab.work → Grafana (port 80)
3. uptime.h0melab.work → Uptime Kuma (port 3001)
4. am.h0melab.work → Alertmanager (port 9093)
5. authentik.h0melab.work → Authentik (port 9000) ⭐ NEW
6. couchdb.h0melab.work → CouchDB (port 5984)
7. audiobooks.h0melab.work → Audiobookshelf (port 80)
8. n8n.h0melab.work → N8N (port 5678)
9. linkding.h0melab.work → Linkding (port 9090)

**Additional Services (not via tunnel):**
- mealie, wallabag, immich, paperless (internal access only)

**Configuration Details:**
- **Deployment**: infrastructure/configs/staging/cloudflare/cloudflared.yaml
- **ConfigMap**: Reference-only (tunnel config, metrics endpoint)
- **Ingress Routes**: Managed via Cloudflare Dashboard Zero Trust section
- **Important**: ConfigMap does NOT contain ingress/service routes (API-managed)

**DNS Strategy:**
- **External services (via Cloudflare Tunnel)**: CNAME records pointing to tunnel (e.g., authentik → c2188394-85ac-402a-8025-0e404ae6004f.cfargotunnel.com)
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
- **Internal services** (7 apps): Local network → AdGuard Home → Traefik Ingress → Service
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

**MariaDB (2 Replicas)**: ✅ **High Availability with Galera Cluster**
- **Usage**: Application data for Home Assistant, Uptime Kuma (2 apps migrated from SQLite)
- **Cluster Type**: Galera multi-master synchronous replication
- **Replicas**: 2 instances (active-active replication)
- **Version**: MariaDB 12.1
- **Operator**: mariadb-operator v0.37.1
- **Replication**: Synchronous multi-master (all nodes writable)
- **Failover**: Automatic via MariaDB operator
- **Why HA**: Critical application data, multi-master for write availability, automatic recovery
- **Architecture**: Matches PostgreSQL pattern (base = infrastructure, staging = app-specific resources)
- **Databases**: 2 databases (homeassistant, uptimekuma)
- **Backups**: Daily automated backups (3:15 AM, 30-day retention, SHA256 checksums)
- **Migration Date**: 2025-11-24 (completed migration from SQLite for Home Assistant & Uptime Kuma)
- **Migration Approach**:
  - Home Assistant: Fresh start (42 tables auto-created)
  - Uptime Kuma: Custom Python migration (22 tables migrated, 5 excluded)
- **Storage**: 10Gi per replica (local-path PVCs on worker node)
- **NetworkPolicy**: Restricts access to app namespaces + monitoring
- **Connection Pattern**: Direct to primary (main-mariadb-primary.databases.svc.cluster.local:3306)
- **Documentation**: Complete migration guide in `docs/MARIADB_MIGRATION.md`

**Summary**:
- **Critical data (PostgreSQL)**: 3 replicas, HA, zero downtime
- **Critical data (MariaDB)**: 2 replicas, Galera multi-master, automatic failover
- **Cache/ephemeral (Redis)**: Single instance, restart tolerance acceptable
- **Personal sync (CouchDB)**: Single instance, backup-based recovery acceptable

---

**Last Updated**: 2025-12-13 20:00 UTC
**Next Review**: 2025-12-27

---

## 📝 CHANGELOG (Recent)

*For older entries, see [HOMELAB_HISTORY.md](./HOMELAB_HISTORY.md)*

### 2025-12-13 (Documentation Refresh & Immich Quota Fix) 📋
- ✅ **Immich ResourceQuota Increased**: Fixed rolling update failures by increasing namespace quota ⭐
- ✅ **Documentation Refresh**: Updated stale dates and metrics throughout HOMELAB_ANALYSIS.md
- 🎯 **Impact**: Immich deployments now succeed during rolling updates, documentation accurate
- 🔧 **Technical Details**:
  - **Immich Quota Fix**:
    - Root cause: Rolling updates need 2x resources temporarily (old + new pods)
    - Old quota: 18Gi memory limit (insufficient for 2x 9Gi pods)
    - New quota: 24Gi memory limit, 16 CPU limit
    - File: `infrastructure/configs/staging/resource-governance/large-tier/immich.yaml`
  - **Documentation Updates**:
    - Header date: 2025-11-07 → 2025-12-13
    - Kyverno violations: Updated to current counts (30 require-resource-limits in audit mode)
    - CSP production uptime: 16 days → 43 days (still zero violations)
    - PVC backup retention: Corrected from 3-day to 7-day
    - HSTS review date: Fixed to 2026-01-15
- 📋 **Commit**: ccc0598 (Immich quota)

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

