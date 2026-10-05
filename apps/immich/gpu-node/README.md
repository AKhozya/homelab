# Immich GPU-node — VM substrate

Canonical libvirt domain XML for the `immich-vm` GPU-passthrough VM on the zettOS
NAS (`192.168.1.136`), guest IP `192.168.1.231`. Design record: git history up to `7a9add14`.

## Why a libvirt XML under `apps/`
The zettOS appliance regenerates the VM domain from its own template on **any UI
op** (shutdown/start/autostart toggle) — wiping q35, the `<hostdev>` GPU passthrough,
the `<filesystem>` virtiofs share, `memfd` `memoryBacking`, and the pinned MAC (so the
guest can lose its `.231` address). So the domain is **not durably ours**. The host watchdog
below re-defines it from this file on drift: `virsh define immich-vm-domain.xml`.
A NAS-only backup is insufficient — hence Git.

## Host watchdog (this dir, wired into `apps/immich/kustomization.yaml`)
A CronJob (`immich-vm-heal`, immich ns, every 5 min, scheduled OFF the GPU node)
SSHes the NAS host and drives `virsh` to keep the domain **defined-from-Git + running**.
After the 2026-10-03 NAS reboot, its 11:20 UTC run found the VM stopped and started it, about
2 minutes after boot. The libvirt autostart flag is on (`virsh dominfo`, link dated 2026-07-11).
Never toggle autostart in the zettOS UI. A UI action regenerates the domain. The July 2026
incident notes (`0a6e3dcd`) also record that the appliance's autostart restarts a running VM,
which leaves the iGPU unresponsive.

| File | Role |
|---|---|
| `immich-vm-heal.sh` | Heal logic. Non-root, POSIX sh. Checks ssh/ libvirt-group/ defined/ drift/ running; heals via `virsh define` (drift/missing) + `virsh start` (shut off). NEVER `destroy`, NEVER restarts a running domain (see Lifecycle rules). |
| `heal-cronjob.yaml` | CronJob. Non-root (`require-non-root` is Enforce for immich), drop-ALL, RoRFS, seccomp; `alpine/git` (bundles ssh) — no runtime apk so egress stays NAS-only. |
| `heal-networkpolicy.yaml` | Egress scoped to the Job pods (`app.kubernetes.io/name: immich-vm-heal`) → NAS `:56634` + DNS only. |
| `heal-serviceaccount.yaml` | Dedicated SA, no RBAC, no token (makes no k8s API calls). |
| `nas-known-hosts-configmap.yaml` | Pinned NAS host key (`:56634`). A NAS rekey → fails closed. |
| `nas-ssh-key-secret.yaml` | SOPS-encrypted **dedicated** `immich-vm-heal` ed25519 private key. |
| `immich-vm-heal.sh` + `immich-vm-domain.xml` | Mounted via `configMapGenerator` (stable names, no hash suffix). |

Alerts: VMRule group `immich-gpu-node-alerts` → Telegram. `NodeNotReady` (immich-vm) covers a down VM.

| Alert | Reads | Condition | `for` | `keep_firing_for` |
|---|---|---|---|---|
| `ImmichVMHealJobFailing` | this CronJob's Jobs | a heal Job has a failed pod and no run succeeded in the last 20 min | 5m | — |
| `ImmichVMHealStale` | this CronJob | no run succeeded in the last 30 min | 10m | — |
| `ImmichGPURenderDown` | `immich_gpu_render_ok`, written by `immich-gpu-heal` in the guest | the Intel render node is missing | 8m | — |
| `ImmichGPUHealGaveUp` | `immich_gpu_heal_giveup` | the guest watchdog makes no further `load-i915` restart after 3 in 30 min | 3m | 30m |
| `ImmichGPUQSVProbeStuck` | `immich_gpu_qsv_stuck` | a `vainfo` probe still runs after its timeout and kill | 10m | — |

`PodPhaseNotRunning` and `JobFailed` exclude this CronJob's pods and Jobs: a NAS reboot fails some of
its runs, and `ImmichVMHealJobFailing` and `ImmichVMHealStale` cover it.

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
  re-binding the dirty iGPU to the host, which crashes the NAS, and leaves it `shut off`
  so the watchdog would auto-start it. `preserve` keeps it `crashed` → alert-only.

Domain name = `0398541a-c088-48cd-b16a-4b45d31a92f3` (internal uuid
`c629f1de-01ff-40bc-9521-8d7adb643636`, title `immich-vm`).

## Lifecycle rules (from live incidents, July 2026)
- **`virsh` only, never the zettOS UI.** virsh needs `-c qemu:///system` (SYSTEM domains).
- **Do not rely on autostart.** The libvirt flag is on, but after the 2026-10-03 NAS reboot the
  CronJob started the VM (see Host watchdog). Never toggle autostart in the zettOS UI.
- Cold-restart = graceful `virsh shutdown --mode acpi <dom>` (no `--timeout` — the flag does
  not exist on the NAS libvirt), then poll `virsh domstate` until `shut off`, then `virsh start`.
  qemu-guest-agent answers `guest-ping` (checked 2026-10-04), but `--mode agent` shutdown is
  untested. The procedures here use `acpi`.
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
- **Kernel-bump reboots are AUTOMATED** (node-maintenance phase2 PLAY 1b, `19d51c19`): if the running kernel is stale after weekly patching, the play runs a graceful in-guest `poweroff` (same as `virsh shutdown --mode acpi`), the `immich-vm-heal` watchdog `virsh start`s the shut-off domain, and the play waits for node Ready. The manual cold restart above stays the break-glass path for a wedged-but-running VM and for clobber recovery. Test on demand: `sudo ansible-playbook -i inventory.yml phase2.yml --limit immich-vm -e vm_cold_cycle_force=true`.

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
