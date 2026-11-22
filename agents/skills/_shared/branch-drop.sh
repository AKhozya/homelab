#!/usr/bin/env bash
set -euo pipefail

# Create and delete throwaway branches with checks that prose cannot make
# reliably. A remote branch is deleted only if this script created it.
#
#   branch-drop.sh create --repo <repo> --branch <name> [--remote <name>]
#     Push refs/heads/<name> to the remote as a new branch. Fails if the
#     remote already has that ref. Records the creation in the repo's ledger.
#
#   branch-drop.sh drop --repo <repo> --branch <name> --expect <full-oid> [--remote <name>]
#     Delete the local branch if it still points at <oid> and no worktree uses
#     it (checked out, or in a rebase or bisect). With --remote, also delete the
#     remote branch, but only if the ledger records that this script created it
#     at the same push URL, and only if it still points at <oid>.
#
# Exit: 0 everything asked for was done; 3 something was kept (reason on
# stderr); 2 usage, environment or git error. Every remote check runs before
# any change, so exit 2 from a remote check means nothing changed.
#
# Limit: a remote branch that someone deletes and recreates at the same commit
# looks the same as the one this script created. Give each throwaway a unique
# name, for example probe-<date>-<random>.
#
# If you edit this script, run branch-drop-selfcheck.sh (next to it) afterwards.

die() {
  printf 'branch-drop: %s\n' "$*" >&2
  exit 2
}
kept() {
  printf 'branch-drop: kept: %s\n' "$*" >&2
  rc=3
}
usage() {
  sed -n '6,19s/^# \{0,1\}//p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
cmd=$1
shift
repo="" branch="" expect="" remote=""
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || usage
  case $1 in
  --repo) repo=$2 ;;
  --branch) branch=$2 ;;
  --expect) expect=$2 ;;
  --remote) remote=$2 ;;
  *) usage ;;
  esac
  shift 2
