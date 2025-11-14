# VictoriaMetrics Migration Plan
**Date Created:** 2025-11-14
**Duration:** 7 days
**Strategy:** Side-by-side deployment with gradual cutover

---

## Executive Summary

**Goal:** Replace kube-prometheus-stack with victoria-metrics-k8s-stack to reduce memory usage from 2.5GB to ~400MB (85% reduction).

**Decisions Made:**
- ✅ **VMSingle** (not VMCluster) - optimal for homelab
- ✅ **Side-by-side migration** - run both systems for 7 days
- ✅ **Reuse existing Grafana** - just add new datasource
- ✅ **7-day timeline** - safe validation period

**Current State:**
- Prometheus memory: 2.5Gi limit, ~1-1.2Gi baseline, ~2Gi peaks
- Retention: 7 days
- Kubelet scrape interval: 30s
- API server histograms: dropped
- All optimizations applied via commits: ed3fd97, c32553f, e09d9bf, 2b46565, 3851c2a

---

## Phase 1: Preparation (30 min)

### 1.1 Create Backup Directory
```bash
cd /Users/akhozya/source-code/homelab
mkdir -p .migration-backups/prometheus-to-vm-$(date +%Y%m%d)
cd .migration-backups/prometheus-to-vm-$(date +%Y%m%d)
```

### 1.2 Backup Current Configuration
```bash
# Export Prometheus CRD
kubectl get prometheus -n monitoring kube-prometheus-stack-prometheus -o yaml > prometheus.yaml

# Export all ServiceMonitors
kubectl get servicemonitor -A -o yaml > servicemonitors.yaml

# Export all PodMonitors
kubectl get podmonitor -A -o yaml > podmonitors.yaml

# Export all PrometheusRules
kubectl get prometheusrule -A -o yaml > prometheusrules.yaml

# Export AlertManager config
kubectl get secret -n monitoring alertmanager-kube-prometheus-stack-alertmanager -o yaml > alertmanager-secret.yaml

# Export Grafana datasources
kubectl get configmap -n monitoring kube-prometheus-stack-grafana -o yaml > grafana-configmap.yaml
```

### 1.3 Document Current Resource Usage
```bash
# Prometheus
kubectl top pod -n monitoring prometheus-kube-prometheus-stack-prometheus-0
# Expected: ~1-1.2Gi baseline

# Get TSDB stats
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- \
  wget -qO- http://localhost:9090/api/v1/status/tsdb | jq . > prometheus-tsdb-stats.json
```

### 1.4 Count Current Metrics
```bash
# Save for comparison later
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- \
  wget -qO- 'http://localhost:9090/api/v1/label/__name__/values' | \
  jq '.data | length' > prometheus-metric-count.txt
```

---

## Phase 2: Install VictoriaMetrics Operator (15 min)

### 2.1 Create Namespace and Directory Structure
```bash
cd /Users/akhozya/source-code/homelab
mkdir -p monitoring/controllers/base/victoria-metrics-operator
mkdir -p monitoring/controllers/staging/victoria-metrics-k8s-stack
```

### 2.2 Create Operator HelmRelease

**File:** `monitoring/controllers/base/victoria-metrics-operator/repository.yaml`
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: victoriametrics
  namespace: monitoring
spec:
  interval: 24h
  url: https://victoriametrics.github.io/helm-charts/
```

**File:** `monitoring/controllers/base/victoria-metrics-operator/release.yaml`
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: victoria-metrics-operator
  namespace: monitoring
spec:
  interval: 6h
  chart:
    spec:
      chart: victoria-metrics-operator
      version: "0.37.x"  # Check latest: https://github.com/VictoriaMetrics/helm-charts
      sourceRef:
        kind: HelmRepository
        name: victoriametrics
        namespace: monitoring
      interval: 12h
  install:
    crds: Create
    remediation:
      retries: 3
  upgrade:
    crds: CreateReplace
    remediation:
      retries: 3
  values:
    # Auto-convert Prometheus CRDs to VictoriaMetrics
    operator:
      enable_converter_ownership: true
      prometheus_converter_add_conv_label: true

    # Enable conversion for all Prometheus CRDs
    env:
      - name: VM_ENABLEDPROMETHEUSCONVERTER_SERVICEMONITOR
        value: "true"
      - name: VM_ENABLEDPROMETHEUSCONVERTER_PODMONITOR
        value: "true"
      - name: VM_ENABLEDPROMETHEUSCONVERTER_PROMETHEUSRULE
        value: "true"
      - name: VM_ENABLEDPROMETHEUSCONVERTER_PROBE
        value: "true"
```

