# Immich GPU-node Step 4: fleet-onboard + k3s join + GPU device-plugin — RUNBOOK v1

> **For executors:** ops runbook, not a code-TDD plan. Each **gate** ends with a verification block (exact command + expected output) and a **rollback / lockout-recovery** block. Execute gate-by-gate; do not start a gate until the prior gate's verification passes. Steps use `- [ ]` for tracking.

**Goal:** Make the already-built Arch GPU-passthrough VM (`immich-vm`, 192.168.1.231) a managed member of the homelab fleet + k3s cluster, and make its Meteor Lake iGPU requestable by pods via the Intel GPU device-plugin — WITHOUT disrupting the live (W1-pinned) Immich, and without ever in-guest-rebooting the passthrough VM.

**Architecture:** Two-tier as designed in `2026-07-10-immich-gpu-node-substrate-heal.md`. This runbook executes the guest onboarding (Tier-1 substrate) + k3s join + GPU exposure. Immich pod cutover to the node (4E) is **design-only here — it is gated on the data-migration spec** (the local-path library PVC pins the server to W1; a nodeSelector alone strands it Pending).

**Tech stack:** ansible node-maintenance (roles reused as-is), k3s v1.36.2+k3s1 (manual binary; matches the live cluster — bumped from the v1.36.1 first pinned here), Flux GitOps, `intel/intel-gpu-plugin:0.36.0` (standalone DaemonSet), libvirt/virsh on the NAS.

## Global Constraints (every gate inherits these)
- **GitOps-only** for cluster state: commit → Flux `fr`. Never `kubectl apply/edit/patch`. Node config via ansible node-maintenance, never hand-edit `/etc/rancher/k3s`.
- **Image-pin** `major.minor.patch`. `intel/intel-gpu-plugin:0.36.0` — pinned, no floating tag.
- **VM lifecycle = `virsh` only** (`-c qemu:///system`), never the zettOS UI (regenerates the domain, C2/C5). Autostart stays OFF.
- **NEVER in-guest reboot / `systemctl reboot` the VM; never `virsh destroy`** (dirty iGPU → host crash, C3). This runbook is designed so **no reboot is needed** (cmdline blacklist already baked).
- **Worktree edits only** (`wt-immich-gpu-node`); main tree is edit-blocked. Codex static-review each repo batch before commit (`.claude/review-invariants.md`), fix in severity order, cap 3 rounds.
- **Agents have no sudo** on nodes. CP-sudo reads (node-maintenance pubkey, k3s node-token) + NAS `virsh` are **operator-assisted** steps, flagged `[OPERATOR]`. VM `akhozya` has NOPASSWD sudo.
- **CI is red since 2026-07-09** (runner-init failure, pre-existing, unrelated) — not a merge blocker for these changes; validate locally.
- **Sequencing invariant:** do NOT commit `immich-vm` into `inventory.yml` until 4A is done (node-maintenance@:65300 reachable + host key in `lib/known_hosts`), else the CP drift-heal (03:00/15:00) errors on the unreachable host every run.

## Current state (spiked 2026-07-10, ground truth)
- linux-lts `6.18.38-1-lts`; NIC `enp2s0` @ `192.168.1.231/24`; MAC `52:54:00:82:be:df`.
- Storage: `vda` 160G → `vda1` 1G `/boot` (vfat) · LVM `root` 32G `/` · `home` 126G `/home` (118G free).
- GPU LIVE: `/dev/dri/renderD129` + i915 loaded; `load-i915.service` active; `immich-gpu-heal-watchdog.timer` active; virtiofs `immich-library` mounted at `/var/lib/immich-library`.
- `/proc/cmdline` already carries `modprobe.blacklist=i915 console=hvc0` → **`immich_gpu_node` role already applied; re-run is idempotent, no UKI rebuild, no reboot.**
- render GID **987**, video GID **983**.
- sshd: default `:22` only (no explicit `Port`); UFW active, currently allows `:22`. `node-maintenance` user **absent**.
- libvirt domain running (Id 2, name = UUID `0398541a-…`, title immich-vm), canonical XML in Git (`apps/immich/gpu-node/immich-vm-domain.xml`, `0a6e3dcd`).

## In-guest-reboot path audit (the core safety property — every path must be neutralized)
Any in-guest reboot of this passthrough VM wedges the iGPU → NAS host crash (C3). Onboarding it as a fleet `workers` member inherits **every** fleet reboot path. All must be closed in the 4B commit:

| # | Reboot path | Reaches VM? | Neutralized by |
|---|---|---|---|
| 1 | phase2 PLAY 1 `ansible.builtin.reboot` (weekly Sat) | YES if in `workers` | 4B: PLAY 1 → `hosts: workers:!virtual` + update-only PLAY 1b |
| 2 | phase1 CP reboot | No — `hosts: localhost` (CP self-update only) | N/A |
| 3 | `rolling-restart-k3s.yml` | No — `systemctl restart k3s-agent`, not an OS reboot | N/A (safe as-is) |
| 4 | `node_isolation_heal` self-reboot ladder (dry-run today) | YES (Play 4 `workers`) | 4B: gate the role `when: "'virtual' not in group_names"` |
| 5 | `hardening` `kernel.panic=10` + `softlockup_panic=1` + `hardlockup_panic=1` (auto-reboot on lockup) | YES (`node-config` Play 3, `hosts: all`) | 4B: VM-only sysctl override `kernel.panic=0` + lockup_panic=0 (via `immich_gpu_node` role) |
| 6 | `hardening` systemd `RuntimeWatchdogSec=30`/`RebootWatchdogSec=2min` | **YES** — the q35 machine emulates an ICH9 LPC bridge whose iTCO watchdog appears in-guest as `/dev/watchdog0` (`iTCO_wdt`). The domain XML has no `<watchdog>` device, but the *chipset* provides one anyway. Original "inert" assumption WRONG — verified live 2026-07-10. | 4B: VM-only `system.conf.d` override `RuntimeWatchdogSec=0` + `RebootWatchdogSec=0` (via `immich_gpu_node` role) + `daemon-reexec`. Distinct vector from #5 — a hardware-watchdog reset fires while the kernel is still ALIVE (no panic), so the panic sysctls do NOT catch it. |
| 7 | Manual/operator in-guest `systemctl reboot` | operator discipline | Rule: NEVER; cold-restart = NAS `virsh shutdown --timeout 120`+`start` |

