# Secrets Rotation Playbook

**Cluster**: K3s Homelab (k3s v1.36.2+k3s1, 4 nodes) | **Last Updated**: 2026-07-14
**Audit Trail**: rotation dates in git commit history

Every secret in this cluster lives encrypted in Git using SOPS with an age key. The
ciphertext is committed alongside the manifests that consume it; only the cluster's age
key can decrypt it, so the repository can be public without exposing any value. The point
of doing it this way is to have one auditable source of truth: every secret change is a
reviewable commit, there is no external secret store to stand up or keep available before
the cluster can boot, and disaster recovery only needs the repo plus the age key. This
document tracks the rotation cadence for each class of secret — database credentials
(PostgreSQL/CNPG, MySQL/Percona, CouchDB, Redis), the Cloudflare tunnel, GitHub deploy
keys, node-maintenance and bot SSH keys, and TLS certificates (auto-renewed by
cert-manager).

---

## SECRETS INVENTORY

### Database Credentials

#### PostgreSQL (CloudNativePG)

| Secret Name | App | Last Rotated | Next Rotation | Priority |
|-------------|-----|--------------|---------------|----------|
| `immich-db-password` | Immich | 2026-04-02 | 2026-10-01 | High |
| `linkwarden-db-password` | Linkwarden | 2026-04-02 | 2026-10-01 | Medium |
| `mealie-db-password` | Mealie | 2026-04-02 | 2026-10-01 | Medium |
| `n8n-db-password` | N8N | 2026-04-02 | 2026-10-01 | High |
| `paperless-db-password` | Paperless-NGX | 2026-04-02 | 2026-10-01 | Medium |
| `authentik-db-password` | Authentik | 2026-04-02 | 2026-10-01 | Critical |
| `blocky-db-user` | Blocky (queryLog) | 2026-06-05 | 2026-12-05 | Low |
| `trivy-dockerhub` | trivy-scan CronJob (Docker Hub read-only PAT, 1Password `docker_hub_ro`; PAT non-expiring — revoke+reissue) | 2026-07-14 | 2027-07-14 | Low |
| `grafana-db-password` | Grafana | N/A (SQLite) | N/A | N/A |
| `audiobookshelf-db-password` | Audiobookshelf | N/A (SQLite) | N/A | N/A |

#### MySQL (Percona)

| Secret Name | App | Last Rotated | Next Rotation | Priority |
|-------------|-----|--------------|---------------|----------|
| `home-assistant-mysql` | Home Assistant | 2026-04-02 | 2026-10-01 | High |
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
| `redis-passwords.immich-password` | Immich (static master Service) | 2026-04-02 | 2026-10-01 | High |
| `redis-passwords.paperless-password` | Paperless-NGX (static master Service) | 2026-04-02 | 2026-10-01 | Medium |
| `redis-passwords.blocky-password` | Blocky DNS (static master Service, db 1) | 2026-04-26 | 2026-10-26 | Medium |
| `redis-passwords.admin-password` | Redis HA admin | 2026-04-26 | 2026-10-26 | High |
| `redis-acl-secret` | Redis ACL (literal user list, mounted /etc/redis/user.acl) | 2026-04-26 | rotate WITH redis-passwords | High |
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
| `grafana-admin-secret` | Grafana | User login — NO auto-rotate |
| `audiobookshelf-admin` | Audiobookshelf | User login — NO auto-rotate |
| `couchdb-admin-credentials` | Obsidian Sync | Client-facing (LiveSync direct) — NO rotate |

### OIDC/OAuth Secrets

