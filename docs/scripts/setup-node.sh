#!/bin/bash
# K3s Node Setup Script
# Run with: sudo bash setup-node.sh
#
# This script configures a K3s node with:
# 1. Packages & firmware (auto-detects Intel/AMD)
# 2. Power/Performance optimization (powersave governor, balance_power EPP, SSD no-sleep, BBR)
# 3. Security hardening (kernel, filesystem, network, SSH, watchdog)
# 4. K3s config (control-plane or worker, auto-detected)
# 5. Graceful shutdown & system services (kubelet, journald, timers)
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

    # Watchdog: auto-restart rebuilderd when builds get stuck in spin loops
    # Some packages (e.g. owl-lisp) have test suites that enter infinite
    # wait loops inside nspawn, spamming journald at ~24M msgs/30s
    echo "Installing rebuilderd stuck-build watchdog..."
    cat > /usr/local/bin/rebuilderd-watchdog.sh << 'WATCHDOG'
#!/bin/bash
SERVICE="rebuilderd-worker@1.service"

if ! systemctl is-active --quiet "$SERVICE"; then
    exit 0
fi

# Count spin indicators: "Suppressed" msgs OR "wait: pid" lines in last 5min
SPIN_COUNT=$(journalctl -u "$SERVICE" --since "5 min ago" --no-pager -q 2>/dev/null \
    | grep -cE "Suppressed|wait: pid" || true)

if [ "$SPIN_COUNT" -ge 5 ]; then
    REAL_LINES=$(journalctl -u "$SERVICE" --since "20 min ago" --no-pager -q 2>/dev/null \
        | grep -v "wait: pid" \
        | grep -v "Suppressed" \
        | grep -v '^\.\c$' \
        | grep -v "^$" \
        | wc -l)

    if [ "$REAL_LINES" -lt 5 ]; then
        echo "$(date -Iseconds) Stuck build detected (${SPIN_COUNT} spin lines, ${REAL_LINES} real). Restarting."
        systemctl restart "$SERVICE"
        logger -t rebuilderd-watchdog "Restarted $SERVICE due to stuck build"
    fi
fi
WATCHDOG
    chmod +x /usr/local/bin/rebuilderd-watchdog.sh

    cat > /etc/systemd/system/rebuilderd-watchdog.service << 'EOF'
[Unit]
Description=Rebuilderd stuck build watchdog
After=rebuilderd-worker@1.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/rebuilderd-watchdog.sh
EOF

    cat > /etc/systemd/system/rebuilderd-watchdog.timer << 'EOF'
[Unit]
Description=Run rebuilderd watchdog every 10 minutes

[Timer]
OnBootSec=10min
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now rebuilderd-watchdog.timer
    echo "  Watchdog timer enabled (every 10min)"
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
echo "[2/5] Performance Optimization"
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
rm -f /etc/tmpfiles.d/cpu-governor.conf  # Clean up old naming
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

# Clean up legacy sysctl files (superseded by unified-hardening)
rm -f /etc/sysctl.d/51-kptr-restrict.conf
rm -f /etc/sysctl.d/99-security-hardening.conf

echo "  Done: Performance optimizations applied"
echo ""

#######################################
# 3. SECURITY HARDENING
#######################################
echo "=============================================="
echo "[3/5] Security Hardening"
echo "=============================================="

# Unified security hardening sysctls
echo "Applying unified security hardening sysctls..."
cat > /etc/sysctl.d/99-unified-hardening.conf << 'EOF'
# Unified K8s Node Hardening - sysctl settings
# Deployed by setup-node.sh

# ===== KERNEL HARDENING =====
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.perf_event_paranoid = 4
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.yama.ptrace_scope = 1
kernel.core_pattern = |/bin/false
kernel.printk = 3 4 1 3
kernel.sysrq = 176
vm.unprivileged_userfaultfd = 0
dev.tty.ldisc_autoload = 0

# ===== FILESYSTEM HARDENING =====
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0

# ===== NETWORK HARDENING =====
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
EOF
sysctl -p /etc/sysctl.d/99-unified-hardening.conf >/dev/null 2>&1

# Kernel watchdog (auto-reboot on lockup)
echo "Configuring kernel watchdog..."
cat > /etc/sysctl.d/99-watchdog.conf << 'EOF'
# Enable NMI watchdog for hard lockup detection
kernel.nmi_watchdog=1
# Panic on soft lockup (logs before crash)
kernel.softlockup_panic=1
# Panic on hard lockup (triggers reboot)
kernel.hardlockup_panic=1
# Log all lockups
kernel.softlockup_all_cpu_backtrace=1
# Auto-reboot 10 seconds after kernel panic
kernel.panic=10
EOF
sysctl -p /etc/sysctl.d/99-watchdog.conf >/dev/null 2>&1

# Hardware watchdog via systemd (forces reboot if PID 1 freezes)
echo "Enabling hardware watchdog via systemd..."
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/watchdog.conf << 'EOF'
# Hardware watchdog - systemd kicks the watchdog periodically.
# If PID 1 freezes (kernel hang, deadlock), hardware forces reboot.
[Manager]
RuntimeWatchdogSec=30
RebootWatchdogSec=10min
EOF

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

