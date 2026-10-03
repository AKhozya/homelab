# Monitoring Check — reference cases

Incident case studies + decode tables behind SKILL.md's triage rules.

## ScrapeTargetDown but pod Ready — metrics server wedged (2026-06-15)

controller-runtime serves metrics (`:8080`) and health (`:8081`) on SEPARATE servers — `:8080/metrics` can hang while probes stay green, so the pod stays `Ready 1/1` and only `up=0` flags it.

Extra mechanism behind SKILL.md's rule: controller-runtime serves metrics (`:8080`) and health (`:8081`) on SEPARATE servers — `:8080/metrics` can hang (accepts TCP, never sends headers) while `:8081/health` keeps the readiness probe green, so `:8081` probes can't catch it.

**`.lastError` decode** (vmagent `/api/v1/targets`):

| lastError | Meaning |
|---|---|
| `awaiting headers` | metrics server wedged (this case) |
| `connection refused` | listener gone, OR a NetworkPolicy blocks the scrape: kube-router REJECTs NP-blocked traffic in both directions (pod.go, `k3s-io/kube-router` v2.6.3-k3s1, the k3s v1.37.0+k3s1 pin). Check the target's ingress NP before the app |
| connect `i/o timeout` | usually a dropped packet: host firewall (UFW, for host-network targets) or an unreachable node. kube-router normally rejects NP-blocked traffic, but a timeout alone does not rule out a NetworkPolicy |

Gotcha: a cross-pod probe of a NON-scrape port (vmagent→`:8081`) falsely shows `connection refused` — the app NP opens only `:8080`; trust kubelet `Ready`, not your own probe. Case: vm-operator v0.71.0 `:8080` wedged after 2d16h, lease still renewing.

## VMAgent stuck remoteWrite — 2026-05-16 UFW incident + lessons

**Reference case (2026-05-16 UFW incident) + lessons**: heal succeeded but alert fired 15+ min; 20+ probes to root-cause, a single vmagent restart cleared it.

**Reference case**: `UfwDisabled` fired on worker-node. `ufw-heal-post-k3s.service` succeeded (probe healthy, ENABLED=yes pinned, `ufw_state.prom` showed `ufw_enabled=1`), but alert kept firing 15+ min. Took 20+ probes to root-cause (ufw.conf, state-metric, textfile path, kube-proxy NAT, CoreDNS endpoints, nslookup, ServiceMonitor relabel, VMAgent drop config, target health, time skew, persistent queue, vmagent log). Single vmagent restart cleared it. Full incident detail: memory `gotchas.md` § "VMAgent Go DNS resolver stuck...".

**Lessons** (drive SKILL.md's triage order):

- Reverting upstream fixes (e.g. disabling UFW back) cascades MORE failures.
- Restarting kube-proxy or k3s-agent is heavy and rarely the actual fix.
- ~95% of "alert won't clear" after a fix = VMAgent stuck queue OR metric staleness window (textfile write cadence + scrape + `for:`; node-exporter textfile ~60s → up to ~7 min, but 5m-cadence timer-written textfile metrics → up to ~10-12 min).
- `alert-cascade-check.sh` runs the right order; cuts diagnosis from 20+ probes to 3-4.

## Gotchas baked into the alert scripts

Gotchas baked into the scripts: vmalert leaks raw control chars → `tr -d '\000-\037'` before jq; `ALERTS{}` metric lags ~5min after a rule clears (trust `/api/v1/rules`); `gotk_reconcile_condition`/`gotk_suspend_status` were removed in Flux 2.8.x; **cumulative metrics never clear** — raw threshold on a `_total` counter (or cumulative gauge like redis slowlog_length) fires forever once tripped; alert on `increase(m[24h])`/`delta` instead (2026-06-07 `6b74c6a1`: `KyvernoPolicyViolationsDailySummary` stuck on all-time `kyverno_policy_results_total`=6951 at 0 live violations — audit every alert exprs's `_total` with raw `>N`); a metric live now can be conditionally-absent (`kube_pod_container_status_waiting_reason` only exists while a container waits).

## Alert won't clear — manual steps

### Step-by-step (if you need to dig manually)

| Step | Check | Symptom → fix |
|---|---|---|
| 1 | Firing alerts snapshot | If alert no longer in list → resolved, you're done |
| 2 | VMAgent queue (`vmagent-queue-check.sh`) | pending > 10MB + DNS errors → `~/.agents/skills/_shared/restart-workload.sh monitoring app.kubernetes.io/name=vmagent` |
| 3 | `up{}` last-sample age per instance (`time() - timestamp(up)`) | age > 120s or a MISSING series on a specific node → that node's scrape broken (a scraped-away series drops out of results entirely — MISSING is the loud form) |
| 4 | VMAlert rule state via `/api/v1/rules` (firing/pending/inactive; "RULE NOT FOUND" = typo'd alertname) | `value` differs from current metric → wait 1-2 rule cycles (60s) + `for:` window |

## VMAgent stuck remoteWrite — root cause

**Root cause**: VMAgent's Go `net.DefaultResolver` caches a failed UDP DNS lookup to CoreDNS during a transient network blip (e.g. UFW chain rebuild, kube-proxy chain churn). Cache returns "connection refused" even after CoreDNS recovers. `nslookup` from same pod works — only the Go resolver state is poisoned.

## Loki k8s-sidecar probes

Gotcha: the loki chart's k8s-sidecar probes.

| Fact | Source |
|---|---|
| Before 2.10.0 the sidecar's health server stops on IPv4-only nodes (upstream #531); the repo turned its probes off | `d1b586ca` |
| 2.10.0+ serves `/healthz` on IPv4; the probes are on again | `8b3d4e68` |
| At 50m CPU the Python start takes 84s, near the ~90s liveness limit; the sidecar now has 200m and a 300s startupProbe | `ff65f775` |

Memory: `gotchas.md` § "k8s-sidecar healthz dies on IPv4-only kernels".

## Baselines (per-line dates carry recency)
- VMSingle memory: ~735Mi
- Series: ~109k active (`vm_cache_entries{type="storage/hour_metric_ids"}`; prior ~204k baseline used a different gauge — compare like-for-like)
- Firing alerts: 0 (VMAlert + AM both clean)
- Popeye: A (90) — NOT the 06-05 "100/100": Job-NPs match no pods between runs + Percona svc lints (POP-1100/1106, deferred 07-04) dilute the score by design. Compare trend, not absolute. POP-1503 reads PolicyViolation EVENTS (~1h TTL) — popeye can false-dirty right after a Kyverno fix while polr is clean; purge events or wait TTL.
- Kyverno violations: 0 (12 CEL ValidatingPolicies, `validationActions: [Deny]`, `.status.conditionStatus.ready=true` — sole engine since 2026-07-12; ClusterPolicies + parity tooling retired; reports-controller limit 800m since 2026-07-13)

## Why both VMAlert and Alertmanager

Alertmanager may show alerts VMAlert doesn't (notification-side failures) — a VMAlert-only check once missed a broken Telegram notification template while everything looked green.

## VMAgent restart — what restart-workload.sh does

`_shared/restart-workload.sh` deletes one pod at a time and waits for a DIFFERENT pod UID to reach Ready. Queue drains in seconds, alerts re-evaluate at next rule cycle.

## Why 127.0.0.1, not localhost

Busybox wget in VM-stack images (vmagent/vmsingle/operator) resolves `localhost`→`::1`; those bind IPv4 only → false `connection refused`. (AM/Grafana images tolerate `localhost`, but pin `127.0.0.1` everywhere for consistency.)
