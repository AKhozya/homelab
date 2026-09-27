# Resource Sizing — diagnosis / tuning / namespace-quota recipes

Loaded on demand from `resource-sizing/SKILL.md`. SKILL.md holds the standard pod tiers + golden rule + pitfalls; load this when diagnosing OOMKilled/throttle, running the tune-down workflow, or sizing a namespace ResourceQuota.

## Diagnosis

### Current Usage
```bash
# Single pod
kubectl top pod <pod> -n <namespace>

# All pods in namespace
kubectl top pods -n <namespace>

# Top memory consumers cluster-wide
kubectl top pods -A --sort-by=memory | head -20
```

### OOMKilled
```bash
# Recent OOM events
kubectl get events -A --field-selector reason=OOMKilled

# Pod restart count (high = likely OOM)
kubectl get pods -n <namespace> -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount
```

### CPU Throttling
Pod-aggregate throttle rate sorted desc (queries VMSingle):
```bash
bash ~/.agents/skills/resource-sizing/scripts/cpu-throttling.sh                # all ns
bash ~/.agents/skills/resource-sizing/scripts/cpu-throttling.sh -n <ns>        # one ns
bash ~/.agents/skills/resource-sizing/scripts/cpu-throttling.sh -n <ns> -p <pod>
```

## Tuning Workflow

### 1. Deploy with generous limits (Medium tier min)
### 2. Monitor 24-48h
```bash
# Quick check
kubectl top pod <pod> -n <namespace>

# Historical (via Grafana or Prometheus)
# Look at max(container_memory_working_set_bytes) over 24h
```

### 3. Calculate
```
New Request = max(observed) × 1.2  (20% buffer)
New Limit = max(observed) × 1.5    (50% buffer)
```
Use the helper script (ceil + format):
```bash
bash ~/.agents/skills/resource-sizing/scripts/calc.sh 512      # → request=615Mi limit=768Mi
bash ~/.agents/skills/resource-sizing/scripts/calc.sh 250 m    # → request=300m limit=375m
```

### 4. Apply + Verify
```bash
# After editing deployment
kubectl rollout status deploy/<name> -n <namespace>

# Verify new limits applied
kubectl describe pod <pod> -n <namespace> | grep -A5 "Limits:"
```

## Raising a Limit

Run this before editing the manifest. It exits non-zero if the new pod would not be admitted:

```bash
bash ~/.agents/skills/_shared/preflight-limit-change.sh <ns> <deploy> <new-mem> [container]
bash ~/.agents/skills/_shared/preflight-limit-change.sh claude-telegram claude-telegram 5Gi
```

It prints the pod total before and after, the deployment strategy, the LimitRange ceilings and the
quota headroom. **Exit 2 means it could not establish an answer** — a quota it was not allowed to
list, a quantity it cannot parse, a container with no effective limit — and is never a pass.

Three facts it exists to enforce, all of them learned from a 15-minute
claude-telegram outage on 2026-08-02 (3Gi → 5Gi against a 4Gi namespace quota):

- **The quota charges the whole pod**, `max(sum(containers), max(initContainers))` — 5Gi main plus a
  128Mi sidecar asks for 5248Mi, not 5Gi. Editing one container's limit moves the pod total.
- **`strategy: Recreate` deletes the old pod first.** A rejection that would merely stall a
  RollingUpdate instead leaves zero pods. Check the strategy before changing anything that can block
  admission: quota, LimitRange, node capacity, PodSecurity, a nonexistent image tag.
- **Fixing the cause does not retry.** The failed ReplicaSet has backed off and blown its progress
  deadline. From a workstation `kubectl -n <ns> rollout restart deploy/<name>` creates a fresh one;
  the bot has no workload `patch` since 2026-08-06 and there is no pod to delete here, so its
  equivalent is `kubectl -n <ns> delete rs <failed-rs>` — the Deployment then creates a new one. The tell is a
  `ReplicaFailure` condition quoting numbers that no longer match the live objects — the condition is
  a stale snapshot, not a live check, so events keep naming the old quota after you have raised it.

Raise the quota and the pod limit in the same commit.

## Namespace ResourceQuota Tiers

Inspect current quota: `bash ~/.agents/skills/_shared/quota.sh <namespace>` (shared with `/ha-enablement`).

Tier values live in `infrastructure/configs/resource-governance/<small|medium|large>-tier/` — read the
actual per-ns quota files there, don't copy numbers from here (previous hardcoded blocks drifted:
small was listed 1cpu/1Gi req while repo has 2cpu/4Gi + pods/services/PVC hard counts).
NOTE: these **namespace-quota** tiers are a different taxonomy from SKILL.md's **pod-level** S/M/L
sizing tiers, despite sharing names — a ns can sit in governance small-tier while its app is
pod-tier Medium (mealie does).
