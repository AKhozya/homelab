---
name: homelab-node-fix
description: "Use when fixing or debugging issues on homelab nodes (gmk-k3s-control-plane, worker-node, worker-node-2, immich-vm) — pacman lock, systemd service failure, disk pressure, NIC drop, kernel oops, journalctl error, package install, sudo-required ops, pam_faillock lockout / sudo locked out, UFW disabled cascade, NAS / zl-nas access. Provides SSH workflow with TTY password prompt (user enters live, output flows back), scp+exec+cleanup for multi-line scripts, drift-heal routing through ansible node-maintenance services, faillock recovery via CP+ansible bypass, monthly security-scan helpers. Cross-refs /bash-scripting for script standards, /k8s-diagnostics for cluster-side symptoms, /monitoring-check for VMAgent stuck after node fix."
user-invocable: false
---

# Homelab Node Fix / Debug

SSH-based diagnose + fix workflow for homelab nodes (Arch Linux on all 4).

## Decision tree — where does the fix belong?

1. **Cluster-side symptom** (pod crashloop, NetworkPolicy block, image pull) → use `/k8s-diagnostics`, NOT this skill.
2. **Node OS state** (systemd, pacman, journalctl, dmesg, ip/ss/ufw, disk) → this skill.
3. **Persistent config drift** (a file you'd want to survive `chezmoi update` / ansible reapply) → fix in ansible role at `node-maintenance/`, then trigger drift-heal (§ Drift-heal routing), NOT one-shot SSH.
4. **A known incident** (UFW down, sudo locked out, post-reboot ClusterIP/DNS wedge, pacman/ansible race, monthly security-scan noise) → load `reference-incidents.md` and follow the matching playbook (§ Incident playbooks).

## SSH conventions

- Prefer alias `ssh_master_node` / `ssh_worker_node` / `ssh_worker_node2` (note: no dash before 2 in the worker-node2 alias). Tell the user these.
- GPU worker: `ssh -p 65300 akhozya@immich-vm` (no zsh alias). **NEVER in-guest reboot / `virsh destroy`** — GPU-passthrough reset-bug wedges the NAS host; phase2 carve-out handles reboots. Service restarts fine. Wedge forensics: memory `gotcha_immich_vm_virtio_gpu_fbdev_wedge`.
- Direct invoke from a script: raw `ssh -p 65300 <user>@<host>` — zsh aliases are not visible to bash subshells.
- Use `127.0.0.1`, not `localhost`, in scratch images.

### NAS (`zl-nas`) — adjacent host, NOT a cluster node
The backup-sink NAS is reachable but is **out of this skill's scope** — it's a ZettLab/zettOS appliance (Debian 12, `192.168.1.136`), **not Arch, not k3s, not ansible/UFW-managed**. Do NOT apply drift-heal / node-maintenance / UFW playbooks to it.
- Access: `ssh zl-nas` (port `56634`, user `akhozya`, file key `~/.ssh/zl_nas_ed25519` — *not* the 1Password agent).
- **sudo needs the account password** (no NOPASSWD): user runs `! ssh -t zl-nas 'sudo …'` (TTY, types password live). Same pattern as below, different host.
- Posture/identity facts: memory `reference_nas`.

## Read state — no sudo needed

Read commands return output directly to the agent context.

```bash
# Service status / recent failures
ssh -p 65300 akhozya@gmk-k3s-control-plane "systemctl --failed --no-pager"
ssh -p 65300 akhozya@gmk-k3s-control-plane "journalctl -xeu k3s --no-pager -n 80"

# Disk / memory
ssh -p 65300 akhozya@gmk-k3s-control-plane "df -h | jc --df"   # JSON via jc
ssh -p 65300 akhozya@gmk-k3s-control-plane "free -h"

# NIC / link / drops (igc gotcha — see memory)
ssh -p 65300 akhozya@gmk-k3s-control-plane "ip -s link show enp89s0"
ssh -p 65300 akhozya@gmk-k3s-control-plane "ethtool -S enp89s0 | grep -iE 'drop|err'"

# Pacman lock / mirror state
ssh -p 65300 akhozya@gmk-k3s-control-plane "ls -la /var/lib/pacman/db.lck 2>/dev/null"
```

**Force mirror DB refresh** (after 404 on install — see incident 2026-05-14):
```bash
bash ~/.agents/skills/_shared/pacman-cache-refresh.sh ssh_master_node
```
Wraps `sudo pacman -Syy` via `ssh -t` — user enters password live.

## Sudo — give command to user, never run directly

Agents have no sudo. For any privileged op:

```bash
# Print this for user to paste — do NOT call Bash with it.
ssh -p 65300 -t akhozya@gmk-k3s-control-plane "sudo systemctl restart k3s"
```

`-t` forces TTY so the sudo password prompt appears in the user's terminal. User enters password live; output flows back to the terminal AND the agent (via the Bash tool result if they invoked it for you).

**Claude Code `!` prefix has NO TTY.** `! ssh -t ... sudo ...` cannot accept password — sudo fails with "a terminal is required". User must run the same command in their own terminal app, OR use `op read` to inject password non-interactively (`op read 'op://Personal/sudo-<node>/password' | ssh ... 'sudo -S ...'`).

**Anti-patterns** (from prior incidents):
- ❌ `sudo -n ...` — fails non-interactive, pam_faillock risk
- ❌ Inline sudo password — never
- ❌ Raw IPs — SSH key host-mismatch
- ❌ `cd dir && cmd` — breaks safe-bash allow patterns; use `git -C dir` or absolute paths
- ❌ Combining Write/chmod/lint in one Bash call — Claude Code auto-classifier blocks "unverifiable script execution". Split into 2-3 calls (Write → chmod alone → lint).

## Multi-line fix — write local, scp, exec, cleanup

For anything beyond ~5 lines, do NOT inline in `ssh "..."`. Write a local script, lint it, scp + run + cleanup via the helper:

```bash
bash ~/.agents/skills/homelab-node-fix/scripts/run-on-node.sh \
  ssh_master_node \
  ./fix-pacman.sh
```

The helper:
1. Runs `shellcheck` on the local script (pre-flight gate, per `/bash-scripting`)
2. `scp -P 65300` to `/tmp/<name>-$$` on the remote
3. `ssh -p 65300 -t` to exec via `bash <remote-path> $args` (TTY for sudo)
4. Always `rm` the remote script on EXIT (trap-based)

**Script body conventions** — use `/bash-scripting` skill:
- `set -euo pipefail`
- Brew tools assumed installed remotely (Arch nodes have `jq`, `yq`, `jc`, `rg`, `fd` per ansible packages role)
- Idempotent where possible (`systemctl is-active X || systemctl start X`)
- Print summary to stderr; data to stdout

## Drift-heal routing — when fix belongs in ansible

If the fix would otherwise drift back on next ansible reapply, push it through the role instead:

1. Edit role at `node-maintenance/ansible/roles/<role>/`
2. Lint locally on CP (CP-hosted tools per CLAUDE.md):
   ```bash
   cat <file.yml> | ssh -p 65300 akhozya@gmk-k3s-control-plane \
     "cat > /tmp/lint.yml && yamllint -d '{extends: relaxed, rules: {line-length: disable}}' /tmp/lint.yml"
   cat <file.sh>  | ssh -p 65300 akhozya@gmk-k3s-control-plane \
     "cat > /tmp/lint.sh && shellcheck /tmp/lint.sh"
   ```
3. Commit + push to homelab repo.
4. Trigger services (give user the commands — they need sudo):
   ```bash
   ssh -p 65300 -t akhozya@gmk-k3s-control-plane \
     "sudo systemctl start node-maintenance-sync.service"     # git pull
   ssh -p 65300 -t akhozya@gmk-k3s-control-plane \
     "sudo systemctl start node-maintenance-config.service"   # drift-heal apply
   ```

Schedules already running per `project_maintenance_schedules.md`:
- sync 10min
- drift-heal 03:00
- weekly Sat 04:30 (pacman update incl. AUR via yay `-Syyu`)
- security scan 1st of month

### Staged / single-node node-config changes (DNS, NIC, anything load-bearing)
Both the 10-min sync timer AND a manual sync heal **ALL 4 nodes at once** (`install.sh --sync-only` is NOT file-copy-only). To stage one node at a time: stop-timers → deploy-key fetch on CP → per-node `ansible-playbook --limit --tags` → restore timers. Full playbook (exact commands + why `mask` fails + deploy-key `GIT_SSH_COMMAND`): `reference-incidents.md` § "Staged / single-node node-config changes". Proven 2026-06-04.

## Incident playbooks — load `reference-incidents.md`

When one of these fires, load `reference-incidents.md` and follow the matching playbook — don't improvise. Each section there carries the full recovery sequence + the why.

| Symptom / alert | Playbook (`reference-incidents.md` §) | Memory |
|---|---|---|
| `UfwDisabled` (worker, post-reboot/module drift); alert won't clear after heal | UFW drift heal | — |
| sudo locked out / `pam_faillock` `deny=3` | Pam_faillock recovery | — |
| post-reboot pod crashloop, ClusterIP/DNS dead, `exit=1` sync cascade, NVMe name flip | Rolling reboot fallout | `[[gotcha_k3s_reboot_ordering]]` |
| ansible play `templar=` / `VaultDecryptionContext` TypeError mid-pacman | Drift-heal vs pacman race | `[[gotchas]]` |
| rkhunter property-change warnings after pacman | Monthly security scan | `security_scan_gotchas.md` |

Faillock helper: `~/.agents/skills/_shared/faillock-via-cp.sh <worker-node|worker-node-2> [akhozya|z3us]` — resets pam_faillock for the locked user via CP-hosted ansible (worker NOPASSWD bypass; user enters the CP sudo password once).

## Cross-refs

- `/bash-scripting` — script body standards (mandatory before scp)
- `/k8s-diagnostics` — if symptom is cluster-side, not node OS
- `/monitoring-check` — if you need VMSingle metrics on the node (e.g. CPU throttling), or an alert won't clear after a heal
- `~/source-code/homelab/CLAUDE.md` — SSH aliases, sudo-over-SSH rule, ansible structure

## Exit codes (helper script)

- `0` success
- `2` bad args / unknown SSH alias
- `3` local script missing
- `4` shellcheck failed (pre-flight gate)
