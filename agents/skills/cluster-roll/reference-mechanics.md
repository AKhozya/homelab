# cluster-roll — mechanics & incident detail

Loaded on demand from `cluster-roll/SKILL.md`. SKILL.md holds the always-needed roll order, SKIP set, flags, and a routing pointer to each section here. Load this file when one of those situations fires (stale-pod survival, authentik misbehaving post-roll, an orphan in `--dry-run`, a `--missing` priority gap).

## Why ordered, not blanket (2026-05-24 cascade)

Replaces the dangerous blanket `kubectl rollout restart -A` primitive that cascaded the cluster on 2026-05-24 (an incomplete map silently skipped workloads and restarted everything at once, taking DNS/edge down together).

The `--dry-run` enumerates **every** live deploy/sts/ds and asserts each maps to a tier or SKIP with a ZERO-orphan cross-check. Preflight runs the same check, so a live roll aborts on an orphan. Fix the map, then re-run.

## Flux-stale-pod → delete-pod fallback (Deployments only)

Baked into the script. On Flux-managed Deployments, `rollout restart`'s `restartedAt` annotation can be reverted by Flux drift-detection — the new RS is abandoned and **stale pod(s) survive** (same pod name+age after "rolled out"). With ≥2 replicas under a PDB the revert can land mid-roll, so only *some* pods cycle and the rest stay stale. The script captures the pre-roll pod UIDs and, after a "successful" rollout, checks whether **any** old UID survived into the after-set (set intersection via `comm -12`). If any survived (full- or partial-stale), it deletes **just those surviving stale pods by name** (Flux manages the *Deployment*, not pods → the RS recreates fresh and Flux doesn't fight it), then re-checks `rollout status`. The fallback is gated to `kind == deploy` only — the abandoned-RS rationale is Deployment-specific; DaemonSets (`ds/alloy`, `ds/loki-canary`) and StatefulSets have no RS and are trusted to `rollout status` alone, so a false "did not cycle" never deletes DS pods across all nodes at once.

## Authentik → pooler → DNS chain

Authentik depends on the PG pooler (tier 4) and DNS (tier 1). It's rolled in tier 3 *after* DNS is confirmed healthy, but its DB pooler is rerolled in tier 4 (clearing PgBouncer cached DNS). If authentik misbehaves post-roll, reroll the pooler (tier 4) then authentik again.

## Priority-class audit — `--missing` not just `--count` (F-30 2026-05-29)

`~/.agents/skills/_shared/audit-priority-class.sh` — pre/post roll, run BOTH `--count` (baseline drift) AND `--missing` (catches workloads silently kept at NULL priority — see F-30 2026-05-29 incident, 4 staging-overlay Jobs only caught by `--missing`, not by count). `--count` alone is insufficient.
