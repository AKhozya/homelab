#!/bin/bash
# Fix UFW rules for K3s cluster networking
# Run on control-plane node: sudo bash /tmp/fix-ufw-k3s.sh

set -e

echo "=== Current UFW Status ==="
ufw status numbered

echo ""
echo "=== Adding K3s network rules ==="

# Allow pod network (Flannel CIDR)
ufw allow from 10.42.0.0/16 to any comment "K3s pod network"

# Allow service network (ClusterIP CIDR)
ufw allow from 10.43.0.0/16 to any comment "K3s service network"

# Allow traffic between nodes (if not already allowed)
ufw allow from 192.168.1.126 comment "K3s worker-node-2"
ufw allow from 192.168.1.127 comment "K3s control-plane"
ufw allow from 192.168.1.129 comment "K3s worker-node"

# Allow VXLAN for Flannel (UDP 8472)
ufw allow 8472/udp comment "Flannel VXLAN"

# Allow kubelet API (TCP 10250)
ufw allow 10250/tcp comment "Kubelet API"

echo ""
echo "=== Updated UFW Status ==="
ufw status numbered

echo ""
echo "=== Done! Pods should now be able to reach the API server ==="
