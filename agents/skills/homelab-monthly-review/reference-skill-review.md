# Homelab monthly review — skill review detail

Read this during Phase 2 step 1, when you edit a skill body or when `scripts/sync-agents.sh` exits with a code other than 1.

## Changelog narration and codification

- **Changelog narration**: cut skill-self-history ("built/added X after Y"); KEEP incident dates/SHAs/repro that change operator behavior.
- **Codification**: inline pipelines that are deterministic AND (repeated across skills OR quoting-fragile) → `scripts/` or `_shared/` (reuse before new); invoke by absolute `~/.agents/skills/...` path; remove the inline copy. Check for drifted script COPIES across skills — consolidate to `_shared/`.

## `sync-agents.sh` exit codes other than 1

| Exit of `--check` or `--update` | Action |
|---|---|
| 0 from `--check` | If an earlier row changed a file in this worktree, continue with the commit step of the exit-1 row in SKILL.md. Otherwise nothing to do |
| 0 from `--update` | continue as in the exit-1 row in SKILL.md. If the `CLAUDE.md` source changed, hand-edit `CLAUDE.global.md`. Run `--check` until it exits 0, then review and commit |
| 2 | read each path the report names. If a skill was renamed or deleted, update the allowlist in the repo or the denylist in dotfiles, then run `chezmoi-sync` for the denylist |
| 3, 4 | For a copied skill, helper or `AGENTS.global.md`, fix the source in dotfiles, run `chezmoi-sync`, then run `--update`. For `README.md`, `sync/` or `CLAUDE.global.md`, fix the file in the repo. If a forbidden entry exists only in the target, delete it in the worktree. If git tracks it, remove it with `git rm --cached`. If `origin/main` contains the file or term, decide on a history rewrite before the next push. If the repo is public, GitHub already shows that history. Then run `--check` again |
| 5 | fix the flagged helper's or skill's source in dotfiles, run `chezmoi-sync`, then run `--update` again |
| 70 | read the error, fix its cause, run the mode again |
