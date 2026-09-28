# Home Assistant Security Documentation

## Pod Security Standards Classification

**Policy Level:** `privileged` (enforce), with `baseline` audit and warn labels (`namespace.yaml`)

The namespace enforces **privileged**; baseline audit and warn report baseline violations. Every capability the container now adds is on the baseline allowlist, because `NET_RAW` and `NET_ADMIN` are dropped (see below). Lowering enforce to baseline is a separate change: prove it with `kubectl apply --dry-run=server` on the namespace first.

## Security Context Configuration

### Pod-Level Security

```yaml
securityContext:
  runAsUser: 0
  runAsGroup: 0
  fsGroup: 0
  seccompProfile:
    type: RuntimeDefault
```

### Container-Level Security

```yaml
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
    add:
      - NET_BIND_SERVICE
      - CHOWN
      - SETGID
      - SETUID
      - DAC_OVERRIDE
```

## Why Root Access Required

HA **officially requires root access** — architecture + integration requirements. Known container image limitation, documented by HA dev team.

### Required Capabilities Explained

1. **NET_BIND_SERVICE**
   - **Purpose:** Bind to privileged ports (< 1024)
   - **Use:** HA binds standard ports for various protocols
   - **Impact:** Low — port binding only

2. **CHOWN**
   - **Purpose:** Change file/dir ownership
   - **Use:** Manage `/config` permissions for file access
   - **Impact:** Low — pod filesystem, PVC isolated

3. **SETGID / SETUID**
   - **Purpose:** Set group/user ID for processes
   - **Use:** HA process management (spawning workers)
   - **Impact:** Medium — contained within pod

4. **DAC_OVERRIDE**
   - **Purpose:** Bypass file r/w/x permission checks
   - **Use:** R/w config files with varied ownership in `/config`
   - **Impact:** Low — pod filesystem, PVC isolated

### Capabilities deliberately not granted

| Capability | Why HA does not need it here |
|---|---|
| `NET_RAW` | Ping and DHCP discovery use raw sockets. No Ping entity exists (checked 2026-09-28), and DHCP discovery sees only this pod's own network namespace. Raw sockets would let the pod forge frames onto `cni0`. If Ping is set up, add it back. |
| `NET_ADMIN` | Bluetooth needs `hostNetwork` and the host adapter, which this pod has neither of. mDNS/Zeroconf is plain multicast UDP and needs no capability. |

## Security Mitigations

Despite root + elevated caps, controls in place:

### 1. Disabled Privilege Escalation
```yaml
allowPrivilegeEscalation: false
```
Root container **cannot gain additional privileges** beyond granted.

### 2. Seccomp Profile
```yaml
seccompProfile:
  type: RuntimeDefault
```
**Runtime default seccomp** restricts dangerous syscalls, prevents exploitation even with root.

### 3. Capability Dropping
```yaml
capabilities:
  drop:
    - ALL
  add: [only required capabilities]
```
Drop all first, grant only **minimum required**. Principle of least privilege.

### 4. Network Isolation
- **NetworkPolicy** restricts net access to authorized services
- Pod net namespace isolates from host net
- No `hostNetwork: true` (pod can't access host net interfaces)

### 5. Filesystem Isolation
- **No host path mounts** (no node filesystem access)
- PVC storage isolated to `/config`
- `readOnlyRootFilesystem` not enabled — HA needs write to `/tmp` + runtime dirs

### 6. No Host Access

Deployment avoids:
- `hostNetwork: false` (default) — no host net access
- `hostPID: false` (default) — no host processes
- `hostIPC: false` (default) — no host IPC
- No `hostPath` volumes — no node filesystem
- `privileged: false` (default) — not privileged

## Risk Assessment

### Risk Level: **MEDIUM**

**Justification:**
- Root **architecturally required** by HA
- Elevated caps **functionally necessary** for integrations
- Security controls reduce the attack surface
- Blast radius **contained** to pod scope (no host access)
- HA = **smart home controller** needing hardware-level access

### Attack Vectors Mitigated

1. **Container Escape:**
   - Mitigated: seccomp profile, no hostPath mounts, allowPrivilegeEscalation: false
   - Residual Risk: Low

2. **Privilege Escalation:**
   - Mitigated: allowPrivilegeEscalation: false, cap dropping
   - Residual Risk: Low

3. **Network Attacks:**
   - Mitigated: NetworkPolicy, pod net namespace isolation
   - Residual Risk: Low

4. **Filesystem Access:**
   - Mitigated: no hostPath mounts, PVC isolation, seccomp filtering
   - Residual Risk: Low

### Accepted Risks

1. **Root Execution:**
   - **Reason:** HA architectural requirement
   - **Acceptance:** Required for smart home functionality
   - **Mitigation:** Seccomp, cap dropping, filesystem isolation

2. **DAC_OVERRIDE Capability:**
   - **Reason:** Config file mgmt with varied permissions
   - **Acceptance:** Required for reliable config persistence
   - **Mitigation:** Pod filesystem only, no host access

## Security Recommendations

### Current Implementation: APPROVED

Current config **appropriate + necessary** for HA functionality while implementing **max possible security** given architectural constraints.

### Future Improvements

1. **Monitor for Rootless HA**
   - Track HA dev for official rootless container support
   - Migrate to non-root when officially supported
   - **Status:** Not available (2025-10-26)

2. **Capability Audit**
   - Periodic review of required caps as HA evolves
   - Remove caps if integrations are disabled
   - **Frequency:** Quarterly

3. **Runtime Monitoring**
   - Monitor unexpected privilege usage via runtime security tools
   - Alert on anomalous behavior (unexpected connections, file access)
   - **Status:** Planned (Falco/Tetragon)

## References

- [Kubernetes Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Home Assistant Container Documentation](https://www.home-assistant.io/installation/linux#docker-compose)
- [Linux Capabilities Manual](https://man7.org/linux/man-pages/man7/capabilities.7.html)
- [Seccomp Security Profiles](https://kubernetes.io/docs/tutorials/security/seccomp/)

## Approval

**Security Review:** APPROVED
**Reviewed By:** Staff DevOps Engineer
**Date:** 2025-10-26
**Next Review:** overdue since 2026-01-26 (quarterly)

**Conclusion:** HA elevated privilege requirements **architecturally necessary + appropriately secured** with defense-in-depth. Privileged enforce with baseline audit and warn = correct classification.
