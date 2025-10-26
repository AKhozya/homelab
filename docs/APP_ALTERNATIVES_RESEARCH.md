# 🔍 Homelab App Alternatives Research
**Date**: 2025-10-26
**Purpose**: Research better alternatives to current self-hosted apps
**Current Apps**: 16 total

---

## 📊 EXECUTIVE SUMMARY

### Overall Assessment: ✅ **Current stack is excellent - minimal changes recommended**

**Key Findings:**
- ✅ **13 apps**: Best-in-class or top 3 in category (keep as-is)
- ⚠️ **2 apps**: Consider alternatives for specific use cases
- 🟢 **1 app**: Emerging competitor worth watching

**Recommendation**: **No immediate changes needed**. Current stack represents the best balance of features, stability, and community support for homelab use.

---

## 📱 DETAILED APP ANALYSIS

### 1. **Immich** (Photo Management)
**Status**: ✅ **Best in class** - Keep

**Current Version**: Using latest stable
**Primary Use**: Self-hosted Google Photos alternative

#### Alternatives Researched:
| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **PhotoPrism** | More mature, SQLite option, stable | Slower AI features, weaker facial recognition | ❌ Immich superior for AI/ML |
| **Ente Photos** | End-to-end encrypted, privacy champion | Less feature-rich, mobile-centric | ❌ Immich better for homelab |
| **Nextcloud Photos** | All-in-one platform | Slower, heavier, less focused | ❌ Immich more specialized |
| **LibrePhotos** | Good AI features | Less polished, smaller community | ❌ Immich more active |

**Recommendation**: **KEEP IMMICH**
- Immich is the clear leader in self-hosted photo management in 2024-2025
- Active development, best-in-class AI features
- Strong community (76K+ GitHub stars)
- Perfect fit for homelab use case

---

### 2. **Paperless-NGX** (Document Management)
**Status**: ✅ **Best in class** - Keep

**Current Version**: Using latest stable
**Primary Use**: Document scanning, OCR, archiving

#### Alternatives Researched:
| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **Papra** | Minimalist UI, simple | No file sharing, limited auto-tagging, no mobile app | ❌ Less feature-rich |
| **Docspell** | Easier to use, email archiving | Smaller community | 🟡 Consider for email focus |
| **Mayan EDMS** | Feature-rich, enterprise-ready | Heavier, more complex | ❌ Overkill for homelab |
| **Papermerge DMS** | Good scanning features | Less mature than Paperless-NGX | ❌ Paperless-NGX superior |

**Recommendation**: **KEEP PAPERLESS-NGX**
- Industry-leading document management for self-hosting
- Excellent OCR, tagging, and search capabilities
- Active development and community
- Perfect balance of features and simplicity

**Note**: Consider **Docspell** if you need heavy email archiving functionality

---

### 3. **N8N** (Workflow Automation)
**Status**: ⚠️ **Consider alternatives** for specific use cases

**Current Version**: Community Edition
**Primary Use**: Workflow automation
**Limitation**: SSO requires Enterprise plan

#### Alternatives Researched:
| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **Windmill** | Much lighter (287MB vs 516MB), Rust-based, code-first, faster | Learning curve for non-devs | 🟢 **Strong alternative** |
| **Temporal** | Mission-critical reliability, durable execution | SDK-based, requires coding, Go-focused | ❌ Too enterprise for homelab |
| **Activepieces** | Open-source, visual | Less mature | 🟡 Watch this space |
| **Automatisch** | N8N clone, open-source | Smaller community | ❌ N8N more established |
| **Apache Airflow** | Enterprise-grade, Python-based | Heavy, complex | ❌ Overkill |

**Recommendation**: **CONSIDER WINDMILL**

**Why switch?**
- ✅ **Performance**: 44% less memory (287MB vs 516MB)
- ✅ **Speed**: Rust-based scheduler "destroys competition"
- ✅ **Reliability**: Auto-retry from checkpoints, <5s recovery
- ✅ **Developer-friendly**: Use existing Python/TS/Go/Bash scripts
- ✅ **Lighter**: Better fit for homelab resource constraints

**Why stay with N8N?**
- ✅ **User-friendly**: Visual workflow editor is more accessible
- ✅ **Mature**: More integrations and community resources
- ✅ **Current investment**: Already configured and working

