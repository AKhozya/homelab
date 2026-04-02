# Homelab

Personal Kubernetes homelab running on K3s with GitOps automation, monitoring, and 16 self-hosted applications.

## What's Inside

**Infrastructure:**
- FluxCD for GitOps (everything in Git)
- CloudNativePG for PostgreSQL (2-node HA)
- Traefik + Cloudflare Tunnel for ingress
- Prometheus, Grafana, Loki for monitoring
- Renovate for automated dependency updates

**Applications:** Authentik (SSO), Home Assistant, Immich (photos), Paperless-NGX (documents), Obsidian sync, and [11 more](docs/HOMELAB_ANALYSIS.md#-current-apps-16-total).

**Security:** 100% Pod Security Standards compliance, NetworkPolicies everywhere, SOPS-encrypted secrets, daily backups.

## Quick Start

**Bootstrap Flux:**
```bash
flux reconcile source git flux-system
flux reconcile kustomization infrastructure-controllers infrastructure-configs
flux reconcile kustomization apps monitoring-controllers monitoring-configs
```

**Force Renovate run:** Check the Dependency Dashboard issue on GitHub.

**Disaster recovery:** See [.backup/README.md](.backup/README.md) for full restore procedures.

## Documentation

- **[HOMELAB_ANALYSIS.md](docs/HOMELAB_ANALYSIS.md)** - Complete infrastructure overview, security posture, metrics (A grade, 94/100)
- **[BACKUP_STRATEGY.md](docs/BACKUP_STRATEGY.md)** - Daily backups, retention policies, restore procedures
- **[SECRETS_ROTATION.md](docs/SECRETS_ROTATION.md)** - Credential rotation schedules and playbooks
- **[COMPREHENSIVE_CODEBASE_REVIEW.md](docs/COMPREHENSIVE_CODEBASE_REVIEW.md)** - Full security audit findings

## Monitoring

Prometheus → Alertmanager → Telegram for alerts. Custom rules for app failures, backup job status, and resource exhaustion.

**Check cluster health:**
```bash
kubectl get helmrelease -A
flux get kustomizations
```

## Secrets

All secrets encrypted with SOPS + age before commit. Never commit plaintext secrets.

**Decrypt a secret:**
```bash
sops -d infrastructure/configs/staging/databases/postgres/admin-secret.yaml
```

## Troubleshooting

- **Flux reconciliation failed?** Check `flux logs` and Telegram notifications
- **Pod stuck?** Likely NetworkPolicy blocking - check with `kubectl describe pod`
- **Backup issues?** See disaster recovery docs in `.backup/`

## Notes

This is a personal homelab, not production infrastructure. Some choices prioritize simplicity over enterprise HA (e.g., single Redis instance, accepted risk for certain CVEs).
