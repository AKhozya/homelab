# Immich GPU-node — VM substrate (Path B)

Canonical libvirt domain XML for the `immich-vm` GPU-passthrough VM on the zettOS
NAS (`192.168.1.136`), guest IP `192.168.1.231`. Design: the Immich GPU-node
substrate heal design plan, removed after `7a9add14`.

## Why a libvirt XML under `apps/`
The zettOS appliance regenerates the VM domain from its own template on **any UI
op** (shutdown/start/autostart toggle) — wiping q35, the `<hostdev>` GPU passthrough,
the `<filesystem>` virtiofs share, `memfd` `memoryBacking`, and the pinned MAC (C2/C5
in the design). So the domain is **not durably ours**. This file is the source of
truth the **Tier-2 host watchdog** (k8s CronJob) re-defines from on drift:
`virsh define immich-vm-domain.xml`. A NAS-only backup is insufficient — hence Git.

## Tier-2 host watchdog (this dir, wired into `apps/immich/kustomization.yaml`)
A CronJob (`immich-vm-heal`, immich ns, every 5 min, scheduled OFF the GPU node)
SSHes the NAS host and drives `virsh` to keep the domain **defined-from-Git + running**.
It IS the autostart — native/UI autostart is OFF by design (C2/C4).

| File | Role |
|---|---|
| `immich-vm-heal.sh` | Heal logic. Non-root, POSIX sh. Checks ssh/ libvirt-group/ defined/ drift/ running; heals via `virsh define` (drift/missing) + `virsh start` (shut off). NEVER `destroy`, NEVER restarts a running domain (C3). |
| `heal-cronjob.yaml` | CronJob. Non-root (`require-non-root` is Enforce for immich), drop-ALL, RoRFS, seccomp; `alpine/git` (bundles ssh) — no runtime apk so egress stays NAS-only. |
| `heal-networkpolicy.yaml` | Egress scoped to the Job pods (`app.kubernetes.io/name: immich-vm-heal`) → NAS `:56634` + DNS only. |
| `heal-serviceaccount.yaml` | Dedicated SA, no RBAC, no token (makes no k8s API calls). |
| `nas-known-hosts-configmap.yaml` | Pinned NAS host key (`:56634`). A NAS rekey → fails closed. |
| `nas-ssh-key-secret.yaml` | SOPS-encrypted **dedicated** `immich-vm-heal` ed25519 private key. |
| `immich-vm-heal.sh` + `immich-vm-domain.xml` | Mounted via `configMapGenerator` (stable names, no hash suffix). |

Alerts: VMRule group `immich-gpu-node-alerts` (`ImmichVMHealJobFailing`,
`ImmichVMHealStale`) → Telegram. VM-down itself is covered by `NodeNotReady` (immich-vm).

**Go-live requires an operator step**: append the dedicated PUBLIC key to the NAS
`~akhozya/.ssh/authorized_keys` (the private half is in the SOPS secret; the pubkey
is printed at build time and recorded in commit `da6857aa`). Until then the watchdog job fails
(`ssh_unreachable`) — which is the correct fail-closed signal.

## The canonical elements (must survive any re-define)
- `machine='pc-q35-7.2'` + stateless OVMF (`OVMF_CODE_4M.fd`, no nvram)
- `<hostdev managed='yes'>` slot `0x02` = host `0000:00:02.0` (Meteor Lake iGPU)
- `<filesystem><driver type='virtiofs'/>` `immich-library` (15T library share)
- `<memoryBacking><source type='memfd'/><access mode='shared'/>` (virtiofs requires)
- `<interface>` MAC `52:54:00:82:be:df` on `vnet-bridge0` (router-reserved `.231`)
- `<on_crash>preserve</on_crash>` — **intentionally diverges** from the original NAS
  snapshot (which had `destroy`). `destroy` on a guest crash tears the domain down,
  re-binding the dirty iGPU to the host = the C3 crash path, and leaves it `shut off`
  so the watchdog would auto-start it. `preserve` keeps it `crashed` → alert-only.

Domain name = `0398541a-c088-48cd-b16a-4b45d31a92f3` (internal uuid
`c629f1de-01ff-40bc-9521-8d7adb643636`, title `immich-vm`).

## Lifecycle rules (learned the hard way — see design C2–C5)
- **`virsh` only, never the zettOS UI.** virsh needs `-c qemu:///system` (SYSTEM domains).
- Autostart **OFF** (appliance soft-restart re-wedges the passthrough iGPU).
- Cold-restart = graceful `virsh shutdown --mode acpi <dom>` (no `--timeout` — the flag does
  not exist on the NAS libvirt), then poll `virsh domstate` until `shut off`, then `virsh start`.
  `--mode agent` is the reliable primary now qemu-guest-agent is installed.
  **Never `virsh destroy`/`reset`** a passthrough VM — dirty iGPU re-binds to host i915 →
  NAS host crash. A true wedge (never reaches `shut off`) = alert + NAS host reboot, never destroy/reset.
- Clobber recovery: `virsh define immich-vm-domain.xml` → graceful shutdown → `virsh start`.
- **Applying a Git change the watchdog does not check** (its drift check matches only
  selected XML markers, so `<graphics>` and similar edits never reach the NAS by themselves):
  edit the NAS definition in place, then do the cold restart above. An in-place edit keeps the
  PCI `<address>` values libvirt already assigned. The Git file has none, so a `define` from it
  makes libvirt assign them again. Nobody has checked that the new addresses match the old ones. A define
  changes only the saved config; the running VM keeps the old one until the cold restart.

  ```bash
  D=0398541a-c088-48cd-b16a-4b45d31a92f3; V="virsh -c qemu:///system"
  ssh zl-nas "$V dumpxml --inactive $D" > cur.xml
  # Copy cur.xml to new.xml and change only the element that changed in Git.
  diff cur.xml new.xml                                   # must show only that change
  ssh zl-nas "$V define /dev/stdin" < new.xml
  ssh zl-nas "$V dumpxml --inactive $D" | diff new.xml - # empty = saved as intended
  ```
- **Kernel-bump reboots are AUTOMATED** (node-maintenance phase2 PLAY 1b, main `19d51c19`): after weekly patching, a stale running kernel triggers an in-guest graceful `poweroff` (== `virsh shutdown --mode acpi`) → the `immich-vm-heal` watchdog cold-`virsh start`s the shut-off domain → waits node Ready. No operator step for the routine kernel case; the manual `virsh` cold-restart above stays the break-glass path (wedged-but-running, clobber recovery). Test on demand: `sudo ansible-playbook -i inventory.yml phase2.yml --limit immich-vm -e vm_cold_cycle_force=true`.

Mirror on the NAS: `/home/akhozya/immich-vm-xml-backups/immich-vm-q35-virtiofs.xml`
(break-glass; this Git copy is now canonical).

## Console (VNC)
| Fact | Value |
|---|---|
| Listener | NAS loopback `127.0.0.1:5900`, no password |
| Since | 2026-09-29; before that, any LAN host could connect |
| Access | SSH tunnel below, then a VNC client on `localhost:5901` |
| Local port | 5901, because macOS Screen Sharing can hold 5900 |

```bash
ssh -N -L 5901:127.0.0.1:5900 zl-nas
```

Never send Ctrl-Alt-Del from the console: it is an in-guest reboot (see `on_reboot` in the XML).
