# Open-source prep — plan (2026-09-26)

Goal: make `AKhozya/homelab` fit to publish. Five sub-projects, run in order. Each one
gets its own spikes and approval before work starts. SP1 is planned in full below; SP2–SP5
record the decisions already made and the spikes still owed.

## Decisions (operator, 2026-09-26)

| # | Question | Answer |
|---|---|---|
| 1 | New home for `docs/scripts/node-maintenance/` | `node-maintenance/` at repo root. Loose scripts go to `scripts/` |
| 2 | Skills: source of truth | Snapshot copy in this repo. A monthly-review step re-syncs it, so the copy never goes stale |
| 3 | Global rules (`~/.claude/CLAUDE.md`) | Publish a sanitized export |
| 4 | LAN IPs, SSH port, usernames, hostnames, domain | Keep as-is |
| 5 | Docs disposition | CODEMAPS → `docs/subsystems/`; `.backup/README.md` → `docs/`. HISTORY / plans disposition is proposed in SP3 |
| 6 | Anti-slop pass | `avoid-ai-writing` skill |
| 7 | Delete + recreate repo to drop 436 `refs/pull/*` | No. Residual accepted |
| 8 | Cloudflare account ID in history | Accepted. Cloudflare treats account and zone IDs as non-secret identifiers |
| 9 | Licence | MIT |

## Roadmap

| SP | Scope | Depends on |
|---|---|---|
| SP1 | Move node-maintenance tree + loose scripts out of `docs/` | — |
| SP2 | Snapshot skills, `_shared/` helpers and sanitized rules into the repo; monthly re-sync step | SP1 (skills cite the new path) |
| SP3 | Docs pass: staleness, duplication, `avoid-ai-writing`, README + mermaid, CODEMAPS rename | SP1, SP2 |
| SP4 | Pre-public gate: full-history gitleaks + PR-ref sampling, MIT `LICENSE`, visibility flip | SP3 |
| SP5 | Ultrareview (`/code-review ultra`, operator-triggered) | SP4 |

---

## SP1 — move node-maintenance out of `docs/`

### The coupling that shapes the plan

All syncs run on the CP only. Every 10 min `node-maintenance-sync.service` runs the
**installed** copy `/usr/local/sbin/node-maintenance-sync-from-git.sh` (root, mode 0750).
That copy pulls `/var/lib/node-maintenance/homelab` and then calls
`$REPO_DIR/docs/scripts/node-maintenance/install.sh --sync-only`
(`lib/sync-from-git.sh:57`). A one-commit move makes that call fail on the first sync.

So the move ships in two commits, with a symlink bridge between them:

| Step | Commit | What the CP does on its next sync |
|---|---|---|
| A | move tree, leave `docs/scripts/node-maintenance → ../../node-maintenance`, fix line 57 | old installed script follows the symlink; `install.sh:23` resolves `realpath "$0"` to the new tree; `install.sh:134` installs the **new** sync script |
| — | verify on the CP (below) | — |
| B | delete the symlink | new installed script calls `node-maintenance/install.sh` directly |

### Spike results

| # | Question | Probe | Result |
|---|---|---|---|
| S1 | Who clones the repo on nodes? | read `install-worker.sh`, `sync-from-git.sh` header | ✅ CP only. Workers get config from the CP over ansible; `install-worker.sh` has no clone |
| S2 | Does anything installed on the CP hardcode the path outside the clone? | `systemctl cat` both units; `grep -rl docs/scripts /etc/systemd/system /etc/node-maintenance` over SSH | ✅ one hit: the `Documentation=` URL in `k3s-wait-ready.service` (text only) |
| S3 | What fires when `k3s-wait-ready.service` changes? | read `roles/k3s_config/tasks` + `handlers` | ✅ `Reload systemd` → `daemon_reload` only. No k3s restart |
| S4 | Does git swap a directory for a symlink under `--depth=50` fetch + `reset --hard`? | scratch repo mirroring the node flow, clean clone and clone with an untracked file | ✅ both `rc=0`, symlink in place, `realpath` lands in the new tree. Run on macOS git; nodes run Arch git (🟡 platform) |
| S5 | Is it safe for `install.sh` to overwrite the sync script while it runs? | `git log` on `lib/sync-from-git.sh` | ✅ 4 prior edits (`2af08707`, `af2994a2`, `c387ffba`, `fc95af34`) shipped through the same self-overwrite |
| S6 | Can I read the installed script to verify it? | `ls -l` / `head` over SSH | 0750 root, not readable. `ls -l` works: installed size **2830** B = repo size. After commit A expect **2817** B (13 B shorter path) |
| S7 | Do CI / pre-commit / lint gates hardcode the path? | `rg` over `.github/`, `.pre-commit-config.yaml`, `scripts/ci/`, `.yamllint.yaml`, `renovate.json` | ✅ all repo-wide `find .`; only two comments mention `docs/scripts` |
| S8 | Live cluster objects (ConfigMaps, Secrets, VMRules) citing the path? | `kubectl get cm,secret -A` + `vmrules,prometheusrules` grep | ✅ 0 |
| S9 | Other repos under `~/source-code` | `rg` per repo | ✅ only the dotfiles clone (same content as the chezmoi source) |
| S10 | Loose scripts run by automation? | name grep across repo, skills, memory | ✅ all are manual bootstrap/usage; hits are usage comments and docs |
| S11 | claude-telegram bot memory | `kubectl exec … grep` + inode compare | ✅ the bot's homelab memory is the chezmoi-applied dotfiles copy (same inode across both project dirs). Refreshes at pod start via `chezmoi-init`. No separate edit |
| S12 | Concurrent worktree `wt-heal-alert-exclude` | `git status` | ✅ touches only `monitoring/configs/victoria-metrics/vmrules.yaml`. No overlap |

