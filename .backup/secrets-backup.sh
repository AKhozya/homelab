#!/usr/bin/env bash
# Backup ALL secrets needed for complete cluster provisioning from scratch
# DO NOT COMMIT THIS FILE - IT CONTAINS UNENCRYPTED SECRETS

set -e

BACKUP_DIR="$(dirname "$0")"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "🔐 Backing up ALL secrets from cluster for disaster recovery..."

# Create backup directory
mkdir -p "${BACKUP_DIR}/secrets"

# =============================================================================
# CRITICAL - SOPS Age Key (must be first, needed to decrypt everything else)
# =============================================================================
echo "📦 [CRITICAL] Backing up SOPS age key..."
kubectl get secret sops-age -n flux-system -o json > "${BACKUP_DIR}/secrets/sops-age.json"
kubectl get secret sops-age -n flux-system -o jsonpath='{.data.age\.agekey}' | base64 -d > "${BACKUP_DIR}/secrets/age.agekey"

# =============================================================================
# Infrastructure Secrets
# =============================================================================
echo "📦 Backing up infrastructure secrets..."

# Cloudflare (cert-manager DNS-01 challenge)
kubectl get secret cloudflare-api-token -n cert-manager -o json > "${BACKUP_DIR}/secrets/cloudflare-api-token.json"

# Cloudflare Tunnel
kubectl get secret tunnel-credentials -n cloudflare-tunnel -o json > "${BACKUP_DIR}/secrets/cloudflare-tunnel-credentials.json" 2>/dev/null || echo "   ⚠️  No cloudflare-tunnel/tunnel-credentials found"

# Flux system
kubectl get secret flux-system -n flux-system -o json > "${BACKUP_DIR}/secrets/flux-system.json" 2>/dev/null || echo "   ⚠️  No flux-system secret (may be using SSH key)"

# =============================================================================
# Monitoring Secrets
# =============================================================================
echo "📦 Backing up monitoring secrets..."
kubectl get secret grafana-admin-secret -n monitoring -o json > "${BACKUP_DIR}/secrets/grafana-admin-secret.json"
kubectl get secret alertmanager-telegram -n monitoring -o json > "${BACKUP_DIR}/secrets/alertmanager-telegram.json"

# =============================================================================
# Database Secrets
# =============================================================================
echo "📦 Backing up database secrets..."
kubectl get secret redis-passwords -n databases -o json > "${BACKUP_DIR}/secrets/redis-passwords.json"
kubectl get secret postgres-admin-user -n databases -o json > "${BACKUP_DIR}/secrets/postgres-admin-user.json"

# Database users (CloudNativePG auto-generates these, but backup for safety)
kubectl get secret authentik-db-user -n databases -o json > "${BACKUP_DIR}/secrets/authentik-db-user.json"
kubectl get secret immich-db-user -n databases -o json > "${BACKUP_DIR}/secrets/immich-db-user.json"
kubectl get secret linkding-db-app-user -n databases -o json > "${BACKUP_DIR}/secrets/linkding-db-user.json"
kubectl get secret mealie-db-user -n databases -o json > "${BACKUP_DIR}/secrets/mealie-db-user.json"
kubectl get secret n8n-db-user -n databases -o json > "${BACKUP_DIR}/secrets/n8n-db-user.json"
kubectl get secret paperless-db-user -n databases -o json > "${BACKUP_DIR}/secrets/paperless-db-user.json"
kubectl get secret wallabag-db-user -n databases -o json > "${BACKUP_DIR}/secrets/wallabag-db-user.json"

# =============================================================================
# Application Secrets (user credentials, API keys, environment variables)
# =============================================================================
echo "📦 Backing up application secrets..."

# Authentik
kubectl get secret authentik -n authentik -o json > "${BACKUP_DIR}/secrets/authentik.json"

# Immich
kubectl get secret immich-admin-credentials -n immich -o json > "${BACKUP_DIR}/secrets/immich-admin-credentials.json"
kubectl get secret immich-db-password -n immich -o json > "${BACKUP_DIR}/secrets/immich-db-password.json"
kubectl get secret immich-redis-password -n immich -o json > "${BACKUP_DIR}/secrets/immich-redis-password.json"

# Home Assistant
kubectl get secret home-assistant-admin-credentials -n home-assistant -o json > "${BACKUP_DIR}/secrets/home-assistant-admin-credentials.json"
kubectl get secret home-assistant-secrets -n home-assistant -o json > "${BACKUP_DIR}/secrets/home-assistant-secrets.json"

