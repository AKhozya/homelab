#!/usr/bin/env bash
# Restore all secrets to cluster
# Run this after creating a fresh cluster

set -e

BACKUP_DIR="$(dirname "$0")"

echo "🔄 Restoring secrets to cluster..."

# Check if backup files exist
if [ ! -d "${BACKUP_DIR}/secrets" ]; then
    echo "❌ Error: No backup directory found at ${BACKUP_DIR}/secrets/"
    echo "   Run secrets-backup.sh first to create backups"
    exit 1
fi

# Restore SOPS age key first (needed for encrypted manifests)
echo "🔑 Restoring SOPS age key..."
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${BACKUP_DIR}/secrets/sops-age.json"

# Restore Cloudflare API token
echo "📦 Restoring Cloudflare API token..."
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${BACKUP_DIR}/secrets/cloudflare-api-token.json"

# Restore Cloudflare tunnel credentials
echo "📦 Restoring Cloudflare tunnel credentials..."
kubectl create namespace linkding --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${BACKUP_DIR}/secrets/linkding-tunnel-credentials.json"

kubectl create namespace audiobookshelf --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${BACKUP_DIR}/secrets/audiobookshelf-tunnel-credentials.json"

# Restore monitoring secrets
echo "📦 Restoring monitoring secrets..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${BACKUP_DIR}/secrets/grafana-admin-secret.json"
kubectl apply -f "${BACKUP_DIR}/secrets/alertmanager-telegram.json"

echo ""
echo "✅ Secrets restored successfully!"
echo ""
echo "📋 Next steps:"
echo "   1. Bootstrap Flux: flux bootstrap github --owner=AKhozya --repository=homelab --path=clusters/staging --personal"
echo "   2. Wait for Flux to reconcile (1-2 minutes)"
echo "   3. Check status: kubectl get kustomization -n flux-system"
echo ""
