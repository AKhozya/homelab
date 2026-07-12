# immich Path B cutover (step 4E) — design

Date: 2026-07-12. Status: **DRAFT for operator review.** Substrate (immich-vm GPU k3s node) is built + resilience-hardened; this spec moves the Immich **server + library** onto it.

Scope: cut the `immich-server` pod over to the `immich-vm` GPU node for Intel QSV transcode, with the library on the NAS (virtiofs). **DB (CNPG), Redis, Cloudflare tunnel, Authentik OIDC, the k8s Service/Ingress all stay in-cluster and unchanged** — this is placement + storage + GPU, NOT a data-platform migration. URL/OIDC/DB are transparent to the user.

Related: `apps/immich/release.yaml` (HelmRelease), `apps/immich/library-pvc.yaml`, `apps/immich/gpu-node/` (substrate + watchdog), `docs/plans/2026-07-10-immich-gpu-node-step4-fleet-onboard.md` (4A–4D), `docs/superpowers/specs/2026-07-11-immich-vm-reboot-resilience-design.md` (substrate hardening), `infrastructure/configs/backup/immich-backup-cronjob.yaml` + `infrastructure/configs/backup-replication/`.

Why Path B (not Path A / NAS-native docker): keeps Flux/GitOps, CNPG HA, monitoring, image-pinning. Path A is the documented fallback (`project_immich_gpu_transcode`).

---

## 0. Decisions locked (brainstorming 2026-07-12)

| # | Decision | Rationale |
|---|---|---|
| D1 | **Phased**: Phase 1 = server + library + GPU; Phase 2 = ML→openvino + VM resource bump | ML doesn't mount the library (talks to server over HTTP) → safe to leave on W1 in P1; smallest blast radius; transcode is the win. Operator will grow VM vCPU/RAM for P2. |
| D2 | **GPU via Intel device-plugin** (`gpu.intel.com/i915: 1`), **non-privileged** | Uses the 4D DaemonSet (advertises 10); drops `privileged`+hostPath `/dev/dri` → cleaner POD securityContext (non-privileged, drop-ALL). NB: the **namespace stays PSS `privileged`** regardless — the library still uses a hostPath (§2.1); immich is already Kyverno-excluded from `disallow-host-path` (rationale updates from `/dev/dri` to the library mount). Spike-gated with a hostPath+privileged fallback. |
| D3 | **Library on NAS via virtiofs**, hostPath `/var/lib/immich-library` → container `/data` | The 15T NAS pool is the target; the virtiofs mount is already live on the VM. |
| D4 | **Data move via backup-restore** (not rsync) | Reuse the existing library-backup tar + sha256 tooling; clean full restore, no partial-state ambiguity. |
| D5 | **Maintenance-window cutover** (accept minutes of downtime) | RWO library → old+new pod can't co-run; zero-downtime dual-path risks split-brain on a single DB. YAGNI for a homelab photo app. |
| D6 | **Backups post-cutover**: library backup on **NAS** + **replicate to W1/W2**; validated **before** W1 decommission | NAS is now BOTH primary library AND backup sink → a non-circular second physical copy is required. |

---

## 1. Ground truth (verified 2026-07-12)

- Library container mount = **`/data`** (Immich `UPLOAD_LOCATION`); volume = PVC `immich-library` (300Gi `local-path` RWO, PV `pvc-495129ee-…`), **hard-pinned to W1** (local-path binds to first-scheduled node). Server pod currently on `worker-node` (W1).
- Current GPU: postRenderer patches `immich-server` → `privileged: true` + hostPath `/dev/dri`; `LIBVA_DRIVER_NAME: radeonsi`; supplementalGroups **985 (video) / 989 (render)** = W1 GIDs.
- immich-vm: render GID **987**, video GID **983**; `/dev/dri/renderD129` (i915) present; node advertises **`gpu.intel.com/i915: 10`**; `/var/lib/immich-library` = virtiofs mount (15T pool) holding the **stale July-5 pre-seed** (must be refreshed).
- immich ns is PSS `privileged` but Kyverno `require-non-root` is **Enforce and does NOT exclude immich** → the pod must run non-root (already `runAsUser: 1000`); excluded from RoRFS + priv-esc only.
- DB via `main-postgres-rw-pooler` (CNPG PgBouncer); Redis via OT `redis-replication-master` Service. **Both unchanged.**
- ML = CPU-only (`v3.0.2`), no library mount, no GPU.

---

## 2. Phase 1 — server + library + GPU cutover

### 2.1 Manifest changes (`apps/immich/release.yaml`)