**File:** `monitoring/controllers/base/victoria-metrics-operator/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - repository.yaml
  - release.yaml
```

### 2.3 Add to Flux
**Update:** `monitoring/controllers/staging/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../base/victoria-metrics-operator
  - ../base/kube-prometheus-stack  # Keep both during migration
  - ../base/loki-stack
```

### 2.4 Apply and Verify
```bash
cd /Users/akhozya/source-code/homelab
git add monitoring/controllers/base/victoria-metrics-operator
git commit -m "Add VictoriaMetrics operator for side-by-side migration"
git push

flux reconcile source git flux-system --timeout=45s
flux reconcile kustomization monitoring-controllers --timeout=60s

# Wait for operator to be ready
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=victoria-metrics-operator -n monitoring --timeout=120s

# Verify CRD conversion started
kubectl get vmservicescrape -A
kubectl get vmpodscrape -A
kubectl get vmrule -A
```

---

## Phase 3: Deploy VictoriaMetrics Stack (30 min)

### 3.1 Create Values File

**File:** `monitoring/controllers/staging/victoria-metrics-k8s-stack/values.yaml`
```yaml
# VictoriaMetrics K8s Stack - Side-by-side with Prometheus
# Migration period: 7 days
# Expected memory: 300-500Mi (vs Prometheus 2.5Gi)

# VMSingle - Time-series database
victoria-metrics-single:
  enabled: true
  server:
    name: vmsingle
    retentionPeriod: "7d"  # Match Prometheus

    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 512Mi  # 80% less than Prometheus!

    storageSpec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: local-path
      resources:
        requests:
          storage: 50Gi  # Match Prometheus

    # Expose metrics for monitoring
    serviceMonitor:
      enabled: true

# VMAgent - Metrics scraper
vmagent:
  enabled: true
  spec:
    scrapeInterval: 30s  # Match optimized Prometheus config
    externalLabels:
      cluster: homelab

    resources:
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        cpu: 200m
        memory: 256Mi

    # ServiceMonitor scraping
    serviceScrapeNamespaceSelector: {}
    serviceScrapeSelector: {}
    podScrapeNamespaceSelector: {}
    podScrapeSelector: {}

    # Auto-discover converted ServiceMonitors/PodMonitors
    selectAllByDefault: true

# VMAlert - Alert evaluation
vmalert:
  enabled: true
  spec:
    evaluationInterval: 30s

    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 100m
        memory: 128Mi

    # Point to existing AlertManager
    notifiers:
      - url: http://kube-prometheus-stack-alertmanager.monitoring.svc:9093

    # Datasource (VMSingle)
    datasource:
      url: http://vmsingle-victoria-metrics-k8s-stack.monitoring.svc:8429

    # Auto-discover converted PrometheusRules
    ruleNamespaceSelector: {}
    ruleSelector: {}
    selectAllByDefault: true

# Disable bundled components (reuse existing)
grafana:
  enabled: false  # Reuse existing Grafana

alertmanager:
  enabled: false  # Reuse existing AlertManager

prometheus-node-exporter:
  enabled: false  # Already running from kube-prometheus-stack

kube-state-metrics:
  enabled: false  # Already running from kube-prometheus-stack

# VictoriaMetrics Operator config
victoria-metrics-operator:
  enabled: false  # Already installed in Phase 2
```

### 3.2 Create HelmRelease

