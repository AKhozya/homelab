# Cluster Reboot + Cluster Roll skills — design (v2, post-review)

**Date:** 2026-05-24 (revised 2026-05-25 after 3-agent review)
**Author:** session (post-incident)
**Status:** design — pending user review

## Context / motivation

A cluster-wide `kubectl rollout restart deploy,sts,ds -A` rescheduled DB/SSO-dependent pods onto
**worker-node-2**, whose kube-proxy was silently wedged since today's 19:53 reboot — node `Ready`
(kubelet) but ClusterIP DNAT (`10.43.0.1`) dead. immich hard-crashed (`CONNECTION_CLOSED`, no retry),
Authentik replica probe-killed, PgBouncer cached `server DNS lookup failed` (worsened by rolling
single-replica CoreDNS). Recovery = cordon wedged node + delete pods → restart `k3s-agent` → uncordon.
See memory `gotcha_k3s_reboot_ordering`.

Two gaps: (1) no sanctioned *ordered* pod-roll primitive; (2) the reboot gate checks only kubelet
Node.Ready, not ClusterIP DNAT — a wedged-but-Ready node passes and gets uncordoned.

**Verified facts (this session):**
- Proxy = **k3s embedded kube-proxy** (iptables; no kube-proxy/kube-router DaemonSet). ClusterIP DNAT
  is `KUBE-SERVICES` iptables, **host-netns-visible** → on-node `curl -k https://10.43.0.1:443/healthz`
  returns **401** when DNAT works; `000`/refused/timeout = wedged. (k3s uses kube-router only for
  NetworkPolicy, not service DNAT.)
- **CoreDNS = k3s Addon**, replicas=1, no PDB. Reverts on both Addon-controller reconcile AND k3s
  restart (re-extracts packaged manifest). See "CoreDNS HA" below.
- **PDBs (live):** `main-postgres-primary` disruptionsAllowed=**0**; `redis-sentinel-sentinel`
  minAvailable=**2**; `redis-replication-replication` minAvailable=**1**; `couchdb` minAvailable=1
  (STS replicas=2); authentik/traefik/cloudflared/kyverno-admission/alertmanager/mysql-haproxy/pooler
  minAvailable=1. `main-mysql-orc` maxUnavailable=1.

Existing machinery to reuse (do NOT reinvent):
- `node-maintenance-phase1.service` — CP self-update (`yay`) → `ExecStartPost=systemctl reboot`.
- `node-maintenance-phase2.service` (4 plays): PLAY 0 CP-stabilize (waits CP Node/coredns+metrics/
  traefik/flux ctrl/flux kustomizations Ready + pause) → PLAY 0.5 pause rebuilderd → **PLAY 1 per-worker
  `serial:1` cordon → yay → reboot → "Wait for node Ready in k8s API" → uncordon → stabilize → observe
  crashloops** → PLAY 2 post-tasks (flux reconcile, GC, alert un-silence, telegram).
- `rolling-restart-k3s.yml` — sanctioned serial k3s/k3s-agent restart (cross-ref for wedge remediation).
- `k3s-wait-ready.sh` — boot gate: API + critical pods + **UFW**-chain hash stable (ignores kube-*
  chains by design → does NOT prove ClusterIP works). This is the exact blind spot the new gate fills.
- Deploy path for ansible edits: commit → `node-maintenance-sync.service` (git pull) →
  `node-maintenance-config.service` (drift-heal). **Interlock:** both units `ConditionPathExists`
  skip while `/var/lib/node-maintenance/phase2-pending` is set (or <2h old) → a phase2.yml edit will
  NOT deploy mid-maintenance; lands on the next sync after the flag clears.

## Decisions (brainstorm + research + review)