Server component:
- **Library volume**: `immich.persistence.library.existingClaim: immich-library` → a **hostPath** volume `/var/lib/immich-library` mounted at `/data` (bjw-s `persistence` `type: hostPath`, or a postRenderer volume swap). Keep the container path `/data` **identical** (DB asset paths are relative to it).
- **Placement**: add `nodeSelector: { homelab/gpu: intel }` to the server pod (immich-vm only).
- **GPU (device-plugin path)**: drop the `privileged: true` securityContext replace + the hostPath `/dev/dri` volume/mount from the postRenderer; add `resources.limits."gpu.intel.com/i915": 1` (and matching request) to the main container; keep the container non-root, drop-ALL.
- **GIDs**: `supplementalGroups: [983, 987]` (was 985/989).
- **Driver**: `LIBVA_DRIVER_NAME: iHD` (was radeonsi).
- **Transcode accel**: set to **QSV** in the Immich admin UI ffmpeg settings **post-cutover** (runtime/DB setting, not the manifest).

Unchanged: DB/Redis env, initContainer wait-for-database, probes, priorityClass, Recreate strategy, serviceAccount patches, ML component (Phase 2).

### 2.2 GPU spike gate (first, de-risks D2)

Before touching the HelmRelease: throwaway pod on immich-vm — `nodeSelector homelab/gpu=intel`, `resources: gpu.intel.com/i915: 1`, **non-privileged** (runAsUser 1000, drop-ALL), `supplementalGroups: [987]`, image = `ghcr.io/immich-app/immich-server:v3.0.2` — run `LIBVA_DRIVER_NAME=iHD vainfo --device /dev/dri/renderD129` + a 5s ffmpeg `hevc_qsv` encode. Pod must be Kyverno-compliant (limits, non-root).
- **Pass** → device-plugin injects `/dev/dri` + render GID gives access non-privileged → proceed with D2.
- **Fail** → fall back to the current mechanism (hostPath `/dev/dri` + `privileged: true`), only swapping GIDs 983/987 + `iHD`. **No spec rework** — this fallback is pre-authorized here.

### 2.3 Data move (backup-restore)

Library lives at `/data` on W1 (PVC). Target = NAS `/home/akhozya/immich/library` (= the virtiofs source → guest `/var/lib/immich-library`).
1. Trigger a **fresh** Immich library backup via the existing `immich-backup-cronjob` (produces `immich-library.tar` + `.sha256`), replicated to the NAS by `backup-replication`.
2. On the NAS: verify sha256, then **extract into a CLEAN empty staging dir and atomically swap** it in for the library source — do NOT extract over the stale July-5 pre-seed. Tar extract only adds/overwrites; overwriting the pre-seed would leave DB-orphaned media (files deleted from Immich since July-5) lingering on disk and in every future backup. Clean-extract-then-swap = a byte-exact restore. Discard the pre-seed.
3. **Ownership (write-capability — grounded 2026-07-12):** virtiofs is `accessmode='passthrough'` → the pod's uid 1000 / gid 1000 map 1:1 to the NAS, where **uid 1000 = `akhozya`** and gid 1000 = `zettos-admins`. Immich (non-root, uid 1000) writes new files into the `/data` subtrees (`upload/ thumbs/ library/ encoded-video/ profile/`), NOT the `/data` root. The restore MUST leave those subtrees writable by uid 1000 / gid 1000 (e.g. `chown -R 1000:1000` on the staged tree, or confirm the tar preserved uid-1000 ownership + group-writable+setgid dirs — the working pre-seed pattern is `drwxrwsr-x` owner-root group-1000-setgid). **Verify with the write-test gate (§2.4 step 5b) — do NOT assume.**
4. Because a full library backup is point-in-time, run steps 1-3 **inside the window** (server suspended = writes fenced) so no upload is missed. Immich backups are full-tar, not incremental → accept one full backup during the window.

### 2.4 Cutover sequence (maintenance window)

**Write-fence principle (per Codex review):** the moment the server resumes on the NAS library and accepts an **upload**, the NAS diverges from the W1 copy → a rollback to W1 would lose those new assets (files on NAS only; DB rows shared). So keep **uploads DISABLED** from fence until acceptance; enabling uploads is the TRUE point of no return, not PV-delete. (Mirrors the Path-A "uploads-disabled-until-acceptance" rule.)

