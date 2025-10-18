# K3s Cluster Configuration

This directory contains configuration files and documentation for the K3s cluster.

## Cluster Architecture

- **Control Plane**: `gmk-k3s-control-plane` (192.168.1.127)
- **Worker Node**: `worker-node` (192.168.1.129)
- **Storage**: 4.09TB multi-PV LVM storage on worker node

## Control Plane Setup

### Installation

```bash
# On control plane node (gmk-k3s-control-plane)
curl -sfL https://get.k3s.io | sh -
```

### Configuration

1. Copy the config file to the control plane:
```bash
sudo mkdir -p /etc/rancher/k3s
sudo cp control-plane-config.yaml /etc/rancher/k3s/config.yaml
```

2. Restart K3s to apply:
```bash
sudo systemctl restart k3s
```

3. Get the join token for worker nodes:
```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

## Worker Node Setup

### Storage Prerequisites

The worker node requires LVM storage to be configured before joining:

1. **4TB NVMe SSD** (`/dev/nvme1n1`): Entire disk as LVM PV
2. **1TB NVMe SSD** (`/dev/nvme0n1p6`): 466GB partition as LVM PV

```bash
# On worker node - LVM setup (already done)
sudo pvcreate /dev/nvme1n1
sudo pvcreate /dev/nvme0n1p6
sudo vgcreate k8s-storage /dev/nvme1n1 /dev/nvme0n1p6
sudo lvcreate -l 100%FREE -n k8s-data k8s-storage
sudo mkfs.ext4 /dev/mapper/k8s--storage-k8s--data

# Mount point
sudo mkdir -p /mnt/k8s-storage
echo '/dev/mapper/k8s--storage-k8s--data /mnt/k8s-storage ext4 defaults 0 2' | sudo tee -a /etc/fstab
sudo mount -a
```

### Worker Node Installation

```bash
# On worker node
# Replace K3S_URL and K3S_TOKEN with your values
curl -sfL https://get.k3s.io | K3S_URL=https://192.168.1.127:6443 K3S_TOKEN=<node-token> sh -
```

## Configuration Details

### Storage Configuration

- **Path**: `/mnt/k8s-storage`
- **Capacity**: 4.09 TiB
- **Physical Volumes**:
  - `/dev/nvme1n1`: 3.64 TiB (4TB SSD)
  - `/dev/nvme0n1p6`: 466 GB (1TB SSD partition)
- **Volume Group**: `k8s-storage`
- **Logical Volume**: `k8s-data`

All Kubernetes PersistentVolumes are created on this storage via the local-path-provisioner.

### Disabled Components

- **Helm Controller**: Disabled (using Flux for GitOps)

## Verification

After setup, verify:

```bash
# Check K3s is running
sudo systemctl status k3s

# Check storage path configuration
kubectl get configmap local-path-config -n kube-system -o jsonpath='{.data.config\.json}' | jq

# Should show:
# {
#   "nodePathMap": [
#     {
#       "node": "DEFAULT_PATH_FOR_NON_LISTED_NODES",
#       "paths": ["/mnt/k8s-storage"]
#     }
#   ]
# }

# Check nodes
kubectl get nodes

# Check PVs are on LVM storage
kubectl get pv -o custom-columns=NAME:.metadata.name,PATH:.spec.local.path | grep /mnt/k8s-storage
```

## Troubleshooting

### Config not applied after restart

If the config doesn't apply after K3s restart, verify:

```bash
# Check config file exists and is readable
cat /etc/rancher/k3s/config.yaml

# Check K3s service status
sudo systemctl status k3s

# Check K3s logs
sudo journalctl -u k3s -f
```

### Storage path reverts to default

If storage path reverts to `/var/lib/rancher/k3s/storage`:

1. Verify the config file exists: `cat /etc/rancher/k3s/config.yaml`
2. Restart K3s: `sudo systemctl restart k3s`
3. Wait 30 seconds for reconciliation
4. Check ConfigMap: `kubectl get configmap local-path-config -n kube-system -o yaml`

## Maintenance

### Updating K3s

```bash
# On control plane
curl -sfL https://get.k3s.io | sh -

# On worker node
curl -sfL https://get.k3s.io | K3S_URL=https://192.168.1.127:6443 K3S_TOKEN=<node-token> sh -
```

### Backing up K3s

K3s state is stored in:
- `/var/lib/rancher/k3s/server/` (control plane)
- etcd snapshots (if configured)

Consider regular etcd snapshots for disaster recovery.

## Related Documentation

- [K3s Official Docs](https://docs.k3s.io/)
- [Homelab Analysis](../../docs/HOMELAB_ANALYSIS.md)
- [Storage Infrastructure](../../docs/HOMELAB_ANALYSIS.md#-storage-infrastructure)
