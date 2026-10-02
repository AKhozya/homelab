---
name: app-scaffold
description: Use when adding or editing an app in the homelab K3s cluster. Provides conventions and the 2-commit bootstrap checklist (DB role + app), ingress middlewares, NetworkPolicy, SOPS, Kyverno, dual-ingress (internal + Cloudflare Tunnel), image pinning, and OIDC.
user-invocable: false
---

# App Scaffold Skill

## When to Activate

- Adding new app under `apps/<app>/`
- Modifying ingress, NetworkPolicy, secrets, or resource limits on existing app
- Refactoring app deployment manifests

## Required files per app

```
apps/<app>/                   # all manifests in ONE flat dir (single-env; F-13 collapsed base/staging)
├── kustomization.yaml        # sets `namespace: <app>`; lists every file; `components: [../components/allow-dns-egress]` for DNS
├── namespace.yaml            # ns = bare app name
├── serviceaccount.yaml
├── deployment.yaml           # or statefulset.yaml
├── service.yaml
├── storage.yaml              # PVCs
├── networkpolicy.yaml        # MANDATORY for every ingress
├── ingress.yaml              # internal Traefik only — tunnel is central, see Ingress conventions
├── certificate.yaml          # cert-manager → <app>-tls-secret
├── <secret>.yaml             # SOPS-encrypted
└── *-provision-job.yaml      # one-shot jobs (ttlSecondsAfterFinished + force annotation)
# DB role secret: infrastructure/configs/databases/postgres/<app>-db-user.yaml (SOPS)
```

## Ingress conventions

- **Middlewares** (set on every ingress, ordered):
  ```yaml
  traefik.ingress.kubernetes.io/router.middlewares: traefik-redirect-https@kubernetescrd,traefik-security-headers@kubernetescrd,traefik-rate-limit-standard@kubernetescrd,traefik-csp@kubernetescrd
  ```
- **CSP** (`infrastructure/configs/traefik-middlewares/csp-middleware.yaml`):

  | Chain token | Policy | Use |
  |---|---|---|
  | `traefik-csp` | inline tier since 2026-06-04: `script-src 'self' 'unsafe-inline'`, no `unsafe-eval` | default for a new app |
  | `traefik-csp-permissive-enforced` | adds `'unsafe-eval'` (eval/wasm) | only if the app needs eval or wasm |
  | `traefik-csp-strict-enforced` | also drops inline | to tighten |

  If an app needs eval or wasm, **browser-verify that first** — read the live DevTools console under a report-only header; the `csp-reporter` soak is **non-functional** (cluster-internal `report-uri`, unreachable from a browser, Loki always empty). Per-app verdicts + deep gotcha: memory `project_csp_rollout.md`.
- **Rate limits** (via middleware): `rate-limit-standard` default; `rate-limit-high-frequency` for n8n/immich/home-assistant; **none on authentik** (auth flow breaks).
- **Dual access** (internal + Cloudflare Tunnel): internal = this Traefik Ingress; external = a hostname row in centralized SOPS `infrastructure/configs/cloudflare/cloudflared-config-secret.yaml` + a `cloudflare-tunnel` NetworkPolicy ingress from-block. **NOT** a second Ingress manifest.
- **Namespace**: bare app name (e.g. `immich`). (`traefik-` prefixes a *middleware* namespace, not the app ns.)

## NetworkPolicy invariants

- **Every ingress requires NetworkPolicy**. Kyverno enforces.
- **Use container port, not service port** in `ports:` block. Service port mapping doesn't apply to NP.
- Egress: explicit allow for DB proxies, OIDC (authentik), webhooks. DNS comes from the shared `apps/components/allow-dns-egress` component in the app's kustomization, not a per-app DNS block (`.claude/review-invariants.md`).
- See `/networkpolicy-helper` for templates.

## Secrets

- **SOPS-encrypted only**. No plain Secrets in repo.
- DB password Secret labels:
  - Postgres: `cnpg.io/cluster: main-postgres` + `cnpg.io/reload: "true"`
  - MySQL: no Percona `User` CR exists. Create the user by hand with SQL (`CREATE USER` + `GRANT`) through `db-operations/scripts/mysql-exec.sh <db> -`, with the SQL on stdin so the password stays out of argv. Add its `CREATE USER` line, with a placeholder password, to `docs/disaster-recovery/mysql-create-dbs.sql`.
