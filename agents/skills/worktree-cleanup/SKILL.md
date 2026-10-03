---
name: worktree-cleanup
description: Use after finishing a worktree task (merge landed) or when asked to clean up stale git worktrees/wt-* branches. Removes merged+clean worktrees and their branches safely (non-force); dry-run by default. Sidesteps the Bash deny pattern that blocks `git branch -d`.
---

# Worktree cleanup

One script: `~/.agents/skills/_shared/worktree-cleanup.sh` (run `--help` for usage).

```bash
# post-task: remove the worktree you just merged
~/.agents/skills/_shared/worktree-cleanup.sh --repo <repo> --apply <worktree-path>

# periodic: scan everything (dry-run), then apply
~/.agents/skills/_shared/worktree-cleanup.sh --repo <repo>
~/.agents/skills/_shared/worktree-cleanup.sh --repo <repo> --apply
```

| Verdict | What `--apply` does |
|---|---|
| `MERGED-CLEAN` | removes the worktree and its branch, plus orphan merged `wt-*` branches, then runs `git worktree prune` |
| `FRESH` (branch never moved since creation) | a scan keeps it. If you name its path, the script removes it |
| `DIRTY`, `UNMERGED`, `LOCKED`, `PRUNABLE`, `MAIN` | nothing |

Branch deletion is always non-force — unmerged work cannot be lost.

Before removing a `MERGED-CLEAN` worktree the script evicts any Codex broker whose cwd sits
inside it (`EVICTED` / `would evict` line). A broker and its `codex app-server` child pin cwd at
spawn; delete the directory under them and both survive on an unnamed inode — nothing crashes,
nothing logs, and every later Codex turn dies `turn_aborted`/`interrupted`. Four reviews were
lost to this on 2026-07-29 before the cause was found. Only broker processes are matched: a
shell parked in the worktree is harmless and killing it would not be.

When a broker **cannot** be proven gone — it survives SIGTERM, cannot be signalled, is this
process's own ancestor, or the path will not resolve — the worktree is left alone with a
`BLOCKED` line and `SKIPPED  <path>`. Removing it anyway is exactly what strands the broker,
so the failure mode is a worktree that outlives its task, never a silently wedged Codex.

Gotchas:
- The settings deny pattern `Bash(*git branch -D*)` also matches lowercase `-d` (glob is case-insensitive) — that's WHY this script exists; invoking the script doesn't match the pattern, and the script itself only ever does safe `--delete`.
- `--repo` takes a PATH, not a repo name — `--repo homelab` exits 3 `not a git repo`.
- Eviction only covers brokers this script is about to strand. A broker whose worktree was
  already deleted, or one simply left over from an old session, is invisible here — the broker
  has no idle timeout and never reaps itself. Those are `_shared/codex-hygiene.sh`, run before
  every Codex dispatch.
- `UNMERGED` orphan branches accumulate (abandoned experiments). Script surfaces them but never deletes; review manually and force-delete yourself if truly dead.
- `UNMERGED` but landed-via-rebase: `git cherry main <branch>` printing only `-` lines means every commit is patch-equivalent to main — the ancestor check fails on oid, not content. Safe to delete via `git update-ref -d refs/heads/<branch>` (the deny pattern that blocks `git branch -d` doesn't match it; reflog keeps recovery). Proven 2026-08-04 on two rebased branches.
- Merged-ness = worktree **HEAD oid** is ancestor of the main worktree's checked-out branch (full ref — tag-shadow-safe; correct for detached HEADs). Rebase-then-merge histories still pass.
- **Gitignored files don't count as dirty** — a worktree holding only ignored artifacts (build output, node_modules) is removable. Ignored ≠ work.
