# Open-source prep — plan (2026-09-26)

Goal: make `AKhozya/homelab` fit to publish. Six sub-projects run in order. Each one gets
its own spikes and operator approval before work starts. This file plans SP1–SP4 and SP6 in
full. SP5's commits depend on what the ultrareview finds, so its section records only the rules.

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
| 10 | SP2 skill scope (2026-09-27) | The 25 homelab skills and the 9 generic skills the operator wrote, plus the `_shared/` helpers they call. No third-party skills |
| 11 | Absolute `/Users/akhozya` paths inside skills (2026-09-27) | Keep, as decision 4 does for usernames |
| 12 | `op://Personal/sudo-homelab/password` in `cluster-reboot` and `k3s-upgrade` (2026-09-27) | Keep. It names a 1Password item, not a secret, and the scripts need it |
| 13 | Claude Code hooks in the snapshot (2026-09-27) | Leave out |
| 14 | Reasoning effort (2026-09-27) | Codex `high` and Opus `high`, recorded in docs only. The global Claude `effortLevel: xhigh` setting stays |
| 15 | NAS SSH port and key file name in skills (2026-09-27) | Keep, as decision 4 does for the cluster |
| 16 | The bot's Telegram handle in `claude-telegram-release` (2026-09-27) | Keep. The bot answers one allowlisted Telegram ID: `authGate` runs before every handler and drops any other sender without a reply |
| 17 | SP3 rewrite depth (2026-09-27) | Plain-English rewrite of the public-facing docs. Every other current doc gets fact fixes and slop-word fixes only |
| 18 | `HOMELAB_HISTORY.md` (2026-09-27) | A rolling 3-month window. SP3 keeps the entries dated 2026-06-27 or later; each monthly review then deletes entries older than 3 months. Git keeps them, as `593d2dd5` did for 2025. The Milestones table stays as the summary of the older months |
| 19 | Kept HISTORY entries (2026-09-27) | Rewrite them in plain English too |
| 20 | `docs/plans/` (2026-09-27) | Keep only open plans: this one and `2026-09-07-immich-ml-followups-research.md`. Delete the 8 finished plans and `node-maintenance/ANSIBLE_REVIEW_PLAN.md` |
| 21 | Merges (2026-09-27) | One security page, with each app's `SECURITY.md` renamed so it no longer shares the name; one DR runbook; delete `scripts/worker-node-post-install.sh`; retire `ANSIBLE_REVIEW_PLAN.md` |
| 22 | Config bugs the SP3 spikes found (2026-09-27) | Fix in the session. Done in `fd6dc2e2`: UFW rules with no source on 6443, 10250 and 22 deleted; SSH key-only on every node. The `victoria-metrics-operator` release was not a bug: Flux's 6-hour chart index had not yet seen 0.68.0, and it went Ready at 18:04 UTC |
| 23 | Remaining config drift (approved 2026-09-27) | SP3 commit C0 |
| 24 | Doc removals beyond decisions 20–21 (approved 2026-09-27) | Delete `apps/home-assistant/README.md` (wrong DNS advice, S31) and drop HOMELAB_ANALYSIS's tables that copy README and `subsystems/apps.md` |
| 25 | Supply-chain pins (2026-09-27) | Pin every GitHub Action to a commit SHA (SP4). Images and Helm charts stay tag-pinned: the `renovate.json` rule from `6c03f930` sets `pinDigests: false` for them, and digest pins would add a Renovate PR for each same-tag rebuild |

## Roadmap

| SP | Scope | Depends on |
|---|---|---|
| SP1 | Move node-maintenance tree + loose scripts out of `docs/`. **Done** 2026-09-26: `7a307ab4`, `8a146a09` | — |
| SP2 | Snapshot skills, `_shared/` helpers and sanitized rules into the repo; monthly re-sync step. **Done** 2026-09-27: `11a9ef29`, `a1ee146d`, `d61d9e12` | SP1 (skills cite the new path) |
| SP3 | Docs pass: staleness, duplication, `avoid-ai-writing`, README + mermaid, CODEMAPS rename. **Done** 2026-09-28: C0 `72b39c6d`, C1 `12025040`, C2 `3d6b6592`, C3 `54a00f4f`..`f987082d`, C4a `6da12196`, C4b in 24 batches `97587af2`..`f0e42940` | SP1, SP2 |
| SP4 | Pre-public gate: history secret scan, `claude.yml` trigger lockdown, MIT `LICENSE`, Action SHA pins. **Done** 2026-09-28: token rotation `52ce08aa`, `54e755a3`; plan `b1dbcdf1`; C0 `bbbe3e85`, C1 `6ca5f826`, C2 `bf940942`, C3 `254a8f63`; repo settings applied | SP3 |
| SP5 | Whole-repo review and fixes. **Done** 2026-09-28: 9 review agents on `8f78a8c8`, 209 findings, 198 fixed; fixes merged `a0b68286`..`1d3ff3d0`, open items in SP5 Carried forward | SP4 |
| SP6 | Visibility flip (operator action), then the settings that need a public repo, a ruleset on `main` and the `AGENTS.md` CI invariant | SP5 |

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
git-only, one-message verdict, pointed at `.claude/review-invariants.md`. Codex runs at the
reasoning effort that the global `~/.codex/config.toml` sets (`high` since 2026-09-27, decision
14); confirm that setting before the first dispatch.
Commit B gets the same rules with a delta-scoped prompt.

### Rollout

1. Merge commit A to `main` and push. `fr` is not needed: Flux reconciles nothing that changed.
2. After the next CP sync (≤10 min), check over SSH, read-only. The run that processed the merge is the only one that proves anything; later runs skip the install.

   | Check | Command | Pass |
   |---|---|---|
   | sync was not skipped | `systemctl show -p ConditionResult,ActiveState,Result node-maintenance-sync` | `ConditionResult=yes`. If it is `no`, the `phase2-pending` flag is blocking syncs. Stop and hand to the operator: the flag may belong to a maintenance run still in progress, so nobody clears it without finding out why it exists |
   | the run processed the merge, including the chained drift-heal | `journalctl -u node-maintenance-sync --since=-15min` | one run, in order: `HEAD … → <main tip after the merge>`, `running install.sh --sync-only`, `Sync applied`, `node-config playbook done`, `Deactivated successfully`. Lines after `install.sh` returns prove bash kept reading the replaced script correctly (S5). They do **not** prove the playbook ran: if another run holds the lock, `node-maintenance-lock.sh skip` exits 0 without running it (`lib/node-maintenance-lock.sh:28-37`) |
   | the playbook ran and passed | `grep -A6 -e '^=== start:' -e '^PLAY RECAP' /var/log/node-maintenance/config-latest.log` (readable by the `adm` group, no sudo) | the `=== start:` timestamp falls inside the sync run, and every host row shows `unreachable=0 failed=0`. The unit truncates this file at each start, so it holds only that run. If there is no `PLAY RECAP`, the lock skipped the run: this does not block B, because `install.sh` already rsynced the tree. If the `=== start:` stamp predates the sync run, an `ExecCondition` (phase2 flag age or pacman `db.lck`, `config.service:30-31`) skipped the unit before it truncated the log; `systemctl show -p Result node-maintenance-config` then reads `exec-condition`. That does not block B either. In both cases re-check after the next drift-heal (03:00 or 15:00 UTC) |
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

## SP2 — skills, helpers and rules in the repo

### Snapshot contents

`agents/` holds a read-only snapshot for readers. The authoritative copy stays in dotfiles:
`~/.agents/skills` on the operator's Mac is what the tools load. No tool loads the snapshot.

| Path | Content |
|---|---|
| `agents/README.md` | what the snapshot is and where the authoritative copy lives; how `~/.agents/skills/…` paths inside the skills map to this folder; that mentions of memory files, hooks and `~/.claude/CLAUDE.md` point at the operator's private setup; the review-loop files and where to start reading them; what is left out and why, by class (third-party skills, hooks, memory), not by name. It points at `sync/allowlist.txt` instead of stating counts |
| `agents/skills/<name>/` | each allowlisted skill, copied byte for byte |
| `agents/skills/_shared/` | each allowlisted helper, byte for byte |
| `agents/rules/CLAUDE.global.md` | a hand-edited export of `~/.claude/CLAUDE.md`. Its first line records the sha256 of the source the edit started from |
| `agents/rules/AGENTS.global.md` | a byte copy of `~/.codex/AGENTS.md`, which needs no edit (S19) |
| `agents/sync/allowlist.txt` | one entry per line: a skill name, or `_shared/<file>` for a helper |
| `scripts/sync-agents.sh` | `--check` and `--update` (contract below) |
| `scripts/sync-agents.test.sh` | a self-contained test of both modes against fake trees |

Two files stay in dotfiles, under `~/.config/sync-agents/`, because a reader gains nothing from
them and each would publish something:

| File | Content | Why not in the repo |
|---|---|---|
| `private-terms.txt` | one fixed string per line: the operator's email and the names of private projects and clients. Each spelling of a name (`a-b`, `a_b`, `A B`) is its own line | a list of names to hide publishes them. This plan names none of them |
| `denylist.txt` | every entry of `~/.agents/skills` and `_shared/` that does not ship, then a tab, then the reason | it lists the operator's whole installed-skill inventory |

Skills in scope (decision 10), 118 files today (S17):

| Class | Skills |
|---|---|
| homelab (25) | `app-scaffold`, `backup-nightly-verify`, `backup-restore-drill`, `checkpoint`, `claude-telegram-release`, `cluster-reboot`, `cluster-roll`, `cluster-stale-cleanup`, `cnpg-full-roll`, `db-operations`, `db-primary-pin`, `gitops-verify`, `gitops-workflow`, `ha-enablement`, `homelab-monthly-review`, `homelab-node-fix`, `homelab-yaml-validate`, `k3s-token-rotate`, `k3s-upgrade`, `k8s-diagnostics`, `kyverno-policy-promotion`, `monitoring-check`, `networkpolicy-helper`, `resource-sizing`, `secrets-rotation` |
| written by the operator, not homelab-specific (9) | `bash-scripting`, `brave-automation`, `chezmoi-sync`, `comment-sweep`, `kb-hygiene`, `mutation-testing`, `peer-reviewed-implementation`, `pii-scrub`, `worktree-cleanup` |
| `_shared/` left out (3) | `check-shared-agent-skills.sh` (dotfiles CI only), `kyverno-policy-probe.sh` (no caller), `op-resolver.sh` (no caller; lists four 1Password item names) |

The review loop the operator asked to showcase is already in scope:
`peer-reviewed-implementation` (the workflow), `_shared/codex-review.sh` (the dispatcher),
`_shared/codex-review-selfcheck.sh` (its self-test) and the two rule exports.

### Spike results

| # | Question | Probe | Result |
|---|---|---|---|
| S14 | Which skills are the operator's? | `~/.agents/.skill-lock.json`, frontmatter, LICENSE files, first dotfiles commit per skill | ✅ 141 entries: 25 homelab, 9 generic by the operator, 105 third-party, 1 unclear (`android-cli`: Google CLI docs, no lock entry, left out). `find-skills` is third-party (vercel-labs) yet tracked in dotfiles, so "whatever chezmoi tracks" is the wrong selector. The allowlist is explicit |
| S15 | Do skills live outside `~/.agents/skills`? | compare `~/.claude/skills` and `~/.codex/skills` with it | ✅ none of the operator's. `~/.claude/skills/synced/` holds 11 Anthropic skills, `.trash/` one deleted skill, `~/.codex/skills/.system/` Codex's built-ins |
| S16 | Does any tool load `agents/`? | headless probes, Claude Code 2.1.283 (load-logging hook) and Codex 0.157.1 (session logs), plus both vendors' docs | 🟡 neither loads `agents/skills/**` as skills. Claude Code **does** load a file named `CLAUDE.md` in a folder as soon as it reads any file there, so the exports take the `*.global.md` name; neither tool loaded those. Codex 0.157.1 now reads `<repo>/.agents/skills` (0.147.0 read `.codex/skills`). The folder has no dot, so this does not apply. The script refuses a `CLAUDE.md`, `AGENTS.md` or dot entry, because a later tool version may load more paths |
| S17 | Do the repo's gates pass on the snapshot? | trial copy of exactly the 34 skills + 29 helpers; CI shellcheck form, `gitleaks dir` with `.gitleaks.toml`, trailing-whitespace and final-newline scan, `git check-ignore`, YAML and manifest search | ✅ 118 files, 637,222 B. shellcheck exit 0, including the extension-less `reviewer-peer`. gitleaks found no leaks. No trailing whitespace, every file ends in a newline, nothing matched by `.gitignore`, no YAML, no package manifests. The failing checks in the full trial all came from third-party skills |
| S18 | Secrets and personal data | `gitleaks dir` + `rg` for emails, `op://`, absolute paths, private project names, tokens, keys | ✅ 0 secrets. In scope: `op://Personal/sudo-homelab/password` (decision 12), 20 `/Users/akhozya` paths in 4 skills (decision 11), and one private project name at `homelab-monthly-review/SKILL.md:87`. The operator's email is in no file |
| S19 | What does the rules export need? | read `~/.claude/CLAUDE.md` (200 lines, 27,922 B) and `~/.codex/AGENTS.md` (34 lines, 1,760 B) in full | 🟡 AGENTS.md needs no edit. CLAUDE.md needs the edits in the table below. Several passages retell private-project incidents without naming the project, so a name search alone misses them. The edit is by hand, and the export gets a prose review |
| S20 | Can the check run inside the Telegram bot? | `kubectl exec` into the bot pod | ✅ no. The pod holds 38 skills and a 7,088 B `CLAUDE.md` from April, so a check there reports drift that is not real. The script refuses any host that is not macOS |
| S21 | Does Renovate or Flux pick up `agents/`? | Renovate 44.115.12 local extract; `clusters/` Kustomization paths | ✅ Renovate finds no manifest in scope today. Flux applies only `./clusters`. Flux still packs `agents/` into its source archive: +637 KB on the 3.2 MB of tracked files |
| S22 | Which `rsync` flags give a correct copy and a correct drift check? | scratch trees; `/usr/bin/rsync` is openrsync (protocol 29) | ✅ `-r -c -n -i --delete --no-links` prints a line for a changed byte at the same mtime and for an extra file. For a new mtime alone it prints a `.f..T....` line, which the script ignores because the line starts with `.`; it prints nothing for a 644 → 664 mode change. Git records neither. It misses a lost exec bit, so the check compares exec bits separately. `-E` means extended attributes in openrsync and copies `._` AppleDouble files, so the script does not use it. `--no-links` skips a symlink with a message and exit 0, so the script finds symlinks itself |
| S23 | Do the copied files retell private matters without names? | a full read of all 119 files (89 skill files, 29 helpers, `~/.codex/AGENTS.md`), then a keyword sweep and a comparison with every folder name under `~/source-code` | ✅ none beyond S18's named project. `pii-scrub/SKILL.md:32` calls the kept IPs and domain "part of the portfolio story"; rollout step 1 rewords it. About 26 mentions of the operator's private memory files, hooks and older skill names stay, because the live skills use them; `agents/README.md` explains them. The NAS SSH port, key file name and the bot handle stay (decisions 15, 16) |
| S24 | Does the fake key in the tests trip gitleaks with the repo config? | `gitleaks dir -c .gitleaks.toml` on one file each | ✅ a random `AKIA` + 16 base32 characters exits 1. The AWS docs key `AKIAIOSFODNN7EXAMPLE` exits 0, because gitleaks allowlists it. So `.gitleaks.toml` keeps the default rules, and the tests use a random key |
| S25 | Three contract details | scratch trees and the S17 trial copy | ✅ `rsync -r -p -c` restores a lost exec bit on a file whose bytes already match. `grep -Fw` finds none of the three denylisted helper names in the 118 in-scope files, so phase 4 passes on day one. `.gitignore` line 2 ignores `.DS_Store`, so `git add -A agents` skips an untracked Finder file. `.gitleaks.toml` adds one rule of its own, `sql-identified-by`, which the default rules lack |
| S26 | Does a test case prove the script reads `.gitleaks.toml`? | a SQL line with a 12-character quoted value, assembled at run time; `gitleaks dir` with and without `-c .gitleaks.toml`; the same on a file that holds only the assembling code | ✅ with the repo config the line exits 1; with the default rules only it exits 0; the assembling file exits 0. The repo rule needs a quoted value of 8 or more characters, so a 1-character value would never match |

