#!/usr/bin/env bash
# kb-hygiene — sweep files for leaked subagent tool-call tags (</content>, </invoke>, antml:*).
# A dispatched subagent writing via Write can leak its closing tags into a file tail; a lossless
# token-checklist is BLIND to trailing junk (it greps presence, not stray tags). Always run this
# on subagent-written files before trusting/committing.
# Uses grep (NOT rg — rg is a shell function in this env, absent from non-interactive script PATH).
# Usage: tag-leak-sweep.sh [PATH ...]   (default: ~/.agents/skills)
# Exit: 0 clean | 1 leaked tags found
set -euo pipefail

paths=("$@")
if [[ "${#paths[@]}" -eq 0 ]]; then paths=("$HOME/.agents/skills"); fi

# A leaked tag is ALWAYS alone on its own line (a Write-tool artifact). Doc mentions of the tag sit
# inline in prose / inside backticks — anchor to standalone lines so we don't flag documentation.
pat='^[[:space:]]*</?antml:|^[[:space:]]*</?(content|invoke|parameter|function)>[[:space:]]*$'

if grep -rnE --include='*.md' "$pat" "${paths[@]}"; then
  echo "^^ LEAKED TOOL-CALL TAGS — strip before commit" >&2
  exit 1
fi
echo "clean — no leaked tool-call tags"
exit 0
