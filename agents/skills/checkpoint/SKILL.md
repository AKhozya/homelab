---
name: checkpoint
description: Use to capture or verify homelab infra state snapshots before/after major changes (upgrades, migrations, hardening). Sub-commands create/verify/list compare git SHA, nodes, pods, Flux, alerts, DBs.
---

# /checkpoint

## When to Activate
- Before major changes (upgrades, migrations, hardening)
- After maintenance to record new baseline
- Comparing state before/after operation

## Sub-commands

### `/checkpoint create <name>`

Capture current state → `~/.claude/sessions/checkpoint-<name>.md` via script:

```bash
bash ~/.agents/skills/checkpoint/scripts/collect.sh <name>
```

The script collects (deterministic, identical fields every run):
1. **Git SHA** from `~/source-code/homelab`
2. **Node Status** (`kubectl get nodes -o wide`)
3. **Pod counts** (total/running/unhealthy via `_shared/pod-health.sh`)
4. **Flux** (ready/total/failed via `_shared/flux-status.sh` + detail)
5. **Alerts** (vmalert + alertmanager via `_shared/check-alerts.sh`)
6. **Databases** (PG ready/instances, MySQL state, CouchDB/Redis pod counts)
7. **UTC timestamp**

Output file format (auto-generated — one-line `key=value` summaries from the `_shared` scripts' `--count` mode plus fenced detail blocks; a `?` sentinel appears in any token whose fetch failed, e.g. `total=? running=? unhealthy=? stale=?` or `?/?`):

````markdown
# Checkpoint: <name>
**Created**: <UTC timestamp>
**Git SHA**: <short sha>

## Nodes
```
<kubectl get nodes -o wide output>
```

## Pods
total=N running=N unhealthy=N stale=N

## Flux Kustomizations
ready=N total=N failed=N reconciling=N

```
<flux-status.sh detail>
```

## Alerts
vmalert=N alertmanager=N

```
<check-alerts.sh detail>
```

## Databases
- PostgreSQL: <readyInstances>/<instances>
- MySQL: <state word, e.g. ready>
- CouchDB pods: N
- Redis pods: N
````

### `/checkpoint verify <name>`

Diff current state vs saved checkpoint via script:

```bash
bash ~/.agents/skills/checkpoint/scripts/verify.sh <name>
```

Emits one line per key (pipe-delimited):
`GIT_SHA|<saved>|<current>|<OK|CHANGED|DEGRADED>`
`PODS|<saved>|<current>|<OK|CHANGED|DEGRADED>`  (DEGRADED if unhealthy grew)
`FLUX|<saved>|<current>|<OK|CHANGED|DEGRADED>`  (DEGRADED if failed grew)
`ALERTS|<saved>|<current>|<OK|CHANGED|DEGRADED>` (DEGRADED if either count grew)

Format into a table + verdict. Example:
```
## Checkpoint Verification: <name>

| Component | Checkpoint | Current | Status |
|-----------|-----------|---------|--------|
| Git SHA | abc1234 | def5678 | CHANGED |
| Pods | total=83 unhealthy=0 | total=85 unhealthy=0 | CHANGED (+2) |
| Flux | 6/6 Ready | 6/6 Ready | OK |
| Alerts | vmalert=0 alertmanager=0 | vmalert=0 alertmanager=0 | OK |

**Verdict**: STABLE (no regressions)
```

Rows = exactly what `verify.sh` emits (`GIT_SHA|PODS|FLUX|ALERTS`). Nodes/DB rows are manual
kubectl adds if the change warrants them — the script doesn't produce them.

Status: OK/CHANGED/DEGRADED. DEGRADED = something got worse.

### `/checkpoint list`
```bash
ls -la ~/.claude/sessions/checkpoint-*.md 2>/dev/null
```
Show name, date, git SHA for each.

## Notes
- Use `|| true` on fragile kubectl/flux commands
- Files persist in `~/.claude/sessions/`
- Keep names short (e.g., `pre-upgrade`, `post-security`, `feb-review`)
