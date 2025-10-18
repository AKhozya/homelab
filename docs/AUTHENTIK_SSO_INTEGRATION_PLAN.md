# Authentik SSO Integration Plan

**Created**: 2025-10-18
**Status**: Draft - Ready for Implementation
**Priority**: P1 - Security & UX Enhancement

---

## Executive Summary

This plan outlines the integration of Authentik SSO across all homelab applications to:
1. **Eliminate password sprawl** - Single set of credentials for all services
2. **Improve security** - Centralized authentication, MFA support, session management
3. **Enhance UX** - Single sign-on across all apps
4. **Simplify management** - One place to manage users, groups, permissions

---

## Current State

### Deployed Apps (10 total)
| App | Auth Method | SSO Ready | Integration Method |
|-----|-------------|-----------|-------------------|
| Homepage | None | ✅ Yes | Traefik Forward Auth (optional) |
| Uptime Kuma | Local users | ✅ Yes | Traefik Forward Auth |
| Authentik | Self | N/A | SSO Provider |
| Home Assistant | Local users | ✅ Yes | Native OIDC |
| Wallabag | Local users | ✅ Yes | Native OAuth2/OIDC |
| Mealie | Local users | ✅ Yes | Native OIDC |
| N8N | Local users | ✅ Yes | Native OAuth2 |
| Linkding | Local users | ⚠️ Partial | Traefik Forward Auth |
| Audiobookshelf | Local users | ⚠️ Partial | Traefik Forward Auth |
| Obsidian | None (CouchDB) | ⚠️ Partial | Traefik Forward Auth |

---

## Integration Approaches

### 1. Native OIDC/OAuth2 (Preferred)
Apps with built-in SSO support using OpenID Connect or OAuth2.

**Pros:**
- Full feature support (user info, groups, roles)
- App-level authorization
- Better user experience

**Cons:**
- Requires app-specific configuration
- May need app restart

**Apps**: Home Assistant, Wallabag, Mealie, N8N

### 2. Traefik Forward Auth (Fallback)
Use Authentik's Proxy Provider with Traefik middleware for apps without native SSO.

**Pros:**
- Works with any HTTP app
- No app modification needed
- Centralized policy enforcement

**Cons:**
- Basic authentication only
- Limited user attribute passing
- Requires Traefik configuration

**Apps**: Uptime Kuma, Linkding, Audiobookshelf, Obsidian, Homepage (optional)

### 3. No SSO (Selected Apps)
Some apps may not require SSO based on use case.

**Apps**: None currently - aim for full SSO coverage

---

## Implementation Phases

### Phase 1: Foundation (Week 1) - ⚠️ CRITICAL
**Goal**: Set up Authentik providers and test with one app

1. **Configure Authentik**
   - ✅ Deploy Authentik (COMPLETED)
   - ✅ Create admin user (COMPLETED)
   - Create user groups (homelab-users, homelab-admins)
   - Configure email settings (SMTP)
   - Enable MFA/2FA (TOTP, WebAuthn)

2. **Create OAuth2/OIDC Providers**
   - Generic OAuth2 provider template
   - OIDC provider template with standard scopes

3. **Traefik Forward Auth Setup**
   - Deploy Authentik Proxy Provider
   - Configure Traefik middleware
   - Test with Homepage or Uptime Kuma

4. **Test & Validate**
   - Verify SSO login flow
   - Test logout/session timeout
   - Validate token refresh

**Deliverables**:
- [ ] At least 1 app integrated with Authentik
- [ ] Documentation for each integration method
- [ ] Rollback plan if issues occur

---

### Phase 2: Native OIDC Apps (Week 2)
**Goal**: Integrate apps with built-in SSO support

#### 2.1 Mealie (Native OIDC)
**Complexity**: Low
**Docs**: https://docs.mealie.io/documentation/getting-started/authentication/#oidc

**Steps**:
1. Create Authentik OIDC Provider for Mealie
   - Redirect URI: `https://mealie.h0melab.work/login`
   - Scopes: openid, profile, email
2. Configure Mealie environment variables:
   ```yaml
   OIDC_AUTH_ENABLED: "true"
   OIDC_SIGNUP_ENABLED: "true"
   OIDC_CONFIGURATION_URL: "https://auth.h0melab.work/application/o/mealie/.well-known/openid-configuration"
   OIDC_CLIENT_ID: "<from-authentik>"
   OIDC_CLIENT_SECRET: "<from-authentik>"
   ```
3. Test login flow
4. Remove local user provisioning job

**Rollback**: Keep existing user provisioning job until validated

---

#### 2.2 N8N (Native OAuth2)
**Complexity**: Medium
**Docs**: https://docs.n8n.io/hosting/configuration/environment-variables/authentication/

**Steps**:
1. Create Authentik OAuth2 Provider for N8N
   - Redirect URI: `https://n8n.h0melab.work/rest/oauth2-credential/callback`
   - Scopes: openid, profile, email
