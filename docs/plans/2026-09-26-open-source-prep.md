# Open-source prep — plan (2026-09-26)

Goal: make `AKhozya/homelab` fit to publish. Six sub-projects run in order. Each one gets
its own spikes and operator approval before work starts. This file plans SP1 and SP2 in full.
For SP3–SP6 it records the decisions already made and the spikes still to run.

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

## Roadmap

| SP | Scope | Depends on |
|---|---|---|
| SP1 | Move node-maintenance tree + loose scripts out of `docs/`. **Done** 2026-09-26: `7a307ab4`, `8a146a09` | — |
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
| S22 | Which `rsync` flags give a correct copy and a correct drift check? | scratch trees; `/usr/bin/rsync` is openrsync (protocol 29) | ✅ `-r -c -n -i --delete --no-links` prints a line for a changed byte at the same mtime and for an extra file, and prints nothing for a new mtime or a 644 → 664 mode change; git records neither. It misses a lost exec bit, so the check compares exec bits separately. `-E` means extended attributes in openrsync and copies `._` AppleDouble files, so the script does not use it. `--no-links` skips a symlink with a message and exit 0, so the script finds symlinks itself |
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
| Actions | CI has not run since 2026-09-10 (see SP2 assumptions). Before the flip, find out what GitHub requires for Actions to run on a public repo owned by this account. After the flip, confirm CI runs |
| Branch protection | The `AGENTS.md` invariant "CI validation — a signal, NOT a merge gate" says branch protection is unavailable on a private repo on the Free plan. GitHub docs list protected branches as available for public repos on the Free plan, so decide: enable required checks, or decline. Then edit the "CI is a signal, NOT a merge gate" invariant to match |
