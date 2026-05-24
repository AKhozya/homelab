# Cluster Reboot + Cluster Roll skills — design

**Date:** 2026-05-24
**Author:** session (post-incident)
**Status:** design — pending user review

## Context / motivation

A cluster-wide `kubectl rollout restart deploy,sts,ds -A` (run manually this session) rescheduled
DB/SSO-dependent pods onto **worker-node-2**, whose kube-proxy was silently wedged since today's
19:53 reboot — node `Ready` (kubelet) but ClusterIP DNAT (`10.43.0.1`) dead. Result: immich hard-crash
(`CONNECTION_CLOSED`, no retry), Authentik replica probe-killed, PgBouncer cached a `server DNS lookup
failed` (worsened by rolling single-replica CoreDNS). Recovery = cordon wedged node + delete pods
(reschedule to healthy node) → restart `k3s-agent` → uncordon. See memory `gotcha_k3s_reboot_ordering`.

Two gaps surfaced:

1. **No sanctioned "roll all pods in order" primitive.** "Roll everything at once" is the wrong shape
   for this cluster — it ignores dependency order (DNS → datastores → platform/SSO → apps) and
   re-exposes a pre-wedged node.
2. **The reboot gate is incomplete.** The ansible `phase2` worker rolling-update already does
   cordon → reboot → *wait Node Ready* → uncordon → stabilize (serial:1, CP-first via phase1). But
   `wait Node Ready` checks only kubelet `.status Ready==True`; a kube-proxy-wedged node passes and
   gets uncordoned. There is **no ClusterIP-DNAT verification**.

Existing machinery to reuse (do NOT reinvent):
- `node-maintenance-phase1.service` — CP self-update (`yay`) → `ExecStartPost=systemctl reboot`.
- `node-maintenance-phase2.service` — gates on `/readyz`, then phase2.yml: CP stabilize
  (Node/coredns/traefik/flux Ready + pause) → pause rebuilderd → **per-worker serial:1
  cordon/upgrade/reboot/wait-Ready/uncordon/stabilize** → cluster post-tasks (flux reconcile, GC,
  alert un-silence, telegram).
- `k3s-wait-ready.sh` — boot gate: API + critical pods + **UFW**-chain hash stable (ignores kube-*
  chains by design → does NOT prove ClusterIP works).
- Deploy path for ansible edits: commit → `node-maintenance-sync.service` (git pull) →
  `node-maintenance-config.service` (drift-heal apply). Per `/homelab-node-fix`.

## Decisions (from brainstorming)

- cluster-reboot = **update-and-reboot only**, reusing phase1/phase2 (not a new reboot engine).
- Safety = ~~cordon + drain~~ → **cordon-only + graceful-shutdown + ClusterIP gate + uncordon.**
  **(REVISED BY RESEARCH 2026-05-25.)** The brainstorm picked "cordon+drain", but `main-postgres-primary`
  has a PDB with `disruptionsAllowed=0` → `kubectl drain` deadlocks on the CNPG-primary node. phase2's
  existing cordon-only + `shutdownGracePeriod` is correct precisely because it respects PDBs implicitly
  (graceful termination + CNPG failover). True drain would require CNPG-aware switchover orchestration
  (promote a replica first) — out of scope. So the value-add is the **ClusterIP gate**, not drain.
- Form = **auto-gated orchestration scripts** (cluster-roll fully automated; cluster-reboot hybrid —
  Claude drives kubectl, sudo steps printed for user).
- ClusterIP-DNAT gate lives in **both** the ansible phase2 (durable, protects unattended weekly
  Sat 04:30 run) **and** a skill-side verifier (interactive). Probe verdict validated: healthy node
  host-netns `curl -k https://10.43.0.1:443/healthz` → **401** (DNAT routed); `000`/refused/timeout
  = wedged. Host-netns is faithful — KUBE-SERVICES DNAT applies in both host and pod netns on
  k3s/kube-router.

---

## Skill 1 — `cluster-reboot`

Thin wrapper + gate hardening around the existing phase1/phase2 flow.

