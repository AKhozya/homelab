# immich-vm reboot resilience — design

Date: 2026-07-11. Status: **DRAFT for operator review.** Central fix (the wedge) is **spike-proven** on the live VM; the rest is designed, not yet applied.

Scope: make the `immich-vm` GPU-passthrough substrate survive its own runtime + a NAS reboot without manual babysitting. Four tracks, one root theme (the VM is fragile around GPU/display + the appliance host). Tracks are ordered by severity — **Track 0 (the wedge) sits under the other three.**

Related: [`2026-07-10-immich-gpu-node-substrate-heal.md`](../../plans/2026-07-10-immich-gpu-node-substrate-heal.md) (the substrate/heal design this extends), `apps/immich/gpu-node/`, `docs/scripts/node-maintenance/ansible/roles/immich_gpu_node/`.

---

## 0. What changed tonight (2026-07-11)

The operator hit a NAS reboot → wedge chain. Investigation root-caused the recurring wedge and **proved a fix live**:

- The VM wedges (~hourly): frozen VNC, hung SSH logins, hung shutdown, "RAM 12/12GB". Long assumed cosmetic/benign — it is a **real hard deadlock**.
- Root cause (evidence below): **`virtio_gpu` fbdev/fbcon damage-work blocks on a stalled host virtqueue, holding `drm_modeset_lock` → every DRM/GPU open D-states → box wedges.**
- Fix, **spike-proven**: `drm_kms_helper.fbdev_emulation=0 fbcon=off` on the guest UKI cmdline. After a boot with it: `/proc/fb` empty, zero D-state, `vainfo` returns rc=0 with H264/HEVC hardware-encode, GPU transcode intact. The exact op that used to D-lock forever now returns clean.
- The fix is **applied to the running VM** (cmdline + UKI rebuilt, verified embedded) and validated after a reboot. It is **not yet codified** in Git — that is this spec's Track 0.

---

## 1. Problem statement — four tracks

| # | Track | Symptom | Blast radius |
|---|---|---|---|
| **0** | **GPU/display wedge** | VM deadlocks ~hourly; all GPU consumers + logins + shutdown hang | The VM (and cascades into Tracks 2/3) |
| 1 | SSH keys don't persist | akhozya key "clears every reboot" — re-add every time | Operator toil; blocks the Tier-2 watchdog |
| 2 | Cold-restart unreliable | `virsh shutdown --mode acpi` hangs forever; documented `--timeout 120` is a phantom flag | Can't cleanly restart the VM → only a NAS reboot recovers |
| 3 | No autostart after NAS reboot | VM stays `shut off`; the watchdog that should start it races a late host mount | VM down until manual `virsh start` |

---

## 2. Root causes (evidence-grounded)

### Track 0 — the wedge (`virtio_gpu` fbdev deadlock)

`ps` at wedge: `kworker/…:events` D + `vainfo` D on `drm_modeset_lock`. `dmesg` hung-task stack:
```
kworker events: drm_fb_helper_damage_work
  virtio_gpu_queue_ctrl_sgs [virtio_gpu]     ← blocks in schedule(), waiting on the host virtqueue
  virtio_gpu_primary_plane_update [virtio_gpu]
  drm_atomic_commit → drm_fbdev_shmem_helper_fb_dirty → drm_fb_helper_damage_work
```
fbcon renders the console to virtio-GPU fb0. The fbdev damage-work does an atomic plane update → `virtio_gpu_queue_ctrl_sgs` blocks forever waiting for the **host** virtio-GPU virtqueue to drain (host-side VNC/virtio-gpu backend stalls = the "frozen VNC"). The blocked kworker **holds `drm_modeset_lock`**; every subsequent DRM open (`vainfo`, Immich) → `drm_client_modeset_commit` → same lock → unkillable D-state → cascade → wedge.

**Ruled out with evidence:**
- Not i915 — `disable_display=Y` (render-only correctly in effect); i915 owns renderD129, transcode works.
- Not a dual-driver fight — `xe` is loaded but **binds nothing**; i915 exclusively claims the iGPU.
- Not RAM — 12/12GB is the `memfd`-shared memory backing (virtiofs requires); guest `free -h` = ~1.1Gi used.
- GSC-proxy-bind-timeout error is benign (PXP/HDCP), present before and after the fix.

**The heal watchdog was the periodic trigger.** `immich-gpu-heal.sh qsv_probe()` runs `vainfo --device renderD129` hourly (correct node) — pre-fix that D-locked on the held modeset lock, piling stuck tasks each cycle. A self-heal that self-harms.

