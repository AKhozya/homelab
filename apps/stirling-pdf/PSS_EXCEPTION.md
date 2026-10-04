# Stirling PDF Security Configuration

## Pod Security Standards Classification: BASELINE

**Rationale:** Stirling PDF needs root during container startup for system config. `deployment.yaml` pins a 3.x `frooodle/s-pdf` image; the sections below describe the v2.0 startup, which this doc has not re-checked against 3.x.

The Kyverno policies `require-non-root` and `require-readonly-rootfs` exclude this namespace (`infrastructure/configs/kyverno-policies/`).

---

## Why Root Required

### V2.0 Architecture Change

Stirling PDF v2.0 runs frontend and backend in one container ("BOTH mode"). These entrypoint steps need root:

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

### Pod Security Standards

**Classification:** BASELINE (not RESTRICTED)

**PSS Violations from Restricted:**
- `runAsNonRoot: true` — can't set (needs root startup)
- `readOnlyRootFilesystem: true` — can't set (v2.0 modifies system files)

**PSS Compliance with Baseline:**
- `allowPrivilegeEscalation: false`
- `capabilities.drop: ["ALL"]`, then the four above added back, all within baseline
- `seccompProfile: RuntimeDefault`
- No `hostNetwork`, `hostPID`, `hostIPC`, `hostPath` volumes or privileged containers

### Additional Mitigations

1. **Network Isolation:** NetworkPolicy allows:
   - ingress on port 8080 from the Traefik, Cloudflare Tunnel and Uptime Kuma namespaces
   - egress to DNS, and to TCP 443 at any destination (the manifest comment names Authentik OIDC)

2. **Resource Limits:** CPU and memory limits prevent exhaustion

3. **Service Account:** own ServiceAccount, with no API token mounted

4. **TLS Encryption:** the Traefik ingress serves a Let's Encrypt certificate

---

## Risk Assessment

**Risk Level:** MEDIUM

**Attack Surface:**
- Container runs as root (UID 0)
- Writable filesystem allows file modifications
- If compromised, attacker has root within container

**Mitigations:**
- the controls above: NetworkPolicy, four capabilities, seccomp, no host access
- security updates via Renovate

**Acceptable Trade-off:** the app needs root, and these controls reduce the risk to an acceptable level for a homelab.

---

## Future Improvements

1. **Monitor Upstream:** Watch [GitHub Issue #1516](https://github.com/Stirling-Tools/Stirling-PDF/issues/1516) for rootless support
2. **Migrate When Available:** switch to non-root when upstream supports it

---

## References

- [Stirling PDF v2.0.0 Release Notes](https://github.com/Stirling-Tools/Stirling-PDF/releases/tag/v2.0.0)
- [GitHub Issue #1516 - Rootless execution](https://github.com/Stirling-Tools/Stirling-PDF/issues/1516)
- [v0.22.0 Release - Non-root user support](https://github.com/Stirling-Tools/Stirling-PDF/releases/tag/v0.22.0)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)

---

**Last Updated:** 2025-11-26
**Next Review:** When Stirling PDF adds rootless support
