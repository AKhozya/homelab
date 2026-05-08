# Monitoring Codemap

VictoriaMetrics primary stack. NO Prometheus pod (only operator chart kept for grafana/alertmanager/operator).

## Stack components
| Component | Type | Purpose |
|-----------|------|---------|
| `vmsingle-vmsingle` | VMSingle (Deploy 1x) | TSDB, retention 90d, 50Gi PVC |
| `vmagent-vmagent` | VMAgent (Deploy 1x) | Scraper (reads VMServiceScrape + VMPodScrape) |
| `vmalert-vmalert` | VMAlert (Deploy 1x) | Rule evaluator (reads VMRule), evaluationInterval 60s |
| `victoria-metrics-operator` | Deploy 1x | Reconciles VM CRDs (helm chart 0.62.1) |
| `kube-prometheus-stack-grafana` | Deploy | UI |
| `alertmanager-kube-prometheus-stack-alertmanager` | STS 2x | Alert routing |
| `kube-prometheus-stack-operator` | Deploy 1x | prom-operator (manages PrometheusRule/SM CRDs but NOT consumed) |
| `kube-prometheus-stack-kube-state-metrics` | Deploy 1x | k8s state metrics |
| `kube-prometheus-stack-prometheus-node-exporter` | DS 3x | host metrics |
| `loki` | STS (`loki` ns) | Log storage |
| `alloy` | DS (`loki` ns) | Log collector → Loki |
| `loki-canary` | DS (`loki` ns) | Loki ingest/query health probe |

## Helm chart versions
| Chart | Version | Notes |
|-------|---------|-------|
| `kube-prometheus-stack` | 84.5.0 | `prometheus.enabled=false` — operator + grafana + alertmanager + KSM + node-exporter only |
| `victoria-metrics-operator` | 0.62.1 | Reconciles VMSingle/VMAgent/VMAlert/VMRule/VMServiceScrape |
| `loki` | 7.0.0 | Includes loki-canary 3.6.7 subchart |
| `alloy` | 1.8.1 | Replaces Promtail |

## Image versions (pinned)
- `victoriametrics/victoria-metrics:v1.140.0` (vmsingle)
- `victoriametrics/vmagent:v1.140.0`
- `victoriametrics/vmalert:v1.140.0`
- `victoriametrics/operator:v0.69.0`
- `grafana/grafana:13.0.1`
- `quay.io/prometheus/alertmanager:v0.32.1`
- `quay.io/prometheus-operator/prometheus-operator:v0.90.1`
- `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.18.0`
- `quay.io/prometheus/node-exporter:v1.11.1`

## ⚠️ Prometheus converter DISABLED
Operator env: `VM_ENABLEDPROMETHEUSCONVERTER_*=false`. **PrometheusRule and ServiceMonitor are silently ignored.** Always use native VMRule + VMServiceScrape directly.

## Rules (VMRule)
| File | VMRule name | Group count | Notable groups |
|------|-------------|-------------|----------------|
| `monitoring/configs/base/victoria-metrics/vmrules.yaml` | `homelab-alerts` | 25 | node, pod, mysql, database, redis-alerts, redis-ha, kubernetes, certificate, flux, cloudflare-tunnel, kyverno, loki, traefik, rebuilderd, firewall (ufw), node-overrides, node-maintenance, etc. |
| `monitoring/configs/staging/blocky/prometheusrule.yaml` | `blocky-alerts` (kind: VMRule) | 1 | blocky (5 alerts) |

vmalert loads 26 groups total across 2 VMRule resources. Verify via: `kubectl port-forward -n monitoring svc/vmalert-vmalert 8080:8080 && curl localhost:8080/api/v1/rules | jq '.data.groups[].name'`

Note: `blocky/prometheusrule.yaml` filename is a relic — kind is already `VMRule`.

