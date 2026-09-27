#!/usr/bin/env bash
# merge-worktree.sh — merge a worktree branch into main DETERMINISTICALLY.
#
# Fixes a recurring footgun (hit 3x on 2026-07-06): running `git merge` / `git push`
# from inside a worktree's own cwd merges the branch into ITSELF (no-op "Already up
# to date") and then `git push` publishes the stray feature branch to origin instead
# of updating main. This helper never depends on the caller's cwd for the merge — it
# addresses the primary (main) worktree via `git -C` and pushes an explicit refspec.
#
# Run from anywhere INSIDE the target repo (any of its worktrees). Usage:
#   merge-worktree.sh <branch>              # fetch, ff-only onto origin/main, push
#   merge-worktree.sh <branch> --teardown   # ...then remove THAT worktree + branch
set -euo pipefail

BRANCH="${1:?usage: merge-worktree.sh <wt-branch> [--teardown]}"
MODE="${2:-}"
case "$MODE" in
"" | --teardown) ;;
*)
  echo "ERR: unknown arg '$MODE' (only --teardown accepted)" >&2
  exit 2
  ;;
esac
[ "$BRANCH" != "main" ] || {
  echo "ERR: refusing to merge 'main' into itself" >&2
  exit 2
}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Primary worktree = first `git worktree list` entry (git always lists the main
# worktree first). Resolved from the current repo (wherever this is invoked).
# substr($0,10) — not $2 — preserves worktree paths containing spaces ("worktree ").
PRIMARY="$(git worktree list --porcelain | awk '/^worktree /{print substr($0,10); exit}')"
[ -n "${PRIMARY:-}" ] || {
  echo "ERR: not inside a git repo / no worktree found" >&2
  exit 1
}

git -C "$PRIMARY" show-ref --verify --quiet "refs/heads/$BRANCH" || {
  echo "ERR: branch '$BRANCH' not found" >&2
  exit 1
}

CUR="$(git -C "$PRIMARY" symbolic-ref --short HEAD 2>/dev/null || true)"
[ "$CUR" = "main" ] || {
  echo "ERR: primary worktree is on '$CUR', not main — aborting" >&2
  exit 1
}

if ! git -C "$PRIMARY" diff --quiet || ! git -C "$PRIMARY" diff --cached --quiet; then
  echo "ERR: primary tree has uncommitted tracked changes — commit/stash first" >&2
  exit 1
fi

echo "==> [$PRIMARY] fetch origin main"
git -C "$PRIMARY" fetch origin main
echo "==> ff-only main up to origin/main"
git -C "$PRIMARY" merge --ff-only refs/remotes/origin/main
echo "==> ff-only merge $BRANCH"
if ! git -C "$PRIMARY" merge --ff-only -- "$BRANCH"; then
  echo "ERR: --ff-only failed — main advanced past '$BRANCH'." >&2
  echo "     Rebase the branch onto main first:  git -C <worktree-path> rebase main" >&2
  echo "     then re-run this helper." >&2
  exit 1
fi
echo "==> push origin HEAD:main"
git -C "$PRIMARY" push origin HEAD:main
echo "OK: '$BRANCH' -> main @ $(git -C "$PRIMARY" rev-parse --short HEAD), pushed."

if [ "$MODE" = "--teardown" ]; then
  # Branch-scoped: resolve THIS branch's linked worktree and remove only it
  # (never a repo-wide sweep — that could nuke other in-flight worktrees).
  WT="$(git -C "$PRIMARY" worktree list --porcelain |
    awk -v b="refs/heads/$BRANCH" '/^worktree /{p=substr($0,10)} $0=="branch "b{print p; exit}')"
  if [ -n "${WT:-}" ] && [ "$WT" != "$PRIMARY" ]; then
    echo "==> teardown worktree $WT (+ branch)"
    "$HERE/worktree-cleanup.sh" --repo "$PRIMARY" --apply "$WT"
  else
    echo "==> no linked worktree for '$BRANCH'; deleting branch only"
    git -C "$PRIMARY" branch -d "$BRANCH" 2>/dev/null ||
      git -C "$PRIMARY" update-ref -d "refs/heads/$BRANCH"
  fi
fi
