---
name: gitops-workflow
description: Use when making changes to homelab GitOps repo. Canonical flow validate→commit→PR merge→Flux reconcile (`fr`)→verify→teardown→rollback. Enforces PR-only changes to main, no kubectl edit/patch, dry-run-first, image pinning, single-line commits.
user-invocable: false
---

# GitOps Workflow Skill

## Workflow Steps

### 0. Worktree (concurrent-session isolation)
Start each task in its own worktree:

```bash
git worktree add .claude/worktrees/<task> -b wt-<task> && cd .claude/worktrees/<task>
```

If you need why the main tree is guarded, or the worktree mechanics, read reference-edge-cases.md § "Why the main tree is guarded".
Flux source = `branch: main`, so finish by merging `wt-<task>` into main through a PR (step 3), then `fr`. Worktree branches are invisible to the cluster until merged. `merge-worktree.sh --teardown` removes the worktree and branch after the merge. Solo session, no other agent session running? `touch .claude/.allow-main-edits` (gitignored) to edit the main tree directly; one-off `WORKTREE_GUARD_SKIP=1`.

### 1. Plan
- Identify affected resources
- Check current state: `kubectl get <resource> -n <namespace>`
- Review existing YAML in repo

### 2. Validate
```bash
# Plain manifest — server-side validation
kubectl apply -f <file.yaml> --dry-run=server

# YAML syntax check
kubectl apply -f <file.yaml> --dry-run=client
```

**SOPS-encrypted overlays** (any kustomization touching a `sops:`-marked Secret): `--dry-run=server` fails with `strict decoding error: unknown field "sops"`. Use `kubectl kustomize` exit-code+grep or `flux build kustomization` instead → `reference-edge-cases.md` § SOPS-encrypted overlay validation.

### 3. Git Operations
```bash
# ~/.gitignore_global ignores *.env. If you stage a directory, Git leaves out a
# configMapGenerator envs: file with no warning, and Flux fails the app's build.
# Give that file a .properties extension, and update envs: to the new name before you stage.

# Stage changes
git add <files>
# The generator input must appear in this list:
git diff --cached --name-only <dir>/

# Commit with single-line message (no AI-agent mention)
git commit -m "Add/Update/Fix: brief description"

# Confirm the generator input is in the commit:
git ls-tree HEAD <dir>/ --name-only
```

**Commit command MUST be one physical line.** `~/.claude/hooks/git-commit-style.sh` exits 2 (BLOCK) on ANY command containing `git commit` that holds a literal newline (`case *$'\n'*`) — NOT just compound chains. If you need an example of a blocked commit command, read reference-edge-cases.md § "Why the hook blocks multiline commit commands". Fix: drop the `cd`, address the repo with `-C`, keep it on one line:

```bash
# Right (single line, no cd, no newline):
git -C /abs/repo add fileA fileB && git -C /abs/repo commit -m 'subject ~72 chars'
# In a worktree: git -C /abs/repo/.claude/worktrees/<name> add … && git -C … commit -m '…'
# Wrong (newline before git commit → BLOCKED):
#   cd /abs/repo
#   git commit -m '…'
```

Also one `add`+`commit` per call (no `commit && commit` batching). See bash-scripting quirk #6.

**Merge the worktree branch into main through a PR.** The `main` ruleset rejects every direct push and has no bypass, so a change reaches main only as a PR whose required checks (`ci-ok`, `gitleaks secret scan`) passed. Use the helper. In order, it:

1. pushes the branch;
2. opens the PR, or reuses an open one;
3. waits for the required checks;
4. merges with a merge commit;
5. fast-forwards the primary tree's `main`.

```bash
~/.agents/skills/_shared/merge-worktree.sh wt-<task>             # PR, required checks, merge commit, sync the primary tree
~/.agents/skills/_shared/merge-worktree.sh wt-<task> --teardown  # + remove THAT worktree & branch (branch-scoped)
```

| Exit | Meaning | Next |
|---|---|---|
| 0 | merged, primary tree synced | 3c, then `fr`, verify |
| 3 | merged on GitHub, but a later step failed (fetch, lock, primary sync, teardown) | 3c and `fr` anyway: Flux reads GitHub, not the local checkout. Then fix the primary tree by hand or ask the operator. Never reset it |
| 5 | merge outcome unknown | `gh pr view <n> --json state`: MERGED → treat as 3; OPEN or CLOSED → treat as 1. If the lookup fails, the outcome stays unknown: no `fr`, ask the operator |
| 4 | branch pushed, no GitHub login (the in-cluster bot) | give the operator the compare URL. Nothing is deployed, so no `fr` |
| 1 | stopped before the merge | nothing is deployed. Read the message, fix, re-run. An open PR stays open |
| 2 | usage error | fix the call |