**File:** `monitoring/controllers/staging/victoria-metrics-k8s-stack/release.yaml`
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: victoria-metrics-k8s-stack
  namespace: monitoring
spec:
  interval: 6h
  chart:
    spec:
      chart: victoria-metrics-k8s-stack
      version: "0.30.x"  # Check latest
      sourceRef:
        kind: HelmRepository
        name: victoriametrics
        namespace: monitoring
      interval: 12h
  install:
    crds: Create
    remediation:
      retries: 3
  upgrade:
    crds: CreateReplace
    remediation:
      retries: 3
  valuesFrom:
    - kind: ConfigMap
      name: victoria-metrics-k8s-stack-values
      valuesKey: values.yaml
```

**File:** `monitoring/controllers/staging/victoria-metrics-k8s-stack/values-configmap.yaml`
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: victoria-metrics-k8s-stack-values
  namespace: monitoring
data:
  values.yaml: |
    # Copy entire values.yaml content here
    # (Use the values from 3.1 above)
```

**File:** `monitoring/controllers/staging/victoria-metrics-k8s-stack/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - release.yaml
  - values-configmap.yaml
```

### 3.3 Deploy
```bash
cd /Users/akhozya/source-code/homelab
git add monitoring/controllers/staging/victoria-metrics-k8s-stack
git commit -m "Deploy VictoriaMetrics stack side-by-side with Prometheus"
git push

flux reconcile source git flux-system --timeout=45s
flux reconcile kustomization monitoring-controllers --timeout=120s

# Watch deployment
kubectl get pods -n monitoring -w
```

### 3.4 Verify Components
```bash
# Check all VM components are running
kubectl get pods -n monitoring | grep victoria

# Expected pods:
# - vmsingle-victoria-metrics-k8s-stack-0
# - vmagent-victoria-metrics-k8s-stack-*
# - vmalert-victoria-metrics-k8s-stack-*

# Check VMSingle is ready
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=vmsingle -n monitoring --timeout=180s

# Verify VMAgent is scraping
kubectl logs -n monitoring -l app.kubernetes.io/name=vmagent --tail=50

# Check VMAlert loaded rules
kubectl logs -n monitoring -l app.kubernetes.io/name=vmalert --tail=50 | grep -i "rule"
```

### 3.5 Test VMSingle API
```bash
# Port-forward to test locally
kubectl port-forward -n monitoring svc/vmsingle-victoria-metrics-k8s-stack 8429:8429 &

# Test query API
curl -s http://localhost:8429/api/v1/query?query=up | jq .

# Check TSDB stats
curl -s http://localhost:8429/api/v1/status/tsdb | jq .

# Stop port-forward
pkill -f "port-forward.*8429"
```

---

## Phase 4: Add VictoriaMetrics to Grafana (15 min)

### 4.1 Update Grafana Configuration

**Update:** `monitoring/controllers/base/kube-prometheus-stack/release.yaml`

Find the `grafana.additionalDataSources` section and add VictoriaMetrics:

```yaml
grafana:
  additionalDataSources:
    # Existing Loki datasource
    - name: Loki
      type: loki
      access: proxy
      url: http://loki.loki.svc.cluster.local:3100
      jsonData:
        maxLines: 1000
        derivedFields:
          - datasourceUid: prometheus
            matcherRegex: "traceID=(\\w+)"
            name: TraceID
            url: "$${__value.raw}"
      isDefault: false
      editable: false

    # NEW: VictoriaMetrics datasource
    - name: VictoriaMetrics
      type: prometheus
      access: proxy
      url: http://vmsingle-victoria-metrics-k8s-stack.monitoring.svc:8429
      jsonData:
        timeInterval: 30s
        httpMethod: POST
      isDefault: false  # Keep Prometheus as default for now
      editable: false
```

