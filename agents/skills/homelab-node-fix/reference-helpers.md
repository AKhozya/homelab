# Homelab Node Fix — access and helper details

Read this when you connect to the NAS, need the steps or exit codes of `run-on-node.sh`, check which tools a node has, or need the maintenance timer schedule.

## NAS access

The backup-sink NAS is reachable but is **out of this skill's scope** — it's a ZettLab/zettOS appliance (Debian 12, `192.168.1.136`), **not Arch, not k3s, not ansible/UFW-managed**.

- Access: `ssh zl-nas` (port `56634`, user `akhozya`, file key `~/.ssh/zl_nas_ed25519` — *not* the 1Password agent).
- **sudo needs the account password** (no NOPASSWD): user runs `! ssh -t zl-nas 'sudo …'` (TTY, types password live). Same pattern as the node sudo rules in SKILL.md, different host.
- Posture/identity facts: memory `reference_nas`.

## run-on-node.sh steps

The helper:
1. Runs `shellcheck` on the local script (pre-flight gate, per `/bash-scripting`)
2. `scp -P 65300` to `/tmp/<name>-$$` on the remote
3. `ssh -p 65300 -t` to exec via `bash <remote-path> $args` (TTY for sudo)
4. Always `rm` the remote script on EXIT (trap-based)

## Exit codes (helper script)

- `0` success
- `2` bad args / unknown SSH alias
- `3` local script missing
- `4` shellcheck failed (pre-flight gate)

## Tools on each node

Tools checked 2026-09-28:

| Tool | CP, worker-node, worker-node-2 | immich-vm |
|---|---|---|
| `jq`, `yq`, `jc`, `fd` | present | present |
| `rg` | absent | present |

## Maintenance schedules

Schedules already running per `project_maintenance_schedules.md`:
- sync 10min
- drift-heal 03:00 and 15:00 UTC
- drift-heal after each sync that applies a new SHA
- weekly Sat 04:30 (pacman update incl. AUR via yay `-Syyu`)
- security scan 1st of month

## Read-state example commands

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
