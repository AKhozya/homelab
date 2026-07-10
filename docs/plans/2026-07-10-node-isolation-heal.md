# node_isolation_heal — worker self-recovery watchdog

**Status:** DESIGN v2 — Codex R1 folded in (2 HIGH + 2 MED + 1 LOW). Pending operator
sign-off on escalation policy + a 2nd Codex delta review, then implement (dry-run first).
**Origin:** 2026-07-10 W2 isolation incident. Trigger (firewall pre-heal unconditional
`ufw reload`) fixed in `ff2b486b`. This watchdog is the **defense-in-depth safety net**
for the failure *class*, not the specific trigger.

## Problem

A worker can become isolated from the control plane — kubelet NotReady, k3s-agent
client-LB (`127.0.0.1:6444`) can't reach the CP apiserver (`192.168.1.127:6443`) —
while the **host stays alive** (kernel journaling, NIC up). No existing self-heal acts:

| Watchdog | Precondition | Why it no-op'd 2026-07-10 |
|---|---|---|
| `clusterip_heal` | k3s-agent active **and** ClusterIP DNAT wedged | reported "agent not active" |
| `ufw_heal` | UFW **inactive** | UFW was active |

Result: W2 isolated ~90 min, recovered only by manual power-cycle. Single-CP topology
(R2) means the agent LB has nothing to fail over to → a wedged tunnel needs an agent
restart. W2's Realtek `r8169` NIC (R4) makes it the node most likely to lose a
reload↔tunnel race. So the class recurs even with the trigger fixed.

## Scope

- **Workers only** (`worker-node`, `worker-node-2`). NOT the CP — self-reboot of the CP
  is a cluster control-plane outage, and k3s *server* restart hangs (existing gotcha).
- New ansible role `node_isolation_heal`, wired into `node-config.yml` for the worker
  group, mirroring `clusterip_heal` (script + oneshot service + timer + textfile metric).

## Detection (every 2 min)

1. Probe the agent→CP path: `curl -sk --max-time 5 https://127.0.0.1:6444/cacerts`.
   This is the k3s-agent client LB; failure = agent can't reach the CP apiserver.
2. OK → clear episode state, exit 0 silently (no journal spam, like ufw_heal watchdog).
3. FAIL → increment a consecutive-fail counter in `/var/lib/node-isolation-heal/state`.
   Escalate only after **≥2 consecutive fails (~≥4 min)** — never act on a single blip.

## Escalation ladder

Each step: gated on continued failure + its own cooldown; emits metric + journal + a
Telegram line on action. Re-probe drives the next tick (agent needs ~30–60 s to rejoin).

> **L1 dropped (Codex R1 / MEDIUM-1):** the earlier L1 called `ufw-heal-post-k3s.sh
> --watchdog`, which **exits immediately when UFW is active** (`ufw-heal-post-k3s.sh:323-337`)
> and skips phase-G (`:306-308`). The incident had UFW *active*, so that step was a no-op
> for this class. The root firewall trigger is already fixed (`ff2b486b`) and the real
> fragility is the NIC (R4), so a firewall-repair step adds nothing. Ladder is now 2 steps.

| Step | Fires when | Action | Bound |
|---|---|---|---|
| **L1** | wedged ≥~6 min | `systemctl restart k3s-agent` (rebuilds tunnel/LB/CNI) | shared restart cooldown ↓ |
| **L2** | wedged ≥ `(15 + node_offset)` min **and** an L1 restart already tried this episode and failed | **controlled `systemctl reboot`** (LAST RESORT — the only thing that recovered W2) | guards ↓ |

### L2 reboot guards (ALL must pass)

- **Cross-worker stagger (Codex R1 / HIGH-1 — storm prevention).** DB HA spans workers
  (CNPG primary+replica, Percona, Redis Sentinel, CouchDB — `docs/CODEMAPS/databases.md`);
  the architecture assumes workloads keep serving during a CP-only outage
  (`docs/ARCHITECTURE.md:151`). If BOTH workers isolate at once (CP-down / partition) and
  both self-reboot together, both replicas of an HA DB drop → data-plane outage. An
  isolated node cannot coordinate (no API, maybe no peer). Fix = **deterministic
  node-indexed reboot offset**: reboot fires at `wedged ≥ 15min + index·8min`
  (W1 index 0 → 15 min; W2 index 1 → 23 min). Two simultaneously-isolated workers therefore
  reboot **≥8 min apart**, never together = a leaderless *rolling* reboot; an HA DB loses
  at most one replica at a time. Offset is a per-host var (`node_isolation_reboot_index`).
