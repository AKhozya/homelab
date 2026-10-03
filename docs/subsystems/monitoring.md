# Monitoring map

VictoriaMetrics primary stack. **No Prometheus pod** — kube-prometheus-stack chart kept only for grafana/alertmanager/operator/KSM/node-exporter (`prometheus.enabled=false`). Flux paths: `monitoring/controllers/` + `monitoring/configs/`. Chart + image versions: pinned in the HelmReleases under `monitoring/controllers/` (`*/release.yaml`, `victoria-metrics/operator-release.yaml`, `loki-stack/alloy-release.yaml`) and the VM CRs.

## Stack components
| Component | Type | Purpose |
|-----------|------|---------|
| `vmsingle-vmsingle` | VMSingle (Deploy 1x) | TSDB, retention 90d |
| `vmagent-vmagent` | VMAgent (Deploy 1x) | Scraper (reads VMServiceScrape + VMPodScrape) |
| `vmalert-vmalert` | VMAlert (Deploy 1x) | Rule evaluator (reads VMRule) |
| `victoria-metrics-operator` | Deploy 1x | Reconciles VM CRDs |
| `kube-prometheus-stack-grafana` | Deploy | UI (PVC, sqlite, OIDC, LAN Ingress only) |
| `alertmanager-kube-prometheus-stack-alertmanager` | STS 2x | Alert routing (HA via gossip) |
| `kube-prometheus-stack-operator` | Deploy 1x | prom-operator (manages PrometheusRule/SM CRDs — NOT consumed, see converter warning) |
| `kube-prometheus-stack-kube-state-metrics` | Deploy 1x | k8s state metrics |
| `kube-prometheus-stack-prometheus-node-exporter` | DS (per node) | host metrics |
| `loki` + `alloy` + `loki-canary` | STS / DS / DS (`loki` ns) | log storage / collector / ingest-query probe |
| `popeye` | CronJob (`popeye` ns) | cluster sanitizer, weekly Sun 06:00 UTC (`monitoring/controllers/popeye/`) |
| `trivy-scan` | CronJob (`trivy-scan` ns) | image-CVE scan of running images, monthly 1st 08:00 UTC (`monitoring/configs/trivy-scan/`) |

Chart lineage gotcha: loki chart comes from the **grafana-community** repo (grafana.github.io lineage is frozen GEL-only). Every HelmRelease in `monitoring/controllers/` sets `driftDetection: enabled`; explicit `timeout: 10m` on KPS + loki.

## ⚠️ Prometheus converter DISABLED
Operator values: `operator.disable_prometheus_converter: true` + `enable_converter_ownership: false`. **PrometheusRule and ServiceMonitor are silently ignored** — always use native VMRule + VMServiceScrape.

The cloudflared scrape is the native VMServiceScrape `cloudflared` in `scrape-apps.yaml`. Git holds no coreos `ServiceMonitor`.

## Rules (VMRule)
- `monitoring/configs/victoria-metrics/vmrules.yaml` — `homelab-alerts` (node, pod, mysql, database, redis, kubernetes, certificate, flux, cloudflare-tunnel, kyverno, loki, traefik, firewall/ufw, node-maintenance, immich-gpu-node groups…)
- `monitoring/configs/blocky/prometheusrule.yaml` — `blocky-alerts` (filename is a relic; kind is `VMRule`)
- Verify loaded groups: `kubectl port-forward -n monitoring svc/vmalert-vmalert 8080:8080 && curl localhost:8080/api/v1/rules | jq '.data.groups[].name'`