**Purpose / when to fire:** updating + rebooting homelab nodes. phase1→phase2 is the full-cluster
update+reboot (CP + both workers) and is the only sanctioned path for that. For a one-off single-node
reboot, the `verify-clusterip.sh` gate is reused around it. Hard rule: **never** hand-roll
`ssh ... sudo reboot` in a tight loop (bypasses every gate; caused the 2026-05-24 wedge).

**Components:**

1. `SKILL.md` — when/why; the trigger (`sudo systemctl start node-maintenance-phase1.service`, user
   runs — TTY for sudo); phase chain explanation; `phase2-pending` flag resume model; the
   "never manual tight reboot" rule; cross-refs (`/homelab-node-fix`, `/k8s-diagnostics`,
   `gotcha_k3s_reboot_ordering`).
2. `scripts/verify-clusterip.sh <ssh-alias>` — **read-only, no sudo.** SSHes the node and probes the
   API ClusterIP from on-node:
   `curl -sS -m5 -k -o /dev/null -w '%{http_code}' https://10.43.0.1:443/healthz`.
   401/200 = DNAT programmed (healthy); timeout/refused = **wedged**. Also probes CoreDNS ClusterIP.
   Exit 0 healthy / 1 wedged. On wedge, prints the remediation command
   (`ssh -p 65300 -t <user>@<node> "sudo systemctl restart k3s-agent"`).
3. `scripts/watch-reboot.sh` — Claude-side monitor for interactive runs: polls `phase2-pending` flag +
   each node's Node.Ready + `verify-clusterip.sh` per node + `_shared/pod-health.sh`. Surfaces a wedge
   the moment a node returns Ready-but-no-ClusterIP, with remediation. Bounded; reports, never sudo.

**Ansible gate hardening (durable fix — the core value):**
In `phase2.yml` PLAY 1, between **Wait for node Ready** and **Uncordon**, insert a
**ClusterIP-DNAT gate** task:
- Probe `https://10.43.0.1:443/healthz` from the just-rebooted worker (delegate to that worker, it
  has `become`). Pass = http 401/200; fail = 000/refused/timeout. Retry (e.g. 12 × 10s).
- If still wedged after retries: `systemctl restart k3s-agent` on that worker (self-heal — ansible
  has become), then re-probe (same retry budget).
- Only `Uncordon` once the ClusterIP probe passes. If it never passes → fail the play loudly
  (telegram + retain `phase2-pending`) rather than uncordon a wedged node.