1. **Spike gate** (§2.2) — resolve D2 (device-plugin vs fallback).
2. **Fence**: `flux suspend helmrelease immich`; scale `immich-server` to 0 (**downtime start**, writes fenced). Trigger fresh library backup → NAS; verify sha256.
3. **Restore**: clean-extract + swap on NAS (§2.3); set/verify uid-1000/gid-1000 writable subtrees; confirm structure (`library/ upload/ thumbs/ encoded-video/ profile/`) + spot-check a recent asset.
4. **Repoint**: apply the §2.1 HelmRelease changes (library hostPath + nodeSelector + GPU resource + GIDs + iHD); **set Immich to a read-only / uploads-disabled posture** (server env or admin lock) before exposing it; `flux resume`.
5. **Verify — reads/transcode** (all must pass): pod `Running` on `immich-vm`; `/data` populated (on-disk asset count); web UI loads thumbnails; open a photo (original serves); **QSV transcode a test video** (ffmpeg uses `hevc_qsv`/renderD129, GPU busy); DB asset count == pre-cutover count.
   - **5b. Verify — WRITE** (the finding-3 gate): with uploads still fenced from the public path, prove the non-root pod can create files on the NAS virtiofs library — e.g. exec `touch /data/upload/.write-test` (lands on NAS as uid 1000) + trigger a thumbnail/one controlled upload and confirm the new file appears under `/home/akhozya/immich/library/...` on the NAS. If writes fail → fix ownership (§2.3 step 3) before proceeding. **Downtime (read-availability) ends** after step 5; the service is up read-only.
