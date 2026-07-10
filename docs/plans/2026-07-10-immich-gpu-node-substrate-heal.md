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
- **Checks**: VM defined? domain XML matches the **canonical XML in Git** (drift, incl. the `<hostdev>` + `<filesystem>`)? running? iGPU on `vfio-pci`? (UI Auto-start is OFF — C2/C4; the watchdog itself owns start via `virsh start` when down, so it IS the autostart.)
- **Auto-heal (no root)**: `virsh define` from the Git canonical XML on drift/missing; `virsh start` if down.
- **Reset-bug wedge (M2 — CRITICAL, hardened per Codex review)**: `NotReady` alone is NOT proof the guest is dead — kubelet/API/network hiccups make a node NotReady while the VM + live transcodes keep running, so an auto cold-restart would *become* the outage (kill in-flight transcodes/writes). Wedge predicate = the reset-bug's true signature: **guest fully unreachable — ping AND ssh both fail — sustained >10min, AND domain state=`running`** (kernel hung at boot, no network at all). **Heal is NOT `virsh destroy`**: force-destroying a passthrough VM re-binds the still-dirty iGPU to the host i915 (`managed='yes'`) and GuC-wedges the host → **NAS host crash, OBSERVED 2026-07-10** (see C3). A wedged guest is also deaf to ACPI, so graceful `virsh shutdown` times out too — net, **there is no safe *auto* virsh recovery for a true wedge**; the only clean reset is a **NAS host reboot** (power-cycles the iGPU). So the wedge path stays **alert-only** (`HEAL_COLD_RESTART=false`, default + kept off): Telegram the one-command operator fix — `virsh shutdown --mode acpi --timeout 120 <dom>` *if the guest still answers*, else a NAS host reboot. **NEVER auto-destroy**; NEVER gate any destructive action on `NotReady`/metrics alone.
- **Diagnose-only → alert** (can't self-fix): NAS SSH key wiped (SSH fails → alert + re-add command); **`akhozya` dropped from the NAS `libvirt` group** (per review — a zettOS update could clobber `/etc/group`: SSH still works but `virsh` heal *silently* can't; check `getent group libvirt` each run → alert + `usermod -aG libvirt akhozya`); host i915 firmware missing (probe → alert).

Metrics/alerting (M5 — no pushgateway in this homelab. Per review: the immich-backup CronJob file shows only the *CronJob shape* + a pinned image, NOT NetworkPolicy/SOPS/VMRule — so those are **authored explicitly here, not copied as precedent**): the watchdog reports via **Job success/failure + structured logs to Loki**; a **new VMRule** alerts on `kube_job_status_failed` / last-success-age (the `NoRecentBackups` pattern) → Telegram, plus a Loki-based alert for the diagnose-only findings.

