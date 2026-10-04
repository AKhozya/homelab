#!/usr/bin/env bash
# Lossless gate: verify that the tokens extracted from OLD still occur across the NEW file(s).
# Extracts SHAs, filenames, long flags, :ports, #issue-refs, and `backtick spans` from OLD, then
# greps each across ALL NEW files. Reports LOST = a candidate dropped fact; a prose word might be
# an intentional cut. Also runs the tag-leak sweep on NEW.
# grep, not rg: rg is a Homebrew binary, and a script run with a minimal PATH does not find it.
# Usage: lossless-verify.sh OLD NEW [NEW ...]
# Exit: 0 all present + no leaks | 1 LOST tokens or leaked tags | 2 bad args
set -euo pipefail

[[ "$#" -ge 2 ]] || {
  echo "usage: lossless-verify.sh OLD NEW [NEW ...]" >&2
  exit 2
}
OLD="$1"
shift
NEW=("$@")
[[ -f "$OLD" ]] || {
  echo "no such OLD: $OLD" >&2
  exit 2
}
for f in "${NEW[@]}"; do
  [[ -f "$f" ]] || {
    echo "no such NEW: $f" >&2
    exit 2
  }
done

extract() {
  local f="$1"
  {
    grep -hoE '[0-9a-f]{7,40}' "$f" | grep -E '[a-f]' || true              # SHAs (must hold a hex letter)
    grep -hoE '[A-Za-z0-9_.-]+\.(sh|ya?ml|md|json|mjs|ts|js)' "$f" || true # filenames
    grep -hoE -- '--[a-z][a-z0-9-]{2,}' "$f" || true                       # long flags
    grep -hoE ':[0-9]{2,5}' "$f" || true                                   # :ports
    grep -hoE '#[0-9]{2,5}' "$f" || true                                   # issue refs
    # shellcheck disable=SC2016  # literal backticks match `code spans`, not command substitution
    grep -hoE '`[^`]+`' "$f" | sed 's/`//g' || true # backtick span contents
  } | sort -u
}

lost=0
total=0
while IFS= read -r t; do
  if [[ -z "$t" ]]; then continue; fi
  total=$((total + 1))
  if ! grep -qF -- "$t" "${NEW[@]}"; then
    echo "  LOST: $t"
    lost=$((lost + 1))
  fi
done < <(extract "$OLD")
if [[ "$lost" -eq 0 ]]; then echo "lossless: all $total candidate tokens present in NEW"; fi

leak=0
# leaked tag = alone on its own line (Write-tool artifact); anchor so doc mentions aren't flagged
pat='^[[:space:]]*</?antml:|^[[:space:]]*</?(content|invoke|parameter|function)>[[:space:]]*$'
if grep -nE "$pat" "${NEW[@]}" >/dev/null 2>&1; then
  echo "  TAG-LEAK in NEW:" >&2
  grep -nE "$pat" "${NEW[@]}" >&2 || true
  leak=1
fi

if [[ "$lost" -gt 0 ]]; then
  echo "review the LOST list — SHAs/ports/flags/filenames almost never are intentional cuts" >&2
fi
if [[ "$lost" -gt 0 || "$leak" -gt 0 ]]; then exit 1; fi
exit 0