### Assumptions and limitations

| Tier | Item |
|---|---|
| 🟡 | S16 covers two tool versions. A newer Claude Code or Codex could load more paths. The forbidden-entry rule and the `*.global.md` names keep out the loaders known today. The monthly check does not re-test discovery |
| 🟡 | The operator edits the CLAUDE.md export by hand. `--check` can report that the source changed, not what the export should now say. Each change needs another hand edit and a prose review |
| 🟡 | The private-terms file holds only the names known today. A new private project needs a new line in it. The file does not catch a private matter told without a name. The Codex review of each refresh diff is the check for that |
| ⚠️ | No `.sourceignore` for Flux. The snapshot adds 637 KB to 3.2 MB of tracked files, and a `.sourceignore` would change the production sync path for no measured gain. If the snapshot grows past 5 MB, add one |
| ⚠️ | `~/.agents/skills/…` paths inside the copied skills stay as written. They are how the skills find each other at run time. `agents/README.md` states the mapping once |
| ⚠️ | No CI runs on either repo. GitHub Actions has started no job on `AKhozya/homelab` or `AKhozya/dotfiles` since the last passing run on 2026-09-10. Every SP2 gate is therefore local, and nothing here depends on a CI result. SP6 checks whether Actions runs once the repo is public |

### Script contract (`scripts/sync-agents.sh`)

Run order:

| Step | Rule |
|---|---|
| 1 | Phase 1 runs first. If it fails, the script stops |
| 2 | Phases 2–4 run. Of these, only phase 3 reads the target. Each phase reports every finding. Phase 3 skips a source that phase 2 reported missing |
| 3 | If phases 2–4 pass, both modes build the same staging folder with `mktemp -d`, which uses `$TMPDIR` if it is set and `/tmp` otherwise. `<staging>/skills/` holds each allowlisted skill and helper, copied with `$RSYNC -r -p --no-links --exclude=.DS_Store`. `<staging>/rules/AGENTS.global.md` is a copy of the Codex rule source. A trap removes the folder on every exit |
| 4 | Phases 5–7 run on the staging folder |
| 5 | The exit code is the code of the first phase that failed. Every finding names the source path (under `AGENTS_SRC` or `RULES_SRC_CODEX`) or the target path, never a staging path |

| Phase | Modes | Test | Exit if it fails |
|---|---|---|---|
| 1 host | both | `uname`, found through `PATH`, prints `Darwin`. This keeps the script off Linux hosts such as the bot pod; the operator runs it on the Mac that holds the dotfiles checkout | 2 |
| 2 inputs | both | `AGENTS_SRC` and every allowlisted source exist. Both rule sources exist. The private-terms file and the denylist exist, hold at least one entry, and hold no line that is empty or only whitespace | 2, naming each path |
| 3 forbidden entries | both | no symlink, no file named `CLAUDE.md` or `AGENTS.md`, and no dot entry other than `.DS_Store`, inside any allowlisted source, or anywhere under `agents/`. Git tracks no `.DS_Store` under `agents/`. The script checks this with `git -C <repo root> ls-files -- agents`. It reads git's own exit code, so a git error exits 70 instead of reading as a pass | 3 |
| 4 lists | both | allowlist and denylist share no entry. Together they name every entry of `AGENTS_SRC` except `_shared` and `.DS_Store`, and every entry of `_shared/` except `.DS_Store`. Neither names an entry that no longer exists. Every `_shared/<file>` that an allowlisted skill or helper mentions is allowlisted. No allowlisted skill or helper contains a denylisted helper's file name as a whole word (`grep -Fw`), which catches a call through `$(dirname "$0")` | 1 |
| 5 publication scan | both | `gitleaks dir` with `.gitleaks.toml` from the folder above the script, and a case-insensitive fixed-string search for each private term. Neither scans an untracked `.DS_Store`. `.gitignore` keeps it out of `git add`. Phase 3 fails if git tracks one. Both modes scan the staging folder. `--update` also scans every file under `agents/` it does not overwrite: everything outside `agents/skills/` and `rules/AGENTS.global.md`. `--check` also scans all of `agents/` | 4 |
| 6 shellcheck | `--update` | `shellcheck -S warning` on every staged file whose name ends in `.sh` or `.bash`, or whose first line starts with `#!` and whose interpreter's base name is exactly `sh` or `bash`, directly or through `env`, with or without arguments (`#!/bin/bash -e`) | 5 |
| 7 drift | `--check` | `$RSYNC -r -c -n -i --delete --no-links --exclude=.DS_Store <staging>/skills/ agents/skills/` prints nothing. Apart from `.DS_Store`, the files with the owner exec bit set are the same in both trees. `agents/rules/AGENTS.global.md` equals its source. `agents/rules/CLAUDE.global.md` exists and its recorded sha256 equals the current source | 1 |

If phases 1–6 pass, `--update` writes two things and nothing else. It copies `<staging>/skills/`
over `agents/skills/` with `$RSYNC -r -p -c --delete --no-links --exclude=.DS_Store`, which also
removes anything the allowlist no longer produces and restores a lost exec bit (S25). It copies
`<staging>/rules/AGENTS.global.md` to `agents/rules/AGENTS.global.md`. The exclude leaves a
Finder `.DS_Store` in place. `.gitignore` keeps an untracked one out of `git add`, and phase 3 fails if git tracks one. If any phase fails, it writes nothing. It never writes
`README.md`, `sync/` or `CLAUDE.global.md`. If `CLAUDE.global.md` is missing or its recorded
sha256 is stale, `--update` says so and still exits 0; `--check` then exits 1. An unexpected
internal error exits 70.

| Variable | Default | Read in phase |
|---|---|---|
| `AGENTS_SRC` | `$HOME/.agents/skills` | 2, 3, 4, staging |
| `RULES_SRC_CLAUDE` | `$HOME/.claude/CLAUDE.md` | 2, 7 |
| `RULES_SRC_CODEX` | `$HOME/.codex/AGENTS.md` | 2, 7, `--update` copy |
| `PRIVATE_TERMS` | `$HOME/.config/sync-agents/private-terms.txt` | 2, 5 |
| `DENYLIST` | `$HOME/.config/sync-agents/denylist.txt` | 2, 4 |
| `AGENTS_DST` | `agents/` in the folder above the script, so it resolves inside a worktree | 3, 5, 7, `--update` copy |
| `RSYNC` | `/usr/bin/rsync`, the openrsync that S22 measured | staging, 7, `--update` copy |

No transforms: every copied byte equals its source.

### Rules export edits (`~/.claude/CLAUDE.md` → `CLAUDE.global.md`)

The table keys rows by section and bold lead-in, because line numbers move whenever the source changes.

| Section › entry | What | Action |
|---|---|---|
| Working approach › Ask instead of draft-and-correct | the operator's own quote | drop the quote, keep the rule |
| Working approach › Absence needs the owning layer (Trigger paragraph) | four dated incidents, one naming a client product | keep the trigger rule. Replace the incident list with one sentence naming the four kinds of wrong claim |
| Working approach › Source every claim | a dated third-party incident | drop the dated clause, keep the rule |
| Working approach › Cost is never a factor | a private cost hook and "four repos" | "Never limit a task because of session cost." |
| Verification › A check can match itself; A mutant dying…; A grep hit… | dated incidents from private media and social projects | keep each rule and its bold line; one neutral sentence per story |
| Git & Commits › A string-matching hook…; `git-commit-style.sh` matches… | two near-duplicate entries naming private hooks | merge into one: "A hook that matches command text also matches a heredoc that contains the pattern. Write the script to a file and run the file." |
| Code review › Acting on findings | a private skill name and a pointer to private memory | drop both |
| Code review › the review-round table | the same table as the repo's `AGENTS.md` | replace with a pointer to that table, so the repo holds it once |
| Code review › Inline the writing rules | a named private project and a PR number | keep the rule, drop both |
| Code review › Codex review is MANUAL | plugin state paths and a named-project incident | keep the rule and the check and disable commands with a `<state-dir>` placeholder; drop the story |
| Docs & Markdown (first line) | a private skill name | "Apply the same writing rules to Markdown files:" |
| Plain English | the operator's quote and date; two examples from a private project | drop the quote and date; neutral examples |
| Sentence length › the *Why* line | a path into a private project | drop the path, keep the sources table |
| Code comments (first line) | personal feedback history | drop the sentence |
| Safety Hook (whole section) | the local safety hook | drop (decision 13) |
| Shell | the shell rules. The 2026-09-27 alias removal already updated them: `grep -n unaliased ~/.claude/CLAUDE.md` prints line 141 | keep as written |
| Shell › Never run an unfamiliar project script | a named-project incident | "One project script ignored `--help`, ran its real job, and overwrote tracked data files." |
| Chezmoi, Personal, Auto-memory (whole sections) | dotfile layout, 1Password item names, memory layout | drop |
| Web search / fetch | the key-loading shell function and account tier | "Prefer Exa search over generic web search for docs." |
| Tools available › last line | "Full list: `~/.Brewfile`" | drop that sentence, keep the tool list |
| everything else | rules, tool behaviour, dated tooling incidents that name no project | keep as written |

The export's first line: `<!-- Source-sha256: <sha256 of ~/.claude/CLAUDE.md when the edit started> -->`.
Its second line says the file is a hand-edited export and that `agents/README.md` maps the
`~/.agents/skills` paths.

### Files touched

| Commit | Files | Review |
|---|---|---|
| C1 | `scripts/sync-agents.sh`, `scripts/sync-agents.test.sh`, `agents/README.md`, `agents/sync/allowlist.txt`, `renovate.json` (`agents/**` in `ignorePaths`), `.pre-commit-config.yaml` (`^agents/(skills/|rules/AGENTS\.global\.md)` in the exclude of every hook that rewrites files, so no hook changes a copy, while the hand-written `README.md` and `CLAUDE.global.md` stay covered), `AGENTS.md` (the skills section points at `agents/`; the Codex effort level as `~/.codex/config.toml` sets it, read at C1), `CLAUDE.md` (the "skills live outside this repo" section points at the snapshot), `docs/HOMELAB_HISTORY.md` (one entry), `docs/HOMELAB_ANALYSIS.md` (a pointer to `agents/`) | Codex loop |
| C2 | `agents/skills/**` and `agents/rules/AGENTS.global.md`, the output of `--update` | Codex loop. The review file holds the file list with sizes, the output of each C2 gate, the S18 scan result and the S23 read table. It does not hold the 637 KB of content, which S23 read in full |
| C3 | `agents/rules/CLAUDE.global.md` | Codex loop on the prose, with the writing rules and the edit table above |

Every later snapshot refresh gets the Codex loop. Its review file is `git diff --cached agents/`
after `git add -A agents`, so it holds new, changed and deleted files. That review reads the
diff for private data. C1–C3 merge to `main` together after C3's last review round passes. Nothing live
reads `agents/`, so the commit order keeps each review small; it does not protect production.

### Gates

