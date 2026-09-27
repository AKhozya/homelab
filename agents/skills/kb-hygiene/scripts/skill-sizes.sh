#!/usr/bin/env bash
# kb-hygiene token-efficiency lens — live SKILL.md word + line counts (a SKILL.md loads in full on
# EVERY fire, so fat ones are the real token lever). Replaces hardcoded word-count lists, which drift.
# WORDS drives the FAT flag (truer token proxy); LINES is shown too — they diverge (code-block-heavy
# skills run high lines / low words; dense prose+tables run high words / low lines).
# Uses find (NOT fd — coreutils-only for zero-dependency robustness in non-interactive script PATH).
# Flags any SKILL.md over THRESHOLD as a relocate candidate (push situational detail to
# reference-*.md / scripts). Sorted heaviest first.
# Usage: skill-sizes.sh [SKILLS_ROOT] [THRESHOLD_WORDS]
# Exit: 0 (2 on bad ROOT)
set -euo pipefail

ROOT="${1:-$HOME/.agents/skills}"
THRESH="${2:-1000}"
[[ -d "$ROOT" ]] || {
  echo "no such dir: $ROOT" >&2
  exit 2
}

printf '%6s %6s  %-28s %s\n' WORDS LINES SKILL FLAG
while IFS= read -r f; do
  printf '%s\t%s\t%s\n' "$(wc -w <"$f" | tr -d ' ')" "$(wc -l <"$f" | tr -d ' ')" "$(basename "$(dirname "$f")")"
done < <(find "$ROOT" -type f -name SKILL.md) |
  sort -rn |
  awk -v t="$THRESH" '{flag=($1>t)?"FAT -> relocate situational detail":""; printf "%6s %6s  %-28s %s\n",$1,$2,$3,flag}'
exit 0
