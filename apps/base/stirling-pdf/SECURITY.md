# Stirling PDF Security Configuration

## Pod Security Standards Classification: BASELINE

**Rationale:** Stirling PDF v2.0 needs root during container startup for system config.

---

## Why Root Required

### V2.0 Architecture Change

Stirling PDF v2.0 = unified container arch ("BOTH mode"): frontend + backend in single container. Entrypoint script ops need root:

1. **User/Group Management**
   - Modifies `/etc/passwd` + `/etc/group`
   - Runs `usermod` + `groupmod`
   - Required for PUID/PGID env var support

2. **Nginx Configuration**
   - Modifies `/etc/nginx/nginx.conf` for frontend/backend routing
   - Configures nginx proxy → backend port 8081
   - Required for v2.0 split deployment

3. **Directory Ownership**
   - Changes app dir ownership → stirlingpdfuser:stirlingpdfgroup
   - `chown` ops for `/configs`, `/logs`, `/pipeline`, etc.

### Upstream Issue

**Status:** Rootless NOT supported in v2.0
- GitHub Issue: [#1516 - Running Stirling-PDF with --user (rootless)](https://github.com/Stirling-Tools/Stirling-PDF/issues/1516)
- Marked "enhancement", status "Next to pickup" (Nov 2025)
- PUID/PGID vars don't enable true rootless
- Container needs root startup, then theoretically drops privileges

---

## Security Posture

### Capabilities Restrictions

Even with root, strict capability controls:

```yaml
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: false  # v2.0 needs writable filesystem
  capabilities:
    drop: ["ALL"]  # Drop all Linux capabilities
    add: ["SETGID", "SETUID", "CHOWN", "DAC_OVERRIDE"]  # Minimal set for operation
```

**Required Capabilities:**
- **SETUID/SETGID:** Privilege drop via su-exec (root → stirlingpdfuser)
- **CHOWN:** Change dir ownership at startup
- **DAC_OVERRIDE:** Bypass file permission checks (nginx needs /var/lib/nginx)

**Impact:** Container runs as root but only 4 specific Linux capabilities.

### Pod Security Standards

**Classification:** BASELINE (not RESTRICTED)

**PSS Violations from Restricted:**
- `runAsNonRoot: true` — can't set (needs root startup)
- `readOnlyRootFilesystem: true` — can't set (v2.0 modifies system files)

**PSS Compliance with Baseline:**
- `allowPrivilegeEscalation: false` — prevents gaining privileges
- `capabilities.drop: ["ALL"]` — no Linux caps granted
- `seccompProfile: RuntimeDefault` — syscall filtering on
- No host namespaces (no hostNetwork, hostPID, hostIPC)
- No host path volumes
- No privileged containers

### Additional Mitigations

1. **Network Isolation:** NetworkPolicy restricts access to:
   - Traefik namespace (internal ingress)
   - Cloudflare Tunnel namespace (external access)
   - Uptime Kuma namespace (monitoring)
   - DNS (CoreDNS)
   - Internet egress (HTTPS for metadata/updates)

2. **Seccomp Profile:** RuntimeDefault filters syscalls at kernel level

3. **No Privilege Escalation:** `allowPrivilegeEscalation: false` prevents gaining privileges

4. **Resource Limits:** CPU + memory limits prevent exhaustion

5. **Service Account:** Custom SA, minimal perms

6. **TLS Encryption:** All ingress traffic via Let's Encrypt

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

**Risk Level:** MEDIUM

**Attack Surface:**
- Container runs as root (UID 0)
- Writable filesystem allows file modifications
- If compromised, attacker has root within container

**Mitigations:**
- NetworkPolicy restricts lateral movement
- No capabilities = limited damage even as root
- Seccomp filters dangerous syscalls
- No host access (no hostPath, hostNetwork, etc.)
- Regular security updates via Renovate

**Acceptable Trade-off:** Root required by app architecture. Security controls (no caps, NetworkPolicy, seccomp) reduce risk to acceptable for homelab.

---

## Future Improvements

1. **Monitor Upstream:** Watch [GitHub Issue #1516](https://github.com/Stirling-Tools/Stirling-PDF/issues/1516) for rootless support
2. **Migrate When Available:** Switch to non-root when v2.x supports
3. **Regular Updates:** Keep Stirling PDF updated via Renovate

---

## References

- [Stirling PDF v2.0.0 Release Notes](https://github.com/Stirling-Tools/Stirling-PDF/releases/tag/v2.0.0)
- [GitHub Issue #1516 - Rootless execution](https://github.com/Stirling-Tools/Stirling-PDF/issues/1516)
- [v0.22.0 Release - Non-root user support](https://github.com/Stirling-Tools/Stirling-PDF/releases/tag/v0.22.0)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)

---

**Last Updated:** 2025-11-26
**Next Review:** When rootless support added to Stirling PDF v2.x