# N8N
kubectl get secret n8n-env -n n8n -o json > "${BACKUP_DIR}/secrets/n8n-env.json"
kubectl get secret n8n-user-credentials -n n8n -o json > "${BACKUP_DIR}/secrets/n8n-user-credentials.json"

# Linkding
kubectl get secret linkding-container-env -n linkding -o json > "${BACKUP_DIR}/secrets/linkding-container-env.json"

# Mealie
kubectl get secret mealie-env -n mealie -o json > "${BACKUP_DIR}/secrets/mealie-env.json"
kubectl get secret mealie-user-credentials -n mealie -o json > "${BACKUP_DIR}/secrets/mealie-user-credentials.json"

# Wallabag
kubectl get secret wallabag-env -n wallabag -o json > "${BACKUP_DIR}/secrets/wallabag-env.json"

# Paperless-NGX
kubectl get secret paperless-env -n paperless-ngx -o json > "${BACKUP_DIR}/secrets/paperless-env.json"

# Audiobookshelf
kubectl get secret audiobookshelf-admin -n audiobookshelf -o json > "${BACKUP_DIR}/secrets/audiobookshelf-admin.json"

# Uptime Kuma
kubectl get secret uptime-kuma-admin -n uptime-kuma -o json > "${BACKUP_DIR}/secrets/uptime-kuma-admin.json"

# Stirling PDF
kubectl get secret stirling-pdf-env -n stirling-pdf -o json > "${BACKUP_DIR}/secrets/stirling-pdf-env.json"

# HomeHub
kubectl get secret homehub-password -n homehub -o json > "${BACKUP_DIR}/secrets/homehub-password.json"

# Obsidian CouchDB
kubectl get secret couchdb-admin-credentials -n obsidian -o json > "${BACKUP_DIR}/secrets/couchdb-admin-credentials.json" 2>/dev/null || echo "   ⚠️  No obsidian/couchdb-admin-credentials"
kubectl get secret couchdb-credentials -n obsidian -o json > "${BACKUP_DIR}/secrets/couchdb-credentials.json" 2>/dev/null || echo "   ⚠️  No obsidian/couchdb-credentials"

# CouchDB (for Obsidian)
kubectl get secret couchdb-couchdb -n couchdb -o json > "${BACKUP_DIR}/secrets/couchdb-couchdb.json" 2>/dev/null || echo "   ⚠️  No couchdb/couchdb-couchdb"

# Loki/Promtail
kubectl get secret promtail -n loki -o json > "${BACKUP_DIR}/secrets/promtail.json" 2>/dev/null || echo "   ⚠️  No loki/promtail secret"

# =============================================================================
# OIDC Integration Secrets (for Authentik SSO)
# =============================================================================
echo "📦 Backing up OIDC integration secrets..."

# Application OIDC configurations
kubectl get secret audiobookshelf-oidc -n audiobookshelf -o json > "${BACKUP_DIR}/secrets/audiobookshelf-oidc.json" 2>/dev/null || echo "   ⚠️  No audiobookshelf/audiobookshelf-oidc"
kubectl get secret grafana-oidc -n monitoring -o json > "${BACKUP_DIR}/secrets/grafana-oidc.json" 2>/dev/null || echo "   ⚠️  No monitoring/grafana-oidc"
kubectl get secret home-assistant-oidc -n home-assistant -o json > "${BACKUP_DIR}/secrets/home-assistant-oidc.json" 2>/dev/null || echo "   ⚠️  No home-assistant/home-assistant-oidc"
kubectl get secret immich-oidc -n immich -o json > "${BACKUP_DIR}/secrets/immich-oidc.json" 2>/dev/null || echo "   ⚠️  No immich/immich-oidc"
kubectl get secret linkding-oidc -n linkding -o json > "${BACKUP_DIR}/secrets/linkding-oidc.json" 2>/dev/null || echo "   ⚠️  No linkding/linkding-oidc"
kubectl get secret mealie-oidc -n mealie -o json > "${BACKUP_DIR}/secrets/mealie-oidc.json" 2>/dev/null || echo "   ⚠️  No mealie/mealie-oidc"
kubectl get secret n8n-oidc -n n8n -o json > "${BACKUP_DIR}/secrets/n8n-oidc.json" 2>/dev/null || echo "   ⚠️  No n8n/n8n-oidc"
kubectl get secret paperless-oidc -n paperless-ngx -o json > "${BACKUP_DIR}/secrets/paperless-oidc.json" 2>/dev/null || echo "   ⚠️  No paperless-ngx/paperless-oidc"

