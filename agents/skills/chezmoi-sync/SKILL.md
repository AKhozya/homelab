---
name: chezmoi-sync
description: "AUTO-FIRE skill for the agent (not user-facing). When the agent finishes developing AND testing any edit under chezmoi-tracked paths (~/.claude/, ~/.agents/ incl. skills, ~/.zshrc, ~/.gitconfig, ~/.ssh/config, ~/.config/, ~/.Brewfile), sync to chezmoi source + commit + push to AKhozya/dotfiles WITHOUT asking. If testing requires user (cluster smoke, GUI, manual verify), prompt user once for confirmation, then sync immediately on yes. Handles re-add vs forget decision tree, template/secret-aware syncing, and pre-commit secret scan."
user-invocable: false
---

# Chezmoi Sync Skill (agent internal)

Sync dotfile edits to chezmoi source + push to dotfiles repo. **This skill is for the agent (Claude or Codex). User does not type `/chezmoi-sync`.**

## Auto-fire trigger (mandatory)

Fire this skill automatically when BOTH conditions hold:
1. **Edit touched a chezmoi-tracked path** (see paths list below).
2. **The change is verified done** — either:
   - The agent tested itself (lint passed, smoke ran, behavior confirmed), OR
   - The agent cannot test (needs cluster, GUI, manual interaction) AND user has confirmed it works.

### Decision rules

| Situation | Action |
|---|---|
| Agent tested + green | Sync + push immediately. NO confirmation prompt. |
| Agent can't test (cluster smoke, manual UI verify needed) | Prompt user once: "Confirm working before I sync to dotfiles?" — on yes, sync + push immediately. |
| Mid-development (still iterating) | Do NOT sync. Wait for "done" signal. |
| Pure docs/comments edit | Sync without test confirmation. |

**Never** ask "should I push to chezmoi?" after a green test (memory: feedback.md `Chezmoi push — no ask`).

## Tracked paths

- `~/.claude/**` (settings, hooks, agents, projects/memory; `skills/` entries are symlinks)
- `~/.agents/**` (canonical skill sources — `~/.claude/skills/` and `~/.codex/skills/` symlink here; skill edits land in this tree and MUST fire this sync)
- `~/.zshrc`, `~/.gitconfig`, `~/.ssh/config`, `~/.hushlogin`
- `~/.config/**` (nvim, gh, git, starship, ghostty)
- `~/.Brewfile`, `~/.local/bin/brewfile-sync`
- macOS-only: `~/Library/Application Support/k9s/**`, ghostty config

## Decision Tree

1. **`chezmoi status`** — see drift first.
2. Status flags (col1 = source vs last-apply, col2 = actual vs target):
   - `MM` = dest modified locally + target differs. Likely re-add.
   - `DA` = source has, dest missing. `chezmoi forget` if obsolete.
   - `AA` = new file, not yet tracked. `chezmoi add`.
3. **`chezmoi diff`** — see exact lines. `+` = source-side, `-` = dest-side.
4. Decide per file:
   - Already tracked + want local edits in source → `chezmoi re-add <path>`
   - New file → `chezmoi add <path>`
   - Source has stale entry not in dest → `chezmoi forget --force <path>`
   - Timestamp-only diff (e.g., `known_marketplaces.json` `lastUpdated`) → **skip**

## Commands

```bash
chezmoi status
chezmoi diff
chezmoi re-add <path>            # tracked file, push dest→source
chezmoi add <path>               # new file
chezmoi forget --force <path>    # untrack (--force skips TTY prompt)
chezmoi managed | grep <name>    # check tracked
chezmoi source-path <dest-path>  # find source location
```

## Commit + push (after sync)

```bash
git -C ~/.local/share/chezmoi status --short
git -C ~/.local/share/chezmoi add -A
git -C ~/.local/share/chezmoi commit -m "<single line, no AI-agent mention>"
git -C ~/.local/share/chezmoi push
```

**Always use `git -C ~/.local/share/chezmoi`** — `cd && git` breaks safe-bash allow pattern.

