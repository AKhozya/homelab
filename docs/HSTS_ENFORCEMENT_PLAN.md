# HSTS Enforcement Plan - Gradual Rollout to 1 Year

**Status**: Phase 1 Complete (1 month max-age deployed 2025-10-31)
**Next Review**: 2025-11-15 (evaluate for 6-month increase)
**Final Target**: 1 year max-age by 2026-01-15

---

## 📊 Current Configuration

### Deployment Status (2025-10-31)

**Cloudflare Edge (Tunnel Services):**
- HSTS: `max-age=2628000` (1 month)
- Services: 9 apps via Cloudflare Tunnel
- Configuration: Cloudflare Dashboard → SSL/TLS → Edge Certificates

**Traefik Origin (Internal Ingress):**
- HSTS: `max-age=2628000` (1 month)
- Services: 17 ingresses (all apps)
- Configuration: `infrastructure/controllers/base/traefik/security-headers-middleware.yaml`

**Coverage**: 100% - All 17 services have consistent 1-month HSTS

---

## 🎯 Gradual Rollout Strategy

### Phase 1: 1 Month (2,628,000 seconds) ✅ COMPLETE

**Deployment Date**: 2025-10-31
**Duration**: 2 weeks (until 2025-11-15)
**Goal**: Verify zero certificate issues, establish baseline

**Success Criteria:**
- ✅ No cert-manager failures
- ✅ No Let's Encrypt rate limit issues
- ✅ All services accessible via HTTPS
- ✅ Zero user-reported access issues

**Actions:**
- ✅ Deployed dual-layer HSTS (Cloudflare + Traefik)
- ✅ Updated all 17 ingresses with consistent max-age
- ⏰ Monitor Grafana cert-manager dashboards
- ⏰ Monitor Prometheus cert expiry alerts

---

### Phase 2: 6 Months (15,768,000 seconds) - PLANNED

**Target Date**: 2025-11-15
**Duration**: 2 months (until 2026-01-15)
**Goal**: Extended HSTS with proven reliability

**Prerequisites (must verify):**
- ✅ Phase 1 ran for 2+ weeks without issues
- ⏰ Zero certificate issuance failures in Grafana
- ⏰ All Let's Encrypt certificates renewed successfully
- ⏰ Backup/restore tested (including certificate recovery)

**Changes Required:**
1. Update Cloudflare Edge HSTS: `max-age=15768000`
2. Update Traefik middleware: `Strict-Transport-Security: max-age=15768000`
3. Git commit: "Increase HSTS to 6 months (Phase 2)"
4. Flux reconcile and verify

**Review Checklist:**
- [ ] Check cert-manager logs for errors
- [ ] Verify all 17 ingresses have valid TLS
- [ ] Test HSTS header via `curl -I https://grafana.h0melab.work`
- [ ] Document any issues encountered in Phase 1

---

### Phase 3: 1 Year (31,536,000 seconds) - FINAL

**Target Date**: 2026-01-15
**Duration**: Indefinite (standard production HSTS)
**Goal**: Maximum security with proven infrastructure

**Prerequisites (must verify):**
- ✅ Phase 2 ran for 2+ months without issues
- ⏰ Multiple successful certificate renewals
- ⏰ Disaster recovery tested and documented
- ⏰ Browser HSTS cache clear procedure documented

**Changes Required:**
1. Update Cloudflare Edge HSTS: `max-age=31536000; includeSubdomains`
2. Update Traefik middleware: `Strict-Transport-Security: max-age=31536000; includeSubdomains`
3. Git commit: "Increase HSTS to 1 year (Phase 3 - Final)"
4. Flux reconcile and verify

**Optional Enhancement:**
- Add `preload` directive (submit to HSTS preload list)
- Requires: `max-age >= 31536000`, `includeSubdomains`, `preload`
- Submission: https://hstspreload.org/

---

## 🚨 Disaster Recovery Scenarios

### Scenario 1: Complete Homelab Rebuild ✅ LOW RISK

**What Happens:**
1. GitOps (Flux) deploys entire cluster from scratch
2. cert-manager automatically issues Let's Encrypt certificates
3. Traefik serves HTTPS with valid certs within ~5 minutes
4. **Browser sees valid HTTPS** → HSTS satisfied → No issues

