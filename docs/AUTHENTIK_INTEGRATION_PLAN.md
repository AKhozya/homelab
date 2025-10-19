# Authentik SSO Integration Plan

## Overview
Centralized authentication for all homelab services using Authentik as the identity provider.

## Current Status
- ✅ Authentik deployed and running at https://authentik.h0melab.work
- ⏳ Certificate issue (Let's Encrypt rate limit) - will auto-resolve 2025-10-20 04:16:16 UTC
- ✅ Authentik uses PostgreSQL (main-postgres) and Redis from databases namespace

## Applications to Integrate

### 1. Home Assistant (Priority: High)
**Protocol**: OAuth2/OIDC
**Documentation**: https://docs.goauthentik.io/integrations/services/home-assistant/
**Current Auth**: Local user (akhozya)
**Plan**:
- Create OAuth2/OIDC Provider in Authentik
- Create Application in Authentik
- Configure Home Assistant `configuration.yaml` with `auth_providers`
- Add `homeassistant` and `authentik` providers for migration period
- Test login with Authentik
- Remove local auth provider after validation

**Configuration Changes**:
- File: `apps/base/home-assistant/configmap.yaml`
- Add Authentik OAuth configuration to `configuration.yaml`

---

### 2. Immich (Priority: High)
**Protocol**: OAuth2
**Documentation**: https://immich.app/docs/administration/oauth
**Current Auth**: Local admin user
**Plan**:
- Create OAuth2 Provider in Authentik
- Configure Immich OAuth settings via environment variables
- Required env vars: `OAUTH_ENABLED`, `OAUTH_ISSUER_URL`, `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`

**Configuration Changes**:
- File: `apps/base/immich/release.yaml`
- Add OAuth environment variables to server component

---

### 3. Paperless-NGX (Priority: High)
**Protocol**: OIDC
**Documentation**: https://docs.paperless-ngx.com/configuration/#single-sign-on
**Current Auth**: Unknown
**Plan**:
- Create OIDC Provider in Authentik
- Configure Paperless-NGX with `PAPERLESS_APPS` configuration
- Set up auto-account creation and group mapping

**Configuration Changes**:
- File: `apps/base/paperless-ngx/deployment.yaml` or HelmRelease
- Add OIDC environment variables

---

### 4. Audiobookshelf (Priority: Medium)
**Protocol**: OIDC
**Documentation**: https://www.audiobookshelf.org/docs#oidc-authentication
**Current Auth**: Unknown
**Plan**:
- Create OIDC Provider in Authentik
- Configure Audiobookshelf OIDC settings
- Map Authentik groups to Audiobookshelf roles

**Configuration Changes**:
- Check current deployment method
- Add OIDC configuration

---

### 5. Linkding (Priority: Medium)
**Protocol**: OIDC
**Documentation**: https://github.com/sissbruecker/linkding/blob/master/docs/Options.md#sso
**Current Auth**: Local users
**Plan**:
- Create OIDC Provider in Authentik
- Set `LD_ENABLE_OIDC=True`
- Configure OIDC endpoint URLs and credentials

**Configuration Changes**:
- File: Check linkding deployment
- Add OIDC environment variables

---

### 6. Mealie (Priority: Medium)
**Protocol**: OIDC
**Documentation**: https://docs.mealie.io/documentation/getting-started/authentication/oidc/
**Current Auth**: Local users + existing setup
**Plan**:
- Create OIDC Provider in Authentik
- Configure Mealie OIDC settings
- Set up group and admin mapping

**Configuration Changes**:
- File: Check Mealie HelmRelease
- Add OIDC configuration

---

### 7. Wallabag (Priority: Low)
**Protocol**: OAuth2
**Documentation**: Limited - may require custom auth provider
**Current Auth**: Local users
**Plan**:
- Research Wallabag OAuth2 support
- May use reverse proxy authentication as fallback
- Consider using Traefik ForwardAuth with Authentik

**Configuration Changes**:
- TBD based on research

---

### 8. n8n (Priority: Medium)
**Protocol**: LDAP or reverse proxy auth
**Documentation**: https://docs.n8n.io/hosting/authentication/
**Current Auth**: Basic auth or local
**Plan**:
- Check if n8n supports OIDC/OAuth
- May require Traefik ForwardAuth middleware
- Alternative: LDAP if Authentik LDAP provider is enabled

**Configuration Changes**:
- File: Check n8n deployment
- Add authentication configuration

---

### 9. Uptime Kuma (Priority: Low)
**Protocol**: Reverse proxy auth
**Documentation**: Limited OAuth support
**Current Auth**: Local users
**Plan**:
- Use Traefik ForwardAuth middleware with Authentik
- Alternative: Keep local auth for monitoring tool

**Configuration Changes**:
- May add ForwardAuth middleware to Ingress

---

### 10. Homepage (Priority: Low)
**Protocol**: N/A (dashboard only)
**Current Auth**: None (public dashboard)
**Plan**:
- Optional: Add ForwardAuth to require authentication
- Consider if dashboard should be public or protected

---

## Implementation Phases

### Phase 1: Foundation (Week 1)
1. ✅ Verify Authentik is fully operational
2. ⏳ Wait for certificate auto-renewal (2025-10-20)
3. Create Authentik users and groups structure
4. Document Authentik admin credentials

### Phase 2: High Priority Apps (Week 2)
1. Home Assistant OAuth integration
2. Immich OAuth integration
3. Paperless-NGX OIDC integration

### Phase 3: Medium Priority Apps (Week 3)
1. Audiobookshelf OIDC
2. Linkding OIDC
3. Mealie OIDC
4. n8n authentication

### Phase 4: Low Priority Apps (Week 4)
1. Wallabag (research and implement)
2. Uptime Kuma (ForwardAuth)
3. Homepage (optional protection)

### Phase 5: Cleanup (Week 5)
1. Remove local authentication from integrated apps
2. Verify all services working with Authentik
3. Document user management procedures
4. Update HOMELAB_ANALYSIS.md

---

## Authentik Configuration Checklist

For each application:
- [ ] Create OAuth2/OIDC Provider in Authentik UI
- [ ] Create Application in Authentik UI
- [ ] Note Client ID and Client Secret
- [ ] Create Kubernetes Secret for OAuth credentials
- [ ] Update application configuration
- [ ] Test authentication flow
- [ ] Verify user provisioning
- [ ] Test group/role mapping
- [ ] Document in this file

---

## Common OAuth/OIDC Endpoints

**Authentik Base URL**: `https://authentik.h0melab.work`

**OIDC Endpoints**:
- Authorization: `https://authentik.h0melab.work/application/o/authorize/`
- Token: `https://authentik.h0melab.work/application/o/token/`
- User Info: `https://authentik.h0melab.work/application/o/userinfo/`
- Issuer: `https://authentik.h0melab.work/application/o/{application-slug}/`
- JWKS: `https://authentik.h0melab.work/application/o/{application-slug}/jwks/`

**OAuth2 Endpoints**:
- Same as OIDC above

**Discovery URL**: `https://authentik.h0melab.work/application/o/{application-slug}/.well-known/openid-configuration`

---

## Security Considerations

1. **Client Secrets**: Store all OAuth client secrets in Kubernetes Secrets encrypted with SOPS
2. **Redirect URIs**: Strictly define allowed redirect URIs for each application
3. **Scopes**: Request minimum necessary scopes (openid, profile, email, groups)
4. **Token Lifetime**: Configure appropriate access/refresh token lifetimes
5. **Fallback**: Maintain emergency admin access method for each service
6. **Backup**: Document Authentik backup and recovery procedures

---

## Rollback Plan

If integration causes issues:
1. Each app maintains existing auth provider during migration
2. Authentik can be disabled per-app by removing OAuth config
3. Local users remain available as fallback
4. Document rollback steps for each application

---

## Resources

- [Authentik Documentation](https://docs.goauthentik.io/)
- [Authentik Integrations](https://docs.goauthentik.io/integrations/)
- [OAuth 2.0 RFC](https://tools.ietf.org/html/rfc6749)
- [OpenID Connect Core](https://openid.net/specs/openid-connect-core-1_0.html)

---

## Notes

- Start with one application to validate the process
- Test thoroughly before removing local auth
- Keep admin credentials in 1Password
- Update HOMELAB_ANALYSIS.md after each integration
