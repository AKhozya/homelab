# Homelab Disaster Recovery Guide

Scripts + docs for complete cluster recovery.

## WARNING IMPORTANT

**All secrets backups ENCRYPTED with GPG AES256!**

- **Encrypted:** all backups auto GPG-encrypted
- **Secure:** unencrypted secrets dir removed after encryption
- **Gitignored:** `.backup/` in `.gitignore`
- **No Default:** no default passphrase — MUST set own
- **Passphrase:** store in 1Password securely!

## Backup Process

### 1. Create Encrypted Backup (run monthly)

```bash
cd .backup
chmod +x secrets-backup.sh
./secrets-backup.sh

# Script prompts for passphrase interactively
# Or set env var to skip prompt:
# export GPG_PASSPHRASE='your-very-secure-passphrase'

# WARNING: Store passphrase in 1Password — need to decrypt!
```

**Output:** `secrets-backup-YYYYMMDD_HHMMSS.tar.gz.gpg` (encrypted archive)

### 2. Decrypt Backup (optional — auto during restore)

**Note:** `secrets-restore.sh` auto-decrypts, manual decrypt rarely needed.

For manual inspection:

```bash
# Interactive (prompts for passphrase)
gpg --decrypt secrets-backup-20251030_120000.tar.gz.gpg | tar -xzf - -C .

# Non-interactive (env var)
export GPG_PASSPHRASE='your-passphrase'
gpg --decrypt --batch --passphrase-file <(echo "$GPG_PASSPHRASE") \
  secrets-backup-20251030_120000.tar.gz.gpg | tar -xzf - -C .
```

Extracts to `secrets/` dir with all secret JSON files.

Extracts **ALL** secrets needed for complete cluster rebuild:

**Critical Infrastructure:**
- SOPS age encryption key (MOST IMPORTANT — decrypts everything)
- Cloudflare API token (cert-manager DNS-01)
- Cloudflare tunnel credentials + config

**Monitoring:**
- Grafana admin creds
- Alertmanager Telegram bot token

**Databases:**
- Redis passwords (all apps)
- PostgreSQL admin creds + all app DB users
- MySQL cluster secrets + app creds (Uptime Kuma, PriceBuddy)

**Applications:**
- Authentik (SSO + identity)
- Immich (photos)
- Home Assistant
- N8N (workflow automation)
- LinkWarden (bookmarks + read-later)
- Mealie (recipes)
- Paperless-NGX (docs)
- Audiobookshelf
- Uptime Kuma
- Stirling PDF (PDF toolkit)
- HomeHub (family dashboard)
- PriceBuddy (price tracking)
- CouchDB (Obsidian sync)

**Backup Replication:**
- SSH key for worker-node-2 sync
- NAS rsync creds (rsync daemon auth)
- Telegram bot token (backup failure notifications)

Files saved to `.backup/secrets/` (gitignored)

### 3. Automated Backups (Already Configured)

**Daily backups auto-configured:**

- **PostgreSQL:** Daily 3:00 AM → `/mnt/k8s-storage/backups/postgres/` (30 day retention)
- **CouchDB:** Daily 3:05 AM → `/mnt/k8s-storage/backups/couchdb/` (30 day retention)
- **MySQL:** Daily 3:15 AM → `/mnt/k8s-storage/backups/mysql/` (30 day retention)
- **Critical PVCs:** Daily 3:10 AM → `/mnt/k8s-storage/backups/pvc/` (30 day retention, bumped from 7d on 2026-05-22)
- **Immich library:** Weekly Sunday 3:00 AM → `/mnt/k8s-storage/backups/immich/` (keep-2 retention, ~63G uncompressed tar+sha)
- **Backup Replication:** Daily 3:30 AM → NAS (30d daily / keep-2 immich, Step 5b prune) + worker-node-2 (today only via `--delete`)

**Details:** `docs/BACKUP_STRATEGY.md`

**No manual action required** — runs via K8s CronJobs

## Recovery Process

### Full Recovery (from scratch)

#### Step 1: Create Fresh K3s Cluster

**On control-plane node (192.168.1.127):**

```bash
curl -sfL https://get.k3s.io | sh -
sudo cat /var/lib/rancher/k3s/server/node-token
```

**On worker-node (192.168.1.129):**

```bash
export K3S_URL=https://192.168.1.127:6443
export K3S_TOKEN=<token-from-control-plane>
curl -sfL https://get.k3s.io | sh -
```

**On worker-node-2 (192.168.1.126):**

```bash
export K3S_URL=https://192.168.1.127:6443
export K3S_TOKEN=<token-from-control-plane>
curl -sfL https://get.k3s.io | sh -
```

**Get kubeconfig:**

