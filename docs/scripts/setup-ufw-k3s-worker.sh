#!/bin/bash
# Setup UFW for K3s worker node
# Run: sudo bash /tmp/setup-ufw-k3s-worker.sh
# IMPORTANT: Run this BEFORE enabling UFW to avoid lockout!

set -e

echo "=== K3s Worker Node UFW Setup ==="
echo "Hostname: $(cat /etc/hostname)"
echo ""

# Check if UFW is installed
if ! command -v ufw &> /dev/null; then
    echo "ERROR: UFW not installed. Install with: pacman -S ufw"
    exit 1
fi

# Reset to defaults (but don't enable yet)
echo "--- Setting UFW defaults ---"
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed

# SSH access (CRITICAL - add first to avoid lockout)
echo "--- Adding SSH access (port 65300) ---"
ufw allow from 192.168.1.0/24 to any port 65300 proto tcp comment "SSH from LAN"

# Allow from all cluster nodes
echo "--- Adding cluster node communication ---"
ufw allow from 192.168.1.127 comment "K3s control-plane"
ufw allow from 192.168.1.129 comment "K3s worker-node"
ufw allow from 192.168.1.126 comment "K3s worker-node-2"

# K3s pod network (10.42.0.0/16)
echo "--- Adding K3s pod network ---"
ufw allow from 10.42.0.0/16 comment "K3s pod network"

# K3s service network (10.43.0.0/16)
echo "--- Adding K3s service network ---"
ufw allow from 10.43.0.0/16 comment "K3s service network"

# Flannel VXLAN (UDP 8472)
echo "--- Adding Flannel VXLAN ---"
ufw allow 8472/udp comment "Flannel VXLAN overlay"

# Kubelet API (TCP 10250)
echo "--- Adding Kubelet API ---"
ufw allow 10250/tcp comment "Kubelet API"

# Allow forwarding for pod traffic
echo "--- Adding FORWARD rules for pod network ---"
ufw route allow from 10.42.0.0/16 to 10.42.0.0/16 comment "K3s pod-to-pod traffic"

# HTTP/HTTPS for services (optional, from LAN)
echo "--- Adding HTTP/HTTPS from LAN ---"
ufw allow from 192.168.1.0/24 to any port 80 proto tcp comment "HTTP from LAN"
ufw allow from 192.168.1.0/24 to any port 443 proto tcp comment "HTTPS from LAN"

echo ""
echo "=== Current UFW Rules (not yet enabled) ==="
ufw status numbered

echo ""
echo "=== Ready to Enable UFW ==="
echo "Review the rules above. If they look correct, run:"
echo "  sudo ufw enable"
echo ""
echo "To test without enabling permanently:"
echo "  sudo ufw --dry-run enable"
echo ""
echo "If you get locked out, physical console access required to fix."
