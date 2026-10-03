# cluster-reboot — trigger script and ansible phase detail

Read this when you need to know what `trigger-reboot.sh` checks before it runs sudo, or what each ansible play in phase1 and phase2 does.

## What trigger-reboot.sh checks

`trigger-reboot.sh` is **faillock-safe by construction**: it fetches the secret first and **aborts
before any sudo if `op read` is empty** (e.g. a dismissed popup), refuses to reboot through a running
drift-heal/sync or an in-flight run (`phase2-pending`), makes a **single** attempt, and never leaks
the password (op → shell var → ssh stdin, never argv/env/history). 1Password item:
`op://Personal/sudo-homelab/password` (shared sudo for the CP, worker-node and worker-node-2); override via `OP_SUDO_PATH` /
`CP_HOST` env.

## The phase1 → phase2 chain (brief — ansible is authoritative)

- **phase1** — CP self-update via `yay`; its `ExecStartPost` **reboots the CP**. Sets the
  `phase2-pending` flag so phase2 auto-runs once the CP is back.
- **phase2** (auto-runs after the CP returns) — 3 plays:
  - **PLAY 0 — CP stabilize.** First task is now a **CP loopback-LB gate** (127.0.0.1:6443), then
    normal CP stabilization.
  - **PLAY 1 — per-worker, `serial: 1`.** For each worker in turn: cordon → `yay` → reboot → wait
    Node Ready → **ClusterIP gate** (host-netns probe + k3s-agent rescue) → **nat-jump gate**
    (root: `-j CNI-HOSTPORT-MASQ` present in nat POSTROUTING + k3s-agent rescue — catches the CNI
    portmap wedge the host-netns probe misses, 2026-05-30) → settle + re-probe → uncordon →
    stabilize → observe. `serial: 1` means one worker at a time.
  - **PLAY 2 — post-tasks.** Flux reconcile, GC, alert checks, telegram notify, and **remove the
    `phase2-pending` flag** on success.

Minimum ansible commit containing the phase2 gate: see `reference-incidents.md` (checkout predating
it = gate absent, old wedge risk applies).

## The two scripts and how path A works

The cluster-reboot skill provides
`trigger-reboot.sh` (starts phase1 with sudo fetched from 1Password — faillock-safe, single-attempt)
and a no-sudo agent-side watcher (`watch-reboot.sh`).

The agent can start phase1 with `trigger-reboot.sh` without a live TTY: the script reads the shared
homelab sudo password from 1Password and pipes it to `sudo -S` over SSH.

A *successful*
sudo resets the faillock counter.

## What watch-reboot.sh reports

Each iteration reports, for all 4 nodes: `Node.Ready`, `verify-clusterip.sh` verdict, the CP loopback
probe (CP only), the `phase2-pending` interlock, the per-node `node_pkg_upgrade_success` verdict, and
a warn-only `pod-health.sh --count` baseline.

`watch-reboot.sh`
makes the stuck state visible (Ready-but-wedged worker + lingering `phase2-pending`).

Exit **0** only when ALL gates pass: all 4 nodes Ready + ClusterIP-healthy (the CP ClusterIP verdict
is advisory), the CP loopback healthy, kube-dns ready endpoints ≥ 1, the package upgrade verified
clean on every reporting node (`UNVERIFIED` counts as failure), the phase1/phase2 run idle, and
`phase2-pending` absent. Otherwise non-zero (keep
watching / remediate).
