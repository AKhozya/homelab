#!/usr/bin/env bash
# SessionStart hook — nudge homelab sessions that start in the MAIN tree to work
# in a per-session worktree (file isolation between concurrent sessions). Emits
# guidance as additionalContext; a hook cannot relocate the session cwd, so
# enforcement is the worktree-guard PreToolUse hook. Silent in worktrees, in
# other repos, and when the solo-mode sentinel is present.
set -euo pipefail

HOMELAB_MAIN=/Users/akhozya/source-code/homelab

proj=$(cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null && pwd) || exit 0
[[ "$proj" == "$HOMELAB_MAIN" ]] || exit 0
[[ -f "$HOMELAB_MAIN/.claude/.allow-main-edits" ]] && exit 0

read -r -d '' msg <<'EOF' || true
[worktree-policy] Session started in the homelab MAIN tree. To avoid clobbering
a concurrent session's uncommitted files, do edits in a worktree:

  git worktree add .claude/worktrees/<task> -b wt-<task> && cd .claude/worktrees/<task>

Commit there, merge wt-<task> -> main, push, `fr`. Main-tree edits are blocked
by the worktree-guard hook. Solo session, no other Claude running?
`touch .claude/.allow-main-edits` to edit the main tree directly.
EOF

jq -nc --arg ctx "$msg" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