**Decision**: **Trial Windmill in parallel**, migrate if performance gains are significant. N8N is fine for current workloads.

---

### 4. **Authentik** (SSO/Identity Provider)
**Status**: ✅ **Best for homelab** - Keep

**Current Version**: Latest stable
**Primary Use**: OIDC/SSO for 8 apps

#### Alternatives Researched:
| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **Keycloak** | Enterprise-standard, Red Hat backed, mature | Heavy (Java-based), complex UI | ❌ Overkill for homelab |
| **Zitadel** | Modern, API-first, event-sourced | License change to AGPL-3.0 in v3 | 🟡 Watch for license issues |
| **Authelia** | Lightweight, simple | Not a full IdP, just forward auth | ❌ Less feature-rich |
| **FreeIPA** | Enterprise LDAP | Complex, legacy | ❌ Too enterprise |

**Recommendation**: **KEEP AUTHENTIK**
- Perfect balance for small-to-medium homelab deployments
- Clean UI, "flow" system for custom auth journeys
- Active community and development
- Already integrated with 8 apps

**Note**: If homelab grows to 50+ apps or multi-tenant, consider **Keycloak**

---

### 5. **AdGuard Home** (DNS Filtering)
**Status**: ✅ **Best in class** - Keep

**Current Version**: Using :latest (⚠️ needs pinning)
**Primary Use**: Network-wide ad blocking, DNS management

#### Alternatives Researched:
| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **Pi-hole** | Most popular, huge community, bulk blocklist import | Lacks DoH/DoT by default, older UI | ❌ AdGuard more modern |
| **Blocky** | Very DevOps-friendly, K8s-native | Less user-friendly UI | 🟡 Consider for K8s-only |
| **Technitium** | Feature-rich, built-in DHCP | Less community support | ❌ AdGuard more popular |

**Recommendation**: **KEEP ADGUARD HOME**
- Best UI among DNS blockers
- Built-in DoH/DoT/DoQ support
- Modern, actively developed
- Perfect for homelab use

**Action Required**: Pin to specific version (not :latest)

**Alternative Worth Watching**: **Blocky** if you want pure Kubernetes-native deployment with YAML configuration

---

### 6. **Uptime Kuma** (Monitoring)
**Status**: ✅ **Best for homelab** - Keep

**Current Version**: 2.0.2-slim-rootless
**Primary Use**: Service uptime monitoring

#### Alternatives Researched:
| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **Gatus** | Lightweight, YAML config, no database | Less polished UI, smaller community (8.8K vs 76K stars) | 🟡 Consider for config-as-code |
| **Statping-ng** | Beautiful graphs, simple | Original project abandoned (ng is fork) | ❌ Less maintained |
| **HertzBeat** | Feature-rich, advanced observability | Heavier, more complex | ❌ Overkill |
| **Checkmk** | Enterprise-grade | Complex, heavy | ❌ Too enterprise |

**Recommendation**: **KEEP UPTIME KUMA**
- Industry-leading for self-hosted uptime monitoring
- 76K+ GitHub stars (8.6x more than Gatus)
- Beautiful UI, easy setup
- Perfect for homelab scale

**Alternative Worth Watching**: **Gatus** if you prefer configuration-as-code (YAML) over database storage

---

### 7. **Other Apps Analysis**

#### ✅ **Keep All** - Best in class or no better alternatives:

| App | Status | Reasoning |
|-----|--------|-----------|
| **Homepage** | ✅ Keep | Best self-hosted dashboard, active development |
| **Grafana** | ✅ Keep | Industry standard, no competition |
| **Prometheus** | ✅ Keep | De facto Kubernetes monitoring |
| **Home Assistant** | ✅ Keep | Best smart home platform |
| **Mealie** | ✅ Keep | Best recipe manager |
| **Wallabag** | ✅ Keep | Best read-it-later for self-hosting |
| **Linkding** | ✅ Keep | Best bookmark manager |
| **Audiobookshelf** | ✅ Keep | Best audiobook server |
| **Stirling PDF** | ✅ Keep | Best PDF toolkit |
| **HomeHub** | ✅ Keep | Simple family dashboard, fits need |
| **Obsidian/CouchDB** | ✅ Keep | Best for Obsidian sync |

---

## 🎯 PRIORITY RECOMMENDATIONS

### Immediate Actions (This Week)