### Assumptions and cut corners

| Tier | Item |
|---|---|
| 🟡 | S4 ran on macOS git, not Arch git. Same upstream checkout logic; commit B's verify catches a failure |
| 🟡 | The CP clone has no untracked files that would block the swap. Not readable without sudo; S4 shows an untracked file does not block it anyway |
| 🟡 | Codex regenerates `~/.codex/memories/memuser/MEMORY.md` from its own sources and could re-introduce the old path. Edit it anyway; it is text, not a code path |
| ⚠️ | `docs/HOMELAB_HISTORY.md` entries and `docs/plans/*` keep the old path. They are dated records; rewriting them falsifies history. SP3 decides whether plans stay public |
| ⚠️ | `~/.codex/memories/memrestore.bHYz8f/` (a restore snapshot) keeps the old path. Left alone |
| ⚠️ | Commit B is a one-line symlink delete; it gets a delta-scoped Codex review, not a full one |

### Files touched by commit A

**Moves (`git mv`):**

| From | To |
|---|---|
| `docs/scripts/node-maintenance/` | `node-maintenance/` |
| `docs/scripts/{ansible-apply,setup-claude-telegram,setup-node,update-firmware}.sh` | `scripts/` |
| `docs/worker-node-post-install.sh` | `scripts/` |
| `docs/scripts/runbooks/authentik-passkey-rollback.md` | `docs/runbooks/` |

Plus the bridge: `ln -s ../../node-maintenance docs/scripts/node-maintenance` (git mode `120000`).

**Functional edits:**

| File:line | Change |
|---|---|
| `node-maintenance/lib/sync-from-git.sh:57` | `$REPO_DIR/node-maintenance/install.sh` |
| `node-maintenance/install.sh:50` | printed `sops` hint path |
| `node-maintenance/ansible/roles/k3s_config/files/k3s-wait-ready.service:3` | `Documentation=` URL |
| `scripts/setup-node.sh:8,229,240` | usage paths |
| `scripts/setup-claude-telegram.sh:5-6`, `scripts/ansible-apply.sh:6` | usage paths |
| `.github/workflows/validate.yaml:10`, `.pre-commit-config.yaml:41` | comments |

**Doc edits:** `AGENTS.md`, `.claude/review-invariants.md` (3), `node-maintenance/README.md` (8),
`node-maintenance/ANSIBLE_REVIEW_PLAN.md`, `docs/setup/K3S_SETUP.md`, `docs/FIREWALL_SECURITY.md`,
`docs/BACKUP_STRATEGY.md`, `docs/CODEMAPS/networking.md`, `docs/HOMELAB_ANALYSIS.md` (if it cites
the path), plus one new `docs/HOMELAB_HISTORY.md` entry.

### Gates before commit A

```bash
rg -n 'docs/scripts|docs/worker-node-post-install' --hidden -g '!.git' -g '!.claude/worktrees' \
  -g '!docs/HOMELAB_HISTORY.md' -g '!docs/plans/**'          # expect 0
git ls-files -s docs/scripts/node-maintenance                # expect mode 120000
test -f docs/scripts/node-maintenance/install.sh             # bridge resolves
wc -c node-maintenance/lib/sync-from-git.sh                  # expect 2817
shellcheck -S warning node-maintenance/**/*.sh scripts/*.sh
yamllint -c .yamllint.yaml node-maintenance
(cd node-maintenance/ansible && ansible-lint)                # if installed; else record as skipped
```

Then the pre-commit review loop (Codex, `codex-review.sh`, against `.claude/review-invariants.md`).

