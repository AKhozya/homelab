# Monitoring Codemap

VictoriaMetrics primary stack. NO Prometheus pod (only operator chart kept for grafana/alertmanager/operator).

## Layout (flat since 2026-05-31)
`monitoring/controllers/` and `monitoring/configs/` are flat — base/staging overlays collapsed render-identical (`b53a4cab` controllers, `081934c0` configs). Flux paths: `./monitoring/controllers` + `./monitoring/configs` (clusters/monitoring.yaml).

## Stack components
| Component | Type | Purpose |
|-----------|------|---------|
| `vmsingle-vmsingle` | VMSingle (Deploy 1x) | TSDB, retention 90d, 50Gi PVC |
| `vmagent-vmagent` | VMAgent (Deploy 1x) | Scraper (reads VMServiceScrape + VMPodScrape) |
| `vmalert-vmalert` | VMAlert (Deploy 1x) | Rule evaluator (reads VMRule), evaluationInterval 60s |
| `victoria-metrics-operator` | Deploy 1x | Reconciles VM CRDs (helm chart 0.63.1) |
| `kube-prometheus-stack-grafana` | Deploy | UI |
| `alertmanager-kube-prometheus-stack-alertmanager` | STS 2x | Alert routing |
| `kube-prometheus-stack-operator` | Deploy 1x | prom-operator (manages PrometheusRule/SM CRDs but NOT consumed) |
| `kube-prometheus-stack-kube-state-metrics` | Deploy 1x | k8s state metrics |
| `kube-prometheus-stack-prometheus-node-exporter` | DS (per node) | host metrics |
| `loki` | STS (`loki` ns) | Log storage |
| `alloy` | DS (`loki` ns) | Log collector → Loki |
| `loki-canary` | DS (`loki` ns) | Loki ingest/query health probe |
| `popeye` | CronJob (`popeye` ns) | Cluster sanitizer scan, weekly Sun 06:00 UTC (`monitoring/controllers/popeye/`) |
| `trivy-scan` | CronJob (`trivy-scan` ns) | Image-CVE scan of all running images, monthly 1st 08:00 UTC, table to stdout/Loki (`monitoring/configs/trivy-scan/`) — replaced trivy-operator 2026-07-14 |

## Helm chart versions
| Chart | Version | Notes |
|-------|---------|-------|
| `kube-prometheus-stack` | 86.1.1 | `prometheus.enabled=false` — operator + grafana + alertmanager + KSM + node-exporter only |
| `victoria-metrics-operator` | 0.63.1 | Reconciles VMSingle/VMAgent/VMAlert/VMRule/VMServiceScrape |
| `loki` | 18.4.0 | `grafana-community` lineage (grafana.github.io frozen GEL-only at 7.0.0); loki + canary 3.7.3 |
| `alloy` | 1.8.2 | Replaces Promtail |

All 4 HelmReleases: `driftDetection: {mode: enabled}`; explicit `timeout: 10m` on KPS + loki; `interval: 6h` standard (Wave 9, `60a8bf32`, 2026-05-24).

## Image versions (pinned)
- `victoriametrics/victoria-metrics:v1.143.0` (vmsingle)
- `victoriametrics/vmagent:v1.143.0`
- `victoriametrics/vmalert:v1.143.0`
- `victoriametrics/operator:v0.70.1`
- `grafana/grafana:13.0.1-security-01`
- `quay.io/prometheus/alertmanager:v0.32.1`
- `quay.io/prometheus-operator/prometheus-operator:v0.91.0`
- `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.19.0`
- `quay.io/prometheus/node-exporter:v1.11.1-distroless`
- `docker.io/grafana/loki:3.6.7` + `grafana/loki-canary:3.6.7`
- `docker.io/grafana/alloy:v1.16.1`
- `derailed/popeye:v0.22.1`
- `aquasec/trivy` + `rancher/shell` (trivy-scan CronJob: scanner + kubectl image-inventory init; pins renovate-managed — see `monitoring/configs/trivy-scan/cronjob.yaml`)

## ⚠️ Prometheus converter DISABLED
Operator helm values: `operator.disable_prometheus_converter: true` + `enable_converter_ownership: false`. **PrometheusRule and ServiceMonitor are silently ignored.** Always use native VMRule + VMServiceScrape directly.

Exception oddity: `monitoring/configs/cloudflared/cloudflared-servicemonitor.yaml` is a coreos `ServiceMonitor` (evicted to own dir `acac60d3` to escape the victoria-metrics namespace transform). Its kustomization comment claims VMAgent discovers it via `serviceScrapeSelector: {}`, but the real scrape is the native VMServiceScrape `cloudflared` in `scrape-apps.yaml` — converter disabled means the ServiceMonitor itself is likely inert.

## Rules (VMRule)
| File | VMRule name | Groups | Alerts | Notable groups |
|------|-------------|--------|--------|----------------|
| `monitoring/configs/victoria-metrics/vmrules.yaml` | `homelab-alerts` | 25 | 123 | node, pod, mysql, database, redis-alerts, redis-ha, kubernetes, certificate, flux, cloudflare-tunnel, kyverno, loki, traefik, firewall (ufw), node-overrides, node-maintenance, immich-gpu-node-alerts, etc. |
| `monitoring/configs/blocky/prometheusrule.yaml` | `blocky-alerts` (kind: VMRule) | 1 | 5 | blocky |

