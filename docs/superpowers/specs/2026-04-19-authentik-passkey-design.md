# Authentik Passkey-First Migration

**Date**: 2026-04-19
**Status**: Spec — pending review
**Target**: Authentik 2026.2.2, single-instance, GitOps-managed
**Owner**: akhozya

## Goal

Make passkeys the default authentication factor on `authentik.h0melab.work` so that the admin user (and any future users) signs in via WebAuthn (Conditional UI autofill) instead of typing a username + password each session. Apply changes declaratively via Authentik blueprints under GitOps control. Avoid regressions to the 10 downstream OIDC apps and to recovery / out-of-band paths.

## Non-Goals

- Removing the password stage entirely. Password remains a fallback for device-loss / unsupported-browser scenarios.
- Out-of-band invitation tokens for new users. There is one human user; defer this until family enrollment becomes a real need.
- Authentik upgrade. Stay on `2026.2.2` (latest stable, has the JSON encoding fix and Conditional UI). 2026.5 (late May ETA) brings additive WebAuthn client hints — not blocking.
- Changes to the 10 OIDC apps. They consume Authentik via OIDC redirect; passwordless at the IdP is transparent to them.
- Migration of the existing `default-authenticator-webauthn-setup` configure_flow path. Reuse it.

## Current State (verified live, 2026-04-19)

| Surface | State |
|---|---|
| Authentik version | `2026.2.2` (server + worker, 2 replicas each) |
| Human users | 1 (`akadmin`, superuser) |
| Service users | 1 (`ak-outpost-...`, internal_service_account, API token only — does not traverse auth flow) |
| OIDC providers | 10 (audiobookshelf, grafana, home-assistant, immich, linkwarden, linkding, mealie, paperless, cloudflare-access, stirling-pdf) |
| `default-authentication-flow` bindings | identification(10) → password(20) → mfa-validate(30) → user-login(100) |
| `default-authentication-identification` | `passwordless_flow=null`, `webauthn_stage=null`, `password_stage=null`, `user_fields=[email, username]` |
| `default-authentication-mfa-validation` | `device_classes=[static, totp, webauthn, duo, sms, email]`, `not_configured_action=skip`, `webauthn_user_verification=preferred` |
| `default-authenticator-webauthn-setup` stage | `resident_key_requirement=preferred`, `user_verification=preferred`, bound only to its own configure_flow (orphan from `default-user-settings-flow`) |
| `default-user-settings-flow` bindings | order 20 `default-user-settings` (prompt-form), order 100 `default-user-settings-write` (user-write). No authenticator-setup stages bound. |
| Existing WebAuthn devices | 1 — akadmin / "1Password", `rp_id=authentik.h0melab.work`, `aaguid=bada5566-…` (1Password), `sign_count=0` (never used for login) |
| Recovery flow | `default-password-recovery-via-email-flow` active. SMTP configured (`smtp.gmail.com:587`, global settings, FROM = alexander.khozya@gmail.com). |
| `AUTHENTIK_COOKIE_DOMAIN` | unset → RPID derived from Host header → `authentik.h0melab.work` |
| Custom blueprints | 0 (only 20 stock defaults applied) |
| Bootstrap secret name | `authentik` (single envFrom secret, not `authentik-secret`) |
| CF Access fronting apps | only SearXNG (`search.h0melab.work`); other 9 tunnel apps go CF Tunnel → Traefik → app → Authentik OIDC |

## Approach

Passkey-first via blueprints. Three orthogonal Authentik mechanisms compose the UX:

1. **Conditional UI / autofill** — `IdentificationStage.webauthn_stage` references an `AuthenticatorValidateStage` (WebAuthn class). When set and the browser supports `mediation: conditional`, the username field surfaces stored passkeys in the autocomplete dropdown. User picks passkey → authenticated → done. (Available since 2025.12.)
2. **Explicit passwordless button** — `IdentificationStage.passwordless_flow` references a flow that runs WebAuthn validation alone. Renders a "Use a passkey" link below the username field. Belt-and-braces fallback for browsers without Conditional UI.
3. **Voluntary enrollment + forced enrollment for new users** — bind `default-authenticator-webauthn-setup` to `default-user-settings-flow` (voluntary path), and switch `default-authentication-mfa-validation.not_configured_action` from `skip` to `configure` with `device_classes=[webauthn]` (force any new user without a passkey to enroll on first login).

Password stage remains bound at order 20 in the main flow as a recovery path. Email-based password recovery flow stays as last resort. Existing passkey for akadmin is preserved (RPID matches, no widening of cookie domain).

### Why this approach over alternatives

