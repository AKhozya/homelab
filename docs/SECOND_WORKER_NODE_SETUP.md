# Second Worker Node Setup Guide

**Target Date**: December 2025 / January 2026
**Current Cluster**: K3s v1.34.2+k3s1

## Worker Node 2 Configuration (Actual)

- **Hostname**: worker-node-2
- **IP**: 192.168.1.126
- **User**: z3us
- **SSH Port**: 65300
- **CPU**: AMD Ryzen 7 8745H (8 cores, 16 threads)
- **RAM**: 30GB
- **Storage**:
  - System: 1TB NVMe (nvme1n1) with ArchinstallVg LVM (20G root, 932G home)
  - Data: 3.6TB NVMe (nvme0n1) as k8s-storage LVM

## Quick Start Files

- **archinstall config**: `docs/archinstall-worker-node.json`
- **Post-install script**: `docs/worker-node-post-install.sh`

---

## Current Worker Node Configuration Reference

### Hardware & OS
- **OS**: Arch Linux (rolling)
- **Kernel**: 6.17.9-arch1-1
- **IP**: 192.168.1.129
- **Hostname**: worker-node

### Storage Configuration

**Disk Layout** (1TB NVMe as system disk):
| Partition | Size | Mount | Purpose |
|-----------|------|-------|---------|
| nvme1n1p1 | 1GB | /boot | EFI boot |
| nvme1n1p2 | 50GB | / | Root filesystem |
| nvme1n1p3 | 32GB | swap | Swap |
| nvme1n1p4 | 50GB | /home | User home |
| nvme1n1p5 | 200GB | /var | K3s data, logs |
| nvme1n1p6 | ~466GB | LVM | k8s-storage VG |
| nvme1n1p7 | ~132GB | LVM | k8s-storage VG |

**4TB NVMe (dedicated to LVM)**:
| Device | Size | Purpose |
|--------|------|---------|
| nvme0n1 | 4TB | 100% LVM for k8s-storage |

**LVM Configuration**:
```bash
# Volume Group: k8s-storage
# Physical Volumes: nvme0n1 (4TB) + nvme1n1p6 (~466GB) + nvme1n1p7 (~132GB)
# Total: ~4.22 TiB

# Logical Volume: k8s-data
# Size: 100% of VG
# Filesystem: ext4
# Mount: /mnt/k8s-storage
```

**fstab entry**:
```
/dev/k8s-storage/k8s-data /mnt/k8s-storage ext4 defaults 0 2
```

### K3s Agent Configuration

**Service file**: `/etc/systemd/system/k3s-agent.service`
- Standard K3s agent service
- Environment file: `/etc/systemd/system/k3s-agent.service.env`

**Config file**: `/etc/rancher/k3s/config.yaml`
```yaml
# K3s Worker Node Configuration
node-name: worker-node

# Enable ServiceLB traffic on this node
node-label:
  - "svccontroller.k3s.cattle.io/enablelb=true"
```

### Network Configuration
- **Primary NIC**: enp3s0 (192.168.1.129/24)
- **Flannel CIDR**: 10.42.1.0/24 (pod network)
- **CNI**: flannel with VXLAN

---

## New Worker Node Setup Procedure

### Prerequisites

1. **Hardware**:
   - x86_64 system with at least 16GB RAM
   - NVMe storage (recommend separate drives for OS and K8s data)
   - Gigabit Ethernet connection to same LAN

2. **Network**:
   - Static IP on 192.168.1.x (not .127, .129)
   - Suggested: 192.168.1.130 for worker-node-2
   - SSH access configured on port 65300

3. **Control Plane Access**:
   - K3s server URL: `https://192.168.1.127:6443`
   - Node token: `/var/lib/rancher/k3s/server/node-token` (on control plane, requires sudo)

### Step 1: OS Installation (Arch Linux)

**Option A: Using archinstall (recommended)**

Boot from Arch ISO and run:
```bash
# Load config from USB or network
archinstall --config /path/to/archinstall-worker-node.json

# Or run interactively and use config as reference
archinstall
```

**Disk configuration (do interactively in archinstall):**
- Select your system NVMe drive
- Use "Best effort" partitioning with these sizes:
  - Boot: 1GB (EFI)
  - Root: 50GB
  - Swap: 32GB (or skip if plenty of RAM)
  - Home: 50GB
  - Leave remaining space UNPARTITIONED (for LVM later)