- **Boot-loop:** skip if uptime < 30 min (just rebooted → don't loop).
- **Daily cap:** ≤1 reboot / 24 h (dated state file). Beyond → set `giveup` metric +
  Telegram "manual intervention", stop escalating. (A persistent cluster-wide outage thus
  yields at most one *staggered* reboot per worker, then alert-only — no storm, no loop.)
- **Maintenance interlock (Codex R1 / HIGH-2 — worker-local).** `phase2-pending` and
  `/run/node-maintenance.lock` are **CP-local** (`phase1.yml` is `hosts: localhost`;
  `flag_file = {{state_dir}}/phase2-pending`) — invisible to a worker watchdog. Fix =
  a **worker-local hold**: `phase2.yml` `touch`es `/var/lib/node-isolation-heal/maint-hold`
  on each worker (delegated) before that worker's orchestrated reboot and removes it after
  rejoin; the watchdog skips L1/L2 while the hold exists. Age-out: ignore a hold > 1 h old
  (mirrors the phase2-pending 2 h age-clear) so a stuck hold can't disable the watchdog
  forever. *Required before ACTIVE mode; dry-run needs it only to log correctly.*

## Shared k3s-agent restart accounting (Codex R1 / MEDIUM-2)

`clusterip_heal` already restarts `k3s-agent` with a 300 s cooldown + 3/30 min cap
(`clusterip-heal.sh:33-36,78-80,110-140`), on an independent timer. This watchdog adds a
second restart path — unbounded together, the two could restart-fight. Fix = a **shared
per-node cooldown file** (`/var/lib/k3s-agent-restart/cooldown`, timestamp) that BOTH
scripts check before restarting and touch after. `clusterip_heal.sh` gets a small change
to honor it. Neither restarts `k3s-agent` within the shared cooldown of the other.

## Metrics (node-exporter textfile: `/var/lib/node_exporter/textfile/node_isolation_heal.prom`)

- `node_isolation_heal_wedged` 0/1 — currently isolated
- `node_isolation_heal_wedged_seconds` — continuous isolation duration
- `node_isolation_heal_pending_action` 0=none/1=restart/2=reboot — the ladder rung selected
- `node_isolation_heal_giveup` 0/1 — escalation exhausted (guard/cap) → needs a human
- `node_isolation_heal_dryrun` 0/1 — 1 while `NIH_DRY_RUN=1` (soak)
- `node_isolation_heal_signal_up{signal="tunnel|cp_direct|kubelet|gateway"}` 0/1 — per-signal probe

## Alerts (monitoring VMRule — separate commit, active-flip follow-up)

- `NodeIsolationHealActing` — `node_isolation_heal_wedged == 1` >8 min — warn
- `NodeIsolationHealPendingReboot` — `node_isolation_heal_pending_action == 2` — **critical**
  (dry-run: it WOULD reboot; active: it did — either way the operator must know)
- `NodeIsolationHealGaveUp` — `node_isolation_heal_giveup == 1` — **critical**, manual

## Testing / rollout

- **`DRY_RUN` mode** (arg/env): logs the decision it *would* take, takes NO destructive
  action, NEVER reboots. Ships FIRST.
- Deploy dry-run → soak ~1 week, confirm it reads healthy vs wedged correctly and never
  false-fires an intended action → then flip to active. No urgency (trigger already
  fixed), so the soak is free.
- Self-check: a `--selfcheck` that runs the probe + prints the ladder decision for the
  current state without acting.

## Codex review round 1 — incorporated

| # | Finding | Resolution |
|---|---|---|
| HIGH-1 | L2/L3 could reboot both workers on one CP-side outage (DB HA spans workers) | node-indexed reboot **stagger** (≥8 min apart) = leaderless rolling reboot; daily cap |
| HIGH-2 | `phase2-pending` interlock is CP-local, invisible to a worker watchdog | **worker-local** `maint-hold` file set by `phase2.yml` (delegated) + 1 h age-out |
| MED-1 | L1 `ufw-heal --watchdog` is a no-op when UFW active (the incident's state) | **dropped L1**; ladder now restart-agent → reboot |
| MED-2 | second independent k3s-agent restart path could fight `clusterip_heal` | **shared restart cooldown** file both scripts honor |
| LOW | timing OK given ~30-60 s rejoin | kept; stagger added |

## Decisions (operator-confirmed 2026-07-10)

1. **Reboot thresholds: 15 min (W1) / 23 min (W2)** continuously isolated (8-min stagger).
2. **Signals (revised after live verification — kubelet-healthz was the wrong 2nd signal).**
   `ISOLATED = tunnel (`6444`) down` — the agent can't reach the CP. Kubelet `10248/healthz`
   was going to be the AND-second-signal, but it reflects the kubelet *process*, which stays
   healthy during CP-isolation → it would **suppress** the very escalation we want. So the
   discriminator is **`cp_direct` (TCP `6443`)**: the **L2 reboot only fires when tunnel AND
   cp_direct are both down** (genuine network isolation, not a mere wedged LB — an LB glitch
   with `6443` still reachable gets an L1 restart, never a reboot). Kubelet + a **gateway ping**
   (`192.168.1.1`) are probed and logged as metrics for soak tuning, not gates.
3. **Dry-run soak first** (no actions; logs the decision it *would* take) → ~1 wk → flip active.

## Build order

- **Now (dry-run, self-contained):** new `node_isolation_heal` role — script (`NIH_DRY_RUN=1`),
  watchdog `.service`+`.timer` (every 2 min), textfile metrics, `defaults/main.yml`,
  `tasks/main.yml`; wire into `node-config.yml` workers play; `node_isolation_reboot_index`
  host_var (W1=0, W2=1). Emits `node_isolation_heal_*` metrics incl. `node_isolation_heal_dryrun`
  and per-signal `node_isolation_heal_signal_up`. No destructive path reachable. Ladder logic
  covered by an offline unit test (`tests/test-ladder.sh`, 22 cases).
- **Before ACTIVE flip (follow-up):** `phase2.yml` worker-local `maint-hold`; shared
  `/var/lib/k3s-agent-restart/cooldown` honored by `clusterip_heal.sh` too; monitoring
  VMRules (`NodeIsolationHealActing/Rebooted/GaveUp`); flip `NIH_DRY_RUN=0`.
