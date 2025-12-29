#!/bin/bash
# K3s Network Diagnostics Script
# Run on each node: sudo bash /tmp/diagnose-k3s-network.sh
# Collects all network-related info for troubleshooting

set -e

NODE_NAME=$(cat /etc/hostname)
OUTPUT_FILE="/tmp/k3s-network-diag-${NODE_NAME}.txt"

echo "=== K3s Network Diagnostics - ${NODE_NAME} ===" | tee "$OUTPUT_FILE"
echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

# --- System Info ---
echo "=== 1. SYSTEM INFO ===" | tee -a "$OUTPUT_FILE"
echo "Hostname: ${NODE_NAME}" | tee -a "$OUTPUT_FILE"
echo "Kernel: $(uname -r)" | tee -a "$OUTPUT_FILE"
ip addr show | grep -E "inet |^[0-9]:" | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

# --- UFW Status ---
echo "=== 2. UFW STATUS ===" | tee -a "$OUTPUT_FILE"
if command -v ufw &> /dev/null; then
    ufw status verbose 2>&1 | tee -a "$OUTPUT_FILE"
    echo "" | tee -a "$OUTPUT_FILE"
    echo "--- UFW Rules (numbered) ---" | tee -a "$OUTPUT_FILE"
    ufw status numbered 2>&1 | tee -a "$OUTPUT_FILE"
else
    echo "UFW not installed" | tee -a "$OUTPUT_FILE"
fi
echo "" | tee -a "$OUTPUT_FILE"

# --- iptables INPUT chain ---
echo "=== 3. IPTABLES INPUT CHAIN ===" | tee -a "$OUTPUT_FILE"
iptables -L INPUT -n -v --line-numbers 2>&1 | head -30 | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

# --- iptables FORWARD chain ---
echo "=== 4. IPTABLES FORWARD CHAIN ===" | tee -a "$OUTPUT_FILE"
iptables -L FORWARD -n -v --line-numbers 2>&1 | head -30 | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

# --- iptables NAT rules for kubernetes service ---
echo "=== 5. IPTABLES NAT - KUBE-SERVICES ===" | tee -a "$OUTPUT_FILE"
iptables -t nat -L KUBE-SERVICES -n 2>&1 | grep -E "(10.43.0.1|kubernetes)" | head -10 | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

# --- nftables (if used) ---
echo "=== 6. NFTABLES RULESET ===" | tee -a "$OUTPUT_FILE"
if command -v nft &> /dev/null; then
    nft list ruleset 2>&1 | head -50 | tee -a "$OUTPUT_FILE"
else
    echo "nft not available" | tee -a "$OUTPUT_FILE"
fi
echo "" | tee -a "$OUTPUT_FILE"

# --- Listening ports ---
echo "=== 7. LISTENING PORTS (K3s related) ===" | tee -a "$OUTPUT_FILE"
ss -tlnp 2>/dev/null | grep -E "(6443|10250|10251|10252|2379|2380|8472)" | tee -a "$OUTPUT_FILE" || \
ss -tln | grep -E "(6443|10250|10251|10252|2379|2380|8472)" | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

# --- Routes ---
echo "=== 8. ROUTING TABLE ===" | tee -a "$OUTPUT_FILE"
ip route show | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

# --- Flannel interface ---
echo "=== 9. FLANNEL INTERFACE ===" | tee -a "$OUTPUT_FILE"
ip addr show flannel.1 2>&1 | tee -a "$OUTPUT_FILE"
ip addr show cni0 2>&1 | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

# --- K3s service status ---
echo "=== 10. K3S SERVICE STATUS ===" | tee -a "$OUTPUT_FILE"
systemctl status k3s --no-pager 2>/dev/null | head -15 | tee -a "$OUTPUT_FILE" || \
systemctl status k3s-agent --no-pager 2>/dev/null | head -15 | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

# --- Connectivity tests ---
echo "=== 11. CONNECTIVITY TESTS ===" | tee -a "$OUTPUT_FILE"

# Test to control plane
echo "--- Ping control-plane (192.168.1.127) ---" | tee -a "$OUTPUT_FILE"
ping -c 1 -W 2 192.168.1.127 2>&1 | tail -2 | tee -a "$OUTPUT_FILE"

# Test TCP to API server
echo "--- TCP to API server (192.168.1.127:6443) ---" | tee -a "$OUTPUT_FILE"
timeout 3 bash -c 'cat < /dev/null > /dev/tcp/192.168.1.127/6443' 2>&1 && echo "SUCCESS: TCP connection established" | tee -a "$OUTPUT_FILE" || echo "FAILED: Cannot connect TCP to 192.168.1.127:6443" | tee -a "$OUTPUT_FILE"

# Test to ClusterIP
echo "--- TCP to kubernetes ClusterIP (10.43.0.1:443) ---" | tee -a "$OUTPUT_FILE"
timeout 3 bash -c 'cat < /dev/null > /dev/tcp/10.43.0.1/443' 2>&1 && echo "SUCCESS: TCP connection established" | tee -a "$OUTPUT_FILE" || echo "FAILED: Cannot connect TCP to 10.43.0.1:443" | tee -a "$OUTPUT_FILE"

# Test to other nodes
echo "--- Ping worker-node (192.168.1.129) ---" | tee -a "$OUTPUT_FILE"
ping -c 1 -W 2 192.168.1.129 2>&1 | tail -2 | tee -a "$OUTPUT_FILE"

echo "--- Ping worker-node-2 (192.168.1.126) ---" | tee -a "$OUTPUT_FILE"
ping -c 1 -W 2 192.168.1.126 2>&1 | tail -2 | tee -a "$OUTPUT_FILE"

echo "" | tee -a "$OUTPUT_FILE"

# --- Conntrack entries ---
echo "=== 12. CONNTRACK STATS ===" | tee -a "$OUTPUT_FILE"
if command -v conntrack &> /dev/null; then
    conntrack -C 2>&1 | tee -a "$OUTPUT_FILE"
    conntrack -S 2>&1 | head -10 | tee -a "$OUTPUT_FILE"
else
    cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null | tee -a "$OUTPUT_FILE" || echo "conntrack not available" | tee -a "$OUTPUT_FILE"
fi
echo "" | tee -a "$OUTPUT_FILE"

# --- Kernel network parameters ---
echo "=== 13. KERNEL NETWORK PARAMS ===" | tee -a "$OUTPUT_FILE"
echo "net.ipv4.ip_forward = $(sysctl -n net.ipv4.ip_forward)" | tee -a "$OUTPUT_FILE"
echo "net.bridge.bridge-nf-call-iptables = $(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null || echo 'N/A')" | tee -a "$OUTPUT_FILE"
echo "net.netfilter.nf_conntrack_max = $(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo 'N/A')" | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

# --- Recent K3s logs (errors only) ---
echo "=== 14. RECENT K3S ERRORS (last 20) ===" | tee -a "$OUTPUT_FILE"
journalctl -u k3s -u k3s-agent --no-pager -n 100 2>/dev/null | grep -iE "(error|fail|refused|timeout)" | tail -20 | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

echo "=== DIAGNOSTICS COMPLETE ===" | tee -a "$OUTPUT_FILE"
echo "Output saved to: $OUTPUT_FILE" | tee -a "$OUTPUT_FILE"