```bash
# C1 — script and test
shellcheck -S warning scripts/sync-agents.sh scripts/sync-agents.test.sh      # pass: exit 0
bash scripts/sync-agents.test.sh                                               # pass: exit 0
npx --yes --package renovate -- renovate-config-validator renovate.json      # pass: exit 0
# C2 — snapshot
scripts/sync-agents.sh --update                                                # pass: exit 0
scripts/sync-agents.sh --check          # pass: exit 1, and the only finding is "CLAUDE.global.md missing" (C3 adds it)
pre-commit run --files $(git ls-files --cached --others --exclude-standard agents)   # pass: exit 0, no file modified
# C3 — rule export
scripts/sync-agents.sh --check                                                 # pass: exit 0
pre-commit run --files agents/rules/CLAUDE.global.md                           # pass: exit 0, no file modified
```

`--check` in C3 already runs gitleaks and the private-term search over all of `agents/`
(phase 5). `pre-commit run --all-files` is not a gate here: its yamllint hook already fails on
files outside `agents/` (S17 baseline), so the C2 gate runs every hook on the `agents/` files only.

`scripts/sync-agents.test.sh` sets a temporary `HOME`, points every variable at fake trees, and
puts a `uname` shim first on `PATH`. It refuses to run if `AGENTS_DST` resolves inside the repo.
It builds the fake AWS key at run time (`AKIA` plus 16 characters from `[A-Z2-7]` read from
`/dev/urandom`) and never writes it into a tracked file, because a literal key in the test would
trip the repo's own gitleaks scan. C1 ships a case for every row; the C1 gate runs the whole file.

| Case | Expected |
|---|---|
| `--update` twice, with a current `CLAUDE.global.md` in the fake target | `--check` 0 |
| a copy touched to a new mtime; a copy changed from mode 644 to 664 | `--check` 0 |
| one byte changed in a copy; a copy loses its exec bit; a file deleted from a copy; an extra file in a copy; an extra folder under `agents/skills/` | `--check` 1 for each; `--update` restores each |
| `README.md`, `sync/allowlist.txt` and `rules/CLAUDE.global.md` present in the target | `--update` leaves all three byte-identical |
| a file deleted from a retained source skill; a skill moved from the allowlist to the denylist | `--update` removes the file and the folder |
| a new source skill or `_shared/` file in neither list; an entry in both lists; a denylisted entry missing from the source | `--check` 1; `--update` 1 and `agents/` unchanged |
| a denylisted source skill present; `.DS_Store` at the top of `AGENTS_SRC` and of `_shared/`, inside a source skill, and inside `agents/skills/` | `--check` 0 |
| an allowlisted skill mentions a denylisted helper; an allowlisted helper mentions one; an allowlisted helper calls one through `$(dirname "$0")` | `--check` 1 |
| an allowlisted source skill renamed | `--check` 2, and the report also names the new unlisted entry |
| a symlink, a `CLAUDE.md`, an `AGENTS.md`, a `.claude/` folder, or another dot entry in an allowlisted source | `--check` 3; `--update` 3 and `agents/` unchanged |
| a `.DS_Store` under `agents/` tracked with `git add -f`; the same after deleting the file without staging the removal | `--check` 3; `--update` 3 and `agents/` unchanged |
| the same after `git rm --cached` | `--check` 0 |
| an untracked `.DS_Store` under `agents/` that holds a private term | `--check` 0 |
| `agents/rules/CLAUDE.md` in the target | `--check` 3; `--update` 3 |
| an allowlisted source missing; a rule source missing; the private-terms file or the denylist missing, empty, or holding a blank line; `uname` prints `Linux` | 2; `--update` leaves `agents/` unchanged |
| a private term in a source file; a random `AKIA` key (S24) in a source file; the same key in the Codex rule source; a SQL line that only the repo's `sql-identified-by` rule catches, assembled at run time from separate pieces with a 12-character quoted value, as S26 measured | `--update` 4 and `agents/` unchanged; `--check` 4 |
| a private term in `agents/README.md` | `--check` 4 and `--update` 4 |
| a shellcheck warning in an extension-less script whose first line is `#!/usr/bin/env bash`; the same with `#!/bin/bash -e` | `--update` 5 and `agents/` unchanged |
| `CLAUDE.global.md` missing; its recorded sha256 differs from the source; `AGENTS.global.md` differs from its source | `--check` 1 |
| `RSYNC` set to a shim that exits 1 | 70, and no staging folder left behind |

### Rollout

1. Off-repo, before C2. `homelab-monthly-review` and `pii-scrub` are in scope, so these edits
   must reach `~/.agents/skills` before `--update` copies them.
   - `homelab-monthly-review/SKILL.md`, "Known gap-classes" section: drop the sentence that names a private project.
   - `homelab-monthly-review/SKILL.md` Phase 2 item 1: add the step in the table below.
   - `pii-scrub/SKILL.md`, "Homelab scope" line: "part of the portfolio story" → "kept by decision".
   - Create `~/.config/sync-agents/private-terms.txt` and `denylist.txt`, then `chezmoi add` both.
   - Memory `decision_skill_location.md`: Codex 0.157.1 reads `<repo>/.agents/skills`. The 2026-09-27 snapshot does not reverse the 2026-08-08 decision, because the authoritative copy stays in dotfiles.
   - `chezmoi-sync`. These are Markdown and text files, so no lint applies, and dotfiles CI cannot run.
2. C1, then the Codex loop, then commit on `wt-oss-prep`.
3. C2, the gates, the Codex loop, commit.
4. C3, the gates, the Codex loop, commit.
5. Merge C1–C3 to `main` and push. CI does not run today, so the C1–C3 gates are the check.
6. From the Mac, `scripts/sync-agents.sh --check` on `main` exits 0.

The monthly-review step runs in the review's task worktree, never in the main tree. If
`scripts/sync-agents.sh` is absent, or the review is not running on the Mac, skip the step and
say so in the report. Otherwise run `--check` and act on its exit code, or on the exit code of
any `--update` a row below asks for:

| Exit of `--check` or `--update` | Action |
|---|---|
| 0 from `--check` | If an earlier row changed a file in this worktree, continue with row 1's commit step. Otherwise nothing to do |
| 0 from `--update` | continue row 1. If the `CLAUDE.md` source changed, hand-edit `CLAUDE.global.md`. Run `--check` until it exits 0, then review and commit |
| 2 | read each path the report names. If a skill was renamed or deleted, update the allowlist in the repo or the denylist in dotfiles, then run `chezmoi-sync` for the denylist |
| 3, 4 | For a copied skill, helper or `AGENTS.global.md`, fix the source in dotfiles, run `chezmoi-sync`, then run `--update`. For `README.md`, `sync/` or `CLAUDE.global.md`, fix the file in the repo. If a forbidden entry exists only in the target, delete it in the worktree. If git tracks it, remove it with `git rm --cached`. If `origin/main` contains the file or term, decide on a history rewrite before the next push. If SP6 has made the repo public, GitHub already shows that history. Then run `--check` again |
| 5 | fix the flagged helper's or skill's source in dotfiles, run `chezmoi-sync`, then run `--update` again |
| 70 | read the error, fix its cause, run the mode again |
| 1 | resolve every finding. For a list finding, update the allowlist in the repo, or the denylist in dotfiles and run `chezmoi-sync`. If an allowlisted skill or helper mentions a denylisted helper, choose one: edit the mention in dotfiles, or move the skill to the denylist. Run `chezmoi-sync` after either. Never allowlist the helper. The denylist holds it back from publication. Run `--update`. If the `CLAUDE.md` source changed, hand-edit `CLAUDE.global.md`. Repeat until `--check` exits 0. Then `git add -A agents` and commit through `/gitops-workflow`, with the Codex loop on `git diff --cached agents/` |

### Rollback

`git revert` the merged commits. Nothing live reads `agents/`. Also remove the monthly-review
step, because it calls the reverted script.

## SP3 — docs pass

SP3 makes every current doc true, removes the copies, and rewrites the pages a visitor reads
first in plain English. It also fixes the config drift that the spikes found. The live
firewall and SSH findings shipped on their own in `fd6dc2e2` (see HISTORY, 2026-09-27).

### What happens to each doc

"Rewrite" means a plain-English rewrite to the writing rules, with every fact re-derived.
"Facts" means fact fixes and slop-word fixes only, with the prose kept.

| Doc today | Action | Path after SP3 |
|---|---|---|
| `README.md` | rewrite; refresh the mermaid diagram and the repo-layout tree | same |
| `docs/ARCHITECTURE.md` | rewrite; refresh the four diagrams; drop its docs map (README keeps the public one) | same |
| `docs/SECURITY.md` + `docs/FIREWALL_SECURITY.md` | rewrite as one page: posture, the layers (link ARCHITECTURE), the host firewall model and the role that owns it, the 2025-10-30 incident, Authentik access. The Tailscale how-to is deleted | `docs/SECURITY.md` |
| `.backup/README.md` + `docs/disaster-recovery/README.md` | move and rewrite as the one DR runbook. The 5-line index is deleted; the MySQL restore step names `mysql-create-dbs.sql`. The DR scripts stay in `.backup/` | `docs/disaster-recovery/README.md` |
| `docs/BACKUP_STRATEGY.md` | rewrite as the policy page: RPO/RTO, one schedule table, tiers. Its restore and rebuild sections become links to the runbook. Its own changelog (2025-12 to 2026-02) is deleted, as HISTORY's older entries are | same |
| `docs/setup/K3S_SETUP.md` | rewrite as the one node-install page, immich-vm included. The DR runbook links to it | same |
| `docs/CODEMAPS/*.md` (6) | move and rewrite (decision 5) | `docs/subsystems/*.md` |
| `node-maintenance/README.md` | rewrite | same |
| `.github/workflows/README.md` | rewrite to cover all six workflows, as the page that documents CI | same |
| `docs/HOMELAB_HISTORY.md` | keep entries dated 2026-06-27 or later as one newest-first list, then rewrite them (decisions 18, 19) | same |
| `AGENTS.md`, `CLAUDE.md`, `docs/HOMELAB_ANALYSIS.md`, `docs/SECRETS_ROTATION.md`, `docs/runbooks/authentik-passkey-rollback.md`, `apps/home-assistant/OIDC_SETUP.md`, `apps/immich/gpu-node/README.md`, `monitoring/configs/kube-prometheus-stack/README.md`, `scripts/macos/README.md`, `.claude/review-invariants.md`, `.claude/agents/k8s-devops-reviewer.md`, `docs/plans/2026-09-07-immich-ml-followups-research.md` | facts. HOMELAB_ANALYSIS also drops the tables that copy README and `apps.md`, and keeps the lines with `NetworkPolicy resources`, `SOPS secrets` and `Kyverno CEL`, which `validate.yaml` greps | same |
| `apps/home-assistant/SECURITY.md`, `apps/stirling-pdf/SECURITY.md` | facts; drop the tables that compare other apps | `apps/<app>/PSS_EXCEPTION.md` |
| `apps/home-assistant/README.md` | delete: its DNS advice points at the CP, which runs no Traefik load balancer | — |
| 8 finished plans in `docs/plans/`, `node-maintenance/ANSIBLE_REVIEW_PLAN.md` | delete (decision 20) | — |
| `scripts/worker-node-post-install.sh` | delete (decision 21) | — |
| this plan | fix S22 and the Codex effort line; mark SP2 and SP3 done | same |

`agents/` is out of scope: its files are byte copies. Its four skills that name a moved path
change in dotfiles, and `--update` copies them in (C1).

### Spike results