### Track 1 — SSH keys

- **Guest half = onboarding gap, now solved.** `/home` is persistent **ext4 LVM** (`ArchinstallVg-home`), **no cloud-init** → keys added to the guest persist. Earlier "the VM keeps clearing my key" was two things: (a) the key was never durably added at build; (b) my client wasn't offering `zl_nas_ed25519` (only auto-loads for the `zl-nas` host alias, not the raw IP). Both are addressable.
- **NAS half = the real recurring nuisance, appliance-side.** `~akhozya/.ssh` is **`drwxrwx--x` (0771) — group-writable**, which `StrictModes yes` (sshd default) rejects. The key file is present + unchanged (0600, mtime stable across today's 3 reboots), but a perms-reset by the appliance flips pubkey auth off → "key cleared". Today an ACL (`+`) masks it and auth works; it is fragile, not fixed. The zettOS appliance owns `/home/akhozya` (a btrfs subvol on bcache) and is **out of our IaC**.

### Track 2 — cold-restart

- The hang is **the same Track 0 deadlock at `device_shutdown`** (shutdown touches the wedged GPU → stalls). Not a separate bug.
- **`virsh shutdown --timeout` does not exist** on the NAS libvirt (9.0.0): `shutdown` supports only `--mode acpi|agent|initctl|signal|paravirt`. The `--timeout 120` prescribed in README:55, the substrate-heal plan, and `immich-vm-heal.sh:130` is a **phantom flag** — it would error, never ran. (The operator's "`--timeout` escalates to destroy" rule was also wrong — there is no such flag to escalate.)
- The guest-agent channel (`org.qemu.guest_agent.0`) **is** in the domain XML, but `qemu-guest-agent` is **not installed** in the guest (`virsh domtime` → "not connected").

### Track 3 — autostart

- Native/UI autostart is **deliberately OFF** (appliance soft-restart re-wedges passthrough — C2/C4). The **Tier-2 CronJob** (`immich-vm-heal`, every 5min, `virsh start` on `shut off`) IS the autostart by design.
- It **races the host mount**: the virtiofs source `/home/akhozya/immich/library` is a **btrfs subvol on bcache mounted LATE** (an appliance lazy-mount: `/home/akhozya` is a 4k ro tmpfs stub until the subvol mounts over it, not in fstab). Before it mounts, `virsh start` fails `internal error: the virtiofs export directory … does not exist`. It also depends on the Track-1-NAS key surviving the reboot.

---

## 3. Cut corners + assumptions (surfaced, per request)

1. **Domain XML is in Git but the appliance regenerates it on any UI op** (C2/C5). The whole model assumes the operator never touches the zettOS UI for this VM; the watchdog re-defines from Git as the safety net.
2. **The NAS is out of IaC.** Every NAS-side fix (dir perms, an autostart unit) is manual/appliance-fragile and can be undone by a zettOS update. This is the hardest constraint — it pushes fixes to the guest (ansible) or in-cluster (GitOps) wherever possible.
3. **`--timeout 120` was baked into three files** as the "safe cold-restart" and never worked. Anyone following the runbook got an error, then improvised.
4. **The heal watchdog actively wedged the box** (vainfo D-lock) — a monitored, "self-healing" node whose healer was a fault accelerant. Assume any GPU-touching probe can D-state until Track 0 is codified.
5. **`on_crash preserve`** (alert-only) is deliberate — a guest crash stays `crashed`, recovered only by a NAS reboot. No auto-recovery for a true crash by design.
6. **`xe` loads and probes the iGPU at boot** (binds nothing). Unhandled second driver; low risk but an unowned variable.
7. **RAM 12/12GB reads as a leak, is normal** (memfd-shared). Documented so it is not misdiagnosed again (it cost real time this session).
8. **Destroy = NAS host crash is now confirmed, not theoretical** — the spike showed i915 bound to the VF; `virsh destroy` releases it dirty → FLR into the live host PF (C3). NEVER destroy. (A well-known internet source claimed "destroy is safe here" — refuted by ground truth.)
9. **The Track-0 fix is proven for the runtime wedge, NOT yet for the shutdown path.** Graceful `virsh shutdown --mode acpi` completing cleanly is *expected* (no more GPU deadlock at device_shutdown) but **untested** — it needs a cold-cycle to verify.
10. **Immich still runs on W1** (Path-B pod cutover not done), so the VM is low-impact today — which is the only reason leaving it wedged overnight was tolerable. Once Immich moves onto it, every one of these tracks becomes production-critical.
11. **`<on_reboot>restart</on_reboot>`** in the canonical XML means an accidental in-guest reboot is a *soft-restart wedge* path (reset-bug C4), even though the design's headline rule is "never in-guest reboot." The rule was asserted but the lifecycle action that would fire on a slip was never hardened (Track 0 item added).
12. **Console mismatch, pre-existing:** guest `console=hvc0` (virtio console) vs the domain's isa-serial ttyS0 — so `virsh console` as a break-glass is likely non-functional and was assumed working. Harmless while VNC exists; a blocker for Option B.

---

## 4. Design — approaches per track

### Track 0 — codify the fbdev-disable fix

| Option | What | Verdict |
|---|---|---|
| **A (recommend, PROVEN)** | Add `drm_kms_helper.fbdev_emulation=0 fbcon=off` to the guest UKI cmdline via the `immich_gpu_node` role's existing i915-cmdline task (same `/etc/kernel/cmdline` + UKI-rebuild mechanism as `modprobe.blacklist=i915`). Keeps the virtio-gpu/VNC device (break-glass) but removes the kernel fbdev consumer that deadlocks. | Ship. Low risk, ansible-managed, reversible, spike-proven. |
| B (future hardening) | Drop `<video type='virtio'>` + `<graphics vnc>` from the canonical domain XML → truly headless, no virtio_gpu at all. | Defer. Removes the stalling device entirely, but: domain-XML change (canonical + watchdog re-define), appliance may re-add on UI ops, and OVMF-headless-boot needs validation. **Prerequisite (per Codex review): the serial console must actually work first** — the guest cmdline is `console=hvc0` (a *virtio* console) but the domain only exposes an **isa-serial** ttyS0 + a serial `<console>` (`immich-vm-domain.xml:62-69`), no virtio-console device. So `virsh console` may be non-functional today; dropping VNC without fixing this leaves **no working console**. Fix = add a virtio-console device matching `hvc0` (or switch the cmdline to `ttyS0`) and verify `virsh console` before removing the graphics. Revisit only if the host virtqueue stall resurfaces via another virtio_gpu path. |

Companions to A:
- **Blacklist `xe`** (`modprobe.blacklist=i915,xe`) — remove the second driver probing the iGPU at boot. Hygiene; binds nothing today, so low urgency but cheap.
- **Harden the heal QSV probe** — the fix makes `vainfo` safe again, but a `timeout` can't kill a D-state, so a future regression could re-hang the healer. Change the per-cycle GPU health check to **sysfs** (renderD129 present + engine status) and keep `vainfo` to the bounded hourly probe wrapped so a stuck probe is detected and surfaced, not silently accumulated.
- **Codify the cmdline correctly (per Codex review):** the current role task only appends `modprobe.blacklist=i915` (grep-guarded, i915-specific — `immich_gpu_node/tasks/main.yml:22-38`), and base_config drift-checks only `expected_kernel_params: [console=hvc0, modprobe.blacklist=i915]` (`host_vars/immich-vm.yml:27-30`). Track 0 must: (a) generalize that task to **token-set handling** — idempotent add of `drm_kms_helper.fbdev_emulation=0`, `fbcon=off`, and `xe` on the blacklist, no double-append; (b) **add those tokens to `expected_kernel_params`** so base_config's cmdline drift-check covers them; (c) assert role-idempotence (run twice → zero changes).
- **Decide `on_reboot` (per Codex review — a reset-bug gap the design missed):** the canonical domain XML has `<on_reboot>restart</on_reboot>` (`immich-vm-domain.xml:33`). An accidental in-guest reboot → libvirt **soft-restart** → iGPU not reset → wedge (the C4 class this design bans). `on_reboot=destroy` is worse (dirty-iGPU teardown → C3 host crash). Candidate: `on_reboot=preserve` (domain goes down → the Tier-2 watchdog cold-starts it = clean iGPU reset) — **spike libvirt's `on_reboot` semantics + the reset-bug interaction before adopting**, then add `on_reboot` to the watchdog's domain drift markers + tests. (In-guest reboot vectors are already neutralized — kernel.panic=0, HW watchdog off — so this is a residual belt for a reboot that slips through, not the primary guard.)

### Track 1 — keys

- **Guest (in scope, ansible):** have the `immich_gpu_node` role (or base_config extended to `admin_user`) **manage `~akhozya/.ssh/authorized_keys`** on the guest — seed the operator + automation pubkeys, and assert `~/.ssh` 0700 / file 0600. A fresh guest build then gets keys without manual steps; drift-heal keeps them. (base_config already does exactly this for the `node-maintenance` user on workers; extend the pattern to `admin_user`.)
- **NAS (out of IaC):** the recurring `0771 ~/.ssh` → StrictModes rejection. Options: (A) accept + document — the Tier-2 watchdog already fails-closed + alerts `ssh_unreachable`, operator re-fixes perms; (B) a NAS-side boot oneshot that `chmod 700 ~akhozya/.ssh` — but it is an appliance unit (a zettOS update can drop it) and needs NAS root to install. Recommend **A now** (document the one-line fix: `chmod 700 ~/.ssh` on the NAS), and investigate whether the 0771 is set on every boot or was a one-off (today's reboots did **not** change it → likely intermittent, so the toil may be rarer than feared). Do not over-build a fragile NAS unit for an intermittent event.

### Track 2 — cold-restart reliability

- **Fix the docs first — full sweep (per Codex review, broader than I first scoped):** the phantom `--timeout 120` is in **more than three files**, including a **live operator-paging Telegram alert**. Remove/correct it everywhere operator-facing:
  - `apps/immich/gpu-node/README.md:55`, the substrate-heal plan, `immich-vm-heal.sh:130` operator hint;
  - `docs/scripts/node-maintenance/ansible/phase2.yml:132`, `:333`, and **`:392`** (the last is the Telegram alert text that pages the operator the broken command);
  - the reset-bug `.conf` comments that document a **host-crashing** recovery: `99-zz-immich-vm-nopanic.conf:6` and `zz-immich-vm-nowatchdog.conf:10` say "NAS-side **virsh reset**" — `virsh reset` is itself a reset-bug trigger. Rewrite to "**NAS host reboot**" (the only safe recovery for a true wedge).
- **Correct procedure everywhere:** `virsh shutdown --mode acpi <dom>` (no `--timeout`) → poll `domstate` for `shut off` → `virsh start`. If it does not reach `shut off` within N minutes → **alert, never destroy/reset** (a true wedge = NAS host reboot).
- **Install `qemu-guest-agent`** in the guest (role) → `virsh shutdown --mode agent` becomes the reliable primary (agent `guest-shutdown` initiates cleanly even when ACPI is ignored), and `virsh domtime`/`domfsinfo` give the Tier-2 watchdog a guest-health signal without SSH. (Research caveat: agent mode won't cure a *late-phase* hang — but Track 0 removed the hang, so with the fix agent-shutdown is a clean primary.)
- **Verify** graceful shutdown actually completes on the next cold-cycle (the one thing Track 0 hasn't proven). Until verified, NAS reboot stays the documented break-glass.

### Track 3 — autostart

- **Recommend: gate the Tier-2 CronJob `virsh start` on the mount.** In `immich-vm-heal.sh`, before `virsh start`, check the virtiofs **source** is mounted on the NAS (`ssh_nas "test -d /home/akhozya/immich/library && findmnt -T /home/akhozya/immich/library"` — or a `mountpoint`-style check on `/home/akhozya`'s btrfs subvol). If not ready → log + skip this cycle (the next 5-min tick retries). GitOps-native, no fragile NAS-side unit, and it naturally waits out the lazy-mount.
- Reject the research's `RequiresMountsFor=` NAS systemd unit — it is appliance/out-of-IaC and re-opens the soft-restart-wedge risk.
- Note the **cross-dependency**: autostart only works if the Track-1-NAS key survives the reboot (else the CronJob can't SSH). Track 1 and Track 3 share the appliance-perms root.

---

## 5. GitOps placement

| Change | Where | Managed by |
|---|---|---|
| fbdev-disable + xe blacklist on cmdline | `immich_gpu_node` role i915-cmdline task | ansible drift-heal (guest) |
| Guest `authorized_keys` management | `immich_gpu_node` / base_config | ansible drift-heal (guest) |
| Heal QSV-probe hardening | `immich_gpu_node/files/immich-gpu-heal.sh` | ansible drift-heal (guest) |
| `qemu-guest-agent` install | `immich_gpu_node` packages | ansible drift-heal (guest) |
| CronJob mount-gate | `apps/immich/gpu-node/immich-vm-heal.sh` | Flux (in-cluster) |
| `expected_kernel_params` += new tokens | `host_vars/immich-vm.yml` | ansible drift-heal (guest) |
| Remove `--timeout 120` + fix "virsh reset" wording | README, plan, heal.sh, **phase2.yml (incl. alert), the two `.conf` comments** | docs/GitOps |
| `on_reboot` decision (spike then set) | `apps/immich/gpu-node/immich-vm-domain.xml` + watchdog markers | Flux + watchdog re-define |
| NAS `~/.ssh` perms | — | **operator (appliance, out of IaC)** |
| Drop `<video>`/`<graphics>` + fix console (Option B) | `apps/immich/gpu-node/immich-vm-domain.xml` | Flux + watchdog re-define (deferred) |

Guest changes are ansible-managed because the `immich_gpu_node` role runs on the VM (it's a `workers`/`virtual` node). Only NAS-host changes are out of scope.

---

## 6. Testing / what's proven vs pending

| Item | State |
|---|---|
| Track 0 fbdev fix resolves the runtime wedge | **PROVEN** (spike, 2026-07-11): no fbdev, zero D-state, vainfo rc=0 + HW encode |
| GPU transcode intact after the fix | **PROVEN** (renderD129=i915, iHD 26.1.5, H264/HEVC EncSlice) |
| Fix survives reboot (cmdline in UKI) | **PROVEN** (embedded `.cmdline` verified; booted with it) |
| Role idempotence (cmdline task twice → no double-append) | pending |
| Graceful `virsh shutdown --mode acpi` now completes | **PROVEN** (2026-07-12 cold-cycle: `shut off` in 48s, clean restart, GPU intact; pre-fix hung forever) |
| Fix holds under load (no re-wedge) | **PROVEN** — 4h15m continuous uptime with GPU probes, zero D-state (pre-fix wedged in ~1h) |
| qemu-guest-agent → `--mode agent` shutdown | pending (agent not installed) |
| CronJob mount-gate waits out the race | pending (design) |
| Guest authorized_keys management | pending |
| `on_reboot` safe value (spike libvirt semantics) | pending |
| `virsh console` actually works (blocks Option B) | pending |

---

## 7. Operator actions (can't be automated)

1. **Re-enable the guest heal watchdog** — I disabled it for the controlled reboot test and `op`/sudo locked before I could restore it: `sudo systemctl enable --now immich-gpu-heal-watchdog.timer` on the VM. (Safe now — the fbdev fix makes its vainfo probe non-hanging.)
2. **NAS `~/.ssh` perms** if key auth ever breaks post-reboot: `chmod 700 ~/.ssh` on the NAS (StrictModes wants non-group-writable).
3. Review this spec; decide Option A vs A+B for Track 0, and A vs B for Track 1-NAS.

---

## 8. Residual risks (accepted / to-track)

- The Track-0 fix keeps the (stalling) virtio_gpu device; if the host virtqueue stalls via a non-fbdev path, it could resurface. Option B (drop the device) is the escape hatch. Low likelihood on a headless serial-console VM with no other virtio_gpu user.
- NAS-side perms/keys remain appliance-fragile (out of IaC). Bounded, alerting, operator-in-the-loop.
- Reset-bug stays: NEVER `virsh destroy`/`reset`/in-guest reboot; NAS host reboot is the only clean reset for a true wedge. Confirmed by the VF-driver-binding spike.
- Shutdown reliability is designed but unverified until a cold-cycle.

---

## Appendix — key commands (this VM)

```sh
# SSH the guest (key must be explicit — only auto-loads for the zl-nas alias):
ssh -i ~/.ssh/zl_nas_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none -p 65300 akhozya@192.168.1.231
# GPU health (targets the i915 node, NOT default renderD128=virtio):
LIBVA_DRIVER_NAME=iHD vainfo --display drm --device /dev/dri/renderD129
# Wedge signature:
ps -eo pid,stat,wchan,cmd | awk '$2 ~ /^D/'          # D-state on drm_modeset_lock = wedged
# Verify the UKI cmdline:
sudo objcopy -O binary --only-section=.cmdline /boot/EFI/Linux/arch-linux-lts.efi /dev/stdout | tr -d '\0'
# NAS-side (akhozya, libvirt group, no sudo): domain = the UUID-named domain
virsh -c qemu:///system domstate 0398541a-c088-48cd-b16a-4b45d31a92f3
```
