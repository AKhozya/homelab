# Home Assistant Security Documentation

## Pod Security Standards Classification

**Policy Level:** `baseline`

HA needs elevated privileges → uses K8s **baseline** PSS policy, not stricter **restricted** used for most apps.

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
      - NET_RAW
      - NET_ADMIN
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

2. **NET_RAW**
   - **Purpose:** Raw socket access
   - **Uses:**
     - **Ping Integration:** network device discovery/monitoring via ICMP
     - **Bluetooth:** low-level BT device comms
   - **Impact:** Medium — packet sniffing, isolated to pod net namespace

3. **NET_ADMIN**
   - **Purpose:** Network admin capabilities
   - **Uses:**
     - **Bluetooth:** BLE pairing + management
     - **Device Discovery:** mDNS/Zeroconf on local net
     - **Network Config:** dynamic interface management
   - **Impact:** Medium — limited by pod net namespace

4. **CHOWN**
   - **Purpose:** Change file/dir ownership
   - **Use:** Manage `/config` permissions for file access
   - **Impact:** Low — pod filesystem, PVC isolated

5. **SETGID / SETUID**
   - **Purpose:** Set group/user ID for processes
   - **Use:** HA process management (spawning workers)
   - **Impact:** Medium — contained within pod

6. **DAC_OVERRIDE**
   - **Purpose:** Bypass file r/w/x permission checks
   - **Use:** R/w config files with varied ownership in `/config`
   - **Impact:** Low — pod filesystem, PVC isolated

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

2. **NET_ADMIN Capability:**
   - **Reason:** BT + device discovery need net admin
   - **Acceptance:** Essential for HomeKit, BT, Zeroconf
   - **Mitigation:** Pod net namespace isolation (can't affect host net)

3. **DAC_OVERRIDE Capability:**
   - **Reason:** Config file mgmt with varied permissions
   - **Acceptance:** Required for reliable config persistence
   - **Mitigation:** Pod filesystem only, no host access

## Comparison to Other Applications

| Application | Policy | runAsUser | Privileged Capabilities | Rationale |
|-------------|--------|-----------|------------------------|-----------|
| **Home Assistant** | baseline | 0 (root) | NET_RAW, NET_ADMIN, SETUID, etc. | Hardware access, Bluetooth, discovery |
| **AdGuard Home** | baseline | 0 (root) | NET_BIND_SERVICE | DNS service (port 53) |
| **Wallabag** | baseline | 0 (root) | SETUID, SETGID, CHOWN | PHP user switching |
| **Authentik** | restricted | 1000 | None | Standard web app |
| **Immich** | restricted | 1000 | None | Standard web app |
| **Paperless-NGX** | restricted | 1000 | None | Standard web app |

HA has **most elevated privileges** among homelab apps — **justified by unique role** as smart home controller needing direct hardware + net access.

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
   - Remove caps if integrations disabled (e.g., NET_RAW if Ping unused)
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
**Next Review:** 2026-01-26 (Quarterly)

**Conclusion:** HA elevated privilege requirements **architecturally necessary + appropriately secured** with defense-in-depth. Baseline PSS = correct classification.