### 4.2 Apply Changes
```bash
cd /Users/akhozya/source-code/homelab
git add monitoring/controllers/base/kube-prometheus-stack/release.yaml
git commit -m "Add VictoriaMetrics datasource to Grafana"
git push

flux reconcile helmrelease kube-prometheus-stack -n monitoring --timeout=120s

# Restart Grafana to pick up new datasource
kubectl rollout restart deployment -n monitoring kube-prometheus-stack-grafana
kubectl rollout status deployment -n monitoring kube-prometheus-stack-grafana
```

### 4.3 Test in Grafana UI
```bash
# Get Grafana password
kubectl get secret -n monitoring grafana-admin-secret -o jsonpath='{.data.admin-password}' | base64 -d
echo ""

# Open Grafana
echo "Open: https://grafana.h0melab.work"
echo "1. Go to Configuration > Data Sources"
echo "2. Verify 'VictoriaMetrics' datasource exists"
echo "3. Click 'Test' button - should see 'Data source is working'"
```

### 4.4 Test Queries
```bash
# In Grafana Explore:
# 1. Select VictoriaMetrics datasource
# 2. Run: up
# 3. Run: node_cpu_seconds_total
# 4. Compare with Prometheus datasource
```

---

## Phase 5: Parallel Running & Validation (7 days)

### Day 1: Initial Validation

```bash
# Compare resource usage
kubectl top pod -n monitoring prometheus-kube-prometheus-stack-prometheus-0
kubectl top pod -n monitoring vmsingle-victoria-metrics-k8s-stack-0

# Compare series count
PROM_SERIES=$(kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- \
  wget -qO- http://localhost:9090/api/v1/status/tsdb 2>/dev/null | \
  jq -r '.data.headStats.numSeries')

VM_SERIES=$(kubectl exec -n monitoring vmsingle-victoria-metrics-k8s-stack-0 -- \
  wget -qO- http://localhost:8429/api/v1/status/tsdb 2>/dev/null | \
  jq -r '.data.headStats.numSeries')

echo "Prometheus series: $PROM_SERIES"
echo "VictoriaMetrics series: $VM_SERIES"
```

### Daily Checks (Run daily for 7 days)

**Create script:** `.migration-backups/daily-validation.sh`
```bash
#!/bin/bash
DATE=$(date +%Y-%m-%d)
LOG_DIR="/Users/akhozya/source-code/homelab/.migration-backups/prometheus-to-vm-$(date +%Y%m%d)"

echo "=== VictoriaMetrics Migration Validation - $DATE ===" | tee -a $LOG_DIR/validation.log

# 1. Resource usage comparison
echo -e "\n--- Resource Usage ---" | tee -a $LOG_DIR/validation.log
echo "Prometheus:" | tee -a $LOG_DIR/validation.log
kubectl top pod -n monitoring prometheus-kube-prometheus-stack-prometheus-0 | tee -a $LOG_DIR/validation.log
echo "VictoriaMetrics:" | tee -a $LOG_DIR/validation.log
kubectl top pod -n monitoring vmsingle-victoria-metrics-k8s-stack-0 | tee -a $LOG_DIR/validation.log

# 2. Series count
echo -e "\n--- Series Count ---" | tee -a $LOG_DIR/validation.log
PROM_SERIES=$(kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- \
  wget -qO- http://localhost:9090/api/v1/status/tsdb 2>/dev/null | jq -r '.data.headStats.numSeries')
VM_SERIES=$(kubectl exec -n monitoring vmsingle-victoria-metrics-k8s-stack-0 -- \
  wget -qO- http://localhost:8429/api/v1/status/tsdb 2>/dev/null | jq -r '.data.headStats.numSeries')
echo "Prometheus: $PROM_SERIES" | tee -a $LOG_DIR/validation.log
echo "VictoriaMetrics: $VM_SERIES" | tee -a $LOG_DIR/validation.log

# 3. Pod status
echo -e "\n--- Pod Status ---" | tee -a $LOG_DIR/validation.log
kubectl get pods -n monitoring | grep -E "(prometheus|victoria)" | tee -a $LOG_DIR/validation.log

# 4. Alert status
echo -e "\n--- Active Alerts ---" | tee -a $LOG_DIR/validation.log
kubectl exec -n monitoring vmalert-victoria-metrics-k8s-stack-0 -- \
  wget -qO- http://localhost:8880/api/v1/alerts 2>/dev/null | \
  jq -r '.data.alerts[] | "\(.labels.alertname): \(.state)"' | tee -a $LOG_DIR/validation.log

echo -e "\n===================\n" | tee -a $LOG_DIR/validation.log
```

