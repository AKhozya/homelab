# Monitoring Check — reference cases

Incident case studies + decode tables behind SKILL.md's triage rules.

## ScrapeTargetDown but pod Ready — metrics server wedged (2026-06-15)

Extra mechanism behind SKILL.md's rule: controller-runtime serves metrics (`:8080`) and health (`:8081`) on SEPARATE servers — `:8080/metrics` can hang (accepts TCP, never sends headers) while `:8081/health` keeps the readiness probe green, so `:8081` probes can't catch it.

**`.lastError` decode** (vmagent `/api/v1/targets`):

| lastError | Meaning |
|---|---|
| `awaiting headers` | metrics server wedged (this case) |
| `connection refused` | listener gone |
| connect `i/o timeout` | NetworkPolicy blocking scrape |

Gotcha: a cross-pod probe of a NON-scrape port (vmagent→`:8081`) falsely shows `connection refused` — the app NP opens only `:8080`; trust kubelet `Ready`, not your own probe. Case: vm-operator v0.71.0 `:8080` wedged after 2d16h, lease still renewing.

## VMAgent stuck remoteWrite — 2026-05-16 UFW incident + lessons

**Reference case**: `UfwDisabled` fired on worker-node. `ufw-heal-post-k3s.service` succeeded (probe healthy, ENABLED=yes pinned, `ufw_state.prom` showed `ufw_enabled=1`), but alert kept firing 15+ min. Took 20+ probes to root-cause (ufw.conf, state-metric, textfile path, kube-proxy NAT, CoreDNS endpoints, nslookup, ServiceMonitor relabel, VMAgent drop config, target health, time skew, persistent queue, vmagent log). Single vmagent restart cleared it. Full incident detail: memory `gotchas.md` § "VMAgent Go DNS resolver stuck...".

**Lessons** (drive SKILL.md's triage order):

- Reverting upstream fixes (e.g. disabling UFW back) cascades MORE failures.
- Restarting kube-proxy or k3s-agent is heavy and rarely the actual fix.
- ~95% of "alert won't clear" after a fix = VMAgent stuck queue OR metric staleness window (textfile write cadence + scrape + `for:`; node-exporter textfile ~60s → up to ~7 min, but 5m-cadence timer-written textfile metrics → up to ~10-12 min).
- `alert-cascade-check.sh` runs the right order; cuts diagnosis from 20+ probes to 3-4.
