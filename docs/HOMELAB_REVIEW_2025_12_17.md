# Homelab Comprehensive Review - December 17, 2025

**Review Date**: 2025-12-17 23:00 UTC
**Reviewer**: Claude (Staff DevOps Engineer)
**Previous Review**: 2025-10-27 ([COMPREHENSIVE_CODEBASE_REVIEW.md](./COMPREHENSIVE_CODEBASE_REVIEW.md))

---

## Executive Summary

### Overall Assessment: **B+ (Good with Significant Gaps)**

The homelab has undergone significant changes since the last review, including:
- Addition of **worker-node-2** (3rd node in cluster)
- Migration from **MariaDB to MySQL** (Percona Operator)
- PostgreSQL reduced from 3 to 2 replicas

However, several critical issues require attention:
- **Documentation severely out of sync** with actual cluster state
- **HA not leveraged** despite having 3 nodes
- **Monitoring gaps** - Prometheus/Alertmanager/Loki all single-instance
- **Kyverno violations** returned (22 violations)
- **Popeye score dropped** from 100 to 87

---

## Cluster State Snapshot

### Nodes (3 total)
| Node | Role | CPU | RAM | Storage | Status |
|------|------|-----|-----|---------|--------|
| gmk-k3s-control-plane | control-plane | 18% | 2.6GB/16GB | N/A | Healthy |
| worker-node | worker | 1% | 11.5GB/61GB | 4.2TB LVM (18% used) | Healthy |
| worker-node-2 | worker | 2% | 4.8GB/30GB | 3.6TB LVM (1% used) | Healthy, **NO SWAP** |

### Pod Distribution
- **worker-node**: 48 pods
- **worker-node-2**: 31 pods
- **gmk-k3s-control-plane**: 13 pods (system only)

### K3s Version
- All nodes: **v1.34.2+k3s1**
- CA Certificate: Valid until **October 5, 2035**

---

## Critical Findings

### P0 - CRITICAL (Immediate Action Required)

#### 1. Documentation Severely Out of Sync
| Item | Documentation Says | Actual State | Impact |
|------|-------------------|--------------|--------|
| Worker nodes | "Single worker node" | **3 nodes** | Misleading for DR planning |
| PostgreSQL | "3-node HA" | **2 replicas** | Incorrect capacity planning |
| Popeye score | "100/100" | **87/100** | False confidence |
| Kyverno violations | "0 violations" | **22 violations** | Security posture incorrect |
| Second worker | "Planned Jan 2026" | **Already deployed 2d ago** | Task tracking broken |
| App count | "16 apps" | Needs recount | Inventory incorrect |

**Action**: Update HOMELAB_ANALYSIS.md immediately

