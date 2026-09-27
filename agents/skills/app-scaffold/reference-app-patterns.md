# App Scaffold — situational deep patterns

Loaded on demand from `app-scaffold/SKILL.md`. Each section = one situational pattern's full detail + the why. SKILL.md holds the routing pointers; load this file when the matching condition fires.

## Probes — slow-starting apps need startupProbe

Fires when: app cold-start >30s (Django+migrations, Rails+migrations, Spring Boot, Authentik server, Postgres bootstrap, Mongo replica).

Use `startupProbe` instead of bumping liveness `initialDelaySeconds`. Cold-start timing is variable; tight `initialDelaySeconds` causes CrashLoopBackOff on rolling updates while the OLD pod stays healthy.

Pattern:

```yaml
startupProbe:
  httpGet: { path: /, port: 8000 }
  initialDelaySeconds: 30
  periodSeconds: 10
  failureThreshold: 30   # 300s budget — paperless observed 98s init
livenessProbe:
  httpGet: { path: /, port: 8000 }
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
  # NO initialDelaySeconds — startupProbe gates this
readinessProbe:
  httpGet: { path: /, port: 8000 }
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 3
```

Reference: paperless-ngx incident 2026-05-23 (init=98s, liveness initialDelaySeconds=60 → CrashLoop). Commit a36c8f31.

## Init container sizing rule of thumb

Fires when: setting `resources` on `initContainers[*]` (Kyverno `require-resource-limits` Enforce covers `=(initContainers)[*]`).

- busybox chown/cmp = 10m/16Mi req → 50m/32Mi lim
- alpine + wget + unzip = 50m/64Mi req → 500m/256Mi lim
- curl health-wait loop = 10m/16Mi req → 50m/32Mi lim

See `/resource-sizing` for full sizing guidance.

## OIDC/SSO

Fires when: app integrates SSO via authentik OIDC provider.

Pattern:
- Authentik provider + application + group binding (client_id == app slug by convention)
- App config: `OIDC_ISSUER=https://authentik.h0melab.work/application/o/<slug>/`
- Client secret in SOPS-encrypted Secret (confidential client). Public/PKCE clients (no secret) also work — upstream often prefers them for home setups.

**redirect_uri must match the app's REAL ingress host** — the #1 OIDC footgun. The provider's Strict redirect URI is `https://<app-real-host>/<callback-path>`; a doc/host mismatch (e.g. `homeassistant` vs the real `ha.h0melab.work`, F-43) passes discovery but fails at the callback. Verify wiring without a browser:
```
_shared/oidc-verify.sh <app-slug> <full-callback-url> [authentik-host]
# checks discovery 200+issuer AND probes authorize → 302 (allowlisted) vs 400 (not)
```

**HACS-style apps (Home Assistant):** the integration isn't a container env-var — it's a Python component installed into the app's config dir by an **init container** that downloads the pinned upstream **release zip** into `custom_components/<name>/` (see `apps/home-assistant/deployment.yaml` `oidc-auth-install`; mirrors the HACS init, `.installed-version` sentinel for idempotent version bumps). Re-derive the callback from the request host — don't hardcode it.

## gunicorn + readOnlyRootFilesystem

Fires when: a gunicorn-served app (gunicorn ≥25.1.0) runs with `readOnlyRootFilesystem: true`.

gunicorn 25.1.0+ opens a control socket at the relative path `gunicorn.ctl` — under a read-only cwd the open fails with Errno 30 and intermittently hangs the worker fork on ~50% of restarts. Fix: env `GUNICORN_CMD_ARGS=--no-control-socket` (keeps RoRFS). Detail: memory `gotcha_gunicorn_control_socket_rorfs`.

## App gotchas (driver-specific)

### Connection-string env-substitution

Fires when: baking a DB DSN into an env-var for a Go-driver app.

Some Go drivers (pgx, parts of database/sql) **pre-parse** the DSN at config time and do NOT re-substitute `${VAR}` at runtime. If you bake `${PASSWORD}` into a connection string env-var, the literal `${PASSWORD}` reaches the driver and auth fails. Examples: **Blocky** `queryLog.target: postgres://blocky:${PASSWORD}@...` fails — env-substitute is NOT applied. **Fix**: bake the literal credential into the env-var via SOPS-encrypted Secret (still safe at rest), OR use the driver's individual fields (`PGUSER`/`PGPASSWORD`) instead of a combined DSN. Cross-link: `/db-operations` for DSN templates per engine.
