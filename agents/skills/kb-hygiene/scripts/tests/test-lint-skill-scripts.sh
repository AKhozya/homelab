#!/usr/bin/env bash
# Asserts that lint-skill-scripts.sh skips vendored skills and still fails on the others. Pass the
# script under test as the first argument to run an older copy and watch which assertions it fails.
# Usage: test-lint-skill-scripts.sh [SCRIPT_UNDER_TEST]
# Exit: 0 every assertion holds | 1 any assertion failed
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${1:-$HERE/../lint-skill-scripts.sh}"
[[ -f "$SUT" ]] || {
  echo "no such script: $SUT" >&2
  exit 1
}

FIX="$(mktemp -d)"
trap 'chmod -R u+rw "$FIX"; rm -rf "$FIX"' EXIT
fails=0

fail() {
  printf 'FAIL  %s\n' "$1"
  fails=$((fails + 1))
}
ok() { printf 'ok    %s\n' "$1"; }
check() { # check <label> <got> <want>
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1: got '$2', want '$3'"; fi
}
run() { # run <root>: sets rc and out
  rc=0
  out="$(bash "$SUT" "$1" 2>&1)" || rc=$?
}

# An unformatted script with an unused variable fails both shellcheck and shfmt -i 2. It also
# calls rg, and has a commented rg call that the audit must ignore. The %s placeholders keep
# the rg patterns out of this file, which the linter itself scans.
bad() { # bad <skill>
  mkdir -p "$FIX/skills/$1/scripts"
  printf '#!/usr/bin/env bash\nunused=1\nif true; then\n    %s x .\nfi\n# a %s y .\n' rg '| rg' >"$FIX/skills/$1/scripts/bad.sh"
}

# If the lock and markers are absent, the vendored list is empty and owned scripts must still be linted.
bad own
run "$FIX/skills"
check "no lock: exit" "$rc" 1
check "no lock: counted" "$(grep -c 'summary: shellcheck-fail=1 unformatted=1 rg-calls=1$' <<<"$out")" 1
run "$FIX/skills//"
check "no lock, doubled slash on ROOT: exit" "$rc" 1
rm -rf "$FIX/skills/own"

bad locked
bad marked
bad .hidden
touch "$FIX/skills/marked/.INSTALLED-FROM.txt" "$FIX/skills/.hidden/.INSTALLED-FROM.txt"
printf '{"skills":{"locked":{"source":"someone/skills"}}}\n' >"$FIX/.skill-lock.json"

run "$FIX/skills"
check "vendored only: exit" "$rc" 0
check "vendored only: 3 skipped" "$(grep -c 'skipping 3 vendored skills' <<<"$out")" 1

run "$FIX/skills//"
check "doubled trailing slash on ROOT: exit" "$rc" 0

bad own
run "$FIX/skills"
check "own skill: exit" "$rc" 1
check "own skill: counted once each" "$(grep -c 'summary: shellcheck-fail=1 unformatted=1 rg-calls=1$' <<<"$out")" 1
check "own skill: the rg call is reported" "$(grep -c 'RG-CALL: .*own/scripts/bad.sh:4: ' <<<"$out")" 1
check "own skill: the commented rg is not" "$(grep -c 'RG-CALL: .*bad.sh:6:' <<<"$out")" 0

run "$FIX/skills//"
check "own skill, doubled slash on ROOT: exit" "$rc" 1

printf '{"skills":' >"$FIX/.skill-lock.json"
run "$FIX/skills"
check "malformed lock: exit" "$rc" 2
printf ' \n' >"$FIX/.skill-lock.json"
run "$FIX/skills"
check "blank lock: exit" "$rc" 2
printf '{"skills":{}}\n' >"$FIX/.skill-lock.json"
run "$FIX/skills"
check "lock with no skills: exit" "$rc" 1

chmod a-rwx "$FIX/.skill-lock.json"
run "$FIX/skills"
check "unreadable lock: exit" "$rc" 2

[[ "$fails" -eq 0 ]] || exit 1
