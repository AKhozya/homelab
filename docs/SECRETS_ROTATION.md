# Secrets Rotation Playbook

**Cluster**: K3s Homelab | **Last Updated**: 2026-04-02
**Audit Trail**: Rotation dates tracked in git commit history

---

## SECRETS INVENTORY

### Database Credentials

#### PostgreSQL (CloudNativePG)

| Secret Name | App | Last Rotated | Next Rotation | Priority |
|-------------|-----|--------------|---------------|----------|
| `immich-db-password` | Immich | 2026-04-02 | 2026-07-01 | High |
| `linkwarden-db-password` | Linkwarden | 2026-04-02 | 2026-10-01 | Medium |
| `mealie-db-password` | Mealie | 2026-04-02 | 2026-10-01 | Medium |
| `n8n-db-password` | N8N | 2026-04-02 | 2026-07-01 | High |
| `paperless-db-password` | Paperless-NGX | 2026-04-02 | 2026-10-01 | Medium |
| `authentik-db-password` | Authentik | 2026-04-02 | 2026-07-01 | Critical |
| `grafana-db-password` | Grafana | N/A (SQLite) | N/A | N/A |
| `audiobookshelf-db-password` | Audiobookshelf | N/A (SQLite) | N/A | N/A |

#### MySQL (Percona)

| Secret Name | App | Last Rotated | Next Rotation | Priority |
|-------------|-----|--------------|---------------|----------|
| `home-assistant-mysql` | Home Assistant | 2026-04-02 | 2026-07-01 | High |
| `uptime-kuma-mysql` | Uptime Kuma | 2026-04-02 | 2026-10-01 | Medium |
| `pricebuddy-mysql` | PriceBuddy | 2026-04-02 | 2026-10-01 | Medium |

#### CouchDB

| Secret Name | App | Notes |
|-------------|-----|-------|
| `couchdb-admin-credentials` | Obsidian Sync | **MOVED** — see User Login Passwords |

### Redis

| Secret Name | App | Last Rotated | Next Rotation | Priority |
|-------------|-----|--------------|---------------|----------|
| `authentik-redis-password` | Authentik | N/A (Removed 2025-10-29) | N/A | N/A |
| `immich-redis-password` | Immich | 2026-04-02 | 2026-07-01 | High |
| `paperless-redis-password` | Paperless-NGX | 2026-04-02 | 2026-10-01 | Medium |
| `wallabag-redis-password` | Wallabag | N/A (Decommissioned) | N/A | N/A |

### Application Secrets

| Secret Name | App | Type | Last Rotated | Next Rotation | Priority |
|-------------|-----|------|--------------|---------------|----------|
| `authentik-secret-key` | Authentik | Django Secret | 2026-04-02 | 2026-10-01 | High |
| `n8n-encryption-key` | N8N | Encryption Key | Never* | N/A | Critical |

\* **N8N encryption key NEVER rotated** — encrypts all workflow credentials

### User Login Passwords (NOT rotated)

| Secret Name | App | Notes |
|-------------|-----|-------|
| `homehub-password` | HomeHub | User login — NO auto-rotate |
| `adguard-home-config` | AdGuard Home | User login — NO auto-rotate |
| `grafana-admin-secret` | Grafana | User login — NO auto-rotate |
| `audiobookshelf-admin` | Audiobookshelf | User login — NO auto-rotate |
| `couchdb-admin-credentials` | Obsidian Sync | Client-facing (LiveSync connects directly) — NO rotate |

### OIDC/OAuth Secrets

| App | Where Secret Lives | Last Rotated | Next Rotation | Priority |
|-----|-------------------|--------------|---------------|----------|
| Grafana | `grafana-oidc` K8s Secret (volume mount) | 2026-04-02 | 2026-10-01 | High |
| Immich | PostgreSQL `system_metadata` table (`oauth.clientSecret` jsonb) + Authentik API | 2026-04-02 | 2026-10-01 | High |
| Paperless-NGX | `paperless-env-secret.yaml` (PAPERLESS_SOCIALACCOUNT_PROVIDERS env) | 2026-04-02 | 2026-10-01 | High |
| Mealie | `mealie-env-secret.yaml` (OIDC_CLIENT_SECRET env) | 2026-04-02 | 2026-10-01 | Medium |
| Linkwarden | `linkwarden-secret.yaml` (DATABASE_URL + OIDC combined) | 2026-04-02 | 2026-10-01 | Medium |
| Audiobookshelf | SQLite on PVC (web UI config) + Authentik API | 2026-04-02 | 2026-10-01 | Medium |
| Home Assistant | OIDC disabled (hass-oidc-auth incompatible with HA 2026.4.0) | N/A | N/A | N/A |
| Stirling PDF | `custom-settings-configmap.yaml` (SOPS Secret) | 2026-04-02 | 2026-10-01 | Medium |

