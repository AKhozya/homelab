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
    "secrets/age.agekey"
    "secrets/cloudflare-api-token.json"
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

# Step 1.5: Check for automated backups (optional but recommended)
echo "1.5️⃣  Checking automated backup availability..."

if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
    # Check for PostgreSQL backups
    POSTGRES_BACKUPS=$(kubectl debug node/worker-node --quiet --image=alpine:3.22 -- \
        sh -c "ls -1 /host/mnt/k8s-storage/backups/postgres/postgres_*.tar.gz 2>/dev/null | wc -l" 2>/dev/null || echo "0")

    # Check for CouchDB backups
    COUCHDB_BACKUPS=$(kubectl debug node/worker-node --quiet --image=alpine:3.22 -- \
        sh -c "ls -1 /host/mnt/k8s-storage/backups/couchdb/couchdb_*.tar.gz 2>/dev/null | wc -l" 2>/dev/null || echo "0")

    # Check for PVC backups
    PVC_BACKUPS=$(kubectl debug node/worker-node --quiet --image=alpine:3.22 -- \
        sh -c "ls -1d /host/mnt/k8s-storage/backups/pvc/20* 2>/dev/null | wc -l" 2>/dev/null || echo "0")

    echo "   PostgreSQL backups found: $POSTGRES_BACKUPS"
    echo "   CouchDB backups found: $COUCHDB_BACKUPS"
    echo "   PVC backups found: $PVC_BACKUPS"

    if [ "$POSTGRES_BACKUPS" -gt 0 ] && [ "$COUCHDB_BACKUPS" -gt 0 ] && [ "$PVC_BACKUPS" -gt 0 ]; then
        echo "✅ Automated backups available for full recovery"
    else
        echo "⚠️  Warning: Some automated backups missing"
        echo "   You can still restore secrets and infrastructure"
        echo "   See docs/BACKUP_STRATEGY.md for backup procedures"
    fi
else
    echo "   ⚠️  Cannot check automated backups (cluster not accessible yet)"
    echo "   Will verify after cluster is restored"
fi
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
echo "💾 IMPORTANT: Restore databases and PVCs from automated backups:"
echo ""
echo "   1. Wait for PostgreSQL cluster to be ready:"
echo "      kubectl wait --for=condition=ready cluster/main-postgres -n databases --timeout=600s"
echo ""
echo "   2. Restore PostgreSQL databases:"
echo "      See detailed procedure in docs/BACKUP_STRATEGY.md"
echo "      (Restores: authentik, immich, paperless, grafana, and 6 more DBs)"
echo ""
echo "   3. Restore CouchDB:"
echo "      See detailed procedure in docs/BACKUP_STRATEGY.md"
echo "      (Restores: obsidian-personal)"
echo ""
echo "   4. Restore PVCs:"
echo "      See detailed procedure in docs/BACKUP_STRATEGY.md"
echo "      (Restores: Home Assistant, Immich library, Paperless, Audiobookshelf)"
echo ""
echo "   Full procedures: docs/BACKUP_STRATEGY.md (Section: Disaster Recovery)"
echo ""
echo "🌐 Access points (after DNS/firewall setup and data restoration):"
echo "   - Grafana: https://grafana.h0melab.work"
echo "   - Alertmanager: https://am.h0melab.work"
echo "   - Immich: https://immich.h0melab.work"
echo "   - N8N: https://n8n.h0melab.work"
echo "   - Linkding: https://linkding.h0melab.work"
echo "   - Home Assistant: https://ha.h0melab.work"
echo "   - Authentik: https://authentik.h0melab.work"
echo "   - Audiobookshelf: https://audiobookshelf.h0melab.work"
echo "   - Paperless-NGX: https://paperless.h0melab.work"
echo ""
