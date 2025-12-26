#!/bin/bash
# Patch archlinux-repro to add CPU limit support (MAX_CPU environment variable)
# Run as: sudo bash patch-archlinux-repro-cpu.sh
#
# This adds -C option for CPUQuota, similar to existing -M for MemoryMax
# Usage after patch: archlinux-repro -C 500% -M 12G package.pkg.tar.zst

set -e

REPRO_SCRIPT="/usr/bin/archlinux-repro"
BACKUP="/usr/bin/archlinux-repro.backup.$(date +%Y%m%d)"

echo "=== Patching archlinux-repro for CPU limit support ==="

# Check if already patched
if grep -q 'MAX_CPU' "$REPRO_SCRIPT" 2>/dev/null; then
    echo "Already patched! MAX_CPU support exists."
    exit 0
fi

# Backup original
echo "Creating backup at $BACKUP"
cp "$REPRO_SCRIPT" "$BACKUP"

# Patch 1: Add MAX_CPU property to nspawn call (after MAX_MEMORY line)
echo "Patching nspawn call..."
sed -i '/\${MAX_MEMORY:+--property="MemoryMax=\${MAX_MEMORY}"}/a\        ${MAX_CPU:+--property="CPUQuota=${MAX_CPU}"} \\' "$REPRO_SCRIPT"

# Patch 2: Add C: to getopts (change M:Vo: to M:C:Vo:)
echo "Patching getopts..."
sed -i 's/while getopts :hdnfM:Vo:/while getopts :hdnfM:C:Vo:/' "$REPRO_SCRIPT"

# Patch 3: Add C) case handler (after M) line)
echo "Patching case handler..."
sed -i '/M) MAX_MEMORY="\$OPTARG";;/a\            C) MAX_CPU="$OPTARG";;' "$REPRO_SCRIPT"

# Patch 4: Add help text for -C option (find -M line in help and add after it)
echo "Patching help text..."
sed -i '/-M <memory>/a\    -C <cpuquota>   Limit CPU usage (e.g., 500% for 5 cores, 1200% for 12 cores)' "$REPRO_SCRIPT"

# Verify patches applied
echo ""
echo "=== Verification ==="
if grep -q 'MAX_CPU' "$REPRO_SCRIPT"; then
    echo "✓ MAX_CPU variable added"
else
    echo "✗ MAX_CPU patch failed!"
    exit 1
fi

if grep -q 'CPUQuota' "$REPRO_SCRIPT"; then
    echo "✓ CPUQuota property added"
else
    echo "✗ CPUQuota patch failed!"
    exit 1
fi

if grep -q 'C:' "$REPRO_SCRIPT"; then
    echo "✓ -C option added to getopts"
else
    echo "✗ getopts patch failed!"
    exit 1
fi

echo ""
echo "=== Done! ==="
echo "Backup saved to: $BACKUP"
echo ""
echo "Usage examples:"
echo "  archlinux-repro -C 500% package.pkg.tar.zst      # Limit to 5 cores"
echo "  archlinux-repro -C 1200% -M 24G package.pkg.tar.zst  # 12 cores, 24GB RAM"
echo ""
echo "For rebuilderd, set in systemd service:"
echo "  Environment=MAX_CPU=500%"
echo "  Environment=MAX_MEMORY=12G"
