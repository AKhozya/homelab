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
**not** reimplement reboot logic — ansible phase1/phase2 are authoritative. It provides
`trigger-reboot.sh` (starts phase1 with sudo fetched from 1Password — faillock-safe, single-attempt)
and a no-sudo agent-side watcher (`watch-reboot.sh`).

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

The agent can start it without a live TTY by reading the shared homelab sudo password from 1Password and
piping it to `sudo -S` over SSH:

```bash
# 1) verify op can read the secret FIRST — faillock-safe, touches NO sudo (approve the 1Password popup):
op read 'op://Personal/sudo-homelab/password' >/dev/null && echo OK
# 2) dry-run prints what it would do; omit --dry-run to actually fire:
bash ~/.agents/skills/cluster-reboot/scripts/trigger-reboot.sh --dry-run
bash ~/.agents/skills/cluster-reboot/scripts/trigger-reboot.sh
```

`trigger-reboot.sh` is **faillock-safe by construction**: it fetches the secret first and **aborts
before any sudo if `op read` is empty** (e.g. a dismissed popup), refuses to reboot through a running
drift-heal/sync or an in-flight run (`phase2-pending`), makes a **single** attempt, and never leaks
the password (op → shell var → ssh stdin, never argv/env/history). 1Password item:
`op://Personal/sudo-homelab/password` (shared sudo for all 3 nodes); override via `OP_SUDO_PATH` /
`CP_HOST` env.

> ⚠️ **pam_faillock `deny=3`** — a wrong/empty sudo password tried 3× = 10-min lockout. NEVER
> auto-retry a failed sudo. If the script prints `SUDO-FAILED`, or `op read` won't unlock (popup
> dismissed → empty), **STOP** and fix op/the password — do not re-run blindly. Always pre-verify
> with the `op read … >/dev/null && echo OK` check above, which spends no sudo attempt. A *successful*
> sudo resets the faillock counter.

### B. Manual fallback — user runs it over a TTY

If the op item isn't set up or the op CLI can't unlock, the user starts it directly:

```bash
ssh -p 65300 -t akhozya@gmk-k3s-control-plane "sudo systemctl start node-maintenance-phase1.service"
```

Either path → then monitor via `watch-reboot.sh` (below).

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

## The four wedge surfaces (Ready ≠ healthy)

A node can be `Ready` while wedged at one of **4** network surfaces `kubectl get nodes` hides: worker
kube-proxy ClusterIP DNAT (`10.43.0.1:443`), CP k3s loopback LB (`127.0.0.1:6443`), CNI portmap
masquerade (`CNI-HOSTPORT-MASQ`), and the **CP pod-netns ClusterIP DNAT** — a
CP-pinned pod can't reach ANY ClusterIP (DNS `10.43.0.10` / API `10.43.0.1`) while the CP host AND
both workers are fine. `watch-reboot.sh` + `verify-clusterip.sh` probe the first three; the CP
pod-netns surface is host-netns-BLIND and now self-heals via the `clusterip_heal_cp` watchdog (its
own nsenter-into-coredns pod-netns probe).
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
node is uncordoned, then **re-trigger** the flow to process the remaining worker(s). `watch-reboot.sh`
makes the stuck state visible (Ready-but-wedged worker + lingering `phase2-pending`).

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

Each iteration reports, for all 3 nodes: `Node.Ready`, `verify-clusterip.sh` verdict, the CP loopback
probe (CP only), the `phase2-pending` interlock, the per-node `node_pkg_upgrade_success` verdict, and
a warn-only `pod-health.sh --count` baseline. On a Ready-but-wedged node it prints the sanctioned
remediation one-liner (it never runs it — no sudo).

> **`pkg-upgrade: FAILED` = the node is UNPATCHED even though the run reported success.** Every
> worker/VM `yay` is rescue-wrapped on purpose (a hard failure strands `phase2-pending` and gates
> drift-heal cluster-wide), so a failed upgrade leaves no other durable, latching *health signal* —
> the phase log under `/var/log/node-maintenance/` does record it, but nothing watches that. Only the **GPU-VM**
> play's rescue fires a Telegram warning; the worker play's rescue sends nothing at all, and Telegram
> is transient regardless — it was missed on 2026-07-11 and 2026-07-18.
> 2026-08-01: this script exited 0 with both workers stuck on a failed AUR upgrade.
> **`UNVERIFIED` also blocks exit-0** — query or parse failure means the patch state is unknown, and
> exit-0 asserts "packages upgraded". The gate fails closed rather than attest something it cannot
> check; the loop is bounded, so this can't deadlock.