Make executable:
```bash
chmod +x .migration-backups/daily-validation.sh
```

### Validation Checklist

Run through this checklist daily:

**Day 1-2:**
- [ ] All VM pods running (vmsingle, vmagent, vmalert)
- [ ] VMAgent scraping all targets (check logs)
- [ ] VMAlert loaded all rules (check logs)
- [ ] VictoriaMetrics datasource works in Grafana
- [ ] Basic PromQL queries return data
- [ ] Memory usage < 600Mi

**Day 3-4:**
- [ ] No missing metrics (compare series count)
- [ ] All Grafana dashboards work with VM datasource
- [ ] Alerts firing correctly in VMAlert
- [ ] AlertManager receiving alerts from VMAlert
- [ ] No OOM events on VMSingle pod

**Day 5-7:**
- [ ] Memory usage stable (not growing)
- [ ] Query performance acceptable
- [ ] No data gaps in metrics
- [ ] All recording rules working
- [ ] Backup spike (3am) handled without OOM

### Test Specific Dashboards

**Critical dashboards to test:**
```bash
# Open each dashboard, switch datasource to VictoriaMetrics:
# 1. Kubernetes / Compute Resources / Cluster
# 2. Kubernetes / Compute Resources / Namespace (Pods)
# 3. Kubernetes / Compute Resources / Pod
# 4. Node Exporter / Nodes
# 5. Any custom dashboards you created
```

### Test Alert Rules

```bash
# List all VMRules
kubectl get vmrule -A

# Check specific rule groups
kubectl get vmrule -n monitoring homelab-alerts -o yaml

# Verify alerts in VMAlert
kubectl exec -n monitoring vmalert-victoria-metrics-k8s-stack-0 -- \
  wget -qO- http://localhost:8880/api/v1/rules | jq .
```

---

## Phase 6: Cutover (1 hour)

### After 7 days of successful validation, switch to VictoriaMetrics as default.

### 6.1 Make VictoriaMetrics Default Datasource

**Update:** `monitoring/controllers/base/kube-prometheus-stack/release.yaml`

```yaml
grafana:
  additionalDataSources:
    - name: VictoriaMetrics
      type: prometheus
      url: http://vmsingle-victoria-metrics-k8s-stack.monitoring.svc:8429
      isDefault: true  # ✅ NOW DEFAULT
      editable: false

    - name: Prometheus
      type: prometheus
      url: http://kube-prometheus-stack-prometheus.monitoring.svc:9090
      isDefault: false  # Keep as fallback
      editable: false

    - name: Loki
      # ... existing config
```

Apply:
```bash
git add monitoring/controllers/base/kube-prometheus-stack/release.yaml
git commit -m "Switch Grafana default datasource to VictoriaMetrics"
git push
flux reconcile helmrelease kube-prometheus-stack -n monitoring --timeout=120s
```

### 6.2 Monitor for Issues (24 hours)

```bash
# Watch for any alert differences
kubectl logs -n monitoring vmalert-victoria-metrics-k8s-stack-0 -f

# Check Grafana dashboards still work
# Check AlertManager notifications still arrive
```

### 6.3 Verify Everything

**Checklist:**
- [ ] All dashboards load correctly
- [ ] All panels show data
- [ ] Alerts firing as expected
- [ ] Telegram notifications working
- [ ] No metric gaps
- [ ] No errors in VMAlert logs

---

## Phase 7: Cleanup (after 7+ days)

### Only proceed if validation is 100% successful!

