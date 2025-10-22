# Home Assistant OIDC Setup with Authentik

This document describes the manual steps required to complete the Home Assistant OIDC integration with Authentik.

## Prerequisites

The following has been configured via GitOps (automatic):
- ✅ Home Assistant configuration.yaml with `auth_oidc` section
- ✅ Secrets for OIDC client credentials
- ✅ Configuration mounted to `/config/secrets.yaml`
- ✅ HACS automatically installed via init container
- ✅ hass-oidc-auth integration automatically installed via init container

## Manual Setup Steps

### 1. ~~Install hass-oidc-auth via HACS~~ (✅ Auto-installed)

**This step is now automated!** HACS and the hass-oidc-auth integration are automatically installed on pod startup via init containers.

### 2. (Optional) Configure HACS

If you want to use HACS for other integrations:
1. Go to Settings → Devices & Services
2. Click "+ ADD INTEGRATION"
3. Search for "HACS"
4. Complete the GitHub authentication flow

### 3. Configure Authentik Provider

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
