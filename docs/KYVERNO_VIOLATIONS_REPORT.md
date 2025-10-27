# Kyverno Policy Violations Report

**Report Date:** 2025-10-27
**Total Violations:** 89 across 13 namespaces
**Mode:** Audit (non-blocking)

---

## Executive Summary

### Violation Breakdown by Policy Type

| Policy | Violations | Severity | Affected Namespaces |
|--------|-----------|----------|---------------------|
| require-resource-limits | 61 | Medium | monitoring(22), loki(7), trivy-system(6), immich(4), home-assistant(4), audiobookshelf(4), databases(4), uptime-kuma(3), obsidian(2), n8n(2) |
| require-non-root | 18 | High | adguard-home(11), loki(4), wallabag(7), uptime-kuma(2) |
| disallow-host-path | 10 | Medium | databases(4), couchdb(2) |

### Top Violators by Namespace

1. **Monitoring** - 22 violations (all resource limits)
2. **Databases** - 12 violations (8 resource limits, 4 hostPath)
3. **Loki** - 11 violations (7 resource limits, 4 non-root)
4. **AdGuard Home** - 11 violations (all non-root)
5. **Wallabag** - 7 violations (all non-root)

---

## Priority Classification

### 🔴 P0-CRITICAL (High Severity + Easy Fix)

**None** - All high-severity violations are in expected places (databases, system namespaces)

### 🟠 P1-HIGH (Quick Wins - Easy to Fix)

1. **Monitoring namespace resource limits** (22 violations)
   - Issue: Prometheus stack components missing resource limits
   - Impact: Potential resource exhaustion
   - Effort: 1-2 hours
   - Fix: Add limits to monitoring Helm values

2. **AdGuard Home non-root** (11 violations)
   - Issue: Running as root unnecessarily
   - Impact: Security risk
   - Effort: 30 minutes
   - Fix: Add runAsUser to deployment

3. **Trivy System resource limits** (6 violations)
   - Issue: Scan jobs missing resource limits
   - Impact: Moderate
   - Effort: 30 minutes
   - Fix: Already configured in HelmRelease, may need tuning

### 🟡 P2-MEDIUM (More Complex)

4. **Loki resource limits & non-root** (11 violations)
   - Issue: Loki pods missing limits and running as root
   - Impact: Moderate
   - Effort: 1 hour
   - Fix: Update Loki Helm values

5. **Wallabag non-root** (7 violations)
   - Issue: Running as root
   - Impact: Security risk
   - Effort: 30 minutes
   - Fix: Already has runAsUser configured, may be init containers

6. **Databases hostPath** (4 violations)
   - Issue: PostgreSQL using hostPath for data
   - Impact: Low (intentional for persistence)
   - Effort: N/A
   - Fix: **WONTFIX** - Required for local storage

7. **CouchDB hostPath** (2 violations)
   - Issue: Using hostPath
   - Impact: Low (intentional for persistence)
   - Effort: N/A
   - Fix: **WONTFIX** - Required for local storage

### 🟢 P3-LOW (Minor Issues)

8. **Application resource limits** (immich, home-assistant, audiobookshelf, uptime-kuma, obsidian, n8n)
   - Issue: Missing resource limits on some containers
   - Impact: Low (apps already have some limits)
   - Effort: 2-3 hours total
   - Fix: Add limits to remaining containers

---

## Recommended Actions

### Phase 1: Quick Wins (This Week)

1. ✅ **Add policy exclusions for intentional violations**
   - Exclude databases namespace from hostPath policy
   - Exclude CouchDB from hostPath policy
   - Already excluded: mealie, home-assistant from non-root

2. 🎯 **Fix Monitoring resource limits**
   - Add CPU/memory limits to Prometheus components
   - Update kube-prometheus-stack Helm values

3. 🎯 **Fix AdGuard Home non-root**
   - Add securityContext with runAsUser

### Phase 2: Security Hardening (Next Week)

4. 🎯 **Fix Loki configuration**
   - Add resource limits
   - Configure non-root execution

5. 🎯 **Review Wallabag security context**
   - Verify init containers are non-root
   - Update if needed

### Phase 3: Comprehensive Coverage (Next 2 Weeks)

6. 🎯 **Add resource limits to remaining apps**
   - Immich, Home Assistant, Audiobookshelf
   - Uptime Kuma, Obsidian, n8n

7. 🎯 **Consider switching to Enforce mode**
   - Start with require-resource-limits on new deployments
   - Gradually enable other policies

---

## Policy Exclusion Updates Needed

```yaml
# disallow-host-path.yaml - Add to exclude section
- resources:
    namespaces:
      - databases  # PostgreSQL data persistence
      - couchdb    # CouchDB data persistence
```

---

## Metrics to Track

- [ ] Violations reduced from 89 to <30 (Phase 1)
- [ ] All P1-HIGH violations resolved
- [ ] Resource limits on all production apps
- [ ] At least 1 policy in Enforce mode

---

## Notes

- **WONTFIX violations:** 10 (hostPath in databases/couchdb - required)
- **Fixable violations:** 79
- **Target:** Reduce to <30 violations by end of week
- **Enforcement strategy:** Keep in Audit mode until <10 violations
