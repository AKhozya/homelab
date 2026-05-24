# Authentik Passkey-First Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make passkeys the default authentication factor on `authentik.h0melab.work` via blueprints under GitOps control, while preserving the password fallback path and the existing 1Password passkey enrolled by `akadmin`.

**Architecture:** Add a Kustomize-managed ConfigMap mounted into the Authentik server + worker pods at `/blueprints/custom/`, containing 4 blueprint files delivered across 4 functional phases (plumbing → voluntary enrollment → passkey-first identification → enforcement for new users). Use `IdentificationStage.webauthn_stage` (Conditional UI autofill) + `passwordless_flow` (button fallback) + `AuthenticatorValidateStage.configuration_stages` (force inline enrollment for users without a passkey). Keep the existing password stage bound at order 20 of the main flow as a recovery path.

**Tech Stack:** Authentik 2026.2.2, K3s + Kustomize + Flux, SOPS for secrets (none needed here), 1Password for browser-side passkey storage.

**Spec:** `docs/superpowers/specs/2026-04-19-authentik-passkey-design.md`

## Source-of-truth notes (verified live, 2026-04-19)

These were confirmed against the running cluster + Authentik source. Do not improvise away from them:

- **Blueprint apply ordering across files is NOT alphabetical.** `authentik/blueprints/v1/tasks.py` uses `Path.rglob("**/*.yaml")` with no `sorted()`. Filename prefixes (`00-`, `10-`, `20-`, `30-`) are documentation only. **Within a single blueprint file, entry order IS preserved** and the file applies as ONE atomic transaction. **Therefore each PR ships exactly one file**, fully self-contained for that phase, with cross-phase references resolved via `!Find` against DB state from prior phases.
- **`flowstagebinding` unique constraint** is `(target, stage, order)`. Blueprint identifiers must include all three or `state: present` will fail to find an existing binding and collide on insert.
- **`state: present` is a partial update** (`importer.py:281` sets `partial=True`). Fields not in `attrs` are left unchanged.
- **`AuthenticatorValidateStage.configure_flow` does NOT exist.** Only `configuration_stages` (list of authenticator setup stage UUIDs to run inline during login when `not_configured_action: configure`). Use that.
- **Flow primary key field is `pk`** (not `pbm_uuid`).
- **`last_auth_threshold` is a quoted string** like `"seconds=0"` (Django timedelta parse format).
- **Recovery flow slug** in this install: `default-password-recovery-via-email-flow`.
- **Existing WebAuthn setup stage's `configure_flow`** points to its own same-named flow (`9366f34d-…`). **Do not null it.** It's the only path akadmin currently has to (re-)enroll, and we're going to add the inline path alongside, not replace it.
- **Existing 1Password credential's `sign_count` = 0** — never used for actual login. The first real exercise is Phase 2 smoke test 6a. Acceptable risk because Phase 2 is fully reversible by `git revert`.
- **`fr` is a zsh interactive function** — not callable from `bash -c`. Plan uses literal `flux reconcile` invocations.

## File Structure

```
apps/base/authentik/
├── blueprints/                                                   (NEW DIR)
│   ├── 00-noop.yaml                Phase 0: validate ConfigMap mount + watcher pickup
│   ├── 10-voluntary-enrollment.yaml Phase 1: tighten setup stage + bind to user-settings-flow
│   ├── 20-passkey-first.yaml       Phase 2: passwordless flow + setup flow + identification patch
│   └── 30-enforce.yaml             Phase 3: MFA validate enforces passkey for new users
├── kustomization.yaml              MODIFY: add configMapGenerator entry
├── server-deployment.yaml          MODIFY: mount ConfigMap at /blueprints/custom/
└── worker-deployment.yaml          MODIFY: mount ConfigMap at /blueprints/custom/

docs/HOMELAB_ANALYSIS.md            MODIFY: add changelog entry + pending items
docs/scripts/runbooks/authentik-passkey-rollback.md  CREATE: rollback runbook
```

Each phase = one PR. PRs land sequentially with verification gates between them. Filename prefixes are organizational only — Authentik does not use them for ordering.

---

## Pre-Flight (Manual — runs once before Task 1)

### Task 0: Pre-flight gates

**No code changes. Pure verification + manual config.**

- [ ] **Step 1: Snapshot current Authentik flow state for forensic recovery**

```bash
TOKEN=$(kubectl get secret -n authentik authentik -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_TOKEN}' | base64 -d)
mkdir -p /tmp/authentik-snapshot-2026-04-19
for endpoint in \
  "stages/identification/?name=default-authentication-identification" \
  "stages/authenticator/validate/?name=default-authentication-mfa-validation" \
  "stages/authenticator/webauthn/?name=default-authenticator-webauthn-setup" \
  "flows/instances/?slug=default-authentication-flow" \
  "flows/instances/?slug=default-user-settings-flow" \
  "flows/bindings/?ordering=order" \
  "blueprints/instances/" \
  "authenticators/admin/webauthn/" ; do
  fname=$(echo "$endpoint" | tr '/?=&' '_')
  kubectl exec -n authentik deploy/authentik-server -- sh -c \
    "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:9000/api/v3/$endpoint" \
    > "/tmp/authentik-snapshot-2026-04-19/${fname}.json"
done
ls -la /tmp/authentik-snapshot-2026-04-19/
```

Expected: 8 JSON files saved. Tar them for safekeeping:

```bash
tar czf ~/authentik-snapshot-2026-04-19.tgz -C /tmp authentik-snapshot-2026-04-19
```

- [ ] **Step 2: Enable Instant Auth on SearXNG CF Access app**

Open Cloudflare Zero Trust dashboard → Access → Applications → `search.h0melab.work` → Authentication → toggle "Instant Auth" ON. Save.

Smoke: incognito visit `https://search.h0melab.work` → expect direct redirect to Authentik (no IdP chooser page).

- [ ] **Step 3: Confirm 1Password is unlocked + accessible in the browser you'll smoke-test from**

Phase 2's Conditional UI smoke test (Task 13 Step 6) requires browser-side passkey storage to surface the akadmin credential. Make sure 1Password browser extension is unlocked + reachable before that phase.

- [ ] **Step 4: Document gate completion**

In the Phase 0 commit body (Task 5), include:

```
Pre-flight verified:
- Authentik flow state snapshot saved (~/authentik-snapshot-2026-04-19.tgz)
- SearXNG CF Access Instant Auth enabled
- 1Password browser extension confirmed unlocked
```