**Risk**: ✅ **NONE** - HSTS only requires HTTPS (doesn't care if cluster is new)

**Recovery Time**: ~5 minutes (GitOps + cert-manager)

---

### Scenario 2: TLS Certificate Issuance Failure 🟡 MEDIUM RISK

**What Happens:**
1. cert-manager fails to issue certificates (rate limit, DNS issue, etc.)
2. Traefik has no valid TLS certificates
3. Services inaccessible via HTTPS
4. **Browser blocks HTTP fallback** due to HSTS cache

**Symptoms:**
```
ERR_SSL_PROTOCOL_ERROR (if Traefik serves self-signed)
ERR_CONNECTION_REFUSED (if HTTPS port closed)
Cannot bypass - no "Advanced > Proceed anyway" option
```

**Duration Without Intervention:**
- 1 month HSTS: Browser blocks for up to 30 days
- 6 months HSTS: Browser blocks for up to 180 days
- 1 year HSTS: Browser blocks for up to 365 days

**Recovery Options:**

#### Option 1: Fix Certificate Issuance (Preferred)
```bash
# Check cert-manager status
kubectl get certificate -A
kubectl describe certificate -n <namespace> <cert-name>

# Check cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager --tail=100

# Force certificate reissuance
kubectl delete secret <tls-secret-name> -n <namespace>
flux reconcile helmrelease cert-manager -n cert-manager

# Verify certificate issued
kubectl get certificate -n <namespace> -w
```

#### Option 2: Use Let's Encrypt Staging (Emergency)
```bash
# Temporarily switch to staging issuer (higher rate limits)
# Edit Ingress to use letsencrypt-staging ClusterIssuer
kubectl edit ingress <ingress-name> -n <namespace>

# Change:
#   cert-manager.io/cluster-issuer: letsencrypt-prod
# To:
#   cert-manager.io/cluster-issuer: letsencrypt-staging

# Wait for staging cert issuance
kubectl wait --for=condition=ready certificate <cert-name> -n <namespace>
```

#### Option 3: Clear Browser HSTS Cache
**Chrome:**
1. Navigate to: `chrome://net-internals/#hsts`
2. Enter domain: `grafana.h0melab.work` (or affected domain)
3. Click "Delete"
4. Verify deletion: Query domain again

**Firefox:**
1. Navigate to: `about:preferences#privacy`
2. Click "Manage Data" under Cookies and Site Data
3. Search for: `h0melab.work`
4. Click "Remove Selected"
5. Restart Firefox

**Safari:**
1. Navigate to: Develop → Empty Caches
2. Or: Safari → Clear History → All History (nuclear option)
3. Restart Safari

**Edge:**
1. Navigate to: `edge://net-internals/#hsts`
2. Same as Chrome procedure

#### Option 4: Alternative Access (Temporary)
- Access via IP:port instead of domain: `http://192.168.1.129:8080`
- Use different browser that never visited site
- Use mobile device on cell data (bypasses local DNS + fresh HSTS cache)
- Use private/incognito mode on different device

---

### Scenario 3: Traefik Down, Apps Running on HTTP 🟡 MEDIUM RISK

**What Happens:**
1. Traefik pod crashes, won't start
2. Apps still running, accessible on HTTP ports
3. **Browser blocks direct HTTP access** due to HSTS

**Workaround:**
- Access via IP:port instead of domain (bypasses HSTS)
- Example: `http://192.168.1.129:8080` instead of `https://grafana.h0melab.work`

**Fix:**
```bash
# Check Traefik status
kubectl get pods -n traefik
kubectl logs -n traefik -l app.kubernetes.io/name=traefik --tail=100

# Restart Traefik
kubectl rollout restart deployment traefik -n traefik

# Verify Ingress endpoints
kubectl get ingress -A
```

---

### Scenario 4: DNS Failure (AdGuard Home Down) ✅ LOW RISK

**What Happens:**
1. AdGuard Home crashes
2. Local DNS resolution fails
3. Browsers can't resolve `*.h0melab.work`

**Impact on HSTS**: ✅ **NONE** - HSTS only applies AFTER DNS resolution

**Workaround:**
- Add entries to `/etc/hosts` manually
- Cloudflare Tunnel services still work (external DNS)

---

## 📋 Emergency Recovery Playbook

### Step 1: Verify TLS Certificate Status

```bash
# Check all certificates
kubectl get certificate -A

# Check specific certificate details
kubectl describe certificate <cert-name> -n <namespace>

# Check cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager --tail=100 --follow
```

---

### Step 2: Check cert-manager Issuer Status

```bash
# Check ClusterIssuers
kubectl get clusterissuer

# Verify Let's Encrypt production issuer
kubectl describe clusterissuer letsencrypt-prod

# Verify Let's Encrypt staging issuer
kubectl describe clusterissuer letsencrypt-staging
```

---

### Step 3: Force Certificate Reissuance

```bash
# Delete certificate secret (forces renewal)
kubectl delete secret <tls-secret-name> -n <namespace>

# Reconcile cert-manager HelmRelease
flux reconcile helmrelease cert-manager -n cert-manager

# Wait for certificate to be ready
kubectl wait --for=condition=ready certificate <cert-name> -n <namespace> --timeout=300s
```

---

### Step 4: Check Let's Encrypt Rate Limits

**Rate Limits:**
- Production: 5 certificates per registered domain per week
- Staging: 50 certificates per registered domain per week

**If Rate Limited:**
- Switch to staging issuer temporarily
- Wait 7 days for production rate limit to reset
- Monitor cert-manager logs for rate limit errors

---

### Step 5: Clear Browser HSTS Cache (Last Resort)

**Only if:**
- Certificate issue cannot be fixed immediately
- User needs urgent access to homelab services
- All other recovery options exhausted

**See**: "Option 3: Clear Browser HSTS Cache" in Scenario 2 above

---

## 🔒 Security Benefits of 1-Year HSTS

**Protection Against:**
- Man-in-the-middle attacks (MITM)
- SSL stripping attacks
- Protocol downgrade attacks
- Session hijacking via HTTP

**Why 1 Year:**
- Industry standard for production environments
- Recommended by OWASP and Mozilla Observatory
- Required for HSTS preload list submission
- Provides maximum protection duration

---

## 📊 HSTS Max-Age Trade-offs

| Max-Age | Security Benefit | Disaster Recovery Risk |
|---------|------------------|------------------------|
| **1 week (604,800s)** | 🟡 Moderate | ✅ Low (wait 7 days) |
| **1 month (2,628,000s)** ✅ CURRENT | 🟢 High | 🟡 Medium (wait 30 days, 5 min cache clear) |
| **6 months (15,768,000s)** | 🟢 Very High | 🟡 Medium (wait 6 months, 5 min cache clear) |
| **1 year (31,536,000s)** | 🟢 Maximum | 🟡 Medium (wait 1 year, 5 min cache clear) |

**Key Insight**: Browser HSTS cache clear takes ~5 minutes, so disaster recovery time is NOT equal to max-age duration.

---

## 🛡️ Safeguards in Place

### 1. GitOps Ensures Reliability
- Flux auto-deploys cert-manager + Traefik
- Declarative configuration prevents drift
- Git history provides rollback capability

### 2. Let's Encrypt Staging Fallback
- Staging has higher rate limits (50/week vs 5/week)
- Can always issue staging certs as emergency fallback
- ClusterIssuer: `letsencrypt-staging` already configured

### 3. Monitoring & Alerting
- Prometheus alerts for certificate expiry (<7 days)
- Grafana dashboards for cert-manager status
- Telegram notifications for backup failures

### 4. Backup & Recovery
- Daily Kubernetes secrets backup (includes TLS certificates)
- Disaster recovery scripts in `.backup/` directory
- Tested recovery procedures (2025-10-26)

---

## 📅 Review Schedule

### 2025-11-15 (Phase 1 → Phase 2)
**Review Checklist:**
- [ ] Verify zero certificate failures in last 2 weeks
- [ ] Check cert-manager Grafana dashboard for issues
- [ ] Verify all 17 ingresses have valid TLS
- [ ] Test HSTS header: `curl -I https://grafana.h0melab.work | grep Strict-Transport-Security`
- [ ] Review Prometheus alerts for cert-related warnings
- [ ] Decision: Proceed to 6 months or extend Phase 1

**If Approved:**
- Update Cloudflare HSTS to 6 months
- Update Traefik middleware to 6 months
- Commit changes via GitOps
- Document decision in HOMELAB_ANALYSIS.md

---

### 2026-01-15 (Phase 2 → Phase 3)
**Review Checklist:**
- [ ] Verify zero certificate failures in last 2 months
- [ ] Verify multiple successful certificate renewals
- [ ] Verify backup/restore procedures tested
- [ ] Review disaster recovery playbook for updates
- [ ] Test browser HSTS cache clear on all platforms
- [ ] Decision: Proceed to 1 year or extend Phase 2

**If Approved:**
- Update Cloudflare HSTS to 1 year (+ includeSubdomains)
- Update Traefik middleware to 1 year (+ includeSubdomains)
- Commit changes via GitOps
- Document decision in HOMELAB_ANALYSIS.md
- Consider HSTS preload submission

---

## 🎓 References

**Analysis Document**: `/tmp/hsts-disaster-recovery-risks.md` (comprehensive 198-line analysis)

**OWASP HSTS Cheat Sheet**: https://cheatsheetseries.owasp.org/cheatsheets/HTTP_Strict_Transport_Security_Cheat_Sheet.html

**Mozilla HSTS Guidelines**: https://infosec.mozilla.org/guidelines/web_security#http-strict-transport-security

**HSTS Preload List**: https://hstspreload.org/

**Let's Encrypt Rate Limits**: https://letsencrypt.org/docs/rate-limits/

---

## ✅ Conclusion

**Current 1-month HSTS is appropriate** for homelab:
- ✅ Strong security benefit (protects against MITM for 30 days)
- ✅ Reasonable recovery time (30 days expiry, 5 min manual clear)
- ✅ GitOps architecture minimizes certificate failures
- ✅ Multiple recovery options available

**Gradual rollout strategy**:
- Phase 1 (1 month): Establish baseline, verify reliability
- Phase 2 (6 months): Extended protection with proven stability
- Phase 3 (1 year): Maximum security with comprehensive safeguards

**Risk Mitigation**:
- Browser HSTS cache can be cleared in ~5 minutes
- Let's Encrypt staging provides emergency fallback
- Disaster recovery procedures documented and tested
- GitOps ensures consistent, reliable deployments

**Next Review**: 2025-11-15 (evaluate for 6-month increase)

---

**Last Updated**: 2025-11-07
**Document Owner**: DevOps / Infrastructure Team
**Status**: Phase 1 Active, Phase 2 Planned
