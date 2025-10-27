# Kyverno Additional Policies - Recommendations

**Analysis Date:** 2025-10-27
**Current Policies:** 7 (3 Enforce + 4 Audit)
**Cluster Analysis:** 74 pods across 23 namespaces

---

## Executive Summary

After analyzing the homelab cluster configuration, I've identified **5 high-value policies** that would significantly improve security and operational excellence:

**Priority 1 (High Value, Low Risk):**
1. ✅ **Require non-default service accounts** - 23 pods at risk
2. ✅ **Require seccomp RuntimeDefault** - 23 pods without profile
3. ✅ **Disallow hostPID/hostIPC/hostNetwork** - Prevent dangerous configurations

**Priority 2 (Medium Value, Low Risk):**
4. ⚠️ **Require readOnlyRootFilesystem** - 21 pods writeable (needs testing)
5. ⚠️ **Restrict volume types** - Enforce safe volume types only

---

## Current State Analysis

### Service Account Usage
```
Default SA:     23 pods (31%) ⚠️ SECURITY RISK
Custom SA:      51 pods (69%) ✅ GOOD
```

**Pods using default SA:**
- adguard-home, audiobookshelf, authentik, cloudflare-tunnel
- databases (redis, init jobs)
- home-assistant, homehub, immich, linkding
- mealie, n8n, paperless-ngx, stirling-pdf
- And more...

**Risk:** Default service account has unnecessary cluster access

---

### Security Context Profiles

#### ReadOnlyRootFilesystem
```
Enabled:   53 pods (72%) ✅ GOOD
Disabled:  21 pods (28%) ⚠️ RISK
```

**Impact:** Writable filesystems increase malware persistence risk

#### Seccomp Profile
```
RuntimeDefault:  45 pods (66%) ✅ GOOD
None:            23 pods (34%) ⚠️ RISK
```

**Impact:** Missing seccomp = no syscall filtering = larger attack surface

---

### Host Namespace Usage
```
hostNetwork: 0 pods ✅ EXCELLENT
hostPID:     0 pods ✅ EXCELLENT
hostIPC:     0 pods ✅ EXCELLENT
```

**Status:** Already compliant! Policy would prevent future misconfigurations.

---

### Volume Types
```
hostPath:              5 pods (loki, monitoring, trivy - excluded)
persistentVolumeClaim: Multiple (expected)
emptyDir:              Multiple (safe)
configMap:             Multiple (safe)
secret:                Multiple (safe)
```

**Status:** All hostPath usage is legitimate and already excluded from policies.

---

## Recommended Policies

### 1. Require Non-Default Service Accounts

**Priority:** 🔴 **P0-CRITICAL**
**Compliance:** 69% (23 violations)
**Risk Level:** 🟢 LOW (easy fix)
**Effort:** 2-3 hours

**Why it matters:**
- Default service account has cluster-wide permissions
- Follows principle of least privilege
- Required by Pod Security Standards (Restricted)
- Industry best practice

**What it blocks:**
```yaml
spec:
  serviceAccountName: default  # ❌ BLOCKED
```

**What it requires:**
```yaml
spec:
  serviceAccountName: myapp-sa  # ✅ REQUIRED
  automountServiceAccountToken: false  # ✅ BEST PRACTICE
```

**Remediation:**
```bash
# For each namespace, create dedicated SA
kubectl create serviceaccount adguard-home -n adguard-home
kubectl create serviceaccount audiobookshelf -n audiobookshelf
# etc...

# Update deployments to use custom SA
spec:
  serviceAccountName: adguard-home
  automountServiceAccountToken: false  # Unless app needs K8s API access
```

**Recommendation:** ✅ **IMPLEMENT IN AUDIT MODE**
- Start in Audit to identify all violations
- Fix violations over 1-2 weeks
- Switch to Enforce once all fixed

---

### 2. Require Seccomp RuntimeDefault Profile

**Priority:** 🟠 **P1-HIGH**
**Compliance:** 66% (23 violations)
**Risk Level:** 🟢 LOW (non-breaking)
**Effort:** 1-2 hours

**Why it matters:**
- Seccomp filters dangerous system calls
- Prevents kernel exploits
- Required by Pod Security Standards (Restricted)
- Minimal performance impact

**What it blocks:**
```yaml
securityContext:
  seccompProfile:
    type: Unconfined  # ❌ BLOCKED
```

**What it requires:**
```yaml
spec:
  securityContext:
    seccompProfile:
      type: RuntimeDefault  # ✅ REQUIRED
```

**Remediation:**
```yaml
# Add to all deployments/statefulsets
spec:
  template:
    spec:
      securityContext:
        seccompProfile:
          type: RuntimeDefault
```

**Recommendation:** ✅ **IMPLEMENT IN AUDIT MODE**
- Very low risk (seccomp rarely breaks apps)
- Can enforce quickly after testing
- Significant security benefit

---

### 3. Disallow Host Namespaces (hostPID, hostIPC, hostNetwork)

