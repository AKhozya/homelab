# 🚨 Quick Disaster Recovery Reference

## Files Created (LOCAL ONLY - Not in Git)

All sensitive data is stored locally in `.backup/` directory:

```
.backup/
├── secrets/                    # ⛔ NEVER COMMIT - Contains unencrypted secrets
│   ├── age.agekey             # SOPS encryption key
│   ├── cloudflare-api-token.txt
│   ├── telegram-bot-token.txt
│   ├── grafana-admin-password.txt
│   ├── *.json                 # Full K8s secret manifests
│   └── ...
├── ENV_VARS.md                # ⛔ NEVER COMMIT - All your actual values
└── (scripts are in git) ✅
```

## 🔐 Your Actual Secrets (Backed Up Locally)

Location: `.backup/ENV_VARS.md` and `.backup/secrets/`

These files contain:
- Cloudflare API token: `SWYqwj-HuS0Yj0hOF8hf0HKyDg2U8zgtq_icYFqf`
- Telegram bot token: `8199025855:AAHueh5u9IBGNi4LXmSasC7UVFX2NXT41eM`
- Telegram chat ID: `113452686`
- Age encryption key
- Cloudflare tunnel credentials
- Grafana admin password

**IMPORTANT:** These are gitignored - keep them safe!

## 🔄 Disaster Recovery - 2 Commands

If you lose your cluster completely:

### Option 1: You have Flux already bootstrapped

```bash
cd .backup
./disaster-recovery.sh
```

### Option 2: Fresh cluster from scratch

```bash
# 1. Create K3s cluster
# 2. Restore secrets
cd .backup
./secrets-restore.sh

# 3. Bootstrap Flux
flux bootstrap github \
  --owner=AKhozya \
  --repository=homelab \
  --path=clusters/staging \
  --personal
```

## 📦 Keep Backups Updated

Run this regularly (monthly or after adding new secrets):

```bash
cd .backup
./secrets-backup.sh
```

## 💾 Additional Backups Needed

The scripts backup **secrets** but not **data**. Also backup:

1. **Persistent Volume data** on each node:
   ```bash
   sudo rsync -av /var/lib/rancher/k3s/storage/ /backup/k3s-pv/
   ```

2. **This directory** (`.backup/`):
   - Copy to USB drive
   - Store in password manager
   - Keep encrypted backup offsite

## 🔒 Security Checklist

- ✅ `.backup/secrets/` is gitignored
- ✅ `.backup/ENV_VARS.md` is gitignored
- ✅ Only template and scripts are in git
- ✅ GitHub repo does NOT contain secrets

**Never run:** `git add .backup/` (will try to add secrets)
**Always run:** `git add .backup/*.sh .backup/*.md` (specific files only)

## 🌐 Access URLs (After Recovery)

- Grafana: https://grafana.h0melab.work
- Alertmanager: https://am.h0melab.work
- Linkding: https://linkding.h0melab.work (via Cloudflare Tunnel)
- Audiobookshelf: https://audiobookshelf.h0melab.work (via Cloudflare Tunnel)

## 📝 Node Information

- Control plane: `192.168.1.127` (gmk-k3s-control-plane)
- Worker: `192.168.1.129` (worker-node)
- Firewall: `sudo ufw allow from 192.168.1.0/24` (on both nodes)
