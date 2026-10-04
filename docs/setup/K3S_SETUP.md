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

Run the bootstrap and the Ansible config **before** the first K3s start. The control plane does
this with one tagged playbook run (see [Control plane](#control-plane)). A bare
`curl -sfL https://get.k3s.io | sh -` installs an unpinned K3s with its bundled Traefik, CoreDNS
and helm-controller, and those collide with the ones Flux manages. The Ansible `k3s_config` role
writes `/etc/rancher/k3s/config.yaml`, which turns the bundled ones off and turns on secrets
encryption, so it must exist first.

Set up the control plane first, then the workers.

## Control plane

K3s applies `node-taint` and `node-label` only
when a node first registers, and the `disable:` list keeps the bundled CoreDNS, Traefik and
helm-controller from ever starting. If they start once, a later restart with `disable:` deletes
their add-on objects, including the `kube-dns` Service.

The drift-heal playbook writes `config.yaml`, but `install.sh`, which installs the playbook's
units, needs K3s already running. So on a new control plane run the playbook straight from the
repo checkout, limited to the tasks that write the two K3s files:

| Tag | Writes | Why |
|---|---|---|
| `k3s-config` | `/etc/rancher/k3s/config.yaml`, `k3s-wait-ready`, `clusterip-probe.sh` | the K3s server flags |
| `kubelet` | `/etc/rancher/k3s/kubelet.yaml` | `config.yaml` points the kubelet at it; without it the kubelet does not start |
| skip `secrets-encryption` | nothing | its task runs `k3s secrets-encrypt status`, which fails before K3s is installed |

The control plane is `ansible_connection: local` in the inventory, so this needs no SSH key.
`secrets-encryption: true` in `config.yaml` makes the first start generate the key and encrypt
from the start ([K3s docs](https://docs.k3s.io/security/secrets-encryption)), so no
`secrets-encrypt enable` or `rotate-keys` step follows.

Checked on 2026-09-29 without a cluster:

| Check | Result |
|---|---|
| render both files from the repo alone | byte for byte equal to the live control plane's |
| check-mode run of the tagged selection on a Mac | the file tasks ran; it stopped at "Enable k3s-wait-ready.service" for lack of `systemctl`, so the unit and later tasks are untested |

**Not drilled.** No rebuild has run this order end to end.

| Command | Needs | Where that comes from |
|---|---|---|
| `scripts/setup-node.sh control-plane` | root, and the role | If K3s is not running, pass the role: there is no unit to read it from. For `control-plane` it installs the Ansible stack (`ansible jq rsync logrotate python-kubernetes`). |
| `node-maintenance/install.sh` | the Ansible stack, `kubectl`, `flux`, a readable `/etc/rancher/k3s/k3s.yaml`, the staged SSH key ([node-maintenance README](../../node-maintenance/README.md#install-once)) | K3s must already run. `flux` comes from the AUR package `flux-bin`; nothing in this repo installs it. |
| `node-maintenance-sync.service` | `install.sh` and the deploy key `/root/.ssh/homelab-deploy` | the node-maintenance README, "Deploy key (once)". A rebuilt control plane has no deploy key yet. |

Cluster DNS stays down after these steps, because the bundled CoreDNS never starts. The
[DR runbook](../disaster-recovery/README.md#step-5-bootstrap-flux) applies CoreDNS before
`flux bootstrap`.

```bash
# 1. Bootstrap. Pass the role, because K3s is not running yet. Also install `flux-bin` from the
#    AUR: install.sh needs `flux`, and nothing in this repo installs it.
sudo bash scripts/setup-node.sh control-plane

# 2. Write config.yaml and kubelet.yaml before K3s first starts
sudo ansible-playbook -i node-maintenance/ansible/inventory.yml \
  node-maintenance/ansible/node-config.yml -l gmk-k3s-control-plane \
  --tags k3s-config,kubelet --skip-tags secrets-encryption

# 3. Install pinned K3s. It reads /etc/rancher/k3s/config.yaml on its first start.
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.37.0+k3s1" sh -
sudo k3s secrets-encrypt status  # Expect: Encryption Status: Enabled
sudo k3s kubectl get node gmk-k3s-control-plane -o jsonpath='{.spec.taints}'  # Expect: the NoSchedule taint

# 4. Install node-maintenance (stage the SSH key first, as install.sh prints), run the full
#    drift-heal, then reboot for the bootloader parameters setup-node.sh wrote
sudo bash node-maintenance/install.sh
sudo systemctl start node-maintenance-config.service
sudo reboot

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

`worker-node` keeps most app volumes on an LVM volume built from two NVMe disks.

The NVMe names (`nvme0`, `nvme1`) can swap between boots (`host_vars/worker-node.yml`), so the
names below are only an example. Identify the 4 TB disk and the 1 TB partition by
`ls -l /dev/disk/by-id/` first. The block is for new disks only. If the disks still hold the
`k8s-storage` volume group, as after a reinstall of the OS alone, skip `pvcreate`, `vgcreate`,
`lvcreate` and especially `mkfs.ext4`, which erases every app volume. Activate the group with
`sudo vgchange -ay k8s-storage` and run only the `mkdir`, `fstab` and `mount` lines.

```bash
# 4TB + 1TB NVMe LVM setup (new disks only)
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

A worker has no node-maintenance units of its own; the control plane runs Ansible against it over
SSH. So the worker's `config.yaml` can exist before its first K3s start:

```bash
# 1. On the worker: bootstrap
sudo bash scripts/setup-node.sh worker

# 2. On the worker: create the node-maintenance user and key. install.sh on the control plane
#    wrote /tmp/install-worker-ready.sh and printed the commands that copy and run it.

# 3. On the control plane: write the worker's config.yaml, kubelet.yaml and firewall
sudo systemctl start node-maintenance-config.service

# 4. On the worker: install pinned K3s agent (replace token)
curl -sfL https://get.k3s.io | K3S_URL=https://192.168.1.127:6443 K3S_TOKEN=<node-token> INSTALL_K3S_VERSION="v1.37.0+k3s1" sh -
```

## immich-vm

`immich-vm` is the GPU worker: a VM on the NAS with the Intel GPU passed through.

Never reboot this guest from inside it, and never `virsh reboot`, `reset` or `destroy` it. Each one
hits the GPU reset bug: the GPU wedges, and a `destroy` crashes the NAS host. The
only safe restart runs on the NAS host. The libvirt domain's name is a UUID; `immich-vm` is
only its title, so `virsh … immich-vm` fails with `failed to get domain`. Without
`-c qemu:///system`, a non-root `virsh` lists the empty session connection instead:

```bash
D=0398541a-c088-48cd-b16a-4b45d31a92f3; V="virsh -c qemu:///system"
$V shutdown $D --mode acpi
$V domstate $D     # wait for "shut off" before the next line
$V start $D
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

`scripts/setup-node.sh` only bootstraps a node. It takes the node role as its
argument, or reads it from a running `k3s` or `k3s-agent` unit, and does three things:

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
| `worker-node`, `worker-node-2` | `true` |

`immich-vm` carries no such label (`host_vars/immich-vm.yml`), so Traefik's `EXTERNAL-IP` lists
the two worker IPs only.

## Upgrading K3s

Do not re-run the install script to upgrade. K3s is a manual binary at `/usr/local/bin/k3s`;
pacman does not manage it, and the weekly node update does not upgrade it. The
[`k3s-upgrade`](../../agents/skills/k3s-upgrade/SKILL.md) skill describes the procedure: pick a
version from the channels API, stage the new binary on each node, restart `k3s` or `k3s-agent` one
node at a time (control plane first, no reboot), check, and keep the old binary for rollback.

## Reinstalled node: new SSH host key

A reinstall gives a node a new SSH host key. `node-maintenance/lib/known_hosts` is the one copy
of the node keys: `install.sh` installs it for Ansible on the control plane, and the
claude-telegram bot appends it at pod start. If the file still holds the old key, the drift-heal
and the bot refuse SSH to that node.

1. Read the new key on the node itself, at its console or over an SSH session you already trust.
   Never take it from `ssh-keyscan`, which trusts whatever answers:
   ```bash
   awk '{print "[<name>]:65300,[<ip>]:65300", $1, $2}' /etc/ssh/ssh_host_ed25519_key.pub
   ```
2. Replace that node's line in `node-maintenance/lib/known_hosts` with the output. Commit it,
   merge it to `main` and push `main`. The next sync installs it on the control plane. Restart the bot pod
   (`kubectl delete pod -n claude-telegram -l app=claude-telegram`) so it reads the file again.
3. On your workstation, drop the old key under both names:
   `ssh-keygen -R '[<ip>]:65300'` and `ssh-keygen -R '[<name>]:65300'`.

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
