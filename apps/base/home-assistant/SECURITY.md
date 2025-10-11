# Home Assistant Security Assessment

**Last Updated:** 2025-10-11
**Status:** ⚠️  Running as root with elevated capabilities (unavoidable for Home Assistant)

---

## Current Security Posture

### ✅ Security Measures in Place

1. **Seccomp Profile**
   - `seccompProfile: RuntimeDefault` - Restricts syscalls to only those needed
   - Provides defense-in-depth against container breakout attempts

2. **Privilege Escalation Prevention**
   - `allowPrivilegeEscalation: false` - Prevents gaining additional privileges
   - Container cannot acquire more capabilities than it was granted

3. **Capability Management**
   - Default: DROP ALL capabilities
   - Only specific capabilities added back:
     - `CAP_NET_BIND_SERVICE` - Bind to privileged ports (< 1024)
     - `CAP_NET_RAW` - Raw socket access (for Ping integration, Bluetooth)
     - `CAP_NET_ADMIN` - Network configuration (for mDNS, Bluetooth)
     - `CAP_CHOWN` - Change file ownership
     - `CAP_SETGID` - Set group ID
     - `CAP_SETUID` - Set user ID
     - `CAP_DAC_OVERRIDE` - Bypass file permission checks

4. **Network Isolation**
   - NetworkPolicy enforced
   - Ingress: Only port 8123 from cluster
   - Egress: DNS, HTTP/S, mDNS, MQTT, private networks only
   - No direct internet exposure (behind Traefik ingress)

5. **Resource Limits**
   - CPU: 200m request, 2000m limit
   - Memory: 512Mi request, 2Gi limit
   - Prevents resource exhaustion attacks

6. **TLS Encryption**
   - Valid Let's Encrypt certificate
   - HTTPS enforced via Traefik ingress
   - External URL properly configured

---

## ⚠️ Security Limitations

### Running as Root User

**Status:** Cannot be changed
**Reason:** Home Assistant officially requires root access and does not support non-root operation

**Risk:** If the container is compromised:
- Attacker has root privileges inside the container
- Could potentially escape to the host (mitigated by seccomp + capabilities)
- Can modify any file in the container filesystem

**Mitigation:**
- Seccomp profile limits syscalls available to attacker
- `allowPrivilegeEscalation: false` prevents gaining more privileges
- NetworkPolicy limits network access
- No privileged mode or hostPath volumes

### Elevated Capabilities

**High-Risk Capabilities Currently Granted:**

1. **CAP_SETUID + CAP_SETGID**
   - **Risk:** Can change to any user/group, including root
   - **Why needed:** Home Assistant's internal process management
   - **Assessment:** Redundant since already running as root, consider removing

2. **CAP_DAC_OVERRIDE**
   - **Risk:** Can bypass all file permission checks
   - **Why needed:** Read/write to config files regardless of permissions
   - **Assessment:** High risk but probably required for HA functionality

3. **CAP_CHOWN**
   - **Risk:** Can change ownership of any file
   - **Why needed:** Managing config file ownership
   - **Assessment:** Moderate risk, likely required

**Medium-Risk Capabilities:**

4. **CAP_NET_ADMIN**
   - **Risk:** Can modify network configuration
   - **Why needed:** mDNS discovery, Bluetooth setup
   - **Assessment:** Required for device discovery features
   - **Note:** mDNS actually works via NetworkPolicy allowing UDP 5353, not via this capability

5. **CAP_NET_RAW**
   - **Risk:** Can use raw sockets, craft packets
   - **Why needed:** Ping integration, Bluetooth
   - **Assessment:** Required for network diagnostics
   - **Note:** Only remove if you don't use Ping or Bluetooth integrations

**Low-Risk Capabilities:**

6. **CAP_NET_BIND_SERVICE**
   - **Risk:** Can bind to privileged ports (< 1024)
   - **Why needed:** NOT NEEDED - Home Assistant runs on port 8123
   - **Assessment:** ✅ **Can be safely removed**

---

## Recommendations

### Immediate Actions (Low Risk)

1. **Remove CAP_NET_BIND_SERVICE**
   - Not needed since Home Assistant runs on port 8123 (non-privileged)
   - Reduces attack surface

### Evaluation Required (Test Before Applying)

2. **Consider removing CAP_SETUID and CAP_SETGID**
   - Since already running as root, these may be redundant
   - Test: Remove and verify Home Assistant starts and functions normally
   - Risk: May break internal process management

3. **Add read-only root filesystem**
   - Set `readOnlyRootFilesystem: true`
   - Keep `/config` and `/tmp` as writable volumes
   - Prevents attacker from modifying system files
   - Test: May break Home Assistant if it writes to other locations

