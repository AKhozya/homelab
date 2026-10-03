# Homelab YAML Validation — edge cases

Read this when a validation step gives a result you do not expect, or when you need the detail behind a rung.

## Immutable-field false positive

**Immutable-field false-positive — handled by `validate.sh`.** Editing a live `Job`'s `spec.template` (any immutable field) makes `--dry-run=server` fail with `field is immutable` (it attempts an UPDATE), even though the manifest is valid and Flux delete+recreates it via `kustomize.toolkit.fluxcd.io/force: enabled`. `validate.sh` auto-detects `field is immutable` + the `force` annotation and reports PASS. CI (offline kubeconform, no cluster) never hits it. (W8 2026-05-25, uptime-kuma-setup Job.)

## Init container guard — background

Wave 1 ultrareview surfaced 5 init containers without resource limits.

For multi-init deployments (home-assistant: `config-setup` + `hacs-install`), the `all(...)` predicate covers every entry. Operator-managed Pods (CNPG pooler, VMAgent) are excluded at the policy level — see `infrastructure/configs/kyverno-policies/require-resource-limits-vp.yaml` CEL guards (`exclude-cnpg-pooler`: `cnpg.io/podRole != 'pooler'`, `exclude-vm-operator`: `managed-by != 'vm-operator'`).

## Image pin audit — rules and allowlist

Major-only (`:8`) or major.minor (`:1.0`, `:1.24`) tags float silently — the gap that hid `seleniumbase-scrapper:v1.0` + `claude-telegram-bot:1.24` (F-23, closed 2026-05-29). The `image-pin` job in `validate.yaml` runs it too, but CI is a signal, not a merge gate (AGENTS.md).

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

## Server-side apply conflict

Server-side apply checks field ownership and returns exit 1 with "Apply failed with 1 conflict: conflict with kustomize-controller: .spec.<X>" even though the manifest itself is valid — kustomize-controller (Flux) owns those fields. Plain `--dry-run=server` runs the same admission webhooks (Kyverno included) without the field-ownership check. Verified 2026-05-24 against `disallow-host-path` policy: `--server-side --dry-run=server` exit 1, plain `--dry-run=server` exit 0, both ran admission.

## Legacy Kyverno pattern fix (W8)

Fix was the canonical PSS mandatory-pattern (W8 2026-05-25: `disallow-privilege-escalation`, `require-drop-all-capabilities`, `require-readonly-rootfs`).

## Helm chart render — repo config and CI

`scripts/ci/helm-render-check.sh` sets its own
`HELM_REPOSITORY_CONFIG`, so it neither reads nor mutates locally registered repos. The same
script runs as the `helm-render` job in `validate.yaml`.

## Kustomize namespace-transformer conflict

**Steps 1-4 cannot catch an overlay-level conflict — run SKILL.md step 5 (Kustomize overlay) too, or you ship a build failure
that passed every file check.** Adding 20 RoleBindings (one per target namespace) to
`apps/claude-telegram/` on 2026-08-02 passed yamllint, kubeconform, and both dry-runs, then broke
`kustomization/apps` for **every application** in the cluster: that directory's `kustomization.yaml`
sets `namespace: claude-telegram`, and the transformer rewrites `.metadata.namespace` on every
namespaced resource, collapsing all 20 onto one identity —
`namespace transformation produces ID conflict`. A build failure applies nothing, so it stalls
reconciliation rather than half-applying, but it blocks every app until reverted.

## CI backstop — limits

If a push changes only markdown or `docs/images/**`, `paths-ignore` skips it. gitleaks runs separately in `gitleaks.yaml`, which carries no `paths-ignore`. Branch protection is unavailable on this plan. Withholding `fr` delays reconciliation until Flux polls `main`, which it does every 5 min. It does not prevent deployment. This validation ladder and the pre-commit review loop can stop the commit, because both run before it exists.

## Tools

All in `~/.Brewfile`: `yamllint`, `kubeconform`, `kubectl`, `flux`. Confirm with `command -v <tool>` if missing.

## What steps 1-3 check

### 1. yamllint

Catches indentation, duplicate keys, trailing whitespace. Frontmatter colons in descriptions need quoting — `description: Use X: Y` parses Y as nested mapping; quote the whole string.

### 2. kubeconform

Catches CRD field drift offline (no cluster round-trip).

### 3. Client dry-run

Validates YAML→object decoding. No cluster contact for schema, but already verifies API version + kind are known to the client.

## Flux build vs kustomize build — background

(2026-06-12 bootstrap flatten: cavecrew false-flagged a deadlock from a `kustomize build` failure; `flux build` exit 0 refuted it.) The flat `clusters/` layout has no `../../` escape → plain `kustomize build clusters` works + is CI-eligible.

## New namespace — why the quota waits

If the quota comes first, `infrastructure-configs` fails to reconcile, and `apps`, which depends on it, stops reconciling too (2-commit bootstrap, `/app-scaffold`)
