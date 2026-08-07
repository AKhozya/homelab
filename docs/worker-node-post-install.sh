#!/bin/bash
# Post-install script for K3s worker node
# Run as root after archinstall completes and reboot

set -e

# Configuration - EDIT THESE
NODE_NAME="worker-node-2"
NODE_IP="192.168.1.130"
GATEWAY="192.168.1.1"
DNS_SERVERS="192.168.1.127,1.1.1.1"
SSH_PORT="65300"
USERNAME="akhozya"
K3S_SERVER="https://192.168.1.127:6443"
K3S_VERSION="v1.34.2+k3s1"
# Get this from control plane: sudo cat /var/lib/rancher/k3s/server/node-token
K3S_TOKEN=""

# LVM configuration - adjust device names for your hardware
# Use 'lsblk' to identify your NVMe devices
LVM_DEVICES=""  # e.g., "/dev/nvme0n1" or "/dev/nvme0n1 /dev/nvme1n1p6"

echo "=== K3s Worker Node Post-Install ==="
echo "Node: $NODE_NAME"
echo "IP: $NODE_IP"

# ============================================
# 1. Set hostname
# ============================================
echo "[1/10] Setting hostname..."
hostnamectl set-hostname "$NODE_NAME"

# ============================================
# 2. Configure SSH on non-standard port
# ============================================
echo "[2/10] Configuring SSH on port $SSH_PORT..."
sed -i "s/^#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config

# Disable password auth (after adding SSH keys!)
# sed -i "s/^#PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config

systemctl enable sshd
systemctl restart sshd

# ============================================
# 3. Configure UFW firewall
# ============================================
echo "[3/10] Configuring UFW firewall..."
ufw default deny incoming
ufw default allow outgoing

# SSH
ufw allow "$SSH_PORT"/tcp

# K3s required ports
ufw allow 6443/tcp      # K3s API (outbound to control plane)
ufw allow 10250/tcp     # Kubelet metrics
ufw allow 8472/udp      # Flannel VXLAN
ufw allow 51820/udp     # Flannel WireGuard (if used)
ufw allow 51821/udp     # Flannel WireGuard IPv6 (if used)

# Enable UFW
echo "y" | ufw enable
systemctl enable ufw

# ============================================
# 4. Configure fail2ban
# ============================================
echo "[4/10] Configuring fail2ban..."
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
EOF

systemctl enable fail2ban
systemctl start fail2ban

# ============================================
# 5. Configure static IP via systemd-networkd
# ============================================
echo "[5/10] Configuring static IP..."

# Find the primary ethernet interface
PRIMARY_IF=$(ip -o link show | awk -F': ' '$2 !~ /lo|veth|flannel|cni|docker|br-/{print $2; exit}')
echo "Primary interface: $PRIMARY_IF"

# Disable NetworkManager if present, use systemd-networkd
systemctl disable NetworkManager 2>/dev/null || true
systemctl stop NetworkManager 2>/dev/null || true

cat > /etc/systemd/network/20-wired.network << EOF
[Match]
Name=$PRIMARY_IF

[Network]
Address=$NODE_IP/24
Gateway=$GATEWAY
DNS=$DNS_SERVERS

[Link]
RequiredForOnline=routable
EOF

systemctl enable systemd-networkd
systemctl enable systemd-resolved
systemctl restart systemd-networkd

# ============================================
# 6. Configure LVM storage (if devices specified)
# ============================================
if [ -n "$LVM_DEVICES" ]; then
    echo "[6/10] Configuring LVM storage..."

    for dev in $LVM_DEVICES; do
        echo "Creating PV on $dev..."
        pvcreate "$dev"
    done

    echo "Creating VG k8s-storage..."
    vgcreate k8s-storage $LVM_DEVICES

    echo "Creating LV k8s-data..."
    lvcreate -l 100%FREE -n k8s-data k8s-storage

    echo "Formatting with ext4..."
    mkfs.ext4 /dev/k8s-storage/k8s-data

    mkdir -p /mnt/k8s-storage

    echo '/dev/k8s-storage/k8s-data /mnt/k8s-storage ext4 defaults 0 2' >> /etc/fstab

    mount -a

    echo "LVM storage configured:"
    df -h /mnt/k8s-storage
else
    echo "[6/10] Skipping LVM (no devices specified)..."
    echo "WARNING: Configure LVM manually before installing K3s!"
fi

# ============================================
# 7. Create K3s config
# ============================================
echo "[7/10] Creating K3s config..."
mkdir -p /etc/rancher/k3s

cat > /etc/rancher/k3s/config.yaml << EOF
# K3s Worker Node Configuration
node-name: $NODE_NAME

# Enable ServiceLB traffic on this node
node-label:
  - "svccontroller.k3s.cattle.io/enablelb=true"
EOF

# ============================================
# 8. Install K3s agent
# ============================================
if [ -n "$K3S_TOKEN" ]; then
    echo "[8/10] Installing K3s agent..."
    curl -sfL https://get.k3s.io | \
        K3S_URL="$K3S_SERVER" \
        K3S_TOKEN="$K3S_TOKEN" \
        INSTALL_K3S_VERSION="$K3S_VERSION" \
        sh -

    echo "K3s agent installed. Checking status..."
    systemctl status k3s-agent --no-pager
else
    echo "[8/10] Skipping K3s install (no token provided)..."
    echo "Run this command after getting the token from control plane:"
    echo ""
    echo "curl -sfL https://get.k3s.io | \\"
    echo "    K3S_URL=\"$K3S_SERVER\" \\"
    echo "    K3S_TOKEN=\"<token>\" \\"
    echo "    INSTALL_K3S_VERSION=\"$K3S_VERSION\" \\"
    echo "    sh -"
fi

# ============================================
# 9. Install yay (AUR helper)
# ============================================
echo "[9/10] Installing yay..."
if [ -n "$USERNAME" ]; then
    sudo -u "$USERNAME" bash << 'EOFYAY'
cd /tmp
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
cd ..
rm -rf yay
EOFYAY
fi

# ============================================
# 10. Final checks
# ============================================
echo "[10/10] Final checks..."

echo ""
echo "=== Summary ==="
echo "Hostname: $(hostname)"
echo "IP: $(ip -4 addr show "$PRIMARY_IF" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo 'Check network config')"
echo "SSH Port: $SSH_PORT"
echo "UFW Status: $(ufw status | head -1)"
echo "LVM:"
vgs 2>/dev/null || echo "  Not configured"
lvs 2>/dev/null || echo "  Not configured"
echo ""

if [ -n "$K3S_TOKEN" ]; then
    echo "K3s Status:"
    systemctl is-active k3s-agent
else
    echo "K3s: Not installed (token required)"
fi

echo ""
echo "=== Next Steps ==="
echo "1. Add your SSH public key to /home/$USERNAME/.ssh/authorized_keys"
echo "2. Test SSH: ssh -p $SSH_PORT $USERNAME@$NODE_IP"
echo "3. If LVM not configured, set LVM_DEVICES and re-run section 6"
echo "4. Get K3s token from control plane: sudo cat /var/lib/rancher/k3s/server/node-token"
echo "5. If K3s not installed, run the curl command shown above"
echo "6. Verify node joined: kubectl get nodes"
echo ""
echo "Done!"