### Future Monitoring

4. **Monitor for privilege escalation exploits**
   - Subscribe to Home Assistant security advisories
   - Keep container image updated with `renovate`

5. **Regular capability audits**
   - Periodically review if all capabilities are still needed
   - Remove unused integrations that require elevated capabilities

---

## Comparison with Similar Services

| Service | User | Capabilities | Risk Level |
|---------|------|--------------|------------|
| **Home Assistant** | root | 7 capabilities including SETUID, DAC_OVERRIDE | ⚠️ High |
| **Grafana** | grafana (non-root) | None | ✅ Low |
| **Prometheus** | nobody (non-root) | None | ✅ Low |
| **Alertmanager** | nobody (non-root) | None | ✅ Low |
| **CouchDB** | couchdb (non-root) | None | ✅ Low |

**Assessment:** Home Assistant has significantly higher privilege requirements than other services in the cluster.

---

## Threat Model

### Threat: Container Escape
- **Likelihood:** Low (mitigated by seccomp, no privileged mode)
- **Impact:** Critical (root access to worker node)
- **Mitigation:** Keep kernel updated, monitor security advisories

### Threat: Compromised Home Assistant Process
- **Likelihood:** Medium (internet-facing via Traefik)
- **Impact:** High (root access to container, all capabilities)
- **Mitigation:**
  - NetworkPolicy limits lateral movement
  - No sensitive secrets mounted (credentials stored in config files)
  - Regular updates via Renovate

### Threat: Malicious Integration/Plugin
- **Likelihood:** Medium (if installing community integrations)
- **Impact:** High (full container access)
- **Mitigation:**
  - Only install trusted integrations
  - Review integration code before installation
  - Monitor for unusual network activity

### Threat: Configuration File Tampering
- **Likelihood:** Low (requires container access)
- **Impact:** High (can modify authentication, add backdoors)
- **Mitigation:**
  - Backup `/config` regularly
  - Monitor configuration changes
  - Use version control for critical config files

---

## Hardening Checklist

- [x] Seccomp profile enabled (RuntimeDefault)
- [x] Privilege escalation disabled
- [x] Capabilities dropped by default
- [x] Only necessary capabilities added
- [x] NetworkPolicy enforced
- [x] Resource limits set
- [x] TLS enabled with valid certificate
- [x] No privileged mode
- [x] No hostPath volumes
- [x] No host networking
- [ ] Remove CAP_NET_BIND_SERVICE (recommended)
- [ ] Test removing CAP_SETUID/CAP_SETGID (optional)
- [ ] Add read-only root filesystem (test required)
- [ ] Regular security audits scheduled

---

## Alternative Approaches (Not Recommended)

### 1. LinuxServer.io Image with PUID/PGID
- Unofficial image that supports non-root via PUID/PGID
- **Risk:** Not officially supported, may lag behind official releases
- **Verdict:** Not recommended for production

### 2. Podman Rootless
- Run container without root privileges on the host
- **Risk:** Complex setup, may have compatibility issues
- **Verdict:** Possible but requires significant testing

### 3. Run as Non-Root (Unsupported)
- Modify official image to run as UID 1000
- **Risk:** Officially unsupported, will likely break
- **Verdict:** Not recommended

---

## Conclusion

Home Assistant's security posture is **acceptable for home/personal use** given:
1. Not running in privileged mode
2. NetworkPolicy limits blast radius
3. No direct internet exposure
4. Regular updates via Renovate

However, it remains the **highest-risk service** in the cluster due to:
1. Running as root
2. Elevated capabilities (SETUID, DAC_OVERRIDE, etc.)
3. Complex attack surface (many integrations)

**Recommendation:** Accept the risk as unavoidable for Home Assistant, focus on:
- Keeping it updated
- Only installing trusted integrations
- Monitoring for suspicious activity
- Regular backups of configuration

**Next Steps:**
1. Remove `CAP_NET_BIND_SERVICE` (safe, immediate benefit)
2. Test removing `CAP_SETUID`/`CAP_SETGID` in a dev environment
3. Document which integrations require which capabilities
4. Set up configuration backup automation

---

**References:**
- [Home Assistant Community: Docker Security](https://community.home-assistant.io/t/best-security-practices-with-docker-ha/540702)
- [Home Assistant: WTH Non-Root Not Supported](https://community.home-assistant.io/t/wth-its-not-possible-to-use-a-non-root-account-for-docker-image/806208)
- [Linux Capabilities Man Page](https://man7.org/linux/man-pages/man7/capabilities.7.html)