| # | Question | Probe | Result |
|---|---|---|---|
| S27 | Which docs does the slop detector flag? | `avoid-ai-writing` detector, `--context technical --source-mode rendered-markdown`, on all 42 docs | ✅ every doc scores `HUMAN_ONLY`, 0 to 11. The detector only ranks files for reading order; it is not a gate. The writing rules are the standard |
| S28 | Do the mermaid diagrams render? | `mmdc` from `@mermaid-js/mermaid-cli` with Brave as the browser, on the 5 blocks; a broken block as control | ✅ all 5 render; the broken block exits 1 |
| S29 | Do private terms appear outside `agents/`? | `grep -I -i -F -f private-terms.txt` over the 691 tracked files; the file against itself as control | ✅ 0 hits; the control matches all 9 lines |
| S30 | Which facts are stale? | 219 drift-prone claims in 29 docs, checked against the cluster (`kubectl`, `flux`, `gh`) and the owning repo file | ✅ 125 OK, 53 stale, 34 wrong, 7 not checkable. The rows that matter are in the table below |
| S31 | Where do docs repeat or contradict each other? | full read of every current doc; the owning manifest settles each conflict | ✅ 33 topics, 47 contradictions, 11 merge or delete candidates |
| S32 | Links | a link checker (Markdown, reference and HTML links, GitHub heading slugs) with a known-bad control | ✅ 3 dead targets: the two commented-out screenshots in README, and HISTORY's link to the deleted 2025 archive |
| S33 | Plans, HISTORY and the old helpers | `git log`, HISTORY entries, reference greps | ✅ 8 plans done, this plan open, `immich-ml-followups-research` has open follow-ups. HISTORY: 4,036 lines, 189 dated entries from 2026-01-06; entries dated 2026-06-27 or later are 81 headings and about 247 KB. Its Milestones table already covers Oct 2025 to Q2 2026. `ANSIBLE_REVIEW_PLAN` closed 2026-04-28. `worker-node-post-install.sh` has no caller and contradicts the firewall and hardening roles |
| S34 | What reads a doc path? | `git grep` over `.github`, `scripts`, `.claude/hooks`, `node-maintenance/{install.sh,lib}`, `renovate.json`, `.pre-commit-config.yaml` | ✅ only `validate.yaml` (its warn-only drift job greps HOMELAB_ANALYSIS for `NetworkPolicy resources`, `SOPS secrets` or `Kyverno CEL`; today the file has the first and the third) and the analysis-reminder hook (HOMELAB_ANALYSIS path). Nothing reads `CODEMAPS` or `.backup/README.md`. `.pre-commit-config.yaml` still excludes `docs/superpowers/`, which no longer exists |
| S35 | Who links the paths that move or go? | `git grep` for each path and basename | ✅ `CODEMAPS`: AGENTS, README, ARCHITECTURE, HOMELAB_ANALYSIS, three plans, and in dotfiles `backup-nightly-verify` and `homelab-monthly-review`. `.backup/README.md`: AGENTS, ARCHITECTURE, `docs/disaster-recovery/README.md`, `.backup/secrets-restore.sh:307`, `couchdb-backup-cronjob.yaml:176`, `disallow-host-path-vp.yaml:45`, and in dotfiles `backup-restore-drill` and `k3s-upgrade`. Deleted plans: `apps/immich/gpu-node/{README.md,immich-vm-heal.sh}` (substrate-heal), the three `node_isolation_heal` role files (node-isolation-heal), `immich-ml-followups-research` (openvino). `apps/home-assistant/SECURITY.md`: `apps/home-assistant/deployment.yaml:24`. `FIREWALL_SECURITY`: README |
| S36 | Does the ECC `update-codemaps` command follow the rename? | read `commands/update-codemaps.md` (ECC 2.2.2) | ✅ no: it writes `docs/CODEMAPS/`. Nobody runs it here; the monthly review verifies the maps and never regenerates them |
| S37 | Is Grafana behind the tunnel? | `sops -d` of the tunnel config, hostnames only | ✅ no. The tunnel serves 9 hostnames: audiobooks, authentik, couchdb, immich, linkwarden, mealie, n8n, paperless, stirling |
| S38 | Config drift the docs describe | files, nodes, git history | ✅ the August scan shift was never reverted: trivy runs `0 8 8 * *` (namespace `trivy-scan`), and the security-scan timer runs `*-*-09` with `Persistent=false`. Before the shift (`1f1cda12`, then `67da4c30`) the timer ran `*-*-01 04:00 UTC` with `Persistent=true`. UFW opens 9090 to the LAN for a Prometheus that no longer exists; `ss` finds no listener on the CP. `roles/nic_tuning/files/igc-tune.service` has no task that copies it. All 9 units in `node-maintenance/systemd/` and 4 role units carry `Documentation=file:///etc/node-maintenance/README.md`, a file nothing installs |
| S39 | Can the firewall role delete a rule that has a source? | Debian container, ufw 0.36.2, ansible-core 2.21.4, community.general 13.4.0; seeded 9090 from the LAN with no comment, as `control_plane.yml` declares it and the CP's `user.rules` holds it, plus a no-source 9090 decoy | ✅ the delete with `from_ip` removes only the LAN rule; the decoy stays; the second run reports `changed=0`. The shipped delete task omits `from_ip`, so C0 adds it |
| S40 | Does reverting the scan timer start a scan? | user-scope timers on worker-node (systemd 262, the nodes' version), `OnCalendar=*-*-01`, a stamp dated 2026-07-01 as the nodes hold today (`/var/lib/systemd/timers/stamp-node-maintenance-security-scan.timer`: 07-01 on CP, W1, W2; 07-10 on immich-vm) | ✅ switching to `Persistent=true` with a daemon-reload only (the role's path) runs nothing, but the next restart of the timer runs the scan at once, and the weekly reboot restarts it. A stamp removed or set to now runs nothing. With `Persistent=false`, no stamp is read. So C0 keeps `Persistent=false` and changes only the calendar |
| S41 | Does the trivy schedule change start a Job? | `kubectl get cronjob -n trivy-scan` | ✅ `lastScheduleTime` is 2026-09-08. With `0 8 1 * *`, no scheduled time falls between then and now, so the controller starts nothing until 2026-10-01 |
| S42 | Do C1's manifest comment edits change live objects? | read each file around the line | ✅ `couchdb-backup-cronjob.yaml:176` sits inside the job's shell script (the `- \|` block at line 112), so the CronJob spec changes; the next backup Job runs a script that differs only in a shell comment. `apps/home-assistant/deployment.yaml:24` and `disallow-host-path-vp.yaml:45` are YAML comments outside any block scalar, so their objects do not change |
| S43 | Does a daemon-reload alone move a running timer to an edited `OnCalendar`? | user-scope timer on worker-node, `*-*-09` edited to `*-*-01`, `Persistent=false`, daemon-reload only | ✅ yes: the next elapse moved from 2026-10-09 to 2026-10-01 and the timer stayed active. The role needs no restart |

### Wrong facts to fix

C2 and C3 re-derive each row at edit time. The table records what the spikes found. It leaves
out stale counts (NetworkPolicies, SOPS files, HelmReleases, PSS levels), because C2 re-counts
them. If a rewrite keeps one of S30's 7 not-checkable claims, the rewrite either measures it
or says it was not measured.

| Doc | Claim | Truth, and where it lives |
|---|---|---|
| README, ARCHITECTURE, DR runbook | K3s v1.36 | v1.37.0+k3s1 on all nodes. ARCHITECTURE states no version (its own rule); README drops the minor from the badge |
| README, ARCHITECTURE, AGENTS, DR runbook | Flux applies a commit in 60 s | Flux fetches the Git source every 5 min (`gotk-sync.yaml`) and runs each Kustomization every 1 min |
| README (text and diagram) | CI validates every push; the diagram's CI box sits between the repo and Flux | 8 validate jobs plus 5 more workflows. Flux does not wait for CI. No job has started since 2026-09-10 (billing). SP6 re-checks once the repo is public |
| README | CouchDB is single-instance; W1 holds the Postgres replica | CouchDB `clusterSize: 2`. W1 is the primary's pin target; the role moves on failover |
| README | repo-layout tree | add `node-maintenance/`, `scripts/`, `agents/` |
| ARCHITECTURE | the Watchdog alert routes to null | it routes to receiver `deadman` (healthchecks.io); the "monitoring is blind" trade-off changes |
| ARCHITECTURE, HOMELAB_ANALYSIS | Percona `User` CR | no such CRD; users come from SQL |
| HOMELAB_ANALYSIS, BACKUP_STRATEGY | Grafana, Audiobookshelf and `app` are Postgres databases | both apps use SQLite. The databases are authentik, blocky, immich, linkwarden, mealie, n8n, paperless |
| HOMELAB_ANALYSIS, `subsystems/monitoring`, node-maintenance README | the scans go back to the 1st after August | true after C0 |
| SECURITY | apps are LAN-only; admin login is password + TOTP | 9 apps are on the tunnel; login is passkey-only since 2026-06-05, with TOTP as recovery |
| FIREWALL_SECURITY | 6443 local only, 10250 localhost only, Grafana tunnel-only, Linkding and Wallabag tunneled, tunnel → Traefik | after `fd6dc2e2`: 6443 from the LAN, node IPs and pod network; 10250 from node IPs and pod network; Grafana is LAN-only; cloudflared calls each Service directly |
| BACKUP_STRATEGY | CouchDB backup in namespace `couchdb`; restore via `main-postgres-1`; 13 PVCs; NAS pruned by hand, no SSH; n8n has OIDC; backup alerts are future work | `databases`; primary found by label; 14 PVCs; Step 4b prunes, NAS SSH on :56634; n8n has none; five backup alerts exist |
| BACKUP_STRATEGY restore blocks | paths and tools | wrong against the drilled runbook (`couchrestore` is not in the image; no `mysql_` prefix on per-DB files). Replaced by links |
| DR runbook | step 1 runs `docs/scripts/setup-node.sh`; three rollback tags; `.backup/` is git-ignored; critical PVCs = 3 apps | `scripts/setup-node.sh`; only `pre-ultrareview-2026-07-03` exists; only `.backup/secrets/` outputs are ignored; 14 PVCs |
| node-maintenance README | 3 nodes; `igc-tune@`; isolation heal is dry-run; drift-heal daily 03:00; no Telegram on scan failure; `install-worker-ready.sh` | 4 nodes; `nic-tune@`; active since 2026-07-23; 03:00 and 15:00; failures notify; `install-worker.sh` |
| `.github/workflows/README.md` | two workflows; a `.disabled` file | six workflow files; no `.disabled` file |
| SECRETS_ROTATION | ten Secret names such as `mealie-db-password`; Blocky rotation reconciles `infrastructure-controllers` | live names such as `*-db-user`, `home-assistant-secrets`; `infrastructure-configs` |
| `subsystems/apps` | uptime-kuma has a PVC; audiobookshelf has 2 PVCs; obsidian is LAN-only | no PVC; 4 PVCs; LiveSync reaches couchdb through the tunnel |
| `subsystems/databases`, `networking`, `monitoring`, `backup-restore` | CouchDB admin Secret `couchdb-credentials`; pooler users; 4 Job egress policies; per-app certs; cloudflared ServiceMonitor path; `.backup/` scripts ignored; the 2026-05-22 drill covered extraction | `couchdb-couchdb`; authentik, mealie and immich also go direct; 5 including `immich-vm-heal-egress`; 18 Certificates; no ServiceMonitor in git; tracked; the drill checked archives, not extraction |
| `review-invariants.md` | middleware `traefik-csp@kubernetescrd`; hostnames in `cloudflared.yaml` | apps use `csp-inline-enforced` / `csp-permissive-enforced`; hostnames are in `cloudflared-config-secret.yaml` |
| `k8s-devops-reviewer.md` vs CLAUDE.md | CLAUDE.md says every reviewer checks `review-invariants.md` first | the agent prompt never names it. Add the instruction to the prompt |
| `PSS_EXCEPTION` (Home Assistant) | PSS baseline; `home-assistant-oidc` Secret | `privileged`; the client secret is in `home-assistant-secrets` |
| `PSS_EXCEPTION` (Stirling) | Stirling v2.0; "no Linux caps granted" | image `3.0.0-fat`; four caps are added |
| passkey rollback runbook | "all 4 phases", 4 blueprints | 5 blueprints; phases 40 and 50 are not covered |
| `kube-prometheus-stack/README.md` | cloudflared may reach `monitoring` on 3000 and 9093 | no such egress rule |

### Assumptions and limitations

| Tier | Item |
|---|---|
| ⚠️ | The C4 token check compares the token kinds in its table, both ways, with counts. It says nothing about paths outside backticks, word order or meaning. Codex reads source and rewrite side by side for those |
| ⚠️ | Other sessions append to HISTORY and HOMELAB_ANALYSIS (one open worktree today). C4 starts from a fresh `origin/main`. If `main` gains entries before C4 merges, rebase and keep them |
| ⚠️ | Every merge to `main` runs drift-heal on all four nodes, because the sync runs the playbook on any new SHA. So SP3 merges four times: C0 alone, then C1–C2, then C3a–C3d, then C4 with C5's plan change. C5's memory edits are outside the repo |
| ⚠️ | C0 has two deadlines on 2026-10-01, measured when each change reaches the cluster, not when it merges. If a node's timer is not reloaded by 04:00 UTC, that node's next scan is 11-01, so the operator starts its October scan by hand. If Flux applies the CronJob after 08:00 UTC while `lastScheduleTime` still reads 2026-09-08, the controller starts the missed 10-01 run at once, because the CronJob sets no `startingDeadlineSeconds` |
| 🟡 | GitHub renders mermaid with its own version; S28 used `mmdc`. Check each changed diagram on GitHub after merge |
| ⚠️ | Old paths stay inside HISTORY entries that predate the move, as history. Only links must resolve |
| ⚠️ | After the rename, running ECC `update-codemaps` would recreate `docs/CODEMAPS/`. Accepted: nobody runs it here (S36) |
| ⚠️ | C0 keeps the scan timer at `Persistent=false` (S40). A node that is down at 04:00 on the 1st skips that month's scan; before August, `Persistent=true` ran it on the next boot. Restoring that needs a stale-stamp step in the role; it can follow later. When the 1st is a Saturday (next: 2027-05-01), the 04:00 scan and its random delay of up to an hour overlap the 04:30 maintenance window, as they did before August |
| ⚠️ | The gate script, its helpers, the link checker and its control, and the S30–S31 reports live in `~/.local/share/homelab-sp3/` (`$T`), outside the repo and outside chezmoi, so a later session can reach them. SP4 decides whether to commit the link checker |
| ⚠️ | CI starts no job (billing), so every gate below runs locally |

### Commits

Every commit gets the Codex loop, docs included. As in SP2, each review file stays at 30 KB or
less. If a commit's diff is larger, one round sends one dispatch per chunk, and the round's
findings are the union of the chunks' findings. Each review file inlines the writing rules,
the gate output, and the commands used to re-derive the facts it changes.

| Commit | Content | Review file holds |
|---|---|---|
| C0 config drift | see the C0 list below | the diff; S38–S41 |
| C1 moves and links | see the C1 list below | the rename list, the dropped index lines, the link-site diff, `git diff --cached agents/` |
| C2 facts | the facts-only docs from the first table, fixed row by row | the diff; one re-derive command per changed fact |
| C3a | README and ARCHITECTURE | the diff; the mermaid output |
| C3b | the merged SECURITY page; `FIREWALL_SECURITY.md` deleted; README's docs table updated | the diff; the live `ufw` facts from `fd6dc2e2` |
| C3c | DR runbook, BACKUP_STRATEGY, K3S_SETUP | the diff, chunked; every fenced command of the drilled runbook, before and after, compared byte for byte |
| C3d | `docs/subsystems/*`, node-maintenance README, workflows README | the diff, chunked |
| C4a HISTORY trim | keep entries dated 2026-06-27 or later, newest first, under one heading, each byte-identical to its source; keep the Milestones table; fix the header's coverage line. AGENTS.md's HISTORY line says the file keeps the last 3 months, that a new entry goes at the top, and that the monthly review deletes older entries. Every current-doc link to a removed entry names the commit instead | the kept-heading lists and per-entry hashes, before and after; the relinked sites |
| C4b… HISTORY rewrite | the kept entries in batches of 12 KB or less of source, so source and rewrite fit one review file. Each heading keeps its date prefix; if its text changes, the link gate finds every anchor that broke, and the same commit fixes it. `sp3-gates.sh C4b --src <batch source> --new <batch rewrite>` runs per batch | per batch: source, rewrite, the token-check output |
| C5 close-out | this plan: roadmap SP3 done, merged with C4. Memory: `reference_homelab_docs.md` (subsystems path; `docs/superpowers/` is gone) and each memory file that the gate script's old-path pattern, plus `FIREWALL_SECURITY` and `docs/superpowers`, finds in the memory folder | memory is outside the repo; the plan change is a one-line diff |