# =============================================================================
# Extract important plaintext values for easy reference
# =============================================================================
echo "📝 Extracting plaintext values for reference..."

# Cloudflare API token
kubectl get secret cloudflare-api-token -n cert-manager -o jsonpath='{.data.api-token}' | base64 -d > "${BACKUP_DIR}/secrets/cloudflare-api-token.txt" 2>/dev/null

# Grafana admin password
kubectl get secret grafana-admin-secret -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d > "${BACKUP_DIR}/secrets/grafana-admin-password.txt" 2>/dev/null

# Telegram bot token
kubectl get secret alertmanager-telegram -n monitoring -o jsonpath='{.data.bot_token}' | base64 -d > "${BACKUP_DIR}/secrets/telegram-bot-token.txt" 2>/dev/null

# Redis password
kubectl get secret redis-passwords -n databases -o jsonpath='{.data.immich-password}' | base64 -d > "${BACKUP_DIR}/secrets/redis-password-immich.txt" 2>/dev/null

# =============================================================================
# Encrypt backup with GPG
# =============================================================================
echo "🔐 Encrypting backup with GPG..."
ENCRYPTED_FILE="${BACKUP_DIR}/secrets-backup-${TIMESTAMP}.tar.gz.gpg"

# Create tarball of secrets directory
tar -czf - -C "${BACKUP_DIR}" secrets | \
  gpg --symmetric --cipher-algo AES256 --batch --yes --passphrase-file <(echo "${GPG_PASSPHRASE:-homelab-secrets-backup}") \
  -o "${ENCRYPTED_FILE}"

if [ $? -eq 0 ]; then
  echo "✅ Encrypted backup created: ${ENCRYPTED_FILE}"
  echo "📊 Backup size: $(du -h "${ENCRYPTED_FILE}" | awk '{print $1}')"

  # Remove unencrypted secrets directory
  echo "🗑️  Removing unencrypted secrets directory for security..."
  rm -rf "${BACKUP_DIR}/secrets"

  echo ""
  echo "🔓 To decrypt this backup later, use:"
  echo "   gpg --decrypt ${ENCRYPTED_FILE} | tar -xzf - -C ${BACKUP_DIR}"
  echo ""
  echo "   Or set GPG_PASSPHRASE environment variable:"
  echo "   export GPG_PASSPHRASE='your-secure-passphrase'"
  echo "   gpg --decrypt --batch --passphrase-file <(echo \"\$GPG_PASSPHRASE\") ${ENCRYPTED_FILE} | tar -xzf - -C ${BACKUP_DIR}"
else
  echo "❌ GPG encryption failed! Secrets remain unencrypted in ${BACKUP_DIR}/secrets/"
  exit 1
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "✅ Encrypted backup complete!"
echo ""
echo "🔒 Security Notes:"
echo "   ✅ Backup is encrypted with GPG AES256"
echo "   ✅ Unencrypted secrets directory removed"
echo "   ⚠️  Store GPG passphrase securely (1Password recommended)"
echo "   ⚠️  Default passphrase: 'homelab-secrets-backup' (change via GPG_PASSPHRASE env var)"
echo "   ⚠️  The .backup/ directory is in .gitignore"
echo ""
echo "📋 Backed up secrets for:"
echo "   🔑 SOPS age encryption key (CRITICAL)"
echo "   🌐 Cloudflare API token & tunnel credentials"
echo "   📊 Grafana & Telegram (monitoring)"
echo "   🗄️  Redis & PostgreSQL (databases)"
echo "   📱 All application secrets:"
echo "      - Authentik, Immich, Home Assistant"
echo "      - N8N, Linkding, Mealie, Wallabag"
echo "      - Paperless-NGX, Audiobookshelf, Uptime Kuma"
echo "      - Stirling PDF, CouchDB (Obsidian)"
echo "   🔐 OIDC integration secrets:"
echo "      - Grafana, Immich, Home Assistant, Linkding"
echo "      - Mealie, N8N, Paperless-NGX, Audiobookshelf"
echo ""
echo "📂 Encrypted file: $(basename ${ENCRYPTED_FILE})"
