---
name: kyverno-policy-promotion
description: Use when authoring a new Kyverno CEL ValidatingPolicy (policies.kyverno.io/v1) or promoting one from Audit to Deny (validationActions flip). Drives the Audit→scan→fix-forward→Deny workflow: read-only PolicyReport scanner, live-action checker, local Audit→Deny flip with validation. Pairs with /gitops-workflow for commit + push + reconcile.
user-invocable: false
---

# Kyverno Policy Promotion

> **CP→VP migration COMPLETE 2026-07-12.** The cluster runs 12 CEL `ValidatingPolicy`
> resources (`policies.kyverno.io/v1`, short name `vpol`) as the sole policy engine —
> zero `kyverno.io/v1` ClusterPolicies remain and none may be authored (kind removed
> in Kyverno 1.20). Authoring rules: `.claude/review-invariants.md` § Kyverno
> ValidatingPolicy (CanAutoGen silent-kill, request.namespace, orValue soft-anchor,
> autogen-rewrite classes). Promotion = `validationActions: [Audit]`→`[Deny]`.

## Core rules — apply on every promotion

1. **Never ship Deny on day one.** Audit-first surfaces latent violations that would crash admission. (Wave 1 F-3 surfaced 5 latent init-container gaps that fix-forward addressed before flip — see `reference-wave-notes.md` § Reference incident.)
2. **Operator-managed workloads = label-based `matchConditions` exclude, never name-based.** Pods from CNPG, VM operator, Percona, Kyverno itself get hash-suffix names that rotate. Exclude via CEL on labels: `cnpg.io/podRole`, `managed-by: vm-operator`, `app.kubernetes.io/managed-by: cloudnative-pg`, etc.
3. **Autogen propagates Pod-level CEL to controllers — but REWRITES `object.metadata` to the pod-TEMPLATE metadata in the clones.** That's desired for label checks; it silently VOIDS any top-level-metadata check (`deletionTimestamp`, ownerReferences) — the clone reads `object.spec.template.metadata.deletionTimestamp`, which never exists (live-verified 2026-07-12, Codex catch). Default: pod-only match + autogen on. Policy needs a top-level-metadata condition (require-X-present class)? Match Pods AND controller kinds directly + `autogen.podControllers.controllers: []` — `require-networkpolicy-vp` is the template.
4. **A pod-label exclude does NOT cover a Job** — autogen evaluates the controller resource and Jobs carry only Flux labels at metadata level → Deny blocks Job recreation while pods look clean. Fixes + tell-tale + repro: `reference-wave-notes.md` § "A pod-label exclude does NOT cover a Job".
5. **Action lives at `spec.validationActions`** (list; `[Audit]` or `[Deny]` here — one line, flow style, so `prepare-enforce.sh` can flip it). CP-era per-rule `validate.failureAction` is history (kind deleted 2026-07-12).

## The workflow

### Phase 0 — Author the policy (CEL ValidatingPolicy)