C0, in order:

1. `monitoring/configs/trivy-scan/cronjob.yaml`: schedule `0 8 1 * *`, TEMPORARY comment removed.
2. `roles/security_scan/files/node-maintenance-security-scan.timer`: `OnCalendar=*-*-01 04:00:00 UTC`,
   `Persistent=false` kept (S40), TEMPORARY comment removed. A daemon-reload applies it (S43).
3. The firewall delete task passes `from_ip`. The 9090 LAN rule moves from `control_plane.yml` to
   `ufw_rules_absent`, whose comment then says: an entry for a no-source rule has no `from_ip`,
   and no entry has a comment.
4. `git rm roles/nic_tuning/files/igc-tune.service`.
5. Each `Documentation=` that names `/etc/node-maintenance/README.md` names
   `https://github.com/AKhozya/homelab/tree/main/node-maintenance` instead. It resolves if SP6
   makes the repo public.
6. HOMELAB_ANALYSIS drops its August-shift rows.

C1, in order:

1. `git rm` the 5-line `docs/disaster-recovery/README.md`, then `git mv .backup/README.md` into
   its place. The review file lists the dropped lines.
2. `git mv` the CODEMAPS folder to `docs/subsystems/` and each app `SECURITY.md` to `PSS_EXCEPTION.md`.
3. `git rm` the 8 finished plans, `ANSIBLE_REVIEW_PLAN.md`, `apps/home-assistant/README.md` and
   `scripts/worker-node-post-install.sh`.
4. Update every link site from S35. A comment that named a deleted plan names the plan's title
   and the commit that last changed it, without the path, for example "the node-isolation-heal
   design plan, removed after `<sha>`", so the old-path gate stays strict. The edit in
   `couchdb-backup-cronjob.yaml` changes the CronJob spec (S42).
5. Delete HISTORY's dead archive link. HISTORY's three links to deleted plans (the 2026-07-24
   and 2026-07-26 entries) become plain text with the commit. The link check skips HTML
   comments, so README's commented-out screenshot block stays. The link check then passes
   from C1.
6. Drop the `docs/superpowers/` excludes from `.pre-commit-config.yaml` and `.yamllint.yaml`.
7. Dotfiles: give the four skills from S35 the new paths, and add the rolling trim to
   `homelab-monthly-review` Phase 5 item 2 (decision 18): after the new HISTORY entry, delete
   every entry whose `### YYYY-MM-DD` date is more than 3 months before the review date. An
   entry runs from its heading to the next `## ` or `### ` heading. Git keeps the deleted text.
   Then find each link to a deleted entry, from other files (`git grep -n 'HOMELAB_HISTORY.md#<date>'`)
   and inside HISTORY (`grep -n '(#<date>' docs/HOMELAB_HISTORY.md`), and replace it with the
   entry's commit. Then run `chezmoi-sync` and `scripts/sync-agents.sh --update`; the refreshed
   `agents/` files join C1.

C1 changes no other prose.

### Gates

`$T/sp3-gates.sh <step>` runs every gate for a step. It needs bash 5 (`#!/usr/bin/env bash`
finds Homebrew's 5.3; macOS `/bin/bash` 3.2 lacks `mapfile`, and the script exits 2 under it).
It compares the working tree, untracked files included, with its merge-base against
`origin/main`. It runs every check, prints `ok:` or `FAIL:` for each, and exits 1 if any
failed. A search gate passes only on exit code 1 (no match), so an error cannot pass.

| Steps | Gates | Control |
|---|---|---|
| all | no private term in a changed file; `pre-commit` on changed files; `gitleaks dir` with `.gitleaks.toml`; `yamllint` on changed YAML; `kubeconform -strict` on each changed file of a built-in kind; each `validate.yaml` phrase that the merge-base's HOMELAB_ANALYSIS has is still there | the terms file has 9 lines and the search matches all 9 |
| all | every mermaid block in a changed `.md` is extracted at gate time and rendered by `mmdc` from `@mermaid-js/mermaid-cli@12.0.0` (Brave). A fence may be indented and use 3 or more backticks or tildes; it closes on a line of the same character, at least as long; an unclosed fence fails | the extracted count equals the fence count |
| C0 | in a Debian container at the node versions (ansible-core 2.21.4, community.general 13.4.0), with the lint tools pinned to the baseline's (ansible-lint 26.9.0, kubernetes.core 6.6.0, ansible.posix 2.2.2): `ansible-playbook --syntax-check node-config.yml` exits 0, `ansible-lint roles` exits 0 or 2 (2 means findings; anything else is a crash) and gives the same rule-and-file findings, duplicates included, as `$T/ansible-lint-baseline.txt` (two on `origin/main`) | — |
| C1 on | the retired paths do not exist, tracked or untracked; the link checker over every tracked and untracked `.md`: it skips HTML comments and fenced code in one pass (a backticked `<!--` opens no comment, and a fence line inside a comment opens no fence), accepts only a target git would publish, spelled as in the index, inside the worktree, and reports a file it cannot read; no `.md` file is untracked, so a doc that passes the link check is also committed; `scripts/sync-agents.sh --check`; the old-path grep, untracked files included, outside HISTORY and this plan; no bare `SECURITY.md` name under `apps/` (a `docs/SECURITY.md` link passes) | the doc list has more than 40 files; the link checker, run first, reports exactly the 15 lines in `$T/linkcheck-control/expected.txt` (a crash also exits 1, so the lines are compared, not counted). They cover a missing file, image and anchor, a wrong-case target, a target outside the folder, anchors that exist only inside a comment or inline code, and links after a backticked `<!--`, a backticked `-->` inside a comment, a comment holding a fence, a fence holding a ```` ```example ```` line, a four-space-indented closer, an empty `<!-->` comment and a line that starts with an inline code span, plus a file that is not UTF-8. A footnote definition and two commented-out links must not appear; a known string matches with the same pathspec |
| C4a on | at C4a, the sha256 of each entry dated 2026-06-27 or later (`$T/entry-hashes.sh`) is the same in the working tree as at the merge-base, compared sorted, so the entry order does not matter; at C4b, the entry dates, sorted, are the same. At both, every `### ` heading is an entry dated 2026-06-27 or later, so no undated block and no older date remains, and no file outside this plan and `agents/` still calls HISTORY append-only | the helper exits 1 if it finds no entry in the window; the heading check fails if HISTORY has no `### ` heading |
| C4b | `$T/token-check.py <source> <rewrite>` for the batch (`--src`, `--new`); neither file is empty; every entry in the source is an unchanged entry of the merge-base, and the source has at least one; the rewrite appears verbatim in `docs/HOMELAB_HISTORY.md`. The batch review file holds the diff of the commit as well as source and rewrite | `token-check.py --selftest` runs a built-in sample and rejects six rewrites of it: a SHA in code removed, a prose count changed, a command changed inside an indented four-backtick fence, a prose SHA removed, a date changed, a URL changed |

An entry runs from its `### YYYY-MM-DD` heading to the next `## ` or `### ` heading; deeper
headings stay inside it. That boundary matters: a `### December 2025 Review Findings` block, which C4a removes, comes right
after the 2026-07-03 entry, and HISTORY has 87 `####` headings inside entries.

The retired paths and the old-path grep cover `CODEMAPS`, `.backup/README`,
`ANSIBLE_REVIEW_PLAN`, `worker-node-post-install`, `home-assistant/README`, `apps/…SECURITY.md` and the 8 deleted plan
names from C1, and `FIREWALL_SECURITY` from C3b.

Tested on `fd6dc2e2`, each run invoked directly:

| Run | Result |
|---|---|
| `C0` with a comment line added to the trivy CronJob | PASS: yamllint, `kubeconform -strict` (Valid 1, Skipped 0), the container, syntax and lint checks (`lint exit 2`, the two baseline findings). The same CronJob with `schedule` misspelled fails `kubeconform` |
| the mermaid extractor on an indented `~~~` block, a four-backtick fence holding a three-backtick line, and an unclosed fence | 3 blocks: the extractor strips the indent, keeps the four-backtick block whole and reports the unclosed fence |
| `C0` with a temporary doc holding a good and a broken mermaid block | the good one renders; the broken one fails |
| `C1` | fails on HISTORY's dead archive link (README's two commented-out links no longer count), the retired paths, the old-path grep and `apps/…SECURITY.md`, as expected before C1; every control passes |
| `C4a` | 81 window entries at the merge-base; the hashes match; the heading check fails on the old headings, as expected before the trim |
| `C4b` with the 2026-09-26 node-maintenance entry as the batch | with a reworded copy placed in HISTORY, the token, source-subset, verbatim and date checks pass; a reworded rewrite that is not in the tree fails the verbatim check; empty `--src` and `--new` files fail three checks. On a sample batch, rewrites without the SHA, with a digit changed, or with a fenced command changed fail the token check; the self-test rejects its six mutants |
| `C9`, `--src` with no value, and `/bin/bash` running either script | exit 2 |
| `entry-hashes.sh` on a copy of HISTORY with one line removed from one entry | output changes |

The C4 token check (`$T/token-check.py`) lists these tokens in a batch's source
and in its rewrite, and fails if the two lists differ in any token or in how often it occurs:

| Token | Pattern |
|---|---|
| commit SHA | 7 to 40 hex characters with at least one of `a`–`f` |
| date | `YYYY-MM-DD` |
| number | every run of digits, so versions, IPs, ports and counts are covered |
| inline code | each backticked span |
| fenced block | each fenced code block, compared byte for byte |
| URL | `http://` or `https://` up to the next space, `)`, `>` or `]`, without a final `.`, `,`, `;` or `:` |

### Rollout

1. C0: gates, Codex loop, commit, merge alone, early enough that every node's timer reloads before
   2026-10-01 04:00 UTC (see Assumptions), and outside Saturday 03:00–07:00 UTC, when the weekly
   update and reboot run. Flux applies the CronJob. The next
   sync runs `install.sh --sync-only`, which installs the 9 units in `node-maintenance/systemd/`,
   and then drift-heal, which installs the role units, deletes the 9090 rule and reloads the
   timer. Check without sudo:

   | Check | Expect |
   |---|---|
   | `kubectl -n trivy-scan get cronjob trivy-scan` | schedule `0 8 1 * *`; no Job created since the merge |
   | `systemctl list-timers node-maintenance-security-scan.timer`, each node | next run 2026-10-01 |
   | `systemctl show --property=Documentation node-maintenance-sync.service` on the CP (from `systemd/`), and the same for `node-maintenance-security-scan.service` on a worker (from the role) | the repo URL |
   | `/etc/ufw/user.rules` (mode 644), CP | no 9090 tuple |
   | `/var/log/node-maintenance/config-latest.log` (group `adm`) | `failed=0` on every host; the 9090 delete `changed` on the CP |
2. C1 and C2, then merge. C3a–C3d, then merge. Nothing live reads these files, except the
   CouchDB CronJob script comment (S42).
3. C4a and C4b onward from a fresh `origin/main`, and C5's plan change; merge them once, at the
   end.
4. C5's memory edits.

### Rollback

`git revert` the commit. For C1, also revert the dotfiles skill commit, run `chezmoi-sync`, then
`scripts/sync-agents.sh --update`. Two commits have a live effect. Reverting C0 puts back the
August schedules, the old `Documentation=` lines and the 9090 rule; the role adds the rule again
on the next drift-heal. Reverting C1 changes the CouchDB backup script comment back (S42), which
Flux applies to the CronJob.

## SP4 — pre-public gate

SP4 finds what a public reader could see that they should not, and fixes what a commit can fix.
It adds the licence, pins every GitHub Action to a commit, and limits the Claude workflow to the
owner. Some items need the operator: old values in PR refs, repo settings, and dashboards with no
licence. The operator's answers of 2026-09-28 settle them, and the last table in this section
lists them.

### Spike results

Run 2026-09-28 against `origin/main` at `aec47982`, and against a mirror clone made the same day.
A mirror clone fetches every ref GitHub serves, `refs/pull/*` included.