| App | Where Secret Lives | Last Rotated | Next Rotation | Priority |
|-----|-------------------|--------------|---------------|----------|
| Grafana | `grafana-oidc` K8s Secret (volume mount) | 2026-04-02 | 2026-10-01 | High |
| Immich | PostgreSQL `system_metadata` table (`oauth.clientSecret` jsonb) + Authentik API | 2026-04-02 | 2026-10-01 | High |
| Paperless-NGX | `paperless-env-secret.yaml` (PAPERLESS_SOCIALACCOUNT_PROVIDERS env) | 2026-04-02 | 2026-10-01 | High |
| Mealie | `mealie-env-secret.yaml` (OIDC_CLIENT_SECRET env) | 2026-04-02 | 2026-10-01 | Medium |
| Linkwarden | `linkwarden-secret.yaml` (DATABASE_URL + OIDC combined) | 2026-04-02 | 2026-10-01 | Medium |
| Audiobookshelf | SQLite on PVC (web UI config) + Authentik API | 2026-04-02 | 2026-10-01 | Medium |
| Home Assistant | Confidential `!secret` in HA config (hass-oidc-auth v1.1.0, re-enabled 2026-05-31) | 2026-05-31 | 2026-10-01 | Medium |
| Stirling PDF | `custom-settings-configmap.yaml` (SOPS Secret) | 2026-04-02 | 2026-10-01 | Medium |

**OIDC rotation gotchas:**
- **Immich**: update Authentik API AND PostgreSQL: `UPDATE system_metadata SET value = jsonb_set(value::jsonb, '{oauth,clientSecret}', '"NEW_SECRET"') WHERE key = 'system-config';` then restart
- **Audiobookshelf**: update Authentik API AND web UI (Settings → Auth → OpenID). No CLI (SQLite on PVC)
- **Paperless-NGX**: secret in `PAPERLESS_SOCIALACCOUNT_PROVIDERS` JSON inside env secret (NOT standalone file)
- **All others**: update Authentik API + SOPS file + restart pod

### Infrastructure Credentials

| Secret Name | Component | Last Rotated | Next Rotation | Priority |
|-------------|-----------|--------------|---------------|----------|
| `tunnel-credentials` | Cloudflare Tunnel | 2025-10-18 | Never* | Critical |
| `pricebuddy-telegram` | PriceBuddy | 2025-12-05 | Never* | Medium |
| `backup-replication-ssh` | Backup Jobs | RETIRED 2026-07-17 — W2 safety-net leg removed, secret deleted (NAS-only replication, rsync daemon auth) | N/A | N/A |
| `cloudflare-tunnel-mgmt-token` | CF Tunnel Mgmt | 2026-02-19 | 2026-12-31 | Medium |
| `node-maintenance-ssh` | Node Auto-Update (CP → workers) | 2026-04-17 | 2027-04-17 | High |
| `homelab-deploy` (GitHub deploy key) | Node-Maintenance git sync (CP `/root/.ssh/homelab-deploy`, read-only) | 2026-04-18 | 2027-04-18 | Medium |
| `claude-telegram-ssh` (id_ed25519) | Telegram bot — GitHub account auth + node SSH | 2026-06-12 (compromise) | 2027-06-12 | High |
| `cloudflare-api-token` (`cert-manager` ns) | cert-manager DNS-01 for `*.h0melab.work` | 2025-10-19 | 2026-10-19 | Critical |
| `sops-age` (`flux-system` ns) | SOPS decryption key for every secret in this repo | 2025-10-19 (bootstrap) | Never* | Critical |
| `alertmanager-basic-auth` (`monitoring` ns) | Traefik basicAuth on `am.h0melab.work` | 2026-07-25 | 2027-07-25 | Medium |

\* Rotate only if compromised

**`sops-age`** is the root of the whole scheme — losing it makes every encrypted file in this repo unreadable, and leaking it makes all of them readable. It is deliberately *not* on a rotation clock: rotating it means re-encrypting every SOPS file in one commit. Keep an offline copy.

**`alertmanager-basic-auth`** holds only the htpasswd `users` key — Traefik rejects a basicAuth Secret with more than one key. The generating plaintext lives in the separate `alertmanager-basic-auth-credential` Secret, which should be moved to 1Password and then deleted.

