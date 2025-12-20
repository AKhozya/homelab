#!/bin/bash
# Performance Optimization - Worker Node 1 (worker-node)
# Run with: sudo bash optimize-worker-1.sh
#
# This script applies:
# 1. CPU governor: performance (consistent low latency)
# 2. Kernel tuning for K8s containers
# 3. Network optimizations (BBR, TCP buffers)

set -e

echo "=== Performance Optimization for Worker Node 1 ==="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Run as root (sudo bash optimize-worker-1.sh)"
    exit 1
fi

# 1. CPU Governor
echo "[1/4] Setting CPU governor to performance..."
if command -v cpupower &>/dev/null; then
    cpupower frequency-set -g performance
    echo "    Done: CPU governor set to performance"
else
    # Fallback: set directly
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$cpu" 2>/dev/null || true
    done
    echo "    Done: CPU governor set to performance (direct method)"
fi

# Make CPU governor persistent
if [ ! -f /etc/tmpfiles.d/cpu-governor.conf ]; then
    cat > /etc/tmpfiles.d/cpu-governor.conf << 'EOF'
# Set CPU governor to performance on boot
w /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor - - - - performance
EOF
    echo "    Created /etc/tmpfiles.d/cpu-governor.conf for persistence"
fi

# 2. Kernel tuning for K8s
echo ""
echo "[2/4] Applying kernel tuning for K8s..."
cat > /etc/sysctl.d/99-k8s-performance.conf << 'EOF'
# K8s Performance Tuning
# Applied by optimize-worker-1.sh

# Container support - more inotify instances for pods
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

# TCP buffer sizes for high throughput
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Connection tracking for K8s services
net.netfilter.nf_conntrack_max = 1048576

# Memory management
vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
EOF
sysctl -p /etc/sysctl.d/99-k8s-performance.conf
echo "    Done: Applied kernel tuning"

# 3. Ensure fstrim is enabled
echo ""
echo "[3/4] Checking SSD TRIM..."
if systemctl is-enabled fstrim.timer &>/dev/null; then
    echo "    ✓ fstrim.timer already enabled"
else
    systemctl enable --now fstrim.timer
    echo "    Done: Enabled fstrim.timer"
fi

# 4. Verify settings
echo ""
echo "[4/4] Verification..."
echo "    CPU Governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
echo "    inotify.max_user_instances: $(cat /proc/sys/fs/inotify/max_user_instances)"
echo "    tcp_congestion_control: $(cat /proc/sys/net/ipv4/tcp_congestion_control)"
echo "    nf_conntrack_max: $(cat /proc/sys/net/netfilter/nf_conntrack_max)"
echo "    swappiness: $(cat /proc/sys/vm/swappiness)"

echo ""
echo "=== Optimization Complete ==="
echo ""
echo "Note: CPU governor will persist across reboots via tmpfiles.d"
echo "Note: No reboot required - all settings applied immediately"
