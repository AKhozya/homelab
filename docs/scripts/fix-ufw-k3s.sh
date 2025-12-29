#!/bin/bash
# Fix UFW rules for K3s cluster networking
# Run on ANY node: sudo bash /tmp/fix-ufw-k3s.sh
#
# This script adds missing rules that may cause pod networking issues.
# Common symptom: pods can't reach API server (10.43.0.1:443 connection refused)

set -e

echo "=== Current UFW Status ==="
ufw status numbered

echo ""
echo "=== Adding K3s network rules ==="

# Allow pod network (Flannel CIDR) - INPUT chain
ufw allow from 10.42.0.0/16 to any comment "K3s pod network"

# Allow service network (ClusterIP CIDR) - INPUT chain
ufw allow from 10.43.0.0/16 to any comment "K3s service network"

# Allow traffic between nodes (if not already allowed)
ufw allow from 192.168.1.126 comment "K3s worker-node-2"
ufw allow from 192.168.1.127 comment "K3s control-plane"
ufw allow from 192.168.1.129 comment "K3s worker-node"

# Allow VXLAN for Flannel (UDP 8472)
ufw allow 8472/udp comment "Flannel VXLAN"

# Allow kubelet API (TCP 10250)
ufw allow 10250/tcp comment "Kubelet API"

# CRITICAL: Allow forwarding for pod traffic (FORWARD chain)
# Without these, pods cannot reach node IPs (including API server)
echo ""
echo "=== Adding FORWARD rules (CRITICAL for pod networking) ==="
ufw route allow from 10.42.0.0/16 to 10.42.0.0/16 comment "K3s pod-to-pod traffic"
ufw route allow from 10.42.0.0/16 to 192.168.1.0/24 comment "K3s pod-to-node traffic (API server)"
ufw route allow from 192.168.1.0/24 to 10.42.0.0/16 comment "K3s node-to-pod traffic"

echo ""
echo "=== Reloading UFW ==="
ufw reload

echo ""
echo "=== Updated UFW Status ==="
ufw status numbered

echo ""
echo "=== Done! ==="
echo "Pods should now be able to reach the API server."
echo "If pods are still failing, restart them: kubectl delete pod <pod-name>"
