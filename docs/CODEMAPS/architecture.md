# Architecture Codemap

**Cluster**: K3s v1.35.x staging, 3 nodes (1 CP + 2 workers).

## Nodes
| Hostname | IP | Role | OS |
|----------|-----|------|-----|
| `gmk-k3s-control-plane` | 192.168.1.127 | CP, etcd | Arch + zsh, SSH user `akhozya` |
| `worker-node` (W1) | 192.168.1.129 | Worker, hosts Immich PVs (local-path nodeAffinity) | Arch + zsh, SSH user `akhozya` |
| `worker-node-2` (W2) | 192.168.1.126 | Worker | Arch + zsh, **SSH user `z3us`** (different!) |

SSH port for all nodes: `65300`. Aliases: `ssh_master_node`, `ssh_worker_node`, `ssh_worker_node2`. Claude has NO sudo over SSH (pam_faillock lockout risk).

CP NIC: Intel I225-V (`enp3s0`), forced 1Gbps + EEE off via `igc-tune@.service` (ansible role `nic_tuning`).

## GitOps Layer (Flux v2)
6 Kustomizations, dependency-ordered:
```
flux-system
  └─ infrastructure-controllers   (cert-manager, traefik, kyverno, CNPG operator, OT redis-op, Percona MySQL op)
       └─ infrastructure-configs  (cluster CRs, NetworkPolicies, ResourceQuotas, secrets, cronjobs, backup-replication)
            └─ monitoring-controllers   (kube-prometheus-stack chart, VictoriaMetrics op, Loki, Alloy)
                 └─ monitoring-configs  (VMRule, VMServiceScrape, dashboards, alertmanager templates)
                      └─ apps           (16 application stacks)
```

## Encryption
- **SOPS + age** (53 SOPS-encrypted Secrets in git)
- Bootstrap key: `sops-age` Secret in `flux-system` ns
- Cloudflare Tunnel config also SOPS-encrypted
- **Edit pattern**: `sops <file>` opens decrypted in `$EDITOR`, re-encrypts on save. Or `sops -e -i <file>` to encrypt-in-place after manual write.

## ⚠️ GitOps invariants
- **Never** `kubectl apply -f` without `--dry-run=server` (hook blocks). Commit to git → Flux reconciles in ≤60s.
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
- 8 apps integrated: Stirling PDF, Grafana, Immich, Paperless, HA, LinkWarden, Mealie, Audiobookshelf
- N8N uses native user mgmt (no OIDC — Enterprise-plan-only feature)

## External access
- **Cloudflare Tunnel** (9 svcs): authentik, couchdb, audiobooks, linkwarden, stirling-pdf, mealie, paperless, immich, n8n
- **Internal**: Blocky DNS (W1+W2 LB IPs) + Traefik Ingress (class=traefik) on port 443 (Traefik in own `traefik` ns)
- **Domain**: `h0melab.work` (cert-manager DNS-01 via Cloudflare API token)

## Cluster boundaries
- 27 namespaces (excl. system: kube-*, flux-system, default)
- 44 NetworkPolicies (every ingress + every cross-ns egress)
- 10 Kyverno ClusterPolicies — 7 Enforce (disallow-host-namespaces, disallow-latest-tag, disallow-privilege-escalation, require-drop-all-capabilities, require-labels, require-non-default-serviceaccount, require-seccomp-runtimedefault) + 3 Audit (disallow-host-path, require-non-root, require-resource-limits)
