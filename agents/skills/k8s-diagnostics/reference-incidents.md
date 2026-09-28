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
