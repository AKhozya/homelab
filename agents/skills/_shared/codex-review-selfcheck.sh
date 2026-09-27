#!/usr/bin/env bash
set -euo pipefail

# Checks codex-review.sh against stub codex and hygiene executables, so no real
# review is dispatched.
#
# The stdin case matters most. This script feeds the wrapper a pipe that never
# reaches EOF, matching the socket an agent harness supplies. If the wrapper
# drops `</dev/null`, the stub sees open stdin and the case fails.

here="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
target="$here/codex-review.sh"
[[ -f "$target" ]] || {
  echo "no codex-review.sh next to this script" >&2
  exit 2
}

tmp="$(mktemp -d -t codex-review-selfcheck)"
blocker=""
cleanup() {
  [[ -n "$blocker" ]] && kill "$blocker" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/bin"
run="$tmp/bin/codex-review.sh"
cp "$target" "$run"
chmod 755 "$run"
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/bin/codex-hygiene.sh"
chmod 755 "$tmp/bin/codex-hygiene.sh"
printf 'diff content\n' >"$tmp/diff.txt"
printf 'review instructions\n' >"$tmp/prompt.txt"
: >"$tmp/empty.txt"
# Untouched references, so an alias case can prove the input is byte-identical.
printf 'diff content\n' >"$tmp/ref-diff.txt"
printf 'review instructions\n' >"$tmp/ref-prompt.txt"

# A writer holding this FIFO open gives the wrapper a stdin that never ends.
mkfifo "$tmp/never-eof"
sleep 600 >"$tmp/never-eof" &
blocker=$!

export PATH="$tmp/bin:$PATH"

pass=0
fail=0
check() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    printf 'ok   %-40s %s\n' "$name" "$got"
    pass=$((pass + 1))
  else
    printf 'FAIL %-40s want=%s got=%s\n' "$name" "$want" "$got"
    fail=$((fail + 1))
  fi
}

# $1 exit code for the stub, $2 reply text it writes, empty for none
mkstub() {
  cat >"$tmp/bin/codex" <<EOF
#!/usr/bin/env bash
echo called >> "$tmp/calls"
if IFS= read -r -t 2 _line; then
  echo open > "$tmp/stdin-state"
elif [ \$? -gt 128 ]; then
  echo blocked > "$tmp/stdin-state"
else
  echo eof > "$tmp/stdin-state"
fi
printf '%s\n' "\$@" > "$tmp/argv"
out=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$2" ] && printf '%s\n' "$2" > "\$out"
exit $1
EOF
  chmod 755 "$tmp/bin/codex"
  : >"$tmp/calls"
}

# Assert an option and its value are adjacent, so a swap cannot pass.
argpair() {
  grep -A1 -x -- "$1" "$tmp/argv" 2>/dev/null | tail -n1 | grep -qx -- "$2" && echo yes || echo no
}

invoke() { "$run" "$@" <"$tmp/never-eof"; }

# 1. Dispatch succeeds and stdin is closed.
mkstub 0 "VERDICT: APPROVE"
out=$(invoke --diff "$tmp/diff.txt" --prompt "$tmp/prompt.txt" --out "$tmp/out.txt" 2>/dev/null) && rc=0 || rc=$?
check "dispatch rc" 0 "$rc"
check "verdict returned" "VERDICT: APPROVE" "$out"
check "wrapper closed stdin" "eof" "$(cat "$tmp/stdin-state" 2>/dev/null)"

# 2. The flags that keep the reply parseable must reach codex, paired correctly.
check "argv --sandbox read-only" yes "$(argpair --sandbox read-only)"
check "argv --color never" yes "$(argpair --color never)"
check "argv -o names the out file" yes "$(argpair -o "$tmp/out.txt")"
grep -q "cat $tmp/diff.txt" "$tmp/argv" && r=yes || r=no
check "prompt names the one cat" yes "$r"
grep -q 'review instructions' "$tmp/argv" && r=yes || r=no
check "prompt carries caller text" yes "$r"
# The reply check accepts one closed set of verdict tokens. If the prompt stops
# naming that set, Codex answers in its own vocabulary and a real review exits 3
# as if the run had died.
grep -q 'VERDICT: <one of: APPROVE, APPROVE-WITH-NITS, REQUEST-CHANGES, PROCEED, PROCEED-WITH-CHANGES, DO-NOT-PROCEED>' "$tmp/argv" && r=yes || r=no
check "prompt states the accepted verdicts" yes "$r"

