#!/bin/bash
# K3s Node Setup Script
# Run with: sudo bash setup-node.sh
#
# This script bootstraps a K3s node. Only one-shot, boot-time, or hardware-level
# setup lives here; drift-prone config (sysctls, sshd, kubelet, systemd drop-ins,
# udev, tmpfiles, journald, logrotate) is owned by ansible roles in
# docs/scripts/node-maintenance/ansible/roles/ and applied daily by timer.
#
# Sections:
# 1. Packages & firmware (auto-detects Intel/AMD)
# 2. Power/performance runtime knobs (cpupower, EPP, NVMe/SATA one-shots)
# 3. Bootloader + non-drift security (boot params, PermitEmptyPasswords, timers)
# 4. K3s config (control-plane or worker, auto-detected)
# 5. systemd reload (drop-ins placed by ansible)
#
# Works for both control-plane and worker nodes (auto-detected)

set -e

echo "=============================================="
echo "       K3s Node Setup Script"
echo "=============================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Run as root: sudo bash setup-node.sh"
    exit 1
fi

# Detect node type
HOSTNAME=$(cat /etc/hostname)
if systemctl is-active --quiet k3s; then
    NODE_TYPE="control-plane"
    K3S_SERVICE="k3s"
elif systemctl is-active --quiet k3s-agent; then
    NODE_TYPE="worker"
    K3S_SERVICE="k3s-agent"
else
    echo "WARNING: K3s not detected. Assuming worker node."
    NODE_TYPE="worker"
    K3S_SERVICE="k3s-agent"
fi

# Detect CPU vendor (used for AUR conditional + amd_pstate boot param).
# Microcode package ownership moved to ansible (host_vars/*.yml ucode_pkg).
CPU_VENDOR=$(grep -m1 "vendor_id" /proc/cpuinfo | awk '{print $3}')
if [ "$CPU_VENDOR" = "GenuineIntel" ]; then
    CPU_TYPE="Intel"
elif [ "$CPU_VENDOR" = "AuthenticAMD" ]; then
    CPU_TYPE="AMD"
else
    echo "ERROR: Unknown CPU vendor: $CPU_VENDOR"
    exit 1
fi

echo "Hostname:   $HOSTNAME"
echo "Node type:  $NODE_TYPE"
echo "CPU:        $CPU_TYPE ($CPU_VENDOR)"
echo "K3s service: $K3S_SERVICE"
echo ""

#######################################
# 1. BOOTSTRAP PACKAGES (ansible stack + AUR)
#######################################
echo "=============================================="
echo "[1/5] Bootstrap Packages"
echo "=============================================="
# Scope kept minimal: whatever ansible itself needs to run. Everything else
# (base-devel, linux-lts, ucode, mesa, vulkan, rebuilderd, fail2ban, lynis,
# rkhunter, ufw, etc.) is ansible-managed (roles/packages) — declared in
# group_vars/all.yml + host_vars/*.yml (ucode_pkg, gpu_vendor). Drift-healed
# daily by node-config timer.
#
# Ansible stack bootstrap is CP-only — only CP runs ansible-playbook. Workers
# need only python3 (Arch base) + openssh + sudo for ansible to reach them.

if [ "$NODE_TYPE" = "control-plane" ]; then
    echo "Installing ansible stack (CP-only; install.sh Preconditions pass through)..."
    pacman -S --noconfirm --needed ansible jq rsync logrotate python-kubernetes 2>/dev/null || true
fi

# AUR bootstrap (all nodes): yay + optional firmware. Reason kept in bash:
#   - kewlfft.aur ansible module requires per-user makepkg.conf on
#     node-maintenance (clashes with rebuilderd /etc/makepkg.conf.d/storage.conf)
#   - These AUR pkgs install once, never update — zero drift-heal value
#   - yay itself is AUR — chicken-egg before any AUR ansible task could run
echo "Installing optional firmware (AUR)..."
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
        # Create user makepkg.conf to override system BUILDDIR/SRCDEST/PKGDEST
        # (rebuilderd nodes set these to root-owned dirs in /etc/makepkg.conf.d/storage.conf,
        # which breaks AUR builds as a regular user)
        USER_HOME=$(eval echo "~$SUDO_USER")
        USER_MAKEPKG="$USER_HOME/.makepkg.conf"
        if [ ! -f "$USER_MAKEPKG" ]; then
            echo "  Creating $USER_MAKEPKG (override rebuilderd BUILDDIR)..."
            cat > "$USER_MAKEPKG" << MKEOF
# Override /etc/makepkg.conf.d/storage.conf which points to rebuilderd root-owned dirs
BUILDDIR="\$HOME/.cache/makepkg/build"
SRCDEST="\$HOME/.cache/makepkg/sources"
PKGDEST="\$HOME/.cache/makepkg/packages"
MKEOF
            chown "$SUDO_USER:$SUDO_USER" "$USER_MAKEPKG"
            sudo -u "$SUDO_USER" mkdir -p "$USER_HOME/.cache/makepkg"/{build,sources,packages}
        fi
        for pkg in $AUR_PKGS; do
            if ! pacman -Qi "$pkg" &>/dev/null; then
                sudo -u "$SUDO_USER" $AUR_HELPER -S --noconfirm --needed "$pkg" 2>/dev/null && echo "  Installed: $pkg" || true
            fi
        done
    else
        echo "  Skipped: Cannot run $AUR_HELPER as root, install manually"
    fi
