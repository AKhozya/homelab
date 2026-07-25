# HOMELAB SECURITY DOCUMENTATION

**Last Updated:** 2026-07-14
**Infrastructure:** K3s cluster (v1.36.2+k3s1) with Flux GitOps

This homelab leans on defense-in-depth rather than any single control. Secrets are SOPS/age-encrypted in git, Kyverno admission policies block non-compliant workloads before they schedule, and every namespace runs under default-deny NetworkPolicies plus Pod Security Standards. User-facing access flows through Authentik SSO, and anything reachable from outside the LAN goes over a Cloudflare Tunnel — so the cluster keeps zero inbound ports open to the internet. The sections below document the current posture, the trade-offs accepted for a personal single-admin setup, and the triggers that would justify tightening it further.

---

## TABLE OF CONTENTS

1. [Current Security Posture](#current-security-posture)
2. [Authentication & Access Control](#authentication--access-control)
3. [Network Security](#network-security)
4. [Admin Access Strategy](#admin-access-strategy)
5. [When to Revisit Security Decisions](#when-to-revisit-security-decisions)
6. [Future Enhancements](#future-enhancements)

---

## CURRENT SECURITY POSTURE

### Overall Assessment

**Strengths:**
- Centralized SSO with Authentik — 7 of 17 apps via OIDC, plus homepage via forward-auth
- Admin user 2FA enabled (TOTP)
- OIDC-only (passwords disabled most apps)
- NetworkPolicy default-deny across all 28 namespaces (64 policy resources)
- Kyverno admission policies enforced (12 ClusterPolicies: 9 Enforce, 3 in Audit soak)
- Secrets SOPS/age encrypted
- TLS on all ingresses
- Emergency admin accounts for critical apps

**Current Risk Acceptance:**
- Apps accessible local network (not public internet)
- Authentik admin accessible without VPN
- Single auth layer (OIDC + 2FA, no network layer)

---

## AUTHENTICATION & ACCESS CONTROL

### Authentik SSO Configuration

**Admin User:**
- Username: `akadmin`
- 2FA: Enabled (TOTP)
- Access: full admin to Authentik
- **Decision**: public access allowed with 2FA protection

**Security Model:**
```
Internet/LAN → Authentik Login → 2FA → Application Access
├─ Layer 1: None (no network restriction)
├─ Layer 2: ✅ Password + TOTP (2FA)
└─ Layer 3: ✅ Application RBAC
```

**Rationale:**
- 2FA strong protection vs credential compromise
- Personal homelab, limited users (not enterprise)
- Authentik kept updated
- No evidence of targeted attacks
- **Trade-off**: convenience vs defense-in-depth

### OIDC-Integrated Applications (7 of 16)

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
- OIDC User: primary admin (daily)
- Local User: `akhozya` (emergency backup)
- Password: complex, stored in 1Password
- **Rationale**: physical device control needs backup if OIDC fails

---

## NETWORK SECURITY

### Current Network Exposure

**Internal Only (*.h0melab.work):**
- All apps accessible local network only
- Not exposed via Cloudflare tunnel
- Traefik ingress + TLS certs
- NetworkPolicy on all pods

**No VPN Layer:**
- Apps accessible without VPN from LAN
- Admin interfaces no extra network restriction
- **Decision**: accepted risk for personal use

### NetworkPolicy Coverage

**Status**: default-deny NetworkPolicies across every namespace, covering all apps (live inventory count in HOMELAB_ANALYSIS.md)

All apps have egress + ingress rules:
- DNS allowed
- Monitoring endpoints allowed (Prometheus)
- App-specific rules (DB, cache)
- Default deny other traffic

---

## ADMIN ACCESS STRATEGY

### Current: **2FA Without Network Restriction**

**Decision Date**: 2025-10-22
**Decision**: keep Authentik admin accessible from LAN with 2FA

### Security Layers

**Current Protection:**
1. Strong password (unique, complex)
2. TOTP 2FA (time-based)
3. Session management (Authentik)
4. Updates (via Renovate)

**Not Implemented:**
- IP-based restrictions (no Tailscale)
- Separate admin domain
- Network-layer protection

### Risk Analysis

**Threats Mitigated:**
- Brute force (2FA required)
- Credential stuffing (2FA required)
- Password leaks (2FA protects)
- Weak passwords (enforced strong)

**Remaining Attack Vectors:**
- Authentik 0-day (mitigated by updates)
- Phishing (harder with 2FA)
- Session hijacking (mitigated by secure sessions)
- Social engineering (user awareness)

**Likelihood:**
- Personal homelab (not high-value target)
- Not publicly exposed
- Single admin
- **Overall Risk**: Low to Medium

---

## WHEN TO REVISIT SECURITY DECISIONS

### Triggers for VPN Layer (Tailscale)

**IMMEDIATE — Revisit if:**
1. Apps exposed to public internet (Cloudflare tunnel)
2. Authentik shows suspicious logins
3. Store highly sensitive data (financial, medical)
4. Multiple users access homelab
5. Compliance requirements change

**CONSIDER — Revisit if:**
1. Uncomfortable with current risk
2. Authentik major vuln
3. Want remote access (off home network)
4. Add more critical apps
5. Threat model changes (targeted attacks)

**PROBABLY NOT NEEDED if:**
1. Apps stay local network only
2. 2FA stays enabled
3. Security updates applied
4. No suspicious activity
5. Risk tolerance maintained

### Monitoring & Review

**Monthly:**
- Authentik access logs — suspicious activity
- Verify 2FA still on admin
- Review failed logins

**Quarterly:**
- Re-assess threat model
- Review this doc
- Evaluate new Authentik features
- Check security advisories

**Annually:**
- Full security audit
- Pen testing consideration
- Update risk assessment
- Review emergency access procedures

---

## FUTURE ENHANCEMENTS

### When to Implement Tailscale + IP Policies

#### Step 1: Install Tailscale on K3s Cluster

```yaml
# apps/tailscale/deployment.yaml
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
   - Navigate: **Policies → Create → Reputation Policy**
   - Name: `Admin Tailscale Only`
   - **IP Allowlist**: `100.64.0.0/10` (Tailscale range)
   - Check: "Check IP"
   - Save

2. **Create Admin Group:**
   - Navigate: **Directory → Groups → Create**
   - Name: `Authentik Admins`
   - Add `akadmin`

3. **Bind Policy to Admin Flow:**
   - Navigate: **Flows & Stages → Flows**
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
- Regular users: log in from anywhere
- Admin users: must connect via Tailscale first

### Alternative: Separate Admin Domain

Domain-based separation:

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

## SECURITY POSTURE BY AREA

| Area | State | Notes |
|------|-------|-------|
| Authentication | Strong | 2FA (TOTP) on admin |
| Network Security | Moderate | LAN-only, no VPN layer |
| Access Control | Strong | OIDC + RBAC |
| Secrets | Strong | SOPS/age encryption |
| Updates | Strong | Automated via Renovate |

The main gap is the absence of a network-layer (VPN) control in front of admin interfaces. That is a deliberate trade-off for a personal, LAN-only setup — see the triggers below for when it should be revisited.

---

## DECISION LOG

### 2025-10-22: Admin Access Without VPN

**Decision**: Keep Authentik admin accessible from LAN with 2FA protection (no Tailscale requirement)

**Rationale:**
- 2FA strong protection vs most attacks
- Personal homelab (not enterprise/high-value)
- Apps not publicly exposed
- Convenience vs security trade-off justified
- Can revisit if threat model changes

**Accepted Risks:**
- Authentik vulns (mitigated by updates)
- No network-layer defense in depth
- Single auth factor type (know + have)

**Review Date**: 2025-11-22 (1 month)

---

## INCIDENT RESPONSE

### If Admin Account Compromised

1. **Immediate:**
   - Access Authentik from trusted device
   - Change admin password
   - Regenerate 2FA (new TOTP)
   - Revoke all sessions
   - Review audit logs

2. **Investigation:**
   - Check Authentik access logs
   - Review recent config changes
   - Check all app access logs
   - Identify breach source

3. **Recovery:**
   - Rotate OIDC client secrets
   - Force re-auth on all apps
   - Review user accounts for unauthorized adds
   - Consider VPN layer post-incident

### Emergency Access

**If Authentik Down:**
- Home Assistant: local admin (`akhozya`)
- Other apps: restore from backup or redeploy

**Backup Admin Credentials:**
- Stored in: 1Password vault
- Emergency access: available offline

---

## REFERENCES

- [Authentik Security Best Practices](https://goauthentik.io/docs/security/)
- [OWASP Authentication Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html)
- [Tailscale Security Model](https://tailscale.com/security/)
- [NIST Digital Identity Guidelines](https://pages.nist.gov/800-63-3/)

---

**Next Review**: 2026-07-04
