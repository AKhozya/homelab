#!/usr/bin/env bash
# PreToolUse hook — enforce worktree-per-session isolation for the homelab repo.
# Blocks Edit/Write/MultiEdit targeting the MAIN working tree so concurrent
# sessions can't clobber each other's uncommitted files. Edits inside a linked
# worktree (.claude/worktrees/<name>) pass. FAIL-OPEN: any uncertainty -> allow,
# never brick editing because of a guard bug.
#
# Escape (solo session, no other Claude running):
#   touch <main>/.claude/.allow-main-edits    # gitignored, never committed
# One-off bypass: WORKTREE_GUARD_SKIP=1
set -euo pipefail

HOMELAB_MAIN=/Users/akhozya/source-code/homelab

[[ "${WORKTREE_GUARD_SKIP:-0}" == "1" ]] && exit 0
[[ -f "$HOMELAB_MAIN/.claude/.allow-main-edits" ]] && exit 0

input=$(cat)
fp=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
[[ -z "$fp" ]] && exit 0

# Nearest existing ancestor of the target (new files are created in existing dirs).
dir=$(dirname "$fp")
while [[ "$dir" != "/" && ! -d "$dir" ]]; do dir=$(dirname "$dir"); done

# Outside any git repo (e.g. ~/.claude dotfiles) -> not our concern.
toplevel=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || exit 0
# The first `worktree` entry is always the main working tree.
main_tree=$(git -C "$dir" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')
[[ -z "$main_tree" ]] && exit 0

# Only guard the homelab main tree; never block edits to other repos.
[[ "$main_tree" == "$HOMELAB_MAIN" ]] || exit 0
# Inside a linked worktree (toplevel != main tree) -> allow.
[[ "$toplevel" != "$main_tree" ]] && exit 0

rel=${fp#"$main_tree"/}
cat >&2 <<EOF
[worktree-guard] BLOCKED edit on homelab MAIN tree: $rel

  Main tree is the pristine checkout Flux reconciles; concurrent sessions
  editing it stomp each other's uncommitted work. Use a worktree:

    git worktree add .claude/worktrees/<task> -b wt-<task>
    cd .claude/worktrees/<task>        # re-run the edit from here

  Done: merge wt-<task> -> main, push, then \`fr\`.
  Solo session, no other Claude running? touch .claude/.allow-main-edits
  One-off bypass: WORKTREE_GUARD_SKIP=1
EOF
exit 2