Alert classes worth knowing:
- **firewall-alerts**: `UfwDisabled`/`UfwServiceInactive`/`UfwChainsUnhealthy` (critical, 5m) — gauges from node-exporter textfile collector via `ufw-state-metric.timer`
- **systemd failed units** — `scrape-node-exporter.yaml` keeps only `node_systemd_unit_state{state="failed"}` and drops the socket counters.

  | Alert | Fires when |
  |---|---|
  | `NodeSystemdUnitFailed` (warning, 15m) | a service, timer, socket, path or target unit stays failed. The collector's default excludes mount, automount, device, scope and slice units |
  | `NodeSystemdCollectorFailed` (warning, 15m) | the collector fails on a node (for example, it cannot reach the host's D-Bus socket), or is not running there |
- **Job failure alerts** — both fire only when the Job itself has failed. A Job that succeeds after a retry does not fire these alerts. A failed backup Job fires only `BackupJobFailed`, and a failed `immich-vm-heal` Job fires neither: `ImmichVMHealJobFailing` covers it. The Job pod vanishes with its TTL, so use VM exit-code metrics, not Loki, for the postmortem.

  | Alert | Expression |
  |---|---|
  | `JobFailed` | `kube_job_failed{condition="true", job_name!~".*backup.*"} == 1`, minus the `immich-vm-heal` Jobs |
  | `BackupJobFailed` | `kube_job_failed{job_name=~".*backup.*",condition="true"} == 1` |

## VMAgent relabel-drops (filtered before remoteWrite, in `vmagent.yaml`)
- `flag`, `config_parameter`, `kube_pod_tolerations`, `etcd_bookmark_counts`
- High-cardinality `_bucket` series: `apiserver_watch_list_duration_seconds_bucket`, `kyverno_(policy_execution|admission_review)_duration_seconds_bucket`, `controller_runtime_reconcile_time_seconds_bucket`, `workqueue_(queue|work)_duration_seconds_bucket`, `rest_client_request_duration_seconds_bucket`, `vm_promscrape_push_data_duration_seconds_bucket`
- `container_memory_(mapped_file|max_usage_bytes|swap|total_inactive_file_bytes)`, `container_(sockets|threads)`, `container_spec_cpu_(period|shares)`, `container_cpu_(system|user)_seconds_total`
- Loop-device fs metrics: `(container_fs_.+|node_filesystem_.+);loop\d+`

## Scrapes (VMServiceScrape / VMPodScrape)
- Scrape files: `monitoring/configs/victoria-metrics/scrape-*.yaml` — apiserver, apps, cnpg-operator, coredns, databases, kube-state-metrics, kubelet, kubelet-cadvisor, kubelet-probes, kyverno, monitoring-stack, node-exporter, vmoperator
- App-specific scrapes also live alongside app configs (e.g. `monitoring/configs/blocky/servicemonitor.yaml` — kind VMServiceScrape despite filename)

## NetworkPolicies
Per-pod NPs: vmsingle/vmagent/vmalert/vmoperator (one file: `victoria-metrics/networkpolicy.yaml`), grafana, alertmanager, kube-state-metrics, prometheus-operator (`kube-prometheus-stack/`), loki + alloy (`controllers/loki-stack/networkpolicy.yaml`), popeye, trivy-scan (`configs/trivy-scan/networkpolicy.yaml`).

Alertmanager does not authenticate requests to port 9093. The `am.h0melab.work` Ingress enforces basic authentication. So Alertmanager's NetworkPolicy (`kube-prometheus-stack/alertmanager-networkpolicy.yaml`) admits only these sources:

| Source | Ports | Client |
|---|---|---|
| namespace `monitoring` | 9093 | vmalert, the vmagent scrape, the Grafana datasource |
| namespace `loki` | 9093 | the Loki ruler |
| namespace `uptime-kuma` | 9093 | the probe |
| namespace `traefik` | 9093 | the `am.h0melab.work` Ingress |
| ipBlock `10.42.0.0/32` | 9093 | the API server service proxy, which the claude-telegram bot reads through; it dials from the control plane's flannel address |
| pods labelled `app.kubernetes.io/name: prometheus` | 9093, 8080 | none: the stack runs no Prometheus pod, so no pod matches; 8080 is the config-reloader metrics port |
| pods labelled `app.kubernetes.io/name: alertmanager` | 9094 TCP and UDP | the HA gossip mesh between Alertmanager pods |

## Dashboards
- ConfigMaps labeled `grafana_dashboard: "1"` auto-loaded by the Grafana sidecar (polls 30s → `/tmp/dashboards/`)
- `monitoring/configs/grafana-dashboards/`: cnpg, redis, traefik-k8s, loki-stack, cert-manager, backup-monitoring, node-maintenance
- **Custom** `blocky-dashboard` — community 13768 had Prometheus hardcoded + an interactive HTML/JS plugin error; panels rebuilt on the VictoriaMetrics datasource
- Standard kube-prometheus-stack dashboards: cluster-total, pod-total, workload-total, node-exporter, kubelet, etc.

## Alertmanager
- 2 STS replicas; receivers: `telegram` (default), `telegram-backup` (backup alerts), `deadman` (Watchdog → healthchecks.io), `null`
- Routing severity-based (critical/warning/info); `alertmanager-overrides` group in vmrules.yaml inhibits noisy alerts
- **Gotcha**: Go templates have NO `sub`/`add`/`mul`/`div` math funcs (use `len`)
- Health check BOTH `/api/v1/alerts` (Prometheus-compat) AND `/api/v2/alerts` (native)

## VMAlert wiring
- `datasource.url` + `remoteWrite.url`: `http://vmsingle-vmsingle.monitoring.svc:8429`
- `notifiers[]`: **both AM pod FQDNs** (`...alertmanager-{0,1}.alertmanager-operated.monitoring.svc:9093`) — a single service URL pinned one endpoint and left AM-0 dark; AM gossip dedupes
- `ruleNamespaceSelector: {}` + `ruleSelector: {}` → VMRules from all namespaces; `evaluationInterval: 60s`

## Loki + Alloy (`loki` ns)
- Alloy config: pod logs through `loki.source.kubernetes` (K8s API, no hostPath); the node-maintenance systemd journal through read-only hostPath mounts of `/var/log/journal` and `/etc/machine-id` (`alloy-release.yaml`); metrics port 12345 (NOT default; prefix `loki_write_*`)
- `loki-canary` DS probes ingest/query latency
- Fresh deploy → "timestamp too old" 400s self-resolve in minutes
- VM-core (vmsingle/vmagent/vmalert): `priorityClassName: homelab-critical`
