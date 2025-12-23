# 🔐 Secrets Rotation Playbook

**Cluster**: K3s Homelab (single-master, SQLite backend)
**Last Updated**: 2025-12-23
**Audit Trail**: All rotation dates are tracked in git commit history with detailed commit messages

---

## 📋 SECRETS INVENTORY

### Database Credentials

#### PostgreSQL (CloudNativePG)

| Secret Name | App | Type | Last Rotated | Next Rotation | Priority |
|-------------|-----|------|--------------|---------------|----------|
| `immich-db-password` | Immich | PostgreSQL | 2025-10-19 | 2026-01-17 | High |
| `linkwarden-db-password` | Linkwarden | PostgreSQL | 2025-11-24 | 2026-02-22 | Medium |
| `mealie-db-password` | Mealie | PostgreSQL | 2025-10-23 | 2026-01-21 | Medium |
| `n8n-db-password` | N8N | PostgreSQL | 2025-10-23 | 2026-01-21 | High |
| `paperless-db-password` | Paperless-NGX | PostgreSQL | 2025-10-19 | 2026-01-17 | Medium |
| `authentik-db-password` | Authentik | PostgreSQL | 2025-10-18 | 2026-01-16 | Critical |
| `grafana-db-password` | Grafana | PostgreSQL | 2025-10-18 | 2026-01-16 | High |
| `audiobookshelf-db-password` | Audiobookshelf | PostgreSQL | 2025-10-23 | 2026-01-21 | Medium |

#### MySQL (Percona Operator)

| Secret Name | App | Type | Last Rotated | Next Rotation | Priority |
|-------------|-----|------|--------------|---------------|----------|
| `home-assistant-mysql` | Home Assistant | MySQL | 2025-12-16 | 2026-03-16 | High |
| `uptime-kuma-mysql` | Uptime Kuma | MySQL | 2025-12-16 | 2026-03-16 | Medium |
| `pricebuddy-mysql` | PriceBuddy | MySQL | 2025-12-16 | 2026-03-16 | Medium |

#### CouchDB

| Secret Name | App | Type | Last Rotated | Next Rotation | Priority |
|-------------|-----|------|--------------|---------------|----------|
| `couchdb-admin-credentials` | Obsidian Sync | CouchDB Admin | 2025-10-23 | 2026-04-21 | Medium |

### Redis Credentials

| Secret Name | App | Type | Last Rotated | Next Rotation | Priority |
|-------------|-----|------|--------------|---------------|----------|
| `authentik-redis-password` | Authentik | Redis | N/A (Removed 2025-10-29) | N/A | N/A |
| `immich-redis-password` | Immich | Redis | 2025-10-18 | 2026-01-16 | High |
| `paperless-redis-password` | Paperless-NGX | Redis | 2025-10-18 | 2026-01-16 | Medium |
| `wallabag-redis-password` | Wallabag | Redis | 2025-10-18 | 2026-01-16 | Medium |

### Application Credentials

| Secret Name | App | Type | Last Rotated | Next Rotation | Priority |
|-------------|-----|------|--------------|---------------|----------|
| `authentik-secret-key` | Authentik | Django Secret | 2025-10-18 | 2026-04-16 | High |
| `n8n-encryption-key` | N8N | Encryption Key | Never* | N/A | Critical |
| `homehub-password` | HomeHub | Bcrypt Password | 2025-10-26 | 2026-01-24 | Medium |
| `adguard-home-config` | AdGuard Home | Bcrypt Password | 2025-10-25 | 2026-04-23 | Medium |

\* **IMPORTANT**: N8N encryption key should NEVER be rotated as it encrypts workflow credentials

### OIDC/OAuth Secrets

| Secret Name | App | Type | Last Rotated | Next Rotation | Priority |
|-------------|-----|------|--------------|---------------|----------|
| `grafana-oidc` | Grafana | OIDC Client Secret | 2025-10-20 | 2026-04-18 | High |
| `immich-oidc` | Immich | OIDC Client Secret | 2025-10-20 | 2026-04-18 | High |
| `paperless-oidc` | Paperless-NGX | OIDC Client Secret | 2025-10-20 | 2026-04-18 | High |
| `mealie-oidc` | Mealie | OIDC Client Secret | 2025-10-20 | 2026-04-18 | Medium |
| `linkwarden-oidc` | Linkwarden | OIDC Client Secret | 2025-11-24 | 2026-05-22 | Medium |
| `audiobookshelf-oidc` | Audiobookshelf | OIDC Client Secret | 2025-10-20 | 2026-04-18 | Medium |
| `home-assistant-oidc` | Home Assistant | OIDC Client Secret | 2025-10-20 | 2026-04-18 | High |
| `stirling-pdf-oidc` | Stirling PDF | OIDC Client Secret | 2025-10-25 | 2026-04-23 | Medium |