**Note on existing passkey verification**: The 1Password credential for akadmin shows `sign_count=0` (never used for assertion — current Authentik flow has `not_configured_action=skip` + no passwordless wiring, so the credential has never been exercised). This is expected, not a defect. The first real exercise happens in Phase 2 smoke 6a. If the credential turns out to be unusable for assertion, Phase 2 is fully reversible (`git revert HEAD; git push; flux reconcile kustomization apps`). Re-enrollment then proceeds via Phase 1's User Settings binding.

---

## Phase 0 — Blueprint Plumbing (PR 1)

### Task 1: Add no-op blueprint file

**Files:**
- Create: `apps/base/authentik/blueprints/00-noop.yaml`

- [ ] **Step 1: Create the directory + no-op file**

```bash
mkdir -p apps/base/authentik/blueprints
```

```yaml
# apps/base/authentik/blueprints/00-noop.yaml
version: 1
metadata:
  name: homelab-noop-pipeline-test
  labels:
    blueprints.goauthentik.io/description: "No-op blueprint validating custom ConfigMap mount + Authentik blueprint runner pickup."
entries: []
```

- [ ] **Step 2: Validate YAML parses**

```bash
python3 -c "import yaml; yaml.safe_load(open('apps/base/authentik/blueprints/00-noop.yaml'))"
```

Expected: no output (success).

### Task 2: Wire blueprints into Kustomize

**Files:**
- Modify: `apps/base/authentik/kustomization.yaml`

- [ ] **Step 1: Add configMapGenerator + generatorOptions**

Edit `apps/base/authentik/kustomization.yaml`. Append after the `resources:` block:

```yaml
configMapGenerator:
  - name: authentik-blueprints-custom
    namespace: authentik
    files:
      - blueprints/00-noop.yaml

generatorOptions:
  disableNameSuffixHash: true
```

