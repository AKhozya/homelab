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

# Detect CPU vendor
CPU_VENDOR=$(grep -m1 "vendor_id" /proc/cpuinfo | awk '{print $3}')
if [ "$CPU_VENDOR" = "GenuineIntel" ]; then
    CPU_TYPE="Intel"
    UCODE_PKG="intel-ucode"
elif [ "$CPU_VENDOR" = "AuthenticAMD" ]; then
    CPU_TYPE="AMD"
    UCODE_PKG="amd-ucode"
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
# 1. PACKAGES & FIRMWARE
#######################################
echo "=============================================="
echo "[1/5] Packages & Firmware"
echo "=============================================="

# Install essential packages
echo "Installing essential packages..."
ESSENTIAL_PKGS="base-devel bash-completion btop efibootmgr ethtool fail2ban fwupd fzf git go
    inetutils jq linux-lts linux-lts-headers lvm2 lynis nvme-cli openssh pacman-contrib
    reflector rkhunter rsync smartmontools sysstat tree ufw ufw-extras vim yay yq"
pacman -S --noconfirm --needed $ESSENTIAL_PKGS 2>/dev/null || true

# Worker-only packages: rebuilderd for reproducible builds
if [ "$NODE_TYPE" = "worker" ]; then
    echo "Installing worker-specific packages (rebuilderd)..."
    pacman -S --noconfirm --needed rebuilderd archlinux-repro 2>/dev/null || true
    # rebuilderd-watchdog + watchdog.timer + all units: owned by ansible roles/rebuilderd (Phase B)
fi

# GPU packages: mesa + vulkan (auto-detect GPU presence)
if lspci 2>/dev/null | grep -qi 'VGA\|3D\|Display'; then
    echo "Installing GPU packages (mesa, vulkan)..."
    GPU_PKGS="mesa vulkan-tools vulkan-mesa-implicit-layers"
    if [ "$CPU_TYPE" = "AMD" ]; then
        GPU_PKGS="$GPU_PKGS vulkan-radeon"
    elif [ "$CPU_TYPE" = "Intel" ]; then
        GPU_PKGS="$GPU_PKGS vulkan-intel"
    fi
    pacman -S --noconfirm --needed $GPU_PKGS 2>/dev/null || true
fi

# Install required firmware
echo "Installing firmware packages..."
pacman -S --noconfirm --needed $UCODE_PKG linux-firmware linux-firmware-whence 2>/dev/null || true

# Install optional firmware to suppress mkinitcpio warnings
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

# sshd_config.d/99-hardening.conf: owned by ansible roles/hardening (Phase D)

# Ensure PermitEmptyPasswords is set in main sshd_config
if ! grep -q "^PermitEmptyPasswords" /etc/ssh/sshd_config; then
    if grep -q "^PasswordAuthentication" /etc/ssh/sshd_config; then
        sed -i '/^PasswordAuthentication/a PermitEmptyPasswords no' /etc/ssh/sshd_config
    else
        echo "PermitEmptyPasswords no" >> /etc/ssh/sshd_config
    fi
    echo "  Added PermitEmptyPasswords no"
fi

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

# Enable SSD TRIM
systemctl enable --now fstrim.timer 2>/dev/null || true

# Enable pacman cache cleanup (keeps last 2 versions)
systemctl enable --now paccache.timer 2>/dev/null || true

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
# 4. K3S CONFIG
#######################################
echo "=============================================="
echo "[4/5] K3s Configuration"
echo "=============================================="

mkdir -p /etc/rancher/k3s/

if [ "$NODE_TYPE" = "control-plane" ]; then
    echo "Deploying control-plane K3s config..."
    cat > /etc/rancher/k3s/config.yaml << 'EOF'
# K3s Control Plane Configuration
# Deployed by setup-node.sh

# Storage: LVM on worker node for all PVCs
default-local-storage-path: /mnt/k8s-storage

# Disable Helm controller (Flux manages everything)
disable-helm-controller: true

# Disable K3s bundled Traefik (managed by Flux HelmRelease)
disable:
  - traefik

node-name: gmk-k3s-control-plane

# No workloads on control plane
node-taint:
  - "node-role.kubernetes.io/control-plane:NoSchedule"

