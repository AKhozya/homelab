# CLAUDE.md

Project context for Claude Code. The canonical agent context is shared with all
AI tools in **[AGENTS.md](AGENTS.md)** — imported below so there's one source of
truth, no drift. Everything about the cluster, hard invariants, the worktree
model, the pre-commit review loop, and the docs map lives there; read it first.

@AGENTS.md

---

## Claude Code harness (this section is Claude-specific)

`AGENTS.md` is the shared brain. The rest of this file covers only the in-repo
`.claude/` harness — Codex has no use for it, so it stays out of `AGENTS.md`.
Do **not** duplicate cluster facts here; add them to `AGENTS.md` instead.

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
  pristine main tree (`/Users/akhozya/source-code/homelab`) so concurrent
  sessions can't stomp each other. Fail-open. Escape: `touch
  .claude/.allow-main-edits` (solo session) or `WORKTREE_GUARD_SKIP=1` (one-off).
- **SessionStart `worktree-session-start.sh`** — nudges sessions that start in
  the main tree toward a worktree (it can't move cwd; the PreToolUse guard is
  what actually enforces).
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

The `deny` entries name the two backup CronJobs whose re-run is destructive, in
both the `--from=` and `--from ` spellings, because the rules match command text
and a pattern list never covers every spelling a tool accepts. Treat them as a
backstop on a verb that already prompts, not as the control.

This allowlist is a permission-prompt convenience — it does **not** relax the
**GitOps-only** invariant in `AGENTS.md` (live mutation still goes through
Git → Flux, never `kubectl edit/patch/replace`).

### Review loop

The pre-commit gate-of-record is in `AGENTS.md` (opposite-family peer, static
git-only, delta-scoped re-review). Its state table decides when to commit. Any
reviewer — that peer, the
`k8s-devops-reviewer` sub-agent, or a security pass — checks the diff against
`.claude/review-invariants.md` first. Docs/markdown-only commits are exempt.

### Slash commands & skills live outside this repo

Homelab skills (`cluster-reboot`, `cluster-roll`, `homelab-node-fix`,
`cluster-stale-cleanup`, …) and slash commands (`/gitops-workflow`,
`/homelab-yaml-validate`, …) referenced in `AGENTS.md` are **not** in this
tree — they live in `~/.claude/` (a separate chezmoi-managed dotfiles repo).
A worktree isolates this repo's files, not `~/.claude/**`.
