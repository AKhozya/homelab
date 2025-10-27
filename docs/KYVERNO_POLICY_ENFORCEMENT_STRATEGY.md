# Kyverno Policy Enforcement Strategy

**Document Date:** 2025-10-27
**Total Policies:** 7
**Current Mode:** All policies in Audit mode
**Total Violations:** 105 across 23 namespaces

---

## Executive Summary

After comprehensive analysis of policy violations across the homelab cluster, we've identified:
- **3 policies ready for Enforce mode** (0 violations, 100% compliant)
- **4 policies requiring remediation** before enforcement (105 violations)
- **Daily alerting strategy** for non-disruptive monitoring

---

## Policy Analysis

### ✅ Ready for Enforce Mode (Zero Violations)

These policies have **ZERO violations** across all workloads and can be safely switched to Enforce mode:

#### 1. disallow-privilege-escalation (High Severity)
- **Current Violations:** 0
- **Compliance Rate:** 100%
- **Enforcement Impact:** None - all workloads already compliant
- **Pod Security Standard:** Restricted
- **Recommendation:** ✅ **ENFORCE IMMEDIATELY**

**Why it's safe:**
- All containers already have `allowPrivilegeEscalation: false`
- No workloads require privilege escalation
- Critical security control - prevents container breakout

**Action:** Change `validationFailureAction` from `Audit` to `Enforce`

---

#### 2. require-drop-all-capabilities (High Severity)
- **Current Violations:** 0
- **Compliance Rate:** 100%
- **Enforcement Impact:** None - all workloads already compliant
- **Pod Security Standard:** Restricted
- **Recommendation:** ✅ **ENFORCE IMMEDIATELY**

**Why it's safe:**
- All containers already drop ALL capabilities
- No workloads require special Linux capabilities
- Reduces attack surface significantly

**Action:** Change `validationFailureAction` from `Audit` to `Enforce`

---

#### 3. require-labels (Low Severity)
- **Current Violations:** 0
- **Compliance Rate:** 100% (253/253 pass)
- **Enforcement Impact:** None - all workloads already have app labels
- **Best Practice:** Resource organization
- **Recommendation:** ✅ **ENFORCE IMMEDIATELY**

**Why it's safe:**
- All pods have either `app` or `app.kubernetes.io/name` labels
- Helm and kustomize add these labels automatically
- Improves resource management and filtering

**Action:** Change `validationFailureAction` from `Audit` to `Enforce`

---

### ⚠️ Requires Remediation (Violations Present)

These policies have violations and should remain in **Audit mode** until fixed:

#### 4. require-resource-limits (Medium Severity)
- **Current Violations:** 64
- **Compliance Rate:** ~70%
- **Top Violators:**
  - Monitoring namespace: 22 violations (Prometheus stack)
  - Loki namespace: 7 violations
  - Trivy system: 6 violations
  - Applications: Immich, Home Assistant, Audiobookshelf, Uptime Kuma

**Remediation Plan:**
1. Add resource limits to Prometheus/Grafana (monitoring)
2. Configure Loki resource limits
3. Update application Helm values with limits
4. Estimated effort: 2-3 hours

**Recommendation:** Keep in Audit mode for 1-2 weeks during remediation

---

#### 5. require-non-root (High Severity)
- **Current Violations:** 24
- **Compliance Rate:** ~85%
- **Top Violators:**
  - AdGuard Home: 11 violations (running as root)
  - Wallabag: 7 violations
  - Loki: 4 violations
  - Uptime Kuma: 2 violations

**Remediation Plan:**
1. Add `runAsUser: 1000` to AdGuard Home deployment
2. Review Wallabag init containers
3. Configure Loki securityContext
4. Estimated effort: 1-2 hours

**Recommendation:** Keep in Audit mode until all high-traffic apps fixed

---

#### 6. disallow-latest-tag (Medium Severity)
- **Current Violations:** 13
- **Compliance Rate:** ~95%
- **Pattern:** Mostly init containers and job containers

**Remediation Plan:**
1. Pin versions on all init containers
2. Update job image tags
3. Estimated effort: 1 hour

**Recommendation:** Keep in Audit mode, low priority