**OIDC rotation gotchas:**
- **Immich**: Update Authentik API AND PostgreSQL: `UPDATE system_metadata SET value = jsonb_set(value::jsonb, '{oauth,clientSecret}', '"NEW_SECRET"') WHERE key = 'system-config';` then restart
- **Audiobookshelf**: Update Authentik API AND web UI (Settings → Auth → OpenID). Can't do via CLI (SQLite on PVC)
- **Paperless-NGX**: Secret in `PAPERLESS_SOCIALACCOUNT_PROVIDERS` JSON inside env secret (NOT standalone file)
- **All others**: Update Authentik API + SOPS file + restart pod

### Infrastructure Credentials

| Secret Name | Component | Last Rotated | Next Rotation | Priority |
|-------------|-----------|--------------|---------------|----------|
| `tunnel-credentials` | Cloudflare Tunnel | 2025-10-18 | Never* | Critical |
| `pricebuddy-telegram` | PriceBuddy | 2025-12-05 | Never* | Medium |
| `backup-replication-ssh` | Backup Jobs | 2025-12-18 | 2026-12-18 | High |
| `cloudflare-tunnel-mgmt-token` | CF Tunnel Mgmt | 2026-02-19 | 2026-12-31 | Medium |

\* Only rotate if compromised

### TLS Certificates

