# Monitoring Codemap

VictoriaMetrics primary stack. NO Prometheus pod (only operator chart kept for grafana/alertmanager/operator).

## Stack components
| Component | Type | Purpose |
|-----------|------|---------|
| `vmsingle-vmsingle` | Deploy 1x | TSDB, retention 30d |
| `vmagent-vmagent` | Deploy 1x | Scraper (reads VMServiceScrape + VMPodScrape) |
| `vmalert-vmalert` | Deploy 1x | Rule evaluator (reads VMRule) |
| `victoria-metrics-operator` | Deploy 1x | Reconciles VM CRDs |
| `kube-prometheus-stack-grafana` | Deploy | UI |
| `alertmanager-kube-prometheus-stack-alertmanager` | STS 2x | Alert routing |
| `kube-prometheus-stack-operator` | Deploy 1x | prom-operator (manages PrometheusRule/SM CRDs but NOT consumed) |
| `kube-prometheus-stack-kube-state-metrics` | Deploy 1x | k8s state metrics |
| `kube-prometheus-stack-prometheus-node-exporter` | DS 3x | host metrics |
| `loki` | STS | Log storage |
| `alloy` | DS | Log collector → Loki |

## ⚠️ Prometheus converter DISABLED
Operator env: `VM_ENABLEDPROMETHEUSCONVERTER_*=false`. **PrometheusRule and ServiceMonitor are silently ignored.** Always use native VMRule + VMServiceScrape directly.

## Rules (VMRule)
| File | Group count | Notable groups |
|------|-------------|----------------|
| `monitoring/configs/base/victoria-metrics/vmrules.yaml` | 24 | node, pod, mysql, database, redis-alerts, **redis-ha** (added 2026-04-26), kubernetes, certificate, flux, cloudflare-tunnel, kyverno, etc. |
| `monitoring/configs/staging/blocky/prometheusrule.yaml` | 1 | blocky (5 alerts) |

vmalert loads 25 groups total. Verify via: `kubectl port-forward -n monitoring svc/vmalert-vmalert 8080:8080 && curl localhost:8080/api/v1/rules | jq '.data.groups[].name'`

## Service scrapes (VMServiceScrape)
- **37 native VMServiceScrape** resources across multiple namespaces
- Cluster-wide infra: `cnpg-operator-cloudnative-pg`, `main-postgres-cluster`, `cert-manager`, `cloudflared`, `kyverno-*` (4), `loki`, `alertmanager`, `alloy`, `coredns`, `kubelet`, `monitoring-stack`, `apps`
- App-specific: `blocky` (added 2026-04-26)
- Naming: scrapes in `monitoring/configs/base/victoria-metrics/scrape-*.yaml`

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

## Loki + Alloy
- **Alloy** = Grafana's log collector (replaces Promtail)
- Config: `loki.source.kubernetes` (K8s API, NO hostPath)
- Metrics port: 12345 (NOT default; prefix `loki_write_*`)
- Fresh deploy → "timestamp too old" 400s self-resolve in minutes

## Resource quotas
- monitoring ns: 16 CPU lim, 24Gi mem lim
- vmsingle: 1Gi req / 2Gi lim
- Loki: 1Gi req / 4Gi lim (chunk index growth)
- Grafana: 256Mi req / 512Mi lim

## Decommissioned
- Prometheus pods (replaced by vmsingle, 2026-Q1)
- Prometheus PVCs (~100Gi) deleted 2026-04-26
- `monitoring/configs/staging/kube-prometheus-stack/prometheus-rules.yaml` deleted 2026-04-26 (1183 lines, all groups duplicated to vmrules.yaml + redis-ha was missing)