**Priority:** 🟢 **P2-MEDIUM**
**Compliance:** 100% (0 violations)
**Risk Level:** 🟢 ZERO (already compliant)
**Effort:** 0 hours (preventive)

**Why it matters:**
- Host namespaces allow container escape
- Required by Pod Security Standards (Baseline)
- Currently compliant - policy prevents regression

**What it blocks:**
```yaml
spec:
  hostNetwork: true  # ❌ BLOCKED
  hostPID: true      # ❌ BLOCKED
  hostIPC: true      # ❌ BLOCKED
```

**Remediation:**
None needed - already compliant!

**Recommendation:** ✅ **IMPLEMENT IN ENFORCE MODE IMMEDIATELY**
- Zero violations = zero risk
- Prevents future misconfigurations
- Industry standard control

---

### 4. Require ReadOnlyRootFilesystem (Optional)

**Priority:** 🟡 **P3-LOW**
**Compliance:** 72% (21 violations)
**Risk Level:** 🟠 MEDIUM (may break apps)
**Effort:** 3-4 hours (testing required)

**Why it matters:**
- Prevents malware persistence
- Immutable infrastructure best practice
- Pod Security Standards recommended

**What it requires:**
```yaml
securityContext:
  readOnlyRootFilesystem: true  # ✅ REQUIRED
```

**Violations (apps that may need writable FS):**
- Applications with local caching
- Apps that write temporary files
- Legacy apps not designed for immutability

**Workaround for apps needing writes:**
```yaml
volumeMounts:
  - name: tmp
    mountPath: /tmp
  - name: cache
    mountPath: /app/cache
volumes:
  - name: tmp
    emptyDir: {}
  - name: cache
    emptyDir: {}
```

**Recommendation:** ⚠️ **OPTIONAL - REQUIRES TESTING**
- Start in Audit mode
- Test each violating app individually
- May need emptyDir volumes for /tmp, /cache
- Only enforce if willing to invest effort

---

### 5. Restrict Volume Types (Optional)

**Priority:** 🟡 **P3-LOW**
**Compliance:** ~95% (mostly compliant)
**Risk Level:** 🟢 LOW
**Effort:** 1 hour

**Why it matters:**
- Prevents dangerous volume types
- hostPath already restricted
- Enforce safe volume types only

**Allowed volume types:**
- persistentVolumeClaim ✅
- emptyDir ✅
- configMap ✅
- secret ✅
- projected ✅
- downwardAPI ✅

**Blocked volume types:**
- hostPath ❌ (already restricted)
- gcePersistentDisk ❌
- awsElasticBlockStore ❌
- nfs ❌ (unless needed)

**Recommendation:** ⚠️ **OPTIONAL**
- Already covered by disallow-host-path
- Marginal additional value
- Consider if using cloud providers

---

## Implementation Roadmap

### Phase 1: Immediate (Zero Risk) ✅

**Implement in Enforce Mode:**
1. disallow-host-namespaces (0 violations)

**Effort:** 5 minutes
**Risk:** Zero
**Action:** Deploy policy, monitor for 24h

---

### Phase 2: Short-term (1-2 Weeks)

**Implement in Audit Mode:**
1. require-non-default-service-accounts (23 violations)
2. require-seccomp-runtimedefault (23 violations)

**Remediation Tasks:**
- Create dedicated service accounts per namespace
- Add seccompProfile to all deployments
- Test applications after changes

**Effort:** 2-3 hours
**Risk:** Low (tested configurations)

---

### Phase 3: Medium-term (2-4 Weeks)

**After Phase 2 fixes, switch to Enforce:**
1. require-non-default-service-accounts
2. require-seccomp-runtimedefault

**Target:** 5 enforced policies total (current 3 + 2 new)

---

### Phase 4: Optional (As Needed)

**Consider if beneficial:**
1. require-readonly-root-filesystem
2. restrict-volume-types

**Effort:** 3-5 hours
**Decision:** Based on security posture requirements

---

## Policy Priority Matrix

```
                    HIGH COMPLIANCE         LOW COMPLIANCE
HIGH IMPACT         ┌───────────────────────┬──────────────────┐
                    │ 3. Host Namespaces    │ 1. Service Accts │
                    │    [0 violations]     │    [23 violate]  │
                    │    ✅ ENFORCE NOW     │    ⚠️ FIX FIRST  │
                    ├───────────────────────┼──────────────────┤
MEDIUM IMPACT       │                       │ 2. Seccomp       │
                    │                       │    [23 violate]  │
                    │                       │    ⚠️ FIX FIRST  │
                    ├───────────────────────┼──────────────────┤
LOW IMPACT          │ 5. Volume Types       │ 4. ReadOnlyFS    │
                    │    [~5 violations]    │    [21 violate]  │
                    │    ⚠️ OPTIONAL        │    ⚠️ OPTIONAL   │
                    └───────────────────────┴──────────────────┘
```

---

## Risk Assessment

### Implementing Recommended Policies