### Infrastructure Credentials

| Secret Name | Component | Type | Last Rotated | Next Rotation | Priority |
|-------------|-----------|------|--------------|---------------|----------|
| `tunnel-credentials` | Cloudflare Tunnel | Tunnel Token | 2025-10-18 | Never* | Critical |
| `grafana-admin-secret` | Grafana | Admin Password | 2025-10-18 | 2026-04-16 | High |
| `pricebuddy-telegram` | PriceBuddy | Telegram Bot Token | 2025-12-05 | Never* | Medium |
| `backup-replication-ssh` | Backup Jobs | SSH Private Key | 2025-12-18 | 2026-12-18 | High |

\* **Tunnel/API tokens**: Only rotate if compromised; regeneration requires reconfiguration

### TLS Certificates

| Certificate | Issuer | Type | Renewal | Priority |
|-------------|--------|------|---------|----------|
| `*.h0melab.work` | Let's Encrypt | Wildcard | Automatic (cert-manager) | High |
| Individual app certs | Let's Encrypt | Single domain | Automatic (cert-manager) | High |

---

## 🔄 ROTATION SCHEDULES

### High Priority (Every 90 Days)
- Database passwords for apps with sensitive data (Immich, Authentik, N8N)
- Redis passwords for authentication services

### Medium Priority (Every 180 Days)
- OIDC client secrets
- Application passwords (AdGuard Home, HomeHub)
- Database passwords for less critical apps

### Low Priority (Annually)
- Non-critical application credentials
- Development/testing credentials

### Never Rotate
- ⚠️ **N8N Encryption Key** - Rotating this will break all encrypted workflow credentials
- Age key for SOPS encryption - Only rotate if compromised

---

## 📝 ROTATION PROCEDURES

### 1. Database Password Rotation (PostgreSQL)

#### Prerequisites
- kubectl access to cluster
- SOPS key configured
- Git repository access

#### Steps

```bash
# 1. Generate new password (32 characters, alphanumeric only for URL safety)
NEW_PASSWORD=$(openssl rand -base64 24 | tr -d '+/=' | head -c 32)

# 2. Update the Database User password via CRD
# Example for Immich:
kubectl patch database immich -n databases --type=merge -p '{"spec":{"user":{"password":"'$NEW_PASSWORD'"}}}'

# Wait for CloudNativePG operator to update the password
kubectl wait --for=condition=Ready database/immich -n databases --timeout=60s

# 3. Update SOPS-encrypted secret
cd /Users/akhozya/source-code/homelab
sops apps/base/immich/secret.yaml

# Update the password value in the YAML file
# Save and exit (SOPS will re-encrypt automatically)

# 4. Commit and push
git add apps/base/immich/secret.yaml
git commit -m "Rotate Immich database password"
git push

# 5. Force Flux to reconcile
flux reconcile source git flux-system --timeout 45s
flux reconcile kustomization apps --timeout 45s --force

# 6. Restart affected pods to pick up new secret
kubectl rollout restart deployment/immich-server -n immich

# 7. Verify connectivity
kubectl logs -n immich deployment/immich-server --tail=20 | grep -i "database\|error"

# 8. Update rotation tracking
# Update "Last Rotated" date in this document
```

**Rollback Procedure** (if issues occur):
```bash
# 1. Revert git commit
git revert HEAD
git push

# 2. Restore database password to previous value
kubectl patch database immich -n databases --type=merge -p '{"spec":{"user":{"password":"OLD_PASSWORD"}}}'

# 3. Force reconcile and restart
flux reconcile kustomization apps --timeout 45s --force
kubectl rollout restart deployment/immich-server -n immich
```

---

### 2. Redis Password Rotation

#### Steps

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

### 3. MySQL Password Rotation (Percona)

