# immich Path B cutover (step 4E) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the `immich-server` pod + its photo library onto the `immich-vm` GPU k3s node for Intel QSV transcode, with the library on the NAS via virtiofs. DB (CNPG), Redis, Cloudflare tunnel, Authentik OIDC, Service/Ingress stay in-cluster and unchanged.

**Architecture:** Repoint the existing Flux `HelmRelease immich` (chart 0.13.1) — swap the library volume from a W1-pinned `local-path` PVC to a hostPath on the virtiofs-mounted NAS pool, pin the server pod to `immich-vm` (`nodeSelector homelab/gpu=intel`), and switch GPU access from privileged+hostPath `/dev/dri` to the Intel device-plugin (`gpu.intel.com/i915: 1`, non-privileged) — spike-gated with a privileged+hostPath fallback. Data moves by a fresh backup-restore into a clean staging dir, atomically swapped. Cutover runs in a maintenance window with uploads fenced until acceptance; enabling uploads is the true point of no return.

**Tech Stack:** Flux GitOps, immich-charts 0.13.1 (bjw-s common-library), Kustomize postRenderer, Intel GPU device-plugin DaemonSet, virtiofs (accessmode=passthrough), libvirt/QEMU (immich-vm), rsync backup-replication, CNPG (unchanged).

**Source spec:** `docs/superpowers/specs/2026-07-12-immich-vm-path-b-cutover-design.md` (main @ `ba250045`, Codex-reviewed 2 rounds). The spec is authoritative for *decisions* (D1–D6) and *rationale*; this plan is the executable step list.

## Global Constraints

- **GitOps only.** Commit → Flux reconcile. No `kubectl apply/edit/patch/replace` on live objects. The only live mutations are the operator-run cutover window steps (fence/backup/restore/decommission), which use `flux suspend`/`scale`/SSH — never freehand kubectl edits.
- **Edit in the worktree** `.claude/worktrees/immich-4e-plan` (main tree is edit-blocked). Commit there → merge `wt-immich-4e-plan` → main → push → `fr`.
- **Merge = cutover trigger.** The HelmRelease repoint (Task 3) and backup re-topology (Task 4) are committed in the worktree but **NOT merged to main** until the operator runs the cutover window (Task 5). Merging to main deploys straight to prod.
- **Pin all images** `major.minor.patch[-variant]`. No floating tags.
- **Reset-bug — NEVER** `virsh destroy` / `virsh reset` / in-guest reboot on immich-vm (dirty iGPU re-binds host i915 → NAS host crash). Cold-cycle = NAS host reboot **or** graceful `virsh shutdown --mode acpi` → poll `domstate` → `virsh start`. No cutover step requires a cold-cycle; Phase 2 (VM resource bump) does.
- **Pre-commit review gate** (per AGENTS.md): before committing a non-trivial diff → Codex STATIC git-only review (allowed `git diff/show/log` + reads; FORBIDDEN run-anything; point at `.claude/review-invariants.md`; one-message verdict) → `superpowers:receiving-code-review` (verify each finding vs code, push back on wrong/YAGNI, fix in severity order) → delta re-review while CRITICAL/HIGH, cap 3 rounds → `/homelab-yaml-validate` → CI green.
- **CI green = gate of record.** CI is currently **infra-blocked (GitHub billing)**. Task 0 resolves it; **no cutover change merges to main on a red/absent CI gate.**
- **Uploads-fenced principle:** from fence (Task 5 step 2) until acceptance (step 6), user uploads are blocked. Enabling uploads is the TRUE point of no return — after it, new assets exist only on the NAS. Clean rollback exists only through step 5b.

---

## Task 0: Unblock CI (operator prerequisite)

**Blocks:** every merge to main in this plan. Not a code task — an operator/billing action.

**Files:** none (GitHub org billing / `.github/workflows/validate.yaml` runs once billing restored).

- [ ] **Step 1: Confirm CI is red/absent**

Run: `gh run list --repo <origin> --workflow validate.yaml --limit 3`
Expected: no recent runs, or runs failing at setup with a billing/spending-limit error.

- [ ] **Step 2: Operator resolves GitHub billing** (out of band — update payment method / raise spending limit for the org that owns the repo).

- [ ] **Step 3: Verify CI runs green via `workflow_dispatch`**

`validate.yaml` has `paths-ignore: ['**.md', 'docs/images/**']` on push+PR — a docs-only commit will NOT trigger a run, so proving the gate that way is impossible. Trigger it directly (the workflow declares `workflow_dispatch`):
Run: `gh workflow run validate.yaml --ref main && sleep 5 && gh run list --workflow validate.yaml --limit 1`
Expected: latest run `completed / success` (~45s). This proves the gate is live before any cutover merge. (The real cutover commits touch `apps/**`/`infrastructure/**` YAML, which DO trigger push/PR runs.)

**Deliverable:** CI green on a real push. Until this passes, Tasks 3/4/7 commits stay in the worktree and are NOT merged.

---

## Task 1: GPU spike gate (de-risks D2 — device-plugin vs fallback) — ✅ EXECUTED 2026-07-12

