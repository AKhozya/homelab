#!/bin/bash
# K3s Node Setup Script
# Run with: sudo bash setup-node.sh
#
# This script configures a K3s node with:
# 1. Firmware (auto-detects Intel/AMD)
# 2. Power/Performance optimization (powersave governor, balance_power EPP, SSD no-sleep, BBR)
# 3. Graceful shutdown (kubelet config)
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
# 1. FIRMWARE
#######################################
echo "=============================================="
echo "[1/3] Firmware Setup"
echo "=============================================="

# Install required firmware
echo "Installing firmware packages..."
pacman -S --noconfirm --needed $UCODE_PKG linux-firmware linux-firmware-whence 2>/dev/null || true

# Install optional firmware to suppress mkinitcpio warnings
echo "Installing optional firmware (AUR)..."
AUR_PKGS="aic94xx-firmware ast-firmware wd719x-firmware upd72020x-fw"
if command -v yay &>/dev/null; then
    sudo -u nobody true 2>/dev/null || true  # Test if we can drop privs
    # Find a non-root user to run yay
    SUDO_USER=${SUDO_USER:-$(who | head -1 | awk '{print $1}')}
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        for pkg in $AUR_PKGS; do
            if ! pacman -Qi "$pkg" &>/dev/null; then
                sudo -u "$SUDO_USER" yay -S --noconfirm --needed "$pkg" 2>/dev/null && echo "  Installed: $pkg" || true
            fi
        done
    else
        echo "  Skipped: Cannot run yay as root, install manually"
    fi
elif command -v paru &>/dev/null; then
    SUDO_USER=${SUDO_USER:-$(who | head -1 | awk '{print $1}')}
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        for pkg in $AUR_PKGS; do
            if ! pacman -Qi "$pkg" &>/dev/null; then
                sudo -u "$SUDO_USER" paru -S --noconfirm --needed "$pkg" 2>/dev/null && echo "  Installed: $pkg" || true
            fi
        done
    else
        echo "  Skipped: Cannot run paru as root, install manually"
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
echo "[2/3] Performance Optimization"
echo "=============================================="

# CPU Governor (powersave with balance_power EPP)
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

# Make CPU settings persistent (boost remains enabled for burst performance)
cat > /etc/tmpfiles.d/cpu-power-settings.conf << 'EOF'
# K3s Node CPU Power Settings
# Governor: powersave (efficient baseline, boost available when needed)
w /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor - - - - powersave
# EPP: balance_power (prioritize efficiency, but allow boost for bursts)
w /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference - - - - balance_power
EOF

# Kernel tuning
echo "Applying kernel tuning..."
cat > /etc/sysctl.d/99-k8s-performance.conf << 'EOF'
# K8s Performance Tuning

# Container support
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576

# Network performance
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 1024 65535

# TCP optimizations (BBR)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1

# TCP buffer sizes
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Connection tracking for K8s
net.netfilter.nf_conntrack_max = 1048576

# Memory management
vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
EOF
sysctl -p /etc/sysctl.d/99-k8s-performance.conf >/dev/null 2>&1

# Enable SSD TRIM
systemctl enable --now fstrim.timer 2>/dev/null || true

# Disable SSD/NVMe power saving
echo "Disabling SSD/NVMe power saving..."

# NVMe: Disable APST via modprobe (survives reboots)
cat > /etc/modprobe.d/nvme-no-apst.conf << 'EOF'
options nvme_core default_ps_max_latency_us=0
EOF
echo 0 > /sys/module/nvme_core/parameters/default_ps_max_latency_us 2>/dev/null || true

# NVMe: Disable PCI runtime power management via udev (for new devices)
cat > /etc/udev/rules.d/60-nvme-no-pm.rules << 'EOF'
# Disable runtime PM for NVMe devices
ACTION=="add", SUBSYSTEM=="pci", ATTR{class}=="0x010802", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="block", KERNEL=="nvme*", RUN+="/bin/sh -c 'echo on > /sys$devpath/device/power/control 2>/dev/null || true'"
EOF

# NVMe: Also use tmpfiles.d for reliability at boot (udev timing can be inconsistent)
cat > /etc/tmpfiles.d/nvme-no-pm.conf << 'EOF'
# Disable NVMe runtime power management at boot
w /sys/block/nvme*/device/power/control - - - - on
EOF

# Apply immediately to existing NVMe devices
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

