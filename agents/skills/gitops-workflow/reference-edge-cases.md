# GitOps Workflow — situational deep-dives

Loaded on demand from `gitops-workflow/SKILL.md`. Each section = one situation's full recipe + the why. SKILL.md holds the routing pointers; load this file when the matching situation fires.

## SOPS-encrypted overlay validation

For any kustomization touching a `sops:`-marked Secret, `kubectl apply -k <path> --dry-run=server` fails with `strict decoding error: unknown field "sops"`. Use these instead:

```bash
# 1. Build exit-code check + grep for stale refs (cheap, works always)
kubectl kustomize <path> > /tmp/built.yaml
echo "exit=$?"
grep -iE '<expected-removed-string>' /tmp/built.yaml && echo FAIL || echo PASS

# 2. Full Flux SSA dry-run (decrypts via cluster's kustomize-controller Secret)
flux build kustomization <name> --path <path> --kustomization-file clusters/<name>.yaml
```

## CI content-red vs infra-red classification

"Block `fr` on CI red" only holds when the red is YOUR manifest. Don't eyeball it — run `_shared/ci-red-classify.sh [branch] [sha]`:
- `GREEN` (exit 0) → proceed to `fr`.
- `CONTENT-RED` (exit 10) → real failure (some jobs passed, or predecessors were green). BLOCK `fr`; fix via `gh run view <id> --log-failed`.
- `INFRA-RED` (exit 11) → runner not executing. Two signals, either fires: (a) every job on the target run failed with **0 steps executed** (fail-to-start — billing block's signature since 2026-07-22; needs no predecessor corroboration because cancelled runs in history broke the all-red check); (b) every job dead + the last N runs incl. SHAs you didn't author all `failure`. Local validate (`/homelab-yaml-validate`) + peer static review are the **authorized gate of record** — proceed to `fr`. Recurred thrice (`b53a4cab`, `8de095cd`, `cda83418`).

Never hand-wave CONTENT-RED through. Accepted bypass on signal (a): a workflow-file content error that breaks job dispatch (bad `runs-on`) also presents all-zero-step — if your diff touched `.github/workflows`, treat the verdict as content-red.

## Flux cascade timing (don't tight-loop poll)

All six `fr`-reconciled kustomizations settle in **~5 minutes** post-push (the graph branches — see SKILL.md § 4). Don't tight-loop poll `flux get kustomization`:

```bash
sleep 75            # GitRepository fetch + first Kustomization Ready
flux reconcile kustomization <next-in-chain>
sleep 60            # downstream propagation
```

Reference: Wave 1 2026-05-23 — `infrastructure-controllers` Ready ~60s, `infrastructure-configs` ~90s, `apps` ~150s post-push.

## Path / layout moves (Kustomization `spec.path` change)

Repointing Flux at a moved/flattened dir (F-13/F-14, monitoring-controllers flatten `b53a4cab`):
- **Prove render-identical FIRST** — `_shared/kustomize-render-diff.sh oracle <old-path>` on the clean pre-change tree, then `… check <new-path>` after edits; must report `BYTE-IDENTICAL`. Identical render → Flux re-adopts every object by unchanged name/ns/GVK = zero churn (no restart/recreate/prune).
- **Path-change race.** Deleting the old dir in the SAME commit that repoints `spec.path` fires a brief "path not found" alert (the Kustomization's 1-min ticker reconciles against the deleted path before flux-system patches `spec.path`). Self-heals next reconcile. Two safe paths: (a) **hands-off → 2 commits** (repoint to the already-existing new dir, THEN delete old); (b) **attended → single atomic commit** + drive `flux reconcile source git flux-system` then `flux reconcile kustomization <name> --with-source` immediately — fetch+apply land together before the ticker hits the dead path, window near-zero.
- **Verify the repoint took:** `kubectl get kustomization <name> -n flux-system -o jsonpath='{.spec.path}'` + pod ages unchanged (no restarts). Full playbook (namespace-fold, worktree isolation, autostash-split) → `reference_kustomize_collapse` memory.

## New namespace + workload = 2 commits (Kyverno require-networkpolicy vs Flux dry-run)

Flux server-side dry-runs the WHOLE apply set before persisting anything. A single commit shipping ns+NP+workload has the workload admission-validated against a namespace whose NP doesn't exist yet (dry-run persists nothing) → `require-networkpolicy` VP denies, the kustomization stays stuck on the OLD revision until fixed. Bootstrap order: **commit 1** = namespace + NetworkPolicy (+SA/RBAC), reconcile; **commit 2** = workload. (2026-07-14 trivy-scan, first new namespace since the VP migration.)

Same family: **helm hook Jobs go through admission too** — a chart whose pre/post-upgrade hook Job ships without resource limits wedges EVERY upgrade (`require-resource-limits` denies → HelmRelease retries then Stalls + auto-rolls-back, silently holding back any values changes riding the release). On chart bumps check hook Jobs have resources via values (kube-prometheus-stack: `prometheusOperator.admissionWebhooks.patch.resources`). (2026-07-14, 87.15.2/87.16.0.)

## Pre-wave annotated tag (multi-commit infra/security waves)

Before any wave touching 3+ Flux-managed files, create a signed annotated tag for rollback:

```bash
git tag -a pre-<wavename>-$(date +%Y-%m-%d) -m "Pre-wave baseline before <description>"
git push origin pre-<wavename>-$(date +%Y-%m-%d)
```

Lightweight tags (`git tag <name>` without `-a`) FAIL when `~/.gitconfig` has `[tag] gpgsign = true`. Always use `-a`.

Rollback path: revert the first-parent commits after the tag, newest first. Push only if the
loop prints `ROLLBACK COMPLETE`:

```bash
ok=1
commits=$(git rev-list --first-parent pre-<wavename>-<date>..HEAD) && [ -n "$commits" ] || ok=0
while [ "$ok" = 1 ] && IFS= read -r c; do
  if git rev-parse -q --verify "$c^2" >/dev/null; then
    git revert --no-edit -m 1 "$c" || ok=0
  else
    git revert --no-edit "$c" || ok=0
  fi
done <<<"$commits"
[ "$ok" = 1 ] && echo "ROLLBACK COMPLETE — push" || echo "ROLLBACK STOPPED — resolve or git revert --abort; do NOT push"
```

`--first-parent` skips the commits inside a merged branch; their merge commit's `-m 1` revert already undoes them. Never force-push `main`: Flux and every worktree track it, and after a rewrite their history no longer matches the remote branch.

## Teardown pattern (full sequence)

```bash
# 1. Suspend Flux reconciliation
flux suspend kustomization <name>

# 2. Delete resources manually
kubectl delete -f <file.yaml>

# 3. Remove from Git
git rm <files>
git commit -m "Remove: <resource>"
git push

# 4. Resume Flux
flux resume kustomization <name>

# 5. Reconcile
flux reconcile kustomization <name> --timeout=60s
```

- 2026-07-23 recurrence #4 (`9c3421a5`): 12 failure + 1 NULL-conclusion job, all 0 steps — old `conclusion=="failure"` zerostep filter undercounted → false CONTENT-RED. Classifier now conclusion-agnostic on zerostep, gated on run `conclusion=="failure"`, and cancelled runs exit 12 CANCELLED (never infra-red — sha was never validated).

## validate.yaml jobs

After push, `.github/workflows/validate.yaml` runs 14 parallel jobs, ~45s p95. gitleaks is not one of them. It runs in its own `gitleaks.yaml`.

| Job | Legs |
|---|---|
| yamllint | 1 |
| shellcheck | 1 |
| sops-check | 1 |
| init-resources | 1 |
| image-pin | 1 |
| HOMELAB_ANALYSIS drift, warn-only | 1 |
| kubeconform, one per kustomize root incl. `infrastructure/coredns` | 7 |
| helm-render, every HelmRelease chart at its pinned version | 1 |

## Actions billing block

If Actions billing blocks jobs again (it did 2026-09-10 to 2026-10-01):

| Fact | Consequence |
|---|---|
| GitHub creates a `validate.yaml` run for a push that CI covers, but no job starts; every job fails with 0 steps | `wait-for-ci.sh` exits 11 INFRA-RED for that push until the account owner fixes billing |
| a docs/markdown-only push creates no run | `wait-for-ci.sh` exits 3, as before |
| CI therefore checks nothing | run the pre-commit review loop and `/homelab-yaml-validate` before the commit; they are the checks that still run |

## `fr` serial order vs the dependency graph

**`fr` serial execution order** (NOT the dep graph): `flux-system` → `infrastructure-controllers` → `infrastructure-configs` → `monitoring-controllers` → `monitoring-configs` → `apps`. The real dependency graph BRANCHES — `flux-system` → `infrastructure-controllers` → { `coredns` | `infrastructure-configs` → `apps` | `monitoring-controllers` → `monitoring-configs` } (see AGENTS.md; source of truth `clusters/*.yaml` dependsOn).

## Why the main tree is guarded

The homelab main tree is the pristine checkout Flux reconciles; the `worktree-guard` PreToolUse hook BLOCKS Edit/Write/MultiEdit there so concurrent sessions can't clobber each other's uncommitted files.

Mechanics: native `EnterWorktree` tool or `superpowers:using-git-worktrees` skill.

## Why the hook blocks multiline commit commands

The recurring trip is a benign `cd /path`⏎`git commit …` two-liner: the newline alone blocks it (forces a manual approve every time).

## Why a hand-merge from a worktree fails

**Merge worktree → main DETERMINISTICALLY.** Running `git merge`/`git push` from a worktree's own cwd merges the branch into ITSELF (silent no-op "Already up to date") and then pushes the stray feature branch to origin instead of updating main — hit 3× on 2026-07-06.

## Example review-invariants catch

Example of the class: Wave-1 caught a `vm-operator` → `victoria-metrics-operator` Flux healthCheck name mismatch in `clusters/monitoring.yaml` before it reached the cluster.

## Why a docs-only push skips 3c and `fr`

**Docs/markdown/asset-only push? SKIP 3b + 3c + `fr` entirely.** Both workflows run on every push to `main` and every PR targeting `main`. `validate.yaml` has no path filter, because the `main` ruleset requires its `ci-ok` check, and a path-filtered required check stays pending on a docs-only PR. A docs-only push changes nothing Flux applies, so waiting for CI protects no deploy, and `fr` is a no-op. If CI fails on a docs-only push, read the failed check: the secret scan covers markdown too.

## Why withholding `fr` is not a gate

| Resource | Interval |
|---|---|
| GitRepository `flux-system` | 5 min |
| Kustomization `flux-system` | 5 min |
| the other six Kustomizations | 1 min |

CI finishes in ~45s, so a red run may finish before the next poll. The gate is the pre-commit review loop, which runs before the commit exists.

## Why an applied StatefulSet fix can leave the pod down

Flux says applied, `sts.spec` shows the fix, prod stays down.

2026-08-04: linkwarden/meilisearch sat 13h / 164 restarts, two revisions behind, after its fix commit reconciled green.
