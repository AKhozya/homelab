# Secrets Rotation Playbook

**Cluster**: K3s Homelab (k3s v1.37.1+k3s1, 4 nodes) | **Last Updated**: 2026-10-04
**Audit Trail**: rotation dates in git commit history

Every Kubernetes Secret this repo deploys lives in Git, encrypted with SOPS and an age key, next to
the manifests that use it. Only the cluster's age key decrypts it, so the repo can be public without
exposing a value. Each secret change is a reviewable commit, no external secret store has to run
before the cluster boots, and restoring those Secrets needs only the repo and the age key. This page tracks the rotation
dates and procedures for each class of secret.

---

## SECRETS INVENTORY

### Database Credentials

#### PostgreSQL (CloudNativePG)

| Secret Name | App | Last Rotated | Next Rotation | Priority |
|-------------|-----|--------------|---------------|----------|
| `immich-db-user` (ns `databases`) + `immich-db-password` (ns `immich`) | Immich | 2026-10-02 | 2027-03-31 | High |
| `linkwarden-db-app-user` (file `linkwarden-app-user-secret.yaml`) | Linkwarden | 2026-10-02 | 2027-03-31 | Medium |
| `mealie-db-user` | Mealie | 2026-10-02 | 2027-03-31 | Medium |
| `n8n-db-user` | N8N | 2026-10-02 | 2027-03-31 | High |
| `paperless-db-user` | Paperless-NGX | 2026-10-02 | 2027-03-31 | Medium |
| `authentik-db-user` | Authentik | 2026-10-02 | 2027-03-31 | Critical |
| `blocky-db-user` | Blocky (queryLog) | 2026-06-05 | 2026-12-05 | Low |

Grafana and Audiobookshelf use SQLite, so they have no database Secret.

#### MySQL (Percona)

| Secret Name | App | Last Rotated | Next Rotation | Priority |
|-------------|-----|--------------|---------------|----------|
| `home-assistant-secrets` (the `db_url` line inside key `secrets.yaml`) | Home Assistant | 2026-10-02 | 2027-03-31 | High |
| `uptime-kuma-mysql-credentials` | Uptime Kuma | 2026-10-02 | 2027-03-31 | Medium |
| `pricebuddy-mysql-credentials` | PriceBuddy | 2026-10-02 | 2027-03-31 | Medium |

#### CouchDB

