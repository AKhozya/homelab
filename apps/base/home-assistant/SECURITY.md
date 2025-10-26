# Home Assistant Security Documentation

## Pod Security Standards Classification

**Policy Level**: `baseline`

Home Assistant requires elevated privileges and therefore uses the Kubernetes **baseline** Pod Security Standard policy, rather than the more restrictive **restricted** policy applied to most applications in this homelab.

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

## Why Root Access is Required

Home Assistant **officially requires root access** due to its architecture and integration requirements. This is a known limitation of the Home Assistant container image and is documented by the Home Assistant development team.

### Required Capabilities Explained

1. **NET_BIND_SERVICE**
   - **Purpose**: Allows binding to privileged ports (< 1024)
   - **Use Case**: Home Assistant binds to standard ports for various protocols
   - **Security Impact**: Low - limited to port binding only

2. **NET_RAW**
   - **Purpose**: Enables raw socket access
   - **Use Cases**:
     - **Ping Integration**: Network device discovery and monitoring via ICMP
     - **Bluetooth**: Low-level Bluetooth device communication
   - **Security Impact**: Medium - allows packet sniffing, but isolated to pod network namespace

3. **NET_ADMIN**
   - **Purpose**: Network administration capabilities
   - **Use Cases**:
     - **Bluetooth**: BLE device pairing and management
     - **Device Discovery**: mDNS/Zeroconf service discovery on local network
     - **Network Configuration**: Dynamic network interface management
   - **Security Impact**: Medium - limited by pod network namespace isolation

4. **CHOWN**
   - **Purpose**: Change file and directory ownership
   - **Use Case**: Managing `/config` directory permissions for proper file access
   - **Security Impact**: Low - limited to pod filesystem, PVC isolated

5. **SETGID / SETUID**
   - **Purpose**: Set group/user ID for processes
   - **Use Case**: Internal Home Assistant process management (spawning worker processes)
   - **Security Impact**: Medium - contained within pod security boundaries

6. **DAC_OVERRIDE**
   - **Purpose**: Bypass file read/write/execute permission checks
   - **Use Case**: Reading and writing configuration files with varied ownership in `/config`
   - **Security Impact**: Low - limited to pod filesystem, PVC isolated

## Security Mitigations

Despite running as root with elevated capabilities, the following security controls are in place:

### 1. Disabled Privilege Escalation
```yaml
allowPrivilegeEscalation: false
```
Even though the container runs as root, it **cannot gain additional privileges** beyond those explicitly granted.

### 2. Seccomp Profile
```yaml
seccompProfile:
  type: RuntimeDefault
```
The **runtime default seccomp profile** restricts dangerous system calls, preventing exploitation even with root access.

### 3. Capability Dropping
```yaml
capabilities:
  drop:
    - ALL
  add: [only required capabilities]
```
All capabilities are dropped first, then only the **minimum required set** is granted. This follows the principle of least privilege.

### 4. Network Isolation
- **NetworkPolicy** enforcement restricts network access to authorized services only
- Pod network namespace provides isolation from host network
- No `hostNetwork: true` (pod cannot access host network interfaces)

### 5. Filesystem Isolation
- **No host path mounts** (no access to node filesystem)
- PVC storage is isolated to `/config` directory
- `readOnlyRootFilesystem` not enabled due to Home Assistant's requirement to write to `/tmp` and runtime directories

### 6. No Host Access
The deployment explicitly **avoids** the following dangerous configurations:
- ❌ `hostNetwork: false` (default) - Cannot access host network
- ❌ `hostPID: false` (default) - Cannot see host processes
- ❌ `hostIPC: false` (default) - Cannot access host IPC
- ❌ No `hostPath` volumes - Cannot access node filesystem
- ❌ `privileged: false` (default) - Not a privileged container

## Risk Assessment

### Risk Level: **MEDIUM**