- **vs. WebAuthn-as-MFA-only (status quo + enable enforcement)**: still requires typing password each login. Doesn't meet the "instead of entering login and password every time" goal.
- **vs. removing password stage entirely**: brittle. One device loss = full DB-level reset. Recovery flow exists but is also email-bound; keeping password as fallback gives a layered recovery path.
- **vs. waiting for 2026.5 client hints**: additive only, doesn't change blueprint shape, ~5 weeks out. Opportunity cost too high.

## Architecture

### Flow topology (after)

```
default-authentication-flow                  default-authentication-webauthn-passwordless (NEW)
├── 10 identification                        ├── 10 webauthn-passwordless-validate
│     webauthn_stage    ─────────┐             │     device_classes=[webauthn]
│     passwordless_flow ─────────┼──REF────►   │     not_configured_action=deny
│                                │             │     webauthn_user_verification=required
├── 20 password (kept as fallback)            └── 20 default-authentication-login (existing, reused)
├── 30 mfa-validate
│     not_configured_action=configure
│     device_classes=[webauthn]
│     configure_flow ────────────┐
└── 100 user-login                │           passkey-setup-flow (NEW, designation=stage_configuration)
                                  └────REF──► ├── 10 default-authenticator-webauthn-setup (existing stage, reused)
                                              └── 20 default-authentication-login (existing, reused)

default-user-settings-flow
├── 20  default-user-settings (existing prompt-form)
├── 30  default-authenticator-webauthn-setup (NEW BINDING — existing stage, reused)
└── 100 default-user-settings-write (existing)
```

### Stage tightening

- `default-authenticator-webauthn-setup`: `resident_key_requirement: preferred → required`, `user_verification: preferred → required`. Existing 1Password credential (enrolled under "preferred") is unaffected; only future enrollments are tightened. Required is needed for reliable Conditional UI autofill across all passkey providers.

### Blueprint delivery

- Single ConfigMap `authentik-blueprints-custom` in namespace `authentik`, generated via Kustomize `configMapGenerator` from raw YAML files in `apps/base/authentik/blueprints/`.
- Mounted at `/blueprints/custom/` on both `authentik-server` and `authentik-worker` deployments (read-only).
- Authentik file watcher discovers new files on mtime change; full re-apply also runs every 60 minutes.
- Each blueprint entry uses `state: present` for additive changes. Rollback uses `state: absent`.

### RPID decision (irreversible)

Keep `AUTHENTIK_COOKIE_DOMAIN` **unset**. RPID stays `authentik.h0melab.work`, matching the existing 1Password credential's `rp_id` field. Widening to `h0melab.work` would invalidate the existing passkey (must re-enroll) and offers no functional gain — OIDC apps never see WebAuthn, only browser-redirect to Authentik.

## Components (blueprints to ship)

All under `apps/base/authentik/blueprints/`, generated into ConfigMap `authentik-blueprints-custom`:

| File | Purpose | Phase |
|---|---|---|
| `00-noop.yaml` | description-only entry; validates ConfigMap mount + watcher pickup | 0 |
| `10-tighten-webauthn-setup.yaml` | sets `resident_key_requirement=required`, `user_verification=required` on existing setup stage | 1 |
| `11-bind-webauthn-to-user-settings.yaml` | binds setup stage to `default-user-settings-flow` at order 30 | 1 |
| `20-passwordless-flow.yaml` | creates `default-authentication-webauthn-passwordless` flow + validate stage + bindings | 2 |
| `21-passkey-setup-flow.yaml` | creates `passkey-setup-flow` (designation=stage_configuration) with setup stage bound | 2 (used by phase 3) |
| `22-identification-passkey-first.yaml` | patches `default-authentication-identification` to set `webauthn_stage` + `passwordless_flow` | 2 |
| `30-mfa-validate-enforce-passkey.yaml` | patches `default-authentication-mfa-validation`: `not_configured_action=configure`, `device_classes=[webauthn]`, `configure_flow=passkey-setup-flow` | 3 |

## Migration Phases

### Pre-flight (manual, no code change)

P0a. **Live login test of existing passkey**. In a private browser window, navigate to `authentik.h0melab.work`, click "Set up MFA" in user settings (currently the only path that exposes WebAuthn, via the orphan configure_flow), then log out and log back in using the existing 1Password passkey. Confirm `sign_count` increments via API:

```bash
TOKEN=$(kubectl get secret -n authentik authentik -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_TOKEN}' | base64 -d)
kubectl exec -n authentik deploy/authentik-server -- sh -c \
  "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:9000/api/v3/authenticators/admin/webauthn/" \
  | jq '.results[] | {name, sign_count, last_used}'
```

