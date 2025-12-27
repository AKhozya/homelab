#!/bin/bash
# NVMe Health Diagnostic Script for worker-node
# Run with: sudo bash diagnose-nvme-health.sh

set -e

echo "=========================================="
echo "NVMe Health Diagnostic - $(date)"
echo "=========================================="

echo ""
echo "=== 1. SYSTEM INFO ==="
uname -a
uptime

echo ""
echo "=== 2. BLOCK DEVICE LAYOUT ==="
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL

echo ""
echo "=== 3. NVMe SMART DATA - nvme0n1 (4TB) ==="
if command -v nvme &> /dev/null; then
    nvme smart-log /dev/nvme0n1 2>/dev/null || echo "Failed to read SMART for nvme0n1"
else
    echo "nvme-cli not installed. Install with: pacman -S nvme-cli"
fi

echo ""
echo "=== 4. NVMe SMART DATA - nvme1n1 (1TB) ==="
if command -v nvme &> /dev/null; then
    nvme smart-log /dev/nvme1n1 2>/dev/null || echo "Failed to read SMART for nvme1n1"
fi

echo ""
echo "=== 5. NVMe ERROR LOG - nvme0n1 ==="
if command -v nvme &> /dev/null; then
    nvme error-log /dev/nvme0n1 2>/dev/null | head -50 || echo "No error log available"
fi

echo ""
echo "=== 6. NVMe ERROR LOG - nvme1n1 ==="
if command -v nvme &> /dev/null; then
    nvme error-log /dev/nvme1n1 2>/dev/null | head -50 || echo "No error log available"
fi

echo ""
echo "=== 7. LVM STATUS ==="
pvs -v
vgs -v
lvs -v

echo ""
echo "=== 8. FILESYSTEM CHECK STATUS ==="
cat /proc/mounts | grep -E 'ext4|xfs'
tune2fs -l /dev/mapper/k8s--storage-k8s--data 2>/dev/null | grep -E "Mount count|Maximum mount|Last checked|Filesystem state" || echo "Cannot read tune2fs"

echo ""
echo "=== 9. DMESG - LAST 200 LINES (I/O ERRORS) ==="
dmesg | tail -200 | grep -iE "error|fail|abort|ext4|nvme|dm-|I/O" || echo "No recent I/O errors in dmesg"

echo ""
echo "=== 10. JOURNAL - FILESYSTEM ERRORS (LAST HOUR) ==="
journalctl --since "1 hour ago" -k | grep -iE "ext4|nvme|dm-|error|abort|I/O" | tail -100 || echo "No recent errors"

echo ""
echo "=== 11. JOURNAL - LAST BOOT ERRORS ==="
journalctl -b -1 -k 2>/dev/null | grep -iE "ext4|nvme|error|abort" | tail -50 || echo "Previous boot log not available"

echo ""
echo "=== 12. TEMPERATURE CHECK ==="
if command -v nvme &> /dev/null; then
    echo "nvme0n1 temperature:"
    nvme smart-log /dev/nvme0n1 2>/dev/null | grep -i temp || echo "N/A"
    echo "nvme1n1 temperature:"
    nvme smart-log /dev/nvme1n1 2>/dev/null | grep -i temp || echo "N/A"
fi

echo ""
echo "=== 13. POWER STATUS ==="
if command -v sensors &> /dev/null; then
    sensors 2>/dev/null | head -30
else
    echo "lm_sensors not installed"
fi

echo ""
echo "=========================================="
echo "Diagnostic complete. Review output above."
echo "KEY THINGS TO CHECK:"
echo "  - SMART: media_errors, unsafe_shutdowns, percentage_used"
echo "  - Error logs for any entries"
echo "  - Filesystem state should be 'clean'"
echo "  - Temperature should be <70C"
echo "=========================================="
