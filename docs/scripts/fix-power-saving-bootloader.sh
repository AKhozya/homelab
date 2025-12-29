#!/bin/bash
# Fix PCIe ASPM and NVMe PCI power for Arch Linux with systemd-boot
# Run with: sudo bash fix-power-saving-bootloader.sh

set -e

echo "=== Fixing Power Saving Bootloader Settings ==="

# 1. Add pcie_aspm=off to systemd-boot entries
echo "1. Adding pcie_aspm=off to bootloader entries..."
for conf in /boot/loader/entries/*.conf; do
    if ! grep -q "pcie_aspm=off" "$conf"; then
        sed -i 's/^options /options pcie_aspm=off /' "$conf"
        echo "   Updated: $conf"
    else
        echo "   Already set: $conf"
    fi
done

# 2. Fix udev rule for NVMe PCI power (use KERNEL match)
echo "2. Fixing NVMe PCI udev rule..."
cat > /etc/udev/rules.d/60-nvme-no-pm.rules << 'EOF'
# Disable runtime PM for NVMe devices
ACTION=="add", SUBSYSTEM=="pci", ATTR{class}=="0x010802", ATTR{power/control}="on"
EOF
echo "   Written: /etc/udev/rules.d/60-nvme-no-pm.rules"

# 3. Apply udev rule immediately
echo "3. Reloading udev rules..."
udevadm control --reload-rules
udevadm trigger --subsystem-match=pci --attr-match=class=0x010802

# 4. Set NVMe PCI power now
echo "4. Setting NVMe PCI power to 'on' now..."
for d in /sys/block/nvme*/device/power/control; do
    echo on > "$d" 2>/dev/null || true
    echo "   $d: $(cat $d)"
done

echo ""
echo "=== Done! ==="
echo "Current kernel cmdline:"
cat /proc/cmdline
echo ""
echo "Bootloader entries updated. Reboot to apply pcie_aspm=off."
echo ""
echo "Current NVMe PCI power:"
cat /sys/block/nvme*/device/power/control
