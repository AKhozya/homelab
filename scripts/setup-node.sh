#!/bin/bash
# K3s Node Setup Script
# Run with: sudo bash scripts/setup-node.sh [control-plane|worker]
# If no role is passed, the script reads it from the running k3s unit. A node bootstrapped
# before k3s is installed has none, so pass the role there.
#
# Bootstrap-only: AUR firmware, ansible stack (CP), bootloader kernel params,
# K3s config directory. Everything else — sysctls, sshd, kubelet, udev,
# tmpfiles, journald, logrotate, UFW, packages, K3s config.yaml — is owned
# by ansible roles (node-maintenance/ansible/roles/) and
# drift-healed twice a day (03:00 and 15:00 UTC) by node-maintenance-config.timer.
#
# Sections:
#   1. Bootstrap packages (ansible stack CP-only + AUR firmware suppressors)
#   2. Bootloader kernel params (systemd-boot entries — not ansible-managed)
#   3. K3s config directory stub

set -euo pipefail

echo "=============================================="
echo "       K3s Node Setup Script"
echo "=============================================="
echo ""

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Run as root: sudo bash setup-node.sh"
    exit 1
fi

HOSTNAME=$(cat /etc/hostname)
NODE_TYPE="${1:-}"
if [ -z "$NODE_TYPE" ]; then
    if systemctl is-active --quiet k3s; then
        NODE_TYPE="control-plane"
    elif systemctl is-active --quiet k3s-agent; then
        NODE_TYPE="worker"
    else
        echo "ERROR: K3s is not running, so the role is unknown."
        echo "       Run one of:"
        echo "         sudo bash scripts/setup-node.sh control-plane"
        echo "         sudo bash scripts/setup-node.sh worker"
        exit 1
    fi
fi
case "$NODE_TYPE" in
    control-plane) K3S_SERVICE="k3s" ;;
    worker) K3S_SERVICE="k3s-agent" ;;
    *)
        echo "ERROR: role must be control-plane or worker, got '$NODE_TYPE'"
        exit 1
        ;;
esac

# CPU vendor decides the AMD amd_pstate boot param.
# Microcode package: ansible-managed (host_vars/*.yml ucode_pkg).
CPU_VENDOR=$(grep -m1 "vendor_id" /proc/cpuinfo | awk '{print $3}')
if [ "$CPU_VENDOR" = "GenuineIntel" ]; then
    CPU_TYPE="Intel"
elif [ "$CPU_VENDOR" = "AuthenticAMD" ]; then
    CPU_TYPE="AMD"
else
    echo "ERROR: Unknown CPU vendor: $CPU_VENDOR"
    exit 1
fi

echo "Hostname:    $HOSTNAME"
echo "Node type:   $NODE_TYPE"
echo "CPU:         $CPU_TYPE ($CPU_VENDOR)"
echo "K3s service: $K3S_SERVICE"
echo ""

#######################################
# 1. BOOTSTRAP PACKAGES
#######################################
echo "=============================================="
echo "[1/3] Bootstrap Packages"
echo "=============================================="

# Ansible stack (CP-only — only CP runs ansible-playbook; workers need only
# python3 + openssh + sudo from Arch base).
if [ "$NODE_TYPE" = "control-plane" ]; then
    echo "Installing ansible stack..."
    # Not best-effort: node-maintenance/install.sh refuses to run without these.
    pacman -S --noconfirm --needed ansible jq rsync logrotate python-kubernetes
fi

# AUR firmware (mkinitcpio warning suppressors). Kept in bash, not ansible, for two reasons.
# The kewlfft.aur module needs a per-user makepkg.conf on the node-maintenance user
# to guarantee a writable BUILDDIR that overrides any system /etc/makepkg.conf.d/ entry.
# These packages install once and never update, so drift-heal gains nothing.
echo "Installing AUR firmware..."
# kernel-modules-hook does not belong here: it lives in `extra`, not the AUR.
# ansible's pacman_packages_base installs it on every node-config run. It moved out
# of this list on 2026-07-18.
AUR_PKGS="aic94xx-firmware ast-firmware wd719x-firmware upd72020x-fw"
AUR_HELPER=""
if command -v yay &>/dev/null; then
    AUR_HELPER="yay"
