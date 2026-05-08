# Codemaps

Token-lean architecture references for AI agents (and humans). Update when major structural changes happen.

| File | Scope |
|------|-------|
| [`architecture.md`](architecture.md) | Cluster topology, GitOps tree, identity, external access |
| [`apps.md`](apps.md) | 17 application stacks, ns/storage/DB/SSO mapping |
| [`networking.md`](networking.md) | Ingress, Services, NetworkPolicies, Cloudflare Tunnel, DNS chain, TLS |
| [`databases.md`](databases.md) | PG (CNPG), MySQL (Percona), Redis HA (OT operator), CouchDB; backup CronJobs |
| [`monitoring.md`](monitoring.md) | VictoriaMetrics stack, VMRule, dashboards, Loki/Alloy; Prometheus DECOMMISSIONED |
| [`backup-restore.md`](backup-restore.md) | DR strategy, replication topology, .backup scripts, what's NOT backed up |

## When to update
- New app added → update `apps.md` + relevant per-domain map
- DB / NetworkPolicy / monitoring CRD changes → update appropriate codemap
- Architecture / GitOps / identity changes → update `architecture.md`
- **Monthly review** → diff against current cluster state, fix drift (see `HOMELAB_ANALYSIS.md` Monthly Review Checklist item 3)
- Quarterly review → full audit pass alongside `/automation-audit-ops`

## Source of truth
- Operational state: `docs/HOMELAB_ANALYSIS.md`
- Historical changelog: `docs/HOMELAB_HISTORY.md`
- Codemaps = stable structural snapshots, NOT live state. Refresh when major changes land.
