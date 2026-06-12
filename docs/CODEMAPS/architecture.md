# Architecture Codemap

**Cluster**: K3s v1.36.1+k3s1 **production** (single env — merge to `main` = deploy to prod), 3 nodes (1 CP + 2 workers), containerd 2.2.3-k3s1. Refreshed 2026-06-05.

## Nodes
| Hostname | IP | Role | OS |
|----------|-----|------|-----|
| `gmk-k3s-control-plane` | 192.168.1.127 | CP, etcd | Arch + zsh, SSH user `akhozya` |
| `worker-node` (W1) | 192.168.1.129 | Worker, hosts Immich PVs (local-path nodeAffinity) | Arch + zsh, SSH user `akhozya` |
| `worker-node-2` (W2) | 192.168.1.126 | Worker | Arch + zsh, **SSH user `z3us`** (different!) |

SSH port for all nodes: `65300`. Aliases: `ssh_master_node`, `ssh_worker_node`, `ssh_worker_node2`. No sudo over SSH (pam_faillock lockout risk).

CP NIC: Intel I225-V (`enp3s0`), forced 1Gbps + EEE off via `igc-tune@.service` (ansible role `nic_tuning`).

## GitOps Layer (Flux v2)
7 Kustomizations, dependency DAG (apps does NOT depend on monitoring — parallel chains):
```
flux-system (path ./clusters/staging — "staging" dir name = legacy artifact, env is PROD; branch main)
  └─ infrastructure-controllers   (cert-manager, traefik, kyverno, csp-reporter, DB operators: CNPG, OpsTree redis, Percona MySQL)
       ├─ coredns                 (coredns-ha DaemonSet in kube-system — own Kustomization so DNS heals independently)
       ├─ infrastructure-configs  (cluster CRs, NetworkPolicies, ResourceQuotas, secrets, cronjobs, backup-replication, kyverno-policies)
       │    └─ apps               (16 app stacks, flat apps/<app>; + components/ shared allow-dns-egress Kustomize component)
       └─ monitoring-controllers  (kube-prometheus-stack chart, VictoriaMetrics op, Loki, Alloy)
            └─ monitoring-configs (VMRule, VMServiceScrape, dashboards, alertmanager templates; flat monitoring/{controllers,configs})
```

## DNS & resilience
- **coredns-ha**: DaemonSet (Deployment→DaemonSet 2026-06-05 — wn2 had no local coredns pod, all pod-DNS rode VXLAN → 2026-06-04 wn2-only blackout). Never `--disable=coredns` (deletes addon-owned kube-dns objects Flux can't recreate — break-glass `kubectl apply -k infrastructure/coredns/`).
- **Blocky** = LAN DNS (apps/blocky, servicelb 1 LB IP per worker .129/.126, ETP=Local preserves source IP).
- **Node resolvers** = public DNS since 2026-06-04 (`c4fcd922`) — broke circular node→blocky dependency at boot.
- **CNPG** `main-postgres`: `failoverDelay: 30` + operator scheduled off W2 (`47fbf602`) — guards against spurious failover from flaky-node operator probes (2026-06-04 incident).

## Encryption
- **SOPS + age** (53 SOPS-encrypted files in git)
- Bootstrap key: `sops-age` Secret in `flux-system` ns
- Cloudflare Tunnel config also SOPS-encrypted (`cloudflared-config-secret.yaml` = source of truth for external hostnames)
- **Edit pattern**: `sops <file>` opens decrypted in `$EDITOR`, re-encrypts on save. Or `sops -e -i <file>` to encrypt-in-place after manual write.

## ⚠️ GitOps invariants
- **Never** `kubectl apply -f` without `--dry-run=server`. Commit to git → Flux reconciles in ≤60s.
- **Never** force-delete DB pods. Use CRDs (CNPG/Percona) + `kubectl rollout restart`.
- **Always** pin images `major.minor.patch-variant`. Floating tags drift silently (Kyverno only catches `:latest`/no-tag).
- **`readOnlyRootFilesystem: true`** requires `/tmp` emptyDir volume mount.
- **Every ingress → NetworkPolicy.** Dual access (internal + Cloudflare Tunnel) needs 2 ingress rules but 1 NP.

## Storage
- `local-path-provisioner` (default StorageClass)
- Worker-side mount roots: `/mnt/k8s-storage` (W1, root-only 0700), `/mnt/extra-storage` (W2)
- Replication topology: W1 → W2 (rsync --delete) → NAS (rsync daemon, port 50555)

## Identity / Auth
- **Authentik** = OIDC provider (PostgreSQL, no Redis — in-memory cache, passkey-first via Conditional UI)
- 8 apps integrated: Stirling PDF, Grafana, Immich, Paperless, HA (hass-oidc-auth v1.1.0, re-enabled 2026-05-31), LinkWarden, Mealie, Audiobookshelf
- N8N uses native user mgmt (no OIDC — Enterprise-plan-only feature)

## External access
- **Cloudflare Tunnel** (9 svcs, verified from SOPS config 2026-06-05): authentik, couchdb, audiobooks, linkwarden, stirling, mealie, paperless, immich, n8n. New external app = entry in central `cloudflared.yaml`, NOT a 2nd Ingress.
- **Internal**: Blocky DNS (see DNS section) + Traefik Ingress (class=traefik) on port 443 (Traefik in own `traefik` ns)
- **Domain**: `h0melab.work` (cert-manager DNS-01 via Cloudflare API token)

## Cluster boundaries
- 28 namespaces
- 64 NetworkPolicies live = 42 git manifests + `allow-dns-egress` Kustomize Component fanned into 14 app namespaces (Jobs excluded via `batch.kubernetes.io/job-name DoesNotExist`)
- 12 Kyverno ClusterPolicies — **9 Enforce, 3 Audit soak**: disallow-host-namespaces, disallow-host-path, disallow-latest-tag, disallow-privilege-escalation, require-drop-all-capabilities, require-networkpolicy, require-non-default-serviceaccount, require-readonly-rootfs, require-resource-limits (Enforce); require-labels, require-non-root, require-seccomp-runtimedefault (Audit)
