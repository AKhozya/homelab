#!/usr/bin/env bash
# worktree-cleanup-selfcheck.sh — prove worktree-cleanup.sh deletes merged and squash-merged
# branches and keeps everything else. Builds a scratch repo with a bare "remote", so
# "[gone]" upstreams come from a real `git fetch --prune`. Runs isolated from the user's git
# config, because signing or hooks there would make the setup commits fail or prompt.
#
# usage: worktree-cleanup-selfcheck.sh     exit 0 = all cases pass, 1 = a case failed
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
cleanup="$here/worktree-cleanup.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$tmp/gitconfig"
git config --global user.name selfcheck
git config --global user.email selfcheck@localhost
git config --global init.defaultBranch main

fail=0
check() { # check <description> <command...>
  if "${@:2}"; then echo "ok    $1"; else
    echo "FAIL  $1"
    fail=1
  fi
}
# shellcheck disable=SC2329 # called through check()
has() { git -C "$repo" show-ref --verify --quiet "refs/heads/$1"; }
# shellcheck disable=SC2329 # called through check()
lacks() { ! has "$1"; }
state() { git -C "$repo" for-each-ref --format='%(refname) %(objectname)' refs/heads && git -C "$repo" worktree list; }
# shellcheck disable=SC2329 # called through check()
kept() { grep -qxF "refs/heads/$1 $(git -C "$repo" rev-parse --verify -q "refs/heads/$1")" <<<"$before"; }

git init -q --bare "$tmp/remote.git"
# A space and an apostrophe in the path catch a quoting slip in the script or the restore command.
repo="$tmp/re po'x"
git clone -q "$tmp/remote.git" "$repo" 2>/dev/null
cd "$repo"
echo base >f && git add f && git commit -qm base
# If both sides edit a keep-ours path, a merge returns main's version of it, so a check built on
# merging would call the branch merged.
git config merge.keepours.driver true
mkdir keep && echo "* merge=keepours" >keep/.gitattributes
echo "m.txt merge=keepours" >.gitattributes && echo base >m.txt && echo base >keep/$'a\tb\tunspecified' &&
  git add .gitattributes m.txt keep && git commit -qm attributes && git push -q origin main
# A clone of an empty remote has no origin/HEAD; a real clone of a GitHub repo does.
git remote set-head -q origin main 2>/dev/null || git remote set-head origin main >/dev/null
root=$(git rev-parse main)

# branch <name> <file> <content>: one commit on a new branch off main, pushed with upstream.
branch() {
  git switch -qc "$1" main
  echo "$3" >"$2" && git add "$2" && git commit -qm "$1"
  git push -qu origin "$1" 2>/dev/null
  git switch -q main
}
squash() { # squash <branch>: land the branch on main as one new commit
  git merge -q --squash "$1" >/dev/null 2>&1 && git commit -qm "squash $1"
}
worktree() { # worktree <branch> <file>: a worktree on a new branch with one commit
  git worktree add -q -b "$1" "$tmp/$1" "$root"
  (cd "$tmp/$1" && echo "$1" >"$2" && git add "$2" && git commit -qm "$1")
}

branch sq a.txt "squashed change"   # squash-merged, then main moves on -> delete
branch un b.txt "never merged"      # upstream gone, not on main -> keep
branch anc c.txt "fast-forwarded"   # ancestor-merged -> delete with branch --delete
branch rework d.txt "first version" # main lands a different version -> keep
branch ws p.py "    x = 1"          # main lands the same line with other indentation -> keep
branch rev r.txt "reverted later"   # squash-merged, then main reverts it -> keep
branch drv m.txt "branch version"   # main edits a keep-ours path differently -> keep
# A path holding tabs catches a slip in NUL-separated path handling.
branch tab keep/$'a\tb\tunspecified' "branch version" # same, inside a keep-ours directory -> keep
# Same blob, other mode: a check that compares only blob ids would call it merged.
git switch -qc mode main && chmod +x f && git add f && git commit -qm mode &&
  git push -qu origin mode 2>/dev/null && git switch -q main # never merged -> keep
# Two commits that cancel out leave no net change, so nothing proves the branch merged.
git switch -qc empty main && echo tmp >t.txt && git add t.txt && git commit -qm add &&
  git rm -q t.txt && git commit -qm remove && git push -qu origin empty 2>/dev/null &&
  git switch -q main # no net change -> keep
git switch -qc local main && echo local >e.txt && git add e.txt && git commit -qm local &&
  git switch -q main # never pushed, unmerged -> not a candidate, keep

echo unrelated >g.txt && git add g.txt && git commit -qm unrelated # main moves before the squash
squash sq
git merge -q --ff-only anc 2>/dev/null || git merge -q --no-edit anc
echo "second version" >d.txt && git add d.txt && git commit -qm "rework landed differently"
# git cherry's patch ids ignore whitespace, so it reports ws as merged.
echo "  x = 1" >p.py && git add p.py && git commit -qm "same line, other indentation"
echo "main version" >m.txt && echo "main version" >keep/$'a\tb\tunspecified' &&
  git add m.txt keep && git commit -qm "main edits the keep-ours paths"
