# Open-source prep — plan (2026-09-26)

Goal: make `AKhozya/homelab` fit to publish. Six sub-projects run in order. Each one gets
its own spikes and operator approval before work starts. This file plans SP1 in full. For
SP2–SP6 it records the decisions already made and the spikes still to run.

## Decisions (operator, 2026-09-26)

| # | Question | Answer |
|---|---|---|
| 1 | New home for `docs/scripts/node-maintenance/` | `node-maintenance/` at repo root. Loose scripts go to `scripts/` |
| 2 | Skills: source of truth | Snapshot copy in this repo. A monthly-review step re-syncs it |
| 3 | Global rules (`~/.claude/CLAUDE.md`) | Publish a sanitized export |
| 4 | LAN IPs, SSH port, usernames, hostnames, domain | Keep as-is |
| 5 | Docs disposition | CODEMAPS → `docs/subsystems/`. `.backup/README.md` → `docs/`. SP3 proposes what happens to HISTORY and plans |
| 6 | Anti-slop pass | `avoid-ai-writing` skill |
| 7 | Delete + recreate repo to drop 436 `refs/pull/*` | No. The operator accepts the residual |
| 8 | Cloudflare account ID in history | The operator accepts it. Cloudflare treats account and zone IDs as non-secret identifiers |
| 9 | Licence | MIT |

## Roadmap

| SP | Scope | Depends on |
|---|---|---|
| SP1 | Move node-maintenance tree + loose scripts out of `docs/` | — |
| SP2 | Snapshot skills, `_shared/` helpers and sanitized rules into the repo; monthly re-sync step | SP1 (skills cite the new path) |
| SP3 | Docs pass: staleness, duplication, `avoid-ai-writing`, README + mermaid, CODEMAPS rename | SP1, SP2 |
| SP4 | Pre-public gate: history secret scan, `claude.yml` trigger lockdown, MIT `LICENSE` | SP3 |
| SP5 | Ultrareview (`/code-review ultra`, operator-triggered); fix every finding that blocks publishing | SP4 |
| SP6 | Visibility flip (operator action) + branch-protection decision | SP5 |

---

## SP1 — move node-maintenance out of `docs/`

### The coupling that shapes the plan

Only the CP clones the repo. Every 10 min `node-maintenance-sync.service` runs the
**installed** copy `/usr/local/sbin/node-maintenance-sync-from-git.sh` (root, mode 0750).
That copy fetches `/var/lib/node-maintenance/homelab` and runs `git reset --hard`. If HEAD
moved, it then calls `$REPO_DIR/docs/scripts/node-maintenance/install.sh --sync-only`
(`lib/sync-from-git.sh:57`). A one-commit move makes that call fail on the first sync.

**A failed install is never retried.** The reset moves HEAD before `install.sh` runs, so the
next timer run sees an unchanged HEAD, prints `No changes … skip install`, and exits 0
(`sync-from-git.sh:47-50`). The Telegram alert fires once, and `Result=success` ten minutes
later hides the failure. Every recovery row below relies on one of these two triggers:

| Trigger | Who |
|---|---|
| a new commit on `main` | agent or operator |
| `sudo bash …/install.sh --sync-only` on the CP | operator only (agents have no sudo) |

So the move ships in two commits, with a compatibility symlink between them:

| Step | Commit | What the CP does on its next sync |
|---|---|---|
| A | move the tree, add symlink `docs/scripts/node-maintenance → ../../node-maintenance`, fix line 57 | the old installed script follows the symlink. `install.sh:23` resolves `realpath "$0"` to the new tree. `install.sh:134` installs the **new** sync script |
| — | verify on the CP (Rollout step 2) | — |
| B | delete the symlink | the new installed script calls `node-maintenance/install.sh` directly |

### Spike results

