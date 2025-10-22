# 🔒 HOMELAB SECURITY DOCUMENTATION

**Last Updated:** 2025-10-22
**Security Officer:** Alexander Khozya
**Infrastructure:** K3s cluster with Flux GitOps

---

## 📋 TABLE OF CONTENTS

1. [Current Security Posture](#current-security-posture)
2. [Authentication & Access Control](#authentication--access-control)
3. [Network Security](#network-security)
4. [Admin Access Strategy](#admin-access-strategy)
5. [When to Revisit Security Decisions](#when-to-revisit-security-decisions)
6. [Future Enhancements](#future-enhancements)

---

## 🎯 CURRENT SECURITY POSTURE

### Overall Assessment: **Strong (A-)**

**Strengths:**
- ✅ Centralized SSO with Authentik (7/13 apps)
- ✅ Admin user has 2FA enabled (TOTP)
- ✅ OIDC-only authentication (passwords disabled on most apps)
- ✅ All apps have NetworkPolicy (100% coverage)
- ✅ Secrets encrypted with SOPS/age
- ✅ TLS on all ingresses
- ✅ Emergency admin accounts for critical apps

**Current Risk Acceptance:**
- ⚠️ Apps accessible from local network (not public internet)
- ⚠️ Authentik admin interface accessible without VPN
- ⚠️ Single authentication layer (OIDC + 2FA, no network layer)

---

## 🔐 AUTHENTICATION & ACCESS CONTROL

### Authentik SSO Configuration

**Admin User:**
- Username: `akadmin`
- 2FA: ✅ Enabled (TOTP)
- Access: Full admin access to Authentik
- **Current Decision:** Public access allowed with 2FA protection

**Security Model:**
```
Internet/LAN → Authentik Login → 2FA → Application Access
├─ Layer 1: None (no network restriction)
├─ Layer 2: ✅ Password + TOTP (2FA)
└─ Layer 3: ✅ Application RBAC
```

**Rationale for Current Setup:**
- 2FA provides strong protection against credential compromise
- Personal homelab with limited users (not enterprise)
- Authentik kept updated with security patches
- No evidence of targeted attacks
- **Trade-off:** Convenience vs. defense-in-depth

### OIDC-Integrated Applications (7/13)

| Application | Auth Method | Local Admin | Notes |
|-------------|-------------|-------------|-------|
| **Grafana** | OIDC | Disabled | SSO-only |
| **Immich** | OIDC | Via Web UI | Configured post-deployment |
| **Paperless-NGX** | OIDC | Disabled | Env var config |
| **Linkding** | OIDC | Disabled | Env var config |
| **Mealie** | OIDC | Disabled | Env var config |
| **Audiobookshelf** | OIDC | Via Web UI | Configured post-deployment |
| **Home Assistant** | OIDC + Local | ✅ Backup | Emergency access |

### Emergency Access Strategy

**Home Assistant:**
- OIDC User: Primary admin (daily use)
- Local User: `akhozya` (emergency backup)
- Password: Complex, stored in 1Password
- **Rationale:** Physical device control requires backup access if OIDC fails

---

## 🌐 NETWORK SECURITY

### Current Network Exposure

**Internal Only (*.h0melab.work):**
- All applications accessible on local network only
- Not exposed via Cloudflare tunnel
- Traefik ingress with TLS certificates
- NetworkPolicy enforcement on all pods

**No VPN Layer:**
- Applications accessible without VPN from LAN
- Admin interfaces accessible without additional network restriction
- **Decision:** Accepted risk for personal homelab use

### NetworkPolicy Coverage

**Status:** 100% coverage (13/13 apps)

All applications have egress and ingress rules:
- DNS resolution allowed
- Monitoring endpoints allowed (Prometheus)
- Application-specific rules (database, cache, etc.)
- Default deny all other traffic

---

## 👤 ADMIN ACCESS STRATEGY

### Current Approach: **2FA Without Network Restriction**

**Decision Date:** 2025-10-22
**Decision:** Keep Authentik admin accessible from LAN with 2FA protection

### Security Layers

**Current Protection:**
1. ✅ Strong password (unique, complex)
2. ✅ TOTP 2FA (time-based one-time password)
3. ✅ Session management (Authentik)
4. ✅ Regular updates (via Renovate)

**Not Implemented:**
- ❌ IP-based restrictions (no Tailscale requirement)
- ❌ Separate admin domain
- ❌ Network-layer protection

### Risk Analysis

**Threats Mitigated:**
- ✅ Brute force attacks (2FA required)
- ✅ Credential stuffing (2FA required)
- ✅ Password leaks (2FA protects)
- ✅ Weak passwords (enforced strong password)

**Remaining Attack Vectors:**
- ⚠️ Authentik 0-day vulnerabilities (mitigated by updates)
- ⚠️ Phishing attacks (harder with 2FA but possible)
- ⚠️ Session hijacking (mitigated by secure sessions)
- ⚠️ Social engineering (user awareness required)

**Likelihood Assessment:**
- Personal homelab (not high-value target)
- Not publicly exposed to internet
- Limited user base (single admin)
- **Overall Risk:** Low to Medium

---

## 🔄 WHEN TO REVISIT SECURITY DECISIONS

### Triggers for Adding VPN Layer (Tailscale)

**IMMEDIATE - Revisit if:**
1. ❌ Apps are exposed to public internet (Cloudflare tunnel)
2. ❌ Authentik shows suspicious login attempts
3. ❌ You store highly sensitive data (financial, medical records)
4. ❌ Multiple users access the homelab
5. ❌ Compliance requirements change

**CONSIDER - Revisit if:**
1. ⚠️ You become uncomfortable with current risk
2. ⚠️ Authentik has a major security vulnerability
3. ⚠️ You want to access remotely (away from home network)
4. ⚠️ You add more critical applications
5. ⚠️ Threat model changes (targeted attacks)

**PROBABLY NOT NEEDED if:**
1. ✅ Apps remain on local network only
2. ✅ 2FA remains enabled
3. ✅ Regular security updates applied
4. ✅ No suspicious activity
5. ✅ Current risk tolerance maintained

### Monitoring & Review Schedule

**Monthly:**
- Check Authentik access logs for suspicious activity
- Verify 2FA is still enabled on admin account
- Review failed login attempts

**Quarterly:**
- Re-assess threat model
- Review this security document
- Evaluate new security features in Authentik
- Check for security advisories

**Annually:**
- Full security audit
- Penetration testing consideration
- Update risk assessment
- Review emergency access procedures

---

## 🚀 FUTURE ENHANCEMENTS

### When to Implement Tailscale + IP Policies

If you decide to add network-layer protection in the future, here's how:

#### Step 1: Install Tailscale on K3s Cluster

```yaml
# apps/base/tailscale/deployment.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: tailscale
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: tailscale
  template:
    spec:
      hostNetwork: true
      containers:
        - name: tailscale
          image: tailscale/tailscale:latest
          env:
            - name: TS_AUTHKEY
              valueFrom:
                secretKeyRef:
                  name: tailscale-auth
                  key: authkey
            - name: TS_ROUTES
              value: "10.42.0.0/16,10.43.0.0/16"
            - name: TS_STATE_DIR
              value: /var/lib/tailscale
```

#### Step 2: Create Authentik IP Reputation Policy

1. **In Authentik Admin:**
   - Navigate to: **Policies → Create → Reputation Policy**
   - Name: `Admin Tailscale Only`
   - **IP Allowlist:** `100.64.0.0/10` (Tailscale range)
   - Check: "Check IP"
   - Save

2. **Create Admin Group:**
   - Navigate to: **Directory → Groups → Create**
   - Name: `Authentik Admins`
   - Add `akadmin` to group

3. **Bind Policy to Admin Flow:**
   - Navigate to: **Flows & Stages → Flows**
   - Edit: `default-authentication-flow`
   - Add Stage: **Reputation Policy: Admin Tailscale Only**
   - Bind to: Group "Authentik Admins"

#### Step 3: Test Access

```bash
# Without Tailscale - Should FAIL
curl -I https://authentik.h0melab.work/if/admin

# With Tailscale - Should SUCCEED
tailscale up
curl -I https://authentik.h0melab.work/if/admin
```

**Result:**
- Regular users: Can log in from anywhere
- Admin users: Must connect via Tailscale first

### Alternative: Separate Admin Domain

If you prefer domain-based separation:

```yaml
# Separate ingress for admin interface
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: authentik-admin
  annotations:
    # IP allowlist middleware (Tailscale IPs only)
    traefik.ingress.kubernetes.io/router.middlewares: default-tailscale-ips@kubernetescrd
spec:
  rules:
    - host: admin-authentik.h0melab.work
      http:
        paths:
          - path: /if/admin
            pathType: Prefix
            backend:
              service:
                name: authentik
                port: 9000
```

---

## 📊 SECURITY METRICS

**Current Scores:**
- Authentication: ✅ Strong (2FA enabled)
- Network Security: ⚠️ Moderate (LAN-only, no VPN)
- Access Control: ✅ Strong (OIDC, RBAC)
- Secrets Management: ✅ Strong (SOPS encryption)
- Update Cadence: ✅ Excellent (Renovate automation)

**Overall Security Grade: A- (Strong)**

**Target Grade: A+ (Requires VPN layer or justified risk acceptance)**

---

## 📝 DECISION LOG

### 2025-10-22: Admin Access Without VPN

**Decision:** Keep Authentik admin accessible from LAN with 2FA protection (no Tailscale requirement)

**Rationale:**
- 2FA provides strong protection against most attacks
- Personal homelab (not enterprise or high-value target)
- Apps not exposed to public internet
- Convenience vs. security trade-off justified
- Can revisit if threat model changes

**Accepted Risks:**
- Authentik vulnerabilities (mitigated by updates)
- No network-layer defense in depth
- Single authentication factor type (something you know + have)

**Review Date:** 2025-11-22 (1 month)

**Signed:** Alexander Khozya (akadmin)

---

## 🆘 INCIDENT RESPONSE

### If Admin Account is Compromised

1. **Immediate:**
   - Access Authentik from trusted device
   - Change admin password immediately
   - Regenerate 2FA (new TOTP secret)
   - Revoke all sessions
   - Review audit logs for unauthorized changes

2. **Investigation:**
   - Check Authentik access logs
   - Review recent configuration changes
   - Check all application access logs
   - Identify breach source

3. **Recovery:**
   - Rotate all OIDC client secrets
   - Force re-authentication on all apps
   - Review all user accounts for unauthorized additions
   - Consider implementing VPN layer post-incident

### Emergency Access

**If Authentik is Down:**
- Home Assistant: Use local admin account (`akhozya`)
- Other apps: Restore from backup or redeploy

**Backup Admin Credentials:**
- Stored in: 1Password vault
- Emergency access: Available offline

---

## 📚 REFERENCES

- [Authentik Security Best Practices](https://goauthentik.io/docs/security/)
- [OWASP Authentication Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html)
- [Tailscale Security Model](https://tailscale.com/security/)
- [NIST Digital Identity Guidelines](https://pages.nist.gov/800-63-3/)

---

**Document Owner:** Alexander Khozya
**Next Review:** 2025-11-22
**Classification:** Internal Use Only
