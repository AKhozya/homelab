# Kyverno Additional Policies - Recommendations

**Analysis Date:** 2025-10-27
**Current Policies:** 7 (3 Enforce + 4 Audit)
**Cluster Analysis:** 74 pods across 23 namespaces

---

## Executive Summary

Cluster analysis found **5 high-value policies** — boost security + ops:

**Priority 1 (High Value, Low Risk):**
1. **Require non-default service accounts** — 23 pods at risk
2. **Require seccomp RuntimeDefault** — 23 pods no profile
3. **Disallow hostPID/hostIPC/hostNetwork** — block dangerous configs

**Priority 2 (Medium Value, Low Risk):**
4. **Require readOnlyRootFilesystem** — 21 pods writable (need test)
5. **Restrict volume types** — safe types only

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
- more...

**Risk:** Default SA = unnecessary cluster access

---

### Security Context Profiles

#### ReadOnlyRootFilesystem
```
Enabled:   53 pods (72%) ✅ GOOD
Disabled:  21 pods (28%) ⚠️ RISK
```

**Impact:** Writable FS → malware persistence risk

#### Seccomp Profile
```
RuntimeDefault:  45 pods (66%) ✅ GOOD
None:            23 pods (34%) ⚠️ RISK
```

**Impact:** No seccomp → no syscall filter → bigger attack surface

---

### Host Namespace Usage
```
hostNetwork: 0 pods ✅ EXCELLENT
hostPID:     0 pods ✅ EXCELLENT
hostIPC:     0 pods ✅ EXCELLENT
```

**Status:** Compliant. Policy block future misconfig.

---

### Volume Types
```
hostPath:              5 pods (loki, monitoring, trivy - excluded)
persistentVolumeClaim: Multiple (expected)
emptyDir:              Multiple (safe)
configMap:             Multiple (safe)
secret:                Multiple (safe)
```

**Status:** All hostPath legit + excluded.

---

## Recommended Policies

### 1. Require Non-Default Service Accounts

**Priority:** **P0-CRITICAL**
**Compliance:** 69% (23 violations)
**Risk Level:** LOW (easy fix)
**Effort:** 2-3h

**Why:**
- Default SA = cluster-wide perms
- Least privilege
- PSS Restricted requires
- Industry best practice

**Blocks:**
```yaml
spec:
  serviceAccountName: default  # ❌ BLOCKED
```

**Requires:**
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

**Recommendation:** **IMPLEMENT IN AUDIT MODE**
- Audit → find violations
- Fix over 1-2 weeks
- Switch Enforce when done

---

### 2. Require Seccomp RuntimeDefault Profile

**Priority:** **P1-HIGH**
**Compliance:** 66% (23 violations)
**Risk Level:** LOW (non-breaking)
**Effort:** 1-2h

**Why:**
- Seccomp filter dangerous syscalls
- Block kernel exploits
- PSS Restricted requires
- Tiny perf hit

**Blocks:**
```yaml
securityContext:
  seccompProfile:
    type: Unconfined  # ❌ BLOCKED
```

**Requires:**
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

**Recommendation:** **IMPLEMENT IN AUDIT MODE**
- Tiny risk (seccomp rare break apps)
- Enforce fast after test
- Big security win

---

### 3. Disallow Host Namespaces (hostPID, hostIPC, hostNetwork)

**Priority:** **P2-MEDIUM**
**Compliance:** 100% (0 violations)
**Risk Level:** ZERO (compliant)
**Effort:** 0h (preventive)

**Why:**
- Host namespaces = container escape
- PSS Baseline requires
- Compliant now — policy block regression

**Blocks:**
```yaml
spec:
  hostNetwork: true  # ❌ BLOCKED
  hostPID: true      # ❌ BLOCKED
  hostIPC: true      # ❌ BLOCKED
```

**Remediation:** None — compliant.

**Recommendation:** **IMPLEMENT IN ENFORCE MODE IMMEDIATELY**
- Zero violations = zero risk
- Block future misconfig
- Industry standard

---

### 4. Require ReadOnlyRootFilesystem (Optional)

**Priority:** **P3-LOW**
**Compliance:** 72% (21 violations)
**Risk Level:** MEDIUM (may break apps)
**Effort:** 3-4h (test required)

**Why:**
- Block malware persistence
- Immutable infra
- PSS recommended

**Requires:**
```yaml
securityContext:
  readOnlyRootFilesystem: true  # ✅ REQUIRED
```

