# Homelab Node Fix — incident playbooks

Per-symptom recovery recipes + the why, behind SKILL.md's symptom→section routing table.

## UFW drift heal (worker nodes — incident pattern)

When `UfwDisabled` alert fires (typical on `worker-node` after reboot or ip6tables module drift), the 3-layer recovery sequence is:

**Before reverting anything**: check the cascade. The "alert still firing" after heal is often not UFW — it's VMAgent stuck. See `/monitoring-check` § "VMAgent stuck remoteWrite". Pattern: heal succeeds (`ENABLED=yes`, probe healthy), local metric file = 1, but alert keeps firing because vmagent's Go DNS resolver cached a failed CoreDNS lookup during the UFW chain rebuild window. Fix = `kubectl rollout restart deploy vmagent-vmagent -n monitoring`. Cheap, safe.

Also expect a ~3-5 min state-metric staleness window during heal: textfile is rewritten only every 60s, then VMAgent scrape + VMSingle ingest + 5m `for:` window in the rule = up to ~7 min before alert clears even when everything's healthy.

1. **Verify ip6tables module loaded** (UFW depends on it; module drift after kernel update breaks UFW):
   ```bash
   ssh -p 65300 akhozya@worker-node "lsmod | grep -E 'ip6_tables|iptable'"
   ssh -p 65300 -t akhozya@worker-node "sudo modprobe ip6_tables iptable_filter iptable_nat"
   ```
2. **Wait for k3s to be ready before re-enabling UFW** (UFW rule load races k3s iptables setup):
   ```bash
   ssh -p 65300 akhozya@worker-node "systemctl is-active k3s-agent && echo READY"
   ```
3. **Re-enable + verify**:
   ```bash
   ssh -p 65300 -t akhozya@worker-node "sudo ufw --force enable && sudo ufw status verbose"
   ```