### 7.1 Suspend Prometheus (Don't Delete Yet!)

```bash
# Suspend but don't delete (can easily resume if issues found)
flux suspend helmrelease kube-prometheus-stack -n monitoring

# Verify Prometheus stopped
kubectl get pods -n monitoring | grep prometheus
# Should show pods terminating
```

### 7.2 Monitor for 3 More Days

```bash
# Ensure VictoriaMetrics handles everything
./migration-backups/daily-validation.sh

# Watch for any issues:
# - Missing metrics
# - Alert gaps
# - Dashboard errors
```

### 7.3 Final Cleanup (after 10+ days total)

```bash
# Remove from Flux
cd /Users/akhozya/source-code/homelab

# Update monitoring kustomization to remove Prometheus
vim monitoring/controllers/staging/kustomization.yaml
# Remove: - ../base/kube-prometheus-stack

git add monitoring/controllers/staging/kustomization.yaml
git commit -m "Remove kube-prometheus-stack from Flux"
git push

flux reconcile kustomization monitoring-controllers --timeout=60s

# Delete Helm release
helm uninstall kube-prometheus-stack -n monitoring

# Remove from Git (keep in backups!)
git rm -r monitoring/controllers/base/kube-prometheus-stack
git rm -r monitoring/configs/staging/kube-prometheus-stack
git commit -m "Complete migration to VictoriaMetrics - remove Prometheus"
git push
```

### 7.4 Update Documentation

Update `docs/HOMELAB_ANALYSIS.md`:
```markdown
## Monitoring Stack

**Time-Series Database:** VictoriaMetrics (VMSingle)
**Metrics Collection:** VMAgent
**Alerting:** VMAlert → AlertManager
**Visualization:** Grafana
**Memory Usage:** ~300-400Mi (was 2.5Gi with Prometheus)
**Retention:** 7 days
**Migration Date:** 2025-11-XX
```

---

## Rollback Plan

### If Issues Found During Validation

**Minor issues (dashboards, queries):**
- Keep both systems running
- Fix issues with MetricsQL adjustments
- Continue validation

**Major issues (data loss, critical alerts missing):**

```bash
# 1. Resume using Prometheus in Grafana
# Update Grafana datasource back to Prometheus as default

# 2. Delete VictoriaMetrics
flux suspend helmrelease victoria-metrics-k8s-stack -n monitoring
helm uninstall victoria-metrics-k8s-stack -n monitoring
helm uninstall victoria-metrics-operator -n monitoring

# 3. Verify Prometheus still has data
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- \
  wget -qO- http://localhost:9090/api/v1/query?query=up

# 4. Clean up
git revert <commit-hashes>
git push
flux reconcile kustomization monitoring-controllers
```

---

## Expected Results

### Resource Savings

| Metric | Prometheus | VictoriaMetrics | Improvement |
|--------|-----------|-----------------|-------------|
| **Memory (baseline)** | 1-1.2Gi | 250-350Mi | **70-75%** ↓ |
| **Memory (peak)** | ~2Gi | ~400Mi | **80%** ↓ |
| **Memory (limit)** | 2.5Gi | 512Mi | **80%** ↓ |
| **CPU (average)** | 150-200m | 50-100m | **50%** ↓ |
| **Storage size** | ~15GB | ~2GB | **87%** ↓ |
| **Total RAM freed** | - | **~2GB** | - |

### Operational Benefits

✅ **Stable memory** - no OOM spikes
✅ **Faster queries** - better compression
✅ **Lower resource usage** - more room for apps
✅ **Same PromQL** - zero learning curve
✅ **Better cardinality** - handles labels efficiently

---

## Troubleshooting

### VMAgent not scraping

```bash
# Check VMAgent logs
kubectl logs -n monitoring -l app.kubernetes.io/name=vmagent

# Verify ServiceMonitors were converted
kubectl get vmservicescrape -A

# Check VMAgent config
kubectl exec -n monitoring vmagent-* -- cat /etc/vmagent/config.yaml
```

