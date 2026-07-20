# RustDesk Server OSS — Research, Score, Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline) to implement task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Self-host RustDesk rendezvous (hbbs) + relay (hbbr) on the K3s cluster, LAN-only, replacing dependency on RustDesk's public servers for remote desktop between home machines.

**Architecture:** Single pod (2 containers: hbbs + hbbr) sharing a 100Mi PVC at `/data` (ed25519 keypair + sqlite peer DB), exposed via one mixed-protocol LoadBalancer Service (klipper/servicelb, ETP=Local) pinned to worker-node. servicelb advertises BOTH pool-node IPs (.129 + .126 — verified live on blocky); with ETP=Local only `.129` (pod's node) carries traffic, `.126` blackholes — **clients are configured with `192.168.1.129` only**. Zero egress. GitOps via Flux, 2-commit namespace bootstrap with a reconcile barrier between the commits.

**Tech Stack:** `rustdesk/rustdesk-server:1.1.15` (classic image, FROM scratch, static bins), Kustomize, Flux, Kyverno CEL VPs, servicelb.

## Research summary (2026-07-19)

| Fact | Value | Source |
|---|---|---|
| Latest OSS release | **1.1.15** (2026-01-13) | github releases/latest |
| Image | `rustdesk/rustdesk-server:1.1.15`, multi-arch amd64/arm64/armv7, ~5.9MB | Docker Hub API + local pull |
| Classic Dockerfile | `FROM scratch`, `COPY hbbs/hbbr /usr/bin/`, `WORKDIR /root`, no USER | repo `docker-classic/Dockerfile` |
| Ports hbbs | 21115/TCP (NAT test), **21116/TCP+UDP** (ID reg/heartbeat + hole punch), 21118/TCP (web client, optional) | official docs |
| Ports hbbr | 21117/TCP (relay), 21119/TCP (web client, optional) | official docs |
| 21114/TCP | web console — **Pro only**, OSS has no web UI | official docs |
| State | `id_ed25519` (88B secret), `id_ed25519.pub` (44B), `db_v2.sqlite3` — all written to **CWD** | spike |
| Key enforcement | `-k _` = require clients to present the server pubkey | official docs/source |
| Relay discovery | client infers relay = ID-server-host:21117 when unset → `-r` unnecessary, avoids hbbs relay-healthcheck egress | client-config docs |
| Client needs | ID server `192.168.1.129`, Key = contents of `id_ed25519.pub` | client-config docs |

### CVE-2026-30784 (rustdesk-server#670, open — NO real fix even on master)
hbbs answers `PunchHoleSent`/`LocalAddr` messages **without key validation** (`-k _` only gates `handle_punch_hole_request` at `rendezvous_server.rs:682`), sending a `PunchHoleResponse` (+32B pk, ×2–3 amplification) to an attacker-chosen encoded address → UDP reflection/DDoS abuse on internet-exposed servers. **Verified against master source:** the maintainer's referenced commit `80d3a505` only makes UDP `PunchHoleRequest` unsupported (+2/−10); it does NOT touch the reflection handlers — self-building master gains nothing. Registration (`RegisterPk`) is also unauthenticated. So `-k _` gates the connect-to-peer path only, not registration or the reflection surface.

**Decision: stay on 1.1.15, no custom build.** Two mitigation layers:
1. **Reachability (primary):** 21116/UDP is LAN-only (zero inbound WAN ports; tunnel is HTTP-only) — internet attackers can't reach it. Abuse requires a LAN foothold.
2. **Default-deny egress (defense-in-depth, not elimination):** a reflected packet to an address with no active conntrack tuple is a NEW egress connection → dropped. Residual: a LAN attacker could still steer reflections at a *currently-registered peer* (active reverse UDP tuple) — victim set ≈ our own clients, amplification ×2–3, LAN-internal only. Conversely a legit punch-hole packet can be dropped if the peer's UDP tuple has conntrack-expired; heartbeat cadence normally keeps it warm.

Renovate (kubernetes manager, `apps/**` patch automerge + 3-day soak) picks up 1.1.16 when released. A self-built master image = supply-chain + renovate-blind cost against a LAN-foothold-only residual. Revisit if the server is ever WAN-exposed.

### Spike results (docker, mimicking pod securityContext)
- ✅ `-u 1000:1000 --read-only -w /data`: hbbs+hbbr run, keypair+db created in /data, ports listen. Non-root + readOnlyRootFilesystem viable. Cold start ≈10ms (log timestamps: keygen 22:54:55.236 → listeners up .246) → startupProbes unnecessary.
- ✅ hbbs and hbbr both run with `--network none` → **zero-egress NetworkPolicy safe**. Non-fatal ERRORs only (`Failed to store config` ×2 from HOME=/root read-only — silenced by `HOME=/data`; `Failed to generate new id` ×3 offline — harmless, server starts).
- ✅ hbbr reuses hbbs-generated key from shared dir ("Private key comes from id_ed25519").
- ✅ Tag `1.1.15` pulled and ran locally (arm64; amd64 manifest present for cluster).

## Scorecard — host RustDesk in this homelab?

| Dimension | Score /5 | Rationale |
|---|---|---|
| Value | 4 | Kills 3rd-party rendezvous dependency (privacy: public hbbs sees IDs/IPs); LAN-direct latency; free Pro-feature-less OSS covers point-to-point use |
| Platform fit | 5 | Blocky = exact precedent (mixed TCP+UDP LB, servicelb, ETP=Local); ~10Mi RAM footprint; no DB server needed |
| Security fit | 5 | scratch image, non-root + RoRFS spike-verified, key-enforced encryption, zero egress, PSS restricted clean |
| Ops burden | 5 | Renovate tracks pin via kubernetes manager; 100Mi PVC in existing daily backup; no migrations |
| Network fit (LAN) | 5 | servicelb + stable node IP; no UFW change (LAN→pod-CIDR forward rule already allows DNAT'd traffic — blocky-proven) |
| Network fit (WAN) | 1 | 21116/UDP required → Cloudflare Tunnel can't carry it; zero-inbound-ports invariant blocks port-forward. **LAN-only by design**; WAN later = WARP private network or VPN (out of scope) |
| **Overall** | **GO (LAN-only)** | Weighted verdict: high value, trivial cost, one hard limitation accepted up front |

## Assumptions & cut corners

| # | Claim | Tier |
|---|---|---|
| A1 | Non-root+RoRFS+workingDir=/data works | ✅ spike |
| A2 | Zero egress tolerated by both binaries | ✅ spike |
| A3 | Image tag 1.1.15 exists, multi-arch | ✅ pulled |
| A4 | Mixed-protocol LB Service works on this cluster | ✅ blocky live precedent |
| A5 | 2-commit ns bootstrap required (Kyverno require-networkpolicy vs Flux dry-run) | ✅ recorded gotcha 2026-07-14 |
| A6 | LAN client → nodeIP:2111x reaches pod without UFW change (DNAT→FORWARD path, `192.168.1.0/24 → 10.42.0.0/16` allow rule) | 🟡 blocky-proven for :53; verify for new ports at deploy verify step |
| A7 | `-k _` rejects clients lacking the key | 🟡 docs+source; verified functionally only at first client connect |
| A8 | Client relay inference (no `-r`) works on LAN | 🟡 docs; fallback = add `-r 192.168.1.129:21117` (still zero-egress impact is small: allow egress to 192.168.1.129/32:21117) |
| Cut | Web-client ports 21118/21119 not exposed | deliberate — no web client use |
| Cut | No metrics/alerts | OSS exposes none; uptime-kuma TCP monitor on 21116 = optional manual UI step |
| Cut | WAN access | LAN-only; revisit via WARP if ever needed |
| Cut | Single replica, Recreate | RWO PVC + pinned node; HA meaningless for 1-node LB anyway |

## Global constraints
- GitOps only; image pinned `1.1.15`; DB-username rule N/A (no DB server).
- Kyverno: SA non-default, `app` label, limits on all containers, non-root, RoRFS (+`/tmp` emptyDir per repo invariant), seccomp RuntimeDefault, drop ALL, no latest tag, NetworkPolicy present.
- PSS `restricted` namespace labels.
- NetworkPolicy ports = container ports (same numbers here; no remap).
- 2-commit bootstrap: commit 1 = ns+SA+NP (+apps/kustomization entry), commit 2 = workload.

---

### Task 1: Bootstrap commit — namespace, SA, NetworkPolicy

**Files:**
- Create: `apps/rustdesk/namespace.yaml`, `apps/rustdesk/serviceaccount.yaml`, `apps/rustdesk/networkpolicy.yaml`, `apps/rustdesk/kustomization.yaml`
- Modify: `apps/kustomization.yaml` (add `- rustdesk`)

`namespace.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: rustdesk
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

`serviceaccount.yaml`:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: rustdesk
  namespace: rustdesk
```

`networkpolicy.yaml`:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: rustdesk-network-policy
  namespace: rustdesk
spec:
  podSelector:
    matchLabels:
      app: rustdesk
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # RustDesk clients from anywhere (LAN via servicelb, source IP preserved by ETP=Local)
    - ports:
        - { protocol: TCP, port: 21115 }  # hbbs NAT-type test
        - { protocol: TCP, port: 21116 }  # hbbs TCP hole punch
        - { protocol: UDP, port: 21116 }  # hbbs ID registration/heartbeat
        - { protocol: TCP, port: 21117 }  # hbbr relay
  # No egress rules = default-deny egress. Spike-verified both binaries run offline;
  # update-check/machine-id lookups fail as non-fatal log lines.
```

`kustomization.yaml` (commit-1 shape):
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: rustdesk
resources:
  - namespace.yaml
  - serviceaccount.yaml
  - networkpolicy.yaml
```

- [ ] Step 1: Write the 4 files + add `- rustdesk` to `apps/kustomization.yaml` (alphabetical position not enforced in that file; append after `pricebuddy`).
- [ ] Step 2: Validate: `yamllint` the files; `kustomize build apps/rustdesk`; `kubeconform -strict`.
- [ ] Step 3: Commit `Add rustdesk namespace bootstrap (ns+SA+NetworkPolicy)` (worktree; single-line, no Claude mention).
- [ ] Step 4: **Reconcile barrier (sequencing-critical):** merge wt-rustdesk → main NOW (only commit 1 exists), push, `fr`, verify `kubectl get ns rustdesk` Active + NetworkPolicy present. Commit 2 must NOT exist on the branch until this barrier passes — Flux reconciles the branch HEAD, and dry-running the workload alongside an unpersisted ns/NP trips the Kyverno `require-networkpolicy` deny (2026-07-14 gotcha).

### Task 2: Workload commit — PVC, Deployment, Service, governance, backup

**Files:**
- Create: `apps/rustdesk/storage.yaml`, `apps/rustdesk/deployment.yaml`, `apps/rustdesk/service.yaml`, `infrastructure/configs/resource-governance/small-tier/rustdesk.yaml`
- Modify: `apps/rustdesk/kustomization.yaml` (add 3 resources), `infrastructure/configs/resource-governance/kustomization.yaml` (add entry if per-file listing), `infrastructure/configs/backup/pvc-backup-cronjob.yaml` (add `rustdesk/rustdesk-data/*rustdesk-data*` to CRITICAL_PVCS)

`storage.yaml`:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: rustdesk-data
  namespace: rustdesk
spec:
  storageClassName: local-path
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Mi
```

`deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rustdesk
  namespace: rustdesk
  labels:
    app: rustdesk
spec:
  replicas: 1
  revisionHistoryLimit: 2
  strategy:
    type: Recreate  # RWO PVC shared by both containers; no rolling overlap
  selector:
    matchLabels:
      app: rustdesk
  template:
    metadata:
      labels:
        app: rustdesk
    spec:
      serviceAccountName: rustdesk
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      # Pin to W1: servicelb ETP=Local → the node running the pod IS the client-facing
      # IP (192.168.1.129). Clients hardcode it; don't let the pod drift.
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/hostname
                    operator: In
                    values:
                      - worker-node
      containers:
        - name: hbbs
          image: rustdesk/rustdesk-server:1.1.15
          imagePullPolicy: IfNotPresent
          # -k _ = only clients presenting the server pubkey may connect.
          # No -r: clients infer relay = ID-server-host:21117; keeps hbbs egress-free.
          command: ["hbbs", "-k", "_"]
          workingDir: /data
          env:
            - name: HOME  # binary writes fallback config under $HOME; /root is RO scratch
              value: /data
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
          ports:
            - { containerPort: 21115, name: hbbs-nat, protocol: TCP }
            - { containerPort: 21116, name: hbbs-tcp, protocol: TCP }
            - { containerPort: 21116, name: hbbs-udp, protocol: UDP }
          resources:
            requests:
              cpu: "25m"
              memory: "32Mi"
            limits:
              cpu: "200m"
              memory: "128Mi"
          livenessProbe:
            tcpSocket: { port: 21116 }
            periodSeconds: 30
            failureThreshold: 3
          readinessProbe:
            tcpSocket: { port: 21116 }
            periodSeconds: 10
            failureThreshold: 3
          volumeMounts:
            - { name: data, mountPath: /data }
            - { name: tmp, mountPath: /tmp }
        - name: hbbr
          image: rustdesk/rustdesk-server:1.1.15
          imagePullPolicy: IfNotPresent
          command: ["hbbr", "-k", "_"]
          workingDir: /data
          env:
            - name: HOME
              value: /data
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
          ports:
            - { containerPort: 21117, name: hbbr-relay, protocol: TCP }
          resources:
            requests:
              cpu: "25m"
              memory: "32Mi"
            limits:
              cpu: "200m"
              memory: "128Mi"
          livenessProbe:
            tcpSocket: { port: 21117 }
            periodSeconds: 30
            failureThreshold: 3
          readinessProbe:
            tcpSocket: { port: 21117 }
            periodSeconds: 10
            failureThreshold: 3
          volumeMounts:
            - { name: data, mountPath: /data }
            - { name: tmp, mountPath: /tmp }
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: rustdesk-data
        - name: tmp
          emptyDir:
            sizeLimit: 16Mi
```

`service.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: rustdesk
  namespace: rustdesk
  annotations:
    description: "RustDesk hbbs+hbbr. Client-facing IP = 192.168.1.129 (W1 pin); .126 is advertised but blackholes by design. ETP=Local preserves client source IP."
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  ports:
    - { port: 21115, targetPort: 21115, protocol: TCP, name: hbbs-nat }
    - { port: 21116, targetPort: 21116, protocol: TCP, name: hbbs-tcp }
    - { port: 21116, targetPort: 21116, protocol: UDP, name: hbbs-udp }
    - { port: 21117, targetPort: 21117, protocol: TCP, name: hbbr-relay }
  selector:
    app: rustdesk
```

`infrastructure/configs/resource-governance/small-tier/rustdesk.yaml`: copy blocky.yaml shape (LimitRange `default-limits` + ResourceQuota `namespace-quota`), namespace `rustdesk`, `persistentvolumeclaims: "1"`.

- [ ] Step 1: Write files; extend `apps/rustdesk/kustomization.yaml` resources with `storage.yaml`, `deployment.yaml`, `service.yaml`; register governance file; add backup CRITICAL_PVCS line.
- [ ] Step 2: Validate ladder: yamllint → `kustomize build` → kubeconform -strict → `kubectl apply --dry-run=server -k apps/rustdesk` (after commit 1 reconciled).
- [ ] Step 3: Commit `Add rustdesk server (hbbs+hbbr) LAN remote desktop` .

### Task 3: Deploy commit 2 + verify
(Commit 1 already merged+reconciled via Task 1 Step 4 barrier.)
- [ ] Merge wt-rustdesk (commit 2) → main, push, `fr`.
- [ ] Verify: pod 2/2 Running on worker-node; `kubectl get svc -n rustdesk` status shows **both** `.126` and `.129` (servicelb pool behavior, expected); clients use `.129` only.
- [ ] A6 check: from Mac (LAN): TCP `nc -vz 192.168.1.129 21115/21116/21117` succeed; TCP against `.126` FAIL/timeout = the negative assertion (UDP `nc -vzu` exit status is NOT evidence either way — UDP scans false-positive).
- [ ] Retrieve client key: `kubectl exec -n rustdesk deploy/rustdesk -c hbbs -- cat /data/id_ed25519.pub`.
- [ ] Logs clean-ish: expect the harmless offline ERRORs, no crash loop.
- [ ] **Real-client e2e (A7):** Mac RustDesk app installed; settings PIN in 1Password item `RustDesk` notes. Two-phase: (a) configure ID server `192.168.1.129` with a WRONG key → expect "Key mismatch"/not-Ready (proves enforcement, A7-negative); (b) set the real pubkey → expect status **Ready** (proves UDP 21116 app path + key handshake + registration). Config via UI or `~/Library/Preferences/com.carriez.RustDesk/RustDesk2.toml` (`custom-rendezvous-server`, `key`), relaunch app between phases.
- [ ] **A8 residual (accepted):** relay inference through hbbr:21117 unproven until a real Mac↔iOS session (user action; force "always connect via relay" on the peer once to exercise hbbr explicitly). Recorded as open 🟡 in HOMELAB_ANALYSIS follow-up.

### Task 4: Docs
- [ ] `docs/HOMELAB_ANALYSIS.md`: 16→17 apps, ns counts.
- [ ] `docs/HOMELAB_HISTORY.md`: append entry.
- [ ] `docs/CODEMAPS/apps.md` + `docs/CODEMAPS/networking.md`: rustdesk rows (LB service, ports, LAN-only rationale).
- [ ] Client setup note (ID server/key) in HOMELAB_ANALYSIS or app row.
- [ ] Docs-only commit (review-gate exempt).
