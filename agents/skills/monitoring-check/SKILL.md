---
name: monitoring-check
description: "Use to check homelab monitoring stack health — VictoriaMetrics (vmsingle/vmagent/vmalert), Grafana, Loki, Alertmanager (v2), Popeye, Kyverno. Also: alert won't clear / staleness window / VMAgent stuck remoteWrite / Go DNS resolver cached failure. Always queries BOTH VMAlert AND Alertmanager — one alone can look clean while notification routing is broken."
---

# Monitoring Check Skill

## Firing Alerts

Dual check (VMAlert rule eval + Alertmanager notification pipeline) via shared script:
```bash
bash ~/.agents/skills/_shared/check-alerts.sh           # text: VMALERT|... AM|... lines
bash ~/.agents/skills/_shared/check-alerts.sh --count   # vmalert=N alertmanager=M
bash ~/.agents/skills/_shared/check-alerts.sh --json    # structured (jq)
```

## ScrapeTargetDown but pod `Ready` — metrics server wedged (2026-06-15)
Fix: `~/.agents/skills/_shared/restart-workload.sh <ns> <selector>` (GitOps-safe; the bot has no workload `patch` since 2026-08-06, so `rollout restart` returns Forbidden — and the helper is what makes a delete-based restart safe on multi-replica workloads). `.lastError` decode table + cross-pod NP-probe gotcha + vm-operator case: `reference-cases.md` § "ScrapeTargetDown but pod Ready".

## Editing vmrules.yaml — mandatory gate (UR2 2026-06-06)
A dead alert (metric drifted / wrong job label / metric removed upstream) shows 0 firing — identical to healthy. So you cannot trust "no alerts" after a vmrules edit. Two scripts:
```bash
# PRE-COMMIT: every alert metric has series + every job= matches a live target
bash ~/.agents/skills/_shared/vmrules-metric-audit.sh [vmrules.yaml]
# POST-RECONCILE: authoritative firing + PENDING + unhealthy from vmalert (not the lagging ALERTS metric)
bash ~/.agents/skills/_shared/vmalert-state.sh            # --quiet for problems-only
```
**New exporter? Metric names aren't knowable until it runs** — `vmrules-metric-audit.sh` can't pre-check series that don't exist yet, and DB major versions RENAME metrics: MySQL 8.4 `SHOW REPLICA STATUS` emits `mysql_slave_status_replica_{sql,io}_running` / `_seconds_behind_source`, NOT the legacy `slave_*`/`master` (2026-06-07 — old `SHOW SLAVE STATUS`-based alerts went dead). **Split the work:** ship the exporter+scrape → query VM `/api/v1/query?query=<metric_prefix>` for the ACTUAL live series + `job=` label → THEN author the alerts. Writing alerts from docs / old-version names = dead alerts that look healthy.

**Test the EXACT expr live before commit (audit script only checks metric/job existence, not that the expr FIRES right):** query it via `/api/v1/query` — healthy state → empty (no false-fire); prove the firing direction by running the `==0`/threshold against a sibling counter that is currently 0 (e.g. `controller_runtime_reconcile_errors_total{...}==0` returns `0`, so the filter matches when value is 0); confirm absent-series → empty (no double-fire with a broader `up==0` alert like ScrapeTargetDown). 2026-06-15 `072eeaac` `VMOperatorReconcileStalled` (operator up but reconcile loop stalled) shipped this way — see memory `gotcha_vmalert_flux_metrics`.

Never put a raw threshold on a cumulative counter or gauge (`_total`, redis `slowlog_length`): once tripped it fires for ever. Alert on `increase(m[24h])` or `delta` instead.
If you query vmalert or VMSingle by hand, read `reference-cases.md` § "Gotchas baked into the alert scripts" first (control characters, `ALERTS{}` lag, cumulative counters).

## VictoriaMetrics Health
```bash
bash ~/.agents/skills/monitoring-check/scripts/check-vm.sh   # memory + series + targets
```
`check-vm.sh` and `check-loki.sh` use `kubectl port-forward`, which the claude-telegram bot's RBAC
does not grant. From the bot, query vmsingle through the API service proxy instead (AGENTS.md).

## Alert won't clear — triage decision tree

When alert keeps firing AFTER the underlying issue is fixed, run cascade check in this order BEFORE reverting:

```bash
bash ~/.agents/skills/_shared/alert-cascade-check.sh [<alertname>]
```

Composite script that runs steps 1-4 of `reference-cases.md` § "Alert won't clear — manual steps". Output ends with fix-order summary.

If you investigate an alert by hand, read `reference-cases.md` § "Alert won't clear — manual steps" for the symptom and fix of each step.