# 3. Replies that are not a usable verdict.
mkstub 0 "VERDICT: BANANA"
invoke --diff "$tmp/diff.txt" --prompt "$tmp/prompt.txt" --out "$tmp/out.txt" >/dev/null 2>&1 && rc=0 || rc=$?
check "off-enum verdict rc" 3 "$rc"

mkstub 0 "I could not review this."
invoke --diff "$tmp/diff.txt" --prompt "$tmp/prompt.txt" --out "$tmp/out.txt" >/dev/null 2>&1 && rc=0 || rc=$?
check "refusal rc" 3 "$rc"

# A failed run can still flush a good first line. Process status decides.
mkstub 1 "VERDICT: APPROVE"
invoke --diff "$tmp/diff.txt" --prompt "$tmp/prompt.txt" --out "$tmp/out.txt" >/dev/null 2>&1 && rc=0 || rc=$?
check "codex failure with verdict rc" 3 "$rc"

# 4. A reply left by an earlier run must not count.
mkstub 0 ""
printf 'VERDICT: APPROVE\n' >"$tmp/stale.txt"
invoke --diff "$tmp/diff.txt" --prompt "$tmp/prompt.txt" --out "$tmp/stale.txt" >/dev/null 2>&1 && rc=0 || rc=$?
check "stale reply file rc" 3 "$rc"

# 5. Input guards. Each must reject before codex is called.
guard() {
  local name="$1" want="$2"
  shift 2
  mkstub 0 "VERDICT: APPROVE"
  # Restore the inputs, so a case that wrongly empties one cannot make later
  # cases pass for the wrong reason.
  printf 'diff content\n' >"$tmp/diff.txt"
  printf 'review instructions\n' >"$tmp/prompt.txt"
  invoke "$@" >/dev/null 2>&1 && rc=0 || rc=$?
  check "$name rc" "$want" "$rc"
  check "$name calls no codex" 0 "$(wc -l <"$tmp/calls" | tr -d ' ')"
}
guard "missing --diff" 2 --prompt "$tmp/prompt.txt"
guard "empty --diff" 2 --diff "$tmp/empty.txt" --prompt "$tmp/prompt.txt"
guard "empty --prompt" 2 --diff "$tmp/diff.txt" --prompt "$tmp/empty.txt"
guard "bad --cd" 2 --diff "$tmp/diff.txt" --prompt "$tmp/prompt.txt" --cd "$tmp/nope"
guard "non-numeric --deadline" 2 --diff "$tmp/diff.txt" --prompt "$tmp/prompt.txt" --deadline abc
# GNU timeout reads 0 as no limit, so it must not be accepted.
guard "zero --deadline" 2 --diff "$tmp/diff.txt" --prompt "$tmp/prompt.txt" --deadline 0
guard "valued option with no value" 2 --diff "$tmp/diff.txt" --prompt
# If an output names an input, the run must stop AND leave the input intact.
# If the wrapper truncates before it rejects, the caller loses the file.
# -s alone passes for any non-empty overwrite. Command substitution strips
# trailing newlines, so it cannot compare bytes either. cmp reads the files.
alive() { cmp -s -- "$1" "$2" && echo yes || echo no; }
guard "--out aliases --diff" 2 --diff "$tmp/diff.txt" --prompt "$tmp/prompt.txt" --out "$tmp/diff.txt"
check "aliased --diff survives" yes "$(alive "$tmp/diff.txt" "$tmp/ref-diff.txt")"
guard "--log aliases --prompt" 2 --diff "$tmp/diff.txt" --prompt "$tmp/prompt.txt" --log "$tmp/prompt.txt"
check "aliased --prompt survives" yes "$(alive "$tmp/prompt.txt" "$tmp/ref-prompt.txt")"
ln -s "$tmp/diff.txt" "$tmp/diff-link.txt"
guard "--out symlinks --diff" 2 --diff "$tmp/diff.txt" --prompt "$tmp/prompt.txt" --out "$tmp/diff-link.txt"
check "symlinked --diff survives" yes "$(alive "$tmp/diff.txt" "$tmp/ref-diff.txt")"
ln "$tmp/diff.txt" "$tmp/diff-hard.txt"
guard "--out hard-links --diff" 2 --diff "$tmp/diff.txt" --prompt "$tmp/prompt.txt" --out "$tmp/diff-hard.txt"
check "hard-linked --diff survives" yes "$(alive "$tmp/diff.txt" "$tmp/ref-diff.txt")"
mkfifo "$tmp/fifo.out"
guard "--out is a fifo" 2 --diff "$tmp/diff.txt" --prompt "$tmp/prompt.txt" --out "$tmp/fifo.out"