**RESULT: `GPU_PATH = device-plugin`.** A non-privileged pod on `immich-vm` (device-plugin `gpu.intel.com/i915: 1`, `supplementalGroups: [987]`, drop-ALL) was Kyverno-admitted, `/dev/dri/renderD129` was injected (`crw-rw-rw-`), `id` showed `groups=1000,987`, and `ffmpeg -c:v hevc_qsv` encoded 60 frames at **25.3x realtime, rc=0**. The privileged+hostPath fallback is NOT needed. Spike pod torn down. Task 3 Step 5 uses the device-plugin path. The steps below are the recorded procedure.

**Goal:** Prove a **non-privileged** pod on `immich-vm`, using the Intel device-plugin (`gpu.intel.com/i915: 1`) + render GID `987`, can run VAAPI/QSV against `/dev/dri/renderD129`. Decides whether Task 3 uses the device-plugin path (preferred) or the privileged+hostPath fallback. **This is a throwaway diagnostic pod — an explicit, spec-§2.2-authorized exception to the GitOps-only invariant** (never reconciled by Flux, not repo-owned, deleted immediately after). It is NOT live GitOps state; do not `kubectl apply -f` it (the safety hook blocks that anyway) — use `kubectl create -f` for an imperative throwaway. Do NOT push it through commit→Flux→revert; that is 4 commits of churn for a 90-second probe (YAGNI).

**Files:**
- Create (scratch, NOT committed): `/private/tmp/.../immich-gpu-spike.yaml`

**Interfaces:**
- Produces: `GPU_PATH` ∈ {`device-plugin`, `fallback`} — consumed by Task 3 (server securityContext + GPU resource vs privileged+hostPath).

- [ ] **Step 1: Confirm the node advertises the GPU resource + label**

