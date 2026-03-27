#!/bin/bash
# Enable crash diagnostics on all K3s nodes
# Run as root: sudo bash enable-crash-logging.sh
#
# What this enables:
#   1. Hardware watchdog via systemd (distinguishes kernel freeze from power loss)
#   2. EFI pstore (saves kernel panic/oops to NVRAM, survives hard reboot)
#   3. printk crash dump (flushes log buffer to pstore on crash)
#   4. Panic reboot timeout (auto-reboot 10s after panic instead of hanging)
#
# After reboot, verify with:
#   cat /sys/class/watchdog/watchdog0/state  # should show "active"
#   cat /sys/module/efi_pstore/parameters/pstore_disable  # should show "N"
#   cat /sys/module/printk/parameters/always_kmsg_dump  # should show "Y"
#   ls /sys/fs/pstore/  # will contain crash data after next panic

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root: sudo bash $0"
    exit 1
fi

HOSTNAME=$(cat /etc/hostname 2>/dev/null || hostname 2>/dev/null || echo "unknown")
echo "=== Enabling crash diagnostics on ${HOSTNAME} ==="

# --- 1. Hardware watchdog via systemd ---
echo "[1/4] Enabling hardware watchdog via systemd..."
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/watchdog.conf << 'EOF'
# Hardware watchdog - systemd kicks the watchdog periodically.
# If PID 1 freezes (kernel hang, deadlock), hardware forces reboot.
# After such reboot, journalctl will show no graceful shutdown = watchdog triggered.
[Manager]
RuntimeWatchdogSec=30
RebootWatchdogSec=10min
EOF
echo "  Created /etc/systemd/system.conf.d/watchdog.conf"

# --- 2. Kernel cmdline: EFI pstore + printk dump + panic timeout ---
echo "[2/4] Updating kernel command line..."

# Find the main boot entry
BOOT_ENTRY=$(ls /boot/loader/entries/*lts.conf 2>/dev/null | grep -v fallback | head -1)
FALLBACK_ENTRY=$(ls /boot/loader/entries/*lts-fallback.conf 2>/dev/null | head -1)

if [[ -z "$BOOT_ENTRY" ]]; then
    echo "ERROR: No *lts.conf boot entry found in /boot/loader/entries/"
    exit 1
fi

# Parameters to add
CRASH_PARAMS="efi_pstore.pstore_disable=0 printk.always_kmsg_dump=Y panic=10"

for entry in "$BOOT_ENTRY" "$FALLBACK_ENTRY"; do
    [[ -z "$entry" ]] && continue

    current_options=$(grep "^options " "$entry")
    needs_update=false

    for param in $CRASH_PARAMS; do
        if ! echo "$current_options" | grep -q "$param"; then
            needs_update=true
            break
        fi
    done

    if $needs_update; then
        # Remove any existing crash params (idempotent)
        new_options=$(echo "$current_options" | sed \
            -e 's/ efi_pstore\.pstore_disable=[^ ]*//g' \
            -e 's/ printk\.always_kmsg_dump=[^ ]*//g' \
            -e 's/ panic=[^ ]*//g')
        # Append crash params
        new_options="${new_options} ${CRASH_PARAMS}"
        # Replace in file
        sed -i "s|^options .*|${new_options}|" "$entry"
        echo "  Updated $(basename "$entry")"
    else
        echo "  $(basename "$entry") already has crash params"
    fi
done

# --- 3. Apply printk dump at runtime (no reboot needed for this one) ---
echo "[3/4] Enabling printk crash dump at runtime..."
if [[ -f /sys/module/printk/parameters/always_kmsg_dump ]]; then
    echo Y > /sys/module/printk/parameters/always_kmsg_dump
    echo "  printk.always_kmsg_dump = Y (active now)"
else
    echo "  SKIP: /sys/module/printk/parameters/always_kmsg_dump not available"
fi

# --- 4. Set panic timeout at runtime ---
echo "[4/4] Setting panic timeout..."
sysctl -w kernel.panic=10 >/dev/null 2>&1
echo "  kernel.panic = 10 (reboot 10s after panic)"

# Also persist panic timeout via sysctl
if ! grep -q "kernel.panic" /etc/sysctl.d/99-watchdog.conf 2>/dev/null; then
    echo "" >> /etc/sysctl.d/99-watchdog.conf
    echo "# Auto-reboot 10 seconds after kernel panic" >> /etc/sysctl.d/99-watchdog.conf
    echo "kernel.panic=10" >> /etc/sysctl.d/99-watchdog.conf
    sysctl -p /etc/sysctl.d/99-watchdog.conf >/dev/null 2>&1
    echo "  Added kernel.panic=10 to /etc/sysctl.d/99-watchdog.conf"
fi

echo ""
echo "=== Done ==="
echo ""
echo "What was enabled:"
echo "  - Hardware watchdog (30s): systemd kicks it; if kernel freezes, hardware reboots"
echo "  - EFI pstore: kernel panic logs saved to NVRAM (check /sys/fs/pstore/ after crash)"
echo "  - printk crash dump: log buffer flushed to pstore on panic"
echo "  - panic=10: auto-reboot 10s after kernel panic"
echo ""
echo "REBOOT REQUIRED for:"
echo "  - Hardware watchdog activation (systemd reads config at boot)"
echo "  - EFI pstore (kernel cmdline parameter)"
echo ""
echo "After reboot, verify:"
echo "  cat /sys/class/watchdog/watchdog0/state   # expect: active"
echo "  cat /sys/module/efi_pstore/parameters/pstore_disable  # expect: N"
echo "  cat /sys/module/printk/parameters/always_kmsg_dump    # expect: Y"
echo ""
echo "After next crash, check:"
echo "  ls -la /sys/fs/pstore/    # will contain dmesg-efi-* files"
echo "  journalctl -b -1 | tail   # last lines before crash"