2. Configure N8N environment variables:
   ```yaml
   N8N_SSO_ENABLED: "true"
   N8N_SSO_OIDC_ENABLED: "true"
   N8N_SSO_OIDC_CONFIG_NAME: "Authentik"
   N8N_SSO_OIDC_ISSUER: "https://auth.h0melab.work/application/o/n8n/"
   N8N_SSO_OIDC_CLIENT_ID: "<from-authentik>"
   N8N_SSO_OIDC_CLIENT_SECRET: "<from-authentik>"
   N8N_SSO_OIDC_SCOPE: "openid profile email"
   ```
3. Test login flow
4. Remove local user provisioning job

**Rollback**: Keep existing user provisioning job until validated

---

#### 2.3 Wallabag (Native OAuth2)
**Complexity**: Medium
**Docs**: https://doc.wallabag.org/en/admin/oauth.html

**Steps**:
1. Create Authentik OAuth2 Provider for Wallabag
   - Redirect URI: `https://wallabag.h0melab.work/oauth/v2/generic/callback`
   - Scopes: openid, profile, email
2. Configure Wallabag OAuth settings via admin UI or config:
   ```yaml
   oauth:
     generic:
       client_id: "<from-authentik>"
       client_secret: "<from-authentik>"
       authorization_url: "https://auth.h0melab.work/application/o/authorize/"
       access_token_url: "https://auth.h0melab.work/application/o/token/"
       userinfo_url: "https://auth.h0melab.work/application/o/userinfo/"
       scope: "openid profile email"
   ```
3. Test login flow
4. Remove custom user setup

**Rollback**: Keep existing local users until validated

---

#### 2.4 Home Assistant (Native OIDC)
**Complexity**: Low
**Docs**: https://www.home-assistant.io/integrations/auth/

**Steps**:
1. Create Authentik OIDC Provider for Home Assistant
   - Redirect URI: `https://ha.h0melab.work/auth/external/callback`
   - Scopes: openid, profile, email
2. Configure Home Assistant `configuration.yaml`:
   ```yaml
   auth_providers:
     - type: homeassistant
     - type: trusted_networks
       trusted_networks:
         - 10.0.0.0/8
       allow_bypass_login: true
     - type: generic_oauth
       name: Authentik
       client_id: "<from-authentik>"
       client_secret: "<from-authentik>"
       authorize_url: https://auth.h0melab.work/application/o/authorize/
       token_url: https://auth.h0melab.work/application/o/token/
       userinfo_url: https://auth.h0melab.work/application/o/userinfo/
   ```
3. Test login flow
4. Keep local auth as fallback

**Rollback**: Local auth remains enabled as fallback

---

### Phase 3: Forward Auth Apps (Week 3)
**Goal**: Protect apps without native SSO using Traefik Forward Auth

#### 3.1 Setup Authentik Proxy Provider
**Steps**:
1. Create Authentik Application for each app
2. Create Proxy Provider with External Host URL
3. Generate outpost deployment manifest
4. Deploy Authentik Outpost (or use embedded)

---

#### 3.2 Configure Traefik Middleware
**File**: `infrastructure/configs/base/traefik/forward-auth-middleware.yaml`

```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: authentik-forward-auth
  namespace: traefik
spec:
  forwardAuth:
    address: http://authentik-server.authentik.svc.cluster.local:9000/outpost.goauthentik.io/auth/traefik
    trustForwardHeader: true
    authResponseHeaders:
      - X-authentik-username
      - X-authentik-groups
      - X-authentik-email
      - X-authentik-name
      - X-authentik-uid
```

---

#### 3.3 Uptime Kuma
**Complexity**: Low

**Steps**:
1. Create Authentik Proxy Provider for Uptime Kuma
   - External Host: `https://uptime.h0melab.work`
2. Update Uptime Kuma Ingress to use forward auth middleware:
   ```yaml
   metadata:
     annotations:
       traefik.ingress.kubernetes.io/router.middlewares: traefik-authentik-forward-auth@kubernetescrd
   ```
3. Test access - should redirect to Authentik login
4. Remove/disable local admin user (optional)

**Rollback**: Remove middleware annotation from Ingress

---

#### 3.4 Linkding
**Complexity**: Low

**Steps**:
1. Create Authentik Proxy Provider for Linkding
   - External Host: `https://bookmarks.h0melab.work`
2. Update Linkding Ingress with forward auth middleware
3. Test access
4. Disable local authentication (optional)

**Rollback**: Remove middleware annotation

---

#### 3.5 Audiobookshelf
**Complexity**: Medium (has auth_request support)

**Steps**:
1. Check if Audiobookshelf supports OIDC natively first
2. If not, use Authentik Proxy Provider
3. Update Ingress with forward auth middleware
4. Test access

**Note**: Audiobookshelf may have native OIDC support - verify first

---

#### 3.6 Obsidian (CouchDB)
**Complexity**: Low

**Steps**:
1. Create Authentik Proxy Provider for Obsidian
   - External Host: `https://obsidian.h0melab.work`
2. Update Obsidian Ingress with forward auth middleware
3. Test access

**Note**: CouchDB itself might need additional config

---

#### 3.7 Homepage
**Complexity**: Low (Optional)

