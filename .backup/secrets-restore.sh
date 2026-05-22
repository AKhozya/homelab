#!/usr/bin/env bash
# Restore ALL secrets needed for complete cluster provisioning from scratch
# Run this after creating a fresh cluster and BEFORE bootstrapping Flux

set -e

BACKUP_DIR="$(dirname "$0")"

echo "🔄 Restoring ALL secrets to cluster for disaster recovery..."

# =============================================================================
# Decrypt backup if needed
# =============================================================================
if [ ! -d "${BACKUP_DIR}/secrets" ]; then
    echo "📦 Secrets directory not found. Looking for encrypted backups..."

    # Find the latest encrypted backup
    LATEST_BACKUP=$(ls -t "${BACKUP_DIR}"/secrets-backup-*.tar.gz.gpg 2>/dev/null | head -1)

    if [ -z "${LATEST_BACKUP}" ]; then
        echo "❌ Error: No encrypted backup found in ${BACKUP_DIR}/"
        echo "   Expected file: secrets-backup-YYYYMMDD_HHMMSS.tar.gz.gpg"
        echo "   Run secrets-backup.sh first to create backups"
        exit 1
    fi

    echo "🔓 Found encrypted backup: $(basename ${LATEST_BACKUP})"
    echo ""

    # Get passphrase (prompt if not set as environment variable)
    if [ -z "${GPG_PASSPHRASE}" ]; then
        echo "⚠️  This backup is encrypted. You need the passphrase to decrypt it."
        echo ""

        # Prompt for passphrase (hidden input)
        read -s -p "Enter passphrase: " GPG_PASSPHRASE
        echo ""

        # Verify passphrase is not empty
        if [ -z "${GPG_PASSPHRASE}" ]; then
            echo "❌ ERROR: Passphrase cannot be empty!"
            exit 1
        fi
    fi

    # Decrypt and extract backup
    echo "🔓 Decrypting backup..."
    if gpg --decrypt --batch --passphrase-file <(echo "${GPG_PASSPHRASE}") "${LATEST_BACKUP}" | tar -xzf - -C "${BACKUP_DIR}"; then
        echo "✅ Backup decrypted successfully"
        echo ""
    else
        echo "❌ ERROR: Failed to decrypt backup. Check your passphrase."
        exit 1
    fi
fi

# Verify secrets directory exists now
if [ ! -d "${BACKUP_DIR}/secrets" ]; then
    echo "❌ Error: Secrets directory still not found after decryption"
    exit 1
fi

# =============================================================================
# CRITICAL - SOPS Age Key (must be first, needed for Flux to decrypt secrets)
# =============================================================================
echo "🔑 [CRITICAL] Restoring SOPS age key..."
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${BACKUP_DIR}/secrets/sops-age.json"
echo "   ✅ SOPS age key restored"

# =============================================================================
# Infrastructure Secrets
# =============================================================================
echo "📦 Restoring infrastructure secrets..."

# Cloudflare (cert-manager DNS-01 challenge)
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${BACKUP_DIR}/secrets/cloudflare-api-token.json"
echo "   ✅ Cloudflare API token restored"

# Cloudflare Tunnel
if [ -f "${BACKUP_DIR}/secrets/cloudflare-tunnel-credentials.json" ]; then
    kubectl create namespace cloudflare-tunnel --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f "${BACKUP_DIR}/secrets/cloudflare-tunnel-credentials.json"
    echo "   ✅ Cloudflare tunnel credentials restored"
fi

# Flux system (if exists)
if [ -f "${BACKUP_DIR}/secrets/flux-system.json" ]; then
    kubectl apply -f "${BACKUP_DIR}/secrets/flux-system.json"
    echo "   ✅ Flux system secret restored"
fi

