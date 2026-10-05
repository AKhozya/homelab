#!/usr/bin/env bash
# Tests for merge-worktree.sh. Real git against a throwaway bare repo that represents the GitHub
# remote, and a fake
# gh (gh-stub.sh) that keeps PRs in a JSON file. No network, no TTY.
# Usage: test-merge-worktree.sh [path-to-merge-worktree.sh]
# shellcheck disable=SC2016,SC2034,SC2329  # check() bodies are single-quoted eval strings that call these helpers
set -euo pipefail
# Test commits must not reach the signing agent; the merge commits the stub makes inherit this too.
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=tag.gpgsign GIT_CONFIG_VALUE_1=false
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED="$HERE/../../../_shared"
SUT="${1:-$SHARED/merge-worktree.sh}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0

# One case = fresh origin, primary clone, one worktree branch with one commit.
setup() { # case-name
  C="$T/$1"
  mkdir -p "$C/bin" "$C/skills/_shared" "$C/ghs"
  cp "$SUT" "$C/skills/_shared/merge-worktree.sh"
  cp "$SHARED/worktree-cleanup.sh" "$C/skills/_shared/worktree-cleanup.sh" 2>/dev/null || true
  cp "$HERE/gh-stub.sh" "$C/bin/gh"
  chmod +x "$C/bin/gh" "$C/skills/_shared/"*.sh
  echo '[]' >"$C/ghs/prs.json"
  echo pass >"$C/ghs/checks_seq"
  git init -q --bare -b main "$C/origin.git"
  git clone -q "$C/origin.git" "$C/seed" 2>/dev/null
  git -C "$C/seed" commit -q --allow-empty -m base
  git -C "$C/seed" push -q origin HEAD:main
  git clone -q "$C/origin.git" "$C/primary"
  add_branch wt-a
}
add_branch() { # branch
  git -C "$C/primary" worktree add -q "$C/$1" -b "$1" 2>/dev/null
  echo "$1" >"$C/$1/$1.txt"
  git -C "$C/$1" add "$1.txt"
  git -C "$C/$1" commit -q -m "change on $1"
}
run() { # branch [args...] -> sets RC, OUT
  local b="$1"
  shift
  RC=0
  OUT="$(cd "$C/$b" && PATH="$C/bin:$PATH" GHS="$C/ghs" ORIGIN="$C/origin.git" MW_POLL_SECONDS=0 \
    MW_LOCK_WAIT_SECONDS=2 bash "$C/skills/_shared/merge-worktree.sh" "$b" "$@" 2>&1)" || RC=$?
}
check() { # description, command...
  local d="$1"
  shift
  if "$@"; then echo "PASS $d"; else
    echo "FAIL $d"
    [ -z "${OUT:-}" ] || printf '      %s\n' "$OUT" | sed -n '1,6p'
    fail=1
  fi
}
on_main() { git --git-dir="$C/origin.git" merge-base --is-ancestor "$(git -C "$C/primary" rev-parse "$1")" main; }
primary_synced() { [ "$(git -C "$C/primary" rev-parse HEAD)" = "$(git --git-dir="$C/origin.git" rev-parse main)" ]; }
merge_commit_on_main() { [ "$(git --git-dir="$C/origin.git" rev-list --merges --count main)" -ge 1 ]; }
calls() { grep -c -- "$1" "$C/ghs/calls" 2>/dev/null || true; }
pr_state() { jq -r '.[] | select(.number == 100) | .state' "$C/ghs/prs.json"; }

setup green
printf 'none\npending\npass\n' >"$C/ghs/checks_seq"
run wt-a
check "green: exit 0" test "$RC" = 0
check "green: branch on main through a merge commit" eval 'on_main wt-a && merge_commit_on_main'
check "green: primary synced" primary_synced
check "green: PR merged" test "$(pr_state)" = MERGED

setup failcheck
printf 'pending\nfail\n' >"$C/ghs/checks_seq"
run wt-a
check "failing check: exit 1" test "$RC" = 1
check "failing check: no merge call" test "$(calls 'pr merge')" = 0
check "failing check: PR left open" test "$(pr_state)" = OPEN

setup skip
echo skipping >"$C/ghs/checks_seq"
run wt-a
check "skipped check: exit 1, no merge" eval 'test "$RC" = 1 && test "$(calls "pr merge")" = 0'