---

## Gate 4A — Access bootstrap (ACCESS-CHANGING, lockout risk)
**Objective:** `node-maintenance@192.168.1.231:65300` reachable with the CP key + NOPASSWD sudo, `:22` retained as break-glass until the firewall role flips UFW in 4B. **Operator at the NAS** (virsh console = the only recovery if this locks out).

**Files:** none in Git yet (all on-node). `known_hosts` entry is added in 4B.

- [ ] **1. [OPERATOR — on CP, sudo] Capture the CP node-maintenance public key.**
  ```bash
  ssh -p 65300 akhozya@gmk-k3s-control-plane 'sudo cat /var/lib/node-maintenance/.ssh/id_ed25519.pub'
  ```
  Copy the single `ssh-ed25519 AAAA… node-maintenance@…` line. This is what the VM must trust.

- [ ] **2. [VM — akhozya] Create the `node-maintenance` user + key + sudoers** (mirrors `install-worker.sh:27-49`).
  ```bash
  ssh -o IdentityAgent=none -o IdentitiesOnly=yes -i ~/.ssh/zl_nas_ed25519 akhozya@192.168.1.231
  # then on the VM:
  sudo useradd -r -s /bin/bash -m -d /var/lib/node-maintenance node-maintenance
  sudo install -d -m 0700 -o node-maintenance -g node-maintenance /var/lib/node-maintenance/.ssh
  printf '%s\n' '<CP-PUBKEY-FROM-STEP-1>' | sudo tee /var/lib/node-maintenance/.ssh/authorized_keys
  sudo chown node-maintenance:node-maintenance /var/lib/node-maintenance/.ssh/authorized_keys
  sudo chmod 0600 /var/lib/node-maintenance/.ssh/authorized_keys
  printf 'node-maintenance ALL=(ALL) NOPASSWD:ALL\n' | sudo tee /etc/sudoers.d/node-maintenance
  sudo chmod 0440 /etc/sudoers.d/node-maintenance
  sudo visudo -cf /etc/sudoers.d/node-maintenance   # expect: parsed OK
  ```
  (base_config drift-heals both authorized_keys and the canonical sudoers on the first node-config run in 4B.)

- [ ] **3. [VM — akhozya] Add sshd `:65300` alongside `:22`, and transiently open UFW :65300.**
  ```bash
  printf 'Port 22\nPort 65300\n' | sudo tee /etc/ssh/sshd_config.d/10-port.conf
  sudo sshd -t && echo "sshd config OK"      # must print OK before reload
  sudo systemctl reload sshd
  sudo ufw allow from 192.168.1.0/24 to any port 65300 proto tcp   # matches the firewall role's canonical rule exactly → role sees it present, no leftover broad rule
  sudo ss -tlnp | grep -E ':(22|65300)\b'     # expect sshd LISTEN on BOTH 22 and 65300
  ```

**VERIFICATION 4A** — from the CP as the node-maintenance user (the exact identity ansible uses):
```bash
# [OPERATOR — on CP, sudo]
ssh -p 65300 akhozya@gmk-k3s-control-plane \
  "sudo -u node-maintenance ssh -p 65300 -i /var/lib/node-maintenance/.ssh/id_ed25519 \
   -o StrictHostKeyChecking=accept-new node-maintenance@192.168.1.231 'id && sudo -n whoami'"
```
Expect: `uid=…(node-maintenance) …` then `root` (NOPASSWD sudo works). If this passes, 4A is done.

**ROLLBACK / LOCKOUT-RECOVERY 4A:** everything here is additive (`:22` still open, UFW still allows `:22`). If `:65300` misbehaves, you are still in via `akhozya@:22`. If akhozya@:22 is also lost: **NAS virsh console** — `[OPERATOR]` `ssh -p 56634 akhozya@192.168.1.136` then `virsh -c qemu:///system console 0398541a-c088-48cd-b16a-4b45d31a92f3` (login via console, `console=hvc0` is baked in the UKI). Undo: `sudo rm -f /etc/ssh/sshd_config.d/10-port.conf /etc/sudoers.d/node-maintenance && sudo userdel -r node-maintenance && sudo systemctl reload sshd`.

---