| # | Question | Probe | Result |
|---|---|---|---|
| S1 | Who clones the repo on nodes? | read `install-worker.sh`, `sync-from-git.sh` header | ✅ CP only. Workers get config from the CP over ansible; `install-worker.sh` has no clone |
| S2 | Do node files outside the clone hardcode the path? | `grep -rl docs/scripts` over `/etc/systemd`, `/usr/lib/systemd/system`, `/usr/local/sbin`, `/etc/node-maintenance` on all 4 nodes; `systemctl list-timers --all` on the CP | ✅ one hit per node: the `Documentation=` URL in `k3s-wait-ready.service` (text only). Grep exits 2 because root-only files are unreadable. Those files are safe to skip: on the CP they are installed copies of the repo's `lib/` and `ansible/`, which the repo sweep covers, and workers hold no clone, so the old path does not exist there. No cron on the CP: `crontab` is not installed and `/etc/cron.d` does not exist |
| S3 | What fires when `k3s-wait-ready.service` changes? | read `roles/k3s_config/tasks/main.yml:43-50` + handlers | ✅ `Reload systemd` → `daemon_reload` only. No k3s restart. Drift-heal reports `changed` for this file after A; that is expected |
| S4 | Does git swap a directory for a symlink under `--depth=50` fetch + `reset --hard`? | scratch repo mirroring the node flow: one clean clone, one clone with a single untracked file in the directory | 🟡 both `rc=0`, symlink in place, `realpath` lands in the new tree. Ran on macOS git; nodes run Arch git. Rollout step 2 catches a platform difference |
| S5 | Is it safe for `install.sh` to overwrite the sync script while it runs? | `git log` on `lib/sync-from-git.sh` | 🟡 3 prior edits (`af2994a2`, `c387ffba`, `fc95af34`) shipped through the same self-overwrite. Precedent, not proof: Rollout step 2 checks the chained config run finished |
| S6 | Can the operator read the installed script to verify it? | `ls -l` / `head` over SSH | 0750 root, not readable. `ls -l` works: installed size **2830** B equals the repo copy. After A the new copy is **2817** B (13 B shorter path) |
| S7 | Do CI, pre-commit, lint or bot configs key on the path? | read `.github/workflows/*`, `.pre-commit-config.yaml`, `scripts/ci/*`, `.yamllint.yaml`, `renovate.json`, `ansible/.ansible-lint`, `ansible/ansible.cfg`; `ls` for `.gitattributes`, `CODEOWNERS`, `.editorconfig` | 🟡 CI, pre-commit and `scripts/ci` use repo-wide `find .`. `.ansible-lint` and `ansible.cfg` hold no paths. `.gitattributes`, `CODEOWNERS`, `.editorconfig` are absent. **`renovate.json:166-167` ignores `docs/**`**, so the move exposes `node-maintenance/ansible/requirements.yml` to Renovate. Commit A adds `node-maintenance/**` to `ignorePaths` to keep today's behaviour |
| S8 | Do live cluster objects cite the path? | `kubectl get cm,secret -A` + `vmrules,prometheusrules` grep | ✅ 0 |
| S9 | Do other repos under `~/source-code` cite it? | `rg` per repo | ✅ only the dotfiles clone, which holds the same content as the chezmoi source |
| S10 | Does automation run the loose scripts? | name grep across repo, skills, memory; Mac `~/Library/LaunchAgents`, `/Library/Launch*`, `crontab -l`, zsh rc files | ✅ no. All hits are usage comments, docs, or `~/.zsh_history` |
| S11 | Does the claude-telegram bot hold its own copy? | `kubectl exec … grep` + inode compare | ✅ the bot's homelab memory and skills come from the dotfiles. `chezmoi-init` applies them at pod start (same inode across both project dirs). They refresh only when the pod restarts |
| S12 | Does the concurrent worktree `wt-heal-alert-exclude` overlap? | `git status` | ✅ it touches only `monitoring/configs/victoria-metrics/vmrules.yaml` |
| S13 | Do relative links break when files move? | `rg '\]\(\.\./'` inside the moved tree; `rg '\]\((\.\./)*scripts/'` across docs | ✅ none inside the tree. One outside: `docs/setup/K3S_SETUP.md:115` `(../scripts/setup-node.sh)`. Commit A changes it to `../../scripts/setup-node.sh` |

### Assumptions and cut corners

| Tier | Item |
|---|---|
| 🟡 | S4 and S5 above: Rollout step 2 is the check for both |
| 🟡 | The CP clone may hold untracked files the probe did not model. The clone is 0750 root, so nobody can list it without sudo. S4 shows one untracked file does not block the swap |
| 🟡 | Codex may regenerate `~/.codex/memories/memuser/MEMORY.md` from its own sources and re-introduce the old path. Edit it anyway: it is text, not a code path |
| ⚠️ | `docs/HOMELAB_HISTORY.md` entries and `docs/plans/*` keep the old path. They are dated records, and rewriting them would falsify history. SP3 decides whether plans stay public |
| ⚠️ | `~/.codex/memories/memrestore.bHYz8f/` is a restore snapshot. It keeps the old path; leave it alone |
| ⚠️ | `scripts/worker-node-post-install.sh` (moved as-is) pins `K3S_VERSION="v1.34.2+k3s1"` and `NODE_IP="192.168.1.130"`, both stale. Commit A changes only path strings; deleting a script is a separate decision for SP3 |