### VMAgent stuck remoteWrite — root cause, fix, case study

**Symptoms**: alerts NOT clearing despite metric value flipped; range query shows series went stale ~minutes ago; instance-filtered queries return null; `up{}` empty for the affected job; vmagent persistent queue grows MB/min.

If `nslookup` works from the VMAgent pod but VMAgent still fails DNS lookups, read `reference-cases.md` § "VMAgent stuck remoteWrite — root cause".

**Diagnostic**:
```bash
bash ~/.agents/skills/_shared/vmagent-queue-check.sh   # pending + dropped + recent errors
```
Watch for `vm_persistentqueue_bytes_pending` > 10MB + log lines `dial tcp4: lookup ... refused`.

**Fix** (cheap, safe — no cluster mutation outside the pod):
```bash
~/.agents/skills/_shared/restart-workload.sh monitoring app.kubernetes.io/name=vmagent
```

Not `rollout restart`: the bot's ServiceAccount lost workload `patch` on 2026-08-06 (RBAC cannot
express "only the restartedAt annotation", so the grant meant rewriting the whole pod template).
Not a bare `delete pod -l …` either — that deletes every replica at once and bypasses any PDB, and
`rollout status` afterwards is not a gate, because deleting a pod does not bump the Deployment
generation, so it reports the PREVIOUS rollout complete and returns 0 while the replacement is still
pending.
Operators on a workstation can still use `rollout restart`.

Key lesson: ~95% of "alert won't clear" after a fix = VMAgent stuck queue OR metric staleness window (cadence numbers + full probe list: `reference-cases.md` § "2026-05-16 UFW incident").

## Alertmanager Status
```bash
# Check pods
kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager

# Cluster status
kubectl get --raw \
  /api/v1/namespaces/monitoring/services/kube-prometheus-stack-alertmanager:9093/proxy/api/v2/status |
  jq '.cluster.status'
```

## Grafana Health
```bash
bash ~/.agents/skills/monitoring-check/scripts/check-grafana.sh
```

## Loki Health
```bash
bash ~/.agents/skills/monitoring-check/scripts/check-loki.sh
```
If a Loki k8s-sidecar probe fails or the sidecar restarts, read `reference-cases.md` § "Loki k8s-sidecar probes".

## Cluster Scanners

### Popeye
```bash
bash ~/.agents/skills/monitoring-check/scripts/check-popeye.sh         # latest results
bash ~/.agents/skills/monitoring-check/scripts/check-popeye.sh --run   # trigger new scan
```

### Kyverno Violations
```bash
bash ~/.agents/skills/_shared/check-kyverno.sh --modes   # violations + policy modes (strict: exit 2 on fetch fail)
```

## Resource Pressure
```bash
# Memory/CPU by namespace (columns: NAMESPACE NAME CPU(m) MEMORY(Mi))
kubectl top pods -A --no-headers | \
  awk '{cpu[$1]+=$3; mem[$1]+=$4} END {for(n in mem) print n, cpu[n] "m", mem[n] "Mi"}' | \
  sort -k3 -rn | head -10

# PVC usage
kubectl get pv -o custom-columns=NAME:.metadata.name,CAPACITY:.spec.capacity.storage,STATUS:.status.phase
```

## Health Endpoints

The claude-telegram bot reads three services through the API server's service proxy, `kubectl get --raw /api/v1/namespaces/monitoring/services/<name>:<port>/proxy/<path>`:

| Service | `<name>:<port>` |
|---|---|
| VMSingle | `vmsingle-vmsingle:8429` |
| VMAlert | `vmalert-vmalert:8080` |
| Alertmanager | `kube-prometheus-stack-alertmanager:9093` |

Any other service or port returns 403 for the bot. The operator's `kubectl exec ... wget` probes: use `127.0.0.1`, NOT `localhost`.

| Service | Endpoint |
|---------|----------|
| VMSingle | `http://127.0.0.1:8429/health` |
| VMAgent | `http://127.0.0.1:8429/health` |
| VMAlert | `http://127.0.0.1:8080/health` |
| Alertmanager | `http://127.0.0.1:9093/-/healthy` |
| Grafana | `http://127.0.0.1:3000/api/health` |
| Loki | `http://127.0.0.1:3100/ready` |

Before you judge a VMSingle memory, series, alert, Popeye or Kyverno number, read `reference-cases.md` § "Baselines".
For Popeye, compare the trend between runs, not the absolute score.
For series counts, compare numbers from the same gauge: the older baseline used a different one.

## Tools Allowed
- `Bash(kubectl *)`
- `Bash(curl *)`
- `Read`
