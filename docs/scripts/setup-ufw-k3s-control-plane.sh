#!/bin/bash
# Setup UFW for K3s control-plane node
# Run: sudo bash /tmp/setup-ufw-k3s-control-plane.sh
# IMPORTANT: Run this BEFORE enabling UFW to avoid lockout!

set -e

echo "=== K3s Control-Plane UFW Setup ==="
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
ufw allow from 192.168.1.127 comment "K3s control-plane (self)"
ufw allow from 192.168.1.129 comment "K3s worker-node"
ufw allow from 192.168.1.126 comment "K3s worker-node-2"

# K3s pod network (10.42.0.0/16) - CRITICAL for pod-to-API communication
echo "--- Adding K3s pod network ---"
ufw allow from 10.42.0.0/16 comment "K3s pod network"

# K3s service network (10.43.0.0/16)
echo "--- Adding K3s service network ---"
ufw allow from 10.43.0.0/16 comment "K3s service network"

# Kubernetes API server (TCP 6443)
echo "--- Adding Kubernetes API server ---"
ufw allow 6443/tcp comment "Kubernetes API server"

# Flannel VXLAN (UDP 8472)
echo "--- Adding Flannel VXLAN ---"
ufw allow 8472/udp comment "Flannel VXLAN overlay"

# Kubelet API (TCP 10250)
echo "--- Adding Kubelet API ---"
ufw allow 10250/tcp comment "Kubelet API"

# etcd (TCP 2379-2380) - only needed if external etcd
# echo "--- Adding etcd ---"
# ufw allow from 192.168.1.0/24 to any port 2379:2380 proto tcp comment "etcd"

# Allow forwarding for pod traffic (CRITICAL for K3s networking)
echo "--- Adding FORWARD rules for pod network ---"
ufw route allow from 10.42.0.0/16 to 10.42.0.0/16 comment "K3s pod-to-pod traffic"
ufw route allow from 10.42.0.0/16 to 192.168.1.0/24 comment "K3s pod-to-node traffic (API server)"
ufw route allow from 192.168.1.0/24 to 10.42.0.0/16 comment "K3s node-to-pod traffic"

# HTTP/HTTPS for services (optional, from LAN)
echo "--- Adding HTTP/HTTPS from LAN ---"
ufw allow from 192.168.1.0/24 to any port 80 proto tcp comment "HTTP from LAN"
ufw allow from 192.168.1.0/24 to any port 443 proto tcp comment "HTTPS from LAN"

echo ""
echo "=== Enabling UFW ==="
ufw --force enable
systemctl enable ufw

echo ""
echo "=== UFW Status ==="
ufw status numbered

echo ""
echo "=== Done! ==="
echo "UFW is now active and will persist across reboots."
