---
name: k8s-diagnostics
description: "Use when SOMETHING IS WRONG — unhealthy pods, CrashLoopBackOff, performance regressions, network/storage troubleshooting, or unexplained behavior. Symptom-driven. For post-deploy verification (clean-tree checks) use `/gitops-verify` instead. Sequenced checks — nodes, Flux, DBs (CNPG/Percona/CouchDB/Redis), top pods, NetworkPolicy gap-finder, VMAlert+Alertmanager. Also: vanished Job pod (no logs), node crash forensics (OOM/panic), alert cascade when an alert persists after a fix, StatefulSet pod that keeps crashing after its fix already reconciled."
---

# K8s Diagnostics Skill

## When to Use
- Cluster unhealthy or pods failing
- Performance issues
- Network/storage troubleshooting

## Diagnostic Sequence

**Fast path:** run the full sweep via script, then triage output by priority.

```bash
bash ~/.agents/skills/k8s-diagnostics/scripts/diagnose.sh
```

Per-section commands below are kept for targeted re-runs / debugging.

### 1. Cluster Health
```bash
# Node status
kubectl get nodes -o wide

# Pod status (shared script — Running/Succeeded filtered out)
bash ~/.agents/skills/_shared/pod-health.sh | head -30

# Recent events (warnings/errors)
kubectl get events -A --sort-by='.lastTimestamp' --field-selector type!=Normal | tail -20
```

### 2. Flux GitOps Status
```bash
bash ~/.agents/skills/_shared/flux-status.sh --all      # kustomizations + helmreleases
bash ~/.agents/skills/_shared/flux-status.sh --failed   # only non-Ready
```

If every Flux reconcile stalls with an i/o timeout to `10.43.0.10`, read reference-incidents.md § CoreDNS `--disable` deadlock.
Run its break-glass `kubectl apply -k infrastructure/coredns/` one time only: the recreated objects carry no owner label.

### 3. Database Clusters

#### PostgreSQL (CloudNativePG)
```bash
kubectl get cluster -n databases main-postgres -o jsonpath='{.status.phase}'
kubectl get pods -n databases -l cnpg.io/cluster=main-postgres -o wide
```

#### MySQL (Percona)
```bash
kubectl get ps -n databases main-mysql -o jsonpath='{.status.state}'
kubectl get pods -n databases -l app.kubernetes.io/instance=main-mysql -o wide
```

#### CouchDB
```bash
kubectl get pods -n databases -o wide | grep couchdb-
```

#### Redis
```bash
kubectl get pods -n databases -l redis_setup_type -o wide   # replication + sentinel pods
```

### 4. Resource Usage
```bash
# Node resources
kubectl top nodes

# Pod resources (top consumers)
kubectl top pods -A --sort-by=memory | head -15
kubectl top pods -A --sort-by=cpu | head -15
```

### 5. NetworkPolicy Issues
```bash
kubectl get networkpolicies -A                # full list
bash ~/.agents/skills/_shared/np-gap.sh       # ns-level: ns with pods but ZERO NP (exit 1 if gaps)
bash ~/.agents/skills/_shared/np-coverage.sh  # per-pod: pods no NP selects + orphan NPs (exit 1 if gaps)
```
Before you act on a gap, read reference-incidents.md § NetworkPolicy gap scripts for what each script catches and its expected false positives.
Verify each reported gap or ORPHAN against the live pods before you act: a scaled-to-0 app or an idle CronJob shows as ORPHAN.

### 5b. Node crash forensics (host-side)

When pods evicted, OOMKilled cluster-wide, or nodes went `NotReady` then back, run host-side probe via SSH (delegates to `/homelab-node-fix` for SSH workflow):

```bash
bash ~/.agents/skills/_shared/node-crash-probe.sh ssh_master_node
bash ~/.agents/skills/_shared/node-crash-probe.sh ssh_worker_node
bash ~/.agents/skills/_shared/node-crash-probe.sh ssh_worker_node2
bash ~/.agents/skills/_shared/node-crash-probe.sh immich-vm   # GPU VM — wedge history: memory gotcha_immich_vm_virtio_gpu_fbdev_wedge
```

Checks pstore (kernel panic blobs at `/sys/fs/pstore/`), `dmesg -T | grep -iE 'oom|panic|kill|hung|tainted'`, `journalctl --boot=-1 -p err`, uptime/load. Read-only — no sudo needed.

If pstore is non-empty: capture for analysis, then clear with `sudo rm -f /sys/fs/pstore/*` (give command to user, never run sudo directly).

**Tell:** node NotReady + SSH dead but the wedged boot's journal shows a *clean* shutdown with ZERO panic/OOM/soft-lockup = network-isolated (UFW-reload class), NOT crashed → load `reference-incidents.md` § Network-isolation wedge for the journalctl forensics + memory pointers.

