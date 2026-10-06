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

Run `_shared/ci-red-classify.sh <branch> <sha>` to classify a `ci-ok` failure before you read its log. The classifier reads only `validate.yaml`. If `gitleaks secret scan` fails, read that run's log. The classifier applies at two points:

| Point | Branch and sha to pass |
|---|---|
| `ci-ok` failed on the PR, so `merge-worktree.sh` exited 1 | the PR branch and its head sha |
| the merge commit's run on `main` is red | `main` and the merge commit sha |

| Verdict | Exit | Means | On the PR | On `main` |
|---|---|---|---|---|
| `GREEN` | 0 | the run passed | run `merge-worktree.sh` again; it re-checks both required checks | `fr` |
| `CONTENT-RED` | 10 | a real failure: some jobs passed, or earlier runs were green | read `gh run view <id> --log-failed`, commit the fix in the worktree, run `merge-worktree.sh` again | no `fr`; revert through a PR |
| `INFRA-RED` | 11 | the runner failed, not the change (signals below) | nothing merges until the runner works; ask the operator | `gh run rerun <id>`, then watch again |
| `CANCELLED` | 12 | no run finished checking the sha | `gh run rerun <id>` | `gh run rerun <id>`, then watch again |

If any test matches, the classifier reports INFRA-RED:

| Signal | Test | Note |
|---|---|---|
| fail-to-start | the target run's conclusion is `failure` and every job executed **0 steps**, whatever the job's own conclusion | the billing block's signature since 2026-07-22. It needs no check of earlier runs, because cancelled runs in the history broke the all-red test |
| all red | every job failed, and the last N runs, including SHAs you did not author, all failed | |
| never started | the target run's conclusion is `failure`, every job that executed a step succeeded (`ci-ok` aside), and at least one job executed 0 steps and did not succeed | `ci-ok` then fails only because those jobs did not succeed. In the 2026-10-05 Actions incident GitHub cancelled 6 of 16 queued jobs; the old classifier called that CONTENT-RED. Re-run with `gh run rerun <id> --failed` |

| Infra-red recurrence | Commit | Note |
|---|---|---|
| 1 | `b53a4cab` | |
| 2 | `8de095cd` | |
| 3 | `cda83418` | |
| 4, 2026-07-23 | `9c3421a5` | 12 failed jobs and 1 job with no conclusion, all with 0 steps |

On recurrence 4 the old zero-step filter counted only `conclusion=="failure"`, so it undercounted and reported a false CONTENT-RED. The classifier now counts zero-step jobs whatever their conclusion, but only if the run's conclusion is `failure`. A cancelled run is never infra-red.

Never treat CONTENT-RED as anything but a real failure. Caveat on the fail-to-start signal: a workflow-file error that breaks job dispatch (bad `runs-on`) also shows every job with 0 steps. If your diff touched `.github/workflows`, treat the verdict as content-red.

## Flux cascade timing (don't tight-loop poll)

All six `fr`-reconciled kustomizations settle in **~5 minutes** after the merge (the graph branches — see SKILL.md § 4). Don't tight-loop poll `flux get kustomization`:

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

Rollback path: run `git fetch origin main`, make a new worktree from `origin/main`, and revert
the first-parent commits after the tag there, newest first. If the loop prints
`ROLLBACK COMPLETE`, merge the revert branch with `merge-worktree.sh`. If it prints anything
else, do not merge:

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
[ "$ok" = 1 ] && echo "ROLLBACK COMPLETE — merge it with merge-worktree.sh" || echo "ROLLBACK STOPPED — resolve or git revert --abort; do NOT merge"
```

`--first-parent` skips the commits inside a merged branch; their merge commit's `-m 1` revert already undoes them. Never force-push `main`: Flux and every worktree track it, and after a rewrite their history no longer matches the remote branch.

## Teardown pattern (full sequence)

```bash
# 1. Suspend Flux reconciliation
flux suspend kustomization <name>

# 2. Delete resources manually
kubectl delete -f <file.yaml>

# 3. Remove from Git (in the task worktree), then merge it through a PR
git rm <files>
git commit -m "Remove: <resource>"
~/.agents/skills/_shared/merge-worktree.sh wt-<task>
```

If the script exits 0 or 3 and SKILL.md step 3c reports GREEN, resume. Otherwise stop: if the
PR did not merge, git still holds the resources, so resuming Flux recreates them.

```bash
# 4. Resume Flux
flux resume kustomization <name>

# 5. Reconcile
flux reconcile kustomization <name> --timeout=60s
```

## validate.yaml jobs

On every PR to `main` and every push to `main` (a merge commit included), `.github/workflows/validate.yaml` runs 14 parallel jobs, ~45s p95. gitleaks is not one of them. It runs in its own `gitleaks.yaml`.

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
| GitHub creates a `validate.yaml` run, but no job starts; every job fails with 0 steps | the required checks fail, so `merge-worktree.sh` exits 1 and nothing merges |
| the ruleset has no bypass | only the operator can let a change through, by changing the ruleset; ask, never work around it |

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

## Why a docs-only change skips the 3c watch and `fr`

Both workflows run on every push to `main` and every PR targeting `main`. `validate.yaml` has no path filter, because the `main` ruleset requires its `ci-ok` check, and a path-filtered required check stays pending on a docs-only PR. So the required checks still gate a docs-only merge. A docs-only merge changes nothing Flux applies, so watching its run on `main` protects no deploy, and `fr` is a no-op. If a check fails on a docs-only PR, read it: the secret scan covers markdown too.

## Why withholding `fr` is not a gate

| Resource | Interval |
|---|---|
| GitRepository `flux-system` | 5 min |
| Kustomization `flux-system` | 5 min |
| the other six Kustomizations | 1 min |

CI finishes in ~45s, so a red run may finish before the next poll. The gates are the pre-commit review loop, which runs before the commit exists, and the required checks, which run before the merge.

## Why an applied StatefulSet fix can leave the pod down

Flux says applied, `sts.spec` shows the fix, prod stays down.

2026-08-04: linkwarden/meilisearch sat 13h / 164 restarts, two revisions behind, after its fix commit reconciled green.