**CP-side gate (asymmetry fix, corner #5):** phase2 PLAY 0 (CP stabilize) currently proves CP health
via kubectl-against-API only. Add the same host-netns ClusterIP probe on the CP (localhost in PLAY 0)
so a CP kube-proxy wedge is caught before workers roll. Note CP↔apiserver is localhost:6443, so a CP
ClusterIP wedge primarily strands CP-hosted pods reaching *other* services — still worth the probe.

This makes the **unattended weekly run self-healing** against today's failure mode.

**Testing:** dry-run the new ansible task with `--check` where possible; lint via CP-hosted
yamllint/ansible-lint (per `/homelab-node-fix` drift-heal lint step). Live validation = next manual
phase1 trigger (user-gated). verify-clusterip.sh tested against a healthy node (expect 401) — shellcheck/shfmt clean.

---

## Skill 2 — `cluster-roll` (net-new)

Ordered, health-gated in-place pod restart (NO reboot). For recycling pods cluster-wide (clear cached
state, post-config bounce) without the "all at once" blast radius.

**Pre-flight (abort-on-fail):**
- All 3 nodes `Ready` AND `verify-clusterip.sh` healthy on each (reuse skill-1 script). **Abort** if
  any node wedged — never roll onto a broken node. This single check would have prevented the incident.
- No unready pods baseline (warn).

**Ordered tiers — each waits for prior to be Ready + settle before proceeding:**
1. **DNS** — **CoreDNS is a k3s Addon** (`objectset.rio.cattle.io/owner-gvk: k3s.cattle.io/v1
   Kind=Addon`), replicas=1. **Do NOT scale out-of-band** — the addon controller reconciles it back
   (drift). Roll **in place** (`rollout restart deploy/coredns -n kube-system`) and **wait fully Ready
   before any other tier** so the single-replica gap is closed before dependents touch DNS. The
   single-replica gap is the root of the PgBouncer cache poison; the durable fix is making CoreDNS HA
   via a `HelmChartConfig`/k3s-addon override (replicas=2 + anti-affinity) — **tracked as a separate
   item, not done by this skill.** Until then, tier 3 (DNS-cache-client restart) is what recovers any
   client that cached a failure during the roll gap.
2. **Datastores (operators + edge only — validated ownership):** `rollout restart` the rollable set —
   `cnpg-operator-cloudnative-pg`, `redis-operator`, `main-postgres-rw-pooler`, `mysql-exporter`.
   **Skip all data-bearing StatefulSets** — `main-mysql-*` (percona-server-mysql-operator-owned),
   `redis-replication` / `redis-sentinel` (PDB min=2), `couchdb-couchdb` (PDB min=1, Helm). These are
   CRD/operator-managed and PDB-guarded; recycle them via the operator/CRD, never `rollout restart`.
   Wait healthy.
3. **DNS-cache clients** — restart `main-postgres-rw-pooler` (PgBouncer) + `vmagent` **after** DNS
   confirmed healthy (clears Go-resolver / PgBouncer cached DNS failures). Wait Ready.
4. **Platform** — cert-manager → traefik → cloudflared → Authentik (server+worker). Wait Ready each.
   (Note PDBs allowed=1 on these → rollout restart respects them but is serial/slower.)
5. **Apps** — all remaining app namespaces. Wait Ready.

**Component:** `scripts/cluster-roll.sh` — drives the tiers; health-gate between each via
`_shared/pod-health.sh` + a per-tier `kubectl rollout status` wait + ClusterIP recheck. **kubectl-only,
no sudo.** Flags: `--from-tier <n>` (resume), `--dry-run` (print plan), `--tier <name>` (single tier).
Per `/bash-scripting` (set -euo pipefail, shellcheck/shfmt clean).

**SKILL.md:** when to fire (need to recycle pods, NOT for reboots — that's cluster-reboot); the tier
table; the rules — "skip data-bearing DB StatefulSets (operator/CRD + PDB-guarded)", "roll CoreDNS
in place, never scale out-of-band (k3s addon)", "abort if any node wedged"; cross-refs
(`/gitops-workflow`, `/k8s-diagnostics`, `kyverno-policy-promotion` for post-roll scan,
`gotcha_k3s_reboot_ordering`).

---

## Risks / constraints

- **Ansible phase2 edit touches the production weekly run.** The ClusterIP gate must be bounded
  (retry budget) + self-heal-or-fail-loud, never infinite-block. Deploy via node-maintenance
  sync/drift-heal, not a one-shot.
- Skills live in `~/.claude/skills/` (chezmoi/dotfiles) → `/chezmoi-sync` after. Ansible change lives
  in homelab repo → normal commit + node-maintenance deploy.
- `cluster-roll.sh` must respect invariants: no force-delete DB pods, no kubectl edit/patch of
  git-managed specs (rollout restart only — it patches a template annotation, allowed).
- **CoreDNS HA is a prerequisite for a *gap-free* roll but is a separate change** (k3s-addon
  `HelmChartConfig` override → replicas=2 + anti-affinity). Resolved in tier 1: roll-in-place + wait,
  never scale out-of-band (k3s addon reconciles it back). Recommend filing the HA change separately.
- **Drain is intentionally NOT used** (CNPG-primary PDB `allowed=0` deadlocks it). If a future need
  for true node-drain arises, it must orchestrate CNPG switchover first — separate, larger scope.

## Out of scope (YAGNI)

- No new reboot engine (phase1/phase2 stay authoritative).
- No automatic scheduling of cluster-roll (manual invocation only).
- No rollback automation beyond existing Flux/`/gitops-workflow`.
- **No CoreDNS HA change** here (separate k3s-addon `HelmChartConfig` item — recommended follow-up).
- **No node drain / CNPG-switchover orchestration** (cordon-only + graceful is the chosen pattern).
