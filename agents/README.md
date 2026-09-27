# Agent skills and rules

This folder is a read-only copy of the skills, helper scripts and rules that Claude Code
and Codex use to run this cluster. It is here for readers. No tool loads it.

The authoritative copy lives in the operator's dotfiles, in `~/.agents/skills/` on the Mac
that runs the agents. `~/.claude/skills/` and `~/.codex/skills/` link into that folder.
Edit a skill, a helper or the Codex rules in dotfiles, never here:
`scripts/sync-agents.sh --update` overwrites `skills/` and `rules/AGENTS.global.md` from
dotfiles. `rules/CLAUDE.global.md` is the one file edited here, by hand.

## Layout

| Path | Content |
|---|---|
| `skills/<name>/` | one skill: `SKILL.md`, plus any scripts and reference files it uses |
| `skills/_shared/` | helper scripts that several skills call |
| `rules/CLAUDE.global.md` | the global Claude Code instructions, edited by hand for publication |
| `rules/AGENTS.global.md` | the global Codex instructions, copied unchanged |
| `sync/allowlist.txt` | the skills and helpers that are copied here, one per line |

The rule files are not named `CLAUDE.md` or `AGENTS.md`, because Claude Code loads a
`CLAUDE.md` from any folder it reads a file in.

## Reading the skills

| A skill says | It means |
|---|---|
| `~/.agents/skills/<name>/…` | `skills/<name>/…` in this folder |
| `~/.agents/skills/_shared/<file>` | `skills/_shared/<file>` |
| `~/.claude/CLAUDE.md` or `~/.codex/AGENTS.md` | `rules/CLAUDE.global.md` or `rules/AGENTS.global.md`. The Claude export leaves out personal sections, so a pointer can name a section it no longer has |
| a memory file (`reference_…`, `gotcha_…`, `feedback.md`, `[[…]]`) | the operator's private agent memory, not published |
| a hook (`~/.claude/hooks/…`, the commit-style hook, the command-safety hook) | a local Claude Code hook, not published |

The skills keep their home-folder paths because that is how they find each other when they
run. The repo's own conventions (`AGENTS.md`, `CLAUDE.md`, `.claude/`) apply to changes in
this repo; the skills are how the agents carry them out.

## The review loop

Every substantive code or config change in this repo gets a static review from the other model family
before the commit. Start with these:

| File | Role |
|---|---|
| `skills/peer-reviewed-implementation/SKILL.md` | the workflow: plan, spike the unknowns, peer-review the plan, implement, peer-review the code |
| `skills/_shared/codex-review.sh` | dispatches one Codex review over one file and returns a verdict or a failure exit code |
| `skills/_shared/codex-review-selfcheck.sh` | tests the dispatcher |
| `../AGENTS.md`, "Pre-commit review loop" | when a review round lets a commit through |

## What is left out

| Class | Why |
|---|---|
| third-party skills installed from other repos | not the operator's work; each has its own upstream |
| helpers with no caller, or used only by the dotfiles CI | nothing here would run them |
| Claude Code hooks and settings | local to one machine |
| agent memory | private notes |

`sync/allowlist.txt` names what is in. The list of what is out stays in dotfiles, because it
names every installed skill.

## Refreshing

On the operator's Mac, from a worktree of this repo:

```bash
scripts/sync-agents.sh --update   # copy the allowlisted sources; writes nothing if any check fails
scripts/sync-agents.sh --check    # exit 0 when this folder matches dotfiles
```

| Both modes | Entries or content |
|---|---|
| refuse | a symlink, a `CLAUDE.md`, an `AGENTS.md`, a dot entry other than `.DS_Store` |
| scan for | secrets (`gitleaks` with the repo's `.gitleaks.toml`), and a list of private names kept in dotfiles |

If `~/.claude/CLAUDE.md` changed,
`--check` exits 1 until `rules/CLAUDE.global.md` is edited again and its first line records
the new sha256. The script header lists every exit code.
