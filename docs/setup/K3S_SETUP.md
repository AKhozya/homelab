# K3s Node Setup

This page installs K3s on each node: the control plane, the two workers and `immich-vm`. The
[DR runbook](../disaster-recovery/README.md) uses it for step 1 of a rebuild.

## The nodes

| Node | IP | Role | Storage |
|---|---|---|---|
| `gmk-k3s-control-plane` | 192.168.1.127 | control plane | — |
| `worker-node` | 192.168.1.129 | worker | 4.2 TB LVM at `/mnt/k8s-storage` |
| `worker-node-2` | 192.168.1.126 | worker | 863 GB at `/mnt/extra-storage` |
| `immich-vm` | 192.168.1.231 | GPU worker, a VM on the NAS | k3s data under `/home/k3s` |

## Order matters

Run the bootstrap and the Ansible config **before** the first K3s start. A bare
`curl -sfL https://get.k3s.io | sh -` installs an unpinned K3s with its bundled Traefik, CoreDNS
and helm-controller, and those collide with the ones Flux manages. The Ansible `k3s_config` role
writes `/etc/rancher/k3s/config.yaml`, which turns the bundled ones off and turns on secrets
encryption, so it must exist first.

Set up the control plane first, then the workers.

## Control plane

```bash
# 1. Bootstrap (ansible stack + firmware suppressors + bootloader params + K3s config dir)
sudo bash scripts/setup-node.sh

# 2. Apply ansible-owned config (k3s config.yaml/kubelet.yaml, hardening, firewall, sysctls)
sudo systemctl start node-maintenance-sync.service
sudo systemctl start node-maintenance-config.service

# 3. Install pinned K3s
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.37.0+k3s1" sh -

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

Get a kubeconfig for your workstation:

```bash
# On control-plane
sudo cat /etc/rancher/k3s/k3s.yaml
# Copy to local at ~/.kube/config
# Update server IP to 192.168.1.127
```

## Workers

### Storage on worker-node

`worker-node` keeps most app volumes on an LVM volume built from two NVMe disks:

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

### Install

```bash
# 1. Bootstrap + ansible-owned config (same as CP — BEFORE k3s install)
sudo bash scripts/setup-node.sh
sudo systemctl start node-maintenance-sync.service
sudo systemctl start node-maintenance-config.service

# 2. Install pinned K3s agent (replace token)
curl -sfL https://get.k3s.io | K3S_URL=https://192.168.1.127:6443 K3S_TOKEN=<node-token> INSTALL_K3S_VERSION="v1.37.0+k3s1" sh -
```

## immich-vm

`immich-vm` is the GPU worker: a VM on the NAS with the Intel GPU passed through.

Never reboot this guest from inside it, and never `virsh reboot`, `reset` or `destroy` it. Each one
hits the GPU reset bug and crashes the NAS host. The only safe restart runs on the NAS host:

```bash
virsh shutdown immich-vm --mode acpi
virsh domstate immich-vm     # wait for "shut off" before the next line
virsh start immich-vm
```

The NAS host supplies the GPU and the virtiofs library mount, so start the guest before installing
K3s. The bootstrap and Ansible steps above already wrote `/etc/rancher/k3s/config.yaml`, which the
agent reads when it first registers:

| Setting | Value |
|---|---|
| `data-dir` | `/home/k3s` |
| `node-name` | `immich-vm` |
| `node-ip` | `192.168.1.231` |
| `node-label` | `homelab/gpu=intel` |

```bash
export K3S_URL=https://192.168.1.127:6443
export K3S_TOKEN=<token-from-control-plane>
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.37.0+k3s1" sh -
```

Run these checks on the control-plane node:

```bash
sudo k3s kubectl wait --for=condition=Ready node/immich-vm --timeout=5m
sudo k3s kubectl get node immich-vm -o jsonpath='{.metadata.labels.homelab/gpu}{"\n"}'
# expect: intel
```

Flux recreates the `intel-gpu-plugin` DaemonSet through the `infrastructure-configs`
Kustomization, and that DaemonSet advertises `gpu.intel.com/i915`. Do not install the plugin by
hand.

## What `setup-node.sh` does

`scripts/setup-node.sh` only bootstraps a node; its header says so. It detects the node type and
does three things:

| # | Step |
|---|---|
| 1 | Installs the bootstrap packages: the Ansible stack (control plane only) and the AUR firmware packages that silence mkinitcpio's missing-firmware warnings |
| 2 | Writes the kernel parameters into the systemd-boot entries, which Ansible does not manage |
| 3 | Creates the empty `/etc/rancher/k3s/` directory |

It does not write `config.yaml` or `kubelet.yaml`, and it does not harden the node. The Ansible
roles in `node-maintenance/ansible/roles/` own everything else: the K3s `config.yaml` (on the
control plane it turns off the bundled CoreDNS, Traefik and helm-controller and turns on secrets
encryption; on workers it sets the node name and ServiceLB), `kubelet.yaml` (120 s graceful
shutdown), sysctls, SSH hardening, udev, tmpfiles, journald, logrotate, UFW and packages. The
`node-maintenance-config.timer` drift-heal re-applies them at 03:00 and 15:00 UTC.

## Scheduling

| Node | Taint | What runs there |
|---|---|---|
| control plane | `NoSchedule` | system pods, plus the platform pods that tolerate the taint: for example Authentik, Traefik, the CNPG operator, MySQL's orchestrator and Redis Sentinel |
| workers | none | the app workloads |
| `immich-vm` | `homelab/dedicated=immich:NoSchedule` (`host_vars/immich-vm.yml`) | Immich and the per-node agents only |

## ServiceLB

K3s ServiceLB gives each LoadBalancer Service an address on the nodes that allow it:

| Node | Label `svccontroller.k3s.cattle.io/enablelb` |
|---|---|
| control plane | `false` |
| workers | `true` |

So Traefik's `EXTERNAL-IP` lists the worker IPs only.

## Upgrading K3s

Do not re-run the install script to upgrade. K3s is a manual binary at `/usr/local/bin/k3s`;
pacman does not manage it, and the weekly node update does not upgrade it. The
[`k3s-upgrade`](../../agents/skills/k3s-upgrade/SKILL.md) skill describes the procedure: pick a
version from the channels API, stage the new binary on each node, restart `k3s` or `k3s-agent` one
node at a time (control plane first, no reboot), check, and keep the old binary for rollback.

## Check

```bash
kubectl get nodes -o wide
kubectl describe node gmk-k3s-control-plane | grep Taints
kubectl get node --show-labels | grep enablelb
kubectl get svc traefik -n traefik  # EXTERNAL-IP = worker IPs
```

## Related

- [Homelab Analysis](../HOMELAB_ANALYSIS.md)
- [Setup Script](../../scripts/setup-node.sh)
