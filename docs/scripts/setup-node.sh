#!/bin/bash
# K3s Node Setup Script
# Run with: sudo bash setup-node.sh
#
# This script configures a K3s node with:
# 1. Firmware (auto-detects Intel/AMD)
# 2. Power/Performance optimization (powersave governor for noise/heat reduction, balance_power EPP, SSD no-sleep, BBR)
# 3. K3s config (control-plane or worker, auto-detected)
# 4. Graceful shutdown (kubelet config)
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
echo "[1/4] Firmware Setup"
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
echo "[2/4] Performance Optimization"
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

# Security hardening sysctls
echo "Applying security hardening sysctls..."
cat > /etc/sysctl.d/99-security-hardening.conf << 'EOF'
# Security Hardening (February 2026)

# Disable ICMP secure redirects (prevent MITM route injection)
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0

# Log martian packets (spoofed source addresses)
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# BPF hardening: Arch kernel uses BPF_JIT_ALWAYS_ON + BPF_UNPRIV_DEFAULT_OFF
# which is superior to bpf_jit_harden (no interpreter fallback, unprivileged blocked)
# Ensure unprivileged BPF stays disabled (defense in depth)
kernel.unprivileged_bpf_disabled = 1
EOF
sysctl -p /etc/sysctl.d/99-security-hardening.conf >/dev/null 2>&1

# SSH hardening (post-quantum kex, strong ciphers only)
echo "Applying SSH hardening..."
cat > /etc/ssh/sshd_config.d/99-hardening.conf << 'EOF'
# Security hardening - February 2026
# Post-quantum key exchange (OpenSSH 10.x)
KexAlgorithms mlkem768x25519-sha256,curve25519-sha256,curve25519-sha256@libssh.org

# Strong ciphers only (no CBC, no 3DES)
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com

# ETM MACs only (no MD5, no SHA1, no non-ETM)
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com

# Modern host key algorithms only (no DSA, no ECDSA NIST curves)
HostKeyAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256
PubkeyAcceptedAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256
EOF
if sshd -t 2>/dev/null; then
    systemctl reload sshd
    echo "  Done: SSH hardened and reloaded"
else
    echo "  ERROR: SSH config invalid, reverting"
    rm -f /etc/ssh/sshd_config.d/99-hardening.conf
fi

# Enable SSD TRIM
systemctl enable --now fstrim.timer 2>/dev/null || true

# Enable pacman cache cleanup (keeps last 2 versions)
systemctl enable --now paccache.timer 2>/dev/null || true

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
# 3. K3S CONFIG
#######################################
echo "=============================================="
echo "[3/4] K3s Configuration"
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
# 4. GRACEFUL SHUTDOWN
#######################################
echo "=============================================="
echo "[4/4] Graceful Shutdown Configuration"
echo "=============================================="

# Update systemd timeouts
echo "Configuring systemd timeouts..."
if grep -q "^DefaultTimeoutStopSec=" /etc/systemd/system.conf; then
    sed -i 's/^DefaultTimeoutStopSec=.*/DefaultTimeoutStopSec=120s/' /etc/systemd/system.conf
else
    echo "DefaultTimeoutStopSec=120s" >> /etc/systemd/system.conf
fi

# Create kubelet config (referenced by K3s config from step 3)
echo "Creating kubelet config..."
cat > /etc/rancher/k3s/kubelet.yaml << 'EOF'
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
shutdownGracePeriod: 120s
shutdownGracePeriodCriticalPods: 30s
# Eviction: hard threshold at 10%, soft at 15% with 1m grace
evictionHard:
  imagefs.available: "10%"
  nodefs.available: "10%"
  memory.available: "100Mi"
evictionSoft:
  imagefs.available: "15%"
  nodefs.available: "15%"
  memory.available: "200Mi"
evictionSoftGracePeriod:
  imagefs.available: "1m"
  nodefs.available: "1m"
  memory.available: "1m"
# Log rotation
containerLogMaxSize: "50Mi"
containerLogMaxFiles: 5
# Streaming connection security (CIS benchmark, default 4h is excessive)
streamingConnectionIdleTimeout: 5m
EOF

# Create systemd overrides for K3s service
mkdir -p /etc/systemd/system/${K3S_SERVICE}.service.d/
cat > /etc/systemd/system/${K3S_SERVICE}.service.d/shutdown-timeout.conf << EOF
[Service]
TimeoutStopSec=150
EOF

# K3s kube-proxy recalculates conntrack on startup (cores × 32768)
# Override it after K3s starts to ensure our value sticks
cat > /etc/systemd/system/${K3S_SERVICE}.service.d/conntrack-fix.conf << 'EOF'
[Service]
ExecStartPost=/sbin/sysctl -w net.netfilter.nf_conntrack_max=1048576
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
echo "  - CPU governor: powersave (noise/heat reduction, EPP: balance_power, boost enabled)"
echo "  - TCP congestion: BBR"
echo "  - SSD power saving: disabled (NVMe APST, PCIe ASPM, SATA ALPM)"
echo "  - inotify limits: 8192 instances, 1M watches"
echo "  - Conntrack max: 1048576"
echo "  - SSH: post-quantum kex, strong ciphers/MACs only"
echo "  - Kernel: secure_redirects off, log_martians, unprivileged_bpf_disabled"
echo "  - K3s config: $NODE_TYPE (node-name: $HOSTNAME)"
echo "  - Eviction: hard 10%, soft 15% (1m grace)"
echo "  - Container logs: 50Mi × 5 files"
echo "  - Kubelet streaming timeout: 5m"
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
echo "  - /etc/rancher/k3s/config.yaml"
echo "  - /etc/rancher/k3s/kubelet.yaml"
echo "  - /etc/systemd/system/${K3S_SERVICE}.service.d/shutdown-timeout.conf"
echo ""
if [ "$NODE_TYPE" = "control-plane" ]; then
    UFW_SCRIPT="setup-ufw-k3s-control-plane.sh"
else
    UFW_SCRIPT="setup-ufw-k3s-worker.sh"
fi
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
    echo "  3. Setup UFW (if needed): sudo bash /tmp/$UFW_SCRIPT"
else
    echo "Next steps:"
    echo "  1. Restart K3s: sudo systemctl restart $K3S_SERVICE"
    echo "  2. Setup UFW (if needed): sudo bash /tmp/$UFW_SCRIPT"
fi
echo ""
