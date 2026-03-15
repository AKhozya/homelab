#!/bin/bash
# Firmware update script using fwupd
# Run as root: sudo bash update-firmware.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root (sudo bash $0)"
    exit 1
fi

HOSTNAME=$(cat /etc/hostname)
echo "=== Firmware Update: ${HOSTNAME} ==="
echo ""

# Install fwupd if missing
if ! command -v fwupdmgr &>/dev/null; then
    echo "Installing fwupd..."
    pacman -S --noconfirm fwupd
    echo ""
fi

# Show detected devices
echo "=== Detected Devices ==="
fwupdmgr get-devices --no-unreported-check 2>/dev/null || true
echo ""

# Refresh metadata
echo "=== Refreshing Metadata ==="
fwupdmgr refresh --force 2>/dev/null || true
echo ""

# Check for updates
echo "=== Available Updates ==="
if fwupdmgr get-updates --no-unreported-check 2>/dev/null; then
    echo ""
    read -rp "Apply firmware updates? [y/N] " confirm
    if [[ "${confirm}" =~ ^[Yy]$ ]]; then
        fwupdmgr update --no-unreported-check
        echo ""
        echo "Firmware updated. Reboot may be required."
    else
        echo "Skipped."
    fi
else
    echo "No firmware updates available."
fi

echo ""
echo "=== Done: ${HOSTNAME} ==="
