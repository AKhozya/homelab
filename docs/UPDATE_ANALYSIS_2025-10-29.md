# Homelab Update Analysis - October 29, 2025

## Executive Summary

Analysis of recently merged Renovate updates reveals **2 critical action items** and several configuration changes that require attention.

---

## 🚨 Critical: Action Required

### 1. Authentik PostgreSQL Connection Pool (HIGH PRIORITY)

**Update**: v2025.8.4 → v2025.10.0
**Status**: ✅ Redis removed, ⚠️ Database monitoring needed

#### What Changed
- **v2025.8**: Replaced Celery with Dramatiq (stopped using Redis for tasks)
- **v2025.10**: Completely removed Redis dependency
- **ALL caching, task management, session storage now uses PostgreSQL**

#### Action Items
1. **Monitor PostgreSQL connections**: Authentik now uses ~50% more database connections
2. **Check connection pool settings**:
   ```bash
   kubectl exec -n databases couchdb-0 -c couchdb -- psql -U authentik -c "SELECT count(*) FROM pg_stat_activity WHERE datname='authentik';"
   ```
3. **Verify no performance degradation**:
   - Check Authentik logs: `kubectl logs -n authentik -l app.kubernetes.io/name=authentik --tail=100`
   - Monitor authentication latency in Grafana
   - Check for connection pool exhaustion warnings

#### Configuration Cleanup
- ✅ Redis deployments removed
- ✅ Redis manifests removed from Git
- ⚠️ **Check if Redis PVC/PV still exists**:
  ```bash
  kubectl get pvc -n authentik | grep redis
  kubectl get pv | grep redis
  ```

#### Rollback Considerations
- PostgreSQL must support TLS 1.3 or Extended Master Secret extension
- No easy rollback - v2025.10+ requires PostgreSQL-only architecture

---

### 2. External-DNS IPv6 and Traefik API Changes

**Update**: v0.18.x → v0.19.0
**Status**: ⚠️ Breaking changes may affect DNS records

#### Breaking Changes
1. **IPv6 Node Exposure (Now Default)**
   - External IPv6 addresses are now exposed automatically
   - **Impact**: May create unexpected AAAA records if IPv6 is available
   - **Rollback**: Use `--expose-internal-ipv6` flag if needed

2. **Traefik Legacy API Disabled**
   - `traefik.containo.us` API group no longer supported by default
   - **Impact**: Older Traefik IngressRoute resources may not be watched
   - **Rollback**: CLI flags available to restore v0.18 behavior

#### Action Items
1. **Verify DNS records**:
   ```bash
   # Check if unexpected AAAA records were created
   dig @1.1.1.1 AAAA *.h0melab.work
   ```
2. **Check external-dns logs**:
   ```bash
   kubectl logs -n kube-system -l app.kubernetes.io/name=external-dns --tail=100
   ```
3. **Verify Traefik integration still works**:
   - All IngressRoutes should be updated to `traefik.io` API group
   - Check if any resources use old API group:
   ```bash
   grep -r "traefik.containo.us" apps/ infrastructure/
   ```

---

## ✅ Verified: No Action Required

### Grafana Admin Password (kube-prometheus-stack v79)
**Status**: ✅ Already secure

- **Security Fix**: Removed default "prom-operator" password
- **Your Setup**: Using custom secret `grafana-admin-secret` ✓
- **Verification**: Password hash does not match default ✓
- **Action**: None needed - already secure

### Stirling-PDF v1.0.0
**Status**: ✅ No breaking changes for open-source users

- Pro features moved to proprietary folder
- OCR/compression restored to OCRMyPDF + Ghostscript
- No configuration changes required for basic deployment
- **Action**: None unless using Pro features

### Home Assistant v2025.10.4
**Status**: ✅ Maintenance release

- Bug fixes and dependency updates
- No breaking changes
- **Action**: None required

---

## 📊 Database Connection Monitoring

Since Authentik now heavily uses PostgreSQL, monitor these metrics:

### Key Metrics to Watch
```bash
# Check active connections
kubectl exec -n databases couchdb-0 -c couchdb -- psql -U postgres -c "SELECT datname, count(*) FROM pg_stat_activity GROUP BY datname;"

# Check connection pool utilization
kubectl exec -n databases couchdb-0 -c couchdb -- psql -U postgres -c "SELECT count(*), state FROM pg_stat_activity GROUP BY state;"

# Check for connection errors in Authentik
kubectl logs -n authentik -l app.kubernetes.io/name=authentik | grep -i "connection\|pool\|database"
```

### Prometheus Queries (if available)
```promql
# PostgreSQL connections by database
pg_stat_database_numbackends{datname="authentik"}

# Connection pool utilization
rate(pg_stat_database_xact_commit{datname="authentik"}[5m])
```

---

## 🔧 Recommended Database Configuration Updates

Consider increasing PostgreSQL connection limits if Authentik shows connection issues:

### Option 1: Increase max_connections
```yaml
# databases/base/couchdb/postgresql.yaml (if using custom config)
postgresql:
  max_connections: 200  # Default is usually 100
```

### Option 2: Configure Authentik Connection Pool
Check if Authentik deployment has connection pool settings:
```yaml
env:
  - name: AUTHENTIK_POSTGRESQL__MAX_CONNS
    value: "50"  # Adjust based on monitoring
  - name: AUTHENTIK_POSTGRESQL__TIMEOUT
    value: "30"
```

---

## 🎯 Next Steps

### Immediate (Today)
1. ✅ Grafana password verified - no action needed
2. ⚠️ Monitor Authentik PostgreSQL connections for 48 hours
3. ⚠️ Verify External-DNS AAAA records

### This Week
1. Check for leftover Redis PVC/PV in Authentik namespace
2. Review all DNS records for unexpected IPv6 entries
3. Confirm Traefik integration working correctly
4. Baseline PostgreSQL connection metrics in Grafana

### Ongoing
1. Implement automated changelog analysis (in progress)
2. Set up alerts for PostgreSQL connection pool exhaustion
3. Document Authentik database migration for future reference

---

## 📚 References

- [Authentik v2025.10 Release Notes](https://docs.goauthentik.io/docs/releases/2025.10)
- [Authentik v2025.8 Release Notes](https://docs.goauthentik.io/docs/releases/2025.8)
- [External-DNS v0.19.0 Release](https://github.com/kubernetes-sigs/external-dns/releases/tag/v0.19.0)
- [kube-prometheus-stack v79 Security Fix](https://github.com/prometheus-community/helm-charts/pull/5679)

---

## ⚙️ Update Review Process Going Forward

See `RENOVATE_UPDATES.md` for the new manual review process and guidelines.

**Key Changes**:
- Auto-merge disabled for all updates
- All PRs require manual review and approval
- Version changelog analysis required before merge
- Action items documented before applying updates
