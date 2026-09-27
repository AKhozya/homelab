#!/usr/bin/env bash
# kb-hygiene — lint every skill shell script: shellcheck + shfmt + rg-in-scripts audit.
# Corpus-wide .sh counterpart to skill-sizes.sh (which sizes SKILL.md). Catches the three cross-skill
# failure modes: unlinted scripts, unformatted scripts, and `rg` used as a COMMAND inside a script
# (rg is a shell function here, absent from non-interactive script PATH → silent failure; bash-scripting §7).
# Uses grep/find (NOT rg — same reason).
# Usage: lint-skill-scripts.sh [SKILLS_ROOT]
# Exit: 0 all clean | 1 lint/format/rg issue found | 2 bad args / missing tool
set -euo pipefail

ROOT="${1:-$HOME/.agents/skills}"
[[ -d "$ROOT" ]] || {
  echo "no such dir: $ROOT" >&2
  exit 2
}
command -v shellcheck >/dev/null || {
  echo "shellcheck not installed" >&2
  exit 2
}
command -v shfmt >/dev/null || {
  echo "shfmt not installed" >&2
  exit 2
}

sc_fail=0
fmt_fail=0
rg_fail=0

echo "== shellcheck =="
while IFS= read -r f; do
  # -x follows `# shellcheck source=` directives; -P SCRIPTDIR resolves them relative
  # to each script's own dir (default is CWD → every sourced _shared helper would trip
  # info-level SC1091 and read as a corpus FAIL).
  if ! out="$(shellcheck -x -P SCRIPTDIR "$f" 2>&1)"; then
    echo "  FAIL: $f"
    while IFS= read -r l; do echo "    $l"; done <<<"$out"
    sc_fail=$((sc_fail + 1))
  fi
done < <(find "$ROOT" -type f -name '*.sh')
if [[ "$sc_fail" -eq 0 ]]; then echo "  all clean"; fi

echo "== shfmt (canonical -i 2) =="
while IFS= read -r f; do
  if ! shfmt -i 2 -d "$f" >/dev/null 2>&1; then
    echo "  UNFORMATTED: $f  (fix: shfmt -i 2 -w '$f')"
    fmt_fail=$((fmt_fail + 1))
  fi
done < <(find "$ROOT" -type f -name '*.sh')
if [[ "$fmt_fail" -eq 0 ]]; then echo "  all formatted"; fi

echo "== rg-as-command (rg is a shell fn, breaks non-interactively — use grep; bash-scripting §7) =="
while IFS= read -r line; do
  echo "  RG-CALL: $line"
  rg_fail=$((rg_fail + 1))
done < <(grep -rnE '(^[[:space:]]*|[;&|][[:space:]]*|\$\()rg[[:space:]]' --include='*.sh' "$ROOT" | grep -vE ':[0-9]+:[[:space:]]*#' || true)
if [[ "$rg_fail" -eq 0 ]]; then echo "  none"; fi

echo
echo "summary: shellcheck-fail=$sc_fail unformatted=$fmt_fail rg-calls=$rg_fail"
if [[ "$sc_fail" -gt 0 || "$fmt_fail" -gt 0 || "$rg_fail" -gt 0 ]]; then exit 1; fi
exit 0