## GPU exposure to the Immich pods (Kyverno PSS-safe — HIGH, per review; was undesigned)
Immich `server` (transcode) + `machine-learning` pods need the passed-through iGPU render node. Under Kyverno PSS-enforce, a raw `hostPath: /dev/dri` + privileged pod is a **PSS/hostPath violation** ([[review-invariants]]: PSS Baseline forbids hostPath below privileged). So:
- **Primary: Intel GPU device-plugin** (`intel-device-plugins-operator` + `gpu-plugin` + node-feature-discovery). Pods request `gpu.intel.com/i915` as a **resource** — the plugin injects the render device, **no privileged, no hostPath** → passes PSS + Kyverno clean. Pin operator/plugin images; the plugin DaemonSet is nodeSelector'd to the GPU node only.
- **Fallback (only if the plugin can't bind renderD129):** `hostPath: /dev/dri` + a **scoped Kyverno PSS exception** for the immich namespace/workload (documented, single-namespace, last resort).
- Node pinning: `server`+`machine-learning` → nodeSelector on the `immich_gpu_node` label; **postgres (CNPG) + redis stay in-cluster on the Arch nodes** (DB HA + backup unchanged). `LIBVA_DRIVER_NAME=iHD`, target the Intel render node.

## Heal-vs-alert boundary
- **Auto-heal**: anything via libvirt-group virsh, privileged docker, or guest sudo (i915 reload, virsh define/start/**graceful** cold-restart — `shutdown --mode acpi --timeout 120`+`start`, **never forced `destroy`** on this passthrough VM, see C3 — k3s-agent restart, virtiofs remount).
- **Alert-only** (needs NAS root): `/lib/firmware` writes, host config, SSH-key re-add. Telegram carries the finding + the exact fix command.

## Reset-bug carve-out
The guest must NEVER `systemctl reboot` / in-guest reboot (wedges the GPU — only a clean host-side reset recovers). `rolling-restart-k3s.yml` gets a guard: this node is drained, then cold-restarted via **graceful `virsh shutdown --mode acpi --timeout 120` + `virsh start`** (a *responsive* drained guest releases the iGPU cleanly), **never `virsh destroy`** — forced destroy of this passthrough VM crashed the NAS host (2026-07-10, C3). Node labeled to select this path.

## Spike findings folded in (2026-07-08, on the box)
- **C1 (survivability)**: domain XML (`/etc/libvirt/qemu/<uuid>.xml`), autostart symlink, and `/etc/group` membership are all standard-located + **survived a NAS reboot**. Reboot-durable. Update-durability: keys confirmed-wiped by updates; XML/group unconfirmed → the heal must *detect + recover* (re-define from Git; alert on key-wipe).
- **C2 (dual-ownership — REVISED 2026-07-10: UI ops rewrite the domain)**: q35+`<hostdev>` edits survive a plain *reboot*, BUT **any zettOS-UI VM operation (shutdown, start, autostart toggle) REGENERATES the domain from the appliance's default template** — OBSERVED: a UI shutdown reset the domain q35→`i440fx`, dropped `<hostdev>` (GPU) + `<filesystem>` (virtiofs) + `<memoryBacking>` (memfd), and replaced the pinned-MAC `type='network'` NIC with a random-MAC `type='direct'` macvtap → wrong DHCP IP (C5). So the domain XML is **NOT durably ours** — the appliance template wins on every UI op. **Rules: (1) NEVER use the zettOS UI for this VM — lifecycle is `virsh`-only. (2) The Tier-2 watchdog's domain-drift check (re-define from the Git canonical XML) is ESSENTIAL and must run every cycle, not just after reboots.** Recovery from a clobber = `virsh define <canonical.xml>` + graceful stop + `virsh start` (proven: 10s clean boot, GPU+virtiofs+MAC all restored). **BUT the appliance DOES reconcile lifecycle**: with UI "Auto-start" ON it restarted a *running* VM out-of-band (domain Id `-`→1(mine)→2(appliance), libvirt `autostart=disable`, operator didn't touch it) — a *soft* restart that wedges the passed-through iGPU (reset-bug), and its start path also *errors* on the GPU detach after a host reboot ("error state"). See C4. **Decision: UI Auto-start OFF; the Tier-2 watchdog owns start** (`virsh start` when down — reliable + proven, cold-start-only so the GPU always resets). `virsh autostart` also left OFF (the appliance, not libvirtd, runs boot-time starts). Residual: a zettOS-UI-edit/major-update rewriting the domain → the watchdog's re-define-from-Git recovers it.
- **C3 (forced-destroy crashes the host — 2026-07-10, live incident)**: `virsh destroy` on the passthrough VM re-binds the still-dirty iGPU to the host i915 (`managed='yes'`) → host GuC wedge → **NAS crash + reboot** (which wiped SSH `authorized_keys` — actually StrictModes-rejected after `/home` perms reset to group-writable — and reset `/home/akhozya` ownership). Consequences: **(1)** cold-restart is graceful-only — `virsh shutdown --mode acpi --timeout 120` then `start`, and only when the guest ACPI still answers; a truly-wedged (hung) guest has **no safe virsh recovery** → a **NAS host reboot** is the clean iGPU reset. **(2)** After a NAS reboot the **zettOS-UI VM start / autostart path errored** on the GPU detach (VM shown "error state") while libvirt-level **`virsh start` succeeded** — so the watchdog's `virsh start` is the reliable + sole start path (UI autostart is now OFF — C2/C4). **(3)** Recovery after a NAS reboot may need the SSH key re-added: `akhozya` is in the `libvirt` group (virsh needs no root) and owns `~/.ssh`, so the operator can re-append the pubkey **without sudo** once `/home` perms settle. Note the reboot did NOT wipe the key — it reset `/home` to group-writable → sshd StrictModes rejected the still-present key; password-SSH (port 56634, `PubkeyAuthentication=no`) still works to re-verify. NAS `sudo` password is separate from the SSH-login password and rejected both — don't burn attempts, use libvirt-group instead.
- **C4 (appliance lifecycle-reconcile re-wedges the VM — 2026-07-10, live)**: with UI Auto-start ON, `zettos-vm` restarted an already-running (virsh-started, verified-healthy) VM on its own → *soft* cycle → iGPU not reset → **wedged at splash**. Then graceful `virsh shutdown` timed out (guest deaf to ACPI), destroy is barred (C3) → **NAS host reboot** was the only recovery. Root fix = **UI Auto-start OFF** (C2) so the appliance stops reconciling this VM's lifecycle; the watchdog's `virsh start` is the sole start path. The Tier-2 watchdog thus doubles as the autostart mechanism.
- **C5 (UI op clobbers the domain → wrong MAC/IP — 2026-07-10, live)**: after a NAS reboot, disabling autostart required a UI shutdown; that UI op **regenerated the domain from the appliance template** (q35→i440fx, GPU+virtiofs+memfd gone, NIC → random MAC `52:54:00:6b:16:6e` `type='direct'` macvtap). The VM then booted fine (no GPU = no wedge) but the new MAC missed the router's `.231` reservation → no route to host, looked "down." Diagnosis path (no guest network, no guest-agent): `virsh domiflist` showed the wrong MAC; `virsh dumpxml` showed i440fx/no-hostdev. Recovery: `virsh define /…/immich-vm-q35-virtiofs.xml` → graceful `virsh shutdown` (safe: current instance had no hostdev) → `virsh start` → clean 10s boot, IP `.231`, GPU renderD129, virtiofs auto-mounted. **Canonical domain XML MUST live in Git** (watchdog re-defines from it) — a NAS-only backup is not enough. The mount `.mount` unit lives in the guest FS (survives domain redefine) and auto-mounted correctly on the recovered boot.
- **M3 (role HW-coupling, hardened per review)**: `nic_tuning` currently runs `hosts: all` in `node-config.yml` → adding the VM as a plain worker WOULD run the igc/EEE tuning on the virtio guest. Fix: put the guest in a dedicated inventory group (`virtual`) and gate `nic_tuning` with `when: inventory_hostname not in groups['virtual']` (or split it into a `hosts: physical` play). Others OS-generic (build-check `k3s_config` NVMe-by-uuid/disk logic no-ops on a virtio disk).
- **M5 (metrics)**: no pushgateway → kube-state-metrics Job status + VMRule + Loki logs.

## Operator actions (manual, at build time — Claude can't do these)
- **DISABLE the zettOS-UI "Auto-start" toggle** for this VM (per-VM). Native autostart soft-restarts the VM out-of-band → reset-bug wedge (C4) and errors on the GPU detach after a host reboot. The Tier-2 watchdog starts the VM via `virsh` instead (cold-start-only, GPU always resets). Claude will nudge at VM-creation time.
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
- Integration on the real VM: `rmmod i915` → guest-heal reloads; graceful `virsh shutdown --timeout 120`+`start` recovers a *responsive* guest; drift (edit domain) → re-define from Git. **Do NOT test-inject a wedge via `virsh destroy`** — it crashed the host (C3). A true wedge (guest `systemctl reboot` → hung at splash) is **alert-only** → verify the alert fires + the operator NAS-host-reboot recipe, not an auto-heal.

## Residual risks (accepted / mitigated)
- Host-watchdog's NAS SSH key wiped by updates → self-breaks, but detects+alerts (M1). Recurring toil, bounded.
- Reset-bug wedge is **alert-only** (auto-cold-restart kept off): a true wedge needs a NAS host reboot, and forced `virsh destroy` crashes the host (C3) — so recovery is operator-in-the-loop by design. Cost = manual step on a rare wedge; benefit = no auto-action can crash the host or kill live transcodes on a false positive.
- zettOS major update could clobber domain/group/firmware → heal re-defines what it can, alerts the rest.

## Optional — 1Password interactive SSH (deferred, end-of-plan convenience)
The VM and NAS both authenticate via the on-disk file key `~/.ssh/zl_nas_ed25519` — matching the NAS admin-access model ([[reference_nas]]: file-key, not 1P agent). Automation **must stay on the file key**: this repo's Bash/ansible and the Tier-2 host watchdog run headless (no interactive 1P agent), so they keep `-o IdentityAgent=none -o IdentitiesOnly=yes -i ~/.ssh/zl_nas_ed25519`.

Optional operator convenience (do after go-live, not a build blocker) — interactive human SSH from any machine without copying the file key:
1. Store `zl_nas_ed25519` as a 1Password **SSH key** item in the Personal vault (private key import).
2. Enable the 1Password SSH agent; add a `~/.ssh/config` host block for `immich-vm` (192.168.1.231) + the NAS (192.168.1.136:56634) pointing `IdentityAgent` at the 1P agent socket.
3. Same pubkey → no server-side change (already in both `authorized_keys`); the file key stays as the automation/break-glass path.

Purely additive — does not touch the substrate, heal loops, or domain XML.