### VMAlert not firing alerts

```bash
# Check VMAlert logs
kubectl logs -n monitoring -l app.kubernetes.io/name=vmalert

# Verify PrometheusRules were converted
kubectl get vmrule -A

# Check loaded rules
kubectl exec -n monitoring vmalert-* -- \
  wget -qO- http://localhost:8880/api/v1/rules | jq .
```

### Grafana dashboards broken

```bash
# MetricsQL differences from PromQL:
# - rate() requires [step] interval (Prometheus auto-infers)
# - Some functions have different names

# Fix example:
# Prometheus: rate(metric[5m])
# VictoriaMetrics: rate(metric[30s])  # Use scrape interval
```

### Missing metrics

```bash
# Compare metric names
comm -23 \
  <(kubectl exec -n monitoring prometheus-* -- wget -qO- 'http://localhost:9090/api/v1/label/__name__/values' | jq -r '.data[]' | sort) \
  <(kubectl exec -n monitoring vmsingle-* -- wget -qO- 'http://localhost:8429/api/v1/label/__name__/values' | jq -r '.data[]' | sort)

# If metrics missing, check VMAgent targets
kubectl exec -n monitoring vmagent-* -- \
  wget -qO- http://localhost:8429/targets | grep -i "down"
```

---

## Key Files Modified

**New files:**
- `monitoring/controllers/base/victoria-metrics-operator/`
- `monitoring/controllers/staging/victoria-metrics-k8s-stack/`

**Modified files:**
- `monitoring/controllers/base/kube-prometheus-stack/release.yaml` (Grafana datasource)
- `monitoring/controllers/staging/kustomization.yaml` (add VM, later remove Prom)

**Backup location:**
- `.migration-backups/prometheus-to-vm-YYYYMMDD/`

---

## Migration Timeline

| Day | Phase | Tasks |
|-----|-------|-------|
| **0** | Preparation | Backups, document current state |
| **0** | Install | VM Operator, VM Stack deployment |
| **0** | Configure | Add Grafana datasource, verify scraping |
| **1-2** | Validate | Test dashboards, verify alerts, check memory |
| **3-4** | Validate | Compare metrics, test edge cases |
| **5-7** | Validate | Monitor stability, backup cycles |
| **7** | Cutover | Switch Grafana default to VM |
| **8-10** | Monitor | Watch for issues with VM only |
| **10+** | Cleanup | Remove Prometheus |

---

## Success Criteria

Before completing migration, all must be true:

- [ ] VictoriaMetrics memory usage < 500Mi
- [ ] Zero metric gaps in 7-day validation
- [ ] All Grafana dashboards functional
- [ ] All critical alerts firing correctly
- [ ] AlertManager receiving notifications
- [ ] No errors in VM component logs
- [ ] Backup jobs (3am) don't cause OOM
- [ ] Query performance acceptable
- [ ] Series count matches Prometheus (±5%)
- [ ] 7 consecutive days without issues

---

## References

- **VictoriaMetrics Docs:** https://docs.victoriametrics.com/
- **Helm Charts:** https://github.com/VictoriaMetrics/helm-charts
- **Operator Guide:** https://docs.victoriametrics.com/operator/
- **Migration Guide:** https://docs.victoriametrics.com/operator/migration/
- **MetricsQL:** https://docs.victoriametrics.com/MetricsQL.html

---

## Contact & Support

**If stuck:**
1. Check troubleshooting section above
2. Review VM operator logs: `kubectl logs -n monitoring -l app.kubernetes.io/name=victoria-metrics-operator`
3. VM Slack: https://slack.victoriametrics.com/
4. GitHub Issues: https://github.com/VictoriaMetrics/VictoriaMetrics/issues

**Rollback threshold:**
- Critical alerts not firing for >1 hour
- Metric gaps >10% of time
- OOM events on VMSingle
- Query failures affecting dashboards

---

**Status:** Ready to begin Phase 1
**Next Step:** Create backup directory and export current Prometheus config