#### 2. worker-node-2 Has No Swap
- **Risk**: OOM killer will terminate pods under memory pressure
- **Current RAM**: 30GB (half of worker-node's 61GB)
- **Impact**: Node could become unstable under heavy load
- **Action**: Add swap partition or file (8-16GB recommended)

#### 3. Stale MariaDB Backup Directory
- Location: `/mnt/k8s-storage/backups/mariadb`
- **Issue**: MariaDB migrated to MySQL on 2025-12-16
- **Risk**: Stale backups consuming space, confusion during DR
- **Action**: Archive and remove after confirming MySQL backups working

---

### P1 - HIGH (Address This Week)

#### 4. HA Not Enabled for Critical Infrastructure
Now that 3 nodes exist, these should be HA but aren't:

| Component | Current | Recommended | Node Distribution |
|-----------|---------|-------------|-------------------|
| Prometheus | 1 replica | 2 replicas | worker-node only |
| Alertmanager | 1 replica | 2 replicas | worker-node only |
| Loki | 1 replica | 2 replicas | worker-node only |
| Redis | 1 replica | 2 (+ Sentinel) | worker-node only |
| Meilisearch | 1 replica | 2 replicas | worker-node only |
| Grafana | 1 replica | 2 replicas | worker-node only |

**Risk**: Single point of failure; maintenance window = service outage
**Action**: Enable HA with anti-affinity for critical components

#### 5. Kyverno Violations Returned (22 total)
- **Policy**: `require-resource-limits`
- **Status**: Documentation claims 0 violations (2025-12-13)
- **Likely cause**: New pods created without limits after Percona MySQL deployment
- **Action**: Audit and fix resource limits on violating pods

#### 6. Popeye Score Dropped (87/100)
**Issues Found**:
- Orphaned ClusterRoleBindings referencing non-existent ServiceAccounts:
  - `databases/mariadb` (MariaDB removed)
  - `flux-system/image-reflector-controller` (never installed)
  - `flux-system/image-automation-controller` (never installed)
  - `flux-system/source-watcher` (never installed)

**Action**: Clean up orphaned RBAC resources

#### 7. ContainerMemoryNearLimit Alert Active
- **Pod**: `pricebuddy/pricebuddy-8676596947-gq7jx`
- **Container**: apprise sidecar
- **Usage**: 185Mi / 210Mi limit (88%)
- **Action**: Increase apprise memory limit to 300Mi

#### 8. MySQL HAProxy Missing Anti-Affinity
- Both HAProxy replicas could schedule on same node
- **Risk**: Single node failure takes out MySQL proxy layer
- **Action**: Add required podAntiAffinity to HAProxy StatefulSet

---

### P2 - MEDIUM (Address This Month)

#### 9. PVC Distribution Imbalanced
- **worker-node**: ~25 PVCs (including large ones: immich 300Gi, paperless 100Gi, prometheus 50Gi)
- **worker-node-2**: 4 PVCs only (postgres, couchdb, mysql replicas)
- **Issue**: New apps still default to worker-node
- **Action**: Consider migrating some PVCs to worker-node-2 for balance

#### 10. No HorizontalPodAutoscalers Deployed
- All scaling is manual
- **Opportunity**: Add HPA for bursty workloads (immich, n8n, pricebuddy)

#### 11. Resource Governance Slightly Reduced
- **Documentation**: 25 ResourceQuotas, 25 LimitRanges
- **Actual**: 23 ResourceQuotas, 22 LimitRanges
- **Action**: Audit which namespaces are missing governance

#### 12. Percona Operator Has No Resource Limits
- `percona-mysql/ps-operator-6954b485c-8clvw` has no limits
- Violates `require-resource-limits` policy
- **Action**: Add limits via HelmRelease values

---

### P3 - LOW (Address When Convenient)

#### 13. Cleanup Opportunities
- Remove stale Flux ClusterRoleBindings for image-automation controllers
- Remove mariadb-related RBAC resources
- Clean up old mariadb backup directory

#### 14. Monitoring Enhancements
- Add Grafana dashboard for MySQL (new database)
- Add PrometheusRules for MySQL alerts (if not already present)
- Review Telegram alert grouping

#### 15. Code Pattern Inconsistencies
From codebase exploration:
- Certificate definitions inconsistent (some in base/, some in staging/)
- Secret naming not standardized across apps
- Some kustomization.yaml files set namespace globally, others don't

---

## Architecture Review

### Strengths
1. **GitOps Foundation**: Solid Flux-based GitOps with proper dependency ordering
2. **Security Layers**: NetworkPolicies, Kyverno, SOPS, TLS everywhere
3. **Database HA**: PostgreSQL (CNPG) and MySQL (Percona) both HA with anti-affinity
4. **Backup Coverage**: All databases backed up daily with checksums
5. **Secret Management**: SOPS/age encryption working well
6. **Certificate Management**: cert-manager with Let's Encrypt, all certs valid

### Weaknesses
1. **Documentation Drift**: Significant gap between docs and reality
2. **Monitoring SPOF**: Entire observability stack on single node
3. **No HPA**: All scaling manual
4. **Storage Imbalance**: Most PVCs on worker-node despite worker-node-2 having 3.6TB available

### Recommendations
1. **Enable monitoring HA**: Prometheus, Alertmanager, Loki should have 2 replicas
2. **Add swap to worker-node-2**: Prevent OOM issues
3. **Implement HPA**: At least for immich, pricebuddy (memory-intensive apps)
4. **Standardize code patterns**: Create templates for new apps
5. **Regular documentation sync**: Add to monthly checklist

---

## Storage Analysis

### worker-node (Primary Storage)
```
LVM: k8s-storage VG (3 PVs, 4.22TB total)
Usage: 693GB / 4.2TB (18%)
Backups: /mnt/k8s-storage/backups/
  - postgres/  (47 days of backups)
  - mysql/     (12 days of backups)
  - couchdb/   (active)
  - pvc/       (11 days of backups)
  - mariadb/   (STALE - migrate removed)
```

### worker-node-2 (Secondary Storage)
```
LVM: k8s-storage VG (1 PV, 3.6TB)
Usage: 1.3GB / 3.4TB (1%)
Content: Database replicas only (postgres, couchdb, mysql)
Backups: None (no backup directory)
```

**Recommendation**: Consider setting up backup replication to worker-node-2 as interim solution before NAS arrives.

---

## Security Audit

### Positive Findings
- 63/92 pods (68%) have seccomp RuntimeDefault
- 70/92 pods (76%) running as non-root
- All 17 ingresses have security headers middleware
- 29 NetworkPolicies in place
- All certificates valid (earliest expiry: Jan 17, 2026)

### Negative Findings
- 22 Kyverno violations (resource limits policy)
- Percona operator pod has no resource limits
- Documentation says 0 violations but 22 exist

---

## Action Plan

### Phase 1: Immediate (Today/Tomorrow)
1. [ ] Update HOMELAB_ANALYSIS.md with correct cluster state
2. [ ] Fix pricebuddy apprise memory limit (210Mi -> 300Mi)
3. [ ] Archive and remove stale mariadb backup directory

### Phase 2: This Week
4. [ ] Add swap to worker-node-2 (8-16GB)
5. [ ] Clean up orphaned RBAC (mariadb, flux image controllers)
6. [ ] Audit and fix 22 Kyverno violations
7. [ ] Add resource limits to Percona operator

### Phase 3: Next 2 Weeks
8. [ ] Enable Prometheus HA (2 replicas)
9. [ ] Enable Alertmanager HA (2 replicas)
10. [ ] Enable Loki HA (2 replicas)
11. [ ] Add anti-affinity to MySQL HAProxy
12. [ ] Audit ResourceQuota/LimitRange coverage

### Phase 4: This Month
13. [ ] Consider Redis HA (evaluate complexity vs benefit)
14. [ ] Review PVC distribution strategy
15. [ ] Add HPA for memory-intensive apps
16. [ ] Standardize code patterns across apps

---

## Metrics Summary

| Metric | Previous (Oct 27) | Current (Dec 17) | Trend |
|--------|-------------------|------------------|-------|
| Popeye Score | 100/100 | 87/100 | Down |
| Kyverno Violations | 0 | 22 | Up (bad) |
| Nodes | 2 | 3 | Up (good) |
| PostgreSQL Replicas | 3 | 2 | Down |
| Total Pods | ~60 | 92 | Up |
| Storage Used | ~500GB | 693GB | Up |
| NetworkPolicies | 16 | 29 | Up (good) |
| Certificates | All valid | All valid | Stable |

---

## Next Review

**Scheduled**: 2026-01-15 (HSTS Step 3 rollout date)

**Focus Areas**:
- HSTS max-age increase to 1 year
- HA status for monitoring stack
- NAS arrival and offsite backup setup
- Kyverno violation count

---

*Document created: 2025-12-17 23:00 UTC*
*Reference from: HOMELAB_ANALYSIS.md*