- DB role NOT auto-created from labeled Secret. Add to `infrastructure/configs/databases/postgres/cluster.yaml` `managed.roles[]`. (Why/error 42704: memory `gotchas.md` "CNPG roles must be in cluster.yaml managed.roles".)
- **DB username = app name** (invariant).

## Resource limits (Kyverno enforces)

- **Every container** (init included) needs `resources.limits.{cpu,memory}` + `resources.requests.{cpu,memory}`. Kyverno `require-resource-limits` Enforce (post-2026-05-23) covers BOTH `containers[*]` and `=(initContainers)[*]`.
- Init sizing numbers (busybox/alpine/curl req→lim) → `reference-app-patterns.md` § Init container sizing rule of thumb. General sizing → `/resource-sizing`.
- **`readOnlyRootFilesystem: true`** required → mount `/tmp` as `emptyDir` volume.
- gunicorn app + RoRFS: set `GUNICORN_CMD_ARGS=--no-control-socket` (gunicorn ≥25.1.0 control-socket hang) → `reference-app-patterns.md` § gunicorn + readOnlyRootFilesystem.

## Probes — slow-starting apps need startupProbe

Apps with cold-start >30s (Django+migrations, Rails+migrations, Spring Boot, Authentik server, Postgres bootstrap, Mongo replica): use `startupProbe`, NOT a bumped liveness `initialDelaySeconds` (tight value → CrashLoopBackOff on rolling updates while OLD pod stays healthy). Worked YAML + paperless incident (a36c8f31) → `reference-app-patterns.md` § Probes.

## Image pinning

- **`major.minor.patch-variant`** required. Floating tags drift silently.
- Kyverno only blocks `:latest`/no-tag — pin manually. (Float-gap why + audit: repo `scripts/ci/image-pin-audit.sh`, memory `gotchas.md` "Image-pin gap".)
- Authentik: `imagePullPolicy: Always` (upstream re-publishes same tag).
- CNPG main cluster image: current pin in `infrastructure/configs/databases/postgres/cluster.yaml` (renovate-bumped — don't copy from here). Helpers can float `18-*-trixie`.

## OIDC/SSO

App integrates SSO via authentik OIDC provider → `reference-app-patterns.md` § OIDC/SSO. Covers provider/application/group binding, `OIDC_ISSUER` shape, confidential vs PKCE clients, the redirect_uri-must-match-real-host footgun (F-43, `_shared/oidc-verify.sh`), and the HACS-style init-container release-zip install (Home Assistant `oidc-auth-install`).

## Bootstrap paradox (new namespace)

Adding new app with namespace + ResourceQuota in `resource-governance` causes circular dep (apps → infra-configs → ns missing). **2-commit pattern**:

1. **Commit 1**: add app to `apps/kustomization.yaml`. **DEFER** governance entry.
2. After Flux reconciles `apps` (creates ns), **Commit 2**: add `<newapp>.yaml` to `infrastructure/configs/resource-governance/kustomization.yaml`.

## Checklist before commit

- [ ] Image pinned `major.minor.patch-variant`
- [ ] Resources set on all containers (init + main) — Kyverno Enforce blocks otherwise
- [ ] `startupProbe` if app cold-start >30s (slow-starts: Django/Rails/Spring/Authentik)
- [ ] `readOnlyRootFilesystem` + `/tmp` emptyDir if applicable
- [ ] NetworkPolicy with container ports
- [ ] Ingress middlewares + rate limit
- [ ] Dual ingress if Cloudflare Tunnel access
- [ ] Secrets SOPS-encrypted
- [ ] DB role in cluster.yaml `managed.roles` (if Postgres user)
- [ ] `kubectl apply -f <file> --dry-run=server` clean
- [ ] 2-commit if new namespace + governance
- [ ] Update `docs/HOMELAB_ANALYSIS.md` post-merge

## App gotchas (driver-specific)

Baking a DB DSN into an env-var for a Go-driver app (pgx pre-parses, `${VAR}` not re-substituted at runtime → literal reaches driver, auth fails — e.g. Blocky `queryLog.target`) → `reference-app-patterns.md` § App gotchas (driver-specific).

## Reconcile + verify

See `/gitops-workflow` for `fr` reconcile + verification flow.

## Tools Allowed
- `Edit`, `Write`, `Read`
- `Bash(kubectl apply *--dry-run=server*)`
- `Bash(kubectl get *)`
- `Bash(git *)`
- `mcp__flux-operator__get_kubernetes_resources`
