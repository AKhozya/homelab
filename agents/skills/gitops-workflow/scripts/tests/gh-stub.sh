#!/usr/bin/env bash
# Fake `gh` for test-merge-worktree.sh. State lives in $GHS: prs.json (the PRs), checks_seq (one
# check result per line, consumed per call, the last line repeats), and flag files that switch on
# a failure mode. ORIGIN is the bare repo that represents the GitHub remote. Every call is logged
# to $GHS/calls.
set -euo pipefail
echo "$*" >>"$GHS/calls"

OWN=0
lock() {
  until mkdir "$GHS/lock" 2>/dev/null; do sleep 0.05; done
  OWN=1
}
unlock() {
  rmdir "$GHS/lock"
  OWN=0
}
# A failing git step must not leave the lock behind for the other concurrent stub calls.
trap '[ "$OWN" = 0 ] || rmdir "$GHS/lock" 2>/dev/null' EXIT
prs() { cat "$GHS/prs.json"; }
save() { cat >"$GHS/prs.json.new" && mv "$GHS/prs.json.new" "$GHS/prs.json"; }
remote_head() { git --git-dir="$ORIGIN" rev-parse -q --verify "refs/heads/$1" 2>/dev/null || echo ""; }

# Pull out -q / -R / --json, keep the rest.
Q=""
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
  -q)
    Q="$2"
    shift
    ;;
  -R | --json) shift ;;
  *) args+=("$1") ;;
  esac
  shift
done
set -- "${args[@]}"
out() { if [ -n "$Q" ]; then jq -r "$Q"; else cat; fi; }
opt() { # name -> value from the remaining args
  local want="$1"
  shift
  while [ "$#" -gt 0 ]; do
    [ "$1" = "$want" ] && {
      echo "$2"
      return
    }
    shift
  done
}

case "$1 ${2:-}" in
"auth status") [ ! -e "$GHS/noauth" ] ;;
"repo view") echo '{"nameWithOwner":"o/r"}' | out ;;
"pr list")
  head="$(opt --head "$@")"
  state="$(opt --state "$@")"
  prs | jq --arg h "$head" --arg s "$state" \
    'map(select(.headRefName == $h and ($s == "all" or .state == ($s | ascii_upcase))))' | out
  ;;
"pr create")
  head="$(opt --head "$@")"
  lock
  if prs | jq -e --arg h "$head" 'any(.[]; .headRefName == $h and .state == "OPEN")' >/dev/null; then
    unlock
    echo "a pull request for branch \"$head\" into branch \"main\" already exists" >&2
    exit 1
  fi
  n=$(($(prs | jq 'length') + 100))
  prs | jq --argjson n "$n" --arg h "$head" --arg sha "$(remote_head "$head")" \
    '. + [{number: $n, state: "OPEN", headRefName: $h, headRefOid: $sha, isCrossRepository: false, mergeCommit: null}]' | save
  unlock
  [ ! -e "$GHS/create_race" ] || {
    echo "a pull request for branch \"$head\" into branch \"main\" already exists" >&2
    exit 1
  }
  echo "https://github.com/o/r/pull/$n"
  ;;
"pr view")
  n="$3"
  # lag_merged holds how many reads of a merged PR still say OPEN (empty file: 2).
  if [ -e "$GHS/lag_merged" ] && prs | jq -e --argjson n "$n" 'any(.[]; .number == $n and .state == "MERGED")' >/dev/null; then
    c="$(cat "$GHS/lag_count" 2>/dev/null || echo 0)"
    limit="$(cat "$GHS/lag_merged")"
    if [ "$c" -lt "${limit:-2}" ]; then
      echo $((c + 1)) >"$GHS/lag_count"
      prs | jq --argjson n "$n" '.[] | select(.number == $n) | .state = "OPEN"' | out
      exit 0
    fi
  fi
  if [ -e "$GHS/view_fail_after_merge" ] && prs | jq -e --argjson n "$n" 'any(.[]; .number == $n and .state == "MERGED")' >/dev/null; then
    exit 1
  fi
  lock
  # If a push changes a branch, GitHub updates its open PR's head.
  h="$(prs | jq -r --argjson n "$n" '.[] | select(.number == $n) | .headRefName')"
  prs | jq --argjson n "$n" --arg sha "$(remote_head "$h")" \
    'map(if .number == $n and .state == "OPEN" and $sha != "" then .headRefOid = $sha else . end)' | save
  unlock
  mergeable="MERGEABLE"
  [ ! -e "$GHS/conflicting" ] || mergeable="CONFLICTING"
  prs | jq --argjson n "$n" --arg m "$mergeable" --arg o "$(cat "$GHS/head_override" 2>/dev/null || true)" \
    '.[] | select(.number == $n) | .mergeable = $m | (if $o != "" then .headRefOid = $o else . end)' | out
  ;;
