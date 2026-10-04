# Authentik Passkey-First — Rollback Runbook

**Owner**: akhozya
**Created**: 2026-04-19
**Passkey rollout completed**: 2026-04-20

## When to use

- Login broken for akadmin
- Conditional UI doesn't surface the credential + passwordless button missing
- Blueprint apply errors blocking other Authentik changes
- The TOTP/WebAuthn device-ID collision in the UI (upstream #18232, see [Known behaviors](#known-behaviors--gotchas)) blocks device management

## API endpoint cheatsheet

```bash
TOKEN=$(kubectl get secret -n authentik authentik -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_TOKEN}' | base64 -d)

# Blueprint instances (note path: /api/v3/managed/blueprints/, paginated default page_size=20)
kubectl exec -n authentik deploy/authentik-server -- curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:9000/api/v3/managed/blueprints/?page_size=100"

# WebAuthn devices (cluster-wide)
kubectl exec -n authentik deploy/authentik-server -- curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:9000/api/v3/authenticators/admin/webauthn/"

# Identification stage
kubectl exec -n authentik deploy/authentik-server -- curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:9000/api/v3/stages/identification/?name=default-authentication-identification"

# MFA validate
kubectl exec -n authentik deploy/authentik-server -- curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:9000/api/v3/stages/authenticator/validate/?name=default-authentication-mfa-validation"
```

## Quick rollback (single phase)

```bash
git log --oneline -5 -- apps/authentik/
# Identify offending commit. Then:
git revert --no-edit <SHA>
git push
flux reconcile source git flux-system --timeout=90s
flux reconcile kustomization apps --timeout=120s
```

**Important**: `state: present` updates only the fields it names. If you remove a key from a blueprint, the database field keeps its value. To clear a field a blueprint set, do one of these:

1. Use `state: absent` on the entry to fully delete the entity (only safe for entities the blueprint created — e.g. `homelab-*` flows/stages/bindings).
2. Patch the entity manually via API (see "Manual field reset" below).
3. Restore from the pre-flight Authentik snapshot (`~/authentik-snapshot-2026-04-19.tgz`).

## Manual field reset (e.g. unset `webauthn_stage` after Phase 2 revert)

```bash
TOKEN=$(kubectl get secret -n authentik authentik -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_TOKEN}' | base64 -d)
ID_PK=$(kubectl exec -n authentik deploy/authentik-server -- curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:9000/api/v3/stages/identification/?name=default-authentication-identification" \
  | jq -r '.results[0].pk')

kubectl exec -n authentik deploy/authentik-server -- curl -s -X PATCH \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"webauthn_stage": null, "passwordless_flow": null, "user_fields": ["email", "username"], "sources": []}' \
  "http://localhost:9000/api/v3/stages/identification/$ID_PK/"
```

Every PATCH must include `user_fields` and `sources`: the serializer requires at least one of them to be non-empty, even on a partial update.

## Full rollback (phases 0-3)

This section reverts phases 0-3. It also removes blueprint `40-remove-password-binding.yaml` (added 2026-06-05, `5a79e178`) and restores the password binding, first. It keeps `50-homepage-forward-auth.yaml` (added 2026-07-25, `21071530`).

Restore the **password** binding first. Blueprint 40 removed the password stage from `default-authentication-flow`. Reverting phase 3 sets the MFA stage back to `not_configured_action: skip`. With both in place, a user without an MFA device signs in with a username alone, on an internet-facing hostname. So before any revert below:

1. Remove blueprint 40, so it does not delete the binding again: delete `apps/authentik/blueprints/40-remove-password-binding.yaml` and its line in `apps/authentik/kustomization.yaml`, commit and push, then `flux reconcile kustomization apps --with-source`. A `git revert` of `5a79e178` can conflict, because blueprint 50's line was added next to it later.
2. Recreate the binding. Reverting the file does not bring it back. These identifiers come from blueprint 40; this snippet has not been run:

   ```bash
   kubectl exec -n authentik deploy/authentik-worker -- ak shell -c "
   from authentik.flows.models import Flow, FlowStageBinding
   from authentik.stages.password.models import PasswordStage
   b, created = FlowStageBinding.objects.get_or_create(
       target=Flow.objects.get(slug='default-authentication-flow'),
       stage=PasswordStage.objects.get(name='default-authentication-password'),
       order=20)
   print(b.pk, created)
   "
   ```

3. Check that a sign-in asks for the password before you revert the phases.

The phase commits edited `apps/base/authentik/`, before `b92a8032` moved it to `apps/authentik/`:

| Phase | Commit | Adds |
|---|---|---|
| 0, plumbing | `7d3d55d0` | the blueprint ConfigMap and its mount |
| 1 | `084c5641` | `10-voluntary-enrollment.yaml` |
| 2 | `55385305`, fixed by `6e4646c4` | `20-passkey-first.yaml` |
| 3 | `bada5b6a`, then `a2bf7649` added TOTP to `device_classes` | `30-enforce.yaml` |

Remove the phase blueprints by hand; do not `git revert` the phase commits. Later commits changed `30-enforce.yaml` and the kustomization, so a revert of `bada5b6a` stops on a conflict (tested 2026-10-04). Keep phase 0 (`7d3d55d0`): blueprint 50 still loads through its ConfigMap and mount, and it refers only to authentik's default flows.

```bash
git rm apps/authentik/blueprints/30-enforce.yaml apps/authentik/blueprints/20-passkey-first.yaml \
  apps/authentik/blueprints/10-voluntary-enrollment.yaml
# Then delete those three lines from configMapGenerator.files in apps/authentik/kustomization.yaml.
kustomize build apps/authentik >/dev/null
# git rm stages only the deletions; stage the kustomization edit too.
git add apps/authentik/kustomization.yaml
git commit -m "authentik: roll back passkey phases 1-3"

git push
flux reconcile source git flux-system --timeout=90s
flux reconcile kustomization apps --timeout=120s
# Delete pods, not `rollout restart`: Flux's drift correction reverts the restartedAt annotation.
agents/skills/_shared/restart-workload.sh authentik app=authentik,component=server 300 &&
  agents/skills/_shared/restart-workload.sh authentik app=authentik,component=worker 300
```

If a revert removes a key, or the whole blueprint, the field keeps the value that blueprint set: `state: present` leaves fields outside `attrs` unchanged (authentik blueprint docs, `structure.mdx`). Reset each such field by hand, as in [Manual field reset](#manual-field-reset-eg-unset-webauthn_stage-after-phase-2-revert). If the revert restores the key with an earlier value, the next blueprint apply writes that value, and no reset is needed.

## Verify post-rollback state

```bash
TOKEN=$(kubectl get secret -n authentik authentik -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_TOKEN}' | base64 -d)

# Identification should be back to defaults
kubectl exec -n authentik deploy/authentik-server -- curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:9000/api/v3/stages/identification/?name=default-authentication-identification" \
  | jq '.results[] | {webauthn_stage, passwordless_flow}'
# Expected: both null

# MFA validate back to skip
kubectl exec -n authentik deploy/authentik-server -- curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:9000/api/v3/stages/authenticator/validate/?name=default-authentication-mfa-validation" \
  | jq '.results[] | {device_classes, not_configured_action}'
# Expected: device_classes includes all 6, not_configured_action: skip
```

## Cache caveat

Authentik server pods cache stage state in memory. After a blueprint that changes a stage reports `status: successful`, either server replica may still serve the old values. If `device_classes` or another field does not match the blueprint, restart the server:

```bash
agents/skills/_shared/restart-workload.sh authentik app=authentik,component=server 300
```

The database holds the real value. Check it directly:
```bash
kubectl exec -n authentik deploy/authentik-worker -- ak shell -c "
from authentik.stages.authenticator_validate.models import AuthenticatorValidateStage
v = AuthenticatorValidateStage.objects.get(name='default-authentication-mfa-validation')
print(v.device_classes, v.not_configured_action)
"
```

## Lockout recovery (worst case — cannot log in at all)

1. Open a shell in the worker and reset the stages through the Django ORM:

   ```bash
   kubectl exec -n authentik deploy/authentik-worker -it -- ak shell
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

3. Last resort: restore the `authentik` database from the nightly `pg_dump` with the [DR runbook's PostgreSQL steps](../disaster-recovery/README.md#postgresql). Restore only `authentik.dump`, not every dump in the archive. Changes since that night's 03:00 dump are lost. There is no point-in-time recovery: the cluster keeps logical dumps only, by design ([BACKUP_STRATEGY.md](../BACKUP_STRATEGY.md)).

## Blueprint discovery troubleshooting

If a newly-pushed blueprint file doesn't appear in the API:

```bash
# Confirm file is mounted on worker
kubectl exec -n authentik deploy/authentik-worker -- ls -la /blueprints/custom/

# Queue a blueprint discovery. .send() only enqueues the dramatiq task and returns.
# The command does not wait for discovery to finish.
kubectl exec -n authentik deploy/authentik-worker -- ak shell -c "
from authentik.blueprints.v1.tasks import blueprints_discovery
blueprints_discovery.send()
"

# Or restart worker pod to trigger periodic discovery on boot
agents/skills/_shared/restart-workload.sh authentik app=authentik,component=worker 300
```

## Related issues

- Authentik upstream issues monitored: #18232, #19580, #20934, #21418
- Issue #20700 (client hints, 2026.5) — additive, not a rollback trigger

## Known behaviors / gotchas

- **WebAuthn devices API returns `rp_id: null` at registration**: the field is display-only and fills in after the first sign-in with that passkey. The credential works either way, so `rp_id: null` on a new enrolment does not mean it is broken.
- **`/api/v3/managed/blueprints/` is paginated**: default 20/page. Use `?page_size=100` to list all 25+ on a typical install (20 defaults + 5 custom).
- **TOTP/WebAuthn pk collision in UI** (#18232): deleting via UI checkboxes can target the wrong device class. Always delete WebAuthn devices via API by UUID / integer pk.