Run:
```bash
kubectl get node -l homelab/gpu=intel -o custom-columns=NAME:.metadata.name,I915:.status.allocatable.gpu\\.intel\\.com/i915
```
Expected: `immich-vm` row with `I915 = 10`. If the label key differs, note the real key (used verbatim in Task 3's `nodeSelector`). If `i915` is absent/`<none>`, the device-plugin DaemonSet (4D) is not healthy on this node → stop and fix that first (out of plan scope).

- [ ] **Step 2: Write the spike pod manifest** (Kyverno-compliant: non-root, limits, drop-ALL)

```yaml
# /private/tmp/.../immich-gpu-spike.yaml
apiVersion: v1
kind: Pod
metadata:
  name: immich-gpu-spike
  namespace: immich
spec:
  restartPolicy: Never
  nodeSelector:
    homelab/gpu: intel            # use the real key from Step 1
  priorityClassName: homelab-batch
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    supplementalGroups: [987]     # render GID on immich-vm
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: ghcr.io/immich-app/immich-server:v3.0.2
      command: ["sh","-c","sleep 900"]
      env:
        - name: LIBVA_DRIVER_NAME
          value: iHD
      resources:
        requests:
          cpu: 200m
          memory: 256Mi
          gpu.intel.com/i915: "1"
        limits:
          cpu: "1000m"
          memory: 512Mi
          gpu.intel.com/i915: "1"
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
```

- [ ] **Step 3: Create (imperative throwaway), wait Running**

Run: `kubectl create -f /private/tmp/.../immich-gpu-spike.yaml && kubectl -n immich wait --for=condition=Ready pod/immich-gpu-spike --timeout=300s`
(Use `create`, not `apply -f` — the latter is a GitOps-drift risk and is blocked by the safety hook. 300s tolerates the first image pull of `immich-server:v3.0.2` onto immich-vm.)
Expected: `pod/immich-gpu-spike condition met`. If it fails Kyverno admission → read the deny reason; if it's non-root/limits, the spike manifest is wrong (fix); if it's `disallow-host-path` it shouldn't fire (no hostPath here).

- [ ] **Step 4: Prove VAAPI enumerates + QSV encodes, non-privileged**

Run:
```bash
kubectl -n immich exec immich-gpu-spike -- sh -c '
  ls -l /dev/dri &&
  LIBVA_DRIVER_NAME=iHD vainfo --device /dev/dri/renderD129 2>&1 | grep -E "VAProfile|Driver version" | head &&
  ffmpeg -hide_banner -f lavfi -i testsrc=size=640x480:rate=30:duration=2 \
    -c:v hevc_qsv -f null - 2>&1 | tail -3'
```
Expected: `/dev/dri/renderD129` present; vainfo prints `iHD` driver + `VAProfileHEVCMain`/`VAEntrypointEncSlice`; ffmpeg exits 0 with frames encoded (no `Cannot load libva`/`Device creation failed`).

- [ ] **Step 5: Record verdict + tear down**

Run: `kubectl -n immich delete pod immich-gpu-spike --now`
- vainfo rc=0 **and** ffmpeg encoded → `GPU_PATH = device-plugin`.
- vainfo/ffmpeg failed on device access despite Step 1 showing i915 allocatable → `GPU_PATH = fallback` (privileged + hostPath `/dev/dri`, GIDs 983/987, iHD only). **No spec rework — fallback is pre-authorized (spec §2.2).**

**Deliverable:** `GPU_PATH` decided, spike pod deleted. No commit.

---

## Task 2: Library hostPath mechanism + pre-cutover ground-truth assertions — ✅ RENDER-CHECKED 2026-07-12

**RESULT: `LIB_MECH = postrenderer`.** `helm template` of immich-charts `immich` 0.13.1 proved the chart's JSON schema **rejects** `immich.persistence.library.type`/`hostPath` ("Automatically creating the library volume is not supported by this chart — specify an existing PVC"). The library persistence key accepts **only `existingClaim`**. The rendered `immich-server` Deployment carries exactly one volume: `name: data` at **index 0**, a `persistentVolumeClaim` (`claimName` from `existingClaim`), mounted at **`/data`** (confirms ground truth). So the hostPath swap MUST be a postRenderer JSON-patch that `replace`s `/spec/template/spec/volumes/0` (PVC→hostPath); the mount stays `/data`, and `immich.persistence.library.existingClaim` stays set (schema-required) but is overridden by the patch. Step 1 below (live mount confirm) + Step 3 (NAS virtiofs) remain execution-time checks.

**Goal:** Lock the exact way the library becomes a hostPath (chart-native vs postRenderer) by *rendering* the chart — no guessing — and re-confirm the mount path is `/data` on the running pod. Non-mutating.

**Files:**
- Read: `apps/immich/release.yaml`
- Scratch render output (not committed).

**Interfaces:**
- Produces: `LIB_MECH` ∈ {`chart-native`, `postrenderer`} + confirmed container mountPath — consumed by Task 3.

- [ ] **Step 1: Confirm the live pod mounts the library at `/data`**

Run:
```bash
kubectl -n immich get deploy immich-server -o jsonpath='{range .spec.template.spec.containers[0].volumeMounts[*]}{.name}{" -> "}{.mountPath}{"\n"}{end}'
kubectl -n immich get deploy immich-server -o jsonpath='{.spec.template.spec.containers[0].env}' | tr ',' '\n' | grep -i upload || echo "no UPLOAD_LOCATION env (chart default)"
```
Expected: a volumeMount whose `mountPath` is `/data` (the library). Record it as `LIB_MOUNT`. If it is NOT `/data`, STOP — the spec's ground truth is wrong; the hostPath must mount at whatever `LIB_MOUNT` actually is (DB asset paths are relative to it). Do not proceed on a mismatched path.

- [ ] **Step 2: Render the chart with a chart-native hostPath and diff**

Render the current HelmRelease values through `helm template` (or `flux build`) with the library persistence swapped to:
```yaml
immich:
  persistence:
    library:
      type: hostPath
      hostPath: /var/lib/immich-library
```
Run (illustrative — use the repo's render helper if one exists):
```bash
helm template immich immich/immich --version 0.13.1 -n immich \
  -f <values-with-hostPath-library.yaml> \
  | yq 'select(.kind=="Deployment" and .metadata.name=="immich-server") | .spec.template.spec | {volumes: .volumes, mounts: .containers[0].volumeMounts}'
```
Expected: the server Deployment has a `volumes[]` entry with `hostPath.path: /var/lib/immich-library` **and** a `volumeMounts[]` entry mounting it at `LIB_MOUNT` (`/data`).
- Renders correctly → `LIB_MECH = chart-native` (preferred; least postRenderer surface).
- Chart ignores `type: hostPath` for the `library` key or mounts at the wrong path → `LIB_MECH = postrenderer` (Task 3 will JSON-patch the volume like the existing `/dev/dri` pattern).

- [ ] **Step 3: Confirm NAS virtiofs source is present + writable-by-1000**

Run (from the immich-vm — key must be passed explicitly):
```bash
ssh -i ~/.ssh/zl_nas_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none -p 65300 akhozya@192.168.1.231 \
  'mount | grep immich-library; ls -ln /var/lib/immich-library'
```
Expected: `/var/lib/immich-library` is a `virtiofs` mount; contents show the stale July-5 pre-seed with subtrees `drwxrwsr-x` owned `root` group `1000` (setgid), traversable by uid 1000. This is the pattern the restore (Task 5) must reproduce.

**Deliverable:** `LIB_MECH` + confirmed `LIB_MOUNT`. No commit.

---

## Task 3: HelmRelease repoint (git change — committed, NOT merged)

**Goal:** Write the `apps/immich/release.yaml` changes that repoint the server to immich-vm. Commit in the worktree. **Do not merge** — the merge is the cutover step (Task 5). Because merge = deploy, this task's deliverable is a reviewed, CI-eligible commit sitting on the worktree branch.

**Files:**
- Modify: `apps/immich/release.yaml`

**Interfaces:**
- Consumes: `GPU_PATH` (Task 1), `LIB_MECH` + `LIB_MOUNT` (Task 2).
- Produces: the cutover commit on `wt-immich-4e-plan`.

- [ ] **Step 1: Swap the library volume to the NAS hostPath**

`LIB_MECH = postrenderer` (Task 2 render-check: the chart schema forbids `type`/`hostPath` under `immich.persistence.library`; it accepts only `existingClaim`, and always emits the library as volume `name: data` at **index 0** mounted at `/data`). So:

1. **Leave the values persistence block UNCHANGED** (`immich.persistence.library.existingClaim: immich-library` stays — schema-required; the postRenderer overrides the volume source, so the dead PVC name is harmless after Task 7 removes the PVC). Add a clarifying comment there:
```yaml
    immich:
      metrics:
        enabled: true
      persistence:
        library:
          # existingClaim is schema-required but OVERRIDDEN by the postRenderer below,
          # which replaces volume[0] (name=data) PVC→hostPath /var/lib/immich-library (NAS
          # virtiofs). The immich-library PVC is removed in Task 7 after soak.
          existingClaim: immich-library
```
2. **Add a postRenderer JSON-patch** to the existing `immich-server` target patch block (alongside the priorityClass/strategy ops), replacing the chart's PVC library volume with the NAS hostPath. Index 0 is render-proven stable (the server carries only the `data` volume; the `/dev/dri` volume is removed in Step 5 for the device-plugin path):
```yaml
              # Library: swap the chart's PVC volume (index 0, name=data) for the NAS
              # virtiofs hostPath. Mount path /data is unchanged (DB asset paths are
              # relative to it). accessmode=passthrough → pod uid/gid 1000 = NAS akhozya.
              - op: replace
                path: /spec/template/spec/volumes/0
                value:
                  name: data
                  hostPath:
                    path: /var/lib/immich-library
                    type: Directory
```
   (The `/data` volumeMount comes from the chart and is left as-is. Re-render after writing to reconfirm `volumes[0].name == data` before committing — Step 6 validate.)

- [ ] **Step 2: Pin the server pod to immich-vm**

Add to `server.controllers.main.pod` (release.yaml ~line 193, alongside `securityContext`):
```yaml
          pod:
            nodeSelector:
              homelab/gpu: intel        # real key from Task 1 Step 1
            securityContext:
              ...
```

- [ ] **Step 3: Swap GPU GIDs to immich-vm values**

Replace release.yaml:199-201:
```yaml
    # BEFORE
              supplementalGroups:
                - 985  # video group on worker-node
                - 989  # render group on worker-node
```
```yaml
    # AFTER
              supplementalGroups:
                - 983  # video group on immich-vm
                - 987  # render group on immich-vm
```

- [ ] **Step 4: Switch the VAAPI driver to iHD (Intel)**

Replace release.yaml:271:
```yaml
    # BEFORE
              LIBVA_DRIVER_NAME: radeonsi
```
```yaml
    # AFTER
              LIBVA_DRIVER_NAME: iHD
```

- [ ] **Step 5: Apply the GPU access change (device-plugin — proven in Task 1)**

`GPU_PATH = device-plugin` (Task 1 confirmed non-priv QSV works; the fallback is unused but was pre-authorized). Do:
1. **Remove** the postRenderer privileged/hostPath block (release.yaml:57-75) — the three ops: `replace .../securityContext → privileged:true`, `add volumes/- dri hostPath /dev/dri`, `add volumeMounts/- dri`.
2. Add the GPU resource to the server main container (release.yaml `containers.main.resources`):
```yaml
              resources:
                requests:
                  cpu: 200m
                  memory: 512Mi
                  gpu.intel.com/i915: "1"
                limits:
                  cpu: "1500m"
                  memory: 5Gi
                  gpu.intel.com/i915: "1"
```
3. Give the server main container a Kyverno-clean securityContext (replaces the deleted privileged patch — pod-level already sets runAsUser 1000; immich is excluded from RoRFS + priv-esc so RoRFS is not required):
```yaml
              securityContext:
                allowPrivilegeEscalation: false
                capabilities:
                  drop: ["ALL"]
```
   Update the pod-level seccomp comment (release.yaml:202-204) — it says "container's securityContext is replaced with privileged:true"; that is no longer true. Reword to note pod-level seccomp is retained for the device-plugin path.

(Fallback path, NOT taken: had the spike failed, keep the postRenderer privileged + `/dev/dri` hostPath block as-is and change only Steps 2/3/4. Task 1 passed, so this is not used.)

- [ ] **Step 6: Validate the render locally**

Run: `cd .claude/worktrees/immich-4e-plan && /homelab-yaml-validate` (or the repo's kustomize-build + kubeconform path for the `apps` root).
Expected: kustomize build succeeds; kubeconform passes; no Kyverno-obvious violations (limits present, non-root retained). Fix any error before committing.

- [ ] **Step 7: Codex STATIC review** (git-only, one-message verdict, point at `.claude/review-invariants.md`)

Dispatch `codex-rescue` constrained to `git diff main..wt-immich-4e-plan -- apps/immich/release.yaml` + reads. Process findings via `superpowers:receiving-code-review`; delta re-review while CRITICAL/HIGH (cap 3). Specifically ask it to check: NetworkPolicy still allows the server↔DB/Redis egress from the new node (NP is namespace-scoped, node-move is transparent — confirm), the library mount path is preserved, GID/driver correctness, and that removing the privileged patch doesn't strand a Kyverno requirement.

- [ ] **Step 8: Commit (worktree only — do NOT merge)**

```bash
git add apps/immich/release.yaml
git commit -m "feat: repoint immich-server to immich-vm GPU node with NAS library"
```

**Deliverable:** reviewed cutover commit on `wt-immich-4e-plan`. Stays unmerged until Task 5.

---

## Task 4: Backup re-topology (git change — committed, NOT merged)

**Goal:** Post-cutover the library is on the NAS, so `immich-backup-cronjob`'s W1 source path (`/mnt/k8s-storage/*immich-library*`) is gone. Re-point the backup Job to read the NAS-resident library on immich-vm (primary tar → NAS) AND add a W2 pull-replica so a second physical copy exists (D6). The DB (CNPG) backup is unaffected.

**Files:**
- Modify: `infrastructure/configs/backup/immich-backup-cronjob.yaml` (producer → W2, library via NAS rsync module)
- Reference (mirror creds/known-hosts/NP): `infrastructure/configs/backup-replication/{nas-rsync-secret.yaml,ssh-known-hosts-configmap.yaml,networkpolicy.yaml}`

**Interfaces:**
- Consumes: the NAS-resident library (via the `personal_folder` rsync module — see grounded facts below).
- Produces: the locked topology (design); the manifest is authored + committed at the backup gate (Task 7 Step 1).

**This task is DESIGN + GROUNDING; the CronJob manifest is authored at Task 7 Step 1** (the backup gate runs post-48h-soak, days after cutover, and is operator-driven — writing the manifest now, before the post-cutover library exists to perf-test the producer against, would be speculative). The topology + NAS module facts below are locked so there is no rework.

**Grounded NAS facts (verified 2026-07-12 via `ssh zl-nas`).** rsync daemon on **port 50555**, modules: `personal_folder` → `/home/akhozya` (so the library at `/home/akhozya/immich/library` is reachable at `rsync://akhozya@192.168.1.136:50555/personal_folder/immich/library/`); `akhozya-pool1` → `/zettos/pool/1/teams/akhozya-pool1/DATA/akhozya-pool1` (the homelab backup **history** root — existing replication accumulates `backups/homelab/…` here). immich-vm mounts ONLY `/var/lib/immich-library` (= NAS `/home/akhozya/immich/library`), NOT a backups dir; the guest is small (12Gi RAM, limited disk) and **cannot stage a 60G+ tar**. So the producer CANNOT simply run on immich-vm and write a NAS tar without either a 2nd virtiofs mount (domain XML + cold-cycle) or streaming — both add coupling.

**Topology LOCKED (grounded).** Produce the tar on a NODE that has disk + the NAS rsync creds (**W2**), not on immich-vm:
1. **Producer (W2)** — the `immich-backup` CronJob moves to W2 (`nodeSelector kubernetes.io/hostname: worker-node-2`) and obtains the library over the NAS `personal_folder` rsync module, producing `immich-library.tar` + `.sha256` on a **W2 hostPath** (`/mnt/extra-storage/backups/immich`) = first physical copy on a node. Two producer mechanisms, decided by a one-off perf test at execution:
   - (a) rsync-pull `personal_folder/immich/library/` → W2 staging, then tar+sha locally (double I/O, slow over 100k+ small files), or
   - (b) `ssh akhozya@NAS 'tar -C /home/akhozya/immich/library -cf - .'` streamed to W2 where it's written + sha256'd (single stream; needs the NAS SSH key in the Job, mirroring the gpu-node `nas-ssh-key-secret` pattern).
2. **History/second location (NAS pool)** — push the tar to the NAS `akhozya-pool1` module at `backups/homelab/immich/` (where homelab backup history already lives + is retention-pruned), keep-2. This reuses the existing `backup-replication` push path/creds.

Net: two physical copies (W2 node + NAS `akhozya-pool1` pool, a different filesystem than the `personal_folder`/library) — non-circular, D6 satisfied. No immich-vm involvement, no 2nd virtiofs mount, no guest-disk limit.

- [ ] **Step 1: Lock the producer mechanism** — at the backup gate, time (a) vs (b) against the real post-cutover library once (`time` a dry rsync-pull vs a dry ssh-tar-stream of a subtree). Pick the faster; default to (b) ssh-tar-stream if comparable (one pass, no 60G staging on W2). Record the choice in the CronJob comment.

- [ ] **Step 2: Author the producer CronJob** (`infrastructure/configs/backup/immich-backup-cronjob.yaml`) — mirror the existing structure (keep-2 retention, homelab-batch priority, securityContext, resources). Change: `nodeSelector` → `worker-node-2`; source = the NAS `personal_folder` library over the chosen mechanism (rsync creds from `backup-replication/nas-rsync-secret.yaml`, or NAS SSH key secret for stream); tar+sha to the W2 hostPath; then push the tar to `rsync://…@192.168.1.136:50555/akhozya-pool1/backups/homelab/immich/`. Add a NetworkPolicy for the Job's egress to `192.168.1.136:50555` (and :65300 if ssh-stream) mirroring `backup-replication/networkpolicy.yaml`. Register any new files in the backup kustomization.

- [ ] **Step 3: Validate** — `cd .claude/worktrees/… && /homelab-yaml-validate` (build + kubeconform).

- [ ] **Step 4: Codex STATIC review** (git-only, `.claude/review-invariants.md`) on `git diff … -- infrastructure/configs/backup/`. Check: the tar reaches a *second physical box* (W2) AND the NAS `akhozya-pool1` pool (not only the `personal_folder`/library filesystem = would be circular); library access is read-only; keep-2 holds; every new egress has a NetworkPolicy; placement is W2. Process via `receiving-code-review`.

- [ ] **Step 5: Commit + this is where Task 7 Step 1 merges it** (worktree commit, merged at the backup gate):
```bash
git add infrastructure/configs/backup/
git commit -m "feat: re-point immich library backup to NAS-resident library with W2 + pool copies"
```

**Deliverable:** locked, grounded topology (this task) + the reviewed backup commit authored at the gate (Task 7 Step 1). D6 met before W1 decommission.

---

## Task 5: Cutover runbook (operator, maintenance window)

**Goal:** Execute the live cutover. **Operator-run, not agent-autonomous** (fence/backup/restore/enable-uploads touch prod). The agent prepares the runbook + assists with verification queries; the operator drives the destructive/live steps. Merging Task 3's commit to main IS "step 4" here.

**Precondition:** Task 0 CI green; Task 1 `GPU_PATH` decided; Task 2 `LIB_MECH`/`LIB_MOUNT` confirmed; Task 3 commit reviewed on the worktree branch. Snapshot the pre-cutover DB asset count for the reads gate:
```bash
kubectl -n immich exec deploy/immich-server -- sh -c \
  'psql "$DB_URL" -tAc "select count(*) from assets"' 2>/dev/null || echo "capture via the DB pod instead"
```
Record `ASSET_COUNT_PRE`.

- [ ] **Step 0 — Prepare the upload-fence commit (NetworkPolicy, verified mechanism).** GROUND TRUTH (verified 2026-07-12 against `apps/immich/networkpolicy.yaml`): external traffic enters from the **`cloudflare-tunnel` namespace straight to `immich-server:2283`, BYPASSING Traefik** (NP ingress rule lines 21-27); LAN enters from the `traefik` namespace (lines 14-20). So a Traefik middleware CANNOT fence external uploads — a Traefik-only fence would leak. The reliable, path-agnostic fence is the NetworkPolicy itself: temporarily remove the three **client-facing** `:2283` ingress rules (`traefik`, `cloudflare-tunnel`, `uptime-kuma`) while KEEPING the `monitoring` (8081/8082), intra-immich (3003/6379), admin-setup, and all egress rules. Effect: no HTTP client (LAN or external) can reach the pod, so no upload is possible; `kubectl port-forward` still reaches it (it goes API-server→kubelet→pod, not subject to NetworkPolicy) so the operator can still read-verify. Prepare this as a SEPARATE commit on `wt-immich-4e-plan` (comment the three rules out with a `# FENCE (4E cutover) — restore at enable-uploads` marker) — it is merged at Step 2 and `git revert`ed at Step 6.
  - **Spec deviation (deliberate):** the spec's "up read-only after Step 5" is downgraded to "unreachable to clients until Step 6." No reliable method-level (read-allow/write-deny) fence exists across both paths (`cloudflare-tunnel` has no Traefik to attach a middleware to; Traefik has no built-in HTTP-method deny). A full NP fence is provable and simple; D5 already accepts window downtime; reads are still verified via port-forward. This extends read-downtime to cover the verify window — an accepted trade for a provable rollback guarantee. (Derived-file writes by the server itself — thumbnails/transcodes during read-verify — are fine; they regenerate on rollback. Only original-asset uploads are rollback-critical, and those are impossible while clients can't reach the pod.)

- [ ] **Step 1 — Spike gate.** Confirm Task 1 `GPU_PATH = device-plugin` still holds (re-run Task 1 if the VM was cold-cycled since).

- [ ] **Step 2 — Fence (downtime start).**
```bash
flux -n flux-system suspend helmrelease immich
kubectl -n immich scale deploy immich-server --replicas=0
kubectl -n immich rollout status deploy immich-server --timeout=120s   # →0
```
Merge the Step-0 fence commit → main → push → `fr` (fence-on). **Negative test:** from a LAN browser AND the external `https://immich.h0melab.work` URL, confirm immich is now UNREACHABLE (timeout/502) — proves both paths are fenced before any pod serves the NAS library. Trigger a fresh library backup on the CURRENT (W1) library and verify sha256 — this is the point-in-time snapshot with writes fenced:
```bash
kubectl -n kube-system create job immich-backup-cutover --from=cronjob/immich-backup
kubectl -n kube-system wait --for=condition=complete job/immich-backup-cutover --timeout=45m
# then verify the tar + .sha256 on the backup target (sha256sum -c)
```

- [ ] **Step 3 — Restore into a CLEAN dir + atomic swap on the NAS** (discard the July-5 pre-seed; extract-over would leave DB-orphaned deleted files, spec §2.3):
```bash
# on the NAS host (ssh zl-nas), staging beside the live source:
STAGE=/home/akhozya/immich/library.new
LIVE=/home/akhozya/immich/library
rm -rf "$STAGE" && mkdir -p "$STAGE"
# verify sha256, then extract the fresh tar into the EMPTY staging dir:
sha256sum -c immich-library.tar.sha256
tar -xf immich-library.tar -C "$STAGE"
# reproduce write-capability: uid-1000-writable, group-1000 setgid subtrees
chown -R 1000:1000 "$STAGE"          # or confirm tar preserved uid-1000 + drwxrwsr-x
# atomic swap:
mv "$LIVE" "$LIVE.old-$(date +%s)" && mv "$STAGE" "$LIVE"
```
Confirm structure (`library/ upload/ thumbs/ encoded-video/ profile/`) + spot-check a recent asset exists. Keep `library.old-*` until soak passes.

- [ ] **Step 4 — Repoint (merge Task 3).** Merge `wt-immich-4e-plan` (Task 3 commit only) → main → push → `fr`. Keep the upload fence in place. `flux resume helmrelease immich`; Flux rolls the server onto immich-vm.
```bash
kubectl -n immich rollout status deploy immich-server --timeout=300s
kubectl -n immich get pod -l app.kubernetes.io/name=immich-server -o wide   # NODE == immich-vm
```

- [ ] **Step 5 — Verify reads/transcode** (all must pass; the ingress paths are NP-fenced, so verify via `kubectl -n immich port-forward deploy/immich-server 2283:2283` — NOT by uploading). NB: `port-forward` reaches the pod via the kubelet injecting into the pod netns, bypassing the CNI NetworkPolicy datapath — confirm it connects as the first sub-check; if a hardened CNI blocks it, temporarily add a narrow `ipBlock` ingress allow for the operator's workstation instead of lifting the client-facing rules:
  - pod `Running` on `immich-vm`; `/data` populated (`kubectl -n immich exec deploy/immich-server -- sh -c 'ls /data && find /data -type f | wc -l'`).
  - Web UI loads thumbnails; opening a photo serves the original.
  - **QSV transcode:** play a video that needs transcode → confirm the server uses `hevc_qsv`/renderD129 (GPU busy on immich-vm), not CPU/radeonsi.
  - `ASSET_COUNT_PRE` == current DB asset count (DB unchanged; sanity that nothing dropped).

- [ ] **Step 5b — WRITE gate (zero-DB-impact; blocks upload-enable):**
```bash
kubectl -n immich exec deploy/immich-server -- sh -c 'touch /data/upload/.write-test && echo ok'
# on the NAS: confirm the file appears owned by uid 1000
ssh zl-nas 'ls -ln /home/akhozya/immich/library/upload/.write-test'
kubectl -n immich exec deploy/immich-server -- rm /data/upload/.write-test
```
Expected: `touch` succeeds; file shows uid `1000` on the NAS; removed cleanly. This proves the non-root pod can create files on virtiofs **without** an Immich asset/DB row (rollback stays clean). **Fails → fix ownership (Step 3 chown), do NOT enable uploads.** (The service stays NP-fenced/unreachable-to-clients through here — client read-availability returns only at Step 6.)

- [ ] **Step 6 — Enable uploads (⚠️ POINT OF NO RETURN).** `git revert` the Step-0 fence commit → merge → push → `fr` (fence-off: restores the three client `:2283` ingress rules). **Positive test:** LAN + external URL now load. Set admin ffmpeg accel = **QSV** in the Immich admin UI; re-run one transcode on a sample; confirm no `radeonsi`/CPU fallback in logs. After this, new user assets land only on the NAS — a W1 rollback would lose them.

**Deliverable:** Immich serving from immich-vm with QSV transcode; uploads live; client access restored. Rollback boundary passed.

**Rollback (only valid through Step 5b, before Step 6):** the fence commit is still in force (no user upload could have landed). `flux suspend helmrelease immich`; revert the Task 3 merge AND the fence commit on main (`git revert`); `flux resume` → server returns to W1 on the intact `immich-library` PVC with client access restored. The W1 PVC is untouched and no user asset landed on the NAS → zero data loss.

---

## Task 6: Soak (≥48h)

**Goal:** Confirm the new placement is stable before touching backups/decommission.

- [ ] **Step 1: Watch for 48h** — check daily:
  - `kubectl -n immich get pod -o wide` — no restarts from I/O; still on immich-vm.
  - Transcode jobs succeed (Immich admin jobs page; GPU used).
  - Memory stable (`kubectl -n immich top pod`); virtiofs I/O latency not causing probe flaps.
  - immich-vm watchdog green (`immich-vm-heal` Jobs Succeeded; no fbdev-wedge alerts).
- [ ] **Step 2: Gate** — all green for ≥48h → proceed to Task 7. Any instability → diagnose (escape hatch: move hot dirs like `thumbs/` to VM-local disk, spec §5.2) before decommission.

**Deliverable:** 48h clean soak recorded.

---

## Task 7: Backup gate + W1 decommission

**Goal:** Prove the post-cutover backup topology (NAS primary + replicated to a second physical node, restore-verified) BEFORE reclaiming the stale W1 library. This gate blocks decommission (D6).

**Files:**
- Merge: Task 4 commit (backup re-topology).
- Modify: `apps/immich/library-pvc.yaml`, `apps/immich/kustomization.yaml` (remove the PVC after decommission).

- [ ] **Step 1: Author + review + merge the backup re-topology** per Task 4's locked topology (producer on W2 via the NAS `personal_folder` module; tar to W2 hostPath + push to NAS `akhozya-pool1/backups/homelab/immich/`). Do Task 4 Steps 1-5 now (perf-test producer mechanism → author CronJob + NP → validate → Codex → commit), then merge → main → push → `fr`. Confirm the re-pointed `immich-backup` CronJob is scheduled and reads the post-cutover NAS library.

- [ ] **Step 2: Run one full backup + prove the second physical copy**
```bash
kubectl -n kube-system create job immich-backup-gate --from=cronjob/immich-backup
kubectl -n kube-system wait --for=condition=complete job/immich-backup-gate --timeout=45m
```
Confirm the tar landed on **W2** (`/mnt/extra-storage/backups/immich`) AND on the NAS `akhozya-pool1` pool — two physical copies on different filesystems.

- [ ] **Step 3: Restore-verify on W2** — extract the W2 tar, `sha256sum -c`, and spot-check a recent asset. This proves the copy is restorable, not just present.

- [ ] **Step 4: Decommission W1** (only after Steps 2-3 GREEN):
  - Remove `apps/immich/library-pvc.yaml` from `apps/immich/kustomization.yaml` and delete the file.
  - Commit → merge → push → `fr`. Flux prunes the PVC; confirm the underlying local-path PV (`pvc-495129ee-…`) is released, then delete it + the W1 on-disk dir + the `library.old-*` NAS staging copy.
```bash
git add apps/immich/kustomization.yaml && git rm apps/immich/library-pvc.yaml
git commit -m "chore: remove W1 immich-library PVC after NAS cutover soak"
```

**Deliverable:** W1 library reclaimed; backups NAS-primary + node-replicated + restore-verified.

---

## Follow-up (post-cutover, separate cleanup — Codex T3 LOW #2)

After the cutover soaks, review whether the immich exemptions in the cluster-wide Kyverno policies are still needed now that the **server** is non-privileged + `drop:[ALL]` + no `/dev/dri`: `disallow-privilege-escalation{,-vp}`, `require-drop-all-capabilities`, `require-readonly-rootfs`, `disallow-host-path{,-vp}`. The host-path exemption is STILL needed (library hostPath). The priv-esc/drop-all exemptions may be removable for the server but could still be load-bearing for other immich pods (ML, admin-setup Job, backup) — verify across ALL immich workloads before touching (behavioral change). Update the stale rationale comments in those policy files at the same time. Kept out of the cutover commit to avoid scope creep + cross-workload policy risk.

## Phase 2 (follow-on — NOT in this plan)

Tracked in the spec §4; execute as a separate plan after Phase 1 soaks:
- ML image `v3.0.2` → `v3.0.2-openvino`; add `gpu.intel.com/i915: 1` + `nodeSelector homelab/gpu=intel` + supplementalGroups `[983,987]`; re-home the ML cache PVC.
- VM vCPU/RAM bump via `apps/immich/gpu-node/immich-vm-domain.xml` → NAS-side **cold-cycle** (watchdog re-defines from Git; memfd-backed RAM; NAS 30Gi total — keep headroom). Never a zettOS-UI edit.
- Reset-bug rules unchanged.

---

## Self-Review

**Spec coverage:** D1 phased (Phase 1 here, Phase 2 deferred) ✓; D2 device-plugin spike + fallback (Task 1, Task 3 Step 5) ✓; D3 library hostPath (Task 2, Task 3 Step 1) ✓; D4 backup-restore clean-extract+swap (Task 5 Steps 2-3) ✓; D5 maintenance window (Task 5) ✓; D6 NAS+node backup, gated before decommission (Task 4, Task 7) ✓. Ground-truth §1 re-asserted (Task 2). Write gate §2.4-5b (Task 5 Step 5b) ✓. Point-of-no-return = enable uploads (Task 5 Step 6) ✓. CI billing gate §6 (Task 0) ✓. Reset-bug §6 (Global Constraints) ✓.

**Resolved during planning (2026-07-12, all render/spike/NAS-verified):**
- `GPU_PATH = device-plugin` — Task 1 EXECUTED: non-priv `hevc_qsv` 25.3x on immich-vm, render GID 987.
- `LIB_MECH = postrenderer` — Task 2 render-check: chart rejects `type/hostPath`; library = volume `data` idx 0 mount `/data`; postRenderer `replace volumes/0` PROVEN via helm+kustomize (final pod has hostPath+nodeSelector+GIDs+gpu+iHD+non-priv). Task 3 written accordingly.
- Upload fence = surgical NetworkPolicy (drop 3 client `:2283` rules) — Task 5 Step 0: confirmed `cloudflare-tunnel` ns hits `immich-server:2283` bypassing Traefik, so NP is the only path-agnostic fence. User-approved full-fence (unreachable during verify, not read-only).
- Backup topology — Task 4: NAS rsync modules verified (`personal_folder`→`/home/akhozya`=library; `akhozya-pool1`=history pool); immich-vm can't hold a 60G tar → producer runs on **W2** (library via `personal_folder` module → tar on W2 + push to `akhozya-pool1` pool = two physical copies). Manifest authored at the backup gate (Task 7 Step 1, post-soak) against the live library — grounded, not speculative.

**Execution-time choice remaining (not a placeholder):** the W2 producer mechanism (rsync-pull-then-tar vs ssh-tar-stream) — one perf test at the backup gate (Task 4 Step 1).

**Codex static review (2 rounds):** R1 = 3 HIGH + 1 MED + 1 LOW, all folded in (GPU spike `create`-not-`apply` + throwaway-exception note; upload fence made concrete via NP after confirming `cloudflare-tunnel` bypasses Traefik; backup second-copy built in Task 4 not deferred; Task 0 uses `workflow_dispatch`; library line anchor fixed). Pushed back on R1-#1's "make the spike a GitOps Job" remedy as YAGNI for a 90-second throwaway.
