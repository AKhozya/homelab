#!/bin/bash
# Fix NVMe Power Management settings
# Run with: sudo bash fix-nvme-pm.sh
#
# This script fixes the NVMe PM "auto" issue on nodes that ran the old setup-node.sh
# It adds tmpfiles.d rule and updates udev rule for reliability

set -e

echo "=== NVMe Power Management Fix ==="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Run as root: sudo bash fix-nvme-pm.sh"
    exit 1
fi

# Update udev rule with more reliable approach
echo "Updating udev rule..."
cat > /etc/udev/rules.d/60-nvme-no-pm.rules << 'EOF'
# Disable runtime PM for NVMe devices
ACTION=="add", SUBSYSTEM=="pci", ATTR{class}=="0x010802", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="block", KERNEL=="nvme*", RUN+="/bin/sh -c 'echo on > /sys$devpath/device/power/control 2>/dev/null || true'"
EOF

# Add tmpfiles.d rule for boot-time reliability
echo "Adding tmpfiles.d rule..."
cat > /etc/tmpfiles.d/nvme-no-pm.conf << 'EOF'
# Disable NVMe runtime power management at boot
w /sys/block/nvme*/device/power/control - - - - on
EOF

# Apply immediately
echo "Applying to existing NVMe devices..."
for d in /sys/block/nvme*/device/power/control; do
    if [ -f "$d" ]; then
        echo on > "$d" 2>/dev/null && echo "  Set $d to on" || echo "  Failed: $d"
    fi
done

# Reload udev
udevadm control --reload-rules 2>/dev/null || true

# Verify
echo ""
echo "=== Verification ==="
echo "NVMe devices:"
for d in /sys/block/nvme*/device/power/control; do
    if [ -f "$d" ]; then
        echo "  $d = $(cat "$d")"
    fi
done

echo ""
echo "APST setting:"
echo "  default_ps_max_latency_us = $(cat /sys/module/nvme_core/parameters/default_ps_max_latency_us 2>/dev/null || echo 'N/A')"

echo ""
echo "=== Done ==="
echo "Settings applied. No reboot required."
