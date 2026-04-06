# VictoriaMetrics vs Prometheus RAM Comparison Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy VictoriaMetrics v1.139.0 alongside existing Prometheus for a 72-hour apples-to-apples RAM comparison, with identical scrape targets, metric drops, retention, and storage.

**Architecture:** VMOperator (CRD-only, no auto-conversion) + VMAgent (scraper) + VMSingle (storage). Explicit VMServiceScrape/VMPodScrape resources replicate every Prometheus scrape target with identical metric drop rules. Both systems scrape the same 49 targets at 60s intervals with 90d retention and 50Gi storage. Additionally, fix Prometheus to scrape previously-missed ServiceMonitors (kyverno, immich, CNPG operator) so both systems have identical target sets.

**Tech Stack:** VictoriaMetrics v1.139.0, VMOperator v0.68.3 (chart 0.59.3), Flux HelmRelease, Kustomize

**Background:** Previous attempt (2025-11-15) failed because `metricRelabelConfigs` were silently ignored — likely due to incorrect YAML nesting in VMNodeScrape (top-level vs under `endpoints`). This plan avoids VMNodeScrape entirely, using VMServiceScrape with `attachMetadata.node: true` instead.

---

## File Structure

### New files (VictoriaMetrics stack)

```
monitoring/controllers/base/victoria-metrics/
├── namespace.yaml                    # victoria-metrics namespace
├── repository.yaml                   # HelmRepository for VM charts
├── operator-release.yaml             # VMOperator HelmRelease (chart 0.59.3)
├── kustomization.yaml                # Base kustomization

monitoring/configs/base/victoria-metrics/
├── vmsingle.yaml                     # VMSingle CR (storage, 90d retention, 50Gi)
├── vmagent.yaml                      # VMAgent CR (scraper, 60s interval)
├── scrape-kubelet.yaml               # VMServiceScrape: kubelet /metrics
├── scrape-kubelet-cadvisor.yaml      # VMServiceScrape: kubelet /metrics/cadvisor
├── scrape-kubelet-probes.yaml        # VMServiceScrape: kubelet /metrics/probes
├── scrape-apiserver.yaml             # VMServiceScrape: kube-apiserver
├── scrape-coredns.yaml               # VMServiceScrape: coredns
├── scrape-node-exporter.yaml         # VMServiceScrape: node-exporter
├── scrape-kube-state-metrics.yaml    # VMServiceScrape: kube-state-metrics
├── scrape-monitoring-stack.yaml      # VMServiceScrape: prometheus, alertmanager, operator, grafana
├── scrape-databases.yaml             # VMServiceScrape: mysql, redis, couchdb + VMPodScrape: postgres
├── scrape-apps.yaml                  # VMServiceScrape: cloudflared, traefik, cert-manager, alloy, loki, immich
├── scrape-kyverno.yaml               # VMServiceScrape: kyverno (4 controllers)
├── scrape-cnpg-operator.yaml         # VMPodScrape: cnpg-operator
├── scrape-vmagent.yaml               # VMServiceScrape: vmagent self-monitoring
├── networkpolicy.yaml                # NetworkPolicy for VM namespace
├── kustomization.yaml                # Configs kustomization

monitoring/controllers/staging/victoria-metrics/
├── kustomization.yaml                # Staging overlay (passthrough)

monitoring/configs/staging/victoria-metrics/
├── kustomization.yaml                # Staging overlay (passthrough)
```

### Modified files (Prometheus fixes + wiring)

```
monitoring/controllers/staging/kustomization.yaml        # Add victoria-metrics to resources
monitoring/configs/staging/kustomization.yaml             # Add victoria-metrics to resources
infrastructure/controllers/base/kyverno/release.yaml      # Add release label to ServiceMonitors
apps/base/immich/release.yaml                             # Add release label to ServiceMonitor
infrastructure/controllers/base/databases/postgres/release.yaml  # Add release label to PodMonitor
monitoring/controllers/base/kube-prometheus-stack/release.yaml   # Add VM datasource to Grafana
```

---

### Task 1: Fix Prometheus — Add Missing ServiceMonitor/PodMonitor Labels

**Why:** Kyverno (4 ServiceMonitors), immich (1 ServiceMonitor), and CNPG operator (1 PodMonitor) exist but lack `release: kube-prometheus-stack` label, so Prometheus doesn't scrape them. Both Prometheus and VM must scrape identical targets for a fair comparison.

**Files:**
- Modify: `infrastructure/controllers/base/kyverno/release.yaml:86,117,149,181`
- Modify: `apps/base/immich/release.yaml:146`
- Modify: `infrastructure/controllers/base/databases/postgres/release.yaml:58`

- [ ] **Step 1: Add `release` label to kyverno ServiceMonitors**

In `infrastructure/controllers/base/kyverno/release.yaml`, add `additionalLabels` under each of the 4 serviceMonitor sections. Each section currently looks like:

```yaml
      serviceMonitor:
        enabled: true
        interval: 60s
```

Change ALL FOUR sections (admissionController ~line 86, backgroundController ~line 117, cleanupController ~line 149, reportsController ~line 181) to:

```yaml
      serviceMonitor:
        enabled: true
        interval: 60s
        additionalLabels:
          release: kube-prometheus-stack
```

- [ ] **Step 2: Add `release` label to immich ServiceMonitor**

In `apps/base/immich/release.yaml`, the metrics section (~line 146) currently has:

```yaml
    immich:
      metrics:
        enabled: true
```

Change to:

```yaml
    immich:
      metrics:
        enabled: true
        serviceMonitor:
          additionalLabels:
            release: kube-prometheus-stack
```

> **Note:** Check the immich helm chart docs — the label path may be `immich.metrics.serviceMonitor.additionalLabels` or similar. Verify with `helm show values immich/immich --version 0.11.1 2>/dev/null | grep -A 20 metrics` or by checking the chart templates.

- [ ] **Step 3: Add `release` label to CNPG operator PodMonitor**

In `infrastructure/controllers/base/databases/postgres/release.yaml`, the monitoring section (~line 58) currently has:

```yaml
    monitoring:
      podMonitorEnabled: true
```

Change to:

```yaml
    monitoring:
      podMonitorEnabled: true
      podMonitorAdditionalLabels:
        release: kube-prometheus-stack
```

> **Note:** Check CNPG operator chart values — the key may be `monitoring.podMonitorAdditionalLabels` or `monitoring.podMonitor.labels`. Verify with `helm show values cnpg/cloudnative-pg 2>/dev/null | grep -A 10 -i podmonitor`.

- [ ] **Step 4: Validate YAML changes**

```bash
# Dry-run each changed file
kubectl apply -f infrastructure/controllers/base/kyverno/release.yaml --dry-run=server
kubectl apply -f apps/base/immich/release.yaml --dry-run=server
kubectl apply -f infrastructure/controllers/base/databases/postgres/release.yaml --dry-run=server
```

Expected: all pass validation.

- [ ] **Step 5: Commit Prometheus fixes**

```bash
git add infrastructure/controllers/base/kyverno/release.yaml \
      apps/base/immich/release.yaml \
      infrastructure/controllers/base/databases/postgres/release.yaml
git commit -m "Fix: add release label to kyverno/immich/cnpg ServiceMonitors for Prometheus discovery"
```

- [ ] **Step 6: Push and reconcile — verify new targets appear**

```bash
git push
flux reconcile source git flux-system --timeout=60s
flux reconcile kustomization infrastructure-controllers --timeout=60s
flux reconcile kustomization apps --timeout=60s
# Wait 2-3 minutes for HelmReleases to reconcile
```

