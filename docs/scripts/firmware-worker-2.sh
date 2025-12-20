#!/bin/bash
# Firmware Management - Worker Node 2 (worker-node-2)
# Run with: bash firmware-worker-2.sh
#
# Hardware: AMD Ryzen 7 8745H (Zen 4)
# - AMD Radeon 780M Graphics (HawkPoint integrated)
# - Realtek RTL8125 2.5GbE Ethernet
# - MediaTek MT7902 WiFi
# - AMD USB4/Thunderbolt
#
# Required firmware: amd-ucode, linux-firmware (base covers AMD GPU, Realtek, MediaTek)
# Unnecessary AUR packages: aic94xx-firmware, ast-firmware, upd72020x-fw, wd719x-firmware

set -e

echo "=== Firmware Management for Worker Node 2 (AMD Ryzen 7 8745H) ==="
echo ""

# Check if running as regular user (yay requires non-root)
if [ "$EUID" -eq 0 ]; then
    echo "ERROR: Do not run as root. Run as regular user (yay requires non-root)."
    exit 1
fi

# 1. Ensure required firmware is installed
echo "[1/3] Checking required firmware packages..."
REQUIRED_PACKAGES=(
    "amd-ucode"             # AMD CPU microcode
    "linux-firmware"        # Base firmware (includes AMD GPU, Realtek, MediaTek)
    "linux-firmware-whence" # Firmware metadata
)

for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if pacman -Qi "$pkg" &>/dev/null; then
        echo "    ✓ $pkg already installed"
    else
        echo "    Installing $pkg..."
        sudo pacman -S --noconfirm "$pkg"
    fi
done

# 2. Remove unnecessary AUR firmware packages
echo ""
echo "[2/3] Removing unnecessary AUR firmware packages..."
UNNECESSARY_AUR=(
    "aic94xx-firmware"   # Adaptec SAS controllers - no Adaptec hardware
    "ast-firmware"       # ASPEED BMC graphics - no BMC hardware
    "upd72020x-fw"       # Renesas USB 3.0 controllers - AMD USB only
    "wd719x-firmware"    # Western Digital SCSI - no WD SCSI hardware
)

for pkg in "${UNNECESSARY_AUR[@]}"; do
    if pacman -Qi "$pkg" &>/dev/null; then
        echo "    Removing $pkg (not needed for this hardware)..."
        yay -Rns --noconfirm "$pkg" 2>/dev/null || sudo pacman -Rns --noconfirm "$pkg"
    else
        echo "    ✓ $pkg not installed (good)"
    fi
done

# 3. Verify no missing firmware
echo ""
echo "[3/3] Checking for missing firmware errors..."
MISSING=$(dmesg | grep -i "firmware" | grep -i "failed\|missing\|not found" | head -5)
if [ -z "$MISSING" ]; then
    echo "    ✓ No missing firmware errors detected"
else
    echo "    ⚠ Potential firmware issues detected:"
    echo "$MISSING" | sed 's/^/      /'
fi

echo ""
echo "=== Firmware Management Complete ==="
echo ""
echo "Installed firmware:"
pacman -Qs "firmware\|ucode" | grep "^local" | sed 's/^/  /'
