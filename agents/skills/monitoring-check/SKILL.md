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
Alertmanager may show alerts VMAlert doesn't (notification-side failures) — a VMAlert-only check once missed a broken Telegram notification template while everything looked green.

## ScrapeTargetDown but pod `Ready` — metrics server wedged (2026-06-15)
controller-runtime serves metrics (`:8080`) and health (`:8081`) on SEPARATE servers — `:8080/metrics` can hang while probes stay green, so the pod stays `Ready 1/1` and only `up=0` flags it. Fix: `~/.agents/skills/_shared/restart-workload.sh <ns> <selector>` (GitOps-safe; the bot has no workload `patch` since 2026-08-06, so `rollout restart` returns Forbidden — and the helper is what makes a delete-based restart safe on multi-replica workloads). `.lastError` decode table + cross-pod NP-probe gotcha + vm-operator case: `reference-cases.md` § "ScrapeTargetDown but pod Ready".

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

Gotchas baked into the scripts: vmalert leaks raw control chars → `tr -d '\000-\037'` before jq; `ALERTS{}` metric lags ~5min after a rule clears (trust `/api/v1/rules`); `gotk_reconcile_condition`/`gotk_suspend_status` were removed in Flux 2.8.x; **cumulative metrics never clear** — raw threshold on a `_total` counter (or cumulative gauge like redis slowlog_length) fires forever once tripped; alert on `increase(m[24h])`/`delta` instead (2026-06-07 `6b74c6a1`: `KyvernoPolicyViolationsDailySummary` stuck on all-time `kyverno_policy_results_total`=6951 at 0 live violations — audit every alert exprs's `_total` with raw `>N`); a metric live now can be conditionally-absent (`kube_pod_container_status_waiting_reason` only exists while a container waits).

## VictoriaMetrics Health
```bash
bash ~/.agents/skills/monitoring-check/scripts/check-vm.sh   # memory + series + targets
```

## Alert won't clear — triage decision tree

When alert keeps firing AFTER the underlying issue is fixed, run cascade check in this order BEFORE reverting:

```bash
bash ~/.agents/skills/_shared/alert-cascade-check.sh [<alertname>]
```

Composite script that runs steps 1-4 below. Output ends with fix-order summary.

### Step-by-step (if you need to dig manually)

| Step | Check | Symptom → fix |
|---|---|---|
| 1 | Firing alerts snapshot | If alert no longer in list → resolved, you're done |
| 2 | VMAgent queue (`vmagent-queue-check.sh`) | pending > 10MB + DNS errors → `~/.agents/skills/_shared/restart-workload.sh monitoring app.kubernetes.io/name=vmagent` |
| 3 | `up{}` last-sample age per instance (`time() - timestamp(up)`) | age > 120s or a MISSING series on a specific node → that node's scrape broken (a scraped-away series drops out of results entirely — MISSING is the loud form) |
| 4 | VMAlert rule state via `/api/v1/rules` (firing/pending/inactive; "RULE NOT FOUND" = typo'd alertname) | `value` differs from current metric → wait 1-2 rule cycles (60s) + `for:` window |

### VMAgent stuck remoteWrite — root cause, fix, case study

**Symptoms**: alerts NOT clearing despite metric value flipped; range query shows series went stale ~minutes ago; instance-filtered queries return null; `up{}` empty for the affected job; vmagent persistent queue grows MB/min.

**Root cause**: VMAgent's Go `net.DefaultResolver` caches a failed UDP DNS lookup to CoreDNS during a transient network blip (e.g. UFW chain rebuild, kube-proxy chain churn). Cache returns "connection refused" even after CoreDNS recovers. `nslookup` from same pod works — only the Go resolver state is poisoned.

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
pending. The helper deletes one pod at a time and waits for a DIFFERENT pod UID to reach Ready.
Operators on a workstation can still use `rollout restart`.
Queue drains in seconds, alerts re-evaluate at next rule cycle.

**Reference case (2026-05-16 UFW incident) + lessons**: heal succeeded but alert fired 15+ min; 20+ probes to root-cause, a single vmagent restart cleared it. Key lesson: ~95% of "alert won't clear" after a fix = VMAgent stuck queue OR metric staleness window (cadence numbers + full probe list: `reference-cases.md` § "2026-05-16 UFW incident").

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
Gotcha: the chart's k8s-sidecar containers' healthz endpoint dies IPv4-only (upstream k8s-sidecar#531) — loki 18.x sidecar probes CrashLoop; the fix was disabling BOTH sidecar probes. Memory: `gotchas.md` § "k8s-sidecar healthz dies on IPv4-only kernels".

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

Any other service or port returns 403 for the bot. The operator's `kubectl exec ... wget` probes: use `127.0.0.1`, NOT `localhost`. Busybox wget in VM-stack images (vmagent/vmsingle/operator) resolves `localhost`→`::1`; those bind IPv4 only → false `connection refused`. (AM/Grafana images tolerate `localhost`, but pin `127.0.0.1` everywhere for consistency.)

| Service | Endpoint |
|---------|----------|
| VMSingle | `http://127.0.0.1:8429/health` |
| VMAgent | `http://127.0.0.1:8429/health` |
| VMAlert | `http://127.0.0.1:8080/health` |
| Alertmanager | `http://127.0.0.1:9093/-/healthy` |
| Grafana | `http://127.0.0.1:3000/api/health` |
| Loki | `http://127.0.0.1:3100/ready` |

## Baselines (per-line dates carry recency)
- VMSingle memory: ~735Mi
- Series: ~109k active (`vm_cache_entries{type="storage/hour_metric_ids"}`; prior ~204k baseline used a different gauge — compare like-for-like)
- Firing alerts: 0 (VMAlert + AM both clean)
- Popeye: A (90) — NOT the 06-05 "100/100": Job-NPs match no pods between runs + Percona svc lints (POP-1100/1106, deferred 07-04) dilute the score by design. Compare trend, not absolute. POP-1503 reads PolicyViolation EVENTS (~1h TTL) — popeye can false-dirty right after a Kyverno fix while polr is clean; purge events or wait TTL.
- Kyverno violations: 0 (12 CEL ValidatingPolicies, `validationActions: [Deny]`, `.status.conditionStatus.ready=true` — sole engine since 2026-07-12; ClusterPolicies + parity tooling retired; reports-controller limit 800m since 2026-07-13)

## Tools Allowed
- `Bash(kubectl *)`
- `Bash(curl *)`
- `Read`
