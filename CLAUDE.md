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
`shellcheck`, `dyff`, `stern`). The write-ish verbs it allows are the safe
GitOps-compatible ones only: `kubectl rollout restart`, `delete pod`,
`create job`, `apply --dry-run=server`. It explicitly **denies** re-running the
destructive DR restore CronJobs. This allowlist is a permission-prompt
convenience — it does **not** relax the **GitOps-only** invariant in `AGENTS.md`
(live mutation still goes through Git → Flux, never `kubectl edit/patch/replace`).

### Review loop

The pre-commit gate-of-record is in `AGENTS.md` (opposite-family peer, static
git-only, ≤3 delta-scoped rounds). Any reviewer — that peer, the
`k8s-devops-reviewer` sub-agent, or a security pass — checks the diff against
`.claude/review-invariants.md` first. Docs/markdown-only commits are exempt.

### Slash commands & skills live outside this repo

Homelab skills (`cluster-reboot`, `cluster-roll`, `homelab-node-fix`,
`cluster-stale-cleanup`, …) and slash commands (`/gitops-workflow`,
`/homelab-yaml-validate`, …) referenced in `AGENTS.md` are **not** in this
tree — they live in `~/.claude/` (a separate chezmoi-managed dotfiles repo).
A worktree isolates this repo's files, not `~/.claude/**`.