# SSH hardening (post-quantum kex, strong ciphers only)
echo "Applying SSH hardening..."
cat > /etc/ssh/sshd_config.d/99-hardening.conf << 'EOF'
# Security hardening - March 2026
# Post-quantum key exchange (OpenSSH 10.x)
KexAlgorithms mlkem768x25519-sha256,curve25519-sha256,curve25519-sha256@libssh.org

# Strong ciphers only (no CBC, no 3DES)
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com

# ETM MACs only (no MD5, no SHA1, no non-ETM)
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com

# Modern host key algorithms only (no DSA, no ECDSA NIST curves)
HostKeyAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256
PubkeyAcceptedAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256

# Brute force mitigation (default 6 is too generous)
MaxAuthTries 3

# Free connection slots faster (default 120s)
LoginGraceTime 30

# Kill stale sessions after 10 min (300s × 2 = 600s)
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
if sshd -t 2>/dev/null; then
    systemctl reload sshd
    echo "  Done: SSH hardened and reloaded"
else
    echo "  ERROR: SSH config invalid, reverting"
    rm -f /etc/ssh/sshd_config.d/99-hardening.conf
fi

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

# Disable LLMNR (port 5355) - unnecessary with AdGuard Home for DNS
# LLMNR is a legacy local-network name resolution fallback; reduces attack surface
echo "Disabling LLMNR..."
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/no-llmnr.conf << 'EOF'
[Resolve]
LLMNR=no
EOF
systemctl restart systemd-resolved
echo "  Done: LLMNR disabled (port 5355 closed)"

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
# 5. GRACEFUL SHUTDOWN & SYSTEM SERVICES
#######################################
echo "=============================================="
echo "[5/5] Graceful Shutdown & System Services"
echo "=============================================="

# Journald size limits (prevent unbounded growth)
echo "Configuring journald size limits..."
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/00-journal-size.conf << 'EOF'
[Journal]
SystemMaxUse=500M
MaxRetentionSec=2weeks
Compress=yes
EOF
systemctl restart systemd-journald

# Update systemd timeouts
echo "Configuring systemd timeouts..."
for timeout_key in DefaultTimeoutStartSec DefaultTimeoutStopSec; do
    if grep -q "^${timeout_key}=" /etc/systemd/system.conf; then
        sed -i "s/^${timeout_key}=.*/${timeout_key}=120s/" /etc/systemd/system.conf
    else
        echo "${timeout_key}=120s" >> /etc/systemd/system.conf
    fi
done

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

# Re-apply network hardening after K3s creates flannel/cni interfaces
# (systemd-sysctl runs before K3s, so network sysctls get reset by new interface creation)
cat > /etc/systemd/system/${K3S_SERVICE}.service.d/network-hardening.conf << 'EOF'
[Service]
ExecStartPost=/sbin/sysctl -w net.ipv4.conf.all.log_martians=1 net.ipv4.conf.default.log_martians=1 net.ipv4.conf.all.secure_redirects=0 net.ipv4.conf.default.secure_redirects=0
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
echo "  - Packages: base-devel, btop, fail2ban, fwupd, git, go, jq, yq, rsync, etc."
echo "  - Workers: rebuilderd, archlinux-repro"
echo "  - GPU: mesa, vulkan (auto-detected)"
echo "  - User makepkg.conf: BUILDDIR/SRCDEST/PKGDEST override for rebuilderd nodes"
echo "  - CPU governor: powersave (EPP: balance_power, boost enabled)"
echo "  - TCP congestion: BBR, inotify 8192/1M, conntrack 1M"
echo "  - SSD power saving: disabled (NVMe APST, PCIe ASPM, SATA ALPM)"
echo "  - Security: unified kernel/fs/network hardening (50+ settings)"
echo "  - Watchdog: panic on soft/hard lockup, hardware watchdog (30s systemd kick)"
echo "  - Crash logging: EFI pstore, printk dump, panic=10 auto-reboot"
echo "  - SSH: post-quantum kex, strong ciphers/MACs, PermitEmptyPasswords no"
echo "  - Journald: 500MB max, 2 weeks retention"
echo "  - K3s config: $NODE_TYPE (node-name: $HOSTNAME)"
echo "  - Graceful shutdown: 120s (30s critical)"
echo ""
echo "Key files:"
echo "  - /etc/sysctl.d/99-unified-hardening.conf"
echo "  - /etc/sysctl.d/99-watchdog.conf"
echo "  - /etc/sysctl.d/99-k8s-performance.conf"
echo "  - /etc/ssh/sshd_config.d/99-hardening.conf"
echo "  - /etc/systemd/journald.conf.d/00-journal-size.conf"
echo "  - /etc/rancher/k3s/config.yaml"
echo "  - /etc/rancher/k3s/kubelet.yaml"
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
