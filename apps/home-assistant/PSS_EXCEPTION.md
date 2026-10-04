# Home Assistant Security Documentation

## Pod Security Standards Classification

**Policy Level:** `privileged` (enforce), with `baseline` audit and warn labels (`namespace.yaml`)

The namespace enforces **privileged**; baseline audit and warn report baseline violations. Every capability the container now adds is on the baseline allowlist, because `NET_RAW` and `NET_ADMIN` are dropped (see below). Lowering enforce to baseline is a separate change: prove it with `kubectl apply --dry-run=server` on the namespace first.

The Kyverno policies `require-non-root` and `require-readonly-rootfs` exclude this namespace (`infrastructure/configs/kyverno-policies/`).

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

The Home Assistant container image requires root. This is an upstream limitation.

### Required Capabilities Explained

| Capability | Lets the process | HA uses it to | Impact |
|---|---|---|---|
| `NET_BIND_SERVICE` | bind ports below 1024 | bind standard ports for some protocols | Low: port binding only |
| `CHOWN` | change file ownership | manage permissions under `/config` | Low: pod filesystem and its own PVC |
| `SETGID` / `SETUID` | set the group or user ID of a process | spawn worker processes | Medium: stays inside the pod |
| `DAC_OVERRIDE` | skip file read, write and execute checks | read and write config files with mixed owners in `/config` | Low: pod filesystem and its own PVC |

### Capabilities deliberately not granted

| Capability | Why HA does not need it here |
|---|---|
| `NET_RAW` | Ping and DHCP discovery use raw sockets. No Ping entity exists (checked 2026-09-28), and DHCP discovery sees only this pod's own network namespace. Raw sockets would let the pod forge frames onto `cni0`. If Ping is set up, add it back. |
| `NET_ADMIN` | Bluetooth needs `hostNetwork` and the host adapter, which this pod has neither of. mDNS/Zeroconf is plain multicast UDP and needs no capability. |

## Security Mitigations

### 1. Disabled Privilege Escalation
```yaml
allowPrivilegeEscalation: false
```
The root process cannot gain privileges beyond the ones granted.

### 2. Seccomp Profile
```yaml
seccompProfile:
  type: RuntimeDefault
```
The runtime default seccomp profile blocks dangerous syscalls, even for root.

### 3. Capability Dropping
```yaml
capabilities:
  drop:
    - ALL
  add: [only required capabilities]
```

### 4. Network Isolation
- A NetworkPolicy limits which services the pod can reach and be reached from.
- No `hostNetwork`, `hostPID` or `hostIPC`: the pod sees only its own network, processes and IPC.

### 5. Filesystem Isolation
- The Deployment sets no `hostPath` volume and no `privileged` container.
- Persistent storage is one PVC at `/config`.
- `readOnlyRootFilesystem` is off: HA writes to runtime dirs on the root filesystem. `/tmp` is an emptyDir.

## Risk Assessment

### Risk Level: **MEDIUM**

**Justification:** HA needs root, and the added capabilities serve `/config` file handling and worker processes. The pod has no `hostPath` volume, no `privileged` container, and none of `hostNetwork`, `hostPID` or `hostIPC`, which limits what a compromise reaches on the node. A compromise can still reach whatever the NetworkPolicy allows, and a kernel or container-runtime escape would bypass these controls.

### Attack Vectors Mitigated

| Vector | Mitigations | Residual risk |
|---|---|---|
| Container escape | seccomp profile, no `hostPath`, `allowPrivilegeEscalation: false` | Low |
| Privilege escalation | `allowPrivilegeEscalation: false`, capabilities dropped | Low |
| Network attacks | NetworkPolicy, own network namespace | Low |
| Filesystem access | no `hostPath`, one PVC, seccomp | Low |

### Accepted Risks

| Risk | Reason | Mitigation |
|---|---|---|
| Root execution | the HA image requires it | seccomp, capabilities dropped, no host filesystem |
| `DAC_OVERRIDE` | config files in `/config` have mixed owners | pod filesystem only, no host access |

## Security Recommendations

### Current Implementation: APPROVED

Root execution stays until HA supports a non-root image. The capability audit below decides each of the five added capabilities on its own.

### Future Improvements

| Improvement | What to do | Status |
|---|---|---|
| Rootless HA | move to non-root when HA supports it officially | not available (2025-10-26) |
| Capability audit | review the added capabilities as HA changes; if you disable an integration, remove the capabilities only it used | quarterly |
| Runtime monitoring | alert on unexpected privilege use, connections or file access with a runtime security tool | planned (Falco or Tetragon) |

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

**Conclusion:** privileged enforce with baseline audit and warn is the correct classification.
