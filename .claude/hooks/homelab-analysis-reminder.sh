#!/usr/bin/env bash
# PostToolUse hook — remind to update docs/HOMELAB_ANALYSIS.md after meaningful changes
# to apps/, infrastructure/, monitoring/, or clusters/.

set -euo pipefail

# Read hook input (JSON on stdin)
input=$(cat)

# Extract file path from Edit/Write tool input
file_path=$(echo "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || true)

# Skip if no path
[[ -z "$file_path" ]] && exit 0

# Only trigger for tracked homelab dirs
# Match Flux-managed dirs in EITHER the main tree (.../homelab/apps/...) or a
# linked worktree (.../homelab/.claude/worktrees/<task>/apps/...). Both paths
# contain /homelab/ AND a Flux dir; other repos match neither.
case "$file_path" in
  */homelab/*)
    case "$file_path" in
      */apps/*|*/infrastructure/*|*/monitoring/*|*/clusters/*)
        # Already editing HOMELAB_ANALYSIS.md? Skip.
        [[ "$file_path" == *HOMELAB_ANALYSIS.md ]] && exit 0

        # Print reminder to stderr (Claude sees it)
        echo "[homelab] changed: ${file_path##*/homelab/}" >&2
        echo "[homelab] reminder: update docs/HOMELAB_ANALYSIS.md if this is a meaningful infra/app change." >&2
        ;;
    esac
    ;;
esac

exit 0