**`claude-telegram-ssh` (2026-06-12)**: rotated after the old key was found in pre-rewrite git history (an account-wide GitHub auth key that doubled as a node SSH key). Procedure: new key added to GitHub + the 3 nodes' `authorized_keys` + SOPS secret → bot restart → verified GitHub and node auth → old key removed everywhere. The bot also reaches GitHub over `ssh.github.com:443`, since the cluster's egress firewall blocks outbound `:22`.

### TLS Certificates

| Certificate | Renewal |
|-------------|---------|
| `*.h0melab.work` | Auto (cert-manager, Let's Encrypt) |
| Individual app certs | Auto (cert-manager) |

---

## ROTATION SCHEDULES

### Standard (180 Days) — single cadence for all scheduled rotations
- DB passwords: Immich, Authentik, N8N, Home Assistant, Mealie, Paperless, Linkwarden, Uptime Kuma, PriceBuddy, Blocky
- Redis: Immich, Paperless, Blocky, HA admin (`redis-acl-secret` rotates with `redis-passwords`)
- OIDC client secrets (Authentik provider + app-side)
- CouchDB admin (also update `monitoring/configs/victoria-metrics/couchdb-auth-secret.yaml` for VMAgent)
- Authentik Django secret key

90-day High tier retired 2026-07-02 — Priority column in the inventory ranks blast-radius, not cadence. Annual infrastructure keys (SSH, deploy, CF mgmt token) keep their own dates.

### Never Rotate
- User login passwords (HomeHub, Grafana admin, Audiobookshelf admin)
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
  infrastructure/configs/databases/postgres/<app>-db-user.yaml

# 3. Update app-side SOPS secret (so the app uses the new password)
# Key name varies by app — check the file first with: sops --ignore-mac -d <file>
sops --ignore-mac --set '["stringData"]["<PASSWORD_KEY>"] "'${NEW_PASSWORD}'"' \
  apps/<app>/<secret-file>.yaml

# NOTE — DSN-embedded credential (no discrete key): if the app bakes the password into a
# connection string rather than its own key — e.g. Blocky queryLog `target: postgres://blocky:PW@...`
# (pgx can't expand ${VAR}, so the literal is required) — step 3 above does NOT apply. Decrypt the
# config value, sed the password inside the DSN, re-encrypt:
#   NEWCFG=$(sops -d --extract '["stringData"]["config.yml"]' apps/blocky/config-secret.yaml \
#     | sed -E "s#(://blocky:)[^@]*(@main-postgres-rw)#\1${NEW_PASSWORD}\2#")
#   sops set apps/blocky/config-secret.yaml '["stringData"]["config.yml"]' "$(printf '%s' "$NEWCFG" | jq -Rs .)"
# Verify both carry the same new pw WITHOUT printing it; confirm CNPG synced the role via
# `kubectl -n databases get cluster main-postgres -o jsonpath='{.status.managedRolesStatus}'`
# (role in .reconciled at the new secret resourceVersion) before/after the app rollout restart.

# 4. Commit and push
git add infrastructure/configs/databases/postgres/<app>-db-user.yaml \
      apps/<app>/<secret-file>.yaml
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

### 2. Redis Password (redis-ha)

Redis auth lives in TWO server-side SOPS secrets that must rotate TOGETHER, plus
each consumer's app-side secret (Authentik has had no Redis since 2025-10-29):

- `infrastructure/configs/databases/redis-ha/passwords-secret.yaml` — `redis-passwords` (per-user: admin, immich, paperless, blocky)
- `infrastructure/configs/databases/redis-ha/acl-secret.yaml` — `redis-acl-secret`, literal user list mounted at `/etc/redis/user.acl`; contains the SAME passwords — regenerate both, never hand-sync one side
- Consumers: `apps/immich/immich-redis-url-secret.yaml` (`REDIS_URL=ioredis://<base64(json)>` — password embedded in the JSON) · `apps/paperless-ngx/paperless-env-secret.yaml` (Redis URL env) · Blocky config

```bash
# 1. Generate new password (per Redis user being rotated)
NEW_PASSWORD=$(openssl rand -base64 32 | tr -d '+/=' | head -c 32)

# 2. Update BOTH server-side secrets with the new password
sops infrastructure/configs/databases/redis-ha/passwords-secret.yaml
sops infrastructure/configs/databases/redis-ha/acl-secret.yaml   # same password in the ACL line

# 3. Update the app-side consumer secret
sops apps/immich/immich-redis-url-secret.yaml        # rebuild the base64(json) REDIS_URL
# or: sops apps/paperless-ngx/paperless-env-secret.yaml

# 4. Commit and push
git add -A
git commit -m "Rotate Redis <user> password"
git push

# 5. Reconcile, then rollout restart (NEVER delete pods — Flux reverts restartedAt)
# infrastructure-configs, not -controllers: the Redis secrets live under
# infrastructure/configs/databases/redis-ha/, which is the -configs Kustomization's path.
flux reconcile source git flux-system --timeout 45s
flux reconcile kustomization infrastructure-configs --timeout 60s
flux reconcile kustomization apps --timeout 60s
kubectl rollout restart statefulset/redis-replication -n databases
kubectl rollout restart deployment/<app> -n <app>

# 6. Verify connectivity
kubectl logs -n <app> deployment/<app> --tail=20 | grep -i "redis\|error"
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
sops apps/home-assistant/admin-credentials-secret.yaml
# Update the MySQL password value

# 4. Commit and push
git add apps/home-assistant/admin-credentials-secret.yaml
git commit -m "Rotate Home Assistant MySQL password"
git push

# 5. Reconcile and restart
flux reconcile source git flux-system --timeout 45s
flux reconcile kustomization apps --timeout 45s
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
  apps/<app>/<oidc-secret-file>.yaml

# 4. Commit and push
git add apps/<app>/<oidc-secret-file>.yaml
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

### 5. User Login Passwords (HomeHub)

#### HomeHub
```bash
# 1. Generate bcrypt hash
python3 -c "import bcrypt; print(bcrypt.hashpw(b'YOUR_NEW_PASSWORD', bcrypt.gensalt(rounds=12)).decode())"

# 2. Update SOPS secret
sops apps/homehub/secret.yaml
# Update HOMEHUB_PASSWORD with bcrypt hash

# 3. Commit, push, reconcile, restart
git add apps/homehub/secret.yaml
git commit -m "Rotate HomeHub password"
git push
flux reconcile kustomization apps --timeout 45s
kubectl rollout restart deployment/homehub -n homehub
```

#### Blocky DNS (Redis password coordinated rotation)
```bash
# 1. Generate new password
NEW=$(openssl rand -base64 32 | tr -d '\n=/+' | head -c 40)

# 2. Update redis-passwords (databases ns)
sops infrastructure/configs/databases/redis-ha/passwords-secret.yaml
# Replace blocky-password value with $NEW

# 3. Update redis-acl-secret (databases ns) — replace blocky line `>${OLD}` with `>${NEW}`
sops infrastructure/configs/databases/redis-ha/acl-secret.yaml

# 4. Update Blocky's inlined config Secret
sops apps/blocky/config-secret.yaml
# Find redis.password: <OLD> → replace with <NEW>

# 5. Commit, push, reconcile, restart
git add infrastructure/configs/databases/redis-ha/passwords-secret.yaml \
        infrastructure/configs/databases/redis-ha/acl-secret.yaml \
        apps/blocky/config-secret.yaml
git commit -m "Rotate blocky redis password"
git push
flux reconcile source git flux-system --timeout 45s
flux reconcile kustomization infrastructure-controllers --timeout 60s
flux reconcile kustomization apps --timeout 60s
kubectl rollout restart statefulset -n databases redis-replication redis-sentinel-sentinel
kubectl rollout restart deploy -n blocky blocky

# 6. Verify
kubectl logs -n blocky -l app=blocky --tail=20 | grep -iE "redis|error"
```

---

## VERIFICATION CHECKLIST

After rotating any secret:
- [ ] Git commit pushed
- [ ] Flux reconciliation done
- [ ] Pods restarted
- [ ] No auth errors in logs
- [ ] App accessible via web UI
- [ ] Dependent services connected
- [ ] No monitoring alerts
- [ ] "Last Rotated" updated in this doc
- [ ] Doc update committed

---

## EMERGENCY ROTATION

If compromised:
1. **Immediate**: rotate within 1h, check logs for unauthorized access
2. **Investigate**: scope, affected systems, lateral movement
3. **Remediate**: rotate all related secrets, tighten NetworkPolicies, update firewall
4. **Post-mortem**: document, update procedures, review access controls

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
- [x] 2026-07-02: Cadence change — 90-day High tier retired, all scheduled rotations now 180-day. Ex-High secrets (PG authentik/immich/n8n, MySQL HA, Redis immich) folded into the 2026-10-01 batch; Redis admin → 2026-10-26.
- [ ] **2026-08-06: move the Alertmanager basicAuth password to 1Password, then delete the `alertmanager-basic-auth-credential` Secret.** Created 2026-07-25 with the `am.h0melab.work` basicAuth work. The plaintext currently sits in SOPS purely so it can be retrieved once — it is not read by anything, so deleting it breaks nothing. Nothing reminds you automatically; this checklist is the reminder.
  ```bash
  kubectl -n monitoring get secret alertmanager-basic-auth-credential \
    -o jsonpath='{.data.username}' | base64 -d; echo
  kubectl -n monitoring get secret alertmanager-basic-auth-credential \
    -o jsonpath='{.data.password}' | base64 -d; echo
  ```
  Store it in 1Password, then delete **only the second Secret document** from
  `monitoring/configs/kube-prometheus-stack/alertmanager-basic-auth-secret.yaml` — that
  one file holds *both* Secrets, and the first one (`alertmanager-basic-auth`, the htpasswd
  `users` key) is what Traefik actually reads. Deleting the whole file, or its kustomization
  entry, takes Alertmanager's auth down with it. Leave the file and the entry in place.
  Flux prunes the removed Secret on the next reconcile; confirm with a `401` on
  `https://am.h0melab.work` and a `200` with the credentials.

### 2026 Q4 (Oct-Dec)
- [ ] 2026-10-01: 180-day rotation — ALL scheduled secrets (PG, MySQL, Redis, CouchDB, OIDC, Django key; ex-High included)
- [ ] 2026-10-26: Redis `admin-password` + `blocky-password` (+ `redis-acl-secret`)

---

## BEST PRACTICES

1. **Password gen**: cryptographically secure, 32+ chars DB/Redis, 64+ OIDC. Avoid special chars (URL encoding).
2. **Testing**: verify dependent services. Keep prev password 24h for rollback.
3. **Docs**: update this doc + commit immediately after rotation.
4. **Monitoring**: watch auth errors 15 min post-rotation. Check Grafana.
5. **Backup**: ensure secrets backup current before rotation.

---

## RELATED

- [Security](./SECURITY.md) | [Homelab Analysis](./HOMELAB_ANALYSIS.md)

### Git Audit Trail
```bash
# View all secret rotation commits with dates
git log --all --date=short --format="%ad %s" --grep="secret\|password\|rotate" -- apps/

# View specific secret file history
git log --all --date=short --format="%ad %h %s" --follow -- apps/immich/immich-db-password-secret.yaml

# View detailed changes for a specific commit
git show <commit-hash> -- apps/immich/immich-db-password-secret.yaml
```

---

**Review Schedule**: Quarterly | **Next Review**: 2026-10-01