elif command -v paru &>/dev/null; then
    AUR_HELPER="paru"
fi
if [ -n "$AUR_HELPER" ]; then
    SUDO_USER=${SUDO_USER:-$(who | head -1 | awk '{print $1}')}
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        # Per-user makepkg.conf override: guarantees writable BUILDDIR/SRCDEST/
        # PKGDEST so AUR builds work as a regular user even if a system-wide
        # /etc/makepkg.conf.d/ entry points them at root-owned dirs.
        USER_HOME=$(eval echo "~$SUDO_USER")
        USER_MAKEPKG="$USER_HOME/.makepkg.conf"
        if [ ! -f "$USER_MAKEPKG" ]; then
            echo "  Creating $USER_MAKEPKG..."
            cat > "$USER_MAKEPKG" << MKEOF
BUILDDIR="\$HOME/.cache/makepkg/build"
SRCDEST="\$HOME/.cache/makepkg/sources"
PKGDEST="\$HOME/.cache/makepkg/packages"
MKEOF
            chown "$SUDO_USER:$SUDO_USER" "$USER_MAKEPKG"
            sudo -u "$SUDO_USER" mkdir -p "$USER_HOME/.cache/makepkg"/{build,sources,packages}
        fi
        # Report failures so a node cannot finish bootstrap silently
        # missing packages. immich-vm lacked kernel-modules-hook
        # that way until the modprobe cascade surfaced it on 2026-07-18.
        # Still non-fatal: these are optional HW firmware blobs, and a build failure
        # must not abort the rest of the bootstrap.
        AUR_FAILED=""
        for pkg in $AUR_PKGS; do
            if ! pacman -Qi "$pkg" &>/dev/null; then
                if sudo -u "$SUDO_USER" $AUR_HELPER -S --noconfirm --needed "$pkg"; then
                    echo "  Installed: $pkg"
                else
                    echo "  FAILED: $pkg (rc=$?)" >&2
                    AUR_FAILED="$AUR_FAILED $pkg"
                fi
            fi
        done
        if [ -n "$AUR_FAILED" ]; then
            echo "" >&2
            echo "  !! AUR packages NOT installed:$AUR_FAILED" >&2
            echo "  !! Bootstrap continued, but this node is missing them. Retry with:" >&2
            echo "  !!   sudo -u $SUDO_USER $AUR_HELPER -S --needed$AUR_FAILED" >&2
        fi
    else
        echo "  Skipped: Cannot run $AUR_HELPER as root, install manually" >&2
    fi
else
    echo "  Skipped: No AUR helper (yay/paru) found" >&2
    echo "  To install manually: yay -S $AUR_PKGS" >&2
fi
echo ""

#######################################
# 2. BOOTLOADER KERNEL PARAMS
#######################################
echo "=============================================="
echo "[2/3] Bootloader Kernel Params"
echo "=============================================="
# systemd-boot entries in /boot/loader/entries/*.conf kept here (not ansible):
# drift risk is low (not regenerated by mkinitcpio or kernel upgrades) and
# a bad ansible regex on these files = unbootable node, recovery via IPMI/USB.

# Crash logging: EFI pstore + printk dump + panic reboot
echo "Enabling crash logging..."
CRASH_PARAMS="efi_pstore.pstore_disable=0 printk.always_kmsg_dump=Y panic=10"
for entry in /boot/loader/entries/*lts*.conf; do
    [[ -f "$entry" ]] || continue
    current_options=$(grep "^options " "$entry" || true)
    [[ -n "$current_options" ]] || continue
    new_options=$(echo "$current_options" | sed \
        -e 's/ efi_pstore\.pstore_disable=[^ ]*//g' \
        -e 's/ printk\.always_kmsg_dump=[^ ]*//g' \
        -e 's/ panic=[^ ]*//g')
    new_options="${new_options} ${CRASH_PARAMS}"
    sed -i "s|^options .*|${new_options}|" "$entry"
    echo "  Updated $(basename "$entry")"
