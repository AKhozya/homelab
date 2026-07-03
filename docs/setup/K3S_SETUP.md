# K3s Cluster Setup

## Cluster Architecture

- **Control Plane**: `gmk-k3s-control-plane` (192.168.1.127)
- **Worker Node 1**: `worker-node` (192.168.1.129) — 4.2TB LVM storage
- **Worker Node 2**: `worker-node-2` (192.168.1.126) — 863GB LVM storage

## Control Plane Setup

Order matters: bootstrap + ansible config BEFORE first k3s start. A bare
`curl | sh -` installs unpinned k3s WITH bundled Traefik + CoreDNS + helm-controller
that collide with the Flux-managed ones — the ansible-owned `config.yaml` disables them.

```bash
# 1. Bootstrap (ansible stack + firmware suppressors + bootloader params + K3s config dir)
sudo bash setup-node.sh

# 2. Apply ansible-owned config (k3s config.yaml/kubelet.yaml, hardening, firewall, sysctls)
sudo systemctl start node-maintenance-sync.service
sudo systemctl start node-maintenance-config.service

# 3. Install pinned K3s
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.36.1+k3s1" sh -

# Enable secrets encryption (first time only)
sudo k3s secrets-encrypt enable
# 'secrets-encryption: true' is already in config.yaml from the ansible k3s_config role
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
# 1. Bootstrap + ansible-owned config (same as CP — BEFORE k3s install)
sudo bash setup-node.sh
sudo systemctl start node-maintenance-sync.service
sudo systemctl start node-maintenance-config.service

# 2. Install pinned K3s agent (replace token)
curl -sfL https://get.k3s.io | K3S_URL=https://192.168.1.127:6443 K3S_TOKEN=<node-token> INSTALL_K3S_VERSION="v1.36.1+k3s1" sh -
```

## What setup-node.sh Configures (bootstrap-only)

The script (`docs/scripts/setup-node.sh`) is **bootstrap-only** (see its header) and
auto-detects node type. It applies exactly three things:

1. **Bootstrap packages**: ansible stack (CP only) + AUR firmware suppressors
2. **Bootloader kernel params**: systemd-boot entries (not ansible-managed)
3. **K3s config directory stub**: creates the `/etc/rancher/k3s/` directory

It does NOT write `config.yaml`/`kubelet.yaml` or apply hardening directly. Everything
else — K3s `config.yaml` (CP: disables bundled coredns/traefik/helm-controller, secrets
encryption; worker: node-name, ServiceLB) + `kubelet.yaml` (120s graceful shutdown),
sysctls, sshd hardening, udev, tmpfiles, journald, logrotate, UFW, packages — is owned
by ansible roles (`docs/scripts/node-maintenance/ansible/roles/`) and drift-healed daily
by `node-maintenance-config.timer`.

## Node Scheduling

- **CP**: tainted `NoSchedule` — system pods only (kube-system, flux-system, cert-manager)
- **Workers**: all app workloads, ServiceLB enabled

## ServiceLB

- CP: `svccontroller.k3s.cattle.io/enablelb=false`
- Workers: `svccontroller.k3s.cattle.io/enablelb=true`
- Traefik EXTERNAL-IP = worker node IPs only

## Updating K3s

Do NOT re-run the install script to upgrade. k3s is a manual binary at
`/usr/local/bin/k3s` — not pacman/yay-managed, and the node-maintenance
phase1/phase2 flow does not bump it. Upgrade via the manual-binary rolling
procedure (`k3s-upgrade` skill): pick version from the channels API, stage the
new binary on each node, rolling-restart k3s / k3s-agent (no reboot, CP first),
verify, keep the old binary for rollback.

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
