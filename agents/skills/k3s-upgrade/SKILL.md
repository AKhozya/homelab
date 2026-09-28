---
name: k3s-upgrade
description: >-
  Use when upgrading or updating the k3s VERSION on the homelab cluster (e.g. "update k3s",
  "upgrade k3s to 1.37", "bump kubernetes version"). k3s is a manual binary at /usr/local/bin/k3s —
  NOT pacman/yay-managed, so the phase1/phase2 node-update flow does NOT bump it and renovate does
  not see it. Covers version pick (channels API), binary staging (no install script, no token),
  activation via the sanctioned rolling restart (no reboot, zero pod disruption), verification, and
  rollback caveats. NOT for node OS/package updates or reboots → cluster-reboot skill. NOT for pod
  recycling → cluster-roll skill.
---

# k3s-upgrade

Binary-swap upgrade of k3s across the 4 nodes (CP `gmk-k3s-control-plane`, W1 `worker-node`,
W2 `worker-node-2`, GPU worker `immich-vm` — service restart is safe there, only in-guest REBOOT
is forbidden). Validated 2026-06-05 (v1.35.3 → v1.36.1, 3 nodes then): zero pod disruption, ~10 min total.

## Why this path (traps that motivated it)

| Trap | Reality |
|---|---|
| "phase1/phase2 or yay updates k3s" | NO — k3s is a manual binary install (`pacman -Qi k3s` = empty). OS updates never touch it. |
| "re-run get.k3s.io install script" | On AGENTS it rewrites systemd units and demands `K3S_URL`/`K3S_TOKEN`. Binary swap needs **neither** — agents stay joined (token persisted in `k3s-agent.service.env` + `/var/lib/rancher/k3s/agent/`). |
| "need node-token from CP" | Only for (re)JOINING via install script. Upgrade-in-place = never. |
| "needs reboot" | No. `systemctl restart k3s(-agent)` activates the new binary; containerd keeps pods running — only the control process bounces. |
| "restart workers in parallel" | Same wedge class as reboots (2026-05-24). Use the serial sanctioned service, CP first. |

## Procedure

1. **Pick version** (server must activate before agents — CP-first order below handles skew):
   ```bash
   curl -s https://update.k3s.io/v1-release/channels | jq -r '.data[] | select(.id=="stable" or .id=="latest") | "\(.id): \(.latest)"'
   ```
   Ask user: stable patch vs latest minor. Check current: `kubectl get nodes -o custom-columns='N:.metadata.name,V:.status.nodeInfo.kubeletVersion'`.

2. **Checkpoint**: `/checkpoint create pre-k3s-<ver>`.

3. **Pre-verify op** (faillock-safe, spends no sudo; popup must be approved — run FOREGROUND):
   ```bash
   op read 'op://Personal/sudo-homelab/password' >/dev/null && echo OP-OK
   ```

4. **Stage** (download + sha256 verify + per-node `install -m755`, old binary kept at `k3s.prev`):
   ```bash
   K3S_VERSION=v1.XX.Y+k3s1 bash ~/.agents/skills/k3s-upgrade/scripts/stage-k3s.sh --dry-run   # checksum sanity
   K3S_VERSION=v1.XX.Y+k3s1 bash ~/.agents/skills/k3s-upgrade/scripts/stage-k3s.sh
   ```
   Staging is inert — running services keep the old in-memory binary.

5. **Activate** — sanctioned serial restart (CP→workers incl. immich-vm, Ready gate per node, ~6 min,
   `phase2-pending` guard, telegram on fail). Single sudo attempt:
   ```bash
   sudo_pw="$(op read 'op://Personal/sudo-homelab/password')" && [ -n "$sudo_pw" ] && \
     printf '%s\n' "$sudo_pw" | ssh -p 65300 akhozya@gmk-k3s-control-plane \
     "sudo -S -p '' systemctl start node-maintenance-rolling-restart.service"
   ```
   Blocks until done (oneshot, 25 min cap). Brief kubectl API blip during CP restart = normal.

   Since `f3c6abd7` (2026-08-08) the unit runs under `node-maintenance-lock.sh wait --`, so it
   queues behind a drift-heal instead of running beside it — up to 15 min of silence before ansible
   starts, then ~6 min of work. Unlocked it shared root's ansible SSH ControlMaster with the
   concurrent heal, and the heal finishing first killed the in-flight task: `UNREACHABLE … Data
   could not be sent to remote host`, exit 4, though the restart had already run. Any push to
   homelab `main` arms a drift-heal within 10 min via the sync timer, so this is the normal case
   right after a commit, not an edge one. Prefer `--no-block` + poll `ActiveState` over a
   foreground call that can outlive the Bash timeout.

6. **Verify**: all nodes converge on new `kubeletVersion`; then
   `bash ~/.agents/skills/cluster-reboot/scripts/watch-reboot.sh --once` (3-surface wedge check)
   + `/checkpoint verify pre-k3s-<ver>`.

## Rollback

`/usr/local/bin/k3s.prev` holds the previous binary — but **minor-version sqlite/etcd state
migrations are NOT cleanly reversible**; treat a minor downgrade as restore-from-backup territory
(`docs/disaster-recovery/README.md`). Patch-level rollback: swap back + rolling restart. Cleanup after ~a week
stable: `sudo rm /usr/local/bin/k3s.prev` per node.

## Cross-refs

- `cluster-reboot` — node OS updates + reboots (phase1/phase2), wedge surfaces, watch-reboot.sh.
- `/checkpoint` — pre/post state snapshot.
- `/homelab-node-fix` — if a node misbehaves post-restart (faillock, drift-heal).
