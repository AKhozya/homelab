---
name: k3s-upgrade
description: >-
  Use when upgrading or updating the k3s VERSION on the homelab cluster (e.g. "update k3s",
  "upgrade k3s to 1.38", "bump kubernetes version"), when a Renovate PR for k3s-io/k3s appears,
  or when a k3s upgrade fails or needs a rollback. `k3s_version` in
  node-maintenance/ansible/group_vars/all.yml pins the version; Renovate bumps it, and merging the
  PR upgrades every node through the drift-heal and the sanctioned rolling restart (no reboot,
  zero pod disruption). Covers merging, the minor-version gate, watching, verifying and rollback.
  NOT for node OS/package updates or reboots → cluster-reboot skill. NOT for pod recycling →
  cluster-roll skill.
---

# k3s-upgrade

pacman does not manage k3s, and phase1/phase2 never changes it. The rolling restart installs
`k3s_version` at `/usr/local/bin/k3s` on each node. `node-maintenance/README.md` § "K3s version" in
the homelab repo is the reference for the mechanism.

| Node | Role | Note |
|---|---|---|
| `gmk-k3s-control-plane` | CP | upgrades first |
| `worker-node` | worker | |
| `worker-node-2` | worker | |
| `immich-vm` | GPU worker | a k3s service restart is safe; an in-guest reboot is forbidden |

## How an upgrade runs

