# Homelab YAML Validation — edge cases

Read this when a validation step gives a result you do not expect, or when you need the detail behind a rung.

## Immutable-field false positive

**Immutable-field false-positive — handled by `validate.sh`.** Editing a live `Job`'s `spec.template` (any immutable field) makes `--dry-run=server` fail with `field is immutable` (it attempts an UPDATE), even though the manifest is valid and Flux delete+recreates it via `kustomize.toolkit.fluxcd.io/force: enabled`. `validate.sh` auto-detects `field is immutable` + the `force` annotation and reports PASS. CI (offline kubeconform, no cluster) never hits it. (W8 2026-05-25, uptime-kuma-setup Job.)

## Init container guard — background

For multi-init deployments (home-assistant: `config-setup` + `hacs-install`), the `all(...)` predicate covers every entry. Operator-managed Pods (CNPG pooler, VMAgent) are excluded at the policy level — see `infrastructure/configs/kyverno-policies/require-resource-limits-vp.yaml` CEL guards (`exclude-cnpg-pooler`: `cnpg.io/podRole != 'pooler'`, `exclude-vm-operator`: `managed-by != 'vm-operator'`).

## Image pin audit — rules and allowlist

PASS = `major.minor.patch[-variant]` or `@sha256:` digest. HelmRelease docs skipped (chart-version pinning), SOPS skipped, yq `---` doc-separators filtered. Allowlist (accept 2-component) for native-2-component upstreams: postgres/postgresql (`18.4`). seleniumbase-scrapper left the allowlist on 2026-10-02, when upstream published `v1.0.1`. To add an upstream that legitimately lacks 3-component tags, extend `twocomp_ok_re` in the script.

## Helm chart render — incident and fatal conditions

Renovate merged `kube-prometheus-stack` v90 on 2026-09-07 and the release then failed in prod:
chart 90.0.0 fails to render if an enabled control-plane component keeps its default
`serviceMonitor.authorization`, because the chart creates the Secret that field names only if
`prometheus.enabled` is true. This repo disables Prometheus. See commit `b46d0803` (2026-09-07).

A skipped chart must never read as a passing one, so the script exits 1 on each of these:

| Condition | Why it is fatal |
|---|---|
| Discovery finds no manifest | The run proves nothing |
| `yq` cannot parse a manifest | That release never renders |
| Two HelmRepositories share a name | A release can render against the wrong source |
| `spec.chart.spec` is incomplete | Chart, version or sourceRef is missing |

## DB users

- DB users:

| Engine | How the user exists |
|---|---|
| Postgres | Secret labels `cnpg.io/cluster: main-postgres` + `cnpg.io/reload: "true"`, role in `managed.roles` |
| MySQL | No Percona `User` CR exists. Create the user by hand with SQL (`CREATE USER` + `GRANT`) through `db-operations/scripts/mysql-exec.sh <db> -`, with the SQL on stdin so the password stays out of argv. Add its `CREATE USER` line, with a placeholder password, to `docs/disaster-recovery/mysql-create-dbs.sql`. |