## VMAgent relabel-drops (noisy series filtered before remoteWrite)
Drops in `vmagent.yaml`:
- `flag`, `config_parameter`, `kube_pod_tolerations`, `etcd_bookmark_counts`
- High-cardinality `_bucket` series: `apiserver_watch_list_duration_seconds_bucket`, `kyverno_(policy_execution|admission_review)_duration_seconds_bucket`, `controller_runtime_reconcile_time_seconds_bucket`, `workqueue_(queue|work)_duration_seconds_bucket`, `rest_client_request_duration_seconds_bucket`, `vm_promscrape_push_data_duration_seconds_bucket`
- `container_memory_(mapped_file|max_usage_bytes|swap|total_inactive_file_bytes)`, `container_(sockets|threads)`, `container_spec_cpu_(period|shares)`, `container_cpu_(system|user)_seconds_total`
- Loop-device fs metrics: `(container_fs_.+|node_filesystem_.+);loop\d+`

## Service scrapes (VMServiceScrape)
- **26 native VMServiceScrape** + 2 VMPodScrape resources (cluster-wide, all manifests)
- 12 scrape files in `monitoring/configs/base/victoria-metrics/scrape-*.yaml`: apiserver, apps, cnpg-operator, coredns, databases, kube-state-metrics, kubelet, kubelet-cadvisor, kubelet-probes, kyverno, monitoring-stack, node-exporter, vmoperator
- App-specific scrapes also live alongside apps (e.g. `monitoring/configs/staging/blocky/servicemonitor.yaml`)

## Dashboards
- ConfigMaps with label `grafana_dashboard: "1"` auto-loaded by Grafana sidecar
- Sidecar polls every 30s, writes to `/tmp/dashboards/`
- Grafana `sidecarProvider` reads `/tmp/dashboards/` every 30s
- **Custom**: `blocky-dashboard` (custom panels using VictoriaMetrics datasource — community 13768 had Prometheus hardcoded + interactive HTML/JS plugin error)
- Standard kube-prometheus-stack dashboards: cluster-total, pod-total, workload-total, node-exporter, kubelet, etc.

## Alertmanager
- 2 STS replicas (HA via gossip)
- Receivers: Telegram (bot via `alertmanager-telegram` Secret)
- Routing: severity-based (critical/warning/info)
- Templates: `alertmanager-overrides` group in vmrules.yaml inhibits noisy alerts
- **Gotcha**: Go templates have NO `sub`/`add`/`mul`/`div` math funcs (use `len`)
- Health check: BOTH `/api/v1/alerts` (Prometheus-compat) AND `/api/v2/alerts` (Alertmanager native)

## VMAlert wiring
- `datasource.url`: `http://vmsingle-vmsingle.monitoring.svc:8429`
- `remoteWrite.url`: `http://vmsingle-vmsingle.monitoring.svc:8429` (recording rule results)
- `notifier.url`: `http://alertmanager-operated.monitoring.svc:9093`
- `ruleNamespaceSelector: {}` + `ruleSelector: {}` → picks up VMRules from all namespaces
- `replicaCount: 1`, `evaluationInterval: 60s`

## Loki + Alloy (in `loki` namespace, separated from `monitoring`)
- **Alloy** = Grafana's log collector (replaces Promtail)
- Config: `loki.source.kubernetes` (K8s API, NO hostPath)
- Metrics port: 12345 (NOT default; prefix `loki_write_*`)
- `loki-canary` DS provides ingest/query latency probes
- Fresh deploy → "timestamp too old" 400s self-resolve in minutes

## Resource quotas / limits
- monitoring ns: 16 CPU lim, 24Gi mem lim
- vmsingle: 100m / 512Mi req → 500m / 1500Mi lim, 50Gi PVC
- vmagent: 100m / 256Mi req → 500m / 512Mi lim
- vmalert: 50m / 128Mi req → 200m / 256Mi lim
- Loki: 1Gi req / 4Gi lim (chunk index growth)
- Grafana: 256Mi req / 512Mi lim

## Decommissioned
- Prometheus pods (replaced by vmsingle, 2026-Q1)
- Prometheus PVCs (~100Gi) deleted 2026-04-26
- `monitoring/configs/staging/kube-prometheus-stack/prometheus-rules.yaml` deleted 2026-04-26 (1183 lines, all groups duplicated to vmrules.yaml + redis-ha was missing)
- Loki/Alloy moved out of `monitoring` ns into dedicated `loki` ns
