#!/usr/bin/env bash
# merge-worktree.sh — land a worktree branch on main through a pull request.
#
# The main ruleset rejects direct pushes: every change reaches main through a PR whose required
# checks passed. This script pushes the branch, opens (or reuses) the PR, waits for the required
# checks, merges with a merge commit, then fast-forwards the primary worktree's main.
#
# Run from anywhere inside the repo (any worktree). Usage:
#   merge-worktree.sh <branch> [--teardown] [--title TEXT] [--timeout SECONDS]
#     --teardown   after a successful merge and sync, remove that branch's worktree and branch
#     --title      PR title (default: the newest commit subject)
#     --timeout    seconds to wait for the required checks, 1-86400 (default 900)
#
# Exit codes (the caller's next step depends on them):
#   0  merged and the primary worktree synced            -> run fr, verify
#   1  stopped before the merge; nothing of this branch deployed -> fix and re-run (an open PR stays open)
#   2  usage error
#   3  merged on GitHub, but a later step failed         -> run fr anyway (Flux reads GitHub), then
#                                                           fix the primary worktree by hand
#   4  branch pushed, no GitHub login (the in-cluster bot) -> hand the compare URL to the operator
#   5  merge outcome unknown                             -> gh pr view <n> --json state decides
#
# Only this script changes the primary worktree. Its sync and teardown run under a lock directory
# in the git common dir. The script never removes a lock it does not own: two waiters reclaiming
# a stale lock at once could delete each other's live lock.
set -euo pipefail

usage() {
  sed -n '2,25p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

BRANCH=""
TEARDOWN=0
TITLE=""
TIMEOUT=900
while [ "$#" -gt 0 ]; do
  case "$1" in
  --teardown) TEARDOWN=1 ;;
  --title)
    [ "$#" -ge 2 ] || usage
    TITLE="$2"
    shift
    ;;
  --timeout)
    # No leading zero: bash arithmetic reads 010 as octal.
    [ "$#" -ge 2 ] && [[ "$2" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$2" -le 86400 ] || usage
    TIMEOUT="$2"
    shift
    ;;
  -h | --help) usage ;;
  -*) usage ;;
  *)
    [ -z "$BRANCH" ] || usage
    BRANCH="$1"
    ;;
  esac
  shift
done
[ -n "$BRANCH" ] || usage
[ "$BRANCH" != "main" ] || {
  echo "ERR: refusing to merge 'main' into itself" >&2
  exit 2
}

# The main ruleset requires these two check names. Rename one there, rename it here.
REQUIRED_CHECKS=("ci-ok" "gitleaks secret scan")
POLL_SECONDS="${MW_POLL_SECONDS:-10}"
LOCK_WAIT_SECONDS="${MW_LOCK_WAIT_SECONDS:-120}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

stop() { # exit-code, message
  echo "ERR: $2" >&2
  exit "$1"
}

# Once GitHub confirms the merge, the change is on its way to production: any later failure,
# including one set -e catches, must exit 3, never 1.
DEPLOYED=0
LOCK=""
# shellcheck disable=SC2329  # run by the EXIT trap
on_exit() {
  local rc=$?
  set +e # a failed cleanup must not skip the exit-code rule below
  if [ -n "$LOCK" ] && [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ]; then
    rm -f "$LOCK/pid"
    rmdir "$LOCK" 2>/dev/null
  fi
  if [ "$DEPLOYED" = 1 ] && [ "$rc" != 0 ] && [ "$rc" != 3 ]; then
    echo "ERR: merged, but a later step failed unexpectedly (rc=$rc); treat as exit 3" >&2
    exit 3
  fi
}
trap on_exit EXIT

# git always lists the main worktree first; substr keeps paths that contain spaces.
PRIMARY="$(git worktree list --porcelain | awk '/^worktree /{print substr($0, 10); exit}')"
[ -n "${PRIMARY:-}" ] || stop 1 "not inside a git repo"
g() { git -C "$PRIMARY" "$@"; }

g show-ref --verify --quiet "refs/heads/$BRANCH" || stop 1 "branch '$BRANCH' not found"

# owner/repo from origin's configured URL (not get-url, which applies insteadOf rewrites):
# git@github.com:o/r.git, https://github.com/o/r.git, or an ssh alias such as gh-homelab:o/r.git.
# gh is bound to github.com/<this name> with -R, so GH_REPO, GH_HOST or a gh default cannot
# redirect the PR.
origin_url="$(g config --get remote.origin.url)" || stop 1 "no origin remote"
REPO="${origin_url%.git}"
REPO="${REPO%/}"
repo_name="${REPO##*[:/]}"
REPO="${REPO%[:/]*}"
REPO="${REPO##*[:/]}/$repo_name"

