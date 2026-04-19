# Authentik SSO Integration Plan

Guide for integrating Authentik SSO with all homelab apps.

## Table of Contents

- [Overview](#overview)
- [Application Support Matrix](#application-support-matrix)
- [Integration Phases](#integration-phases)
- [Automation Scripts](#automation-scripts)
- [Implementation Guide](#implementation-guide)
- [Testing & Validation](#testing--validation)
- [Troubleshooting](#troubleshooting)
- [Recovery Procedures](#recovery-procedures)

---

## Overview

Plan integrates Authentik (https://authentik.h0melab.work) as central SSO provider for all homelab apps via OIDC.

**Goals:**
- SSO across all apps
- Centralized user mgmt
- Group-based access control
- Reduced password fatigue
- Better security

**Automation Level:** 60-70% automated via K8s manifests, Helm, scripts

**Estimated Time:** 4-7h total

---

## Application Support Matrix

| Application | URL | Native OIDC | Method | Priority | Effort |
|------------|-----|-------------|---------|----------|--------|
| **Grafana** | grafana.h0melab.work | ✅ | Native OIDC | High | 15 min |
| **Immich** | immich.h0melab.work | ✅ | Native OIDC | High | 10 min |
| **Paperless-NGX** | paperless.h0melab.work | ✅ | Native OIDC | High | 10 min |
| **N8N** | n8n.h0melab.work | ✅ | Native OIDC | Medium | 10 min |
| **Linkding** | linkding.h0melab.work | ✅ | Native OIDC | Medium | 10 min |
| **Mealie** | mealie.h0melab.work | ✅ | Native OIDC | Medium | 10 min |
| **Audiobookshelf** | audiobookshelf.h0melab.work | ✅ | Native OIDC | Medium | 10 min |
| **Wallabag** | wallabag.h0melab.work | ❌ | Authentik Proxy | Low | 20 min |
| **Home Assistant** | ha.h0melab.work | ⚠️ | HACS addon/Proxy | Low | 30 min |
| **Uptime Kuma** | uptime.h0melab.work | ❌ | Authentik Proxy | Low | 15 min |
| **Homepage** | home.h0melab.work | N/A | No auth (dashboard) | - | - |
| **CouchDB** | - | ❌ | Keep native auth | - | - |
| **Alertmanager** | am.h0melab.work | ✅ | Native OIDC | Low | 15 min |

**Legend:**
- ✅ Native OIDC support
- ❌ No native support (needs proxy)
- ⚠️ Partial support (community addon)

---

## Integration Phases

### Phase 1: Native OIDC Apps (Priority: High)
**Duration:** 2-3h
**Automation:** 80%

Apps with built-in OIDC:
1. Grafana (monitoring — most critical)
2. Immich (high usage)
3. Paperless-NGX (high usage)
4. N8N (automation)
5. Linkding (bookmarks)
6. Mealie (recipes)
7. Audiobookshelf (media)

**Process:**
1. Create OIDC provider in Authentik (UI or Terraform)
2. Generate client credentials
3. Update app config via K8s secrets
4. Deploy via Flux
5. Test login flow

### Phase 2: Authentik Proxy Apps (Priority: Medium)
**Duration:** 1-2h
**Automation:** 50%

Apps needing reverse proxy auth:
1. Wallabag (no OIDC)
2. Uptime Kuma (no OIDC)
3. Home Assistant (optional — HACS addon alt)

**Process:**
1. Deploy Authentik Proxy Outpost
2. Create Proxy Provider per app
3. Update Traefik IngressRoute with auth middleware
4. Configure bypass rules for APIs

### Phase 3: Testing & Documentation (Priority: High)
**Duration:** 1-2h
**Automation:** 20%

1. Test login flows all apps
2. Verify group-based access
3. Test logout behavior
4. Validate mobile app compat
5. Document recovery
6. Create runbooks

---

## Automation Scripts

Location: `/Users/akhozya/.local/bin/authentik-*`

### 1. Provider Creation Script
`authentik-create-providers.sh` — batch create OIDC providers

### 2. Secret Generator
`authentik-generate-secrets.sh` — generate K8s secrets for OIDC creds

### 3. Helm Values Updater
`authentik-update-helm-values.sh` — update Helm values with OIDC config

### 4. Test Suite
`authentik-test-sso.sh` — validate SSO integration all apps

---

## Implementation Guide

### Prerequisites

**1. Authentik Setup** (Already deployed)
- URL: https://authentik.h0melab.work
- Admin access required
- PostgreSQL DB: `authentik` in main-postgres cluster

**2. Create User Groups**

In Authentik UI (Settings → Groups):

```
Group: homelab-admins
- Description: Full admin access to all applications
- Users: <your-admin-user>

Group: homelab-users
- Description: Standard user access
- Users: <standard-users>

Group: homelab-readonly
- Description: Read-only access where supported
- Users: <readonly-users>
```

**3. Backup Current Credentials**

Run before starting:
```bash
cd .backup && ./secrets-backup.sh
```

---

### Phase 1A: Grafana Integration

**Authentik Configuration** (Manual UI):

1. Applications → Providers → Create
2. Select "OAuth2/OpenID Provider"
3. Configure:
   ```
   Name: grafana
   Authorization flow: default-provider-authorization-implicit-consent
   Redirect URIs: https://grafana.h0melab.work/login/generic_oauth
   Signing Key: authentik Self-signed Certificate
   Scopes: openid, profile, email, groups
   ```
4. Save + note Client ID & Client Secret

5. Applications → Applications → Create
   ```
   Name: Grafana
   Slug: grafana
   Provider: grafana (select from dropdown)
   Launch URL: https://grafana.h0melab.work
   ```

**Grafana Configuration** (Automated):

Create secret:
```bash
kubectl create secret generic grafana-oidc \
  --from-literal=client-id="<client-id-from-authentik>" \
  --from-literal=client-secret="<client-secret-from-authentik>" \
  -n monitoring
```

Update `monitoring/controllers/base/kube-prometheus-stack/release.yaml`:
```yaml
grafana:
  env:
    GF_AUTH_GENERIC_OAUTH_ENABLED: "true"
    GF_AUTH_GENERIC_OAUTH_NAME: "Authentik"
    GF_AUTH_GENERIC_OAUTH_CLIENT_ID:
      valueFrom:
        secretKeyRef:
          name: grafana-oidc
          key: client-id
    GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET:
      valueFrom:
        secretKeyRef:
          name: grafana-oidc
          key: client-secret
    GF_AUTH_GENERIC_OAUTH_SCOPES: "openid profile email groups"
    GF_AUTH_GENERIC_OAUTH_AUTH_URL: "https://authentik.h0melab.work/application/o/authorize/"
    GF_AUTH_GENERIC_OAUTH_TOKEN_URL: "https://authentik.h0melab.work/application/o/token/"
    GF_AUTH_GENERIC_OAUTH_API_URL: "https://authentik.h0melab.work/application/o/userinfo/"
    GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH: "contains(groups, 'homelab-admins') && 'Admin' || 'Viewer'"
    GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP: "true"
```

Commit + let Flux reconcile:
```bash
git add monitoring/controllers/base/kube-prometheus-stack/release.yaml
git commit -m "Add Authentik OIDC integration for Grafana"
git push
flux reconcile kustomization monitoring --timeout=2m
```

**Testing:**
1. Navigate https://grafana.h0melab.work
2. Click "Sign in with Authentik"
3. Verify redirect to Authentik login
4. Login + verify redirect back to Grafana
5. Check user assigned correct role (Admin/Viewer)

---

### Phase 1B: Immich Integration

**Authentik Configuration:**

1. Create OAuth2/OIDC Provider:
   ```
   Name: immich
   Redirect URIs: https://immich.h0melab.work/auth/login
                  https://immich.h0melab.work/user-settings
                  app.immich:///oauth-callback (for mobile)
   Scopes: openid, profile, email
   ```

2. Create Application:
   ```
   Name: Immich
   Slug: immich
   Provider: immich
   ```

**Immich Configuration** (Via UI):

1. Login as admin: https://immich.h0melab.work
2. Administration → Settings → OAuth
3. Configure:
   ```
   Enable: Yes
   Issuer URL: https://authentik.h0melab.work/application/o/immich/
   Client ID: <from-authentik>
   Client Secret: <from-authentik>
   Scope: openid profile email
   Button Text: Login with Authentik
   Auto Register: Yes
   Auto Launch: No (keep password login as fallback)
   ```
4. Save

**Testing:**
1. Logout Immich
2. See "Login with Authentik" button
3. Test SSO login
4. Verify existing users still login w/ password
5. Test mobile app login (uses OAuth callback)

---

### Phase 1C: Paperless-NGX Integration

**Authentik Configuration:**

1. Create OAuth2/OIDC Provider:
   ```
   Name: paperless
   Redirect URIs: https://paperless.h0melab.work/accounts/oidc/authentik/login/callback/
   Scopes: openid, profile, email
   ```

**Paperless Configuration** (Automated):

Create secret with OIDC config:
```bash
kubectl create secret generic paperless-oidc \
  --from-literal=client-id="<client-id>" \
  --from-literal=client-secret="<client-secret>" \
  -n paperless-ngx
```

Update `apps/base/paperless-ngx/deployment.yaml` env vars:
```yaml
- name: PAPERLESS_APPS
  value: "allauth.socialaccount.providers.openid_connect"
- name: PAPERLESS_SOCIALACCOUNT_PROVIDERS
  value: |
    {
      "openid_connect": {
        "APPS": [{
          "provider_id": "authentik",
          "name": "Authentik",
          "client_id": "$(OIDC_CLIENT_ID)",
          "secret": "$(OIDC_CLIENT_SECRET)",
          "settings": {
            "server_url": "https://authentik.h0melab.work/application/o/paperless/.well-known/openid-configuration"
          }
        }]
      }
    }
- name: OIDC_CLIENT_ID
  valueFrom:
    secretKeyRef:
      name: paperless-oidc
      key: client-id
- name: OIDC_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: paperless-oidc
      key: client-secret
- name: PAPERLESS_REDIRECT_LOGIN_TO_SSO
  value: "true"
- name: PAPERLESS_DISABLE_REGULAR_LOGIN
  value: "false"  # Keep password login for now
```

---

### Phase 1D-G: Remaining Native OIDC Apps

Similar pattern for:
- N8N (Settings → SSO)
- Linkding (env vars)
- Mealie (Settings → Authentication)
- Audiobookshelf (Settings → Authentication)

Refer to automation scripts for batch config.

---

### Phase 2: Authentik Proxy Setup

**Apps without native OIDC:** Wallabag, Uptime Kuma, (optional) Home Assistant

**1. Deploy Authentik Proxy Outpost:**

Create `apps/base/authentik/proxy-outpost.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: authentik-outpost-proxy
  namespace: authentik
spec:
  ports:
    - name: http
      port: 9000
      targetPort: 9000
  selector:
    app.kubernetes.io/name: authentik-proxy
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: authentik-outpost-proxy
  namespace: authentik
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: authentik-proxy
  template:
    metadata:
      labels:
        app.kubernetes.io/name: authentik-proxy
    spec:
      containers:
        - name: proxy
          image: ghcr.io/goauthentik/proxy:2025.1.2
          env:
            - name: AUTHENTIK_HOST
              value: https://authentik.h0melab.work
            - name: AUTHENTIK_TOKEN
              valueFrom:
                secretKeyRef:
                  name: authentik-outpost-token
                  key: token
          ports:
            - containerPort: 9000
```

**2. Create Proxy Providers in Authentik:**

For each app (Wallabag, Uptime Kuma):
1. Applications → Providers → Create
2. Select "Proxy Provider"
3. Configure:
   ```
   Name: <app>-proxy
   Authorization flow: default-provider-authorization-implicit-consent
   Type: Forward auth (single application)
   External host: https://<app>.h0melab.work
   ```

**3. Update Traefik Ingress with Auth Middleware:**

Create `infrastructure/base/traefik/middlewares/authentik-auth.yaml`:
```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: authentik-auth
  namespace: traefik
spec:
  forwardAuth:
    address: http://authentik-outpost-proxy.authentik:9000/outpost.goauthentik.io/auth/traefik
    trustForwardHeader: true
    authResponseHeaders:
      - X-authentik-username
      - X-authentik-groups
      - X-authentik-email
      - X-authentik-name
      - X-authentik-uid
```

**4. Update App Ingresses:**

Example Wallabag (`apps/base/wallabag/ingress.yaml`):
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: wallabag
  namespace: wallabag
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: traefik-authentik-auth@kubernetescrd
spec:
  rules:
    - host: wallabag.h0melab.work
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: wallabag
                port:
                  number: 80
```

---

## Testing & Validation

### Login Flow Testing

For each app, verify:
1. **SSO Login Works**
   - Navigate to app URL
   - Click SSO/Authentik button
   - Redirect to Authentik
   - Login with creds
   - Redirect back to app
   - Authenticated

2. **Group Mapping Works**
   - Admin users get admin role
   - Regular users get user role
   - Read-only users get viewer role

3. **Password Fallback** (where enabled)
   - SSO login works
   - Password login still works
   - Can switch between methods

4. **Logout Behavior**
   - Logout from app
   - Verify session cleared
   - Verify Authentik session status

### Mobile App Testing

Apps with mobile clients (Immich, Audiobookshelf):
1. Configure OAuth callback URL
2. Test login from mobile app
3. Verify token refresh works
4. Test API access with OAuth token

### API Access Testing

Apps with APIs (N8N, Immich, Paperless):
1. Verify API token gen still works
2. Test API access with bearer token
3. Ensure SSO doesn't break API access

---

## Troubleshooting

### Issue: Redirect Loop

**Symptoms:** Browser redirects between app + Authentik

**Causes:**
- Incorrect redirect URI in Authentik
- Cookie/session issues
- Proxy misconfig

**Solutions:**
1. Verify redirect URI matches exact (case-sensitive)
2. Clear browser cookies
3. Check Authentik provider config
4. Verify proxy middleware config

### Issue: "Invalid Client" Error

**Symptoms:** Authentik error about invalid client

**Causes:**
- Wrong client ID in app config
- Client secret mismatch
- Provider not linked to application in Authentik

**Solutions:**
1. Verify client ID matches between app + Authentik
2. Regenerate client secret if needed
3. Check provider linked to application in Authentik UI

### Issue: User Not Assigned Correct Role

**Symptoms:** User logs in but no expected perms

**Causes:**
- Wrong group mapping in app config
- User not in correct Authentik group
- App-specific role mapping not configured

**Solutions:**
1. Check user group membership in Authentik
2. Verify group mapping logic in app config
3. Review app-specific role attribute path

### Issue: SSO Works But Password Login Broken

**Symptoms:** Can't login with password after enabling SSO

**Causes:**
- `DISABLE_REGULAR_LOGIN` enabled too early
- Password hash corruption
- DB user mismatch

**Solutions:**
1. Set `DISABLE_REGULAR_LOGIN=false`
2. Verify user exists in app DB
3. Reset password via app CLI if needed

---

## Recovery Procedures

### If Authentik Goes Down

**Immediate Actions:**
1. Check password login still works for critical apps (Grafana, Immich)
2. If needed, temporarily disable SSO redirect:
   ```bash
   # For Paperless
   kubectl set env deployment/paperless -n paperless-ngx PAPERLESS_REDIRECT_LOGIN_TO_SSO=false
   ```

**Recovery:**
1. Fix Authentik deployment
2. Verify DB connectivity
3. Check pod logs: `kubectl logs -n authentik deployment/authentik-server`
4. Restart Authentik pods if needed

### If User Locked Out

**Admin Access via Password:**
1. Ensure admin accounts always have password fallback
2. Login with admin password
3. Investigate SSO issue
4. Temporary bypass: disable SSO redirect for that app

**CLI Recovery:**
Apps with CLI access:
```bash
# Immich
kubectl exec -n immich deployment/immich-server -- immich user reset-password <email>

# Paperless
kubectl exec -n paperless-ngx deployment/paperless -- python manage.py changepassword <username>
```

### Rollback SSO Configuration

**Per-App Rollback:**
```bash
# Remove OIDC configuration
kubectl delete secret <app>-oidc -n <namespace>

# Revert Helm values
git revert <commit-hash>
git push
flux reconcile kustomization <app> --timeout=2m
```

**Full Rollback:**
```bash
# Disable all OIDC integrations
cd /Users/akhozya/source-code/homelab
git revert <sso-integration-commit>
git push
flux reconcile kustomization apps --timeout=5m
```

---

## Security Considerations

### Best Practices

1. **Always Keep Password Fallback**
   - Critical for admin access
   - Prevents lockout if Authentik fails
   - Disable only after extensive testing

2. **Use Strong Client Secrets**
   - Generate with `openssl rand -hex 32`
   - Store in K8s secrets
   - Rotate periodically

3. **Limit Redirect URIs**
   - Only add necessary URIs
   - Avoid wildcards
   - Include mobile app callbacks

4. **Configure Session Timeouts**
   - Set in Authentik provider settings
   - Balance security vs convenience
   - Per-app requirements

5. **Monitor SSO Logs**
   - Check Authentik audit logs regularly
   - Alert on failed login attempts
   - Track unusual access patterns

### Access Control

**Group Hierarchy:**
```
homelab-admins (full access)
  └── homelab-users (standard access)
        └── homelab-readonly (read-only)
```

**App-Specific Groups** (optional):
```
immich-users
paperless-users
n8n-editors
grafana-admins
```

---

## Maintenance

### Regular Tasks

**Monthly:**
- Review Authentik audit logs
- Verify all SSO logins working
- Check failed auth attempts
- Update user group memberships

**Quarterly:**
- Rotate OIDC client secrets
- Review + remove unused apps
- Test disaster recovery
- Update docs

**Annually:**
- Full SSO security audit
- Review + update access control policies
- Validate mobile app integrations
- Perf optimization

### Monitoring

**Prometheus Metrics:**
- Authentik login success/failure rates
- OAuth token gen rates
- Session duration metrics
- Error rates per app

**Grafana Dashboards:**
- Dashboard for SSO metrics
- Track login patterns
- Alert on anomalies

---

## Resources

### Documentation
- Authentik Official Docs: https://docs.goauthentik.io/
- OIDC Spec: https://openid.net/specs/openid-connect-core-1_0.html
- Authentik Integration Guides: https://docs.goauthentik.io/integrations/

### Automation Scripts
- Location: `/Users/akhozya/.local/bin/authentik-*`
- Terraform modules: `/Users/akhozya/source-code/homelab/terraform/authentik/`
- K8s manifests: `/Users/akhozya/source-code/homelab/apps/base/authentik/`

### Support
- Authentik GitHub: https://github.com/goauthentik/authentik
- Homelab Issues: https://github.com/AKhozya/homelab/issues

---

## Appendix

### A. OIDC Configuration Reference

**Standard OIDC Claims:**
- `sub`: User ID (unique identifier)
- `email`: User email
- `name`: User's full name
- `preferred_username`: Username
- `groups`: User's group memberships

**Authentik-Specific:**
- `X-authentik-username`: Username header
- `X-authentik-groups`: Groups header (proxy)
- `X-authentik-email`: Email header
- `X-authentik-uid`: User ID header

### B. Application-Specific Notes

**Grafana:**
- Role mapping via `GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH`
- Supports auto-provisioning users
- Can sync teams from groups

**Immich:**
- Mobile app requires `app.immich:///oauth-callback`
- Auto-register creates users on first login
- Email must match for existing users

**Paperless-NGX:**
- Uses django-allauth for OIDC
- Requires PAPERLESS_APPS env var
- Can disable regular login after testing

**N8N:**
- OIDC only in self-hosted
- Requires instance owner to enable
- No PKCE support (yet)

**Linkding:**
- Simple OIDC config via env vars
- Auto-creates users on first login
- Supports auth proxy as alt

### C. Terraform Module Example

See `terraform/authentik/` for:
- Provider creation module
- Application creation module
- Group management module
- Output variable definitions

---

**Document Version:** 1.0
**Last Updated:** 2025-10-20
**Author:** Homelab Infrastructure Team
**Status:** Ready for Implementation
