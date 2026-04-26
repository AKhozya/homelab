# Architecture Codemap

**Cluster**: K3s v1.35.x staging, 3 nodes (1 CP + 2 workers).

## Nodes
| Hostname | IP | Role | OS |
|----------|-----|------|-----|
| `gmk-k3s-control-plane` | 192.168.1.127 | CP, etcd | Arch + zsh |
| `worker-node` (W1) | 192.168.1.129 | Worker, AdGuard-inherited apps | Arch + zsh |
| `worker-node-2` (W2) | 192.168.1.126 | Worker, Immich-pinned (mtime) | Arch + zsh |

CP NIC: Intel I225-V (`enp3s0`), forced 1Gbps + EEE off via `igc-tune@.service` (ansible role `nic_tuning`).

## GitOps Layer (Flux v2)
6 Kustomizations, dependency-ordered:
```
flux-system
  └─ infrastructure-controllers   (cert-manager, traefik, kyverno, CNPG operator, OT redis-op, Percona MySQL op)
       └─ infrastructure-configs  (cluster CRs, NetworkPolicies, ResourceQuotas, secrets, cronjobs, backup-replication)
            └─ monitoring-controllers   (kube-prometheus-stack chart, VictoriaMetrics op, Loki, Alloy)
                 └─ monitoring-configs  (VMRule, VMServiceScrape, dashboards, alertmanager templates)
                      └─ apps           (17 application stacks)
```

## Encryption
- **SOPS + age** (~55 SOPS-encrypted Secrets in git)
- Bootstrap key: `sops-age` Secret in `flux-system` ns
- Cloudflare Tunnel config also SOPS-encrypted

## Storage
- `local-path-provisioner` (default StorageClass)
- Worker-side mount roots: `/mnt/k8s-storage` (W1, root-only 0700), `/mnt/extra-storage` (W2)
- Replication topology: W1 → W2 (rsync --delete) → NAS (rsync daemon, port 50555)

## Identity / Auth
- **Authentik** = OIDC provider (PostgreSQL, no Redis — in-memory cache, passkey-first via Conditional UI)
- 11 apps integrated: Stirling PDF, Grafana, Immich, Paperless, HA, LinkWarden, Mealie, N8N (Enterprise), Audiobookshelf

## External access
- **Cloudflare Tunnel** (9 svcs): authentik, couchdb, audiobooks, linkwarden, stirling-pdf, mealie, paperless, immich, n8n
- **Internal**: Blocky DNS (W1+W2 LB IPs) + Traefik IngressRoute on port 443
- **Domain**: `h0melab.work` (cert-manager DNS-01 via Cloudflare API token)

## Cluster boundaries
- 28 namespaces (excl. system: kube-*, flux-system, default)
- 44 NetworkPolicies (every ingress + every cross-ns egress)
- 10 Kyverno ClusterPolicies (PSS Restricted enforce, image-pin, NP-required, default-SA-disallowed, drop-all-caps, etc.)