#### Steps

```bash
# 1. Generate new password (32 characters, alphanumeric only)
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

**Note**: Percona MySQL operator handles password updates through its CRDs. The user secrets
are stored in the `databases` namespace and referenced by the PerconaServerMySQL resource.

---

### 4. OIDC Client Secret Rotation

#### Steps

```bash
# 1. Generate new OIDC client secret
NEW_SECRET=$(openssl rand -hex 32)

# 2. Update in Authentik UI
# - Login to https://authentik.h0melab.work
# - Navigate to Applications > Providers > [App Provider]
# - Update Client Secret
# - Save

# 3. Update SOPS-encrypted secret for the app
# Example for Grafana:
sops apps/base/grafana/secret.yaml
# Update GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET

# 4. Commit and push
git add apps/base/grafana/secret.yaml
git commit -m "Rotate Grafana OIDC client secret"
git push

# 5. Reconcile and restart
flux reconcile kustomization apps --timeout 45s --force
kubectl rollout restart deployment/grafana -n grafana

# 6. Test SSO login
# Visit https://grafana.h0melab.work and test login
```

---

### 5. Application Password Rotation (HomeHub, AdGuard Home)

#### HomeHub Password Rotation

```bash
# 1. Generate new bcrypt password hash
# Option A: Use Python
python3 -c "import bcrypt; print(bcrypt.hashpw(b'YOUR_NEW_PASSWORD', bcrypt.gensalt(rounds=12)).decode())"

# Option B: Use online bcrypt generator (less secure)
# https://bcrypt-generator.com/ (rounds: 12)

# 2. Update SOPS-encrypted secret
sops apps/base/homehub/secret.yaml
# Update HOMEHUB_PASSWORD with bcrypt hash

# 3. Commit and push
git add apps/base/homehub/secret.yaml
git commit -m "Rotate HomeHub password"
git push

# 4. Reconcile and restart
flux reconcile kustomization apps --timeout 45s --force
kubectl rollout restart deployment/homehub -n homehub

# 5. Test login
# Visit https://homehub.h0melab.work and test with new password
```

#### AdGuard Home Password Rotation

```bash
# 1. Generate new bcrypt hash (same as HomeHub)

# 2. Update AdGuard Home config
sops apps/base/adguard-home/secret.yaml
# Update the password field under users section

# 3. Commit and push
git add apps/base/adguard-home/secret.yaml
git commit -m "Rotate AdGuard Home password"
git push

# 4. Reconcile and restart
flux reconcile kustomization apps --timeout 45s --force
kubectl rollout restart deployment/adguard-home -n adguard-home

