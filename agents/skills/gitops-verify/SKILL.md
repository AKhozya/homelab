---
name: gitops-verify
description: Use ONLY for post-deploy verification after pushing infra changes, after Flux reconciliation, or before/after maintenance windows. NOT for symptom-driven diagnosis — use `/k8s-diagnostics` for that. Runs structured checks (git, dry-run, Flux, pods, events, VMAlert+Alertmanager, Kyverno, priority-class audit) and outputs PASS/FAIL/WARN/SKIP report.
---

# /gitops-verify

## When to Activate
- After pushing infra changes
- After Flux reconciliation
- Health check before/after maintenance

## Instructions

**Fast path (preferred):** run all checks via script, then format the table from JSON.

```bash
bash ~/.agents/skills/gitops-verify/scripts/run-checks.sh          # JSON
bash ~/.agents/skills/gitops-verify/scripts/run-checks.sh --text   # human summary
```

Then map each field to PASS/FAIL/WARN/SKIP:
- `git.dirty_files == 0` → PASS, else WARN
- `yaml.fail == 0` → PASS; `yaml.skipped == 1` → SKIP; else FAIL
- `flux` shows `failed=0` → PASS
- `pods` shows `unhealthy=0` → PASS
- `events_warn_recent == 0` → PASS, else WARN (judgment: any actionable?)
- `alerts` shows `vmalert=0 alertmanager=0` → PASS
- `kyverno_violations == 0` → PASS

Per-check raw blocks below are kept as fallback / debugging reference.

### Check 1: Git Status
```bash
git -C ~/source-code/homelab status --porcelain
```
- **[PASS]** empty (clean tree)
- **[WARN]** uncommitted changes

### Check 2: YAML Dry-Run
```bash
# Pick recently changed YAML files
git -C ~/source-code/homelab diff --name-only HEAD~1 -- '*.yaml' | head -5
```
For each K8s manifest:
```bash
kubectl apply -f <file> --dry-run=server 2>&1
```
- **[PASS]** all succeed
- **[FAIL]** any fail
- **[SKIP]** no YAML changed

### Check 3: Flux Reconciliation
```bash
bash ~/.agents/skills/_shared/flux-status.sh --failed   # empty = PASS
bash ~/.agents/skills/_shared/flux-status.sh --count    # ready/total summary
```
- **[PASS]** all `Ready True` (empty --failed output)
- **[FAIL]** any `Ready False` or suspended

### Check 4: Pod Health
```bash
bash ~/.agents/skills/_shared/pod-health.sh --count   # quick summary
bash ~/.agents/skills/_shared/pod-health.sh           # detail if unhealthy>0
```
- **[PASS]** unhealthy=0
- **[FAIL]** CrashLoopBackOff, Error, or Pending

### Check 5: Warning Events (Last 5 Min)
```bash
kubectl get events -A --field-selector=type=Warning --sort-by='.lastTimestamp' 2>&1 | tail -10
```
- **[PASS]** none in last 5 min
- **[WARN]** warnings exist (show them)

### Check 6: Firing Alerts (VMAlert + Alertmanager dual)
Always check BOTH (gotcha: VMAlert-only missed broken AM Telegram template). See `/monitoring-check` for VictoriaMetrics stack details.
```bash
bash ~/.agents/skills/_shared/check-alerts.sh --count   # vmalert=N alertmanager=M
bash ~/.agents/skills/_shared/check-alerts.sh           # detail if any non-zero
```
- **[PASS]** both counts 0
- **[FAIL]** alerts firing on either (list them)

### Check 7: Kyverno Violations
```bash
bash ~/.agents/skills/_shared/check-kyverno.sh --count   # violations=N policies=M
bash ~/.agents/skills/_shared/check-kyverno.sh           # per-policy detail
```
- **[PASS]** `violations=0`
- **[WARN]** known acceptable (stale null namespace reports)
- **[FAIL]** new actionable violations

### Output Format

```
## GitOps Verification Report

| # | Check | Status | Details |
|---|-------|--------|---------|
| 1 | Git Status | [PASS] | Clean working tree |
| 2 | YAML Dry-Run | [PASS] | 3/3 files valid |
| 3 | Flux Reconciliation | [PASS] | 6/6 kustomizations ready |
| 4 | Pod Health | [PASS] | 81 running, 0 unhealthy |
| 5 | Warning Events | [WARN] | 2 events in last 5 min |
| 6 | Firing Alerts | [PASS] | No alerts firing |
| 7 | Kyverno Violations | [PASS] | 0 violations |

**Overall: PASS** (7/7 checks passed)
```

Use PASS/FAIL/WARN/SKIP. Show details for non-PASS.

## Optional add-on check

Run BOTH after any priorityClassName-touching commit:
```bash
bash ~/.agents/skills/_shared/audit-priority-class.sh --count    # baseline comparison
bash ~/.agents/skills/_shared/audit-priority-class.sh --missing   # MUST be empty for "fully closed" claim
```
- `--count` catches regression: `homelab-critical` should stay ≥ baseline.
- `--missing` is the only honest signal: lists Running pods at NULL priority. **`--count` alone misses workloads silently kept at NULL** (e.g. F-30 2026-05-29 — 4 setup Jobs were missed by the file-map investigator and only caught by `--missing` post-deploy). Always run `--missing` before declaring a tier-injection task done.
- Chart support gotcha (F-30 lesson): before editing a HelmRelease's `values.priorityClassName`, probe upstream chart's `values.yaml` + `templates/deployment.yaml`. If no template hook (cnpg 0.28.2 OK, ps-operator 1.1.0 / cert-mgr 1.20.2 / alloy 1.8.2 / vm-op 0.63.1 NO), use `postRenderers` JSON6902 instead — see `~/.agents/skills/_shared/REFERENCE-postrenderer-priorityclass.md`.
