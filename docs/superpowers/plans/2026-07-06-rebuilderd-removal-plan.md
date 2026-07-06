# Rebuilderd Full Removal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Remove rebuilderd (reproducible-build farm) entirely from the homelab — packages, systemd units, data/cache, ansible role, monitoring, docs — because its builds repeatedly saturate worker-node-2 (load ~11, swap thrash, OOM-kill MySQL pods) and disrupt latency-sensitive cluster workloads.

**Architecture:** rebuilderd is **host-level only** (systemd via ansible on both workers; CP is clean — never ran it). No k8s workload provisions it. Removal has two moving parts: (1) **repo changes** via GitOps (worktree → main → push), and (2) a **one-time active teardown** on the two worker nodes (declaratively deleting `- role: rebuilderd` only *stops managing* it — the running install stays until actively removed). The teardown runs as root through the existing `node-maintenance-config.service` (NOPASSWD sudoers), triggered by `sync-from-git.sh` on the next merge.

**Tech Stack:** ansible-core (node-config.yml drift-heal), systemd, pacman, Flux GitOps (repo side), VictoriaMetrics VMRule (monitoring side).

**Review status:** Codex static peer-review = **SHIP-WITH-FIXES** (2026-07-06). All 5 findings verified against the repo + applied: deferred-silence block deletion made explicit (#1, verified rebuilderd-only), legacy orphan units added to teardown (#2), per-target rm assert strengthened (#3), verify command widened (#4), both makepkg comments retagged (#5). Codex independently confirmed C1 (no glob/symlink-follow risk) + C5 (makepkg override safe to keep).

## Global Constraints (verbatim, homelab invariants)

- **GitOps only.** No `kubectl edit/patch/replace`. Repo changes flow worktree → main → `fr`. (Teardown is host-side ansible, not k8s — exempt, but still driven from committed repo.)
- **Edit in a worktree.** Main tree is edit-blocked by worktree-guard hook.
- **Pin all images / `readOnlyRootFilesystem` / Kyverno / NetworkPolicy** — N/A here (no k8s manifests change).
- **CI gate-of-record** — `.github/workflows/validate.yaml` (yamllint + shellcheck + kubeconform). Ansible YAML is under `docs/scripts/` — confirm whether validate lints it; run `ansible-lint` + `yamllint` locally regardless.
- **Pre-commit Codex static review** on the substantive diff, `.claude/review-invariants.md` rubric, one-message verdict, ≤3 delta rounds.
- **Docs anti-fluff** — every line load-bearing; KEEP the why/dates/SHAs.

---

## ⚠️ CUT CORNERS & RISKS (read first — these are the deliberate trade-offs)

| # | Corner / Risk | Decision | Why / mitigation |
|---|---|---|---|
| **C1** | **Destructive teardown (`pacman -Rns` + `rm` of a 9.1 G dir) on a disk that also holds `/mnt/extra-storage/backups` (128 G NAS sink).** | Teardown **hardcodes exact paths** + an `assert` that each rm target matches `^/mnt/(extra-storage|k8s-storage)/(repro|rebuilderd-worker)$`. **No globs, ever.** | A wrong var or `rm /mnt/extra-storage/*` would nuke the offsite backup. The assert is the guardrail. |
| **C2** | **Attended vs unattended apply.** The teardown can auto-run unattended via the 10-min sync→config timer, OR be run once attended. | **RECOMMEND attended one-shot** (`ansible-apply.sh` on CP — one `sudo systemctl start`). Needs 1Password unlocked. | User asked "without my involvement," but a one-time destructive `pacman -Rns`+`rm -rf` is safer with a human watching the output once. If you truly want unattended: merge and the timer applies it within ≤10 min. **Pick one — flagged for review.** |
| **C3** | **`pacman -Rns` `-s` recursion** could in theory remove a shared dep. | Spike proved deps are isolated (`rebuilderd`→`rebuilderd-tools`+`archlinux-repro`, all `Required By: None`/rebuilderd-only; `git/curl/gnupg/zstd` are kept — required elsewhere). Only orphan is `diffoscope`. | Accept `diffoscope` removal. **No aggressive `pacman -Qtdq` orphan sweep** (could catch unrelated orphans). |
| **C4** | **Two-PR teardown** (add throwaway `rebuilderd_teardown` role → apply → delete it) vs a permanent "ensure-absent" guard. | **2-PR throwaway** → pristine end-state. Between PRs the idempotent teardown runs daily as a no-op. | Ponytail: delete over keep. A permanent guard is dead weight running forever. Alternative (permanent guard against re-creep) noted for review. |
| **C5** | **base_config makepkg override (tasks 258-289)** exists *solely* to shield phase2 yay AUR builds from rebuilderd's `storage.conf`. Once `storage.conf` is gone the override is redundant. | **KEEP it, only update the comment.** Do NOT delete. | Deleting touches the fragile phase2 AUR-build path (`gotcha_node_maintenance_aur_build`) and can't be verified until the next phase2 (Sat 2026-07-11). Harmless redundancy < unverifiable risk. **Flagged for review.** |
| **C6** | **"cleanup ... history"** is ambiguous. | Interpret as: purge on-node rebuilderd **state/DB/cache**; **APPEND** a HOMELAB_HISTORY removal entry; **do NOT rewrite** past dated history/archive entries (append-only record of what happened). | Rewriting the changelog erases the audit trail. State this assumption; correct me if you meant git-history rewrite. |
| **C7** | **`rebuilderd` system user (uid 212)** survives pkg removal. | **Leave it** (nologin, harmless). Optional `userdel` noted. | YAGNI. |
| **C8** | **VMRule node-alert exclusions** (CPU-throttling threshold @ vmrules:134, node CPU/mem/page-fault exclusions @ :1176-1216) were loosened *for* rebuilderd load. | Revert them to pre-rebuilderd sensitivity. | Correct — the load that needed loosening is gone. But **review each**: don't re-tighten a threshold that another workload also relies on. |
| **C9** | **`rebuilderd-progress` skill** lives in `~/.claude/skills/` (separate **chezmoi** repo, NOT homelab). | Remove it + the `CLAUDE.md:51` line, but the skill deletion is a **separate chezmoi-sync commit**, out of this repo's scope. | Cross-repo. Handled in Task 9 via `/chezmoi-sync`. |
| **C10** | **Cannot verify phase2 reboot path** (PLAY 0.5 removal) until next weekly maintenance (Sat 2026-07-11). | Remove phase2 pause + phase1/all.yml silence in the SAME PR as the role, so no run ever references a missing unit. Accept deferred verification. | If pause tasks lingered after the unit is gone, next phase2 would error on `systemctl stop rebuilderd-worker@1` (missing unit). Removing together is the safe order. |

---

## File Structure (what changes)

**Ansible (`docs/scripts/node-maintenance/ansible/`)**
- **Create (PR-1, delete in PR-2):** `roles/rebuilderd_teardown/{tasks/main.yml,handlers/main.yml}` — idempotent active removal, hardcoded paths + safety assert.
- **Delete (PR-1):** `roles/rebuilderd/` (entire dir — install role, superseded).
- **Modify:** `node-config.yml` (swap role in workers play), `group_vars/workers.yml` (drop pkgs), `group_vars/all.yml` (drop silence), `host_vars/worker-node.yml` + `host_vars/worker-node-2.yml` (drop rebuilderd blocks), `roles/packages/tasks/main.yml` (drop worker-pkg task), `roles/base_config/tasks/main.yml` (drop worker-override tasks 417-436; retag makepkg comment 258-289), `phase1.yml`, `phase2.yml`, `.ansible-lint`.

**Monitoring**
- **Modify:** `monitoring/configs/victoria-metrics/vmrules.yaml` (drop `rebuilderd-alerts` group; revert node-alert exclusions).

**k8s comments**
- **Modify:** `infrastructure/configs/databases/mysql/cluster.yaml:204`, `.../mysql/exporter.yaml:53` (rebuilderd-load comment lines — update, keep the raised limits: MySQL still benefits).

**Scripts**
- **Modify:** `docs/scripts/ansible-apply.sh` (drop rebuilderd verify block), `docs/scripts/setup-node.sh`, `docs/scripts/node-maintenance/install-worker.sh`, `docs/scripts/node-maintenance/lib/node-config-notify.sh` (comment).
- **Delete:** `docs/scripts/node-maintenance/systemd/rebuilderd-worker-override.conf`.

**Docs**
- **Modify:** `docs/ARCHITECTURE.md`, `docs/HOMELAB_ANALYSIS.md`, `README.md`, `docs/CODEMAPS/monitoring.md`, `docs/scripts/node-maintenance/README.md`, `docs/scripts/node-maintenance/ANSIBLE_REVIEW_PLAN.md`, `CLAUDE.md` (drop skill line).
- **Append:** `docs/HOMELAB_HISTORY.md` (removal entry + why).
- **Leave untouched:** `docs/archive/**` (historical record).

**Out-of-repo (chezmoi):** `~/.claude/skills/rebuilderd-progress/` — Task 9.

---

## Tasks

> Ansible removal has no unit tests; each task's "test" is a **verification command** (yamllint / ansible-lint / kubeconform / SSH probe). Frequent commits within the PR-1 worktree.

### Task 0: Worktree + baseline checkpoint

**Files:** none (setup)

- [ ] **Step 1:** Create worktree.
```bash
cd /Users/akhozya/source-code/homelab
git worktree add .claude/worktrees/rm-rebuilderd -b wt-rm-rebuilderd && cd .claude/worktrees/rm-rebuilderd
```
- [ ] **Step 2:** Snapshot current node state for rollback reference (already captured in this session; re-confirm).
```bash
for h in "z3us@worker-node-2" "akhozya@worker-node"; do ssh -p 65300 "$h" 'pacman -Qs rebuilderd; systemctl is-active rebuilderd rebuilderd-worker@1'; done
```
Expected: pkgs present, services active (pre-removal baseline).

---

### Task 1: `rebuilderd_teardown` role (the active removal)

**Files:**
- Create: `docs/scripts/node-maintenance/ansible/roles/rebuilderd_teardown/tasks/main.yml`
- Create: `docs/scripts/node-maintenance/ansible/roles/rebuilderd_teardown/handlers/main.yml`

**Interfaces:**
- Consumes: nothing (hardcoded paths — deliberately independent of host_vars, which are deleted in Task 3).
- Produces: a clean node (no rebuilderd pkg/units/data). Invoked by Task 2's workers play.

- [ ] **Step 1: Write `handlers/main.yml`**
```yaml
---
- name: Reload systemd
  ansible.builtin.systemd_service:
    daemon_reload: true
```

- [ ] **Step 2: Write `tasks/main.yml`** (idempotent; safe on already-clean nodes)
```yaml
---
# Active removal of rebuilderd (reproducible-build farm). Idempotent.
# Paths HARDCODED (not host_vars) so this role is self-contained and the
# host_vars rebuilderd blocks can be deleted in the same PR. See C1: the
# assert below is the guardrail against ever rm-ing a non-rebuilderd path
# (esp. /mnt/extra-storage/backups, the 128G NAS sink on W2's disk).

- name: Stop + disable rebuilderd units (ignore absent)
  ansible.builtin.systemd_service:
    name: "{{ item }}"
    state: stopped
    enabled: false
  loop:
    - "rebuilderd-worker@1.service"
    - rebuilderd.service
    - rebuilderd-metrics.timer
    - rebuilderd-watchdog.timer
    - rebuilderd-worker-boot.timer
    - repro-cleanup.timer
    - "rebuilderd-sync@archlinux-core.timer"
    - "rebuilderd-sync@archlinux-extra.timer"
    - rebuilderd-metrics.service
    - rebuilderd-watchdog.service
    - repro-cleanup.service
    # legacy orphan units the install role also cleaned (already gone on live nodes; idempotent here)
    - rebuilderd-reenable-stop.timer
    - rebuilderd-reenable-stop.service
    - rebuilderd-worker-scheduled.service
  failed_when: false

- name: Remove rebuilderd packages (recursive — orphans archlinux-repro/rebuilderd-tools/diffoscope)
  community.general.pacman:
    name:
      - rebuilderd
      - rebuilderd-tools
      - archlinux-repro
    state: absent
    extra_args: --recursive

- name: Remove ansible-dropped unit files + drop-in dirs
  ansible.builtin.file:
    path: "{{ item }}"
    state: absent
  loop:
    - /etc/systemd/system/rebuilderd-metrics.service
    - /etc/systemd/system/rebuilderd-metrics.timer
    - /etc/systemd/system/rebuilderd-watchdog.service
    - /etc/systemd/system/rebuilderd-watchdog.timer
    - /etc/systemd/system/rebuilderd-worker-boot.timer
    - /etc/systemd/system/repro-cleanup.service
    - /etc/systemd/system/repro-cleanup.timer
    - /etc/systemd/system/rebuilderd-sync@.service.d
    - /etc/systemd/system/rebuilderd-worker.service.d
    - /etc/systemd/system/rebuilderd-worker@.service.d
    - '/etc/systemd/system/system-rebuilderd\x2dworker.slice.d'
    - /etc/systemd/system/rebuilderd-reenable-stop.service
    - /etc/systemd/system/rebuilderd-reenable-stop.timer
    - /etc/systemd/system/rebuilderd-worker-scheduled.service
  notify: Reload systemd

- name: Remove helper scripts + configs
  ansible.builtin.file:
    path: "{{ item }}"
    state: absent
  loop:
    - /usr/local/bin/rebuilderd-metrics.sh
    - /usr/local/bin/rebuilderd-watchdog.sh
    - /usr/local/bin/cleanup-stale-repro.sh
    - /etc/rebuilderd.conf
    - /etc/rebuilderd-sync.conf
    - /etc/rebuilderd-worker.conf
    - /etc/makepkg.conf.d/storage.conf
    - /var/lib/node_exporter/textfile/rebuilderd.prom

- name: Build rebuilderd data-path list (hardcoded per host — see C1)
  ansible.builtin.set_fact:
    _rebuilderd_data_paths: >-
      {{ [ _base ~ '/repro', _base ~ '/rebuilderd-worker',
           '/var/lib/repro', '/var/lib/rebuilderd-worker', '/var/lib/rebuilderd' ] }}
  vars:
    _base: "{{ '/mnt/extra-storage' if inventory_hostname == 'worker-node-2' else '/mnt/k8s-storage' }}"

# C1 guard STRENGTHENED (Codex #3): assert EVERY final rm target, not just the base.
- name: SAFETY ASSERT — every rm target is an exact rebuilderd path
  ansible.builtin.assert:
    that:
      - item is match('^/mnt/(extra-storage|k8s-storage)/(repro|rebuilderd-worker)$') or
        item is match('^/var/lib/(repro|rebuilderd-worker|rebuilderd)$')
    fail_msg: "Refusing to rm '{{ item }}' — not an exact rebuilderd data path (guards /mnt/extra-storage/backups)"
    quiet: true
  loop: "{{ _rebuilderd_data_paths }}"

- name: Remove rebuilderd data dirs + symlinks (exact paths only, asserted above)
  ansible.builtin.file:
    path: "{{ item }}"
    state: absent
  loop: "{{ _rebuilderd_data_paths }}"
```

- [ ] **Step 3: Lint**
```bash
cd docs/scripts/node-maintenance/ansible
ansible-lint roles/rebuilderd_teardown/ && yamllint roles/rebuilderd_teardown/
```
Expected: clean (0 errors).

- [ ] **Step 4: Commit**
```bash
git add roles/rebuilderd_teardown/
git commit -m "feat(node-maint): add rebuilderd_teardown role (active removal)"
```

---

### Task 2: Wire teardown into workers play; delete install role

**Files:**
- Modify: `docs/scripts/node-maintenance/ansible/node-config.yml:60-61`
- Delete: `docs/scripts/node-maintenance/ansible/roles/rebuilderd/` (whole dir)

- [ ] **Step 1:** In the workers-only play, replace `- role: rebuilderd` with `- role: rebuilderd_teardown`; drop the stale defense comment lines 53-55 that name rebuilderd.
- [ ] **Step 2:** Delete the install role.
```bash
git rm -r roles/rebuilderd/
```
- [ ] **Step 3: Verify playbook still parses**
```bash
ansible-playbook --syntax-check node-config.yml -i inventory.yml
```
Expected: `playbook: node-config.yml` (no undefined-role error).
- [ ] **Step 4: Commit**
```bash
git add node-config.yml roles/rebuilderd/
git commit -m "refactor(node-maint): swap rebuilderd install role for teardown"
```

---

### Task 3: Strip rebuilderd from packages, host_vars, base_config, .ansible-lint

**Files:**
- Modify: `group_vars/workers.yml` (drop `rebuilderd`, `archlinux-repro` from `pacman_packages_worker`)
- Modify: `roles/packages/tasks/main.yml:100` (drop the "Install worker-only packages (rebuilderd stack)" task if the list is now empty; else keep the task, empty list)
- Modify: `host_vars/worker-node.yml` (drop rebuilderd block ~34-49)
- Modify: `host_vars/worker-node-2.yml` (drop rebuilderd block 29-44)
- Modify: `roles/base_config/tasks/main.yml` (delete worker-override tasks 417-436; **retag** makepkg comment 258-262 per C5 — keep the tasks)
- Modify: `.ansible-lint:11` (drop `rebuilderd_*` var-prefix exception)

- [ ] **Step 1:** Edit each file above. For base_config: **delete** "Ensure rebuilderd-worker@.service.d exists" + "Deploy rebuilderd-worker TimeoutStopSec override" (417-436); **keep** makepkg tasks (Codex confirmed their active paths `/tmp/makepkg-node-maintenance` + `/var/lib/node-maintenance/.cache/...` don't depend on removed rebuilderd paths). **Retag BOTH** makepkg comments — the header (258-262) AND the embedded content comment inside the deployed file (280-282) — so the final `git grep rebuilderd` in the ansible tree is empty. New rationale, e.g.: `# node-maintenance user makepkg override — writable BUILDDIR for phase2 yay AUR builds.`
- [ ] **Step 2:** Confirm no dangling references.
```bash
cd /Users/akhozya/source-code/homelab/.claude/worktrees/rm-rebuilderd
git grep -in 'rebuilderd\|archlinux-repro' docs/scripts/node-maintenance/ansible/ | grep -v roles/rebuilderd_teardown
```
Expected: only intentional leftovers (none, or the retagged makepkg comment).
- [ ] **Step 3: Lint**
```bash
cd docs/scripts/node-maintenance/ansible && ansible-lint . && yamllint .
```
Expected: clean.
- [ ] **Step 4: Commit**
```bash
git commit -am "refactor(node-maint): drop rebuilderd packages/host_vars/base_config wiring"
```

---

### Task 4: Remove reboot-orchestration coupling (phase1/phase2/all.yml)

**Files:**
- Modify: `phase2.yml` (delete PLAY 0.5 "Pause rebuilderd fleet-wide" 126-142; per-node stop 160-162; comments 336, 475-478)
- Modify: `phase1.yml:112-126` (delete the ENTIRE "DEFERRED-START ALERTS" block — comment + the `Silence deferred-start alerts` task; it is rebuilderd-only)
- Modify: `group_vars/all.yml:24-33` (delete the deferred-silence comment + `silence_deferred_duration_seconds` + `silence_deferred_alertnames`)

- [ ] **Step 1 (Codex #1 — verified rebuilderd-only):** Delete, explicitly:
  - `group_vars/all.yml:24-33` — the deferred block (`silence_deferred_duration_seconds` + `silence_deferred_alertnames: "RebuilderdWorkerDown"`). **Do NOT set to `[]` — remove the vars.**
  - `phase1.yml:112-126` — the whole `DEFERRED-START ALERTS` comment + `Silence deferred-start alerts` task (its only consumer).
  - `phase2.yml:475-478` — the deferred-silence comment; plus PLAY 0.5 (126-142), per-node stop (160-162), comment 336.
  - **KEEP** `silence_alertnames` + `silence_duration_seconds` (all.yml:21-22) — the *broad* maintenance silence covering StatefulSetReplicasMismatch/MySQLDown/etc. Non-rebuilderd.
- [ ] **Step 1b:** Confirm no orphaned consumer.
```bash
git grep -n 'silence_deferred' docs/scripts/node-maintenance/ansible/
```
Expected: empty.
```bash
git grep -n 'silence_deferred_alertnames\|RebuilderdWorkerDown' docs/scripts/node-maintenance/ansible/
```
Handle every consumer so no play references an undefined var.
- [ ] **Step 2: Syntax-check both playbooks**
```bash
ansible-playbook --syntax-check phase1.yml phase2.yml -i inventory.yml
```
Expected: parse OK.
- [ ] **Step 3: Commit**
```bash
git commit -am "refactor(node-maint): drop rebuilderd pause/silence from reboot phases"
```

---

### Task 5: Monitoring — drop VMRule group + revert exclusions

**Files:**
- Modify: `monitoring/configs/victoria-metrics/vmrules.yaml` (delete `rebuilderd-alerts` group 1108-1134; revert exclusions/thresholds 134, 1176-1216 per C8)

- [ ] **Step 1:** Delete the `rebuilderd-alerts` group (`RebuilderdWorkerDown`, `RebuilderdHighFailureRate`). For each node-alert exclusion (`HighCpuThrottling` threshold, node CPU/mem/page-fault `rebuilderd-worker` label excludes), remove the rebuilderd carve-out and restore the base threshold — **review each individually** (C8).
- [ ] **Step 2: Validate schema** (SOPS-free file → kubeconform direct)
```bash
cd /Users/akhozya/source-code/homelab/.claude/worktrees/rm-rebuilderd
yamllint monitoring/configs/victoria-metrics/vmrules.yaml
kubeconform -strict -ignore-missing-schemas monitoring/configs/victoria-metrics/vmrules.yaml
```
Expected: no errors; PromQL groups still valid YAML.
- [ ] **Step 3:** Sanity — no rebuilderd metric names remain.
```bash
git grep -in rebuilderd monitoring/
```
Expected: empty.
- [ ] **Step 4: Commit**
```bash
git commit -am "refactor(monitoring): drop rebuilderd VMRule group + load exclusions"
```

---

### Task 6: k8s comments + scripts cleanup

**Files:**
- Modify: `infrastructure/configs/databases/mysql/cluster.yaml:204`, `.../mysql/exporter.yaml:53` (update comment; **keep** the raised CPU limits)
- Modify: `docs/scripts/ansible-apply.sh` (delete rebuilderd verify `case` block 29-38; update header usage)
- Modify: `docs/scripts/setup-node.sh` (drop rebuilderd role-list echo + makepkg note)
- Modify: `docs/scripts/node-maintenance/install-worker.sh` (drop rebuilderd-worker override deploy + echo)
- Modify: `docs/scripts/node-maintenance/lib/node-config-notify.sh:28` (comment)
- Delete: `docs/scripts/node-maintenance/systemd/rebuilderd-worker-override.conf`

- [ ] **Step 1:** Edit/delete per above. For cluster.yaml/exporter.yaml, reword to e.g. `# CPU headroom for build-farm load (rebuilderd removed 2026-07; retained as general burst headroom).` — decide keep-limit rationale.
- [ ] **Step 2: shellcheck the touched scripts**
```bash
shellcheck docs/scripts/ansible-apply.sh docs/scripts/setup-node.sh docs/scripts/node-maintenance/install-worker.sh docs/scripts/node-maintenance/lib/node-config-notify.sh
```
Expected: no new warnings.
- [ ] **Step 3: Commit**
```bash
git rm docs/scripts/node-maintenance/systemd/rebuilderd-worker-override.conf
git commit -am "refactor: drop rebuilderd hooks from scripts + mysql comments"
```

---

### Task 7: Docs update + history entry (the "why")

**Files:**
- Modify: `docs/ARCHITECTURE.md`, `docs/HOMELAB_ANALYSIS.md:93`, `README.md:86`, `docs/CODEMAPS/monitoring.md:57,67`, `docs/scripts/node-maintenance/README.md:11`, `docs/scripts/node-maintenance/ANSIBLE_REVIEW_PLAN.md:38,59`, `CLAUDE.md:51`
- Append: `docs/HOMELAB_HISTORY.md`

- [ ] **Step 1:** Remove rebuilderd from live-state docs (node roles, role apply-order 13→12, vmrules group list, review item #15). Drop the `rebuilderd-progress` skill line from `CLAUDE.md:51`.
- [ ] **Step 2:** Append a HOMELAB_HISTORY.md entry dated 2026-07-06 — **the why**: reproducible-build farm removed after chronic W2 resource saturation (load ~11, 7.6 G swap thrash, 17× cicc/nvshmem OOM 2026-07-06 that starved the co-located MySQL replica → DNS `-2` NONAME → replica IO thread stopped → StatefulSetReplicasMismatch; plus the documented 2026-02-21 / 04-26 / 05-22 OOM→MySQL-pod-kill incidents that drove MemoryMax 18G→8G). Reference this session's diagnosis. Do NOT edit archive/ or past dated entries (C6).
- [ ] **Step 3: Lint docs** (markdown-only push is CI-exempt, but check)
```bash
git grep -in rebuilderd docs/ README.md CLAUDE.md | grep -v docs/archive | grep -v HOMELAB_HISTORY
```
Expected: empty (all live refs gone; history entry + archive retained).
- [ ] **Step 4: Commit**
```bash
git commit -am "docs: remove rebuilderd from live docs; record removal rationale"
```

---

### Task 8: Merge, apply on nodes, verify

**Files:** none (deploy)

- [ ] **Step 1: Merge PR-1 to main + push**
```bash
cd /Users/akhozya/source-code/homelab
git checkout main && git merge wt-rm-rebuilderd && git push
```
- [ ] **Step 2: Apply the teardown** — **choose per C2:**
  - **Attended (recommended):** deploy + run `ansible-apply.sh` on CP:
    ```bash
    scp -P 65300 docs/scripts/ansible-apply.sh akhozya@gmk-k3s-control-plane:~/ansible-apply.sh
    ssh -p 65300 -t akhozya@gmk-k3s-control-plane "chmod +x ~/ansible-apply.sh && ~/ansible-apply.sh"
    ```
    (`sudo systemctl start node-maintenance-sync.service` → pulls main → fires `node-maintenance-config.service` → teardown runs. One sudo, live output.)
  - **Unattended:** do nothing — the 10-min sync timer pulls + applies within ≤10 min (04:00 safety net).
- [ ] **Step 3: Verify nodes clean** (SSH, read-only)
```bash
for h in "z3us@worker-node-2" "akhozya@worker-node"; do
  echo "== $h =="; ssh -p 65300 "$h" '
    pacman -Qs rebuilderd || echo PKG_GONE;
    systemctl list-unit-files 2>/dev/null | grep -iE "rebuild|repro" || echo UNITS_GONE;
    ls -d /mnt/*/repro /mnt/*/rebuilderd-worker /var/lib/repro /var/lib/rebuilderd-worker /var/lib/rebuilderd 2>/dev/null || echo DATA_GONE'
done
```
Expected: `PKG_GONE`, `UNITS_GONE`, `DATA_GONE` on both.
- [ ] **Step 4: Verify alerts + drift-heal green**
```bash
bash ~/.claude/skills/_shared/check-alerts.sh | grep -i rebuilderd || echo "no rebuilderd alerts"
ssh -p 65300 akhozya@gmk-k3s-control-plane 'systemctl is-active node-maintenance-config.service; journalctl -u node-maintenance-config.service -n 20 --no-pager | tail'
```
Expected: no rebuilderd alerts; drift-heal `changed` on this run then idempotent; no failures.

---

### Task 9: PR-2 — remove teardown scaffold + chezmoi skill

**Files:**
- Delete: `roles/rebuilderd_teardown/`, its line in `node-config.yml`
- Out-of-repo: `~/.claude/skills/rebuilderd-progress/` (chezmoi)

- [ ] **Step 1 (only after Task 8 verified clean):** new worktree, delete the teardown role + its workers-play line.
```bash
git worktree add .claude/worktrees/rm-teardown-scaffold -b wt-rm-teardown-scaffold && cd $_
git rm -r docs/scripts/node-maintenance/ansible/roles/rebuilderd_teardown/
# edit node-config.yml: remove `- role: rebuilderd_teardown`
ansible-playbook --syntax-check docs/scripts/node-maintenance/ansible/node-config.yml -i docs/scripts/node-maintenance/ansible/inventory.yml
git commit -am "chore(node-maint): remove one-shot rebuilderd_teardown scaffold"
```
- [ ] **Step 2:** merge + push. (Workers play now has no rebuilderd anything.)
- [ ] **Step 3:** Remove the skill via chezmoi (separate repo).
```bash
# invoke /chezmoi-sync after: rm -rf ~/.claude/skills/rebuilderd-progress/
```
- [ ] **Step 4: Final grep — whole homelab repo clean**
```bash
git grep -in 'rebuilderd\|archlinux-repro' -- ':!docs/archive' ':!docs/HOMELAB_HISTORY.md'
```
Expected: empty.

---

## Self-Review (against the map)

- **Ansible:** role dir ✓(T2), node-config.yml ✓(T2), workers.yml pkgs ✓(T3), packages task ✓(T3), host_vars ✓(T3), base_config 417-436 ✓(T3) + makepkg 258-289 ✓(C5 keep), phase1/2/all.yml ✓(T4), .ansible-lint ✓(T3).
- **k8s:** mysql cluster.yaml + exporter.yaml comments ✓(T6). (No provisioning manifests — confirmed by map.)
- **Scripts:** ansible-apply.sh, setup-node.sh, install-worker.sh, node-config-notify.sh, rebuilderd-worker-override.conf ✓(T6).
- **Docs:** ARCHITECTURE, HOMELAB_ANALYSIS, README, CODEMAPS/monitoring, node-maintenance/README, ANSIBLE_REVIEW_PLAN, CLAUDE.md ✓(T7); HISTORY append ✓(T7); archive untouched ✓(C6).
- **CI:** no CI ref (map). Ansible YAML lint via ansible-lint locally (validate.yaml may not cover docs/scripts — confirm).
- **Monitoring:** vmrules group + exclusions ✓(T5).
- **Skill:** rebuilderd-progress ✓(T9, chezmoi).
- **Node teardown completeness** (from spikes): pkgs, pkg-owned units (auto via pacman), ansible units + 4 drop-in dirs, 3 scripts, 3 confs + storage.conf, textfile .prom, data dirs + symlinks, daemon-reload ✓(T1).

## Open decisions for review
1. **C2** — attended vs unattended apply? (recommend attended)
2. **C5** — keep base_config makepkg override? (recommend keep, retag)
3. **C6** — "history" = on-node state purge + HISTORY append, archive untouched — correct reading?
4. **C8** — confirm reverting each VMRule exclusion is safe (no other workload relies on the loosened threshold).