# 1. Fetch main (required), then the branch if it exists on origin.
g fetch -q origin main || stop 1 "git fetch origin main failed"
rc=0
g ls-remote --exit-code origin "refs/heads/$BRANCH" >/dev/null 2>&1 || rc=$?
case "$rc" in
0) g fetch -q origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" || stop 1 "git fetch of origin/$BRANCH failed" ;;
2) ;; # the branch is not on origin yet
*) stop 1 "git ls-remote origin failed (rc=$rc)" ;;
esac

TIP="$(g rev-parse "refs/heads/$BRANCH")"
ahead() { g rev-list --count "refs/remotes/origin/main..$TIP"; }
push_branch() {
  # No force: if another session pushed to this branch, stop rather than overwrite its commits.
  # A rejected push is fine if a fresh fetch shows the remote branch already at this exact tip
  # (two runs racing on one branch).
  g push -q origin "$TIP:refs/heads/$BRANCH" 2>/dev/null && return 0
  g fetch -q origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" ||
    stop 1 "push of '$BRANCH' rejected, and re-reading origin/$BRANCH failed"
  [ "$(g rev-parse "refs/remotes/origin/$BRANCH")" = "$TIP" ] ||
    stop 1 "push of '$BRANCH' rejected (origin/$BRANCH has commits this branch lacks); merge them in its worktree and re-run"
}

# 2. The in-cluster bot has a deploy key but no GitHub login: push the branch and hand over.
if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  [ "$(ahead)" -gt 0 ] || stop 1 "'$BRANCH' has no commits ahead of origin/main"
  push_branch
  enc="$(jq -rn --arg b "$BRANCH" '$b | @uri | gsub("%2F"; "/")')"
  echo "BRANCH-ONLY: pushed '$BRANCH' ($TIP). No GitHub login here, so no PR was opened."
  echo "Open and merge it: https://github.com/$REPO/compare/main...$enc"
  exit 4
fi
ghr() { gh "$@" -R "github.com/$REPO"; }

lock_dir() { echo "$(g rev-parse --path-format=absolute --git-common-dir)/merge-worktree.lock"; }

# 7-8. Sync the primary worktree after GitHub confirmed the merge.
sync_primary() { # pr-number
  local n="$1" mc waited=0 cur owner_pid
  DEPLOYED=1
  # Test hook: an unguarded failure after the merge, to prove the EXIT trap maps it to 3.
  [ -z "${MW_TEST_FAIL_AFTER_MERGE:-}" ] || false
  LOCK="$(lock_dir)"
  until mkdir "$LOCK" 2>/dev/null; do
    if [ "$waited" -ge "$LOCK_WAIT_SECONDS" ]; then
      owner_pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
      LOCK=""
      if [ -z "$owner_pid" ]; then
        stop 3 "MERGED PR #$n; primary not synced: lock $(lock_dir) has no pid file (its owner may still be starting); check before removing it"
      elif kill -0 "$owner_pid" 2>/dev/null; then
        stop 3 "MERGED PR #$n; primary not synced: lock $(lock_dir) held by live PID $owner_pid"
      fi
      stop 3 "MERGED PR #$n; primary not synced: lock $(lock_dir) left by PID $owner_pid, which is not running. Remove its pid file and the directory, then re-run"
    fi
    sleep 1
    waited=$((waited + 1))
  done
  echo "$$" >"$LOCK/pid" || stop 3 "MERGED PR #$n; primary not synced: could not write the lock's pid file"

  g fetch -q origin main || stop 3 "MERGED PR #$n; primary not synced: git fetch origin main failed"
  mc="$(ghr pr view "$n" --json mergeCommit -q .mergeCommit.oid)" ||
    stop 3 "MERGED PR #$n; primary not synced: could not read the merge commit"
  g merge-base --is-ancestor "$mc" refs/remotes/origin/main 2>/dev/null ||
    stop 3 "MERGED PR #$n at $mc, but origin/main does not contain it yet; re-run to sync"
  cur="$(g symbolic-ref --short HEAD 2>/dev/null || true)"
  [ "$cur" = main ] || stop 3 "MERGED at $mc; primary not synced: primary worktree is on '$cur', not main"
  if ! g diff --quiet || ! g diff --cached --quiet; then
    stop 3 "MERGED at $mc; primary not synced: primary worktree has uncommitted tracked changes"
  fi
  g merge-base --is-ancestor HEAD refs/remotes/origin/main ||
    stop 3 "MERGED at $mc; primary not synced: local main has commits origin/main lacks (left untouched)"
  g merge --ff-only -q refs/remotes/origin/main || stop 3 "MERGED at $mc; primary not synced: fast-forward failed"
  [ "$(g rev-parse HEAD)" = "$(g rev-parse refs/remotes/origin/main)" ] ||
    stop 3 "MERGED at $mc; primary main does not equal origin/main after the fast-forward"
  echo "OK: '$BRANCH' merged through PR #$n ($mc); primary main at $(g rev-parse --short HEAD)."

  if [ "$TEARDOWN" = 1 ]; then
    local wt
    # A commit added to the branch after TIP is not merged: keep the branch and worktree.
    [ "$(g rev-parse "refs/heads/$BRANCH")" = "$TIP" ] ||
      stop 3 "MERGED at $mc; '$BRANCH' moved past $TIP during the merge, so no teardown"
    wt="$(g worktree list --porcelain |
      awk -v b="refs/heads/$BRANCH" '/^worktree /{p=substr($0,10)} $0=="branch "b{print p; exit}')"
    if [ -n "${wt:-}" ] && [ "$wt" != "$PRIMARY" ]; then
      echo "==> teardown worktree $wt (+ branch)"
      "$HERE/worktree-cleanup.sh" --repo "$PRIMARY" --apply "$wt" || stop 3 "MERGED at $mc; teardown of $wt failed"
    else
      # The old-value argument makes the delete fail if the branch moved after the check above.
      g update-ref -d "refs/heads/$BRANCH" "$TIP" || stop 3 "MERGED at $mc; could not delete branch '$BRANCH'"
    fi
  fi
  exit 0
}

