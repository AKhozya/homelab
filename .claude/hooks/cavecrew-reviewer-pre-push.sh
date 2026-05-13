#!/usr/bin/env bash
# PreToolUse hook — block `git push` on Flux paths until cavecrew-reviewer runs.
# Cavecrew-reviewer is a Claude subagent, so this hook only nags the main thread.
# Bypass: set CAVECREW_SKIP=1 in env.

set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)

[[ -z "$cmd" ]] && exit 0

case "$cmd" in
  git\ push*|*\;\ git\ push*|*\&\&\ git\ push*) ;;
  *) exit 0 ;;
esac

[[ "${CAVECREW_SKIP:-0}" == "1" ]] && exit 0

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo "origin/main")
diff_files=$(git diff --name-only "${upstream}"..HEAD 2>/dev/null || git diff --name-only HEAD)

flux_hits=$(echo "$diff_files" | grep -E '^(apps|infrastructure|monitoring|clusters)/' || true)

[[ -z "$flux_hits" ]] && exit 0

# Skip doc-only changes within Flux paths.
non_doc=$(echo "$flux_hits" | grep -Ev '(^|/)(README\.md$|docs/|.*\.md$)' || true)
[[ -z "$non_doc" ]] && exit 0

# Skip trivial diffs (<20 lines changed across non-doc Flux files).
changed_lines=$(git diff --numstat "${upstream}"..HEAD -- $non_doc 2>/dev/null \
  | awk '{a+=$1; d+=$2} END {print a+d+0}')
[[ "${changed_lines:-0}" -lt 20 ]] && exit 0

marker=".git/.cavecrew-reviewed-$(git rev-parse HEAD 2>/dev/null || echo none)"
[[ -f "$marker" ]] && exit 0

cat >&2 <<EOF
[cavecrew] git push touches Flux-managed paths. Run cavecrew-reviewer subagent on diff first:

  Files:
$(echo "$non_doc" | sed 's/^/    /')

  Action: invoke Task tool with subagent_type=caveman:cavecrew-reviewer on the diff,
  address findings, then \`touch $marker\` and retry push.
  Bypass: CAVECREW_SKIP=1 git push ...
EOF

exit 2