```bash
# On control-plane
sudo cat /etc/rancher/k3s/k3s.yaml
# Copy to local at ~/.kube/config
# Update server IP to 192.168.1.127
```

#### Step 2: Configure Firewall

**On all 3 nodes:**

```bash
sudo ufw allow from 192.168.1.0/24
```

#### Step 3: Install Flux CLI

```bash
brew install fluxcd/tap/flux  # macOS
```

#### Step 4: Restore ALL Secrets

**WARNING: Run BEFORE bootstrapping Flux!**

```bash
cd .backup
chmod +x secrets-restore.sh
./secrets-restore.sh

# Script will:
# 1. Auto-find latest encrypted backup
# 2. Prompt for passphrase to decrypt
# 3. Restore all secrets to respective namespaces
#
# Set GPG_PASSPHRASE env var to skip prompt
```

Auto-decrypts backup + restores ALL secrets needed for cluster ops.

#### Step 5: Bootstrap Flux

```bash
flux bootstrap github \
  --owner=AKhozya \
  --repository=homelab \
  --path=clusters/staging \
  --personal
```

#### Step 6: Wait for Reconciliation

```bash
# Watch deploy
watch kubectl get pods -A

# Flux status
flux get kustomizations -A
kubectl get helmrelease -A
```

#### Step 7: Restore Databases from Backups

Backups from 3 sources (preference order):
1. **NAS** (192.168.1.136) — full history, rsync daemon port 50555
2. **worker-node-2** (192.168.1.126) — latest only, `/mnt/extra-storage/backups/`
3. **worker-node** (192.168.1.129) — source cleaned daily, may be empty

**Copy backups from NAS to worker-node:**
```bash
# Get NAS creds from restored secrets or 1Password
export RSYNC_PASSWORD='<nas-rsync-password>'
rsync -avz --port=50555 \
  rsync://akhozya@192.168.1.136/akhozya/backups/homelab/ \
  /mnt/k8s-storage/backups/
```

**Or copy from worker-node-2:**
```bash
rsync -avz -e "ssh -p 65300" \
  z3us@192.168.1.126:/mnt/extra-storage/backups/ \
  /mnt/k8s-storage/backups/
```

**PostgreSQL restore:**
```bash
# Find latest backup
LATEST_BACKUP=$(ls -t /mnt/k8s-storage/backups/postgres/postgres_*.tar.gz | head -1)

# Verify integrity
sha256sum -c ${LATEST_BACKUP}.sha256

# Extract
tar -xzf $LATEST_BACKUP -C /tmp

# Restore each DB
for DB in authentik immich paperless grafana linkwarden mealie audiobookshelf n8n app; do
  echo "Restoring $DB..."
  kubectl exec -n databases main-postgres-1 -- \
    pg_restore -U postgres -d $DB -c --if-exists \
    /tmp/$(basename $LATEST_BACKUP .tar.gz)/${DB}.dump
done
```

**MySQL restore:**
```bash
# Find latest backup
LATEST_MYSQL=$(ls -t /mnt/k8s-storage/backups/mysql/mysql_*.tar.gz | head -1)

# Verify integrity
sha256sum -c ${LATEST_MYSQL}.sha256

# Extract
tar -xzf $LATEST_MYSQL -C /tmp

# Get root password
MYSQL_ROOT_PWD=$(kubectl get secret -n databases mysql-cluster-secrets -o jsonpath='{.data.root}' | base64 -d)

# Restore each DB
for DB in homeassistant uptimekuma pricebuddy; do
  echo "Restoring $DB..."
  kubectl exec -n databases main-mysql-mysql-0 -- \
    mysql -uroot -p${MYSQL_ROOT_PWD} $DB < /tmp/*/mysql_${DB}.sql
done
```

**CouchDB restore:**
```bash
# Find latest backup
LATEST_COUCHDB=$(ls -t /mnt/k8s-storage/backups/couchdb/couchdb_*.tar.gz | head -1)

# Verify integrity
sha256sum -c ${LATEST_COUCHDB}.sha256

# Extract + restore
tar -xzf $LATEST_COUCHDB -C /tmp
cat /tmp/*/obsidian-personal.couchbackup | \
  kubectl exec -i -n databases couchdb-couchdb-0 -- \
  couchrestore --url http://admin:PASSWORD@localhost:5984 --db obsidian-personal
```

**PVC restore:**
```bash
# Find latest PVC backup
LATEST_PVC=$(ls -td /mnt/k8s-storage/backups/pvc/* | head -1)

# For each critical PVC (stop, restore, start):
kubectl scale deployment/home-assistant -n home-assistant --replicas=0
tar -xzf $LATEST_PVC/home-assistant/home-assistant-data-pvc.tar.gz \
  -C /mnt/k8s-storage/pvc-XXXXX/
kubectl scale deployment/home-assistant -n home-assistant --replicas=1

# Repeat: paperless-ngx, audiobookshelf
# Note: Immich photos excluded from PVC backups (re-upload from source)
```

