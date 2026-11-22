#!/usr/bin/env bash
# Each case is a string that check() runs with eval, so single quotes are intended.
# shellcheck disable=SC2016
set -uo pipefail
exec </dev/null

# Checks branch-drop.sh against scratch repositories with bare remotes. Each case
# tests one guarantee; it fails if the script deletes what it must keep, keeps
# what it may delete, or returns the wrong exit code.

here="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
bd="$here/branch-drop.sh"
[[ -x "$bd" ]] || {
  echo "no executable branch-drop.sh next to this script" >&2
  exit 2
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/branch-drop-selfcheck.XXXXXX") || exit 2
[[ -n $tmp && -d $tmp ]] || exit 2
tmp=$(cd "$tmp" && pwd -P) || exit 2
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$1"
}
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$1"
  sed 's/^/     /' "$tmp/out" 2>/dev/null
}
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
setup() { "$@" >"$tmp/out" 2>&1 || { bad "setup: $*"; }; }

# The fixture must never touch the caller's repository or git config.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$tmp"
R="$tmp/repo with space's"
A="$tmp/a.git" B="$tmp/b.git"
git init -q --bare "$A" && git init -q --bare "$B"
git init -q -b main "$R"
g() { git -C "$R" -c user.email=x@x.invalid -c user.name=x -c commit.gpgsign=false "$@"; }
g commit -q --allow-empty -m one
c1=$(g rev-parse HEAD)
g commit -q --allow-empty -m two
c2=$(g rev-parse HEAD)
[[ $(g rev-parse --path-format=absolute --git-dir) == "$tmp"/* ]] || {
  echo "fixture git dir is outside the scratch dir" >&2
  exit 2
}
g remote add origin "$A"
g remote add split "$A"
g remote set-url --push split "$B"
g remote add dead "$tmp/nonexistent.git"
ledger="$(g rev-parse --path-format=absolute --git-common-dir)/branch-drop-created"
key() { printf '%s' "$1" | git hash-object --stdin; }
# Prints the oid, or nothing if the ref is missing; exits 2 on a git error.
remote_has() { git -C "$1" for-each-ref --format='%(objectname)' "refs/heads/$2" || exit 2; }
local_has() { g for-each-ref --format='%(objectname)' "refs/heads/$1" || exit 2; }
in_ledger() { [[ -r $ledger ]] && grep -qxF -e "$(key "$1")"$'\t'"refs/heads/$2" "$ledger"; }
run() {
  "$bd" "$@" >"$tmp/out" 2>&1
  echo $?
}

check "no arguments exits 2" '[[ $(run) == 2 ]]'
check "a flag with no value exits 2" '[[ $(run drop --repo "$R" --branch x --expect) == 2 ]]'
check "drop without --expect exits 2" '[[ $(run drop --repo "$R" --branch x) == 2 ]]'
check "create with --expect exits 2" '[[ $(run create --repo "$R" --branch x --expect "$c1") == 2 ]]'
check "an abbreviated --expect exits 2" '[[ $(run drop --repo "$R" --branch x --expect "${c2:0:10}") == 2 ]]'
check "a branch name as --expect exits 2" '[[ $(run drop --repo "$R" --branch x --expect main) == 2 ]]'
check "a full oid that is no commit here exits 2" '[[ $(run drop --repo "$R" --branch x --expect 0123456789012345678901234567890123456789) == 2 ]]'
check "not a repo exits 2" '[[ $(run drop --repo "$tmp" --branch x --expect "$c1") == 2 ]]'
check "invalid branch name exits 2" '[[ $(run drop --repo "$R" --branch "a b" --expect "$c1") == 2 ]]'
check "unknown remote exits 2" '[[ $(run drop --repo "$R" --branch x --expect "$c1" --remote nope) == 2 ]]'
check "create without a local branch exits 2" '[[ $(run create --repo "$R" --branch nope) == 2 ]]'

g branch b1 "$c2"
check "drop deletes a local branch at the expected oid" '[[ $(run drop --repo "$R" --branch b1 --expect "$c2") == 0 ]] && [[ -z $(local_has b1) ]]'
g branch b2 "$c1"
check "drop keeps a branch that moved (exit 3, oid unchanged)" '[[ $(run drop --repo "$R" --branch b2 --expect "$c2") == 3 ]] && [[ $(local_has b2) == "$c1" ]]'
g branch b3 "$c2"
g worktree add -q "$tmp/wt3" b3
check "drop keeps a branch checked out in a worktree" '[[ $(run drop --repo "$R" --branch b3 --expect "$c2") == 3 ]] && [[ $(local_has b3) == "$c2" ]]'
g symbolic-ref refs/heads/alias refs/heads/main
check "drop refuses a symbolic branch ref and keeps its target" '[[ $(run drop --repo "$R" --branch alias --expect "$c2") == 2 ]] && [[ $(local_has main) == "$c2" ]]'
g symbolic-ref --delete refs/heads/alias

# A rebase in another worktree shows that worktree as "detached".
g branch rb "$c1"
g worktree add -q "$tmp/wtrb" rb
gw() { git -C "$tmp/wtrb" -c user.email=x@x.invalid -c user.name=x -c commit.gpgsign=false "$@"; }
printf 'a\n' >"$tmp/wtrb/f" && gw add f && gw commit -qm rb-a
# shellcheck disable=SC2034 # used inside the check string
rbo=$(local_has rb)
gw switch -q -c rbbase "$c1"
printf 'b\n' >"$tmp/wtrb/f" && gw add f && gw commit -qm base-b
gw switch -q rb
gw rebase rbbase >/dev/null 2>&1
check "drop keeps a branch that another worktree is rebasing" '[[ $(gw rev-parse --abbrev-ref HEAD) == HEAD ]] && [[ $(run drop --repo "$R" --branch rb --expect "$rbo") == 3 ]] && [[ $(local_has rb) == "$rbo" ]]'
gw rebase --abort >/dev/null 2>&1

# worktree list failing must not read as "not in use".
mkdir -p "$tmp/wlbin"
cat >"$tmp/wlbin/git" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" worktree list "* ]]; then exit 1; fi
exec "$REAL_GIT" "$@"
EOF
chmod 755 "$tmp/wlbin/git"
g branch b12 "$c2"
check "a worktree-list failure exits 2 and keeps the branch" '[[ $(REAL_GIT=$(command -v git) PATH="$tmp/wlbin:$PATH" run drop --repo "$R" --branch b12 --expect "$c2") == 2 ]] && [[ $(local_has b12) == "$c2" ]]'

g branch b4 "$c2"
check "create pushes a new branch and records it" '[[ $(run create --repo "$R" --branch b4) == 0 ]] && [[ $(remote_has "$A" b4) == "$c2" ]] && in_ledger "$A" b4'
check "the ledger holds no URL text" '! grep -qF "$A" "$ledger"'
setup g push -q "$A" "$c1:refs/heads/b5"
g branch b5 "$c2"
check "create refuses a branch the remote already has, even a fast-forward" '[[ $(run create --repo "$R" --branch b5) == 3 ]] && [[ $(remote_has "$A" b5) == "$c1" ]] && ! in_ledger "$A" b5'
setup g push -q "$A" "$c2:refs/heads/bsame"
g branch bsame "$c2"
check "create refuses a remote branch already at the same commit" '[[ $(run create --repo "$R" --branch bsame) == 3 ]] && ! in_ledger "$A" bsame'

check "drop --remote deletes a branch create made, and clears the ledger" '[[ $(run drop --repo "$R" --branch b4 --expect "$c2" --remote origin) == 0 ]] && [[ -z $(remote_has "$A" b4) ]] && ! in_ledger "$A" b4'
g branch b6 "$c2"
setup g push -q "$A" "$c2:refs/heads/b6"
check "drop --remote keeps a remote branch that create did not make" '[[ $(run drop --repo "$R" --branch b6 --expect "$c2" --remote origin) == 3 ]] && [[ $(remote_has "$A" b6) == "$c2" ]]'
g branch b7 "$c2"
setup "$bd" create --repo "$R" --branch b7
setup g push -q --force "$A" "$c1:refs/heads/b7"
check "drop --remote keeps a remote branch that moved, and says so" '[[ $(run drop --repo "$R" --branch b7 --expect "$c2" --remote origin) == 3 ]] && [[ $(remote_has "$A" b7) == "$c1" ]] && grep -q "is at" "$tmp/out" && in_ledger "$A" b7'
g branch b8 "$c2"
setup g push -q "$A" "$c2:refs/heads/b8"
check "create uses the push URL" '[[ $(run create --repo "$R" --branch b8 --remote split) == 0 ]] && [[ $(remote_has "$B" b8) == "$c2" ]]'
check "drop --remote at the fetch URL's remote keeps a branch recorded only at the push URL" '[[ $(run drop --repo "$R" --branch b8 --expect "$c2" --remote origin) == 3 ]] && [[ $(remote_has "$A" b8) == "$c2" ]]'
g branch b8 "$c2"
check "drop --remote deletes at the push URL and leaves the fetch URL alone" '[[ $(run drop --repo "$R" --branch b8 --expect "$c2" --remote split) == 0 ]] && [[ -z $(remote_has "$B" b8) ]] && [[ $(remote_has "$A" b8) == "$c2" ]]'

# ls-remote fails, the remote is live and recorded: nothing may change.
g branch b9 "$c2"
setup "$bd" create --repo "$R" --branch b9
cat >"$tmp/wlbin/git" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" ls-remote "* ]]; then exit 128; fi
if [[ " $* " == *" push "* ]]; then echo push >>"$PUSH_LOG"; fi
exec "$REAL_GIT" "$@"
EOF
check "an ls-remote failure exits 2 and changes nothing" '[[ $(PUSH_LOG="$tmp/pushes" REAL_GIT=$(command -v git) PATH="$tmp/wlbin:$PATH" run drop --repo "$R" --branch b9 --expect "$c2" --remote origin) == 2 ]] && [[ $(local_has b9) == "$c2" ]] && [[ $(remote_has "$A" b9) == "$c2" ]] && in_ledger "$A" b9 && [[ ! -e $tmp/pushes ]]'

# A delete push that fails while the remote did not move is an error, not "kept".
cat >"$tmp/wlbin/git" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" push "* && " $* " == *" :refs/heads/"* ]]; then echo "remote: hook declined" >&2; exit 1; fi
exec "$REAL_GIT" "$@"
EOF
check "a failed delete push with the remote unchanged exits 2" '[[ $(REAL_GIT=$(command -v git) PATH="$tmp/wlbin:$PATH" run drop --repo "$R" --branch b9 --expect "$c2" --remote origin) == 2 ]] && [[ $(remote_has "$A" b9) == "$c2" ]] && in_ledger "$A" b9'

g branch b10 "$c2"
setup "$bd" create --repo "$R" --branch b10
g update-ref -d refs/heads/b10
check "drop --remote works when the local branch is already gone" '[[ $(run drop --repo "$R" --branch b10 --expect "$c2" --remote origin) == 0 ]] && [[ -z $(remote_has "$A" b10) ]]'
g branch b13 "$c2"
setup "$bd" create --repo "$R" --branch b13
git -C "$A" update-ref -d refs/heads/b13
check "a remote already gone clears the ledger" '[[ $(run drop --repo "$R" --branch b13 --expect "$c2" --remote origin) == 0 ]] && ! in_ledger "$A" b13'
g branch b14 "$c2"
setup "$bd" create --repo "$R" --branch b14
g branch -f b14 "$c1"
check "a kept local branch still clears the ledger after the remote delete" '[[ $(run drop --repo "$R" --branch b14 --expect "$c2" --remote origin) == 3 ]] && [[ $(local_has b14) == "$c1" ]] && [[ -z $(remote_has "$A" b14) ]] && ! in_ledger "$A" b14'

# Race: the remote moves between the script's ls-remote and its delete push.
g branch b11 "$c2"
setup "$bd" create --repo "$R" --branch b11
cat >"$tmp/wlbin/git" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [[ $a == :refs/heads/b11 ]]; then "$REAL_GIT" -C "$FIX_R" push -q --force "$FIX_A" "$FIX_C1:refs/heads/b11"; fi
done
exec "$REAL_GIT" "$@"
EOF
check "drop --remote keeps a remote branch that moves after the check (lease)" '[[ $(FIX_R="$R" FIX_A="$A" FIX_C1="$c1" REAL_GIT=$(command -v git) PATH="$tmp/wlbin:$PATH" run drop --repo "$R" --branch b11 --expect "$c2" --remote origin) == 3 ]] && [[ $(remote_has "$A" b11) == "$c1" ]]'

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