setup dup
echo dup >"$C/ghs/checks_seq"
run wt-a
check "re-run check listed twice: exit 0" test "$RC" = 0

setup apierr
printf 'garbage\ngarbage\npass\n' >"$C/ghs/checks_seq"
run wt-a
check "two API errors then green: exit 0" test "$RC" = 0
setup apierr3
echo garbage >"$C/ghs/checks_seq"
run wt-a
check "three API errors in a row: exit 1, no merge" eval 'test "$RC" = 1 && test "$(calls "pr merge")" = 0'

setup timeout
echo pending >"$C/ghs/checks_seq"
RC=0
OUT="$(cd "$C/wt-a" && PATH="$C/bin:$PATH" GHS="$C/ghs" ORIGIN="$C/origin.git" MW_POLL_SECONDS=0.2 \
  bash "$C/skills/_shared/merge-worktree.sh" wt-a --timeout 1 2>&1)" || RC=$?
check "timeout: exit 1, PR left open" eval 'test "$RC" = 1 && test "$(pr_state)" = OPEN'

setup timeoutmerged
echo merge_now >"$C/ghs/checks_seq"
RC=0
OUT="$(cd "$C/wt-a" && PATH="$C/bin:$PATH" GHS="$C/ghs" ORIGIN="$C/origin.git" MW_POLL_SECONDS=2 \
  bash "$C/skills/_shared/merge-worktree.sh" wt-a --timeout 1 2>&1)" || RC=$?
check "another session merges as the wait times out: exit 0, synced" eval 'test "$RC" = 0 && on_main wt-a && primary_synced'

for form in "https://github.com/own/rep.git" "git@github.com:own/rep.git" "gh-homelab:own/rep.git"; do
  setup "bot-${form%%:*}"
  touch "$C/ghs/noauth"
  git -C "$C/primary" config "url.$C/origin.git.insteadOf" "$form"
  git -C "$C/primary" remote set-url origin "$form"
  run wt-a
  check "no GitHub login ($form): exit 4" test "$RC" = 4
  check "no GitHub login ($form): branch pushed" test "$(git --git-dir="$C/origin.git" rev-parse -q --verify refs/heads/wt-a)" = "$(git -C "$C/primary" rev-parse wt-a)"
  check "no GitHub login ($form): only the auth call" test "$(grep -vc '^auth status' "$C/ghs/calls")" = 0
  check "no GitHub login ($form): full compare URL" grep -qx 'Open and merge it: https://github.com/own/rep/compare/main...wt-a' <<<"$OUT"
done

setup reuse
git -C "$C/wt-a" push -q origin wt-a
jq --arg sha "$(git -C "$C/primary" rev-parse wt-a)" '. + [{number: 100, state: "OPEN", headRefName: "wt-a", headRefOid: $sha, isCrossRepository: false, mergeCommit: null}]' "$C/ghs/prs.json" >"$C/x" && mv "$C/x" "$C/ghs/prs.json"
run wt-a
check "open PR reused: exit 0, no create" eval 'test "$RC" = 0 && test "$(calls "pr create")" = 0'

setup closed
jq --arg sha "$(git -C "$C/primary" rev-parse wt-a)" '. + [{number: 100, state: "CLOSED", headRefName: "wt-a", headRefOid: $sha, isCrossRepository: false, mergeCommit: null}]' "$C/ghs/prs.json" >"$C/x" && mv "$C/x" "$C/ghs/prs.json"
run wt-a
check "closed PR with this tip: exit 1, nothing pushed" eval 'test "$RC" = 1 && ! git --git-dir="$C/origin.git" rev-parse -q --verify refs/heads/wt-a >/dev/null'

setup oldpr
jq '. + [{number: 100, state: "CLOSED", headRefName: "wt-a", headRefOid: "1111111111111111111111111111111111111111", isCrossRepository: false, mergeCommit: null}, {number: 101, state: "MERGED", headRefName: "wt-a", headRefOid: "2222222222222222222222222222222222222222", isCrossRepository: false, mergeCommit: {oid: "x"}}]' "$C/ghs/prs.json" >"$C/x" && mv "$C/x" "$C/ghs/prs.json"
run wt-a
check "old PRs on a reused branch name are ignored: exit 0" test "$RC" = 0