done
# Runtime toggle (no reboot needed for immediate effect)
[[ -f /sys/module/printk/parameters/always_kmsg_dump ]] && echo Y > /sys/module/printk/parameters/always_kmsg_dump

# AMD P-state active driver (AMD CPUs only)
if [ "$CPU_TYPE" = "AMD" ]; then
    echo "Adding amd_pstate=active..."
    for conf in /boot/loader/entries/*.conf; do
        if [ -f "$conf" ] && ! grep -q "amd_pstate=active" "$conf"; then
            sed -i '/^options / s/$/ amd_pstate=active/' "$conf"
            echo "  Added to $(basename "$conf")"
        fi
    done
fi

# PCIe ASPM off (NVMe latency + interrupt stability)
echo "Adding pcie_aspm=off..."
for conf in /boot/loader/entries/*.conf; do
    if [ -f "$conf" ] && ! grep -q "pcie_aspm=off" "$conf"; then
        sed -i 's/^options /options pcie_aspm=off /' "$conf"
        echo "  Added to $(basename "$conf")"
    fi
done
echo ""

#######################################
# 3. K3S CONFIG DIRECTORY
#######################################
echo "=============================================="
echo "[3/3] K3s Config Directory"
echo "=============================================="
# /etc/rancher/k3s/config.yaml + kubelet.yaml are ansible-owned
# (roles/k3s_config, roles/hardening). Bootstrap ensures directory exists.
mkdir -p /etc/rancher/k3s/
echo "  Done"
echo ""

#######################################
# SUMMARY
#######################################
echo "=============================================="
echo "       Setup Complete"
echo "=============================================="
echo ""
echo "Bootstrap applied:"
echo "  - AUR firmware: aic94xx/ast/wd719x/upd72020x (mkinitcpio warning suppressors)"
echo "  - User makepkg.conf: writable BUILDDIR/SRCDEST/PKGDEST override for AUR builds"
if [ "$NODE_TYPE" = "control-plane" ]; then
    echo "  - Ansible stack: ansible, jq, rsync, logrotate, python-kubernetes"
fi
echo "  - Bootloader: efi_pstore, printk dump, panic=10, pcie_aspm=off" \
     "$([ "$CPU_TYPE" = "AMD" ] && echo ', amd_pstate=active')"
echo "  - K3s config directory stub"
echo ""
echo "The roles in node-maintenance/ansible/node-config.yml own the rest. install.sh applies"
echo "them, and node-maintenance-config.timer re-applies them at 03:00 and 15:00 UTC."
echo ""
if [ "$NODE_TYPE" = "control-plane" ]; then
    echo "Next steps (docs/setup/K3S_SETUP.md, Control plane):"
    if ! systemctl is-active --quiet k3s; then
        echo "  0. K3s is not running. Write its config before the first start, then install it:"
        echo "       sudo ansible-playbook -i node-maintenance/ansible/inventory.yml \\"
        echo "         node-maintenance/ansible/node-config.yml -l gmk-k3s-control-plane \\"
        echo "         --tags k3s-config,kubelet --skip-tags secrets-encryption"
        echo "       then install the pinned K3s version from K3S_SETUP.md"
    fi
    echo "  1. Install node-maintenance, then run the full drift-heal:"
    echo "       sudo bash node-maintenance/install.sh"
    echo "       sudo systemctl start node-maintenance-config.service"
    echo "  2. Reboot to apply the bootloader params"
else
    echo "Next steps:"
    echo "  1. On the CP, run node-maintenance/install.sh. It writes"
    echo "     /tmp/install-worker-ready.sh (install-worker.sh with the CP's public key) and"
    echo "     prints the scp + ssh commands that run it on each worker. Do not run"
    echo "     install-worker.sh from the repo: its key placeholder makes it exit."
    echo "  2. Reboot (or restart k3s-agent) after first CP ansible run picks up new config"
fi
echo ""
