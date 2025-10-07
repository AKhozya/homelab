sudo rsync -av /var/lib/rancher/k3s/storage/ /backup/k3s-storage/
sudo cat /var/lib/rancher/k3s/server/node-token
curl -sfL https://get.k3s.io | sh -

# Homelab Disaster Recovery Guide

This directory contains scripts and documentation for complete cluster recovery.

## ⚠️ IMPORTANT

**Files in `.backup/secrets/` contain UNENCRYPTED credentials!**

- DO NOT commit these files to git
- The `.backup/` directory is already in `.gitignore`
- Store backups securely (password manager, encrypted drive, etc.)

## 📦 Backup Process

### 1. Create Backup (run regularly)

```bash
cd .backup
chmod +x secrets-backup.sh
./secrets-backup.sh
```

This will extract and save:

- Cloudflare tunnel credentials
- Cloudflare API token (for cert-manager)
- Grafana admin credentials
- Telegram bot token
- SOPS age encryption key

Files are saved to `.backup/secrets/`

### 2. Backup Persistent Data

Your application data is stored on cluster nodes. Back it up with:

```bash
# On each node (control-plane and worker)
sudo rsync -av /var/lib/rancher/k3s/storage/ /backup/k3s-storage/
```

Or use your preferred backup solution (Velero, Restic, etc.)

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

#### Step 4: Restore Secrets

```bash
cd .backup
chmod +x secrets-restore.sh
./secrets-restore.sh
```

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

#### Step 7: Restore Persistent Data

```bash
# On each node, restore backed up data
sudo rsync -av /backup/k3s-storage/ /var/lib/rancher/k3s/storage/

# Restart affected pods to pick up data
kubectl rollout restart deployment -n linkding linkding
kubectl rollout restart deployment -n audiobookshelf audiobookshelf
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

### Automatically (via GitOps)
- ✅ All Kubernetes manifests
- ✅ Helm releases
- ✅ Deployments, Services, Ingresses
- ✅ Prometheus alerts and rules
- ✅ Grafana dashboards
- ✅ Loki and Promtail

### Via Backup Scripts
- ✅ Cloudflare credentials
- ✅ TLS certificates (auto-renewed)
- ✅ Grafana admin password
- ✅ Telegram bot token
- ✅ SOPS encryption key

### Manual Steps Required
- ⚠️ Persistent volume data (if not using external backup)
- ⚠️ DNS A records (if changed)
- ⚠️ Cloudflare tunnel configuration (if creating new tunnels)

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