# A MERGED PR whose recorded head is not TIP: someone merged another head of this branch.
# If TIP is on main anyway, the change is deployed; otherwise this branch's tip is not.
merged_other_head() { # pr-number, head
  g fetch -q origin main || stop 5 "PR #$1 merged head $2, not $TIP, and git fetch failed: check main by hand"
  if g merge-base --is-ancestor "$TIP" refs/remotes/origin/main; then
    sync_primary "$1"
  fi
  stop 1 "PR #$1 was merged at head $2; $TIP is not on main. Re-run to open a PR for the rest"
}

# 3. Pick the PR. One head-branch name can carry several PRs over time (worktree names are
# reused), so a merged or closed PR counts only if its head is this branch's tip.
list_prs() {
  ghr pr list --head "$BRANCH" --base main --state all --limit 200 \
    --json number,state,headRefOid,isCrossRepository
}
pick() { # prs-json, state, match-tip(1/0)
  jq -r --arg s "$2" --arg t "$TIP" --argjson m "$3" \
    'map(select((.isCrossRepository | not) and .state == $s and ($m == 0 or .headRefOid == $t))) | .[0].number // empty' <<<"$1"
}
# Another run on this branch may have merged TIP since the last look.
resume_if_merged() {
  local prs merged
  prs="$(list_prs)" || return 0
  merged="$(pick "$prs" MERGED 1)"
  [ -z "$merged" ] || {
    echo "PR #$merged already merged this tip; syncing the primary worktree."
    sync_primary "$merged"
  }
}

prs="$(list_prs)" || stop 1 "gh pr list failed"
PR="$(pick "$prs" OPEN 0)"
if [ -z "$PR" ]; then
  resume_if_merged
  closed="$(pick "$prs" CLOSED 1)"
  [ -z "$closed" ] || stop 1 "PR #$closed with this exact tip was closed without merging; reopen it on GitHub or commit again"
fi

# 4-5.
if [ "$(ahead)" -eq 0 ]; then
  resume_if_merged
  stop 1 "'$BRANCH' has no commits ahead of origin/main"
fi
push_branch

# 6. Create the PR if needed, wait for the required checks, merge.
if [ -z "$PR" ]; then
  [ -n "$TITLE" ] || TITLE="$(g log -1 --format=%s "$TIP")"
  body="$(g log --format='- %h %s' "refs/remotes/origin/main..$TIP")"
  if out="$(ghr pr create --base main --head "$BRANCH" --title "$TITLE" --body "$body" 2>&1)"; then
    PR="${out##*/}"
  else
    prs="$(list_prs)" || stop 1 "gh pr create failed ($out), and gh pr list failed"
    PR="$(pick "$prs" OPEN 0)"
    if [ -z "$PR" ]; then
      resume_if_merged
      stop 1 "gh pr create failed: $out"
    fi
  fi
  [[ "$PR" =~ ^[0-9]+$ ]] || stop 1 "could not read the PR number from: $out"