- **Important**: Don't let archinstall use the data NVMe - that's for LVM

**Option B: Manual installation**
```bash
# Partition scheme (adjust sizes based on available storage)
# p1: 1GB   - EFI (/boot)
# p2: 50GB  - Root (/)
# p3: 32GB  - Swap
# p4: 50GB  - Home (/home)
# p5: 200GB - Var (/var) - K3s runtime data
# p6+: Remaining - LVM for k8s-storage

# Install base system with:
pacstrap /mnt base linux linux-firmware openssh sudo vim lvm2 \
    base-devel git btop fd fzf rsync tree ufw fail2ban bash-completion

# Enable services in chroot
arch-chroot /mnt systemctl enable sshd systemd-networkd systemd-resolved systemd-timesyncd
```

### Step 1b: Run Post-Install Script (Alternative to Steps 2-8)

After archinstall completes and you reboot, you can run the automated post-install script:

```bash
# Copy script to new node
scp -P 65300 docs/worker-node-post-install.sh akhozya@192.168.1.130:/tmp/

# SSH to node and run as root
ssh -p 65300 akhozya@192.168.1.130
sudo bash /tmp/worker-node-post-install.sh
```

The script handles: SSH config, UFW firewall, fail2ban, static IP, LVM, K3s config, and K3s installation.

**Edit these variables in the script before running:**
- `NODE_IP` - Static IP for new node
- `K3S_TOKEN` - Get from control plane
- `LVM_DEVICES` - Your NVMe device(s) for K8s storage

---

### Step 2: Configure SSH (Port 65300)

```bash
# Edit /etc/ssh/sshd_config
Port 65300
PermitRootLogin no
PasswordAuthentication no  # After adding SSH keys

# Add your SSH public key
mkdir -p ~/.ssh
chmod 700 ~/.ssh
# Add public key to ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

### Step 3: Configure Static IP

```bash
# Using NetworkManager
nmcli con mod "Wired connection 1" ipv4.addresses 192.168.1.130/24
nmcli con mod "Wired connection 1" ipv4.gateway 192.168.1.1
nmcli con mod "Wired connection 1" ipv4.dns "192.168.1.127,1.1.1.1"
nmcli con mod "Wired connection 1" ipv4.method manual
nmcli con up "Wired connection 1"
```

### Step 4: Set Hostname

```bash
hostnamectl set-hostname worker-node-2
```

### Step 5: Configure LVM Storage

```bash
# Create physical volume on dedicated NVMe (adjust device name)
pvcreate /dev/nvme0n1

# If using partition from system disk as well:
# pvcreate /dev/nvme1n1p6

# Create volume group
vgcreate k8s-storage /dev/nvme0n1

# Create logical volume (100% of VG)
lvcreate -l 100%FREE -n k8s-data k8s-storage

# Format with ext4
mkfs.ext4 /dev/k8s-storage/k8s-data

# Create mount point
mkdir -p /mnt/k8s-storage

# Add to fstab
echo '/dev/k8s-storage/k8s-data /mnt/k8s-storage ext4 defaults 0 2' >> /etc/fstab

# Mount
mount -a

# Verify
df -h /mnt/k8s-storage
```

### Step 6: Get K3s Node Token

On control plane (192.168.1.127):
```bash
# Requires sudo
sudo cat /var/lib/rancher/k3s/server/node-token
```

### Step 7: Install K3s Agent

```bash
# Get the token from control plane first
export K3S_TOKEN="<token-from-control-plane>"
export K3S_URL="https://192.168.1.127:6443"

# Install K3s agent (same version as cluster)
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.34.2+k3s1 sh -
```

### Step 8: Create K3s Config

```bash
# Create config directory
sudo mkdir -p /etc/rancher/k3s

# Create config file
sudo tee /etc/rancher/k3s/config.yaml << 'EOF'
# K3s Worker Node 2 Configuration
node-name: worker-node-2

# Enable ServiceLB traffic on this node
node-label:
  - "svccontroller.k3s.cattle.io/enablelb=true"