| Secret Name | App | Last Rotated | Next Rotation | Priority |
|-------------|-----|--------------|---------------|----------|
| CouchDB admin, three copies (see [Standard](#standard-180-days--single-cadence-for-all-scheduled-rotations)) | Obsidian Sync | 2026-10-02 | 2027-03-31 | — |

The sync user `couchdb-credentials` is not rotated; it is under User Login Passwords. The LiveSync
devices log in as the admin instead. If a device keeps the old password after a rotation, its sync
requests return 401 (see the Standard section).

### Redis

| Secret Name | App | Last Rotated | Next Rotation | Priority |
|-------------|-----|--------------|---------------|----------|
| `authentik-redis-password` | Authentik | N/A (Removed 2025-10-29) | N/A | N/A |
| `redis-passwords.immich-password` | Immich (static master Service) | 2026-10-02 | 2027-03-31 | High |
| `redis-passwords.paperless-password` | Paperless-NGX (static master Service) | 2026-10-02 | 2027-03-31 | Medium |
| `redis-passwords.blocky-password` | Blocky DNS (static master Service, db 1) | 2026-10-02 | 2027-03-31 | Medium |
| `redis-passwords.admin-password` | Redis HA admin | 2026-10-02 | 2027-03-31 | High |
| `redis-acl-secret` | Redis ACL (literal user list, mounted /etc/redis/user.acl) | 2026-10-02 | rotate WITH redis-passwords | High |
| `wallabag-redis-password` | Wallabag | N/A (Decommissioned) | N/A | N/A |

### Application Secrets

| Secret Name | App | Type | Last Rotated | Next Rotation | Priority |
|-------------|-----|------|--------------|---------------|----------|
| `authentik` (key `AUTHENTIK_SECRET_KEY`) | Authentik | Django Secret | 2026-10-02 | 2027-03-31 | High |
| `n8n-env` (key `N8N_ENCRYPTION_KEY`) | N8N | Encryption Key | Never* | N/A | Critical |

\* **N8N encryption key NEVER rotated** — encrypts all workflow credentials

Since authentik 2023.6, `AUTHENTIK_SECRET_KEY` signs cookies and no longer feeds user IDs, and the docs say a change invalidates active sessions ([configuration docs](https://docs.goauthentik.io/install-config/configuration/)). So after a rotation each user logs in to Authentik again. The docs say nothing about app sessions or OIDC refresh tokens; on 2026-10-02 no app reported a login problem afterwards.

### User Login Passwords (NOT rotated)

| Secret Name | App | Notes |
|-------------|-----|-------|
| `homehub-password` | HomeHub | User login — NO auto-rotate |
| `grafana-admin-secret` | Grafana | User login — NO auto-rotate |
| `audiobookshelf-admin` | Audiobookshelf | User login — NO auto-rotate |
| `couchdb-credentials` (ns `obsidian`) | Obsidian Sync | Sync user, admin of `obsidian-personal` only. The LiveSync devices log in as the CouchDB admin. The plugin's database-configuration fixes change server settings, which needs a server admin — NO rotate |

### OIDC/OAuth Secrets

| App | Where Secret Lives | Last Rotated | Next Rotation | Priority |
|-----|-------------------|--------------|---------------|----------|
| Grafana | `grafana-oidc` K8s Secret (volume mount) | 2026-10-02 | 2027-03-31 | High |
| Immich | PostgreSQL `system_metadata` table (`oauth.clientSecret` jsonb) + Authentik API | 2026-10-02 | 2027-03-31 | High |
| Paperless-NGX | `paperless-env-secret.yaml` (PAPERLESS_SOCIALACCOUNT_PROVIDERS env) | 2026-10-02 | 2027-03-31 | High |
| Mealie | `mealie-env-secret.yaml` (OIDC_CLIENT_SECRET env) | 2026-10-02 | 2027-03-31 | Medium |
| Linkwarden | `linkwarden-secret.yaml` (DATABASE_URL + OIDC combined) | 2026-10-02 | 2027-03-31 | Medium |
| Audiobookshelf | SQLite on PVC (web UI config) + Authentik API | 2026-10-02 | 2027-03-31 | Medium |
| Home Assistant | Confidential `!secret` in HA config (hass-oidc-auth v1.1.0, re-enabled 2026-05-31) | 2026-10-02 | 2027-03-31 | Medium |
| Stirling PDF | `custom-settings-secret.yaml` (inside key `custom_settings.yml`) | 2026-10-02 | 2027-03-31 | Medium |
| Cloudflare Access | Cloudflare Zero Trust: Integrations → Identity providers → the Authentik OpenID Connect provider → Client secret | 2026-10-02 | 2027-03-31 | High |

**OIDC rotation gotchas:**
- **Immich**: update Authentik API AND PostgreSQL: `UPDATE system_metadata SET value = jsonb_set(value::jsonb, '{oauth,clientSecret}', '"NEW_SECRET"') WHERE key = 'system-config';` then restart
- **Audiobookshelf**: update Authentik API AND web UI (Settings → Auth → OpenID). No CLI (SQLite on PVC)
- **Paperless-NGX**: secret in `PAPERLESS_SOCIALACCOUNT_PROVIDERS` JSON inside env secret (NOT standalone file)
- **Cloudflare Access** (provider 50): update Authentik (step 2), then paste the same secret into the Zero Trust identity provider, select **Save**, and select **Test**. Then log in to an Access-protected app through Authentik. No file in this repo holds the secret, and nothing restarts
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
| `claude-telegram-ssh` → `id_ed25519` | Telegram bot — node SSH only (pinned to the `agent-diag` forced command since 2026-08-03, read-only diagnostics) | 2026-06-12 (compromise) | 2027-06-12 | High |
| `claude-telegram-ssh` → `gh-homelab` | Telegram bot — GitHub deploy key, repo `homelab`, **WRITE** (`read_only=false`) | 2026-08-03 | 2027-01-30 | Critical |
| `claude-telegram-ssh` → `gh-dotfiles` | Telegram bot — GitHub deploy key, repo `dotfiles`, read-only | 2026-08-03 | 2027-08-03 | Medium |
| `claude-telegram-ssh` → `gh-fork` | Telegram bot — GitHub deploy key, repo `claude-telegram-bot`, read-only | 2026-08-03 | 2027-08-03 | Low |
| `cloudflare-api-token` (`cert-manager` ns) | cert-manager DNS-01 for the `h0melab.work` zone; Cloudflare token `dns_and_certs` (Zone.Zone + Zone.DNS, one zone) | 2026-09-28 (compromise) | 2027-09-28 | Critical |
| `alertmanager-telegram` (`bot_token`, `token`) + `backup-telegram` (`bot_token`) | Telegram bot @h0melab_alerts_bot: Alertmanager, Flux notifications, backup job | 2026-09-28 (compromise) | Never* | Medium |
| `claude-telegram-env` → `telegram-bot-token` | Telegram bot @ClaudeSelfHostedBot (claude-telegram) | 2026-09-28 | Never* | High |
| `sops-age` (`flux-system` ns) | SOPS decryption key for every secret in this repo | 2025-10-19 (bootstrap) | Never* | Critical |
| `alertmanager-basic-auth` (`monitoring` ns) | Traefik basicAuth on `am.h0melab.work` | 2026-07-25 | 2027-07-25 | Medium |
| `FLUX_UPDATE_TOKEN` (GitHub Actions repo secret) | `flux-update.yaml` opens the weekly Flux update PR; fine-grained PAT `homelab-flux-update`, repo `homelab` only, Contents + Pull requests write; 1Password `homelab-flux-update-token` | 2026-10-01 (created) | 2027-03-30 | Critical |
| `trivy-dockerhub` | trivy-scan CronJob (Docker Hub read-only PAT, 1Password `docker_hub_ro`; PAT non-expiring — revoke+reissue) | 2026-07-14 | 2027-07-14 | Low |

\* Rotate only if compromised

**`gh-homelab`** is the only key here that can change what runs in the cluster. Flux reconciles
`main` every 5 minutes, so a push with this key is a deploy — which is why it carries a 180-day
deadline rather than the annual one the other deploy keys get. The three `gh-*` keys and
`id_ed25519` all live in the single `claude-telegram-ssh` Secret; rotating one means re-encrypting
that file, not replacing it. Confirm scope against GitHub rather than this table before trusting
it: `gh api repos/AKhozya/<repo>/keys --jq '.[] | "\(.title) read_only=\(.read_only)"'`.

**`FLUX_UPDATE_TOKEN`**:

| Fact | Consequence |
|---|---|
| it has Contents and Pull requests write on this repo | it can merge a PR whose checks pass, so treat its use as a deploy, like one with `gh-homelab` |
| the `main` ruleset has no bypass | it cannot push to `main` |

For that reason you rotate it every 180 days, like `gh-homelab`. Each counts from its own last rotation, so the two deadlines in the table above differ. The PAT itself never expires, so GitHub does not enforce that deadline. It is a fine-grained PAT, separate from the classic PAT that owns Flux's deploy key. Deleting that classic PAT also deletes the deploy key. If it leaks or you rotate it: regenerate `homelab-flux-update` at github.com/settings/personal-access-tokens, save the new value in the 1Password item, then load it and test it:

```bash
op read 'op://Personal/homelab-flux-update-token/credential' | gh secret set FLUX_UPDATE_TOKEN --repo AKhozya/homelab
gh workflow run flux-update.yaml --repo AKhozya/homelab
```

If the secret is empty or missing, the workflow's `Require FLUX_UPDATE_TOKEN` step fails. Pipe the value in as above. If no terminal is attached and stdin is empty, a bare `gh secret set` stores an empty secret.

**`sops-age`** is the root of the whole scheme — losing it makes every encrypted file in this repo unreadable, and leaking it makes all of them readable. It is deliberately *not* on a rotation clock: rotating it means re-encrypting every SOPS file in one commit. Keep an offline copy.

**`alertmanager-basic-auth`** holds only the htpasswd `users` key — Traefik rejects a basicAuth Secret with more than one key. `users` is bcrypt and one-way, so the readable credential lives in 1Password: `op read 'op://Personal/alertmanager-homelab/password'`. Do not add a second key to this Secret to keep a copy in-cluster; the middleware then fails to build and the host returns 404 rather than 401, silently.

**The Cloudflare and alerts-bot tokens (2026-09-28).** A pre-rewrite commit (`7349f6cc`, 2025-10-07) holds both values, and 18 `refs/pull/*` still reach that commit. The repo owner cannot delete PR refs, so the operator rotated both tokens. The operator rotated the claude-telegram token in the same pass, although that commit does not hold it. Before the rotation, the Cloudflare row said "2025-10-19", but the SOPS file had not changed since 2025-10-06, so the value in it could not be newer. If this table and a file's `sops.lastmodified` disagree, the value is no newer than `sops.lastmodified`. Procedure: [section 6](#6-cloudflare-api-token-and-telegram-bot-tokens).

**`claude-telegram-ssh` (2026-06-12)**: rotated after the old key was found in pre-rewrite git history (an account-wide GitHub auth key that doubled as a node SSH key). Procedure: new key added to GitHub + the 3 nodes' `authorized_keys` + SOPS secret → bot restart → verified GitHub and node auth → old key removed everywhere. The bot also reaches GitHub over `ssh.github.com:443`, because its NetworkPolicy allows no egress to port 22.

### TLS Certificates

| Certificate | Renewal |
|-------------|---------|
| One per ingress hostname; no wildcard certificate | Auto (cert-manager, Let's Encrypt DNS-01) |
| MySQL internal TLS (`main-mysql-ca-cert`, `main-mysql-ssl`) | Auto (cert-manager) |

---

## ROTATION SCHEDULES

### Standard (180 Days) — single cadence for all scheduled rotations
- DB passwords: Immich, Authentik, N8N, Home Assistant, Mealie, Paperless, Linkwarden, Uptime Kuma, PriceBuddy, Blocky
- Redis: Immich, Paperless, Blocky, HA admin (`redis-acl-secret` rotates with `redis-passwords`)
- OIDC client secrets (Authentik provider + app-side)
- CouchDB admin. After the three files deploy, delete the CouchDB pods one at a time. If the new
  pod is Ready and its login check passes, delete the next one. Why a restart applies it: the image entrypoint writes the admin from
  `COUCHDB_PASSWORD` into `local.d`, which is not mounted, so each new container takes the new
  value. Three SOPS files and the operator's devices hold it, and all must match:

  | File | Secret (namespace) | Keys | Reader |
  |---|---|---|---|
  | `infrastructure/configs/databases/couchdb/admin-secret.yaml` | `couchdb-couchdb` (`databases`) | `adminUsername`, `adminPassword` | CouchDB, backup CronJob |
  | `monitoring/configs/victoria-metrics/couchdb-auth-secret.yaml` | `couchdb-couchdb` (`monitoring`) | `adminUsername`, `adminPassword` | VMAgent scrape |
  | `apps/obsidian/couchdb-admin-credentials.yaml` | `couchdb-admin-credentials` (`obsidian`) | `username`, `password` | Obsidian init Job |
  | none in git | the LiveSync settings on each of the operator's devices | username, password | Obsidian LiveSync |

  If both pods pass the login check, stop and tell the operator to put the new password into
  LiveSync on every device. If a device keeps the old password, its sync fails with 401.
  1Password holds no copy. The operator reads it from `admin-secret.yaml` with `sops -d`.
- Authentik Django secret key

90-day High tier retired 2026-07-02 — Priority column in the inventory ranks blast-radius, not cadence. Annual infrastructure keys (SSH, deploy, CF mgmt token) keep their own dates.

### Never Rotate
- User login passwords (HomeHub, Grafana admin, Audiobookshelf admin)
- N8N encryption key (breaks encrypted workflow credentials)
- Cloudflare tunnel token (only if compromised)
- Age key for SOPS (only if compromised)
- vmsingle `deleteAuthKey` (`monitoring/configs/victoria-metrics/vmsingle-auth-secret.yaml`): vmsingle reads it from a mounted file to protect `/api/v1/admin/tsdb/delete_series`. No script, skill or app sends it. Rotate it only if compromised

---

## ROTATION PROCEDURES

**Restarting app pods.** Do not use `kubectl rollout restart` on a Flux-managed workload. Flux's
drift correction removes the `restartedAt` annotation it adds, so the old pod keeps running on the
old secret (n8n, recorded in `d6d67c20`). Delete the pods instead. `agents/skills/_shared/restart-workload.sh`
deletes one pod at a time and waits until the workload is Ready again before the next, so a
two-replica app keeps serving. It is not for databases, although nothing in it stops you; Redis
has its own restart step in section 2.

| App | Namespace | Selector | Replicas |
|---|---|---|---|
| Authentik | `authentik` | `app=authentik,component=server`, then `app=authentik,component=worker` | 2 each |
| Blocky | `blocky` | `app=blocky` | 2 |
| Grafana | `monitoring` | `app.kubernetes.io/name=grafana` | 1 |
| Home Assistant | `home-assistant` | `app=home-assistant` | 1 |
| HomeHub | `homehub` | `app=homehub` | 1 |
| Immich | `immich` | `app.kubernetes.io/name=server` | 1 |
| Linkwarden | `linkwarden` | `app=linkwarden` | 1 |
| Mealie | `mealie` | `app=mealie` | 1 |
| N8N | `n8n` | `app=n8n` | 1 |
| Paperless-NGX | `paperless-ngx` | `app=paperless-ngx` | 1 |
| PriceBuddy | `pricebuddy` | `app=pricebuddy` | 1 |
| Stirling PDF | `stirling-pdf` | `app=stirling-pdf` | 1 |
| Uptime Kuma | `uptime-kuma` | `app=uptime-kuma` | 1 |

```bash
agents/skills/_shared/restart-workload.sh <namespace> <selector>
```

**Merging a rotation.** The `main` ruleset rejects direct pushes, so each procedure below merges
its commit through a PR. Run the procedures in a worktree (AGENTS.md "Sessions & Worktrees") and
define this function once per shell. If `merged` fails, stop the procedure there: nothing merged,
or the outcome is unknown.

```bash
# Exit 3 means the PR merged but a later local step failed. Flux still deploys the merge, so the
# rotation must go on to its reconcile and restart.
merged() { agents/skills/_shared/merge-worktree.sh "$(git branch --show-current)"; local rc=$?; [ "$rc" = 0 ] || [ "$rc" = 3 ] || { echo "STOP: merge not confirmed (exit $rc); do not run the next steps"; return 1; }; }
```

### 1. PostgreSQL Password (CNPG)

`agents/skills/_shared/rotate-pg-roles.sh <role>...` does steps 1-3 for every copy at once. It
finds each copy by the current value, including DSNs, so no file list becomes outdated. Apps behind the
PgBouncer pooler show old server connections in `pg_stat_activity`; prove the new login with
`agents/skills/_shared/pooler-login-proof.sh` instead.

```bash
# 1. Generate new password (64-char hex for URL safety)
NEW_PASSWORD=$(openssl rand -hex 32)

# 2. Update CNPG db-user secret (CNPG operator watches this and syncs to PostgreSQL)
# All users are in managed.roles in the Cluster CRD — CNPG auto-updates the DB password
# The value goes in on stdin, never on the command line.
printf '"%s"' "$NEW_PASSWORD" | sops set --ignore-mac --value-stdin \
  infrastructure/configs/databases/postgres/<app>-db-user.yaml '["stringData"]["password"]'

# 3. Update app-side SOPS secret (so the app uses the new password)
# Key name varies by app. List the key names, not the values, with:
#   sops -d apps/<app>/<secret-file>.yaml | yq '.stringData | keys'
printf '"%s"' "$NEW_PASSWORD" | sops set --ignore-mac --value-stdin \
  apps/<app>/<secret-file>.yaml '["stringData"]["<PASSWORD_KEY>"]'

# NOTE — DSN-embedded credential (no discrete key): if the app bakes the password into a
# connection string rather than its own key — Linkwarden's `DATABASE_URL`, or Blocky queryLog `target: postgres://blocky:PW@...`
# (pgx can't expand ${VAR}, so the literal is required) — step 3 above does NOT apply. Decrypt the
# config value, replace the password inside the DSN, re-encrypt:
# awk takes the password from its environment, not its arguments, so it stays off the command line:
#   NEWCFG=$(sops -d --extract '["stringData"]["config.yml"]' apps/blocky/config-secret.yaml |
#     NP="$NEW_PASSWORD" awk '{ if (match($0, /:\/\/blocky:[^@]*@main-postgres-rw/))
#       $0 = substr($0, 1, RSTART - 1) "://blocky:" ENVIRON["NP"] "@main-postgres-rw" substr($0, RSTART + RLENGTH)
#       print }')
#   printf '%s' "$NEWCFG" | jq -Rs . | sops set --value-stdin apps/blocky/config-secret.yaml '["stringData"]["config.yml"]'
# Verify both carry the same new pw WITHOUT printing it; confirm CNPG synced the role via
# `kubectl -n databases get cluster main-postgres -o jsonpath='{.status.managedRolesStatus}'`
# (role in .reconciled at the new secret resourceVersion) before/after the app restart.

# 4. Commit and merge. If merged fails, stop here.
git add infrastructure/configs/databases/postgres/<app>-db-user.yaml \
      apps/<app>/<secret-file>.yaml
git commit -m "Rotate <app> database password"
merged

# 5. Force Flux to reconcile
flux reconcile source git flux-system --timeout 60s
flux reconcile kustomization infrastructure-configs --timeout 60s
flux reconcile kustomization apps --timeout 60s

# 6. Restart the app's pods so they read the new secret (selector table above)
agents/skills/_shared/restart-workload.sh <namespace> <selector>

# 7. Verify connectivity
kubectl logs -n <app> deployment/<app> --tail=20 | grep -i "database\|error"

# 8. Update rotation tracking in this document
```

**Rollback:**
```bash
# 1. Revert the rotation's merge commit (in a worktree from a fresh origin/main) and merge it.
#    If merged fails, stop here.
git revert -m 1 --no-edit <merge-SHA>
merged

# 2. Force reconcile and restart (CNPG will revert the DB password from the reverted secret)
flux reconcile source git flux-system --timeout 60s
flux reconcile kustomization infrastructure-configs --timeout 60s
flux reconcile kustomization apps --timeout 60s
agents/skills/_shared/restart-workload.sh <namespace> <selector>
```

---

### 2. Redis Password (redis-ha)

**Preferred since 2026-10-02: three passes that overlap the old and new password**, run with the
helpers in `agents/skills/_shared/` (`rotate-redis-users.sh`, `redis-restart.sh`,
`redis-acl-drop-old.sh`). Redis accepts both passwords until every client holds the new one, so it
never rejects a client's password. That matters because blocky sets redis `required: true` and
serves DNS. Restarts and failovers can still interrupt clients briefly. The single-password steps
below lock out each consumer from the Redis restart until its own restart. What the 2026-10-02 run
showed:

| Observation | Consequence |
|---|---|
| `redis-acl-secret` is mounted with `subPath` | a running pod never sees a new ACL; only a restart or a runtime `ACL SETUSER` changes it |
| a replication restart left both pods `role:master` for ~50s until the operator re-attached the replica | `redis-restart.sh` waits for one master with one linked replica |
| the same restart gave the pods new IPs and the sentinels kept the dead master IP | no failover until the sentinels restart; `redis-restart.sh sentinel` waits for quorum on the current master |
| `ACL SETUSER <user> !<hash>` removes an old password from a running pod | the last pass needs no restart |
| since the redisSecret change, `REDIS_PASSWORD` in the Redis pods is `admin-password` | after pass 2, restart the Redis pods as well as the sentinels, before pass 3 drops the old token |

Redis auth lives in TWO server-side SOPS secrets that must rotate TOGETHER, plus
each consumer's app-side secret (Authentik has had no Redis since 2025-10-29):

- `infrastructure/configs/databases/redis-ha/passwords-secret.yaml` — `redis-passwords` (per-user: admin, immich, paperless, blocky)
- `infrastructure/configs/databases/redis-ha/acl-secret.yaml` — `redis-acl-secret`, literal user list mounted at `/etc/redis/user.acl`; contains the SAME passwords — regenerate both, never hand-sync one side
- Consumers: `apps/immich/immich-redis-url-secret.yaml` (key `redis-url`, `ioredis://<base64(json)>` — password embedded in the JSON) · `apps/paperless-ngx/paperless-env-secret.yaml` (key `PAPERLESS_REDIS`, a URL) · Blocky config ([Blocky DNS](#blocky-dns-redis-password-coordinated-rotation))

If you rotate **`admin-password`**, stop here and follow [Rotating admin-password](#rotating-admin-password)
instead. Do not edit either secret first. Steps 1 to 6 below are for the app users `immich`,
`paperless` and `blocky`.

```bash
# 1. Generate new password (per Redis user being rotated)
NEW_PASSWORD=$(openssl rand -base64 32 | tr -d '+/=' | head -c 32)

# 2. Update BOTH server-side secrets with the new password
sops infrastructure/configs/databases/redis-ha/passwords-secret.yaml
sops infrastructure/configs/databases/redis-ha/acl-secret.yaml   # same password in the ACL line

# 3. Update the app-side consumer secret
sops apps/immich/immich-redis-url-secret.yaml        # rebuild the base64(json) REDIS_URL
# or: sops apps/paperless-ngx/paperless-env-secret.yaml

# 4. Commit and merge. If merged fails, stop here.
git add infrastructure/configs/databases/redis-ha/passwords-secret.yaml \
        infrastructure/configs/databases/redis-ha/acl-secret.yaml \
        apps/<app>/<secret-file>.yaml
git commit -m "Rotate Redis <user> password"
merged

# infrastructure-configs, not -controllers: the Redis secrets live under
# infrastructure/configs/databases/redis-ha/, which is the -configs Kustomization's path.
flux reconcile source git flux-system --timeout 45s
flux reconcile kustomization infrastructure-configs --timeout 60s
flux reconcile kustomization apps --timeout 60s
```

5. Restart the Redis pods, one at a time: the replica, then the master. The helpers below behave
   as follows:

   | Behaviour | Consequence |
   |---|---|
   | Redis reads `user.acl` only when it starts | The kubelet updates the mounted file, but a running Redis keeps the old passwords until it restarts. |
   | The opstree operator loops on the `restartedAt` annotation that `kubectl rollout restart` adds (`bf7bf65d`) | Never run `rollout restart` on these StatefulSets. The helpers delete one pod at a time. |
   | The StatefulSet gives a recreated pod the same name but a new UID | You record every Redis pod's UID in `OLD_UIDS` after step 4. If a pod's UID is not in that list, the helpers treat the pod as restarted. |
   | `restart_old` sends the recorded UID as a delete precondition | If the StatefulSet replaced the pod after the helper read its UID, the API server refuses the delete, so no pod restarts twice. |
   | A pod whose UID cannot be read | `restart_old` stops rather than delete it. |
   | Roles swap on failover | The chain reads the `redis-role` label again before each restart. `all_restarted` checks at the end that every pod has a new UID and is Ready. |
   | Deleting the master makes the sentinels promote the restarted replica | Writes fail for a few seconds. |
   | Each helper returns non-zero on a failure | The `&&` chain stops at the first failure. |

   ```bash
   # Record the UIDs once per restart pass, after step 4. If you lose this shell, record again:
   # the pods already restarted then restart once more, which is safe.
   OLD_UIDS=$(kubectl -n databases get pod -l 'app in (redis-replication,redis-sentinel-sentinel)' \
     -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}') && [ -n "$OLD_UIDS" ] && echo "UIDs recorded" ||
     { OLD_UIDS=""; echo "UID capture FAILED: do not go on"; }
   pod_uid() { kubectl -n databases get pod "$1" -o jsonpath='{.metadata.uid}'; }
   # An empty OLD_UIDS would make every pod look already restarted, so both helpers refuse it.
   have_uids() { [ -n "$OLD_UIDS" ] || { echo "OLD_UIDS is empty: record the UIDs first"; return 1; }; }
   is_old() { case "$OLD_UIDS" in *"$1"*) true ;; *) false ;; esac; }
   restart_old() {  # $1 = pod; restarts it if its UID is still an old one, then waits for Ready
     have_uids || return 1
     uid=$(pod_uid "$1") && [ -n "$uid" ] || { echo "cannot read the UID of $1"; return 1; }
     if is_old "$uid"; then
       printf '{"kind":"DeleteOptions","apiVersion":"v1","preconditions":{"uid":"%s"}}' "$uid" |
         kubectl delete --raw "/api/v1/namespaces/databases/pods/$1" -f - >/dev/null || return 1
       n=0
       until new=$(pod_uid "$1" 2>/dev/null) && [ -n "$new" ] && [ "$new" != "$uid" ]; do
         n=$((n + 1)); [ "$n" -le 90 ] || { echo "$1 was not recreated within 3 min"; return 1; }
         sleep 2
       done
       echo "$1 restarted"
     else
       echo "$1 already restarted"
     fi
     kubectl -n databases wait --for=condition=Ready pod/"$1" --timeout=180s
   }
   role_pod() { kubectl -n databases get pod -l "app=redis-replication,redis-role=$1" -o jsonpath='{.items[0].metadata.name}'; }
   all_restarted() {  # $1 = label selector; every matching pod must have a new UID and be Ready
     have_uids || return 1
     names=$(kubectl -n databases get pod -l "$1" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') &&
       [ -n "$names" ] || return 1
     printf '%s\n' "$names" | while IFS= read -r p; do
       uid=$(pod_uid "$p") && [ -n "$uid" ] && ! is_old "$uid" || { echo "NOT restarted: $p"; return 1; }
       [ "$(kubectl -n databases get pod "$p" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ] ||
         { echo "NOT Ready: $p"; return 1; }
     done || return 1
     echo "every pod of $1 has restarted and is Ready"
   }

   R=$(role_pod slave) && restart_old "$R" &&
     M=$(role_pod master) && restart_old "$M" &&
     all_restarted app=redis-replication
   ```

   If `all_restarted` prints `NOT restarted`, a failover moved a role mid-way. Run the last three
   lines again; `restart_old` skips the pods that are already done.
6. Restart each consumer (selector table under ROTATION PROCEDURES), then check its log:

   ```bash
   agents/skills/_shared/restart-workload.sh <namespace> <selector>
   kubectl logs -n <namespace> deployment/<deployment> --tail=20 | grep -i "redis\|error"
   ```

#### Rotating admin-password

The sentinels log in to Redis with `admin-password`, and they read it only when they start. If a
Redis pod accepts only the new password, the sentinels that still hold the old one cannot log in
to it. They then cannot promote it after a failover. Redis accepts several passwords for one ACL
user, so rotate in three passes that overlap the old and the new password. In each pass, make the
change, then commit, merge and reconcile as in step 4, then record the UIDs and restart as in step 5:

| Pass | Change | Restart |
|---|---|---|
| 1 | In `acl-secret.yaml`, give the admin line both passwords: `>OLD >NEW`. Leave `passwords-secret.yaml` unchanged. | replica, then master (step 5) |
| 2 | In `passwords-secret.yaml`, set `admin-password` to NEW | each sentinel (below) |
| 3 | In `acl-secret.yaml`, remove `>OLD` from the admin line | replica, then master (step 5) |

```bash
restart_old redis-sentinel-sentinel-0 && restart_old redis-sentinel-sentinel-1 &&
  restart_old redis-sentinel-sentinel-2 && all_restarted app=redis-sentinel-sentinel
```

---

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

# 5. Commit, merge, reconcile. If merged fails, stop here.
git add infrastructure/configs/databases/redis-ha/passwords-secret.yaml \
        infrastructure/configs/databases/redis-ha/acl-secret.yaml \
        apps/blocky/config-secret.yaml
git commit -m "Rotate blocky redis password"
merged
flux reconcile source git flux-system --timeout 45s
flux reconcile kustomization infrastructure-configs --timeout 60s
flux reconcile kustomization apps --timeout 60s

# 6. Restart the Redis pods: section 2, step 5 (never `rollout restart` them)

# 7. Restart Blocky one pod at a time (2 replicas), then verify
agents/skills/_shared/restart-workload.sh blocky app=blocky
kubectl logs -n blocky -l app=blocky --tail=20 | grep -iE "redis|error"
```

### 3. MySQL Password (Percona)

The Percona operator has no user resource. The app users come from SQL
([`mysql-create-dbs.sql`](disaster-recovery/mysql-create-dbs.sql)), so the password changes with
`ALTER USER` on the primary. Each app keeps its own copy:

| App | MySQL user | SOPS file | Secret | Key the app reads | Where the password sits |
|---|---|---|---|---|---|
| Home Assistant | `homeassistant` | `apps/home-assistant/secrets.yaml` | `home-assistant-secrets` | `secrets.yaml` | the DSN on the `db_url:` line inside key `secrets.yaml`, and the separate `db_url` key |
| Uptime Kuma | `uptimekuma` | `apps/uptime-kuma/mysql-credentials.yaml` | `uptime-kuma-mysql-credentials` | `password` | key `password` |
| PriceBuddy | `pricebuddy` | `apps/pricebuddy/mysql-credentials.yaml` | `pricebuddy-mysql-credentials` | `password` | key `password` |

Home Assistant mounts only the `secrets.yaml` key, as the file `/config/secrets.yaml`. Its
configuration says `db_url: !secret db_url`, which resolves to the DSN on the `db_url:` line of
that file. Nothing in the repo reads the separate `db_url` key; set it to the same DSN so the two
never disagree.

Deploy the new secret first, then change the user, then restart the app. The app then fails only
between the `ALTER USER` and its restart. Rotate one app at a time. Take the variables in step 1
from the table above and from the selector table under ROTATION PROCEDURES.

```bash
# 1. Pick the app and generate the password (hex: safe inside a DSN and a SQL string)
APP_NS=uptime-kuma; APP_SEL=app=uptime-kuma; DB_USER=uptimekuma
SECRET_FILE=apps/uptime-kuma/mysql-credentials.yaml; SECRET_NAME=uptime-kuma-mysql-credentials
READ_KEY=password   # "Key the app reads"; step 3 checks the new password is there
NEW_PASSWORD=$(openssl rand -hex 32)

# 2a. Uptime Kuma, PriceBuddy: bare key. The value goes in on stdin, never on the command line.
printf '"%s"' "$NEW_PASSWORD" | sops set --value-stdin "$SECRET_FILE" '["stringData"]["password"]'
# 2b. Home Assistant: the password sits inside a DSN, so edit both places by hand
printf '%s' "$NEW_PASSWORD" | pbcopy   # macOS; paste it in the editor
sops "$SECRET_FILE"
```

Step 3 is one chain. If a command fails, nothing after it runs. If the live Secret does not hold
the new password, the database does not change. If the `ALTER USER` fails, the app does not
restart.

```bash
# 3. Commit, merge, reconcile; check the live Secret; change the user; restart the app
if git add "$SECRET_FILE" && git commit -m "Rotate $APP_NS MySQL password" && merged &&
   flux reconcile source git flux-system --timeout 45s &&
   flux reconcile kustomization apps --timeout 60s &&
   case "$(kubectl get secret -n "$APP_NS" "$SECRET_NAME" -o json | jq -r --arg k "$READ_KEY" '.data[$k] | @base64d')" in
     *"$NEW_PASSWORD"*) true ;;
     *) echo "the live Secret does not hold the new password yet"; false ;;
   esac &&
   # HAProxy routes the write to the primary. The SQL goes in on stdin, and the root password is
   # read inside the pod from the mounted operator secret, so neither is on a command line.
   printf "ALTER USER '%s'@'%%' IDENTIFIED BY '%s';\n" "$DB_USER" "$NEW_PASSWORD" |
     kubectl exec -i -n databases main-mysql-mysql-0 -c mysql -- sh -c \
     'export MYSQL_PWD="$(cat /etc/mysql/mysql-users-secret/root)"; exec mysql -h main-mysql-haproxy.databases.svc.cluster.local -uroot' &&
   agents/skills/_shared/restart-workload.sh "$APP_NS" "$APP_SEL"; then
  kubectl logs -n "$APP_NS" -l "$APP_SEL" --tail=20 | grep -i "mysql\|database\|error"
else
  echo "STOPPED: the step above failed; nothing after it ran"
fi
```

---

### 4. OIDC Client Secret

```bash
# 1. Generate new OIDC client secret (64-char hex)
NEW_SECRET=$(openssl rand -hex 32)

# 2. Update in Authentik via API. The PATCH runs inside the server pod with Python, because the
#    image has no curl or wget. The provider ID and the secret go in on stdin. The admin token
#    comes from the pod's own environment. Only the HTTP status comes back, so no secret reaches
#    a command line or the screen.
PK=<PROVIDER_PK>   # 1=Grafana, 3=Immich, 5=Paperless, 11=Mealie, 13=Audiobookshelf, 14=HA, 16=Stirling, 48=Linkwarden, 50=Cloudflare Access
# Not rotated: 53=homepage-forward-auth (only Authentik's embedded outpost uses it).
PY='import json,os,sys,urllib.request as u
pk,s=sys.stdin.read().split()
r=u.Request(f"http://localhost:9000/api/v3/providers/oauth2/{pk}/",method="PATCH",
  data=json.dumps({"client_secret":s}).encode(),
  headers={"Authorization":"Bearer "+os.environ["AUTHENTIK_BOOTSTRAP_TOKEN"],"Content-Type":"application/json"})
try: print(u.urlopen(r,timeout=20).status)
except u.HTTPError as e: print(e.code)'
code=$(printf '%s %s' "$PK" "$NEW_SECRET" |
  kubectl exec -i -n authentik deploy/authentik-server -- python3 -c "$PY")
if [ "$code" = 200 ]; then echo "Authentik updated"; else echo "PATCH FAILED (HTTP $code): stop here"; fi

# 3-5. Only if step 2 printed "Authentik updated": write the app-side copy, commit, push,
#      reconcile, restart. Take the values from the table below and the selector table under
#      ROTATION PROCEDURES. For a secret inside a larger value, leave KEY empty: sops then opens
#      the file for a hand edit.
FILE=<file>; KEY=<key>; KS=<kustomization>; NS=<namespace>; SEL=<selector>
if [ "$code" = 200 ] &&
   if [ -n "$KEY" ]; then
     printf '"%s"' "$NEW_SECRET" | sops set --value-stdin "$FILE" "[\"stringData\"][\"$KEY\"]"
   else sops "$FILE"; fi &&
   git add "$FILE" && git commit -m "Rotate $NS OIDC client secret" && merged &&
   flux reconcile source git flux-system --timeout 60s &&
   flux reconcile kustomization "$KS" --timeout 60s &&
   agents/skills/_shared/restart-workload.sh "$NS" "$SEL"; then
  echo "rotated; now test the SSO login"
else
  echo "STOPPED: the step above failed; nothing after it ran"
fi

# 6. Test SSO login
# Visit https://<app>.h0melab.work and test login
```

| App | FILE | KEY | Where the secret sits | KS |
|---|---|---|---|---|
| Grafana | `monitoring/configs/kube-prometheus-stack/grafana-oidc-secret.yaml` | `client-secret` | that key | `monitoring-configs` |
| Mealie | `apps/mealie/mealie-env-secret.yaml` | `OIDC_CLIENT_SECRET` | that key | `apps` |
| Linkwarden | `apps/linkwarden/linkwarden-secret.yaml` | `AUTHENTIK_CLIENT_SECRET` | that key | `apps` |
| Paperless-NGX | `apps/paperless-ngx/paperless-env-secret.yaml` | empty | inside the JSON in key `PAPERLESS_SOCIALACCOUNT_PROVIDERS` | `apps` |
| Stirling PDF | `apps/stirling-pdf/custom-settings-secret.yaml` | empty | inside the YAML in key `custom_settings.yml` | `apps` |
| Home Assistant | `apps/home-assistant/secrets.yaml` | empty | the `oidc_client_secret:` line inside key `secrets.yaml` | `apps` |

Immich, Audiobookshelf and Cloudflare Access do not use steps 3-5. Done 2026-10-02 as follows. For Immich and Audiobookshelf, each update was guarded on the row still holding the old secret, and the app restarted right after the PATCH:

| App | Where the secret sits | How |
|---|---|---|
| Immich | PostgreSQL `immich` db, `system_metadata` row `system-config`, `value->'oauth'->>'clientSecret'` | `UPDATE ... jsonb_set(value, '{oauth,clientSecret}', ...)` on stdin through `agents/skills/db-operations/scripts/pg-primary.sh exec immich -`, then restart immich-server (it caches the config) |
| Audiobookshelf | `/config/absdatabase.sqlite`, `settings` row `server-settings`, JSON field `authOpenIDClientSecret` | no `sqlite3` binary in the image: `node -e` from `/app` with the app's own `sqlite3` module, then restart; the row still held the new value after the restart |
| Cloudflare Access | Zero Trust dashboard: Integrations → Identity providers → Authentik → Client secret | the agent puts a new value on the clipboard (`pbcopy`), opens the edit form and empties the field; the operator pastes and saves (an agent must not type a secret into a web form); the agent PATCHes provider 50; the operator clicks **Test**. On 2026-10-02 a paste into the unemptied field gave `Invalid client secret` in the Authentik log; emptying it first fixed it |

The provider PKs are in the `PK=` comment in step 2. n8n has no provider: its free version has no
OIDC.

---

### 5. User Login Passwords (HomeHub)

#### HomeHub

Secret `homehub-password` (`apps/homehub/secret.yaml`) holds the password in plain text, in key
`password`. The init container copies it into `config.yml`. HomeHub hashes it with SHA-256 when it
loads the file (`app/config.py` in HomeHub v0.2.4). Do not store a bcrypt hash here: HomeHub would
treat the hash string itself as the password.

```bash
# 1. Type the new password; it stays off the screen and off the command line. An empty
#    password, or a failed read, writes nothing.
if IFS= read -rs NEW_PASSWORD && [ -n "$NEW_PASSWORD" ]; then
  printf '%s' "$NEW_PASSWORD" | jq -Rs . | sops set --value-stdin \
    apps/homehub/secret.yaml '["stringData"]["password"]'
else
  echo "STOPPED: empty password or failed read"
fi

# 2. Commit, merge, reconcile, restart. If merged fails, stop here.
git add apps/homehub/secret.yaml
git commit -m "Rotate HomeHub password"
merged
flux reconcile source git flux-system --timeout 45s
flux reconcile kustomization apps --timeout 45s
agents/skills/_shared/restart-workload.sh homehub app=homehub
```

### 6. Cloudflare API token and Telegram bot tokens

The issuer makes the new value, so a person does step 1. `scripts/rotate-token.sh` does the
rest of the edit. It reads the new value from the 1Password item's `credential` field and checks
it with the issuer. Then it writes the value into every SOPS file that holds it, and reads each
one back. It never prints a value, and `--dry-run` writes nothing. Run it from a worktree: it
edits the checkout it lives in.

1. Make the new value, and save it in the item's `credential` field in 1Password:

   | Token | Where | 1Password item |
   |---|---|---|
   | Cloudflare `dns_and_certs` | dashboard → My Profile → API Tokens → ⋯ → Roll | `Cloudflare API for DNS and Certs` |
   | @h0melab_alerts_bot | BotFather → `/mybots` → the bot → API Token → Revoke current token | `TG Monitorings bot token` |
   | @ClaudeSelfHostedBot | same, for that bot | `TG HomelabBot Token` |

   The old value stops working at once, so the consumers fail until Flux applies step 3.
2. Write it into the SOPS files:
   ```bash
   scripts/rotate-token.sh cf "Cloudflare API for DNS and Certs" --dry-run  # then without --dry-run
   scripts/rotate-token.sh tg "TG Monitorings bot token"
   scripts/rotate-token.sh tg "TG HomelabBot Token"
   ```
   For `tg`, the script updates every listed secret whose token has the same bot id (the part
   before `:`), so it finds each file that bot uses.
3. Commit, merge, push, then `flux reconcile source git flux-system` and reconcile
   `infrastructure-controllers`, `infrastructure-configs`, `monitoring-configs` and `apps`.
4. Each consumer picks up the value as follows:

   | Consumer | Reads the token | Action |
   |---|---|---|
   | cert-manager | the Secret, on each certificate request | none |
   | Alertmanager | mounted file `bot_token_file`; the kubelet refreshes it within about 2 min | none |
   | Flux notifications | the Secret, per event | none |
   | backup job | env, at the next run | none |
   | claude-telegram | env `TELEGRAM_BOT_TOKEN`, at start-up | `agents/skills/_shared/restart-workload.sh claude-telegram app=claude-telegram` (Flux reverts `rollout restart`) |
   | node-maintenance notices (alerts bot) | the CP file `/etc/node-maintenance/telegram-token`, on each send | none (below) |

   The node-maintenance files match the Secret without an operator step:

   | Stage | What happens |
   |---|---|
   | every 10-min sync on the CP | `lib/sync-from-git.sh` runs `lib/refresh-telegram-creds.sh`, which copies `bot_token` and `chat_id` from the `backup-telegram` Secret into `/etc/node-maintenance/telegram-token` and `telegram-chat-id`. So the CP files match the Secret within one sync after Flux applies it. |
   | next drift-heal | the `security_scan` role copies both files from the CP to the other nodes. Drift-heal runs at 03:00 and 15:00 UTC, each up to 5 minutes later (`RandomizedDelaySec=300`), and after a sync that applies a new commit. |
   | if the read fails or a value is empty | the refresh keeps both old files, and the sync prints a `WARN` line. It writes the two files only if both values are non-empty. |
   | if a send fails | `telegram-notify.sh` writes `node_maintenance_telegram_notify_success 0`. If the gauge stays 0 for 5 minutes, the `NodeMaintenanceTelegramNotifyFailed` alert fires. |

   To test, wait for the first sync after Flux applies the Secret, which is at most 10 minutes
   later. If you test earlier, the CP file may still hold the revoked token. Then run this on the
   CP and check that the message reaches the chat. The second line is optional: it runs drift-heal
   now, so the `security_scan` role copies the files to the other nodes at once.

   ```bash
   sudo /usr/local/sbin/telegram-notify.sh "token refresh test"
   sudo systemctl start node-maintenance-config.service
   ```

5. Verify. Cloudflare: the script's check shows the token active, and Roll keeps its
   permissions. Certificates that stay `True` in `kubectl get certificates -A` do not test the
   token: cert-manager uses it only when it issues or renews. So after the next renewals, check
   that the earliest expiry moved later, every certificate is still `True`, and
   `kubectl get challenges -A` finds none left:
   ```bash
   kubectl get certificates -A -o json | jq -r '[.items[].status.notAfter] | min'
   ```
   On 2026-09-28 this printed `2026-11-30T20:27:49Z`, with renewals due 2026-10-31. Alerts: fire a test alert
   that expires by itself, and check that Alertmanager's send counter rises while its failure
   counters stay 0. The alert name carries a timestamp: if it matches a recent test alert,
   Alertmanager holds the new one until the group interval passes, and the counter does not move
   within the 40 s:
   ```bash
   kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- sh -c \
     "amtool alert add alertname=TokenRotationTest$(date +%s) severity=warning --end=$(date -u -v+2M +%Y-%m-%dT%H:%M:%SZ) \
      --alertmanager.url=http://localhost:9093; sleep 40; wget -qO- localhost:9093/metrics | grep 'notifications.*telegram'"
   ```
   The bot: `kubectl logs -n claude-telegram deploy/claude-telegram --all-containers | grep 'Bot started'`
   prints `Bot started: @ClaudeSelfHostedBot`.

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
- [x] **2026-09-28: Cloudflare `dns_and_certs` and two Telegram bot tokens rotated** (`52ce08aa`),
  before the repo goes public. A scan of every ref (`gitleaks git --log-opts=--all` on a mirror
  clone) found the Cloudflare and alerts-bot tokens in pre-rewrite commit `7349f6cc`, reachable
  from 18 PR refs. Verified: Cloudflare reports the new token active; a test alert raised
  Alertmanager's Telegram send count from 24 to 25 with 0 failures; claude-telegram restarted and
  logged `Bot started`. The first certificate renewals with the new token are due 2026-10-31.
  The CP began running the node-maintenance fixes (`2a09e2b0`) at 23:11 BST, so the refresh of the
  CP file `/etc/node-maintenance/telegram-token` became automatic. One send with the old token
  failed at 23:11:01. The sync that started in the same second refreshed the file at 23:11:02. One
  send at 23:17:09 succeeded.
- [x] **2026-08-07: claude-telegram bot token rotated after a pod-log leak** (`aac32751`) — failed
  `getUpdates` errors printed the token in the request URL during the morning WAN outage (Loki
  retains 720h). Bot 1.32.0 now redacts secrets from console output, so this leak class is closed
  going forward; token lives in 1Password `TG HomelabBot Token` + `claude-telegram-env-secret.yaml`.
- [x] **2026-07-31: claude-telegram credentials rotated after a transcript leak** — bot token
  (`7300db42`), Claude oauth token and the HTTP trigger secret (`c0301bcb`), and the Codex
  `auth.json` refreshed from the current CLI session (`3c6e26bc`). All three live in
  `claude-telegram-env-secret.yaml` / `claude-telegram-codex-secret.yaml`.
- [x] **2026-08-03: three per-repo GitHub deploy keys added** to `claude-telegram-ssh`
  (`15907135`), replacing the bot's use of the account key for git. `gh-homelab` is write-capable;
  `gh-dotfiles` and `gh-fork` are read-only. `id_ed25519` keeps node SSH only and is now pinned to
  the `agent-diag` forced command (`cb79cdfa`).
- [x] 2026-07-02: Cadence change — 90-day High tier retired, all scheduled rotations now 180-day. Ex-High secrets (PG authentik/immich/n8n, MySQL HA, Redis immich) folded into the 2026-10-01 batch; Redis admin → 2026-10-26.
- [x] **2026-07-26: Alertmanager basicAuth password moved to 1Password** (`alertmanager-homelab`,
  Personal vault) and the `alertmanager-basic-auth-credential` Secret deleted. Done 11 days ahead
  of the 2026-08-06 deadline set on 07-25.
  ```bash
  op read 'op://Personal/alertmanager-homelab/password'
  ```
  Two things to know if this ever needs redoing. The one file
  `monitoring/configs/kube-prometheus-stack/alertmanager-basic-auth-secret.yaml` held **both**
  Secrets, and the surviving one (`alertmanager-basic-auth`, htpasswd `users`) is what Traefik
  reads — deleting the file or its kustomization entry takes Alertmanager's auth down. And both
  documents shared a **single SOPS MAC covering the whole file**, so truncating the second
  document produced `MAC mismatch` on decrypt; the working sequence is `sops -d` → drop the
  document with `yq` → `sops -e`, never a partial edit of the ciphertext.

### 2026 Q4 (Oct-Dec)
- [x] 2026-10-02: 180-day rotation, run end to end by an agent:

  | Batch | Commits |
  |---|---|
  | MySQL: uptime-kuma, pricebuddy, home-assistant | `927b9db3` |
  | PostgreSQL: mealie, linkwarden, paperless, immich, n8n | `fd0048f5` |
  | CouchDB admin, three copies | `f93a6b43` |
  | Redis immich, paperless, blocky, admin (three overlap passes; the 2026-10-26 items done before their date) | `54b00722`, `c7446798`, `1517297a` |
  | Authentik database password and Django secret key | `0dbd6068` |
  | OIDC: grafana, paperless, mealie, home-assistant, stirling-pdf, linkwarden | `617556ce` |
  | OIDC: Immich (`system_metadata` row) and Audiobookshelf (SQLite settings row) | no commit; live database update + Authentik PATCH |
- [x] Cloudflare Access OIDC client secret: operator pasted it in the Zero Trust dashboard, agent PATCHed Authentik provider 50 (2026-10-02)
- [ ] 2026-12-31: `cloudflare-tunnel-mgmt-token`

### 2027 Q1 (Jan-Mar)
- [ ] 2027-01-30: `claude-telegram-ssh` → `gh-homelab` (write deploy key, 180 days)
- [ ] 2027-03-30: `FLUX_UPDATE_TOKEN` (180 days from creation)
- [ ] 2027-03-31: 180-day rotation — every row above that shows 2027-03-31

---

## BEST PRACTICES

1. **Password gen**: cryptographically secure, 32+ chars DB/Redis, 64+ OIDC. Avoid special chars (URL encoding).
2. **Testing**: verify dependent services. Keep prev password 24h for rollback.
3. **Docs**: update this doc + commit immediately after rotation.
4. **Monitoring**: watch auth errors 15 min post-rotation. Check Grafana.
5. **Backup**: check that the secrets backup is current before rotation.

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

**Review Schedule**: Quarterly | **Next Review**: 2027-01-02