### 5c. Cascade-check order — when alert persists after upstream fix

See `/monitoring-check` § "Alert won't clear — triage decision tree" for full sequence (VMAgent stuck → metric staleness → rule eval lag → revert).

### 5c-bis. JobFailed where the pod has VANISHED (no logs)

`restartPolicy: OnFailure` Job pods are **deleted by the job controller at backoffLimit** → `kubectl logs` gone. Alloy/Loki also **misses fast-crashloop pods** (06-04 audiobookshelf-init: 0 Loki streams on failure day, full streams every prior success day — log absence ≠ never-ran). VictoriaMetrics keeps the truth:

```bash
# Forensics via kube-state metrics at the failure window (port-forward vmsingle :8429)
# exit code: curl 6 = DNS resolve fail, 7 = connect refused
kube_pod_container_status_last_terminated_exitcode{pod=~"<job>.*"}
kube_pod_container_status_waiting_reason{pod=~"<job>.*"}     # CrashLoopBackOff vs ImagePullBackOff vs ConfigError
kube_pod_info{pod="<failed-pod>"}                            # -> node
```

**Try Loki first — a Job that ran for seconds still ships its stdout.** The whole log of a Job
pod deleted 8h earlier came back in full on 2026-08-08. Metrics only say *that* it failed;
Loki says *why*. Three access traps make it read as "Loki has nothing":

Do not look for a pod to exec into for Loki: every in-cluster client image is distroless now. Use the workstation port-forward below.
If a Loki query returns nothing, read reference-incidents.md § Loki access traps.

The path that works is a **port-forward from the workstation**. It ignores NetworkPolicy and
needs no credentials, so it survives image changes:

```bash
kubectl port-forward -n loki svc/loki 3100:3100 &   # run_in_background in Claude Code
```

Then fetch `http://localhost:3100/loki/api/v1/query_range` with `query`, `start`, `limit` and
`direction=forward`. Claude Code's context-mode hook rewrites any Bash command containing
`curl`/`wget`, so issue the request from `ctx_execute` rather than fighting the hook.

Nanosecond timestamps, not seconds.

**Do not narrow with `|= "<substring>"` on a first pass.** A Job prints its diagnosis on the
line *after* its headline, and a keyword filter drops it. On 2026-09-11
`{namespace="immich"} |= "admin"` returned five `HTTP 400` lines and hid every
`{"message": "Admin setup is not available"}` line that named the cause. Select the stream by
`pod=` and read it whole.

Cross-check siblings: other pods restarting same window **same node** = node-local (check `increase(node_network_transmit_drop_total{device="flannel.1"}[1h])` per instance — vxlan path); same window other nodes = cluster-wide.

If the failed Job is an init Job with `ttlSecondsAfterFinished` and a Flux `force` annotation, read reference-incidents.md § TTL+force re-run class.

If you exec into a pod picked by `.items[0]`, add `--field-selector=status.phase=Running` first. A reboot leaves terminal `Succeeded` pods that `.items[0]` can select.

### 5d. CrashLoopBackOff — init-timing vs liveness race

**Tell:** NEW ReplicaSet pod CrashLoops while OLD ReplicaSet pod stays healthy = liveness probe kills a still-booting app (`initialDelaySeconds` too short for cold-start). Check `lastState.terminated.reason` first — `OOMKilled` = raise limits; `Error`/exit 0/143 with clean startup logs = probe-kill, widen `startupProbe`, do NOT raise memory. Full diagnose commands, startupProbe fix shape, cold-boot caveat + incident SHAs: load `reference-incidents.md` § CrashLoopBackOff init-timing.

### 5e. CrashLoopBackOff that survives its own fix (StatefulSet only)

**Tell:** pod age far exceeds the fix commit, RESTARTS climbing in place, `sts.spec` already holds the fix. An unhealthy StatefulSet pod halts the rollout and is never recreated, so a Flux-applied fix reconciles green while the pod keeps crashing on the old template. Compare pod `controller-revision-hash` to `sts.status.updateRevision`; mismatch = stuck, `kubectl delete pod <name>-0` to force it. Commands + upstream refs: `/gitops-workflow` § 5 Verify.

### 6. Firing Alerts (VMAlert + Alertmanager dual)
Always check both. See `/monitoring-check` for stack details.
```bash
bash ~/.agents/skills/_shared/check-alerts.sh           # VMALERT|... AM|... lines
bash ~/.agents/skills/_shared/check-alerts.sh --json    # structured for processing
```

## Tools Allowed
- `Bash(kubectl *)`
- `Bash(flux *)`
- `Read`
- `Grep`

## Output Format
Report by priority:
1. **Critical**: CrashLoopBackOff, node NotReady
2. **Warning**: Resource pressure, pending pods, failed reconciliations
3. **Info**: Normal operations