# 6. If the hygiene sweep is missing, stop before dispatching.
mkstub 0 "VERDICT: APPROVE"
mv "$tmp/bin/codex-hygiene.sh" "$tmp/hygiene.hidden"
invoke --diff "$tmp/diff.txt" --prompt "$tmp/prompt.txt" >/dev/null 2>&1 && rc=0 || rc=$?
check "missing hygiene sweep rc" 2 "$rc"
check "missing hygiene calls no codex" 0 "$(wc -l <"$tmp/calls" | tr -d ' ')"
mv "$tmp/hygiene.hidden" "$tmp/bin/codex-hygiene.sh"

# 7. The deadline stops a process that ignores TERM.
cat >"$tmp/bin/codex" <<EOF
#!/usr/bin/env bash
echo called >> "$tmp/calls"
trap '' TERM
sleep 60
EOF
chmod 755 "$tmp/bin/codex"
: >"$tmp/calls"
printf 'diff content\n' >"$tmp/diff.txt"
printf 'review instructions\n' >"$tmp/prompt.txt"
# If -k is absent, timeout signals at the deadline and then waits for the child.
# If that child exits without KILL, timeout still reports 124. The elapsed time
# is the only thing that separates the two cases.
started=$(date +%s)
invoke --diff "$tmp/diff.txt" --prompt "$tmp/prompt.txt" --deadline 2 >/dev/null 2>&1 && rc=0 || rc=$?
elapsed=$(($(date +%s) - started))
check "deadline rc against a TERM-proof run" 124 "$rc"
check "deadline dispatched once" 1 "$(wc -l <"$tmp/calls" | tr -d ' ')"
# If the wrapper errors early, it never dispatches. The lower bound rejects
# that path. If timeout signals and then waits for the child, the upper bound
# rejects that path.
check "deadline kills between 2s and 20s" yes "$([[ $elapsed -ge 2 && $elapsed -le 20 ]] && echo yes || echo no)"

# 8. If the hygiene sweep ignores TERM, the run must still start on time.
# Sleep past the sweep's 60s limit plus its 10s grace. If the sleep is shorter
# than that sum, both variants finish together. The case then passes either
# way.
printf '#!/usr/bin/env bash\ntrap "" TERM\nsleep 300\n' >"$tmp/bin/codex-hygiene.sh"
chmod 755 "$tmp/bin/codex-hygiene.sh"
mkstub 0 "VERDICT: APPROVE"
started=$(date +%s)
invoke --diff "$tmp/diff.txt" --prompt "$tmp/prompt.txt" >/dev/null 2>&1 && rc=0 || rc=$?
elapsed=$(($(date +%s) - started))
check "TERM-proof sweep is bounded" yes "$([[ $elapsed -ge 60 && $elapsed -le 120 ]] && echo yes || echo no)"
check "TERM-proof sweep stops the run" 2 "$rc"
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/bin/codex-hygiene.sh"
chmod 755 "$tmp/bin/codex-hygiene.sh"

# 9. GNU stat reads -f as --file-system and reports the volume, so every file on
# one disk would carry the same identity. Emulate GNU stat and require the
# wrapper to keep telling two files apart.
cat >"$tmp/bin/stat" <<'STATEOF'
#!/usr/bin/env bash
mode=""
args=()
while [ $# -gt 0 ]; do
  case "$1" in
  -L) shift ;;
  -c)
    mode=c
    shift 2
    ;;
  -f)
    mode=f
    shift 2
    ;;
  --) shift ;;
  *)
    args+=("$1")
    shift
    ;;
  esac
done
if [ "$mode" = c ]; then
  printf 'dev:%s\n' "$(/usr/bin/stat -L -f '%i' -- "${args[0]}")"
else
  printf 'ONE-FILESYSTEM\n'
fi
STATEOF
chmod 755 "$tmp/bin/stat"
mkstub 0 "VERDICT: APPROVE"
printf 'diff content\n' >"$tmp/diff.txt"
printf 'review instructions\n' >"$tmp/prompt.txt"
invoke --diff "$tmp/diff.txt" --prompt "$tmp/prompt.txt" --out "$tmp/gnu.out" >/dev/null 2>&1 && rc=0 || rc=$?
check "GNU stat: distinct files still run" 0 "$rc"
guard "GNU stat: alias still rejected" 2 --diff "$tmp/diff.txt" --prompt "$tmp/prompt.txt" --out "$tmp/diff.txt"
check "GNU stat: aliased --diff survives" yes "$(alive "$tmp/diff.txt" "$tmp/ref-diff.txt")"
rm -f "$tmp/bin/stat"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
