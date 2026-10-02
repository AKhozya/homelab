#!/usr/bin/env bash
# PostToolUse hook — remind to update docs/HOMELAB_ANALYSIS.md after meaningful changes
# to apps/, infrastructure/, monitoring/, or clusters/.

set -euo pipefail

# This repo's main working tree, found from the hook's own location, so a clone at any
# path works. The first `worktree` entry is always the main tree.
HOMELAB_MAIN=$(git -C "$(dirname "${BASH_SOURCE[0]}")" worktree list --porcelain 2>/dev/null |
  awk '/^worktree /{print substr($0, 10); exit}') || exit 0
[[ -n "$HOMELAB_MAIN" ]] || exit 0

input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || true)
[[ -z "$file_path" ]] && exit 0

# Nearest existing ancestor of the target (new files are created in existing dirs).
dir=$(dirname "$file_path")
while [[ "$dir" != "/" && ! -d "$dir" ]]; do dir=$(dirname "$dir"); done

# The main tree and every linked worktree share one main tree; other repos do not.
toplevel=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || exit 0
# awk reads all input: an early exit can SIGPIPE git, and pipefail would then fail the hook.
main_tree=$(git -C "$dir" worktree list --porcelain 2>/dev/null | awk '/^worktree /{if (!n++) print substr($0, 10)}') || exit 0
[[ "$main_tree" == "$HOMELAB_MAIN" ]] || exit 0

rel=${file_path#"$toplevel"/}
case "$rel" in
apps/* | infrastructure/* | monitoring/* | clusters/*)
  # PostToolUse stderr on exit 0 reaches only the debug log; additionalContext
  # is what Claude reads.
  jq -nc --arg ctx "[homelab] changed: $rel. Update docs/HOMELAB_ANALYSIS.md if this is a meaningful infra/app change." \
    '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'
  ;;
esac

exit 0
