# Secret Storage Best Practices

## 🎯 Recommended Storage Strategy (3-2-1 Rule)

**3 copies** of your data, on **2 different media types**, with **1 copy off-site**

### Current Setup
- ✅ **Working Copy**: `.backup/` directory on your Mac
- ✅ **Git (scripts only)**: Disaster recovery scripts committed (secrets gitignored)

### What You Should Add

#### 1. 🔐 Password Manager (Primary - Do This First!)
**Best choice: 1Password, Bitwarden, or KeePassXC**

Store as secure notes:
- `ENV_VARS.md` - All your tokens and credentials
- `age.agekey` - SOPS encryption key (as attachment)
- Cloudflare tunnel credentials
- Grafana admin password

**Why:** 
- ✅ Encrypted end-to-end
- ✅ Synced across devices
- ✅ Easy access when needed
- ✅ Can share with team if needed

#### 2. 💾 Encrypted USB Drive (Offline Backup)
**Best choice: VeraCrypt container or hardware-encrypted USB**

```bash
# Monthly: Copy to encrypted USB
cp -r .backup/ /Volumes/EncryptedUSB/homelab-$(date +%Y%m%d)/
```

**Why:**
- ✅ Air-gapped (survives cloud hacks)
- ✅ Survives laptop failure
- ✅ Can store in safe/bank vault

#### 3. ☁️ Cloud Storage (Off-site Redundant)
**Best choice: Encrypted archive to Google Drive/Dropbox/S3**

```bash
# Use the backup-all.sh script created above
chmod +x .backup/backup-all.sh

# Set encryption passphrase
echo "your-strong-passphrase" > ~/.homelab-backup-passphrase
chmod 600 ~/.homelab-backup-passphrase

# Run backup (creates encrypted .tar.gz.gpg)
./.backup/backup-all.sh
```

**Why:**
- ✅ Off-site (survives house fire/theft)
- ✅ Can automate
- ✅ Free tier available (Google Drive 15GB)

## 🚀 Quick Setup Guide

### Step 1: Password Manager (5 minutes)
```bash
# Copy content to clipboard for password manager
cat .backup/ENV_VARS.md | pbcopy

# Then create a "Secure Note" in 1Password/Bitwarden
# Title: "Homelab Secrets"
# Paste the content
# Attach: .backup/secrets/age.agekey
```

### Step 2: Encrypted USB (10 minutes)
```bash
# Option A: VeraCrypt (most secure)
# 1. Download VeraCrypt: https://www.veracrypt.fr/
# 2. Create encrypted volume on USB
# 3. Mount it
# 4. Copy: cp -r .backup/ /Volumes/VeraCrypt1/homelab-backup/

# Option B: Simple (macOS encrypted disk image)
# 1. Plug in USB drive
# 2. Disk Utility > File > New Image > from Folder
# 3. Select .backup folder
# 4. Encryption: AES-256
# 5. Save to USB drive
```

### Step 3: Cloud Backup (Automated)
```bash
# 1. Set up passphrase
echo "ChooseAStrongPassphrase123!" > ~/.homelab-backup-passphrase
chmod 600 ~/.homelab-backup-passphrase

# 2. Make script executable
chmod +x .backup/backup-all.sh

# 3. Run backup
./.backup/backup-all.sh

# 4. Upload the .tar.gz.gpg file to Google Drive/Dropbox
# Or configure rclone in the script for automation
```

### Step 4: Schedule Regular Backups
```bash
# Add to crontab for monthly backups
# Run: crontab -e
# Add line:
0 0 1 * * /Users/akhozya/source-code/homelab/.backup/backup-all.sh
```

## 🔓 How to Restore from Backup

### From Password Manager
1. Open secure note "Homelab Secrets"
2. Copy ENV_VARS.md content
3. Download age.agekey attachment
4. Place in `.backup/` directory

### From Encrypted USB
```bash
cp -r /Volumes/EncryptedUSB/homelab-backup/ ~/restore/
cd ~/restore
./secrets-restore.sh
```

### From Cloud (Encrypted Archive)
```bash
# Download homelab-secrets-YYYYMMDD.tar.gz.gpg
gpg -d homelab-secrets-20251007.tar.gz.gpg | tar xzf -
cd .backup
./secrets-restore.sh
```

## ⚠️ Security Warnings

### ❌ DO NOT:
- Store secrets in public GitHub repos
- Email secrets to yourself
- Store in plain text on cloud
- Keep only one copy
- Store USB drive next to your cluster

### ✅ DO:
- Use password manager as primary storage
- Keep offline backup (USB) off-site
- Encrypt everything before cloud upload
- Test restore process quarterly
- Update backups after adding new secrets

## 📅 Maintenance Schedule

- **Weekly**: Run `backup-all.sh` (automated)
- **Monthly**: Copy to USB drive
- **Quarterly**: Test full disaster recovery
- **Yearly**: Rotate encryption keys, update passwords

## 🛠️ Tools You'll Need

1. **Password Manager**: 1Password ($3/mo), Bitwarden (free), or KeePassXC (free)
2. **Encryption**: GPG (built-in macOS), or VeraCrypt (USB encryption)
3. **Cloud Sync** (optional): rclone (free, supports all clouds)

## 📊 Storage Comparison

| Location | Security | Accessibility | Off-site | Cost | Setup Time |
|----------|----------|---------------|----------|------|------------|
| Password Manager | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ✅ | $3-10/mo | 5 min |
| Encrypted USB | ⭐⭐⭐⭐ | ⭐⭐ | ❌→✅* | $20-50 | 10 min |
| Cloud (encrypted) | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ✅ | Free-$5/mo | 15 min |
| NAS (local) | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ❌ | $200-500 | 30 min |

*Store USB off-site for true disaster recovery

## 🎯 Start Here (Minimum Viable Backup)

If you only do **ONE thing** right now:

```bash
# Copy secrets to password manager
cat .backup/ENV_VARS.md | pbcopy
# Then save in 1Password/Bitwarden as "Homelab Secrets"
```

This alone protects you from 90% of disaster scenarios! 🎉
