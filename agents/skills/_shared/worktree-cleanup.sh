#!/usr/bin/env bash
# worktree-cleanup.sh — scan/remove merged+clean git worktrees and their wt-* branches.
#
# usage: worktree-cleanup.sh [--repo DIR] [--apply] [WORKTREE_PATH]
#   default        dry-run scan: verdict per worktree + orphan wt-* branches
#   WORKTREE_PATH  target a single worktree (post-task cleanup)
#   --apply        perform removals (dry-run otherwise)
#
# Verdicts: MERGED-CLEAN (removable) | DIRTY | UNMERGED | LOCKED | PRUNABLE | MAIN
# Branch deletion is always non-force (git branch --delete) — unmerged work survives.
# Merged-ness tested on the worktree HEAD oid (detached-safe, tag-shadow-safe).
# Gitignored files do NOT count as dirty — declared disposable by definition.
# Exit: 0 ok, 2 bad args, 3 not a git repo.
set -euo pipefail

REPO=. APPLY=0 TARGET=""
while (($#)); do
  case "$1" in
  --repo)
    REPO="$2"
    shift 2
    ;;
  --apply)
    APPLY=1
    shift
    ;;
  -h | --help)
    grep -E '^#( |$)' "$0" | cut -c3-
    exit 0
    ;;
  *)
    TARGET="$1"
    shift
    ;;
  esac
done
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "not a git repo: $REPO" >&2
  exit 3
}
if [[ -n $TARGET ]]; then
  RESOLVED=$(cd "$TARGET" 2>/dev/null && pwd) || {
    echo "not a directory: $TARGET" >&2
    exit 2
  }
  TARGET="$RESOLVED"
fi
MAIN_WT=$(git -C "$REPO" worktree list --porcelain | awk '/^worktree /{print substr($0,10); exit}')
# full symbolic ref (refs/heads/…) so a same-named tag can never shadow it
DEFAULT=$(git -C "$MAIN_WT" symbolic-ref HEAD 2>/dev/null || echo refs/heads/main)

act() { # act <desc> <cmd...>
  local desc="$1"
  shift
  if ((APPLY)); then
    if "$@"; then
      echo "REMOVED  $desc"
    else
      echo "FAILED   $desc" >&2
    fi
  else
    echo "would remove  $desc"
  fi
}

# A Codex broker and its app-server child pin cwd at spawn. Delete the directory under them
# and both stay alive on an unnamed inode — nothing crashes, nothing logs, and every later
# Codex turn aborts mid-flight with turn_aborted/interrupted. Evict before removing, not after.
# Scoped to broker processes on purpose: a user shell parked in the worktree is harmless, and
# killing it would not be. Anchored to the plugin's real argv, since `pgrep -f` on a bare name
# also selects a grep or an editor that merely mentions it.
BROKER_RE='app-server-broker\.mjs serve( |$)|/codex app-server$|/codex-code-mode-host$'

