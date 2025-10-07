#!/usr/bin/env bash
# Backup all secrets from cluster
# DO NOT COMMIT THIS FILE - IT CONTAINS UNENCRYPTED SECRETS

set -e

BACKUP_DIR="$(dirname "$0")"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "🔐 Backing up secrets from cluster..."

# Create backup directory
mkdir -p "${BACKUP_DIR}/secrets"

# Backup Cloudflare tunnel credentials
echo "📦 Backing up Cloudflare tunnel credentials..."
kubectl get secret tunnel-credentials -n linkding -o json > "${BACKUP_DIR}/secrets/linkding-tunnel-credentials.json"
kubectl get secret tunnel-credentials -n audiobookshelf -o json > "${BACKUP_DIR}/secrets/audiobookshelf-tunnel-credentials.json"

# Backup Cloudflare API token for cert-manager
echo "📦 Backing up Cloudflare API token..."
kubectl get secret cloudflare-api-token -n cert-manager -o json > "${BACKUP_DIR}/secrets/cloudflare-api-token.json"

# Backup Grafana admin credentials
echo "📦 Backing up Grafana admin credentials..."
kubectl get secret grafana-admin-secret -n monitoring -o json > "${BACKUP_DIR}/secrets/grafana-admin-secret.json"

# Backup Telegram bot credentials
echo "📦 Backing up Telegram bot credentials..."
kubectl get secret alertmanager-telegram -n monitoring -o json > "${BACKUP_DIR}/secrets/alertmanager-telegram.json"

# Backup SOPS age key
echo "📦 Backing up SOPS age key..."
kubectl get secret sops-age -n flux-system -o json > "${BACKUP_DIR}/secrets/sops-age.json"

# Extract important values to plain text for easy reference
echo "📝 Extracting values to plaintext (for reference only)..."

# Cloudflare API token
kubectl get secret cloudflare-api-token -n cert-manager -o jsonpath='{.data.api-token}' | base64 -d > "${BACKUP_DIR}/secrets/cloudflare-api-token.txt"

# Grafana admin password
kubectl get secret grafana-admin-secret -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d > "${BACKUP_DIR}/secrets/grafana-admin-password.txt"

# Telegram bot token
kubectl get secret alertmanager-telegram -n monitoring -o jsonpath='{.data.bot_token}' | base64 -d > "${BACKUP_DIR}/secrets/telegram-bot-token.txt"

# SOPS age key
kubectl get secret sops-age -n flux-system -o jsonpath='{.data.age\.agekey}' | base64 -d > "${BACKUP_DIR}/secrets/age.agekey"

echo ""
echo "✅ Backup complete! Files saved to: ${BACKUP_DIR}/secrets/"
echo ""
echo "⚠️  IMPORTANT: These files contain unencrypted secrets!"
echo "   - DO NOT commit them to git"
echo "   - Store them securely (password manager, encrypted drive, etc.)"
echo "   - The .backup/ directory is already in .gitignore"
echo ""
echo "📋 Backed up:"
echo "   - Cloudflare tunnel credentials (linkding, audiobookshelf)"
echo "   - Cloudflare API token"
echo "   - Grafana admin credentials"
echo "   - Telegram bot credentials"
echo "   - SOPS age encryption key"