**If the commit fails with `fatal: failed to write commit object` and an `error: 1Password:` line (seen: `agent returned an error`, `Could not connect to socket`, earlier `failed to fill whole buffer`)**, the commit-signing key is blocked (1Password locked / no biometric surface from the agent shell). Staging survives.
1. Retry the same commit once unsigned: `git -C ~/.local/share/chezmoi -c commit.gpgsign=false commit ...` (the user's rule: an unsigned commit is fine if 1Password is locked, for example by a locked screen; do not stop to ask for an unlock first).
2. If that retry fails too, stop and report it. Do not retry-loop.

## Gotchas

- **Source path uses `private_` / `dot_` prefixes (and sometimes `.tmpl`)**: `~/.claude/settings.json` → `dot_claude/settings.json.tmpl`. Use `chezmoi source-path` to find.
- **If `source-path` says "not managed" for a skill file**, read reference-edge-cases.md before you conclude the file is untracked.
- **A skill file can be under edit by another session right now.** If you need the incident, read reference-edge-cases.md § "Two sessions editing one skill file". Check `ls -l` mtime before editing, prefer small exact-match edits over a rewrite, and after editing grep for the other session's sections to prove you did not clobber them.
- **Templates**: `.zshrc`/`.ssh/config`/`.claude/settings.json` are `.tmpl` files (OS-gated `{{ .chezmoi.os }}` etc.). Edit the `.tmpl` directly in source — `re-add` writes raw and breaks templating.
- **Live-ahead-of-template drift → NEVER `chezmoi apply`**: if an earlier session edited LIVE `settings.json` (model, enabled plugins) but never synced to the `.tmpl`, `chezmoi diff` shows the stale template as the "target" — `chezmoi apply`/`update` would REVERT live (disable a plugin, flip model). CHECK `chezmoi diff <file>` first; if live is truth, sync live→template by editing the `.tmpl` DIRECTLY (not `re-add` — breaks `{{ }}`; not `apply` — reverts live), then `chezmoi diff` empty = reconciled. If you need the incident, read reference-edge-cases.md § "Live-ahead-of-template drift incident".
- **Plugin marketplace timestamps**: `.claude/plugins/known_marketplaces.json` `lastUpdated` drifts every session. Skip unless plugins changed.
- **`.chezmoiignore` linux-side**: excludes mac-only files (Library, Brewfile, ghostty, starship.toml, .ssh, source-code, macos-defaults.sh) — don't track those for linux nodes.
- **Secret leak**: pre-commit chezmoi hook may scan with `--secrets`. For known-safe files (plugin caches), pass `--secrets ignore` if blocked.

If the change must reach the K3s nodes, read reference-edge-cases.md § "After dotfile sync to nodes".

If you want the whole sync as one block, read reference-edge-cases.md § "End-to-end fast path (after verified done)".

## Pre-commit gate (mandatory — mirrors homelab pre-commit review loop)

If only config values change, skip this gate. If every changed file is under `~/.claude/projects/*/memory/` and is a memory note or the `MEMORY.md` index, skip this gate too. Agents write these notes many times a day. Other docs and Markdown changes, SKILL.md text included, get the peer review (steps 2–4): nothing tests a doc, so a wrong fact outlives a wrong line of code.
Any NEW or substantively CHANGED script/skill logic (`.sh`, `.py`, hook, SKILL.md workflow steps):

1. **Lint matrix** — every touched file type, all must pass:
   | Type | Gate |
   |---|---|
   | `.sh` | `shellcheck` + `shfmt -i 2 -d` (via `/bash-scripting`) |
   | `.py` | `uv run --with ruff ruff check` |
   | YAML | `yamllint` (K8s YAML → `/homelab-yaml-validate`) |
   | JSON | `jq empty <file>` |
   | TOML | `taplo check` |
   | `.js`/`.ts` | `node --check` / `bunx tsc --noEmit` if tsconfig present |
2. **Peer static review** — resolve the opposite-family reviewer with `peer-reviewed-implementation/scripts/reviewer-peer`, and take the action `peer-reviewed-implementation` (step 7) gives for its return value, `self-review` included. The review is file-reads only. Report the result of each check that ran (lint matrix, tests), and name each check you skipped. Ask for a verdict in one message. Include intent + tested behaviors in the prompt.
3. Read the round outcome from the round table in `~/.codex/AGENTS.md` (heading "Round table") first. A finding you dispute counts as open. If the round table calls for fixes, verify each finding against the code. If a finding is unclear, ask about it before you fix anything. If a finding is incorrect or asks for an unnecessary change, record why you dispute it. Fix the rest in severity order and re-test each fix. If the round table calls for another round, re-review the change since the last round, with each open finding, its disposition and the current text of the lines it cites.
4. If the round table permits a commit, commit and push. If it says to stop, give the open findings to the user.

If you need the reason for the pre-commit gate, read reference-edge-cases.md § "Why the pre-commit gate exists".

## Tools Allowed
- `Bash(chezmoi *)`
- `Bash(git -C ~/.local/share/chezmoi *)`
- `Edit`, `Write`, `Read`
