# Homelab Architecture

**What this is:** the *why* and the *shape* of the cluster — design principles, the diagrams, and the rationale behind each convention. For the current numbers see [HOMELAB_ANALYSIS.md](HOMELAB_ANALYSIS.md); for refreshed component snapshots see [CODEMAPS/](CODEMAPS/); for the changelog see [HOMELAB_HISTORY.md](HOMELAB_HISTORY.md). This file changes only when the *design* changes, not when counts drift.

**Cluster in one line:** single-environment K3s (v1.35.x, 3 Arch nodes) run as GitOps — Git is the only write path, Flux reconciles, every secret is SOPS-encrypted, every workload is admission-gated and network-fenced.

---

## Design principles (the logic)

1. **Git is the only source of truth.** No `kubectl edit/patch/apply` against live objects — the cluster is whatever `main` says. A change is a commit; Flux reconciles it in ≤60s. This makes the cluster reproducible, auditable (git log = change log), and self-healing (drift is reverted on the next reconcile). The cost — no out-of-band hotfix — is accepted deliberately.
2. **Layered reconciliation, infra before apps.** Resources have a dependency order (CRDs before custom resources, operators before the things they manage, databases before the apps that connect). Flux `dependsOn` + `wait: true` encodes it as a 6-stage chain so apps never reconcile against a half-built platform.
3. **Secrets are git-native, encrypted at rest.** SOPS + age keeps secrets *in* the repo (one source of truth, PR-reviewable) but unreadable without the cluster's age key. No external secret store to bootstrap or keep available.
4. **Defense in depth, default-deny.** Four independent layers (admission, network, runtime, identity) each assume the others may fail. A compromised app still hits a NetworkPolicy wall, a non-root RoRFS container, and Kyverno-enforced limits.
5. **Two front doors, no port-forwards.** Internal traffic stays on the LAN (fast, Blocky DNS → Traefik). External traffic enters only through a Cloudflare Tunnel (outbound-initiated — no inbound ports opened on the router). The LAN is never exposed directly.
6. **Pin everything, name things after what they are.** Images pinned to `major.minor.patch-variant` (floating tags drift silently). DB role name = app name. These conventions let humans and policy reason about the cluster without lookups.

---

## Node topology + storage

```mermaid
flowchart TB
  subgraph LAN["Home LAN — 192.168.1.0/24, SSH :65300"]
    CP["gmk-k3s-control-plane · .127<br/>control-plane + etcd<br/>NIC I225-V forced 1Gbps, EEE off"]
    W1["worker-node (W1) · .129<br/>/mnt/k8s-storage (0700)<br/>hosts Immich PVs (local-path)"]
    W2["worker-node-2 (W2) · .126<br/>/mnt/extra-storage<br/>SSH user z3us (not akhozya)"]
    NAS["NAS<br/>rsync daemon :50555"]
  end
  CP -. k3s API .-> W1
  CP -. k3s API .-> W2
  W1 -->|"rsync --delete"| W2
  W2 -->|"rsync :50555"| NAS
```

Storage is `local-path-provisioner` (node-local PVs — no distributed storage layer by choice; simpler, faster, and the backup chain provides durability instead). Each PV is bound to the node where it was first allocated via the PV's `nodeAffinity` (the local-path mechanism) — there is no Deployment-level node pinning. **Immich PVs live on W1** (`/mnt/k8s-storage/...immich-library`, `...immich-machine-learning`) → Immich Pods can only run on W1; W1 down = Immich down. Durability comes from the **replication chain W1 → W2 → NAS**, not from replicated volumes.

---

## GitOps reconciliation order

```mermaid
flowchart TB
  G["Git repo (main)<br/>SOPS-encrypted secrets"] --> FS["flux-system<br/>GitRepository source + Flux controllers"]
  FS --> IC["infrastructure-controllers<br/>cert-manager · Traefik · Kyverno<br/>CNPG / Percona / Redis operators"]
  IC --> ICF["infrastructure-configs<br/>DB Cluster CRs · NetworkPolicy · ResourceQuota<br/>SOPS secrets · backup CronJobs"]
  ICF --> MC["monitoring-controllers<br/>kube-prometheus-stack · VictoriaMetrics op · Loki · Alloy"]
  MC --> MCF["monitoring-configs<br/>VMRule · VMServiceScrape · dashboards · alert templates"]
  MCF --> APPS["apps<br/>application stacks"]
```

Each arrow is a hard `dependsOn` with `wait: true` — a stage only starts once the previous one reports Ready. Why this exact order:

| Stage | Owns | Must precede next because |
|---|---|---|
| `infrastructure-controllers` | Operators + CRDs (cert-manager, Traefik, Kyverno, CNPG/Percona/Redis) | CRs in the next stage need their CRDs registered + operators running |
| `infrastructure-configs` | DB `Cluster` CRs, NetworkPolicies, quotas, secrets, backups | Databases + network fences must exist before workloads use them |
| `monitoring-controllers` | Metrics/logging stack (VictoriaMetrics, Loki, Alloy) | Scrape/alert configs need the CRDs + operators |
| `monitoring-configs` | Scrapes, rules, dashboards | — |
| `apps` | 16 application stacks | Apps `dependsOn` everything above (DBs, ingress, policy, observability) |

**Consequence for DB provisioning:** a CNPG `Database` CR is *infrastructure*, not app config — it belongs in `infrastructure-configs`, in the `databases` namespace alongside its `Cluster` (the CR's `spec.cluster` is a same-namespace `LocalObjectReference`). This is why DB manifests live under `infrastructure/configs/.../databases/postgres/`, not in app dirs (F-15, 2026-05-27).

---

## Traffic flow — two front doors (different paths to the same Pod)

```mermaid
flowchart LR
  subgraph EXT["External — internet → tunnel → Service (Traefik NOT in path)"]
    U1["Internet client"] --> CF["Cloudflare edge<br/>WAF + TLS terminate"]
    CF -->|"outbound tunnel"| CFD["cloudflared pod<br/>SOPS tunnel config"]
    CFD -->|"direct to Service:port"| SVCE["app Service<br/>e.g. authentik:9000"]
  end
  subgraph INT["Internal — LAN client → Traefik → Service (middleware applies)"]
    U2["LAN device"] --> BL["Blocky DNS<br/>W1/W2 LB IP"]
    BL --> TR["Traefik :443<br/>traefik ns"]
    TR --> ING["IngressRoute + middleware<br/>security-headers · rate-limit · CSP · redirect-https"]
    ING --> SVCI["app Service"]
  end
  SVCE --> POD["app Pod"]
  SVCI --> POD
  NP{{"NetworkPolicy<br/>per ingress + cross-ns egress"}} -. fences .- POD
```

An externally-reachable app has **two ingress rules** (internal hostname + Cloudflare hostname) but **one NetworkPolicy**. cert-manager issues TLS via DNS-01 (Cloudflare API token) for `*.h0melab.work`. The Cloudflare Tunnel is outbound-initiated → home router opens **zero** inbound ports.

**Consequence (often missed):** Traefik middleware applies **only on the internal path.** External traffic via Cloudflare Tunnel hops `cloudflared → Service` directly (per `infrastructure/configs/cloudflare/networkpolicy.yaml`: per-app `Service:port` egress to 9 apps, zero egress to the `traefik` namespace). Externally-reached apps get Cloudflare's WAF + TLS, **not** the Traefik CSP/headers/rate-limit middlewares. F-22's tier-based CSP soak therefore covers internal browsing only; CF-tunnel browsers see whatever CSP the app itself sets.

---

## Security layers (defense in depth)

```mermaid
flowchart TB
  L1["1 · Secrets at rest — SOPS + age, encrypted in git"]
  L2["2 · Admission — Kyverno (12 ClusterPolicies, all Enforce) + Pod Security Standards"]
  L3["3 · Network — allow-list NetworkPolicies per workload (per-pod default-deny effect; Kyverno F-5 require-networkpolicy Enforce denies Pod creation in any non-system ns lacking a NetworkPolicy)"]
  L4["4 · Runtime — runAsNonRoot · readOnlyRootFilesystem · drop ALL caps · seccomp RuntimeDefault"]
  L5["5 · Identity + transport — Authentik OIDC + cert-manager TLS"]
  L1 --> L2 --> L3 --> L4 --> L5
```

Each layer is independent: bypassing admission still leaves the network fence; escaping the network still leaves a non-root, read-only-rootfs container. **PSS** sets the namespace floor (`restricted` where possible, `baseline`/`privileged` only where a workload genuinely needs hostPath/host-namespaces/GPU — each justified, see F-45). **Kyverno** enforces the per-workload specifics PSS can't (image pinning, resource limits on *every* container including init, NetworkPolicy presence). NetworkPolicy ports are **container ports, not service ports**.

---

## Data layer

| Engine | Operator | Notes |
|---|---|---|
| PostgreSQL | CloudNativePG (`main-postgres`) | Shared cluster; per-app `Database` CR + role; PgBouncer pooler; role name = app name |
| MySQL | Percona | Per-app `User` CR; HAProxy front |
| CouchDB | Helm | |
| Redis | Operator (OT) | In-memory; Authentik uses Postgres-only (no Redis) |

Backups: per-engine CronJobs in `infrastructure-configs` → the W1→W2→NAS replication chain. DR runbook in [`.backup/README.md`](../.backup/README.md). Never force-delete a DB pod or drop a DB directly — go through the CRD + `kubectl rollout restart`.

---

## Failure modes (what breaks when X dies)

| Failure | Effect | What still works | Recovery |
|---|---|---|---|
| CP node down | Flux reconcile + admission paused; new pods can't schedule | Running pods + Services keep serving (kube-proxy on workers is independent) | Reboot CP; Flux catches up |
| Worker node down | Pods on it go NotReady; Deployments reschedule elsewhere | Other-node workloads unaffected. **Immich PVs are on W1 (local-path nodeAffinity) → if W1 is down, Immich is down** (no failover; local-path is node-bound) | Reboot/replace; Immich resumes when its host returns |
| Cloudflare edge or tunnel down | Externally-published apps unreachable | LAN access via Traefik fully unaffected | Wait CF; LAN keeps working |
| Authentik down | SSO apps lose login | Non-SSO apps; non-OIDC paths | Restart Authentik Pod or rollout |
| GitHub down | No new commits reconciled | Cluster state frozen at last sync; everything keeps running | Wait GitHub |
| Age key (`sops-age` Secret in flux-system) lost | Encrypted secrets unreadable; new SOPS reconciles fail | Already-applied secrets in etcd keep working | Restore key from secure backup (NOT in this repo) |

## Single-environment reality

This is a single-environment cluster — and that environment is **production** (the live homelab). There is no separate staging and no promotion pipeline: a merge to `main` deploys straight to prod. The repo once carried the canonical Flux `base/` + `staging/` overlay shape, but with one and only one environment the split was pure ceremony (overlays were `[../base]` + SOPS secrets — no patches, replicas, or image overrides), and the `staging/` dir name was a Flux-convention artifact, not a second environment. It has been **fully collapsed to flat single-env dirs**: apps (F-13, 2026-05-29), infra + monitoring controllers (F-14), and the configs layer (2026-06-04). Every move was proven render byte-identical (`kustomize build` oracle-diff empty) → Flux re-adopted every object in place, zero churn. **No `base/staging` overlay split remains repo-wide;** a new such split is now the smell, not the norm.

---

## Deliberate simplifications (cut corners)

Called out so they are choices, not accidents:

- **Diagrams are logical, not exhaustive.** Individual apps (16), every NetworkPolicy (~44 live), and every namespace (27) are not drawn — the [codemaps](CODEMAPS/) carry the full enumeration. This file shows the *pattern*.
- **No formal threat model.** Trust boundaries are implicit: LAN is semi-trusted, Cloudflare edge is the only external entry, pod-to-pod is default-deny. A written threat model is not maintained.
- **No distributed storage / no HA control plane.** Single CP node, node-local PVs. Durability is backup-based (replication chain), not replica-based. A CP outage stops reconciliation until the node returns; running workloads keep serving.
- **Counts live in other docs.** This file avoids hard numbers that drift; where one appears it is approximate and the codemap/ANALYSIS is authoritative.
- **Monitoring + backup internals are summarized.** Full detail in [CODEMAPS/monitoring.md](CODEMAPS/monitoring.md) and [CODEMAPS/backup-restore.md](CODEMAPS/backup-restore.md).
- **OIDC redirect flow not in the traffic diagram.** SSO apps bounce through Authentik (`/oauth2/*`) on first login; the diagram shows the steady-state request path only.
- **CNI / kube-proxy / cluster-internal pod networking not drawn.** Pod-to-pod via CoreDNS (`kube-system`) + flannel + ClusterIP DNAT is assumed; the 2026-05-24 ClusterIP wedge incident proves this layer matters operationally even if it's invisible here.
- **Operator-created NetworkPolicies not enumerated.** Live `kubectl get netpol -A` shows ~44, git contains ~43 — the delta is operators (CNPG, Kyverno) creating their own. Codemap counts the file-level breakdown.
- **Age-key bootstrap not drawn.** The decryption chain is: `sops-age` Secret in `flux-system` → kustomize-controller reads it → decrypts SOPS-encrypted manifests on apply. Lose the key and you can't reconcile new secrets (see Failure modes).
- **Cluster boundary is implicit.** In-scope: the 3 nodes + the workloads they run. Out-of-scope but referenced: the NAS (backup sink), the home router (forwards nothing inbound — CF tunnel is outbound), the Cloudflare edge.
- **Reconcile cascade timing not in diagrams.** Full chain ~5 min post-push (see `/gitops-workflow` skill); not worth drawing.

---

## Map of the docs

| Doc | Answers |
|---|---|
| **ARCHITECTURE.md** (this) | How is it organized and *why* |
| [HOMELAB_ANALYSIS.md](HOMELAB_ANALYSIS.md) | Current state + open action items (live counts) |
| [CODEMAPS/](CODEMAPS/) | Refreshed structural snapshots per domain |
| [HOMELAB_HISTORY.md](HOMELAB_HISTORY.md) | Append-only changelog |
| [REVIEW.md](../REVIEW.md) | Ultrareview backlog + decisions |
| [.backup/README.md](../.backup/README.md) | DR runbook |
| [SECRETS_ROTATION.md](SECRETS_ROTATION.md) | Rotation schedule |