EOF
```

### Step 9: Verify Node Joined

From your local machine:
```bash
kubectl get nodes -o wide
# Should show:
# gmk-k3s-control-plane   Ready   control-plane,master   ...
# worker-node             Ready   <none>                 ...
# worker-node-2           Ready   <none>                 ...
```

---

## Post-Setup Tasks

### 1. Update local-path-provisioner (if needed)

The current config uses `DEFAULT_PATH_FOR_NON_LISTED_NODES` which applies to all nodes.
If you want node-specific paths, update the ConfigMap:

```bash
kubectl edit configmap -n kube-system local-path-config
```

Add node-specific paths if needed:
```json
{
  "nodePathMap":[
    {
      "node":"DEFAULT_PATH_FOR_NON_LISTED_NODES",
      "paths":["/mnt/k8s-storage"]
    },
    {
      "node":"worker-node-2",
      "paths":["/mnt/k8s-storage"]
    }
  ]
}
```

### 2. Enable Pod Anti-Affinity

With 2 worker nodes, enable pod anti-affinity for HA:

**PostgreSQL** (CNPG):
```yaml
# infrastructure/configs/base/databases/postgres/cluster.yaml
spec:
  enablePodAntiAffinity: true
  podAntiAffinityType: "required"  # Change from "preferred"
```

**Critical Infrastructure** (already configured with preferred):
- Traefik
- cert-manager
- Cloudflare tunnel

### 3. Verify Storage Distribution

After workloads schedule on new node:
```bash
# Check PVCs per node
kubectl get pv -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]'
```

### 4. Test Node Drain

```bash
# Drain new node (test failover)
kubectl drain worker-node-2 --ignore-daemonsets --delete-emptydir-data

# Verify workloads moved to worker-node
kubectl get pods -A -o wide | grep worker-node

# Uncordon
kubectl uncordon worker-node-2
```

---

## Quick Reference Commands

```bash
# SSH to new worker
ssh -p 65300 akhozya@192.168.1.130

# Check K3s agent status
sudo systemctl status k3s-agent

# View K3s agent logs
sudo journalctl -u k3s-agent -f

# Check node status
kubectl get nodes
kubectl describe node worker-node-2

# Check pods on node
kubectl get pods -A --field-selector spec.nodeName=worker-node-2

# Check LVM status (on node)
sudo vgs
sudo lvs
sudo pvs
```

---

## UFW Firewall Rules for Cross-Node Networking

**CRITICAL**: These rules are required for Flannel VXLAN overlay networking between nodes.

### Required Rules on Each Node

The Flannel CNI uses VXLAN (UDP port 8472) for pod-to-pod communication across nodes. Each node must allow:
1. **VXLAN traffic (UDP 8472)** from all other cluster nodes
2. **Pod network traffic (10.42.x.0/24)** from all other nodes' pod CIDRs

### Node Pod Network CIDRs

| Node | IP | Pod CIDR |
|------|-----|----------|
| control-plane | 192.168.1.127 | 10.42.0.0/24 |
| worker-node | 192.168.1.129 | 10.42.1.0/24 |
| worker-node-2 | 192.168.1.126 | 10.42.2.0/24 |

### UFW Rules Applied

**On worker-node-2 (192.168.1.126)**:
```bash
# Allow Flannel VXLAN from other nodes
sudo ufw allow from 192.168.1.127 to any port 8472 proto udp comment 'Flannel VXLAN from control-plane'
sudo ufw allow from 192.168.1.129 to any port 8472 proto udp comment 'Flannel VXLAN from worker-node'

# Allow pod network from all nodes
sudo ufw allow from 10.42.0.0/16 comment 'K8s pod network'
```

**On worker-node (192.168.1.129)**:
```bash
# Allow Flannel VXLAN from worker-node-2
sudo ufw allow from 192.168.1.126 to any port 8472 proto udp comment 'Flannel VXLAN from worker-node-2'

# Allow pod network from worker-node-2
sudo ufw allow from 10.42.2.0/24 comment 'Pod network from worker-node-2'
```

**On control-plane (192.168.1.127)**:
```bash
# Allow Flannel VXLAN from worker-node-2
sudo ufw allow from 192.168.1.126 to any port 8472 proto udp comment 'Flannel VXLAN from worker-node-2'