- cluster-reboot = **update-and-reboot only**, reusing phase1/phase2 (not a new reboot engine).
- Safety = **cordon-only + graceful node-shutdown + ClusterIP gate + uncordon.** Drain dropped (user
  confirmed). **Rationale (corrected):** kubelet graceful-shutdown does NOT consult PDBs — the reboot
  terminates pods (incl. CNPG primary) regardless. Continuity comes from **CNPG operator failover**
  (replica promotion), *conditional on a ready CNPG replica off the rebooting node*. → add a pre-flight
  asserting that (below). `kubectl drain` is separately infeasible (CNPG-primary PDB allowed=0 deadlocks).
- Form = **auto-gated orchestration scripts** (cluster-roll fully automated; cluster-reboot hybrid).
- ClusterIP gate lives in **both** ansible phase2 (durable, protects unattended weekly run) **and** a
  skill-side verifier. **Single-sourced:** one on-node probe script `clusterip-probe.sh` shipped via the
  node-maintenance ansible role to `/etc/node-maintenance/bin/`; both the ansible gate task and the
  skill's `verify-clusterip.sh` invoke that same script (one verdict, two callers — no drift).
- **CoreDNS HA (replicas=2) lands first as its own change** and becomes a hard prerequisite for
  cluster-roll. Approach decision pending (A vs B below).

## Delivery sequence (decomposition fix)

Different artifacts, different pipelines, different blast radius — ship in order, each verified before
the next:

1. **CoreDNS HA** (ansible node-maintenance change; homelab repo; prerequisite for cluster-roll).
2. **ClusterIP gate** in `phase2.yml` PLAY 0 + PLAY 1 + the shared `clusterip-probe.sh` role file
   (homelab repo PR; hits CI `validate.yaml`; deploy via sync/drift-heal, mind the phase2-pending interlock).
3. **`cluster-roll` skill** (`~/.claude/skills/`, chezmoi) — net-new orchestrator; requires CoreDNS≥2.
4. **`cluster-reboot` skill** (`~/.claude/skills/`, chezmoi) — thin doc/monitor wrapper that *references
   the already-merged* ansible gate; states the min ansible commit it assumes.

---

## (0) CoreDNS HA — prerequisite

CoreDNS is a k3s Addon (replicas=1). To reach replicas=2 + anti-affinity **durably (survives Addon
reconcile AND k3s/CP restart):**

- **Option A (recommended — fits existing pattern):** ansible `k3s_config` role, post-`k3s-wait-ready`,
  rewrites the *source* `/var/lib/rancher/k3s/server/manifests/coredns.yaml` to replicas=2 + podAntiAffinity,
  so the Addon controller applies 2. Drift-heal re-applies after any k3s re-extract. Small boot window at
  replicas=1 until the role runs. Stays on k3s-shipped CoreDNS.
- **Option B:** `coredns.yaml.skip` + self-managed CoreDNS manifest (replicas=2 baked in). Survives
  natively, but we own CoreDNS (miss k3s version bumps) — higher long-term maintenance.

**DECISION NEEDED FROM USER: A or B.** (Recommend A.) Either way: verify post-change that both replicas
land on different nodes and a CP reboot leaves replicas=2.

## (1) `cluster-reboot` skill (thin wrapper over phase1/phase2 + the gate it references)

**Purpose:** updating + rebooting nodes via phase1→phase2 (full-cluster: CP then workers serial). The
only sanctioned path; **never** hand-roll `ssh ... sudo reboot` in a tight loop (caused the wedge).
For a one-off single-node reboot, reuse `verify-clusterip.sh` around it.

**Components:**
1. `SKILL.md` — when/why; trigger (`sudo systemctl start node-maintenance-phase1.service`, user runs,
   TTY); the 4-play chain; `phase2-pending` resume model **incl. partial-completion semantics**: on a
   `serial:1` gate failure the play aborts → the failing worker is left cordoned + flag retained AND the
   *next* worker is never processed (un-updated, still scheduled) — documented so the operator knows to
   re-trigger after remediation; the min ansible commit that contains the gate; cross-refs
   (`/homelab-node-fix`, `/k8s-diagnostics`, `rolling-restart-k3s.yml`, `gotcha_k3s_reboot_ordering`).