fi
echo "PR #$PR: waiting for: ${REQUIRED_CHECKS[*]} (timeout ${TIMEOUT}s)"

# MERGED or CLOSED end the run; any other state returns so the caller keeps going.
on_final_state() { # state, head
  case "$1" in
  MERGED)
    [ "$2" = "$TIP" ] || merged_other_head "$PR" "$2"
    sync_primary "$PR"
    ;;
  CLOSED) stop 1 "PR #$PR was closed without merging" ;;
  esac
}

deadline=$((SECONDS + TIMEOUT))
view_errors=0
check_errors=0
while :; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    # Another session may have merged the PR during the last sleep.
    if ! view="$(ghr pr view "$PR" --json state,headRefOid 2>/dev/null)" ||
      ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$view"; then
      stop 5 "timed out on PR #$PR and could not read its state: check 'gh pr view $PR --json state'"
    fi
    on_final_state "$(jq -r .state <<<"$view")" "$(jq -r .headRefOid <<<"$view")"
    stop 1 "timed out after ${TIMEOUT}s waiting for the required checks on PR #$PR (left open)"
  fi
  if ! view="$(ghr pr view "$PR" --json state,headRefOid,mergeable 2>/dev/null)" ||
    ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$view"; then
    view_errors=$((view_errors + 1))
    [ "$view_errors" -lt 3 ] || stop 1 "could not read PR #$PR three times in a row"
    sleep "$POLL_SECONDS"
    continue
  fi
  view_errors=0
  state="$(jq -r .state <<<"$view")"
  head="$(jq -r .headRefOid <<<"$view")"
  on_final_state "$state" "$head"
  if [ "$head" != "$TIP" ]; then
    # Right after a push GitHub can still report the previous head for a few seconds.
    g merge-base --is-ancestor "$head" "$TIP" 2>/dev/null ||
      stop 1 "PR #$PR head is $head, not $TIP: someone else pushed to '$BRANCH'"
    sleep "$POLL_SECONDS"
    continue
  fi
  [ "$(jq -r .mergeable <<<"$view")" != CONFLICTING ] ||
    stop 1 "PR #$PR conflicts with main. In its worktree run 'git merge origin/main' (merge, not rebase, so cited SHAs survive), then re-run"

  # gh exits 8 while checks are pending; the JSON is what counts.
  checks="$(ghr pr checks "$PR" --required --json name,bucket 2>/dev/null || true)"
  if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$checks"; then
    check_errors=$((check_errors + 1))
    [ "$check_errors" -lt 3 ] || stop 1 "could not read the checks of PR #$PR three times in a row"
    sleep "$POLL_SECONDS"
    continue
  fi
  check_errors=0
  passed=0
  for name in "${REQUIRED_CHECKS[@]}"; do
    # A re-run check can appear more than once; it passes only if every entry passed.
    verdict="$(jq -r --arg n "$name" '[.[] | select(.name == $n) | .bucket] as $b
      | if ($b | length) == 0 then "pending"
        elif any($b[]; . == "fail" or . == "cancel") then "fail"
        elif any($b[]; . == "skipping") then "skipping"
        elif all($b[]; . == "pass") then "pass"
        else "pending" end' <<<"$checks")"
    case "$verdict" in
    fail) stop 1 "required check '$name' failed on PR #$PR (left open)" ;;
    skipping) stop 1 "required check '$name' was skipped on PR #$PR; investigate before merging" ;;
    pass) passed=$((passed + 1)) ;;
    esac
  done
  [ "$passed" -lt "${#REQUIRED_CHECKS[@]}" ] || break
  sleep "$POLL_SECONDS"
done

merge_rc=0
merge_out="$(ghr pr merge "$PR" --merge --match-head-commit "$TIP" 2>&1)" || merge_rc=$?
# Trust only the PR state GitHub reports. Right after a merge it can still read OPEN, and a gh
# error can hide a merge that happened, so keep reading before deciding.
# "last" holds only the newest read; a failed read clears it.
last=""
for _ in 1 2 3 4 5 6; do
  last=""
  if after="$(ghr pr view "$PR" --json state,headRefOid 2>/dev/null)" &&
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$after"; then
    last="$(jq -r .state <<<"$after")"
    on_final_state "$last" "$(jq -r .headRefOid <<<"$after")"
  fi
  sleep "$POLL_SECONDS"
done
if [ "$last" = OPEN ] && [ "$merge_rc" != 0 ]; then
  stop 1 "merge of PR #$PR was refused and the PR is still open: $merge_out"
fi
stop 5 "outcome of the merge of PR #$PR is unknown: check 'gh pr view $PR --json state' before anything else"
