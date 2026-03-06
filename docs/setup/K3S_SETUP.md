# K3s Cluster Setup

## Cluster Architecture

- **Control Plane**: `gmk-k3s-control-plane` (192.168.1.127)
- **Worker Node 1**: `worker-node` (192.168.1.129) - 4.2TB LVM storage
- **Worker Node 2**: `worker-node-2` (192.168.1.126) - 863GB LVM storage

## Control Plane Setup

```bash
# Install K3s
curl -sfL https://get.k3s.io | sh -

# Run setup script (deploys config, firmware, hardening, kubelet, shutdown)
sudo bash setup-node.sh

# Restart K3s to apply config
sudo systemctl restart k3s

# Enable secrets encryption (first time only)
sudo k3s secrets-encrypt enable
# Add 'secrets-encryption: true' is already in config from setup-node.sh
sudo systemctl restart k3s
sudo k3s secrets-encrypt rotate-keys
sudo systemctl restart k3s
sudo k3s secrets-encrypt status  # Expect: Enabled + reencrypt_finished

# Get join token for worker nodes
sudo cat /var/lib/rancher/k3s/server/node-token
```

## Worker Node Setup

### Storage Prerequisites (worker-node)

```bash
# 4TB + 1TB NVMe LVM setup
sudo pvcreate /dev/nvme1n1
sudo pvcreate /dev/nvme0n1p6
sudo vgcreate k8s-storage /dev/nvme1n1 /dev/nvme0n1p6
sudo lvcreate -l 100%FREE -n k8s-data k8s-storage
sudo mkfs.ext4 /dev/mapper/k8s--storage-k8s--data
sudo mkdir -p /mnt/k8s-storage
echo '/dev/mapper/k8s--storage-k8s--data /mnt/k8s-storage ext4 defaults 0 2' | sudo tee -a /etc/fstab
sudo mount -a
```

### Installation

```bash
# Install K3s agent (replace token)
curl -sfL https://get.k3s.io | K3S_URL=https://192.168.1.127:6443 K3S_TOKEN=<node-token> sh -

# Run setup script (deploys config, firmware, hardening, kubelet, shutdown)
sudo bash setup-node.sh

# Restart K3s agent
sudo systemctl restart k3s-agent
```

## What setup-node.sh Configures

The setup script (`docs/scripts/setup-node.sh`) auto-detects node type and applies:

1. **Firmware**: Intel/AMD microcode, linux-firmware, optional AUR firmware
2. **Performance**: CPU governor, BBR, inotify limits, conntrack, SSD power management
3. **Security**: SSH hardening (post-quantum kex), kernel sysctls, streaming timeout
4. **K3s config**: Writes `/etc/rancher/k3s/config.yaml` (control-plane or worker, auto-detected)
   - Control plane: disables Helm controller + bundled Traefik, taints node, secrets encryption flag
   - Worker: sets node-name from hostname, enables ServiceLB
5. **Graceful shutdown**: kubelet config (120s grace), systemd timeouts, conntrack fix

## Node Scheduling

- **Control Plane**: Tainted `NoSchedule` — only system pods (kube-system, flux-system, cert-manager)
- **Workers**: All application workloads, ServiceLB enabled

## ServiceLB

- Control plane: `svccontroller.k3s.cattle.io/enablelb=false`
- Workers: `svccontroller.k3s.cattle.io/enablelb=true`
- Traefik EXTERNAL-IP should show worker node IPs only

## Updating K3s

```bash
# Control plane
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.35.2+k3s1 sh -

# Worker nodes (need URL + token)
curl -sfL https://get.k3s.io | K3S_URL=https://192.168.1.127:6443 K3S_TOKEN=<token> INSTALL_K3S_VERSION=v1.35.2+k3s1 sh -
```

## Verification

```bash
kubectl get nodes -o wide
kubectl describe node gmk-k3s-control-plane | grep Taints
kubectl get node --show-labels | grep enablelb
kubectl get svc traefik -n traefik  # EXTERNAL-IP = worker IPs
```

## Related

- [Homelab Analysis](../HOMELAB_ANALYSIS.md)
- [Setup Script](../scripts/setup-node.sh)
