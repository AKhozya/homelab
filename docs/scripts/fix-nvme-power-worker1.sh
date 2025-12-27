#!/bin/bash
# Fix NVMe power management on worker-node (Minisforum MS-A2)
# Run with: sudo bash fix-nvme-power-worker1.sh

set -e

BOOT_ENTRY="/boot/loader/entries/2025-08-08_17-05-09_linux.conf"

echo "=== Adding NVMe power management fix ==="

# Check boot entry exists
if [[ ! -f "$BOOT_ENTRY" ]]; then
    echo "ERROR: Boot entry not found: $BOOT_ENTRY"
    exit 1
fi

echo "Current boot entry:"
cat "$BOOT_ENTRY"

# Check if already present
if grep -q "nvme_core.default_ps_max_latency_us=0" "$BOOT_ENTRY"; then
    echo ""
    echo "Already configured, nothing to do"
    exit 0
fi

# Backup
cp "$BOOT_ENTRY" "${BOOT_ENTRY}.backup.$(date +%Y%m%d)"

# Add parameter to options line
sed -i 's/amd_pstate=active$/amd_pstate=active nvme_core.default_ps_max_latency_us=0/' "$BOOT_ENTRY"

echo ""
echo "Updated boot entry:"
cat "$BOOT_ENTRY"

echo ""
echo "=== Done ==="
echo "Reboot required to apply changes."
echo "After reboot, verify with: cat /proc/cmdline | grep nvme"