**Persistent fix — ALREADY SHIPPED (do not re-build):** the v3 stack covers this class — L1 modules-load.d, L2 k3s-wait-ready, L3 ufw-heal-post-k3s, L4 `firewall_preflight` role (memory `gotchas.md` § UFW). Later hardening: `ufw reload` gated on `repaired>0` (`ff2b486b`, 2026-07-10 — unconditional reload dropped W2's k3s tunnel, memory `gotcha_ufw_reload_node_isolation`) + `node_isolation_heal` watchdog. The manual steps above remain the break-glass when the stack itself is down.

## Pam_faillock recovery (when sudo gets locked out)

Default Arch PAM: `deny=3 unlock_time=600` per user. 3 failed sudo attempts → 10 min lock. Each new attempt during lock RESETS the timer.

Diagnose (no sudo needed):
```bash
ssh -p 65300 <user>@<node> "faillock --user <user>"
```

**Recovery options (fastest first):**

1. **Bypass via CP + ansible** (zero wait — uses node-maintenance NOPASSWD on workers):
```bash
ssh -p 65300 -t akhozya@gmk-k3s-control-plane \
  "sudo ansible <node> -i /etc/node-maintenance/ansible/inventory.yml -m shell -a 'faillock --user <user> --reset' --become"
```
One sudo prompt — on CP (akhozya@CP). CP and worker faillock are independent files (`/run/faillock/<user>`), so CP sudo is unaffected by worker lock.

2. **Wait for auto-unlock** (~10 min from last fail). Don't retry sudo during window — resets timer.

3. **Console reset** (physical or BMC): boot to root, `faillock --user <user> --reset`. Last resort.

**Anti-patterns:**
- ❌ `sudo -k && sudo ...` in script via `!` prefix — no TTY → silent fail → 3 strikes → lockout
- ❌ `sudo -n ...` over SSH — non-interactive sudo without cached creds → fail → counter ticks
- ❌ Pasting wrong sudo password 3x in a row — instant lockout
- ✅ Use `op read 'op://Personal/sudo-<node>/password'` to inject correct password if 1Password item exists

## Rolling reboot fallout (2026-05-24 incident)

Rebooting nodes too fast (next rebooted before previous fully `Ready`) or in bulk surfaces three traps. All three hit at once on 2026-05-24.

**1. kube-proxy ClusterIP wedge — symptom looks cluster-side, fix is node-side.**
Worker kube-proxy fails to (re)program service iptables after a too-tight rolling reboot. Diagnosis tell: CP `:6443` returns 401 (API healthy) BUT in-cluster `ClusterIP 10.43.0.1:443` times out → pods crashloop on connection refused/timeout. Fix = restart the agent (give user, needs sudo):
```bash
ssh -p 65300 -t akhozya@worker-node "sudo systemctl restart k3s-agent"
```
Prevention: space reboots until each node is fully `Ready`, not just `uptime > 2min`. Full detail: [[gotcha_k3s_reboot_ordering]].

**1b. CNI portmap masquerade wedge — host-netns probes are BLIND to it (2026-05-30).** Distinct from 1: here kube-proxy is fine (`10.43.0.1:443`→401, `:10256`→200, `verify-clusterip.sh` reads GREEN) yet pod→ClusterIP/DNS is dead cluster-wide (CoreDNS `0/1`, mass crashloop on DNS i/o timeout). Cause: UFW boots disabled → `ufw-heal` `flush-all` runs `iptables -t nat -F POSTROUTING`, deleting `-j CNI-HOSTPORT-MASQ`; flannel + kube-proxy re-add their jumps, **portmap does not** (k8s#93091). Diagnosis tell (ROOT, no host-netns probe works): `sudo iptables -t nat -S POSTROUTING | grep CNI-HOSTPORT-MASQ` → missing = wedged. Same fix (`sudo systemctl restart k3s-agent` rebuilds CNI chains). Now AUTO-HEALED: phase2 PLAY 1 nat-jump gate + `ufw-heal` phase-G (worker-only). Full detail: [[gotcha_k3s_reboot_ordering]].

**2. NVMe device names are non-deterministic across reboots.**
`/dev/nvme0n1` ↔ `/dev/nvme1n1` enumeration flips on PCIe probe order. NEVER pin a raw `/dev/nvmeXn1pY` in ansible `host_vars` (swap_path, mounts) — it silently breaks after a reboot and tempts a "fix" that just flips the number back (W1 swap flip-flopped twice: `c836a618`/`68bbf6fe`, re-fixed `2ff39465`). Use the stable symlink: `/dev/disk/by-uuid/<uuid>` (the verify task `readlink -f` resolves it to the current device). LVM paths (`/dev/<vg>/<lv>`) and file paths (`/swapfile`) are already stable.

**3. `node-maintenance-sync failed (exit=1)` is usually a CASCADE, not a git problem.**
The sync service runs an initial drift-heal (`node-maintenance-config.service`) after `git pull`. If that drift-heal fails, sync reports `exit=1` even though `git pull` succeeded. Don't chase git — read the config service first:
```bash
ssh -p 65300 akhozya@gmk-k3s-control-plane "journalctl -u node-maintenance-config.service --no-pager -n 60 | grep -iE 'fatal|failed=|PLAY RECAP|TASK \['"
```
The real failing task name is in there (e.g. `Verify swap active`). The deployed ansible copy lives at `/etc/node-maintenance/ansible/` (rsync'd by install.sh) and can lag the repo if a prior sync aborted — a stale rendered value in an alert (`path=/swapfile`) can come from that lag.

## Staged / single-node node-config changes (DNS, NIC, anything load-bearing)

`node-maintenance-config.service` runs `node-config.yml` across **ALL hosts** (push from CP via SSH), and `node-maintenance-sync.service` runs `install.sh --sync-only` which is **NOT file-copy-only** — it re-enables `config.timer` + `systemctl start --wait node-maintenance-config.service` (install.sh lines 158/164) = a full all-host heal (~5 min, blocking). So both the 10-min timer AND a manual sync apply to all 4 nodes at once. To stage one node at a time (verify before the next):

1. Stop the timers so the auto-heal can't race: `systemctl stop node-maintenance.timer node-maintenance-sync.timer node-maintenance-config.timer`. (`systemctl mask` FAILS — the units are real files in `/etc/systemd/system/`: "File already exists". `stop` + services already `disabled` suffices; just don't reboot mid-window.)
2. Update the CP checkout WITHOUT triggering a heal (do NOT run `install.sh --sync-only`):
   ```bash
   export GIT_SSH_COMMAND="ssh -i /root/.ssh/homelab-deploy -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/node-maintenance/github_known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes"
   git -C /var/lib/node-maintenance/homelab fetch --depth=50 origin main
   git -C /var/lib/node-maintenance/homelab reset --hard origin/main
   rsync -a --delete /var/lib/node-maintenance/homelab/node-maintenance/ansible/ /etc/node-maintenance/ansible/
   ```
   (plain `git fetch` as root fails `Permission denied (publickey)` — needs that deploy-key `GIT_SSH_COMMAND`. Clone lives at `/var/lib/node-maintenance/homelab`; installed copy at `/etc/node-maintenance/ansible`.)
3. Apply per node, verify between each: `cd /etc/node-maintenance/ansible && ansible-playbook -D -i inventory.yml node-config.yml --limit <node> --tags <tag>` (prefix with `--check` for a dry-run first). Tag your new tasks so `--tags` scopes to just your change (skips firewall/etc).
4. Restore: `systemctl enable --now node-maintenance.timer node-maintenance-sync.timer node-maintenance-config.timer`. Next auto-heal is idempotent (`changed=0`).

Proven 2026-06-04 (DNS decoupling): using `install.sh --sync-only` ran a full all-host heal that bypassed the intended staged W2→W1→CP rollout. See `[[gotcha_k3s_reboot_ordering]]`.

## Drift-heal vs pacman race (2026-05-22, commit 3b5696d7)

Concurrent `pacman -Syu` (manual OR `yay -Syu` inside same ansible-playbook) that upgrades `ansible-core` mid-flight breaks the playbook: action plugins reload from new core (e.g. `copy.py` passing `templar=` kwarg) while `ConfigManager` singleton stays on old import → `unexpected keyword argument 'templar'` TypeError. Co-symptom: `cannot import name 'VaultDecryptionContext' from 'ansible._internal._yaml._dumper'` kills `ansible.builtin.core` filter set.

Two guards in place — usually you don't touch these, but know they exist:

- **drift-heal** (`node-maintenance-config.service`): second `ExecCondition=/bin/sh -c '[ ! -e /var/lib/pacman/db.lck ]'`. Drift-heal cycle skips when pacman DB lock present. Verify via `systemctl status node-maintenance-config.service` — see ExecCondition line. If user ran manual `pacman -Syu` and drift-heal seems skipped, that's working as designed; next 10-min cycle catches up.
- **phase1** (`node-maintenance-phase1.service`): `ExecStartPre=/usr/bin/pacman -Sy --noconfirm --needed ansible ansible-core` runs BEFORE `ansible-playbook`. Pre-upgrades ansible runtime so `yay -Syu` inside the play finds it current → no mid-flight bump. If phase1 fails at ExecStartPre with pacman lock error → another pacman is running; let it finish, retry phase1.

Don't pin/downgrade ansible packages — Arch rolling. Race is timing, not version. See [[gotchas]] memory entry "Ansible mid-play runtime upgrade race".

## Monthly security scan — post-pacman noise filter

After pacman upgrade, rkhunter flags property changes as warnings. Expected drift — refresh baseline:

```bash
ssh -p 65300 -t akhozya@gmk-k3s-control-plane "sudo rkhunter --propupd"
```

Filter list (skip in alerts): see `security_scan_gotchas.md` memory. Common false positives after pacman: `/usr/bin/<binary>` property changes, prelinking timestamps, package version bumps.
