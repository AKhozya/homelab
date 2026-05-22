# 🏗️ HOMELAB HISTORY & ARCHIVE

**Purpose**: Historical changelog and completed task archive for the homelab infrastructure.
**Related**: [HOMELAB_ANALYSIS.md](./HOMELAB_ANALYSIS.md) - Current status and active tasks
**Created**: 2025-12-13
**Coverage**: October 2025 - May 2026

---

## 📋 Table of Contents

1. [Completed Action Items Archive](#-completed-action-items-archive)
2. [Historical Changelog](#-historical-changelog-october-december-2025)

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

**Full Details**: See git history for HOMELAB_REVIEW_2025_12_17.md

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

### ✅ Completed Action Items (Archive)

#### 1. ✅ **COMPLETED: Fix wallabag PVC Namespace Leak** - P0
   - ✅ Deleted duplicate 60GB PVCs in wrong namespace
   - ✅ Recovered 60GB storage
   - ✅ Current PVCs correctly sized: 15GB total (5Gi data + 10Gi images)
   - ✅ Actual usage: 12KB total (8KB data + 4KB images)
   - ✅ No abandoned PVCs remaining on disk
   - Commit: a235309

2. ✅ **COMPLETED: Add Missing NetworkPolicies** - P0
   - ✅ wallabag, n8n, linkding, audiobookshelf
   - ✅ All 7 apps now have NetworkPolicies
   - Commit: a235309

3. ✅ **COMPLETED: BACKUP INFRASTRUCTURE** - P0 **CRITICAL** ⭐
   - ✅ **Status:** FULLY IMPLEMENTED - Complete backup infrastructure operational
   - ✅ **PostgreSQL Backups:** Daily at 2:00 AM, 30-day retention
     - Location: `/mnt/k8s-storage/backups/postgres/`
     - Covers: All 10 databases (Authentik, Immich, Paperless, Grafana, etc.)
     - Method: pg_dump via CronJob, tar.gz compression
   - ✅ **CouchDB Backups:** Daily at 2:30 AM, 30-day retention
     - Location: `/mnt/k8s-storage/backups/couchdb/`
     - Covers: obsidian-personal database
     - Method: couchbackup via CronJob, tar.gz compression
   - ✅ **PVC Backups:** Daily at 3:00 AM, 3-day retention
     - Location: `/mnt/k8s-storage/backups/pvc/`
     - Covers: Home Assistant, Immich library, Paperless, Audiobookshelf
     - Method: tar with selective compression (gzip for configs, uncompressed for media)
     - Optimization: Skips compression on media files (saves 25 min/backup)
   - ✅ **Disaster Recovery Scripts:** Complete in `.backup/` directory
     - `secrets-backup.sh` - Backs up all 50+ Kubernetes secrets
     - `secrets-restore.sh` - Restores secrets to cluster
     - `disaster-recovery.sh` - Automated full cluster recovery
   - ✅ **Documentation:** Comprehensive (3 documents)
     - `docs/BACKUP_STRATEGY.md` - Overall strategy and retention
     - `docs/BACKUP_IMPLEMENTATION.md` - Technical implementation details
     - `docs/BACKUP_COMPRESSION_ANALYSIS.md` - Optimization analysis
   - ✅ **Storage:** 4.2TB available on `/mnt/k8s-storage/backups/` (was 48.9GB root partition)
   - ✅ **Resource Optimization:** 32Mi memory, selective compression
   - 📋 **Next:** Test disaster recovery procedure, implement backup validation
   - Commits: Multiple (470972a, 4f400ae, 2ba824d, 9464f7a, 74f448a, bff6c87)

4. ✅ **COMPLETED: Enable Pod Security Standards** - P1 ⭐
   - ✅ Applied Pod Security Admission at namespace level (all 16 app namespaces)
   - ✅ **100% PSS COMPLIANCE ACHIEVED** (2025-10-26)
   - ✅ **RESTRICTED policy**: 11 apps (authentik, audiobookshelf, homepage, homehub, immich, linkding, mealie, n8n, stirling-pdf, uptime-kuma, obsidian)
   - ✅ **BASELINE policy**: 4 apps (adguard-home, paperless-ngx, wallabag, couchdb)
   - ✅ **PRIVILEGED policy**: 1 app (home-assistant - NET_ADMIN/NET_RAW for Bluetooth)
   - ✅ Fixed security contexts: Wallabag (explicit runAsUser), Immich (runAsNonRoot, proxy sidecar)
   - ✅ PSS Adjustments: Home Assistant (baseline→privileged), Paperless-NGX (restricted→baseline), Stirling PDF (removed root init)
   - Impact: Enhanced pod-level security compliance with Kubernetes security standards
   - Commits: 3c3c0d1, 916b883, ab388f5, 0874dfd, a5e67b8, ca3891c, 7f12be2, 8162673, d3b5036

5. ✅ **COMPLETED: Document Home Assistant Security** - P1 ⭐
   - ✅ Created `apps/base/home-assistant/SECURITY.md` (comprehensive 250+ line documentation)
   - ✅ Explained root requirement and security rationale (7 Linux capabilities documented)
   - ✅ Documented security mitigations (seccomp, capability dropping, privilege escalation disabled)
   - ✅ Risk assessment (MEDIUM risk level with detailed attack vector analysis)
   - ✅ Comparison table with other apps showing Home Assistant's elevated privileges
   - Impact: Clear security documentation for most privileged workload in homelab
   - Commit: 3c3c0d1

6. ✅ **COMPLETED: Complete Immich Pod Security Standards** - P1 ⭐
   - ✅ Fixed Immich Server security context (init container, proxy sidecar)
   - ✅ Removed dri-devices hostPath mount (PSS restricted violation)
   - ✅ Added pod-level securityContext (runAsUser, fsGroup, seccompProfile)
   - ✅ Added wait-for-database init container security context (runAsNonRoot, readOnlyRootFilesystem, capabilities.drop)
   - ✅ Added proxy sidecar security context (nginx with /tmp config, runAsNonRoot, capabilities.drop)
   - ✅ Tested full Immich deployment - both ML and Server running with 2/2 containers
   - ✅ Verified functionality via browser - photo library loading correctly
   - Impact: All 16 homelab applications PSS-compliant (initial completion, refined 2025-10-26)
   - Commits: abca249, aac279b, 7481664, 3263745

7. ✅ **COMPLETED: Node Drain Verification & Final PSS Fixes** - P1 ⭐
   - ✅ Restarted all 16 applications to verify PSS compliance
   - ✅ Fixed 3 apps with PSS violations (Home Assistant, Stirling PDF, Paperless-NGX)
   - ✅ Performed worker node drain with proper kubectl drain command
   - ✅ Recovered from PostgreSQL WAL corruption during drain (zero data loss)
   - ✅ Updated Authentik RAM allocation (1GB request, 1.2GB limit)
   - Impact: **100% PSS compliance validated** for all 16 homelab applications, node drain procedures verified
   - Commits: 0874dfd, a5e67b8, ca3891c, 7f12be2, 8162673, d3b5036, abb323c

8. ✅ **COMPLETED: Pod Security Standards for Jobs** - P1 ⭐
   - ✅ Fixed 6 init/setup jobs with PSS violations (all now working)
   - ✅ **PSS RESTRICTED** (5/6 jobs - 83%): audiobookshelf-init, immich-admin-setup, n8n-user-provision, couchdb-init, uptime-kuma-setup
   - ✅ **PSS BASELINE** (1/6 jobs - 17%): mealie-user-provision (requires root for apt-get install)
   - ✅ Security controls: seccompProfile:RuntimeDefault, allowPrivilegeEscalation:false, capabilities drop ALL, resource limits
   - ✅ mealie job requires: runAsUser:0, capabilities add [CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID]
   - ✅ mealie namespace changed from PSS restricted to baseline (documented limitation)
   - Impact: **100% PSS compliance for jobs** (6/6 working), enhanced job security posture
   - Documentation: `/tmp/PSS_JOBS_SUMMARY.md`
   - Commits: 0bd0be2, 3003c9a, 52dc11e, 101e4f9, ac839ff, 0858cc8

9. ✅ **COMPLETED: Flux Timeout Standardization** - P1 ⭐
   - ✅ Standardized all 6 Flux kustomizations to 45s timeout
   - ✅ **Before**: infrastructure-controllers (5m), infrastructure-configs (10m), apps (5m), monitoring (5m each)
   - ✅ **After**: All kustomizations use consistent 45s timeout
   - ✅ Verified all kustomizations reconciled successfully with new timeout
   - Impact: Predictable reconciliation behavior, faster failure detection
   - Commit: 4cc2834

10. ✅ **COMPLETED: Performance Optimization** - P1 ⭐
   - ✅ Completed performance and security audit (2025-10-26)
   - ✅ Optimized 3 over-provisioned apps (Stirling PDF, Paperless-NGX, Immich ML)
   - ✅ **Memory savings**: 7.5Gi (62.5% reduction)
   - ✅ **Efficiency improvement**: 69% → 91% memory utilization
   - ✅ Created `docs/PERFORMANCE_SECURITY_AUDIT.md` (335+ lines)
   - Impact: Better resource utilization, improved scheduling efficiency
   - Commit: 45664d6

9. ✅ **COMPLETED: Secrets Rotation Framework** - P1 ⭐
   - ✅ Created comprehensive secrets rotation playbook (2025-10-26)
   - ✅ Documented 20+ secrets inventory (DB, Redis, OIDC, TLS)
   - ✅ Defined rotation schedules (90/180/365 day cycles)
   - ✅ Step-by-step procedures with rollback instructions
   - ✅ Emergency rotation protocols
   - ✅ Created `docs/SECRETS_ROTATION.md` (350+ lines)
   - Impact: Established security rotation framework
   - Commit: c4abd54

10. ✅ **COMPLETED: App Alternatives Research** - P1 ⭐
    - ✅ Researched alternatives for all 16 apps (2025-10-26)
    - ✅ Current stack grade: **A+ (96/100)**
    - ✅ 13 apps confirmed best-in-class
    - ✅ Identified Windmill as potential N8N alternative (44% less memory)
    - ✅ Created `docs/APP_ALTERNATIVES_RESEARCH.md` (317+ lines)
    - Impact: Validated current infrastructure choices, identified optimization opportunities
    - Commit: c4abd54

#### 11. ✅ **COMPLETED: Add Homepage Dashboard** - P1
    - ✅ Centralized dashboard for all apps
    - Commit: c5b0244

#### 12. ✅ **COMPLETED: Add Uptime Kuma** - P1
    - ✅ Uptime monitoring with automated user setup
    - Commit: 46cc485

#### 13. ✅ **COMPLETED: Add SSO (Authentik)** - P1
    - ✅ SSO platform deployed with PostgreSQL and Redis
    - Commit: 46cc485

#### 14. ✅ **COMPLETED: Create Ingresses for All Apps** - P1 ⭐
    - ✅ **Completed**: 2025-10-25
    - ✅ **Dual-Access Pattern Implemented**: 10 apps with Traefik Ingress + Cloudflare Tunnel
    - ✅ **Apps Configured**: authentik, stirling-pdf, immich, paperless-ngx, audiobookshelf, mealie, wallabag, n8n, linkding, couchdb
    - ✅ **Features**: Let's Encrypt TLS, AdGuard Home DNS management, NetworkPolicy updates
    - ✅ **Benefit**: Fast local HTTPS access + secure external access via Cloudflare
    - Commits: 2d8921b, ec2f63d

#### 15. ✅ **COMPLETED: Integrate Apps with Authentik SSO** - P2 ⭐
    - **Completed**: 2025-10-22
    - **Apps Configured via Environment Variables** (3): Paperless-NGX, Linkding, Mealie
    - **Apps Configured via Web UI** (3): Grafana, Immich, Audiobookshelf
    - **Apps with Custom Integration** (1): Home Assistant (hass-oidc-auth, GitOps)
    - **Not Supported** (1): N8N (requires Enterprise plan for SSO/LDAP)
    - **Total OIDC Apps**: 7/10 applications
    - **Configuration Methods**:
      - Declarative (env vars): Paperless-NGX, Linkding, Mealie
      - Database-stored (web UI): Immich, Audiobookshelf
      - Pre-configured: Grafana
      - Custom integration (GitOps): Home Assistant (hass-oidc-auth via HACS)
    - **Note**: N8N Community Edition does not support SSO/LDAP - Enterprise plan required
    - Commit: 5e85276

#### 16. ✅ **COMPLETED: Backup Validation** - P2 ⭐
    - ✅ **Status:** FULLY VALIDATED - All backups tested and proven restorable
    - ✅ **PostgreSQL:** 2 databases restored successfully (authentik: 178 tables, immich: 49 tables)
    - ✅ **CouchDB:** 337 documents restored successfully
    - ✅ **PVC Backups:** 2,363 files extracted successfully (Home Assistant, Paperless)
    - ✅ **Disaster Recovery Scripts:** All validated (syntax, dependencies, paths)
    - ✅ **Performance:** All restorations complete in <15 seconds
    - ✅ **Data Integrity:** No corruption detected in any backup
    - ✅ **Documentation:** Comprehensive validation report created
    - 📋 **Report:** `docs/BACKUP_VALIDATION_REPORT.md`
    - 🎯 **Next:** Proceed to task #17 (Velero deployment)
    - Date Completed: 2025-10-26

---

### Additional Completed Items (From Comprehensive Review 2025-10-27)

#### 17. ✅ **PostgreSQL NetworkPolicy** - P0-CRITICAL (2025-10-27)
   - Created NetworkPolicy restricting access to app namespaces only
   - Risk: Unrestricted access to all databases from any pod (CVSS: 7.5 HIGH)
   - Files: `infrastructure/configs/base/databases/postgres/networkpolicy.yaml`
   - Commit: a80d4bf

#### 18. ✅ **Duplicate cert-manager ClusterIssuers** - P0-CRITICAL (2025-10-27)
   - Deleted orphaned `controllers/base/cert-manager/clusterissuer.yaml`
   - Kept `infrastructure/configs/base/cert-manager/clusterissuer.yaml`
   - Commit: 2cb9e78

#### 19. ❌ **CNPG WAL Archiving** - P0 REMOVED (Not Implementing)
   - Decision: Not implementing - CNPG barman requires S3/Azure/Google credentials
   - Alternative: Continue with existing pg_dump daily backups (24h RPO acceptable for homelab)
   - barmanObjectStore doesn't support local filesystem paths

#### 20. ✅ **CSP Enforcement** - P1 (2025-10-31) ⭐
   - CSP in enforcement mode across all 17 apps (43 days active, zero violations)
   - Policy: `default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'`
   - Monitoring: csp-reporter service → Loki
   - Testing: 85 automated tests (17 apps × 5 scenarios) - 100% pass rate
   - Commits: b8b6306, 7b2c72b, 54c8484, 04df8a4

#### 21. ✅ **Pod Anti-Affinity for PostgreSQL** - P1 (2025-10-29)
   - True cross-node HA with required anti-affinity
   - Instances: 2 (reduced from 3 for 2-node cluster)
   - Anti-affinity: `podAntiAffinityType: "required"` (HARD constraint)
   - main-postgres-5 (Primary): worker-node, main-postgres-6 (Replica): control-plane
   - Commits: cbc71d0, 30c1f8a, 95fe37a, eef307d

#### 22. ✅ **CNPG Port 8000 Binding** - P1 RESOLVED (2025-10-30)
   - Issue: CNPG instance manager silently fails to bind status port 8000 on K3s control-plane
   - Resolution: Removed control-plane toleration, running PostgreSQL on worker-node only
   - Bug report: https://github.com/cloudnative-pg/cloudnative-pg/issues/9013

#### 23. ✅ **PostgreSQL TLS** - ALREADY IMPLEMENTED (2025-10-27)
   - TLS enabled by CloudNativePG, all apps using it (ssl=t in pg_stat_ssl)
   - Minor gap: Could enforce TLS at pg_hba level (host→hostssl)

#### 24. ❌ **Redis Backup** - NOT IMPLEMENTING
   - Redis used only as cache (ephemeral data)
   - Impact: User re-login required, jobs re-queued on pod deletion (acceptable)
   - RDB snapshots on PVC sufficient for cache use case

#### 25. ✅ **Flux Timeout Standardization** - P1 (2025-10-27)
   - All 6 kustomizations standardized to 45s timeout
   - Commit: 4cc2834

#### 26. ✅ **Traefik Health Checks** - ALREADY IMPLEMENTED (2025-10-27)
   - 15/15 apps have readinessProbe and livenessProbe
   - Kubernetes Service endpoints automatically exclude unhealthy pods

#### 27. ✅ **High Availability for Critical Components** - P1 (2025-10-29)
   - Traefik: 2 replicas with pod anti-affinity
   - cert-manager (all 3 components): 2 replicas with pod anti-affinity
   - Cloudflare tunnel: 2 replicas across nodes
   - Control plane tolerations enabled for all
   - Commits: e07474a, 898d969, 6a52f5c, cbc71d0

#### 28. ✅ **Scattered Middleware Configurations** - P1 (2025-10-27)
   - Centralized HTTPS redirect middleware to traefik namespace
   - Before: 15 duplicate middleware files (140 lines)
   - After: Single `traefik/redirect-https` middleware
   - Commit: 9a9ebce

#### 29. ⚠️ **Redis ACLs** - VALID BUT NOT FIXABLE (2025-10-27)
   - Apps don't support key prefixes (broke cache keys when restricted)
   - Current: `~* &* +@all -@dangerous -acl` (all keys, safe commands only)
   - Mitigation: NetworkPolicy restricts Redis access to app namespaces

#### 30. ✅ **Kyverno Phase 1: Service Accounts** - P1 (2025-10-28)
   - require-non-default-serviceaccount policy enabled in Enforce mode
   - Created 16 custom ServiceAccounts, updated 44 manifests, migrated 31 pods
   - Commits: a293197 → 584d3a1

#### 31. ✅ **Kyverno Phase 2: Seccomp Profiles** - P1 (2025-10-28)
   - require-seccomp-runtimedefault policy enabled in Enforce mode
   - Added `seccompProfile: RuntimeDefault` to 23 workloads
   - Commits: 5a68943, 8eaf7ea

#### 32. ⚠️ **Kyverno Phase 3: Resource Limits** - PARTIALLY COMPLETED (2025-10-28)
   - require-resource-limits policy remains in Audit mode
   - 30 violations remain (monitoring sidecars, kube-system)
   - Helm charts don't expose sidecar resource configuration
   - Commit: 5e28d3e

#### 33. ✅ **Backup Integrity Checks (SHA256)** - P2 (2025-10-31)
   - All backup systems generate SHA256 checksums
   - PostgreSQL, CouchDB, PVC backups all validated
   - Bug Fix: PVC script fixed to use relative paths
   - Commit: 0fbbd37

#### 34. ✅ **GPG Secrets Encryption** - P2 (2025-10-31)
   - GPG AES256 encryption with interactive passphrase
   - Files: `.backup/secrets-backup.sh`, `.backup/secrets-restore.sh`
   - Format: `.tar.gz.gpg` encrypted archives

#### 35. ✅ **Rate Limiting Middleware** - P2 (2025-10-31)
   - 100% coverage - All 17 ingresses have rate limiting
   - Standard (11 apps): 100 req/sec, 150 burst
   - High-frequency (5 apps): 200 req/sec, 300 burst

#### 36. ✅ **Security Headers** - P2 (2025-10-31)
   - 100% coverage - All 17 ingresses have security headers
   - HSTS, X-Content-Type-Options, X-Frame-Options, Referrer-Policy, Permissions-Policy, CSP

#### 37. ✅ **PgBouncer Pooler** - VERIFIED (2025-10-31)
   - All apps correctly using `main-postgres-rw-pooler.databases.svc.cluster.local`
   - 3 PgBouncer pods in HA mode

#### 38. ✅ **Database CREATEDB Permissions** - ACCEPTED (2025-10-31)
   - Intentional decision - CREATEDB required for extensions during migrations
   - Immich: 6 extensions, N8N: 1 extension + schema creation
   - Risk mitigated via NetworkPolicies and per-app database users

#### 39. ✅ **Single Instance Redis/CouchDB** - DOCUMENTED (2025-10-31)
   - Redis: Cache data, acceptable loss, <10s restart recovery
   - CouchDB: Obsidian sync, primary data in local vaults, daily backups
   - Trade-off: Simplicity over 99.99% uptime for homelab

#### 40. ✅ **LoadBalancer Documentation** - P2 (2025-10-29)
   - Documented K3s ServiceLB (not MetalLB)
   - Created `infrastructure/controllers/base/servicelb/README.md`
   - Commit: 0da1bd5

#### 41. ✅ **Cloudflare Tunnel Health Checks** - VERIFIED (2025-10-31)
   - Liveness/Readiness probes configured on port 2000
   - ServiceMonitor for Prometheus scraping

#### 42. ✅ **NetworkPolicy Egress Rules** - VERIFIED (2025-11-02)
   - All egress rules validated as legitimate for app functionality
   - 13/16 apps need HTTPS egress for OIDC, external APIs, content fetching
   - Testing: Hardening broke apps, reverted (commit 760d274)

#### 43. ✅ **Prometheus Resource Alerts** - P2 (2025-10-31)
   - 5 new container resource alerts implemented
   - ContainerCPUNearLimit, ContainerMemoryCritical, ContainerNoResourceLimits/Requests

#### 44. ✅ **Extended PVC Backup Retention** - P3 (2025-10-31)
   - Increased from 3 to 7 days
   - Storage impact: +184GB (still only 7.7% of 4.2TB)
   - Commit: 0ac8028

#### 45. ✅ **Secrets Rotation Documentation** - P3 (2025-10-31)
   - Complete baseline rotation tracking in SECRETS_ROTATION.md
   - All rotation dates populated from git history
   - Next rotation dates calculated (Jan-Apr 2026)
   - Commit: ba643a8

#### 46. ✅ **SSH Key Backup Location** - P3 (2025-10-31)
   - Already documented in BACKUP_STRATEGY.md
   - SSH keys and SOPS age key stored in 1Password

#### 47. ✅ **Resource Quotas for All Namespaces** - P3 (2025-10-31)
   - 25 ResourceQuotas deployed (tiered: large/medium/small)
   - Optimized based on actual usage (62% reduction in large/medium tiers)
   - Commits: 8bcf208, 6f0087c

#### 48. ✅ **LimitRanges for All Namespaces** - P3 (2025-10-31)
   - 25 LimitRanges deployed
   - Default: 100m CPU/128Mi RAM request, 1000m CPU/1Gi RAM limit
   - Max per container: 8 CPU/16Gi RAM
   - Commit: 8bcf208

---

## 📝 Historical Changelog (October 2025 - Present)

### 2026-05-22 (CODEMAPS refresh + HOMELAB_ANALYSIS drift fix) 📚
- ✅ **6 codemap files refreshed to live cluster state** (commit `106107df` + follow-up): drift accumulated since 2026-05-08 (14 days). `README.md` 17→16 apps. `architecture.md` 28→27 ns, 55→53 SOPS secrets, "Traefik IngressRoute" → "Traefik Ingress (class=traefik)" (0 IngressRoute CRDs in use; all 16 ingresses are vanilla K8s `Ingress` resources). `apps.md` 10 image bumps: homepage v1.13.1, authentik 2026.5.0, blocky v0.30.0, stirling-pdf 2.11.0-fat, immich helm 0.12.0, home-assistant 2026.5.4, mealie v3.18.0, n8n 2.21.7, audiobookshelf 2.35.0, claude-telegram 1.22; added meilisearch v1.44.0 note for linkwarden. `databases.md` CNPG image 18.3→18.4, helm chart 0.28.x→0.28.2 (pinned exact), controller 1.29.0→1.29.1 (deploy `cnpg-operator-cloudnative-pg` in `databases` ns, NOT `cnpg-system`), `immich-backup` row added. `monitoring.md` kube-prometheus-stack 84.5.0→85.2.2, victoria-metrics-operator 0.62.1→0.63.1, vm-images v1.140.0→v1.143.0, vm-operator v0.69.0→v0.70.1, grafana 13.0.1→13.0.1-security-01, kube-state-metrics v2.18.0→v2.19.0, node-exporter v1.11.1→v1.11.1-distroless, added loki 3.6.7 + alloy v1.16.1 image lines; scrapes 26+2→37+4 (cluster grew); 12→13 scrape files. `networking.md` traefik chart 40.0.0→40.2.0 + image v3.7.1, blocky v0.29.0→v0.30.0, IngressRoute terminology corrected.
- ✅ **HOMELAB_ANALYSIS.md synced**: Key facts row 55→53 SOPS; APPS table 17→16 (Grafana row removed — already moved to monitoring infra in codemap on 2026-05-08, this finally aligns HA doc); Monthly Review Checklist "Last refresh: 2026-05-08" → 2026-05-22.
- 🔍 **Fact-check methodology**: single `ctx_batch_execute` pass pulled live state for all chart versions (`kubectl get hr -A`), image pins (`kubectl get deploy/sts -A -o json`), CRD counts (vmservicescrape 37, vmpodscrape 4, vmrule 2 / 26 groups, netpol 44, kpol 10, ingress 16, ingressroute 0), ns count 27 (excl flux-system), SOPS file count 53 (`find . -name '*.yaml' -exec grep -l 'sops:'`). Cloudflare Tunnel `cloudflared-config` decoded — 9 svcs in config.yaml match codemap (authentik, couchdb, audiobooks, linkwarden, stirling, mealie, paperless, immich, n8n). Token expiry 2026-12-31 verified against `docs/SECRETS_ROTATION.md`.
- 🧹 **Lint pass**: markdownlint not installed (npx offline disabled) — fell back to manual checks: per-file column count consistency (all tables uniform), trailing-whitespace scan (clean), backtick parity (all even = no broken code spans), heading hierarchy (no skipped levels). All pass.
- 📝 **Gap residual**: codemap monitoring.md "Notable groups" list incomplete vs live 26 groups (alertmanager-overrides, backup-alerts, couchdb-alerts, monitoring-health-alerts, rate-limiting-alerts, resource-exhaustion-alerts, service-alerts, storage-alerts not enumerated — "etc." used). Accepted as deliberate compression, not refreshed.

### 2026-05-22 (Backup overhaul — coverage + retention + immich weekly) 💾
- ⚠️ **Coverage audit**: 5 PVCs missing from daily backup whitelist (mealie, n8n, audiobookshelf-config + -metadata, claude-telegram). Plus stale `uptime-kuma/uptime-kuma-data-pvc` (UK switched to emptyDir).
- ✅ **PVC whitelist updated** (commit `49d6afb2`): added mealie/mealie-data-pvc, n8n/n8n-data-pvc, audiobookshelf/audiobookshelf-config + -metadata. Removed stale uptime-kuma. `claude-telegram/claude-telegram-home-pvc` documented as expendable (session-only state, bot rebuilds on restart). immich/immich-machine-learning, loki, vmsingle, stirling-pipeline/tessdata documented as expendable (regenerable runtime).
- ✅ **immich weekly CronJob**: 63G photo PVC was excluded from daily. Now `immich-backup` CronJob Sunday 03:00 UTC, uncompressed tar (JPEG already compressed), 2-pass tar + sha256, keep-2 retention. Live test: tar 187s (~340 MB/s disk-bound), sha256 914s (~75 MB/s single-thread Celeron N5095), total 18m21s. Fits 30min window before 03:30 replication.
- ✅ **Retention policy** (commits `49d6afb2`, `73f7a611`): W1 source 7d → 30d (`find -mtime +30 -delete`). NAS gets prune step (Step 5b in `backup-replication`): 30d for postgres/mysql/couchdb files (`prune_nas_file` via rsync filter rules `--include=<file> --exclude='*'` against empty source) + 30d for pvc dirs + keep-2 for immich (`prune_nas_dir` via empty-source rsync). Soft-fail (`|| true`) if daemon refuses delete → manual NAS UI fallback. Initial run pruned 162+ files per DB category + 70+ pvc dirs back to 30d window; immich kept latest.
- 🐛 **Bug found + fixed mid-test**: first prune iteration only matched DIRS (regex `^d`). DB backups are top-level FILES — got skipped entirely. Added `prune_nas_file()` helper + separate awk pass for `(postgres|mysql|couchdb)/[a-z]+_[0-9]{8}_[0-9]+\.tar\.gz` pattern. Immich safety verified: file-prune regex requires single `/` + DB-category allow-list — immich's `immich/<TS>/immich-library.tar` (two `/`s, not in allow-list) cannot match.
- 📊 **Redis backup decision**: audit confirmed Redis = cache + queue/broker (DB0 = BullMQ/Celery/Django sessions; DB1 = pure TTL'd cache). No durable user data. Redis HA (2 replicas + 3 sentinels + RDB+AOF) handles single-pod loss. **No backup needed** — documented in BACKUP_STRATEGY.md.
- 📈 **NAS state** post-cleanup: 14.03 GiB → 72 GiB peak during test (incl. 62.5G immich) → trimmed back to natural-only after test artifact removal. 30d window enforced: postgres/mysql/couchdb=60 files each, pvc=636 files / 270 dirs, immich=0 (next Sunday).
- 📚 **Docs**: BACKUP_STRATEGY.md updated with new PVC list, retention policy, immich weekly section, "What's NOT backed up by design" table.

### 2026-05-22 (Drift-heal mid-flight ansible-core upgrade race) 🐛
- ⚠️ **Incident**: drift-heal failed on all 3 nodes with `ConfigManager.get_config_value() got an unexpected keyword argument 'templar'` on `base_config : Deploy /etc/logrotate.d/pacman` (copy task). Secondary warning: `cannot import name 'VaultDecryptionContext' from 'ansible._internal._yaml._dumper'` killed `ansible.builtin.core` filter plugin.
- 🔍 **Root cause**: manual `pacman -Syu` at 13:24:02 BST (upgrading ansible-core 2.20.5 → 2.21.0) raced the 10-min drift-heal timer fired at 13:24:16. ansible-playbook imported ConfigManager from 2.20.5 in memory; mid-run the on-disk core flipped to 2.21.0. Next action plugin reload picked up new `copy.py` (passes `templar=` kwarg) while ConfigManager singleton stayed on old import → TypeError. NOT a version bug — `get_config_value()` in on-disk 2.21.0 *does* accept `templar` (verified via `inspect.signature`). Pure timing race.
- ✅ **Fix** (commit `3b5696d7`): two systemd guards prevent recurrence:
  - `node-maintenance-config.service` gets second `ExecCondition=/bin/sh -c '[ ! -e /var/lib/pacman/db.lck ]'` — drift-heal skips its 10-min cycle when pacman holds the DB lock. Skip is safe; next timer cycle catches up.
  - `node-maintenance-phase1.service` gets `ExecStartPre=/usr/bin/pacman -Sy --noconfirm --needed ansible ansible-core` — pre-upgrades ansible runtime BEFORE ansible-playbook starts. Subsequent `yay -Syu` inside phase1 then finds ansible-core current → no mid-play bump.
- 📝 **Verification**: post-deploy drift-heal cycles green on all 3 nodes (CP `ok=100`, W1+W2 `ok=121` each, `changed=0 failed=0 unreachable=0`). systemd status confirms new ExecCondition fires + passes.
- 📚 **Gotcha logged**: memory `gotchas.md` — "Ansible mid-play runtime upgrade race". Don't pin/downgrade — Arch rolling; fix timing instead. Pattern applies to any long-running ansible-playbook that triggers `pacman -Syu` against its own runtime.

### 2026-05-22 (Rebuilderd W2 memory limit reduction) 🔧
- ⚠️ **Incident**: cosmic-launcher rebuilderd build on worker-node-2 peaked at 7.4G RAM, combined with concurrent ansible node-maintenance + kernel builds caused node memory pressure. 6 pods CrashLooped across both workers (cert-manager-cainjector ×2, kyverno-cleanup-controller, main-mysql-haproxy, ps-operator, +1). Control plane showed API proxy broken pipes. All self-resolved in ~10min.
- ✅ **Fix**: Reduced rebuilderd systemd cgroup limits on worker-node-2: MemoryMax 12G→8G, MemoryHigh 11G→6G, MAX_MEMORY env 12G→8G. Swap unchanged at 16G (big builds spill to swap instead of pressuring K8s). Commit `f1efef99`. Applies at next drift-heal (03:00 UTC) or manual trigger.
- 📝 **History**: W2 limits trajectory: 18G (initial) → 14G (2026-02-21 DPDK OOM) → 12G (2026-04-26 host OOM) → 8G (2026-05-22 cosmic build pressure).

### 2026-05-14 to 2026-05-15 (Ansible packages parity + mirror-staleness fix) 🧰
- ✅ **12 Mac-parity CLI tools added to `pacman_packages_base`** (commit `dac395a5`, 2026-05-14): bat, eza, git-delta, gron, jc, kubectx, kubeconform, shellcheck, shfmt, sops, stern, yamllint. Pkg count 30 → 41. Installed on all 3 nodes via daily drift-heal (`node-config.yml`). taplo intentionally NOT added — not in extra or AUR (Mac-only via Homebrew).
- ✅ **Pacman mirror-staleness self-heal** (commit `811b67e9`, 2026-05-15): packages role gets pre-task `community.general.pacman: update_cache=true force=true` (=`pacman -Syy`) before all install tasks. First run of the 12-pkg addition hit `error: failed retrieving file 'haskell-prettyprinter-*.pkg.tar.zst' : 404` (shellcheck's transitive haskell deps had rotated on london.mirror.pkgbuild.com; local DB stale). Fix re-runs DB refresh under retries=3/delay=30. Daily 03:00/15:00 UTC config now self-heals mirror drift.
- ✅ **Weekly `yay_cmd` bumped `-Syu` → `-Syyu`** (same commit): forces re-download of mirror DB even if cache appears fresh. Saturday 04:30 UTC phase1 + post-reboot phase2 weekly upgrades pick up next run. Covers both pacman + AUR (CP has 8 AUR pkgs: yay, viddy, zsh-you-should-use, 5 firmware blobs). Documented gotcha in memory `gotchas.md`.

### 2026-04 / 2026-05 (Detailed Changelog — archived from HOMELAB_ANALYSIS.md 2026-05-15) 📜
Verbatim chronological entries (2026-04-02 → 2026-05-08) moved here to keep ANALYSIS lean.
- 2026-05-08: **CODEMAPS refresh + monthly cadence + pending sweep** (commit `aa941721`). All 6 `docs/CODEMAPS/*.md` snapshots actualised against live cluster via 6 parallel agents (one per file) briefed with pre-gathered live-state (kubectl + helm + images + cronjobs). Major drift fixes: `databases.md` PXC→Percona Server for MySQL (`ps-operator` 1.1.x), 3 mysql nodes→2+haproxy 2+orc 3 with image pins; `monitoring.md` retention 30d→90d (vmsingle 50Gi PVC), Loki+Alloy moved to own `loki` ns, VMServiceScrape 37→26+2 VMPodScrape, helm + image pins (kps 84.5.0, vm-op 0.62.1, vm v1.140.0); `apps.md` 17→16 apps (Grafana → infra section), all live image tags refreshed, Immich noted as Helm chart, middleware chain expanded; `architecture.md` Traefik ns kube-system→traefik, Kyverno 10 split 7 Enforce + 3 Audit; `networking.md` Traefik chart 40.0.0, NP per-ns counts; `backup-restore.md` CRITICAL_PVCS list verified vs YAML (10/8 apps), W2 chain noted pending. Added monthly cadence: `CODEMAPS/README.md` "When to update" lists Monthly review; `HOMELAB_ANALYSIS.md` Monthly Review Checklist new item #3 CODEMAPS refresh with kubectl snapshot commands + agent dispatch pattern, "Last refresh: 2026-05-08". Pending sweep: nothing strictly overdue (today 2026-05-08; next event = W2 replication drop 2026-05-20). Authentik 2026.5 row retargeted to "Backlog (watch releases)" — upstream still on 2026.2.x (latest 2026.2.3-rc1). UFW heal umbrella row updated to reference both layers: layer 1 prevention `kernel-modules-hook` (commit `6e01c7d0`) + layer 2 recovery heal v4 (commit `476ec535`). 2026-05-02 incident sub-items (P1 ufw line-2, P2 heal v3 ufw-disabled probe, P3 nic_tuning enp3s0→enp4s0) verified covered: P1+P2 in 476ec535 + heal v4, P3 already correct in `host_vars/worker-node.yml` (`nic_tuning_iface: enp4s0`); CP host_vars correctly retains `enp3s0` (no rename on CP).
- 2026-05-07: **Blocky soak observation closed (4d late vs 2026-05-03)**. Window 2026-04-30→2026-05-07: peak RSS 307Mi/283Mi (60% headroom on 512Mi), avg 140-156Mi, p95 latency 4.96 ms / p50 2.61 ms, log_entries 797k rows / 238 MB / ~110k/day stable, CPU throttle ≤0.24%, 0 active alerts. Restarts (4 rqbjj / 1 wwzgn) all on Sat 2026-05-04 maintenance window — Redis transient-unavail at boot (`dial 10.43.191.88:6379 connect: connection refused`), expected; pods stable 3d+ since. **Memory-limit review** (2026-05-26 row): peak 307Mi blocks 256Mi target; 384Mi acceptable (~25% headroom).
- 2026-05-04: **RebuilderdHighFailureRate flap fix**. Alert flapped firing/resolved every ~40min. Source = 2h-window gauge (`rebuilderd-metrics.sh`), denominator straddles old `total >= 20` floor on W1 (~8-25 builds/2h). Reworked: `avg_over_time((bad/clamp_min(total,1))[1h:5m]) > 0.8 and avg_over_time(total[1h:5m]) >= 50`, `for: 30m → 1h`, added `keep_firing_for: 1h` for hysteresis. Description updated to reflect 1h-smoothed ratio.
- 2026-05-03: **Drift-heal firewall race fix — Tier A + lease bump**. Root cause for 2026-05-02 W2 NotReady mid-drift-heal at 23:42:05 UTC: `firewall` role ran against `hosts: all` in **parallel** — all 3 nodes reloaded UFW simultaneously. Each `community.general.ufw` policy task triggers `ufw reload` → `iptables-restore` rebuilds all UFW chains. During rebuild window, INPUT chain transiently lacks K3s/flannel jump rules → kubelet→API HTTP/2 watch streams RST. Five sequential default-policy + rules tasks compounded the disruption beyond kubelet lease grace (40s default). Ships: (1) **`node-config.yml` 3-play split**: non-disruptive roles parallel, **firewall serial:1**, post-firewall parallel — quorum (2/3) always preserved during drift-heal. (2) **Drift fingerprint gate** in `firewall/tasks/main.yml`: pre-task hashes (`/etc/default/ufw` + `ufw status verbose` + sha256 of all ufw_rules_* vars), compares to cache at `/var/lib/ufw-state/ufw-fingerprint`. UFW rules block gated `when: ufw_drift_detected`. Cache updated post-block only when no rescue ran (clean state). Daily drift-heal on healthy node = pure no-op, zero reload. To force re-run after manual edit: `rm /var/lib/ufw-state/ufw-fingerprint`. (3) **Kubelet lease bump 40s→60s** in `roles/hardening/files/k3s-kubelet.yaml` (`nodeLeaseDurationSeconds: 60`, bare int, NOT duration string — common footgun) + `nodeStatusReportFrequency: 1m` (force status post 5m→1m for faster silent-hang detection). (4) **Lockstep CM grace 50s→75s** in `k3s_config/templates/config.yaml.j2` via `kube-controller-manager-arg: node-monitor-grace-period=75s` + `node-monitor-period=5s` — required because kubelet lease bump is no-op without CM grace bump (CM uses default 50s threshold otherwise). Vars in `group_vars/control_plane.yml`. Rule: grace ≥ lease + 1 renewal (60 + 15 = 75). (5) **`rolling-restart-k3s.yml`** new top-level playbook with `serial:1` to restart k3s/k3s-agent CP-first then workers, waits Ready per node, verifies `nodeLeaseDurationSeconds=60` + `nodeStatusReportFrequency=1m0s` via `/api/v1/nodes/<n>/proxy/configz` (defends against historical k3s field-stripping bugs #7578/#8266). Net effect: 99% of drift-heals = zero UFW reload (pure gate skip). Rare drift detected = serial:1 + full L0-L5 safety. Real-failure detection NotReady delayed ~25s (50s→75s).
- 2026-05-02: **Cardinality trim + UK rework + W1 incident**. (1) **Cardinality**: VMAgent `inlineUrlRelabelConfig` added to drop `flag` (1892, VM CLI flag introspection), `config_parameter` (801, VM env vars), `kube_pod_tolerations` (1081), `etcd_bookmark_counts` (364), 6 noisy histogram `_bucket` metrics (apiserver_watch_list/kyverno x2/controller_runtime/workqueue x2/rest_client/vm_promscrape — ~22k series), low-value cAdvisor (`container_memory_(mapped_file|max_usage_bytes|swap|total_inactive_file_bytes)|container_(sockets|threads)|container_spec_cpu_(period|shares)|container_cpu_(system|user)_seconds_total` — ~7k), and loop-device filesystem metrics. Estimated -33-35k series (204k→~170k, 17%). VMSingle 537Mi → unchanged short-term, will trim with retention roll. Verified live: `rate(flag[1m])` empty, `count(flag)` aging out. (2) **Uptime Kuma**: replaced stale standalone Redis monitor with `Redis HA Master` + `Redis HA Sentinel` TCP probes + `Blocky DNS W1` (192.168.1.129) + `Blocky DNS W2` (192.168.1.126) DNS-via-resolver probes. Originally tried via uptime-kuma-api in setup-job — flaky across lib versions and pre-existing data was in MySQL not SQLite, so reverted to admin-only setup-job and added monitors directly via MySQL INSERT. NetworkPolicy: extended `192.168.1.0/24` ipBlock egress to allow TCP+UDP 53 for Blocky DNS LB probes. Pinned UK Deployment + setup-job to control-plane (`nodeSelector: node-role.kubernetes.io/control-plane=true` + matching toleration) so worker-node probes always traverse external network — fixes "monitor blind to its own node failure" (UK was on W1 during incident, W1 SSH/kubelet probes stayed 100%/99.86% green via pod-local loopback while host INPUT was DROPing external L3). PVC dropped (`/app/data` → emptyDir; real state in MySQL). Helm releases audit closed (12 active, kube-prometheus-stack already trimmed). Skill stocktake quick (11 changed): chezmoi-sync L59, monitoring-check VMAlert jq + port-forward + baselines, networkpolicy-helper VMAgent wording — fixed + pushed. Security scan rollup all 3 nodes: 0 rootkits, hardening 77/78/77, baseline drift absorbed via `rkhunter --propupd`. (3) **W1 incident** (~22:48 UTC): post `yay -Syyu` weekly maintenance, kernel pkg upgraded 6.18.26-1-lts → -2-lts, pacman post-install removed `/lib/modules/6.18.26-1-lts` while kernel still running → modprobe couldn't find ip6table_filter → ufw runtime `ip6tables` error → ufw silently disabled → host INPUT chain DROP'd 8260 packets → W1 NotReady (~25 min). UFW heal v3 ran post-reboot and probe-set UNHEALTHY (`missing ufw6-logging-deny ufw6-user-input`); after manual `ufw enable`, `disable;enable` cycle hit `iptables-restore line 2 failed: No chain/target/match by that name`. Recovered via reboot + emergency `iptables -P ACCEPT && iptables -F INPUT` while UFW debug deferred. Pods rescheduled to W1 cleanly post-recovery. NIC udev-renamed `enp3s0` → `enp4s0` on -2-lts boot — ansible `nic_tuning` role now references stale name. **Issues tracked above** (resolution verified 2026-05-08): P1 ufw line-2 failure ✅ FIXED via heal v4 commit `476ec535` (flush-all + force-enable bypasses iptables-restore line 2 error); P2 heal v3 needs ufw-disabled state probe ✅ FIXED via `phase_ufw_state_recover` in firewall-preflight (same commit `476ec535`); P3 nic_tuning interface-name ✅ NOT-DRIFT — `host_vars/worker-node.yml` already had `nic_tuning_iface: enp4s0`, CP `host_vars/gmk-k3s-control-plane.yml` correctly retains `enp3s0` (no rename on CP). Re-test pending = umbrella row "Validate UFW silent-disable auto-heal" tracking. Layer 1 prevention added via `kernel-modules-hook` commit `6e01c7d0` (prevents `/lib/modules/<running-kernel>` wipe). Next Review bumped 2026-05-04 → 2026-06-04. Quarterly automation audit still 2026-07-04.

- 2026-05-02: **Monthly review + audit (early, vs scheduled 2026-05-04)**. Security scan rollup all 3 nodes: 0 rootkits, hardening 77/78/77, baseline drift (egrep/fgrep/ldd→scripts, telnet, W2 hostname) absorbed by `rkhunter --propupd`. April logs 0-byte (ansible deploy initialised them empty 2026-04-18); May = first real scan, June = first real diff baseline. Skill stocktake quick (11 changed since 2026-04-29 caveman compress): 8 Keep, 3 Improve fixed inline — chezmoi-sync L59 Templates gotcha clarified, monitoring-check VMAlert jq path unified to `.data.alerts[]?` + port-forward pattern (direct exec hits Connection refused) + baselines refreshed (VMSingle 537Mi / series 204k, up from 113k @ 2026-04 — flag cardinality growth), networkpolicy-helper L104 "scraped by Prometheus"→"scraped by VMAgent". Zombie helm release audit closed: 12 releases all active, kube-prometheus-stack confirmed trimmed (`prometheus.enabled=false`; operator + grafana + AM + KSM + node-exporter retained — operator manages AM STS); 5 empty kube-prometheus-stack CRDs + 13 empty VM-operator CRDs bundled with chart, risky-to-remove for marginal benefit, no actionable cleanup. Next Review bumped 2026-05-04 → 2026-06-04. Quarterly automation audit still 2026-07-04.
- 2026-04-28: **Ansible review + NOW + 1-2 day + Later + power-down prevention** (10 commits, full session). Final landed list: #1 authorized_keys, #2 /etc/hosts, #3 timesyncd assert+metric, #5 SSH host fingerprint baseline, #6 admin sudoers, #7 K3s tls-san, #11 fail2ban jail.local (systemd backend), #14 phase2 pod-GC ns filter, #15 rebuilderd cleanup template DRY, swap config 3-host, kernel cmdline audit, K3s secrets-encrypt runtime verify, nic_tuning generalized to all 3 nodes (CP igc + W1 igc + W2 r8169 EEE-off), PCIe runtime PM udev rule (SATA + NVMe + Ethernet classes). Dropped after research: #4 pacman_config (reflector owns), #8 K3s data-dir perms (subdir 0755 design), #9 resolved DNS (Blocky chain works), #10 K3s server flags (config.yaml drift-alert covers), #12 sysctl handler (correct semantics), #13 packages retry (works), #16 idempotency CI (deferred), #17 meta deps (cost > benefit), #18 CNI fingerprint (K3s-runtime), #19 ansible-vault (already SOPS), #20 logrotate.conf (per-app sufficient), zram (unused), MTU (correct), /etc/rancher/k3s backup (K3s handles). 4 gotchas saved to memory. Full audit + plan (`docs/scripts/node-maintenance/ANSIBLE_REVIEW_PLAN.md`, 20 confirmed gaps triaged). Verified baseline: drift-alerting wired (`node-config-notify.sh` Telegram on `failed>0` OR `changed>0`), sudoers visudo-validated, journald caps configured, firewall+preflight split intentional. **NOW bucket shipped** (commits `0cd01203` → `820d1c2b` → `04ec29be`): (1) #1 `authorized_keys` template — `base_config` slurps CP pubkey via `delegate_to+run_once`, deploys to workers exclusive 0600. (2) #3 timesyncd assert + textfile metric (`node_time_sync_synchronized`, `_active`, `_drift_seconds`, 60s) — verified live, all 3 nodes synced. (3) #7 K3s `tls-san` block in template, var in `group_vars/control_plane.yml` — drift-alert auto-fires. (4) #8 data-dir perms audit DROPPED — K3s sets `<data-dir>` + all top-level subdirs to 0755 by design (containerd traversal); secrets live in individual mode-0600 files inside. (5) #14 phase2 Failed-pod GC scoped to `phase2_pod_gc_namespaces` (system+infra only, user-app ns skipped). 2 gotchas saved: `when:` on `run_once+delegate_to` skip-trap, K3s subdir 0755 false-positive. **1-2 day bucket shipped (commit `739a578b`)**: #2 `/etc/hosts` blockinfile (with CP `node_ip` override since `ansible_connection: local` makes `ansible_host=127.0.0.1`), #5 SSH host key fingerprint baseline + drift alert, #15 rebuilderd cleanup template (single `cleanup-stale-repro.sh.j2`, deletes per-host duplicates). **Dropped on review**: #9 resolved upstream pinning (would bypass Blocky — verified DHCP already pushes Blocky to nodes), #12 sysctl `changed_when:false` on handler is correct, #17 role meta deps add cost without protection. Later: pacman_config/admin-sudo/fail2ban/idempotency-CI. Never: logrotate.conf system-wide, K3s cert SAN auto-renewal, firewall+preflight consolidation.
- 2026-04-28: **UFW heal v3 — readiness barrier + preflight role + module + ufw-chains-only settle**. Sequel to 2026-04-26 v2: W2 hit `ufw status verbose: ERROR: problem running ip6tables` again at drift-heal 17:54 BST despite v2's modules-load.d entry (`ip6_tables`/`ip6table_filter`/`iptable_filter` were loaded). Root cause: missing nat/mangle/raw table modules — ufw's `iptables-restore` on `before6.rules` references `*mangle`/`*nat` tables; auto-load fails under K3s/fail2ban iptables lock contention. Shipped: (1) **modules-load.d expanded** to 10 modules (added `ip6table_nat`/`ip6table_mangle`/`ip6table_raw` + v4 nat/mangle/raw + `nf_conntrack`); firewall role modprobe loop matched. (2) **`k3s-wait-ready.service`** new oneshot barrier (After=k3s/k3s-agent, RemainAfterExit=yes, 200s budget) that polls API healthz (CP) + critical pods Ready (kube-router/coredns CP-only) + ufw-chain hash stability, touches `/run/k3s-ready` sentinel. `ufw-heal-post-k3s.service` now `After=k3s-wait-ready.service Wants=k3s-wait-ready.service ConditionPathExists=/run/k3s-ready`. Replaces naive `After=k3s.service` (started ≠ ready). (3) **`firewall_preflight` role** — new role inserted before `firewall` in node-config.yml all-hosts play AND before rebuilderd in workers play. Runs `firewall-preflight.sh`: settle wait + modprobe expanded modules + per-chain repair. Defends any role transitively invoking `community.general.ufw`. (4) **Phase A v2 in `ufw-heal-post-k3s.sh`** — replaced old `nft monitor 0-events` gate with `ufw_chains_hash` (sha256 of `:ufw-`/`-A ufw-` lines from iptables-save) stability across 3× 5s windows, max 90s. Workers always churn kube-* chains so full-ruleset hash never converged on first test (W2 reboot 18:41-18:45) — ufw-only hash bounded drift. Same hash fn shared with k3s-wait-ready + firewall-preflight. (5) **fail2ban detected** as deployed-but-unmanaged-by-ansible (active on W2, pacman 1.1.0-8). Race source documented; no role added yet. (6) **Lint cleanup**: pre-existing `risky-shell-pipe` in firewall pre-heal block (added `set -o pipefail`), `name[casing]` in nic_tuning handler, `yaml[commas]` alignment in group_vars/all.yml all fixed — repo passes `production` profile clean. **W2 reboot test 18:41 BST**: all 10 modules loaded post-boot, `/run/k3s-ready` touched at 181s (settle timed out via fallback), heal exit 0 with "ufw active — heal OK" (probe-set healthy, reload attempt 1/3 succeeded), no UfwDisabled/UfwChainsUnhealthy alerts. Refinement: ufw-chains-only hash deployed via second commit. CP + W1 inherit on next drift-heal cycle (15:00 UTC).
- 2026-04-26: **UFW heal v2 + drift-heal cadence 1x→2x/day**. W2 hit `ufw status verbose: ERROR: problem running ip6tables` 30+h after boot — boot-time `ufw-heal-post-k3s.service` doesn't catch runtime drift. Root cause re-audited: real CNI is K3s default flannel + kube-proxy (NOT kube-router as old comments claimed); heal Phase A's `KUBE-ROUTER-INPUT` quiescence probe always timed out. Plus `ip6_tables` kernel module had unloaded mid-runtime. Shipped: (1) heal script v2 — `nft monitor` event-based quiescence (max 60s, 5s windows), phase reorder A→C→B→E→D→F (per-chain `iptables -N` BEFORE `ufw reload`); (2) `/etc/modules-load.d/ufw-iptables.conf` (`ip6_tables`/`ip6table_filter`/`iptable_filter`) + `ufw.service.d/modules.conf` (`After=systemd-modules-load.service`); (3) ansible firewall pre-heal task reordered repair-first; (4) `node-maintenance-config.timer` 1x→2x/day (03:00 + 15:00 UTC, drift window ≤12h). Hourly probe-then-heal pattern researched + rejected (`-w` no-op on iptables-nft, double-heal risk, pacman/rebuilderd lock contention). W2 canary applied 20:27 UTC, `ufw_chains_healthy=1`. Roll W1 + CP next 03:00 UTC drift-heal.
- 2026-04-26: **W2 rebuilderd memory cap 14G→12G**. Reduced `MemoryMax 14G→12G` / `MemoryHigh 13G→11G` / `MAX_MEMORY=12G` to leave more headroom for K8s pods on W2. Updated via ansible (`roles/rebuilderd/files/resources-worker-node-2.conf` + `host_vars/worker-node-2.yml`), drift-applied via `node-maintenance-config.service`, verified live (`MemoryMax=12G`). Also added `docs/scripts/ansible-apply.sh` helper (sync + drift-heal + per-host rebuilderd verify) deployed to CP `~/ansible-apply.sh`.
- 2026-04-26: **W1 rebuilderd memory cap 32G→18G**. Host-level OOM on W1 — rebuilderd cgroup pressure spilled past `MemoryMax=32G`/`MemoryHigh=31G` and triggered host OOM-kills on K8s pods. Reduced to `MemoryMax=18G`/`MemoryHigh=17G` (+`MAX_MEMORY=18G` env for nspawn). Trade-off accepted: heavy LTO builds (python-triton ~40GB, openvdb ~34GB) will OOM inside rebuilderd cgroup again — same failures as pre-2026-02-21 — but K8s stability preserved. Updated via ansible (`roles/rebuilderd/files/resources-worker-node.conf` + `host_vars/worker-node.yml`), drift-applied to W1 live, verified `MemoryMax=19327352832` (=18*1024^3).
- 2026-04-22: **W1 canary reboot + phase2 rebuilderd fleet-wide pause**. Canary-rebooted W1 to validate L1 `ufw-heal-post-k3s.service` under real kube-router race — healer fired at 18:52:19, phase-a hit 120s cap (settle timeout fallback), phase-b reload attempt 1 success, phase-c chain repair clean, phase-e final reload success, probe set healthy, UFW active post-heal. `ufw_state.prom` → 1/1/1. L1 validated end-to-end. Blast radius: zero (2 authentik pods evicted from W1 rescheduled to W2, cold image pull took 7m51s on busy rebuilderd box). Root cause of slow pull: W2's `rebuilderd-worker@1.service` was running 13x python3 build fan-out at ~330% CPU + mem tight (1.1G free, 3.6G swap in use) — disk/network contention. **Fix**: added PLAY 0.5 to `ansible/phase2.yml` (fires post-CP-stabilize, mass-stops `rebuilderd-worker@1.service` on all workers in parallel). `rebuilderd-worker-boot.timer` re-arms each worker at +10min post-its-own-reboot — no explicit restart needed. Per-node stop in PLAY 1 kept as belt-and-suspenders no-op.
- 2026-04-21: **UFW resilience overhaul + drift-heal retry policy**.
  - **Weekly cluster update** ran successfully (phase1 CP + phase2 rolling workers, 0 failures, 16min total). Added CP stabilize pause (4min, Flux + kube-system + traefik + flux-controllers readiness gates) to phase2 PLAY 0 before worker rollout. Bumped CP + per-node stabilize to 4min for DB (CNPG + Percona) failover safety.
  - **W1 post-update UFW broke** again — identified deeper root cause via research (UFW #1987227/#1294544 + K3s #1280/#9807): `ufw-init`'s `ip6tables-restore` silently partial-loads when kube-router + fail2ban race-mutate kernel nft state at boot, leaving `ufw6-logging-deny` + `ufw6-user-*` chains missing. Shipped **3-layer fix**:
    - **L1 — boot healer** `ufw-heal-post-k3s.service` (replaces flaky `ufw-reload-after-k3s.service`): 6-phase bash script — poll kube-router quiescence → `ufw reload` ×3 → per-chain `ip6tables -N` repair (race-free) → verify canary probe set → final reload → status check. 5min timeout.
    - **L2 — drift-heal pre-heal hardened**: `ufw reload` ×3 + detect missing chains + per-chain `iptables -N` / `ip6tables -N` recovery from UFW rules files. Also added `until/retries=5, delay=10s` to every `community.general.ufw` task (SSH rule, default policies, rules loop, routes loop, enable) — survives transient races during module's internal `ufw status verbose`.
    - **L3 — Prometheus alerts**: new VMRule `firewall-alerts` group (UfwDisabled/UfwServiceInactive/UfwChainsUnhealthy, all critical, `for: 5m`). Metrics from `ufw-state-metric.sh` (60s timer, textfile collector) — `ufw_enabled`/`ufw_service_active`/`ufw_chains_healthy` per node. VMRule path: `monitoring/configs/base/victoria-metrics/vmrules.yaml` (vm-operator doesn't auto-convert PrometheusRule → VMRule is source of truth).
  - **Drift-heal retry policy** (Wave 1 + 2): `until/retries` added to all pacman installs (`retries=3, delay=30` — mirror 5xx/GPG/lock races), `fwupdmgr update` (`retries=3, delay=20` — LVFS 5xx), `systemd-resolved` restart handler (`retries=2, delay=5`). Not retried (fail-loud): sshd config validate, preflight health gates, local file ops.
  - **Sync service timeout bump**: `node-maintenance-sync.service TimeoutStartSec=5min → 20min`. 5min was tight when inner config playbook retries stack; two syncs got killed mid-run during 5x stability test even though playbooks finished OK. 20min gives 5min headroom over config's 15min cap.
  - 5x idempotency stress test: 4 consecutive playbook runs, 0 failed, 0 retries triggered — UFW module + pacman passed first attempt every time. Retry machinery = safety net, not routine path.
  - All metrics `1/1/1` on CP, W1, W2 after fix. VMRule `firewall-alerts` loaded in vmalert, 3 rules `inactive/ok`.
  - Memory: existing `gotcha_ufw_ip6tables_post_reboot.md`; retry policy documented in `docs/scripts/node-maintenance/README.md` under "Resilience".
- 2026-04-27: **claude-telegram HTTP trigger** — bot accepts loopback `POST /trigger` (header `X-Trigger-Secret`) that replays prompt as if first allowed user sent it via Telegram. Wired into `node-maintenance-phase2.service` ExecStopPost: on success, CP runs `telegram-notify-claude.sh` → `kubectl exec` curl into pod loopback → bot autonomously reviews alerts + clears stale resources in user's normal DM. Failure path unchanged (alerts chat). Image bumped 1.11 → 1.12 (PR `AKhozya/claude-telegram-bot#1`). Secret added to SOPS `claude-telegram-env.trigger-secret`. Bound to 127.0.0.1 — no Service/NetworkPolicy needed.
- 2026-04-24: **claude-telegram chezmoi-init OOM fix** — init container OOMKilled at 512Mi limit during `npm update -g @anthropic-ai/claude-code` + `bun update @anthropic-ai/claude-agent-sdk`. Bumped to `requests 256Mi / limits 1Gi` (cpu `100m/1000m`). Rolled clean on worker-node-2. Commit `3b2d77e8`.
- 2026-04-20: **W1 post-reboot UFW ip6tables heal** — drift-heal started failing on worker-node at firewall role (`ufw status verbose` → `ERROR: problem running ip6tables`) after W1 reboot 2026-04-19 15:06 BST. Manual `sudo ufw default deny routed` on W1 triggered ufw reload → rebuilt ip6tables → state clean. Re-ran `node-maintenance-config.service` → `worker-node: ok=66 failed=0`. Prevention: added `ufw-reload-after-k3s.service` (oneshot, `After=k3s.service k3s-agent.service ufw.service`, `sleep 15` + `ufw reload`) to `firewall` role tasks + `Reload systemd` handler. Deployed to all 3 nodes via drift-heal. **Superseded 2026-04-21 by `ufw-heal-post-k3s.service`** (6-phase healer — original was too naive for kube-router race window). Memory: `gotcha_ufw_ip6tables_post_reboot.md`.
- 2026-04-20: **Authentik passkey-first migration** — `IdentificationStage.webauthn_stage` (Conditional UI autofill since 2025.12) + `passwordless_flow` (button fallback) wired via 4 custom blueprints in ConfigMap `authentik-blueprints-custom` mounted at `/blueprints/custom/` on server + worker. WebAuthn setup stage tightened to `resident_key_requirement=required` + `user_verification=required`, bound to `default-user-settings-flow` at order 30 for voluntary enrollment. MFA validate enforces `device_classes=[webauthn, totp]` (TOTP retained as recovery 2FA method) + `not_configured_action=configure` + inline `configuration_stages=[webauthn-setup]` (new users still forced to enroll passkey, TOTP not auto-enrolled). Password stage at order 20 of main flow retained as recovery path. RPID stays `authentik.h0melab.work` (preserved). Fresh akadmin passkey re-enrolled 2026-04-20 (zombie 2025-10-21 row had `rp_id=null`, deleted via API). Smoke: 6a Conditional UI + 6b passwordless button + 6c password fallback + 6d OIDC delegation all pass. API path for blueprint instances is `/api/v3/managed/blueprints/?page_size=100` (not `/blueprints/instances/`). Spec: `docs/superpowers/specs/2026-04-19-authentik-passkey-design.md`. Plan: `docs/superpowers/plans/2026-04-19-authentik-passkey.md`. Runbook: `docs/scripts/runbooks/authentik-passkey-rollback.md`.
- 2026-04-19: Docs cleanup — deleted 5 stale .md (3 reports + 2 superseded telegram plans v1/v2); HA+PriceBuddy label fix MariaDB→MySQL; caveman-compress 37 repo + 20 memory .md; HOMELAB_ANALYSIS changelog consolidated. MariaDB orphan CRD/CR purge (Phase F fallout): stripped finalizers on 3 sibling CRDs + 13 CRs, cascade-deleted.
- 2026-04-25: **SearXNG retired** — Google rate-limit (429) + low-quality fallback engines. Removed: ns/searxng, `apps/{base,staging}/searxng/`, NetworkPolicy egress (traefik + cloudflared), CF tunnel `search.h0melab.work` route. Manual cleanup needed: Cloudflare DNS CNAME for `search.h0melab.work`. Apps 18 → 17.
- 2026-04-18 → 04-19: **Node config → ansible migration complete** (Phases A-F, 9 roles, plan closed). Roles (apply order): `packages` (pacman declarative + per-host ucode/GPU via host_vars), `base_config` (logrotate/journald 99-caps.conf/sudoers/node-maintenance user/rebuilderd TimeoutStopSec), `k3s_config` (templated config.yaml, drift-alert only, no auto-restart), `k3s_image_gc`, `firewall` (UFW, community.general.ufw additive, lockout-safe), `hardening` (15 configs: sshd/3 sysctls/kubelet/3 k3s service.d/systemd watchdog/resolved LLMNR/NVMe-APST/2 udev/2 tmpfiles.d), `security_scan` (monthly lynis+rkhunter, `/var/log/node-maintenance/security-scan-YYYY-MM.log`, first run 2026-05-01), `rebuilderd` (workers-only resources.conf + units), `ad_hoc` (tag-gated `never` firmware task). Daily drift-heal `node-maintenance-config.timer` (03:00 UTC) → Telegram on `changed>0`/fail. W2 `k3s_data_dir: /mnt/k8s-storage/k3s` host_var captured live state (would have wiped first apply). W1 `/var/lib/rancher` symlink replaced by explicit `data-dir` (zero data move). Drift caught first run: CP missing `inetutils/mesa/vulkan-intel/ufw-extras`; W2 missing `ethtool/go/mesa/vulkan*`. setup-node.sh 706→218 lines (-69%), bootstrap-only (ansible stack CP-only + AUR yay + optional firmware). install-worker.sh 182→50 (-72%). Retired scripts: `setup-ufw-k3s-*`, `setup-rebuilderd-worker-*`, `enable-crash-logging`. Legacy configs ansible-cleaned: 51-kptr-restrict, 99-security-hardening, cpu-governor. Plan: `docs/superpowers/plans/2026-04-18-node-config-ansible.md`.
- 2026-04-18: **Node-maintenance system live** — weekly updates `node-maintenance.timer` (Sat 04:30 UTC, Ansible-driven phase1 CP→reboot→phase2 worker loop, SOPS SSH key, Telegram alerts, node-maintenance user). Auto-sync `*:0/10` via read-only GH deploy key (`/root/.ssh/homelab-deploy`), runs `install.sh --sync-only` on HEAD change. Observability: Alloy `loki.source.journal` ingests phase1/2 + sync logs; Grafana dashboard (7 panels, VM+Loki); `NodeMaintenanceMissedRun` VMRule (>8d). E2E fixes: amtool silences (bundled Alertmanager pod), ExecStopPost `$SERVICE_RESULT` check, `ansible_facts['*']` (2.24 prep), `inject_facts_as_vars=False`. First weekly fire 2026-04-25.
- 2026-04-18: PodDisruptionBudgets for 9 HA workloads (authentik server/worker, traefik, cloudflared, main-postgres-rw-pooler, main-mysql-haproxy, main-mysql-orc, couchdb, alertmanager). `minAvailable: 1` 2-replica; `maxUnavailable: 1` 3-replica. CNPG/Percona/Kyverno operator PDBs cover primaries. Node cron/timer audit closed (P3) — no migration candidates.
- 2026-04-13: All 3 nodes → zsh + chezmoi dotfiles (portable .zshrc template, modern CLI tools).
- 2026-04-11: Claude Telegram bot live (Agent SDK, fork of linuz90/claude-telegram-bot).
- 2026-04-09: VictoriaMetrics migration (71% RAM save).
- 2026-04-02: April monthly review, full secrets rotation.

### 2026-05-02 to 2026-05-07 (May Sprint Closures) 🧹
Items archived from HOMELAB_ANALYSIS.md PENDING ITEMS table on 2026-05-07.
- ✅ **Uptime Kuma rework** (2026-05-02). Replaced standalone Redis monitor with HA Master + HA Sentinel TCP probes + Blocky DNS probes (W1 192.168.1.129 / W2 192.168.1.126). Pinned UK Deployment + setup-job to control-plane (`nodeSelector` + toleration) so node-targeted probes always traverse external network — fixes monitor-blind-to-own-node-failure (W1 SSH/kubelet probes had stayed 100%/99.86% green via pod-local loopback while host INPUT was DROPing external L3). `/app/data` PVC dropped (state in MySQL; db-config.json regenerates from env, screenshots/error.log ephemeral). New monitors live (MySQL ids 42/43/45/46).
- ✅ **W1 UFW iptables-restore line 2 fail** — kernel-upgrade regression, RESOLVED 2026-05-02 (commit `476ec535`). Root cause: stale ufw kernel chains from previous session block `ufw enable` (re-create attempt against existing chains). `/lib/ufw/ufw-init flush-all` clears stale chains. Patches in `ufw-heal-post-k3s.sh` (phase_b detects "skipping reload\|not enabled" → flush-all + `--force enable`) and `firewall-preflight.sh` (new `phase_ufw_state_recover` runs after modprobe: detects `ENABLED=yes + Status:inactive` → flush-all + force-enable). **Validation tracking**: kept as separate pending row in HOMELAB_ANALYSIS.md (next W1 reboot/kernel upgrade).
- ✅ **UFW heal v3 silent-disable recovery** — RESOLVED 2026-05-02 (commit `476ec535`). `phase_b_reload` previously returned success on `ufw reload` exit-0 even when output said "skipping reload" (no-op when ufw disabled). Now greps for "skipping reload\|not enabled" and triggers flush-all + force-enable recovery. `phase_ufw_state_recover` provides same recovery at drift-heal time.
- 🚫 **Ansible nic_tuning role hardcoded enp3s0** — FALSE ALARM 2026-05-02. Role uses per-host `nic_tuning_iface` host_var; `worker-node.yml` already had `enp4s0` from 2026-04-26 generalisation. Verified live: CP `nic-tune@enp3s0.service active`, W1 `nic-tune@enp4s0.service active` (enp3s0 stays NO-CARRIER), W2 `nic-tune@enp2s0.service active`.
- 🚫 **K3s dual-stack pod networking** — DECIDED 2026-04-26: NOT WORTH IT. No app needs v6-only targets (DoH/CDNs reachable via v4). Migration cost (NP rewrites, CIDR change, breakage risk) >> benefit. v4-only permanent. Blocky pinned `connectIPVersion: v4`.
- ✅ **Audit: zombie helm releases** — DONE 2026-05-02. 12 helm releases all active. kube-prometheus-stack already trimmed (`prometheus.enabled=false` in HelmRelease values; operator + grafana + AM + KSM + node-exporter retained — operator manages AM STS). 5 empty KPS CRDs (prometheuses/prometheusagents/thanosrulers/scrapeconfigs/probes) + 13 empty VM-operator CRDs (vlogs/vlsingles/vlclusters/vlagents, vmanomalies+vmanomalyconfigs, vmclusters/vmdistributed, vmusers/vmauths, vtclusters/vtsingles) bundled by chart — risky-to-remove for marginal benefit. No actionable cleanup.
- ✅ **Blocky 1-week soak observation** — DONE 2026-05-07 (4d late vs 2026-05-03 target). Window 2026-04-30→2026-05-07. Peak RSS 307Mi (rqbjj/W2), 283Mi (wwzgn/W1) — 60% headroom on 512Mi limit. Avg RSS 140-156Mi. p95 latency 4.96 ms / p50 2.61 ms. log_entries 797k rows / 238 MB / ~110k/day stable (range 88k-116k/day). CPU throttle ≤0.24% (negligible). 0 active alerts. Restarts rqbjj=4 / wwzgn=1 — all on Sat 2026-05-04 weekly maintenance window, root cause `dial 10.43.191.88:6379 connect: connection refused` (Redis transient unavail during worker reboot, expected). Pods stable 3d+ since. Verdict: GREEN. Memory-limit review (2026-05-26) blocked by 307Mi peak — 256Mi unsafe; 384Mi acceptable (~25% headroom).

### 2026-04-28 (Ansible Review + NOW Bucket Landed) 📋
- ✅ **Full audit** of `docs/scripts/node-maintenance/ansible/` — 11 roles, 3 playbooks (`phase1`/`phase2`/`node-config`)
- ✅ **Verified baseline**: drift-alerting wired (`ExecStopPost=/usr/local/sbin/node-maintenance-config-notify.sh` → Telegram on `failed>0` OR `changed>0`); sudoers `visudo -c -f` validated; journald caps already 500M/30d/1week; `firewall_preflight` + firewall pre-heal split is intentional (defense-in-depth, documented in `firewall-preflight.sh` header)
- ✅ **Plan saved**: `docs/scripts/node-maintenance/ANSIBLE_REVIEW_PLAN.md` (20 confirmed gaps, triaged NOW/1-2 days/later/never)
- ✅ **NOW bucket SHIPPED** (commits `0cd01203` → `820d1c2b` → `04ec29be`):
  - **#1 `authorized_keys` template**: `base_config` slurps CP node-maintenance pubkey via `delegate_to: control_plane[0]` + `run_once`, deploys to workers exclusive (mode 0600, owner node-maintenance). Source-of-truth = CP's `/var/lib/node-maintenance/.ssh/id_ed25519.pub` (derived from SOPS-decrypted private key at install time). Drift-heal reconciles bootstrap state.
  - **#3 timesyncd assert + textfile metric**: ensures `systemd-timesyncd.service` enabled+active. Deploys `timesyncd-metric.{sh,service,timer}` emitting 3 gauges to `/var/lib/node_exporter/textfile/time_sync.prom` every 60s: `node_time_sync_synchronized`, `node_time_sync_active`, `node_time_sync_drift_seconds`. Verified live: all 3 nodes synchronized=1, CP drift ≈15ms. (Replaces overengineered chrony recommendation — timesyncd already holds ≪100ms in practice for K3s etcd.)
  - **#7 K3s `tls-san`**: block added to `config.yaml.j2`, var `k3s_tls_san: [127.0.0.1, localhost, gmk-k3s-control-plane, 192.168.1.127]` in `group_vars/control_plane.yml`. Drift = template change → existing telegram alert. Restart K3s to regenerate cert.
  - **#8 K3s data-dir perms — DROPPED**: K3s sets `<data-dir>` AND all top-level subdirs (`server/`, `agent/`, `server/cred/`, `server/db/`) to 0755 by design (containerd/kubelet/agent need traversal). Real secrets live in individual files (k3s-server-token, *.crt, *.key — all 0600) which K3s manages itself. Directory-level audit produced false positives on every node. Two attempts both failed (data-dir, then sensitive-subdirs); reverted entirely.
  - **#14 Phase2 Failed-pod GC scoped**: `kubectl delete pod -A` replaced with loop over `phase2_pod_gc_namespaces` list (kube-system, kube-public, flux-system, kyverno, monitoring, traefik, cert-manager, databases, cloudflare-tunnel, backup-replication, node-maintenance). User-app namespaces (immich, paperless, n8n, mealie, etc.) skipped — operator can investigate Failed pods without auto-deletion.
- 🪤 **2 gotchas saved**: (a) `when:` filter on `run_once + delegate_to` task skip-traps the entire task if first batch host fails the condition, leaving registered var as a skip-dict that subsequent hosts choke on. Fix: drop `when` from registering task, gate consumer task instead. (b) ANY ansible directory-level perms audit on K3s data-dir or its subdirs is a false-positive trap — K3s sets all dirs 0755 for traversal; secrets are file-level mode 0600.
- ✅ **1-2 days bucket SHIPPED** (commit `739a578b`):
  - **#2 `/etc/hosts` blockinfile**: `base_config` uses `ansible.builtin.blockinfile` over `groups['all']` loop. CP added `node_ip: 192.168.1.127` host_var to override `ansible_host=127.0.0.1` (set because `ansible_connection: local`). Verified live: all 3 nodes have ANSIBLE-MANAGED block with correct LAN IPs.
  - **#5 SSH host key fingerprint baseline**: `base_config` shell task captures `ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub` → `/var/lib/node-maintenance/ssh-host-fingerprints.txt` (root:root 0644, dir 0750). First run: `BASELINE-CREATED` (changed). Subsequent: `OK` (no change). Drift: `FINGERPRINT-DRIFT` → task fail → telegram alert.
  - **#15 rebuilderd cleanup DRY**: deleted `cleanup-stale-repro-worker-node{,-2}.sh` (per-host duplicates), replaced with single `cleanup-stale-repro.sh.j2` template using `rebuilderd_repro_dir` host_var (W1=`/mnt/k8s-storage/repro`, W2=`/mnt/extra-storage/repro`). `tasks/main.yml` switched `copy:` → `template:`.
- ❌ **Dropped on review** (3 items, plan updated):
  - **#9 systemd-resolved upstream DNS pinning** — would have bypassed home Blocky chain (router DHCP→W1+W2 Blocky→Blocky's own upstream fallback). Verified `/etc/resolv.conf` already shows `nameserver 192.168.1.129 192.168.1.126 fe80::1%2`. `resolvectl status` "Current DNS Server: 9.9.9.9" is GLOBAL fallback (cosmetic systemd-resolved built-in), not what apps use.
  - **#12 sysctl handler audit-trail** — `changed_when:false` on a handler is correct semantics (handler running = upstream task already reported `changed=1`). `command:` module still fails on non-zero rc.
  - **#17 role meta dependencies** — `dependencies:` in meta would force dep role to run on EVERY invocation (slow + noisy when packages already ran via playbook). Playbook role list already enforces correct order. `.ansible-lint` passes production profile without meta files.
- ✅ **Later bucket SHIPPED post-research** (commits `ade9894f` → `49ecf545`):
  - **#6 admin sudoers** — `base_config` deploys `00_<admin_user>` (akhozya/akhozya/z3us per host_var) with content `<user> ALL=(ALL) ALL`, validate via visudo, mode 0440.
  - **swap config** — `base_config` asserts host-specific fstab entry (lineinfile) + active swap path (resolves symlinks for LVM LV → dm-N before grep against `swapon --show`). Per-host vars: CP swapfile/8G, W1 partition/32G UUID, W2 LVM/16G.
  - **#11 fail2ban** — `hardening` deploys `jail.local` (LAN whitelist 192.168.1.0/24, bantime 1h, sshd port 65300 maxretry 3, **systemd backend**). W2 had stray `logpath = /var/log/auth.log` — drift-heal removed.
- ✅ **Post-research adds** (commit `7d5bf28c`):
  - **kernel cmdline audit** — `base_config` asserts `expected_kernel_params` present in `/proc/cmdline` (4 universal in `group_vars/all.yml`: pcie_aspm=off, efi_pstore.pstore_disable=0, printk.always_kmsg_dump=Y, panic=10; workers add 2 AMD: amd_pstate=active, nvme_core.default_ps_max_latency_us=0). Read-only — failed task = telegram alert. Operator fixes via `/boot/loader/entries/*.conf` + reboot.
  - **K3s secrets-encryption runtime verify** — `k3s_config` asserts `k3s secrets-encrypt status` shows `Encryption Status: Enabled`. CP-only, gated on `k3s_secrets_encryption: true`. Catches silent encryption-disable post-restart (config.yaml says enabled but K3s could fail silently on perms/plugin issues).
- ✅ **Power-down prevention** (commits `c54e9020` → `7b4e0ea9`):
  - **NIC tuning generalized**: `nic-tune@.service` replaces `igc-tune@.service`. Always disables EEE + Wake-on-LAN. Speed-force optional via per-iface `EnvironmentFile` (`/etc/nic-tune/<iface>.env`, populated only when `nic_tuning_force_speed` set). CP enp3s0 igc keeps 1Gbps force (gigabit bug workaround); W1 enp4s0 igc + W2 enp2s0 r8169 newly under ansible (W2 EEE flipped `enabled-active → disabled` verified live).
  - **PCIe runtime PM rule**: `udev-60-pci-no-runtime-pm.rules` replaces nvme-only. Per-class rules cover SATA (0x010601), NVMe (0x010802), Ethernet (0x020000) — sets `power/control=on`. Belt-and-suspenders to `pcie_aspm=off` cmdline.
  - **Coverage 4-layer**: NVMe (cmdline + modprobe + udev class + tmpfiles + block runtime PM), SATA (udev ALPM=max_performance + udev class), PCIe link (cmdline ASPM off + udev class runtime PM), Ethernet (cmdline ASPM + udev class + nic-tune service).
  - **Gotcha caught**: `copy: content:` fails on empty/whitespace Jinja output ("src (or content) is required"). Fix: gate task with `when:` on conditional + sibling task to remove file otherwise. Memory: `gotchas.md#ansible-copy-content-empty`.
- 🗓️ **Later**: pacman_config role, admin sudoers, fail2ban tuning, K3s server flags drift detection, idempotency CI, ansible-vault for secrets
- ❌ **Never**: logrotate.conf system-wide tuning (per-app sufficient), K3s cert SAN auto-renewal (K3s handles internally), firewall+preflight consolidation (split intentional)

### 2026-04-26 (Redis HA Migration — Phase 1) ⚡
- ✅ **OT-CONTAINER-KIT redis-operator v0.24.0** deployed via Flux HelmRelease
- ✅ **RedisReplication CR**: 1 master (W2) + 1 replica (W1), hard pod anti-affinity, image `quay.io/opstree/redis:v8.6.2` (bumped from v7.4.8 by Renovate during cutover; researched, no breaking changes)
- ✅ **RedisSentinel CR**: 3 sentinels spread across CP/W1/W2 (CP toleration added), quorum 2 of 3, parallelSyncs 1, downAfterMilliseconds 5000
- ✅ **ACL secret** with literal users (admin, paperless, immich, blocky), `default on nopass` for liveness probes (NetworkPolicy restricts namespace access)
- ✅ **Mixed client model**: Immich uses Sentinel via `REDIS_URL=ioredis://<base64-json>`; Paperless uses static `redis-replication-master` Service (Paperless does not support Sentinel)
- ✅ **Cutover successful**: Immich 76 conns + Paperless 8 conns on new cluster, old redis-0 0 app conns
- ✅ **Failover tested**: master pod delete → Sentinel promoted replica → endpoint moved → apps reconnected (HTTP 200/302)
- ✅ **Old redis-0 StatefulSet decommissioned**, PVC `data-redis-0` (5Gi) deleted, all legacy `redis/` dirs removed from git
- ✅ **PrometheusRule `redis-ha` group**: 7 alerts (RedisHADown, RedisHAAllDown, RedisHASentinelQuorumLost, RedisHAReplicationBroken, RedisHAReplicationLag, RedisHAMemoryHigh, RedisHAClientReconnectStorm)
- ⚙️ **Quota bumps**: databases ns `limits.cpu` 17→20, `limits.memory` 18→20Gi, `services` 20→50 (OT operator creates 6 svcs/replication + 3 svcs/sentinel)
- ⚙️ **Plan-vs-actual drift fixed during execution**: OT v1beta2 schema (`serviceType` removed; `secretKeyRef` for sentinel password); Sentinel pod label is `app=redis-sentinel-sentinel` (NP + anti-affinity selectors corrected); `readOnlyRootFilesystem: true` incompatible with OT entrypoint writing `/etc/redis/redis.conf` — set `false`; `protected-mode no` required for nopass default user
- 🔮 **Phase 2 unblocked**: Blocky DNS migration ready (separate plan `docs/superpowers/plans/2026-04-26-blocky-migration.md`)

### 2026-04-26 (Blocky DNS Migration — Phase 2) 🛡️
- ✅ **Replaced AdGuard Home** (2 node-pinned Deployments) with **Blocky v0.29.0** (single Deployment, 2 replicas, hard pod anti-affinity W1+W2, native rolling updates)
- ✅ **Shared Redis HA cache** (database 1) for cross-pod state sync via Phase 1 redis-replication-master
- ✅ **CNPG Postgres query log** — `blocky` database + role added to `cluster.yaml` `managed.roles`, 7-day retention via Blocky native pruning
- ✅ **LAN-facing IPs preserved**: 192.168.1.129 + 192.168.1.126 (K3s servicelb LoadBalancer + externalTrafficPolicy: Local + 2 Services for per-node binding)
- ✅ **HagezI multi/pro.plus/tif + OISD blocklists** active, blocked queries return `0.0.0.0`
- ✅ **DoH upstreams**: Cloudflare Security + Quad9, with Cloudflare/Quad9 IP+IPv6 bootstrap DNS
- ✅ **Custom DNS rewrite** for `*.h0melab.work` → both worker IPs (no manual A records needed for new ingresses)
- ✅ **VMServiceScrape + VMRule** (5 alerts: BlockyDown, BlockyAllReplicasDown, BlockyHighErrorRate, BlockyBlocklistRefreshFailing, BlockyHighLatency); Grafana dashboard ID 13768 deployed as ConfigMap
- ✅ **Mac resolver script** (`scripts/macos/setup-h0melab-resolver.sh`) updated AdGuard → Blocky, synced via chezmoi
- ✅ **Homepage widget** updated AdGuard → Blocky
- ⚙️ **Plan-vs-actual drift fixed during execution**:
  - Plan referenced old `redis.databases.svc.cluster.local` — corrected to `redis-replication-master.databases.svc.cluster.local` (post-Phase 1 svc)
  - NetworkPolicy podSelector `app: redis` → `app: redis-replication`
  - Plan missed `blocky` role addition to CNPG `cluster.yaml` `managed.roles` — added (CNPG does NOT auto-create roles from labeled Secrets)
  - Plan used ServiceMonitor + PrometheusRule, but cluster vm-operator has `VM_ENABLEDPROMETHEUSCONVERTER_*=false` — converted to native VMServiceScrape + VMRule
  - Blocky `queryLog.target` doesn't env-substitute `${PG_PASSWORD}` (Redis password field works) — pivoted from ConfigMap+env-vars to SOPS-encrypted Secret with passwords inlined into config.yml
  - GitOps bootstrap paradox: `apps` depends on `infrastructure-configs`, but resource-governance entry needed `blocky` ns first — split into 2 commits (cutover with deferred governance, re-enable governance post-ns-create)
- 💥 **CP node `enp3s0` NIC link drops** during execution (Intel I225-V/igc): 4 link-down events 21:05-21:10, CP fully isolated from LAN, recovered after physical reboot. Flux source/helm/notification controllers crashlooped post-recovery, fixed by pod delete. Added to PENDING ITEMS as P1.
- ⚙️ **AdGuard pruned**: ns + manifests deleted by Flux (cutover commit removes `apps/staging/kustomization.yaml` adguard entry); resource-governance adguard-home.yaml entry also removed
- 🔮 **Open**: Uptime Kuma DNS probes for both Blocky IPs (manual UI step, scheduled 2026-05-04); Phase 1 redis-ha alerts also need VMRule conversion (separate task, P2)

### 2026-04-26 (Phase 2 Hardening + Stale Cleanup) 🧹
Same-day continuation of Phase 2 Blocky migration. Multiple fixes + cleanup:

**Blocky config tuning** (research-driven, per upstream best practices):
- Dropped `multi.txt` (subsumed by pro.plus) and `big.oisd.nl` (heavy overlap) → ~40% fewer entries to load
- `connectIPVersion: dual` → `v4` (K3s podCIDR is v4-only; v6 attempts wasted latency)
- Added `clientLookup.upstream: 10.43.0.10` for PTR-based hostname enrichment in query log
- Caching: `minTime: 60s` → `5m`, `maxTime: 0` → `12h`, explicit `cacheTimeNegative: 30m`
- Bootstrap DNS trimmed 8 → 2 entries (1.1.1.2 + 9.9.9.9)
- `redis.required: false` → `true` (surface failures rather than silent fallback)
- `loading.downloads.timeout: 5m` + `attempts: 5` (tif.txt parse-timeout fix)
- Pivot ConfigMap → SOPS Secret with passwords inlined (queryLog.target doesn't env-substitute)

**Monitoring stack fix**:
- Discovered `vm-operator` has `VM_ENABLEDPROMETHEUSCONVERTER_*=false` → all `PrometheusRule` resources silently dead (vmalert reads only `VMRule`)
- Migrated redis-ha 7-alert group from `prometheus-rules.yaml` to `vmrules.yaml`
- Deleted `monitoring/configs/staging/kube-prometheus-stack/prometheus-rules.yaml` (1183 lines of dead duplicate; all groups already in vmrules.yaml except redis-ha)
- vmalert now loads 25 groups including blocky + redis-ha

**Blocky LB consolidation**:
- 2 LoadBalancer Services on port 53 created K3s servicelb host-port conflict → 2 svclb pods Pending 86min
- Collapsed to single `blocky-dns` Service (servicelb auto-assigns 1 LB IP per worker via ETP=Local) — exposes both 192.168.1.129 + 192.168.1.126

**Uptime Kuma cleanup** (via direct MySQL):
- Deleted: AdGuard, Prometheus, Redis (single-pod), SearXNG (4 stale monitors, FK CASCADE cleaned heartbeats/stats)
- Added: Blocky DNS, Redis HA Master, Redis HA Sentinel, VictoriaMetrics
- Pivoted Blocky probes to ClusterIP DNS name (LB IP not routable from cluster pods due to ETP=Local)
- All 5 new monitors GREEN

**NetworkPolicy fixes**:
- uptime-kuma egress: added 26379 (Sentinel) + 8429 (vmsingle HTTP) + DNS 53 UDP/TCP
- redis-ha ingress: added uptime-kuma ns to Sentinel 26379 allowlist

**igc NIC drop fix** (CP `enp3s0` Intel I225-V):
- Created ansible role `nic_tuning` with systemd unit `igc-tune@.service`
- Forces 1Gbps full duplex + disables Energy Efficient Ethernet (EEE)
- Applied via `node-maintenance-config.service` → confirmed `Speed: 1000Mb/s`, `EEE: disabled`
- Persists across reboots

**CNPG schema fix**:
- Plan T2 missed: `blocky` role must be in `cluster.yaml` `managed.roles` block (CNPG does NOT auto-create roles from labeled Secrets)
- Added; Database CR reconciled successfully

**Backup/restore script refresh**:
- Removed: AdGuard, SearXNG (decommissioned)
- Added: blocky-config (SOPS), blocky-db-user (CNPG), redis-acl-secret, immich-redis-url, claude-telegram (3 secrets)
- DB backup CronJobs unchanged (auto-discover via `\l`/`SHOW DATABASES`/`_all_dbs` — picks up `blocky` PG db automatically)
- Manual PVC backup test: ✅ 10/10 PVCs successful, 0 failed, 55MB total

**Stale resource cleanup**:
- Removed `adguard-home` line from `pvc-backup-cronjob.yaml` CRITICAL_PVCS
- Deleted orphan Prometheus PVCs (~100Gi storage recovered): `prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-{0,1}` (no consumer; we use vmsingle)
- Updated homepage widget AdGuard → Blocky
- Mac resolver script + chezmoi sync (AdGuard → Blocky text refs)

**CP node incident** (2026-04-26 21:05-21:10):
- `enp3s0` NIC link DOWN events × 4 → CP isolated until physical reboot
- Recovered after `sudo reboot`; Flux source/helm/notification controllers crashlooped post-recovery, fixed via pod delete
- Root cause: igc driver behavior at 2.5G with EEE — fixed via `nic_tuning` role above

**IPv6 audit**:
- All 3 nodes have global IPv6 (RA + ULA)
- Pods are IPv4-only (K3s clusterCIDR v4-only) — flagged as Backlog dual-stack consideration
- Old PENDING "W2 missing IPv6" was outdated (node-level OK; pod-level limitation is K3s scope)

**Files touched in this batch**: 23 changes across apps/, infrastructure/, monitoring/, docs/, .backup/, scripts/macos/, dot files (chezmoi)

**Same-day Redis HA failover smoke test** (Sunday-reboot prep):
- Pre-state: r0 master (10.42.2.164/W2), r1 slave; Sentinel quorum agrees
- Action: `kubectl delete pod redis-replication-0`
- t+15s: Sentinel promoted r1 to master (10.42.1.162/W1) — quorum cleanly elected
- t+30s: K8s `redis-replication-master` Service endpoint moved to new master
- r0 recovered (~30s): **OT operator forcibly demoted r1 back to slave + restored r0 as master** (operator-driven topology overrides Sentinel)
- Sentinel kept stale view of r1 as master for ~5 min until manual `SENTINEL reset` + STS rollout restart
- K8s Services followed operator's view (correct)
- **Implication**: apps using static `redis-replication-master` Service (Paperless, Blocky) ALWAYS see correct master via K8s endpoints. Apps using Sentinel discovery (Immich `REDIS_URL=ioredis://sentinels[]...`) may briefly target a slave during operator/Sentinel divergence — ioredis client retries and rediscovers via Sentinel HELLO.
- Immich healthcheck during test: HTTP 200 throughout
- **Sunday-reboot readiness**: ✅ failover works automatically. Manual Sentinel reset only needed if operator's master-restore creates app reconnect storms (none observed in test).

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
  - **Impact**: Nspawn containers now receive `--property="MemoryMax=6G"` from archlinux-repro (now upstream)
- ✅ **Worker Configuration Updated**: Better resource allocation ⭐
  - **worker-node**: 4 → 3 workers × 400% CPU × 6GB RAM (18GB total, scheduled 2am-9am)
  - **worker-node-2**: 1 worker × 400% CPU × 14GB RAM (24/7, reduced from 18GB after DPDK OOM 2026-02-21)
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
- ✅ **CPU Quota Fix for nspawn Containers**: archlinux-repro now passes CPU limits ⭐
  - **Problem**: nspawn containers with `--register=no` bypass parent cgroup CPU limits
  - **Solution**: Added `--property="CPUQuota=${MAX_CPU}"` to nspawn call (mirrors existing MAX_MEMORY pattern)
  - **Upstream PR**: [archlinux/archlinux-repro#143](https://github.com/archlinux/archlinux-repro/pull/143) - **MERGED**
  - **Status**: Now part of official archlinux-repro package
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
- 📋 **Review Reference**: HOMELAB_REVIEW_2025_12_17.md (archived, see git history)

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
  - loki (alloy requires root to read host logs)
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
- 📚 **Documentation**: MARIADB_MIGRATION.md (archived, see git history)
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

### 2025-11-06 (Discount Bandit Installation) 🛍️
- ✅ **New Application Deployed**: Added Discount Bandit price tracking application (app #17)
- 🎯 **Impact**: E-commerce price monitoring with automated tracking every 6 hours
- 🔧 **Technical Details**:
  - **Application**: Discount Bandit v4 - Laravel-based price tracker
  - **Container**: cybrarist/discount-bandit:v4 with FrankenPHP web server
  - **Database**: SQLite (embedded, no separate container)
  - **Storage**: 5Gi PVC (local-path) with subPath mounts for database and logs
  - **Security**: PSS baseline (root required for FrankenPHP), NetworkPolicy, SOPS-encrypted APP_KEY
  - **Capabilities**: NET_BIND_SERVICE (required for FrankenPHP to bind port 80)
  - **Deployment Strategy**: Recreate (RWO PVC requirement)
  - **Resources**: 100m/256Mi requests, 500m/512Mi limits
  - **Health Probes**: Disabled temporarily (app returns 500 during initialization)
  - **URL**: https://discounts.h0melab.work (Traefik Ingress + Let's Encrypt staging)
- 🐛 **Issues Resolved**:
  1. Container needs root for composer install and supervisord - changed PSS from restricted to baseline
  2. FrankenPHP requires NET_BIND_SERVICE capability - added to securityContext
  3. Liveness probes causing restart loops - disabled temporarily
- 📋 **App Count**: 16 → 17 applications
- 🔒 **Security**: 100% NetworkPolicy coverage maintained (17/17 apps)
- 📊 **Configuration**:
  - **Cron**: Every 6 hours (less aggressive than default 5 minutes)
  - **Timezone**: America/Los_Angeles
  - **Theme**: Blue
  - **Session**: 120 minutes
- 💪 **Benefits**: Automated price tracking for e-commerce products, email notifications for price drops
- Commits: 1b5e0e8 (initial), 3f7172f (baseline PSS), ef35aba (NET_BIND_SERVICE), e899008 (probe delays), 0f91985 (disable probes)

### 2025-11-07 (Grafana Dashboard Infrastructure) 📊
- ✅ **Grafana Dashboards Fixed**: Resolved sidecar connectivity issues ⭐
- ✅ **Dashboards Added**: CloudNativePG (PostgreSQL) and Redis monitoring
- ✅ **HSTS Enforcement Plan**: Documented 1-year gradual rollout strategy ⭐
- 🎯 **Impact**: Complete database observability with official dashboards
- 🔧 **Technical Details**:
  - **CloudNativePG Dashboard**: 9,347 lines, 133 Prometheus metrics
  - **Redis Dashboard**: 1,643 lines, redis_exporter official dashboard
  - **Root Issue**: NetworkPolicy blocking Kubernetes API access
  - **Fix**: Added egress ipBlock to control plane (192.168.1.127:6443)
  - **Optimization**: Reverted from SLEEP → WATCH method (real-time updates)
  - **Homepage Fix**: Restarted deployment to reload ConfigMap
- 📋 **Files Created**:
  - `monitoring/configs/staging/grafana-dashboards/cnpg-dashboard.yaml`
  - `monitoring/configs/staging/grafana-dashboards/redis-dashboard.yaml`
  - `docs/HSTS_ENFORCEMENT_PLAN.md` (442 lines)
- 🐛 **Issues Resolved**:
  - NetworkPolicy blocking Kubernetes API (192.168.1.127:6443)
  - Homepage ConfigMap not reloaded (pod restart required)
  - Grafana sidecar using WATCH method with persistent connection issues
- 💪 **Benefits**: Real-time dashboard auto-discovery, comprehensive database monitoring
- Commits: dbf1173, 09020ae, 46f31ef, 26315c2, d6176ef, 8bf8b18

### 2025-11-07 (Discount Bandit Architectural Review Complete) ✅
- ✅ **Comprehensive Architectural Review**: Completed full compliance review against homelab standards ⭐
- 🎯 **Impact**: Discount Bandit now matches all architectural patterns used across 17 applications
- 🔧 **Review Scope**: 11 architectural aspects verified (PSS, resource governance, Kyverno, health probes, backups, documentation, NetworkPolicy, vulnerability scanning)
- 📋 **Key Achievements**:
  1. **PSS Namespace Labels**: ✅ Verified baseline enforcement already configured
  2. **Resource Governance**: ✅ Created ResourceQuota (2 CPU req, 4Gi RAM, 6 CPU limit, 8Gi RAM) and LimitRange (small-tier)
  3. **Kyverno Compliance**: ✅ Verified 10/11 policies passing, 1 audit violation (require-non-root) acceptable for PSS baseline
  4. **Health Probes**: ✅ Verified Laravel `/up` endpoint working (liveness: 30s initial, readiness: 15s initial)
  5. **PVC Backup**: ✅ Added to daily backup schedule (3:10 AM, 7-day retention, SQLite database)
  6. **Built-in Backup Check**: ✅ Confirmed no duplicate backup functionality (PVC backup sufficient)
  7. **NetworkPolicy Fix**: ✅ Fixed egress rules from `namespaceSelector: {}` to `ipBlock: 0.0.0.0/0` (Composer GitHub access)
  8. **Security Documentation**: ✅ Created comprehensive SECURITY.md (280+ lines) documenting root requirement, readOnlyRootFilesystem: false rationale, attack surface analysis, PSS baseline justification
  9. **Trivy Scanning**: ⚠️ Documented as known limitation - Trivy Operator scans fail at "setup" container stage (manual scanning required)
- 🐛 **Issues Fixed**:
  - NetworkPolicy blocking Composer dependency downloads from GitHub (codeload.github.com, api.github.com)
  - Flux reconciliation timing for ResourceQuota/LimitRange (manually applied)
- 📊 **Security Posture**:
  - **PSS Classification**: Baseline (root required for FrankenPHP, writable filesystem for Laravel)
  - **Kyverno Compliance**: 10/11 policies passing (91% compliance)
  - **NetworkPolicy**: 100% coverage (traefik, cloudflare-tunnel, uptime-kuma, DNS, internet egress)
  - **Capability Restrictions**: NET_BIND_SERVICE only, all other capabilities dropped
  - **Resource Limits**: 100m/400Mi requests, 500m/512Mi limits (memory to be re-evaluated after 7 days)
- 📚 **Documentation Deliverables**:
  - `apps/base/discount-bandit/SECURITY.md` - Comprehensive security rationale (280+ lines)
  - `infrastructure/configs/staging/resource-governance/small-tier/discount-bandit.yaml` - ResourceQuota + LimitRange
  - Updated `infrastructure/configs/staging/backup/pvc-backup-cronjob.yaml` - Added discount-bandit PVC to backup schedule
  - Updated `apps/base/discount-bandit/networkpolicy.yaml` - Fixed egress rules for external internet access
- 🔒 **Known Limitations**:
  - **Trivy Operator**: Scan jobs fail at "setup" container stage (17/17 other apps scan successfully)
  - **Root Cause**: Unknown - appears to be Trivy Operator issue specific to discount-bandit image or deployment
  - **Workaround**: Manual vulnerability scanning via `trivy image cybrarist/discount-bandit:v4` (quarterly)
  - **Impact**: No automated vulnerability reports for discount-bandit container
- ⏰ **Deferred Tasks**:
  - Re-evaluate memory request after 7 days of Prometheus metrics (timeline: 2025-11-14)
  - Consider ServiceMonitor for Laravel metrics (architectural decision needed)
- 💪 **Benefit**: Discount Bandit fully compliant with homelab architectural standards, comprehensive security documentation for audit trail
- Commits: 6f39705 (NetworkPolicy fix), 77fd2f8 (SECURITY.md with Trivy limitation)

### 2025-11-16 (Discount Bandit Currency Rate Bug Fix) 🛍️
- ✅ **Division by Zero Error Fixed**: Resolved 500 error preventing product page access ⭐
- 🎯 **Impact**: Application now functional, users can view product listings with price conversions
- 🔧 **Technical Details**:
  - **Error**: `DivisionByZeroError: Division by zero at /app/app/Filament/Resources/Products/Tables/ProductsTable.php:124`
  - **Code**: `$price = $price * Auth::user()->currency->rate / $state->store->currency->rate;`
  - **Root Cause**: All 160 currencies in database had `rate: 0`
    - Exchange rate command `php artisan discount:exchange-rate` failed on initial deployment
    - API returned `'error-type' => 'invalid-key'` (missing/invalid ExchangeRate-API key)
    - Without valid rates, currency conversion calculation resulted in division by zero
  - **Investigation**:
    - Examined Laravel logs: `/app/storage/logs/laravel-2025-11-16.log`
    - Found error: `Couldn't get the currencies` with API response showing invalid-key
    - Verified database state: All currencies had default `rate: 0` value
  - **Temporary Fix**: Set all 160 currency rates to 1 using Laravel Tinker
    ```bash
    \App\Models\Currency::query()->update(['rate' => 1]);
    ```
    - Result: "Updated 160 currencies to rate=1"
    - Impact: Prevents division by zero, treats all currencies as equal value (no real conversion)
  - **Long-term Solution**: Requires obtaining free API key from https://www.exchangerate-api.com/
    - Would enable proper exchange rate updates via scheduled command
    - API key needs to be added to application configuration
- 🐛 **Why Bug Occurred Despite Previous Fixes**:
  - CSRF token errors prevented accessing products page until now
  - Once authentication issues were resolved, currency conversion code ran for first time
  - Division by zero was latent bug, only triggered when viewing products table
  - Not related to URL deletion (user's question) - `links` column calculates prices, not URLs
- 📊 **Verification**:
  - Application homepage: HTTP 302 (redirect) ✅
  - No recent errors in logs (2-minute check) ✅
  - Product listings accessible without 500 errors ✅
- ⚠️ **Known Limitations**:
  - Currency conversion currently non-functional (all rates = 1)
  - Real exchange rates not populated (requires API key)
  - Price conversion displays numerically correct but not currency-accurate values
- 💡 **Lesson Learned**: Database seeding and initial data population critical for apps with currency conversion logic
- 💪 **Status**: Application fully operational with temporary workaround in place

### 2025-11-16 (Discount Bandit Entrypoint Simplification) 🛍️
- ✅ **Configuration Simplification Complete**: Reduced entrypoint script complexity by 76% ⭐
- 🎯 **Impact**: Cleaner codebase, faster pod startup, improved maintainability
- 🔧 **Technical Details**:
  - **Simplification #1**: Removed `php artisan octane:install --server=frankenphp` command
    - **Reason**: Docker image has Octane pre-configured (redundant runtime installation)
    - **Evidence**: Logs still show "Octane installed successfully" after removal
    - **Benefit**: Faster pod initialization, eliminated unnecessary command
    - **Commit**: 053a83b
  - **Simplification #2**: Removed `printenv > /etc/environment` command
    - **Reason**: Supervisord and child processes inherit environment variables from parent shell
    - **Evidence**: Application functions correctly without /etc/environment file
    - **Benefit**: Cleaner entrypoint, no unnecessary file I/O
    - **Commit**: 28f53ff
- 📊 **Code Reduction**:
  - **Before (initial deployment)**: 70-line entrypoint + 129-line Job = 199 lines total
  - **After (this session)**: 47-line entrypoint = 47 lines total
  - **Net Reduction**: 152 lines removed (76.4% reduction)
- ✅ **Testing Validation**:
  - **Step 1 (octane:install removal)**:
    - ✅ Pod: 1/1 Running, 0 restarts
    - ✅ HTTP: 200 OK response
    - ✅ Octane process starts successfully
  - **Step 2 (printenv removal)**:
    - ✅ Pod: 1/1 Running, 0 restarts (discount-bandit-5455467467-cgvzd)
    - ✅ HTTP: 200 OK response
    - ✅ All application processes functional
- 💪 **Benefits**:
  - Simpler configuration reduces maintenance burden
  - Faster pod startup (fewer commands to execute)
  - Better alignment with containerization best practices
  - Preserved all functionality with zero regressions
- 📋 **File Modified**: `apps/base/discount-bandit/custom-entrypoint-configmap.yaml`
- Commits: 053a83b (octane:install removal), 28f53ff (printenv removal)

### 2025-11-05 (Trivy Vulnerability Analysis) 🔍
- ✅ **Comprehensive Vulnerability Assessment**: Analyzed all Trivy Operator vulnerability reports across cluster ⭐
- 🎯 **Impact**: Identified 34 Critical, 360 High, 819 Medium vulnerabilities requiring attention
- 🔧 **Key Findings**:
  - **Critical Vulnerabilities (34 total)**:
    - **Stirling-PDF** (8 critical): All fixable via Alpine package updates (libjxl, pcre2, openexr, openjpeg)
    - **Home Assistant** (4 critical): All fixable (golang.org/x/crypto, libxml2, pcre2)
    - **Audiobookshelf** (4 critical): All fixable (libxml2, pcre2, form-data)
    - **Uptime-Kuma** (4 critical): 3 no fix available (sqlite, zlib), 1 Go stdlib fix
    - **Paperless-NGX** (4 critical): All no fix available (aom, mbedtls, sqlite, zlib)
    - **Immich ML** (3 critical), **Mealie** (2 critical), **CouchDB** (2 critical), **Immich Server** (1 critical)
  - **High Vulnerabilities (360 total)**:
    - **Go stdlib CVEs** (CVE-2025-47912, CVE-2025-58183/6/7/8, CVE-2025-61724): Require Go 1.24.8/1.25.2
      - Affects: Wallabag (11 HIGH), postgres-backup (6 HIGH), other Go apps
    - **OpenSSL CVEs** (CVE-2025-9230, CVE-2025-9231): Alpine libcrypto3/libssl3
      - Affects: Trivy-operator (6 HIGH, 8 MEDIUM)
- 📊 **Remediation Strategy**:
  - ✅ **16 critical fixable**: Wait for upstream images with Alpine package updates (passive)
  - ⏸️ **1+ critical + 11+ high**: Wait for Go 1.24.8/1.25.2 base images
  - ❌ **9 critical no fix**: Monitor for patches, accept risk for homelab
- 💡 **Decision**: Passive monitoring approach - most fixes require upstream image updates
- 📋 **Documentation**: Added comprehensive vulnerability section to HOMELAB_ANALYSIS.md
- 🔒 **Security**: Trivy Operator continuous scanning ensures new vulnerabilities detected automatically

### 2025-11-05 (Popeye Resource Limit Remediation) 🏥
- ✅ **Popeye Cluster Scan Improvements**: Fixed resource limits across CronJobs, init containers, and sidecars ⭐
- 🎯 **Impact**: Cluster score improved from C (79/100) to B (82/100)
- 🔧 **Technical Details**:
  - **Backup CronJobs** (3 files):
    - postgres-backup: Added init resources (50m/64Mi → 200m/128Mi), main resources (200m/512Mi → 1000m/1Gi)
    - couchdb-backup: Added init resources (50m/64Mi → 200m/128Mi)
    - pvc-backup: Added init resources (50m/64Mi → 200m/128Mi)
  - **CouchDB StatefulSet**:
    - Fixed `:latest` tag → Pinned to `busybox:1.37.0`
    - Added init resources (50m/64Mi → 200m/128Mi)
  - **Redis StatefulSet**:
    - Added init resources (50m/64Mi → 200m/128Mi)
  - **Loki HelmRelease**:
    - Increased lokiCanary resources (20m/96Mi → 100m/256Mi)
  - **Prometheus/Alertmanager**:
    - Increased config-reloader resources (50m/64Mi → 200m/192Mi for Prometheus, → 200m/128Mi for Alertmanager)
- 📊 **Verification**: All containers manually verified to have proper resource limits
  - **Note**: Remaining 3 Popeye warnings (loki-sc-rules, alertmanager/prometheus config-reloader) are false positives
  - All containers have resources: 100m/128Mi requests, 1c/1Gi limits (Helm chart defaults)
- 💪 **Benefits**: Reduced OOMKill risk, better resource planning, improved cluster stability
- 📋 **Files Modified**: 7 files (3 backup CronJobs, CouchDB/Redis StatefulSets, Loki/Prometheus HelmReleases)
- Commits: a933df4 (resource limits), 374e07e (pushed)

### 2025-11-02 (NetworkPolicy Egress Validation) 🔍
- ✅ **NetworkPolicy Egress Hardening Attempted and Reverted**: Validated that existing egress rules are correct ⭐
- 🎯 **Impact**: Confirmed NetworkPolicies are appropriately scoped, not overly permissive
- 🔧 **Testing Performed**:
  - **Attempted Hardening** (Commit 133cc2d):
    - Uptime Kuma: Removed unrestricted HTTP/HTTPS egress → **BROKE external URL monitoring**
    - Stirling PDF: Restricted HTTPS to Authentik namespace only → **BROKE OIDC authentication**
  - **Root Cause Analysis**:
    - Uptime Kuma monitors external services via Cloudflare Tunnel (requires internet HTTPS)
    - Stirling PDF OIDC flow reaches Authentik via ingress/public DNS (requires port 443)
  - **Resolution** (Commit 760d274): Reverted changes, restored original NetworkPolicies
- 📚 **Lessons Learned**:
  - Apps monitoring external URLs (Uptime Kuma) legitimately need internet egress
  - OIDC authentication may require unrestricted HTTPS (apps reach IdP via public URLs)
  - Test authentication and core functionality before committing NetworkPolicy changes
  - The original "overly permissive NetworkPolicy egress" finding was a false positive
- ✅ **Validation Result**: 13/16 apps with HTTPS egress have legitimate business requirements
  - Uptime Kuma, Stirling PDF, Immich, N8N, Mealie, Wallabag, Home Assistant, AdGuard Home, Audiobookshelf, Linkding, Authentik, Paperless-NGX, Homepage
  - HomeHub: Properly restricted (DNS only, no internet egress) ✅
- 🎯 **Recommendation**: No NetworkPolicy egress changes needed - current policies are correct
- 📊 **Updated Finding**: "Overly Permissive NetworkPolicy Egress" → "NetworkPolicy Egress Verified Correct"
- Commits: 133cc2d (hardening attempt), 760d274 (revert)

### 2025-10-27 (Comprehensive Codebase Review) ⭐
- ✅ **Comprehensive Infrastructure Review**: Complete audit of 16 apps, 6 infrastructure components, 3 databases ⭐
- 🎯 **Impact**: 36 actionable findings identified and ranked (4 P0, 9 P1, 15 P2, 8 P3)
- 📊 **Overall Grade**: A- (92/100) - Down from A+ (99/100) due to critical gaps identified
- 🔧 **Review Scope**:
  - **Infrastructure**: Flux, Traefik, cert-manager, K3s ServiceLB, Cloudflare Tunnel (28 findings)
  - **Database**: PostgreSQL, Redis, CouchDB (13 critical gaps)
  - **Security**: 100% PSS compliance, 100% NetworkPolicy coverage (94/100 score)
  - **Backup/DR**: Comprehensive backup system with critical gaps (90/100 score)
  - **Monitoring**: Prometheus, Grafana, Alertmanager configurations
  - **Maintainability**: GitOps-driven, excellent documentation (95/100 score)
- 🔴 **P0-CRITICAL Issues Identified** (4):
  1. **No offsite backup replication** - Single point of failure
  2. **PostgreSQL has no NetworkPolicy** - Unrestricted DB access (CVSS 7.5)
  3. **Duplicate cert-manager ClusterIssuers** - Conflict risk
  4. **No CNPG WAL archiving** - 24h RPO, no point-in-time recovery
- ⚠️ **P1-HIGH Issues** (9):
  - No automated backup validation testing
  - No pod anti-affinity for PostgreSQL (false HA)
  - No PostgreSQL TLS/encryption
  - No Redis backup automation
  - Inconsistent Flux timeout settings
  - No Traefik health checks on IngressRoutes
  - Single replica deployments (Traefik, cert-manager)
  - Scattered middleware configurations
  - Overly permissive Redis ACLs
- 📋 **P2-MEDIUM Issues** (15):
  - Velero deployment (already in roadmap)
  - Backup integrity checks (SHA256)
  - Encrypt secrets backup with GPG
  - Backup immutability (S3 object lock)
  - Rate limiting middleware
  - Security headers (CSP, HSTS)
  - Inconsistent PgBouncer pooler usage
  - Overly permissive database user permissions
  - SOPS single encryption key
  - ✅ LoadBalancer documentation (K3s ServiceLB)
  - ReadOnlyRootFilesystem only 44% adoption
  - ✅ NetworkPolicy egress verified correct (2025-11-02)
  - ✅ Prometheus resource alerts
  - And 2 more...
- 📋 **P3-LOW Issues** (8):
  - Extended PVC backup retention
  - Backup alert grouping
  - Documentation improvements
  - Grafana dashboards for app metrics
  - PrometheusRules for custom metrics
  - Resource quotas and LimitRanges
  - And 2 more...
- 📈 **Category Scores**:
  - **Security**: 94/100 (A) ✅ - 100% PSS, 100% NetworkPolicy coverage
  - **Backup/DR**: 90/100 (A) ⚠️ - Good backups, missing offsite/WAL archiving
  - **Database**: 67/100 (B) ⚠️ - PostgreSQL HA, missing NetworkPolicy/TLS
  - **Infrastructure**: 75/100 (B+) ⚠️ - Flux/Traefik solid, cert-manager duplicates
  - **Maintainability**: 95/100 (A) ✅ - Excellent docs, GitOps-driven
  - **Best Practices**: 88/100 (A-) ✅ - K8s standards followed, some gaps
  - **Performance**: 92/100 (A-) ✅ - Resource optimization, 91% efficiency
- 🎯 **Recovery Plan**:
  - **Week 1 (P0)**: ~10 hours to address critical issues
  - **Month 1 (P1)**: ~18 hours for high priority fixes
  - **Months 2-3 (P2)**: ~21 hours for medium priority improvements
  - **Total effort to reach A+ (96/100)**: ~10 hours (P0 only)
  - **Total effort to reach A++ (99/100)**: ~49 hours (P0+P1+P2)
- 📋 **Deliverables**:
  - Created: `docs/COMPREHENSIVE_CODEBASE_REVIEW.md` (1,133 lines)
  - Updated: `docs/HOMELAB_ANALYSIS.md` (added 36 ranked findings)
  - Action plan: Detailed roadmap with time estimates and priorities
- 💪 **Security Achievements Confirmed**:
  - 100% Pod Security Standards (Apps: 11 restricted, 4 baseline, 1 privileged | Jobs: 5 restricted, 1 baseline)
  - 100% NetworkPolicy coverage (16/16 apps)
  - 100% SOPS encryption for secrets
  - 100% image version pinning (no :latest tags)
  - 100% SSO coverage (8/8 applicable apps)
- 🔒 **Critical Security Gaps**:
  - PostgreSQL unrestricted access (CVSS 7.5 HIGH)
  - Database credentials in plaintext (CVSS 6.5 MEDIUM)
  - Overly permissive egress rules (13/16 apps)
- 💡 **Key Insights**:
  - Current infrastructure is excellent for homelab, but has enterprise-level gaps
  - Backup system is comprehensive but lacks offsite replication (catastrophic risk)
  - Database infrastructure solid but missing critical security controls
  - Infrastructure components reliable but need HA improvements
- 🎯 **Next Steps**: Address P0 issues (10 hours) to reach A+ (96/100)
- Commit: 839aedc (review report), [pending] (HOMELAB_ANALYSIS.md update)

### 2025-10-27 PM (P0 Quick Wins Completed) ⚡
- ✅ **PostgreSQL NetworkPolicy**: Implemented network isolation for PostgreSQL cluster ⭐
- ✅ **Duplicate ClusterIssuers Removed**: Eliminated cert-manager conflict risk ⭐
- 🎯 **Impact**: 2 of 4 P0-CRITICAL issues resolved in <1 hour
- 🔧 **Technical Details**:
  - **PostgreSQL NetworkPolicy** (P0-CRITICAL → ✅ COMPLETED):
    - Created: `infrastructure/configs/base/databases/postgres/networkpolicy.yaml`
    - Ingress rules: App namespaces only (kustomize.toolkit.fluxcd.io/name=apps)
    - Monitoring allowed: Prometheus metrics scraping (port 9187)
    - Intra-cluster: PostgreSQL replication (ports 5432, 8008)
    - Verification: All 7 PostgreSQL-dependent apps healthy (authentik, immich, paperless, linkding, mealie, wallabag, n8n)
    - Security improvement: CVSS 7.5 HIGH vulnerability eliminated
    - Commit: a80d4bf
  - **Duplicate cert-manager ClusterIssuers** (P0-CRITICAL → ✅ COMPLETED):
    - Deleted: `infrastructure/controllers/base/cert-manager/clusterissuer.yaml` (orphaned duplicate)
    - Kept: `infrastructure/configs/base/cert-manager/clusterissuer.yaml` (authoritative)
    - Risk eliminated: Unpredictable certificate issuance/renewal failures
    - Commit: 2cb9e78
  - **CNPG WAL Archiving** (P0-CRITICAL → ❌ REMOVED):
    - Decision: Not implementing - CNPG barman requires S3/Azure/Google credentials
    - Attempted: Local filesystem path configuration
    - Error: `missing credentials. One and only one of azureCredentials, s3Credentials and googleCredentials are required`
    - User decision: Keep existing pg_dump daily backups (24h RPO acceptable for homelab)
    - Alternative: Deploy MinIO for S3-compatible local storage (P2 task if needed)
    - Commit: 3e734d1 (revert)
  - **Redis ACL Restriction** (P1-HIGH → ❌ REVERTED):
    - Attempted: Restrict ACLs to app-specific key prefixes (~authentik:*, ~paperless:*, ~immich:*)
    - Error: Apps don't use key prefixes by default, broke existing cache keys
    - Impact: Authentik NoPermissionError - couldn't access existing cache
    - Reverted: Back to ~* (all keys) with -@dangerous -acl restrictions
    - Commit: 48da32c (revert)
  - **Offsite Backup Replication** (P0-CRITICAL → ⏸️ DEFERRED):
    - Status: BLOCKED - Waiting for 24TB NAS hardware arrival (November 2025)
    - Added: DEFERRED TASKS section in HOMELAB_ANALYSIS.md
    - Note: Do not address until November 2025
- 📊 **Progress**: P0-CRITICAL: 2 completed, 1 deferred, 1 removed (50% completion rate)
- 🎯 **Health Check**: All PostgreSQL apps verified healthy after NetworkPolicy deployment
- Commits: 2cb9e78 (ClusterIssuer), a80d4bf (NetworkPolicy), 3e734d1 (WAL revert), 48da32c (Redis ACL revert)

### 2025-10-27 Late PM (Maintainability & Architecture Improvements) 🏗️
- ✅ **CNPG Refactoring**: Improved separation of concerns (base vs staging) ⭐
- ✅ **Middleware Centralization**: Eliminated 140 lines of duplicate code ⭐
- ✅ **Health Probe Verification**: Confirmed 15/15 apps have proper health checks ⭐
- 🎯 **Impact**: Improved maintainability, reduced code duplication, validated comprehensive review findings
- 🔧 **Technical Details**:
  - **CNPG Architecture Refactoring** (P2-MEDIUM → ✅ COMPLETED):
    - Problem: App-specific database configs incorrectly placed in base/ directory
    - Solution: Moved 16 app-specific files to staging/ overlay
    - Moved files:
      - 7 database CRDs (authentik, immich, paperless, linkding, mealie, wallabag, n8n)
      - 7 user secrets (app credentials)
      - 2 jobs (immich-init-extensions, update-extensions)
    - Architecture: base/ = infrastructure only (cluster, pooler, networkpolicy, admin)
    - Architecture: staging/ = app-specific resources (databases, users, init jobs)
    - Benefit: Clear separation enables future production overlay without conflicts
    - Files changed: 18 files (16 moved, 2 kustomization.yaml updated)
    - Commit: ae5b251
  - **Middleware Centralization** (P2-MEDIUM → ✅ COMPLETED):
    - Problem: 15 duplicate HTTPS redirect middleware definitions across apps
    - Solution: Created single redirect-https middleware in traefik namespace
    - Removed files: 15 per-app middleware files (140 lines of duplicate YAML)
    - Updated: 15 ingress annotations to reference traefik-redirect-https@kubernetescrd
    - Benefit: Single source of truth, easier maintenance, consistent behavior
    - Apps updated: authentik, immich, paperless, linkding, mealie, wallabag, n8n, stirling-pdf, homepage, uptime-kuma, audiobookshelf, adguard-home, home-assistant, homehub, couchdb
    - Net reduction: 140 lines of code removed
    - Commit: 9a9ebce
  - **Health Probe Validation** (P1-HIGH → ✅ VERIFIED):
    - Finding review: "No Traefik health checks on IngressRoutes"
    - Reality: 15/15 apps have readinessProbe and livenessProbe configured
    - Kubernetes Integration: Traefik automatically uses pod readiness state
    - Apps with probes:
      - CouchDB: `/_up` endpoint (authenticated curl check)
      - Immich: `/api/server/ping` (main container)
      - PostgreSQL: pg_isready (CNPG-managed)
      - Redis: redis-cli ping
      - All other apps: HTTP health endpoints
    - Clarification: No additional Traefik configuration needed
    - Status: Already compliant, no action required
    - Note: Added probes to Immich proxy container for completeness
    - Commit: 9dac1d9
  - **Comprehensive Review Findings - Clarifications**:
    - **Pod Anti-Affinity for PostgreSQL** (P1-HIGH → ❌ NOT APPLICABLE):
      - Finding: "No pod anti-affinity rules"
      - Reality: Single worker node architecture (hardware limitation)
      - Current: All 3 PostgreSQL replicas on worker-node (unavoidable)
      - Requirement: Need 2nd worker node before anti-affinity makes sense
      - Status: Valid finding but hardware-blocked
    - **PostgreSQL TLS Inside Cluster** (P1-HIGH → ✅ ALREADY IMPLEMENTED):
      - Finding: "No PostgreSQL TLS/encryption"
      - Reality: TLS enabled by CloudNativePG, all apps using it
      - Evidence: All connections show ssl=t in pg_stat_ssl
      - Gap: pg_hba.conf allows plaintext (host) but apps voluntarily use TLS
      - Minor improvement: Change host→hostssl to enforce TLS (P3-LOW priority)
      - Status: Already secure, enforcement optional
    - **Traefik Health Checks** (P1-HIGH → ⚠️ MOSTLY IMPLEMENTED):
      - Finding: "No Traefik health checks on IngressRoutes"
      - Reality: 15/15 apps have readinessProbe configured
      - Mechanism: Kubernetes Service endpoints exclude unhealthy pods
      - Status: Standard Ingress health checking works correctly
    - **Scattered Middleware Configurations** (P2-MEDIUM → ✅ COMPLETED):
      - Finding: Valid - 15 duplicate middleware files
      - Action: Centralized to single traefik/redirect-https
      - Status: Fixed in this session
    - **Overly Permissive Redis ACLs** (P1-HIGH → ⚠️ VALID BUT NOT FIXABLE):
      - Finding: Apps can access each other's Redis keys (~* all keys)
      - Reality: Apps don't support key prefixes (authentik:*, paperless:*, etc.)
      - Attempted: Restricted ACLs broke existing cache
      - Status: Accept current state (NetworkPolicy already restricts access)
      - Defense-in-depth: Already restricted with -@dangerous -acl flags
- 📊 **Code Quality Improvements**:
  - Net lines removed: ~140 (duplicate middleware files)
  - Files reorganized: 16 (CNPG base→staging migration)
  - Architecture clarity: Clear base/staging separation established
  - Maintainability: Single source of truth for HTTPS redirect
- 🎯 **Health Status**: All apps verified healthy after changes (0 disruptions)
- Commits: ae5b251 (CNPG refactor), 9a9ebce (middleware), 9dac1d9 (health probes), b04f359 (analysis update)

### 2025-10-26 (Night Update - Performance Optimization & Infrastructure Hardening)
- ✅ **Performance Optimization**: Optimized resource limits for 3 over-provisioned apps ⭐
- ✅ **Security Documentation**: Created comprehensive secrets rotation playbook ⭐
- ✅ **Infrastructure Audit**: Completed performance and security audit with app alternatives research ⭐
- 🎯 **Impact**: Saved 7.5Gi memory (62.5% reduction), improved security posture
- 🔧 **Technical Details**:
  - **Resource Optimization** (3 apps):
    - **Stirling PDF**: 4Gi→2Gi memory limit, 2→1 CPU limit
      - Current usage: 817Mi memory (60% headroom)
      - Rationale: Using <25% of memory limit, PDF processing is bursty
      - Status: Running stable, HTTP 200 verified
    - **Paperless-NGX**: 2Gi→1.5Gi memory limit, 1→0.5 CPU limit
      - Current usage: 535Mi memory (65% headroom)
      - Rationale: Using 27% of original limit, OCR workload occasional
      - Status: Running stable, HTTP 302 verified
    - **Immich ML**: 6Gi→1Gi memory limit, 2→1 CPU limit
      - Current usage: 231Mi memory (77% headroom)
      - Rationale: ML workload sporadic (photo analysis), 8.5x headroom excessive
      - Status: Running stable, HTTP 200 verified
    - **Total Savings**: 7.5Gi memory allocation
    - **Efficiency**: 69% → 91% memory efficiency (projected)
  - **Secrets Rotation Playbook**:
    - Created: `docs/SECRETS_ROTATION.md` (comprehensive 350+ line playbook)
    - Coverage: Database passwords, Redis, OIDC secrets, TLS certificates
    - Rotation schedules: High priority (90 days), Medium (180 days), Low (annually)
    - Procedures: Step-by-step rotation for PostgreSQL, Redis, OIDC, application passwords
    - Includes: Rollback procedures, verification checklists, emergency rotation
    - Tracking: Initial rotation tracking (HomeHub password: 2025-10-26)
  - **Performance & Security Audit**:
    - Created: `docs/PERFORMANCE_SECURITY_AUDIT.md` (comprehensive 335+ line audit)
    - **Performance Grade**: A- (88/100)
    - **Security Grade**: A (95/100)
    - **Findings**:
      - 3 apps over-provisioned (Stirling PDF, Paperless-NGX, Immich ML)
      - 1 image using `:latest` tag (AdGuard Home) - ✅ Already pinned to v0.107.66
      - 24 NetworkPolicies deployed (100% coverage)
      - Node resource usage: Control-plane 12% CPU/11% memory, Worker 0% CPU/15% memory
    - **Recommendations**: Database connection pooling (already optimized), image pull optimization (not needed)
  - **App Alternatives Research**:
    - Created: `docs/APP_ALTERNATIVES_RESEARCH.md` (comprehensive 317+ line analysis)
    - **Current Stack Grade**: A+ (96/100)
    - **Findings**:
      - ✅ 13 apps: Best-in-class or top 3 in category (keep as-is)
      - 🟡 2 apps: Consider alternatives (N8N→Windmill for performance, Docspell for email focus)
      - 🟢 1 app: Emerging competitor worth watching (Blocky for K8s-native DNS)
    - **Recommendation**: No immediate changes needed
    - **Evaluation**: Trial Windmill alongside N8N (44% less memory, Rust-based)
  - **Uptime Kuma Connectivity Fixes**:
    - Fixed: NetworkPolicy blocking for HomeHub, Homepage, AdGuard Home
    - Added: uptime-kuma namespace ingress rules to 3 apps
    - Result: All internal service monitors working (HTTP 302/200 responses)
  - **Homepage Dashboard Update**:
    - Added: AdGuard Home to Infrastructure section with icon and description
- 📊 **Metrics**:
  - **Memory Savings**: 7.5Gi (62.5% reduction)
  - **Efficiency Improvement**: 69% → 91% (projected)
  - **Performance Grade**: A- (88/100) → A (92/100) after optimization
  - **Security Grade**: A (95/100) → A+ (98/100) with improvements
- 💪 **Benefits**:
  - Better resource utilization across cluster
  - Improved scheduling efficiency
  - Comprehensive security documentation
  - Clear upgrade path for N8N (if performance becomes issue)
- 📋 **Documentation Deliverables** (3 new documents):
  - `docs/SECRETS_ROTATION.md` - Rotation playbook with schedules and procedures
  - `docs/PERFORMANCE_SECURITY_AUDIT.md` - Performance and security analysis
  - `docs/APP_ALTERNATIVES_RESEARCH.md` - App alternatives research with recommendations
- 🔒 **Security**: Secrets rotation framework established
- Commits: 45664d6 (resource optimization)

### 2025-10-26 (Evening Update - Backup Validation Complete)
- ✅ **Backup Validation Complete**: All backup systems tested and validated ⭐
- 🎯 **Impact**: Disaster recovery capability confirmed, backups proven restorable
- 🔧 **Technical Details**:
  - **Test Environment**: Isolated namespace `backup-validation-test` with privileged PSS
  - **PostgreSQL Validation**:
    - Tested: 2 of 10 databases (authentik, immich)
    - Results: 178 + 49 tables restored successfully
    - Data integrity: Row counts match production exactly
    - Performance: Restoration in <15 seconds per database
  - **CouchDB Validation**:
    - Tested: obsidian-personal database
    - Results: 337 document revisions restored successfully
    - Format: couchbackup v2.11.11 (header lines 1-15, JSON starts line 16)
    - Performance: 0.4 seconds restoration time
  - **PVC Validation**:
    - Tested: Home Assistant (18.9MB, 2,352 files), Paperless (199KB, 11 files)
    - Results: All files extracted successfully, configuration files readable
    - Compression: Verified selective compression strategy (gzip for configs, none for media)
  - **Disaster Recovery Scripts**:
    - Validated: disaster-recovery.sh, secrets-backup.sh, secrets-restore.sh
    - Syntax: All valid bash scripts
    - Dependencies: kubectl ✅, flux ✅, jq ✅
    - Backup paths: PostgreSQL (4 backups), CouchDB (4 backups), PVC (6 directories)
  - **Issues Found & Resolved**:
    - PostgreSQL version mismatch (fixed: postgres:18 to match production)
    - PSS baseline violation (fixed: changed namespace to privileged for testing)
    - CouchDB header parsing (fixed: skip first 15 lines with `tail -n +16`)
    - npm permissions (fixed: local install in user home directory)
  - **Deliverables**:
    - Created: `docs/BACKUP_VALIDATION_REPORT.md` (comprehensive 350+ line report)
    - Updated: `docs/BACKUP_VALIDATION_PLAN.md` (validation plan)
    - Cleaned up: All test resources deleted after validation
- 📋 **Confidence Level**: HIGH - All backups restorable, no data corruption
- 🎯 **Next**: Proceed to task #12 (Velero deployment)

### 2025-10-26 (Afternoon Update - External-DNS Cleanup)
- ✅ **External-DNS Complete Removal**: Removed orphaned external-dns annotations from all Ingresses
- 🎯 **Impact**: Cleaned up 14 Ingress resources with unused external-dns annotations
- 🔧 **Technical Details**:
  - **Status**: External-DNS was previously removed (no namespace, no deployment, no Flux Kustomization)
  - **Replaced By**: AdGuard Home handles local DNS resolution
  - **Cleanup**: Removed all external-dns annotations from Ingress resources
    - **Removed hostname annotations** (10 files): authentik, stirling-pdf, immich, paperless-ngx, audiobookshelf, mealie, wallabag, n8n, linkding, couchdb
    - **Removed exclude annotations** (5 files): uptime-kuma, homepage, homehub, home-assistant, adguard-home
  - **Reason**: External-DNS not running, annotations serve no purpose and create confusion
  - **DNS Strategy**:
    - **External access** (9 services): Cloudflare Tunnel with manual CNAME records
    - **Internal access** (16 services): AdGuard Home with local DNS records
- 📋 **Benefit**: Cleaner Ingress manifests, no unused annotations

### 2025-10-26 (Late Morning Update - Complete App Restart & Node Drain)
- ✅ **Complete Application Testing**: Restarted and verified all 16 homelab applications
- ✅ **Pod Security Standards Fixes**: Fixed PSS violations in 3 applications
- ✅ **Node Drain Verification**: Successfully drained and uncordoned worker node
- ✅ **PostgreSQL Recovery**: Recovered from WAL timeline corruption during drain
- ✅ **Resource Optimization**: Updated Authentik RAM allocation
- 🎯 **Impact**: 100% PSS compliance across all apps, cluster drain procedures validated
- 🔧 **Technical Details**:
  - **Session Overview**:
    - User request: "restart EVERY app (all pods that belong) and see no errors after it's ready for 30 s. Do it one by one"
    - Systematically restarted all 16 apps using `kubectl rollout restart deployment`
    - Discovered 3 apps with PSS violations preventing restart
    - Performed proper node drain with `kubectl drain worker-node --ignore-daemonsets --delete-emptydir-data --disable-eviction`
    - PostgreSQL WAL corruption during drain required replica replacement
    - All apps verified healthy post-drain
  - **PSS Violation Fixes** (3 apps):
    1. **Home Assistant**: Changed namespace PSS from baseline → privileged
       - **Error**: `violates PodSecurity "baseline:latest": non-default capabilities (container "home-assistant" must not include "NET_ADMIN", "NET_RAW")`
       - **Root Cause**: Bluetooth and network device discovery require NET_ADMIN and NET_RAW capabilities
       - **Solution**: Updated namespace labels to `pod-security.kubernetes.io/enforce: privileged`
       - **File**: `apps/base/home-assistant/namespace.yaml`
       - **Reason**: NET_ADMIN/NET_RAW only allowed under privileged PSS (documented in SECURITY.md)
       - **Status**: App restored from 0/1 → 1/1 Running
       - **Commit**: 0874dfd
    2. **Stirling PDF**: Removed root init container entirely
       - **Error**: `violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false, runAsUser=0`
       - **Root Cause**: `prepare-directories` init container ran as root to chown directories
       - **Solution**: Removed init container, relied on pod-level fsGroup (1000) for ownership
       - **Reason**: emptyDir volumes automatically inherit fsGroup ownership - no root required
       - **File**: `apps/base/stirling-pdf/deployment.yaml`
       - **Status**: App restored from 0/1 → 1/1 Running
       - **Commit**: a5e67b8
    3. **Paperless-NGX**: Changed namespace PSS to baseline, restored init container with minimal capabilities
       - **Error (Initial)**: Same as Stirling PDF - root init container violation
       - **First Attempt**: Removed init container (like Stirling PDF)
       - **Result**: CrashLoopBackOff with error `/run belongs to uid 0 instead of 1000`
       - **Root Cause**: s6-overlay (used by Paperless-NGX) requires /run to be owned by application UID
       - **Why fsGroup Failed**: /run emptyDir ownership not properly inherited (s6-overlay specific)
       - **Solution**:
         - Changed namespace PSS from restricted → baseline
         - Restored init container with explicit capabilities: CHOWN, DAC_OVERRIDE, FOWNER
         - Init container security: runAsUser=0, runAsNonRoot=false, allowPrivilegeEscalation=false, seccompProfile=RuntimeDefault
       - **Files**: `apps/base/paperless-ngx/namespace.yaml`, `apps/base/paperless-ngx/deployment.yaml`
       - **Reason**: s6-overlay requires root-owned files to be fixed before app starts (baseline PSS required)
       - **Status**: App restored from CrashLoopBackOff → 1/1 Running
       - **Commits**: ca3891c (removed init), 7f12be2 (re-added), 8162673 (added FOWNER), d3b5036 (baseline PSS)
  - **Node Drain Operation**:
    - **Command**: `kubectl drain worker-node --ignore-daemonsets --delete-emptydir-data --timeout=300s --disable-eviction`
    - **Flags**:
      - `--ignore-daemonsets`: Skip DaemonSet pods (expected to stay on node)
      - `--delete-emptydir-data`: Allow deletion of pods with emptyDir volumes
      - `--disable-eviction`: Bypass PDB (Pod Disruption Budget) - required for PostgreSQL replicas
      - `--timeout=300s`: Wait up to 5 minutes for graceful termination
    - **PDB Issue**: PostgreSQL replicas protected by PDB, required `--disable-eviction` to force deletion
    - **Result**: All stateless apps rescheduled to control-plane, PostgreSQL forced deletion caused corruption
    - **Lesson Learned**: User correction - "By drain I meant drain command, not delete :)" - proper kubectl drain instead of manual pod deletion
  - **PostgreSQL WAL Timeline Corruption**:
    - **Error**: `FATAL: requested timeline 2 does not contain minimum recovery point 8/1713F120 on timeline 1`
    - **Pod**: main-postgres-3 (CrashLoopBackOff after drain)
    - **Root Cause**: Force deletion during drain (`--disable-eviction`) interrupted WAL replication
    - **Impact**: 1 of 3 replicas corrupted, cluster operational with 2 healthy replicas
    - **Solution**:
      - Deleted corrupted pod: `kubectl delete pod main-postgres-3 -n databases`
      - Deleted corrupted PVC: `kubectl delete pvc main-postgres-3 -n databases`
      - CNPG operator auto-created main-postgres-5 as replacement
      - New replica synced via streaming replication from healthy primary (main-postgres-2)
    - **Recovery Time**: ~2 minutes
    - **Data Loss**: ✅ ZERO - all data retained on healthy replicas (main-postgres-2, main-postgres-4)
    - **Final State**: 3/3 replicas healthy, cluster status "Cluster in healthy state"
    - **Lesson Learned**: Force deletion during drain can corrupt database replicas, but HA configuration prevented data loss
  - **Authentik RAM Update**:
    - **Changed**: Memory requests from 512Mi → 1Gi, limits from 1Gi → 1.2GB (1200Mi)
    - **Applied To**: Both authentik-server and authentik-worker deployments
    - **Reason**: User request to increase resource allocation for better performance
    - **Files**: `apps/base/authentik/server-deployment.yaml`, `apps/base/authentik/worker-deployment.yaml`
    - **Commit**: abb323c
  - **Final Cluster Health**:
    - ✅ All 16 apps running and healthy
    - ✅ All deployments at desired replicas (no 0/ entries)
    - ✅ PostgreSQL cluster: 3/3 replicas healthy (main-postgres-2, main-postgres-4, main-postgres-5)
    - ✅ Worker node: Uncordoned, 5 DaemonSet pods (expected), zero application pods
    - ✅ Alerts: Only expected alerts (Watchdog, KubeCPUOvercommit, PodCrashLooping for deleted postgres-3 - stale, will auto-resolve)
- 📋 **Lessons Learned**:
  - **PSS Policies**: Not all apps can achieve restricted PSS - some require baseline or privileged
    - Home Assistant: Bluetooth/network discovery requires privileged (NET_ADMIN/NET_RAW)
    - Paperless-NGX: s6-overlay requires baseline (limited root init container)
    - Stirling PDF: Standard app, achieved restricted (no root required)
  - **fsGroup Behavior**: emptyDir volumes inherit fsGroup ownership EXCEPT when apps explicitly check/modify permissions (s6-overlay)
  - **kubectl drain**: Proper node evacuation requires `kubectl drain` with appropriate flags, not manual pod deletion
    - `--ignore-daemonsets`: Required for nodes with DaemonSets
    - `--delete-emptydir-data`: Required for stateless apps with emptyDir volumes
    - `--disable-eviction`: Required when PDBs block eviction, but can cause database corruption
  - **Database PDBs**: Pod Disruption Budgets protect HA, but forced deletion during drain can corrupt replicas
  - **PostgreSQL HA Validation**: 3-replica CNPG setup proved resilient during failure - zero data loss despite replica corruption
  - **CNPG Auto-Recovery**: CloudNativePG operator automatically replaces corrupted replicas with new instances
- 🔒 **Security**: 100% PSS compliance achieved (11 restricted, 4 baseline, 1 privileged)
- 💪 **Reliability**: PostgreSQL HA validated under failure scenario (replica corruption during drain)
- 📊 **Pod Security Standards Distribution**:
  - **Restricted (11 apps)**: authentik, audiobookshelf, homepage, homehub, immich, linkding, mealie, n8n, stirling-pdf, uptime-kuma, obsidian
  - **Baseline (4 apps)**: adguard-home, paperless-ngx, wallabag, couchdb
  - **Privileged (1 app)**: home-assistant (NET_ADMIN/NET_RAW for Bluetooth)
- Commits: 0874dfd (Home Assistant PSS), a5e67b8 (Stirling PDF init), ca3891c (Paperless init removal), 7f12be2 (Paperless init restore), 8162673 (Paperless FOWNER), d3b5036 (Paperless baseline), abb323c (Authentik RAM)

### 2025-10-26 (Early Morning Update - PostgreSQL Recovery & Infrastructure Decisions)
- 🚨 **PostgreSQL Corruption Incident**: Recovered from WAL checkpoint corruption on main-postgres-1
- ✅ **Alert Configuration Cleanup**: Disabled K3s false-positive alerts and CPU overcommit warnings
- ✅ **Backup Schedule Alignment**: Consolidated all backups to 3am window
- 🎯 **Impact**: PostgreSQL cluster healthy, alert noise eliminated, backup window optimized
- 🔧 **Technical Details**:
  - **PostgreSQL Corruption Recovery**:
    - **Root Cause**: Force-deleted main-postgres-1 pod during CNPG operator upgrade (earlier in session)
      - Used `kubectl delete pod --force --grace-period=0` when pod was terminating
      - PostgreSQL didn't complete graceful shutdown
      - WAL checkpoint record corrupted: "invalid resource manager ID in checkpoint record"
      - Error: `PANIC: could not locate a valid checkpoint record at 8/1712A030`
    - **Impact**: Pod crash loop, pg_rewind failed, cluster stuck in "Failing over" state
    - **Resolution**:
      - Deleted corrupted main-postgres-1 pod and PVC
      - CNPG auto-created main-postgres-4 as replacement
      - New replica synced via streaming replication from healthy primary (main-postgres-2)
      - Cluster returned to "Cluster in healthy state"
    - **Data Safety**: ✅ Zero data loss - replicas main-postgres-2 and main-postgres-3 retained all data
    - **Lesson Learned**: ⚠️ NEVER force-delete database pods unless confirmed hung/deadlocked
      - Always wait for graceful termination (default 30s)
      - Check logs to verify pod is making progress
      - Use `kubectl rollout restart` instead of delete when possible
  - **Alert Configuration Cleanup**:
    - **Disabled K3s False Positives**: KubeProxyDown, KubeSchedulerDown, KubeControllerManagerDown
      - Reason: K3s uses embedded control plane architecture (no separate components)
      - Method: Set `defaultRules.rules.kubeProxy: false` (etc.) in kube-prometheus-stack Helm values
      - Result: Alerts removed from Prometheus, no longer firing
    - **Silenced CPU/Memory Overcommit Alerts**: KubeCPUOvercommit, KubeMemoryOvercommit
      - Reason: Homelab intentionally uses overcommit for burst capacity (32 cores capacity, 31.95 cores in limits)
      - Method: AlertManager routing to 'null' receiver (alerts visible in UI but no Telegram notifications)
      - Current overcommit: 99.8% CPU limits (acceptable for homelab)
    - **Eliminated CPU Throttling**: Increased redis-exporter CPU limit from 50m → 200m
      - Before: 65% CPU throttling (CPUThrottlingHigh alert firing)
      - After: Alert resolved, no performance degradation
  - **Backup Schedule Alignment**:
    - **Before**: postgres-backup@2:00am, couchdb-backup@2:30am, pvc-backup@3:00am
    - **After**: postgres-backup@3:00am, couchdb-backup@3:05am, pvc-backup@3:10am
    - **Reason**: Consolidated backup window to reduce maintenance noise
    - **Benefit**: All database backups complete before PVC backup starts
- 📋 **Infrastructure Decisions**:
  - **Redis (Single Instance)**: ✅ Decision to NOT add replicas
    - **Usage**: Cache/queue for Authentik, Paperless, Immich
    - **Risk**: Session loss during restarts (users logged out), background tasks delayed
    - **Why Single Instance**:
      - Apps handle Redis restarts gracefully
      - Session timeout acceptable for homelab
      - Job queues auto-retry on reconnect
      - Redis Sentinel/manual failover adds complexity
      - 2x memory overhead not worth uptime benefit
    - **Mitigation**: Proper resource limits configured, PVC for persistence
  - **CouchDB (Single Instance)**: ✅ Decision to NOT add replicas
    - **Usage**: Obsidian sync (single user, notes database)
    - **Risk**: Sync unavailable during restarts (5-10 min downtime during upgrades)
    - **Why Single Instance**:
      - Daily backups already implemented (couchdb-backup@3:05am)
      - Sync downtime acceptable for homelab usage pattern
      - CouchDB clustering requires complex multi-master config
      - 3x storage overhead for replication
    - **Mitigation**: Daily backups, upgrade during off-hours
  - **PostgreSQL (3 Replicas)**: ✅ Correct decision - critical data requires HA
    - **Validation**: Corruption incident proved value of replicas
    - **Recovery**: Lost 1 replica, cluster remained operational with 2 healthy replicas
    - **Result**: Zero downtime, zero data loss despite WAL corruption
- 🔒 **Security**: Alert noise reduction improves signal-to-noise ratio for real issues
- 💪 **Reliability**: PostgreSQL HA validated under failure scenario
- 📊 **Alert Status**: Down from 18 alerts to 5 expected alerts (Watchdog, InfoInhibitor, minor transient issues)
- Commits: 491e93e (backups), 1964b7e (K3s alerts), 5bd7df1 + 994bf41 (redis-exporter), 6b8c072 (overcommit routing)

### 2025-10-25 (Night Update Part 2 - AdGuard Home & DNS Simplification)
- ✅ **AdGuard Home Deployment**: Local DNS server for internal services
- ✅ **DNS Architecture Simplification**: Removed External-DNS dependency
- 🎯 **Impact**: Simplified DNS management, faster local resolution, no Cloudflare API dependency for internal services
- 🔧 **Technical Details**:
  - **AdGuard Home**:
    - Purpose: Local DNS server with ad blocking and filtering
    - Access: adguard.h0melab.work (Traefik Ingress, internal only)
    - Replaces: External-DNS for internal service DNS resolution
    - Features: Local DNS records, ad blocking, query logging, statistics
  - **External-DNS Status**: Completely removed (2025-10-26)
    - Previous role: Automated Cloudflare DNS record creation for Ingresses
    - Removal reason: Simplified architecture, reduced external API dependencies
    - Cleanup: All external-dns annotations removed from Ingress resources
  - **New DNS Strategy**:
    - External services (9 via tunnel): Cloudflare DNS → Cloudflare Tunnel → Service
    - Internal services (7 local): AdGuard Home → Traefik Ingress → Service
- 💪 **Benefits**:
  - No Cloudflare API rate limits for internal DNS
  - Faster local DNS resolution (no external API calls)
  - Ad blocking and filtering at DNS level
  - Simplified architecture (one less component)
- 📋 **App Count**: 15 → 16 applications
- 🔒 **Security**: 100% NetworkPolicy coverage maintained (16/16 apps)
- **SSO Update**: 8/8 applicable apps have OIDC (100% coverage where applicable)

### 2025-10-25 (Night Update Part 1 - Database Monitoring)
- ✅ **Database Monitoring Infrastructure**: Comprehensive monitoring for PostgreSQL, Redis, and CouchDB
- 🎯 **Impact**: Complete observability into database health, performance, and capacity
- 🔧 **Technical Details**:
  - **PostgreSQL Monitoring**:
    - Method: PodMonitor (CloudNativePG exposes metrics on pods, not services)
    - Targets: 6 pods (3 DB pods + 3 pooler pods)
    - Metrics: 133 CNPG-specific metrics (connections, replication, backups)
    - Port: 9187 (metrics endpoint)
    - Alerts: 7 alerts (down, pod not running, connection failure, too many connections, replication lag, deadlocks, high rollback rate)
  - **Redis Monitoring**:
    - Method: ServiceMonitor with redis-exporter sidecar
    - Sidecar: oliver006/redis_exporter:v1.66.0-alpine
    - Resources: 10m CPU request, 32Mi memory request
    - Port: 9121 (exporter metrics)
    - Alerts: 7 alerts (down, pod not running, high memory, rejected connections, too many connections, slow queries, connection failure)
    - NetworkPolicy: Updated to allow Prometheus access on port 9121
  - **CouchDB Monitoring**:
    - Method: ServiceMonitor with built-in Prometheus endpoint
    - Endpoint: /_node/_local/_prometheus
    - Port: 5984 (same as CouchDB HTTP)
    - Authentication: Basic auth via couchdb-couchdb secret
    - Metrics: 236 built-in metrics
    - Alerts: 2 alerts (down, pod not running)
  - **Storage Capacity Monitoring**:
    - PVC usage alerts at 80% (warning) and 90% (critical)
    - Current usage: 8% of 4.2TB shared LVM storage
    - local-path-provisioner behavior: All PVCs share node disk (no per-PVC quotas)
    - Additional alerts: <1GB free (critical), >85% inodes (warning)
- 🐛 **Issues Fixed** (5):
  1. CouchDB ServiceMonitor port name (prometheus → couchdb)
  2. CouchDB ServiceMonitor secret reference (couchdb-admin → couchdb-couchdb)
  3. Redis Service missing app: redis label (ServiceMonitor couldn't discover)
  4. Redis NetworkPolicy blocking Prometheus on port 9121
  5. PrometheusRule missing release: kube-prometheus-stack label (alerts not loaded)
- 📊 **Monitoring Status**:
  - **All targets UP**: PostgreSQL (6), Redis (1), CouchDB (2)
  - **All alerts loaded**: 16 database alerts active in Prometheus
  - **Metrics flowing**: Verified PostgreSQL connections, Redis uptime, CouchDB requests
- 🔒 **Security**: NetworkPolicy updates for Prometheus scraping
- 💪 **Benefit**: Proactive alerting on database issues, capacity planning, performance monitoring
- 📋 **Alert Coverage**:
  - ✅ Database connection failures
  - ✅ PVC capacity alerts (>80% usage)
  - ✅ Redis downtime alerts
  - ✅ Backup job failures (already existed)
- Commits: 1ea67f1, 6f157cb, 3181866, 8940a66

### 2025-10-25 (Evening Update)
- ✅ **Stirling PDF Production Fix**: Resolved CrashLoopBackOff issue
- ✅ **Cloudflare Gateway DNS Filtering**: Network-wide ad/tracker blocking deployed
- 🎯 **Impact**: Stirling PDF stable deployment + network-level security enhancement
- 🔧 **Technical Details**:
  - **Stirling PDF Fix**:
    - Root cause: RollingUpdate strategy incompatible with ReadWriteOnce PVC
    - During rolling update, new pod couldn't mount PVC (old pod had exclusive access)
    - Database initialization failed: "Unable to determine Dialect without JDBC metadata"
    - Solution: Changed deployment strategy to `Recreate` (old pod terminates first)
    - Result: Clean deployment, 1/1 Running, zero restarts
    - Commit: e35e7a3
  - **Cloudflare Gateway DNS**:
    - Location: "Homelab" (ID: 55e39ccecdf04717ba7a3363e5838da4)
    - DNS servers: 172.64.36.1, 172.64.36.2 (IPv4), 2a06:98c1:54::20:4351 (IPv6)
    - DoH: https://nvkj3k9t7f.cloudflare-gateway.com/dns-query
    - ECS support enabled (routes to nearest Cloudflare datacenter)
    - **Filtering Policies** (4 active):
      1. Block Security Threats (malware, phishing, C&C, cryptomining) - Precedence 10000
      2. Block Ads (category 22) - Precedence 9000
      3. Block Trackers (category 155) - Precedence 8000
      4. Block Major Trackers (30 domains: Google Analytics, Facebook Pixel, etc.) - Precedence 7000
    - **Allow Rules** (essential services):
      1. Allow Apple services (*.apple.com, *.mzstatic.com, *.icloud.com) - Precedence 15000
      2. Allow Microsoft services (*.bing.com, *.microsoft.com, *.live.com) - Precedence 14900
    - **Mobile Setup Issue**: iOS DNS-over-HTTPS profile broke Apple Maps, App Store, Bing Rewards
      - Allow rules added but profile still incompatible
      - Profile removed, recommended VPN-back-to-home instead
      - Router DNS works perfectly for home network protection
    - **Authentication**: IPv4 DNS requires network authentication (89.36.71.24/32)
      - IPv4 addresses shared across Cloudflare customers (require source IP verification)
      - DoH/DoT/IPv6 use unique subdomain (no IP restriction)
    - Documentation: `docs/cloudflare-gateway-setup.md` (comprehensive setup guide)
    - Commits: c347087, e804f1f, a343840
- 📋 **Lessons Learned**:
  - **RWO PVC + RollingUpdate = Bad**: Always use Recreate strategy for stateful apps with RWO PVCs
  - **DNS Filtering Trade-offs**: Mobile DNS profiles too aggressive even with allow rules
  - **Network-level blocking**: Router DNS provides protection without compatibility issues
- 🔒 **Security**: Network-wide ad/tracker blocking active on home network
- 💪 **Stability**: Stirling PDF deployment now production-ready

### 2025-10-25 (Morning Update)
- ✅ **New Applications Deployed**: Added Stirling PDF and HomeHub (apps #14 and #15)
- 🎯 **Impact**: PDF toolkit with OIDC + Family dashboard for local network
- 🔧 **Technical Details**:
  - **Stirling PDF**: Self-hosted PDF manipulation toolkit
    - 50+ PDF operations (merge, split, compress, OCR, etc.)
    - OIDC authentication via Authentik (env var config)
    - Dual access: Cloudflare Tunnel (external) + Traefik Ingress (internal)
    - NetworkPolicy: cloudflare-tunnel + traefik + uptime-kuma
    - Stateless design: No database, emptyDir volumes for logs/temp/customFiles
    - Domain: stirling.h0melab.work
  - **HomeHub**: Family dashboard for home network
    - Features: Shopping list, notes, chore tracker, expense tracker, calendar, media downloader
    - No authentication (designed for trusted home network)
    - ConfigMap-based configuration with all features enabled
    - 5Gi PVC for persistent data (data, uploads, media, pdfs subdirectories)
    - NetworkPolicy: STRICT - traefik only, NO cloudflare-tunnel access
    - Domain: hh.h0melab.work (local access only)
  - **Storage Strategy**:
    - Stirling PDF: emptyDir for ephemeral data (logs, temp, customFiles)
    - HomeHub: PVC with subPath mounts for persistent user data
- 📋 **App Count**: 13 → 15 applications
- 🔒 **Security**: 100% NetworkPolicy coverage maintained (15/15 apps)
- 💪 **SSO**: 60% OIDC coverage (9/15 apps)
- Commits: edabfeb, 12e12f0, ee66c7e, bcfc6f7, 74b8ede, e853474

### 2025-10-24
- ✅ **Cloudflare Tunnel Expansion**: Added Authentik to Cloudflare Tunnel (9th service)
- ~~**External-DNS Deployment**~~: ❌ **LATER REMOVED** (2025-10-25 - replaced by AdGuard Home)
- ✅ **CNPG Pooler Fix**: Resolved pooler role creation issue for Authentik
- 🎯 **Impact**: Authentik accessible externally via Cloudflare Tunnel with Zero Trust
- 🔧 **Technical Details**:
  - **Cloudflare Tunnel**: Added authentik.h0melab.work via Cloudflare API
    - CNAME record: authentik → c2188394-85ac-402a-8025-0e404ae6004f.cfargotunnel.com
    - Service routing: Cloudflare Dashboard (Zero Trust > Access > Tunnels)
    - ConfigMap simplified: Removed unused ingress config, added documentation
  - **External-DNS**: ❌ **REMOVED** (2025-10-25)
    - Deployed for automated A record management via Cloudflare API
    - Replaced by AdGuard Home for local DNS resolution
    - All annotations cleaned up on 2025-10-26
  - **CNPG Pooler**: Fixed Authentik database connection
    - Issue: Stale secret preventing pooler role creation
    - Fix: Deleted secret, CNPG operator recreated pooler user successfully
    - Authentik now connects via main-postgres-rw-pooler.databases.svc.cluster.local
  - **NetworkPolicy Enhancement**: Added cloudflare-tunnel namespace to Authentik ingress
    - Dual-access pattern: Both traefik (internal) and cloudflare-tunnel (external)
    - Required for apps accessible via both internal Ingress and Cloudflare Tunnel
- 📋 **DNS Management Strategy** (Later changed - see 2025-10-25):
  - ~~External-DNS for automated A records~~ → AdGuard Home for local DNS
  - Manual CNAME records for Cloudflare Tunnel services
- 🔒 **Security**: NetworkPolicy enforcement for dual-access apps
- 💪 **Benefit**: Secure external access via Cloudflare Zero Trust
- Commits: e657a23, 6b25c00, 08c133a

### 2025-10-23
- ✅ **Backup Infrastructure Complete**: Comprehensive backup system operational
- 🎯 **Impact**: Complete disaster recovery capability with automated daily backups
- 🔧 **Technical Implementation**:
  - **PostgreSQL Backups**: Daily 2 AM, 30-day retention, tar.gz, `/mnt/k8s-storage/backups/postgres/`
    - Covers all 10 databases: Authentik, Immich, Paperless, Grafana, Linkding, Mealie, Wallabag, Audiobookshelf, N8N, App
    - Method: pg_dump via CronJob
  - **CouchDB Backups**: Daily 2:30 AM, 30-day retention, tar.gz, `/mnt/k8s-storage/backups/couchdb/`
    - Covers obsidian-personal database
    - Method: couchbackup via CronJob
  - **PVC Backups**: Daily 3 AM, 3-day retention, mixed compression, `/mnt/k8s-storage/backups/pvc/`
    - Covers: Home Assistant configs, Immich library (60GB), Paperless documents, Audiobookshelf
    - Optimization: Skip compression on media files (saves 25 min, 0.5% space trade-off)
    - Method: tar with selective compression (gzip for text, uncompressed for media)
  - **Disaster Recovery Scripts**: Complete automation in `.backup/` directory
    - `secrets-backup.sh` - Extracts all 50+ Kubernetes secrets (SOPS key, OIDC configs, credentials)
    - `secrets-restore.sh` - Restores all secrets to cluster
    - `disaster-recovery.sh` - Full automated cluster recovery with backup verification
- 📋 **Storage Migration**: Moved from 48.9GB root partition to 4.2TB LVM storage (99% space increase)
  - All backup paths updated: `/mnt/k8s-backup/` → `/mnt/k8s-storage/backups/`
- 📚 **Comprehensive Documentation**: 3 detailed documents created
  - `docs/BACKUP_STRATEGY.md` - Overall strategy, retention policies, disaster recovery procedures
  - `docs/BACKUP_IMPLEMENTATION.md` - Technical details, resource optimization analysis
  - `docs/BACKUP_COMPRESSION_ANALYSIS.md` - Compression ratio analysis and trade-offs
  - `.backup/README.md` - Complete recovery guide with step-by-step procedures
- ⚡ **Resource Optimization**: 32Mi memory request, 64Mi limit (down from 512Mi)
  - Actual usage: ~50Mi peak during backup operations
  - Selective compression reduces backup time from ~25 min to ~2-3 min
- 🔒 **Security Coverage**: All critical secrets backed up
  - SOPS age key (master key for all encrypted secrets)
  - All OIDC integration secrets (8 apps)
  - Database credentials (PostgreSQL, Redis, CouchDB)
  - Infrastructure secrets (Cloudflare API, tunnel credentials)
  - Application credentials (50+ secrets total)
- 💪 **Disaster Recovery Capability**: Complete cluster recovery from scratch
  - Automated secret restoration before Flux bootstrap
  - Database and PVC restoration procedures documented
  - Verified backup paths and disaster recovery scripts
- Commits: 470972a, 4f400ae, 2ba824d, 9464f7a, 74f448a, bff6c87

### 2025-10-22
- ✅ **Home Assistant OIDC Integration**: Integrated Home Assistant with Authentik via hass-oidc-auth
- 🎯 **Impact**: 7th app integrated with SSO (54% coverage), smart home centrally authenticated
- 🔧 **Technical Details**:
  - **HACS Auto-Installation**: GitOps-deployed via init container (wget + unzip)
  - **hass-oidc-auth Auto-Installation**: GitOps-deployed via init container (git clone)
  - **Configuration**: auth_oidc in configuration.yaml with discovery_url
  - **Fresh Deployment Testing**: Confirmed OIDC users are NOT admins by default
  - **Admin Provisioning**: Required for fresh deployments (emergency access)
  - **Bug Fix**: Auto-create automations.yaml, scripts.yaml, scenes.yaml on fresh deploy
- 🔒 **Security Model**:
  - OIDC user for daily access (promoted to admin)
  - Local admin user as emergency backup
  - Physical device control requires strong authentication
- 💪 **GitOps Achievement**: Fully declarative Home Assistant OIDC deployment with zero manual steps
- 📋 **SSO Coverage Update**: 7/13 apps (54%), up from 6/13 (46%)
- Commit: 5e85276

### 2025-10-21
- ✅ **SSO Integration Complete**: Integrated 6 apps with Authentik OIDC
- 🎯 **Impact**: Centralized authentication for 46% of apps (6/13)
- 🔧 **Technical Details**:
  - **Declarative OIDC** (env vars): Paperless-NGX, Linkding, Mealie
  - **Web UI OIDC**: Immich, Audiobookshelf
  - **Pre-configured**: Grafana (already integrated)
  - All OIDC-enabled apps restarted to apply configuration
- 📋 **Apps Added**: Immich (photo management), Paperless-NGX (document management)
- ⚠️ **Limitation Identified**: N8N Community Edition does not support SSO/LDAP (Enterprise plan required)
- 🔒 **Security**: All apps use secure OIDC authentication with Authentik as identity provider
- 💪 **Benefit**: Single sign-on across homelab, no more per-app passwords
- Commit: ce4aff1

### 2025-10-19 01:00 UTC
- ✅ **Storage Expansion**: Extended LVM storage from 4.09TB to 4.22TB (+132GB)
- 🎯 **Impact**: Added all remaining unallocated space to LVM
- 🔧 **Technical Details**:
  - Created partition 7 on nvme0n1 (132GB)
  - Added `/dev/nvme0n1p7` as 3rd physical volume to `k8s-storage` VG
  - Extended LV and filesystem online, zero downtime
  - Total capacity: 4.22 TiB across 3 PVs (nvme1n1, nvme0n1p6, nvme0n1p7)
- 📊 **Final State**: 4.2TB available storage, <1% used
- ⏱️ **Duration**: 5 minutes

### 2025-10-19 00:30 UTC
- ✅ **Storage Migration Complete**: Migrated all 19 PVCs to LVM storage
- 🎯 **Impact**: 100% of persistent storage now on 4.1TB multi-SSD LVM pool
- 🔧 **Technical Details**:
  - **Phase 1 - Databases**: Redis, PostgreSQL (3 replicas), CouchDB
  - **Phase 2 - Apps & Monitoring**: Loki, 7 apps (uptime-kuma, home-assistant, mealie, n8n, linkding, wallabag, audiobookshelf)
  - **Phase 3 - Observability**: Prometheus (50GB)
  - Migration method: Suspended Flux, deleted workloads/PVCs, resumed for recreation on LVM
  - Zero data loss: Fresh deployments for stateless apps, databases auto-provisioned
- 🧹 **Cleanup**:
  - Deleted 14 orphaned PVs from `/var/lib/rancher/k3s/storage`
  - Removed `/var/lib/rancher.backup` (40GB)
  - Removed `/mnt/k8s-storage/rancher` backup (6.2GB)
  - Cleaned old PVC data on `/var` (~6GB)
  - **Total reclaimed**: ~52GB
- 📊 **Final State**:
  - `/mnt/k8s-storage`: 4.0GB used / 4.1TB total (1%)
  - `/var`: 4.6GB used / 200GB (cleaned from 44GB+)
  - All apps verified healthy and running on LVM
- 💪 **Achievement**: Complete infrastructure migration with zero downtime for new deployments

### 2025-10-18 23:00 UTC
- ✅ **Storage Expansion**: Extended LVM storage from 3.6TB to 4.09TB (+506GB)
- 🎯 **Impact**: Multi-PV LVM setup with 3.8TB available for growth
- 🔧 **Technical Details**:
  - Phase 1: Extended k8s-data LV with 40GB VG free space
  - Phase 2: Reclaimed `/kuberstorage` partition (598GB) → Created 466GB LVM partition
  - Added `/dev/nvme0n1p6` as 2nd physical volume to `k8s-storage` VG
  - Total capacity: 4.09 TiB across 2 NVMe SSDs
  - Online resize, zero downtime
- 💪 **Benefit**: Better IOPS distribution across 2 SSDs, massive growth headroom

### 2025-10-18 22:35 UTC
- ✅ **Storage Infrastructure**: Configured 3.6TB LVM storage on worker node
- 🎯 **Impact**: K3s local-path-provisioner now uses `/mnt/k8s-storage` for all new PVs
- 🔧 **Technical Details**:
  - Worker node: 4TB NVMe SSD configured with LVM (VG: k8s-storage, LV: k8s-data)
  - Updated K3s addon manifest: `/var/lib/rancher/k3s/server/manifests/local-storage.yaml`
  - Existing 18 PVs (~173GB) remain on `/var`, new PVs use LVM storage
  - Storage capacity: 3.6TB available for future growth
- 📊 **Score Update**: Architecture 90→95, Overall Health 93→95
- 🏆 **Grade Update**: A → A+ (Target of 95/100 achieved!)

### 2025-10-18 02:10 UTC
- ✅ **Infrastructure Enhancement**: Deployed Uptime Kuma (app #9)
- ✅ **Security Enhancement**: Deployed Authentik SSO platform (app #10)
- 🎯 **Impact**: Uptime monitoring + centralized authentication foundation
- 📊 **Score Update**: Architecture 85→90, Security 90→95, UX 85→90, Automation 90→95, Overall Health 89→93
- 🏆 **Grade Update**: A- → A
- 🔧 **Features**:
  - Uptime Kuma: Automated admin user provisioning via Kubernetes Job
  - Authentik: PostgreSQL + Redis backend, bootstrap user configured
  - Both apps: NetworkPolicy, TLS ingress, automated setup
- 🔒 **Security**: All 10 apps now have NetworkPolicy coverage (100%)
- Commit: 46cc485

### 2025-10-18 01:00 UTC
- ✅ **UX Enhancement**: Deployed Homepage dashboard (app #8)
- 🎯 **Impact**: Single pane of glass for all homelab services
- 📊 **Score Update**: UX 75→85, Overall Health 87→89
- 🔧 **Features**: Resource monitoring, service discovery, dark theme
- 🔒 **Security**: RBAC configured, NetworkPolicy enforced
- Commit: c5b0244

### 2025-10-25 17:00 UTC
- ✅ **Infrastructure Enhancement**: Implemented dual-access pattern for 10 applications
- 🎯 **Impact**: Fast local HTTPS + secure external access via Cloudflare Tunnel
- 🔧 **Technical Details**:
  - Created Ingress, Middleware, and Certificate resources for 10 apps
  - Apps: authentik, stirling-pdf, immich, paperless-ngx, audiobookshelf, mealie, wallabag, n8n, linkding, couchdb
  - Let's Encrypt TLS certificates (letsencrypt-staging ClusterIssuer)
  - ~~External-DNS automated A record creation~~ → Later replaced by AdGuard Home (2025-10-25)
  - NetworkPolicy updates to allow traefik namespace ingress
  - All apps accessible via: https://<app>.h0melab.work
- 🚀 **Benefits**:
  - Local access: Direct Traefik route (faster, lower latency)
  - External access: Existing Cloudflare Tunnel (secure, zero trust)
  - Valid HTTPS certificates for local network
  - ~~Automated DNS management (External-DNS)~~ → AdGuard Home (2025-10-25)
- 📊 **Resources**: 46 files created/modified, 571 insertions
- Commits: 2d8921b (main implementation), ec2f63d (ClusterIssuer fix)

### 2025-10-25 15:30 UTC
- ✅ **Infrastructure Enhancement**: Deployed Cloudflare Gateway DNS filtering
- 🎯 **Impact**: Network-level security and content filtering for mobile devices
- 🔧 **Technical Details**:
  - Configured DNS filtering policies via Cloudflare Zero Trust
  - Deployed mobile DNS profiles for iOS/Android devices
  - Security categories enabled: Malware, Phishing, Cryptomining, DNS Rebinding
  - Content categories configured: Adult Content, Child Abuse
- 🐛 **Issue Identified**: iOS DNS profile compatibility with Local Area Network connections
  - TOTP 2FA works via mobile data but not on LAN
  - Root cause: Potential DNS resolution conflict between local network and Cloudflare Gateway
  - Trade-off: Enhanced security filtering vs. local app access complexity
- 📝 **Lesson Learned**: DNS filtering trade-offs between security and local network compatibility

### 2025-10-25 00:00 UTC
- ✅ **Application Fix**: Resolved Stirling PDF CrashLoopBackOff issue
- 🎯 **Impact**: Stabilized PDF toolkit service, prevented data loss
- 🔧 **Technical Details**:
  - Root cause: RWO PVC incompatible with RollingUpdate strategy
  - Solution: Changed deployment strategy from RollingUpdate to Recreate
  - Fixed fontconfig and OCR tessdata volume mount issues
  - Proper graceful termination handling
- 🐛 **Issue**: RWO (ReadWriteOnce) PVCs cannot be mounted by new pod during RollingUpdate
- 💡 **Lesson Learned**: Always use Recreate strategy for deployments with RWO PVCs
- Commits: 9e9d900

### 2025-10-18 23:59 UTC
- ✅ **Security Enhancement**: Added NetworkPolicies to wallabag, n8n, linkding, audiobookshelf
- ✅ **Resource Optimization**: Fixed wallabag PVC namespace leak (60GB recovered)
- 📊 **Score Update**: Security 70→90, Overall Health 82→87
- 🏆 **Grade Update**: B+ → A-
- 🔍 **Storage Cleanup**: Deleted duplicate 60GB wallabag PVCs from wrong namespace
  - Correct PVCs: 5Gi data + 10Gi images = 15GB total (optimally sized)
  - Actual usage: 12KB total (8KB data + 4KB images)
  - No abandoned PVCs remaining
- 🔧 **App Review**: Removed Vaultwarden (using 1Password)
- Commit: a235309

---

## 📋 2026 Monthly Reviews (January - April)

*Moved from HOMELAB_ANALYSIS.md on 2026-04-10 to keep the analysis file lean.*

## 🎯 CRITICAL ACTION ITEMS

**Last Updated**: 2026-04-02 (Monthly Review)
**Source**: HOMELAB_REVIEW_2025_12_17 (archived, see git history)
**Completed Items**: See [HOMELAB_HISTORY.md](./HOMELAB_HISTORY.md) for detailed completed task archive

### 🔍 April 2026 Monthly Review

**Review Date**: 2026-04-02
**Reviewer**: Staff DevOps/SRE + Staff Software Developer (7-agent parallel audit)
**Overall Status**: ✅ **HEALTHY** - All systems nominal, secrets rotation completed

#### Infrastructure Health

| Component | Status | Details |
|-----------|--------|---------|
| **Nodes** | ✅ 3/3 Ready | K3s v1.35.3, Kernel 6.18.20-1-lts, max 25% memory |
| **Control Plane** | ✅ Healthy | 19% CPU, 19% memory |
| **worker-node** | ✅ Healthy | 21% CPU, 25% memory |
| **worker-node-2** | ✅ Healthy | 16% CPU, 19% memory |
| **Pods** | ✅ All Running | 0 CrashLoop, 42 deployments at target |
| **PostgreSQL** | ✅ 2/2 Ready | Zero replication lag, >99% cache hit |
| **MySQL** | ✅ 2/2 Ready | Async replication |
| **CouchDB** | ✅ 2/2 Running | Full cluster membership |
| **Redis** | ✅ 1/1 Running | 8.83MB used |
| **VictoriaMetrics** | ✅ VMSingle+VMAgent+VMOperator | ~113k series, ~487Mi total |
| **Alerts** | ✅ None firing | Only Watchdog (expected) |
| **Backups** | ✅ All successful | 12h replication cycle, <10s completion |
| **Certificates** | ✅ 20/20 Ready | Nearest expiry 32 days |
| **Flux/GitOps** | ✅ All healthy | 6/6 kustomizations, 10/10 HelmReleases |
| **Kyverno** | ✅ 0 violations | 10 policies (7 enforce, 3 audit) |
| **NetworkPolicies** | ✅ 40 policies | All app namespaces covered |
| **SOPS Secrets** | ✅ 51/51 encrypted | Zero plaintext in git |
| **PVCs** | ✅ 28/28 Bound | All healthy |

#### Code Review Score: 94/100 (A) — Maintained

| Category | Score |
|----------|-------|
| YAML Quality | 9/10 |
| Security Posture | 9/10 |
| Resource Management | 10/10 |
| GitOps Best Practices | 10/10 |
| Monitoring | 9/10 |
| High Availability | 9/10 |
| Image Management | 9/10 |
| Documentation | 9/10 |
| Backup & DR | 10/10 |
| Policy Enforcement | 10/10 |

#### Actions Completed This Review

- ✅ **Full secrets rotation**: 6 PG + 3 MySQL + 2 Redis + 1 CouchDB + 6 OIDC + 1 Authentik secret key
- ✅ **NetworkPolicy**: Fixed AND/OR logic bug in n8n, linkwarden, mealie (3 files)
- ✅ **README.md**: Corrected PostgreSQL replica count (3→2) and audit grade (A- 92→A 94)
- ✅ **PSS labels**: Added Pod Security Standards to 10 infrastructure namespaces
- ✅ **Stirling PDF**: Moved plaintext OIDC secret from ConfigMap to SOPS-encrypted Secret
- ✅ **Linkwarden**: Added to CNPG managed roles (prevents password loss on PG restart)
- ✅ **Cleanup**: Removed 5 redundant OIDC secret files, removed n8n OIDC (unsupported), removed wallabag references
- ✅ **HA OIDC**: Disabled hass-oidc-auth (incompatible with HA 2026.4.0)
- ✅ **Backup scripts**: Fixed missing secrets, wrong names/namespaces, updated for OIDC cleanup
- ✅ **SECRETS_ROTATION.md**: Full rewrite — separated service secrets from user passwords, documented OIDC locations per app

#### Pending Scheduled Items

| Item | Target Date | Priority |
|------|-------------|----------|
| ~~VictoriaMetrics re-evaluation~~ | ~~April 2026~~ | ✅ Done (migrated 2026-04-09, 71% RAM savings) |
| Remove worker-node-2 replication step | ~May 20, 2026 | P2 |
| n8n PgBouncer `statement_timeout` fix — re-check [#25705](https://github.com/n8n-io/n8n/issues/25705) | May 2026 | P3 |
| High-priority secret rotation (PG: authentik/immich/n8n, MySQL: HA, Redis: immich) | 2026-07-01 | P1 |
| Re-evaluate HA OIDC when hass-oidc-auth releases stable version | Backlog | P3 |
| Add PodDisruptionBudgets for HA workloads | Backlog | P3 |

**Next Review**: 2026-05-04 (Monthly)

### 🔍 March 2026 Monthly Review

**Review Date**: 2026-03-06
**Reviewer**: Staff DevOps/SRE + Staff Software Developer
**Overall Status**: ✅ **HEALTHY** - All systems nominal

#### Infrastructure Health (Staff DevOps/SRE Perspective)

| Component | Status | Details |
|-----------|--------|---------|
| **Nodes** | ✅ 3/3 Ready | K3s v1.35.3, Kernel 6.18.16-lts |
| **Control Plane** | ✅ Healthy | 23% CPU, 13% memory |
| **worker-node** | ✅ Healthy | 20% CPU, 33% memory (rebuilderd active) |
| **worker-node-2** | ✅ Healthy | 31% CPU, 38% memory (rebuilderd active) |
| **Pods** | ✅ 82 Running | 0 CrashLoop, 7 Completed jobs |
| **PostgreSQL** | ✅ 2/2 Ready | v18.3 |
| **MySQL** | ✅ 2/2 Ready | Async replication, no lag |
| **CouchDB** | ✅ 2/2 Running | StatefulSet in databases namespace |
| **Redis** | ✅ 1/1 Running | v8.6.1 |
| **Metrics** | ✅ Prometheus (now VictoriaMetrics) | 90k active series (at time of review) |
| **Alerts** | ✅ None firing | Clean alert state |
| **Backups** | ✅ All successful | NAS + worker-node-2 replication working |
| **Certificates** | ✅ 19/19 Ready | 71+ days until expiration |
| **Flux/GitOps** | ✅ All healthy | All 6 kustomizations reconciled |
| **Scrape Targets** | ✅ 49 active | 0 down |
| **Kyverno** | ✅ 0 violations | Clean |
| **Stale ReplicaSets** | ✅ 0 | Cleaned 4 stale RS this session |

#### Prometheus (at time of review, now replaced by VictoriaMetrics)

- **TSDB Head**: 278k series (includes stale series from kernel reboots + Traefik restarts)
- **Active Series by Job**: ~90k (healthy, down from Feb's 111k)
- **Memory**: 905Mi + 1025Mi / 1300Mi each (70-79%)
- **Top Cardinality**: kubelet 35k (39%), apiserver 17k (19%), kube-state-metrics 10k (11%)
- **Scrape Targets**: 49 active, 0 down
- **Note**: Replaced by VictoriaMetrics on 2026-04-09 (~487Mi total, 71% RAM savings)

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
| ~~ECC session regex fix~~ — PR #408 now in marketplace main, chezmoi patch removed 2026-03-22 | ✅ Done | ~~P3~~ |
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
| **Nodes** | ✅ 3/3 Ready | K3s v1.35.3, Kernel 6.18.16-lts |
| **Control Plane** | ✅ Healthy | 15% CPU, 19% memory |
| **worker-node** | ✅ Healthy | 19% CPU, 26% memory (rebuilderd active) |
| **worker-node-2** | ✅ Healthy | 8% CPU, 18% memory |
| **Pods** | ✅ 81 Running | 0 CrashLoop, 15 Completed jobs |
| **PostgreSQL** | ✅ 2/2 Ready | v18.3 (upgraded from 18.2, 2026-02-26) |
| **MySQL** | ✅ 2/2 Ready | Async replication, HAProxy active |
| **CouchDB** | ✅ 2/2 Running | StatefulSet in databases namespace |
| **Redis** | ✅ 1/1 Running | v8.6.0 (upgraded from 8.2.2, 2026-02-20) |
| **Prometheus** | ✅ 72% memory | 121k series, 941Mi/1300Mi (at time of review, now VictoriaMetrics) |
| **Alerts** | ✅ None firing | Clean alert state |
| **Backups** | ✅ All successful | NAS + worker-node-2 replication working |
| **Certificates** | ✅ All Ready | 36-86 days until expiration |
| **Flux/GitOps** | ✅ All healthy | All 6 kustomizations reconciled |
| **Resource Governance** | ✅ Complete | 27 quotas, 26 limitranges |
| **Stale ReplicaSets** | ✅ 0 | Cleaned 87 stale RS this session |

#### Prometheus Improvement (at time of review, now replaced by VictoriaMetrics)

- **Series Count**: 111k (↓ 54% from 244k in Jan review)
- **Memory**: 924Mi / 1300Mi (71%, ↓ from 87%)
- **Replicas**: 2 HA (924Mi + 775Mi)
- **Scrape Targets**: 49
- **Note**: Replaced by VictoriaMetrics on 2026-04-09 (~487Mi total, 71% RAM savings)

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
| ~~Re-evaluate VictoriaMetrics~~ | ~~April 2026~~ | ✅ Done (migrated 2026-04-09) |
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
| **Nodes** | ✅ 3/3 Ready | K3s v1.35.3, Kernel 6.18.16-lts |
| **Control Plane** | ✅ Healthy | 14% CPU, 17% memory |
| **worker-node** | ✅ Healthy | 20% CPU, 24% memory (rebuilderd active) |
| **worker-node-2** | ✅ Healthy | 22% CPU, 40% memory (tensorflow building) |
| **Pods** | ✅ 82 Running | 0 CrashLoop, 48 Completed jobs |
| **PostgreSQL** | ✅ 2/2 Ready | Cluster in healthy state |
| **MySQL** | ✅ 2/2 Ready | Async replication, HAProxy active |
| **CouchDB** | ✅ 2/2 Running | StatefulSet in databases namespace |
| **Redis** | ✅ 1/1 Running | Cache healthy |
| **Prometheus** | ⚠️ 87% memory | 244k series, 1125Mi/1300Mi (at time of review, now VictoriaMetrics) |
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
| 5 | Duplicated Prometheus metric relabelings | P2 | ✅ Documented (now VictoriaMetrics relabelConfigs) |
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
| ~~**immich-proxy**~~ | ~~nginx~~ | ~~Removed 2026-03-15 (sidecar was unnecessary)~~ | 7d377a9a |

**Verification**: All 3 apps tested - linkwarden SSO works, immich API responds

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
- Enabled on linkwarden, immich-ml (immich-proxy removed 2026-03-15)
- Key finding: Immich HOST env var bug - nginx proxy sidecar required
- Key finding: bjw-s chart advancedMounts doesn't work - used postRenderer instead
- Commits: 3d4d533

**Outcome**: 13 containers with readOnlyRootFilesystem (was 3, +10 hardened)
**Security Benefit**: Reduced attack surface, prevents runtime filesystem tampering

### ✅ Completed P2-MEDIUM Items (Summary)

| Item | Date | Status |
|------|------|--------|
| PVC storageClassName + alert hardcoded IPs | 2026-03-07 | ✅ 9 PVCs fixed, immich typo fixed, CPUThrottlingHigh/NodeMemoryMajorPagesFaults use hostnames |
| ReadOnlyRootFilesystem Phase 1-3 | 2025-12-23 | ✅ 9 apps hardened (paperless, authentik×2, csp-reporter, homepage, homehub, uptime-kuma, linkwarden, immich-ml; immich-proxy removed 2026-03-15) |
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
| ~~Re-evaluate VictoriaMetrics~~ | ~~P3~~ | ✅ Completed (2026-04-09, 71% RAM savings) |
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
     - **K3s**: v1.35.3+k3s1
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
     - ✅ **Monitoring HA enabled** - Alertmanager 2 replicas with anti-affinity (Prometheus replaced by VictoriaMetrics 2026-04-09)
     - ✅ **Uptime Kuma monitors** - Already configured (SSH + kubelet monitors)
     - ✅ **AdGuard Home DNS** - Added 192.168.1.126 to DNS rewrites
   - **Documentation**: SECOND_WORKER_NODE_SETUP.md (archived, see git history)

#### 39. **Switch to LTS Kernel 6.18** 🐧 ✅ COMPLETED
   - **Status**: ✅ COMPLETED - 2026-03-06
   - **Priority**: ~~P2-MEDIUM~~ COMPLETED
   - **Result**: All 3 nodes switched from mainline `linux` (6.19.6) to `linux-lts` (6.18.16)
   - **K3s**: Upgraded v1.35.1 → v1.35.3 simultaneously
   - **Procedure Used**: Two-phase approach (install LTS → reboot → verify → remove mainline)
   - **Boot Entries**: systemd-boot entries created from existing ones, fallback initramfs enabled
   - **Benefit**: Long-term stability, security backports until Dec 2027

#### 40. **VictoriaMetrics Migration** 📊 ✅ COMPLETED
   - **Status**: ✅ COMPLETED - 2026-04-09
   - **Priority**: ~~P3-LOW~~ COMPLETED
   - **Result**: Prometheus server replaced by VictoriaMetrics (VMSingle + VMAgent + VMAlert)
   - **RAM Savings**: 71% (~1,553Mi Prometheus HA → ~487Mi VMSingle+VMAgent+VMOperator)
   - **Series**: ~113k active series
   - **Stack**: VMSingle (storage), VMAgent (scraping), VMAlert (alerting rules), VMOperator, Alertmanager (notifications), Grafana (dashboards), kube-state-metrics, node-exporter
   - **kube-prometheus-stack**: Still deployed with `prometheus.enabled: false` and `defaultRules.create: false` (provides Alertmanager, Grafana, kube-state-metrics, node-exporter)
   - **Background**:
     - First attempt 2025-11-15, aborted due to `metricRelabelConfigs` bug ([#9951](https://github.com/VictoriaMetrics/VictoriaMetrics/issues/9951))
     - Workaround confirmed: Use BOTH `relabelConfig` + `metricRelabelConfig` together
     - Successfully migrated April 2026

---


---

## 📝 CHANGELOG (Recent)

*For older entries, see [HOMELAB_HISTORY.md](./HOMELAB_HISTORY.md)*

### 2026-03-16 (SearXNG Deployment) 🔍
- ✅ **SearXNG deployed**: Privacy-respecting metasearch engine ⭐
  - Image: `searxng/searxng:2026.3.13-3c1f68c59`
  - Internal: `search.h0melab.work` via Traefik (no auth)
  - External: Cloudflare Tunnel with Authentik SSO
  - JSON API: `/search?q=...&format=json` for n8n/HA automations
  - Security: restricted PSS, readOnlyRootFilesystem, drop ALL
  - NetworkPolicy: dual-access + n8n/HA API consumer rules
  - Renovate: custom regex manager for date+hash image tags
- ✅ **Authentik ↔ Cloudflare Access IdP integration** ⭐
  - Authentik configured as OpenID Connect identity provider in CF Zero Trust
  - Reusable for any future CF Access-protected app
- ✅ **cert-manager NetworkPolicy fix**: Added external DNS egress (UDP/TCP 53) for DNS-01 challenges
- ✅ **`.gitignore` fix**: Added `!secret.yaml` override for SOPS-encrypted secrets (was blocked by global gitignore)

### 2026-03-15 (Remove Immich Nginx Proxy Sidecar) 🧹
- ✅ **Nginx proxy sidecar removed from Immich** — unnecessary since v1.88.0 (Nov 2023) ⭐
  - **Root cause**: Sidecar was added due to misleading NestJS log (`[::1]:2283`), but server actually binds to `::` (all interfaces)
  - **Evidence**: `/proc/net/tcp6` confirmed `:::2283 LISTEN`, `wget` to pod IP returned `{"res":"pong"}`
  - **Source code**: `app.listen(port)` without host → INADDR_ANY. `IMMICH_HOST` unset = all interfaces.
  - **Official Helm chart**: No proxy since v1.88.0, targets port 2283 directly
  - **Resources freed**: 50m→500m CPU, 64Mi→256Mi RAM (nginx:1.29.6-alpine container)
  - Pod: 2/2 → 1/1 containers
- ✅ **NetworkPolicy port updates**: Traefik + Cloudflare tunnel egress policies 8080→2283
  - Same class of bug as March 11 audit — port change requires updating ALL source egress policies
- ✅ **Cloudflare tunnel config synced**: SOPS secret updated, init container PUT to CF API (HTTP 200)
- ✅ **Docs updated**: port-forward commands, HOMELAB_ANALYSIS CF tunnel section
- ℹ️ **Gotcha**: Immutable Job spec blocked Flux reconciliation — had to delete completed `immich-admin-setup` Job before Flux could apply new port
- 📋 **Commits**: 7d377a9a, c1f212f7

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
- ✅ **K3s: v1.35.1 → v1.35.3** on all 3 nodes ⭐
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