---

#### 7. disallow-host-path (Medium Severity)
- **Current Violations:** 4 (after exclusions)
- **Compliance Rate:** ~98%
- **Context:** Database persistence volumes

**Status:** ✅ **POLICY UPDATED**
- Added databases and couchdb namespaces to exclusions
- Required for local storage persistence
- Violations are intentional (WONTFIX)

**Recommendation:** Keep in Audit mode (violations are acceptable)

---

## Enforcement Strategy

### Phase 1: Immediate (This Week) ✅

**Switch to Enforce Mode:**
1. ✅ `disallow-privilege-escalation`
2. ✅ `require-drop-all-capabilities`
3. ✅ `require-labels`

**Why:** Zero violations, 100% compliant, no risk

**Action Items:**
- Update policy YAML files
- Test in staging (already live)
- Deploy to production
- Monitor for 24 hours

---

### Phase 2: Short-term (Next 2 Weeks)

**Fix Violations:**
1. Add resource limits to monitoring stack
2. Configure non-root for AdGuard Home, Wallabag, Loki
3. Pin image tags on init containers

**Target:** Reduce violations from 105 to <30

---

### Phase 3: Medium-term (Next Month)

**Consider Enforcement:**
1. `require-non-root` (after fixes)
2. `require-resource-limits` (after fixes)

**Keep in Audit:**
- `disallow-latest-tag` (nice-to-have, not critical)
- `disallow-host-path` (intentional violations for storage)

---

## Alerting Strategy

### Daily Digest (Info Level)
- Fire once per day (24h evaluation)
- Summary of total violations
- Non-disruptive monitoring
- Telegram notification

**Alerts:**
1. `KyvernoPolicyViolationsDailySummary` (>50 violations)
2. `KyvernoHighSeverityViolationsDaily` (>10 high-severity)

### Critical Alerts (Immediate)
- Fire within 5 minutes
- Only for system failures
- Requires immediate action

**Alerts:**
1. `KyvernoAdmissionControllerDown` (critical)

---

## Risk Assessment

### Enforcing Safe Policies (Phase 1)

**Risk Level:** ✅ **MINIMAL**

**Rationale:**
- Zero current violations = zero breaking changes
- All workloads already compliant
- No production impact expected
- Easy rollback (change back to Audit)

**Monitoring:**
- Watch for admission denials in Kyverno logs
- Monitor application deployments for failures
- Check PolicyReports for new violations

**Rollback Plan:**
If issues occur:
1. Change `validationFailureAction: Enforce` → `Audit`
2. Commit and push
3. Flux will auto-reconcile in <2 minutes
4. Investigate violation and fix workload
5. Re-enable Enforce mode

---

## Success Metrics

### Week 1 (Phase 1)
- [ ] 3 policies in Enforce mode
- [ ] Zero deployment failures
- [ ] Zero new violations
- [ ] Daily alerts functioning

### Week 2-3 (Phase 2)
- [ ] Violations reduced from 105 to <30
- [ ] Monitoring stack has resource limits
- [ ] AdGuard Home running non-root
- [ ] All image tags pinned

### Month 1 (Phase 3)
- [ ] 5 policies in Enforce mode
- [ ] <10 total violations
- [ ] Comprehensive compliance
- [ ] Automated enforcement

---

## Recommendations

### Immediate Actions (Today)
1. ✅ Switch 3 safe policies to Enforce mode
2. ✅ Deploy changes via GitOps
3. ✅ Monitor for 24 hours
4. ✅ Document any issues

### This Week
1. Fix Monitoring resource limits
2. Configure AdGuard Home non-root
3. Pin init container image tags

### This Month
1. Enable `require-non-root` enforcement
2. Enable `require-resource-limits` enforcement
3. Comprehensive policy coverage

---

## Conclusion

The homelab cluster is **well-positioned for policy enforcement**:
- 43% of policies (3/7) ready for immediate enforcement
- Zero risk for Phase 1 enforcement
- Clear remediation path for remaining policies
- Daily alerting provides visibility without noise

**Next Step:** Proceed with Phase 1 enforcement of the 3 compliant policies.