- Kind: `policies.kyverno.io/v1` `ValidatingPolicy`. Copy the shape of an existing `-vp.yaml` in `infrastructure/configs/kyverno-policies/` — don't hand-roll.
- Match: `matchConstraints.resourceRules` on `pods` only; autogen covers controllers (default: deployments/statefulsets/daemonsets/jobs/cronjobs/replicasets/replicationcontrollers). EXCEPTION: top-level-metadata conditions → direct controller match, autogen off (Rule 3).
- `validationActions: [Audit]` (NOT Deny — yet; Rule 1). Flow style, one line (Rule 5).
- Background scanning is DEFAULT-ON for VPs (live polr rows proved it through the 07-04→07-12 parity soak) — the homelab VP files carry no `evaluation.background` block; don't add one.
- **Authoring a "require X present" policy (require-networkpolicy-style)? Scope `operations: [CREATE, UPDATE]` AND add a matchCondition `!has(object.metadata.deletionTimestamp)`** — otherwise a missing-X deny blocks DELETE of a namespace's own workloads once X is pruned → the ns wedges in `Terminating` forever. A delete never needs X present. BUT: that deletionTimestamp condition dies inside autogen clones (Rule 3) → this policy class needs the direct-controller-match pattern. (2026-07-03 csp-reporter ns wedge + 2026-07-12 autogen-rewrite catch; review-invariants § Kyverno.)
- Exclusions = CEL `matchConditions` on labels/namespaces (NOT CP-era `exclude.any` selectors — those don't exist in VP). Common operator labels:
  - CNPG: `cnpg.io/podRole: pooler` or `app.kubernetes.io/managed-by: cloudnative-pg`
  - VM operator: `managed-by: vm-operator`
  - Percona: `app.kubernetes.io/managed-by: percona-server-mysql-operator`
- **Run every CEL expression through the CanAutoGen check + orValue rules in `.claude/review-invariants.md` § Kyverno ValidatingPolicy** — an unsupported construct silently kills autogen for the whole policy (no error, controllers just stop being checked).
- File path: `infrastructure/configs/kyverno-policies/<name>-vp.yaml`. Register in `kustomization.yaml` resources list.

### Phase 1 — Ship Audit + reconcile

Use `/gitops-workflow` to validate, commit, push, reconcile.

```bash
# Pre-push validation
bash ~/.agents/skills/homelab-yaml-validate/scripts/validate.sh \
  "$(git rev-parse --show-toplevel)"/infrastructure/configs/kyverno-policies/<name>-vp.yaml

# Commit + push (per gitops-workflow pre-commit peer review loop)
```

After Flux reconciles (`kubectl get vpol <name>` shows READY True), confirm:

```bash
bash ~/.agents/skills/kyverno-policy-promotion/scripts/check-policy-action.sh <name>
# Expected: Audit
```

### Phase 2 — Scan for violations (wait ≥24h for `background: true` to evaluate all pods)

```bash
# Cluster-wide scan
bash ~/.agents/skills/kyverno-policy-promotion/scripts/scan-violations.sh

# Filter to one policy
bash ~/.agents/skills/kyverno-policy-promotion/scripts/scan-violations.sh --policy <name>

# JSON output (for processing)
bash ~/.agents/skills/kyverno-policy-promotion/scripts/scan-violations.sh --policy <name> --json
```

Exit 0 = clean; exit 1 = violations present (and listed).

**Reports lag policy changes — beware false-clean (W8).** After an exclude/fix, per-pod reports stay stale on the `backgroundScanInterval` (~1h) and a soak-start baseline undercounts. After ANY fix/exclude, gate with `--force-regen`. A freshness guard exits **3** on `0 fail AND 0 pass` (reports absent = false-clean). Mechanism + detail: `reference-wave-notes.md` § "Reports lag policy changes".

```bash
scan-violations.sh --policy <name> --force-regen   # trustworthy gate after a fix/exclude
```

**PolicyViolation EVENTS also outlive a fix (~1h TTL) — popeye POP-1503 reads them, false-dirtying its score; and `--force-regen` shows a LOW partial pass total right after report deletion.** Purge/wait rules + numbers: `reference-wave-notes.md` § "PolicyViolation events outlive a fix".

**Seccomp: cross-check LIVE pods via `scripts/seccomp-violators.sh`** (instant, bypasses report lag) — but it is point-in-time; a durable gap lives in the CronJob/Job pod template, check that too. Why + case: `reference-wave-notes.md` § "Seccomp live-pod cross-check".

### Phase 3 — Classify + fix-forward

For each violation row:

- **In-repo workload** (e.g. your app `Deployment` under `apps/<app>/`): EDIT the workload to satisfy the policy. Don't add it to the exclude list unless there's an upstream reason (s6-overlay /run perms, GPU hardware, etc.).
- **Operator-managed workload** (CNPG pooler, VMAgent, Percona, CNPG operator itself, Kyverno admission-controller): the spec is generated by an upstream controller you don't control. Add a label-selector exclude block. Verify the label exists with `kubectl get pod <name> --show-labels`.
- **Adding seccomp/securityContext to a Helm/operator workload?** Mechanism ladder (memory `[[gotcha_kyverno_seccomp_postrenderer]]`): chart-values `podSecurityContext` → operator-CR per-component `podSecurityContext` (Percona `spec.{mysql,proxy.haproxy,orchestrator}`; `kubectl explain` the field first or it's a silent no-op) → HelmRelease postRenderer **strategic-merge** (NEVER JSON6902 `op:add /securityContext` — replaces the chart's pod securityContext, drops fsGroup → PVC breakage). Privileged / replaced-securityContext container → set seccomp **pod-level** (container-level gets clobbered). UR2 remediated 12/12 this way (8 postRenderer + couchdb chart-values + Percona CR).

After fix-forward changes:

1. Validate locally (`/homelab-yaml-validate`).
2. Commit + push (per `/gitops-workflow`, one commit per `git add && git commit`).
3. Wait for Flux reconcile cascade (~5min — see `/gitops-workflow` § cascade timing).
4. Re-scan with `scan-violations.sh`. Loop until exit 0.

### Phase 4 — Promote to Deny

If `scan-violations.sh --policy <name> --force-regen` returns exit 0 (regeneration is complete and the scan finds no fails), run this from your task worktree (the script refuses the primary checkout):

```bash
bash ~/.agents/skills/kyverno-policy-promotion/scripts/prepare-enforce.sh \
  "$(git rev-parse --show-toplevel)"/infrastructure/configs/kyverno-policies/<name>-vp.yaml
```

The script edits the file in place (`validationActions: [Audit]`→`[Deny]`), runs plain `--dry-run=server` (NOT `--server-side` — field-ownership footgun with Flux), and prints the resulting `git diff`. It does NOT commit — review the diff, then commit per `/gitops-workflow`.

After push + reconcile, verify:

```bash
bash ~/.agents/skills/kyverno-policy-promotion/scripts/check-policy-action.sh <name>
# Expected: Deny
bash ~/.agents/skills/kyverno-policy-promotion/scripts/scan-violations.sh --policy <name>
# Expected: clean (exit 0)
kubectl get events -A --field-selector reason=PolicyViolation --sort-by='.lastTimestamp' | tail -5
# Should not show new violations for this policy in the post-promote window
```

**Positive admission test (prove Deny actually blocks, W8).** A clean scan + `Deny` action confirms live config, but a server-side dry-run create of a violating pod confirms the webhook denies. Three interplays (all hit during Gate B 2026-07-12):
- **PSS admission fires first** (`violates PodSecurity "restricted:latest"`) — craft a pod that passes PSS-restricted and violates ONLY the target policy; for host-field policies use a PSS-privileged ns (home-assistant).
- **Fine-grained VP webhooks short-circuit** — the deny message names only the FIRST failing policy (`vpol.validate.kyverno.svc-fail-finegrained-<policy>`). Attribution per policy = probe pod compliant-except-target.
- **LimitRanger injects default limits BEFORE validating webhooks** — a limit-less probe legitimately passes require-resource-limits in any ns with a LimitRange; probe in one without (trivy-scan).
Expected denial format + snippets: `reference-wave-notes.md` § "Positive admission test".

If new violations appear post-promote (a workload created between scan and Deny flip), revert the policy file to Audit, fix-forward the new violator, re-promote. Easier than chasing CrashLoop in cluster.

## Scripts

| Script | Use |
|---|---|
| `scripts/scan-violations.sh [--policy <name>] [--json] [--force-regen]` | Read-only scan. Lists PolicyReport fails. Exit 0 clean / 1 violations / 3 false-clean guard. |
| `scripts/seccomp-violators.sh [--json] [--count] [--exclude-ns a,b]` | Read-only LIVE-pod seccomp audit (RuntimeDefault), grouped ns/owner. Bypasses lagging PolicyReports; point-in-time (also check CronJob/Job templates). Exit 0 clean / 1 violators. |
| `scripts/check-policy-action.sh <policy-name>` | Read-only. Prints live vpol `spec.validationActions` (Audit / Deny / unknown). |
| `scripts/prepare-enforce.sh <policy-file-path>` | Local edit: `validationActions` [Audit] → [Deny]. Runs plain `--dry-run=server` (NOT `--server-side`). Does NOT commit. |

All scripts are `set -euo pipefail` with `shellcheck`/`shfmt` clean.

## Anti-patterns to avoid

- **Don't promote Audit→Deny inside the same PR that introduces the policy.** Audit needs ≥24h background-scan cycle to evaluate cluster-wide pods, else `scan-violations.sh` returns "clean" only because the controller hasn't scanned yet.
- **Don't use name-based excludes for operator pods.** Hash suffixes rotate. Use labels.
- **Don't bypass the pre-commit peer review loop** (see `/gitops-workflow`). The reviewer gate caught the `vm-operator` → `victoria-metrics-operator` healthCheck mismatch in Wave 1; it'll catch similar policy-target mismatches.
- **Don't add an entire namespace to `exclude:`** to make a violation go away unless you accept ALL pods there bypassing the policy. Prefer workload-label exclude. Precedent F-38 (`a35481fb`) narrowed `disallow-host-namespaces` whole-ns excludes → a `app.kubernetes.io/name: prometheus-node-exporter` label selector: `reference-wave-notes.md` § "Namespace-exclude vs label-exclude precedent".
- **PSS namespace `enforce` level ≠ a Kyverno exclude — and PSS Baseline forbids hostPath.** Before lowering a ns `privileged`→`baseline`, scan for hostPath volumes; prove the change with a live `--dry-run=server` first (F-45). Detail: `reference-wave-notes.md` § "PSS namespace level ≠ a Kyverno exclude". See `[[gotchas]]` "PSS Baseline FORBIDS hostPath".

## Cross-refs

- `/gitops-workflow` — commit + push + reconcile, cascade timing, pre-commit peer review loop.
- `/homelab-yaml-validate` — local validation ladder before commit.
- `reference-wave-notes.md` — Wave 1 / W8 incident detail, repro snippets, full why for each rule above.
- `[[project-ultrareview-learnings]]` memory — full Wave 1 incident notes.
