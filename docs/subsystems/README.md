# Subsystem maps

These maps say where each part of the cluster lives, how the parts connect, and which gotchas apply. They describe the shape, not the live state. They are written for the people and AI agents who change the repo.

## Content rules

| Rule | Why |
|---|---|
| No image or chart versions; write "pinned in `<path>`" | versions change with every Renovate update |
| No counts; grep, or see [HOMELAB_ANALYSIS.md](../HOMELAB_ANALYSIS.md) | counts drift |
| No change log; see [HOMELAB_HISTORY.md](../HOMELAB_HISTORY.md) | keep the gotcha, not the story |
| Every fact names its source path | so a reader can check it |
| Freshness comes from `git log -1 --format=%cs -- <file>`, never a hand-written date | a hand-written date goes stale |
| A fact read from a SOPS file carries "verified <date>" and the command that decodes it | nobody can grep an encrypted file |

These files drift. Check a path before you act on it, and fix drift when you see it. CI skips docs-only pushes.

| File | Scope | Read when |
|------|-------|-----------|
| [`apps.md`](apps.md) | app → ns/storage/DB/SSO/external matrix; shared ingress/CSP/DB patterns | touching any app |
| [`networking.md`](networking.md) | endpoints, middlewares, NetworkPolicy invariants, Cloudflare Tunnel, DNS chain, TLS, UFW | ingress / NP / DNS / cert work |
| [`databases.md`](databases.md) | CNPG, Percona MySQL, Redis HA, CouchDB — shape, roles, restart matrix, engine gotchas | DB work |
| [`monitoring.md`](monitoring.md) | VictoriaMetrics stack wiring, rules, scrapes, relabel-drops, Alertmanager, Loki/Alloy | metrics / alerts / logs |
| [`backup-restore.md`](backup-restore.md) | backup layers, exclusions + reasons, replication + prune mechanics, DR scripts | backup / DR work |

Node table, SSH, hard invariants: [AGENTS.md](../../AGENTS.md). Design rationale + diagrams: [ARCHITECTURE.md](../ARCHITECTURE.md).

## Flux layout (paths)

```text
clusters/                          Flux Kustomizations (flat single-env prod, branch main)
└─ infrastructure-controllers      infrastructure/controllers/ — cert-manager, traefik, kyverno, DB operators
   ├─ coredns                      infrastructure/coredns/ — coredns-ha (own ks so DNS heals independently)
   ├─ infrastructure-configs       infrastructure/configs/ — DB CRs, NetworkPolicies, quotas, SOPS secrets, backups
   │  └─ apps                      apps/<name>/ + apps/components/ (allow-dns-egress Kustomize Component)
   └─ monitoring-controllers       monitoring/controllers/ — VM operator, kube-prometheus-stack, Loki, Alloy
      └─ monitoring-configs        monitoring/configs/ — VMRule, scrapes, dashboards, alert templates
```

SOPS edit: `sops <file>` opens decrypted in `$EDITOR`, re-encrypts on save; `sops -e -i <file>` encrypts in place after a manual write. Examples: [SECRETS_ROTATION.md](../SECRETS_ROTATION.md).