**Steps**:
1. Decide if Homepage needs SSO (it's a dashboard, may not need auth)
2. If yes, create Proxy Provider and add middleware
3. If no, skip (current state is fine)

**Recommendation**: Skip for now - Homepage is internal-only dashboard

---

### Phase 4: Advanced Features (Week 4+)
**Goal**: Enhance SSO with advanced features

1. **Multi-Factor Authentication (MFA)**
   - Enable TOTP (Google Authenticator, Authy)
   - Enable WebAuthn (YubiKey, Touch ID)
   - Enforce MFA for admin users

2. **Groups & RBAC**
   - Create groups: homelab-admin, homelab-user, homelab-readonly
   - Map groups to app permissions
   - Use Authentik policies for fine-grained access

3. **Session Management**
   - Configure session timeouts
   - Set up "remember me" tokens
   - Configure logout propagation

4. **Monitoring & Logging**
   - Add Authentik events to Grafana
   - Create dashboards for login success/failures
   - Alert on suspicious activity

5. **Backup & Recovery**
   - Document Authentik configuration
   - Backup PostgreSQL database
   - Test recovery procedure

---

## Security Considerations

### 1. Secrets Management
- Store OAuth client secrets in SOPS-encrypted Kubernetes secrets
- Rotate secrets periodically (90 days)
- Never commit plaintext secrets to Git

### 2. Network Policies
- Ensure Authentik can communicate with apps (already configured)
- Restrict Authentik admin UI to internal network
- Use TLS for all connections (already using cert-manager)

### 3. User Permissions
- Principle of least privilege
- Separate admin and user accounts
- Regular access reviews

### 4. Session Security
- Secure cookie settings (HttpOnly, Secure, SameSite)
- Short session timeouts for sensitive apps
- Logout on all devices capability

---

## Rollback Strategy

For each app integration:

1. **Pre-Integration**
   - Document current auth configuration
   - Take database backup (if applicable)
   - Save current Kubernetes manifests

2. **During Integration**
   - Keep existing auth method enabled alongside SSO
   - Test SSO in parallel
   - Validate all user flows

3. **Post-Integration**
   - Monitor for issues (24-48 hours)
   - If stable, remove old auth method
   - If issues, disable SSO via feature flag or Ingress annotation

4. **Emergency Rollback**
   - Remove Traefik middleware annotation (Forward Auth apps)
   - Disable SSO environment variables (Native SSO apps)
   - Restart pods if needed
   - Re-enable local authentication

---

## Success Criteria

### Per-App
- [ ] User can login with Authentik credentials
- [ ] User session persists across page reloads
- [ ] Logout works correctly
- [ ] No regression in app functionality
- [ ] Performance is acceptable (< 500ms auth overhead)

### Overall
- [ ] All apps (except Homepage) integrated with Authentik
- [ ] MFA enabled for admin users
- [ ] Groups configured and working
- [ ] Monitoring dashboards created
- [ ] Documentation complete
- [ ] Backup/recovery tested

---

## Timeline

- **Week 1**: Foundation + 1 test app (Mealie)
- **Week 2**: Native SSO apps (N8N, Wallabag, Home Assistant)
- **Week 3**: Forward Auth apps (Uptime Kuma, Linkding, Audiobookshelf, Obsidian)
- **Week 4**: MFA, Groups, Monitoring, Documentation

**Total Duration**: 4 weeks
**Effort**: ~20 hours
**Risk Level**: Medium (with rollback plan: Low)

---

## Resources

### Authentik Documentation
- Providers: https://docs.goauthentik.io/docs/providers/
- OAuth2/OIDC: https://docs.goauthentik.io/docs/providers/oauth2/
- Proxy Provider: https://docs.goauthentik.io/docs/providers/proxy/
- Outposts: https://docs.goauthentik.io/docs/outposts/

### App-Specific Docs
- Mealie OIDC: https://docs.mealie.io/documentation/getting-started/authentication/#oidc
- N8N SSO: https://docs.n8n.io/hosting/configuration/environment-variables/authentication/
- Wallabag OAuth: https://doc.wallabag.org/en/admin/oauth.html
- Home Assistant: https://www.home-assistant.io/integrations/auth/

### Traefik
- Forward Auth: https://doc.traefik.io/traefik/middlewares/http/forwardauth/

---

## Notes

1. **Database Requirement**: Authentik requires PostgreSQL (✅ already deployed via CloudNativePG)
2. **Redis Requirement**: Authentik requires Redis for caching (✅ already deployed)
3. **SMTP**: Not yet configured - needed for email verification and password reset
4. **Domain**: All apps use h0melab.work with Cloudflare DNS
5. **Certificates**: Using cert-manager with Let's Encrypt (✅ working)

---

## Next Steps

1. Start with Phase 1: Configure Authentik base settings
2. Create user groups (homelab-admin, homelab-user)
3. Test Forward Auth with Uptime Kuma (simplest app)
4. Once validated, proceed with Phase 2 (native OIDC apps)
5. Document lessons learned for each app

---

**Last Updated**: 2025-10-18
**Owner**: System Administrator
**Status**: Ready for Implementation