### Files touched by commit A

Moves (`git mv`):

| From | To |
|---|---|
| `docs/scripts/node-maintenance/` | `node-maintenance/` |
| `docs/scripts/{ansible-apply,setup-claude-telegram,setup-node,update-firmware}.sh` | `scripts/` |
| `docs/worker-node-post-install.sh` | `scripts/` |
| `docs/scripts/runbooks/authentik-passkey-rollback.md` | `docs/runbooks/` |
| new symlink | `docs/scripts/node-maintenance → ../../node-maintenance` (git mode `120000`) |

Functional edits:

| File:line | Change |
|---|---|
| `node-maintenance/lib/sync-from-git.sh:57` | `$REPO_DIR/node-maintenance/install.sh` |
| `node-maintenance/install.sh:50` | printed `sops` hint path |
| `node-maintenance/ansible/roles/k3s_config/files/k3s-wait-ready.service:3` | `Documentation=` URL |
| `renovate.json` `ignorePaths` | add `node-maintenance/**` |
| `scripts/setup-node.sh:8,229,240`, `scripts/setup-claude-telegram.sh:5-6`, `scripts/ansible-apply.sh:6` | usage paths |
| `.github/workflows/validate.yaml:10`, `.pre-commit-config.yaml:41` | comments |

Doc edits:

| File | Hits |
|---|---|
| `AGENTS.md` | 1 |
| `.claude/review-invariants.md` | 3 |
| `node-maintenance/README.md` | 8 |
| `node-maintenance/ANSIBLE_REVIEW_PLAN.md`, `docs/CODEMAPS/networking.md`, `docs/BACKUP_STRATEGY.md` | 1 each |
| `docs/setup/K3S_SETUP.md` | 2 + the relative link at line 115 |
| `docs/FIREWALL_SECURITY.md` | 2 |
| `docs/HOMELAB_HISTORY.md` | one new entry; old entries unchanged |

### Gates before commit A

Run from the worktree root. Each comment states the pass condition. The commands sit in a
code block, not a table, because a table forces `\|` escapes that change the regex.

```bash
# no live old-path text — pass: 0 lines
rg -n -e 'docs/scripts' -e 'docs/worker-node-post-install' --hidden -g '!.git' \
  -g '!.claude/worktrees' -g '!docs/HOMELAB_HISTORY.md' -g '!docs/plans/**'
# no broken relative links — pass: only ../../scripts/… targets, and each exists
rg -n '\]\((\.\./)*scripts/' docs
# symlink stored as a link — pass: mode 120000
git ls-files -s docs/scripts/node-maintenance
# symlink resolves — pass: exit 0
test -f docs/scripts/node-maintenance/install.sh
# new sync script — pass: 2817. Review may still change the file, so record the sha256
# for Rollout step 2 after the merge: git show main:node-maintenance/lib/sync-from-git.sh | shasum -a 256
wc -c < node-maintenance/lib/sync-from-git.sh
# shell lint, same as CI — pass: exit 0
find node-maintenance scripts -type f \( -name '*.sh' -o -name '*.bash' \) -exec shellcheck -S warning {} +
# yaml lint — pass: exit 0
yamllint -c .yamllint.yaml node-maintenance renovate.json
# renovate config — pass: exit 0
npx --yes --package renovate -- renovate-config-validator renovate.json
# ansible lint — pass: exit 0. If ansible-lint is not installed, say so in the commit report
(cd node-maintenance/ansible && ansible-lint)
```

Then the pre-commit review loop. If Claude implements, `peer-reviewed-implementation/scripts/reviewer-peer`
resolves the peer to Codex. Dispatch it through `~/.agents/skills/_shared/codex-review.sh`: static,
git-only, one-message verdict, pointed at `.claude/review-invariants.md`. Codex runs at `xhigh`
reasoning from the global `~/.codex/config.toml`; confirm that setting before the first dispatch.
Commit B gets the same rules with a delta-scoped prompt.

### Rollout

