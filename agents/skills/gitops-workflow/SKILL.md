---
name: gitops-workflow
description: Use when making changes to homelab GitOps repo. Canonical flow validate→commit→push→Flux reconcile (`fr`)→verify→teardown→rollback. Enforces no kubectl edit/patch, dry-run-first, image pinning, single-line commits.
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
Flux source = `branch: main`, so finish by merging `wt-<task>` → main → push → `fr` (worktree branches are invisible to the cluster until merged). Teardown after merge (step 6): `git worktree remove .claude/worktrees/<task>`. Solo session, no other agent session running? `touch .claude/.allow-main-edits` (gitignored) to edit the main tree directly; one-off `WORKTREE_GUARD_SKIP=1`.

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
# Create feature branch (for major changes)
git checkout -b feature/<name>

# ~/.gitignore_global ignores *.env. If you stage a directory, Git leaves out a
# configMapGenerator envs: file with no warning, and Flux fails the app's build.
# Give that file a .properties extension, and update envs: to the new name before you stage.

# Stage changes
git add <files>
# The generator input must appear in this list:
git diff --cached --name-only <dir>/

# Commit with single-line message (no AI-agent mention)
git commit -m "Add/Update/Fix: brief description"

# Push
git push origin <branch>
# Confirm the generator input reached the pushed branch:
git ls-tree origin/<branch> <dir>/ --name-only
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

**Merge worktree → main DETERMINISTICALLY.** If you need why, read reference-edge-cases.md § "Why a hand-merge from a worktree fails". Don't hand-merge; use the helper, which addresses the primary tree via `git -C` and guards on-main + clean-tree + ff-only:
```bash
~/.agents/skills/_shared/merge-worktree.sh wt-<task>             # fetch, ff-only onto origin/main, push origin HEAD:main
~/.agents/skills/_shared/merge-worktree.sh wt-<task> --teardown  # + remove THAT worktree & branch (branch-scoped)
```

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

### 3c. CI gate — wait for `validate.yaml` green (post-push, pre-`fr`)

**Docs/markdown/asset-only push? SKIP 3b + 3c + `fr` entirely.** If you need why, read reference-edge-cases.md § "Why a docs-only push skips CI and `fr`". The pre-commit peer review (3b) applies to substantive code/config commits; docs/markdown are exempt. Pure docs/memory flow = commit → merge → push → done. Reserve CI-watch for pushes CI can fail on (any `.yaml`/`.sh`/manifest — `node-maintenance/**` and `scripts/**` shell is linted). Mixed md+yaml push → CI runs, watch normally.

If you read a CI result or change `validate.yaml`, read reference-edge-cases.md § "validate.yaml jobs" for its jobs, legs and run time.

**If CI is red, do not run `fr`.** Withholding `fr` delays reconciliation until Flux polls. It does not prevent deployment.
If you need the poll intervals behind this, read reference-edge-cases.md § "Why withholding `fr` is not a gate".

Read the fetched revision before deciding: `flux get source git flux-system`. If it already names your commit, this is an incident, not a gate.

```bash
# One command: resolves the run for the JUST-PUSHED sha (never "latest" — that races with
# neighbouring pushes), watches it, then auto-classifies via _shared/ci-red-classify.sh.
bash ~/.agents/skills/gitops-workflow/scripts/wait-for-ci.sh
# Exit 0 GREEN → fr | 10 CONTENT-RED → STOP, gh run view <id> --log-failed
# | 11 INFRA-RED → local gate + peer review authorize fr | 3 no run appeared (docs-only push?)
```

If Actions billing blocks every job again, CI checks nothing. Run the pre-commit review loop and `/homelab-yaml-validate` before each commit.
Then read reference-edge-cases.md § "Actions billing block".

**Content-red vs infra-red — classify before blocking.** "Block `fr` on CI red" only holds when the red is YOUR manifest. If CI is red, don't eyeball it — run `_shared/ci-red-classify.sh [branch] [sha]` (exit-code map in the block above). Full classification + the never-hand-wave rule → `reference-edge-cases.md` § CI content-red vs infra-red.

### 4. Flux Reconciliation

**Full-stack** (preferred): `fr` zsh function — reconciles helm repos + git source + 6 kustomizations in dep order.

If a Kustomization reconciles out of the order you expect, read reference-edge-cases.md § "`fr` serial order vs the dependency graph".

**Granular**:
```bash
# Git source first if commit pushed
flux reconcile source git flux-system --timeout=60s

# Then specific kustomization
flux reconcile kustomization <name> --timeout=60s

# Or specific HelmRelease
flux reconcile helmrelease <name> -n <namespace> --timeout=60s

# Watch
flux get kustomization <name> -w
```

**Cascade timing.** Full chain takes **~5 minutes** post-push — don't tight-loop poll `flux get kustomization`; pace with `sleep 75` (first Kustomization Ready) → reconcile next → `sleep 60` (downstream). Per-stage numbers → `reference-edge-cases.md` § Flux cascade timing.

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
- **Never**: `kubectl apply -f` without `--dry-run=server` first
- **Never**: Direct DB drops - use CRDs
- **Never**: Force-delete DB pods
- **Always**: Single-line commit, no AI-agent mention
- **Always**: Verify with flux-operator MCP (`get_kubernetes_resources`) after reconciliation

## Rollback
```bash
# Git revert last commit
git revert HEAD --no-edit
git push

# Flux will auto-reconcile in 60s, or force:
flux reconcile kustomization <name> --timeout=60s
```

## Tools Allowed
- `Bash(git *)`
- `Bash(kubectl *)`
- `Bash(flux reconcile *)` (write ops only)
- `mcp__flux-operator__get_kubernetes_resources` (read/verify)
- `Edit`
- `Write`
- `Read`
