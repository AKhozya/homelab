# Immich GPU-node substrate: diagnostic + heal (Path B) — DESIGN v1

Date: 2026-07-08 (rev 2026-07-10). Status: design, pre-implementation. Spikes folded in; **Codex tight-scoped review addressed** (2026-07-10): CRITICAL reset-bug predicate (now strict unreachable-signature + default-off), HIGH /dev/dri PSS path (device-plugin), HIGH libvirt-group diagnose, + 4 MEDIUM/LOW (nic_tuning hosts:all exclude, CronJob Job-pod NP, overstated-conventions softened, bounded self-heal).

## Goal
Immich runs as k8s pods on an **Arch** VM on the zettOS NAS, with the Meteor Lake iGPU full-passthrough'd for QSV transcode. The VM substrate is fragile (reset-bug, zettOS updates wipe SSH keys, VM config was not GitOps'd). This design makes the substrate **reproducible (GitOps'd) + self-healing**, converting Path B's biggest weakness into a codified asset. Passthrough itself is already PROVEN (Ubuntu spike); this covers the durable Arch build + the heal system, NOT the data cutover (separate migration spec).

## Guest OS decision
Arch (not the Ubuntu spike VM — discard it). Rationale: unify with the 3 Arch k3s nodes + **reuse** node-maintenance ansible roles. Host-side passthrough (q35+OVMF+`<hostdev managed='yes'>`, autostart) is OS-agnostic and carries over from the spike unchanged; only guest internals change.

## Architecture — two heal loops, each matched to its layer
- **Tier 1 — Guest self-heal**: node-local, ansible + systemd watchdog (mirrors `clusterip_heal`). The Arch guest = 4th `workers` node in the node-maintenance inventory.
- **Tier 2 — Host VM watchdog**: cross-host, k8s CronJob (GitOps, Flux-reconciled), SSHes the NAS + runs `virsh` (libvirt group, no root).

Rationale for the split (GitOps + uniformity): node-local self-heal = ansible (like clusterip_heal); cross-host management of a *different* machine = k8s CronJob (like the cluster's other ops jobs — backups/trivy). Forcing the cross-host piece into node-maintenance breaks that framework's node-local premise.

## Tier 1 — Guest (Arch node)
Reused roles as-is: `base_config`, `hardening`, `firewall`, `k3s_config`, `clusterip_heal`. **Excluded**: `nic_tuning` (virtio NIC — no igc/EEE). Build-check: `k3s_config` NVMe by-uuid/swap-path logic must no-op or be guarded on a virtio-disk VM.

New role **`immich_gpu_node`** (idempotent = install AND heal):
- i915 render-only: `/etc/modprobe.d/i915-render.conf` = `options i915 disable_display=1`; boot-blacklist i915; keep i915 out of mkinitcpio; `load-i915.service` (oneshot, After=multi-user.target, `modprobe i915`).
- `linux-firmware` present (MTL GuC/HuC/DMC).
- virtiofs mount unit for the library share (systemd .mount or fstab), depends on the host exposing the `<filesystem>` device.
- Deploys the guest-heal watchdog (below).

New guest-heal watchdog `immich-gpu-heal.sh` + systemd timer (mirrors `clusterip_heal` exactly):
- **Light check every cycle (cheap, no GPU compute — M6)**: i915 loaded? `renderD129` present? `vainfo` lists encode entrypoints? k3s-agent active + node Ready? virtiofs library mount present?
- **Heal**: `modprobe i915` / restart `load-i915.service`; remount virtiofs; restart `k3s-agent` if NotReady.
- **Full QSV encode probe**: only hourly (or on-demand), NOT every cycle — avoids contending with live transcodes.
- Emits node-exporter textfile metrics (`immich_gpu_render_ok`, `immich_gpu_qsv_ok`, `immich_gpu_virtiofs_ok`).
- **Bounded self-heal (per review — carry over `clusterip_heal`'s guards, don't just "mirror" it):** per-action cooldown + max-restarts-per-window + a `..._heal_gaveup` metric when exhausted, so the healer surfaces a *persistent* fault (alert) instead of flapping `k3s-agent`/i915 reloads indefinitely.

## Tier 2 — Host VM watchdog (k8s CronJob)
Flux-reconciled manifest, `nodeSelector` **off** the GPU node (CP or W1) so it can heal the GPU node when down. Runs a script that SSHes the NAS as `akhozya` (SOPS key) + uses `virsh` (libvirt group, no root):
- **Checks**: VM defined? domain XML matches the **canonical XML in Git** (drift, incl. the `<hostdev>` + `<filesystem>`)? running? iGPU on `vfio-pci`? (autostart is the zettOS-UI native toggle — see Findings; watchdog verifies but the user sets it once.)
- **Auto-heal (no root)**: `virsh define` from the Git canonical XML on drift/missing; `virsh start` if down.
- **Reset-bug wedge (M2 — CRITICAL, hardened per Codex review)**: `NotReady` alone is NOT proof the guest is dead — kubelet/API/network hiccups make a node NotReady while the VM + live transcodes keep running, so an auto cold-restart would *become* the outage (kill in-flight transcodes/writes). Wedge predicate = the reset-bug's true signature: **guest fully unreachable — ping AND ssh both fail — sustained >10min, AND domain state=`running`** (kernel hung at boot, no network at all). Heal = `virsh destroy`+`start` (forces vfio reset). **Auto-cold-restart DEFAULT OFF** (`HEAL_COLD_RESTART=false`): always alert with the one-command fix; operator flips it on per-node once trusted. NEVER gate the destructive action on `NotReady`/metrics alone.
- **Diagnose-only → alert** (can't self-fix): NAS SSH key wiped (SSH fails → alert + re-add command); **`akhozya` dropped from the NAS `libvirt` group** (per review — a zettOS update could clobber `/etc/group`: SSH still works but `virsh` heal *silently* can't; check `getent group libvirt` each run → alert + `usermod -aG libvirt akhozya`); host i915 firmware missing (probe → alert).

Metrics/alerting (M5 — no pushgateway in this homelab. Per review: the immich-backup CronJob file shows only the *CronJob shape* + a pinned image, NOT NetworkPolicy/SOPS/VMRule — so those are **authored explicitly here, not copied as precedent**): the watchdog reports via **Job success/failure + structured logs to Loki**; a **new VMRule** alerts on `kube_job_status_failed` / last-success-age (the `NoRecentBackups` pattern) → Telegram, plus a Loki-based alert for the diagnose-only findings.

## GPU exposure to the Immich pods (Kyverno PSS-safe — HIGH, per review; was undesigned)
Immich `server` (transcode) + `machine-learning` pods need the passed-through iGPU render node. Under Kyverno PSS-enforce, a raw `hostPath: /dev/dri` + privileged pod is a **PSS/hostPath violation** ([[review-invariants]]: PSS Baseline forbids hostPath below privileged). So:
- **Primary: Intel GPU device-plugin** (`intel-device-plugins-operator` + `gpu-plugin` + node-feature-discovery). Pods request `gpu.intel.com/i915` as a **resource** — the plugin injects the render device, **no privileged, no hostPath** → passes PSS + Kyverno clean. Pin operator/plugin images; the plugin DaemonSet is nodeSelector'd to the GPU node only.
- **Fallback (only if the plugin can't bind renderD129):** `hostPath: /dev/dri` + a **scoped Kyverno PSS exception** for the immich namespace/workload (documented, single-namespace, last resort).
- Node pinning: `server`+`machine-learning` → nodeSelector on the `immich_gpu_node` label; **postgres (CNPG) + redis stay in-cluster on the Arch nodes** (DB HA + backup unchanged). `LIBVA_DRIVER_NAME=iHD`, target the Intel render node.

## Heal-vs-alert boundary
- **Auto-heal**: anything via libvirt-group virsh, privileged docker, or guest sudo (i915 reload, virsh define/start/cold-restart, k3s-agent restart, virtiofs remount).
- **Alert-only** (needs NAS root): `/lib/firmware` writes, host config, SSH-key re-add. Telegram carries the finding + the exact fix command.

## Reset-bug carve-out
The guest must NEVER `systemctl reboot` (wedges the GPU — only a host cold-restart via vfio reset recovers). `rolling-restart-k3s.yml` gets a guard: this node is drained + cold-restarted via the host watchdog (`virsh destroy`+`start`), not rebooted in-guest. Node labeled to select this path.

## Spike findings folded in (2026-07-08, on the box)
- **C1 (survivability)**: domain XML (`/etc/libvirt/qemu/<uuid>.xml`), autostart symlink, and `/etc/group` membership are all standard-located + **survived a NAS reboot**. Reboot-durable. Update-durability: keys confirmed-wiped by updates; XML/group unconfirmed → the heal must *detect + recover* (re-define from Git; alert on key-wipe).
- **C2 (dual-ownership)**: `zettos-vm.service` runs (owns lifecycle/UI/autostart) BUT our q35+`<hostdev>` edits **persisted through a reboot** and there are **no libvirt hooks** → zettos-vm does NOT reconcile domain XML. Model: **zettos-vm = lifecycle + native autostart toggle; domain XML = ours to edit, it sticks.** Use the zettOS-UI autostart (native), keep virsh for XML content. Residual risk = zettOS-UI-edit or major update rewriting the domain → the watchdog's re-define-from-Git recovers it.
- **M3 (role HW-coupling, hardened per review)**: `nic_tuning` currently runs `hosts: all` in `node-config.yml` → adding the VM as a plain worker WOULD run the igc/EEE tuning on the virtio guest. Fix: put the guest in a dedicated inventory group (`virtual`) and gate `nic_tuning` with `when: inventory_hostname not in groups['virtual']` (or split it into a `hosts: physical` play). Others OS-generic (build-check `k3s_config` NVMe-by-uuid/disk logic no-ops on a virtio disk).
- **M5 (metrics)**: no pushgateway → kube-state-metrics Job status + VMRule + Loki logs.

## Operator actions (manual, at build time — Claude can't do these)
- **At Arch-VM creation: enable the zettOS-UI "Auto-start" toggle** (per-VM, native — zettos-vm.service respects it; more reliable than `virsh autostart`). Claude will nudge at VM-creation time.
- Re-add SSH keys (NAS host + guest) after any zettOS update that wipes them (heal detects + alerts with the command).

## Build sequence — early node prep (privileged, during onboarding)
1. **Kernel → `linux-lts`** (fleet uniformity/stability — other 3 nodes run linux-lts, not mainline). Install `linux-lts`+`linux-lts-headers`, regen initramfs+bootloader, **remove mainline `linux`** (VM shipped with `linux` 7.1.3). MUST precede the i915 config (that config targets the booting kernel). MTL i915 fine on LTS (NAS host runs 6.12-LTS with i915).
2. Then the `immich_gpu_node` role (i915 render config on the LTS kernel).

## Open items — build-phase spikes (not design blockers)
- **C3 (Arch i915)**: the disable_display+blacklist+systemd-load approach is proven on Ubuntu (kernel 7.0); Arch translation = mkinitcpio (i915 out of MODULES + blacklist) + bootloader cmdline, **on linux-lts**. **Confirm the guest bootloader** (grub vs systemd-boot — the zettOS wizard's choice) to know the cmdline mechanism. Validate on the fresh Arch guest (linux-lts) before wiring the role.
- **Arch install portability**: does the homelab `install.sh`/`install-worker.sh` work on a VM (virtio disk/NIC), or is a manual/archinstall path needed? Custom-ISO boot is proven (Ubuntu server ISO attached). 
- **k3s_config disk assumptions** on a virtio-disk VM.
- **DB**: Immich DB stays CNPG in-cluster (only immich-server + ML pin to the GPU node) — migration-spec detail, assumed here.

## GitOps placement
- Guest roles → `docs/scripts/node-maintenance/ansible/roles/immich_gpu_node/` + guest-heal, wired in `node-config.yml` (guest-only play or a tagged group); inventory gets the guest as a `workers` host.
- Host CronJob + canonical VM XML (ConfigMap) + SOPS NAS-SSH key → `apps/immich/` (co-located), Flux-reconciled. **NetworkPolicy (per review):** select the Job pods by `batch.kubernetes.io/job-name`/a dedicated pod label — NOT an `app:` selector (can match zero Job pods) and NOT a namespace-wide egress (clamps unrelated Jobs) ([[review-invariants]] Job-isolation). Egress = ONLY the NAS host IP:65300 (SSH) + DNS; default-deny otherwise.
- VMRule for both tiers → Telegram.

## Testing
- Ansible role idempotence (run twice → zero changes).
- Heal scripts: assert-based self-checks on detection logic (mock `virsh`/`lsmod`/`vainfo` output).
- Integration on the real VM: `rmmod i915` → guest-heal reloads; `virsh destroy` → host-watchdog restarts; forced wedge (guest soft-reboot) → host cold-restart recovers; drift (edit domain) → re-define from Git.

## Residual risks (accepted / mitigated)
- Host-watchdog's NAS SSH key wiped by updates → self-breaks, but detects+alerts (M1). Recurring toil, bounded.
- Auto-cold-restart false-positive → brief downtime; gated on sustained NotReady + `running` state to minimize.
- zettOS major update could clobber domain/group/firmware → heal re-defines what it can, alerts the rest.