#### Step 8: Verify Applications

```bash
# All pods running
kubectl get pods -A

# Test apps
curl -I https://authentik.h0melab.work
curl -I https://grafana.h0melab.work
curl -I https://immich.h0melab.work

# Test OIDC login on all apps
```

## Configuration Rollback (Git Tags)

Distinct from data restore above: when a GitOps change (not a data loss) breaks the
cluster, roll the **config** back to a known-good commit. Signed annotated tags are
created before any multi-commit infra/security wave (`pre-<wave>-<date>`) and serve as
DR handles — they survive many subsequent commits.

**Known DR handles:**

| Tag | Baseline |
|---|---|
| `pre-ultrareview-2026-05-23` | Pre-ultrareview state — last known-good before the multi-wave hardening (Kyverno Enforce, HelmRelease drift, CSP, priority classes). Primary config-rollback handle. |
| `pre-w7-2026-05-24` | Before CI gates (validate.yaml). |
| `pre-w8-2026-05-24` | Before Wave 8 Kyverno Audit→Enforce promotion. |

```bash
# Inspect a handle
git show pre-ultrareview-2026-05-23 --stat

# Roll config back (only if no downstream collaborator commits since the tag)
git reset --hard pre-ultrareview-2026-05-23
git push --force-with-lease origin main
# Flux reconciles the reverted manifests within 60s (or force: fr)
```

Create a new handle before the next wave:

```bash
git tag -a pre-<wave>-$(date +%Y-%m-%d) -m "Pre-wave baseline before <description>"
git push origin pre-<wave>-$(date +%Y-%m-%d)
# NOTE: must be annotated (-a) — lightweight tags fail under [tag] gpgsign = true
```

## Verification

After recovery, verify:

```bash
# All resources
kubectl get all -A

# Flux
kubectl get kustomization -A
kubectl get helmrelease -A

# Certificates
kubectl get certificate -A

# Ingresses
kubectl get ingress -A

# Access URLs
# - https://grafana.h0melab.work
# - https://am.h0melab.work
# - https://authentik.h0melab.work
# - https://immich.h0melab.work
# - https://linkwarden.h0melab.work
# - https://paperless.h0melab.work
# - https://n8n.h0melab.work
```

## What Gets Restored

### Automatically (via GitOps after Flux bootstrap)
- All K8s manifests (deployments, services, ingresses)
- All Helm releases (monitoring, databases, apps)
- NetworkPolicies, RBAC, ConfigMaps
- VMAlert rules (VMRules)
- Grafana dashboards (via ConfigMaps)
- Loki + Alloy log aggregation

### Via Backup Scripts (run BEFORE Flux bootstrap)
- **SOPS age encryption key** (CRITICAL — enables Flux to decrypt secrets)
- **All application secrets** (creds, API keys, env vars)
- **All OIDC integration secrets** (Authentik SSO for 8 apps)
- **Database credentials** (Redis, PostgreSQL users, MySQL cluster + app users)
- **Infrastructure secrets** (Cloudflare tokens, tunnel creds)
- **Monitoring credentials** (Grafana admin, Telegram bot)
- **Backup replication credentials** (SSH key, NAS rsync creds, Telegram)

### Via Automated Backups (restore from NAS or worker-node-2)
- **PostgreSQL databases** — all app DBs backed up daily
- **MySQL databases** — homeassistant, uptimekuma, pricebuddy backed up daily
- **CouchDB databases** — obsidian-personal backed up daily
- **Critical PVCs** — HA, Paperless, Audiobookshelf
- Use restore procedures in `docs/BACKUP_STRATEGY.md`

### Manual Steps Required (one-time)
- **DNS A records** — only if node IPs changed:
  - `*.h0melab.work` records → node IPs
- **Firewall rules** on all 3 nodes:
  - `sudo ufw allow from 192.168.1.0/24`

## Security Best Practices

1. **Encrypt backups:** encrypted storage for `.backup/secrets/`
2. **Rotate creds:** after recovery, rotate sensitive tokens
3. **Test recovery:** regular test in staging
4. **Document changes:** update guide when adding secrets/services
5. **Offline copy:** backup scripts + secrets offline (USB, password manager)

## Support

Issues:
1. Flux events: `flux events`
2. Pod logs: `kubectl logs -n <namespace> <pod>`
3. Secrets exist: `kubectl get secrets -A`
4. Reconciliation: `flux get kustomizations -A`
