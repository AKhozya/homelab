---
name: worktree-cleanup
description: Use after a PR merges (including squash merges) or when asked to clean up stale git worktrees or local branches. Removes merged or squash-merged clean worktrees and their branches, plus orphan branches whose upstream is gone. A squash-merged branch is deleted only if origin/HEAD holds its exact change. Dry-run by default.
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
| `MERGED-CLEAN` | removes the worktree and its branch (`git branch --delete`) |
| `SQUASH-MERGED` | removes the worktree and its branch (`git update-ref -d <ref> <oid>`), printing `restore: git -C <repo> branch <name> <oid>` |
| `FRESH` (branch never moved since creation) | a scan keeps it. If you name its path, the script removes it |
| `DIRTY`, `UNMERGED`, `LOCKED`, `PRUNABLE`, `MAIN` | nothing |

A scan also checks orphan branches, those with no worktree: every `wt-*` branch, and every branch whose upstream is gone. It deletes them under the same merged and squash-merged rules, keeps the rest as `UNMERGED`, then runs `git worktree prune`. The scan never touches a branch outside `wt-*` that has no upstream.

**Squash-merged** means: the branch changed at least one path since its merge base with `origin/HEAD`, and every such path holds the same mode and blob on `origin/HEAD` as on the branch tip. The script compares them with the plumbing command `diff-tree --no-renames`, which reads no diff config, attributes or merge drivers. A rebase-merged branch gets the same verdict.

| The script keeps the branch if | Because |
|---|---|
| main edits one of those paths after the merge, even in an unrelated line | the rule is strict on purpose. In one app repo, most old branches touched `NEXT.md` |
| GitHub resolved a conflict in a path the branch changed, and the result differs from the branch tip | the merged blob differs from the branch tip |
| the branch has no net change | nothing proves it merged |
| `origin/HEAD` is unset | there is no remote default branch to compare against. `git remote set-head origin -a` sets it |

The squash check compares against `origin/HEAD`, not the branch the primary worktree has checked out, because the squash merge happens on the remote.

| Rejected check | Why |
|---|---|
| `git cherry` | its patch ids ignore whitespace and line position, so a different change can match |
| `git merge-tree` tree equality | a merge driver (`merge=ours`, `merge.default`) or `merge.renormalize` can drop the branch's side and still return main's tree |

Self-check: `~/.agents/skills/_shared/worktree-cleanup-selfcheck.sh` builds a scratch repo with a bare remote and checks 29 cases. They include a dry run that changes nothing, kept branches still at their original tips, a mode-only change, a branch with no net change, unmerged and dirty worktrees that survive, a repo path with a space and an apostrophe, hostile merge and diff config, the primary worktree on another branch, an unset `origin/HEAD`, and a restore command that brings back the same commit from another directory. Run it after any edit to the script.

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
- "Upstream gone" comes from the last `git fetch --prune`. The script does not fetch, so run that first.
- `validate-safe-bash.sh` blocks the common spellings of a force delete (`-D`, `-df`, `-d -f`, `--delete --force`, quoted or escaped flags and paths, `git -C <dir> branch -D`, `bash -c "..."`). It splits the command with Python's `shlex`, so a `grep` or an `echo` that holds such a command is blocked too. If you test that rule, put the cases in a file. Known gaps, accepted on 2026-11-07 after seven review rounds: a force spelling other than plain `-D` inside backticks or before a `#` comment, a quoted subcommand (`git 'branch' -D`), `git update-ref -d`, and, if python3 is missing, a flag with quotes inside it. The settings deny rule `Bash(*git branch -D*)` was removed on 2026-11-05, because its glob ignores case and so also blocked the safe `-d`.
- `--repo` takes a PATH, not a repo name — `--repo homelab` exits 3 `not a git repo`.
- Eviction only covers brokers this script is about to strand. A broker whose worktree was
  already deleted, or one simply left over from an old session, is invisible here — the broker
  has no idle timeout and never reaps itself. Those are `_shared/codex-hygiene.sh`, run before
  every Codex dispatch.
- `UNMERGED` orphan branches accumulate (abandoned experiments). Script surfaces them but never deletes; review manually and force-delete yourself if truly dead.
- Merged-ness = worktree **HEAD oid** is ancestor of the main worktree's checked-out branch (full ref — tag-shadow-safe; correct for detached HEADs). Rebase-then-merge histories still pass.
- **Gitignored files don't count as dirty** — a worktree holding only ignored artifacts (build output, node_modules) is removable. Ignored ≠ work.
