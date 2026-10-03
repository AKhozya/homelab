---
name: cluster-reboot
description: >-
  Use when the user wants to UPDATE + REBOOT the homelab K3s nodes safely (CP gmk-k3s-control-plane
  + workers worker-node / worker-node-2). ONLY sanctioned path: trigger the ansible node-maintenance
  phase1 → phase2 rolling-reboot flow and monitor it. NEVER hand-roll `ssh ... sudo reboot` in a loop
  across nodes — bypasses the per-worker serial:1 ClusterIP gate. A node can be Node.Ready while its
  kube-proxy ClusterIP DNAT (worker) or k3s loopback loadbalancer (CP) is wedged — this skill probes
  BOTH surfaces. Single-node reboot = reuse verify-clusterip around it. NOT for in-place pod
  recycling without a reboot → `cluster-roll` skill. NOT for k3s VERSION upgrades (manual binary —
  phase1/phase2 does not bump it) → `k3s-upgrade` skill.
---

# cluster-reboot

Thin doc + orchestration wrapper around the **existing** ansible node-maintenance reboot flow. It does
**not** reimplement reboot logic — ansible phase1/phase2 are authoritative.
If you need to know what the two scripts do, read reference-flow.md § "The two scripts and how path A works".

## When / why

Fires when the user wants node OS/package updates + reboot (CP+W1+W2; immich-vm handled by the
phase2 carve-out — NEVER in-guest reboot/virsh-destroy, GPU reset-bug), or a safe reboot after
kernel/driver changes.

- **DO** trigger phase1 (below) and watch with `watch-reboot.sh`.
- **DO NOT** loop `ssh ... sudo reboot` across nodes — skips the per-worker `serial: 1` ClusterIP
  gate; that's what cascaded the 2026-05-24 wedge. Surface table + cascade detail: `reference-incidents.md`.
- **NOT this skill** for recycling pods without a reboot → use `cluster-roll`.

## Triggering the reboot

phase1 = `sudo systemctl start node-maintenance-phase1.service` (root). Two paths:

### A. Autonomous (preferred) — `trigger-reboot.sh` (sudo fetched from 1Password)

```bash
# 1) verify op can read the secret FIRST — faillock-safe, touches NO sudo (approve the 1Password popup):
op read 'op://Personal/sudo-homelab/password' >/dev/null && echo OK
# 2) dry-run prints what it would do; omit --dry-run to actually fire:
bash ~/.agents/skills/cluster-reboot/scripts/trigger-reboot.sh --dry-run
bash ~/.agents/skills/cluster-reboot/scripts/trigger-reboot.sh
```

Never work around `trigger-reboot.sh`'s guards. It aborts before any sudo if the 1Password read comes back empty, refuses to run during a drift-heal, sync or in-flight run, makes one attempt, and passes the password on ssh stdin, never in argv, env or history.
If you need its checks in detail or its env overrides, read reference-flow.md § "What trigger-reboot.sh checks".

> ⚠️ **pam_faillock `deny=3`** — a wrong/empty sudo password tried 3× = 10-min lockout. NEVER
> auto-retry a failed sudo. If the script prints `SUDO-FAILED`, or `op read` won't unlock (popup
> dismissed → empty), **STOP** and fix op/the password — do not re-run blindly. Always pre-verify
> with the `op read … >/dev/null && echo OK` check above, which spends no sudo attempt.

### B. Manual fallback — user runs it over a TTY

If the op item isn't set up or the op CLI can't unlock, the user starts it directly:

```bash
ssh -p 65300 -t akhozya@gmk-k3s-control-plane "sudo systemctl start node-maintenance-phase1.service"
```

Either path → then monitor via `watch-reboot.sh` (below).

If you change phase1 or phase2, or need to know what each play does, read reference-flow.md first. It also names the minimum ansible commit that holds the gate.

## The four wedge surfaces (Ready ≠ healthy)

**Per-surface probe + fix one-liner table, and cascade mechanics: `reference-incidents.md`.**
Load it when a node is Ready-but-wedged or you're remediating an aborted PLAY 1.

> ⚠️ The CP `clusterip WEDGED` line in `watch-reboot.sh` is **advisory** — but the same verdict can
> MASK a real CP **pod-netns** wedge that breaks CP-PINNED pods (2026-06-29). Unhealthy CP-pinned pod
> post-reboot → do NOT dismiss it; checks: `reference-incidents.md` § "CP advisory verdict".

**Different mode — reboot HANG → worker fully UNREACHABLE (not Ready-but-wedged):** HW watchdog self-resets it in ~2min — **wait ~4min before any manual power-cycle**. Mechanics + 2026-06-20 incident: `reference-incidents.md` § "Reboot HANGS unreachable".

## Partial-completion / resume model

PLAY 1 is `serial: 1` and **aborts on the first ClusterIP-gate failure**. On abort:

