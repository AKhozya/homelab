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

### 2. Decrypt Backup (when needed for disaster recovery)

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
- 🌐 Cloudflare tunnel credentials

**Monitoring:**
- 📊 Grafana admin credentials
- 📱 Telegram bot token (Alertmanager notifications)

**Databases:**
- 🗄️ Redis passwords (for all apps)
- 🗄️ PostgreSQL admin credentials
- 🗄️ All application database user credentials

**Applications:**
- Authentik (SSO & identity provider)
- Immich (photo management)
- Home Assistant
- N8N (workflow automation)
- Linkding (bookmark manager)
- Mealie (recipe manager)
- Wallabag (read-it-later)
- Paperless-NGX (document management)
- Audiobookshelf
- Uptime Kuma (uptime monitoring)
- CouchDB (Obsidian sync)

Files are saved to `.backup/secrets/` (gitignored)

### 2. Automated Backups (Already Configured ✅)

**Your cluster has automated daily backups configured:**

- **PostgreSQL databases:** Daily at 2:00 AM → `/mnt/k8s-storage/backups/postgres/` (30 days retention)
- **CouchDB databases:** Daily at 2:30 AM → `/mnt/k8s-storage/backups/couchdb/` (30 days retention)
- **Critical PVCs:** Daily at 3:00 AM → `/mnt/k8s-storage/backups/pvc/` (3 days retention)

**Backup details in:** `docs/BACKUP_STRATEGY.md` and `docs/BACKUP_IMPLEMENTATION.md`

**No manual action required** - backups run automatically via Kubernetes CronJobs

## 🔄 Recovery Process

### Quick Recovery (2 commands)

If you have:

1. Fresh K3s cluster
2. Flux already bootstrapped
3. Backup files in `.backup/secrets/`

```bash
cd .backup
chmod +x disaster-recovery.sh
./disaster-recovery.sh
```

### Full Recovery (from scratch)

#### Step 1: Create Fresh K3s Cluster

**On control-plane node (192.168.1.127):**

```bash
curl -sfL https://get.k3s.io | sh -
sudo cat /var/lib/rancher/k3s/server/node-token
```

**On worker node (192.168.1.129):**

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

**On both nodes:**

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
```

This will restore ALL secrets needed for cluster operation to their respective namespaces.

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

#### Step 7: Restore Databases and PVCs from Automated Backups

**See detailed procedures in:** `docs/BACKUP_STRATEGY.md`

**PostgreSQL restore:**
```bash
# Find latest backup
LATEST_BACKUP=$(ls -t /mnt/k8s-storage/backups/postgres/postgres_*.tar.gz | head -1)

# Extract
tar -xzf $LATEST_BACKUP -C /tmp

# Restore each database
for DB in authentik immich paperless grafana linkding mealie wallabag audiobookshelf n8n app; do
  kubectl exec -n databases main-postgres-1 -- \
    pg_restore -U postgres -d $DB -c --if-exists \
    /tmp/$(basename $LATEST_BACKUP .tar.gz)/${DB}.dump
done
```

**PVC restore:**
```bash
# Find latest PVC backup
LATEST_PVC=$(ls -td /mnt/k8s-storage/backups/pvc/* | head -1)

# For each critical application (stop, restore, start)
kubectl scale deployment/home-assistant -n home-assistant --replicas=0
tar -xzf $LATEST_PVC/home-assistant/home-assistant-data-pvc.tar.gz \
  -C /mnt/k8s-storage/pvc-XXXXX/
kubectl scale deployment/home-assistant -n home-assistant --replicas=1

# Repeat for: immich, paperless-ngx, couchdb, audiobookshelf
```

**CouchDB restore:**
```bash
# Find latest backup
LATEST_COUCHDB=$(ls -t /mnt/k8s-storage/backups/couchdb/couchdb_*.tar.gz | head -1)

# Extract and restore
tar -xzf $LATEST_COUCHDB -C /tmp
cat /tmp/*/obsidian-personal.couchbackup | \
  kubectl exec -i -n couchdb couchdb-couchdb-0 -- \
  couchrestore --url http://admin:PASSWORD@localhost:5984 --db obsidian-personal
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
# - https://linkding.h0melab.work
# - https://audiobookshelf.h0melab.work
```

## 📋 What Gets Restored

### Automatically (via GitOps after Flux bootstrap)
- ✅ All Kubernetes manifests (deployments, services, ingresses)
- ✅ All Helm releases (monitoring, databases, applications)
- ✅ NetworkPolicies, RBAC, ConfigMaps
- ✅ Prometheus alerts and recording rules
- ✅ Grafana dashboards (via ConfigMaps)
- ✅ Loki and Promtail log aggregation

### Via Backup Scripts (run BEFORE Flux bootstrap)
- ✅ **SOPS age encryption key** (CRITICAL - enables Flux to decrypt secrets)
- ✅ **All application secrets** (user credentials, API keys, env vars)
- ✅ **All OIDC integration secrets** (Authentik SSO for 8 applications)
- ✅ **Database credentials** (Redis, PostgreSQL users)
- ✅ **Infrastructure secrets** (Cloudflare tokens, tunnel credentials)
- ✅ **Monitoring credentials** (Grafana admin, Telegram bot)

### Via Automated Backups (restore from `/mnt/k8s-storage/backups/`)
- ✅ **PostgreSQL databases** - all 10 databases backed up daily (authentik, immich, paperless, etc.)
- ✅ **CouchDB databases** - obsidian-personal backed up daily
- ✅ **Critical PVCs** - Home Assistant, Immich library, Paperless, CouchDB storage, Audiobookshelf
- ⚠️ Use restore procedures in `docs/BACKUP_STRATEGY.md`

### Manual Steps Required (one-time setup)
- ⚠️ **DNS A records** - only if node IPs changed:
  - `*.h0melab.work` records pointing to node IPs
- ⚠️ **Firewall rules** on both nodes:
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