| # | Question | Probe | Result |
|---|---|---|---|
| S44 | What does gitleaks find in history? | `gitleaks git . --log-opts=origin/main --config .gitleaks.toml --redact` (8.30.1); then on the mirror with `--log-opts=--all` | ✅ `main`: 11 findings in 9 commits, the same as the 2026-07-26 audit. All refs: 15. The 4 extra findings sit in commits that only PR refs reach, from before the 2026-06-12 history rewrite. See the table below |
| S45 | Which refs does GitHub serve? | `git ls-remote origin`, grouped by prefix | ✅ 1 branch, 51 tags, 442 `refs/pull/*/head` and no `/merge` refs. Decision 7 counted 436; each new Renovate PR adds one |
| S46 | Did a key or a secrets file ever reach any ref? | on the mirror, `git log --all`: files added under `.backup/ENV_VARS.md`, `.backup/secrets`, `*.age`, `*keys.txt`, `*id_ed25519*`, `*kubeconfig*`, `*.pem`, `*.key`; content matching `AGE-SECRET-KEY-1`, `BEGIN … PRIVATE KEY`, `TunnelSecret`, `client-key-data`, `ghp_`, `github_pat_`, `sk-ant-` | ✅ 0 on every ref. The SOPS age key never reached git, so the SOPS values in history stay encrypted. `git ls-files .backup` holds only the two scripts |
| S47 | What does `claude-code-action@v1` enforce? | read `src/github/validation/permissions.ts` and `actor.ts` at the `v1` tag (`756cc22e`, v1.0.235) | ✅ with `allowed_non_write_users` empty (our case), a human actor needs `write` or `admin` on the repo. A bot actor is refused unless `allowed_bots` lists it, and ours is empty. So a stranger's `@claude` comment cannot use the token today. The job still starts and checks out the repo before the action refuses. An actor guard in `if:` stops the job before any step runs, and it does not depend on a moving tag's code |
| S48 | Which `uses:` follow a moving tag, and what do they point at? | `grep -rn 'uses:' .github/workflows/`; `gh api repos/<o>/<r>/commits/<tag>` and the repo's tags on the same commit | ✅ 22 references to 9 actions. 14 follow a tag (see Pins); the other 8 already name a full SHA with a version comment |
| S49 | Do the actions call other actions by tag? | each action's `action.yml` at the pinned SHA | ✅ two are composite: `claude-code-action` calls `oven-sh/setup-bun@0c5077e5…`, a full SHA, and `fluxcd/flux2/action` calls none. The other seven run on `node24`: `checkout`, `setup-python`, `github-script`, `peter-evans/create-pull-request`, and the three `docker/*` actions |
| S50 | Does GitHub's "require SHA pins" setting check nested actions? | GitHub's docs page on the setting says nothing about nesting; two public reports test it | 🟡 yes: both reports see a job fail at setup when a composite action inside it uses a tag. S49 finds none here |
| S51 | Does Renovate have the preset, and what does it do? | `lib/config/presets/internal/helpers.preset.ts` in `renovatebot/renovate` (latest release 44.116.0) | ✅ `helpers:pinGitHubActionDigestsToSemver` extends `helpers:pinGitHubActionDigests` (`pinDigests: true` for dep types `action` and `workflow`) and tracks full `vX.Y.Z` versions. The repo's `pinDigests: false` rule matches only the `helm` and `docker` datasources, so it does not undo the preset |
| S52 | Does `renovate-config-validator` catch a bad preset name? | `npx --package renovate@44 renovate-config-validator --strict` on `renovate.json`, on it plus the new preset, and on it plus `helpers:noSuchPreset` | ✅ all three pass, so the validator checks the schema only. The preset name rests on S51 (see Assumptions) |
| S53 | What do the repo's Actions settings say? | `gh api repos/AKhozya/homelab/actions/permissions` and `…/permissions/workflow`; `yq` over each workflow's `permissions:` | ✅ all actions allowed; `sha_pinning_required: false`; default token `write`; workflows may approve PRs. Every workflow sets `permissions:` at the top or on each job, so a default of `read` changes no current workflow |
| S54 | What does a fork PR run? | each `pull_request` workflow and the secrets it names | ✅ a fork PR runs the workflow file as the fork wrote it, so an `if:` in it is no barrier. The barrier is GitHub's: a fork PR gets a read-only token and no secrets. A setting makes outside contributors' PRs wait for approval. GitHub's API refuses to read it while the repo is private (HTTP 422), so SP6 sets it |
| S55 | Do vendored files carry their own licence? | `gnetId` in the dashboards; file history; each upstream repo's licence via `gh api repos/<o>/<r>/license`; the grafana.com terms of service | ✅ see the licence table below. The grafana.com terms let a user use community content "solely for your personal use and/or internal business operations", which does not cover publishing a copy. So a grafana.com dashboard is publishable only under an upstream licence |
| S56 | Which files name `/Users/akhozya`? | `git grep` outside `agents/` and HISTORY | ✅ the two hooks (`HOMELAB_MAIN=`), `AGENTS.md:69`, `CLAUDE.md:33`, and this plan. They stay, as decisions 4 and 11 keep usernames and skill paths. The hooks need the path to find the main tree |
| S57 | Are commits signed? | `git log --format=%G? origin/main` | ✅ 3,654 of 4,374 are unsigned; 324 good, 394 unverifiable, 2 untrusted. Signing is not a repo rule, so the unsigned SP3 commits need nothing |
| S58 | Why does editing `vmrules.yaml` or `claude.yml` fail a gate? | `yamllint .` (CI) and `yamllint -s` (pre-commit) | ✅ `.yamllint.yaml` sets `line-length` to `warning`. CI runs `yamllint .`, which exits 0. Pre-commit passes `--strict`, which turns warnings into exit 2. So any edit to one of the 15 files with a line over 200 characters fails. `vmrules.yaml` has 25; `claude.yml` has 1 (its `if:`) |
| S59 | Do the mermaid diagrams still render? | the 5 blocks in README and ARCHITECTURE through `mmdc` (`@mermaid-js/mermaid-cli`, mermaid 12.0.0, Chrome) | ✅ all 5 render; no SVG holds a syntax error |
| S60 | Did the `aec47982` drift-heal pass? | `config-latest.log` on the CP; the sync journal | ✅ the run started 29 s after the push: `changed=0 failed=0` on all four nodes |
| S61 | Does actionlint pass today? | `actionlint -oneline` (1.7.12) | ✅ 7 findings, all shellcheck notes on `run:` scripts in `claude-telegram-build.yml`, `flux-update.yaml` and `validate.yaml`. Saved without line numbers as the baseline |
| S62 | What shows that Renovate ran on a commit? | the Dependency Dashboard, issue #32 | ✅ its `github-actions` list names each reference as Renovate read it: `actions/checkout v7` for a tag, `actions/checkout v7.0.1@3d3c42e5…` for a pin. Its `updatedAt` moves on each run |
| S63 | Did the drift-heal after the rotation merges pass? | `config-latest.log` on the CP after the run for `54e755a3`, whose tree contains `52ce08aa` | ✅ `changed=0 failed=0` on all four nodes |
| S64 | Can the long lines be fixed without changing what Flux applies? | classify each line `yamllint -s` flags by its YAML scalar style; in a scratch run, wrap the quoted and plain values and add the directives; compare each wrapped file's parsed documents (`parse-eq.py`), and `kustomize build --enable-helm` of the 7 CI roots, before and after | ✅ 87 lines in 15 files; the fix for each class is in the C0 table. Wrapping the 4 authentik blueprints changed the `authentik-blueprints-custom` ConfigMap, because a `configMapGenerator` copies those files into it as raw text (see S66). With the blueprints left as they are, all 7 roots build byte-identical, and all 10 changed files parse the same. Three mutants fail the parse check: a `>-` changed to `\|`, a doubled space inside a quoted value, and a `true` changed to `1`. After the scratch run, `yamllint -s .` flags only `claude.yml`'s `if:` |
| S65 | Can private vulnerability reporting be turned on now? | `gh api repos/AKhozya/homelab/private-vulnerability-reporting`; GitHub's docs page on the setting | ✅ no. The API answers 404 while the repo is private, and the docs offer the setting to "owners and administrators of public repositories". It moves to SP6 |
| S66 | What does a byte change in a blueprint file do? | Authentik's blueprint docs; each custom `BlueprintInstance`'s `status` and `last_applied`, read through `kubectl exec -n authentik deploy/authentik-worker -- ak shell -c …` | ✅ Authentik applies a blueprint when its file changes. All 5 custom blueprints read `successful`, last applied on 2026-07-25, so the hourly run skips an unchanged file. A wrapped file would start the first apply since then, and an apply sets every attribute its entries list. If someone changed one of those attributes in the Authentik UI since 2026-07-25, the apply would undo that change. So C0 leaves the 4 files as they are |

S44's findings, by class. "Record" means `docs/SECRETS_ROTATION.md`; no live value was compared.

| Finding | Reached from | Status |
|---|---|---|
| MySQL `IDENTIFIED BY` for homeassistant, uptimekuma and pricebuddy (3), commit `23f7eb5f`, 2025-12-16 | `main` | 🟡 the record rotates all three on 2026-04-02 |
| couchdb admin password (1), 2025-10-08 | `main` | 🟡 the 2026-07-26 audit found the live value differs; the record rotates it on 2026-04-02 |
| stirling-pdf client secret (5), 2025-11-27 | `main` | 🟡 the record rotates the Stirling OIDC secret on 2026-04-02 |
| homehub password (1), 2025-10-24 | `main` | 🟡 the audit found the live value differs; the record lists a rotation on 2025-10-26 |
| linkding db secret (1), 2025-10-08 | `main` | ✅ Linkding is gone, with its namespace |
| couchdb (1) and linkding (1) again, in pre-rewrite commits `ba739489` and `0ecb4bef`, 2025-10-08 | PR refs #18–#26 | 🟡 as the two rows above: both predate the rotation or the removal |
| a Cloudflare API token (40 characters) in `.backup/QUICK_REFERENCE.md`, commit `7349f6cc`, 2025-10-07 | 18 PR refs, #13 upward; not `main` | ✅ dead since 2026-09-28. It was the live cert-manager token: `cloudflare-secret.yaml` had not changed since 2025-10-06 (`sops.lastmodified`), so the record's "2025-10-19" was no rotation. The operator rolled the token, which ends the old value, and `52ce08aa` carries the new one |
| a Telegram bot token (46 characters), same commit | same | ✅ dead since 2026-09-28. It was the live @h0melab_alerts_bot token (`alertmanager-telegram-secret.yaml` unchanged since 2025-10-07). The operator revoked it in BotFather; `52ce08aa` carries the new one |
| the Telegram chat ID, same commit | same | not a credential. It is the ID the bot allowlists (decision 16) |

The 2026-06-12 rewrite recorded the PR-ref residual as "the Cloudflare account ID only"
(memory `reference_repo_publish_sanitization`). Decision 7 rests on that. S44 found two live
tokens as well. This session's auto-mode safety check blocked a comparison of the findings with
live cluster Secrets as credential handling, so the operator judged each row (Q1). Both tokens
are now dead, and the operator accepts the rotation record for the 🟡 rows.

Licences of the vendored files (S55):

| File | Source | Licence |
|---|---|---|
| `monitoring/configs/grafana-dashboards/redis-dashboard.yaml` | grafana.com 763, by oliver006; the same dashboard ships in `oliver006/redis_exporter` `contrib/` | MIT, "Copyright (c) 2016 Oliver" |
| `monitoring/configs/grafana-dashboards/traefik-k8s-dashboard.yaml` | grafana.com 17347, by Traefik Labs; `traefik/traefik` `contrib/grafana/traefik-kubernetes.json` | MIT, "Copyright (c) 2016-2020 Containous SAS; 2020-2025 Traefik Labs" |
| `monitoring/configs/grafana-dashboards/cnpg-dashboard.yaml` | the CloudNativePG dashboard (🟡, matched by content), `cloudnative-pg/grafana-dashboards` | Apache-2.0; the repo has no NOTICE file |
| `clusters/flux-system/gotk-components.yaml` | generated by `flux install` | Apache-2.0 (`fluxcd/flux2`); no NOTICE file |
| `monitoring/configs/grafana-dashboards/cert-manager-dashboard.yaml` | grafana.com 20842, by chrede88; `chrede88/grafana-dashboards`. Our copy is revision 1 with one input renamed | ⚠️ none: that repo has no licence. Kept (Q5) |
| `monitoring/configs/grafana-dashboards/loki-stack-dashboard.yaml` | grafana.com 14055, by Quortex; rewritten here for Alloy | ⚠️ none found: no Quortex repo holds it. Kept (Q5) |

### Assumptions and limitations

| Tier | Item |
|---|---|
| ⚠️ | gitleaks finds values that match its rules. A secret in a shape no rule knows passes. S46's searches cover the key and file shapes this repo has used |
| ⚠️ | A history rewrite cannot reach PR refs (decision 7). Only revoking a token at its issuer makes the copy harmless. Both live tokens S44 found are revoked; the 🟡 rows rest on the rotation record, which the operator accepts (Q1) |
| ⚠️ | The two dashboards with no licence stay in the tree, in history and in PR refs (Q5). The grafana.com terms cover personal use only (S55), so publishing them is a risk the operator accepts. `THIRD_PARTY.md` names each author and source |
| 🟡 | S50 rests on two public reports, not on GitHub's docs. S49 finds no nested tag, so the setting is safe to turn on either way |
| 🟡 | No local check proves that Renovate loads `helpers:pinGitHubActionDigestsToSemver`: the validator ignores preset names (S52), and C1 pins every reference by hand. The preset name comes from Renovate's source (S51). If it fails to load, Renovate opens a config-error issue. Its effect shows only when someone adds a new tag reference, which Renovate should then pin. The `sha_pinning_required` setting (Q3) makes a workflow with a tag reference fail at setup whether or not the preset loads |
| ⚠️ | CI starts no job (billing), so no workflow edit runs before SP6. actionlint and yamllint are the only checks on them |
| ⚠️ | If the owner mentions `@claude` on an issue or PR that someone else wrote, Claude reads that person's text as part of its input. The actor guard cannot stop that. The owner decides when to call Claude on outside content |
| ⚠️ | Pinning `claude-code-action` to v1.0.235 means a Renovate PR for each release, and the project releases often. The workflow runs only when the owner calls it, so an older release affects only the owner's own requests. If the PRs become too many, a Renovate schedule for that one action can follow |
| ⚠️ | S55 checked the dashboards and the Flux manifest. It did not search the rest of the tree for copied files |
| 🟡 | GitHub renders mermaid with its own version; S59 used mermaid 12.0.0. SP6 checks the diagrams on the public page |
| ⚠️ | SP3 left open whether to commit its link checker. It stays out: nothing runs it on a schedule, and the monthly review does not call it |
| ⚠️ | The Milestones table stops at Q2 2026. That is correct today, because HISTORY still holds every entry from 2026-06-27. The first trim that deletes a July entry (the October review) must add a Q3 row, so C3 adds that step to the skill |

### Pins

