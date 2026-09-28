---
name: homelab-yaml-validate
description: "Use when editing or generating any K8s/Kustomize/Helm/Flux YAML in homelab repo before commit. Validation ladder — yamllint syntax, kubeconform -strict schema (offline), kubectl --dry-run=client parse, kubectl --dry-run=server schema+admission (Kyverno). Handles SOPS overlay caveat (unknown field sops) via kustomize build+grep or flux build kustomization. Catches schema drift, image-pin violations, missing resource limits, before commit/Flux reconcile."
user-invocable: false
---

# Homelab YAML Validation

## Fast path

```bash
bash ~/.agents/skills/homelab-yaml-validate/scripts/validate.sh <file.yaml> [<file2.yaml> ...]
bash ~/.agents/skills/homelab-yaml-validate/scripts/validate.sh --kustomize <path>
bash ~/.agents/skills/homelab-yaml-validate/scripts/validate.sh --flux <name> <path>
```

Stops at first failure. Each step prints `[PASS]` / `[FAIL]` / `[SKIP]`.

## Validation ladder (fastest → strictest)

### 1. Syntax — yamllint
```bash
yamllint -d '{extends: relaxed, rules: {line-length: disable}}' file.yaml
```
Catches indentation, duplicate keys, trailing whitespace. Frontmatter colons in descriptions need quoting — `description: Use X: Y` parses Y as nested mapping; quote the whole string.

### 2. Schema — kubeconform (offline, fast)
```bash
kubeconform -strict -summary -ignore-missing-schemas file.yaml
```
Catches CRD field drift offline (no cluster round-trip). Use `-ignore-missing-schemas` for custom CRDs (CNPG, Percona, VictoriaMetrics, Kyverno) since their schemas aren't in the default registry.

### 3. Client dry-run (parse + local validate)
```bash
kubectl apply -f file.yaml --dry-run=client
```
Validates YAML→object decoding. No cluster contact for schema, but already verifies API version + kind are known to the client.

### 4. Server dry-run (parse + schema + admission)
```bash
kubectl apply --dry-run=server -f file.yaml
```
PASS = manifest will reach the cluster. **Kyverno enforce policies run here** — catches image-pin violations, missing resource limits, NetworkPolicy gaps, PSS violations, before commit.

**Do NOT add `--server-side`** when validating an existing Flux-managed resource. Server-side apply checks field ownership and returns exit 1 with "Apply failed with 1 conflict: conflict with kustomize-controller: .spec.<X>" even though the manifest itself is valid — kustomize-controller (Flux) owns those fields. Plain `--dry-run=server` runs the same admission webhooks (Kyverno included) without the field-ownership check. Verified 2026-05-24 against `disallow-host-path` policy: `--server-side --dry-run=server` exit 1, plain `--dry-run=server` exit 0, both ran admission. If you genuinely need `--server-side` for some reason, add `--force-conflicts` to make exit 0 (dry-run takes ownership but nothing actually changes).

**Immutable-field false-positive — handled by `validate.sh`.** Editing a live `Job`'s `spec.template` (any immutable field) makes `--dry-run=server` fail with `field is immutable` (it attempts an UPDATE), even though the manifest is valid and Flux delete+recreates it via `kustomize.toolkit.fluxcd.io/force: enabled`. `validate.sh` auto-detects `field is immutable` + the `force` annotation and reports PASS. CI (offline kubeconform, no cluster) never hits it. (W8 2026-05-25, uptime-kuma-setup Job.)

