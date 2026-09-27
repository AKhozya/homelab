---
name: cnpg-full-roll
description: Full-cluster CNPG (CloudNativePG) instance rolling restart for spec-changes that the operator doesn't treat as a rolling-update trigger (e.g., priorityClassName on v1.29.x). Use when "CNPG pods didn't pick up spec change", "homelab-critical not on Postgres instances after edit", or after editing Cluster.spec for fields the operator-versioned reconciler skips.
user-invocable: false
---

# CNPG full-cluster rolling restart

## Fast path

```bash
bash ~/.agents/skills/cnpg-full-roll/scripts/roll.sh <ns> <cluster>
```

Example:
```bash
bash ~/.agents/skills/cnpg-full-roll/scripts/roll.sh databases main-postgres
```

## What it does (the dance)

1. Snapshot current primary + replica pod names.
2. `kubectl cnpg restart` → operator rolls the **replica only** (cluster stays healthy in between).
3. Poll until the replica's `creationTimestamp` is newer than step-1 snapshot.
4. `kubectl cnpg promote <new-replica>` → switchover, old primary becomes replica.
5. `kubectl cnpg restart` again → roll the just-demoted replica.
6. Poll until both instances have `creationTimestamp` newer than start.
7. Confirm cluster `readyInstances == instances` and primary is the promoted pod.

## Why this exists

CNPG v1.29.x does **not** consider `Cluster.spec.priorityClassName` (and certain other soft spec fields) a rolling-update trigger. A spec edit lands in the CR but instance pods stay on the old spec until a manual restart. Both `cnpg restart` (replica-only) and a promote+restart (primary) are needed for a full roll. This script wraps the 4-step dance into one call.

See `[[gotchas]]` "CNPG v1.29.x: priorityClassName change is NOT a rolling-update trigger" for context.

## Caveats

- Switchover is **brief downtime on writes** for the moment the primary is demoted. CNPG handles connection redirect via Pooler/service.
- If `kubectl cnpg promote` fails (e.g., no eligible replica), the script aborts; you're left with replica rolled, primary on old spec. Investigate then re-run.
- Script does NOT touch the Pooler CR — Pooler pods are managed by the operator's `deploymentStrategy: RollingUpdate` and apply spec changes on Flux reconcile.

## See also

- `/db-primary-pin` — move primary to a specific node (uses `cnpg promote` once, no restart dance).
- `/db-operations` — connection patterns + admin queries.