| Reference today | Count | Pinned to |
|---|---|---|
| `actions/checkout@v7` | 11 | `3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`, as the 3 existing pins |
| `actions/setup-python@v7` | 1 | `5fda3b95a4ea91299a34e894583c3862153e4b97 # v7.0.0` |
| `actions/github-script@v9` | 1 | `3a2844b7e9c422d3c10d287c895573f7108da1b3 # v9.0.0` |
| `anthropics/claude-code-action@v1` | 1 | `756cc22e19660d20e8cc9496b4f242475a7f7790 # v1.0.235` |

Each SHA is the commit the tag points at today, so pinning changes no code that runs.

### Commits

Every commit gets the Codex loop. Each review file stays at 30 KB or less. It inlines the writing
rules, the gate output and the re-derive command for each fact it changes.

| Commit | Content | Review file holds |
|---|---|---|
| C0 long lines | keep `--strict` (Q4) and fix the 86 lines outside `claude.yml`, 4 of them by an exemption in `.yamllint.yaml` (see the C0 table below). `vmrules.yaml`: the `CronJobNotScheduled` comment names the trivy schedule `0 8 1 * *`, as `trivy-scan/cronjob.yaml` sets it | the diff stat and a sample of each class; S58; S64; the gate output |
| C1 Actions | pin the 14 references (see Pins). `claude.yml`: `on.issues.types` drops `assigned`, because an owner who assigns someone else's issue would start Claude on that person's text. `if:` becomes `github.actor == 'AKhozya' && (…)` around the four `@claude` checks, one check per line, so no line passes 200 characters. The Renovate exclusions and their comment go, because the actor check already rules Renovate out. `renovate.json` `extends` gains `helpers:pinGitHubActionDigestsToSemver` | the diff; S47–S54; the resolve and pin-check output; actionlint against the baseline |
| C2 licence | `LICENSE`: MIT, `Copyright (c) 2025 AKhozya` (Q2). `THIRD_PARTY.md`: all six files from the licence table, with source and licence. It quotes the MIT notices in full. The two dashboards with no licence read "no licence found; kept", and the Loki row says the copy is modified. `LICENSES/Apache-2.0.txt` holds the full Apache-2.0 text, fetched from `https://www.apache.org/licenses/LICENSE-2.0.txt`, and `THIRD_PARTY.md` points to it. README gains a Licence section that points to `LICENSE` and `THIRD_PARTY.md` | the diff; S55 |
| C3 Milestones step | dotfiles: `homelab-monthly-review` Phase 5 item 2 gains one step. If the trim deletes an entry from a quarter the Milestones table does not cover, add a row for that quarter naming its main changes. Then `chezmoi-sync` and `scripts/sync-agents.sh --update`; the refreshed `agents/` file joins the commit | the skill diff; `sync-agents.sh --check` |
| C4 close-out | this plan: roadmap SP4 done, the Dependency Dashboard reading, the three settings as read back | the diff |

C0–C3 go on one branch from `origin/main` and merge together. C4 records steps that happen after
that merge, so it merges on its own.

C0 by class. Counts are `yamllint -s` findings on `origin/main`; `claude.yml`'s one line goes in C1.

| Class | Lines | Files | Fix |
|---|---|---|---|
| inside a block scalar (`\|`, `\|-`) | 50 | cnpg (28), traefik (10) and Loki (5) dashboards; blocky dashboard (1); `alloy-release.yaml` (1); `apps/claude-telegram/deployment.yaml` (5) | `# yamllint disable rule:line-length` above the key that opens the block, with a comment line naming why. `# yamllint enable rule:line-length` after the block, unless it runs to the end of the file. A comment inside a block would be content, so each directive sits outside it |
| authentik blueprint `description` | 4 | `apps/authentik/blueprints/` 10, 20, 30 and 40 | `.yamllint.yaml` gives `line-length` an `ignore` entry for `apps/authentik/blueprints/`, with a comment naming why. Any byte change to one of these files applies the blueprint again (S66) |
| double-quoted value | 27 | 4 CSP headers in `infrastructure/controllers/traefik/csp-middleware.yaml` and 1 in `monitoring/configs/kube-prometheus-stack/csp-middleware.yaml`; `phase1.yml`'s `tg_message`; 21 `description:` in `vmrules.yaml` | break at a single space, near 120 characters; continuation lines indent 2 past the key. A line break inside double quotes reads as one space, so the string stays the same. The script never breaks next to another space or after a backslash |
| plain `expr:` | 4 | `vmrules.yaml` | `expr: >-` with the query on the lines below. `>-` also reads each line break as one space and drops the last newline; `\|` would keep the newlines and change the rule |
| comment | 1 | `infrastructure/controllers/traefik/csp-middleware.yaml` | wrap by hand |

### Gates

| Commit | Gate | Pass |
|---|---|---|
| all | `gitleaks dir . --config .gitleaks.toml`; `pre-commit run --files <changed>`; `yamllint .`; no private term in a changed file (`grep -I -l -i -F -f ~/.config/sync-agents/private-terms.txt`, as in SP3) | exit 0; the private-term search exits 1, and the terms file has 9 lines |
| C0 | `yamllint -s -f parsable .` | one finding, `.github/workflows/claude.yml:21` (C1 fixes it) |
| C0 | `uv run --with pyyaml python3 ~/.local/share/homelab-sp4/parse-eq.py <origin/main copy> <each changed manifest>` | every file `same`, exit 0. It compares each value with its type, since Python's `==` treats `true`, `1` and `1.0` as equal |
| C0 | `kustomize build --enable-helm` of the 7 CI roots on the branch and on an `origin/main` copy, then `cmp` | all 7 identical |
| C1 | `yamllint -s .` | exit 0 |
| C1 | `actionlint -oneline`, line numbers stripped, sorted | equals the 7-line baseline in `~/.local/share/homelab-sp4/` |
| C1 | `~/.local/share/homelab-sp4/pin-check.sh .github/workflows`: every `uses:` must name a 40-character SHA and a `# vX.Y.Z` comment, or a `./` path | exit 0. It exits 1 on an unpinned reference, 2 on a missing folder, 3 if it finds no `uses:`, 4 if grep reports an error. Controls, run 2026-09-28: `origin/main` gives `refs=22 unpinned=14` and 1; a missing folder 2; an empty folder 3; a pinned sample 0; a short SHA and a SHA with no comment 1; a pinned file next to an unreadable file 4 |
| C1 | `resolve-tags.sh` in `~/.local/share/homelab-sp4/` resolves each tag again | each SHA in the diff equals the tag's commit |
| C1 | `renovate-config-validator --strict renovate.json` | exit 0 (schema only, S52) |
| C1 | `yq '.on.issues.types' .github/workflows/claude.yml` | `[opened]` |
| C2 | each path in `THIRD_PARTY.md` exists in `git ls-files`, and each remaining S55 file appears in it | both hold |
| C3 | `scripts/sync-agents.sh --check` | exit 0 |

### Rollout

1. C0–C3: gates, Codex loop per commit, then one merge from the main tree. The merge starts a
   drift-heal; expect `changed=0 failed=0` on all four nodes, since no role file changes. Flux
   applies `vmrules.yaml` and the other changed manifests, whose objects do not change (S64).
