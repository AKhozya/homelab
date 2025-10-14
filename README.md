# Homelab

Kubernetes homelab GitOps automation, monitoring, and disaster recovery.

## Features

- Automated cluster management with FluxCD (GitOps)
- Dependency updates managed by Renovate
- Disaster recovery scripts and backup strategy
- Monitoring and alerting with Prometheus, Alertmanager, Telegram
- Secrets management with SOPS and age encryption
- Storage best practices and backup automation

## Quickstart

1. **Bootstrap Flux:**

```bash
flux reconcile source git flux-system && flux reconcile kustomization infrastructure-controllers
flux reconcile kustomization apps --namespace flux-system
flux reconcile kustomization monitoring-controllers --namespace flux-system
flux reconcile kustomization monitoring-configs --namespace flux-system
flux reconcile kustomization infrastructure-configs --namespace flux-system
```

2. **Trigger Renovate:**

- Renovate runs automatically and creates PRs for dependency updates.
- To force a run, use the Dependency Dashboard issue in GitHub.

3. **Restore from Backup:**

- See [.backup/README.md](.backup/README.md) for full disaster recovery instructions.

## Monitoring & Alerting

- Prometheus and Alertmanager monitor cluster health and workloads
- Telegram notifications for critical events and Flux reconciliation
- Custom rules for app and infrastructure failures

## Secrets Management

- All secrets are encrypted with SOPS and age before being committed or backed up
- Never store unencrypted secrets in git or cloud storage
- Rotate credentials after restore

## Obsidian Sync Setup

CouchDB is configured for secure Obsidian note synchronization across devices.

**Get Credentials:**
```bash
./get-obsidian-credentials.sh
```

**Setup Guide:**
- [CouchDB Cloudflare Access Setup](infrastructure/configs/staging/couchdb/CLOUDFLARE_ACCESS_SETUP.md)
- [Service Tokens Template](infrastructure/configs/staging/couchdb/SERVICE_TOKENS_TEMPLATE.md)

**Current Status:**
- ✅ CouchDB running with 1 replica, 30GB storage
- ✅ Database initialized with user permissions
- ✅ Cloudflare tunnel configured for secure access

## Renovate

- Auto-merges minor and patch updates directly to branch
- Groups updates for Flux, Helm, Prometheus stack, Traefik
- Pins digests for Docker images and Helm charts for reproducibility
- Requires manual review for major updates

## Documentation

- [Disaster Recovery Guide](.backup/README.md)
- [Backup Scripts and Best Practices](.backup/STORAGE_BEST_PRACTICES.md)

## Troubleshooting & Support

- If reconciliation fails, check Flux logs and Telegram notifications
- For backup/restore issues, see disaster recovery docs
- For secrets issues, verify SOPS encryption and age key setup

## Contributing

- Fork the repo, make changes, and open a PR
- Use the provided scripts for backup and recovery
## Renovate