vmalert loads 26 groups total across 2 VMRule resources. Verify via: `kubectl port-forward -n monitoring svc/vmalert-vmalert 8080:8080 && curl localhost:8080/api/v1/rules | jq '.data.groups[].name'`

Note: `blocky/prometheusrule.yaml` filename is a relic — kind is already `VMRule`.

Alert classes worth knowing:
- **firewall-alerts**: `UfwDisabled`/`UfwServiceInactive`/`UfwChainsUnhealthy` (critical, 5m) — gauges from node-exporter textfile collector via `ufw-state-metric.timer`.
- **JobFailed** (kubernetes-alerts, `kube_job_status_failed > 0`) — fires on TTL+force daily re-run Jobs that fail; 2026-06-04 RCA: audiobookshelf-init curl×6 during wn2 DNS outage. Job pod vanishes with TTL — use VM exit-code metrics, not Loki, for postmortem.

## VMAgent relabel-drops (noisy series filtered before remoteWrite)
Drops in `vmagent.yaml`:
- `flag`, `config_parameter`, `kube_pod_tolerations`, `etcd_bookmark_counts`
- High-cardinality `_bucket` series: `apiserver_watch_list_duration_seconds_bucket`, `kyverno_(policy_execution|admission_review)_duration_seconds_bucket`, `controller_runtime_reconcile_time_seconds_bucket`, `workqueue_(queue|work)_duration_seconds_bucket`, `rest_client_request_duration_seconds_bucket`, `vm_promscrape_push_data_duration_seconds_bucket`
- `container_memory_(mapped_file|max_usage_bytes|swap|total_inactive_file_bytes)`, `container_(sockets|threads)`, `container_spec_cpu_(period|shares)`, `container_cpu_(system|user)_seconds_total`
- Loop-device fs metrics: `(container_fs_.+|node_filesystem_.+);loop\d+`

## Service scrapes (VMServiceScrape)
- **26 VMServiceScrape** + 2 VMPodScrape manifests repo-wide (2026-06-05)
- 13 scrape files in `monitoring/configs/victoria-metrics/scrape-*.yaml`: apiserver, apps, cnpg-operator, coredns, databases, kube-state-metrics, kubelet, kubelet-cadvisor, kubelet-probes, kyverno, monitoring-stack, node-exporter, vmoperator
- App-specific scrapes also live alongside apps (e.g. `monitoring/configs/blocky/servicemonitor.yaml` — kind VMServiceScrape despite filename)

## NetworkPolicies (coverage complete, `208dd218`)
Per-pod NPs: vmsingle/vmagent/vmalert/vmoperator (`victoria-metrics/networkpolicy.yaml`, 4-in-1), grafana, alertmanager, kube-state-metrics, prometheus-operator (`kube-prometheus-stack/` dir), loki + alloy (`controllers/loki-stack/networkpolicy.yaml`), popeye. Orphan prometheus NP dropped (server disabled).

## Dashboards
- ConfigMaps with label `grafana_dashboard: "1"` auto-loaded by Grafana sidecar
- Sidecar polls every 30s, writes to `/tmp/dashboards/`
- Grafana `sidecarProvider` reads `/tmp/dashboards/` every 30s
- `monitoring/configs/grafana-dashboards/`: cnpg, redis, traefik-k8s, loki-stack, cert-manager, backup-monitoring, node-maintenance
- **Custom**: `blocky-dashboard` (custom panels using VictoriaMetrics datasource — community 13768 had Prometheus hardcoded + interactive HTML/JS plugin error)
- Standard kube-prometheus-stack dashboards: cluster-total, pod-total, workload-total, node-exporter, kubelet, etc.

## Alertmanager
- 2 STS replicas (HA via gossip)
- Receivers: `telegram` (default, bot via `alertmanager-telegram` Secret), `telegram-backup` (backup alerts), `deadman` (Watchdog → healthchecks.io), `null` (`telegram-digest` removed with trivy-operator 2026-07-14)
- Routing: severity-based (critical/warning/info)
- Templates: `alertmanager-overrides` group in vmrules.yaml inhibits noisy alerts
- **Gotcha**: Go templates have NO `sub`/`add`/`mul`/`div` math funcs (use `len`)
- Health check: BOTH `/api/v1/alerts` (Prometheus-compat) AND `/api/v2/alerts` (Alertmanager native)

## VMAlert wiring
- `datasource.url`: `http://vmsingle-vmsingle.monitoring.svc:8429`
- `remoteWrite.url`: `http://vmsingle-vmsingle.monitoring.svc:8429` (recording rule results)
- `notifiers[]`: both AM pod FQDNs (`...alertmanager-{0,1}.alertmanager-operated.monitoring.svc:9093`) — a single service URL pinned one endpoint leaving AM-0 dark (fixed 2026-07-04); AM gossip dedupes
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
- VM-core (vmsingle/vmagent/vmalert): `priorityClassName: homelab-critical` (`85d39527`)

## Decommissioned
- Prometheus pods (replaced by vmsingle, 2026-Q1)
- Prometheus PVCs (~100Gi) deleted 2026-04-26
- `monitoring/configs/kube-prometheus-stack/prometheus-rules.yaml` deleted 2026-04-26 (1183 lines, all groups duplicated to vmrules.yaml + redis-ha was missing)
- Loki/Alloy moved out of `monitoring` ns into dedicated `loki` ns
- base/staging overlay dirs under `monitoring/` (flattened 2026-05-31)