(`disableNameSuffixHash: true` keeps the ConfigMap name stable so the deployment volumeMount doesn't need updating each time a blueprint file is added.)

- [ ] **Step 2: Validate Kustomize build**

```bash
kustomize build apps/base/authentik | grep -A 5 "name: authentik-blueprints-custom"
```

Expected: ConfigMap manifest with `data:` containing key `00-noop.yaml`.

### Task 3: Mount ConfigMap into server deployment

**Files:**
- Modify: `apps/base/authentik/server-deployment.yaml:103-112`

- [ ] **Step 1: Add volumeMount + volume entries**

Edit the `volumeMounts:` (line 103) and `volumes:` (line 108) blocks of the server container. Final shape:

```yaml
          volumeMounts:
            - name: media
              mountPath: /data/media
            - name: tmp
              mountPath: /tmp
            - name: blueprints-custom
              mountPath: /blueprints/custom
              readOnly: true
      volumes:
        - name: media
          emptyDir: {}
        - name: tmp
          emptyDir: {}
        - name: blueprints-custom
          configMap:
            name: authentik-blueprints-custom
```

- [ ] **Step 2: Validate manifest**

```bash
kustomize build apps/base/authentik | yq '.spec.template.spec.containers[].volumeMounts // empty' -
```

Expected: lists `blueprints-custom` mount on the server container.

### Task 4: Mount ConfigMap into worker deployment

**Files:**
- Modify: `apps/base/authentik/worker-deployment.yaml:101-114`

- [ ] **Step 1: Add volumeMount + volume entries**

Edit the `volumeMounts:` (line 101) and `volumes:` (line 108) blocks of the worker container. Final shape:

```yaml
          volumeMounts:
            - name: media
              mountPath: /data/media
            - name: tmp
              mountPath: /tmp
            - name: certs
              mountPath: /certs
            - name: blueprints-custom
              mountPath: /blueprints/custom
              readOnly: true
      volumes:
        - name: media
          emptyDir: {}
        - name: tmp
          emptyDir: {}
        - name: certs
          emptyDir: {}
        - name: blueprints-custom
          configMap:
            name: authentik-blueprints-custom
```

- [ ] **Step 2: Server-side dry-run apply**

```bash
kustomize build apps/base/authentik | kubectl apply --dry-run=server -f -
```

Expected: all resources `unchanged` or `configured (dry run)`. No errors.

### Task 5: Commit + push Phase 0

- [ ] **Step 1: Stage + commit**

```bash
git add apps/base/authentik/blueprints/00-noop.yaml \
        apps/base/authentik/kustomization.yaml \
        apps/base/authentik/server-deployment.yaml \
        apps/base/authentik/worker-deployment.yaml

git commit -m "Authentik: blueprint plumbing — ConfigMap mount + no-op pipeline test

Pre-flight verified:
- Authentik flow state snapshot saved (~/authentik-snapshot-2026-04-19.tgz)
- SearXNG CF Access Instant Auth enabled
- 1Password browser extension confirmed unlocked

Spec: docs/superpowers/specs/2026-04-19-authentik-passkey-design.md
Phase 0/4 of passkey-first migration."

git push
```

### Task 6: Verify Phase 0 reconciled

- [ ] **Step 1: Trigger Flux reconcile**

```bash
flux reconcile source git flux-system --timeout=90s
flux reconcile kustomization apps --timeout=120s
```

- [ ] **Step 2: Confirm pods rolled**

```bash
kubectl rollout status deploy/authentik-server -n authentik --timeout=300s
kubectl rollout status deploy/authentik-worker -n authentik --timeout=300s
```

Expected: `successfully rolled out` for both.

- [ ] **Step 3: Confirm file mounted**

```bash
kubectl exec -n authentik deploy/authentik-server -- ls -la /blueprints/custom/
```

Expected: `00-noop.yaml` listed.

- [ ] **Step 4: Confirm Authentik picked it up**

The blueprint runner uses both inotify + a periodic scheduled discovery (compares SHA-512 of file bytes). Discovery is usually within seconds of file mount; worst case 60 minutes.

```bash
TOKEN=$(kubectl get secret -n authentik authentik -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_TOKEN}' | base64 -d)
kubectl exec -n authentik deploy/authentik-server -- sh -c \
  "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:9000/api/v3/blueprints/instances/" \
  | jq '.results[] | select(.path | contains("custom"))'
```

Expected: one entry with `path: "custom/00-noop.yaml"`, `status: "successful"`, `enabled: true`. If still missing after 5 minutes, force re-discovery:

```bash
kubectl rollout restart deploy/authentik-worker -n authentik
kubectl rollout status deploy/authentik-worker -n authentik --timeout=300s
sleep 30
# Re-run the API check
```

**Gate:** if blueprint not picked up after restart, abort and investigate before Phase 1.

---

## Phase 1 — Voluntary Enrollment via User Settings (PR 2)

### Task 7: Author Phase 1 blueprint

**Files:**
- Create: `apps/base/authentik/blueprints/10-voluntary-enrollment.yaml`
- Modify: `apps/base/authentik/kustomization.yaml`

- [ ] **Step 1: Write the blueprint**

```yaml
# apps/base/authentik/blueprints/10-voluntary-enrollment.yaml
version: 1
metadata:
  name: homelab-voluntary-passkey-enrollment
  labels:
    blueprints.goauthentik.io/description: "Tighten default WebAuthn setup stage to require resident key + user verification (only affects future enrollments — existing 1Password credential remains valid). Bind the setup stage into default-user-settings-flow at order 30 so users can enroll passkeys from User Settings UI. Leaves the existing configure_flow on the setup stage untouched (do not null — it's the orphan path)."
entries:
  # Tighten the existing setup stage. state: present is partial-update, so
  # configure_flow + friendly_name + device_type_restrictions are NOT touched.
  - model: authentik_stages_authenticator_webauthn.authenticatorwebauthnstage
    state: present
    identifiers:
      name: default-authenticator-webauthn-setup
    attrs:
      resident_key_requirement: required
      user_verification: required

  # Bind the setup stage into default-user-settings-flow at order 30.
  # Identifiers MUST include target+stage+order (unique_together on FlowStageBinding).
  - model: authentik_flows.flowstagebinding
    state: present
    identifiers:
      target:
        !Find [authentik_flows.flow, [slug, default-user-settings-flow]]
      stage:
        !Find [
          authentik_stages_authenticator_webauthn.authenticatorwebauthnstage,
          [name, default-authenticator-webauthn-setup],
        ]
      order: 30
    attrs:
      evaluate_on_plan: true
      re_evaluate_policies: false
      invalid_response_action: retry
      policy_engine_mode: any
```

- [ ] **Step 2: Add file to ConfigMap generator**

Edit `apps/base/authentik/kustomization.yaml`, extend the `files:` list:

```yaml
configMapGenerator:
  - name: authentik-blueprints-custom
    namespace: authentik
    files:
      - blueprints/00-noop.yaml
      - blueprints/10-voluntary-enrollment.yaml
```

- [ ] **Step 3: Validate**

```bash
python3 -c "import yaml; yaml.safe_load(open('apps/base/authentik/blueprints/10-voluntary-enrollment.yaml'))"
kustomize build apps/base/authentik | kubectl apply --dry-run=server -f -
```

Expected: no errors.

### Task 8: Commit, push, verify Phase 1

- [ ] **Step 1: Commit + push**

```bash
git add apps/base/authentik/blueprints/10-voluntary-enrollment.yaml \
        apps/base/authentik/kustomization.yaml

git commit -m "Authentik: voluntary passkey enrollment in User Settings

Tighten default-authenticator-webauthn-setup to resident_key_requirement=required
+ user_verification=required (partial update; configure_flow + friendly_name +
device_type_restrictions retained). Only affects future enrollments — akadmin's
existing 1Password credential stays valid since it was enrolled under preferred
and 1P creates discoverable credentials by default.

Bind the setup stage into default-user-settings-flow at order 30 so users can
register passkeys from User Settings UI.

Spec: docs/superpowers/specs/2026-04-19-authentik-passkey-design.md
Phase 1/4 of passkey-first migration."

git push
```

- [ ] **Step 2: Reconcile + wait**

```bash
flux reconcile source git flux-system --timeout=90s
flux reconcile kustomization apps --timeout=120s
sleep 30  # Give blueprint runner time
```

- [ ] **Step 3: Verify blueprint applied**

```bash
TOKEN=$(kubectl get secret -n authentik authentik -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_TOKEN}' | base64 -d)
kubectl exec -n authentik deploy/authentik-server -- sh -c \
  "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:9000/api/v3/blueprints/instances/" \
  | jq '.results[] | select(.path | contains("custom")) | {path, status, last_applied}'
```

Expected: 2 entries (`00-noop.yaml`, `10-voluntary-enrollment.yaml`), both `status: "successful"`.

- [ ] **Step 4: Verify stage tightened**

```bash
kubectl exec -n authentik deploy/authentik-server -- sh -c \
  "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:9000/api/v3/stages/authenticator/webauthn/?name=default-authenticator-webauthn-setup" \
  | jq '.results[] | {name, resident_key_requirement, user_verification, configure_flow}'
```

Expected: `resident_key_requirement: "required"`, `user_verification: "required"`. **`configure_flow` MUST still be a UUID** (not null) — the partial update preserves it. If null, Phase 1 broke the orphan enrollment path; rollback immediately.

- [ ] **Step 5: Verify binding exists**

```bash
USER_SETTINGS_FLOW_PK=$(kubectl exec -n authentik deploy/authentik-server -- sh -c \
  "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:9000/api/v3/flows/instances/?slug=default-user-settings-flow" \
  | jq -r '.results[0].pk')

kubectl exec -n authentik deploy/authentik-server -- sh -c \
  "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:9000/api/v3/flows/bindings/?target=$USER_SETTINGS_FLOW_PK" \
  | jq '.results[] | {order, stage_obj: .stage_obj.name}'
```

Expected: 3 bindings (orders 20, 30, 100), order 30 = `default-authenticator-webauthn-setup`.

- [ ] **Step 6: Browser smoke test**

Log into `https://authentik.h0melab.work/if/user/` as akadmin (current path: type username, type password, MFA validate skips since `not_configured_action=skip`). The User Settings page should now offer passkey enrollment via the new binding. (Optional: enroll a second passkey to validate end-to-end. Skip if no second device available — the binding's existence + UI rendering of the option is sufficient verification.)

**Gate:** if any blueprint is `status: "error"`:

```bash
kubectl exec -n authentik deploy/authentik-server -- sh -c \
  "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:9000/api/v3/blueprints/instances/" \
  | jq '.results[] | select(.status == "error")'
```

Read the error, fix the YAML, re-push. Do not advance to Phase 2 until both blueprints `successful`.

---

## Phase 2 — Passkey-First Identification (PR 3)

### Task 9: Author Phase 2 blueprint

**Files:**
- Create: `apps/base/authentik/blueprints/20-passkey-first.yaml`
- Modify: `apps/base/authentik/kustomization.yaml`

- [ ] **Step 1: Write the blueprint**

```yaml
# apps/base/authentik/blueprints/20-passkey-first.yaml
version: 1
metadata:
  name: homelab-passkey-first-identification
  labels:
    blueprints.goauthentik.io/description: "Create homelab-passwordless-webauthn-validate stage + homelab-authentication-webauthn-passwordless flow + homelab-passkey-setup-flow (used by Phase 3 inline enrollment). Patch default-authentication-identification: set webauthn_stage (Conditional UI autofill, 2025.12+) + passwordless_flow (button fallback). Password stage at order 20 of main flow remains untouched as recovery path."
entries:
  # 1. WebAuthn-only validate stage (used by both passwordless flow + inline phase 3)
  - model: authentik_stages_authenticator_validate.authenticatorvalidatestage
    state: present
    identifiers:
      name: homelab-passwordless-webauthn-validate
    id: homelab-validate
    attrs:
      not_configured_action: deny
      device_classes:
        - webauthn
      webauthn_user_verification: required
      last_auth_threshold: "seconds=0"
      configuration_stages: []

  # 2. Passwordless authentication flow (target of IdentificationStage.passwordless_flow)
  - model: authentik_flows.flow
    state: present
    identifiers:
      slug: homelab-authentication-webauthn-passwordless
    id: homelab-passwordless-flow
    attrs:
      name: "Passwordless Authentication"
      title: "Sign in with Passkey"
      designation: authentication
      authentication: none
      policy_engine_mode: any
      compatibility_mode: false

  # 3. Bind validate stage to passwordless flow at order 10
  - model: authentik_flows.flowstagebinding
    state: present
    identifiers:
      target: !KeyOf homelab-passwordless-flow
      stage: !KeyOf homelab-validate
      order: 10
    attrs:
      evaluate_on_plan: true
      re_evaluate_policies: false
      invalid_response_action: retry
      policy_engine_mode: any

  # 4. Bind existing default-authentication-login at order 20 of passwordless flow
  - model: authentik_flows.flowstagebinding
    state: present
    identifiers:
      target: !KeyOf homelab-passwordless-flow
      stage:
        !Find [
          authentik_stages_user_login.userloginstage,
          [name, default-authentication-login],
        ]
      order: 20
    attrs:
      evaluate_on_plan: true
      re_evaluate_policies: false
      invalid_response_action: retry
      policy_engine_mode: any

  # 5. Passkey enrollment configure_flow (target for inline enrollment in Phase 3)
  - model: authentik_flows.flow
    state: present
    identifiers:
      slug: homelab-passkey-setup-flow
    id: homelab-setup-flow
    attrs:
      name: "Passkey Enrollment"
      title: "Set up your Passkey"
      designation: stage_configuration
      authentication: require_authenticated
      policy_engine_mode: any
      compatibility_mode: false

  # 6. Bind existing setup stage into the new setup flow at order 10
  - model: authentik_flows.flowstagebinding
    state: present
    identifiers:
      target: !KeyOf homelab-setup-flow
      stage:
        !Find [
          authentik_stages_authenticator_webauthn.authenticatorwebauthnstage,
          [name, default-authenticator-webauthn-setup],
        ]
      order: 10
    attrs:
      evaluate_on_plan: true
      re_evaluate_policies: false
      invalid_response_action: retry
      policy_engine_mode: any

  # 7. Patch default-authentication-identification with webauthn_stage + passwordless_flow.
  # state: present is partial — user_fields, case_insensitive_matching, show_matched_user,
  # pretend_user_exists, sources, recovery_flow are all left as-is.
  - model: authentik_stages_identification.identificationstage
    state: present
    identifiers:
      name: default-authentication-identification
    attrs:
      passwordless_flow: !KeyOf homelab-passwordless-flow
      webauthn_stage: !KeyOf homelab-validate
```

Note on `!KeyOf` vs `!Find`: `!KeyOf` resolves a within-blueprint `id:` reference at apply time; `!Find` does a DB lookup. For entries created in this same file, `!KeyOf` is faster + avoids race with creation. For pre-existing entities (e.g. `default-authentication-login`, `default-authenticator-webauthn-setup`, `default-user-settings-flow`), use `!Find`.

- [ ] **Step 2: Add file to ConfigMap generator**

Edit `apps/base/authentik/kustomization.yaml`:

```yaml
configMapGenerator:
  - name: authentik-blueprints-custom
    namespace: authentik
    files:
      - blueprints/00-noop.yaml
      - blueprints/10-voluntary-enrollment.yaml
      - blueprints/20-passkey-first.yaml
```

- [ ] **Step 3: Validate**

```bash
python3 -c "import yaml; list(yaml.safe_load_all(open('apps/base/authentik/blueprints/20-passkey-first.yaml').read()))"
kustomize build apps/base/authentik | kubectl apply --dry-run=server -f -
```

Expected: no errors.

### Task 10: Commit, push, verify Phase 2

- [ ] **Step 1: Commit + push**

```bash
git add apps/base/authentik/blueprints/20-passkey-first.yaml \
        apps/base/authentik/kustomization.yaml

git commit -m "Authentik: passkey-first identification (Conditional UI + button fallback)

Create homelab-passwordless-webauthn-validate stage (device_classes=[webauthn]),
homelab-authentication-webauthn-passwordless flow (validate -> existing user-login),
and homelab-passkey-setup-flow (designation=stage_configuration, target for Phase 3
inline enrollment).

Patch default-authentication-identification: set webauthn_stage (Conditional UI
autofill in username field, 2025.12+) + passwordless_flow (button-based passkey
login link). All other identification fields left untouched (partial update).

Password stage at order 20 of default-authentication-flow remains bound as
recovery path. Existing 1Password credential's first real login attempt happens
during smoke 6a; rollback contingency documented in plan.

Spec: docs/superpowers/specs/2026-04-19-authentik-passkey-design.md
Phase 2/4 of passkey-first migration."

git push
```

- [ ] **Step 2: Reconcile + wait**

```bash
flux reconcile source git flux-system --timeout=90s
flux reconcile kustomization apps --timeout=120s
sleep 30
```

- [ ] **Step 3: Verify all 3 blueprints applied successfully**

```bash
TOKEN=$(kubectl get secret -n authentik authentik -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_TOKEN}' | base64 -d)
kubectl exec -n authentik deploy/authentik-server -- sh -c \
  "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:9000/api/v3/blueprints/instances/" \
  | jq '.results[] | select(.path | contains("custom")) | {path, status, last_applied}'
```

Expected: 3 entries (`00-noop.yaml`, `10-voluntary-enrollment.yaml`, `20-passkey-first.yaml`), all `status: "successful"`.

- [ ] **Step 4: Verify identification stage was patched**

```bash
kubectl exec -n authentik deploy/authentik-server -- sh -c \
  "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:9000/api/v3/stages/identification/?name=default-authentication-identification" \
  | jq '.results[] | {webauthn_stage, passwordless_flow, password_stage, recovery_flow, pretend_user_exists}'
```

Expected: `webauthn_stage` is a UUID (not null), `passwordless_flow` is a UUID (not null), `password_stage` still null, `pretend_user_exists: true` (untouched).

- [ ] **Step 5: Verify passwordless flow exists with correct bindings**

```bash
PWLESS_FLOW_PK=$(kubectl exec -n authentik deploy/authentik-server -- sh -c \
  "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:9000/api/v3/flows/instances/?slug=homelab-authentication-webauthn-passwordless" \
  | jq -r '.results[0].pk')

kubectl exec -n authentik deploy/authentik-server -- sh -c \
  "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:9000/api/v3/flows/bindings/?target=$PWLESS_FLOW_PK" \
  | jq '.results[] | {order, stage_obj: .stage_obj.name}'
```

Expected: 2 bindings — order 10 = `homelab-passwordless-webauthn-validate`, order 20 = `default-authentication-login`.

- [ ] **Step 6: Browser smoke tests**

Run all four (incognito, single browser session per test, 1Password unlocked):

**6a — Conditional UI autofill (PRIMARY GATE):** Visit `https://authentik.h0melab.work/`. Click in the username field. Browser should offer the akadmin passkey from autofill (Conditional UI). Select it → expect login to land on `/if/user/` without typing username or password. **This is the first real exercise of the existing 1Password credential.** If it fails, see "Rollback contingency" below.

**6b — Passwordless button fallback:** Visit `https://authentik.h0melab.work/`. Confirm a "Use a passkey" link appears below the username field (the `passwordless_flow` button). Click it → external authenticator dialog → expect login.

**6c — Password fallback (CRITICAL):** Visit `https://authentik.h0melab.work/`. Type `akadmin` in the username field, click Continue. Expect password stage (the bound stage at order 20 of the main flow). Enter password → MFA validate (passes since `not_configured_action: skip` is still in effect at this phase). Expect login. **This proves password fallback survives — do not advance to Phase 3 if this fails.**

**6d — OIDC delegation intact:** Visit `https://audiobooks.h0melab.work/` (or any of the 10 OIDC apps). App redirects to Authentik. Expect Conditional UI / passwordless options. Pick passkey → land back on app, logged in. Confirms OIDC chain unaffected.

**Rollback contingency** (if 6a or 6c fails):

```bash
git revert --no-edit HEAD  # the Phase 2 commit
git push
flux reconcile source git flux-system --timeout=90s
flux reconcile kustomization apps --timeout=120s
sleep 30

# Verify identification stage reverted
kubectl exec -n authentik deploy/authentik-server -- sh -c \
  "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:9000/api/v3/stages/identification/?name=default-authentication-identification" \
  | jq '.results[] | {webauthn_stage, passwordless_flow}'
# Expected: both null after revert
```

If 6a failed specifically (Conditional UI didn't surface the credential), the credential may have been enrolled without `resident_key=true` despite the stage configuration — re-enroll via User Settings (Phase 1 binding) using a fresh passkey, then re-apply Phase 2.

If `git revert` itself doesn't unset the fields (because `state: present` is partial-update and removing a YAML key from the blueprint doesn't auto-null the DB field), use the manual lockout recovery in the rollback runbook (Task 12).

---

## Phase 3 — Enforce Passkey for New Users (PR 4)

### Task 11: Author Phase 3 blueprint

**Files:**
- Create: `apps/base/authentik/blueprints/30-enforce.yaml`
- Modify: `apps/base/authentik/kustomization.yaml`

- [ ] **Step 1: Write the blueprint**

```yaml
# apps/base/authentik/blueprints/30-enforce.yaml
version: 1
metadata:
  name: homelab-enforce-passkey-mfa
  labels:
    blueprints.goauthentik.io/description: "Tighten default-authentication-mfa-validation: device_classes=[webauthn] only, not_configured_action=configure (force inline enrollment), webauthn_user_verification=required. Bind the existing default-authenticator-webauthn-setup stage as configuration_stages[0] so users without a WebAuthn device enroll inline during login. Preventive — guards future user additions."
entries:
  - model: authentik_stages_authenticator_validate.authenticatorvalidatestage
    state: present
    identifiers:
      name: default-authentication-mfa-validation
    attrs:
      not_configured_action: configure
      device_classes:
        - webauthn
      webauthn_user_verification: required
      last_auth_threshold: "seconds=0"
      configuration_stages:
        - !Find [
            authentik_stages_authenticator_webauthn.authenticatorwebauthnstage,
            [name, default-authenticator-webauthn-setup],
          ]
```

Note: `AuthenticatorValidateStage` has NO `configure_flow` field — only `configuration_stages` (list of authenticator setup stage UUIDs run inline during login). Setting one entry here means: if `not_configured_action: configure` triggers (user has no webauthn device), the user is presented inline with the WebAuthn setup stage to enroll, then continues through the auth flow. No separate flow redirect.

`device_classes` narrows from `[static, totp, webauthn, duo, sms, email]` to `[webauthn]`. The existing TOTP device on akadmin still exists in the DB but is no longer accepted by this stage. WebAuthn alone satisfies MFA. (TOTP can be deleted via API if desired — out of scope here.)

- [ ] **Step 2: Add file to ConfigMap generator**

Edit `apps/base/authentik/kustomization.yaml`:

```yaml
configMapGenerator:
  - name: authentik-blueprints-custom
    namespace: authentik
    files:
      - blueprints/00-noop.yaml
      - blueprints/10-voluntary-enrollment.yaml
      - blueprints/20-passkey-first.yaml
      - blueprints/30-enforce.yaml
```

- [ ] **Step 3: Validate**

```bash
python3 -c "import yaml; yaml.safe_load(open('apps/base/authentik/blueprints/30-enforce.yaml'))"
kustomize build apps/base/authentik | kubectl apply --dry-run=server -f -
```

Expected: no errors.

### Task 12: Commit, push, verify Phase 3

- [ ] **Step 1: Commit + push**

```bash
git add apps/base/authentik/blueprints/30-enforce.yaml \
        apps/base/authentik/kustomization.yaml

git commit -m "Authentik: enforce passkey for new users at MFA validate

Tighten default-authentication-mfa-validation:
- not_configured_action: skip → configure (force enrollment)
- device_classes: all → [webauthn] (passkey-only MFA)
- webauthn_user_verification: preferred → required
- configuration_stages: [] → [default-authenticator-webauthn-setup]
  (inline enrollment during login for users without a WebAuthn device)

Preventive: akadmin already has a passkey → unaffected. Any future user without
WebAuthn is redirected inline to enrollment on first login.

Spec: docs/superpowers/specs/2026-04-19-authentik-passkey-design.md
Phase 3/4 of passkey-first migration."

git push
```

- [ ] **Step 2: Reconcile + verify blueprint**

```bash
flux reconcile source git flux-system --timeout=90s
flux reconcile kustomization apps --timeout=120s
sleep 30

TOKEN=$(kubectl get secret -n authentik authentik -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_TOKEN}' | base64 -d)
kubectl exec -n authentik deploy/authentik-server -- sh -c \
  "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:9000/api/v3/blueprints/instances/" \
  | jq '.results[] | select(.path | contains("30-enforce")) | {path, status}'
```

Expected: `status: "successful"`.

- [ ] **Step 3: Verify MFA validate state**

```bash
kubectl exec -n authentik deploy/authentik-server -- sh -c \
  "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:9000/api/v3/stages/authenticator/validate/?name=default-authentication-mfa-validation" \
  | jq '.results[] | {device_classes, not_configured_action, webauthn_user_verification, configuration_stages}'
```

Expected: `device_classes: ["webauthn"]`, `not_configured_action: "configure"`, `webauthn_user_verification: "required"`, `configuration_stages: ["<webauthn-setup-stage UUID>"]`.

- [ ] **Step 4: Smoke test — re-login akadmin**

Incognito: visit `https://authentik.h0melab.work/`. Use passkey via Conditional UI (or password+MFA-validate path). Land on `/if/user/`. akadmin already has WebAuthn → no enrollment redirect. Confirms enforcement does not break existing-passkey users.

**Gate:** if smoke fails, revert immediately:

```bash
git revert --no-edit HEAD
git push
flux reconcile source git flux-system --timeout=90s
flux reconcile kustomization apps --timeout=120s
```

---

## Phase 4 — Documentation + Memory (PR 5)

### Task 13: Update HOMELAB_ANALYSIS.md

**Files:**
- Modify: `docs/HOMELAB_ANALYSIS.md`

- [ ] **Step 1: Update the Authentik app row**

Find the row for Authentik in the apps table (`| Authentik | Provider | SSO, PostgreSQL + Redis |`). Update the notes column:

```markdown
| Authentik | Provider | SSO, PostgreSQL + Redis, passkey-first via Conditional UI (password fallback retained) |
```

- [ ] **Step 2: Add changelog entry under "Recent highlights"**

Insert at the top of the "Recent highlights (2026):" list:

```markdown
- 2026-04-19: **Authentik passkey-first migration** — `IdentificationStage.webauthn_stage` (Conditional UI autofill since 2025.12) + `passwordless_flow` (button fallback) wired via 4 custom blueprints. ConfigMap mounted at `/blueprints/custom/` on server + worker. WebAuthn setup stage tightened to `resident_key_requirement=required` + `user_verification=required` and bound to `default-user-settings-flow` for voluntary enrollment. MFA validate enforces `device_classes=[webauthn]` + `not_configured_action=configure` + inline `configuration_stages` (preventive for future users). Password stage at order 20 of main flow retained as recovery path. RPID stays `authentik.h0melab.work` (preserved akadmin's existing 1Password credential). Spec: `docs/superpowers/specs/2026-04-19-authentik-passkey-design.md`. Plan: `docs/superpowers/plans/2026-04-19-authentik-passkey.md`.
```

- [ ] **Step 3: Add monitoring items to pending list**

Append to the "PENDING ITEMS" table:

```markdown
| Re-evaluate Authentik 2026.5 client hints (#20700) | 2026-06 | P3 |
| Watch Authentik #18232 (TOTP/WebAuthn pk collision in MFA Devices UI) | Backlog | P3 |
| Watch Authentik #19580 (multi-passkey wrong-pick) — relevant if enrolling 2nd passkey | Backlog | P3 |
| Consider removing default-authentication-password binding once 1+ month clean passkey ops | 2026-06 | P3 |
| Optional: delete akadmin's TOTP device (no longer accepted by tightened MFA validate) | Backlog | P3 |
```

### Task 14: Create rollback runbook

**Files:**
- Create: `docs/scripts/runbooks/authentik-passkey-rollback.md`

- [ ] **Step 1: Verify directory + create file**

```bash
mkdir -p docs/scripts/runbooks
```

```markdown
# Authentik Passkey-First — Rollback Runbook

**Owner**: akhozya
**Spec**: `docs/superpowers/specs/2026-04-19-authentik-passkey-design.md`
**Plan**: `docs/superpowers/plans/2026-04-19-authentik-passkey.md`
**Created**: 2026-04-19

## When to use

- Login broken for akadmin
- Conditional UI doesn't surface the credential + passwordless button missing
- Blueprint apply errors blocking other Authentik changes
- TOTP/WebAuthn device-management UI exposes #18232 collision in a blocking way

## Quick rollback (single phase)

```bash
git log --oneline -5 -- apps/base/authentik/
# Identify offending commit. Then:
git revert --no-edit <SHA>
git push
flux reconcile source git flux-system --timeout=90s
flux reconcile kustomization apps --timeout=120s
sleep 30
```

**Important**: `state: present` is partial-update. Removing a YAML key from a blueprint does NOT auto-null the corresponding DB field. To clear a field that was set by a prior blueprint, you must EITHER:

1. Use `state: absent` on the entry to fully delete the entity (only safe for entities the blueprint created — e.g. homelab-* flows/stages/bindings).
2. Patch the entity manually via API (see "Manual field reset" below).
3. Restore from the pre-flight Authentik snapshot (`~/authentik-snapshot-2026-04-19.tgz`).

## Manual field reset (e.g. unset `webauthn_stage` after Phase 2 revert)

```bash
TOKEN=$(kubectl get secret -n authentik authentik -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_TOKEN}' | base64 -d)
ID_PK=$(kubectl exec -n authentik deploy/authentik-server -- sh -c \
  "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:9000/api/v3/stages/identification/?name=default-authentication-identification" \
  | jq -r '.results[0].pk')

kubectl exec -n authentik deploy/authentik-server -- sh -c \
  "curl -s -X PATCH -H 'Authorization: Bearer $TOKEN' -H 'Content-Type: application/json' \
    -d '{\"webauthn_stage\": null, \"passwordless_flow\": null}' \
    http://localhost:9000/api/v3/stages/identification/$ID_PK/"
```

## Full rollback (all 4 phases)

```bash
# Find Phase 0 plumbing commit. Revert everything after it:
git log --oneline --grep="Authentik.*passkey" -- apps/base/authentik/

# Revert Phase 3, then Phase 2, then Phase 1 (in reverse landing order):
git revert --no-edit <PHASE3_SHA>
git revert --no-edit <PHASE2_SHA>
git revert --no-edit <PHASE1_SHA>
# Optionally revert Phase 0 (plumbing) too — keeps the empty ConfigMap mount; harmless.

git push
flux reconcile source git flux-system --timeout=90s
flux reconcile kustomization apps --timeout=120s
kubectl rollout restart deploy/authentik-server deploy/authentik-worker -n authentik
```

Then manual field resets per the patterns above for any field that was created/modified rather than entity-replaced.

## Verify post-rollback state

```bash
TOKEN=$(kubectl get secret -n authentik authentik -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_TOKEN}' | base64 -d)

# Identification should be back to defaults
kubectl exec -n authentik deploy/authentik-server -- sh -c \
  "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:9000/api/v3/stages/identification/?name=default-authentication-identification" \
  | jq '.results[] | {webauthn_stage, passwordless_flow}'
# Expected: both null

# MFA validate back to skip
kubectl exec -n authentik deploy/authentik-server -- sh -c \
  "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:9000/api/v3/stages/authenticator/validate/?name=default-authentication-mfa-validation" \
  | jq '.results[] | {device_classes, not_configured_action}'
# Expected: device_classes includes all 6, not_configured_action: skip
```

## Lockout recovery (worst case — cannot log in at all)

1. Shell into worker, force-reset target flow via Django ORM:

   ```bash
   kubectl exec -n authentik deploy/authentik-worker -- ak shell
   ```

   ```python
   from authentik.stages.identification.models import IdentificationStage
   from authentik.stages.authenticator_validate.models import AuthenticatorValidateStage
   s = IdentificationStage.objects.get(name="default-authentication-identification")
   s.webauthn_stage = None
   s.passwordless_flow = None
   s.save()
   v = AuthenticatorValidateStage.objects.get(name="default-authentication-mfa-validation")
   v.not_configured_action = "skip"
   v.device_classes = ["static", "totp", "webauthn", "duo", "sms", "email"]
   v.configuration_stages.clear()
   v.save()
   ```

2. If irrecoverable, restore the pre-flight snapshot:

   ```bash
   tar xzf ~/authentik-snapshot-2026-04-19.tgz -C /tmp
   # Manually re-apply pre-change state via API PATCH calls using the snapshot JSON
   ```

3. Last resort: PG point-in-time restore via CNPG (no scheduled backups currently configured on `main-postgres` per audit — would need a manual `kubectl cnpg backup` taken before each phase as a safety net).

## Related issues

- Authentik upstream issues monitored: #18232, #19580, #20934, #21418
- Issue #20700 (client hints, 2026.5) — additive, not a rollback trigger
```

### Task 15: Update CLAUDE.md secret name

**Files:**
- Modify: `~/.claude/CLAUDE.md`

The chezmoi-managed CLAUDE.md may reference `authentik-secret` in some places. The actual secret name is `authentik`.

- [ ] **Step 1: Check current state**

```bash
grep -n "authentik-secret\|authentik secret" ~/.claude/CLAUDE.md
```

If matches found in a context that references the secret name (vs just the namespace), update. If no matches, skip this task.

- [ ] **Step 2: Edit (if needed)**

Use editor of choice to replace `authentik-secret` with `authentik` in the secret-name context.

- [ ] **Step 3: Sync chezmoi**

```bash
chezmoi add ~/.claude/CLAUDE.md
git -C ~/.local/share/chezmoi add -A
git -C ~/.local/share/chezmoi commit -m "Authentik: secret name is 'authentik' not 'authentik-secret'"
git -C ~/.local/share/chezmoi push
```

### Task 16: Save memory file

**Files:**
- Create: `/Users/akhozya/.claude/projects/-Users-akhozya-source-code-homelab/memory/authentik_passkey_setup.md`
- Modify: `/Users/akhozya/.claude/projects/-Users-akhozya-source-code-homelab/memory/MEMORY.md`

- [ ] **Step 1: Write the memory file**

```markdown
---
name: Authentik passkey-first setup
description: Authentik 2026.2.2 uses Conditional UI (webauthn_stage on identification) + passwordless_flow button + force-enrollment on MFA validate via configuration_stages, all via 4 custom blueprints in /blueprints/custom/. Password stays bound at order 20 as recovery.
type: project
---

# Authentik passkey-first

**Active since**: 2026-04-19
**Spec**: `docs/superpowers/specs/2026-04-19-authentik-passkey-design.md`
**Plan**: `docs/superpowers/plans/2026-04-19-authentik-passkey.md`
**Rollback**: `docs/scripts/runbooks/authentik-passkey-rollback.md`

## Why
Single human user (akadmin) wanted passwordless login. Passkey already enrolled (1Password) but flow wasn't wired. Migrated declaratively via blueprints under GitOps.

## How to apply / debug
- Custom blueprints live in `apps/base/authentik/blueprints/`, generated into ConfigMap `authentik-blueprints-custom`, mounted at `/blueprints/custom/` on server + worker.
- Authentik blueprint apply order across files is NOT alphabetical (`Path.rglob` no `sorted()`). Use within-file ordered entries for any cross-entry deps. Each PR ships ONE file; cross-phase refs use `!Find` (DB lookup, works after prior phase landed).
- `state: present` is PARTIAL update — removing a YAML key does NOT null the DB field. Use `state: absent` to delete entities or PATCH the API to null fields.
- `flowstagebinding` unique constraint: `(target, stage, order)` — identifiers MUST set all three.
- `AuthenticatorValidateStage.configure_flow` does NOT exist — only `configuration_stages` (list of setup stage UUIDs run inline during login when `not_configured_action: configure`).
- RPID locked to `authentik.h0melab.work` — do NOT set `AUTHENTIK_COOKIE_DOMAIN` or existing 1P credential breaks.
- Bootstrap token secret name is `authentik` (single envFrom secret, not `authentik-secret`).
- Password stage at order 20 of main auth flow remains as recovery path.
- MFA validate `device_classes=[webauthn]` only — TOTP device on akadmin still exists in DB but unused; can be deleted via API.
- `last_auth_threshold` JSON shape is quoted string `"seconds=0"` (Django timedelta format).
- Flow primary key field is `pk` (not `pbm_uuid`).
```

- [ ] **Step 2: Add pointer to MEMORY.md**

Edit `/Users/akhozya/.claude/projects/-Users-akhozya-source-code-homelab/memory/MEMORY.md`. Under the "Index → detailed files" section, add a new "### Auth" subsection (or append to an existing relevant section):

```markdown
### Auth
- [Authentik passkey-first setup](authentik_passkey_setup.md) — Conditional UI + passwordless button + enforcement, blueprint shape, RPID lock, gotchas
```

### Task 17: Final verification + plan closure

- [ ] **Step 1: Commit homelab repo docs changes**

```bash
git add docs/HOMELAB_ANALYSIS.md docs/scripts/runbooks/authentik-passkey-rollback.md
git commit -m "docs: Authentik passkey-first migration — analysis + rollback runbook"
git push
```

- [ ] **Step 2: Final verification — full system smoke**

```bash
TOKEN=$(kubectl get secret -n authentik authentik -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_TOKEN}' | base64 -d)

# All 4 blueprints applied successfully
kubectl exec -n authentik deploy/authentik-server -- sh -c \
  "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:9000/api/v3/blueprints/instances/" \
  | jq '[.results[] | select(.path | contains("custom"))] | {count: length, all_successful: (all(.status == "successful"))}'
```

Expected: `{count: 4, all_successful: true}`.

- [ ] **Step 3: Spot-check 3 OIDC apps**

For 3 of the 10 apps (pick across the spread — e.g. audiobookshelf, grafana, immich), incognito login via Authentik passkey-first → expect successful redirect to app dashboard.

- [ ] **Step 4: Plan closure note**

Append to this plan file:

```markdown
---

## Plan closed: <YYYY-MM-DD>

All 4 phases applied. Full system smoke passed. 4 blueprints `successful`. Conditional UI working in <browsers tested>. Password fallback verified. 10 OIDC apps authenticating via passkey-first flow.
```

Commit:

```bash
git add docs/superpowers/plans/2026-04-19-authentik-passkey.md
git commit -m "docs: close Authentik passkey-first plan"
git push
```

---

## Self-Review Notes

- All 4 spec phases mapped to PRs (Phase 0 = PR1 / tasks 1-6, Phase 1 = PR2 / tasks 7-8, Phase 2 = PR3 / tasks 9-10, Phase 3 = PR4 / tasks 11-12, Docs = PR5 / tasks 13-17).
- Restructured from 7 blueprint files (original plan, broken because filename ordering isn't honored) to 4 phase-aligned files. Within each file, entry order IS preserved + atomic.
- Phase 1 partial-update preserves `configure_flow` on the WebAuthn setup stage (the orphan path akadmin currently uses) — verified by Step 4 check after apply.
- Phase 3 uses `configuration_stages` (the correct field on `AuthenticatorValidateStage`), not the non-existent `configure_flow`.
- All `!Find` references resolve against either pre-existing entities (default-*) or earlier-applied entries; `!KeyOf` used for within-file refs in Phase 2 to avoid race-with-creation.
- All `flowstagebinding` identifiers set `target+stage+order` (the unique constraint).
- Rollback runbook covers the partial-update gotcha (removing YAML key ≠ unsetting DB field) with explicit PATCH commands.
- Pre-flight snapshot saved as forensic recovery option (no scheduled CNPG backups are configured on `main-postgres` per live audit; manual `kubectl cnpg backup` could be added as additional safety net before each PR but kept out of plan to avoid scope creep).
- Plan uses literal `flux reconcile` invocations (the zsh `fr` function is not callable from `bash -c`).
- API queries use `pk` (the actual primary key field name).

---

## Plan closed: 2026-04-20

All 4 phases applied. 4 custom blueprints `successful`. Smoke tests 6a (Conditional UI autofill) + 6b (passwordless button) + 6c (password+MFA step-up fallback) + 6d (OIDC delegation via audiobookshelf) all pass on Brave (incognito, 1Password unlocked).

### Execution deviations from plan
1. **Zombie existing credential**: akadmin's 2025-10-21 1Password WebAuthn device had `rp_id: null` and was never assertion-tested (`sign_count: null`). First Phase 2 smoke surfaced this — 1Password had no locally-saved credential for the RPID. Fix: re-enrolled via Phase 1's User Settings binding (fresh pk=34, working). Deleted zombie pk=1 via API (`DELETE /api/v3/authenticators/admin/webauthn/1/`, HTTP 204) because UI checkbox was hit by #18232 (selecting WebAuthn pk=1 also selected TOTP pk=1).
2. **Phase 2 first apply errored**: `IdentificationStageSerializer.validate()` rejected the partial patch with "When no user fields are selected, at least one source must be selected". Root cause: validator runs against supplied data only, not merged state, even with `partial=True`. Fix: include `user_fields: [email, username]` + `sources: []` explicitly in the identification patch attrs. Updated in commit 468da0ba.
3. **Blueprint API path**: plan referenced `/api/v3/blueprints/instances/` — actual path is `/api/v3/managed/blueprints/` (paginated default 20, use `?page_size=100`). Runbook corrected.
4. **Known harmless quirk**: fresh WebAuthn device pk=34 also returns `rp_id: null` via API. Credential works regardless — `rp_id` appears to be a display-only field populated after first assertion in 2026.2.x. Documented in runbook.
5. **Rebase required before Phase 3 push**: upstream renovate commits (n8n + audiobookshelf image updates) merged between Phase 2 + Phase 3; `git pull --rebase origin main && git push` cleanly resolved.
6. **TOTP added back as fallback 2FA (post-closure adjustment, commit cbac7ecc)**: original Phase 3 narrowed `device_classes=[webauthn]`. User raised lockout concern — TOTP device on akadmin became unreachable, removing one recovery layer. Relaxed to `[webauthn, totp]`. `configuration_stages` unchanged (still WebAuthn-only) so new-user enrollment forcing is preserved. Required `kubectl rollout restart deploy/authentik-server` to clear in-memory stage cache (DB updated immediately, API served stale until restart). Cache caveat added to runbook + memory file.

### Final state
- `default-authentication-identification`: `webauthn_stage`=UUID, `passwordless_flow`=UUID, `password_stage`=null, `user_fields`=[email, username], `pretend_user_exists`=true
- `default-authentication-mfa-validation`: `device_classes`=[webauthn, totp] (TOTP retained as recovery; post-rollout adjustment 2026-04-20), `not_configured_action`=configure, `webauthn_user_verification`=required, `configuration_stages`=[default-authenticator-webauthn-setup UUID — passkey-only inline enrollment for new users], `last_auth_threshold`=seconds=0
- `default-authenticator-webauthn-setup`: `resident_key_requirement`=required, `user_verification`=required, `configure_flow`=preserved (UUID)
- `default-user-settings-flow`: bindings at orders 20 (prompt), 30 (webauthn setup, NEW), 100 (user-write)
- 3 new homelab-* entities: `homelab-passwordless-webauthn-validate` stage, `homelab-authentication-webauthn-passwordless` flow, `homelab-passkey-setup-flow`
- akadmin: 1 active WebAuthn device (1Password, pk=34, `sign_count` incremented after smoke) + 1 TOTP device (unused by tightened MFA validate, pending optional delete)
