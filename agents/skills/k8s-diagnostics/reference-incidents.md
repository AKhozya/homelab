# K8s Diagnostics — incident playbooks

Situational forensics behind SKILL.md's symptom routing. Load the matching section when its symptom fires.

## Network-isolation wedge (NotReady + SSH dead, kernel alive) — UFW-reload class

**Node NotReady + host SSH dead, but the node was NOT actually down (kernel alive) = firewall/network wedge, NOT a crash.** Tell them apart on the wedged boot (`--boot=-1`): if the kernel journaled normally right up to a *clean* systemd/ACPI shutdown, with ZERO panic/OOM/soft-lockup/NIC-link-down, it was network-isolated, not crashed. Prime suspect: a **node-maintenance drift-heal `ufw reload`** severing the k3s agent↔CP tunnel — grep the wedged boot for the trigger + confirm the node is back healthy now:

```bash
# on the wedged node (--boot=-1 = the boot before the power-cycle):
journalctl --boot=-1 -u k3s-agent --no-pager | grep -iE '127.0.0.1:6444.*(deadline|timeout|connection lost)|192.168.1.126.*6443.*i/o timeout'   # tunnel death
journalctl --boot=-1 --no-pager | grep -iE 'ansible-community.general.ufw|RELOAD_OK|node-maintenance.*192.168.1.127'                            # UFW reconfig trigger
journalctl --boot=-1 -k --no-pager | grep -iE 'UFW BLOCK.*DPT=8472'                                                                              # flannel VXLAN dropped mid-reload
# on the CP: did the drift-heal fail unreachable at the same second?
ssh_master_node 'journalctl -u node-maintenance-config.service --since "<window>" | grep -iE "NOPERMISSION|unreachable|Failed"'
```

Root cause + fix (repaired>0 gate) + the W2-only Realtek-NIC fragility: memory `gotcha_ufw_reload_node_isolation`. Self-heal for this class = the `node_isolation_heal` watchdog (active since 2026-07-23; `node_isolation_dry_run: false` in its role defaults); `clusterip_heal`/`ufw_heal` do NOT catch it (agent looks "not active" / UFW looks "active").

## CrashLoopBackOff — init-timing vs liveness race

**Symptom:** NEW ReplicaSet pod CrashLoops while OLD ReplicaSet pod stays healthy. Liveness probe `initialDelaySeconds` too short for app cold-start.

**Diagnose:**

```bash
POD=<crash-looping-pod>
NS=<namespace>

# Compare app's actual init duration vs liveness initialDelaySeconds
kubectl -n $NS logs $POD -c <main-container> --tail=100 | grep -iE 'init-complete|listening|ready|started'
kubectl -n $NS get pod $POD -o jsonpath='{.spec.containers[0].livenessProbe}{"\n"}'
kubectl -n $NS describe pod $POD | grep -E 'Liveness|Readiness|Startup|Killing'
```

If app `init-complete` log timestamp exceeds `initialDelaySeconds + (periodSeconds × failureThreshold)`, liveness kills the pod before it can serve.

**Fix:** add `startupProbe` with generous `failureThreshold` (NOT just bump liveness `initialDelaySeconds`):

```yaml
startupProbe:
  httpGet: { path: /, port: <port> }
  initialDelaySeconds: 30
  periodSeconds: 10
  failureThreshold: 30   # 300s budget
livenessProbe:
  httpGet: { path: /, port: <port> }
  periodSeconds: 10
  failureThreshold: 3
  # NO initialDelaySeconds — startupProbe gates this
```

Reference: paperless-ngx incident 2026-05-23 (init=98s, liveness initialDelaySeconds=60 → CrashLoop, OLD pod healthy). Commit `a36c8f31`.

**Probe-kill vs OOM tell:** before bumping memory, check the exit. `lastState.terminated.reason`:
```bash
kubectl -n $NS get pod $POD -o jsonpath='{range .status.containerStatuses[*]}{.name}{" exit="}{.lastState.terminated.exitCode}{" reason="}{.lastState.terminated.reason}{"\n"}{end}'
```
- `reason=OOMKilled` (exit 137 from oom) → real memory pressure, raise limits.
- `reason=Error`/exit 0/143 (SIGTERM) WITH clean app logs that show normal startup progress → probe killed a still-booting app. Widen `startupProbe`, do NOT raise memory.