> The warn-only `pod-health` `unhealthy=N` right after a reboot usually reflects transient pods
> (restart races, Jobs mid-retry) that drain on their own within minutes — re-run before treating
> as reboot damage. **Two classes do NOT drain:**
> - **Controller-owned terminal pods.** A reboot leaves one per evicted pod, because nothing reaps
>   them: the ReplicaSet controller ignores terminal pods it owns and the pod-GC controller acts only
>   past `--terminated-pod-gc-threshold` (12500). They keep `DeploymentReplicasMismatch` /
>   `PodRunningNotReady` / `*PodNotRunning` firing — 14 and 4 alerts (2 critical) on 2026-08-01, 11
>   more on 2026-08-08. **phase2 PLAY 2 sweeps them since 2026-08-08** (owner-scoped, cluster-wide,
>   `Failed` + `Succeeded`); before that it matched `Failed` in infra namespaces only. Still do this by
>   hand after a run that never reached PLAY 2 — list, then delete each by name AND phase so a
>   stable-named StatefulSet pod recreated in between is not the one you delete:
>   `kubectl get pods -A -o json | jq -r '.items[]|select(.status.phase=="Failed" or .status.phase=="Succeeded")|select(any(.metadata.ownerReferences[]?; .controller==true and (.kind=="ReplicaSet" or .kind=="StatefulSet" or .kind=="DaemonSet")))|"\(.metadata.namespace) \(.status.phase) \(.metadata.name)"'`
>   then `kubectl -n <ns> delete pod --field-selector="metadata.name=<name>,status.phase=<phase>"`.
>   Leave `Job`-owned pods alone — those are normal CronJob completions.
> - **An app that lost its DB across the rolling reboot** can sit `Running 0/1` until someone
>   intervenes. Observed with n8n vs CNPG on 2026-08-01: readiness 503 for 33min (it did not recover
>   on its own in that window), Deployment showed `Progressing=False /
>   ProgressDeadlineExceeded`, and after `kubectl rollout restart` the *new* pod went Ready while the
>   stale one and its alert stayed put — two ReplicaSets at `desired=1` for 17min. A **second**
>   `rollout restart` converged it. Mechanism not established (`ProgressDeadlineExceeded` reports
>   stalled progress; it does not by itself halt scale-down) — treat as a symptom + remedy, not a rule.

Exit **0** only when ALL gates pass: all 3 nodes Ready + ClusterIP-healthy (the CP ClusterIP verdict
is advisory), the CP loopback healthy, kube-dns ready endpoints ≥ 1, the package upgrade verified
clean on every reporting node (`UNVERIFIED` counts as failure), the phase1/phase2 run idle, and
`phase2-pending` absent. Otherwise non-zero (keep
watching / remediate). The loop is bounded — never infinite.

> ⚠️ **exit-0 false-complete window.** All gate conditions can be true *before* phase1 has rebooted
> the CP — never treat exit-0 alone as "reboot done". Confirmation checklist + ssh-name note:
> `reference-incidents.md` § "watch-reboot.sh notes".

## The post-run Claude alert review

On success, `node-maintenance-phase2.service` ExecStopPost runs
`/usr/local/sbin/telegram-notify-claude.sh`, which POSTs a prompt to the bot's loopback `/trigger` so
Claude reviews the post-reboot alerts in the normal DM. **A missing review is a silent failure by
construction** — that ExecStopPost ends in `|| true`.

It answered `curl: (22) ... error: 403` on 2026-08-01 and 2026-08-08 and nobody noticed: the secret
lived in two places, SOPS `claude-telegram-env.trigger-secret` was rotated on 2026-07-31, and the CP's
`/etc/node-maintenance/claude-trigger-secret` kept its April value. Since 2026-08-08 the script reads
`$TRIGGER_SECRET` from inside the pod (no CP copy, so no drift) and sends its own Telegram alert if the
POST fails.

If no review arrives and no failure alert arrives either, the trigger's own line is the last one in the
run, after `PLAY RECAP`:

```bash
journalctl -u node-maintenance-phase2.service --since=-1d --no-pager | tail -20
```

Check the endpoint by hand without starting a Claude run — an empty body passes the secret check and
stops at the body check, so **400 means the auth path is healthy** and 403 means it is not:

```bash
printf '{}' | kubectl -n claude-telegram exec -i deploy/claude-telegram -c claude-telegram -- \
  sh -c 'curl -s -o /dev/null -w "%{http_code}\n" --max-time 10 -X POST \
    "http://127.0.0.1:8080/trigger" -H "X-Trigger-Secret: $TRIGGER_SECRET" \
    -H "Content-Type: application/json" --data-binary @-'
```

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