Then verify new targets appear in Prometheus:

```bash
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- \
  wget -qO- 'http://localhost:9090/api/v1/targets' 2>/dev/null | \
  jq -r '.data.activeTargets[] | select(.scrapePool | test("kyverno|immich|cnpg-operator")) | "\(.scrapePool) \(.labels.job)"'
```

Expected: kyverno (4 ServiceMonitors × their pods), immich-server (2 ports), cnpg-operator PodMonitor should all appear.

- [ ] **Step 7: Record new baseline series count**

Wait 5 minutes for scrapes to stabilize, then:

```bash
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- \
  wget -qO- 'http://localhost:9090/api/v1/status/tsdb' 2>/dev/null | \
  jq '.data.headStats.numSeries'
```

Record this number — this is the new baseline for apples-to-apples comparison. Expected: ~93k + additional series from kyverno/immich/cnpg.

---

### Task 2: Create VictoriaMetrics Namespace and Helm Repository

**Files:**
- Create: `monitoring/controllers/base/victoria-metrics/namespace.yaml`
- Create: `monitoring/controllers/base/victoria-metrics/repository.yaml`
- Create: `monitoring/controllers/base/victoria-metrics/kustomization.yaml`

- [ ] **Step 1: Create namespace**

Create `monitoring/controllers/base/victoria-metrics/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: victoria-metrics
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

- [ ] **Step 2: Create HelmRepository**

Create `monitoring/controllers/base/victoria-metrics/repository.yaml`:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: victoriametrics
  namespace: victoria-metrics
spec:
  interval: 6h
  url: https://victoriametrics.github.io/helm-charts/
```

- [ ] **Step 3: Create base kustomization (namespace + repo only, operator added next task)**

Create `monitoring/controllers/base/victoria-metrics/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - repository.yaml
  - operator-release.yaml
```

- [ ] **Step 4: Commit**

```bash
git add monitoring/controllers/base/victoria-metrics/
git commit -m "Add VictoriaMetrics namespace and HelmRepository"
```

---

### Task 3: Deploy VMOperator via HelmRelease

**Files:**
- Create: `monitoring/controllers/base/victoria-metrics/operator-release.yaml`
- Modify: `monitoring/controllers/staging/kustomization.yaml`
- Create: `monitoring/controllers/staging/victoria-metrics/kustomization.yaml`

- [ ] **Step 1: Create VMOperator HelmRelease**

Create `monitoring/controllers/base/victoria-metrics/operator-release.yaml`:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: victoria-metrics-operator
  namespace: victoria-metrics
spec:
  interval: 6h
  chart:
    spec:
      chart: victoria-metrics-operator
      version: "0.59.3"
      sourceRef:
        kind: HelmRepository
        name: victoriametrics
        namespace: victoria-metrics
      interval: 12h
  install:
    crds: Create
    remediation:
      retries: 3
  maxHistory: 3
  upgrade:
    crds: CreateReplace
    remediation:
      retries: 3
      remediateLastFailure: true
  values:
    # Disable auto-conversion of Prometheus CRDs — we create explicit VMServiceScrape resources
    operator:
      disable_prometheus_converter: true
      enable_converter_ownership: false
    # Operator resources
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 128Mi
    # Security
    securityContext:
      runAsNonRoot: true
      runAsUser: 65534
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
          - ALL
      seccompProfile:
        type: RuntimeDefault
```

- [ ] **Step 2: Create staging overlay**

Create `monitoring/controllers/staging/victoria-metrics/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base/victoria-metrics
```

- [ ] **Step 3: Wire into monitoring controllers staging kustomization**

Modify `monitoring/controllers/staging/kustomization.yaml` — add `victoria-metrics`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - kube-prometheus-stack
  - loki-stack
  - popeye
  - victoria-metrics
```

- [ ] **Step 4: Validate and commit**

```bash
kubectl apply -f monitoring/controllers/base/victoria-metrics/operator-release.yaml --dry-run=server
git add monitoring/controllers/base/victoria-metrics/operator-release.yaml \
      monitoring/controllers/staging/victoria-metrics/ \
      monitoring/controllers/staging/kustomization.yaml
git commit -m "Deploy VMOperator v0.68.3 with Prometheus conversion disabled"
```

- [ ] **Step 5: Push and verify operator is running**

```bash
git push
flux reconcile source git flux-system --timeout=60s
flux reconcile kustomization monitoring-controllers --timeout=60s
# Wait for HelmRelease to install
flux get helmrelease -n victoria-metrics
```

Expected: `victoria-metrics-operator` shows `Ready True`.

```bash
kubectl get pods -n victoria-metrics
```

Expected: operator pod running.

---

### Task 4: Create VMSingle (Storage) and VMAgent (Scraper)

**Files:**
- Create: `monitoring/configs/base/victoria-metrics/vmsingle.yaml`
- Create: `monitoring/configs/base/victoria-metrics/vmagent.yaml`
- Create: `monitoring/configs/base/victoria-metrics/kustomization.yaml`
- Create: `monitoring/configs/staging/victoria-metrics/kustomization.yaml`
- Modify: `monitoring/configs/staging/kustomization.yaml`

- [ ] **Step 1: Create VMSingle CR**

Create `monitoring/configs/base/victoria-metrics/vmsingle.yaml`:

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMSingle
metadata:
  name: vmsingle
  namespace: victoria-metrics
spec:
  # Match Prometheus: 90 day retention, 50Gi storage
  retentionPeriod: "90d"
  storage:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 50Gi
  resources:
    requests:
      cpu: 100m
      memory: 512Mi
    limits:
      cpu: 500m
      memory: 1500Mi
  # Security context
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop:
        - ALL
    seccompProfile:
      type: RuntimeDefault
  # Extra args for parity with Prometheus behavior
  extraArgs:
    # Align dedup with scrape interval
    dedup.minScrapeInterval: "60s"
```

- [ ] **Step 2: Create VMAgent CR**

Create `monitoring/configs/base/victoria-metrics/vmagent.yaml`:

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMAgent
metadata:
  name: vmagent
  namespace: victoria-metrics
spec:
  # Select ALL VMServiceScrape and VMPodScrape in victoria-metrics namespace
  serviceScrapeSelector:
    matchLabels:
      managed-by: vm-comparison
  podScrapeSelector:
    matchLabels:
      managed-by: vm-comparison
  # Also select VMNodeScrape (none planned, but in case)
  nodeScrapeSelector:
    matchLabels:
      managed-by: vm-comparison
  # Remote write to local VMSingle
  remoteWrite:
    - url: http://vmsingle-vmsingle.victoria-metrics.svc:8429/api/v1/write
  # Match Prometheus scrape interval
  scrapeInterval: "60s"
  # Resources
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
  # Security context
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop:
        - ALL
    seccompProfile:
      type: RuntimeDefault
  # Enable relabel debug UI for troubleshooting metric drops
  extraArgs:
    promscrape.dropOriginalLabels: "false"
```

- [ ] **Step 3: Create base kustomization for configs**

Create `monitoring/configs/base/victoria-metrics/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: victoria-metrics
resources:
  - vmsingle.yaml
  - vmagent.yaml
  - scrape-kubelet.yaml
  - scrape-kubelet-cadvisor.yaml
  - scrape-kubelet-probes.yaml
  - scrape-apiserver.yaml
  - scrape-coredns.yaml
  - scrape-node-exporter.yaml
  - scrape-kube-state-metrics.yaml
  - scrape-monitoring-stack.yaml
  - scrape-databases.yaml
  - scrape-apps.yaml
  - scrape-kyverno.yaml
  - scrape-cnpg-operator.yaml
  - scrape-vmagent.yaml
  - networkpolicy.yaml
```