- the **failing worker is left CORDONED** (not uncordoned),
- the **`phase2-pending` flag is retained** (so `node-maintenance-sync`/`config` stay skipped),
- the **next worker is never processed** — it is un-updated and still schedulable.

So a failure is **partial**, not all-or-nothing. The operator must: remediate the wedged worker
(restart k3s-agent or `rolling-restart-k3s.yml`), confirm `verify-clusterip.sh <worker>` is OK and the
node is uncordoned, then **re-trigger** the flow to process the remaining worker(s).

**Stuck `phase2-pending` after a COMPLETED run:** if the phase1/phase2 work actually finished (nodes
rebooted, updates applied) but the flag remains — e.g. the phase2 flux-reconcile nudge timed out,
exiting the run `failed=1` after the reboots were done (2026-06-20) — it silently gates
`node-maintenance-sync`/`config` (drift-heal) cluster-wide with no alert. Clear it on the CP:
`sudo rm /var/lib/node-maintenance/phase2-pending` (give the command to the user — the agent has no
sudo). Do NOT re-run phase2 — the work was already done.

## Monitoring with watch-reboot.sh

No-sudo, read-only agent-side watcher. Run it during/after a triggered reboot:

```bash
# single snapshot:
bash ~/.agents/skills/cluster-reboot/scripts/watch-reboot.sh --once
# bounded poll loop (default 30s × 60 ≈ 30 min):
bash ~/.agents/skills/cluster-reboot/scripts/watch-reboot.sh --interval 30 --max-iter 60
```

On a Ready-but-wedged node it prints the sanctioned
remediation one-liner (it never runs it — no sudo).
If you need what each iteration reports or the exact exit-0 gates, read reference-flow.md § "What watch-reboot.sh reports".

If `watch-reboot.sh` prints `pkg-upgrade: FAILED` or `UNVERIFIED`, read reference-incidents.md § "pkg-upgrade FAILED and UNVERIFIED verdicts".

If phase1 fails `exit=2` with no `yay` error, read reference-incidents.md § "Other phase1 `exit=2` signatures".

> The warn-only `pod-health` `unhealthy=N` right after a reboot usually reflects transient pods
> (restart races, Jobs mid-retry) that drain on their own within minutes — re-run before treating
> as reboot damage. **Two classes do NOT drain:**
> - **Controller-owned terminal pods.** If you need why they linger, read reference-incidents.md § "Why controller-owned terminal pods linger".
>   **phase2 PLAY 2 sweeps them since 2026-08-08** (owner-scoped, cluster-wide,
>   `Failed` + `Succeeded`); before that it matched `Failed` in infra namespaces only. Still do this by
>   hand after a run that never reached PLAY 2 — list, then delete each by name AND phase so a
>   stable-named StatefulSet pod recreated in between is not the one you delete:
>   `kubectl get pods -A -o json | jq -r '.items[]|select(.status.phase=="Failed" or .status.phase=="Succeeded")|select(any(.metadata.ownerReferences[]?; .controller==true and (.kind=="ReplicaSet" or .kind=="StatefulSet" or .kind=="DaemonSet")))|"\(.metadata.namespace) \(.status.phase) \(.metadata.name)"'`
>   then `kubectl -n <ns> delete pod --field-selector="metadata.name=<name>,status.phase=<phase>"`.
>   Leave `Job`-owned pods alone — those are normal CronJob completions.
> - If an app is stuck `Running 0/1` after it lost its DB, read reference-incidents.md § "App stuck Running 0/1 after losing its DB".

The loop is bounded — never infinite.

> ⚠️ **exit-0 false-complete window.** All gate conditions can be true *before* phase1 has rebooted
> the CP — never treat exit-0 alone as "reboot done". Confirmation checklist + ssh-name note:
> `reference-incidents.md` § "watch-reboot.sh notes".

## The post-run Claude alert review

If you need how the review fires, read reference-incidents.md § "How the post-run Claude review fires".
If no post-run Claude review arrives, read reference-incidents.md § "Missing post-run Claude review".

## k3s version upgrade

NOT this flow — k3s is a manual binary, NOT pacman/yay-managed; phase1/phase2 never bumps it.
Use the dedicated `k3s-upgrade` skill (binary stage + rolling-restart activation, no reboot,
no token).

## Cross-refs

- `/homelab-node-fix` — node-side debug + fix (SSH+TTY sudo pattern, drift-heal, faillock).
- `/k8s-diagnostics` — symptom-driven cluster diagnosis when something is wrong post-reboot.
- `cluster-roll` skill — in-place pod recycling tier-by-tier, **no node reboot** (use that instead
  when you don't need to reboot).
- `rolling-restart-k3s.yml` — sanctioned serial k3s/k3s-agent restart playbook for multi-node wedges.
- `gotcha_k3s_reboot_ordering` (memory) — live incident notes: reboot ordering, kube-proxy wedge,
  NVMe enum flips, sync exit=1 drift-heal cascade.