# Exclude from ServiceLB traffic
node-label:
  - "svccontroller.k3s.cattle.io/enablelb=false"

kubelet-arg:
  - "config=/etc/rancher/k3s/kubelet.yaml"

# Clean up terminated (Failed/Succeeded) pods faster
# Default 12500 is too high for homelab — eviction leftovers linger after reboots
# 20 allows ~10 normal Job pods + headroom, GC reaps bulk eviction pods quickly
kube-controller-manager-arg:
  - "terminated-pod-gc-threshold=20"

# Secrets encrypted at rest (AES-CBC)
# After first deploy, run: k3s secrets-encrypt enable → restart → rotate-keys → restart
secrets-encryption: true
EOF
else
    echo "Deploying worker K3s config..."
    cat > /etc/rancher/k3s/config.yaml << EOF
# K3s Worker Node Configuration
# Deployed by setup-node.sh

node-name: ${HOSTNAME}

# Enable ServiceLB traffic on workers
node-label:
  - "svccontroller.k3s.cattle.io/enablelb=true"

kubelet-arg:
  - "config=/etc/rancher/k3s/kubelet.yaml"

# Note: K3s server URL and token are in /etc/systemd/system/k3s-agent.service.env
# To rejoin: curl -sfL https://get.k3s.io | K3S_URL=https://192.168.1.127:6443 K3S_TOKEN=<token> sh -
EOF
fi

echo "  Done: K3s config deployed to /etc/rancher/k3s/config.yaml"
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
echo "  - Packages: base-devel, btop, fail2ban, fwupd, git, go, jq, yq, rsync, etc."
echo "  - Workers: rebuilderd, archlinux-repro (units via ansible roles/rebuilderd)"
echo "  - GPU: mesa, vulkan (auto-detected)"
echo "  - User makepkg.conf: BUILDDIR/SRCDEST/PKGDEST override for rebuilderd nodes"
echo "  - CPU runtime: powersave governor, balance_power EPP"
echo "  - NVMe/SATA: APST disabled, power/control=on, SATA max_performance"
echo "  - Bootloader: efi_pstore, printk dump, panic=10, pcie_aspm=off" \
     "(AMD: amd_pstate=active)"
echo "  - SSH: PermitEmptyPasswords no (main sshd_config)"
echo "  - Timers: fstrim.timer, paccache.timer"
echo "  - K3s config: $NODE_TYPE (node-name: $HOSTNAME)"
echo ""
echo "Owned by ansible roles (applied after install.sh; drift-healed daily):"
echo "  - hardening: sysctls (unified/k8s-performance/watchdog), sshd drop-in,"
echo "               kubelet.yaml, systemd watchdog + timeouts, k3s service.d drop-ins,"
echo "               resolved LLMNR, NVMe/SATA udev+modprobe, CPU/NVMe tmpfiles"
echo "  - base_config: journald caps, logrotate, sudoers"
echo "  - firewall: UFW rules"
echo "  - rebuilderd (workers): watchdog, metrics, repro-cleanup"
echo "  - k3s_image_gc: weekly crictl rmi --prune"
echo ""
if [ "$NODE_TYPE" = "control-plane" ]; then
    echo "Next steps:"
    echo "  1. Restart K3s: sudo systemctl restart $K3S_SERVICE"
    echo "  2. Enable secrets encryption (control-plane only):"
    echo "       sudo k3s secrets-encrypt enable"
    echo "       # Add 'secrets-encryption: true' to /etc/rancher/k3s/config.yaml"
    echo "       sudo systemctl restart k3s"
    echo "       sudo k3s secrets-encrypt rotate-keys"
    echo "       sudo systemctl restart k3s"
    echo "       sudo k3s secrets-encrypt status  # Expect: Enabled + reencrypt_finished"
    echo "  3. Install node-maintenance (owns UFW via ansible firewall role):"
    echo "       sudo bash docs/scripts/node-maintenance/install.sh"
else
    echo "Next steps:"
    echo "  1. Restart K3s: sudo systemctl restart $K3S_SERVICE"
    echo "  2. Install node-maintenance worker bits (UFW rules applied from CP via ansible):"
    echo "       sudo bash docs/scripts/node-maintenance/install-worker.sh"
fi
echo ""