# 5. Test login
# Visit https://adguard.h0melab.work and test with new password
```

---

## 🔍 VERIFICATION CHECKLIST

After rotating any secret, verify:

- [ ] Git commit pushed successfully
- [ ] Flux reconciliation completed without errors
- [ ] Affected pods restarted successfully
- [ ] Application logs show no authentication errors
- [ ] Application is accessible via web UI (if applicable)
- [ ] Dependent services can still connect (check logs)
- [ ] Monitoring shows no alerts
- [ ] Update "Last Rotated" date in this document
- [ ] Commit documentation update

---

## 🚨 EMERGENCY ROTATION

If a secret is compromised:

1. **Immediate Actions**:
   - Rotate the compromised secret immediately (within 1 hour)
   - Check logs for unauthorized access
   - Review audit logs if available

2. **Investigation**:
   - Determine scope of compromise
   - Identify affected systems
   - Check for lateral movement

3. **Remediation**:
   - Rotate all related secrets
   - Review and tighten NetworkPolicies
   - Update firewall rules if needed
   - Consider rotating SOPS age key if secret encryption compromised

4. **Post-Mortem**:
   - Document incident
   - Update security procedures
   - Review access controls

---

## 📊 ROTATION TRACKING

### 2025 Q4 (Oct-Dec)
- [x] 2025-10-18: Initial deployment with secure credentials
  - Authentik database password
  - Authentik Django secret key
  - Redis passwords (Immich, Paperless-NGX, Wallabag)
- [x] 2025-10-19: Database password rotations
  - Immich database password (64-char hex)
  - Paperless-NGX database password
- [x] 2025-10-20: OIDC secrets deployment
  - Added OIDC client secrets for 7 apps (Authentik SSO integration)
- [x] 2025-10-23: Database password standardization
  - Linkding, Mealie, N8N, Wallabag database passwords (hex-only)
  - CouchDB admin password updated
- [x] 2025-10-25: Application credential deployment
  - AdGuard Home bcrypt password
  - Stirling PDF OAuth2 client secret
- [x] 2025-10-26: Security incident response
  - HomeHub password rotated (exposed password remediation)
- [x] 2025-10-29: Architecture change
  - Removed Redis from Authentik (no longer applicable)
- [x] 2025-11-24: Linkwarden deployment (replaced Linkding)
  - Linkwarden database password (PostgreSQL)
  - Linkwarden OIDC client secret
- [x] 2025-12-05: PriceBuddy deployment
  - PriceBuddy Telegram bot token
- [x] 2025-12-16: MySQL migration (MariaDB → Percona MySQL)
  - Home Assistant MySQL credentials
  - Uptime Kuma MySQL credentials
  - PriceBuddy MySQL credentials
- [x] 2025-12-18: Backup replication setup
  - SSH key for backup replication to worker-node-2

### 2026 Q1 (Jan-Mar)
- [ ] 2026-01-16: Redis password rotation (90-day cycle)
  - Immich, Paperless-NGX Redis passwords
- [ ] 2026-01-17: High-priority PostgreSQL password rotation (90-day cycle)
  - Immich, Paperless-NGX, Authentik database passwords
- [ ] 2026-01-21: Medium-priority PostgreSQL password rotation (90-day cycle)
  - Mealie, N8N, Audiobookshelf database passwords
- [ ] 2026-01-24: HomeHub password rotation (90-day cycle)
- [ ] 2026-02-22: Linkwarden database password rotation (90-day cycle)
- [ ] 2026-03-16: MySQL password rotation (90-day cycle)
  - Home Assistant, Uptime Kuma, PriceBuddy MySQL passwords

### 2026 Q2 (Apr-Jun)
- [ ] 2026-04-16: Authentik secret key rotation (180-day cycle)
- [ ] 2026-04-18: OIDC client secret rotation (180-day cycle)
  - 8 Authentik-integrated apps (Grafana, Immich, Paperless, Mealie, Linkwarden, Audiobookshelf, Home Assistant, Stirling PDF)
- [ ] 2026-04-21: CouchDB admin password rotation (180-day cycle)
- [ ] 2026-04-23: AdGuard Home password rotation (180-day cycle)

---

## 🛡️ BEST PRACTICES

1. **Password Generation**:
   - Use cryptographically secure random generation
   - Minimum 32 characters for database/Redis passwords
   - Minimum 64 characters for OIDC secrets
   - Avoid special characters in database passwords (URL encoding issues)

2. **Testing**:
   - Always test rotation in staging first (if available)
   - Verify all dependent services after rotation
   - Keep previous password available for 24h in case of rollback

3. **Documentation**:
   - Update this document immediately after rotation
   - Commit documentation changes to git
   - Include rotation date in git commit message

4. **Monitoring**:
   - Watch for authentication errors after rotation
   - Monitor application logs for 15 minutes after rotation
   - Check Grafana dashboards for anomalies

5. **Backup**:
   - Ensure secrets backup is current before rotation
   - Verify `.backup/secrets-backup.sh` runs successfully
   - Store backup encryption key separately

---

## 📚 RELATED DOCUMENTATION

- [Security Documentation](./SECURITY.md) - Security policies and incident response
- [Performance & Security Audit](./PERFORMANCE_SECURITY_AUDIT.md) - Latest audit findings
- [Homelab Analysis](./HOMELAB_ANALYSIS.md) - Infrastructure overview

### Git Audit Trail

To verify secret rotation history and exact dates, use git commit history:

```bash
# View all secret rotation commits with dates
git log --all --date=short --format="%ad %s" --grep="secret\|password\|rotate" -- apps/

# View specific secret file history
git log --all --date=short --format="%ad %h %s" --follow -- apps/base/immich/secret.yaml

# View detailed changes for a specific commit
git show <commit-hash> -- apps/base/immich/secret.yaml
```

---

**Document Owner**: DevOps Team
**Review Schedule**: Quarterly
**Next Review**: 2026-01-26