6. **Enable uploads** (⚠️ **POINT OF NO RETURN** — after this, NAS has assets W1 doesn't): lift the uploads lock. Set admin ffmpeg accel = QSV; re-run a transcode on a sample; confirm no `radeonsi`/CPU fallback.
7. **Soak** (≥48h): transcode jobs succeed, virtiofs I/O latency, pod restarts, memory, watchdog green.
8. **Backup gate** (§3) GREEN → **decommission** the W1 PVC/PV + old library-backup source path. (This only reclaims the now-stale W1 copy; the real no-return was step 6.)

---

## 3. Backup topology (post-cutover)

Problem: after cutover the library is on the NAS, which was ALSO the backup sink → a naive backup would be circular (same physical box). Required end state (D6):
- **Immich backup source = the NAS-resident library** (the `immich-backup-cronjob` currently reads the W1 host path `/mnt/k8s-storage/…` — that path is gone post-cutover; re-point it to back up the NAS library, or run the backup on the NAS side).
- **Primary backup copy on NAS**, **replicated to W1 or W2** (a second physical node) via the existing `backup-replication` tooling (reverse or extend its direction so the Immich library backup lands on a node, not only the NAS).
- **Validation gate** (blocks W1 decommission): produce one full backup on NAS → confirm it replicates to W1/W2 → **restore-verify** it (extract + sha256 + asset spot-check) on the second node. Only then delete the old W1 PV.

Design detail (to finalize in the plan): whether the backup Job runs in-cluster (mounts the NAS library via the VM/hostPath) or NAS-side; exact replication direction; retention. The **DB backup** (CNPG logical, existing) is unaffected — it already runs + replicates.

---

## 4. Phase 2 — ML → openvino + VM resource bump (follow-on)

After Phase 1 soaks:
- ML image `ghcr.io/immich-app/immich-machine-learning:v3.0.2` → **`v3.0.2-openvino`**; add `gpu.intel.com/i915: 1` + `nodeSelector homelab/gpu=intel` + supplementalGroups [983,987]; re-home the ML cache PVC (local-path → VM node or emptyDir-with-warmup).
- **VM resource bump**: edit `<vcpu>` / `<memory>` in `apps/immich/gpu-node/immich-vm-domain.xml` (canonical, Flux-managed CM) → NAS-side **cold-cycle** (watchdog re-defines from Git; memory is memfd-backed so guest RAM ↑ = host memfd ↑ — NAS has 30Gi total, keep headroom). Never a zettOS-UI edit (regenerates the domain = clobber).
- Reset-bug rules unchanged: cold-cycle only, never in-guest reboot / destroy / reset.

---

## 5. Cut corners / assumptions (surfaced)

1. **RWO → maintenance window**, not zero-downtime (accepted, D5).
2. **virtiofs library I/O perf under Immich load is unproven** — accept + monitor (soak gate §2.4/7). Escape hatch: move hot dirs (thumbs/) to VM-local disk if latency hurts.
3. **VM = single point for Immich now** — every substrate gotcha (fbdev wedge, cold-restart, NAS-key perms) becomes prod-critical. Mitigated by the 2026-07-11/12 resilience work; the Tier-2 watchdog is the durable autostart.
4. **Device-plugin non-priv QSV** is a standard Intel k8s pattern but unproven on this exact stack → §2.2 spike gate + fallback.
5. **Backup circularity** (NAS primary + sink) is the hardest new constraint → §3 topology + validation gate before decommission.
6. **DB stays CNPG** — no PG18→17 / pgvector / embedding-regen work (that is Path-A-only). DB paths stay valid because `/data` is preserved.
7. **The stale July-5 pre-seed** on the NAS is DISCARDED (clean-extract + swap, §2.3) — do NOT extract over it (leaves DB-orphaned deleted files).
8. **ML left on W1 in P1** — if a future Immich version makes ML mount the library, revisit (today it's HTTP-only).
9. **virtiofs uid-passthrough is load-bearing** (grounded): pod uid 1000 = NAS `akhozya`, gid 1000 = `zettos-admins`; the `/data` root is root:root (pod can only traverse) while the subtrees are group-1000-setgid-writable. A restore that gets subtree ownership wrong = silent upload/thumbnail failures → the §2.4-5b write gate is mandatory, not optional. A zettOS update could reset `/home/akhozya` perms (appliance, out of IaC) → same class as the NAS-key StrictModes gotcha.

---

## 6. Risks / rollback

- **Clean rollback window = while uploads are fenced (through §2.4 step 5b, BEFORE step 6).** The W1 PVC is untouched and no user asset has landed on the NAS, so: `flux suspend`, revert the HelmRelease patch, `flux resume` → server returns to W1 on the intact old library. Cheap and complete, zero data loss.
- **True point of no return = enabling uploads (§2.4 step 6)** — NOT PV-delete (Codex HIGH). Once uploads flow to the NAS library, new files exist on NAS only (DB rows are shared), so a revert to W1 would lose them. After step 6, "rollback" means fence again + reverse-sync the NAS→W1 delta (not cheap) — or forward-fix on NAS. Keep the W1 PV intact through soak + the backup gate purely as a disaster fallback, understanding it is already stale for post-cutover uploads.
- **Reset-bug**: NEVER virsh destroy/reset/in-guest reboot; cold-cycle = NAS host reboot / graceful `virsh shutdown --mode acpi` → poll domstate → `start`.
- **CI = gate of record.** Per `AGENTS.md`, CI green is required to merge a cutover change; local validation is fast iteration, not a bypass. CI is currently **infra-blocked (GitHub billing)** — that block must be **resolved before the cutover merges** (it is an outstanding operator action). Do not proceed a prod cutover on a red/absent CI gate.

---

## 7. Verification gates (what proves each step)

| Gate | Proof |
|---|---|
| GPU spike | vainfo rc=0 + `hevc_qsv` encode, non-privileged, on immich-vm |
| Restore integrity | sha256 match + on-disk asset count + recent-asset spot-check |
| Cutover (reads) | pod Running on immich-vm; thumbnails + originals serve; DB asset count == pre-cutover; QSV (not CPU/radeonsi) in a live transcode |
| **WRITE (blocks upload-enable)** | non-root pod (uid 1000) creates a file under `/data/upload` that appears on the NAS at `/home/akhozya/immich/library/...`; a thumbnail generates. Fails → fix ownership, do NOT enable uploads. |
| Backup gate (blocks W1 decommission) | full backup on NAS → replicated to W1/W2 → restore-verified on the second node |
| Soak (≥48h) | no pod restarts from I/O; transcode jobs succeed; memory stable; watchdog green |

## 8. GitOps placement

| Change | File | Managed by |
|---|---|---|
| Server library hostPath + nodeSelector + device-plugin GPU + GIDs + iHD | `apps/immich/release.yaml` | Flux |
| Remove obsolete library PVC | `apps/immich/library-pvc.yaml` (+ kustomization) | Flux (after decommission) |
| Backup source re-point + replicate-to-node | `infrastructure/configs/backup/immich-backup-cronjob.yaml`, `infrastructure/configs/backup-replication/` | Flux |
| ML openvino + GPU (P2) | `apps/immich/release.yaml` | Flux |
| VM vCPU/RAM bump (P2) | `apps/immich/gpu-node/immich-vm-domain.xml` | Flux CM + watchdog re-define + cold-cycle |
| Admin ffmpeg accel = QSV | Immich admin UI (runtime) | operator (post-cutover) |

Pre-commit: Codex STATIC review + `.claude/review-invariants.md`; `/homelab-yaml-validate`; **CI green (gate of record — resolve the GitHub billing block before the cutover merges, don't bypass it for a prod change).** Cutover steps that touch the live cluster (suspend/scale/backup/restore/decommission) are **operator-run in a window**, not agent-autonomous.
