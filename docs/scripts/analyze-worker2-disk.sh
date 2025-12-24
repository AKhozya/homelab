#!/bin/bash
# Analyze disk usage on worker-node-2 for LVM migration planning
set -e

echo "=== Disk Layout ==="
df -h / /mnt/extra-storage 2>/dev/null
echo ""

echo "=== Root SSD Top Consumers ==="
sudo du -sh /* 2>/dev/null | sort -h | tail -15
echo ""

echo "=== /var breakdown ==="
sudo du -sh /var/* 2>/dev/null | sort -h | tail -10
echo ""

echo "=== K3s Data ==="
sudo du -sh /var/lib/rancher 2>/dev/null || echo "No /var/lib/rancher"
sudo du -sh /var/lib/rancher/k3s/* 2>/dev/null | sort -h | tail -5
echo ""

echo "=== Kubelet Data ==="
sudo du -sh /var/lib/kubelet 2>/dev/null || echo "No /var/lib/kubelet"
echo ""

echo "=== Containerd Data ==="
sudo du -sh /var/lib/containerd 2>/dev/null || echo "No /var/lib/containerd"
echo ""

echo "=== LVM extra-storage current usage ==="
sudo du -sh /mnt/extra-storage/* 2>/dev/null || echo "Empty or not mounted"
echo ""

echo "=== Migration Candidates ==="
echo "These can be moved to /mnt/extra-storage:"
echo ""
for dir in /var/lib/rancher /var/lib/kubelet /var/lib/containerd; do
    if [ -d "$dir" ]; then
        SIZE=$(sudo du -sh "$dir" 2>/dev/null | cut -f1)
        echo "  $dir: $SIZE"
    fi
done
