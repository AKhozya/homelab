# Home Assistant OIDC Setup with Authentik

This document describes the manual steps required to complete the Home Assistant OIDC integration with Authentik.

## Prerequisites

The following has been configured via GitOps:
- ✅ Home Assistant configuration.yaml with `auth_oidc` section
- ✅ Secrets for OIDC client credentials
- ✅ Configuration mounted to `/config/secrets.yaml`

## Manual Setup Steps

### 1. Install hass-oidc-auth via HACS

The `hass-oidc-auth` custom component is required and must be installed manually via HACS:

1. **Access Home Assistant**: Navigate to https://homeassistant.h0melab.work
2. **Open HACS**: Settings → Devices & Services → HACS
3. **Add Custom Repository**:
   - Click the three dots menu (⋮) → Custom repositories
   - Repository: `https://github.com/christiaangoossens/hass-oidc-auth`
   - Category: `Integration`
   - Click ADD
4. **Install the Integration**:
   - Search for "OpenID Connect Auth"
   - Click DOWNLOAD
   - Restart Home Assistant

### 2. Configure Authentik Provider

Create an OAuth2/OIDC Provider in Authentik:

1. **Access Authentik Admin**: Navigate to https://authentik.h0melab.work/if/admin
2. **Create Provider**:
   - Go to Applications → Providers → Create
   - **Type**: OAuth2/OpenID Provider
   - **Name**: `Home Assistant`
   - **Authorization flow**: `default-provider-authorization-implicit-consent`
   - **Client type**: `Confidential`
   - **Client ID**: `home-assistant`
   - **Client Secret**: `2e172f428d9286839323245fe57acb535a534084d0c3ac98f4ba7f994697e0bc`
   - **Redirect URIs**: `https://homeassistant.h0melab.work/auth/oidc/callback`
   - **Signing Key**: Choose your certificate
   - **Scopes**: `openid`, `email`, `profile`
   - Click SAVE

3. **Create Application**:
   - Go to Applications → Applications → Create
   - **Name**: `Home Assistant`
   - **Slug**: `home-assistant`
   - **Provider**: Select the provider created above
   - **Launch URL**: `https://homeassistant.h0melab.work`
   - Click CREATE

### 3. Restart Home Assistant

After installing the HACS integration and configuring Authentik:

```bash
kubectl rollout restart deployment -n home-assistant home-assistant
```

### 4. Test OIDC Login

1. Navigate to https://homeassistant.h0melab.work
2. You should see an "OpenID Connect" login button
3. Click it to authenticate via Authentik
4. On first login, a new Home Assistant user will be created automatically
5. The user will be linked to your Authentik account

## Configuration Details

**OIDC Issuer**: `https://authentik.h0melab.work/application/o/home-assistant/`
**Client ID**: `home-assistant`
**Client Secret**: (stored in `home-assistant-oidc` secret)
**Callback URL**: `https://homeassistant.h0melab.work/auth/oidc/callback`
**Auto-create users**: `true` (users created on first OIDC login)
**Username claim**: `email` (OIDC email used as Home Assistant username)

## Security Notes

- The OIDC client secret is encrypted with SOPS in the repository
- The `secrets.yaml` file is mounted read-only from a Kubernetes Secret
- Users are automatically created on first login (no pre-provisioning needed)
- Home Assistant will use the email from Authentik as the username

## Troubleshooting

**Issue**: "Unknown error" on OIDC login
**Solution**: Check Home Assistant logs for detailed error messages:
```bash
kubectl logs -n home-assistant deployment/home-assistant --tail=100
```

**Issue**: OIDC button not appearing
**Solution**: Ensure hass-oidc-auth is installed via HACS and Home Assistant has been restarted

**Issue**: "Invalid client" error
**Solution**: Verify the client ID and secret match between Home Assistant config and Authentik provider
