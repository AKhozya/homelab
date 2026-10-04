# cluster-roll — mechanics & incident detail

Loaded on demand from `cluster-roll/SKILL.md`. SKILL.md holds the always-needed roll order, SKIP set, flags, and a routing pointer to each section here. Load this file when one of those situations fires (stale-pod survival, authentik misbehaving post-roll, an orphan in `--dry-run`, a `--missing` priority gap).

## Why ordered, not blanket (2026-05-24 cascade)

Replaces the dangerous blanket `kubectl rollout restart -A` primitive that cascaded the cluster on 2026-05-24 (an incomplete map silently skipped workloads and restarted everything at once, taking DNS/edge down together).

The `--dry-run` enumerates **every** live deploy/sts/ds and asserts each maps to a tier or SKIP with a ZERO-orphan cross-check. Preflight runs the same check, so a live roll aborts on an orphan. Fix the map, then re-run.

## Flux-stale-pod fallback (Deployments only)

On Flux-managed Deployments, Flux drift detection can revert the `restartedAt` annotation that `rollout restart` writes. The Deployment controller then abandons the new RS, and **stale pod(s) survive** a "successful" rollout (same pod name and age). If the Deployment has ≥2 replicas under a PDB, the revert can happen during the rollout, so only *some* pods cycle.

The script captures the pre-roll pod UIDs. After the rollout it checks whether **any** old UID is still in the after-set (`comm -12`). If any is, it runs `_shared/restart-workload.sh` on the workload's selector:

| Property | Why it matters here |
|---|---|
| deletes one pod at a time and waits for the Ready count to return to baseline | if every replica survived, a loop of `delete pod` would take the workload fully down |
| refuses if a PDB covering the workload allows no disruption | a direct `delete pod` bypasses the PDB; only the Eviction API honours it |
| Flux manages the Deployment, not its pods | the RS recreates the deleted pods, and Flux does not revert the deletions |

The script then re-checks the UID intersection and exits with an error if any old pod still runs.

The script runs the fallback only for Deployments (`kind == deploy`). The abandoned-RS failure needs a ReplicaSet. DaemonSets (`ds/alloy`, `ds/loki-canary`) and StatefulSets have none, so the script trusts `rollout status` for them.

Test: `bash tests/test-roll-fallback.sh` (bash ≥4.3) stubs `kubectl` and `restart-workload.sh` and checks the four fallback cases.

## Authentik → pooler → DNS chain

Authentik depends on the PG pooler (tier 4) and DNS (tier 1). It's rolled in tier 3 *after* DNS is confirmed healthy, but its DB pooler is rerolled in tier 4 (clearing PgBouncer cached DNS). If authentik misbehaves post-roll, reroll the pooler (tier 4) then authentik again.

## Priority-class audit — `--missing` not just `--count` (F-30 2026-05-29)

`~/.agents/skills/_shared/audit-priority-class.sh` — pre/post roll, run BOTH `--count` (baseline drift) AND `--missing` (catches workloads silently kept at NULL priority — see F-30 2026-05-29 incident, 4 staging-overlay Jobs only caught by `--missing`, not by count). `--count` alone is insufficient.
