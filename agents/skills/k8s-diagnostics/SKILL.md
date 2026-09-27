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

**coredns `--disable` deadlock:** ALL Flux reconciles stall with i/o timeout to `10.43.0.10` after the kube-dns Service/ConfigMap/RBAC are deleted — k3s `--disable=coredns` deletes addon-owned objects by owner-label, and Flux cannot recreate them because the source fetch itself needs DNS. Break-glass: `kubectl apply -k infrastructure/coredns/` from the homelab repo (one-time — the recreated objects are owner-label-free). Memory: `gotcha_coredns_disable_deadlock`.

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
`np-gap.sh` is namespace-level (a ns with ≥1 NP passes); `np-coverage.sh` is the per-pod complement — it catches a pod that no NP *selects* even though its ns has other NPs (the F-48 redis-operator class), and ORPHAN NPs whose selector matches zero pods (typo'd labels = silent no-op). hostNetwork pods are skipped (they bypass NP). Expected false-positives: an NP for a scaled-to-0 app or a CronJob (e.g. popeye) shows ORPHAN when no pod is running — verify before acting.

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

**TTL+force re-run class:** init Jobs with `ttlSecondsAfterFinished` + Flux `force` annotation re-run daily at a drift-creep hour. JobFailed on these usually = transient cluster issue AT the re-run hour, not job regression. Retrigger: `kubectl delete job <j> -n <ns> && flux reconcile kustomization apps` (init jobs are idempotent: HTTP 500 = already-initialized = exit 0). Reference: 2026-06-04 wn2 pod-DNS outage, memory `gotcha_worker_node2_flannel_dns`.

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
