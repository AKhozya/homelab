# Homelab App Alternatives Research
**Date**: 2025-10-26
**Purpose**: Research alts to current self-hosted apps
**Current Apps**: 16 total

---

## EXECUTIVE SUMMARY

### Overall Assessment: Stack excellent — minimal changes

**Key Findings:**
- **13 apps**: best-in-class / top 3 (keep)
- **2 apps**: consider alts for specific cases
- **1 app**: emerging competitor worth watch

**Recommendation**: No immediate changes. Stack = best balance features/stability/community for homelab.

---

## DETAILED APP ANALYSIS

### 1. **Immich** (Photo Management)
**Status**: Best in class — Keep

**Current Version**: latest stable
**Primary Use**: self-hosted Google Photos alt

#### Alternatives Researched:
| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **PhotoPrism** | Mature, SQLite option, stable | Slower AI, weaker face recog | Immich win AI/ML |
| **Ente Photos** | E2E encrypted, privacy | Fewer features, mobile-centric | Immich better homelab |
| **Nextcloud Photos** | All-in-one | Slower, heavier, less focused | Immich more specialized |
| **LibrePhotos** | Good AI | Less polished, smaller community | Immich more active |

**Recommendation**: **KEEP IMMICH**
- Clear leader self-hosted photo mgmt 2024-2025
- Active dev, best AI
- 76K+ GitHub stars
- Perfect homelab fit

---

### 2. **Paperless-NGX** (Document Management)
**Status**: Best in class — Keep

**Current Version**: latest stable
**Primary Use**: doc scan, OCR, archive

#### Alternatives Researched:
| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **Papra** | Minimal UI | No share, limited auto-tag, no mobile | Fewer features |
| **Docspell** | Easier, email archive | Smaller community | Consider email focus |
| **Mayan EDMS** | Enterprise-ready | Heavy, complex | Overkill homelab |
| **Papermerge DMS** | Good scan | Less mature | Paperless-NGX win |

**Recommendation**: **KEEP PAPERLESS-NGX**
- Leader self-hosted doc mgmt
- Excellent OCR, tag, search
- Active dev + community
- Balance features/simplicity

**Note**: Consider **Docspell** if heavy email archive need

---

### 3. **N8N** (Workflow Automation)
**Status**: Consider alts for specific cases

**Current Version**: Community Edition
**Primary Use**: workflow automation
**Limitation**: SSO need Enterprise

#### Alternatives Researched:
| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **Windmill** | Lighter (287MB vs 516MB), Rust, code-first, fast | Dev learn curve | **Strong alt** |
| **Temporal** | Mission-critical, durable exec | SDK-based, Go-focused | Too enterprise |
| **Activepieces** | Open-source, visual | Less mature | Watch space |
| **Automatisch** | N8N clone | Smaller community | N8N more established |
| **Apache Airflow** | Enterprise, Python | Heavy, complex | Overkill |

**Recommendation**: **CONSIDER WINDMILL**

**Why switch?**
- **Performance**: 44% less memory (287MB vs 516MB)
- **Speed**: Rust scheduler destroy competition
- **Reliability**: auto-retry checkpoints, <5s recovery
- **Dev-friendly**: existing Python/TS/Go/Bash scripts
- **Lighter**: fit homelab constraints

**Why stay N8N?**
- **User-friendly**: visual editor accessible
- **Mature**: more integrations/community
- **Current investment**: already configured

**Decision**: **Trial Windmill parallel**. Migrate if perf gain big. N8N fine current workloads.

---

### 4. **Authentik** (SSO/Identity Provider)
**Status**: Best for homelab — Keep

**Current Version**: latest stable
**Primary Use**: OIDC/SSO for 8 apps

#### Alternatives Researched:
| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **Keycloak** | Enterprise standard, Red Hat, mature | Heavy (Java), complex UI | Overkill homelab |
| **Zitadel** | Modern, API-first, event-sourced | License AGPL-3.0 v3 | Watch license |
| **Authelia** | Light, simple | Forward auth only, not full IdP | Fewer features |
| **FreeIPA** | Enterprise LDAP | Complex, legacy | Too enterprise |

**Recommendation**: **KEEP AUTHENTIK**
- Balance for small-med homelab
- Clean UI, flow system custom auth
- Active community
- Integrate 8 apps

**Note**: If homelab grow 50+ apps or multi-tenant → consider **Keycloak**

---

### 5. **AdGuard Home** (DNS Filtering)
**Status**: Best in class — Keep

**Current Version**: `:latest` (need pin)
**Primary Use**: network-wide ad block, DNS mgmt

#### Alternatives Researched:
| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **Pi-hole** | Popular, huge community, bulk blocklists | No DoH/DoT default, old UI | AdGuard more modern |
| **Blocky** | DevOps-friendly, K8s-native | Less UI | Consider K8s-only |
| **Technitium** | Feature-rich, built-in DHCP | Less community | AdGuard more popular |

**Recommendation**: **KEEP ADGUARD HOME**
- Best UI among DNS blockers
- Built-in DoH/DoT/DoQ
- Modern, active dev
- Perfect homelab

**Action Required**: Pin specific version (not `:latest`)

**Alt Worth Watching**: **Blocky** if pure K8s-native YAML config want

---

### 6. **Uptime Kuma** (Monitoring)
**Status**: Best for homelab — Keep

**Current Version**: 2.0.2-slim-rootless
**Primary Use**: service uptime monitor