| Step | What happens | Where to look |
|---|---|---|
| 1 | Renovate opens a PR that bumps `k3s_version`. Patch or `+k3sN`: once the release is at least 3 days old. Minor: only after the owner ticks it on the Dependency Dashboard (issue #32) | the PR |
| 2 | the PR merges (`~/.agents/skills/_shared/merge-worktree.sh`) | |
| 3 | within 10 min the CP sync pulls `main`; the drift-heal's last play compares each node's `kubeletVersion` with `k3s_version` | `/var/log/node-maintenance/config-latest.log`; Telegram "changed" |
| 4 | if the move is an allowed upgrade, the drift-heal starts `node-maintenance-rolling-restart.service`; it waits for the lock until the drift-heal exits (about 5 min) | `systemctl show node-maintenance-rolling-restart.service -p ActiveState` |
| 5 | preflight on the CP: refuses a skipped minor, a major change, a downgrade, or a node set that differs from the inventory; downloads the binary once to `/var/cache/node-maintenance/k3s/` and checks its sha256 | `/var/log/node-maintenance/rolling-restart-latest.log` |
| 6 | per node, CP first, one at a time: swap the binary in (old one kept as `k3s.prev`), restart, wait for `k3s_version` + Ready + a heartbeat newer than the restart, check `configz`, pause 30 s | same log; Telegram on failure |

## Procedure

1. **If the PR is a minor**: read the k3s release notes and the Kubernetes changelog for removed
   APIs first. A minor cannot be rolled back. Then tick the Dashboard box; do not merge yet.
2. **Checkpoint**: `/checkpoint create pre-k3s-<ver>`.
3. **Merge** the PR. If Renovate has not proposed the version you want, edit `k3s_version` in a
   worktree, commit, and merge it the same way.
4. **Watch.** Expect the drift-heal within about 15 min of the merge, then the rolling restart
   (3-7 min of work, plus up to 15 min waiting for the lock). This loop prints one line per change
   and exits when the unit is no longer active:
   ```bash
   prev=""
   while true; do
     st=$(ssh -o ConnectTimeout=10 -p 65300 akhozya@gmk-k3s-control-plane 'systemctl show node-maintenance-rolling-restart.service -p ActiveState -p Result --value' 2>&1 | tr '\n' ' ' || true)
     vers=$(kubectl get nodes --request-timeout=10s -o jsonpath='{range .items[*]}{.metadata.name}={.status.nodeInfo.kubeletVersion}/{.status.conditions[?(@.type=="Ready")].status} {end}' 2>&1 || echo "kubectl-unreachable")
     cur="unit=[$st] nodes=[$vers]"
     if [ "$cur" != "$prev" ]; then echo "$(date -u +%H:%M:%S) $cur"; prev=$cur; fi
     case "$st" in inactive*|failed*) echo "DONE $st"; break;; esac
     sleep 20
   done
   ```
   If you start the loop before the drift-heal queues the unit, it exits at once on `inactive`.
   Start it once `ActiveState` is `activating`.
5. **Verify**: the watch loop ended with `DONE inactive success`; every node reports the new
   `kubeletVersion`; then
   `bash ~/.agents/skills/cluster-reboot/scripts/watch-reboot.sh --once` and
   `/checkpoint verify pre-k3s-<ver>`.

## Failure and rollback

| Case | What to do |
|---|---|
| the drift-heal fails with `refused (skip-minor)` or `refused (downgrade)` | the pin skips a minor, changes the major, or goes backwards. Fix `k3s_version` in git |
| the drift-heal fails with `refused (invalid)` | the message lists the running versions. If `k3s_version` does not match `vX.Y.Z+k3sN`, fix it in git. If a node shows `""`, find out why it reports no version (`kubectl get node <name> -o yaml`). If the node names differ from `node-maintenance/ansible/inventory.yml`, fix the cluster membership or the inventory |
| the rolling restart fails while some node still runs the old version | Telegram reports it; read the log above. The next drift-heal (03:00, 15:00 or a new SHA) starts it again |
| the rolling restart fails after every node reports `k3s_version` (a Ready, heartbeat or `configz` check on the last node) | the next drift-heal sees `same` and does not retry. Fix the cause, start the unit by hand (`sudo systemctl start --no-block node-maintenance-rolling-restart.service` on the CP), if `ActiveState` is `activating`, run the watch loop from step 4 until it prints `DONE inactive success`. If you start the loop before the unit enters `activating`, it reads the previous run's result. Then repeat step 5 |
| patch rollback | revert the PR and merge the revert. Wait until the CP holds the old pin: `ssh -p 65300 akhozya@gmk-k3s-control-plane "grep '^k3s_version:' /etc/node-maintenance/ansible/group_vars/all.yml"` prints the target. Every drift-heal then fails with `downgrade`. Run on the CP: `sudo /usr/local/sbin/node-maintenance-lock.sh wait -- ansible-playbook /etc/node-maintenance/ansible/rolling-restart-k3s.yml -i /etc/node-maintenance/ansible/inventory.yml -e k3s_allow_downgrade=true` |
| minor rollback | not supported: Kubernetes does not support a control-plane downgrade. Restore from backup (`docs/disaster-recovery/README.md`) |

The override allows only a patch or `+k3sN` downgrade, and only if every node shares the target's
major.minor.

| Command check | Result |
|---|---|
| the rollback command, in a `--check` run on 2026-10-08 | ends preflight (`ok=8`); the downgrade itself has not run |
| `--check` on the rolling restart beyond preflight | fails at the first node: its wait and `configz` steps read the output of commands that check mode skips. The playbook behaves the same way before PR #1255. Do not use `--check` on it |

## Why this path

| Rejected | Reason |
|---|---|
| staging the binary ahead of the restart (the old `stage-k3s.sh`) | the weekly reboot and the heal watchdogs (`clusterip_heal`, `clusterip_heal_cp`, `node_isolation_heal`) also restart k3s. They would activate a staged binary on that node alone, possibly a worker before the CP |
| re-running the get.k3s.io `install.sh` | all k3s settings live in the ansible-managed `/etc/rancher/k3s/config.yaml`, so the script only rewrites the unit and env file. On a worker it needs `K3S_URL` and the join token, or it installs a server (v1.37.1 copy, lines 178-182). It rewrites the env file from the shell's `K3S_*` variables (line 1027). It restarts k3s at once (line 1145) |
| system-upgrade-controller | its Plan `ContainerSpec` has no `resources` field, and `require-resource-limits` (Deny) autogens to Jobs, so admission refuses its Jobs without a cluster-wide policy exception. It also runs outside the node-maintenance lock |
| a shell `cp` over `/usr/local/bin/k3s` | fails with `Text file busy` while k3s runs; ansible `copy` renames a temp file into place |

## Measured

| Date | Run | Result |
|---|---|---|
| 2026-06-05 | v1.35.3 → v1.36.1, Mac-side staging, 3 nodes | zero pod disruption, about 10 min |
| 2026-10-07 | v1.37.0 → v1.37.1, Mac-side staging, 4 nodes | zero pod disruption; 2.5 min of work after a 5 min lock wait |
| 2026-10-08 | first run of the version-pin playbook (PR #1255), config-only | download and swap skipped on every node; the heartbeat wait used 1-15 of 30 retries (worker-node: the new heartbeat came 81 s after the restart) |
| 2026-10-08 | the watch loop above, run verbatim | printed one line and exited on `inactive` |

| Leftover | Where | Cleanup |
|---|---|---|
| one binary per version, about 80 MB each | `/var/cache/node-maintenance/k3s/` on the CP | none; remove old versions by hand |
| the previous binary | `/usr/local/bin/k3s.prev` on each node | none; the next upgrade overwrites it |

## Cross-refs

- `cluster-reboot` — node OS updates + reboots (phase1/phase2), wedge surfaces, watch-reboot.sh.
- `/checkpoint` — pre/post state snapshot.
- `/homelab-node-fix` — if a node misbehaves after the restart (faillock, drift-heal).