- [ ] **Step 4: Create staging overlay and wire into monitoring configs**

Create `monitoring/configs/staging/victoria-metrics/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base/victoria-metrics
```

Modify `monitoring/configs/staging/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - kube-prometheus-stack
  - grafana-dashboards
  - flux-notifications.yaml
  - victoria-metrics
```

- [ ] **Step 5: Commit (don't push yet — scrape configs and networkpolicy not created)**

```bash
git add monitoring/configs/base/victoria-metrics/vmsingle.yaml \
      monitoring/configs/base/victoria-metrics/vmagent.yaml \
      monitoring/configs/base/victoria-metrics/kustomization.yaml \
      monitoring/configs/staging/victoria-metrics/ \
      monitoring/configs/staging/kustomization.yaml
git commit -m "Add VMSingle and VMAgent CRs for RAM comparison test"
```

---

### Task 5: Create Kubelet Scrape Configs (3 endpoints: metrics, cadvisor, probes)

These are the trickiest targets — kubelet exposes 3 separate metric endpoints, each with different metric drop rules. We use VMServiceScrape targeting the kubelet Service created by kube-prometheus-stack, NOT VMNodeScrape.

**Files:**
- Create: `monitoring/configs/base/victoria-metrics/scrape-kubelet.yaml`
- Create: `monitoring/configs/base/victoria-metrics/scrape-kubelet-cadvisor.yaml`
- Create: `monitoring/configs/base/victoria-metrics/scrape-kubelet-probes.yaml`

- [ ] **Step 1: Verify kubelet Service exists and check its labels**

```bash
kubectl get service -n kube-system kubelet -o yaml 2>/dev/null | head -20 || true
# If no kubelet service in kube-system, check monitoring namespace
kubectl get endpoints -n monitoring -l app.kubernetes.io/managed-by=prometheus-operator 2>/dev/null | grep kubelet || true
```

> **IMPORTANT:** The kube-prometheus-stack creates a headless Service for kubelet in the `kube-system` namespace. Verify its exact name and labels before proceeding. The VMServiceScrape must match the Service's labels.

- [ ] **Step 2: Create kubelet /metrics scrape**

Create `monitoring/configs/base/victoria-metrics/scrape-kubelet.yaml`:

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: kubelet-metrics
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  jobLabel: k8s-app
  namespaceSelector:
    matchNames:
      - kube-system
  selector:
    matchLabels:
      app.kubernetes.io/name: kubelet
  endpoints:
    - port: https-metrics
      scheme: https
      path: /metrics
      interval: "60s"
      honorLabels: true
      tlsConfig:
        insecureSkipVerify: true
        caFile: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
      bearerTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
      # CRITICAL: metricRelabelConfigs here is correct — it's UNDER endpoints for VMServiceScrape
      # (VMNodeScrape uses top-level, VMServiceScrape uses per-endpoint — this is what bit us in Nov 2025)
      metricRelabelConfigs:
        # Drop API server histogram buckets
        - sourceLabels: [__name__]
          regex: 'apiserver_request_(duration|sli_duration)_seconds_bucket'
          action: drop
        - sourceLabels: [__name__]
          regex: 'apiserver_request_body_size_bytes_bucket'
          action: drop
        - sourceLabels: [__name__]
          regex: 'apiserver_response_sizes_bucket'
          action: drop
        - sourceLabels: [__name__]
          regex: 'etcd_request_duration_seconds_bucket'
          action: drop
        - sourceLabels: [__name__]
          regex: 'apiserver_watch_(cache_read_wait_seconds|events_sizes)_bucket'
          action: drop
        # Drop workqueue metrics
        - sourceLabels: [__name__]
          regex: 'workqueue_(work|queue)_duration_seconds_bucket'
          action: drop
        # Drop scheduler plugin metrics
        - sourceLabels: [__name__]
          regex: 'scheduler_plugin_execution_duration_seconds_bucket'
          action: drop
        # Drop storage operation histograms
        - sourceLabels: [__name__]
          regex: 'storage_operation_duration_seconds_bucket'
          action: drop
        # Drop kubernetes feature flags
        - sourceLabels: [__name__]
          regex: 'kubernetes_feature_enabled'
          action: drop
        # Drop admission controller histograms
        - sourceLabels: [__name__]
          regex: 'apiserver_admission_controller_admission_duration_seconds_bucket'
          action: drop
        # Drop rest client histograms
        - sourceLabels: [__name__]
          regex: 'rest_client_(request_duration|request_size|response_size)_bytes?_bucket'
          action: drop
        # Drop all kubelet histogram buckets
        - sourceLabels: [__name__]
          regex: 'kubelet_.*_bucket'
          action: drop
        # Drop histogram count/sum for already-dropped buckets
        - sourceLabels: [__name__]
          regex: 'apiserver_request_sli_duration_seconds_(count|sum)'
          action: drop
        - sourceLabels: [__name__]
          regex: 'apiserver_response_sizes_(count|sum)'
          action: drop
        - sourceLabels: [__name__]
          regex: 'etcd_request_duration_seconds_(count|sum)'
          action: drop
        - sourceLabels: [__name__]
          regex: 'workqueue_(work|queue)_duration_seconds_(count|sum)'
          action: drop
        # Drop Go runtime histogram buckets
        - sourceLabels: [__name__]
          regex: 'go_(gc_heap_|sched_).*_bucket'
          action: drop
        - sourceLabels: [__name__]
          regex: 'go_gc_pauses_seconds_bucket'
          action: drop
```

- [ ] **Step 3: Create kubelet /metrics/cadvisor scrape**

Create `monitoring/configs/base/victoria-metrics/scrape-kubelet-cadvisor.yaml`:

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: kubelet-cadvisor
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  jobLabel: k8s-app
  namespaceSelector:
    matchNames:
      - kube-system
  selector:
    matchLabels:
      app.kubernetes.io/name: kubelet
  endpoints:
    - port: https-metrics
      scheme: https
      path: /metrics/cadvisor
      interval: "60s"
      honorLabels: true
      tlsConfig:
        insecureSkipVerify: true
        caFile: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
      bearerTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
      metricRelabelConfigs:
        # K3s fix: copy 'name' label to 'container' (K3s exports container='' with name in 'name' label)
        - sourceLabels: [name]
          targetLabel: container
        # Drop low-utility container metrics
        - sourceLabels: [__name__]
          regex: 'container_tasks_state'
          action: drop
        - sourceLabels: [__name__]
          regex: 'container_memory_failures_total'
          action: drop
        - sourceLabels: [__name__]
          regex: 'container_blkio_device_usage_total'
          action: drop
```

- [ ] **Step 4: Create kubelet /metrics/probes scrape**

Create `monitoring/configs/base/victoria-metrics/scrape-kubelet-probes.yaml`:

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: kubelet-probes
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  jobLabel: k8s-app
  namespaceSelector:
    matchNames:
      - kube-system
  selector:
    matchLabels:
      app.kubernetes.io/name: kubelet
  endpoints:
    - port: https-metrics
      scheme: https
      path: /metrics/probes
      interval: "60s"
      honorLabels: true
      tlsConfig:
        insecureSkipVerify: true
        caFile: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
      bearerTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
      metricRelabelConfigs:
        # Drop prober probe duration buckets
        - sourceLabels: [__name__]
          regex: 'prober_probe_duration_seconds_bucket'
          action: drop
```

- [ ] **Step 5: Commit**

```bash
git add monitoring/configs/base/victoria-metrics/scrape-kubelet*.yaml
git commit -m "Add VMServiceScrape for kubelet metrics, cadvisor, and probes endpoints"
```

---

### Task 6: Create API Server and Core Infrastructure Scrape Configs

**Files:**
- Create: `monitoring/configs/base/victoria-metrics/scrape-apiserver.yaml`
- Create: `monitoring/configs/base/victoria-metrics/scrape-coredns.yaml`
- Create: `monitoring/configs/base/victoria-metrics/scrape-node-exporter.yaml`
- Create: `monitoring/configs/base/victoria-metrics/scrape-kube-state-metrics.yaml`

- [ ] **Step 1: Verify service labels for each target**

```bash
# API server
kubectl get service -n default kubernetes -o jsonpath='{.metadata.labels}' | jq .
# CoreDNS
kubectl get service -n kube-system kube-dns -o jsonpath='{.metadata.labels}' | jq .
# Node exporter
kubectl get service -n monitoring -l app.kubernetes.io/name=prometheus-node-exporter -o jsonpath='{.items[0].metadata.name}'
# Kube-state-metrics
kubectl get service -n monitoring -l app.kubernetes.io/name=kube-state-metrics -o jsonpath='{.items[0].metadata.name}'
```

Record exact service names and labels. The VMServiceScrape selectors must match.

- [ ] **Step 2: Create API server scrape**

Create `monitoring/configs/base/victoria-metrics/scrape-apiserver.yaml`:

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: apiserver
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  jobLabel: component
  namespaceSelector:
    matchNames:
      - default
  selector:
    matchLabels:
      component: apiserver
      provider: kubernetes
  endpoints:
    - port: https
      scheme: https
      interval: "60s"
      tlsConfig:
        insecureSkipVerify: true
        caFile: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
      bearerTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
      metricRelabelConfigs:
        # Identical drops to kubeApiServer section in kube-prometheus-stack release.yaml
        - sourceLabels: [__name__]
          regex: 'apiserver_request_(duration|sli_duration)_seconds_bucket'
          action: drop
        - sourceLabels: [__name__]
          regex: 'apiserver_request_body_size_bytes_bucket'
          action: drop
        - sourceLabels: [__name__]
          regex: 'apiserver_response_sizes_bucket'
          action: drop
        - sourceLabels: [__name__]
          regex: 'etcd_request_duration_seconds_bucket'
          action: drop
        - sourceLabels: [__name__]
          regex: 'apiserver_watch_(cache_read_wait_seconds|events_sizes)_bucket'
          action: drop
        - sourceLabels: [__name__]
          regex: 'workqueue_(work|queue)_duration_seconds_bucket'
          action: drop
        - sourceLabels: [__name__]
          regex: 'scheduler_plugin_execution_duration_seconds_bucket'
          action: drop
        - sourceLabels: [__name__]
          regex: 'storage_operation_duration_seconds_bucket'
          action: drop
        - sourceLabels: [__name__]
          regex: 'kubernetes_feature_enabled'
          action: drop
        - sourceLabels: [__name__]
          regex: 'apiserver_admission_controller_admission_duration_seconds_bucket'
          action: drop
        - sourceLabels: [__name__]
          regex: 'rest_client_(request_duration|request_size|response_size)_bytes?_bucket'
          action: drop
        - sourceLabels: [__name__]
          regex: 'apiserver_request_sli_duration_seconds_(count|sum)'
          action: drop
        - sourceLabels: [__name__]
          regex: 'apiserver_response_sizes_(count|sum)'
          action: drop
        - sourceLabels: [__name__]
          regex: 'etcd_request_duration_seconds_(count|sum)'
          action: drop
        - sourceLabels: [__name__]
          regex: 'workqueue_(work|queue)_duration_seconds_(count|sum)'
          action: drop
        - sourceLabels: [__name__]
          regex: 'go_(gc_heap_|sched_).*_bucket'
          action: drop
        - sourceLabels: [__name__]
          regex: 'go_gc_pauses_seconds_bucket'
          action: drop
```

- [ ] **Step 3: Create CoreDNS scrape**

Create `monitoring/configs/base/victoria-metrics/scrape-coredns.yaml`:

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: coredns
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  jobLabel: k8s-app
  namespaceSelector:
    matchNames:
      - kube-system
  selector:
    matchLabels:
      k8s-app: kube-dns
  endpoints:
    - port: metrics
      interval: "60s"
      bearerTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
```

> **Note:** Verify the CoreDNS service exposes a port named `metrics` (usually port 9153). If not, use the port number directly.

- [ ] **Step 4: Create node-exporter scrape**

Create `monitoring/configs/base/victoria-metrics/scrape-node-exporter.yaml`:

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: node-exporter
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  jobLabel: app.kubernetes.io/name
  namespaceSelector:
    matchNames:
      - monitoring
  selector:
    matchLabels:
      app.kubernetes.io/name: prometheus-node-exporter
  endpoints:
    - port: http-metrics
      interval: "60s"
```

> **Note:** Verify the node-exporter service port name. It's typically `http-metrics` or `metrics`. Check with `kubectl get svc -n monitoring -l app.kubernetes.io/name=prometheus-node-exporter -o jsonpath='{.items[0].spec.ports[*].name}'`.

- [ ] **Step 5: Create kube-state-metrics scrape**

Create `monitoring/configs/base/victoria-metrics/scrape-kube-state-metrics.yaml`:

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: kube-state-metrics
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  jobLabel: app.kubernetes.io/name
  namespaceSelector:
    matchNames:
      - monitoring
  selector:
    matchLabels:
      app.kubernetes.io/name: kube-state-metrics
  endpoints:
    - port: http
      interval: "60s"
      honorLabels: true
```

> **Note:** kube-state-metrics service port is typically `http` (port 8080). Verify with `kubectl get svc -n monitoring -l app.kubernetes.io/name=kube-state-metrics -o jsonpath='{.items[0].spec.ports[*].name}'`.

- [ ] **Step 6: Commit**

```bash
git add monitoring/configs/base/victoria-metrics/scrape-apiserver.yaml \
      monitoring/configs/base/victoria-metrics/scrape-coredns.yaml \
      monitoring/configs/base/victoria-metrics/scrape-node-exporter.yaml \
      monitoring/configs/base/victoria-metrics/scrape-kube-state-metrics.yaml
git commit -m "Add VMServiceScrape for apiserver, coredns, node-exporter, kube-state-metrics"
```

---

### Task 7: Create Monitoring Stack Scrape Configs (Prometheus, Alertmanager, Operator, Grafana)

**Files:**
- Create: `monitoring/configs/base/victoria-metrics/scrape-monitoring-stack.yaml`

- [ ] **Step 1: Verify monitoring stack service labels and ports**

```bash
# Prometheus
kubectl get svc -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{range .items[*]}{.metadata.name} ports={.spec.ports[*].name}{"\n"}{end}'
# Alertmanager
kubectl get svc -n monitoring -l app.kubernetes.io/name=alertmanager -o jsonpath='{range .items[*]}{.metadata.name} ports={.spec.ports[*].name}{"\n"}{end}'
# Operator
kubectl get svc -n monitoring -l app.kubernetes.io/name=prometheus-operator -o jsonpath='{range .items[*]}{.metadata.name} ports={.spec.ports[*].name}{"\n"}{end}'
# Grafana
kubectl get svc -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{range .items[*]}{.metadata.name} ports={.spec.ports[*].name}{"\n"}{end}'
```

- [ ] **Step 2: Create monitoring stack scrape config**

Create `monitoring/configs/base/victoria-metrics/scrape-monitoring-stack.yaml`:

```yaml
---
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: prometheus
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  namespaceSelector:
    matchNames:
      - monitoring
  selector:
    matchLabels:
      app.kubernetes.io/name: prometheus
  endpoints:
    - port: http-web
      interval: "60s"
    - port: reloader-web
      interval: "60s"
---
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: alertmanager
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  namespaceSelector:
    matchNames:
      - monitoring
  selector:
    matchLabels:
      app.kubernetes.io/name: alertmanager
  endpoints:
    - port: http-web
      interval: "60s"
    - port: reloader-web
      interval: "60s"
---
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: prometheus-operator
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  namespaceSelector:
    matchNames:
      - monitoring
  selector:
    matchLabels:
      app.kubernetes.io/name: prometheus-operator
  endpoints:
    - port: https
      scheme: https
      interval: "60s"
      tlsConfig:
        insecureSkipVerify: true
---
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: grafana
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  namespaceSelector:
    matchNames:
      - monitoring
  selector:
    matchLabels:
      app.kubernetes.io/name: grafana
  endpoints:
    - port: http-web
      interval: "60s"
```

> **IMPORTANT:** The port names above are guesses based on common kube-prometheus-stack patterns. You MUST verify actual port names from Step 1 output and update accordingly. Prometheus typically uses `http-web` (9090), Alertmanager uses `http-web` (9093) + `reloader-web`, Operator uses `https` (10250), Grafana uses `http-web` (3000).

- [ ] **Step 3: Commit**

```bash
git add monitoring/configs/base/victoria-metrics/scrape-monitoring-stack.yaml
git commit -m "Add VMServiceScrape for Prometheus, Alertmanager, Operator, Grafana"
```

---

### Task 8: Create Database Scrape Configs (MySQL, Redis, CouchDB, PostgreSQL)

**Files:**
- Create: `monitoring/configs/base/victoria-metrics/scrape-databases.yaml`

- [ ] **Step 1: Verify database service labels and ports**

```bash
# MySQL exporter
kubectl get svc -n databases -l app=mysql-exporter -o jsonpath='{range .items[*]}{.metadata.name} ports={.spec.ports[*].name}{"\n"}{end}'
# Redis
kubectl get svc -n databases -l app=redis -o jsonpath='{range .items[*]}{.metadata.name} ports={.spec.ports[*].name}{"\n"}{end}'
# CouchDB
kubectl get svc -n databases -l app=couchdb -o jsonpath='{range .items[*]}{.metadata.name} ports={.spec.ports[*].name}{"\n"}{end}'
# Postgres pods (PodMonitor target)
kubectl get pods -n databases -l cnpg.io/cluster=main-postgres -o jsonpath='{range .items[*]}{.metadata.name} ports={.spec.containers[*].ports[*].name}{"\n"}{end}'
```

- [ ] **Step 2: Get CouchDB credentials for basicAuth**

VMAgent needs CouchDB credentials to scrape `/_node/_local/_prometheus`. The existing Prometheus config uses the `couchdb-couchdb` secret.

```bash
# Verify secret exists
kubectl get secret -n databases couchdb-couchdb -o jsonpath='{.data}' | jq 'keys'
```

The VMServiceScrape for CouchDB will reference this same secret. VMAgent needs RBAC to read secrets in the `databases` namespace — this is handled by the VMOperator automatically when `basicAuth` is configured.

- [ ] **Step 3: Create database scrape configs**

Create `monitoring/configs/base/victoria-metrics/scrape-databases.yaml`:

```yaml
---
# MySQL exporter
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: mysql-metrics
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  namespaceSelector:
    matchNames:
      - databases
  selector:
    matchLabels:
      app: mysql-exporter
  endpoints:
    - port: metrics
      path: /metrics
      interval: "60s"
      scrapeTimeout: "10s"
      metricRelabelConfigs:
        - sourceLabels: [__name__]
          regex: 'mysql_info_schema_innodb_cmp.*'
          action: drop
---
# Redis
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: redis
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  namespaceSelector:
    matchNames:
      - databases
  selector:
    matchLabels:
      app: redis
  endpoints:
    - port: metrics
      path: /metrics
      interval: "60s"
      scrapeTimeout: "10s"
---
# CouchDB (requires basicAuth)
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: couchdb
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  namespaceSelector:
    matchNames:
      - databases
  selector:
    matchLabels:
      app: couchdb
  endpoints:
    - port: couchdb
      path: /_node/_local/_prometheus
      interval: "60s"
      scrapeTimeout: "10s"
      basicAuth:
        username:
          name: couchdb-couchdb
          key: adminUsername
        password:
          name: couchdb-couchdb
          key: adminPassword
      metricRelabelConfigs:
        - sourceLabels: [__name__]
          regex: 'couchdb_erlang_message_queue_size'
          action: drop
        - sourceLabels: [__name__]
          regex: 'couchdb_dreyfus_.*'
          action: drop
        - sourceLabels: [__name__]
          regex: 'couchdb_nouveau_.*'
          action: drop
---
# PostgreSQL (PodMonitor equivalent — VMPodScrape)
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMPodScrape
metadata:
  name: main-postgres-cluster
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  namespaceSelector:
    matchNames:
      - databases
  selector:
    matchLabels:
      cnpg.io/cluster: main-postgres
      cnpg.io/podRole: instance
  podMetricsEndpoints:
    - port: metrics
      interval: "60s"
      scrapeTimeout: "10s"
      metricRelabelConfigs:
        - sourceLabels: [__name__]
          regex: 'cnpg_pg_settings_setting'
          action: drop
```

- [ ] **Step 4: Commit**

```bash
git add monitoring/configs/base/victoria-metrics/scrape-databases.yaml
git commit -m "Add VMServiceScrape/VMPodScrape for MySQL, Redis, CouchDB, PostgreSQL"
```

---

### Task 9: Create App Scrape Configs (Cloudflared, Traefik, cert-manager, Alloy, Loki, Immich)

**Files:**
- Create: `monitoring/configs/base/victoria-metrics/scrape-apps.yaml`

- [ ] **Step 1: Verify app service labels and ports**

```bash
# Cloudflared
kubectl get svc -n cloudflare-tunnel -l app=cloudflared -o jsonpath='{range .items[*]}{.metadata.name} ports={.spec.ports[*].name}{"\n"}{end}'
# Traefik
kubectl get svc -n traefik -o jsonpath='{range .items[*]}{.metadata.name} ports={.spec.ports[*].name}{"\n"}{end}'
# cert-manager
kubectl get svc -n cert-manager -o jsonpath='{range .items[*]}{.metadata.name} ports={.spec.ports[*].name}{"\n"}{end}'
# Alloy
kubectl get svc -n loki -l app.kubernetes.io/name=alloy -o jsonpath='{range .items[*]}{.metadata.name} ports={.spec.ports[*].name}{"\n"}{end}'
# Loki
kubectl get svc -n loki -l app.kubernetes.io/name=loki -o jsonpath='{range .items[*]}{.metadata.name} ports={.spec.ports[*].name}{"\n"}{end}'
# Immich
kubectl get svc -n immich -o jsonpath='{range .items[*]}{.metadata.name} ports={.spec.ports[*].name}{"\n"}{end}'
```

- [ ] **Step 2: Create app scrape configs**

Create `monitoring/configs/base/victoria-metrics/scrape-apps.yaml`:

```yaml
---
# Cloudflared
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: cloudflared
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  namespaceSelector:
    matchNames:
      - cloudflare-tunnel
  selector:
    matchLabels:
      app: cloudflared
  endpoints:
    - port: metrics
      interval: "60s"
      path: /metrics
---
# Traefik
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: traefik
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  namespaceSelector:
    matchNames:
      - traefik
  selector:
    matchLabels:
      app.kubernetes.io/name: traefik
  endpoints:
    - port: metrics
      interval: "60s"
---
# cert-manager (3 components: controller, cainjector, webhook — all share one ServiceMonitor)
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: cert-manager
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  namespaceSelector:
    matchNames:
      - cert-manager
  selector:
    matchLabels:
      app.kubernetes.io/instance: cert-manager
  endpoints:
    - port: http-metrics
      interval: "60s"
---
# Alloy (log collector)
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: alloy
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  namespaceSelector:
    matchNames:
      - loki
  selector:
    matchLabels:
      app.kubernetes.io/name: alloy
  endpoints:
    - port: http-metrics
      interval: "60s"
---
# Loki
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: loki
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  namespaceSelector:
    matchNames:
      - loki
  selector:
    matchLabels:
      app.kubernetes.io/name: loki
  endpoints:
    - port: http-metrics
      interval: "60s"
---
# Immich server
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: immich-server
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  namespaceSelector:
    matchNames:
      - immich
  selector:
    matchLabels:
      app.kubernetes.io/name: server
      app.kubernetes.io/instance: immich
  endpoints:
    - port: metrics-api
      interval: "60s"
    - port: metrics-ms
      interval: "60s"
```

> **IMPORTANT:** All port names above MUST be verified against Step 1 output. cert-manager typically uses `http-metrics` or `http-prometheus` — check actual port names. Traefik metrics port may be named `metrics` or `traefik`. Alloy may use `http-metrics` (port 12345).

- [ ] **Step 3: Commit**

```bash
git add monitoring/configs/base/victoria-metrics/scrape-apps.yaml
git commit -m "Add VMServiceScrape for cloudflared, traefik, cert-manager, alloy, loki, immich"
```

---

### Task 10: Create Kyverno and CNPG Operator Scrape Configs

**Files:**
- Create: `monitoring/configs/base/victoria-metrics/scrape-kyverno.yaml`
- Create: `monitoring/configs/base/victoria-metrics/scrape-cnpg-operator.yaml`

- [ ] **Step 1: Verify kyverno service labels and ports**

```bash
# Each kyverno controller has its own service
kubectl get svc -n kyverno -o jsonpath='{range .items[*]}{.metadata.name} labels={.metadata.labels}{"\n"}{end}'
kubectl get svc -n kyverno -o jsonpath='{range .items[*]}{.metadata.name} ports={.spec.ports[*].name}{"\n"}{end}'
# CNPG operator pods
kubectl get pods -n databases -l app.kubernetes.io/name=cloudnative-pg -o jsonpath='{range .items[*]}{.metadata.name} ports={.spec.containers[*].ports[*].name}{"\n"}{end}'
```

- [ ] **Step 2: Create kyverno scrape config**

Create `monitoring/configs/base/victoria-metrics/scrape-kyverno.yaml`:

```yaml
---
# Kyverno admission controller
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: kyverno-admission
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  namespaceSelector:
    matchNames:
      - kyverno
  selector:
    matchLabels:
      app.kubernetes.io/component: admission-controller
      app.kubernetes.io/instance: kyverno
  endpoints:
    - port: metrics-port
      interval: "60s"
---
# Kyverno background controller
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: kyverno-background
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  namespaceSelector:
    matchNames:
      - kyverno
  selector:
    matchLabels:
      app.kubernetes.io/component: background-controller
      app.kubernetes.io/instance: kyverno
  endpoints:
    - port: metrics-port
      interval: "60s"
---
# Kyverno cleanup controller
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: kyverno-cleanup
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  namespaceSelector:
    matchNames:
      - kyverno
  selector:
    matchLabels:
      app.kubernetes.io/component: cleanup-controller
      app.kubernetes.io/instance: kyverno
  endpoints:
    - port: metrics-port
      interval: "60s"
---
# Kyverno reports controller
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: kyverno-reports
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  namespaceSelector:
    matchNames:
      - kyverno
  selector:
    matchLabels:
      app.kubernetes.io/component: reports-controller
      app.kubernetes.io/instance: kyverno
  endpoints:
    - port: metrics-port
      interval: "60s"
```

> **Note:** Kyverno metrics port is typically named `metrics-port` (port 8000). Verify from Step 1 output.

- [ ] **Step 3: Create CNPG operator scrape config**

Create `monitoring/configs/base/victoria-metrics/scrape-cnpg-operator.yaml`:

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMPodScrape
metadata:
  name: cnpg-operator
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  namespaceSelector:
    matchNames:
      - databases
  selector:
    matchLabels:
      app.kubernetes.io/name: cloudnative-pg
  podMetricsEndpoints:
    - port: metrics
      interval: "60s"
```

- [ ] **Step 4: Commit**

```bash
git add monitoring/configs/base/victoria-metrics/scrape-kyverno.yaml \
      monitoring/configs/base/victoria-metrics/scrape-cnpg-operator.yaml
git commit -m "Add VMServiceScrape for kyverno controllers and CNPG operator"
```

---

### Task 11: Create VMAgent Self-Monitoring Scrape Config

**Files:**
- Create: `monitoring/configs/base/victoria-metrics/scrape-vmagent.yaml`

- [ ] **Step 1: Create VMAgent self-scrape**

Create `monitoring/configs/base/victoria-metrics/scrape-vmagent.yaml`:

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: vmagent
  namespace: victoria-metrics
  labels:
    managed-by: vm-comparison
spec:
  namespaceSelector:
    matchNames:
      - victoria-metrics
  selector:
    matchLabels:
      app.kubernetes.io/name: vmagent
  endpoints:
    - port: http
      interval: "60s"
```

> **Note:** VMAgent exposes metrics on port 8429 (http). The VMOperator creates a Service with port name `http`. Verify after deployment.

- [ ] **Step 2: Commit**

```bash
git add monitoring/configs/base/victoria-metrics/scrape-vmagent.yaml
git commit -m "Add VMAgent self-monitoring scrape config"
```

---

### Task 12: Create NetworkPolicy for VictoriaMetrics Namespace

**Files:**
- Create: `monitoring/configs/base/victoria-metrics/networkpolicy.yaml`

- [ ] **Step 1: Create comprehensive NetworkPolicy**

The VM namespace needs:
- **Ingress:** Grafana (queries VMSingle:8428), Prometheus (if we add VM as scrape target), Uptime Kuma (health check on 8428), VMAgent→VMSingle internal
- **Egress:** DNS, K8s API (6443, for service discovery), scraping all namespaces (all ports), VMAgent→VMSingle internal

Create `monitoring/configs/base/victoria-metrics/networkpolicy.yaml`:

```yaml
---
# VMSingle NetworkPolicy
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: vmsingle-network-policy
  namespace: victoria-metrics
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: vmsingle
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow ingress from VMAgent (remote write)
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: vmagent
      ports:
        - protocol: TCP
          port: 8429
    # Allow ingress from Grafana (queries)
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
          podSelector:
            matchLabels:
              app.kubernetes.io/name: grafana
      ports:
        - protocol: TCP
          port: 8429
    # Allow ingress from Uptime Kuma (health checks)
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: uptime-kuma
      ports:
        - protocol: TCP
          port: 8429
    # Allow ingress from within cluster for ad-hoc querying
    - from:
        - namespaceSelector: {}
      ports:
        - protocol: TCP
          port: 8429
  egress:
    # Allow DNS
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
---
# VMAgent NetworkPolicy
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: vmagent-network-policy
  namespace: victoria-metrics
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: vmagent
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow Prometheus to scrape VMAgent metrics (if ServiceMonitor added later)
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: 8429
  egress:
    # Allow DNS
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
    # Allow remote write to VMSingle
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: vmsingle
      ports:
        - protocol: TCP
          port: 8429
    # Allow scraping metrics from all namespaces (any port)
    - to:
        - namespaceSelector: {}
    # Allow access to K8s API server (service discovery) and node IPs (kubelet, node-exporter)
    - ports:
        - protocol: TCP
          port: 443
        - protocol: TCP
          port: 6443
        - protocol: TCP
          port: 9100
        - protocol: TCP
          port: 10250
        - protocol: TCP
          port: 10255
        - protocol: TCP
          port: 4194
---
# VMOperator NetworkPolicy
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: vmoperator-network-policy
  namespace: victoria-metrics
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: victoria-metrics-operator
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Webhook from API server (pod CIDR for K3s flannel)
    - from:
        - ipBlock:
            cidr: 10.42.0.0/16
      ports:
        - protocol: TCP
          port: 9443
  egress:
    # Allow DNS
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
    # Allow K8s API server access
    - to:
        - ipBlock:
            cidr: 192.168.1.127/32
      ports:
        - protocol: TCP
          port: 6443
```

- [ ] **Step 2: Commit**

```bash
git add monitoring/configs/base/victoria-metrics/networkpolicy.yaml
git commit -m "Add NetworkPolicies for VMSingle, VMAgent, and VMOperator"
```

---

### Task 13: Add VictoriaMetrics Datasource to Grafana

**Files:**
- Modify: `monitoring/controllers/base/kube-prometheus-stack/release.yaml`

- [ ] **Step 1: Add VM as additional datasource in Grafana**

In `monitoring/controllers/base/kube-prometheus-stack/release.yaml`, find the `additionalDataSources` section (~line 68) and add the VictoriaMetrics datasource:

Current:
```yaml
      additionalDataSources:
        - name: Loki
          type: loki
          ...
```

Add after the Loki datasource:

```yaml
        - name: VictoriaMetrics
          type: prometheus
          url: http://vmsingle-vmsingle.victoria-metrics.svc:8429
          access: proxy
          isDefault: false
          editable: false
          jsonData:
            timeInterval: "60s"
```

> **Note:** We use `type: prometheus` (not the VM-specific plugin) for simplicity — VM's query API is Prometheus-compatible. This avoids needing to install the VM Grafana plugin.

- [ ] **Step 2: Validate and commit**

```bash
kubectl apply -f monitoring/controllers/base/kube-prometheus-stack/release.yaml --dry-run=server
git add monitoring/controllers/base/kube-prometheus-stack/release.yaml
git commit -m "Add VictoriaMetrics datasource to Grafana for comparison queries"
```

---

### Task 14: Deploy Everything — Push, Reconcile, Verify

- [ ] **Step 1: Push all changes**

```bash
git push
```

- [ ] **Step 2: Reconcile Flux**

```bash
flux reconcile source git flux-system --timeout=60s
flux reconcile kustomization monitoring-controllers --timeout=60s
flux reconcile kustomization monitoring-configs --timeout=60s
```

- [ ] **Step 3: Wait for operator to create VMSingle and VMAgent pods**

```bash
# Watch for pods to come up (may take 2-5 minutes)
kubectl get pods -n victoria-metrics -w
```

Expected: `victoria-metrics-operator-*`, `vmagent-vmagent-*`, `vmsingle-vmsingle-*` all Running.

- [ ] **Step 4: Check VMAgent targets — verify all scrape targets are discovered**

```bash
# Port-forward to VMAgent UI
kubectl port-forward -n victoria-metrics svc/vmagent-vmagent 8429:8429 &
sleep 2
# Check targets
curl -s 'http://localhost:8429/api/v1/targets' | jq -r '.data.activeTargets | length'
# Compare with Prometheus target count
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- \
  wget -qO- 'http://localhost:9090/api/v1/targets' 2>/dev/null | \
  jq -r '.data.activeTargets | length'
kill %1
```

Expected: Both should show similar target counts. VMAgent may differ slightly (it scrapes itself, Prometheus scrapes itself — both valid).

- [ ] **Step 5: If targets are missing, debug with VMAgent relabel UI**

```bash
kubectl port-forward -n victoria-metrics svc/vmagent-vmagent 8429:8429 &
sleep 2
# Open http://localhost:8429/targets in browser
# Check for any "down" targets or missing scrape pools
curl -s 'http://localhost:8429/api/v1/targets' | jq -r '.data.activeTargets[] | select(.health != "up") | "\(.scrapePool) \(.lastError)"'
kill %1
```

Fix any issues before proceeding to the comparison phase.

- [ ] **Step 6: Verify VMAgent can read CouchDB credentials**

CouchDB scraping requires basicAuth from the `couchdb-couchdb` secret in the `databases` namespace. VMOperator should create the necessary RBAC automatically. Verify:

```bash
# Check if VMAgent is successfully scraping CouchDB
kubectl port-forward -n victoria-metrics svc/vmagent-vmagent 8429:8429 &
sleep 2
curl -s 'http://localhost:8429/api/v1/targets' | jq -r '.data.activeTargets[] | select(.scrapePool | test("couchdb")) | "\(.health) \(.lastError)"'
kill %1
```

If CouchDB shows errors about auth, the VMOperator may need explicit RBAC. Check VMOperator logs:

```bash
kubectl logs -n victoria-metrics deploy/victoria-metrics-operator --tail=50
```

- [ ] **Step 7: Restart VMAgent pod to ensure NetworkPolicy is applied**

Per memory note: "Existing connections survive NetworkPolicy changes — kube-router only evaluates NEW connections."

```bash
kubectl rollout restart deployment -n victoria-metrics vmagent-vmagent
kubectl rollout status deployment -n victoria-metrics vmagent-vmagent --timeout=120s
```

- [ ] **Step 8: Commit any fixes made during verification**

```bash
git add -A
git diff --cached --stat
# If changes exist:
git commit -m "Fix VMServiceScrape port names and selectors after verification"
git push
```

---

### Task 15: Initial Series Count Comparison (T+0)

- [ ] **Step 1: Wait 10 minutes for scrapes to stabilize**

Both Prometheus and VMAgent need at least 5-10 scrape cycles to have stable series counts.

```bash
sleep 600
```

- [ ] **Step 2: Compare series counts**

```bash
echo "=== Prometheus Series Count ==="
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- \
  wget -qO- 'http://localhost:9090/api/v1/status/tsdb' 2>/dev/null | \
  jq '.data.headStats.numSeries'

echo "=== VictoriaMetrics Series Count ==="
kubectl exec -n victoria-metrics deploy/vmsingle-vmsingle -- \
  wget -qO- 'http://localhost:8428/api/v1/status/tsdb' 2>/dev/null | \
  jq '.data.headStats.numSeries'
```

**CRITICAL CHECK:** If VM series count is >10% higher than Prometheus, metric drops are not working correctly. Debug using:

```bash
# Check which metrics VM has that Prometheus doesn't
# Port-forward both
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
kubectl port-forward -n victoria-metrics svc/vmsingle-vmsingle 8428:8428 &
sleep 2

# Get top metric names from each
curl -s 'http://localhost:9090/api/v1/label/__name__/values' | jq '.data | length'
curl -s 'http://localhost:8428/api/v1/label/__name__/values' | jq '.data | length'

# Find metrics in VM but not in Prometheus
diff <(curl -s 'http://localhost:9090/api/v1/label/__name__/values' | jq -r '.data[]' | sort) \
     <(curl -s 'http://localhost:8428/api/v1/label/__name__/values' | jq -r '.data[]' | sort) \
     | grep '^>' | head -30

kill %1 %2
```

If drops are broken, the diff will show the histogram metrics (apiserver_request_duration_seconds_bucket, etc.) present in VM but not Prometheus. Fix the VMServiceScrape configs and re-verify.

- [ ] **Step 3: Compare RAM usage**

```bash
echo "=== Prometheus RAM ==="
kubectl top pod -n monitoring -l app.kubernetes.io/name=prometheus

echo "=== VictoriaMetrics RAM ==="
kubectl top pod -n victoria-metrics
```

- [ ] **Step 4: Record baseline in a comparison log**

Create a comparison log for the 72-hour test:

```bash
cat > /tmp/vm-comparison-log.md << 'EOF'
# VictoriaMetrics vs Prometheus RAM Comparison Log

## Test Parameters
- Start: $(date -u +"%Y-%m-%d %H:%M UTC")
- Duration: 72 hours
- VM Version: v1.139.0 (operator v0.68.3)
- Prometheus Version: kube-prometheus-stack 82.18.0
- Retention: Both 90d
- Storage: Both 50Gi
- Scrape Interval: Both 60s

## Measurements

### T+0 ($(date -u +"%Y-%m-%d %H:%M UTC"))
- Prometheus series: [FILL]
- VM series: [FILL]
- Prometheus RAM (pod 0): [FILL]
- Prometheus RAM (pod 1): [FILL]
- VM RAM (vmsingle): [FILL]
- VM RAM (vmagent): [FILL]
- VM RAM total: [FILL]

### T+24h
- Prometheus series:
- VM series:
- Prometheus RAM:
- VM RAM total:

### T+48h
- Prometheus series:
- VM series:
- Prometheus RAM:
- VM RAM total:

### T+72h (final)
- Prometheus series:
- VM series:
- Prometheus RAM:
- VM RAM total:
- Disk usage Prometheus:
- Disk usage VM:
EOF
echo "Log template created at /tmp/vm-comparison-log.md"
```

---

### Task 16: Set Up Uptime Kuma Health Check for VMSingle

- [ ] **Step 1: Verify port 8428 is already in Uptime Kuma NetworkPolicy egress**

```bash
grep -n "8428" apps/base/uptime-kuma/networkpolicy.yaml
```

Expected: Port 8428 already present (leftover from Nov 2025 attempt). If not, add it.

- [ ] **Step 2: Add health check in Uptime Kuma**

Manually (via Uptime Kuma UI at uptime-kuma.h0melab.work) or note for user:

- **Type:** HTTP(s)
- **URL:** `http://vmsingle-vmsingle.victoria-metrics.svc:8429/health`
- **Name:** VictoriaMetrics VMSingle
- **Heartbeat Interval:** 60s
- **Expected status code:** 200

> **Note:** VMSingle health endpoint is `/health` on port 8429 (the HTTP API port). The response should be `OK`.

---

### Task 17: Periodic Comparison Checks (T+24h, T+48h, T+72h)

This is a manual task — run these commands at each checkpoint.

- [ ] **Step 1: Create a comparison script**

```bash
cat > /tmp/vm-compare.sh << 'SCRIPT'
#!/bin/bash
echo "=== VM vs Prometheus Comparison @ $(date -u +"%Y-%m-%d %H:%M UTC") ==="
echo ""

echo "--- Series Counts ---"
PROM_SERIES=$(kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- \
  wget -qO- 'http://localhost:9090/api/v1/status/tsdb' 2>/dev/null | jq '.data.headStats.numSeries')
VM_SERIES=$(kubectl exec -n victoria-metrics deploy/vmsingle-vmsingle -- \
  wget -qO- 'http://localhost:8428/api/v1/status/tsdb' 2>/dev/null | jq '.data.headStats.numSeries')
echo "Prometheus: $PROM_SERIES"
echo "VictoriaMetrics: $VM_SERIES"
if [ -n "$PROM_SERIES" ] && [ -n "$VM_SERIES" ] && [ "$PROM_SERIES" -gt 0 ]; then
  DIFF=$(echo "scale=1; (($VM_SERIES - $PROM_SERIES) * 100) / $PROM_SERIES" | bc)
  echo "Difference: ${DIFF}%"
fi
echo ""

echo "--- RAM Usage ---"
echo "Prometheus:"
kubectl top pod -n monitoring -l app.kubernetes.io/name=prometheus
echo ""
echo "VictoriaMetrics:"
kubectl top pod -n victoria-metrics
echo ""

echo "--- Disk Usage ---"
echo "Prometheus PVCs:"
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- df -h /prometheus 2>/dev/null | tail -1
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-1 -- df -h /prometheus 2>/dev/null | tail -1
echo "VMSingle PVC:"
kubectl exec -n victoria-metrics deploy/vmsingle-vmsingle -- df -h /victoria-metrics-data 2>/dev/null | tail -1
echo ""

echo "--- VMAgent Target Health ---"
kubectl exec -n victoria-metrics deploy/vmagent-vmagent -- \
  wget -qO- 'http://localhost:8429/api/v1/targets' 2>/dev/null | \
  jq -r '.data.activeTargets | group_by(.health) | map({health: .[0].health, count: length}) | .[]'
SCRIPT
chmod +x /tmp/vm-compare.sh
echo "Comparison script created. Run with: bash /tmp/vm-compare.sh"
```

- [ ] **Step 2: Run at T+24h**

```bash
bash /tmp/vm-compare.sh
```

Record results in `/tmp/vm-comparison-log.md`.

- [ ] **Step 3: Run at T+48h**

```bash
bash /tmp/vm-compare.sh
```

- [ ] **Step 4: Run at T+72h (final)**

```bash
bash /tmp/vm-compare.sh
```

---

### Task 18: Post-Comparison Decision and Cleanup

After 72 hours, based on the results:

**If VM wins on RAM (target: >30% reduction):**

- [ ] **Step 1:** Plan full migration (separate plan document)
- [ ] **Step 2:** Keep VM running, begin migration planning

**If VM does NOT show significant improvement or has issues:**

- [ ] **Step 1: Remove VictoriaMetrics**

```bash
# Suspend Flux to prevent re-creation
flux suspend kustomization monitoring-configs
flux suspend kustomization monitoring-controllers

# Delete VM resources
kubectl delete ns victoria-metrics

# Remove from git
git rm -rf monitoring/controllers/base/victoria-metrics/
git rm -rf monitoring/controllers/staging/victoria-metrics/
git rm -rf monitoring/configs/base/victoria-metrics/
git rm -rf monitoring/configs/staging/victoria-metrics/
```

- [ ] **Step 2: Revert staging kustomizations**

Remove `victoria-metrics` from:
- `monitoring/controllers/staging/kustomization.yaml`
- `monitoring/configs/staging/kustomization.yaml`

- [ ] **Step 3: Remove VM datasource from Grafana**

Remove the VictoriaMetrics entry from `additionalDataSources` in the kube-prometheus-stack release.yaml.

- [ ] **Step 4: Commit and push cleanup**

```bash
git add -A
git commit -m "Remove VictoriaMetrics after comparison test"
git push
flux resume kustomization monitoring-configs
flux resume kustomization monitoring-controllers
flux reconcile kustomization monitoring-controllers --timeout=60s
flux reconcile kustomization monitoring-configs --timeout=60s
```

- [ ] **Step 5: Update HOMELAB_ANALYSIS.md with results**

Update the VictoriaMetrics deferred task entry in `docs/HOMELAB_ANALYSIS.md` with test results, decision, and rationale.
