---
name: cluster-roll
description: >-
  Use to recycle pods cluster-wide in ORDERED, tier-by-tier fashion on the K3s cluster
  (Flux GitOps) — the safe replacement for "kubectl rollout restart -A". Gates each tier on
  rollout status + a ClusterIP re-probe on all 4 nodes. Fires when you need to restart
  workloads after a config/secret/DNS change, clear cached Go-resolver/PgBouncer DNS failures, or
  bounce the fleet. NOT for node reboots — use the cluster-reboot skill for that. kubectl-only
  (+ SSH probe), no sudo. GitOps-safe: rollout restart + delete-pod fallback only, never
  edit/patch/replace.
  OPERATOR-ONLY — run from a workstation, not from the claude-telegram bot. It is built on
  `kubectl rollout restart`, and the bot's ServiceAccount lost workload `patch` on 2026-08-06;
  the script calls `die` on the first non-zero restart, so from the bot it aborts on workload one.
  The delete-pod path inside it is a stale-pod fallback after a SUCCESSFUL restart, not a
  permission fallback.
---

# cluster-roll

Ordered, tier-by-tier pod-recycle orchestrator. Safe replacement for blanket
`kubectl rollout restart -A` (which cascaded the cluster on 2026-05-24 → `reference-mechanics.md` § Why ordered, not blanket).

Script: `scripts/cluster-roll.sh` (kubectl-only + the SSH ClusterIP probe; **no sudo**).

## When to use / NOT use
- **USE**: recycle pods fleet-wide after a config/secret/ConfigMap/DNS change, to clear cached
  Go-resolver or PgBouncer DNS-failure state, or any deliberate "bounce everything" — but SAFELY,
  in dependency order with health gates between tiers.
- **DO NOT USE for node reboots** → use the `cluster-reboot` skill (drain/cordon/reboot ordering,
  CP-loopback surface, kube-proxy wedge recovery). cluster-roll only recycles pods; it never
  touches nodes beyond a read-only ClusterIP probe.

## Roll order (tier 1 → 5)
Each tier: `rollout restart` every listed object → per-tier gate `rollout status --timeout=180s`
scoped to exactly that tier's objects → ~20s settle → re-run `verify-clusterip.sh` on all 4 nodes.
`pod-health.sh` is **preflight baseline only**, NOT a per-tier gate.

| Tier | Name | What | Notes |
|---|---|---|---|
| 1 | `dns` | `kube-system` coredns-ha (Flux-managed **DaemonSet**, 1/node since 2026-06-05; k3s addon `deploy/coredns` GONE via `--disable=coredns` 2026-06-04) | Roll **in place**, NEVER scale. Must be Ready before any other tier. |
| 2 | `operators` | cnpg-operator, redis-operator, ps-operator (percona); metrics-server, local-path-provisioner; kyverno background/cleanup/reports; victoria-metrics-operator, kube-prometheus-stack operator; flux source/kustomize/helm/notification controllers | Operators only, no data pods. **Flux controllers roll LAST** within the tier (self-disruption risk). |
| 3 | `platform` | cert-manager (+ cainjector, webhook) → traefik → cloudflared → kyverno **admission**-controller → authentik server+worker → blocky | Ordered serial chain; PDBs allow=1 so slower. Kyverno admission lives HERE (background/cleanup/reports are tier 2). |
| 4 | `dnscache` | main-postgres-rw-pooler (PgBouncer), mysql-exporter; vmagent, vmalert, vmsingle, grafana, kube-state-metrics, alertmanager (STS); loki-gateway, alloy (DS), loki-canary (DS) | Restart **after** DNS confirmed healthy — clears Go-resolver/PgBouncer cached DNS failures. The PG pooler belongs ONLY here. |
| 5 | `apps` | immich (server+ML), paperless-ngx, n8n, mealie, homepage, homehub, audiobookshelf, uptime-kuma, pricebuddy, stirling-pdf, linkwarden, claude-telegram, home-assistant, rustdesk (rustdesk + warp-beacon) | Stateless app deployments. |

### SKIP (never blanket-roll — recycle via operator/CRD/Helm)
Data-bearing STS and node-infra DaemonSets:
- **Percona MySQL** STS `main-mysql-mysql` / `main-mysql-haproxy` / `main-mysql-orc` → recycle via
  the `PerconaServerMySQL` CR, never blanket rollout.
