# Chezmoi Sync — edge cases and history

Read this when `chezmoi source-path` reports a skill file as not managed, or when you need the incident behind the pre-commit gate.

## `source-path` reports a symlinked skill as not managed

- **`source-path` says "not managed" for a SYMLINK — that does not mean untracked.** Most of `~/.claude/skills/*` are symlinks into `~/.agents/skills/*`; the real file is tracked at the target. `chezmoi source-path ~/.claude/skills/<name>/SKILL.md` reports `not managed` and reads as "this skill isn't in dotfiles", which is wrong and was reported to the user as fact on 2026-08-07. Resolve the link first (`ls -ld`, or compare inodes with `stat -f %i`) and run `chezmoi status | grep <name>` — an `MM` under `.agents/skills/` is the truth. Add via the `~/.agents` path.

## Why the pre-commit gate exists

Origin 2026-07-04: worktree-cleanup.sh shipped unreviewed; post-hoc Codex found a HIGH (detached-HEAD worktree falsely MERGED-CLEAN → removable with unique commits). Gate exists so that never repeats.

## When the signing failure was seen

Seen 2026-07-16.

## Two sessions editing one skill file

**A skill file can be under edit by another session right now.** Two sessions extended `comment-sweep/SKILL.md` on 2026-08-07 within the same hour.

## Live-ahead-of-template drift incident

Seen 2026-07-07: live `opus[1m]`+skillopt-enabled vs template stale `fable-5`+skillopt-absent; apply would've disabled skillopt-sleep.

## After dotfile sync to nodes

K3s nodes pull via `chezmoi update`:
```bash
ssh_master_node "chezmoi update"
ssh_worker_node "chezmoi update"
ssh_worker_node2 "chezmoi update"
```

## End-to-end fast path (after verified done)

```bash
chezmoi status                                    # see drift
chezmoi diff                                      # confirm content
chezmoi re-add <path>                             # OR chezmoi add / forget per decision tree
git -C ~/.local/share/chezmoi add -A
git -C ~/.local/share/chezmoi commit -m "<single-line subject, no AI-agent mention>"
git -C ~/.local/share/chezmoi push
```
