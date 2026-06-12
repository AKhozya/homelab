# NetworkPolicy Egress Audit Report
## Analysis - 2025-10-31

**Date**: 2025-10-31
**Scope**: 18 NetworkPolicy resources (apps + infra)
**Goal**: Restrict egress to required destinations

---

## EXECUTIVE SUMMARY

### Status: 9/18 Apps Unrestricted Egress (improved from 13/18)

**Findings:**
- 0 apps no Egress policy (was 1 — Immich fixed)
- 9 apps allow unrestricted HTTP/HTTPS (80/443 → ANY)
- 9 apps well-restricted (cluster-only or specific destinations)

**Risk:**
- Impact: compromised pod = unrestricted internet
- Exploit: high (lateral movement, exfil, C2)
- Mitigation: restrict egress to required destinations

---

## DETAILED FINDINGS

### Category A: NO Egress Policy (Default Allow ALL) - CRITICAL

#### 1. **Immich** (apps/base/immich/networkpolicy.yaml)
**Current**: No Egress → K8s default = allow ALL
**Risk**: CRITICAL — ANY dest, ANY port
**Needs**:
- DNS (53)
- PostgreSQL (5432, databases ns)
- Redis (6379, databases ns)
- No internet

**Fix**:
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
**Current**: 80/443/587 no dest restriction
**Needs**:
- DNS (53) — restricted
- PostgreSQL (5432) — restricted databases ns
- HTTPS external OAuth (GitHub, Google) — UNRESTRICTED
- SMTP 587 — UNRESTRICTED

**Assessment**: NEEDS UNRESTRICTED — SSO + external OAuth, IPs unpredictable

**Action**: Accept — Authentik role needs external OAuth

---

#### 3. **N8N** (apps/base/n8n/networkpolicy.yaml)
**Current**: 80/443 no dest restriction
**Needs**:
- DNS (53) — restricted
- PostgreSQL (5432) — restricted databases ns
- HTTPS webhooks + external integrations — UNRESTRICTED

**Assessment**: NEEDS UNRESTRICTED — workflow automation hits arbitrary APIs (Slack, Discord, webhooks)

**Action**: Accept — N8N purpose = arbitrary external integration

---

#### 4. **Home Assistant** (apps/base/home-assistant/networkpolicy.yaml)
**Current**: 80/443/1883/8883 no dest + local CIDRs
**Needs**:
- DNS (53) — restricted
- HTTPS IoT integrations (weather, smart home cloud) — UNRESTRICTED
- mDNS 5353 device discovery — UNRESTRICTED
- MQTT 1883/8883 — UNRESTRICTED
- Local 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 — BROAD

**Assessment**: NEEDS UNRESTRICTED — IoT hub hits hundreds of cloud services (Hue, Nest, weather)

**Action**: Accept — HA needs broad egress for IoT

---

#### 5. **Audiobookshelf** (apps/base/audiobookshelf/networkpolicy.yaml)
**Current**: 80/443 no dest restriction
**Needs**:
- DNS (53) — restricted
- HTTPS metadata (Audible, Google Books) — UNRESTRICTED

**Assessment**: CAN RESTRICT — metadata APIs known (Audible, Google Books, Open Library, iTunes)

**Fix**: restrict to known metadata provider IPs/domains (needs research)

**Action**: P2-MEDIUM — document + restrict

---

#### 6. **Linkding** (apps/base/linkding/networkpolicy.yaml)
**Current**: 80/443 no dest restriction
**Needs**:
- DNS (53) — restricted
- PostgreSQL (5432) — restricted
- HTTPS bookmark metadata — UNRESTRICTED

**Assessment**: NEEDS UNRESTRICTED — bookmark manager fetches user-submitted URLs

**Action**: Accept — Linkding purpose requires user-URL access

---

#### 7. **Mealie** (apps/base/mealie/networkpolicy.yaml)
**Current**: 80/443 no dest restriction
**Needs**:
- DNS (53) — restricted
- PostgreSQL (5432) — restricted
- HTTPS recipe scraping — UNRESTRICTED

**Assessment**: NEEDS UNRESTRICTED — recipe manager scrapes user-submitted URLs

**Action**: Accept — scraping requires arbitrary URLs

---

#### 8. **Paperless-NGX** (apps/base/paperless-ngx/networkpolicy.yaml)
**Current**: 80/443/587/465 no dest restriction
**Needs**:
- DNS (53) — restricted
- PostgreSQL (5432) — restricted
- Redis (6379) — restricted
- SMTP 587/465 — UNRESTRICTED
- HTTPS external — UNRESTRICTED

**Assessment**: SMTP CAN RESTRICT — known providers (Gmail: smtp.gmail.com)

**Fix**: restrict SMTP ports to known email provider IPs

**Action**: P3-LOW — document + restrict SMTP

---

#### 9. **Wallabag** (apps/base/wallabag/networkpolicy.yaml)
**Current**: 80/443 no dest restriction
**Needs**:
- DNS (53) — restricted
- PostgreSQL (5432) — restricted
- HTTPS article fetching — UNRESTRICTED

**Assessment**: NEEDS UNRESTRICTED — read-it-later fetches user-submitted URLs

**Action**: Accept — requires arbitrary URLs

---

#### 10. **AdGuard Home** (apps/base/adguard-home/networkpolicy.yaml)
**Current**: RESTRICTED — DNS upstream limited to trusted providers
**Needs**:
- DNS upstream Cloudflare (1.1.1.1, 1.0.0.1) — RESTRICTED
- DNS upstream Google (8.8.8.8, 8.8.4.4) — RESTRICTED
- DNS upstream Quad9 (9.9.9.9) — RESTRICTED
- DoT 853 trusted providers — RESTRICTED
- HTTPS blocklist updates 80/443 — UNRESTRICTED (GitHub, community lists)