# =============================================================================
# Monitoring Secrets
# =============================================================================
echo "📦 Restoring monitoring secrets..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${BACKUP_DIR}/secrets/grafana-admin-secret.json"
kubectl apply -f "${BACKUP_DIR}/secrets/alertmanager-telegram.json"
if [ -f "${BACKUP_DIR}/secrets/couchdb-couchdb-monitoring.json" ]; then
  kubectl apply -f "${BACKUP_DIR}/secrets/couchdb-couchdb-monitoring.json"
else
  echo "   ⚠️  No CouchDB auth mirror for VMAgent (will be created by Flux from SOPS)"
fi
echo "   ✅ Monitoring secrets restored"

# =============================================================================
# Database Secrets
# =============================================================================
echo "📦 Restoring database secrets..."
kubectl create namespace databases --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${BACKUP_DIR}/secrets/redis-passwords.json"
[ -f "${BACKUP_DIR}/secrets/redis-acl-secret.json" ] && kubectl apply -f "${BACKUP_DIR}/secrets/redis-acl-secret.json"
kubectl apply -f "${BACKUP_DIR}/secrets/postgres-admin-user.json"

# CNPG cluster-managed credentials — apply BEFORE the Cluster CR so the
# operator picks up originals instead of generating fresh ones (passwords in
# pg_authid match the WAL/base backup).
[ -f "${BACKUP_DIR}/secrets/main-postgres-app.json" ] && kubectl apply -f "${BACKUP_DIR}/secrets/main-postgres-app.json"
[ -f "${BACKUP_DIR}/secrets/main-postgres-superuser.json" ] && kubectl apply -f "${BACKUP_DIR}/secrets/main-postgres-superuser.json"
[ -f "${BACKUP_DIR}/secrets/main-postgres-replication.json" ] && kubectl apply -f "${BACKUP_DIR}/secrets/main-postgres-replication.json"
[ -f "${BACKUP_DIR}/secrets/main-postgres-pooler.json" ] && kubectl apply -f "${BACKUP_DIR}/secrets/main-postgres-pooler.json"
[ -f "${BACKUP_DIR}/secrets/main-postgres-ca.json" ] && kubectl apply -f "${BACKUP_DIR}/secrets/main-postgres-ca.json"
[ -f "${BACKUP_DIR}/secrets/main-postgres-server.json" ] && kubectl apply -f "${BACKUP_DIR}/secrets/main-postgres-server.json"

# PostgreSQL database users
kubectl apply -f "${BACKUP_DIR}/secrets/authentik-db-user.json"
kubectl apply -f "${BACKUP_DIR}/secrets/immich-db-user.json"
kubectl apply -f "${BACKUP_DIR}/secrets/linkwarden-db-user.json"
kubectl apply -f "${BACKUP_DIR}/secrets/mealie-db-user.json"
kubectl apply -f "${BACKUP_DIR}/secrets/n8n-db-user.json"
kubectl apply -f "${BACKUP_DIR}/secrets/paperless-db-user.json"
[ -f "${BACKUP_DIR}/secrets/blocky-db-user.json" ] && kubectl apply -f "${BACKUP_DIR}/secrets/blocky-db-user.json"

# MySQL secrets (Percona cluster - contains root, replication, xtrabackup, etc.)
kubectl apply -f "${BACKUP_DIR}/secrets/mysql-cluster-secrets.json"

# Percona operator-managed internal credentials — apply BEFORE the
# PerconaServerMySQL CR so the operator reuses originals (matches xtrabackup/replication state).
[ -f "${BACKUP_DIR}/secrets/internal-main-mysql.json" ] && kubectl apply -f "${BACKUP_DIR}/secrets/internal-main-mysql.json"
echo "   ✅ Database secrets restored (PostgreSQL + MySQL)"

# =============================================================================
# Application Secrets
# =============================================================================
echo "📦 Restoring application secrets..."

# Authentik
kubectl create namespace authentik --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${BACKUP_DIR}/secrets/authentik.json"
echo "   ✅ Authentik"

