# Homelab

Personal K8s homelab on K3s. GitOps, monitoring, 16 self-hosted apps.

## What's Inside

**Infra:**
- FluxCD GitOps (all in Git)
- CloudNativePG PostgreSQL (2-node HA)
- Traefik + Cloudflare Tunnel ingress
- VictoriaMetrics, Grafana, Loki monitoring
- Renovate auto-updates

**Apps:** Authentik (SSO), Home Assistant, Immich (photos), Paperless-NGX (docs), Obsidian sync, [11 more](docs/HOMELAB_ANALYSIS.md#-current-apps-16-total).

**Security:** 100% PSS compliance, NetworkPolicies everywhere, SOPS-encrypted secrets, daily backups.

## Quick Start

**Bootstrap Flux:**
```bash
flux reconcile source git flux-system
flux reconcile kustomization infrastructure-controllers infrastructure-configs
flux reconcile kustomization apps monitoring-controllers monitoring-configs
```

**Force Renovate run:** Check Dependency Dashboard issue on GitHub.

**Disaster recovery:** [.backup/README.md](.backup/README.md) — full restore.

## Docs

- **[HOMELAB_ANALYSIS.md](docs/HOMELAB_ANALYSIS.md)** — infra overview, security, metrics (A grade, 94/100)
- **[BACKUP_STRATEGY.md](docs/BACKUP_STRATEGY.md)** — daily backups, retention, restore
- **[SECRETS_ROTATION.md](docs/SECRETS_ROTATION.md)** — credential rotation schedules

## Monitoring

VMAlert → Alertmanager → Telegram. VMRules for app failures, backup status, resource exhaustion.

**Health check:**
```bash
kubectl get helmrelease -A
flux get kustomizations
```

## Secrets

SOPS + age encrypt before commit. Never commit plaintext.

**Decrypt:**
```bash
sops -d infrastructure/configs/databases/postgres/admin-secret.yaml
```

## Troubleshooting

- **Flux fail?** `flux logs` + Telegram
- **Pod stuck?** NetworkPolicy block — `kubectl describe pod`
- **Backup fail?** `.backup/` docs

## Notes

Personal homelab, not production. Some choices prioritise simplicity (not 100% of infra is HA).