**Kyverno `=()` optional-pattern footgun — LEGACY ClusterPolicy pattern syntax.** All 12 policies are CEL ValidatingPolicies since 2026-07-12; this applies only if pattern-based ClusterPolicy syntax ever returns (it's still in `.claude/review-invariants.md` as a rubric item). `=(field)` validated ONLY when the field existed — containers OMITTING it silently passed (omitting `allowPrivilegeEscalation` defaults to TRUE in Linux). Fix was the canonical PSS mandatory-pattern (W8 2026-05-25: `disallow-privilege-escalation`, `require-drop-all-capabilities`, `require-readonly-rootfs`). Do NOT hand-roll `deny: NotEquals` for booleans — `false || 'true'` JMESPath coercion. CEL policies don't have this class: absent fields are handled explicitly with `has()` / `orValue()` — review those instead.

### 4b. Init container resources — yq guard

Wave 1 ultrareview surfaced 5 init containers without resource limits. Local pre-commit guard:

```bash
yq -e '.spec.template.spec.initContainers // [] | all(.resources.limits.cpu and .resources.limits.memory)' file.yaml
```

PASS = all init containers have CPU + memory limits. FAIL (exit 1) = at least one omits; will violate Kyverno `require-resource-limits` Enforce (post-2026-05-23).

For multi-init deployments (home-assistant: `config-setup` + `hacs-install`), the `all(...)` predicate covers every entry. Operator-managed Pods (CNPG pooler, VMAgent) are excluded at the policy level — see `infrastructure/configs/kyverno-policies/require-resource-limits-vp.yaml` CEL guards (`exclude-cnpg-pooler`: `cnpg.io/podRole != 'pooler'`, `exclude-vm-operator`: `managed-by != 'vm-operator'`).

### 4c. Image pin audit — repo-wide

Kyverno's image-pin policy only rejects `:latest`/no-tag. Major-only (`:8`) or major.minor (`:1.0`, `:1.24`) tags float silently — the gap that hid `seleniumbase-scrapper:v1.0` + `claude-telegram-bot:1.24` (F-23, closed 2026-05-29). The `image-pin` job in `validate.yaml` runs it too, but CI is a signal, not a merge gate (AGENTS.md). Run locally before commit (exit 1 on any unpinned):

```bash
scripts/ci/image-pin-audit.sh .        # or apps / infrastructure / monitoring
```

PASS = `major.minor.patch[-variant]` or `@sha256:` digest. HelmRelease docs skipped (chart-version pinning), SOPS skipped, yq `---` doc-separators filtered. Allowlist (accept 2-component) for native-2-component upstreams: postgres/postgresql (`18.4`), seleniumbase-scrapper (upstream ships no patch tag). To add an upstream that legitimately lacks 3-component tags, extend `twocomp_ok_re` in the script.

### 4d. Helm chart render — every HelmRelease

`kubeconform` validates the HelmRelease custom resource, never the chart's own templates, so a
chart that rejects this repo's values passes every rung above and fails only in-cluster after Flux
applies it. If a commit touches any HelmRelease or the HelmRepository it resolves to, render
before committing:

```bash
scripts/ci/helm-render-check.sh .
```

PASS = every HelmRelease chart renders at its pinned version. The script sets its own
`HELM_REPOSITORY_CONFIG`, so it neither reads nor mutates locally registered repos. The same
script runs as the `helm-render` job in `validate.yaml`.

Renovate merged `kube-prometheus-stack` v90 on 2026-09-07 and the release then failed in prod:
chart 90.0.0 fails to render if an enabled control-plane component keeps its default
`serviceMonitor.authorization`, because the chart creates the Secret that field names only if
`prometheus.enabled` is true. This repo disables Prometheus. See `docs/HOMELAB_HISTORY.md`.

A skipped chart must never read as a passing one, so the script exits 1 on each of these:

| Condition | Why it is fatal |
|---|---|
| Discovery finds no manifest | The run proves nothing |
| `yq` cannot parse a manifest | That release never renders |
| Two HelmRepositories share a name | A release can render against the wrong source |
| `spec.chart.spec` is incomplete | Chart, version or sourceRef is missing |

### 5. Kustomize overlay
Use the fast path: `validate.sh --kustomize <path>` (already runs `kubectl kustomize` + exit-code check).

**Steps 1-4 cannot catch an overlay-level conflict — run this one too, or you ship a build failure
that passed every file check.** Adding 20 RoleBindings (one per target namespace) to
`apps/claude-telegram/` on 2026-08-02 passed yamllint, kubeconform, and both dry-runs, then broke
`kustomization/apps` for **every application** in the cluster: that directory's `kustomization.yaml`
sets `namespace: claude-telegram`, and the transformer rewrites `.metadata.namespace` on every
namespaced resource, collapsing all 20 onto one identity —
`namespace transformation produces ID conflict`. A build failure applies nothing, so it stalls
reconciliation rather than half-applying, but it blocks every app until reverted.

**Rule:** a resource whose namespace is *part of its meaning* (RoleBinding, ResourceQuota,
LimitRange, per-namespace NetworkPolicy) cannot live under a kustomization that sets `namespace:`.
Put it where `infrastructure/configs/resource-governance/` puts its per-namespace objects — a
directory whose `kustomization.yaml` has **no** `namespace:` transformer — and leave a comment
saying why, because the obvious tidy-up is to move it back beside the app it belongs to.

## SOPS-encrypted overlays — caveat

Server dry-run fails with `strict decoding error: unknown field "sops"` on any kustomization whose Secret has a `sops:` block. The script auto-detects this and emits `[SKIP]`. Two workarounds:

### A. Build + grep (cheap, works without cluster decrypt key)
```bash
kubectl kustomize <path> > /tmp/built.yaml
echo "exit=$?"
grep -iE '<expected-removed-string>' /tmp/built.yaml && echo FAIL || echo PASS
```

### B. Flux build (decrypts via cluster's kustomize-controller Secret)
```bash
flux build kustomization <name> --path <path> --kustomization-file clusters/<cluster>.yaml
```

## When plain `kustomize build` FAILS but the cluster is fine (Flux root/bootstrap paths)

The kustomize-controller is NOT `kustomize build`: it **auto-generates `kustomization.yaml`** when absent at `spec.path` (recursive) and runs `LoadRestrictionsNone` (permits `../../` parent-escape refs). So a valid, reconciling path can fail the CLI. Two CLI symptoms that are NOT real errors — do NOT read them as a wedge:
- `unable to find one of 'kustomization.yaml' … in directory <dir>` → Flux auto-gens one; the path is fine.
- `… is not in or below <root>` (security/load-restrictor) on `../../*.yaml` refs → add `--load-restrictor LoadRestrictionsNone`.

Replicate the controller instead: `flux build kustomization <name> --path <path> --kustomization-file <gotk-sync.yaml | clusters/<cluster>.yaml> --dry-run` (auto-gens + LoadRestrictionsNone, no cluster needed). This is the authoritative "will Flux build it" check — use it before claiming a path migration deadlocks. (2026-06-12 bootstrap flatten: cavecrew false-flagged a deadlock from a `kustomize build` failure; `flux build` exit 0 refuted it.) The flat `clusters/` layout has no `../../` escape → plain `kustomize build clusters` works + is CI-eligible.

## Homelab invariants to verify in built output

Beyond schema/admission, eyeball or grep:

- Every container (including init) has `resources.{requests,limits}.{cpu,memory}` — Kyverno enforces
- `readOnlyRootFilesystem: true` → `/tmp` emptyDir mounted
- DB users:

  | Engine | How the user exists |
  |---|---|
  | Postgres | Secret labels `cnpg.io/cluster: main-postgres` + `cnpg.io/reload: "true"`, role in `managed.roles` |
  | MySQL | No Percona `User` CR exists. Create the user by hand with SQL (`CREATE USER` + `GRANT`) through `db-operations/scripts/mysql-exec.sh`. Add its `CREATE USER` line, with a placeholder password, to `docs/disaster-recovery/mysql-create-dbs.sql`. |
- New namespace: add the ResourceQuota (governance entry) in a SECOND commit, after Flux has created the namespace. If the quota comes first, `infrastructure-configs` fails to reconcile, and `apps`, which depends on it, stops reconciling too (2-commit bootstrap, `/app-scaffold`)

Other invariants live in canonical skills:
- Image pinning + DB username = app name → `/app-scaffold`
- Dual ingress (internal + CF Tunnel) + container-port-not-service-port → `/networkpolicy-helper`

## After validation passes

Commit, push, `fr` (Flux reconcile zsh function). See `/gitops-workflow` for the full flow.

## CI backstop

`.github/workflows/validate.yaml` re-runs these gates repo-wide. If a push changes only markdown or `docs/images/**`, `paths-ignore` skips it. gitleaks runs separately in `gitleaks.yaml`, which carries no `paths-ignore`.

CI is a post-push signal, not a gate. Branch protection is unavailable on this plan. If CI is red, do not run `fr`. Withholding `fr` delays reconciliation until Flux polls `main`, which it does every 5 min. It does not prevent deployment. Read the fetched revision with `flux get source git flux-system`. This validation ladder and the pre-commit review loop can stop the commit, because both run before it exists.

## Tools

All in `~/.Brewfile`: `yamllint`, `kubeconform`, `kubectl`, `flux`. Confirm with `command -v <tool>` if missing.