setup headmoved
echo deadbeefdeadbeefdeadbeefdeadbeefdeadbeef >"$C/ghs/head_override"
echo pending >"$C/ghs/checks_seq"
run wt-a --timeout 30
check "someone else pushed the branch: exit 1 for that reason, no merge" eval 'test "$RC" = 1 && test "$(calls "pr merge")" = 0 && grep -q "someone else pushed" <<<"$OUT"'

setup conflict
touch "$C/ghs/conflicting"
echo pending >"$C/ghs/checks_seq"
run wt-a
check "conflicting PR: exit 1 at once" eval 'test "$RC" = 1 && test "$(calls "pr checks")" = 0'

setup diverged
git clone -q "$C/origin.git" "$C/other"
git -C "$C/other" checkout -q -b wt-a
git -C "$C/other" commit -q --allow-empty -m "someone else's commit"
git -C "$C/other" push -q origin wt-a
run wt-a
check "remote branch diverged: exit 1, remote commit kept" eval 'test "$RC" = 1 && test "$(git --git-dir="$C/origin.git" log -1 --format=%s refs/heads/wt-a)" = "someone else'"'"'s commit"'

setup advance
printf 'advance\npass\n' >"$C/ghs/checks_seq"
run wt-a
check "main moved during the wait: exit 0, merged, synced" eval 'test "$RC" = 0 && on_main wt-a && primary_synced'

setup rerun
run wt-a
first="$RC"
run wt-a
check "second run after success: exit 0, one create in total" eval 'test "$first" = 0 && test "$RC" = 0 && test "$(calls "pr create")" = 1'

setup ahead
git -C "$C/primary" commit -q --allow-empty -m "local only"
run wt-a
check "primary has a local commit: exit 3 for that reason, commit kept" eval 'test "$RC" = 3 && grep -q "commits origin/main lacks" <<<"$OUT" && test "$(git -C "$C/primary" log -1 --format=%s)" = "local only"'
check "primary has a local commit: change still merged" on_main wt-a

setup samebranch
printf 'pending\npending\npass\n' >"$C/ghs/checks_seq"
(cd "$C/wt-a" && PATH="$C/bin:$PATH" GHS="$C/ghs" ORIGIN="$C/origin.git" MW_POLL_SECONDS=0.1 bash "$C/skills/_shared/merge-worktree.sh" wt-a >"$C/o1" 2>&1) &
p1=$!
(cd "$C/wt-a" && PATH="$C/bin:$PATH" GHS="$C/ghs" ORIGIN="$C/origin.git" MW_POLL_SECONDS=0.1 bash "$C/skills/_shared/merge-worktree.sh" wt-a >"$C/o2" 2>&1) &
p2=$!
r1=0
wait "$p1" || r1=$?
r2=0
wait "$p2" || r2=$?
OUT="$(cat "$C/o1" "$C/o2")"
check "two runs on one branch at once: both exit 0, one PR, merged once" eval 'test "$r1" = 0 && test "$r2" = 0 && test "$(jq length "$C/ghs/prs.json")" = 1 && test "$(pr_state)" = MERGED && test "$(git --git-dir="$C/origin.git" rev-list --merges --count main)" = 1 && on_main wt-a && primary_synced'

setup twobranches
add_branch wt-b
printf 'pending\npass\n' >"$C/ghs/checks_seq"
(cd "$C/wt-a" && PATH="$C/bin:$PATH" GHS="$C/ghs" ORIGIN="$C/origin.git" MW_POLL_SECONDS=0.1 bash "$C/skills/_shared/merge-worktree.sh" wt-a >"$C/o1" 2>&1) &
p1=$!
(cd "$C/wt-b" && PATH="$C/bin:$PATH" GHS="$C/ghs" ORIGIN="$C/origin.git" MW_POLL_SECONDS=0.1 bash "$C/skills/_shared/merge-worktree.sh" wt-b >"$C/o2" 2>&1) &
p2=$!
r1=0
wait "$p1" || r1=$?
r2=0
wait "$p2" || r2=$?
OUT="$(cat "$C/o1" "$C/o2")"
check "two branches at once: both merged" eval 'on_main wt-a && on_main wt-b'
check "two branches at once: both exit 0 and primary is synced, on main, clean" eval 'test "$r1" = 0 && test "$r2" = 0 && primary_synced && test "$(git -C "$C/primary" symbolic-ref --short HEAD)" = main && test -z "$(git -C "$C/primary" status --porcelain)"'

