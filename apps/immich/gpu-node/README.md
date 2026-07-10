# Immich GPU-node — VM substrate (Path B)

Canonical libvirt domain XML for the `immich-vm` GPU-passthrough VM on the zettOS
NAS (`192.168.1.136`), guest IP `192.168.1.231`. Design:
[`docs/plans/2026-07-10-immich-gpu-node-substrate-heal.md`](../../../docs/plans/2026-07-10-immich-gpu-node-substrate-heal.md).

## Why a libvirt XML under `apps/`
The zettOS appliance regenerates the VM domain from its own template on **any UI
op** (shutdown/start/autostart toggle) — wiping q35, the `<hostdev>` GPU passthrough,
the `<filesystem>` virtiofs share, `memfd` `memoryBacking`, and the pinned MAC (C2/C5
in the design). So the domain is **not durably ours**. This file is the source of
truth the planned **Tier-2 host watchdog** (k8s CronJob, step 4) re-defines from on
drift: `virsh define immich-vm-domain.xml`. A NAS-only backup is insufficient — hence Git.

## Status: reference-only, NOT wired
No `kustomization.yaml` references this file yet, so Flux/kustomize ignore it (inert,
does not render, does not affect CI). Step 4 adds the watchdog CronJob + a
`configMapGenerator` over this `.xml` + VMRule + NetworkPolicy + SOPS NAS-SSH key.

## The canonical elements (must survive any re-define)
- `machine='pc-q35-7.2'` + stateless OVMF (`OVMF_CODE_4M.fd`, no nvram)
- `<hostdev managed='yes'>` slot `0x02` = host `0000:00:02.0` (Meteor Lake iGPU)
- `<filesystem><driver type='virtiofs'/>` `immich-library` (15T library share)
- `<memoryBacking><source type='memfd'/><access mode='shared'/>` (virtiofs requires)
- `<interface>` MAC `52:54:00:82:be:df` on `vnet-bridge0` (router-reserved `.231`)

Domain name = `0398541a-c088-48cd-b16a-4b45d31a92f3` (internal uuid
`c629f1de-01ff-40bc-9521-8d7adb643636`, title `immich-vm`).

## Lifecycle rules (learned the hard way — see design C2–C5)
- **`virsh` only, never the zettOS UI.** virsh needs `-c qemu:///system` (SYSTEM domains).
- Autostart **OFF** (appliance soft-restart re-wedges the passthrough iGPU).
- Cold-restart = graceful `virsh shutdown --mode acpi --timeout 120` + `virsh start`.
  **Never `virsh destroy`** a passthrough VM — dirty iGPU re-binds to host i915 →
  NAS host crash. A true wedge = NAS host reboot.
- Clobber recovery: `virsh define immich-vm-domain.xml` → graceful shutdown → `virsh start`.

Mirror on the NAS: `/home/akhozya/immich-vm-xml-backups/immich-vm-q35-virtiofs.xml`
(break-glass; this Git copy is now canonical).