1. ✅ **Pin AdGuard Home version** - HIGH PRIORITY
   - Current: `adguard/adguardhome:latest`
   - Change to: `adguard/adguardhome:v0.107.52` (or current stable)
   - Reason: Security and stability

### Evaluation (This Month)

2. 🟡 **Trial Windmill alongside N8N** - MEDIUM PRIORITY
   - Deploy Windmill in separate namespace
   - Migrate 1-2 workflows to test
   - Compare performance and usability
   - Decision: Keep whichever fits workflow better

### Long Term (3 Months)

3. 🟢 **Monitor these emerging projects**:
   - **Windmill**: May replace N8N if performance gains significant
   - **Blocky**: K8s-native alternative to AdGuard Home
   - **Gatus**: Lightweight alternative to Uptime Kuma
   - **Zitadel v3**: Watch license changes (AGPL-3.0)

---

## 📈 COMPARISON MATRICES

### Performance Comparison (Memory Usage)

| App | Current Memory | Alternative | Alt Memory | Savings |
|-----|----------------|-------------|------------|---------|
| N8N | 185Mi | Windmill | ~130Mi | 30% |
| Uptime Kuma | 127Mi | Gatus | ~50Mi | 61% |
| AdGuard Home | 120Mi | Pi-hole | 138Mi | -15% (worse) |
| Authentik | 1080Mi total | Keycloak | ~2Gi+ | -50% (worse) |

**Conclusion**: Only **Windmill** and **Gatus** offer significant performance improvements, but both trade features for performance.

### Feature Comparison

| Category | Current | Best Alternative | Winner |
|----------|---------|-----------------|--------|
| Photo Management | Immich | PhotoPrism | ✅ Immich |
| Document Mgmt | Paperless-NGX | Docspell | ✅ Paperless-NGX |
| Workflow | N8N | Windmill | 🟡 Depends on use case |
| SSO | Authentik | Keycloak | ✅ Authentik (for homelab) |
| DNS Filter | AdGuard Home | Pi-hole | ✅ AdGuard Home |
| Uptime Monitor | Uptime Kuma | Gatus | ✅ Uptime Kuma |

---

## 🔍 DETAILED MIGRATION ANALYSIS

### If Migrating to Windmill from N8N

**Pros**:
- 44% less memory usage
- Faster execution (Rust scheduler)
- Better reliability (auto-retry, checkpoints)
- Code-first approach (version control friendly)
- Support for Python, TypeScript, Go, Bash, SQL

**Cons**:
- Learning curve for visual workflows → code
- Fewer pre-built integrations
- Smaller community (though growing)
- Migration effort required

**Migration Complexity**: MEDIUM (2-4 hours)
**Recommended Approach**:
1. Deploy Windmill in parallel
2. Migrate 1-2 simple workflows
3. Test for 2 weeks
4. Decide based on experience

**Verdict**: **Worth evaluating** if you're comfortable with code-first approach and want better performance.

---

## 📊 STACK GRADE ANALYSIS

### Current Stack Grade: **A+ (96/100)**

**Breakdown**:
- Photo Management (Immich): 10/10
- Document Management (Paperless-NGX): 10/10
- Workflow Automation (N8N): 8/10 (SSO limitation, performance)
- SSO (Authentik): 10/10
- DNS (AdGuard Home): 9.5/10 (using :latest)
- Monitoring (Uptime Kuma): 10/10
- Other apps: 9.5/10 average

### Potential Stack Grade (with Windmill): **A+ (97/100)**

**Change**: N8N 8/10 → Windmill 9/10

---

## 🎯 FINAL RECOMMENDATIONS

### Keep (13 apps): ✅
- Immich, Paperless-NGX, Authentik, AdGuard Home, Uptime Kuma
- Homepage, Grafana, Prometheus, Home Assistant
- Mealie, Wallabag, Linkding, Audiobookshelf, Stirling PDF, HomeHub

### Evaluate (1 app): 🟡
- N8N → Consider Windmill trial

### Action Items: 📋
1. Pin AdGuard Home version (10 min)
2. Optionally trial Windmill (2-4 hours)

### Overall Verdict: ✅
**Your current app stack is excellent**. Only one app (N8N) has a potentially better alternative (Windmill), and even that depends on your workflow preferences. No urgent changes needed.

---

**Report Generated**: 2025-10-26
**Next Review**: 2026-01-26 (Quarterly)