# Immich
kubectl create namespace immich --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${BACKUP_DIR}/secrets/immich-admin-credentials.json"
kubectl apply -f "${BACKUP_DIR}/secrets/immich-db-password.json"
[ -f "${BACKUP_DIR}/secrets/immich-redis-url.json" ] && kubectl apply -f "${BACKUP_DIR}/secrets/immich-redis-url.json"
echo "   ✅ Immich"

# Home Assistant
kubectl create namespace home-assistant --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${BACKUP_DIR}/secrets/home-assistant-admin-credentials.json"
kubectl apply -f "${BACKUP_DIR}/secrets/home-assistant-secrets.json"
echo "   ✅ Home Assistant"

# N8N
kubectl create namespace n8n --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${BACKUP_DIR}/secrets/n8n-env.json"
kubectl apply -f "${BACKUP_DIR}/secrets/n8n-user-credentials.json"
echo "   ✅ N8N"

# Mealie
kubectl create namespace mealie --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${BACKUP_DIR}/secrets/mealie-env.json"
kubectl apply -f "${BACKUP_DIR}/secrets/mealie-user-credentials.json"
echo "   ✅ Mealie"

# Paperless-NGX
kubectl create namespace paperless-ngx --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${BACKUP_DIR}/secrets/paperless-env.json"
echo "   ✅ Paperless-NGX"

# LinkWarden (replaced Linkding + Wallabag)
kubectl create namespace linkwarden --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${BACKUP_DIR}/secrets/linkwarden.json"
kubectl apply -f "${BACKUP_DIR}/secrets/meilisearch.json"
echo "   ✅ LinkWarden"

# Audiobookshelf
kubectl create namespace audiobookshelf --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${BACKUP_DIR}/secrets/audiobookshelf-admin.json"
echo "   ✅ Audiobookshelf"

# Uptime Kuma
kubectl create namespace uptime-kuma --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${BACKUP_DIR}/secrets/uptime-kuma-admin.json"
kubectl apply -f "${BACKUP_DIR}/secrets/uptime-kuma-mysql-credentials.json"
echo "   ✅ Uptime Kuma"

# Stirling PDF
kubectl create namespace stirling-pdf --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${BACKUP_DIR}/secrets/stirling-pdf-env.json"
if [ -f "${BACKUP_DIR}/secrets/stirling-pdf-custom-settings.json" ]; then
    kubectl apply -f "${BACKUP_DIR}/secrets/stirling-pdf-custom-settings.json"
fi
echo "   ✅ Stirling PDF"

# HomeHub
kubectl create namespace homehub --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${BACKUP_DIR}/secrets/homehub-password.json"
echo "   ✅ HomeHub"

# Blocky DNS
if [ -f "${BACKUP_DIR}/secrets/blocky-config.json" ]; then
    kubectl create namespace blocky --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f "${BACKUP_DIR}/secrets/blocky-config.json"
    echo "   ✅ Blocky"
fi

# Claude Telegram bot
if [ -f "${BACKUP_DIR}/secrets/claude-telegram-env.json" ]; then
    kubectl create namespace claude-telegram --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f "${BACKUP_DIR}/secrets/claude-telegram-env.json"
    [ -f "${BACKUP_DIR}/secrets/claude-telegram-ssh.json" ] && kubectl apply -f "${BACKUP_DIR}/secrets/claude-telegram-ssh.json"
    [ -f "${BACKUP_DIR}/secrets/claude-telegram-chezmoi.json" ] && kubectl apply -f "${BACKUP_DIR}/secrets/claude-telegram-chezmoi.json"
    echo "   ✅ Claude Telegram"
fi

# PriceBuddy
kubectl create namespace pricebuddy --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${BACKUP_DIR}/secrets/pricebuddy-secrets.json"
kubectl apply -f "${BACKUP_DIR}/secrets/pricebuddy-mysql-credentials.json"
kubectl apply -f "${BACKUP_DIR}/secrets/pricebuddy-telegram.json"
echo "   ✅ PriceBuddy"