# SATA: Set ALPM to max_performance
cat > /etc/udev/rules.d/60-sata-no-alpm.rules << 'EOF'
# Disable SATA Link Power Management (ALPM)
ACTION=="add", SUBSYSTEM=="scsi_host", KERNEL=="host*", ATTR{link_power_management_policy}="max_performance"
EOF
for host in /sys/class/scsi_host/host*/link_power_management_policy; do
    echo max_performance > "$host" 2>/dev/null || true
done

echo "  Done: Performance optimizations applied"
echo ""

#######################################
# 3. GRACEFUL SHUTDOWN
#######################################
echo "=============================================="
echo "[3/3] Graceful Shutdown Configuration"
echo "=============================================="

# Update systemd timeouts
echo "Configuring systemd timeouts..."
if grep -q "^DefaultTimeoutStopSec=" /etc/systemd/system.conf; then
    sed -i 's/^DefaultTimeoutStopSec=.*/DefaultTimeoutStopSec=120s/' /etc/systemd/system.conf
else
    echo "DefaultTimeoutStopSec=120s" >> /etc/systemd/system.conf
fi

# Create kubelet config
echo "Creating kubelet config..."
mkdir -p /etc/rancher/k3s/
cat > /etc/rancher/k3s/kubelet.yaml << 'EOF'
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
shutdownGracePeriod: 120s
shutdownGracePeriodCriticalPods: 30s
EOF

# Update K3s config
CONFIG_FILE="/etc/rancher/k3s/config.yaml"
if [ -f "$CONFIG_FILE" ]; then
    # Remove old entries
    sed -i '/shutdown-grace-period/d' "$CONFIG_FILE"

    # Add kubelet config reference if not present
    if ! grep -q 'config=/etc/rancher/k3s/kubelet.yaml' "$CONFIG_FILE"; then
        if grep -q "^kubelet-arg:" "$CONFIG_FILE"; then
            sed -i '/^kubelet-arg:/a\  - "config=/etc/rancher/k3s/kubelet.yaml"' "$CONFIG_FILE"
        else
            cat >> "$CONFIG_FILE" << 'EOF'

kubelet-arg:
  - "config=/etc/rancher/k3s/kubelet.yaml"
EOF
        fi
    fi
fi

# Create systemd override for K3s service
mkdir -p /etc/systemd/system/${K3S_SERVICE}.service.d/
cat > /etc/systemd/system/${K3S_SERVICE}.service.d/shutdown-timeout.conf << EOF
[Service]
TimeoutStopSec=150
EOF

# Reload systemd
systemctl daemon-reload

echo "  Done: Graceful shutdown configured"
echo ""

#######################################
# SUMMARY
#######################################
echo "=============================================="
echo "       Setup Complete"
echo "=============================================="
echo ""
echo "Applied:"
echo "  - Firmware: $UCODE_PKG, linux-firmware"
echo "  - CPU governor: powersave (EPP: balance_power, boost enabled)"
echo "  - TCP congestion: BBR"
echo "  - SSD power saving: disabled (NVMe APST, PCIe ASPM, SATA ALPM)"
echo "  - inotify limits: 8192 instances, 1M watches"
echo "  - Conntrack max: 1048576"
echo "  - Graceful shutdown: 120s (30s critical)"
echo ""
echo "Files created/modified:"
echo "  - /etc/tmpfiles.d/cpu-power-settings.conf"
echo "  - /etc/tmpfiles.d/nvme-no-pm.conf"
echo "  - /etc/sysctl.d/99-k8s-performance.conf"
echo "  - /etc/modprobe.d/nvme-no-apst.conf"
echo "  - /etc/udev/rules.d/60-nvme-no-pm.rules"
echo "  - /etc/udev/rules.d/60-sata-no-alpm.rules"
echo "  - /boot/loader/entries/*.conf (pcie_aspm=off)"
echo "  - /etc/rancher/k3s/kubelet.yaml"
echo "  - /etc/systemd/system/${K3S_SERVICE}.service.d/shutdown-timeout.conf"
echo ""
if [ "$NODE_TYPE" = "control-plane" ]; then
    UFW_SCRIPT="setup-ufw-k3s-control-plane.sh"
else
    UFW_SCRIPT="setup-ufw-k3s-worker.sh"
fi
echo "Next steps:"
echo "  1. Restart K3s: sudo systemctl restart $K3S_SERVICE"
echo "  2. Setup UFW (if needed): sudo bash /tmp/$UFW_SCRIPT"
echo ""