1. Merge commit A to `main` and push. `fr` is not needed: Flux reconciles nothing that changed.
2. After the next CP sync (≤10 min), check over SSH, read-only. The run that processed the merge is the only one that proves anything; later runs skip the install.

   | Check | Command | Pass |
   |---|---|---|
   | sync was not skipped | `systemctl show -p ConditionResult,ActiveState,Result node-maintenance-sync` | `ConditionResult=yes`. If it is `no`, the `phase2-pending` flag is blocking syncs. Stop and hand to the operator: the flag may belong to a maintenance run still in progress, so nobody clears it without finding out why it exists |
   | the run processed the merge, including the chained drift-heal | `journalctl -u node-maintenance-sync --since=-15min` | one run, in order: `HEAD … → <main tip after the merge>`, `running install.sh --sync-only`, `Sync applied`, `node-config playbook done`, `Deactivated successfully`. Lines after `install.sh` returns prove bash kept reading the replaced script correctly (S5). They do **not** prove the playbook ran: if another run holds the lock, `node-maintenance-lock.sh skip` exits 0 without running it (`lib/node-maintenance-lock.sh:28-37`) |
   | the playbook ran and passed | `grep -A6 -e '^=== start:' -e '^PLAY RECAP' /var/log/node-maintenance/config-latest.log` (readable by the `adm` group, no sudo) | the `=== start:` timestamp falls inside the sync run, and every host row shows `unreachable=0 failed=0`. The unit truncates this file at each start, so it holds only that run. If there is no `PLAY RECAP`, the lock skipped the run: this does not block B, because `install.sh` already rsynced the tree. If the `=== start:` stamp predates the sync run, an `ExecCondition` (phase2 flag age or pacman `db.lck`, `config.service:30-31`) skipped the unit before it truncated the log; `systemctl show -p Result node-maintenance-config` then reads `exec-condition`. That does not block B either. In both cases re-check after the 03:00 drift-heal |
   | new script installed | `ls -l /usr/local/sbin/node-maintenance-sync-from-git.sh` | **2817** bytes and a fresh mtime |
   | new script content | operator runs `sudo sha256sum /usr/local/sbin/node-maintenance-sync-from-git.sh` | matches the sha256 recorded after the merge. Size alone cannot rule out a damaged file of the same length |

3. Push the dotfiles updates (Off-repo updates below), then restart the bot pod
   (`kubectl -n claude-telegram delete pod -l app=claude-telegram`) so it re-applies them. Re-run the bot grep:
   0 strict hits.
4. **Precondition: step 2 passes every row, including the sha256 match; the playbook row may defer to the 03:00 drift-heal.** Commit B: `git rm docs/scripts/node-maintenance`, then
   `rmdir docs/scripts` if it is empty. Review, merge, push.
5. Next sync: repeat the step-2 checks. The size stays 2817, and success here proves the new
   script runs without the symlink.

### Off-repo updates (between A and B)

The new path is valid from commit A onward. Re-derive counts at execution time with the
strict pattern `docs/scripts|docs/worker-node-post-install`.

| Surface | Files (counts from 2026-09-26) | How |
|---|---|---|
| Skills (`~/.agents/skills`) | `homelab-node-fix/SKILL.md` (2), `homelab-node-fix/reference-incidents.md:90`: an on-node `rsync` recovery command, **functional**, `homelab-monthly-review/SKILL.md` (2), `gitops-workflow/SKILL.md:86` | edit → `chezmoi-sync` |
| Claude memory (homelab project) | 9 files, 14 lines, incl. `reference_ansible_roles.md` (4) | edit → `chezmoi-sync` |
| Codex memory | `~/.codex/memories/memuser/MEMORY.md:2158,2349,2350` | direct edit (chezmoi does not manage it) |
| claude-telegram bot | inherits the dotfiles | pod restart, Rollout step 3 |

Verify: re-run the home sweep. Pass = 0 strict hits outside `memrestore.*`.

### Rollback

The installed script's size decides the fix. Size is evidence, not proof: if the size is
unexpected, the operator reads the file with sudo before choosing a row.

| Failure after A (Telegram alert fires) | Installed size | Fix |
|---|---|---|
| anything failed before `install.sh:134`: the reset, the symlink, the rsync at `:87`, or the galaxy install at `:96` | 2830 (old) | `git revert` A. The revert is a new commit, so it re-triggers the install with the old layout, which the old script expects |
| `install.sh` passed line 134, then something failed later (for example the playbook) | 2817 (new) | Push a corrective commit on top of A. Do **not** revert A: the new script would then call a path the reverted tree lacks |
| size is neither value, or the file is missing | other | Operator inspects with sudo. Then runs, on the CP, whichever installer exists in the checkout: `sudo bash /var/lib/node-maintenance/homelab/node-maintenance/install.sh --sync-only` (new layout) or `…/docs/scripts/node-maintenance/install.sh --sync-only` (old layout). Then `sudo systemctl start node-maintenance-config.service` and the step-2 checks |

