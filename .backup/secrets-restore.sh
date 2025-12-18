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
echo "   ✅ Monitoring secrets restored"

# =============================================================================
# Database Secrets
# =============================================================================
echo "📦 Restoring database secrets..."
kubectl create namespace databases --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${BACKUP_DIR}/secrets/redis-passwords.json"
kubectl apply -f "${BACKUP_DIR}/secrets/postgres-admin-user.json"

# PostgreSQL database users
kubectl apply -f "${BACKUP_DIR}/secrets/authentik-db-user.json"
kubectl apply -f "${BACKUP_DIR}/secrets/immich-db-user.json"
kubectl apply -f "${BACKUP_DIR}/secrets/linkwarden-db-user.json"
kubectl apply -f "${BACKUP_DIR}/secrets/mealie-db-user.json"
kubectl apply -f "${BACKUP_DIR}/secrets/n8n-db-user.json"
kubectl apply -f "${BACKUP_DIR}/secrets/paperless-db-user.json"

# MySQL secrets (Percona cluster - contains root, replication, xtrabackup, etc.)
kubectl apply -f "${BACKUP_DIR}/secrets/mysql-cluster-secrets.json"
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
kubectl apply -f "${BACKUP_DIR}/secrets/immich-redis-password.json"
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
echo "   ✅ Stirling PDF"

# HomeHub
kubectl create namespace homehub --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${BACKUP_DIR}/secrets/homehub-password.json"
echo "   ✅ HomeHub"

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

# Backup Replication
if [ -f "${BACKUP_DIR}/secrets/backup-replication-ssh-key.json" ]; then
    kubectl create namespace backup-replication --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f "${BACKUP_DIR}/secrets/backup-replication-ssh-key.json"
    echo "   ✅ Backup Replication"
fi

# Loki/Promtail
if [ -f "${BACKUP_DIR}/secrets/promtail.json" ]; then
    kubectl create namespace loki --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f "${BACKUP_DIR}/secrets/promtail.json"
    echo "   ✅ Promtail"
fi

# =============================================================================
# OIDC Integration Secrets
# =============================================================================
echo "📦 Restoring OIDC integration secrets..."

# Restore OIDC secrets for each application
if [ -f "${BACKUP_DIR}/secrets/audiobookshelf-oidc.json" ]; then
    kubectl apply -f "${BACKUP_DIR}/secrets/audiobookshelf-oidc.json"
fi
if [ -f "${BACKUP_DIR}/secrets/grafana-oidc.json" ]; then
    kubectl apply -f "${BACKUP_DIR}/secrets/grafana-oidc.json"
fi
if [ -f "${BACKUP_DIR}/secrets/home-assistant-oidc.json" ]; then
    kubectl apply -f "${BACKUP_DIR}/secrets/home-assistant-oidc.json"
fi
if [ -f "${BACKUP_DIR}/secrets/immich-oidc.json" ]; then
    kubectl apply -f "${BACKUP_DIR}/secrets/immich-oidc.json"
fi
if [ -f "${BACKUP_DIR}/secrets/mealie-oidc.json" ]; then
    kubectl apply -f "${BACKUP_DIR}/secrets/mealie-oidc.json"
fi
if [ -f "${BACKUP_DIR}/secrets/paperless-oidc.json" ]; then
    kubectl apply -f "${BACKUP_DIR}/secrets/paperless-oidc.json"
fi
if [ -f "${BACKUP_DIR}/secrets/n8n-oidc.json" ]; then
    kubectl apply -f "${BACKUP_DIR}/secrets/n8n-oidc.json"
fi
# Note: stirling-pdf and linkwarden OIDC configs are in their main secrets (already restored above)
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