Only this script changes the primary tree, so never `git pull` or `git merge` there by hand. If you need why a hand-merge from a worktree fails, read reference-edge-cases.md § "Why a hand-merge from a worktree fails".

### 3b. Pre-commit review loop (opposite-family peer — gate-of-record; see CLAUDE.md)

Review is **pre-commit**, not pre-push. The AGENTS.md "Pre-commit review loop" hard invariant owns the full loop. Follow it verbatim. Its state table decides when to commit. Resolve the peer via `peer-reviewed-implementation/scripts/reviewer-peer`.

| Constraint | Value |
|---|---|
| reviewer reach | STATIC, git-only |
| verdict | one message, no loop |
| findings | process via `receiving-code-review` |
| re-review | delta-scoped |
| docs/markdown-only | exempt |

Reviewers MUST check the diff against `.claude/review-invariants.md` — semantic bug-classes CI misses. If you need an example of the class, read reference-edge-cases.md § "Example review-invariants catch". Grep the target file to confirm name/GVK claims before flagging.

### 3c. CI — the required checks gate the merge; watch the merge result before `fr`

`merge-worktree.sh` merges only after the required checks pass. Those checks ran on GitHub's test merge of the branch with `main` as it was when GitHub made that test merge. The ruleset does not require the branch to be up to date, so if `main` moved since, the real merge commit is untested until its own `validate.yaml` run on `main` finishes. After exit 0 or 3, watch that run before `fr`.

**If the change is docs, markdown or assets only, skip 3b, the 3c watch and `fr`.** The required checks still run on the PR, so the merge waits for them. If you need why, read reference-edge-cases.md § "Why a docs-only change skips the 3c watch and `fr`". The pre-commit peer review (3b) applies to substantive code/config commits; docs/markdown are exempt. Pure docs/memory flow = commit → `merge-worktree.sh` → done. Mixed md+yaml change → watch CI normally.

If you read a CI result or change `validate.yaml`, read reference-edge-cases.md § "validate.yaml jobs" for its jobs, legs and run time.

**If CI is red, do not run `fr`.** Withholding `fr` delays reconciliation until Flux polls. It does not prevent deployment.
If you need the poll intervals behind this, read reference-edge-cases.md § "Why withholding `fr` is not a gate".

Read the fetched revision before deciding: `flux get source git flux-system`. If it already names your commit, this is an incident, not a gate.

```bash
# Resolves the run for THIS sha (never "latest" — that races with neighbouring merges), watches
# it, then classifies it via _shared/ci-red-classify.sh. The sha is in the script's OK line; after
# exit 3, read it with: gh pr view <n> --json mergeCommit -q .mergeCommit.oid
bash ~/.agents/skills/gitops-workflow/scripts/wait-for-ci.sh <merge-commit-sha>
# Any exit but 0 → no fr until a later watch exits 0.
# 0 GREEN → fr | 10 CONTENT-RED → the merge result is broken: revert through a PR
# | 11 INFRA-RED → the runner failed, not the change: gh run rerun <id>, watch again
# | 12 CANCELLED → gh run rerun <id>, watch again | 5 PENDING → watch again
# | 3 no run or a tooling error → fix the cause, watch again | 2 misuse → fix the arguments, watch again
```

If Actions billing blocks every job again, the required checks cannot pass and nothing merges. Stop and ask the operator: the ruleset has no bypass, so only the operator can change it.
Then read reference-edge-cases.md § "Actions billing block".

**Content-red vs infra-red — classify before acting.** If `ci-ok` fails on the PR (`merge-worktree.sh` exits 1) or the merge commit's run is red, run `_shared/ci-red-classify.sh <branch> <sha>` before you read the log. The classifier reads only `validate.yaml`. If `gitleaks secret scan` fails, read that run's log. Full classification and the rule never to ignore CONTENT-RED → `reference-edge-cases.md` § CI content-red vs infra-red.

### 4. Flux Reconciliation