else
    echo "  Skipped: No AUR helper (yay/paru) found"
    echo "  To install manually: yay -S aic94xx-firmware ast-firmware wd719x-firmware upd72020x-fw"
fi
echo "  Done: Firmware configured"
echo ""

#######################################
# 2. PERFORMANCE OPTIMIZATION
#######################################
echo "=============================================="
echo "[2/5] Performance Runtime Knobs"
echo "=============================================="

# CPU Governor (powersave with balance_power EPP)
# Using powersave (not performance) to reduce noise and heat on mini PCs
# that also run rebuilderd alongside K3s workloads
echo "Setting CPU governor to powersave..."
if command -v cpupower &>/dev/null; then
    cpupower frequency-set -g powersave 2>/dev/null || true
else
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo powersave > "$cpu" 2>/dev/null || true
    done
fi

# Set Energy Performance Preference (EPP) to balance_power
echo "Setting EPP to balance_power..."
for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
    echo balance_power > "$epp" 2>/dev/null || true
done

# tmpfiles.d/cpu-power-settings.conf + sysctl.d/99-k8s-performance.conf: owned by ansible roles/hardening (Phase D)
# Legacy cleanup (51-kptr-restrict.conf, 99-security-hardening.conf, cpu-governor.conf): also ansible-owned.

echo "  Done: Performance runtime knobs applied (config files managed by ansible)"
echo ""

#######################################
# 3. SECURITY HARDENING
#######################################
echo "=============================================="
echo "[3/5] Bootloader + Non-Drift Security"
echo "=============================================="

# sysctl.d/99-unified-hardening.conf + 99-watchdog.conf + systemd/system.conf.d/watchdog.conf:
# owned by ansible roles/hardening (Phase D). Bootstrap only applies runtime one-shots below.

# Bootloader kernel parameters in /boot/loader/entries/*.conf kept in setup-node.sh
# intentionally (not ansible). Reason: systemd-boot entries are NOT regenerated by
# mkinitcpio or kernel upgrades, so drift risk is low. Bad regex via ansible lineinfile
# = unbootable node; recovery requires IPMI/USB. Manual bootstrap > daily drift-heal here.

# Crash logging: EFI pstore + printk dump
echo "Enabling crash logging (EFI pstore, printk dump)..."
CRASH_PARAMS="efi_pstore.pstore_disable=0 printk.always_kmsg_dump=Y panic=10"
for entry in /boot/loader/entries/*lts*.conf; do
    [[ -f "$entry" ]] || continue
    current_options=$(grep "^options " "$entry")
    new_options=$(echo "$current_options" | sed \
        -e 's/ efi_pstore\.pstore_disable=[^ ]*//g' \
        -e 's/ printk\.always_kmsg_dump=[^ ]*//g' \
        -e 's/ panic=[^ ]*//g')
    new_options="${new_options} ${CRASH_PARAMS}"
    sed -i "s|^options .*|${new_options}|" "$entry"
    echo "  Updated $(basename "$entry")"
done
# Enable printk dump at runtime
[[ -f /sys/module/printk/parameters/always_kmsg_dump ]] && echo Y > /sys/module/printk/parameters/always_kmsg_dump

# sshd_config.d/99-hardening.conf owns all SSH hardening (including
# PermitEmptyPasswords no) — ansible roles/hardening (Phase D).

# AMD P-state: add amd_pstate=active to boot entries for AMD CPUs
if [ "$CPU_TYPE" = "AMD" ]; then
    echo "Adding amd_pstate=active to boot entries..."
    for conf in /boot/loader/entries/*.conf; do
        if [ -f "$conf" ] && ! grep -q "amd_pstate=active" "$conf"; then
            sed -i '/^options / s/$/ amd_pstate=active/' "$conf"
            echo "  Added amd_pstate=active to $(basename "$conf")"
        fi
    done
fi

# resolved.conf.d/no-llmnr.conf: owned by ansible roles/hardening (Phase D)

# fstrim.timer + paccache.timer enable: owned by ansible roles/base_config.

# Disable SSD/NVMe power saving (runtime one-shots; config files managed by ansible roles/hardening)
echo "Applying NVMe/SATA power runtime knobs..."

# NVMe: Apply APST disable at runtime (persistent config in modprobe.d, ansible-owned)
echo 0 > /sys/module/nvme_core/parameters/default_ps_max_latency_us 2>/dev/null || true

# NVMe: Apply power/control=on at runtime to existing devices
for d in /sys/block/nvme*/device/power/control; do
    echo on > "$d" 2>/dev/null || true
done