# Allow pod network from worker-node-2
sudo ufw allow from 10.42.2.0/24 comment 'Pod network from worker-node-2'
```

### Verify Connectivity

After adding rules, test cross-node networking:
```bash
# From control-plane, ping worker-node-2 pod network
ping -c 3 10.42.2.1

# Check a pod on worker-node-2 is reachable from another node
kubectl get pods -A -o wide | grep worker-node-2
# Pick a pod IP and ping it from another node
```

---

## Troubleshooting

### Node not joining
1. Check token validity: Token expires, get fresh one
2. Check firewall: Ports 6443 (API), 10250 (kubelet), 8472/UDP (flannel)
3. Check time sync: NTP must be working
4. Check logs: `sudo journalctl -u k3s-agent -f`

### Storage issues
1. Verify LVM mount: `df -h /mnt/k8s-storage`
2. Check permissions: Directory should be root-owned
3. Verify fstab entry persists across reboot

### Network issues
1. Check flannel: `ip addr show flannel.1`
2. Check CNI: `ls /var/lib/rancher/k3s/agent/etc/cni/`
3. Check pod network: Pods should get 10.42.x.x IPs

---

## Important Notes

1. **Storage**: Each worker node has its own LVM storage - PVCs are node-local
2. **Backups**: Update backup scripts if new node has critical data
3. **DNS**: Add worker-node-2 to AdGuard Home for local resolution
4. **SSH Config**: Add to ~/.ssh/config for easy access

**Example SSH config** (update in chezmoi):
```
Host worker-node-2
    HostName 192.168.1.126
    Port 65300
    User z3us
```

---

## Manual Post-Setup Tasks

After the node joins the cluster, complete these manual tasks:

### 1. AdGuard Home DNS Entry

Add a DNS rewrite rule so `worker-node-2.h0melab.work` resolves to the node IP.

**Steps**:
1. Open AdGuard Home: https://adguard.h0melab.work
2. Navigate to: **Filters** → **DNS rewrites**
3. Click **Add DNS rewrite**
4. Enter:
   - **Domain**: `worker-node-2.h0melab.work`
   - **Answer**: `192.168.1.126`
5. Click **Save**

**Verify**:
```bash
dig worker-node-2.h0melab.work @192.168.1.129
# Should return 192.168.1.126
```

### 2. Uptime Kuma Monitors

Add monitoring for the new worker node. Access Uptime Kuma at https://uptime.h0melab.work

**Add these 3 monitors**:

#### Monitor 1: Ping
- **Monitor Type**: Ping
- **Friendly Name**: `worker-node-2 Ping`
- **Hostname**: `192.168.1.126`
- **Heartbeat Interval**: `60` seconds
- **Tags**: Add `infrastructure` tag

#### Monitor 2: SSH Port
- **Monitor Type**: TCP Port
- **Friendly Name**: `worker-node-2 SSH`
- **Hostname**: `192.168.1.126`
- **Port**: `65300`
- **Heartbeat Interval**: `60` seconds
- **Tags**: Add `infrastructure` tag

#### Monitor 3: Kubelet API (Optional)
- **Monitor Type**: HTTP(s)
- **Friendly Name**: `worker-node-2 Kubelet`
- **URL**: `https://192.168.1.126:10250/healthz`
- **Method**: GET
- **Heartbeat Interval**: `60` seconds
- **Accepted Status Codes**: `401` (kubelet requires auth, 401 means it's responding)
- **Tags**: Add `infrastructure` tag

**Group monitors** (optional):
- Create a group called "Worker Node 2" and add all 3 monitors to it

### 3. Update SSH Config (chezmoi)

Add the new node to your SSH config:

```bash
chezmoi edit ~/.ssh/config
```

Add:
```
Host worker-node-2
    HostName 192.168.1.126
    Port 65300
    User z3us
```

Then apply:
```bash
chezmoi apply
```

### 4. Verify HA Distribution

After setup, verify workloads are distributed:

```bash
# PostgreSQL instances (should be 1 per worker node)
kubectl get pods -n databases -l cnpg.io/cluster=main-postgres -o wide

# PgBouncer poolers (should be 1 per worker node)
kubectl get pods -n databases -l cnpg.io/poolerName=main-postgres-rw-pooler -o wide

# All pods per node
kubectl get pods -A -o wide | grep worker-node-2 | wc -l
```