setup mergeerr
touch "$C/ghs/merge_err"
run wt-a
check "merge call errors but the PR merged: exit 0" eval 'test "$RC" = 0 && primary_synced'

setup unknown
touch "$C/ghs/view_fail_after_merge"
run wt-a
check "PR unreadable after the merge call: exit 5" test "$RC" = 5

setup otherhead
touch "$C/ghs/merged_other_head"
run wt-a
check "PR records another head but the tip is on main: exit 0, synced" eval 'test "$RC" = 0 && on_main wt-a && primary_synced'

setup otherheadnomerge
touch "$C/ghs/merged_other_head_nomerge"
run wt-a
check "PR merged another head, tip not on main: exit 1" eval 'test "$RC" = 1 && ! on_main wt-a'

setup lag
touch "$C/ghs/lag_merged"
run wt-a
check "PR reads OPEN twice after a merge: exit 0" eval 'test "$RC" = 0 && primary_synced'

setup stalethenfail
echo 1 >"$C/ghs/lag_merged"
touch "$C/ghs/view_fail_after_merge" "$C/ghs/merge_err"
run wt-a
check "merge call errors, PR reads OPEN once then is unreadable: exit 5" test "$RC" = 5

setup refuse
touch "$C/ghs/merge_refuse"
run wt-a
check "merge refused: exit 1, nothing merged" eval 'test "$RC" = 1 && ! on_main wt-a && grep -q refused <<<"$OUT"'

setup badtimeout
run wt-a --timeout 08
first="$RC"
run wt-a --timeout 0
check "timeout 08 or 0: usage error" eval 'test "$first" = 2 && test "$RC" = 2'

setup suffix
git clone -q "$C/origin.git" "$C/other"
git -C "$C/other" commit -q --allow-empty -m "unrelated"
git -C "$C/other" push -q origin HEAD:refs/heads/team/wt-a
run wt-a
check "a ref named team/wt-a is not taken for wt-a: exit 0" eval 'test "$RC" = 0 && on_main wt-a'

setup livelock
lockdir="$(git -C "$C/primary" rev-parse --path-format=absolute --git-common-dir)/merge-worktree.lock"
mkdir "$lockdir"
sleep 30 &
holder=$!
echo "$holder" >"$lockdir/pid"
run wt-a
kill "$holder" 2>/dev/null || true
check "lock held by a live process: exit 3, lock kept, change merged" eval 'test "$RC" = 3 && test -d "$lockdir" && grep -q "live PID" <<<"$OUT" && on_main wt-a'

setup deadlock
lockdir="$(git -C "$C/primary" rev-parse --path-format=absolute --git-common-dir)/merge-worktree.lock"
mkdir "$lockdir"
echo 999999 >"$lockdir/pid"
run wt-a
check "lock left by a dead process: exit 3, lock kept, cleanup named, change merged" eval 'test "$RC" = 3 && test -d "$lockdir" && grep -q "not running" <<<"$OUT" && on_main wt-a'

setup teardown
run wt-a --teardown
check "teardown: exit 0, worktree and branch gone" eval 'test "$RC" = 0 && test ! -d "$C/wt-a" && ! git -C "$C/primary" show-ref -q --verify refs/heads/wt-a'

setup teardownmoved
printf '%s' "$C/wt-a" >"$C/ghs/advance_branch"
tip="$(git -C "$C/primary" rev-parse wt-a)"
run wt-a --teardown
check "branch moved during the merge: exit 3, worktree and late commit kept, tip merged" eval 'test "$RC" = 3 && test -d "$C/wt-a" && test "$(git -C "$C/primary" log -1 --format=%s wt-a)" = "late commit" && git --git-dir="$C/origin.git" merge-base --is-ancestor "$tip" main'

setup trapexit
RC=0
OUT="$(cd "$C/wt-a" && PATH="$C/bin:$PATH" GHS="$C/ghs" ORIGIN="$C/origin.git" MW_POLL_SECONDS=0 \
  MW_TEST_FAIL_AFTER_MERGE=1 bash "$C/skills/_shared/merge-worktree.sh" wt-a 2>&1)" || RC=$?
check "unexpected failure after the merge: exit 3, change merged" eval 'test "$RC" = 3 && on_main wt-a'

setup nothing
git -C "$C/primary" worktree add -q "$C/wt-empty" -b wt-empty 2>/dev/null
run wt-empty
check "nothing ahead of main: exit 1" test "$RC" = 1

exit "$fail"