2. `scripts/verify-clusterip.sh <ssh-alias>` — **read-only, no sudo, pure verdict.** SSHes the node and
   invokes `/etc/node-maintenance/bin/clusterip-probe.sh` (or inlines the same probe if not yet
   deployed). Exit 0 healthy / 1 wedged. **No remediation text** — callers own that. Resolves the right
   SSH user per node from `~/.ssh/config` (worker-node-2 = `z3us`, not `akhozya`).
3. `scripts/watch-reboot.sh` — Claude-side monitor: polls `phase2-pending` + each node Node.Ready +
   `verify-clusterip.sh` per node + `_shared/pod-health.sh` (baseline only). Surfaces a wedge with the
   remediation one-liner (pointing at `rolling-restart-k3s.yml` as the sanctioned multi-node path).

**Ansible gate hardening (the durable fix — homelab PR, step 2):**
- Ship `clusterip-probe.sh` to `/etc/node-maintenance/bin/` via the role: host-netns
  `curl -sS -m5 -k -o /dev/null -w '%{http_code}' https://10.43.0.1:443/healthz`; pass=401|200,
  fail=000/refused/timeout; exit 0/1. Single source of the verdict.
- **PLAY 1**, insert between `Wait for node Ready in k8s API` (delegate localhost) and `Uncordon node`:
  a task that runs the probe **on the inventory host** (omit `delegate_to`; `become: true`), `until`
  pass, `retries: 12 delay: 10`. If still wedged → `systemctl restart k3s-agent` (on the host), then
  re-probe (same budget). Only then `Uncordon`. If never passes → fail loudly (telegram + retain
  `phase2-pending`), do NOT uncordon. Document that this aborts the serial loop (worker-2 skipped).
- **PLAY 0 (CP)**, after the existing CP-stabilize checks and before the pause: add the same probe on
  the CP (localhost), **`until`-bounded `retries: 12 delay: 10`** (never single-shot — a transient CP
  false-negative must not abort the run after phase1 already rebooted the CP). Comment that this checks
  DNAT *routability*, complementary to (not redundant with) the existing kube-dns/metrics pod-Ready
  checks.

## (2) `cluster-roll` skill (net-new; ordered in-place pod restart, no reboot)

For recycling pods cluster-wide (clear cached state, post-config bounce) without the "all at once"
blast radius.

**Hard prerequisite:** CoreDNS replicas ≥ 2 — **abort** if `< 2` (forces step 0 first; removes the
single-replica DNS-gap class entirely — matches the "abort if node wedged" safety posture).

**Pre-flight (abort-on-fail):**
- All 3 nodes `Ready` AND `verify-clusterip.sh` healthy on each. **Abort if any node wedged.**
- A ready CNPG replica exists (for safety parity with reboot path; warn-only here since no eviction).
- Baseline unready-pod count (warn).

**Explicit namespace→tier map** (every workload has a home; nothing silently skipped). Each tier:
`rollout restart` the listed Deployments/STS, then **per-tier gate** = `kubectl rollout status`
scoped to exactly that tier's objects (`--timeout=180s`) → fixed settle pause → `verify-clusterip.sh`
recheck. Cluster-wide `pod-health.sh` used for pre-flight baseline only, not as a per-tier gate.