### Rollout

1. Commit A in `wt-oss-prep` → merge to `main` → push. No `fr` needed: nothing Flux reconciles changed.
2. Wait for the next CP sync (≤10 min), then check over SSH, read-only:
   - `journalctl -u node-maintenance-sync --since=-15min` shows `HEAD … → <A-sha>`, `Sync applied`, and `Deactivated successfully`
   - `ls -l /usr/local/sbin/node-maintenance-sync-from-git.sh` shows **2817** bytes and a fresh mtime
   - the chained `node-maintenance-config.service` run finished (`systemctl show -p ActiveState,Result`; `ActiveState` first, since `Result` is stale mid-run)
3. Commit B: `git rm docs/scripts/node-maintenance` (+ `rmdir docs/scripts` if empty) → review → merge → push.
4. Next sync: the same journal check. Success here proves the new installed script runs without the bridge.

### Off-repo updates (after commit A merges)

The new path is valid from commit A onward, so these can land between A and B.

| Surface | Files | How |
|---|---|---|
| Skills (`~/.agents/skills`) | `homelab-node-fix/SKILL.md` (2), `homelab-node-fix/reference-incidents.md:90` (an on-node `rsync` recovery command, **functional**), `homelab-monthly-review/SKILL.md` (2), `gitops-workflow/SKILL.md:86` | edit → `chezmoi-sync` |
| Claude memory (homelab project) | 11 files, 14 lines, incl. `reference_ansible_roles.md` (6) | edit → `chezmoi-sync` |
| Codex memory | `~/.codex/memories/memuser/MEMORY.md:2158,2349,2350` | direct edit (not chezmoi-managed) |
| claude-telegram bot | none — inherits dotfiles on next pod start | — |

Verify: re-run the home sweep; expect 0 strict hits outside `memrestore.*`.

### Rollback

The installed script's size decides the fix, because a revert only helps the script that
knows the old path.

| Failure after A (Telegram alert fires) | Installed size | Fix |
|---|---|---|
| `reset --hard` or the bridge failed, so `install.sh` never ran | 2830 (old) | `git revert` A. The old script and the old layout match again |
| `install.sh` ran, something later failed (for example the playbook) | 2817 (new) | Fix forward. Do **not** revert A: the new script would then call a path the reverted tree lacks |
| Neither works | either | Operator runs `sudo bash /var/lib/node-maintenance/homelab/node-maintenance/install.sh --sync-only` on the CP |

| Failure after B | Fix |
|---|---|
| Sync fails | `git revert` B restores the bridge. The installed script is already the new one, so no size check is needed |

---

## SP2 — skills, helpers and rules in the repo (outline)

Decided: snapshot copy under `agents/` (outside `.claude/skills/`, so Claude Code does not
double-load them as project skills). Monthly review gains a re-sync step.

Spikes owed before its plan:

- **Scope (open question):** default is the ~31 homelab-coupled skills + the operator's own generic ones; vendored bundles (firecrawl ×36, hyperframes, Matt Pocock's set, …) excluded for licence reasons. Needs provenance per skill (lock file, git log in dotfiles).
- Codex-only skills: `~/.codex/skills` holds 97 entries; diff against `~/.agents/skills`.
- Secret/PII scan of every file that would be copied (gitleaks + `pii-scrub`).
- Sanitized export of `~/.claude/CLAUDE.md`: strip email, 1Password item names, other-project names and incident narrative tied to them.
- The re-sync mechanism: one script that copies the allowlisted set and exits non-zero on drift, run by `homelab-monthly-review`.

## SP3 — docs pass (outline)

Scope: every `*.md` in the repo. Checks: staleness against the live cluster (re-derive counts
and versions), duplication across docs, `avoid-ai-writing` pass, README + mermaid currency.
Renames: `docs/CODEMAPS/` → `docs/subsystems/` (touches `AGENTS.md`, README, the ECC
`update-codemaps` convention); `.backup/README.md` → `docs/` (CI's sops check prunes `.backup/`,
DR scripts stay). Proposes disposition for `HOMELAB_HISTORY.md` (4,002 lines), `docs/plans/`,
`ANSIBLE_REVIEW_PLAN.md`.

## SP4 — pre-public gate (outline)

- `gitleaks git` over full history; pickaxe for every previously rotated value; sample `refs/pull/*/head` tips.
- Absolute `/Users/akhozya/…` paths in `.claude/settings.json` and hooks: decide keep or genericize.
- Add MIT `LICENSE`.
- Visibility flip is the operator's action, after the gate passes.

## SP5 — ultrareview

Operator runs `/code-review ultra` on the repo after SP4.
