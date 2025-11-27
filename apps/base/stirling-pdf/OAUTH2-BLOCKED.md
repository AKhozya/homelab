# Stirling PDF OAuth2 Configuration - BLOCKED

## Status: ⏸️ Waiting for Upstream Fix

OAuth2/OIDC authentication with Authentik is currently **NOT WORKING** in Stirling PDF v2.0.x due to an upstream bug.

## Issue Details

**GitHub Issue**: [#5020 - "Login With..." button for OAuth2 doesn't appear](https://github.com/Stirling-Tools/Stirling-PDF/issues/5020)

**Symptoms**:
- Login page shows "or" divider but no OAuth2 button
- Only username/password form is visible
- Backend logs show "OAuth2Configuration initialized - OAuth2 enabled: true"
- OAuth2 endpoints return HTML instead of initiating OAuth2 flow

**Affected Versions**: v2.0.0, v2.0.1

**Status**:
- Developers acknowledged: "We are working on this now!"
- [v2.0.1 release notes](https://github.com/Stirling-Tools/Stirling-PDF/releases/tag/v2.0.1) state: "Certain SSO providers are not working with V2 - ongoing issue still being addressed"

## Current Configuration

Our configuration is **CORRECT** (matches official documentation), but the feature is broken in v2.0:

```yaml
security:
  enableLogin: true
  loginMethod: all  # Using "all" to keep username/password login working
  oauth2:
    enabled: true
    issuer: https://authentik.h0melab.work/application/o/stirling-pdf/
    clientId: stirling-pdf-client
    clientSecret: [REDACTED]
    scopes: openid, profile, email
    useAsUsername: email
    autoCreateUser: true
    blockRegistration: false
    provider: oidc
premium:
  enabled: true
  proFeatures:
    SSOAutoLogin: false
```

**Redirect URI configured in Authentik**: `https://stirling.h0melab.work/login/oauth2/code/oidc`

## Attempted Fixes (All Failed)

1. ✅ Changed `loginMethod: all` → `loginMethod: oauth2` - No OAuth2 button appeared
2. ✅ Tried `client.keycloak` nested structure - Didn't work
3. ✅ Tried `client.github` structure - Didn't work
4. ✅ Added `premium.enabled: true` - No effect
5. ✅ Verified all fields non-empty - Configuration is correct

## Temporary Workaround

Using **username/password authentication** with `loginMethod: all` until OAuth2 is fixed upstream.

## Next Steps

1. **Monitor issue #5020** for updates from Stirling PDF developers
2. **Check release notes** for v2.0.2+ mentioning OAuth2/SSO fixes
3. **Test immediately** when new version is released
4. **Update this document** when issue is resolved

## References

- [GitHub Issue #5020](https://github.com/Stirling-Tools/Stirling-PDF/issues/5020)
- [v2.0.1 Release Notes](https://github.com/Stirling-Tools/Stirling-PDF/releases/tag/v2.0.1)
- [Authelia Integration Guide](https://www.authelia.com/integration/openid-connect/clients/stirling-pdf/)

---

**Last Updated**: 2025-11-27
**Last Checked Version**: v2.0.1