done
[[ -n $repo && -n $branch ]] || usage
case $cmd in
create) [[ -z $expect ]] || usage ;;
drop) [[ $expect =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || die "--expect needs a full oid, not: ${expect:-<empty>}" ;;
*) usage ;;
esac

git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $repo"
git check-ref-format "refs/heads/$branch" || die "not a valid branch name: $branch"
ref="refs/heads/$branch"
# The ledger holds a hash of each resolved push URL, never the URL itself, which
# can carry credentials. Writes take a lock, so two sessions do not lose lines.
ledger="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/branch-drop-created"

# The push URL, not the fetch URL: they can name different repositories, and the
# push URL is where a delete lands.
push_url() {
  local u
  u=$(git -C "$repo" remote get-url --push "$1" 2>/dev/null) || die "no such remote: $1"
  # A relative path resolves from the directory git runs in, so linked worktrees
  # would read one URL as different repositories. Resolve it once, here.
  if [[ $u != *://* && $u != *@*:* && -d "$repo/$u" ]]; then
    u=$(cd "$repo/$u" && pwd -P)
  fi
  printf '%s' "$u"
}
url_key() {
  printf '%s' "$1" | git -C "$repo" hash-object --stdin
}
with_lock() {
  local i=0
  until mkdir "$ledger.lock" 2>/dev/null; do
    i=$((i + 1))
    [[ $i -lt 50 ]] || die "ledger lock busy: $ledger.lock"
    sleep 0.1
  done
  "$@" || {
    rmdir "$ledger.lock"
    die "ledger update failed"
  }
  rmdir "$ledger.lock"
}
# shellcheck disable=SC2329 # invoked through with_lock
ledger_add() {
  printf '%s\t%s\n' "$1" "$ref" >>"$ledger"
}
# shellcheck disable=SC2329 # invoked through with_lock
ledger_remove() {
  local tmp
  tmp=$(mktemp "$ledger.XXXXXX") || return 1
  # grep exits 1 if no line is left, which is not an error; 2 is.
  grep -vxF -e "$1"$'\t'"$ref" "$ledger" >"$tmp" || [[ $? -eq 1 ]] || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$ledger"
}
# Prints the oid the remote holds for $ref, or nothing if it holds none.
# ls-remote exits 0 with no output for a missing ref, so a failure is an error.
remote_oid() {
  local out
  out=$(git -C "$repo" ls-remote "$1" "$ref") || die "ls-remote failed for $1"
  printf '%s' "${out%%[[:space:]]*}"
}
in_ledger() {
  [[ -f $ledger ]] && grep -qxF -e "$(url_key "$1")"$'\t'"$ref" "$ledger"
}
# True if any worktree has the branch checked out, or is rebasing or bisecting
# it. During a rebase the porcelain list shows that worktree as "detached", so
# the branch is found only in the worktree's rebase state files.
in_use() {
  local wt line gd f
  # Captured first: grep -q on a pipe can stop early, and under pipefail the
  # SIGPIPE would read as "not in use".
  wt=$(git -C "$repo" worktree list --porcelain) || die "worktree list failed"
  grep -qxF -e "branch $ref" <<<"$wt" && return 0
  while IFS= read -r line; do
    [[ $line == "worktree "* ]] || continue
    gd=$(git -C "${line#worktree }" rev-parse --absolute-git-dir 2>/dev/null) || continue
    for f in rebase-merge/head-name rebase-apply/head-name; do
      [[ -f $gd/$f && $(<"$gd/$f") == "$ref" ]] && return 0
    done
    [[ -f $gd/BISECT_START && $(<"$gd/BISECT_START") == "$branch" ]] && return 0
  done <<<"$wt"
  return 1
}

rc=0
if [[ $cmd == create ]]; then
  [[ -n $remote ]] || remote=origin
  url=$(push_url "$remote")
  oid=$(git -C "$repo" rev-parse --verify --quiet "$ref^{commit}") || die "no local branch $branch"
  # An empty lease means "the remote must not have this ref", so the push
  # itself proves that this script created it.
  # A remote that already holds the same commit reports "up to date" and exits 0
  # without checking the lease, so only a "*" (new ref) line proves creation.
  if out=$(git -C "$repo" push --porcelain --force-with-lease="$ref:" "$url" "$oid:$ref" 2>&1) &&
    grep -q -e "^\*"$'\t'"$oid:$ref"$'\t' <<<"$out"; then
    with_lock ledger_add "$(url_key "$url")"
    printf 'created %s on remote %s at %s\n' "$ref" "$remote" "$oid"
    exit 0
  fi
  if [[ -n $(remote_oid "$url") ]]; then
    kept "remote $remote already has $ref; nothing recorded"
    exit "$rc"
  fi
  die "push to remote $remote failed: $out"
fi

# Settle every remote fact before changing anything.
git -C "$repo" cat-file -e "$expect^{commit}" 2>/dev/null || die "not a commit in $repo: $expect"
url="" have="" recorded=0
if [[ -n $remote ]]; then
  url=$(push_url "$remote")
  if in_ledger "$url"; then
    recorded=1
    have=$(remote_oid "$url")
  fi
fi

# for-each-ref prints nothing for a missing ref and fails only on a real error.
local_oid=$(git -C "$repo" for-each-ref --format='%(objectname)' "$ref") || die "cannot read $ref"
if git -C "$repo" symbolic-ref -q "$ref" >/dev/null; then
  die "$ref is a symbolic ref; update-ref -d would delete its target"
fi
if [[ -z $local_oid ]]; then
  printf 'no local branch %s\n' "$branch"
elif [[ $local_oid != "$expect" ]]; then
  kept "local $branch is at $local_oid, not $expect"
elif in_use; then
  kept "local $branch is in use by a worktree (checked out, rebasing or bisecting)"
else
  # The oid argument makes git refuse the delete if the branch moved since the check.
  git -C "$repo" update-ref --no-deref -d "$ref" "$expect" || die "update-ref failed for $branch"
  printf 'deleted local %s (restore: git -C %q branch %q %s)\n' "$branch" "$repo" "$branch" "$expect"
fi

if [[ -n $remote ]]; then
  gone=0
  if [[ $recorded -eq 0 ]]; then
    kept "remote $ref on $remote: not created by branch-drop.sh create"
  elif [[ -z $have ]]; then
    printf 'remote %s already gone from %s\n' "$ref" "$remote"
    gone=1
  # The lease below also refuses a moved branch; this check runs first only to
  # give a clearer reason.
  elif [[ $have != "$expect" ]]; then
    kept "remote $ref on $remote is at $have, not $expect"
  elif err=$(git -C "$repo" push --quiet --force-with-lease="$ref:$expect" "$url" ":$ref" 2>&1); then
    printf 'deleted remote %s on %s (restore: git -C %q push %q %q)\n' "$ref" "$remote" "$repo" "$remote" "$expect:$ref"
    gone=1
  elif [[ $(remote_oid "$url") != "$expect" ]]; then
    kept "remote $ref on $remote moved before the delete"
  else
    die "delete push to remote $remote failed: $err"
  fi
  if [[ $gone -eq 1 ]]; then
    with_lock ledger_remove "$(url_key "$url")"
  fi
fi
exit "$rc"