| Tier | Namespaces / workloads | Notes |
|---|---|---|
| 1 DNS | `kube-system`: coredns (+ confirm ≥2). | Roll in place; never scale out-of-band (Addon). Wait Ready before any other tier. |
| 2 Operators/edge | `databases`: cnpg-operator, redis-operator, mysql-exporter→(moved to t4 cache). `kube-system`: metrics-server, local-path-provisioner. `flux-system`: source/kustomize/helm/notification controllers (roll LAST-within-tier; self-disruption risk). `kyverno`: background/cleanup/reports controllers (NOT admission yet). | Operators only; no data pods. |
| 3 Platform | `cert-manager` → `traefik` → `cloudflare-tunnel` → `kyverno-admission-controller` → `authentik` (server+worker) → `blocky`. | Ordered; PDBs allowed=1 → serial/slower. Authentik depends on PG pooler (t4) + DNS (t1) — keep after them. |
| 4 DNS-cache clients | `databases`: main-postgres-rw-pooler (PgBouncer), mysql-exporter. `monitoring`: vmagent, vmalert, vmsingle, victoria-metrics-operator, kube-prometheus-stack-operator/grafana/kube-state-metrics, alertmanager (STS). `loki`: loki-gateway, alloy (DS), loki-canary (DS). | Restart **after** DNS confirmed healthy — clears Go-resolver/PgBouncer cached failures. Pooler ONLY here (removed from t2). |
| 5 Apps | All app namespaces: immich, paperless-ngx, n8n, mealie, homepage, homehub, audiobookshelf, uptime-kuma, pricebuddy, stirling-pdf, linkwarden, claude-telegram, csp-reporter, home-assistant. | Explicit list (not "remaining"). |
| SKIP | Data-bearing STS: `main-mysql-*` (percona-operator), `redis-replication`/`redis-sentinel` (redis-operator; sentinel PDB min=2), `couchdb` (Helm, 2 replicas), `linkwarden/meilisearch` (single replica, no PDB), `loki/loki` (Helm STS). DaemonSets `svclb-*`, `node-exporter`. | CRD/operator/PDB-guarded or stateful — recycle via operator/CRD, never blanket rollout. |

> Authentik chain reminder (in SKILL.md): Authentik → PG pooler (t4) → DNS (t1). Do not move earlier.

**Component:** `scripts/cluster-roll.sh` — drives tiers via an explicit object list per tier;
`rollout restart` + scoped `rollout status --timeout` + settle + ClusterIP recheck between tiers.
**kubectl-only, no sudo.** Flags: `--from-tier <name>`, `--tier <name>`, `--dry-run` (all by tier
*name*, not index). Per `/bash-scripting`. Absolute `~/.claude/skills/_shared/pod-health.sh` path.

**SKILL.md:** when to fire (recycle pods, NOT reboots); the tier table; rules — "abort if CoreDNS<2 or
any node wedged", "skip data-bearing STS", "roll CoreDNS in place never scale", Authentik dependency
chain; cross-refs (`/gitops-workflow`, `/k8s-diagnostics`, `kyverno-policy-promotion`,
`gotcha_k3s_reboot_ordering`).

> **Flux-managed caveat (from 2026-05-25 memory):** on Flux-managed Deployments, `rollout restart`'s
> `restartedAt` annotation can be reverted by drift-detection (stale pod survives). If a tier's
> `rollout status` shows the same pod name/age post-restart, fall back to `kubectl delete pod` (Flux
> manages the Deployment, not the pod). cluster-roll.sh must detect this and escalate to pod-delete.

## Risks / constraints

- Ansible phase2 edit touches the **unattended weekly run**: gate must be bounded + self-heal-or-fail,
  never infinite-block. Deploy via sync/drift-heal; **phase2-pending interlock** delays deploy until the
  flag clears.
- CoreDNS HA touches core DNS — test on a single CP-reboot before trusting; verify both replicas split
  across nodes.
- `cluster-roll.sh` respects invariants: no force-delete DB pods (except the documented Flux-stale-pod
  escalation), no kubectl edit/patch of git-managed specs (rollout restart only).
- Skills → `/chezmoi-sync` after. Ansible/CoreDNS changes → homelab commit + node-maintenance deploy.

## Out of scope (YAGNI)

- No new reboot engine (phase1/phase2 authoritative).
- No automatic scheduling of cluster-roll.
- No rollback automation beyond Flux/`/gitops-workflow`.
- No node drain / CNPG-switchover orchestration (cordon-only + graceful + failover is the pattern).