squash rev && git revert --no-edit HEAD >/dev/null
echo later >h.txt && git add h.txt && git commit -qm later # main moves after the squash

worktree wt-sq w.txt # squash-merged and clean -> remove
squash wt-sq
worktree wt-un u.txt    # unmerged -> keep
worktree wt-dirty x.txt # squash-merged but holds an uncommitted file -> keep
squash wt-dirty
echo uncommitted >"$tmp/wt-dirty/y.txt"

git push -q origin main
git push -q origin --delete sq un anc rework ws rev drv tab mode empty 2>/dev/null
git fetch -q --prune

before=$(state)
main_oid=$(git rev-parse main)
sq_oid=$(git rev-parse sq)
printf -v want 'git -C %q branch sq %s' "$repo" "$sq_oid"

dry=$("$cleanup" --repo "$repo")
check "dry run changes no branch and no worktree" test "$before" == "$(state)"
check "dry run reports the squash-merged worktree" grep -q "^SQUASH-MERGED .*wt-sq" <<<"$dry"
check "dry run names the restore command" grep -qF "would remove  squash-merged branch sq (restore: $want)" <<<"$dry"

out=$("$cleanup" --repo "$repo" --apply)
check "squash-merged branch with gone upstream is deleted" lacks sq
check "ancestor-merged branch with gone upstream is deleted" lacks anc
check "unmerged branch with gone upstream is kept at its tip" kept un
check "branch whose change main reworked is kept at its tip" kept rework
check "branch whose line main holds with other whitespace is kept at its tip" kept ws
check "squash-merged branch that main later reverted is kept at its tip" kept rev
check "branch touching a keep-ours merge-driver path is kept at its tip" kept drv
check "branch touching a keep-ours path with tabs in its name is kept at its tip" kept tab
check "never-pushed unmerged branch is kept at its tip" kept local
check "branch that changes only a file mode is kept at its tip" kept mode
check "branch with no net change is kept at its tip" kept empty
check "squash-merged wt-* branch is deleted" lacks wt-sq
check "squash-merged worktree directory is removed" test ! -d "$tmp/wt-sq"
# shellcheck disable=SC2016 # $1 and $2 expand in the inner shell
check "unmerged worktree and its branch are kept" bash -c 'test -d "$1" && grep -qF "$1" <<<"$(git -C "$2" worktree list)"' _ "$tmp/wt-un" "$repo"
check "unmerged worktree branch is kept at its tip" kept wt-un
check "dirty worktree keeps its uncommitted file" test -f "$tmp/wt-dirty/y.txt"
check "dirty worktree branch is kept at its tip" kept wt-dirty
check "main still points at the same commit" test "$main_oid" == "$(git rev-parse main)"

check "output prints the restore command with the repo and the deleted oid" \
  grep -qF "REMOVED  squash-merged branch sq (restore: $want)" <<<"$out"
(cd "$tmp" && eval "$want") || true # from another directory, so the command must carry -C
check "restore command brings the branch back at the same commit" \
  test "$(git -C "$repo" rev-parse --verify -q refs/heads/sq)" == "$sq_oid"

# Merge and diff config must not change a verdict: the check compares blobs, not merge results.
branch sq2 s.txt "second squash" && squash sq2
git push -q origin main && git push -q origin --delete sq2 2>/dev/null && git fetch -q --prune
git config merge.default keepours && git config merge.renormalize true &&
  git config diff.ignoreSubmodules all && git config diff.external false
# shellcheck disable=SC2016 # $1 and $2 expand in the inner shell
check "a second run with hostile merge and diff config succeeds" \
  bash -c '"$1" --repo "$2" --apply >/dev/null' _ "$cleanup" "$repo"
check "squash-merged branch is deleted under that config" lacks sq2
check "branch touching a keep-ours path is still kept at its tip under that config" kept drv
git config --unset merge.default && git config --unset merge.renormalize &&
  git config --unset diff.ignoreSubmodules && git config --unset diff.external

# The primary worktree on a branch that alone holds a squash: origin/main lacks the work.
branch ysq y.txt "only on feat"
git switch -qc feat main && squash ysq && git push -q origin --delete ysq 2>/dev/null &&
  git fetch -q --prune
ysq_oid=$(git rev-parse ysq)
# shellcheck disable=SC2016 # $1 and $2 expand in the inner shell
check "a run with the primary worktree on another branch succeeds" \
  bash -c '"$1" --repo "$2" --apply >/dev/null' _ "$cleanup" "$repo"
check "branch squashed only into the checked-out branch is kept at its tip" \
  test "$(git rev-parse --verify -q refs/heads/ysq)" == "$ysq_oid"
git switch -q main

# If origin/HEAD is unset, there is no remote default branch to compare against.
git remote set-head -q origin -d 2>/dev/null || git remote set-head origin -d >/dev/null
# shellcheck disable=SC2016 # $1 and $2 expand in the inner shell
check "no branch is reported squash-merged while origin/HEAD is unset" \
  bash -c 'out=$("$1" --repo "$2") && ! grep -q "squash-merged branch" <<<"$out"' _ "$cleanup" "$repo"

exit "$fail"