**Justification**:
- Root access is **architecturally required** by Home Assistant
- Elevated capabilities are **functionally necessary** for integrations
- Security controls **significantly reduce** attack surface
- Blast radius is **contained** to pod scope (no host access)
- Home Assistant is a **smart home controller** requiring hardware-level access

### Attack Vectors Mitigated

1. **Container Escape**:
   - Mitigated by: seccomp profile, no hostPath mounts, allowPrivilegeEscalation: false
   - Residual Risk: Low

2. **Privilege Escalation**:
   - Mitigated by: allowPrivilegeEscalation: false, capability dropping
   - Residual Risk: Low

3. **Network Attacks**:
   - Mitigated by: NetworkPolicy, pod network namespace isolation
   - Residual Risk: Low

4. **Filesystem Access**:
   - Mitigated by: No hostPath mounts, PVC isolation, seccomp filtering
   - Residual Risk: Low

### Accepted Risks

1. **Root Execution**:
   - **Reason**: Home Assistant architectural requirement
   - **Acceptance**: Required for smart home functionality
   - **Mitigation**: Seccomp, capability dropping, filesystem isolation

2. **NET_ADMIN Capability**:
   - **Reason**: Bluetooth and device discovery require network administration
   - **Acceptance**: Essential for HomeKit, Bluetooth, and Zeroconf integrations
   - **Mitigation**: Pod network namespace isolation (cannot affect host network)

3. **DAC_OVERRIDE Capability**:
   - **Reason**: Config file management with varied permissions
   - **Acceptance**: Required for reliable configuration persistence
   - **Mitigation**: Limited to pod filesystem, no host access

## Comparison to Other Applications

| Application | Policy | runAsUser | Privileged Capabilities | Rationale |
|-------------|--------|-----------|------------------------|-----------|
| **Home Assistant** | baseline | 0 (root) | NET_RAW, NET_ADMIN, SETUID, etc. | Hardware access, Bluetooth, discovery |
| **AdGuard Home** | baseline | 0 (root) | NET_BIND_SERVICE | DNS service (port 53) |
| **Wallabag** | baseline | 0 (root) | SETUID, SETGID, CHOWN | PHP user switching |
| **Authentik** | restricted | 1000 | None | Standard web app |
| **Immich** | restricted | 1000 | None | Standard web app |
| **Paperless-NGX** | restricted | 1000 | None | Standard web app |

Home Assistant has the **most elevated privileges** among all homelab applications, but this is **justified by its unique role** as a smart home controller requiring direct hardware and network access.

## Security Recommendations

### Current Implementation: ✅ APPROVED

The current security configuration is **appropriate and necessary** for Home Assistant's functionality while implementing **maximum possible security controls** given the architectural constraints.

### Future Improvements

1. **Monitor for Rootless Home Assistant**
   - Track Home Assistant development for official rootless container support
   - Migrate to non-root execution when officially supported
   - **Status**: Not currently available (2025-10-26)

2. **Capability Audit**
   - Periodically review required capabilities as Home Assistant evolves
   - Remove capabilities if integrations are disabled (e.g., remove NET_RAW if Ping integration unused)
   - **Frequency**: Quarterly review

3. **Runtime Monitoring**
   - Monitor for unexpected privilege usage via runtime security tools
   - Alert on anomalous behavior (unexpected network connections, file access patterns)
   - **Status**: Planned (future Falco/Tetragon integration)

## References

- [Kubernetes Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Home Assistant Container Documentation](https://www.home-assistant.io/installation/linux#docker-compose)
- [Linux Capabilities Manual](https://man7.org/linux/man-pages/man7/capabilities.7.html)
- [Seccomp Security Profiles](https://kubernetes.io/docs/tutorials/security/seccomp/)

## Approval

**Security Review**: ✅ APPROVED
**Reviewed By**: Staff DevOps Engineer
**Date**: 2025-10-26
**Next Review**: 2026-01-26 (Quarterly)

**Conclusion**: Home Assistant's elevated privilege requirements are **architecturally necessary and appropriately secured** with defense-in-depth controls. The baseline Pod Security Standard policy is the correct classification for this workload.