**Gate**: if login fails (the credential was registered but is unusable for assertion — possible if the 2025-10-21 enrollment didn't actually create a discoverable credential), re-enroll BEFORE proceeding. Do not proceed to Phase 0 with an unverified credential.

P0b. **Enable Instant Auth on SearXNG CF Access app** in the Cloudflare Zero Trust dashboard. Single-IdP toggle. Without it, users get an extra "pick your IdP" click before reaching Authentik. Manual step (no Terraform for CF Access here).

P0c. **PostgreSQL backup verification**. Confirm last successful CNPG backup was within 24h. Trigger a manual backup if not:

```bash
kubectl cnpg backup main-postgres -n databases
```

### Phase 0 — Blueprint plumbing (PR 1)

Files:
- `apps/base/authentik/blueprints/00-noop.yaml`
- `apps/base/authentik/kustomization.yaml` (add `configMapGenerator` for `authentik-blueprints-custom`)
- `apps/base/authentik/server-deployment.yaml` (mount ConfigMap at `/blueprints/custom/` read-only)
- `apps/base/authentik/worker-deployment.yaml` (same mount)

Verify after Flux reconcile:

```bash
kubectl exec -n authentik deploy/authentik-server -- ls /blueprints/custom/
TOKEN=...
kubectl exec -n authentik deploy/authentik-server -- sh -c \
  "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:9000/api/v3/blueprints/instances/" \
  | jq '.results[] | select(.path | contains("custom"))'
```

Expected: `00-noop.yaml` instance present, `status=successful`.

### Phase 1 — Voluntary enrollment via User Settings (PR 2)

Files: `10-tighten-webauthn-setup.yaml`, `11-bind-webauthn-to-user-settings.yaml`.

After Flux reconcile, log into Authentik User Settings UI as akadmin. New "Register passkey" prompt should appear. Verify by enrolling a second passkey (e.g., on a phone) — confirms the binding works and validates the multi-passkey path despite known issue #19580 (multi-passkey wrong-pick during MFA validate; not relevant when validate runs on `device_classes=[webauthn]` with single class).

### Phase 2 — Passkey-first identification (PR 3)

Files: `20-passwordless-flow.yaml`, `21-passkey-setup-flow.yaml`, `22-identification-passkey-first.yaml`.

After reconcile, smoke test in incognito:
1. Visit `authentik.h0melab.work`. Click in username field. Browser passkey suggestion should appear (Conditional UI). Pick → logged in.
2. Visit `authentik.h0melab.work` in a browser without passkey support. Click "Use a passkey" link below username. → passwordless flow → external authenticator. Logged in.
3. Visit `authentik.h0melab.work`, type username, click Continue (skipping passkey). → password stage → password → MFA validate (passes for akadmin who has passkey). Logged in. **Password fallback intact.**

### Phase 3 — Enforce passkey for new users (PR 4)

File: `30-mfa-validate-enforce-passkey.yaml`.

Behavior change: any user without a WebAuthn device is forced through `passkey-setup-flow` on next login. With 1 user already enrolled this is preventive only — guards future user additions.

### Phase 4 — Documentation + memory (PR 5)

- Update `docs/HOMELAB_ANALYSIS.md`: Authentik section gets "Auth: passkey-first via Conditional UI; password fallback retained."
- Update `~/.claude/CLAUDE.md`: fix Authentik secret name (`authentik` not `authentik-secret`) and add brief note on blueprint custom path.
- Update memory file (`reference_homelab_docs.md` or new `authentik_passkey_setup.md`) with rollback recipe + phase summary.

## Risks + Mitigations

| Risk | Mitigation |
|---|---|
| Existing 1Password passkey is unusable for assertion (enrolled but never used; `sign_count=0`) | P0a gate: live login test before any flow change. Re-enroll if needed. |
| Conditional UI doesn't surface in browser (RPID derivation broken behind CF Tunnel + Traefik) | Phase 2 smoke test catches this. Fall back to passwordless button (`passwordless_flow`). |
| Blueprint reload doesn't pick up ConfigMap-projected file changes (symlink + atomic swap behavior) | Phase 0 no-op blueprint validates. If watcher misses, manual `kubectl rollout restart deploy/authentik-server -n authentik` + worker forces 60-min full re-apply. |
| Locking out admin via misconfigured flow | Password stage stays bound at order 20 → password fallback. Email recovery flow stays active. Worst case: K8s exec into worker, run Authentik management command to reset flows. |
| Issue #19155 (Captcha bypass on passkey path) | Not applicable — no Captcha in this flow. |
| Issue #18232 (TOTP/WebAuthn pk collision in MFA Devices UI) | akadmin already has both TOTP (1) and WebAuthn (1) — pk collision likely present. Doesn't break login, only device-management UI. Workaround: delete via API by UUID rather than UI. |
| Issue #20934 (AAGUID-zero passkey rejection) | 1Password sets a real AAGUID (`bada5566-…`) — not affected. Only matters for some Android passkey providers. |
| Cloudflare Tunnel strips/rewrites Origin header | Existing WebAuthn enrollment proves the chain works. No change. |
| User accidentally widens RPID later | Spec calls out: do NOT set `AUTHENTIK_COOKIE_DOMAIN`. Add as a guarded note in `apps/base/authentik/server-deployment.yaml` near the env block. |

## Rollback

Per-PR rollback: `git revert <commit>`, push, Flux reconciles. Blueprint entries with `state: present` get rolled back by reverting the YAML; `state: absent` is the explicit deletion form for entries that need removal even after the file is gone.

Full rollback (worst case, all 4 PRs):
1. Revert PR 4, PR 3, PR 2 in order. Push.
2. `flux reconcile kustomization apps --timeout=120s`
3. Wait for blueprint runner cycle (≤60 min) or `kubectl rollout restart deploy/authentik-server deploy/authentik-worker -n authentik` to force immediate re-apply.
4. Verify `default-authentication-identification.webauthn_stage` and `passwordless_flow` revert to `null` via API.

Manual lockout recovery (if all flows broken):
1. `kubectl exec -n authentik deploy/authentik-worker -- ak shell` → reset target flow via Django ORM.
2. Or restore from CNPG backup (PG snapshot taken at 03:00 daily; PITR available).

## Verification (per phase)

After each PR, run:

```bash
TOKEN=$(kubectl get secret -n authentik authentik -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_TOKEN}' | base64 -d)

# Blueprint instances
kubectl exec -n authentik deploy/authentik-server -- sh -c \
  "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:9000/api/v3/blueprints/instances/" \
  | jq '.results[] | {name, status, last_applied}'

# Identification stage state
kubectl exec -n authentik deploy/authentik-server -- sh -c \
  "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:9000/api/v3/stages/identification/?name=default-authentication-identification" \
  | jq '.results[] | {webauthn_stage, passwordless_flow, password_stage}'

# MFA validate state
kubectl exec -n authentik deploy/authentik-server -- sh -c \
  "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:9000/api/v3/stages/authenticator/validate/?name=default-authentication-mfa-validation" \
  | jq '.results[] | {device_classes, not_configured_action, configure_flow}'

# WebAuthn devices + sign_count
kubectl exec -n authentik deploy/authentik-server -- sh -c \
  "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:9000/api/v3/authenticators/admin/webauthn/" \
  | jq '.results[] | {name, sign_count, last_used, rp_id}'
```

Browser smoke (incognito) per Phase 2:
- Conditional UI autofill present in username field
- "Use a passkey" link rendered
- Password fallback path still works

## Open Issues to Monitor

Track in `docs/HOMELAB_ANALYSIS.md` pending items:

| Issue | Why we care | Action |
|---|---|---|
| [#19580](https://github.com/goauthentik/authentik/issues/19580) Multi-passkey wrong device picked | If/when enrolling a second passkey (phone) | Phase 1 smoke test catches; if hit, single-passkey-per-class workaround |
| [#18232](https://github.com/goauthentik/authentik/issues/18232) TOTP/WebAuthn pk collision in MFA Devices UI | Currently exposed (akadmin has both) | Manage devices via API by UUID; fix when upstream lands |
| [#20934](https://github.com/goauthentik/authentik/issues/20934) Attestation rejects AAGUID-zero | If/when family enrolls Android passkey | Re-evaluate device_type_restrictions if hit |
| [#21418](https://github.com/goauthentik/authentik/issues/21418) Docs gap on passwordless setup | Improves future maintenance | Watch for landing |
| [#20700](https://github.com/goauthentik/authentik/pull/20700) Client hints (2026.5) | UX improvement, additive | Re-tune `webauthn_authenticator_attachment` semantics on next minor |

## Out of Scope (deferred)

- Family member onboarding via FlowToken-restored Email stage links. Re-evaluate when adding the first non-admin user.
- Removing the password stage from the main auth flow. Re-evaluate after 1+ month of clean passkey-first operation.
- WebAuthn device naming convention / device-type restrictions. Re-evaluate when 2+ devices per user is the norm.
- Authentik upgrade to 2026.5. Tracked in monthly review.