"pr checks")
  lock
  tok="$(head -1 "$GHS/checks_seq")"
  if [ "$(wc -l <"$GHS/checks_seq")" -gt 1 ]; then
    tail -n +2 "$GHS/checks_seq" >"$GHS/checks_seq.new" && mv "$GHS/checks_seq.new" "$GHS/checks_seq"
  fi
  unlock
  both() { printf '[{"name":"ci-ok","bucket":"%s"},{"name":"gitleaks secret scan","bucket":"%s"},{"name":"yamllint","bucket":"pass"}]\n' "$1" "$2"; }
  case "$tok" in
  pass) both pass pass ;;
  pending) both pending pass && exit 8 ;;
  merge_now)
    # Another session merges the PR between this read and the next.
    h="$(prs | jq -r --argjson n "$3" '.[] | select(.number == $n) | .headRefName')"
    "$0" pr merge "$3" --match-head-commit "$(remote_head "$h")" >/dev/null
    both pending pass && exit 8
    ;;
  fail) both fail pass && exit 1 ;;
  skipping) both skipping pass ;;
  none) echo '[]' && exit 8 ;;
  dup) echo '[{"name":"ci-ok","bucket":"pass"},{"name":"ci-ok","bucket":"pass"},{"name":"gitleaks secret scan","bucket":"pass"}]' ;;
  garbage) echo 'HTTP 502' && exit 1 ;;
  advance)
    w="$GHS/adv-$$"
    git clone -q "$ORIGIN" "$w" && git -C "$w" commit -q --allow-empty -m "unrelated work on main" && git -C "$w" push -q origin HEAD:main
    both pending pass && exit 8
    ;;
  esac
  ;;
"pr merge")
  n="$3"
  sha="$(opt --match-head-commit "$@")"
  [ ! -e "$GHS/merge_refuse" ] || {
    echo "Pull request is not mergeable" >&2
    exit 1
  }
  [ ! -s "$GHS/advance_branch" ] || git -C "$(cat "$GHS/advance_branch")" commit -q --allow-empty -m "late commit"
  lock
  # GitHub refuses to merge a PR that is closed, already merged or missing.
  st="$(prs | jq -r --argjson n "$n" '[.[] | select(.number == $n) | .state][0] // "MISSING"')"
  if [ "$st" != OPEN ]; then
    unlock
    echo "Pull request #$n is not open ($st)" >&2
    exit 1
  fi
  h="$(prs | jq -r --argjson n "$n" '.[] | select(.number == $n) | .headRefName')"
  if [ -e "$GHS/merged_other_head_nomerge" ]; then
    prs | jq --argjson n "$n" 'map(if .number == $n then .state = "MERGED" | .mergeCommit = {oid: "1111111111111111111111111111111111111111"} | .headRefOid = "2222222222222222222222222222222222222222" else . end)' | save
    unlock
    exit 0
  fi
  [ "$(remote_head "$h")" = "$sha" ] || {
    unlock
    echo "head commit does not match" >&2
    exit 1
  }
  w="$GHS/merge-$$"
  git clone -q "$ORIGIN" "$w"
  git -C "$w" merge -q --no-ff "origin/$h" -m "Merge pull request #$n"
  git -C "$w" push -q origin HEAD:main
  mc="$(git -C "$w" rev-parse HEAD)"
  head_after="$sha"
  [ ! -e "$GHS/merged_other_head" ] || head_after="0000000000000000000000000000000000000000"
  prs | jq --argjson n "$n" --arg mc "$mc" --arg h "$head_after" \
    'map(if .number == $n then .state = "MERGED" | .mergeCommit = {oid: $mc} | .headRefOid = $h else . end)' | save
  unlock
  [ ! -e "$GHS/merge_err" ] || {
    echo "API timeout" >&2
    exit 1
  }
  ;;
*) echo "gh stub: unhandled: $*" >&2 && exit 99 ;;
esac
