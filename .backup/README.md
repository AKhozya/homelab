# Homelab Disaster Recovery Guide

This directory contains scripts and documentation for complete cluster recovery.

## ⚠️ IMPORTANT

**All secrets backups are now ENCRYPTED with GPG AES256!**

- ✅ **Encrypted**: All backups are automatically encrypted using GPG
- ✅ **Secure**: Unencrypted secrets directory removed after encryption
- ✅ **Gitignored**: `.backup/` directory is in `.gitignore`
- ✅ **No Default**: No default passphrase - you MUST set your own
- ⚠️ **Passphrase**: Store GPG passphrase securely in 1Password!

## 📦 Backup Process

### 1. Create Encrypted Backup (run regularly - monthly recommended)

```bash
cd .backup
chmod +x secrets-backup.sh
./secrets-backup.sh

# The script will prompt you to enter a passphrase interactively
# You can also set it as an environment variable to avoid the prompt:
# export GPG_PASSPHRASE='your-very-secure-passphrase'

# ⚠️ Store this passphrase securely in 1Password - you'll need it to decrypt!
```

**Output**: `secrets-backup-YYYYMMDD_HHMMSS.tar.gz.gpg` (encrypted archive)

### 2. Decrypt Backup (optional - automatic during restore)

**Note:** The `secrets-restore.sh` script automatically decrypts backups, so manual decryption is usually not needed.

If you need to decrypt manually for inspection:

```bash
# Interactive (will prompt for passphrase)
gpg --decrypt secrets-backup-20251030_120000.tar.gz.gpg | tar -xzf - -C .

# Non-interactive (using environment variable)
export GPG_PASSPHRASE='your-passphrase'
gpg --decrypt --batch --passphrase-file <(echo "$GPG_PASSPHRASE") \
  secrets-backup-20251030_120000.tar.gz.gpg | tar -xzf - -C .
```

This extracts to `secrets/` directory containing all secret JSON files.

This will extract and save **ALL** secrets needed for complete cluster rebuild:

**Critical Infrastructure:**
- 🔑 SOPS age encryption key (MOST IMPORTANT - needed to decrypt everything)
- 🌐 Cloudflare API token (for cert-manager DNS-01 challenges)
- 🌐 Cloudflare tunnel credentials + tunnel config

**Monitoring:**
- 📊 Grafana admin credentials
- 📱 Alertmanager Telegram bot token

**Databases:**
- 🗄️ Redis passwords (for all apps)
- 🗄️ PostgreSQL admin credentials + all app database users
- 🗄️ MySQL cluster secrets + app credentials (Uptime Kuma, PriceBuddy)

**Applications:**
- Authentik (SSO & identity provider)
- Immich (photo management)
- Home Assistant
- N8N (workflow automation)
- LinkWarden (bookmark + read-it-later manager)
- Mealie (recipe manager)
- Paperless-NGX (document management)
- Audiobookshelf
- Uptime Kuma (uptime monitoring)
- Stirling PDF (PDF toolkit)
- HomeHub (family dashboard)
- PriceBuddy (price tracking)
- CouchDB (Obsidian sync)

**Backup Replication:**
- 🔑 SSH key for worker-node-2 sync
- 🔑 NAS rsync credentials (rsync daemon auth)
- 📱 Telegram bot token (backup failure notifications)

Files are saved to `.backup/secrets/` (gitignored)

### 3. Automated Backups (Already Configured ✅)

**Your cluster has automated daily backups configured:**

- **PostgreSQL databases:** Daily at 3:00 AM → `/mnt/k8s-storage/backups/postgres/` (30 days retention)
- **CouchDB databases:** Daily at 3:05 AM → `/mnt/k8s-storage/backups/couchdb/` (30 days retention)
- **MySQL databases:** Daily at 3:15 AM → `/mnt/k8s-storage/backups/mysql/` (30 days retention)
- **Critical PVCs:** Daily at 3:10 AM → `/mnt/k8s-storage/backups/pvc/` (7 days retention)
- **Backup Replication:** Daily at 3:30 AM → NAS (full history) + worker-node-2 (today only)

**Backup details in:** `docs/BACKUP_STRATEGY.md`

**No manual action required** - backups run automatically via Kubernetes CronJobs

## 🔄 Recovery Process

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
# Copy to your local machine at ~/.kube/config
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

**IMPORTANT: Run this BEFORE bootstrapping Flux!**