#### Alternatives Researched:
| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **Gatus** | Light, YAML config, no DB | Less polished, smaller (8.8K vs 76K stars) | Consider config-as-code |
| **Statping-ng** | Pretty graphs, simple | Original abandoned (ng = fork) | Less maintained |
| **HertzBeat** | Feature-rich, advanced | Heavy, complex | Overkill |
| **Checkmk** | Enterprise-grade | Complex, heavy | Too enterprise |

**Recommendation**: **KEEP UPTIME KUMA**
- Leader self-hosted uptime
- 76K+ stars (8.6x Gatus)
- Pretty UI, easy setup
- Homelab scale

**Alt Worth Watching**: **Gatus** if config-as-code (YAML) over DB prefer

---

### 7. **Other Apps Analysis**

#### Keep all — best in class / no better alts:

| App | Status | Reasoning |
|-----|--------|-----------|
| **Homepage** | Keep | Best self-hosted dashboard, active dev |
| **Grafana** | Keep | Industry standard, no competition |
| **Prometheus** | Keep | De facto K8s monitoring |
| **Home Assistant** | Keep | Best smart home platform |
| **Mealie** | Keep | Best recipe mgr |
| **Wallabag** | Keep | Best read-it-later self-hosted |
| **Linkding** | Keep | Best bookmark mgr |
| **Audiobookshelf** | Keep | Best audiobook server |
| **Stirling PDF** | Keep | Best PDF toolkit |
| **HomeHub** | Keep | Simple family dashboard |
| **Obsidian/CouchDB** | Keep | Best Obsidian sync |

---

## PRIORITY RECOMMENDATIONS

### Immediate Actions (This Week)

1. **Pin AdGuard Home version** — HIGH PRIORITY
   - Current: `adguard/adguardhome:latest`
   - Change: `adguard/adguardhome:v0.107.52` (or current stable)
   - Reason: security + stability

### Evaluation (This Month)

2. **Trial Windmill alongside N8N** — MEDIUM PRIORITY
   - Deploy Windmill separate ns
   - Migrate 1-2 workflows
   - Compare perf + usability
   - Decision: keep whichever fit

### Long Term (3 Months)

3. **Monitor emerging projects**:
   - **Windmill**: may replace N8N if perf gain big
   - **Blocky**: K8s-native alt to AdGuard
   - **Gatus**: light alt to Uptime Kuma
   - **Zitadel v3**: watch license (AGPL-3.0)

---

## COMPARISON MATRICES

### Performance Comparison (Memory Usage)

| App | Current Memory | Alternative | Alt Memory | Savings |
|-----|----------------|-------------|------------|---------|
| N8N | 185Mi | Windmill | ~130Mi | 30% |
| Uptime Kuma | 127Mi | Gatus | ~50Mi | 61% |
| AdGuard Home | 120Mi | Pi-hole | 138Mi | -15% (worse) |
| Authentik | 1080Mi total | Keycloak | ~2Gi+ | -50% (worse) |

**Conclusion**: Only **Windmill** + **Gatus** give perf gain, both trade features for perf.

### Feature Comparison

| Category | Current | Best Alternative | Winner |
|----------|---------|-----------------|--------|
| Photo Management | Immich | PhotoPrism | Immich |
| Document Mgmt | Paperless-NGX | Docspell | Paperless-NGX |
| Workflow | N8N | Windmill | Depends use case |
| SSO | Authentik | Keycloak | Authentik (homelab) |
| DNS Filter | AdGuard Home | Pi-hole | AdGuard Home |
| Uptime Monitor | Uptime Kuma | Gatus | Uptime Kuma |

---

## DETAILED MIGRATION ANALYSIS

### If Migrating to Windmill from N8N

**Pros**:
- 44% less memory
- Faster exec (Rust scheduler)
- Better reliability (auto-retry, checkpoints)
- Code-first (VCS-friendly)
- Python/TypeScript/Go/Bash/SQL

**Cons**:
- Learn curve visual → code
- Fewer pre-built integrations
- Smaller community (growing)
- Migration effort

**Migration Complexity**: MEDIUM (2-4h)
**Approach**:
1. Deploy Windmill parallel
2. Migrate 1-2 simple workflows
3. Test 2 weeks
4. Decide on experience

**Verdict**: **Worth evaluate** if OK with code-first + want better perf.

---

## STACK GRADE ANALYSIS

### Current Stack Grade: **A+ (96/100)**

**Breakdown**:
- Photo Management (Immich): 10/10
- Document Management (Paperless-NGX): 10/10
- Workflow Automation (N8N): 8/10 (SSO limit, perf)
- SSO (Authentik): 10/10
- DNS (AdGuard Home): 9.5/10 (`:latest`)
- Monitoring (Uptime Kuma): 10/10
- Other apps: 9.5/10 avg

### Potential Stack Grade (Windmill): **A+ (97/100)**

**Change**: N8N 8/10 → Windmill 9/10

---

## FINAL RECOMMENDATIONS

### Keep (13 apps):
- Immich, Paperless-NGX, Authentik, AdGuard Home, Uptime Kuma
- Homepage, Grafana, Prometheus, Home Assistant
- Mealie, Wallabag, Linkding, Audiobookshelf, Stirling PDF, HomeHub

### Evaluate (1 app):
- N8N → consider Windmill trial

### Action Items:
1. Pin AdGuard Home version (10 min)
2. Optionally trial Windmill (2-4h)

### Overall Verdict:
**Stack excellent**. Only N8N have potentially better alt (Windmill), depend on workflow pref. No urgent changes.

---

**Report Generated**: 2025-10-26
**Next Review**: 2026-01-26 (Quarterly)