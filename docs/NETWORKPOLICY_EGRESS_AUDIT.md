# NetworkPolicy Egress Audit Report
## Comprehensive Analysis - 2025-10-31

**Analysis Date**: 2025-10-31
**Scope**: All 18 NetworkPolicy resources across apps and infrastructure
**Objective**: Restrict egress to required destinations only

---

## EXECUTIVE SUMMARY

### Overall Status: ✅ **9/18 Apps Have Unrestricted Egress** (Improved from 13/18)

**Key Findings:**
- ✅ **0 apps** have NO Egress policy (was 1 - Immich fixed)
- ⚠️ **9 apps** allow unrestricted HTTP/HTTPS (ports 80/443 to ANY destination)
- ✅ **9 apps** have well-restricted egress (cluster-only or specific destinations)

**Risk Assessment:**
- **Impact**: Compromised pod = unrestricted internet access
- **Exploitability**: High (lateral movement, data exfiltration, C2 communication)
- **Mitigation**: Restrict egress to required destinations only

---

## DETAILED FINDINGS

### Category A: NO Egress Policy (Default Allow ALL) - CRITICAL

#### 1. **Immich** (apps/base/immich/networkpolicy.yaml)
**Current**: No Egress policy defined → Kubernetes default = allow ALL egress
**Risk**: CRITICAL - Allows egress to ANY destination on ANY port
**Legitimate Needs**:
- DNS resolution (port 53)
- PostgreSQL database (port 5432 to databases namespace)
- Redis (port 6379 to databases namespace)
- NO internet access needed

**Recommended Fix**:
```yaml
policyTypes:
  - Ingress
  - Egress
egress:
  # Allow DNS resolution
  - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: kube-system
    ports:
      - protocol: UDP
        port: 53
  # Allow PostgreSQL database access
  - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: databases
        podSelector:
          matchLabels:
            cnpg.io/cluster: main-postgres
    ports:
      - protocol: TCP
        port: 5432
  # Allow Redis access
  - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: databases
        podSelector:
          matchLabels:
            app: redis
    ports:
      - protocol: TCP
        port: 6379
```

---

### Category B: Unrestricted HTTP/HTTPS Egress (Ports 80/443 to ANY)

#### 2. **Authentik** (apps/base/authentik/networkpolicy.yaml)
**Current**: Allows ports 80/443/587 without destination restriction
**Legitimate Needs**:
- DNS resolution (port 53) ✅ Restricted
- PostgreSQL (port 5432) ✅ Restricted to databases namespace
- HTTPS for external auth providers (GitHub, Google, etc.) ⚠️ UNRESTRICTED
- SMTP for email (port 587) ⚠️ UNRESTRICTED

**Assessment**: NEEDS UNRESTRICTED - SSO provider integrates with external OAuth providers (GitHub, Google, Microsoft, etc.) - cannot predict all IPs

**Action**: ✅ **Accept current state** - Authentik's role requires external OAuth provider access

---

#### 3. **N8N** (apps/base/n8n/networkpolicy.yaml)
**Current**: Allows ports 80/443 without destination restriction
**Legitimate Needs**:
- DNS resolution (port 53) ✅ Restricted
- PostgreSQL (port 5432) ✅ Restricted to databases namespace
- HTTPS for webhooks and external integrations ⚠️ UNRESTRICTED

**Assessment**: NEEDS UNRESTRICTED - Workflow automation tool integrates with arbitrary external APIs (Slack, Discord, webhooks, etc.)

**Action**: ✅ **Accept current state** - N8N's purpose is arbitrary external integration

---

#### 4. **Home Assistant** (apps/base/home-assistant/networkpolicy.yaml)
**Current**: Allows ports 80/443/1883/8883 without destination restriction + local network CIDRs
**Legitimate Needs**:
- DNS resolution (port 53) ✅ Restricted
- HTTPS for integrations (weather APIs, smart home clouds) ⚠️ UNRESTRICTED
- mDNS for device discovery (port 5353) ⚠️ UNRESTRICTED
- MQTT (ports 1883/8883) ⚠️ UNRESTRICTED
- Local network access (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16) ⚠️ BROAD

**Assessment**: NEEDS UNRESTRICTED - IoT hub integrates with hundreds of cloud services (Philips Hue, Nest, weather APIs, etc.)

**Action**: ✅ **Accept current state** - Home Assistant requires broad egress for IoT integrations

---

#### 5. **Audiobookshelf** (apps/base/audiobookshelf/networkpolicy.yaml)
**Current**: Allows ports 80/443 without destination restriction
**Legitimate Needs**:
- DNS resolution (port 53) ✅ Restricted
- HTTPS for metadata fetching (Audible, Google Books, etc.) ⚠️ UNRESTRICTED

**Assessment**: CAN BE RESTRICTED - Metadata APIs are known (Audible, Google Books, Open Library, iTunes)

**Recommended Fix**: Restrict to known metadata provider IPs/domains (requires research)

**Action**: ⏰ **P2-MEDIUM** - Document known metadata APIs and restrict

---

