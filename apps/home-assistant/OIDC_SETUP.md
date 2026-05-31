# Home Assistant OIDC Setup with Authentik

Manual steps for HA OIDC integration with Authentik.

## Prerequisites

Auto-configured via GitOps:
- HA configuration.yaml with `auth_oidc`
- Secrets for OIDC client creds
- Config mounted to `/config/secrets.yaml`
- HACS auto-installed via init container
- hass-oidc-auth auto-installed via init container

## Manual Setup Steps

### 1. ~~Install hass-oidc-auth via HACS~~ (Auto-installed)

**Automated!** HACS + hass-oidc-auth auto-install on pod startup via init containers.

### 2. (Optional) Configure HACS

For other HACS integrations:
1. Settings → Devices & Services
2. Click "+ ADD INTEGRATION"
3. Search "HACS"
4. GitHub auth flow

### 3. Configure Authentik Provider

The `home-assistant` OAuth2 provider + application already exist in Authentik (survived the
2026-04 → 2026-05 OIDC disable; discovery endpoint returns 200). For a fresh setup, create:

1. **Access Authentik Admin:** https://authentik.h0melab.work/if/admin
2. **Create Provider:**
   - Applications → Providers → Create
   - **Type:** OAuth2/OpenID Provider
   - **Name:** `Home Assistant`
   - **Authorization flow:** `default-provider-authorization-implicit-consent`
   - **Client type:** `Confidential`
   - **Client ID:** `home-assistant`
   - **Client Secret:** _SOPS-only — stored in `secrets.yaml` → `oidc_client_secret`. Never commit plaintext; the provider's secret must equal that value._
   - **Redirect URI (Strict):** `https://homeassistant.h0melab.work/auth/oidc/callback`
   - **Signing Key:** any available key (RS256 `id_token_signing_alg`)
   - **Scopes:** `openid`, `email`, `profile`
   - SAVE

3. **Create Application:**
   - Applications → Applications → Create
   - **Name:** `Home Assistant`
   - **Slug:** `home-assistant`
   - **Provider:** select provider above
   - **Launch URL:** `https://homeassistant.h0melab.work`
   - CREATE

### 4. Test OIDC Login

1. Navigate to https://homeassistant.h0melab.work
2. See "OpenID Connect" login button
3. Click → auth via Authentik
4. First login creates new HA user auto
5. User linked to Authentik account

## Configuration Details

**OIDC Issuer:** `https://authentik.h0melab.work/application/o/home-assistant/`
**Client ID:** `home-assistant`
**Client Secret:** (in `home-assistant-oidc` secret)
**Callback URL:** `https://homeassistant.h0melab.work/auth/oidc/callback`
**Auto-create users:** `true` (on first OIDC login)
**Username claim:** `email` (OIDC email = HA username)

## Security Notes

- OIDC client secret SOPS-encrypted in repo
- `secrets.yaml` mounted read-only from K8s Secret
- Users auto-created on first login (no pre-provisioning)
- HA uses email from Authentik as username

## Troubleshooting

**Issue:** "Unknown error" on OIDC login
**Fix:** Check HA logs:
```bash
kubectl logs -n home-assistant deployment/home-assistant --tail=100
```

**Issue:** OIDC button missing
**Fix:** Verify hass-oidc-auth installed via HACS + HA restarted

**Issue:** "Invalid client" error
**Fix:** Verify client ID + secret match between HA config and Authentik provider
