#!/usr/bin/env bash
# Complete cluster disaster recovery script
# This will restore your entire homelab from scratch

set -e

echo "🚀 Homelab Disaster Recovery"
echo "=============================="
echo ""

BACKUP_DIR="$(dirname "$0")"

# Step 1: Verify backup files exist
echo "1️⃣  Verifying backup files..."
if [ ! -d "${BACKUP_DIR}/secrets" ]; then
    echo "❌ Error: No backup directory found!"
    echo "   Run secrets-backup.sh first to create backups"
    exit 1
fi

required_files=(
    "secrets/sops-age.json"
    "secrets/cloudflare-api-token.json"
    "secrets/linkding-tunnel-credentials.json"
    "secrets/audiobookshelf-tunnel-credentials.json"
    "secrets/grafana-admin-secret.json"
    "secrets/alertmanager-telegram.json"
)

for file in "${required_files[@]}"; do
    if [ ! -f "${BACKUP_DIR}/${file}" ]; then
        echo "❌ Missing required file: ${file}"
        exit 1
    fi
done

echo "✅ All backup files found"
echo ""

# Step 2: Check kubectl connectivity
echo "2️⃣  Checking cluster connectivity..."
if ! kubectl cluster-info &>/dev/null; then
    echo "❌ Error: Cannot connect to cluster"
    echo "   Make sure your kubeconfig is configured correctly"
    exit 1
fi
echo "✅ Connected to cluster"
echo ""

# Step 3: Restore secrets
echo "3️⃣  Restoring secrets..."
bash "${BACKUP_DIR}/secrets-restore.sh"
echo ""

# Step 4: Check if Flux is installed
echo "4️⃣  Checking Flux installation..."
if ! kubectl get namespace flux-system &>/dev/null; then
    echo "⚠️  Flux not installed. You need to bootstrap Flux manually:"
    echo ""
    echo "   flux bootstrap github \\"
    echo "     --owner=AKhozya \\"
    echo "     --repository=homelab \\"
    echo "     --path=clusters/staging \\"
    echo "     --personal"
    echo ""
    exit 0
fi

# Step 5: Trigger Flux reconciliation
echo "5️⃣  Triggering Flux reconciliation..."
flux reconcile source git flux-system
flux get kustomizations -A --no-header | awk '{print $2}' | xargs -I {} flux reconcile kustomization {} -n flux-system

echo ""
echo "✅ Disaster recovery complete!"
echo ""
echo "📊 Monitoring the deployment:"
echo "   watch kubectl get pods -A"
echo ""
echo "🔍 Check Flux status:"
echo "   kubectl get kustomization -A"
echo "   kubectl get helmrelease -A"
echo ""
echo "🌐 Access points (after DNS/firewall setup):"
echo "   - Grafana: https://grafana.h0melab.work"
echo "   - Alertmanager: https://am.h0melab.work"
echo "   - Linkding: https://linkding.h0melab.work"
echo "   - Audiobookshelf: https://audiobookshelf.h0melab.work"
echo ""