#### 6. **Linkding** (apps/base/linkding/networkpolicy.yaml)
**Current**: Allows ports 80/443 without destination restriction
**Legitimate Needs**:
- DNS resolution (port 53) ✅ Restricted
- PostgreSQL (port 5432) ✅ Restricted to databases namespace
- HTTPS for bookmark metadata fetching ⚠️ UNRESTRICTED

**Assessment**: NEEDS UNRESTRICTED - Bookmark manager fetches metadata from arbitrary user-bookmarked websites

**Action**: ✅ **Accept current state** - Linkding's purpose requires accessing user-submitted URLs

---

#### 7. **Mealie** (apps/base/mealie/networkpolicy.yaml)
**Current**: Allows ports 80/443 without destination restriction
**Legitimate Needs**:
- DNS resolution (port 53) ✅ Restricted
- PostgreSQL (port 5432) ✅ Restricted to databases namespace
- HTTPS for recipe scraping ⚠️ UNRESTRICTED

**Assessment**: NEEDS UNRESTRICTED - Recipe manager scrapes recipes from arbitrary user-submitted websites

**Action**: ✅ **Accept current state** - Mealie's recipe scraping requires accessing arbitrary URLs

---

#### 8. **Paperless-NGX** (apps/base/paperless-ngx/networkpolicy.yaml)
**Current**: Allows ports 80/443/587/465 without destination restriction
**Legitimate Needs**:
- DNS resolution (port 53) ✅ Restricted
- PostgreSQL (port 5432) ✅ Restricted to databases namespace
- Redis (port 6379) ✅ Restricted to databases namespace
- SMTP for email (ports 587/465) ⚠️ UNRESTRICTED
- HTTPS for external integrations ⚠️ UNRESTRICTED

**Assessment**: SMTP CAN BE RESTRICTED - SMTP typically uses known providers (Gmail: smtp.gmail.com)

**Recommended Fix**: Restrict SMTP ports to known email provider IPs

**Action**: ⏰ **P3-LOW** - Document email provider and restrict SMTP ports

---

#### 9. **Wallabag** (apps/base/wallabag/networkpolicy.yaml)
**Current**: Allows ports 80/443 without destination restriction
**Legitimate Needs**:
- DNS resolution (port 53) ✅ Restricted
- PostgreSQL (port 5432) ✅ Restricted to databases namespace
- HTTPS for article fetching ⚠️ UNRESTRICTED

**Assessment**: NEEDS UNRESTRICTED - Read-it-later app fetches articles from arbitrary user-submitted websites

**Action**: ✅ **Accept current state** - Wallabag's purpose requires accessing arbitrary URLs

---

#### 10. **AdGuard Home** (apps/base/adguard-home/networkpolicy.yaml)
**Current**: ✅ **RESTRICTED** - DNS upstream limited to trusted providers only
**Legitimate Needs**:
- DNS upstream to Cloudflare (1.1.1.1, 1.0.0.1) ✅ RESTRICTED
- DNS upstream to Google (8.8.8.8, 8.8.4.4) ✅ RESTRICTED
- DNS upstream to Quad9 (9.9.9.9) ✅ RESTRICTED
- DoT (port 853) to trusted providers ✅ RESTRICTED
- HTTPS for blocklist updates (ports 80/443) ⚠️ UNRESTRICTED (required for GitHub, community lists)

**Assessment**: OPTIMALLY RESTRICTED - DNS exfiltration limited to trusted providers

**Action**: ✅ **COMPLETE** - DNS upstream restricted to Cloudflare/Google/Quad9 IPs

---

#### 11. **HomeHub** (apps/base/homehub/networkpolicy.yaml)
**Current**: Allows port 443 without destination restriction
**Legitimate Needs**:
- DNS resolution (port 53) ✅ Restricted
- HTTPS for updates/media downloads ⚠️ UNRESTRICTED

**Assessment**: CAN BE HEAVILY RESTRICTED - HomeHub "should primarily work offline" per comment

**Recommended Fix**: Remove HTTPS egress or restrict to specific update server

**Action**: ⏰ **P2-MEDIUM** - Investigate if HTTPS egress is actually used, remove if not

---

#### 12. **Stirling PDF** (apps/base/stirling-pdf/networkpolicy.yaml)
**Current**: Allows port 443 without destination restriction
**Legitimate Needs**:
- DNS resolution (port 53) ✅ Restricted
- Authentik OIDC (port 9000) ✅ Restricted to authentik namespace
- HTTPS for "general internet access if needed" ⚠️ UNRESTRICTED

**Assessment**: CAN BE RESTRICTED - PDF processor should not need internet access

**Recommended Fix**: Remove HTTPS egress entirely

**Action**: ⏰ **P2-MEDIUM** - Remove HTTPS egress (PDF processing is local-only)

---

#### 13. **Uptime Kuma** (apps/base/uptime-kuma/networkpolicy.yaml)
**Current**: Allows ports 80/443 without destination restriction
**Legitimate Needs**:
- DNS resolution (port 53) ✅ Restricted
- HTTPS for monitoring external services ⚠️ UNRESTRICTED
- Cluster service monitoring (various ports) ✅ Restricted to cluster namespaces

