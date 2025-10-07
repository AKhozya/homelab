
# Homelab

Kubernetes homelab GitOps automation and disaster recovery.

## Features

- Automated cluster management with FluxCD
- Dependency updates managed by Renovate
- Disaster recovery scripts and backup strategy

## Quickstart

1. **Reconcile Flux:**



	```bash
	flux reconcile source git flux-system && flux reconcile kustomization infrastructure-controllers
	```
- Renovate runs automatically and creates PRs for dependency updates.
- To force a run, use the Dependency Dashboard issue in GitHub.
2. **Trigger Renovate:**
- See [.backup/README.md](.backup/README.md) for full disaster recovery instructions.

	- Renovate runs automatically and creates PRs for dependency updates.
	- To force a run, use the Dependency Dashboard issue in GitHub.

3. **Restore from Backup:**


	- See [.backup/README.md](.backup/README.md) for full disaster recovery instructions.

## Renovate

- Auto-merges minor and patch updates directly to branch
- Groups updates for Flux, Helm, Prometheus stack, Traefik
- Pins digests for Docker images and Helm charts for reproducibility
- Requires manual review for major updates

## Documentation

- [Disaster Recovery Guide](.backup/README.md)
- [Backup Scripts and Best Practices](.backup/STORAGE_BEST_PRACTICES.md)


# Homelab

Kubernetes homelab GitOps automation and disaster recovery.

## Features

- Automated cluster management with FluxCD
- Dependency updates managed by Renovate
- Disaster recovery scripts and backup strategy

## Quickstart

1. **Reconcile Flux:**

	```bash
	flux reconcile source git flux-system && flux reconcile kustomization infrastructure-controllers
	```

2. **Trigger Renovate:**

	- Renovate runs automatically and creates PRs for dependency updates.
	- To force a run, use the Dependency Dashboard issue in GitHub.

3. **Restore from Backup:**

	- See [.backup/README.md](.backup/README.md) for full disaster recovery instructions.

## Renovate

- Auto-merges minor and patch updates directly to branch
- Groups updates for Flux, Helm, Prometheus stack, Traefik
- Pins digests for Docker images and Helm charts for reproducibility
- Requires manual review for major updates

## Documentation

- [Disaster Recovery Guide](.backup/README.md)
- [Backup Scripts and Best Practices](.backup/STORAGE_BEST_PRACTICES.md)

## Contributing

- Fork the repo, make changes, and open a PR
- Use the provided scripts for backup and recovery
