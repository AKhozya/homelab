#!/bin/bash
# Graceful Node Shutdown Configuration - Worker Node 2 (worker-node-2)
# Run with: sudo bash graceful-shutdown-worker-2.sh
#
# This script configures:
# 1. systemd DefaultTimeoutStopSec=120s
# 2. Kubelet config file with graceful shutdown settings
# 3. K3s config to use kubelet config file
# 4. K3s agent service timeout override (150s for safety margin)
#
# References:
# - https://kubernetes.io/docs/concepts/cluster-administration/node-shutdown/
# - https://github.com/k3s-io/k3s/discussions/8594

set -e

echo "=== Configuring Graceful Node Shutdown for Worker Node 2 ==="

# 1. Update systemd system.conf
echo "[1/5] Updating /etc/systemd/system.conf..."
if grep -q "^DefaultTimeoutStopSec=" /etc/systemd/system.conf; then
    sed -i 's/^DefaultTimeoutStopSec=.*/DefaultTimeoutStopSec=120s/' /etc/systemd/system.conf
else
    echo "DefaultTimeoutStopSec=120s" >> /etc/systemd/system.conf
fi

if grep -q "^DefaultTimeoutStartSec=" /etc/systemd/system.conf; then
    sed -i 's/^DefaultTimeoutStartSec=.*/DefaultTimeoutStartSec=120s/' /etc/systemd/system.conf
fi
echo "    Done: DefaultTimeoutStopSec=120s"

# 2. Create kubelet config file
echo "[2/5] Creating /etc/rancher/k3s/kubelet.yaml..."
cat > /etc/rancher/k3s/kubelet.yaml << 'EOF'
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
# Graceful Node Shutdown Configuration
# Total: 120s (90s for regular pods + 30s for critical pods)
shutdownGracePeriod: 120s
shutdownGracePeriodCriticalPods: 30s
EOF
echo "    Done: Created kubelet config with shutdownGracePeriod=120s"

# 3. Update K3s config to use kubelet config file
echo "[3/5] Updating /etc/rancher/k3s/config.yaml..."
CONFIG_FILE="/etc/rancher/k3s/config.yaml"

# Remove any old incorrect kubelet-arg entries for shutdown
sed -i '/# Graceful Node Shutdown/d' "$CONFIG_FILE"
sed -i '/shutdown-grace-period/d' "$CONFIG_FILE"

# Check if kubelet-arg with config already exists
if grep -q 'config=/etc/rancher/k3s/kubelet.yaml' "$CONFIG_FILE"; then
    echo "    Kubelet config reference already in K3s config"
else
    # Check if kubelet-arg section exists
    if grep -q "^kubelet-arg:" "$CONFIG_FILE"; then
        # Add to existing kubelet-arg section
        sed -i '/^kubelet-arg:/a\  - "config=/etc/rancher/k3s/kubelet.yaml"' "$CONFIG_FILE"
    else
        # Create new kubelet-arg section
        cat >> "$CONFIG_FILE" << 'EOF'

# Kubelet configuration file for graceful shutdown
kubelet-arg:
  - "config=/etc/rancher/k3s/kubelet.yaml"
EOF
    fi
    echo "    Done: Added kubelet config reference"
fi

# 4. Create systemd override for k3s-agent service
echo "[4/5] Creating systemd override for k3s-agent.service..."
mkdir -p /etc/systemd/system/k3s-agent.service.d/
cat > /etc/systemd/system/k3s-agent.service.d/shutdown-timeout.conf << 'EOF'
[Service]
# Allow 150s for graceful shutdown (120s kubelet + 30s buffer)
TimeoutStopSec=150
EOF
echo "    Done: TimeoutStopSec=150s"

# 5. Reload systemd
echo "[5/5] Reloading systemd..."
systemctl daemon-reload
echo "    Done"

echo ""
echo "=== Configuration Complete ==="
echo ""
echo "Changes applied:"
echo "  - /etc/systemd/system.conf: DefaultTimeoutStopSec=120s"
echo "  - /etc/rancher/k3s/kubelet.yaml: shutdownGracePeriod=120s"
echo "  - /etc/rancher/k3s/config.yaml: kubelet-arg with config file"
echo "  - /etc/systemd/system/k3s-agent.service.d/shutdown-timeout.conf: TimeoutStopSec=150s"
echo ""

# 6. Restart K3s agent
echo "[6/6] Restarting K3s agent service..."
systemctl restart k3s-agent
echo "    Done: K3s agent restarted"

# Wait for kubelet to be ready
echo ""
echo "Waiting for node to be ready..."
sleep 15

echo ""
echo "=== Verification ==="
echo "systemd TimeoutStopUSec:"
systemctl show k3s-agent | grep TimeoutStopUSec
echo ""
echo "Kubelet config file:"
cat /etc/rancher/k3s/kubelet.yaml
echo ""
echo "K3s config kubelet-arg:"
grep -A2 "kubelet-arg" /etc/rancher/k3s/config.yaml || echo "Not found"
