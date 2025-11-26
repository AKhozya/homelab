# Stirling PDF Security Configuration

## Pod Security Standards Classification: BASELINE

**Rationale**: Stirling PDF v2.0 requires root privileges during container startup for system configuration.

---

## Why Root Privileges Are Required

### V2.0 Architecture Change

Stirling PDF v2.0 introduced a unified container architecture ("BOTH mode") that combines frontend and backend in a single container. The entrypoint script performs the following operations that require root:

1. **User/Group Management**
   - Modifies `/etc/passwd` and `/etc/group` for user permission setup
   - Attempts to run `usermod` and `groupmod` commands
   - Required for PUID/PGID environment variable support

2. **Nginx Configuration**
   - Modifies `/etc/nginx/nginx.conf` for frontend/backend routing
   - Configures nginx to proxy requests to backend on port 8081
   - Required for v2.0's split deployment capability

3. **Directory Ownership**
   - Changes ownership of application directories to stirlingpdfuser:stirlingpdfgroup
   - Uses `chown` operations for `/configs`, `/logs`, `/pipeline`, etc.

### Upstream Issue

**Status**: Rootless execution is NOT supported in v2.0
- GitHub Issue: [#1516 - Running Stirling-PDF with --user (rootless)](https://github.com/Stirling-Tools/Stirling-PDF/issues/1516)
- Marked as "enhancement", status: "Next to pickup" (as of November 2025)
- PUID/PGID environment variables do not enable true rootless execution
- Container requires root startup, then theoretically drops privileges

---

## Security Posture

### Capabilities Restrictions

Even with root user, we maintain strict capability controls:

```yaml
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: false  # v2.0 needs writable filesystem
  capabilities:
    drop: ["ALL"]  # Drop all Linux capabilities
    add: ["SETGID", "SETUID", "CHOWN", "DAC_OVERRIDE"]  # Minimal set for operation
```

**Required Capabilities**:
- **SETUID/SETGID**: Privilege dropping via su-exec (switch from root to stirlingpdfuser)
- **CHOWN**: Change directory ownership during startup
- **DAC_OVERRIDE**: Bypass file permission checks (nginx needs to access /var/lib/nginx)

**Impact**: Container runs as root but with only 4 specific Linux capabilities.

### Pod Security Standards

**Classification**: BASELINE (not RESTRICTED)

**PSS Violations from Restricted Standard**:
- ❌ `runAsNonRoot: true` - Cannot be set (requires root startup)
- ❌ `readOnlyRootFilesystem: true` - Cannot be set (v2.0 modifies system files)

**PSS Compliance with Baseline Standard**:
- ✅ `allowPrivilegeEscalation: false` - Prevents gaining additional privileges
- ✅ `capabilities.drop: ["ALL"]` - No Linux capabilities granted
- ✅ `seccompProfile: RuntimeDefault` - Syscall filtering enabled
- ✅ No host namespaces (no hostNetwork, hostPID, hostIPC)
- ✅ No host path volumes
- ✅ No privileged containers

### Additional Mitigations

1. **Network Isolation**: NetworkPolicy restricts access to:
   - Traefik namespace (internal ingress)
   - Cloudflare Tunnel namespace (external access)
   - Uptime Kuma namespace (monitoring)
   - DNS (CoreDNS)
   - Internet egress (HTTPS for metadata/updates)

2. **Seccomp Profile**: RuntimeDefault filters syscalls at kernel level

3. **No Privilege Escalation**: `allowPrivilegeEscalation: false` prevents gaining additional privileges

4. **Resource Limits**: CPU and memory limits prevent resource exhaustion

5. **Service Account**: Custom service account with minimal permissions

6. **TLS Encryption**: All ingress traffic encrypted via Let's Encrypt

---

## Comparison with Other Apps

| App            | PSS Level   | Root Required | Reason                        |
|----------------|-------------|---------------|-------------------------------|
| Stirling PDF   | BASELINE    | Yes           | v2.0 system configuration     |
| Home Assistant | PRIVILEGED  | Yes           | Bluetooth/network hardware    |
| Paperless-NGX  | BASELINE    | Yes (init)    | s6-overlay directory ownership|
| Most others    | RESTRICTED  | No            | Standard applications         |

---

## Risk Assessment

**Risk Level**: MEDIUM

**Attack Surface**:
- Container runs as root (UID 0)
- Writable filesystem allows file modifications
- If compromised, attacker has root within container

**Mitigations**:
- NetworkPolicy restricts lateral movement
- No capabilities = limited damage even as root
- Seccomp filters dangerous syscalls
- No host access (no hostPath, hostNetwork, etc.)
- Regular security updates via Renovate

**Acceptable Trade-off**: Running as root is required by application architecture. The security controls in place (no capabilities, NetworkPolicy, seccomp) reduce risk to acceptable level for homelab environment.

---

## Future Improvements

1. **Monitor Upstream**: Watch [GitHub Issue #1516](https://github.com/Stirling-Tools/Stirling-PDF/issues/1516) for rootless support
2. **Migrate When Available**: Switch to non-root deployment when v2.x supports it
3. **Regular Updates**: Keep Stirling PDF updated via Renovate for security patches

---

## References

- [Stirling PDF v2.0.0 Release Notes](https://github.com/Stirling-Tools/Stirling-PDF/releases/tag/v2.0.0)
- [GitHub Issue #1516 - Rootless execution](https://github.com/Stirling-Tools/Stirling-PDF/issues/1516)
- [v0.22.0 Release - Non-root user support](https://github.com/Stirling-Tools/Stirling-PDF/releases/tag/v0.22.0)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)

---

**Last Updated**: 2025-11-26
**Next Review**: When rootless support is added to Stirling PDF v2.x
