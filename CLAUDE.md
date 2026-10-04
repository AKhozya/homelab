# CLAUDE.md

Claude Code imports the agent context that every AI tool shares from
**[AGENTS.md](AGENTS.md)** below. The cluster, hard invariants, worktree model,
pre-commit review loop and docs map live there; read it first.

@AGENTS.md

---

## Claude Code harness (this section is Claude-specific)

The rest of this file covers only the in-repo `.claude/` harness, which Codex
does not use. Do **not** duplicate cluster facts here; add them to `AGENTS.md`.

### Tracked `.claude/` assets

`.gitignore` ignores `.claude/*` except the four things below (worktrees, the
`.allow-main-edits` sentinel, and other local state stay untracked):

| Path | Purpose |
|---|---|
| `.claude/settings.json` | Permission allowlist + the three hooks (below). |
| `.claude/hooks/` | The worktree-guard / session-start / analysis-reminder scripts. |
| `.claude/review-invariants.md` | Reviewer rubric — semantic bug-classes CI can't catch. |
| `.claude/agents/k8s-devops-reviewer.md` | Opus sub-agent for DevOps/K8s review. |

### Hooks (`.claude/settings.json`)

- **PreToolUse `worktree-guard.sh`** — BLOCKS `Edit`/`Write`/`MultiEdit` on the
  pristine main tree (the first entry of `git worktree list`, so any clone path
  works) so concurrent sessions can't overwrite each other's uncommitted files. Fail-open. Escape: `touch
  .claude/.allow-main-edits` (solo session) or `WORKTREE_GUARD_SKIP=1` (one-off).
- **SessionStart `worktree-session-start.sh`** — nudges sessions that start in
  the main tree toward a worktree (it can't move cwd; the PreToolUse guard is
  what enforces).
- **PostToolUse `homelab-analysis-reminder.sh`** — after an edit under
  `apps/`, `infrastructure/`, `monitoring/`, or `clusters/`, reminds you to
  update `docs/HOMELAB_ANALYSIS.md`. Works in the main tree and in worktrees.

### Permissions posture

`settings.json` pre-allows read-mostly `kubectl`/`flux`/`helm`/`chezmoi` verbs
plus the local validation tools (`kubeconform`, `kustomize build`, `yamllint`,
`shellcheck`, `dyff`, `stern`). The write-ish verbs it allows are
`kubectl rollout restart`, `delete pod`, `apply --dry-run=server`, and
`flux reconcile` / `resume` / `suspend` — the last three do mutate live Flux
resources, and a forgotten `suspend` silently stops reconciliation, so treat
them as write verbs even though they change no manifest.

Nothing that executes code is on the allow list. `kubectl exec`, `port-forward`
and `create job` are each in-cluster code execution under the operator's
cluster-admin kubeconfig — the reach that `apps/claude-telegram/rbac.yaml`
exists to take away from the bot — so they prompt every time. Nor is `bash`
against the `~/.claude/skills` or `~/.agents/skills` trees: those live in the
dotfiles repo, outside this repo's pre-commit review gate, and one of them
rewrites live database passwords.

The `deny` entries block these commands:

| Denied | Why |
|---|---|
| `create job --from` either backup CronJob | a re-run of either is destructive |
| `delete` with `--force` or `--grace-period=0` anywhere in it | a force delete skips graceful shutdown; AGENTS.md forbids it on DB pods |
| `get` with `secret` or `Secret` anywhere after it | the `get *` allow would otherwise print Secret values |
| `get` with `-f`, `--filename`, `-k` or `--kustomize`, alone or after one of `-A`, `-R`, `-w` (`-Af`, `-Rk`) | a file or Kustomization can name a Secret without the word appearing in the command |

The rules match command text, so they block only the spellings they list:

| Limit | Reason |
|---|---|
| a cluster of two or more boolean flags before `-f` or `-k` (`-ARf`) passes | a glob wide enough to catch it also blocks routine reads such as `-n stirling-pdf -o wide` |
| a harmless `get` that mentions "secret" is refused | each `get` rule is a substring match; the cluster has no other resource type or namespace with that word in its name |
| no pattern list blocks every spelling | only a kubeconfig without Secret read access would, and the operator's kubeconfig is cluster-admin |

`kubectl apply --dry-run=server *` stays allowed by operator decision
(2026-09-28). kubectl honours the last `--dry-run` flag, so a later
`--dry-run=none` on the same line turns the allowed command into a real apply.

This allowlist is a permission-prompt convenience — it does **not** relax the
**GitOps-only** invariant in `AGENTS.md` (live mutation still goes through
Git → Flux, never `kubectl edit/patch/replace`).

### Review loop

The pre-commit gate-of-record and its round table are in `AGENTS.md`. Any
reviewer — that peer, the `k8s-devops-reviewer` sub-agent, or a security pass —
checks the diff against `.claude/review-invariants.md` first. Docs/markdown-only
commits are exempt.

### Slash commands & skills load from outside this repo

Homelab skills (`cluster-reboot`, `cluster-roll`, `homelab-node-fix`,
`cluster-stale-cleanup`, …) and slash commands (`/gitops-workflow`,
`/homelab-yaml-validate`, …) referenced in `AGENTS.md` load from `~/.claude/`
(a separate chezmoi-managed dotfiles repo). Edit the dotfiles copy, then
refresh this repo's read-only `agents/` copy with
`scripts/sync-agents.sh --update`. A worktree isolates this repo's files, not
`~/.claude/**`.
