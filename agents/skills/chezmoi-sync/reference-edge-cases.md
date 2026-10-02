# Chezmoi Sync — edge cases and history

Read this when `chezmoi source-path` reports a skill file as not managed, or when you need the incident behind the pre-commit gate.

## `source-path` reports a symlinked skill as not managed

- **`source-path` says "not managed" for a SYMLINK — that does not mean untracked.** Most of `~/.claude/skills/*` are symlinks into `~/.agents/skills/*`; the real file is tracked at the target. `chezmoi source-path ~/.claude/skills/<name>/SKILL.md` reports `not managed` and reads as "this skill isn't in dotfiles", which is wrong and was reported to the user as fact on 2026-08-07. Resolve the link first (`ls -ld`, or compare inodes with `stat -f %i`) and run `chezmoi status | grep <name>` — an `MM` under `.agents/skills/` is the truth. Add via the `~/.agents` path.

## Why the pre-commit gate exists

Origin 2026-07-04: worktree-cleanup.sh shipped unreviewed; post-hoc Codex found a HIGH (detached-HEAD worktree falsely MERGED-CLEAN → removable with unique commits). Gate exists so that never repeats.