# Obsidian CouchDB
if [ -f "${BACKUP_DIR}/secrets/couchdb-admin-credentials.json" ]; then
    kubectl create namespace obsidian --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f "${BACKUP_DIR}/secrets/couchdb-admin-credentials.json"
    kubectl apply -f "${BACKUP_DIR}/secrets/couchdb-credentials.json" 2>/dev/null || true
    echo "   ✅ Obsidian CouchDB"
fi

# CouchDB (in databases namespace)
if [ -f "${BACKUP_DIR}/secrets/couchdb-couchdb.json" ]; then
    kubectl apply -f "${BACKUP_DIR}/secrets/couchdb-couchdb.json"
    echo "   ✅ CouchDB"
fi

# Backup Replication (SSH key + NAS rsync credentials + Telegram)
if [ -f "${BACKUP_DIR}/secrets/backup-replication-ssh-key.json" ]; then
    kubectl create namespace backup-replication --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f "${BACKUP_DIR}/secrets/backup-replication-ssh-key.json"
    if [ -f "${BACKUP_DIR}/secrets/nas-rsync-credentials.json" ]; then
        kubectl apply -f "${BACKUP_DIR}/secrets/nas-rsync-credentials.json"
    fi
    if [ -f "${BACKUP_DIR}/secrets/backup-telegram.json" ]; then
        kubectl apply -f "${BACKUP_DIR}/secrets/backup-telegram.json"
    fi
    echo "   ✅ Backup Replication (SSH key + NAS credentials + Telegram)"
fi

# Cloudflare Tunnel config
if [ -f "${BACKUP_DIR}/secrets/cloudflared-config.json" ]; then
    kubectl apply -f "${BACKUP_DIR}/secrets/cloudflared-config.json"
    echo "   ✅ Cloudflare tunnel config"
fi

# Cloudflare Tunnel management API token (for syncing tunnel config from Git)
if [ -f "${BACKUP_DIR}/secrets/cloudflare-tunnel-mgmt-token.json" ]; then
    kubectl apply -f "${BACKUP_DIR}/secrets/cloudflare-tunnel-mgmt-token.json"
    echo "   ✅ Cloudflare tunnel management token"
fi

# =============================================================================
# OIDC Integration Secrets
# =============================================================================
echo "📦 Restoring OIDC integration secrets..."

# Only grafana-oidc is a standalone secret — all other OIDC configs are in
# their app secrets (already restored above). After restore, you must also:
#   - Re-configure OIDC in immich and audiobookshelf web UIs (stored in internal DB)
#   - All other apps get OIDC from env vars / mounted secrets (automatic via Flux)
if [ -f "${BACKUP_DIR}/secrets/grafana-oidc.json" ]; then
    kubectl apply -f "${BACKUP_DIR}/secrets/grafana-oidc.json"
fi
echo "   ✅ OIDC integration secrets restored"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "✅ All secrets restored successfully!"
echo ""
echo "📋 Next steps:"
echo "   1. Bootstrap Flux:"
echo "      flux bootstrap github --owner=AKhozya --repository=homelab --path=clusters/staging --personal"
echo ""
echo "   2. Wait for Flux to reconcile (2-5 minutes):"
echo "      watch kubectl get kustomization -A"
echo ""
echo "   3. Check all resources are deploying:"
echo "      kubectl get helmrelease -A"
echo "      kubectl get pods -A"
echo ""
echo "   4. Verify applications are accessible:"
echo "      - https://grafana.h0melab.work"
echo "      - https://authentik.h0melab.work"
echo "      - https://immich.h0melab.work"
echo "      - https://n8n.h0melab.work"
echo "      - https://paperless.h0melab.work"
echo "      - https://linkwarden.h0melab.work"
echo "      - https://stirling.h0melab.work"
echo "      - https://pricebuddy.h0melab.work"
echo "      etc."
echo ""