2. After the merge, read the Dependency Dashboard (issue #32). Its `updatedAt` must be later than
   the merge, and its `github-actions` list must show every reference as `vX.Y.Z@<sha>` (S62).
   That shows Renovate ran on the new commit and read the pins. It does not show that the preset
   loaded, because C1 writes the pins by hand. If Renovate opens "Action Required: Fix Renovate
   Configuration" instead, read the error it names before changing anything.
3. Settings (Q3), after step 2: `sha_pinning_required: true`, default token `read`, no PR
   approval by workflows. Read each back with `gh api`.
4. C4, then merge.

### Outcome (2026-09-28)

| Step | Result |
|---|---|
| 1 | Main moved from `54e755a3` to `254a8f63` at 16:51 UTC. All 7 Flux Kustomizations were Ready at `254a8f63` about 75 s after a source reconcile. The node sync applied `254a8f63` at 17:00 UTC, and its drift-heal read `changed=0 failed=0` on all four nodes |
| 2 | Issue #32 `updatedAt` 17:04:54 UTC. Its `github-actions` list shows all 22 references as `vX.Y.Z@<sha>`. The 4 actions C1 pinned show the SHAs and versions in Pins. `gh issue list --state all` finds no "Action Required" issue, open or closed |
| 3 | Before (as S53): `sha_pinning_required` false, `default_workflow_permissions` write, `can_approve_pull_request_reviews` true. Read back after the change: `{"enabled":true,"allowed_actions":"all","sha_pinning_required":true}` and `{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}` |
| Carried to SP6 | fork-PR approval (S54) and private vulnerability reporting with its `docs/SECURITY.md` line (S65), since both need a public repo; a check that the mermaid diagrams render on GitHub. CI has not run on these commits (billing), so the next CI run is the first with `sha_pinning_required` on |

### Rollback

`git revert` the commit. If C1's revert would put tags back while `sha_pinning_required` is on,
turn the setting off first and read it back, or every workflow with a tag fails at setup. The
other settings revert with the same `gh api` calls and the old values from S53.

### Operator answers (2026-09-28)

| # | Question | Answer |
|---|---|---|
| Q1 | Old credentials in PR refs | The operator rotated both live tokens on 2026-09-28 (`52ce08aa`), and the claude-telegram bot token with them. The procedure is `docs/SECRETS_ROTATION.md` §6 and `scripts/rotate-token.sh` (`54e755a3`). The rotation record stands for the 🟡 rows. Decision 7 holds, since no credential in PR refs still works |
| Q2 | Copyright line | `Copyright (c) 2025 AKhozya` |
| Q3 | Repo settings | Yes to all: SHA-pinned actions required, default workflow token `read`, workflows may not approve PRs, after the C0–C3 merge. Private vulnerability reporting too, with one line in `docs/SECURITY.md`; GitHub offers it only on a public repo (S65), so both move to SP6 |
| Q4 | yamllint | Keep `--strict` and fix the lines (C0) |
| Q5 | Dashboards with no licence | Keep both, and list them in `THIRD_PARTY.md` with author and source |

## SP5 — whole-repo review

The plan was for the operator to run `/code-review ultra` on `main`. The agent then fixes every
finding before SP6 starts, not only those that block publishing (A2). The review ran on
2026-09-28 at `8f78a8c8`, a descendant of `bfae1f07`. It used local agents instead of the cloud
review, for the reasons below.

### Method change

| Cloud review limit | Effect on this repo |
|---|---|
| 500 files and 8,000 changed lines per review | the tree has 737 reviewable files, so one review cannot cover it |
| it reviews the directory the session started in, not a later `cd` | a run started from the main tree reviewed `main`, not the slice branch |
| it takes one argument; an all-digit short SHA reads as a PR number | nine slices would need nine separate operator runs |

The operator chose an orchestrated run instead:

| Layer | What it did |
|---|---|
| 9 review agents | each read every file in one slice of `8f78a8c8` and listed findings with file, line, severity and fix |
| 7 fix agents | one per area, each in its own worktree; the normal Codex loop on every commit |
| orchestrator merge review | a second Codex review of each whole branch before its merge, split into diffs of 30 KB or less |
| live checks | after each merge, read-only checks against the cluster and the nodes |

The merge review found HIGH or MEDIUM defects in every branch after the authors' own loops had
passed. The fix agents fixed those in the same branches before the merge.

### Scope

`8f78a8c8` tracks 803 files. The review read 737 of them and excluded 66:

| Excluded | Files | Why |
|---|---|---|
| SOPS-encrypted Secrets | 58 | the values are ciphertext; SP4 scanned the history for leaks |
| Grafana dashboard JSON | 7 | exported dashboards, not hand-written config; their `kustomization.yaml` was reviewed |
| `clusters/flux-system/gotk-components.yaml` | 1 | generated by `flux install` |

| Slice | Rule (path regex, first match wins) | Files | HIGH | MEDIUM | LOW | NIT |
|---|---|---|---|---|---|---|
| s1 | `^node-maintenance/ansible/` | 119 | 0 | 7 | 14 | 9 |
| s2 | the rest of `node-maintenance/`, `scripts/`, `.github/`, `.backup/`, `.claude/`, `LICENSES/`, root files | 65 | 3 | 10 | 15 | 6 |
| s3 | `^infrastructure/(configs\|coredns)/` | 109 | 0 | 2 | 11 | 8 |
| s4 | `infrastructure/controllers/`, `monitoring/`, `clusters/` | 114 | 2 | 6 | 5 | 5 |
| s5 | eight apps: immich, claude-telegram, home-assistant, authentik, homepage, linkwarden, mealie, n8n | 101 | 2 | 2 | 7 | 6 |
| s6 | the other `apps/`, and `docs/` | 106 | 5 | 5 | 14 | 3 |
| s7 | `docs/HOMELAB_HISTORY.md` | 1 | 0 | 0 | 3 | 2 |
| s8 | `agents/`: README, rules, sync, `_shared` and six large skills | 64 | 0 | 5 | 12 | 4 |
| s9 | the rest of `agents/` | 58 | 0 | 6 | 26 | 4 |
| **Total** | | 737 | 12 | 43 | 107 | 47 |

No slice found a CRITICAL. The 209 findings are the review's count. The agents' own counts add up
to 214, because some findings touched more than one area and each area counted them.

### Operator decisions (2026-09-28)

| # | Question | Decision |
|---|---|---|
| D1 | the CP `kubectl proxy` and the bot's `pods/exec` in `monitoring` | drift-heal removes the proxy (`17f60674`). The bot keeps `pods/exec` in `monitoring` for now: the API server's service proxy returns 502 there, because the CP cannot reach pod IPs |
| D2 | personal data in plaintext | the Telegram chat ID, the bot's allowed-user ID and the Home Assistant admin name move into SOPS (`09c2abb6`, `ab161f5c`, `fa066ca3`). The Flux Telegram Provider keeps its copy of the chat ID in plaintext, because notification-controller v1.9.4 reads `channel` only from `spec.channel` |
| D3 | global IPv6 addresses in the CoreDNS `NodeHosts` | drop them and keep the ULA entry (`55478c1a`). No history purge, since GitHub keeps `refs/pull/*` |
| D4 | the Claude permission allowlist | deny force deletes and Secret reads (`dfebaebd`, `082832b0`). `kubectl apply --dry-run=server *` stays allowed. |
| D5 | the bot's node SSH on immich-vm | add the read-only `agent-diag` key there (`445aefa3`, `2a10e5f7`) |
| — | the UFW healer fix reached review round 6 with a MEDIUM open | keep going, and spike if needed. The spike showed that a UFW `flush-all` removes only portmap's three nat entry rules, so the healer restores them directly, with no k3s restart (`00e92313`, `891751ea`) |

### Disputes

| Finding | Dispute | Outcome |
|---|---|---|
| s4 MEDIUM: Alertmanager 9093 allow-list | the suggested list dropped `traefik`, which the `am.h0melab.work` ingress needs, and added `homepage`, which never calls Alertmanager | fixed with `monitoring`, `loki`, `uptime-kuma` and `traefik` (`228e19f7`) |
| s1 MEDIUM: add immich-vm to the phase1 preflight | a NAS outage must not block updates to the other three nodes | fixed differently: phase2 alerts on an unreachable immich-vm and skips it (`7b9d596d`) |
| s8 LOW: a restart method for each database engine | CNPG, Redis and CouchDB have sourced methods. No source records a Percona restart through its CR | the runbook tells the agent to ask the operator for Percona. Open |
| merge review MEDIUM: a native sidecar in a skill | no init container with `restartPolicy: Always` exists in the repo or live | not changed |
| merge review MEDIUM: repeated `kubectl wait --for` | the kubectl v1.37 help says repeated conditions must all hold | not changed |

### Outcome (2026-09-28)

| Area | Findings owned | Fixed | Not fixed | Commits on `main` |
|---|---|---|---|---|
| node-maintenance | 41 (s1, s2) | 38 | 2 deferred, 1 operator | `2a09e2b0` `901f5722` `9e674eb7` `17f60674` `badf6379` `7b9d596d` `00e92313` `891751ea` `1bc2817c` `a262c2a2` `445aefa3` `9732090d` |
| tooling | 25 (s2, s1) | 23 | 2 operator | `86d71b8e` `0482cb7f` `d8d83e8a` `082832b0` `c31e5670` `dfebaebd` `154e00b8` `f9ba59b5` `c6e7e38e` `396d360b` `f1cc780d` |
| infrastructure | 20 (s3) | 20 | — | `54b4069a` `dca36ccf` `527375a2` `ebf72957` `0f65dbfa` `55478c1a` |
| monitoring | 18 (s4) | 17 | 1 operator | `a0b68286` `228e19f7` `1068a7ec` `ac1a21b3` `88fe2598` `ab161f5c` `10e08eb3` `71535f59` `a39dd523` `de137101` |
| apps | 24 (s5, s6, s3) | 21 | 1 deferred, 2 operator | `09c2abb6` `aba0768e` `fa066ca3` `9f4ca99f` `2a10e5f7` `42be4cc6` `5f7058a7` |
| docs | 29 (s6, s7, s2, s3, s4) | 28 | 1 deferred | `5bbdeab4` `5581b1c4` `75ce6fc2` `3dd77ea6` `b7571489` `4ccb3986` `165b434c` `b5a52a82` `35780231` `b7f78145` `85e4fd86` `58b45988` `7141b89e` `1d3ff3d0` |
| agent skills | 57 (s8, s9) | 56 | 1 disputed in part | `ea8b0e53` `06c4ac8d` `e7433112` `fbf8e18d` `36db2847` `beb9c4eb` `6aab6dc2`; dotfiles `86fe49c..c1a9e8f` |

Of the 209 findings, 198 are fixed, 4 are deferred, 6 wait on the operator and 1 is disputed in
part. The merge reviews added findings of their own. All of those are fixed, except the two
merge-review disputes above and one pattern limit that D4 accepts.

| Live check after the merges | Result |
|---|---|
| Flux | all 7 Kustomizations and all HelmReleases Ready after each push |
| Traefik Middlewares | all 9 now owned by `infrastructure-configs`, with unchanged creation times; the routes answer 200 or 302 |
| Kyverno filters | a probe pod in `default` labelled `managed-by=vm-operator` is denied |
| cloudflared | 4 registered connections after the egress change |
| CP proxy | 0 listeners on port 8001; the unit file is gone |
| node-maintenance Telegram | the sync refreshed the CP token file at 23:11:02 BST; the last recorded attempt, at 23:17:09 BST, succeeded |
| bot SSH | `agent-diag` and the bot key are present on worker-node, worker-node-2 and immich-vm |
| skill helpers | the cluster-roll dry run maps all 66 workloads; `mysql-exec.sh`, `redis-master.sh` and the `pg-primary.sh` stdin mode return the expected rows; `scripts/sync-agents.sh --check` exits 0 |

### Carried forward

SP5 is done with the items below open. Before SP6 starts, the operator decides whether any of
them blocks the visibility flip.

| Item | Kind | Next step |
|---|---|---|
| s6 HIGH: first start of a rebuilt control plane (`docs/setup/K3S_SETUP.md`) | deferred, partly fixed | needs a design and a drill: `install.sh` needs a running K3s, but the taint and label apply only at first registration. The page marks the order "Not drilled" |
| s5 LOW: n8n `Recreate` | deferred | switch once a server-side dry run with `--field-manager=kustomize-controller` passes. Step 1 (`42be4cc6`) is live |
| s1 NIT: duplicate lines in `sysctl-99-unified-hardening.conf` | deferred | an edit fires the sysctl handler on all four nodes, so fix it after the immich-vm check below |
| s1 NIT: rename the sshd drop-in from `99-` to `00-` | deferred | a rename on all four nodes risks an SSH lockout, and the order changes nothing today |
| s8 LOW: Percona restart procedure | disputed in part | operator: confirm a restart procedure through the CR and document it. Until then, cluster-roll keeps Percona in SKIP |
| D1: why the CP cannot reach pod IPs | follow-up | if the service proxy works, the bot can drop `pods/exec` in `monitoring` |
| sysctl handler on immich-vm (s1 LOW) | operator | run `sudo sysctl --system >/dev/null` on immich-vm and read stderr |
| immich-vm domain XML (`aba0768e`) | operator | apply it on the NAS with `virsh define`, then a graceful cold restart |
| bot SSH host keys (s5 LOW) | operator | pin `[192.168.1.231]:65300` and `[192.168.1.126]:65300` in the bot's SOPS known_hosts |
| paperless (s6 MEDIUM) | operator | check one paperless SOPS setting |
| `THIRD_PARTY.md` dashboards (s2 LOW) | operator | get a licence for the two dashboards, or replace them |
| Alertmanager `chat_id_file` | operator | send one test alert and check that it arrives |
| `FLUX_UPDATE_TOKEN` | operator, optional | add the repo secret only if CI should run on Flux update PRs |
| scheduled runs | check | backup-replication 2026-09-29 03:30 UTC (17 "OK: tar integrity", all 17 validated); immich-backup 2026-10-04; phase1 and phase2 2026-10-03 |

### Rollback

`git revert` the commit, with one exception. The Traefik Middlewares moved between two Flux
Kustomizations, and `infrastructure-configs` prunes. So a move back needs the same two pushes as
the move out (`71535f59`, then `a39dd523`):

1. Add `kustomize.toolkit.fluxcd.io/prune: disabled` to the Middlewares in
   `infrastructure/configs/traefik-middlewares/kustomization.yaml`, push, and check that all 9
   live objects carry it.
2. Revert `a39dd523`, and push.

A node-maintenance revert reaches the nodes at the next sync and drift-heal, within about 10 minutes.

## SP6 — visibility flip

### Spike results

Run 2026-09-28.

| # | Question | Probe | Result |
|---|---|---|---|
| S67 | Why does no Actions job start? | `gh api repos/AKhozya/homelab/check-runs/<job>/annotations` on run `36456312206` (Secret scan on `08a48ce6`) | ✅ "The job was not started because recent account payments have failed or your spending limit needs to be increased" |
| S68 | Does a public repo clear it? | GitHub docs, "GitHub Actions billing" and "Choosing the runner for a job"; the Tahoe-LAFS tracker, ticket 4182 | 🟡 The docs say standard GitHub-hosted runners are "free and unlimited" on public repos. They say nothing about this lock. Tahoe-LAFS, a Free-plan org with public repos, got the same message in 2025. Its jobs started again only after someone paid an outstanding $0.01 charge |
| S69 | Can `main` take rules now? | `gh api repos/AKhozya/homelab/rulesets`; `.../branches/main/protection` | ✅ both 403: "Upgrade to GitHub Pro or make this repository public to enable this feature" |
| S70 | Which check names would a ruleset require? | job `name:` fields in `.github/workflows/`; GitHub docs, "Troubleshooting required status checks" | ✅ Secret scan reports one name, `gitleaks secret scan`, and has no `paths-ignore`. Validate reports 14 names: 7 jobs, plus kubeconform once for each of 7 roots, and skips PRs that touch only `**.md` or `docs/images/**`. GitHub leaves a required check from a skipped workflow at "Pending", so such a PR could merge only through a bypass |
| S71 | Who can approve a PR? | `gh api repos/AKhozya/homelab/collaborators`; GitHub docs, "Approving a pull request with required reviews" and "About protected branches" | ✅ `AKhozya`, admin, is the only collaborator. An approval counts toward a required review only if it comes from an account with write access, and GitHub never lets a PR's author approve that PR |
| S72 | How do Renovate PRs merge today? | `gh pr list --state merged` | ✅ `AKhozya` merged each of #1199–#1206 by hand. `renovate.json` also turns on automerge for patch updates |
| S73 | Values for the fork-PR setting | REST docs, "Set fork PR contributor approval permissions for a repository" | ✅ `approval_policy` takes `first_time_contributors_new_to_github`, `first_time_contributors` or `all_external_contributors` |

### Steps

Steps 2, 3 and 5 need a public repo, because each endpoint refuses a private one (S54, S65, S69).

| Step | Who | Detail |
|---|---|---|
| 1. Flip | operator | On a date the operator picks, after SP5 closes (A5). Settings → Danger zone, or `gh repo edit AKhozya/homelab --visibility public --accept-visibility-change-consequences` |
| 2. Fork PRs | agent | Right after the flip, so no outside PR runs a workflow unseen while later steps wait on billing: `gh api -X PUT repos/AKhozya/homelab/actions/permissions/fork-pr-contributor-approval -f approval_policy=all_external_contributors`, then read it back (A6) |
| 3. Vulnerability reports | agent | `gh api -X PUT repos/AKhozya/homelab/private-vulnerability-reporting`, then read it back. Add one line to `docs/SECURITY.md` that tells a reader to report a problem through the repo's Security tab (Q3) |
| 4. Actions | agent, then operator if needed | Run `gh workflow run gitleaks.yaml` and `gh workflow run validate.yaml`, and watch each run to the end with `gh run watch` (A3). If a job fails with the S67 message, the operator clears the failed payment in Settings → Billing and plans, and the agent runs both again. Record each run's ID and result here. These are the first runs since SP4 turned `sha_pinning_required` on (SP4 Outcome, step 3). So if a job fails at setup, check the pins before the code |
| 5. Ruleset | agent | If step 4 shows a successful `gitleaks secret scan`, create the ruleset. If the scan cannot complete successfully, requiring it would let a PR merge only through a bypass, so stop and tell the operator instead. The ruleset targets `main` with enforcement `active`. It requires a PR with 1 approval and a successful `gitleaks secret scan`. It lists the repo admin role as a bypass actor with bypass mode `always`; mode `pull_request` would refuse the owner's direct pushes (A4, A8). Find the ruleset's ID with `gh api repos/AKhozya/homelab/rulesets`, then read `gh api repos/AKhozya/homelab/rulesets/<id>` and check the target, enforcement, rules and bypass mode. The list call omits rules and bypass actors |
| 6. Renovate | agent | Remove patch automerge from `renovate.json`, because the operator approves and merges each Renovate PR by hand (A7) |
| 7. `AGENTS.md` | agent | If step 5 creates the ruleset and its read-back matches the planned settings, rewrite the invariant "CI validation — a signal, NOT a merge gate" as follows. A PR to `main` needs 1 approval and a successful `gitleaks secret scan`. Only the owner has write access, so only the owner's approval counts (S71). The owner is a bypass actor, so the owner can push to `main` directly and can merge a PR without the approval or the check. So a direct push reaches prod whatever CI says. The pre-commit review loop still covers those pushes, and its docs-only exemption stays. The ruleset does not require the Validate checks to pass |
| 8. Diagrams | agent | Open README and `docs/ARCHITECTURE.md` on GitHub and confirm all 5 mermaid blocks render. S59 rendered them with mermaid 12.0.0; GitHub uses its own version |

### Operator answers (2026-09-28)

| # | Question | Answer |
|---|---|---|
| A1 | When the ultrareview runs | Now, on `main` |
| A2 | Which SP5 findings to fix before the flip | All of them |
| A3 | Actions billing | Flip first, then check whether jobs start. Fix billing only if they do not |
| A4 | Rules on `main` | A PR and the owner's approval for everyone else. The owner bypasses, so the agent's merge-and-push flow stays |
| A5 | Who flips, and when | The operator, on a date the operator picks |
| A6 | Fork PRs that wait for approval | All outside contributors |
| A7 | Renovate PRs | The operator approves each one, then merges it |
| A8 | Required checks | `gitleaks secret scan` only |