**Cold boot is slower than steady-state.** After a node reboot, page cache is cold + disk/CPU contend with everything else restarting, so an app that boots in 60s steady-state can exceed a 90s probe budget. A probe `failureThreshold` tuned on a warm node may crashloop only post-reboot. Reference: stirling-pdf 2.11.0-fat post-reboot crashloop 2026-05-24 (clean logs, graceful exit, NOT OOM); `failureThreshold` 9→30 (90s→300s), commit `466b8fca`.

Common slow-start apps: Django+migrations, Rails+migrations, Spring Boot, Authentik server, Postgres bootstrap, Mongo replica sets.

## CoreDNS `--disable` deadlock

**coredns `--disable` deadlock:** ALL Flux reconciles stall with i/o timeout to `10.43.0.10` after the kube-dns Service/ConfigMap/RBAC are deleted — k3s `--disable=coredns` deletes addon-owned objects by owner-label, and Flux cannot recreate them because the source fetch itself needs DNS. Break-glass: `kubectl apply -k infrastructure/coredns/` from the homelab repo (one-time — the recreated objects are owner-label-free). Memory: `gotcha_coredns_disable_deadlock`.

## NetworkPolicy gap scripts — scope and false positives

`np-gap.sh` is namespace-level (a ns with ≥1 NP passes); `np-coverage.sh` is the per-pod complement — it catches a pod that no NP *selects* even though its ns has other NPs (the F-48 redis-operator class), and ORPHAN NPs whose selector matches zero pods (typo'd labels = silent no-op). hostNetwork pods are skipped (they bypass NP). Expected false-positives: an NP for a scaled-to-0 app or a CronJob (e.g. popeye) shows ORPHAN when no pod is running — verify before acting.

## Loki access traps

Three access traps make it read as "Loki has nothing":

- **`loki-0` has no `wget` and no `curl`** (distroless-ish image), and
  **`loki-gateway` refuses connections** from `monitoring` and `claude-telegram` — instant
  "Could not connect", not a timeout. A `… 2>/dev/null | jq` around either prints nothing,
  which reads as an empty result set. Same false-clean family as the vmsingle rule.
- **The grafana-pod exec recipe is DEAD** (verified 2026-09-11). That image now ships neither
  `sh` nor `curl`, so the exec fails `executable file not found in $PATH`. Every in-cluster
  client for this has now gone distroless; stop looking for a pod to exec into.
  If you exec into any pod picked by `-o jsonpath='{.items[0]…}'`, add
  `--field-selector=status.phase=Running` first. A reboot leaves terminal `Succeeded` pods and
  the selector returns one, so the exec fails `cannot exec into a container in a completed pod`
  (hit on 2026-08-08 for both grafana and vmalert).

## TTL+force re-run class

**TTL+force re-run class:** init Jobs with `ttlSecondsAfterFinished` + Flux `force` annotation re-run daily at a drift-creep hour. JobFailed on these usually = transient cluster issue AT the re-run hour, not job regression. Retrigger: `kubectl delete job <j> -n <ns> && flux reconcile kustomization apps` (init jobs are idempotent: HTTP 500 = already-initialized = exit 0). Reference: 2026-06-04 wn2 pod-DNS outage, memory `gotcha_worker_node2_flannel_dns`.

## Loki first — incidents

**Try Loki first — a Job that ran for seconds still ships its stdout.** The whole log of a Job
pod deleted 8h earlier came back in full on 2026-08-08. Metrics only say *that* it failed;
Loki says *why*.

**Do not narrow with `|= "<substring>"` on a first pass.** A Job prints its diagnosis on the
line *after* its headline, and a keyword filter drops it.
On 2026-09-11 `{namespace="immich"} |= "admin"` returned five `HTTP 400` lines and hid every
`{"message": "Admin setup is not available"}` line that named the cause.