**Full-stack** (preferred): `fr` zsh function — reconciles helm repos + git source + 6 kustomizations in dep order.

If a Kustomization reconciles out of the order you expect, read reference-edge-cases.md § "`fr` serial order vs the dependency graph".

**Granular**:
```bash
# Git source first if a commit merged
flux reconcile source git flux-system --timeout=60s

# Then specific kustomization
flux reconcile kustomization <name> --timeout=60s

# Or specific HelmRelease
flux reconcile helmrelease <name> -n <namespace> --timeout=60s

# Watch
flux get kustomization <name> -w
```

**Cascade timing.** Full chain takes **~5 minutes** after the merge — don't tight-loop poll `flux get kustomization`; pace with `sleep 75` (first Kustomization Ready) → reconcile next → `sleep 60` (downstream). Per-stage numbers → `reference-edge-cases.md` § Flux cascade timing.

**Path / layout moves (Kustomization `spec.path` change).** Repointing Flux at a moved/flattened dir (F-13/F-14): prove render-identical FIRST (`_shared/kustomize-render-diff.sh` → `BYTE-IDENTICAL`), then either 2-commit hands-off or atomic `--with-source` to dodge the path-change race. Full playbook → `reference-edge-cases.md` § Path / layout moves.

### 5. Verify
```bash
# Check deployment status
kubectl rollout status deployment/<name> -n <namespace>

# Verify pods running
kubectl get pods -n <namespace> -l app=<label>

# Check logs for errors
kubectl logs -n <namespace> -l app=<label> --tail=50
```

**StatefulSet: `✔ applied revision` does NOT mean the pod rolled.** A StatefulSet whose pod is *already* unhealthy stops its rollout and waits for that pod to become Ready — which never happens — so a fix pushed through Flux lands in `.spec` while the pod keeps crashing on the old template (upstream calls this [forced rollback](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/#forced-rollback), [k8s#67250](https://github.com/kubernetes/kubernetes/issues/67250)). If you need the incident, read reference-edge-cases.md § "Why an applied StatefulSet fix can leave the pod down". Reverting or fixing the template is not enough — the pod must be deleted by hand:
```bash
kubectl -n <ns> get sts <name> -o jsonpath='{.status.currentRevision}{" -> "}{.status.updateRevision}{"\n"}'
kubectl -n <ns> get pod <name>-0 -o jsonpath='{.metadata.labels.controller-revision-hash}{"\n"}'  # ≠ updateRevision = stuck
kubectl -n <ns> delete pod <name>-0
```

### 6. Update Docs
After success, update `docs/HOMELAB_ANALYSIS.md` if adding apps or major changes.

## Pre-wave annotated tag (multi-commit infra/security waves)

Before any wave touching 3+ Flux-managed files, create a signed annotated tag (`git tag -a pre-<wavename>-<date>`) for rollback — must be `-a`, lightweight tags fail; details + rollback: `reference-edge-cases.md` § Pre-wave annotated tag.

## Teardown Pattern

Removing a git-managed resource = suspend → delete → git rm → resume → reconcile, in that order.
Full command sequence: `reference-edge-cases.md` § Teardown pattern.

## Safety Rules
- **Never**: push to `main` directly or merge a PR around its required checks
- **Never**: `kubectl apply -f` without `--dry-run=server` first
- **Never**: Direct DB drops - use CRDs
- **Never**: Force-delete DB pods
- **Always**: Single-line commit, no AI-agent mention
- **Always**: Verify with flux-operator MCP (`get_kubernetes_resources`) after reconciliation

## Rollback
```bash
# In a new worktree from a fresh origin/main, revert the PR's merge commit, then merge the revert
# through a PR. Then follow step 3's exit-code table and step 3c before fr.
git fetch origin main
git worktree add .claude/worktrees/revert-<task> -b wt-revert-<task> origin/main
git -C .claude/worktrees/revert-<task> revert -m 1 --no-edit <merge-commit-sha>
~/.agents/skills/_shared/merge-worktree.sh wt-revert-<task> --teardown

# Flux fetches main within 5 min, or force:
flux reconcile kustomization <name> --with-source --timeout=60s
```

## Tools Allowed
- `Bash(git *)`
- `Bash(kubectl *)`
- `Bash(flux reconcile *)` (write ops only)
- `mcp__flux-operator__get_kubernetes_resources` (read/verify)
- `Edit`
- `Write`
- `Read`
