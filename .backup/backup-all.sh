#!/usr/bin/env bash
# Automated backup of secrets to multiple locations
# Run this monthly or after adding new secrets

set -e

BACKUP_DIR="$(cd "$(dirname "$0")" && pwd)"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="homelab-secrets-${DATE}"

echo "🔄 Creating comprehensive backup..."

# Step 1: Refresh cluster secrets backup
echo "1️⃣  Backing up from cluster..."
cd "${BACKUP_DIR}"
./secrets-backup.sh

# Step 2: Create encrypted archive
echo "2️⃣  Creating encrypted archive..."
cd ..
tar czf - .backup/ | \
  gpg --symmetric --cipher-algo AES256 --batch --yes \
  --passphrase-file ~/.homelab-backup-passphrase \
  > "${BACKUP_NAME}.tar.gz.gpg"

echo "✅ Encrypted archive created: ${BACKUP_NAME}.tar.gz.gpg"

# Step 3: Copy to different locations
echo "3️⃣  Copying to backup locations..."

# Option 1: Copy to USB drive (if mounted)
if [ -d "/Volumes/BackupUSB" ]; then
    echo "   📁 Copying to USB drive..."
    cp "${BACKUP_NAME}.tar.gz.gpg" "/Volumes/BackupUSB/homelab-backups/"
    cp -r .backup/ "/Volumes/BackupUSB/homelab-backups/backup-${DATE}/"
    echo "   ✅ USB backup complete"
fi

# Option 2: Upload to cloud (uncomment and configure)
# if command -v rclone &> /dev/null; then
#     echo "   ☁️  Uploading to cloud..."
#     rclone copy "${BACKUP_NAME}.tar.gz.gpg" gdrive:homelab-backups/
#     echo "   ✅ Cloud upload complete"
# fi

# Option 3: Copy to NAS (uncomment and configure)
# if ping -c 1 nas.local &> /dev/null; then
#     echo "   🗄️  Copying to NAS..."
#     scp "${BACKUP_NAME}.tar.gz.gpg" nas.local:/volume1/backups/homelab/
#     echo "   ✅ NAS backup complete"
# fi

echo ""
echo "✅ Backup complete!"
echo ""
echo "📋 Next steps:"
echo "   1. Upload ${BACKUP_NAME}.tar.gz.gpg to password manager (1Password/Bitwarden)"
echo "   2. Verify USB backup exists: /Volumes/BackupUSB/homelab-backups/"
echo "   3. Test restore: gpg -d ${BACKUP_NAME}.tar.gz.gpg | tar xzf -"
echo ""
echo "🔐 Decryption passphrase stored in: ~/.homelab-backup-passphrase"
echo "   (Keep this safe! You need it to decrypt backups)"

# Cleanup old backups (keep last 5)
echo ""
echo "🧹 Cleaning up old backups (keeping last 5)..."
ls -t homelab-secrets-*.tar.gz.gpg 2>/dev/null | tail -n +6 | xargs -r rm
echo "   ✅ Cleanup complete"