| Certificate | Renewal |
|-------------|---------|
| `*.h0melab.work` | Automatic (cert-manager, Let's Encrypt) |
| Individual app certs | Automatic (cert-manager) |

---

## ROTATION SCHEDULES

### High Priority (90 Days)
- DB passwords: Immich, Authentik, N8N, Home Assistant
- Redis: Immich

### Medium Priority (180 Days)
- OIDC client secrets (Authentik provider + app-side)
- DB passwords: Mealie, Paperless, Linkwarden, Uptime Kuma, PriceBuddy
- Redis: Paperless
- CouchDB admin (also update `monitoring/configs/base/victoria-metrics/couchdb-auth-secret.yaml` for VMAgent)
- Authentik Django secret key

### Never Rotate
- User login passwords (AdGuard, HomeHub, Grafana admin, Audiobookshelf admin)
- N8N encryption key (breaks encrypted workflow credentials)
- Cloudflare tunnel token (only if compromised)
- Age key for SOPS (only if compromised)

---

## ROTATION PROCEDURES

### 1. PostgreSQL Password (CNPG)

```bash
# 1. Generate new password (64-char hex for URL safety)
NEW_PASSWORD=$(openssl rand -hex 32)

# 2. Update CNPG db-user secret (CNPG operator watches this and syncs to PostgreSQL)
# All users are in managed.roles in the Cluster CRD — CNPG auto-updates the DB password
sops --ignore-mac --set "[\"stringData\"][\"password\"] \"${NEW_PASSWORD}\"" \
  infrastructure/configs/staging/databases/postgres/<app>-db-user.yaml

# 3. Update app-side SOPS secret (so the app uses the new password)
# Key name varies by app — check the file first with: sops --ignore-mac -d <file>
sops --ignore-mac --set '["stringData"]["<PASSWORD_KEY>"] "'${NEW_PASSWORD}'"' \
  apps/staging/<app>/<secret-file>.yaml

# 4. Commit and push
git add infrastructure/configs/staging/databases/postgres/<app>-db-user.yaml \
      apps/staging/<app>/<secret-file>.yaml
git commit -m "Rotate <app> database password"
git push

# 5. Force Flux to reconcile
flux reconcile source git flux-system --timeout 60s
flux reconcile kustomization infrastructure-configs --timeout 60s
flux reconcile kustomization apps --timeout 60s

# 6. Restart affected pods to pick up new secret
kubectl rollout restart deployment/<app> -n <app>

# 7. Verify connectivity
kubectl logs -n <app> deployment/<app> --tail=20 | grep -i "database\|error"

# 8. Update rotation tracking in this document
```

**Rollback:**
```bash
# 1. Revert git commit
git revert HEAD
git push

# 2. Force reconcile and restart (CNPG will revert the DB password from the reverted secret)
flux reconcile source git flux-system --timeout 60s
flux reconcile kustomization infrastructure-configs --timeout 60s
flux reconcile kustomization apps --timeout 60s
kubectl rollout restart deployment/<app> -n <app>
```

---

### 2. Redis Password

```bash
# 1. Generate new password
NEW_PASSWORD=$(openssl rand -base64 32 | tr -d '+/=' | head -c 32)

# 2. Update Redis password via kubectl (if using Redis CRD)
# Or update the Redis ConfigMap/Secret directly

# 3. Update SOPS-encrypted secret for the app
# Example for Authentik:
sops apps/base/authentik/secret.yaml
# Update AUTHENTIK_REDIS__PASSWORD

# 4. Commit and push
git add apps/base/authentik/secret.yaml
git commit -m "Rotate Authentik Redis password"
git push

# 5. Reconcile and restart
flux reconcile source git flux-system --timeout 45s
flux reconcile kustomization apps --timeout 45s --force
kubectl rollout restart deployment/authentik-server -n authentik
kubectl rollout restart deployment/authentik-worker -n authentik

# 6. Verify connectivity
kubectl logs -n authentik deployment/authentik-server --tail=20 | grep -i "redis\|error"
```

---

### 3. MySQL Password (Percona)

```bash
# 1. Generate new password (32 chars, alphanumeric only)
NEW_PASSWORD=$(openssl rand -base64 24 | tr -d '+/=' | head -c 32)

# 2. Update MySQL user password via Percona operator
# The operator manages users via the PerconaServerMySQL CRD
# Update the secret referenced by the user definition

# 3. Update SOPS-encrypted secret for the app
# Example for Home Assistant:
sops apps/staging/home-assistant/secrets.yaml
# Update the MySQL password value

# 4. Commit and push
git add apps/staging/home-assistant/secrets.yaml
git commit -m "Rotate Home Assistant MySQL password"
git push

# 5. Reconcile and restart
flux reconcile source git flux-system --timeout 45s
flux reconcile kustomization apps --timeout 45s --force
kubectl rollout restart deployment/home-assistant -n home-assistant

# 6. Verify connectivity
kubectl logs -n home-assistant deployment/home-assistant --tail=20 | grep -i "mysql\|database\|error"
```

**Note**: Percona operator handles password updates through CRDs. User secrets in `databases` namespace, referenced by PerconaServerMySQL resource.

---

### 4. OIDC Client Secret

```bash
# 1. Generate new OIDC client secret (64-char hex)
NEW_SECRET=$(openssl rand -hex 32)

# 2. Update in Authentik via API (no UI needed)
AUTHENTIK_TOKEN=$(kubectl get secret -n authentik authentik -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_TOKEN}' | base64 -d)
# Get provider PK: 1=Grafana, 3=Immich, 5=Paperless, 11=Mealie, 13=Audiobookshelf, 14=HA, 16=Stirling
kubectl exec -n authentik deploy/authentik-server -- curl -s -X PATCH \
  -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"client_secret\": \"${NEW_SECRET}\"}" \
  "http://localhost:9000/api/v3/providers/oauth2/<PROVIDER_PK>/"

# 3. Update SOPS-encrypted secret for the app
# Key name varies: "client-secret" for most apps, check with: sops --ignore-mac -d <file>
sops --ignore-mac --set '["stringData"]["client-secret"] "'${NEW_SECRET}'"' \
  apps/staging/<app>/<oidc-secret-file>.yaml

# 4. Commit and push
git add apps/staging/<app>/<oidc-secret-file>.yaml
git commit -m "Rotate <app> OIDC client secret"
git push

# 5. Reconcile and restart
flux reconcile source git flux-system --timeout 60s
flux reconcile kustomization apps --timeout 60s
kubectl rollout restart deployment/<app> -n <app>

# 6. Test SSO login
# Visit https://<app>.h0melab.work and test login
```

**Provider PK Reference**:
- 1: Grafana, 3: Immich, 5: Paperless-NGX, 11: Mealie
- 13: Audiobookshelf, 14: Home Assistant, 16: Stirling PDF
- n8n: no OIDC in free version

---

### 5. User Login Passwords (HomeHub, AdGuard)

#### HomeHub
```bash
# 1. Generate bcrypt hash
python3 -c "import bcrypt; print(bcrypt.hashpw(b'YOUR_NEW_PASSWORD', bcrypt.gensalt(rounds=12)).decode())"

# 2. Update SOPS secret
sops apps/base/homehub/secret.yaml
# Update HOMEHUB_PASSWORD with bcrypt hash

# 3. Commit, push, reconcile, restart
git add apps/base/homehub/secret.yaml
git commit -m "Rotate HomeHub password"
git push
flux reconcile kustomization apps --timeout 45s --force
kubectl rollout restart deployment/homehub -n homehub
```

#### AdGuard Home
```bash
# 1. Generate bcrypt hash (same as HomeHub)
# 2. Update: sops apps/base/adguard-home/secret.yaml
# 3. Commit, push, reconcile, restart
```

---

## VERIFICATION CHECKLIST

After rotating any secret:
- [ ] Git commit pushed
- [ ] Flux reconciliation completed
- [ ] Pods restarted successfully
- [ ] No auth errors in logs
- [ ] App accessible via web UI
- [ ] Dependent services connected
- [ ] No monitoring alerts
- [ ] "Last Rotated" updated in this doc
- [ ] Doc update committed

---

## EMERGENCY ROTATION

If compromised:
1. **Immediate**: Rotate within 1h, check logs for unauthorized access
2. **Investigate**: Scope, affected systems, lateral movement
3. **Remediate**: Rotate all related secrets, tighten NetworkPolicies, update firewall
4. **Post-mortem**: Document, update procedures, review access controls

---

## ROTATION TRACKING

### 2025 Q4 (Oct-Dec)
- [x] 2025-10-18: Initial deployment (Authentik DB + Django, Redis x3)
- [x] 2025-10-19: Immich + Paperless DB passwords
- [x] 2025-10-20: OIDC secrets for 7 apps
- [x] 2025-10-23: Linkding, Mealie, N8N, Wallabag, CouchDB passwords
- [x] 2025-10-25: AdGuard + Stirling PDF credentials
- [x] 2025-10-26: HomeHub password (exposed password incident)
- [x] 2025-10-29: Removed Authentik Redis
- [x] 2025-11-24: Linkwarden deployment (DB + OIDC)
- [x] 2025-12-05: PriceBuddy Telegram token
- [x] 2025-12-16: MySQL migration (HA, Uptime Kuma, PriceBuddy)
- [x] 2025-12-18: Backup replication SSH key

### 2026 Q1 (Jan-Mar)
- *Skipped — consolidated into Q2 batch*

### 2026 Q2 (Apr-Jun)
- [x] 2026-04-02: Full batch rotation
  - PostgreSQL (6): Authentik, Immich, Paperless, Mealie, N8N, Linkwarden
  - MySQL (3): Home Assistant, Uptime Kuma, PriceBuddy
  - Redis (2): Immich, Paperless-NGX
  - CouchDB admin
  - OIDC (6): Grafana, Immich (DB), Paperless (env), Mealie (env), Stirling PDF (SOPS)
    - Audiobookshelf reverted (SQLite, must use web UI)
    - HA skipped (hass-oidc-auth disabled)
  - Authentik Django secret key

### 2026 Q3 (Jul-Sep)
- [ ] 2026-07-01: High-priority 90-day rotation (PG: authentik/immich/n8n, MySQL: HA, Redis: immich)

### 2026 Q4 (Oct-Dec)
- [ ] 2026-10-01: Medium-priority 180-day rotation (all remaining PG, MySQL, Redis, CouchDB, OIDC, Django key)

---

## BEST PRACTICES

1. **Password gen**: Cryptographically secure, 32+ chars for DB/Redis, 64+ for OIDC. Avoid special chars (URL encoding issues).
2. **Testing**: Verify all dependent services. Keep prev password 24h for rollback.
3. **Docs**: Update this doc + commit immediately after rotation.
4. **Monitoring**: Watch auth errors 15 min post-rotation. Check Grafana.
5. **Backup**: Ensure secrets backup current before rotation.

---

## RELATED

- [Security](./SECURITY.md) | [Homelab Analysis](./HOMELAB_ANALYSIS.md)

### Git Audit Trail
```bash
# View all secret rotation commits with dates
git log --all --date=short --format="%ad %s" --grep="secret\|password\|rotate" -- apps/

# View specific secret file history
git log --all --date=short --format="%ad %h %s" --follow -- apps/base/immich/secret.yaml

# View detailed changes for a specific commit
git show <commit-hash> -- apps/base/immich/secret.yaml
```

---

**Review Schedule**: Quarterly | **Next Review**: 2026-07-01
