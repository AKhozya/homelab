#!/bin/bash
# Disable power saving features that can cause latency/issues on K8s nodes
# Run with: sudo bash disable-power-saving.sh

set -e

echo "=== Disabling Power Saving Features ==="

# 1. Disable NVMe APST (Autonomous Power State Transitions)
echo "1. NVMe APST..."
echo 0 > /sys/module/nvme_core/parameters/default_ps_max_latency_us
echo "   default_ps_max_latency_us: $(cat /sys/module/nvme_core/parameters/default_ps_max_latency_us)"

# Make persistent via modprobe
cat > /etc/modprobe.d/nvme-no-apst.conf << 'EOF'
options nvme_core default_ps_max_latency_us=0
EOF
echo "   Persistent: /etc/modprobe.d/nvme-no-apst.conf"

# 2. Set NVMe PCI power to 'on' (no runtime PM)
echo "2. NVMe PCI runtime PM..."
for d in /sys/block/nvme*/device/power/control; do
    echo on > "$d"
    echo "   $d: $(cat $d)"
done

# Make persistent via udev
cat > /etc/udev/rules.d/60-nvme-no-pm.rules << 'EOF'
ACTION=="add", SUBSYSTEM=="pci", ATTR{class}=="0x010802", ATTR{power/control}="on"
EOF
echo "   Persistent: /etc/udev/rules.d/60-nvme-no-pm.rules"

# 3. Set PCIe ASPM to performance
echo "3. PCIe ASPM..."
if [ -f /sys/module/pcie_aspm/parameters/policy ]; then
    echo performance > /sys/module/pcie_aspm/parameters/policy 2>/dev/null || true
    echo "   policy: $(cat /sys/module/pcie_aspm/parameters/policy)"
fi

# Make persistent via kernel param
if ! grep -q "pcie_aspm=off" /etc/kernel/cmdline 2>/dev/null; then
    if [ -f /etc/kernel/cmdline ]; then
        sed -i 's/$/ pcie_aspm=off/' /etc/kernel/cmdline
        echo "   Added pcie_aspm=off to /etc/kernel/cmdline"
    else
        echo "   Note: Add 'pcie_aspm=off' to kernel cmdline manually"
    fi
fi

# 4. Regenerate initramfs to include modprobe settings
echo "4. Regenerating initramfs..."
mkinitcpio -P

echo ""
echo "=== Done! ==="
echo "Reboot recommended to apply kernel cmdline changes."
echo ""
echo "Current status:"
echo "  NVMe APST: $(cat /sys/module/nvme_core/parameters/default_ps_max_latency_us)"
echo "  PCIe ASPM: $(cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null || echo 'n/a')"
for d in /sys/block/nvme*/device/power/control; do
    echo "  $d: $(cat $d)"
done