**Violations (apps need writable FS):**
- Local cache apps
- Temp file writers
- Legacy apps

**Workaround for write-needing apps:**
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

**Recommendation:** **OPTIONAL — REQUIRES TESTING**
- Start Audit
- Test each violator
- May need emptyDir for /tmp, /cache
- Enforce only if effort worth

---

### 5. Restrict Volume Types (Optional)

**Priority:** **P3-LOW**
**Compliance:** ~95% (mostly compliant)
**Risk Level:** LOW
**Effort:** 1h

**Why:**
- Block dangerous volume types
- hostPath restricted already
- Safe types only

**Allowed:**
- persistentVolumeClaim
- emptyDir
- configMap
- secret
- projected
- downwardAPI

**Blocked:**
- hostPath (restricted already)
- gcePersistentDisk
- awsElasticBlockStore
- nfs (unless needed)

**Recommendation:** **OPTIONAL**
- disallow-host-path covers this
- Marginal extra value
- Consider if cloud providers

---

## Implementation Roadmap

### Phase 1: Immediate (Zero Risk)

**Implement in Enforce Mode:**
1. disallow-host-namespaces (0 violations)

**Effort:** 5 min
**Risk:** Zero
**Action:** Deploy policy, watch 24h

---

### Phase 2: Short-term (1-2 Weeks)

**Implement in Audit Mode:**
1. require-non-default-service-accounts (23 violations)
2. require-seccomp-runtimedefault (23 violations)

**Remediation Tasks:**
- Make dedicated SA per namespace
- Add seccompProfile to all deployments
- Test apps after

**Effort:** 2-3h
**Risk:** Low (tested configs)

---

### Phase 3: Medium-term (2-4 Weeks)

**After Phase 2 done, switch Enforce:**
1. require-non-default-service-accounts
2. require-seccomp-runtimedefault

**Target:** 5 enforced policies (3 current + 2 new)

---

### Phase 4: Optional (As Needed)

**Consider if worth:**
1. require-readonly-root-filesystem
2. restrict-volume-types

**Effort:** 3-5h
**Decision:** Based security posture

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
| disallow-host-namespaces | 0 | ZERO | Enforce immediately |
| require-non-default-sa | 23 | LOW | Audit → Fix → Enforce |
| require-seccomp | 23 | LOW | Audit → Fix → Enforce |
| require-readonly-fs | 21 | MEDIUM | Optional, test first |
| restrict-volume-types | ~5 | LOW | Optional |

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
- [ ] 0 pods using default SA
- [ ] 100% seccomp coverage
- [ ] 6 policies enforcing (vs 3 current)

### After Phase 3
- [ ] 85% PSS Restricted compliance
- [ ] 100% PSS Baseline compliance
- [ ] Full security posture

---

## Recommendations Summary

### Implement Now (Phase 1)
1. **disallow-host-namespaces** — Enforce mode
   - 0 violations = zero risk
   - Block container escape
   - 5 min

### Implement Soon (Phase 2)
2. **require-non-default-service-accounts** — Audit mode
   - 23 violations
   - Critical security
   - 2-3h

3. **require-seccomp-runtimedefault** — Audit mode
   - 23 violations
   - Big security win
   - 1-2h

### Consider Later (Phase 4)
4. **require-readonly-root-filesystem** — Optional
   - May break apps
   - Heavy test needed
   - 3-4h

5. **restrict-volume-types** — Optional
   - Marginal value
   - hostPath policy covers

---

## Next Actions

### Immediate
1. Review doc
2. Decide Phase 1 (disallow-host-namespaces)
3. Plan Phase 2 remediation timeline

### This Week
1. Deploy disallow-host-namespaces (Enforce)
2. Deploy require-non-default-sa (Audit)
3. Deploy require-seccomp (Audit)

### Next 2 Weeks
1. Make SAs for all apps
2. Add seccomp profiles to deployments
3. Test all changes

### Month 1
1. Switch Phase 2 policies Enforce
2. 6/7+ policies enforcing
3. 95%+ PSS compliance

---

## Conclusion

Homelab ready adopt **3 high-value policies**:
- **1 enforce now** (0 violations)
- **2 need minor fix** (23 violations each, easy)
- **2 optional** (security needs)

Phase 1-2 give:
- Container escape block
- Least privilege (SAs)
- Syscall filter (seccomp)
- 95% PSS compliance

**Recommended Action:** Do Phase 1 (disallow-host-namespaces) now.