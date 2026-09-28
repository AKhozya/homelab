# cluster-reboot — wedge surfaces + incident detail

Loaded on demand from `cluster-reboot/SKILL.md`. Deep diagnostic mechanics for the "Ready ≠ healthy" wedge surfaces — needed when diagnosing a stuck/aborted reboot, not on every routine fire. SKILL.md holds the trigger + watch flow; load this file when a node reports `Ready` but a probe or `watch-reboot.sh` shows a wedge, or when remediating an aborted PLAY 1.

## The four wedge surfaces (Ready ≠ healthy)

| Surface | Where | Probe | Wedged → fix |
|---|---|---|---|
| **Worker kube-proxy ClusterIP DNAT** (`10.43.0.1:443`) | each worker | `verify-clusterip.sh <host>` (exit 0 ok / 1 wedged / 2 bad-arg / 3 unreachable) | `ssh -t <worker> "sudo systemctl restart k3s-agent"`, where `<worker>` is an `~/.ssh/config` Host that carries user + port (multi-node → use `rolling-restart-k3s.yml`) |
| **CP k3s loopback loadbalancer** (`127.0.0.1:6443`) | CP only | `ssh gmk-k3s-control-plane 'curl -sS -m5 -k -o /dev/null -w %{http_code} https://127.0.0.1:6443/healthz'` → 401/200 = ok | `ssh -p 65300 -t akhozya@gmk-k3s-control-plane "sudo reboot"`. **`restart k3s` CAN hang here under CP-apiserver-unstable conditions (2026-05, gotcha_k3s_reboot_ordering) — so reboot for THIS surface; it returns cleanly when the CP is otherwise healthy (2026-06-29), hence `timeout`-guard it if ever scripted.** |
| **CNI portmap masquerade** (`CNI-HOSTPORT-MASQ` jump in nat POSTROUTING) | each worker | ROOT only: `iptables -t nat -S POSTROUTING \| grep -q -- '-j CNI-HOSTPORT-MASQ'`. NO host-netns probe sees it. No-sudo SYMPTOM: `watch-reboot.sh` kube-dns ready-endpoint count = 0. | `ssh -t <worker> "sudo systemctl restart k3s-agent"` (rebuilds CNI nat chains). Auto-healed: phase2 PLAY 1 nat-jump gate + ufw-heal phase-G. |
| **CP pod-netns ClusterIP DNAT** (`10.43.0.1`/`10.43.0.10` from a CP **pod**) | CP only | host-netns probe is BLIND (reads 000 even healthy — so the `watch-reboot.sh`/`verify-clusterip.sh` CP verdict is advisory). REAL probe = `nsenter -t <coredns-pid> -n curl -sk https://10.43.0.1:443/healthz` → 401/200 ok, 000 wedged (what `clusterip_heal_cp`'s `clusterip-probe-cp.sh` does). | `sudo systemctl restart k3s` (reprograms kube-proxy DNAT, ~30-60s; CAN hang under apiserver-unstable → `timeout`-guard). **Auto-healed: `clusterip_heal_cp` watchdog** (CP-only, OnBoot 2min + every 3min, `timeout 120 systemctl restart k3s`, cooldown 300s + cap 3/30min → `node_clusterip_heal_giveup` alert). Breaks CP-PINNED pods (uptime-kuma `EAI_AGAIN`, 2026-06-29) while host + workers fine. **INTERMITTENT** — hit the cold/maintenance reboot, not a warm plain reboot. |

**The 2026-05-30 wedge (3rd surface):** UFW boots disabled → `ufw-heal` runs `flush-all` → `iptables -t nat -F POSTROUTING` deletes `-j CNI-HOSTPORT-MASQ`. flannel + kube-proxy re-add their jumps (daemons); **portmap does NOT** (k8s#93091) → pod→ClusterIP/DNS dead while **`verify-clusterip.sh` reads green** (host OUTPUT→10.43.0.1 + `:10256` both pass). Host-netns probes are structurally blind to it; only a root nat-jump check (phase2 gate) or the DNS-down symptom (watch-reboot kube-dns endpoints) catches it.

`verify-clusterip.sh` deliberately covers only the worker ClusterIP DNAT surface (host-netns) — it
sees neither the CP loopback LB (CP-only, port 6443 vs 6444) **nor** the CNI portmap masquerade
(pod-netns). `watch-reboot.sh` probes the CP loopback itself AND counts kube-dns ready endpoints. A
wedged CP loopback stalls the embedded controller-manager; a CNI portmap wedge kills cluster DNS —
both while the node still reports `Ready`.

## CP advisory verdict can mask a pod-netns wedge (2026-06-29)

The `watch-reboot.sh` CP `clusterip WEDGED` line is printed **advisory** (host-netns quirk for the CP's API role, gated by loopback-LB + kube-dns) — but the SAME verdict can MASK a real CP **pod-netns** wedge that breaks CP-PINNED pods (uptime-kuma `EAI_AGAIN` on its DB, 2026-06-29). If a CP-pinned pod is unhealthy post-reboot, do NOT dismiss the advisory: check the `node_clusterip_heal_*` textfile metric on the CP, or a pod-netns probe (nsenter into a CP pod). Surface-4 row above holds the probe one-liners + the `clusterip_heal_cp` watchdog detail.

## watch-reboot.sh notes — exit-0 false-complete window + ssh names

**exit-0 false-complete window.** The watcher's gate conditions are ALL true in the gap *after* `trigger-reboot.sh` fires but *before* phase1 reboots the CP (`phase2-pending` not set yet, CP still on old uptime). A watcher started too early can exit 0 with **no reboot having happened**. Don't treat exit-0 alone as "reboot done" — confirm the reboot actually occurred: CP `uptime -s` shows a fresh boot ts, the run was observed transitioning `phase run-state: running`→`idle`, and per-node `checkupdates`→0. Boot timestamps (CP→W1→W2 ~6 min apart) also prove the `serial:1` ordering held.

**ssh names.** `watch-reboot.sh` uses **ssh_config Host names** (`gmk-k3s-control-plane`, `worker-node`, `worker-node-2`) — those carry user+port (worker-node-2 = z3us, others = akhozya). It does **not** use zsh aliases like `ssh_master_node` (invisible to bash).

## Green on every surface but UNPATCHED — rescue-swallowed yay failure (2026-08-01)

A node can pass Ready + ClusterIP + loopback + DNS + pod-health and still have received **zero package
updates**. Every worker/VM `yay` call site is rescue-wrapped on purpose (a hard failure there strands
`phase2-pending` and gates drift-heal cluster-wide, 2026-06-20), so the run reports success either way.
Only the **GPU-VM** play's rescue (`hosts: virtual`) fires a Telegram warning — the worker play's
rescue sends nothing — and Telegram is transient regardless: it notified on 2026-07-11 and
2026-07-18 and both went unnoticed (phase2.yml's own comment records this). The only durable,
latching signal is `node_pkg_upgrade_success`, which `watch-reboot.sh` now gates exit-0 on. For the
two physical workers on 2026-08-01 it was the sole signal of any kind.

**2026-08-01.** phase1 died `status=2` at `yay -Syyu`:
`==> ERROR: One or more files did not pass the validity check!` on `flux-bin`. No `phase2-pending`, no
reboot, phase2 never ran — 3 nodes went a week unpatched, CP left running 6.18.39 with 6.18.41
installed. After the CP was cleared and the full cycle re-run, phase2's worker upgrades failed on the
*same* file and exited clean: CP=1, worker-node=0, worker-node-2=0.

**Root cause, and the durable rule.** `makepkg` does **not** re-download a source that already exists —
it validates the copy on disk and aborts. Once a cached tarball's checksum stops matching, no upstream
correction can dislodge it; delete the file. AUR `flux-bin` had hardcoded `_srcver=2.8.6` in its source
URL while `pkgver` advanced, and the filename derives from `${pkgver}`, so weekly "upgrades" kept
re-saving the v2.8.6 tarball under new names. Tell: `pacman -Q flux-bin` = `2.9.3-1` while
`flux version --client` = `v2.8.6`.

**CP and workers cache sources in different places.** Workers got `SRCDEST=.../.cache/makepkg/sources`
from `base_config`; the CP has no override and keeps sources in `.cache/yay/<pkg>/`. Measured:
`--cleanafter` logged `Cleaning (1/1): .cache/yay/flux-bin` while the tarball **survived** in
`.cache/makepkg/sources` — it cleans only yay's own tree, so it covers sources only with `SRCDEST`
unset. Fixed in-repo (`db048f3c`): `--cleanafter` added, worker `SRCDEST` dropped.

**Recovery.** Delete the offending tarball on every affected node (check BOTH paths), then re-run
phase1. A full successful phase1→phase2 rewrites each node's metric from its real `yay` result — do
**not** hand-write the metric after that, it would overwrite a genuine failure with a pass.

Hand-writing `/var/lib/node_exporter/textfile/node_pkg_upgrade.prom` (3 lines, 0644,
`node_pkg_upgrade_success 1`) is correct **only** for a node repaired out-of-band — i.e. you ran `yay`
directly so `tasks/pkg-upgrade-metric.yml` never executed. The proof required is a **zero exit from
the complete `yay` command**, not just the package you were chasing: the metric attests the whole
upgrade, and the same run can fail on a *different* AUR package after the one you fixed succeeds.
Checking `pacman -Q <pkg>` and the binary's own `--version` is a useful extra parity check, never the
whole proof. Otherwise the stale 0 keeps `NodePackageUpgradeFailed` firing until the next weekly run.

## Post-reboot debris that does NOT self-drain (2026-08-01)

- **Controller-owned terminal pods** — a reboot leaves one terminal pod per evicted pod. They keep
  `DeploymentReplicasMismatch` / `PodRunningNotReady` / `*PodNotRunning` firing (14 terminal pods →
  4 alerts, 2 critical). phase2 PLAY 2 deletes them since 2026-08-08:

  | Scope | Phases | Owners |
  |---|---|---|
  | cluster-wide | `Failed`, `Succeeded` | ReplicaSet, StatefulSet, DaemonSet |

  If a run never reached PLAY 2, delete the terminal pods manually with the command in `SKILL.md` § Monitoring with
  watch-reboot.sh, bullet "Controller-owned terminal pods". Leave `Job`-owned `Succeeded` pods —
  normal CronJob completions.
- **App that lost its DB across the roll** — n8n vs CNPG, 2026-08-01: readiness 503 for 33min after
  `Postgres pool client error: Connection terminated unexpectedly` / `server shutting down`, while
  Postgres itself was healthy again. Deployment read `Available=True` but `Progressing=False /
  ProgressDeadlineExceeded`. `kubectl rollout restart` brought up a Ready pod, yet the stale one
  survived — two ReplicaSets at `desired=1` for 17min, keeping the alert up. A **second**
  `rollout restart` converged it. Mechanism NOT established: `ProgressDeadlineExceeded` reports
  stalled progress, it does not by itself halt scale-down, so record this as a symptom and a working
  remedy rather than a general Deployment rule.

## Reboot HANGS unreachable (not Ready-but-wedged) — HW watchdog self-recovery (2026-06-20)

Distinct from the wedge surfaces above: the node goes **fully UNREACHABLE** (ssh dead, `Ready=Unknown`), not Ready-but-wedged. Cause: a **late `systemd-shutdown` hang** — after all units stop and journald flushes, the final phase (unmount `/`, `/var`, multi-device LVM, then `reboot()`) wedges in an uninterruptible device/dm quiesce. Kernel stays alive (no panic → the `kernel.*_panic` softlockup/hardlockup sysctls do NOT cover it); sshd already stopped → node looks dead. Persistent journal ends mid-sequence (last line e.g. `Unmounting /home...`) because journald stopped first; next boot's fsck journal-recovery confirms the unclean shutdown.

**Self-recovery, no human needed:** systemd arms the SP5100 HW watchdog for the shutdown phase via `RebootWatchdogSec=2min` (`hardening/files/systemd-watchdog.conf`, 2min since `f5a9c8a6`; was 10min). A hung reboot force-resets after that window. So when `watch-reboot.sh` shows a worker UNREACHABLE mid reboot-run: **WAIT ~4min** (2min watchdog + ~2min boot) before any manual power-cycle. Still down at ~5min = watchdog did not fire (hardware) → manual reset warranted.

**EXCEPTION — `immich-vm` (4th node, VM on the NAS): NO watchdog, wait-4min does NOT apply.** The `immich_gpu_node` role deliberately disables kernel-panic reboot AND HW watchdog (GPU reset-bug safety) — a hung shutdown there wedges INDEFINITELY, and `virsh destroy`/`reset` are NEVER-rules (dirty-GPU FLR can crash the whole NAS host). Recovery = operator-supervised only; safe path = clean NAS host reboot. Detail: memory `gotcha_reboot_shutdown_hang_watchdog` (immich-vm variant) + `gotcha_immich_vm_virtio_gpu_fbdev_wedge` (root cause, fixed — hang now unlikely but the no-watchdog fact stands).

NOT in conflict with kubelet graceful node shutdown (`shutdownGracePeriod 120s` = 90s normal + 30s critical, backed by logind `InhibitDelayMaxSec=120`): that eviction runs in the **unit-stop** phase (PID 1 alive, RuntimeWatchdog fed) and finishes *before* `systemd-shutdown` arms `RebootWatchdogSec`. The 2min window covers only the bare final unmount+`reboot()` (seconds). Sequential phases, never concurrent.

2026-06-20: worker-node hung here during the maintenance reboot; operator power-cycled at <2min (before the then-10min watchdog could fire). Fix `f5a9c8a6`: `RebootWatchdogSec` 10min→2min + this wait-window note in `watch-reboot.sh`. The hang itself is intermittent (dm/NVMe quiesce race) and accepted — the watchdog is the safety net, not a deterministic prevent.

## Why this skill exists (2026-05-24 / 2026-05-25 wedge cascade)

A node reporting `Ready` can still be **wedged** at the network layer in ways `kubectl get nodes`
does not show — 2 surfaces known from the 2026-05-24 / 2026-05-25 incidents (see
`gotcha_k3s_reboot_ordering`), 4 tracked now (§ surface table above). The sanctioned phase1→phase2
flow gates on them; ad-hoc `ssh ... sudo reboot` loops do not — they skip the per-worker `serial: 1`
ClusterIP gate and cascade wedges across nodes (= the 2026-05-24 incident this skill prevents).

Minimum ansible commit that contains the phase2 gate (probe shipped to nodes + both gates):
`9cb36ae9` — *"node-maintenance: phase2 ClusterIP + CP-loopback gates, ship clusterip-probe to nodes"*.
If the running cluster predates this, the gate is absent and the old wedge risk applies.
