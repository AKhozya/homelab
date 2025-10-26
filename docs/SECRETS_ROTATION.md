# 🔐 Secrets Rotation Playbook

**Cluster**: K3s Homelab
**Last Updated**: 2025-10-26

---

## 📋 SECRETS INVENTORY

### Database Credentials

| Secret Name | App | Type | Last Rotated | Next Rotation | Priority |
|-------------|-----|------|--------------|---------------|----------|
| `immich-db-password` | Immich | PostgreSQL | TBD | 90 days | High |
| `linkding-db-password` | Linkding | PostgreSQL | TBD | 90 days | Medium |
| `mealie-db-password` | Mealie | PostgreSQL | TBD | 90 days | Medium |
| `n8n-db-password` | N8N | PostgreSQL | TBD | 90 days | High |
| `paperless-db-password` | Paperless-NGX | PostgreSQL | TBD | 90 days | Medium |
| `wallabag-db-password` | Wallabag | PostgreSQL | TBD | 90 days | Medium |

### Redis Credentials

| Secret Name | App | Type | Last Rotated | Next Rotation | Priority |
|-------------|-----|------|--------------|---------------|----------|
| `authentik-redis-password` | Authentik | Redis | TBD | 90 days | High |
| `immich-redis-password` | Immich | Redis | TBD | 90 days | High |
| `paperless-redis-password` | Paperless-NGX | Redis | TBD | 90 days | Medium |
| `wallabag-redis-password` | Wallabag | Redis | TBD | 90 days | Medium |

### Application Credentials

| Secret Name | App | Type | Last Rotated | Next Rotation | Priority |
|-------------|-----|------|--------------|---------------|----------|
| `authentik-secret-key` | Authentik | Django Secret | TBD | 180 days | High |
| `n8n-encryption-key` | N8N | Encryption Key | Never* | N/A | Critical |
| `homehub-password` | HomeHub | Bcrypt Password | 2025-10-26 | 90 days | Medium |
| `adguard-home-config` | AdGuard Home | Bcrypt Password | TBD | 180 days | Medium |

\* **IMPORTANT**: N8N encryption key should NEVER be rotated as it encrypts workflow credentials

### OIDC/OAuth Secrets

| Secret Name | App | Type | Last Rotated | Next Rotation | Priority |
|-------------|-----|------|--------------|---------------|----------|
| `authentik-oidc-*` | Various | OIDC Client Secret | TBD | 180 days | High |

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

### 3. OIDC Client Secret Rotation

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

### 4. Application Password Rotation (HomeHub, AdGuard Home)

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
- [x] 2025-10-26: HomeHub password rotated

### 2026 Q1 (Jan-Mar)
- [ ] TBD: Schedule first rotation cycle for all database passwords
- [ ] TBD: Schedule first rotation cycle for all Redis passwords

### 2026 Q2 (Apr-Jun)
- [ ] TBD: Schedule rotation for OIDC client secrets

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

---

**Document Owner**: DevOps Team
**Review Schedule**: Quarterly
**Next Review**: 2026-01-26
