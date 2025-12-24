#!/bin/bash
# Analyze disk usage and suggest cleanup
set -e

echo "=== Disk Usage Analysis: $(hostname) ==="
echo "Date: $(date)"
echo ""

echo "=== Filesystem Overview ==="
df -h / /var /tmp /run 2>/dev/null | grep -v "^Filesystem" | head -10
echo ""

echo "=== Top-level Usage ==="
sudo du -sh /* 2>/dev/null | sort -h | tail -15
echo ""

echo "=== /run breakdown (should be tmpfs, clears on reboot) ==="
sudo du -sh /run/* 2>/dev/null | sort -h | tail -10
echo ""

echo "=== /var breakdown ==="
sudo du -sh /var/* 2>/dev/null | sort -h | tail -10
echo ""

echo "=== /var/log (can often be cleaned) ==="
sudo du -sh /var/log/* 2>/dev/null | sort -h | tail -10
echo ""

echo "=== /var/cache (safe to clean) ==="
sudo du -sh /var/cache/* 2>/dev/null | sort -h | tail -5
echo ""

echo "=== Pacman cache ==="
sudo du -sh /var/cache/pacman/pkg 2>/dev/null
ls /var/cache/pacman/pkg | wc -l | xargs echo "Package files:"
echo ""

echo "=== Journal logs ==="
sudo journalctl --disk-usage 2>/dev/null
echo ""

echo "=== Old kernels (if any) ==="
ls -la /boot/vmlinuz* /boot/initramfs* 2>/dev/null | head -10
echo ""

echo "=== Docker/containerd (if present) ==="
sudo du -sh /var/lib/docker 2>/dev/null || echo "No Docker"
sudo du -sh /var/lib/containerd 2>/dev/null || echo "No containerd dir"
sudo du -sh /var/lib/rancher 2>/dev/null || echo "No rancher dir"
echo ""

echo "=== K3s/Kubelet data ==="
sudo du -sh /var/lib/kubelet 2>/dev/null || echo "No kubelet"
sudo du -sh /var/lib/rancher/k3s 2>/dev/null || echo "No k3s"
echo ""

echo "=== Swapfile check ==="
if [ -f /swapfile ]; then
    ls -lh /swapfile
    echo "RECOMMENDATION: Remove /swapfile if using LVM swap"
else
    echo "No /swapfile found"
fi
echo ""

echo "=== CLEANUP RECOMMENDATIONS ==="
echo ""

# Pacman cache
PKG_COUNT=$(ls /var/cache/pacman/pkg 2>/dev/null | wc -l)
if [ "$PKG_COUNT" -gt 10 ]; then
    echo "1. Clean pacman cache (keep last 2 versions):"
    echo "   sudo paccache -rk2"
    echo ""
fi

# Journal
JOURNAL_SIZE=$(sudo journalctl --disk-usage 2>/dev/null | grep -oP '\d+\.?\d*[GM]' | head -1)
echo "2. Vacuum journal logs (currently: $JOURNAL_SIZE):"
echo "   sudo journalctl --vacuum-size=500M"
echo ""

# Swapfile
if [ -f /swapfile ]; then
    echo "3. Remove old swapfile (if using LVM swap):"
    echo "   sudo swapoff /swapfile && sudo rm -f /swapfile && sudo sed -i '/swapfile/d' /etc/fstab"
    echo ""
fi

# Docker
if [ -d /var/lib/docker ]; then
    echo "4. Prune unused Docker data:"
    echo "   sudo docker system prune -af"
    echo ""
fi

echo "=== END ANALYSIS ==="