**Assessment**: OPTIMALLY RESTRICTED — DNS exfil limited to trusted

**Action**: COMPLETE

---

#### 11. **HomeHub** (apps/base/homehub/networkpolicy.yaml)
**Current**: 443 no dest restriction
**Needs**:
- DNS (53) — restricted
- HTTPS updates/media — UNRESTRICTED

**Assessment**: CAN HEAVILY RESTRICT — HomeHub "should primarily work offline" per comment

**Fix**: remove HTTPS egress or restrict to specific update server

**Action**: P2-MEDIUM — verify HTTPS egress used, remove if not

---

#### 12. **Stirling PDF** (apps/base/stirling-pdf/networkpolicy.yaml)
**Current**: 443 no dest restriction
**Needs**:
- DNS (53) — restricted
- Authentik OIDC (9000) — restricted authentik ns
- HTTPS "general internet access if needed" — UNRESTRICTED

**Assessment**: CAN RESTRICT — PDF processor no internet

**Fix**: remove HTTPS egress entirely

**Action**: P2-MEDIUM — remove HTTPS (local-only)

---

#### 13. **Uptime Kuma** (apps/base/uptime-kuma/networkpolicy.yaml)
**Current**: 80/443 no dest restriction
**Needs**:
- DNS (53) — restricted
- HTTPS external monitoring — UNRESTRICTED
- Cluster service monitoring — restricted cluster ns

**Assessment**: NEEDS UNRESTRICTED — monitoring hits arbitrary external services

**Action**: Accept — Uptime Kuma purpose = external monitoring

---

### Category C: Well-Restricted Egress (Cluster-Only)

#### 14. **Homepage** (apps/base/homepage/networkpolicy.yaml)
**Status**: SECURE — DNS + K8s API (443 cluster ns)
**Action**: No change

---

#### 15. **CouchDB** (infrastructure/configs/base/databases/couchdb/networkpolicy.yaml)
**Status**: SECURE — DNS + intra-cluster Erlang
**Action**: No change

---

#### 16. **PostgreSQL** (infrastructure/configs/base/databases/postgres/networkpolicy.yaml)
**Status**: SECURE — Ingress only (DBs shouldn't initiate egress)
**Action**: No change

---

#### 17. **Redis** (infrastructure/configs/base/databases/redis/networkpolicy.yaml)
**Status**: SECURE — DNS egress only
**Action**: No change

---

#### 18. **CNPG Operator** (infrastructure/controllers/base/databases/postgres/networkpolicy.yaml)
**Status**: SECURE — DNS + K8s API + PostgreSQL instances
**Action**: No change

---

## RISK ANALYSIS

### Apps Requiring Unrestricted Egress (Accepted):
1. **Authentik** — external OAuth (unpredictable IPs)
2. **N8N** — workflow automation arbitrary APIs
3. **Home Assistant** — IoT hub hundreds of integrations
4. **Linkding** — bookmark metadata user URLs
5. **Mealie** — recipe scraping user URLs
6. **Wallabag** — article fetching user URLs
7. **Uptime Kuma** — monitoring arbitrary external

**Justification**: legitimate need for unrestricted internet

### Apps That Can Be Restricted:
1. **Immich** (CRITICAL) — internal services only (PG, Redis)
2. **Stirling PDF** (P2-MEDIUM) — PDF no internet
3. **HomeHub** (P2-MEDIUM) — offline per design
4. **Audiobookshelf** (P2-MEDIUM) — known metadata APIs
5. **AdGuard Home** (P3-LOW) — DNS upstream Cloudflare IPs
6. **Paperless-NGX** (P3-LOW) — SMTP known provider

---

## RECOMMENDED ACTIONS

### Immediate (This Week):
1. Fix Immich — Egress: DNS + PG + Redis only
2. Fix Stirling PDF — remove HTTPS egress
3. Fix HomeHub — remove/restrict HTTPS egress

### Short-term (This Month):
4. Audiobookshelf — research metadata IPs + restrict
5. AdGuard Home — restrict DNS upstream Cloudflare (1.1.1.1/1.0.0.1)

### Long-term:
6. Paperless-NGX — SMTP to documented provider
7. Document risk acceptance for unrestricted apps

---

## IMPLEMENTATION PLAN

### Priority 1: Immich (CRITICAL)
**Impact**: High — photo app NO egress restriction
**Effort**: 15 min
**Change**: Add Egress: DNS + PG + Redis

### Priority 2: Stirling PDF (MEDIUM)
**Impact**: Medium — PDF processor arbitrary internet
**Effort**: 5 min
**Change**: remove HTTPS egress rule

### Priority 3: HomeHub (MEDIUM)
**Impact**: Medium — offline per design
**Effort**: 10 min (verify no breakage)
**Change**: remove/restrict HTTPS egress

---

## METHODOLOGY

### Audit Process:
1. Identified 18 NetworkPolicy files
2. Read each — current egress rules
3. Analyzed legitimate needs
4. Categorized by restriction level
5. Prioritized by risk + effort

### Criteria:
- SECURE: no egress / cluster-only
- UNRESTRICTED: 80/443 → ANY
- CRITICAL: no egress policy (default allow ALL)

---

## REFERENCES

- [Kubernetes NetworkPolicy Documentation](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [HOMELAB_ANALYSIS.md](../HOMELAB_ANALYSIS.md) — original task priority
- Trivy vulnerability analysis (archived) — defense in depth

---

**Generated**: 2025-10-31
**Owner**: Homelab Staff DevOps Engineer
**Status**: Active
**Confidentiality**: Internal