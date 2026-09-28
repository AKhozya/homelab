---
name: cluster-stale-cleanup
description: Use to find and clean stale K8s resources in homelab — failed/evicted pods, completed Jobs lacking ttlSecondsAfterFinished, zero-replica ReplicaSets beyond revisionHistoryLimit, unbound PVCs, released PVs, stuck Helm releases, orphan ConfigMaps. Outputs scan table + GitOps cleanup recommendations. NEVER raw `kubectl delete` for git-managed objects — patches manifests (ttlSecondsAfterFinished, revisionHistoryLimit) then commits via /gitops-workflow. Released PVs need cleanup outside GitOps. Fix stuck Helm releases in Git.
---

# Cluster Stale Cleanup

Sweep for stale resources. Propose GitOps fixes. Refuse out-of-band kubectl delete on Flux-managed objects.

## Scan

```bash
bash ~/.agents/skills/cluster-stale-cleanup/scripts/scan.sh
```

Categories surfaced:

| Category | Threshold | Fix path |
|---|---|---|
| Failed/evicted pods | any | root cause first (see "Evicted = node pressure" below); delete corpses only AFTER pressure clears, else they re-evict |
| Controller-owned terminal pods | any | reboot leftovers — see "Reboot leftovers" below |
| Jobs without TTL | non-CronJob standalone | patch `ttlSecondsAfterFinished: 86400` in manifest → /gitops-workflow |
| Zero-replica RS | count > 5 per Deployment | patch `revisionHistoryLimit: 2` in Deployment spec (the repo convention, `.claude/review-invariants.md`) |
| Unbound PVCs | any | check StorageClass, PV provisioning errors |
| Released/Failed PVs | any | out-of-band `kubectl delete pv` after backup verify |
| Stuck Helm | failed / pending-upgrade | read `helm history` and `flux get hr -A` for the cause, then fix the values or chart version in Git → /gitops-workflow. The HelmRelease's own `remediation` settings handle rollback; never run `helm rollback` by hand (an out-of-band prod change Flux does not know about) |
| Orphan ConfigMaps | not owned (top-5 oldest shown, any age) | manual audit, often residue from renamed deploys |

## Reboot leftovers = terminal pods no controller reaps

A graceful node shutdown puts every evicted pod into a terminal phase. The ReplicaSet
controller ignores terminal pods it owns. The pod-GC controller acts only past
`--terminated-pod-gc-threshold`, default **12500**, which a homelab never reaches. They keep
`DeploymentReplicasMismatch` / `PodRunningNotReady` / `PodPhaseNotRunning` firing.

| Reboot | Leftover pods | Alerts |
|---|---|---|
| 2026-08-01 | 14 | 4 (2 critical) |
| 2026-08-08 | 11 (10 `Succeeded`, 1 `Failed`) | 1 |

**Most are `Succeeded`, not `Failed`** — a container that handles SIGTERM exits 0. The
`Failed/evicted pods` row above uses `--field-selector=status.phase=Failed` and sees almost
none of them, which is why they get their own row.

Delete by name **and phase**, never by name alone. StatefulSet names are stable. If anything
removes a terminal `sts-0` between the listing and the delete, the controller recreates a
**Running** `sts-0` under the same name, and a delete by name alone takes the live pod:

```bash
kubectl -n <ns> delete pod --field-selector="metadata.name=<name>,status.phase=<phase>"
```

`phase2` PLAY 2 sweeps these after every orchestrated reboot since 2026-08-08 — owner-scoped,
cluster-wide, `Failed` + `Succeeded`. If the count is non-zero outside a maintenance window,
that sweep did not run: check whether phase2 reached PLAY 2 before deleting by hand.
Job-owned pods stay, because that history belongs to the CronJob and
`ttlSecondsAfterFinished` clears it. Pods with no controller stay too — an operator is
investigating those.

## Evicted pods = node pressure (not stale corpses)

`status.reason=Evicted` (DiskPressure / ephemeral-storage / MemoryPressure) means the **node** crossed a kubelet eviction threshold — the corpses are downstream. Deleting them while pressure persists just spawns replacements that re-evict.

1. Find the node + condition: `kubectl get pods -A --field-selector=status.phase=Failed -o wide`; `kubectl get node <n> -o jsonpath` DiskPressure/MemoryPressure status.
2. **Trust kubelet, not `df /`.** kubelet's nodefs may be a different mount than root or the k3s data-dir. Get its real view: `kubectl get --raw /api/v1/nodes/<n>/proxy/stats/summary | jq '{nodefs:.node.fs, imagefs:.node.runtime.imageFs}'` — match `capacityBytes`/inodes to a mount via `sudo du`/`df` on the node.
3. Free space at the source (node-side, sudo). DiskPressure flips False only after kubelet's `eviction-pressure-transition-period` (~5min) above threshold.
4. THEN delete the Failed corpses (one-time, won't recur). Failed-phase pods are runtime artifacts, not declarative state → `kubectl delete pod` is GitOps-safe (controllers already rescheduled).

Homelab case: worker-node-2 nodefs = `/mnt/extra-storage` (NOT the k3s data-dir) — historically pressured by the rebuilderd build cache (rebuilderd removed 2026-07; see `gotcha_worker_node2_diskpressure`). Node-side fix → `/homelab-node-fix`.

## GitOps Cleanup Sequence

1. Run scan → capture stale category counts.
2. For each fixable category, locate manifest under `apps/` or `infrastructure/`.
3. Patch via Edit tool (not `kubectl patch`).
4. Validate with `homelab-yaml-validate` skill.
5. Commit + push + `flux reconcile` (use `gitops-workflow` skill).
6. Re-scan to confirm cleanup.

## Hard rules

- Job spec is mostly immutable. `ttlSecondsAfterFinished` IS mutable — SSA patch works for existing Jobs (TTL controller backdates from `completionTime`).
- Flux `kustomize.toolkit.fluxcd.io/force: enabled` annotation makes Flux delete+recreate on conflict — used on init Jobs.
- Never `kubectl delete job` on Flux-managed Jobs without removing from git — Flux will recreate.
- Released PVs are post-PVC-deletion cleanup, safe to delete directly.

## Cross-refs

- `gitops-workflow` — commit + Flux reconcile sequence
- `gitops-verify` — post-cleanup verification
- `homelab-yaml-validate` — manifest schema check before commit
- `k8s-diagnostics` — root cause for failed pods (not cleanup target)