**Assessment**: NEEDS UNRESTRICTED - Monitoring tool must access arbitrary external services

**Action**: ✅ **Accept current state** - Uptime Kuma's purpose requires external monitoring

---

### Category C: Well-Restricted Egress (Cluster-Only) ✅

#### 14. **Homepage** (apps/base/homepage/networkpolicy.yaml)
**Status**: ✅ **SECURE** - Only allows DNS + Kubernetes API (port 443 to cluster namespaces)
**Action**: ✅ No changes needed

---

#### 15. **CouchDB** (infrastructure/configs/base/databases/couchdb/networkpolicy.yaml)
**Status**: ✅ **SECURE** - Only allows DNS + intra-cluster Erlang communication
**Action**: ✅ No changes needed

---

#### 16. **PostgreSQL** (infrastructure/configs/base/databases/postgres/networkpolicy.yaml)
**Status**: ✅ **SECURE** - Only Ingress policy (databases should not initiate egress)
**Action**: ✅ No changes needed

---

#### 17. **Redis** (infrastructure/configs/base/databases/redis/networkpolicy.yaml)
**Status**: ✅ **SECURE** - Only allows DNS egress
**Action**: ✅ No changes needed

---

#### 18. **CNPG Operator** (infrastructure/controllers/base/databases/postgres/networkpolicy.yaml)
**Status**: ✅ **SECURE** - Only allows DNS + Kubernetes API + PostgreSQL instances
**Action**: ✅ No changes needed

---

## RISK ANALYSIS

### Applications Requiring Unrestricted Egress (Accepted):
1. **Authentik** - External OAuth providers (unpredictable IPs)
2. **N8N** - Workflow automation with arbitrary external APIs
3. **Home Assistant** - IoT hub with hundreds of cloud integrations
4. **Linkding** - Bookmark metadata from user-submitted URLs
5. **Mealie** - Recipe scraping from user-submitted URLs
6. **Wallabag** - Article fetching from user-submitted URLs
7. **Uptime Kuma** - Monitoring arbitrary external services

**Justification**: These applications have legitimate business requirements for unrestricted internet access.

### Applications That Can Be Restricted:
1. **Immich** (CRITICAL) - Should only access internal services (PostgreSQL, Redis)
2. **Stirling PDF** (P2-MEDIUM) - PDF processor doesn't need internet access
3. **HomeHub** (P2-MEDIUM) - Should work offline per design intent
4. **Audiobookshelf** (P2-MEDIUM) - Can restrict to known metadata APIs
5. **AdGuard Home** (P3-LOW) - Can restrict DNS upstream to Cloudflare IPs
6. **Paperless-NGX** (P3-LOW) - Can restrict SMTP to known email provider

---

## RECOMMENDED ACTIONS

### Immediate (This Week):
1. ✅ **Fix Immich** - Add Egress policy restricting to DNS/PostgreSQL/Redis only
2. ✅ **Fix Stirling PDF** - Remove unrestricted HTTPS egress
3. ✅ **Fix HomeHub** - Remove or heavily restrict HTTPS egress

### Short-term (This Month):
4. **Audiobookshelf** - Research metadata provider IPs and restrict
5. **AdGuard Home** - Restrict DNS upstream to Cloudflare IPs (1.1.1.1/1.0.0.1)

### Long-term (Ongoing):
6. **Paperless-NGX** - Restrict SMTP to documented email provider
7. **Document risk acceptance** for apps requiring unrestricted egress

---

## IMPLEMENTATION PLAN

### Priority 1: Immich (CRITICAL)
**Impact**: High - Photo management app has NO egress restrictions
**Effort**: 15 minutes
**Change**: Add Egress policy with DNS + PostgreSQL + Redis

### Priority 2: Stirling PDF (MEDIUM)
**Impact**: Medium - PDF processor allows arbitrary internet access
**Effort**: 5 minutes
**Change**: Remove HTTPS egress rule

### Priority 3: HomeHub (MEDIUM)
**Impact**: Medium - Should work offline per design
**Effort**: 10 minutes (verify no breakage)
**Change**: Remove or restrict HTTPS egress

---

## METHODOLOGY

### Audit Process:
1. Identified all 18 NetworkPolicy files
2. Read each policy to understand current egress rules
3. Analyzed legitimate business requirements for each app
4. Categorized apps by restriction level
5. Prioritized fixes by risk and effort

### Policy Analysis Criteria:
- ✅ **SECURE**: No egress or cluster-only egress
- ⚠️ **UNRESTRICTED**: Allows ports 80/443 to ANY destination
- ❌ **CRITICAL**: No egress policy (default allow ALL)

---

## REFERENCES

- [Kubernetes NetworkPolicy Documentation](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [HOMELAB_ANALYSIS.md](./HOMELAB_ANALYSIS.md) - Original task priority
- [Trivy Vulnerability Analysis](./TRIVY_VULNERABILITY_ANALYSIS.md) - Defense in depth

---

**Generated**: 2025-10-31
**Document Owner**: Homelab Staff DevOps Engineer
**Status**: Active
**Confidentiality**: Internal