## Gate 4B — Wire into GitOps + apply node-config (UFW flips to fleet ruleset)
**Objective:** `immich-vm` committed to inventory (`workers` + new `virtual` group), the `immich_gpu_node` role wired via a `hosts: virtual` play, host_vars finalized, host key trusted; then a **targeted** `node-config.yml --limit immich-vm` run applies base_config/hardening/firewall/k3s_config/immich_gpu_node. **No reboot** (cmdline already baked → the role's mkinitcpio handler does not fire).

**Files (worktree edits):**
- Modify: `docs/scripts/node-maintenance/ansible/inventory.yml` (add host + `virtual` group)
- Modify: `docs/scripts/node-maintenance/ansible/node-config.yml` (add `hosts: virtual` play; **gate `node_isolation_heal` off `virtual`** — path #4)
- Modify: `docs/scripts/node-maintenance/ansible/phase2.yml` (**carve the VM out of the weekly in-guest reboot** + add update-only VM play — path #1)
- Create: `docs/scripts/node-maintenance/ansible/roles/immich_gpu_node/files/99-zz-immich-vm-nopanic.conf` (**disable auto-reboot-on-panic** — path #5)
- Create: `docs/scripts/node-maintenance/ansible/roles/immich_gpu_node/files/zz-immich-vm-nowatchdog.conf` (**disarm the q35 iTCO systemd watchdog** — path #6, found live: `/dev/watchdog0` present)
- Modify: `docs/scripts/node-maintenance/ansible/roles/immich_gpu_node/{tasks,handlers}/main.yml` (deploy + apply BOTH reset-bug overrides: `sysctl --system` for no-panic, `daemon-reexec` for no-watchdog)
- Modify: `docs/scripts/node-maintenance/ansible/host_vars/immich-vm.yml` (k3s vars + cmdline token)
- Modify: `docs/scripts/node-maintenance/lib/known_hosts` (add `.231` host keys)

- [ ] **1. inventory.yml — add the host under `workers` and a new `virtual` group** (children of `all`):
  ```yaml
      workers:
        hosts:
          worker-node:
            ansible_host: 192.168.1.129
            k3s_service: k3s-agent.service
          worker-node-2:
            ansible_host: 192.168.1.126
            k3s_service: k3s-agent.service
          immich-vm:
            ansible_host: 192.168.1.231
            k3s_service: k3s-agent.service
      virtual:
        hosts:
          immich-vm: {}
  ```
  (Inherits `ansible_user: node-maintenance`, `ansible_port: 65300`, key + known_hosts from `all.vars`. `nic_tuning` self-gates off the unset `nic_tuning_iface` — no `virtual` exclusion needed.)

- [ ] **2a. node-config.yml — add a 6th play after Play 3** (hardening/nic_tuning/security_scan), before/alongside the workers play:
  ```yaml
  - name: Immich GPU node — passthrough i915 + virtiofs + guest-heal
    hosts: virtual
    become: true
    gather_facts: true
    roles:
      - immich_gpu_node
  ```

- [ ] **2b. node-config.yml — exclude the VM from `node_isolation_heal` (reboot path #4).** Play 4 (`hosts: workers`) applies `node_isolation_heal`, whose ladder ends in `systemctl reboot` (dry-run today, but a post-soak active flip would self-reboot the VM → host crash). Gate the role off the `virtual` group (keeps `clusterip_heal`, whose k3s-agent restart is safe):
  ```yaml
  # in Play 4's roles: list, change the bare `- role: node_isolation_heal` to:
      - role: node_isolation_heal
        when: "'virtual' not in group_names"   # never a self-reboot ladder on the passthrough VM (C3)
  ```

- [ ] **3. host_vars/immich-vm.yml — finalize k3s + cmdline vars.** Add:
  ```yaml
  # ---- K3s data-dir (STEP-4 decision): containerd/images/state on the 126Gi home LV, not the 32Gi root ----
  k3s_data_dir: /home/k3s
  # ---- Node label so the GPU device-plugin DaemonSet + (later) Immich pods can nodeSelector this node ----
  # REPLACES the workers-group inherited svccontroller…enablelb=true (list, no merge — deliberate: the
  # GPU node is not a servicelb ingress endpoint).
  k3s_node_labels:
    - "homelab/gpu=intel"
  # ---- systemd-networkd file managing enp2s0 (REQUIRED — hardening renders {{ primary_network_file }}.d
  #      UNguarded → the play errors on this host without it; networkctl confirms 20-ethernet.network) ----
  primary_network_file: 20-ethernet.network
  ```
  (`k3s_prefer_bundled_bin` is NOT re-declared — inherited `true` from `group_vars/workers.yml` already.)
  And extend the existing `expected_kernel_params` (the i915 token is now baked in `/proc/cmdline`):
  ```yaml
  expected_kernel_params:
    - console=hvc0
    - modprobe.blacklist=i915
  ```

- [ ] **3b. immich_gpu_node role — disable auto-reboot-on-panic (reboot path #5).** The `hardening` role (Play 3, `hosts: all`) ships `sysctl-99-watchdog.conf` = `kernel.panic=10` + `kernel.softlockup_panic=1` + `kernel.hardlockup_panic=1`, so a lockup on the VM auto-**reboots** in-guest → host crash. Ship a VM-only override that sorts AFTER `99-watchdog.conf` in `/etc/sysctl.d` (lexical `99-zz…` > `99-watchdog`), so `sysctl --system` applies these last:
  - `roles/immich_gpu_node/files/99-zz-immich-vm-nopanic.conf`:
    ```ini
    # Passthrough-VM safety: a kernel lockup/panic must NEVER auto-reboot in-guest — that wedges the
    # passed-through iGPU and crashes the NAS host (reset-bug, C3). Overrides hardening's 99-watchdog.conf.
    # On a lockup the guest hangs → goes unreachable → alert → operator/Tier-2 NAS-side virsh reset.
    kernel.panic = 0
    kernel.softlockup_panic = 0
    kernel.hardlockup_panic = 0
    ```
  - `roles/immich_gpu_node/tasks/main.yml` — add (deploy + notify apply):
    ```yaml
    - name: Disable auto-reboot-on-panic (reset-bug safety — overrides hardening watchdog sysctl)
      ansible.builtin.copy:
        src: 99-zz-immich-vm-nopanic.conf
        dest: /etc/sysctl.d/99-zz-immich-vm-nopanic.conf
        owner: root
        group: root
        mode: "0644"
      notify: Apply nopanic sysctl
    ```
  - `roles/immich_gpu_node/handlers/main.yml` — add:
    ```yaml
    - name: Apply nopanic sysctl
      ansible.builtin.command: sysctl --system
      changed_when: false
    ```
  (The `hardening` "Remove legacy sysctl files" task removes only its own known list — it won't touch this override. No reboot; `sysctl --system` is non-disruptive.)

- [ ] **3c. immich_gpu_node role — disarm the systemd hardware watchdog (reboot path #6 — FOUND LIVE, audit was wrong).** The q35 machine emulates an ICH9 iTCO watchdog → `/dev/watchdog0` IS present in-guest (verified `ls -l /dev/watchdog0 → iTCO_wdt`, 2026-07-10). So `hardening`'s `system.conf.d/watchdog.conf` (`RuntimeWatchdogSec=30`+`RebootWatchdogSec=2min`) is NOT inert: once a `systemd` upgrade's `daemon-reexec` reads it, systemd arms the iTCO watchdog and a PID-1 freeze → in-guest reset → wedged iGPU → NAS host crash. The panic sysctls (3b) do NOT cover this (watchdog fires with the kernel alive, no panic). Ship a VM-only `system.conf.d` override sorting AFTER `watchdog.conf` (`zz-…` > `watchdog.conf`):
  - `roles/immich_gpu_node/files/zz-immich-vm-nowatchdog.conf` = `[Manager]` / `RuntimeWatchdogSec=0` / `RebootWatchdogSec=0`.
  - `tasks/main.yml`: `copy` → `/etc/systemd/system.conf.d/zz-immich-vm-nowatchdog.conf`, `notify: Disarm systemd watchdog`.
  - `handlers/main.yml`: `Disarm systemd watchdog` → `systemctl daemon-reexec` (Manager config is re-read ONLY on re-exec, not reload — `daemon-reload` would leave 30 latent). Safe: PID-1 re-exec preserves state, k3s-agent/containerd unaffected.
  (hardening's "Reload systemd" handler is `daemon-reload`, so `RuntimeWatchdogSec=30` never goes live *during* the run — the danger is a future `daemon-reexec`; the override closes it permanently.)

- [ ] **4. lib/known_hosts — trust the VM's host keys** (StrictHostKeyChecking=yes → ansible refuses .231 otherwise):
  ```bash
  ssh-keyscan -H -p 65300 192.168.1.231 >> docs/scripts/node-maintenance/lib/known_hosts
  # verify a hashed entry was appended (do NOT commit an unhashed one)
  tail -3 docs/scripts/node-maintenance/lib/known_hosts
  ```

- [ ] **5. phase2.yml — carve the VM out of the weekly in-guest reboot (MANDATORY, SAME commit as the inventory add).** The weekly `node-maintenance.timer` (Sat 04:30 UTC → phase1 → phase2) runs **phase2 PLAY 1** (`hosts: workers`, `serial:1`) which does `ansible.builtin.reboot` per worker. On the passthrough VM an **in-guest reboot wedges the iGPU → NAS host crash (C3)**. (phase1 is `hosts: localhost` = CP-only, untouched; `rolling-restart-k3s.yml` only `systemctl restart k3s-agent` = safe.) Two edits:
  - PLAY 1 host scope — exclude the `virtual` group:
    ```yaml
    # BEFORE:  hosts: workers
    # AFTER:
      hosts: workers:!virtual   # physical workers only — the GPU VM must never in-guest reboot (C3)
    ```
  - New **PLAY 1b** (update-only; NO in-guest reboot — a kernel bump is alerted for a NAS-side virsh-graceful cold-restart), placed right after PLAY 1:
    ```yaml
    # ──────────────────────────────────────────────────────────────
    # PLAY 1b: GPU VM weekly update (NO in-guest reboot — reset-bug C3)
    # ──────────────────────────────────────────────────────────────
    - name: Node maintenance — Phase 2 (GPU VM update, no reboot)
      hosts: virtual
      serial: 1
      gather_facts: false
      become: true
      tasks:
        - name: Verify SSH reachable
          ansible.builtin.wait_for_connection:
            timeout: 120
        - name: Upgrade via yay (best-effort; NEVER reboots — cold-restart is a NAS-side virsh op)
          block:
            - name: yay upgrade
              ansible.builtin.shell: "{{ yay_cmd }}"
              register: vm_yay
              changed_when: "'there is nothing to do' not in vm_yay.stdout"
          rescue:
            - name: Non-fatal retry
              ansible.builtin.shell: "{{ yay_cmd }}"
              changed_when: false
              failed_when: false
        - name: Detect pending kernel reboot (running kernel != installed linux-lts module dir)
          # NOT `test -d /usr/lib/modules/$(uname -r)`: the fleet installs kernel-modules-hook which
          # keeps the running kernel's module dir across a pacman upgrade → that heuristic always says
          # "current" and the alert never fires. Compare uname to the linux-lts-package-owned module dir.
          ansible.builtin.shell: |
            set -o pipefail
            running="$(uname -r)"
            installed="$(pacman -Ql linux-lts 2>/dev/null \
              | sed -n 's#^linux-lts /usr/lib/modules/\([^/]*\)/$#\1#p' | head -n1)"
            if [ -n "$installed" ] && [ "$running" != "$installed" ]; then echo pending; else echo current; fi
          args:
            executable: /bin/bash
          register: vm_reboot_needed
          changed_when: false
        - name: Alert if a NAS-side virsh-graceful cold-restart is due
          ansible.builtin.command: >-
            /usr/local/sbin/telegram-notify.sh
            "⚠️ immich-vm: weekly updates applied but the running kernel is stale — a NAS-side graceful
             virsh shutdown --mode acpi --timeout 120 + virsh start is due (NEVER in-guest reboot — reset-bug)."
          delegate_to: "{{ groups['control_plane'][0] }}"
          become: false
          when: vm_reboot_needed.stdout == "pending"
    ```
  No cordon/uncordon — nothing is rebooted, so the node is never disrupted. `yay_cmd` + `telegram-notify.sh` are the same var/script PLAY 1 uses; the VM's AUR build-user is set up by `base_config` (runs on it in step 6). **Reviewer/operator option:** if weekly VM patching isn't wanted, drop PLAY 1b and rely on pure exclusion (`workers:!virtual`) + operator/Tier-2 patching — the exclusion alone is the hard safety fix; PLAY 1b is the "keep it patched" nicety.

- [ ] **6. Local validation + Codex static review of the 4B diff**, then commit → merge → push.
  ```bash
  # ansible syntax + inventory sanity
  cd docs/scripts/node-maintenance/ansible && ansible-inventory -i inventory.yml --list >/dev/null && echo "inventory OK"
  ansible-playbook -i inventory.yml node-config.yml --syntax-check && echo "playbook syntax OK"
  ```
  Dispatch Codex STATIC git-only (rubric `.claude/review-invariants.md`); one-shot verdict. Fix in severity order. Then single-line commit, `git merge --ff-only`, push.

- [ ] **7. [OPERATOR — on CP, sudo] Sync the repo to the CP and run node-config TARGETED at the VM only.**
  ```bash
  ssh -p 65300 akhozya@gmk-k3s-control-plane
  sudo systemctl start node-maintenance-sync.service          # git pull into /etc/node-maintenance
  cd /etc/node-maintenance/ansible
  sudo ansible-playbook -i inventory.yml node-config.yml --limit immich-vm
  ```
  Watch for: `immich_gpu_node` tasks `ok`/`changed=0` (already applied); firewall role applies the fleet UFW ruleset; k3s_config writes `/etc/rancher/k3s/config.yaml`. `--limit immich-vm` keeps other nodes untouched.

**VERIFICATION 4B** — run on the VM after the node-config apply (via CP as node-maintenance):
```bash
sudo ufw status verbose | head -20                       # fleet allow-list present
sysctl kernel.panic kernel.softlockup_panic kernel.hardlockup_panic   # expect 0 0 0 (path #5 closed)
systemctl show -p RuntimeWatchdogSec -p RebootWatchdogSec            # expect 0/0 (path #6 closed — iTCO watchdog disarmed)
systemctl list-unit-files | grep -E 'node-isolation-heal' || echo "NO isolation-heal unit (correct, path #4)"
systemctl is-active load-i915.service immich-gpu-heal-watchdog.timer  # active active
cat /etc/rancher/k3s/config.yaml                          # data-dir/node-label/node-name/prefer-bundled-bin
```
Expect: UFW active with the fleet allow-list (`65300/tcp` from LAN, k3s pod/svc nets, VXLAN 8472/udp, kubelet 10250); **`kernel.panic=0` + both lockup_panic=0** (reboot path #5 closed); **no `node-isolation-heal` unit** on the VM (path #4 closed); load-i915 + heal timer active; `config.yaml` shows `data-dir: /home/k3s`, `node-label: homelab/gpu=intel`, `node-name: immich-vm`, `prefer-bundled-bin: true`. Ansible recap `failed=0`.
> **`:22` still allowed** — the firewall role is declarative-**additive** (`will not delete rules not in the list`), so the VM's build-time `ufw allow 22/tcp` + the akhozya `Port 22` drop-in **persist as break-glass**. This is intended through onboarding; close it in step 8 (optional) once `:65300` is proven end-to-end.

**ROLLBACK / LOCKOUT-RECOVERY 4B:** if the firewall role locks out `:65300` → NAS **virsh console** (`console=hvc0`), `sudo ufw allow from 192.168.1.0/24 to any port 65300 proto tcp`, investigate. Config revert = `git revert` the 4B commit + re-sync + re-run `--limit immich-vm`. The firewall pre-heal `ufw reload` is gated on `repaired>0` (`ff2b486b`) so a healthy run won't race the (not-yet-existing) k3s tunnel.

- [ ] **8. [OPTIONAL — run only AFTER 4B verification + 4C prove `:65300` end-to-end] Close the `:22` break-glass for fleet parity.** Keep it if you want an extra SSH break-glass alongside the virsh console; close it for minimal surface (other nodes are :65300-only). On the VM:
  ```bash
  sudo rm -f /etc/ssh/sshd_config.d/10-port.conf   # or edit to `Port 65300` only
  printf 'Port 65300\n' | sudo tee /etc/ssh/sshd_config.d/10-port.conf
  sudo sshd -t && sudo systemctl reload sshd
  sudo ufw delete allow 22/tcp                      # remove the build-time :22 allow (additive role won't)
  ```
  Recovery if this strands you: NAS virsh console. **Do not run this before `:65300` is proven through UFW.**

---

## Gate 4C — k3s-agent join (joins PROD cluster)
**Objective:** `immich-vm` joins as a Ready worker named `immich-vm`, labeled `homelab/gpu=intel`, data-dir on `/home/k3s`. No workload lands yet (Immich still W1-pinned).

**Files:** none (k3s install is out-of-band; `config.yaml` already written by 4B).

- [ ] **1. [OPERATOR — on CP, sudo] Capture the node-token.**
  ```bash
  ssh -p 65300 akhozya@gmk-k3s-control-plane 'sudo cat /var/lib/rancher/k3s/server/node-token'
  ```

- [ ] **2. [VM — node-maintenance or akhozya, sudo] Confirm config.yaml, then join.**
  ```bash
  cat /etc/rancher/k3s/config.yaml    # must show data-dir /home/k3s + node-label + node-name immich-vm (from 4B)
  # version MUST match the live cluster (all nodes v1.36.2+k3s1 as of 2026-07-10 — a concurrent
  # patch bumped it past the v1.36.1 this runbook first pinned). The safety hook blocks `curl | sh`,
  # so download → inspect → run the file: curl -sfL https://get.k3s.io -o /tmp/k3s-install.sh; then
  # sudo K3S_URL=… K3S_TOKEN=… INSTALL_K3S_VERSION='v1.36.2+k3s1' sh /tmp/k3s-install.sh agent
  curl -sfL https://get.k3s.io | sudo K3S_URL=https://192.168.1.127:6443 \
    K3S_TOKEN='<NODE-TOKEN>' INSTALL_K3S_VERSION='v1.36.2+k3s1' sh -s - agent
  systemctl status k3s-agent.service --no-pager | head -5
  ```
  (The installer reads `/etc/rancher/k3s/config.yaml` → applies data-dir, node-name, node-ip, node-label at first registration.)

**VERIFICATION 4C** (from mac, kubectl):
```bash
kubectl get node immich-vm -o wide
kubectl get node immich-vm -o jsonpath='{.metadata.labels.homelab/gpu}{"\n"}'   # expect: intel
# containerd data actually on the home LV:
# [VM] sudo du -sh /home/k3s 2>/dev/null   (should be growing, not /var/lib/rancher/k3s)
```
Expect: `immich-vm  Ready  <none>  …  v1.36.2+k3s1`, label `intel`. `clusterip_heal` (Play 4, workers) now covers it (safe k3s-agent restart on a ClusterIP wedge); `node_isolation_heal` is **excluded** from the VM (reboot path #4).

**ROLLBACK 4C:** `[VM] sudo /usr/local/bin/k3s-agent-uninstall.sh` removes the agent cleanly; then `kubectl delete node immich-vm`. Node-token compromise is the only real risk — do not paste it into logs/commits.

---

## Gate 4D — Intel GPU device-plugin (node advertises `gpu.intel.com/i915`)
**Objective:** the VM node advertises `gpu.intel.com/i915` as an allocatable resource, so pods can request the iGPU with **no privileged / no hostPath** (PSS-clean). Immich still untouched — this is provable standalone.

**Placement decision:** standalone DaemonSet (NOT the operator — the operator overrides pinned images, violating image-pin) in **`kube-system`** (already excluded from `disallow-host-path` + `require-non-root` CP+VP twins → **zero Kyverno edits**). The DaemonSet itself needs hostPath+root; kube-system is the low-friction, precedented home for a node device-plugin. Alternative (rejected for this gate): a dedicated `intel-gpu` ns added to all 4 policy excludes — cleaner ns hygiene but 4 Kyverno CEL/CP edits (review-heavy) for no functional gain.

**Files (worktree):**
- Create: `infrastructure/configs/intel-gpu-plugin/daemonset.yaml` (vendored upstream base @ v0.36.0, pinned + patched)
- Create: `infrastructure/configs/intel-gpu-plugin/kustomization.yaml`
- Modify: the parent `infrastructure/configs/kustomization.yaml` to include it (ordered before `apps`)

- [ ] **1. Vendor the upstream base DaemonSet** (`deployments/gpu_plugin/base/intel-gpu-plugin.yaml` @ `v0.36.0`) into `daemonset.yaml`, namespace `kube-system`, with three edits:
  - `image: docker.io/intel/intel-gpu-plugin:0.36.0` (pinned)
  - add container arg `-shared-dev-num=10` (Immich server + ML time-share one iGPU)
  - `nodeSelector: { kubernetes.io/arch: amd64, homelab/gpu: intel }` (binds to the GPU node via the purpose-built label from D3/host_vars — cleaner + more portable than pinning `kubernetes.io/hostname`; AMD workers lack the label; amd64 guards image arch)
  Keep the upstream securityContext (non-privileged, `drop: ALL`, `readOnlyRootFilesystem: true`, seccomp RuntimeDefault) and the four hostPath mounts (`/dev/dri`, `/sys/class/drm`, `/var/lib/kubelet/device-plugins`, `/var/run/cdi`) — these are why it must live in an excluded ns.
- [ ] **2. kustomization.yaml** referencing `daemonset.yaml`; wire into `infrastructure/configs/kustomization.yaml`.
- [ ] **3. Validate + Codex review + commit → merge → push → `fr`.**
  ```bash
  kubeconform-check / kustomize build infrastructure/configs | kubeconform -strict …   # via /homelab-yaml-validate
  ```
  Codex rubric focus: image-pin present; confirm the ns is genuinely excluded in BOTH CP and VP twins of disallow-host-path AND require-non-root (grep to confirm, don't assume); NetworkPolicy N/A (no Service/Ingress — device-plugin talks to kubelet over a host socket, not the network).

**VERIFICATION 4D:**
```bash
kubectl -n kube-system get ds intel-gpu-plugin -o wide      # DESIRED=1 READY=1, on immich-vm
kubectl -n kube-system get pods -l app=intel-gpu-plugin -o wide
kubectl get node immich-vm -o jsonpath='{.status.allocatable.gpu\.intel\.com/i915}{"\n"}'   # expect: 10
```
Expect allocatable `gpu.intel.com/i915: "10"`. **If `0` / absent:** i915 loads ~post-boot (blacklist + `load-i915.service`), so the plugin may have scanned before `/dev/dri/renderD129` existed → `kubectl -n kube-system rollout restart ds/intel-gpu-plugin`, re-check. (i915 is currently loaded + node is stable, so a fresh DS should see it.)

**ROLLBACK 4D:** `git revert` + `fr` removes the DaemonSet (no node state changes; nothing consumes the resource yet).

---

## Gate 4E — Immich pod pin to the GPU node (DESIGN-ONLY — GATED ON MIGRATION SPEC)
**Why it can't execute in this runbook:** `apps/immich/library-pvc.yaml` is a `local-path` 300Gi PVC bound on **worker-node (W1)**; that binding is what schedules `immich.server` to W1. Adding a `nodeSelector: homelab/gpu=intel` **strands the server Pending** — local-path cannot mount the W1-bound PV on `immich-vm`. Moving the server requires the **library on the VM** (the virtiofs `/var/lib/immich-library` share → a node-local PV), which is the **data-migration/cutover spec** (backups-first, DB stays CNPG in-cluster, Cloudflare tunnel + OIDC unchanged). ML (OpenVINO, no library dep) *could* pin independently but delivers little alone → fold into the migration.

**Designed values deltas** (for the migration spec to execute in `apps/immich/release.yaml`, worktree + Codex-review + `fr`):
- `values.server.controllers.main.pod.nodeSelector: { homelab/gpu: intel }` (+ same for `machine-learning`).
- Replace the postRenderer privileged + `hostPath: /dev/dri` GPU block (`release.yaml:57-75`) with a resource request on both containers: `resources.limits.gpu.intel.com/i915: "1"` (PSS-clean; drops the immich-ns hostPath Kyverno exclusion for Immich).
- `LIBVA_DRIVER_NAME: iHD` (server; currently `radeonsi`).
- Pod-level `securityContext.supplementalGroups: [987]` (VM render GID; **not** W1's 989/985) — re-confirm on the node at cutover: `getent group render`.
- `machine-learning` image → the `-openvino` variant + `MACHINE_LEARNING_DEVICE` set for GPU (plain ML image ignores the iGPU even with the resource granted).
- Library: repoint `immich.persistence.library` off the W1 local-path PVC to a VM-node-local PV backed by virtiofs `/var/lib/immich-library` — **migration-spec detail**.
- UFW pod↔node FORWARD route rules: add `ufw_route_rules_host` to `host_vars/immich-vm.yml` (pod-to-node `10.42.0.0/16→192.168.1.0/24` + node-to-pod, parity with W1/W2) — the `ufw_rules_base` set gets the node Ready + the GPU device-plugin working (4C/4D), but routed pod↔LAN traffic is default-deny until these are added. Not needed until Immich pods actually run on the VM (4E).

**This runbook STOPS at 4D** (GPU provably requestable cluster-side). 4E hands off to the migration spec.

---

## Decisions locked
| # | Decision | Rationale |
|---|---|---|
| D1 | sshd `:65300` = manual on-node drop-in (not drift-healed) | Matches fleet (finding B: no node sets `Port` in git; base-image). Adding `Port` to `hosts:all` hardening risks fleet-wide lockout — YAGNI. |
| D2 | `k3s_data_dir: /home/k3s` (126Gi LV) | 32Gi root too tight for containerd + Immich working set; mirrors W1/W2 big-volume data-dir + the W2 DiskPressure lesson. |
| D3 | Node label `homelab/gpu=intel` via k3s `node-label` (host_vars, applied at registration) | GitOps-native, no imperative `kubectl label`, no NFD. |
| D4 | GPU device-plugin = standalone DaemonSet, **kube-system**, v0.36.0 | Operator overrides pinned images (image-pin violation); kube-system already excluded in all 4 policies → zero Kyverno edits. |
| D5 | 4E is migration-gated; runbook ends at 4D | Library PVC pins server to W1; nodeSelector alone → Pending. Honest coupling. |
| D6 | `--limit immich-vm` for the 4B node-config run | Controlled apply (user present); leaves the other 3 nodes untouched. |
| D7 | VM carved out of phase2 in-guest reboot; weekly *updates* via PLAY 1b, *reboot* via NAS virsh (alerted) | In-guest reboot of a passthrough VM crashes the host (C3). Weekly patch stays automated; the reboot is the one thing that must be host-side. |
| D8 | VM-only `kernel.panic=0`+lockup_panic=0 (path #5) AND `RuntimeWatchdogSec=0`+`RebootWatchdogSec=0` (path #6) overrides | Two distinct in-guest auto-reboot-on-lockup vectors from `hardening`: (#5) panic/lockup sysctls, and (#6) the systemd hardware watchdog — the q35 iTCO `/dev/watchdog0` makes it live (audit's "inert" assumption was wrong). Both auto-reboot the VM → host crash. #6 is not covered by #5 (watchdog fires with the kernel alive, no panic). On the VM a lockup must hang→alert→NAS reset, never auto-reboot. |
| D9 | `node_isolation_heal` gated off `virtual` (reboot path #4), `clusterip_heal` kept | The isolation ladder self-reboots; catastrophic on the VM. k3s-agent restart (clusterip_heal) is the safe isolation recovery. |
| D10 | `:22` break-glass retained through onboarding (additive firewall), optional close in 4B step 8 | firewall role won't delete `:22`; keeping it as an extra break-glass until `:65300` is proven end-to-end is prudent for a fragile substrate. |

## Weekly maintenance & substrate self-heal (operator questions)
**Q: does the weekly "upgrade + reboot" (Sat 04:30) work for the VM/k3s on the NAS?**
- **Trigger chain:** `node-maintenance.timer` (Sat 04:30 UTC) → `phase1.yml` (`hosts: localhost` — CP self-update + CP reboot only, VM untouched) → sets `phase2-pending` → `phase2.yml`.
- **phase2 PLAY 1** (`hosts: workers`, `serial:1`) does `ansible.builtin.reboot` per worker. As written, adding the VM to `workers` would in-guest-reboot it weekly → **host crash (C3)**. Gate 4B step 5 fixes this: `workers:!virtual` excludes the VM; PLAY 1b gives it a **weekly yay upgrade with NO in-guest reboot**, and Telegram-alerts when a kernel bump means a cold-restart is due.
- **The reboot half stays a NAS-side `virsh` op** — `virsh shutdown --mode acpi --timeout 120` + `virsh start` (graceful; the drained/responsive guest releases the iGPU cleanly). Manual by the operator today; automated by the **Tier-2 host watchdog** later (below).
- **k3s rolling restart** (`cluster-roll` / `rolling-restart-k3s.yml`) is a `systemctl restart k3s-agent` — **safe on the VM as-is** (no OS reboot, no GPU reset). No change needed.
- **Daily config drift-heal** (`node-maintenance-config.timer`, 03:00/15:00, `node-config.yml` all hosts) runs the roles on the VM (firewall/hardening/immich_gpu_node) idempotently — the VM IS drift-healed daily, just never in-guest-rebooted.

**Q: any ansible to heal/fix/re-setup the ZL-NAS *host* itself (not the VM)?**
- **No — and by design.** The NAS is a zettOS **appliance**: not an ansible target, not a k3s node (validated non-viable — stripped modules, no modprobe, containerd conflict, updates clobber), no operator sudo. It is out of ansible/k3s scope ([[reference_nas]]). You cannot drift-heal the appliance.
- **Substrate self-heal is the Tier-2 host watchdog** (design `2026-07-10-immich-gpu-node-substrate-heal.md`), a k8s CronJob that runs **outside** the NAS (nodeSelector off the GPU node), SSHes the NAS + `virsh -c qemu:///system` (libvirt group, no root):
  - **Auto-heal:** re-`virsh define` from the Git canonical XML on drift/clobber (the XML is now in Git — `apps/immich/gpu-node/immich-vm-domain.xml`, `0a6e3dcd`); `virsh start` when the domain is down (it IS the autostart, since UI-autostart is off).
  - **Alert-only** (needs NAS root, can't self-fix): SSH key wiped by an update, `akhozya` dropped from the `libvirt` group, host i915 firmware missing → Telegram + the exact operator fix command.
  - **True reset-bug wedge** = alert-only → NAS host reboot (the only clean iGPU reset); never auto-`destroy` (crashes the host).
- **Status: Tier-2 is NOT built yet** — it is the natural **Step-5 follow-up** to this runbook. This runbook committed the canonical XML it consumes; building the CronJob + SOPS NAS-SSH key + VMRule + NetworkPolicy is separate. Until then, substrate recovery is operator-in-the-loop (recipes in memory `project_immich_gpu_transcode` + design C2–C5).

## Rollback matrix
| Gate | Blast radius | Recovery |
|---|---|---|
| 4A | VM only (additive) | still in on `:22`; else virsh console; `userdel -r` + rm drop-in |
| 4B | VM only (`--limit`) | virsh console + `ufw allow 65300`; `git revert` + re-run `--limit` |
| 4C | joins prod cluster (no workload) | `k3s-agent-uninstall.sh` + `kubectl delete node` |
| 4D | new kube-system DaemonSet | `git revert` + `fr` |
| 4E | live Immich (prod) | **not executed here** — migration spec owns it |

## Testing / idempotence
- 4B: re-run `node-config.yml --limit immich-vm` → recap `changed=0` (proves idempotence; role already applied).
- Heal watchdog is live + inert-safe; `immich-gpu-heal.sh --selfcheck` on the VM passes.
- 4D: delete the plugin pod → DaemonSet recreates → resource re-advertised.

## Self-review (spec coverage vs `2026-07-10-immich-gpu-node-substrate-heal.md`)
- Tier-1 guest onboarding (kernel/i915/virtiofs/heal) → already applied; 4B wires + drift-heals it. ✓
- k3s join + node label → 4C. ✓
- GPU exposure via Intel device-plugin (PSS-clean, no hostPath on app pods) → 4D. ✓
- Immich pin server+ML, DB/redis stay in-cluster → 4E design, migration-gated. ✓ (coupling surfaced, not hidden)
- Tier-2 host watchdog (k8s CronJob re-defining the canonical XML) → **NOT in this runbook** — separate follow-up (the canonical XML it consumes is now in Git, `0a6e3dcd`). Flagged so it isn't assumed done.
- nic_tuning exclusion → self-gates (no edit). ✓
