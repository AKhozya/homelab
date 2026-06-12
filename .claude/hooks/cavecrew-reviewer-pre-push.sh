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

# Resolve the dir where the push actually runs (payload cwd) so the git-dir
# probe below matches cavecrew-mark.sh's writer in a linked worktree. Fall back
# to project dir, then pwd, when the payload omits cwd.
cwd=$(echo "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
cd "${cwd:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"

upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo "origin/main")
diff_files=$(git diff --name-only "${upstream}"..HEAD 2>/dev/null || git diff --name-only HEAD)

flux_hits=$(echo "$diff_files" | grep -E '^(apps|infrastructure|monitoring|clusters)/' || true)

[[ -z "$flux_hits" ]] && exit 0

# Skip doc-only changes within Flux paths.
non_doc=$(echo "$flux_hits" | grep -Ev '(^|/)(README\.md$|docs/|.*\.md$)' || true)
[[ -z "$non_doc" ]] && exit 0

# Skip trivial diffs (<20 lines changed across non-doc Flux files).
mapfile -t non_doc_files <<<"$non_doc"
changed_lines=$(git diff --numstat "${upstream}"..HEAD -- "${non_doc_files[@]}" 2>/dev/null \
  | awk '{a+=$1; d+=$2} END {print a+d+0}')
[[ "${changed_lines:-0}" -lt 20 ]] && exit 0

# Resolve git-dir (the per-worktree dir in a linked worktree, .git in the main
# tree) so the marker path matches cavecrew-mark.sh's writer in BOTH trees. A
# hardcoded ".git/" breaks in a worktree, where .git is a file, not a dir.
gitdir=$(git rev-parse --git-dir 2>/dev/null || echo .git)
marker="${gitdir}/.cavecrew-reviewed-$(git rev-parse HEAD 2>/dev/null || echo none)"
[[ -f "$marker" ]] && exit 0

non_doc_indented="    ${non_doc//$'\n'/$'\n'    }"

cat >&2 <<EOF
[cavecrew] git push touches Flux-managed paths. Run cavecrew-reviewer subagent on diff first:

  Files:
$non_doc_indented

  Action: invoke Task tool with subagent_type=caveman:cavecrew-reviewer, model=sonnet, on the diff.
  (model=sonnet per-call override: agent frontmatter defaults to haiku, too weak for the
   semantic invariant bug-classes below; per-call leaves plugin body live, no shadow/drift.)
  Reviewer auto-reads CLAUDE.md -> .claude/review-invariants.md (semantic checks CI misses).
  Address findings, then run ~/.claude/hooks/cavecrew-mark.sh (from this worktree) and retry push.
  Bypass: CAVECREW_SKIP=1 git push ...
EOF

exit 2