# Returns non-zero when a broker is still holding the directory, so the caller skips removal.
# Removing it anyway is what strands the broker in the first place.
evict_brokers() { # evict_brokers <worktree-path>
  local root="$1" root_raw="$1" pid cwd argv chain p rc=0
  # A MERGED-CLEAN worktree was just stat'd by git, so failing to resolve it here means
  # something unexpected (permissions, a race) — not "already gone". Block rather than assume.
  root=$(cd "$root" 2>/dev/null && pwd -P) || {
    echo "BLOCKED  cannot resolve $root_raw — not removing it" >&2
    return 1
  }
  if ! command -v lsof >/dev/null 2>&1; then
    # No lsof: harmless when no broker exists at all, unsafe to guess otherwise. pgrep exits 1
    # for "no match" and 2/3 for its own failures — only the first means "none", so anything
    # else has to block rather than read as an all-clear.
    pgrep -f "$BROKER_RE" >/dev/null 2>&1 && rc=0 || rc=$?
    if ((rc == 1)); then return 0; fi
    if ((rc > 1)); then
      echo "BLOCKED  pgrep failed (exit $rc) — cannot prove no broker holds $root" >&2
      return 1
    fi
    echo "BLOCKED  no lsof — cannot prove no broker holds $root" >&2
    return 1
  fi
  chain="" p=$$
  while [[ -n $p && $p -gt 1 ]]; do
    chain="$chain $p"
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ' || true)
  done
  for pid in $(pgrep -f "$BROKER_RE" 2>/dev/null || true); do
    cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | tail -1 || true)
    [[ -n $cwd ]] || continue
    # Fall back to the raw path when it will not resolve (already-deleted cwd) rather than
    # skipping the process: an unresolvable path must not read as "not in this worktree".
    cwd=$(cd "$cwd" 2>/dev/null && pwd -P || echo "$cwd")
    # Compare against both spellings: an unresolvable cwd keeps its raw path, which may match
    # the pre-canonical root even when it cannot match the resolved one.
    [[ $cwd == "$root" || $cwd == "$root"/* || $cwd == "$root_raw" || $cwd == "$root_raw"/* ]] ||
      continue
    # Never signal the process tree running this cleanup — that is a Codex turn removing its
    # own worktree, and killing it would abort the very task doing the tidying.
    if [[ " $chain " == *" $pid "* ]]; then
      echo "BLOCKED  broker pid $pid is this process's own ancestor — not removing $root" >&2
      rc=1
      continue
    fi
    if ((APPLY)); then
      # Recheck argv immediately before signalling: the pid may have been recycled since pgrep.
      # Empty output is ambiguous — the process exited, or ps failed while it is still there.
      # Only the first is safe to walk away from, so ask kill -0 which one it was.
      argv=$(ps -o command= -p "$pid" 2>/dev/null || true)
      if [[ -z $argv ]]; then
        if kill -0 "$pid" 2>/dev/null; then
          echo "BLOCKED  cannot read argv of live pid $pid — not removing $root" >&2
          rc=1
        fi
        continue
      fi
      if ! grep -Eq "$BROKER_RE" <<<"$argv"; then
        echo "SKIPPED  pid $pid no longer a broker"
        continue
      fi
      # A failed kill means gone (ESRCH) or alive-but-unsignallable (EPERM); only the first is
      # safe to treat as evicted. kill returning 0 only means the signal was accepted, so the
      # loop below still waits for the process to actually go.
      if ! kill -TERM "$pid" 2>/dev/null; then
        if kill -0 "$pid" 2>/dev/null; then
          echo "BLOCKED  cannot signal broker pid $pid — not removing $root" >&2
          rc=1
        fi
        continue
      fi
      for _ in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
      done
      if kill -0 "$pid" 2>/dev/null; then
        echo "BLOCKED  broker pid $pid survived SIGTERM — not removing $root" >&2
        rc=1
      else
        echo "EVICTED  codex broker pid $pid (cwd $cwd)"
      fi
    else
      echo "would evict   codex broker pid $pid (cwd $cwd)"
    fi
  done
  return $rc
}

# --- worktrees ---
wt_path="" wt_branch="" wt_head="" wt_locked=0 wt_prunable=0
flush() {
  [[ -z $wt_path ]] && return 0
  [[ -n $TARGET && $wt_path != "$TARGET" ]] && return 0
  local verdict
  if [[ $wt_path == "$MAIN_WT" ]]; then
    verdict=MAIN
  elif ((wt_prunable)); then
    verdict=PRUNABLE # dir gone; git worktree prune handles it
  elif ((wt_locked)); then
    verdict=LOCKED
  elif [[ -n $(git -C "$wt_path" status --porcelain 2>/dev/null) ]]; then
    verdict=DIRTY
  elif [[ -z $wt_head ]] ||
    ! git -C "$REPO" merge-base --is-ancestor "$wt_head" "$DEFAULT" 2>/dev/null; then
    verdict=UNMERGED # worktree HEAD oid — correct for detached too
  else
    verdict=MERGED-CLEAN
  fi
  printf '%-13s %s  (branch: %s)\n' "$verdict" "$wt_path" "${wt_branch:-detached}"
  if [[ $verdict == MERGED-CLEAN ]]; then
    if ! evict_brokers "$wt_path"; then
      echo "SKIPPED  $wt_path (broker still holds it)" >&2
      return 0
    fi
    act "worktree $wt_path" git -C "$REPO" worktree remove "$wt_path"
    if [[ -n $wt_branch ]]; then
      act "branch $wt_branch" git -C "$REPO" branch --delete "$wt_branch"
    fi
  fi
}
while IFS= read -r line; do
  case "$line" in
  worktree\ *)
    flush
    wt_path="${line#worktree }" wt_branch="" wt_head="" wt_locked=0 wt_prunable=0
    ;;
  HEAD\ *) wt_head="${line#HEAD }" ;;
  branch\ *) wt_branch="${line#branch refs/heads/}" ;;
  locked*) wt_locked=1 ;;
  prunable*) wt_prunable=1 ;;
  esac
done < <(git -C "$REPO" worktree list --porcelain)
flush

# --- orphan wt-* branches (no worktree, fully merged) ---
if [[ -z $TARGET ]]; then
  inuse=$(git -C "$REPO" worktree list --porcelain | grep -E '^branch ' | sed 's|branch refs/heads/||' || true)
  for b in $(git -C "$REPO" for-each-ref --format='%(refname:short)' 'refs/heads/wt-*'); do
    grep -qxF "$b" <<<"$inuse" && continue
    if git -C "$REPO" merge-base --is-ancestor "refs/heads/$b" "$DEFAULT"; then
      act "orphan merged branch $b" git -C "$REPO" branch --delete "$b"
    else
      echo "UNMERGED      orphan branch $b (kept)"
    fi
  done
  ((APPLY)) && git -C "$REPO" worktree prune
fi
exit 0