```bash
cd .backup
chmod +x secrets-restore.sh
./secrets-restore.sh

# The script will:
# 1. Automatically find the latest encrypted backup
# 2. Prompt you for the passphrase to decrypt it
# 3. Restore all secrets to their respective namespaces
#
# You can also set GPG_PASSPHRASE environment variable to avoid the prompt
```

This will automatically decrypt the backup and restore ALL secrets needed for cluster operation.

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
# Watch resources deploy
watch kubectl get pods -A

# Check Flux status
flux get kustomizations -A
kubectl get helmrelease -A
```

#### Step 7: Restore Databases from Backups

Backups are available from 3 sources (in order of preference):
1. **NAS** (192.168.1.136) - Full backup history, rsync daemon on port 50555
2. **worker-node-2** (192.168.1.126) - Latest backup only, at `/mnt/extra-storage/backups/`
3. **worker-node** (192.168.1.129) - Source cleaned daily, may be empty

**Copy backups from NAS to worker-node:**
```bash
# Get NAS credentials from restored secrets or 1Password
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

# Restore each database
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

# Restore each database
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

# Extract and restore
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

# Repeat for: paperless-ngx, audiobookshelf
# Note: Immich photos excluded from PVC backups (can re-upload from source devices)
```

#### Step 8: Verify Applications

```bash
# Check all pods are running
kubectl get pods -A

# Test applications
curl -I https://authentik.h0melab.work
curl -I https://grafana.h0melab.work
curl -I https://immich.h0melab.work

# Test OIDC login on all apps
```

## 🔍 Verification

After recovery, verify everything is working:

```bash
# Check all resources
kubectl get all -A

# Check Flux
kubectl get kustomization -A
kubectl get helmrelease -A

# Check certificates
kubectl get certificate -A

# Check ingresses
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

## 📋 What Gets Restored

### Automatically (via GitOps after Flux bootstrap)
- ✅ All Kubernetes manifests (deployments, services, ingresses)
- ✅ All Helm releases (monitoring, databases, applications)
- ✅ NetworkPolicies, RBAC, ConfigMaps
- ✅ VMAlert rules (VMRules) for alerting
- ✅ Grafana dashboards (via ConfigMaps)
- ✅ Loki and Alloy log aggregation

### Via Backup Scripts (run BEFORE Flux bootstrap)
- ✅ **SOPS age encryption key** (CRITICAL - enables Flux to decrypt secrets)
- ✅ **All application secrets** (user credentials, API keys, env vars)
- ✅ **All OIDC integration secrets** (Authentik SSO for 8 applications)
- ✅ **Database credentials** (Redis, PostgreSQL users, MySQL cluster + app users)
- ✅ **Infrastructure secrets** (Cloudflare tokens, tunnel credentials)
- ✅ **Monitoring credentials** (Grafana admin, Telegram bot)
- ✅ **Backup replication credentials** (SSH key, NAS rsync credentials, Telegram)

### Via Automated Backups (restore from NAS or worker-node-2)
- ✅ **PostgreSQL databases** - all app databases backed up daily
- ✅ **MySQL databases** - homeassistant, uptimekuma, pricebuddy backed up daily
- ✅ **CouchDB databases** - obsidian-personal backed up daily
- ✅ **Critical PVCs** - Home Assistant, Paperless, Audiobookshelf
- ⚠️ Use restore procedures in `docs/BACKUP_STRATEGY.md`

### Manual Steps Required (one-time setup)
- ⚠️ **DNS A records** - only if node IPs changed:
  - `*.h0melab.work` records pointing to node IPs
- ⚠️ **Firewall rules** on all 3 nodes:
  - `sudo ufw allow from 192.168.1.0/24`

## 🔐 Security Best Practices

1. **Encrypt backups**: Use encrypted storage for `.backup/secrets/`
2. **Rotate credentials**: After recovery, consider rotating sensitive tokens
3. **Test recovery**: Regularly test the recovery process in a staging environment
4. **Document changes**: Update this guide when adding new secrets/services
5. **Keep offline copy**: Store backup scripts and secrets offline (USB drive, password manager)

## 📞 Support

If you encounter issues:
1. Check Flux events: `flux events`
2. Check pod logs: `kubectl logs -n <namespace> <pod>`
3. Verify secrets exist: `kubectl get secrets -A`
4. Check reconciliation: `flux get kustomizations -A`