- **Redis** STS `redis-replication` / `redis-sentinel-sentinel` (sentinel PDB **min=2**) → recycle
  via the Redis operator CRDs.
- **CouchDB** `couchdb-couchdb` (Helm, 2 replicas) → recycle via Helm/rollout with quorum care.
- **Meilisearch** `meilisearch` (single replica, no PDB) and **Loki** STS `loki` (Helm) → recycle
  by hand / via Helm with care.
- **DaemonSets** `svclb-*` (k3s svclb), `node-exporter` and `intel-gpu-plugin` → node infra, managed by k3s/operator.

`--dry-run` cross-checks every live workload → tier-or-SKIP with a zero-orphan assert. If it ever
reports an orphan, fix the map before any live roll → `reference-mechanics.md` § Why ordered, not blanket.

## Rules (hard)
- If any check below fails, **preflight aborts the whole roll**:

  | Check | Aborts when |
  |---|---|
  | coredns-ha DaemonSet (Flux-managed `infrastructure/coredns/`; no replicas knob) | `numberReady` < `status.desiredNumberScheduled` |
  | `verify-clusterip.sh` on each of the 4 nodes | any exit ≠ 0 (wedged/unreachable); names the node |
  | orphan cross-check | a live workload is in no tier and not in SKIP; names it |
  | `pod-health.sh --count` baseline | never; preflight prints the count |
- **CoreDNS rolls in place, never scaled** out-of-band (see tier 1 — pod-per-node IS the scaling).
- **Never blanket-roll the SKIP set.** Data STS recycle through their operator/CRD/Helm.
- **Authentik depends on PG pooler (tier 4) + DNS (tier 1).** Rolled in tier 3 after DNS is healthy;
  pooler rerolled in tier 4. If authentik misbehaves post-roll, reroll pooler then authentik →
  `reference-mechanics.md` § Authentik → pooler → DNS chain.
- If stale pods survive a "successful" rollout, read `reference-mechanics.md` § Flux-stale-pod → delete-pod fallback. Full
  mechanic + DS/STS exclusion rationale → `reference-mechanics.md` § Flux-stale-pod → delete-pod fallback.

## Flags (tier by NAME, not index)
- `--dry-run` — print the full ordered plan (every workload → tier or SKIP) + orphan cross-check,
  run NOTHING. Always run this first.
- `--tier <name>` — roll only one tier. Names: `dns|operators|platform|dnscache|apps`. (Preflight still runs.)
- `--from-tier <name>` — roll from this tier through `apps` (tier 5). (Preflight still runs.)
- `--user-facing` — alias for `--tier apps`: roll just the user-facing app fleet (tier 5). Caveat:
  tier 5 also carries 2 non-UI backends (`immich-machine-learning`, `claude-telegram`),
  and the user-facing `authentik` (tier 3) + `grafana` (tier 4) roll with their dep-ordered tiers, NOT here.
- no args — full roll tiers 1→5 after preflight.

```bash
bash scripts/cluster-roll.sh --dry-run
bash scripts/cluster-roll.sh --tier dnscache      # e.g. clear cached DNS failures only
bash scripts/cluster-roll.sh --user-facing        # bounce the app fleet (= --tier apps)
bash scripts/cluster-roll.sh --from-tier platform # platform → apps
bash scripts/cluster-roll.sh                      # full ordered roll
```

## Cross-refs
- `/gitops-workflow` — GitOps invariants; cluster-roll uses only operational verbs (rollout restart,
  delete pod), never edit/patch/replace of git-managed specs.
- `/k8s-diagnostics` — symptom-driven triage if a tier gate fails (CrashLoop, NetworkPolicy gap, DB).
- `kyverno-policy-promotion` — kyverno admission (tier 3) vs background/cleanup/reports (tier 2) split.
- `cluster-reboot` skill — node reboots (drain/cordon/CP-loopback/kube-proxy wedge). cluster-roll
  reuses its `verify-clusterip.sh` probe.
- `gotcha_k3s_reboot_ordering` (memory) — kube-proxy ClusterIP wedge + reboot fallout context; the
  ClusterIP probe gate here defends against rolling onto a wedged node.
- `~/.agents/skills/_shared/audit-priority-class.sh` — pre/post roll, run BOTH `--count` AND
  `--missing` (`--count` alone misses NULL-priority workloads) → `reference-mechanics.md`
  § Priority-class audit.
