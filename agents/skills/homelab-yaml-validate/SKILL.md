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

### 2. Schema — kubeconform (offline, fast)
```bash
kubeconform -strict -summary -ignore-missing-schemas file.yaml
```
Use `-ignore-missing-schemas` for custom CRDs (CNPG, Percona, VictoriaMetrics, Kyverno) since their schemas aren't in the default registry.

### 3. Client dry-run (parse + local validate)
```bash
kubectl apply -f file.yaml --dry-run=client
```

### 4. Server dry-run (parse + schema + admission)
```bash
kubectl apply --dry-run=server -f file.yaml
```
PASS = manifest will reach the cluster. **Kyverno enforce policies run here** — catches image-pin violations, missing resource limits, NetworkPolicy gaps, PSS violations, before commit.

**Do NOT add `--server-side`** when validating an existing Flux-managed resource. If you genuinely need `--server-side` for some reason, add `--force-conflicts` to make exit 0 (dry-run takes ownership but nothing actually changes).

If you need the reason for the `--server-side` rule, read `reference-edge-cases.md` § "Server-side apply conflict".

If `--dry-run=server` reports `field is immutable` on a live Job, read `reference-edge-cases.md` § "Immutable-field false positive".

**Kyverno `=()` optional-pattern footgun — LEGACY ClusterPolicy pattern syntax.** All 12 policies are CEL ValidatingPolicies since 2026-07-12; this applies only if pattern-based ClusterPolicy syntax ever returns (it's still in `.claude/review-invariants.md` as a rubric item). `=(field)` validated ONLY when the field existed — containers OMITTING it silently passed (omitting `allowPrivilegeEscalation` defaults to TRUE in Linux). Do NOT hand-roll `deny: NotEquals` for booleans — `false || 'true'` JMESPath coercion. CEL policies don't have this class: absent fields are handled explicitly with `has()` / `orValue()` — review those instead.

### 4b. Init container resources — yq guard

Local pre-commit guard:

```bash
yq -e '.spec.template.spec.initContainers // [] | all(.resources.limits.cpu and .resources.limits.memory)' file.yaml
```

PASS = all init containers have CPU + memory limits. FAIL (exit 1) = at least one omits; will violate Kyverno `require-resource-limits` Enforce (post-2026-05-23).

If a Pod has more than one init container, or an operator manages it, read `reference-edge-cases.md` § "Init container guard — background".

### 4c. Image pin audit — repo-wide

Kyverno's image-pin policy only rejects `:latest`/no-tag. Run locally before commit (exit 1 on any unpinned):

```bash
scripts/ci/image-pin-audit.sh .        # or apps / infrastructure / monitoring
```

If the audit flags a tag you believe is pinned, or an upstream publishes only two-component tags, read `reference-edge-cases.md` § "Image pin audit — rules and allowlist".

### 4d. Helm chart render — every HelmRelease

`kubeconform` validates the HelmRelease custom resource, never the chart's own templates, so a
chart that rejects this repo's values passes every rung above and fails only in-cluster after Flux
applies it. If a commit touches any HelmRelease or the HelmRepository it resolves to, render
before committing:

```bash
scripts/ci/helm-render-check.sh .
```

PASS = every HelmRelease chart renders at its pinned version.

If the script exits 1, read `reference-edge-cases.md` § "Helm chart render — incident and fatal conditions".
If the script skips a chart, do not count that chart as passed.

### 5. Kustomize overlay
Use the fast path: `validate.sh --kustomize <path>` (already runs `kubectl kustomize` + exit-code check).

If steps 1-4 pass, still run step 5. Read `reference-edge-cases.md` § "Kustomize namespace-transformer conflict" for the reason.

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

Replicate the controller instead: `flux build kustomization <name> --path <path> --kustomization-file <gotk-sync.yaml | clusters/<cluster>.yaml> --dry-run` (auto-gens + LoadRestrictionsNone, no cluster needed). This is the authoritative "will Flux build it" check — use it before claiming a path migration deadlocks.

## Homelab invariants to verify in built output

Beyond schema/admission, eyeball or grep:

- Every container (including init) has `resources.{requests,limits}.{cpu,memory}` — Kyverno enforces
- `readOnlyRootFilesystem: true` → `/tmp` emptyDir mounted
- If you add a Postgres or MySQL user, read `reference-edge-cases.md` § "DB users".
  If you add a MySQL user's `CREATE USER` line to `docs/disaster-recovery/mysql-create-dbs.sql`, use a placeholder password, never the real one.
  If you create a MySQL user by hand, pass the SQL on stdin so the password stays out of argv.
- New namespace: add the ResourceQuota (governance entry) in a SECOND commit, after Flux has created the namespace.

Other invariants live in canonical skills:
- Image pinning + DB username = app name → `/app-scaffold`
- Dual ingress (internal + CF Tunnel) + container-port-not-service-port → `/networkpolicy-helper`

## After validation passes

Commit, push, `fr` (Flux reconcile zsh function). See `/gitops-workflow` for the full flow.

## CI backstop

`.github/workflows/validate.yaml` re-runs these gates repo-wide.

CI is a post-push signal, not a gate. If CI is red, do not run `fr`. Read the fetched revision with `flux get source git flux-system`. If you need what withholding `fr` does not stop, read `reference-edge-cases.md` § "CI backstop — limits".