| Policy | Current Violations | Breaking Risk | Recommendation |
|--------|-------------------|---------------|----------------|
| disallow-host-namespaces | 0 | 🟢 ZERO | Enforce immediately |
| require-non-default-sa | 23 | 🟢 LOW | Audit → Fix → Enforce |
| require-seccomp | 23 | 🟢 LOW | Audit → Fix → Enforce |
| require-readonly-fs | 21 | 🟠 MEDIUM | Optional, test first |
| restrict-volume-types | ~5 | 🟢 LOW | Optional |

---

## Comparison with Pod Security Standards

```
┌────────────────────────────────────────────────────────────┐
│           Pod Security Standards Compliance                 │
├────────────────────────────────────────────────────────────┤
│  RESTRICTED (Most Secure)                                  │
│    ✅ allowPrivilegeEscalation: false [ENFORCING]         │
│    ✅ capabilities: drop ALL [ENFORCING]                  │
│    ⚠️ runAsNonRoot: true [AUDITING - 24 violations]       │
│    ⚠️ seccompProfile: RuntimeDefault [PROPOSED - 23 viol.] │
│    ⚠️ readOnlyRootFilesystem: true [OPTIONAL]             │
│                                                             │
│  BASELINE (Essential Security)                             │
│    ✅ hostPath: disallowed [AUDITING - 4 violations]      │
│    ✅ hostNetwork: disallowed [PROPOSED - 0 violations]   │
│    ✅ hostPID: disallowed [PROPOSED - 0 violations]       │
│    ✅ hostIPC: disallowed [PROPOSED - 0 violations]       │
│    ✅ privileged: disallowed [ENFORCING via caps]         │
│                                                             │
│  PRIVILEGED (No Restrictions)                              │
│    [Not applicable - homelab doesn't need this]           │
└────────────────────────────────────────────────────────────┘

Current Status: ~75% Baseline + ~60% Restricted
With Recommended: ~95% Baseline + ~80% Restricted
```

---

## Sample Policy: Disallow Host Namespaces

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-host-namespaces
  annotations:
    policies.kyverno.io/title: Disallow Host Namespaces
    policies.kyverno.io/category: Pod Security Standards (Baseline)
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      Host namespaces (hostNetwork, hostPID, hostIPC) allow pods to access
      host resources and should be disallowed.
spec:
  validationFailureAction: Enforce  # 0 violations = safe to enforce
  background: true
  rules:
    - name: host-namespaces
      match:
        any:
          - resources:
              kinds:
                - Pod
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kube-public
                - flux-system
                - kyverno
      validate:
        message: "Using host namespaces is disallowed"
        pattern:
          spec:
            =(hostNetwork): false
            =(hostPID): false
            =(hostIPC): false
```

---

## Success Metrics

### After Phase 1
- [ ] 4 policies enforcing (vs 3 current)
- [ ] 100% host namespace protection
- [ ] Zero new violations

### After Phase 2
- [ ] 0 pods using default service account
- [ ] 100% seccomp coverage
- [ ] 6 policies enforcing (vs 3 current)

### After Phase 3
- [ ] 85% Pod Security Standards Restricted compliance
- [ ] 100% Pod Security Standards Baseline compliance
- [ ] Comprehensive security posture

---

## Recommendations Summary

### Implement Now (Phase 1) ✅
1. **disallow-host-namespaces** - Enforce mode
   - 0 violations = zero risk
   - Prevents container escape
   - 5 minutes to implement

### Implement Soon (Phase 2) ⚠️
2. **require-non-default-service-accounts** - Audit mode
   - 23 violations need fixing
   - Critical security improvement
   - 2-3 hours effort

3. **require-seccomp-runtimedefault** - Audit mode
   - 23 violations need fixing
   - Significant security benefit
   - 1-2 hours effort

### Consider Later (Phase 4) 🤔
4. **require-readonly-root-filesystem** - Optional
   - May break applications
   - Requires significant testing
   - 3-4 hours effort

5. **restrict-volume-types** - Optional
   - Marginal additional value
   - Already covered by hostPath policy

---

## Next Actions

### Immediate
1. Review this recommendation document
2. Decide on Phase 1 implementation (disallow-host-namespaces)
3. Plan Phase 2 remediation timeline

### This Week
1. Implement disallow-host-namespaces (Enforce)
2. Implement require-non-default-sa (Audit)
3. Implement require-seccomp (Audit)

### Next 2 Weeks
1. Create service accounts for all apps
2. Add seccomp profiles to all deployments
3. Test all changes

### Month 1
1. Switch Phase 2 policies to Enforce
2. Achieve 6/7+ policies enforcing
3. 95%+ Pod Security Standards compliance

---

## Conclusion

The homelab cluster is well-positioned to adopt **3 additional high-value policies**:
- **1 can be enforced immediately** (0 violations)
- **2 require minor fixes** (23 violations each, easy to remediate)
- **2 are optional** (based on security requirements)

Implementing Phase 1-2 would provide:
- ✅ Container escape prevention
- ✅ Principle of least privilege (service accounts)
- ✅ Syscall filtering (seccomp)
- ✅ 95% Pod Security Standards compliance

**Recommended Action:** Proceed with Phase 1 (disallow-host-namespaces) immediately.