| Failure after B | Fix |
|---|---|
| Sync fails | `git revert` B restores the symlink. If B merged before step 2 showed 2817, the old script is still installed; the revert still recovers, because the old script finds the symlink again |

---

## SP2 — skills, helpers and rules in the repo (outline)

Decided: a snapshot copy under `agents/`. It stays outside `.claude/skills/`, so Claude Code
does not load it a second time as project skills. Monthly review gains a re-sync step.

Spikes still to run before its plan:

| Topic | What to settle |
|---|---|
| Scope (**open question for the operator**) | Default: the ~31 homelab-coupled skills plus the operator's own generic ones. Vendored bundles (firecrawl ×36, hyperframes, Matt Pocock's set, …) stay out because each carries its own licence. Needs provenance per skill: lock file, `git log` in dotfiles |
| Codex-only skills | `~/.codex/skills` holds 97 entries; diff them against `~/.agents/skills` |
| Secret and PII scan | gitleaks + `pii-scrub` over every file the snapshot would copy |
| Rules export | Sanitize `~/.claude/CLAUDE.md`: strip the email, 1Password item names, other-project names and the incident narrative tied to them |
| Re-sync mechanism | Two modes. `--check` reports drift and exits non-zero without writing. `--update` copies the allowlisted set, applies a persistent exclusion and sanitization list, then runs the secret and PII scan on the result. `homelab-monthly-review` runs `--check` |

## SP3 — docs pass (outline)

| Item | Detail |
|---|---|
| Scope | every `*.md` in the repo |
| Checks | staleness against the live cluster (re-derive counts and versions), duplication across docs, `avoid-ai-writing`, README + mermaid currency |
| CODEMAPS → `docs/subsystems/` | link sites: `AGENTS.md`, `README.md`, `docs/ARCHITECTURE.md`, `docs/HOMELAB_ANALYSIS.md`, plus the ECC `update-codemaps` convention |
| `.backup/README.md` → `docs/` | link sites: `docs/ARCHITECTURE.md:133,178,203`, `docs/disaster-recovery/README.md:3`, `AGENTS.md`. CI's sops check prunes `.backup/`; the DR scripts stay there |
| Disposition to propose | `HOMELAB_HISTORY.md` (4,002 lines), `docs/plans/`, `ANSIBLE_REVIEW_PLAN.md`, `scripts/worker-node-post-install.sh` (stale) |
| Known doc errors | every `node-maintenance/systemd/*` unit carries `Documentation=file:///etc/node-maintenance/README.md`, and `install.sh` never installs that README |
| Gate | SP1's old-path sweep plus the relative-link grep, for each renamed path |

## SP4 — pre-public gate (outline)

| Item | Detail |
|---|---|
| History secret scan | `gitleaks git` over full history. Pass = exactly the 11 known inert findings (audited 2026-07-26), 0 new. `git log -S<value>` for every previously rotated value. Sample `refs/pull/*/head` tips |
| `claude.yml` public triggers | `.github/workflows/claude.yml:3-21` fires on `issue_comment`, `issues` and `pull_request_review*`. Its `if:` checks only for `@claude` and excludes Renovate; it has no actor or `author_association` guard. It uses `secrets.CLAUDE_CODE_OAUTH_TOKEN`. Spike what `anthropics/claude-code-action@v1` enforces for users without write access. Then add `github.actor == 'AKhozya'` to the condition of **every** trigger that stays, `pull_request_review*` included |
| Absolute `/Users/akhozya/…` paths | `.claude/hooks/worktree-guard.sh:13`, `.claude/hooks/worktree-session-start.sh:9`, `AGENTS.md:69`, `CLAUDE.md:33`. Decide: keep or make generic |
| Licence | add MIT `LICENSE` |

## SP5 — ultrareview

The operator runs `/code-review ultra` on the repo. The agent fixes every finding that blocks
publishing (exposed secret, licence problem, unsafe public trigger) before SP6 starts.

## SP6 — visibility flip

| Item | Detail |
|---|---|
| Flip | operator action, after SP5 closes |
| Branch protection | `AGENTS.md:31` blames the missing merge gate on "private repo on the Free plan". GitHub docs list protected branches as available for public repos on the Free plan, so decide: enable required checks, or decline. Then edit the "CI is a signal, NOT a merge gate" invariant to match |