# PCIe ASPM: Add pcie_aspm=off to bootloader entries
for conf in /boot/loader/entries/*.conf; do
    if [ -f "$conf" ] && ! grep -q "pcie_aspm=off" "$conf"; then
        sed -i 's/^options /options pcie_aspm=off /' "$conf"
        echo "  Added pcie_aspm=off to $(basename "$conf")"
    fi
done

# Reload udev rules
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --subsystem-match=pci --attr-match=class=0x010802 2>/dev/null || true

# SATA: Apply ALPM runtime (persistent udev rule in /etc/udev/rules.d/60-sata-no-alpm.rules, ansible-owned)
for host in /sys/class/scsi_host/host*/link_power_management_policy; do
    echo max_performance > "$host" 2>/dev/null || true
done

echo "  Done: SSD/NVMe power saving disabled"
echo ""

#######################################
# 4. K3S CONFIG DIRECTORY (content ansible-managed)
#######################################
echo "=============================================="
echo "[4/5] K3s Config Directory"
echo "=============================================="
# /etc/rancher/k3s/config.yaml + /etc/rancher/k3s/kubelet.yaml are ansible-owned
# (roles/k3s_config, roles/hardening). Bootstrap only ensures the directory exists
# so K3s daemon has a place to read from on fresh install.
mkdir -p /etc/rancher/k3s/
echo "  Done: /etc/rancher/k3s/ exists (config.yaml + kubelet.yaml placed by ansible)"
echo ""

#######################################
# 5. SYSTEM SERVICES (ansible-managed config)
#######################################
echo "=============================================="
echo "[5/5] System Services"
echo "=============================================="
# Config files now managed by ansible roles (applied after node-maintenance install):
#   - base_config (Phase A): /etc/systemd/journald.conf.d/99-caps.conf, logrotate, sudoers
#   - hardening  (Phase D): kubelet.yaml, systemd/system.conf.d/watchdog.conf,
#                           system.conf DefaultTimeout{Start,Stop}Sec,
#                           k3s(-agent).service.d/{shutdown-timeout,conntrack-fix,network-hardening}.conf
# Bootstrap only reloads systemd so any pre-existing drop-ins are recognized.
systemctl daemon-reload

echo "  Done: systemd reloaded (drop-ins + kubelet.yaml will be placed by ansible)"
echo ""

#######################################
# SUMMARY
#######################################
echo "=============================================="
echo "       Setup Complete"
echo "=============================================="
echo ""
echo "Applied by bootstrap:"
echo "  - AUR: yay, aic94xx/ast/wd719x/upd72020x firmware (mkinitcpio warnings)"
echo "  - User makepkg.conf: BUILDDIR/SRCDEST/PKGDEST override for rebuilderd nodes"
echo "  - CPU runtime: powersave governor, balance_power EPP"
echo "  - NVMe/SATA: APST disabled, power/control=on, SATA max_performance"
echo "  - Bootloader: efi_pstore, printk dump, panic=10, pcie_aspm=off" \
     "(AMD: amd_pstate=active)"
echo "  - Timers: fstrim.timer, paccache.timer"
echo "  - K3s config: $NODE_TYPE (node-name: $HOSTNAME)"
echo ""
echo "Owned by ansible roles (applied after install.sh; drift-healed daily):"
echo "  - packages: pacman-native base + per-host ucode + per-host GPU stack + worker-only"
echo "  - base_config: journald caps, logrotate, sudoers, fstrim/paccache timers"
echo "  - k3s_config: /etc/rancher/k3s/config.yaml (drift-alert only, manual restart)"
echo "  - firewall: UFW rules"
echo "  - hardening: sysctls (unified/k8s-performance/watchdog), sshd drop-in"
echo "               (incl. PermitEmptyPasswords), kubelet.yaml, systemd watchdog"
echo "               + timeouts, k3s service.d drop-ins, resolved LLMNR,"
echo "               NVMe/SATA udev+modprobe, CPU/NVMe tmpfiles"
echo "  - security_scan: lynis + rkhunter monthly timer + script"
echo "  - rebuilderd (workers): watchdog, metrics, repro-cleanup"
echo "  - k3s_image_gc: weekly crictl rmi --prune"
echo ""
if [ "$NODE_TYPE" = "control-plane" ]; then
    echo "Next steps:"
    echo "  1. Install node-maintenance (ansible applies packages/firewall/hardening/k3s_config/etc.):"
    echo "       sudo bash docs/scripts/node-maintenance/install.sh"
    echo "  2. Restart K3s to apply config.yaml: sudo systemctl restart $K3S_SERVICE"
    echo "  3. Enable secrets encryption (control-plane only, one-time):"
    echo "       sudo k3s secrets-encrypt enable"
    echo "       sudo systemctl restart k3s"
    echo "       sudo k3s secrets-encrypt rotate-keys"
    echo "       sudo systemctl restart k3s"
    echo "       sudo k3s secrets-encrypt status  # Expect: Enabled + reencrypt_finished"
else
    echo "Next steps:"
    echo "  1. Install node-maintenance worker bits (ansible from CP applies the rest):"
    echo "       sudo bash docs/scripts/node-maintenance/install-worker.sh"
    echo "  2. After first ansible run on CP: restart K3s to apply config.yaml:"
    echo "       sudo systemctl restart $K3S_SERVICE"
fi
echo ""
