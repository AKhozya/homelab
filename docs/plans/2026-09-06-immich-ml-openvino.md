# Immich ML on the immich-vm iGPU (OpenVINO) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. The coordinator (the Opus session the operator starts) owns every step marked **Coordinator**: Codex reviews, commits, merges, the ledger. Implementer subagents own every step marked **Implementer**; the coordinator picks their model per the skill's Model Selection rules (Task 1 is transcription of the snippets below; Task 2 needs judgment about live output; Task 3 is docs).

**Goal:** immich-machine-learning runs inference on immich-vm's Intel iGPU through the `-openvino` image, with a gate that proves the GPU is in use.

**Architecture:** One values change in `apps/immich/release.yaml`. The ML image tag gains the `-openvino` suffix; the container requests one `gpu.intel.com/i915` share so the Intel device plugin injects `/dev/dri` without privilege; the pod adds the VM's video and render GIDs; the memory limit grows; the rapidocr mount path in the ML postRenderer follows the image's Python minor. Immich picks the GPU itself: ONNX Runtime's OpenVINO execution provider enumerates devices and the ML code chooses `GPU.0` if one exists, else the OpenVINO CPU plugin.

**Tech Stack:**

| Component | Version |
|---|---|
| k3s | v1.36.3 |
| Flux + Helm chart `immich` (bjw-s common) | chart 0.13.1 |
| Intel GPU device plugin | 0.36.0, `-shared-dev-num=10` |
| Immich | v3.1.0 |
| ML image `ghcr.io/immich-app/immich-machine-learning:v3.1.0-openvino` | Python 3.13.14, onnxruntime-openvino 1.24.1, intel-opencl-icd 26.22.38646.4, IGC 2.36.3 |
| Review | Codex static review |

**Spec:** the *Design* section of this file. There is no separate spec document; the repo keeps plans in `docs/plans/`.

## Global Constraints

- GitOps only. No `kubectl edit/patch/replace`, no `kubectl apply` without `--dry-run=server`. The only imperative actions this plan sanctions are Task 2's read-only probes: `kubectl exec` for a device listing, a rapidocr path check and one inference request, and read-only SSH to the VM.
- Every non-docs change is reviewed **before** it is committed, per the pre-commit loop in `AGENTS.md`: the implementer leaves the diff uncommitted in the worktree; the coordinator reviews `git diff HEAD` via `~/.agents/skills/_shared/codex-review.sh --diff <file> --prompt <file>` with the contract in the Appendix, processes findings with `superpowers:receiving-code-review`, re-reviews delta-scoped, and commits only when the severity table allows. Docs-only commits are exempt.
- Merging Task 1 deploys to production and restarts immich-machine-learning. The Deployment uses `Recreate`, so Immich ML (search, faces, OCR) is unavailable while the 752 MiB image pulls and the pod starts: minutes. The operator approved this plan on 2026-09-06; the coordinator merges without asking again.
- Work happens in worktree `.claude/worktrees/immich-ml-openvino` on branch `wt-immich-ml-openvino`. Create it with `git worktree add .claude/worktrees/immich-ml-openvino -b wt-immich-ml-openvino main` from the main tree. Merge with `bash ~/.agents/skills/_shared/merge-worktree.sh wt-immich-ml-openvino`; add `--teardown` only on the last merge (Task 3).
- The SDD ledger lives in the git-ignored `.superpowers/sdd/2026-09-06-immich-ml-openvino/` inside the worktree. A clean worktree at HEAD == main is exactly what worktree cleanup deletes, and that took the previous plan's ledger on 2026-09-06. Copy `progress.md` outside the worktree after every task.
- Commit messages: single line, no Claude mention. Commit explicit paths: `git commit -m '<msg>' -- <paths>` (message before `--`).
- Comments earn their place only by naming a coupling, constraint, gotcha or rejected alternative. Docs: tables for enumerable facts, active voice, one idea per sentence.
- No sudo over SSH. Every VM command in this plan is read-only and runs as `ssh -p 65300 akhozya@immich-vm`.
- Never reboot immich-vm from inside the guest, never `virsh destroy` it (GPU reset bug). If the GPU hangs, stop and hand over to the operator: recovery is the host-side phase2 carve-out.

## Design

### What changes

| Item | Before | After | Why |
|---|---|---|---|
| ML image tag | `v3.1.0` | `v3.1.0-openvino` (server stays `v3.1.0`) | the suffix selects ONNX Runtime's OpenVINO execution provider plus the Intel compute runtime; the version part must stay in lockstep with the server |
| ML resources | no GPU share; memory limit 2355Mi | `gpu.intel.com/i915: "1"` in requests and limits; memory limit 4Gi; cpu and memory requests unchanged | the device plugin injects `/dev/dri` into the container without privilege (the server does the same); OpenVINO holds model buffers in system RAM charged to the container ("Expect higher RAM usage", Immich docs) |
| ML pod securityContext | uid/gid/fsGroup 1000, seccomp RuntimeDefault | adds `supplementalGroups: [983, 987]` | the injected nodes are `root:render` (renderD*, 0666) and `root:video` (card*, 0660) on the VM; the GIDs let the non-root pod open them, same block as the server |
| rapidocr emptyDir mount path (ML postRenderer) | `/opt/venv/lib/python3.11/site-packages/rapidocr/models` | `/opt/venv/lib/python3.13/site-packages/rapidocr/models` | the `-openvino` image builds on `python:3.13-slim-trixie`, the CPU image on `python:3.11-slim-bookworm`; an unmoved path leaves the real models dir on the read-only root and OCR model downloads fail |
| Env, precision, log level | — | unchanged | Immich picks `GPU.0` on its own (`MACHINE_LEARNING_DEVICE_ID` defaults to `0`); FP32 is the default; the GPU-choice log line is DEBUG, so the gate is a device listing, not a log grep |

### The gate: "the GPU is in use"

A green rollout proves nothing about the GPU. If OpenVINO enumerates no GPU, Immich falls back to the OpenVINO **CPU** plugin at DEBUG log level and keeps serving. Task 2 requires all of:

| Check | Pass |
|---|---|
| `ort.capi._pybind_state.get_available_openvino_device_ids()` run by `kubectl exec` in the new pod (the call Immich makes in `sessions/ort.py`) | the list contains a `GPU` entry |
| ML log after one `/predict` call | `Setting execution providers to` followed by `['OpenVINOExecutionProvider', 'CPUExecutionProvider']` |
| i915 per-client engine counters (`drm-engine-*` in the ML worker's `/proc/<pid>/fdinfo`) read before and after the warm call | at least one counter increases. This ties the activity to the ML process; the clock alone cannot, because immich-server shares the GPU |
| GPU clock sampled on the VM during the first call | `rps_cur_freq_mhz` rises above 0 (supporting evidence only) |
| second `/predict` call | seconds at most; the first call compiles the model for the GPU and writes the blob under `/cache/<model>/openvino` |
| compiled blob | a file larger than 1 MiB under `/cache/clip/ViT-B-32__openai/textual/openvino/`, dated at the first call |
| VM kernel journal after the calls | no `GPU HANG` or reset lines |

The CPU baseline measured on 2026-09-06 with the same call: first call 41.7 s (download of the textual model plus load), warm call 0.045 s. A warm GPU call on a small text model is not expected to beat 0.045 s; the gate is the device listing and the ML process's engine counters, not a speed-up on this model.

### Accepted trade-offs

| Trade-off | Why accepted |
|---|---|
| ML outage for the image pull (Recreate strategy) | minutes; the strategy exists to avoid double quota and lock contention; the pull lands on the 125 G home LV (`/home/k3s` data-dir), not the 32 G root |
| Memory limit 4Gi is headroom, not a measurement | CPU-path 7d peak was ~1.44 GiB under 2355Mi; node limits rise from 8525Mi to ~10.3Gi of 11.6Gi allocatable; requests are unchanged; trim after a week of metrics |
| The test inference uses the default CLIP model `ViT-B-32__openai`, which may differ from the configured one | the gate is provider-level; the textual model is already in `/cache` since the 2026-09-06 baseline call, so no extra download |
| No FP16, no model change | separate follow-ups once a GPU baseline exists |
| GPU compute hang inside the passthrough VM ("Integrated GPUs are more likely to experience issues", Immich docs) | rollback is one reverted commit; recovery of a hung GPU is the host-side phase2 carve-out; Task 2 checks the journal before declaring done |
| Renovate may bump server and ML tags in separate PRs (pre-existing) | unchanged by this plan; the docker versioning keeps the `-openvino` suffix on bumps |

## Assumptions and cut corners

Tiers: ✅ verified against the live system or official source · 🟡 single-source · ⚠️ assumption. Everything below ✅ is validated by a named Task 2 step or listed under Rollback.

| # | Claim | Tier | Evidence |
|---|---|---|---|
| A1 | `ghcr.io/immich-app/immich-machine-learning:v3.1.0-openvino` exists, linux/amd64, 752 MiB compressed | ✅ | ghcr manifest HTTP 200, 2026-09-06 |
| A2 | The `-openvino` image runs Python 3.13.14 with `DEVICE=openvino` and no mimalloc `LD_PRELOAD`; the CPU image runs Python 3.11.15 | ✅ | image config env for both tags; `machine-learning/Dockerfile` at v3.1.0 (`prod-openvino` FROM `python:3.13-slim-trixie`, `prod-cpu` FROM `python:3.11-slim-bookworm`); live pod `sys.version` 3.11.15 |
| A3 | The `-openvino` image installs intel-opencl-icd 26.22.38646.4, IGC 2.36.3, the legacy1 24.35 ICD and libigdgmm12; no `mesa-opencl-icd` (that is the armnn stage) | ✅ | Dockerfile v3.1.0 lines 47–62 and 85–95 |
| A4 | Immich picks `GPU.<MACHINE_LEARNING_DEVICE_ID>` when `get_available_openvino_device_ids()` returns a `GPU*` entry, else `CPU`; both at DEBUG level; `cache_dir` = `/cache/<model>/openvino`; precision default FP32 | ✅ | `immich_ml/sessions/ort.py` 142–156 and `immich_ml/config.py` 75–80 at v3.1.0 |
| A5 | The INFO line `Setting execution providers to [...]` prints on the first model load; the provider list wraps onto the next log line | ✅ | `ort.py:106`; live log 2026-09-06 |
| A6 | The VM GPU is Intel `0x7d55` (Meteor Lake Arc, Core Ultra 5 125H) on `i915` with GuC submission, kernel 6.18.49-lts; `renderD129` is `0666 root:render(987)`, `card0`/`card1` are `0660 root:video(983)`; `renderD128`/`card1` are virtio-gpu | ✅ | SSH spike 2026-09-06 |
| A7 | Intel compute runtime 26.22 supports Meteor Lake; the virtio-gpu node has no OpenCL ICD in the image, so `GPU.0` is the Intel GPU | 🟡 | A3 (no mesa ICD); Meteor Lake support in compute-runtime is from my knowledge, not re-read. Validated by Task 2 step 3; failure mode is the CPU fallback, not an outage |
| A8 | The server already uses `gpu.intel.com/i915: "1"` with `supplementalGroups [983, 987]`; the plugin runs `-shared-dev-num=10`; node allocatable 10, 1 in use | ✅ | live Deployment and Node objects 2026-09-06 |
| A9 | The ML Deployment strategy is `Recreate` (postRenderer) | ✅ | live `spec.strategy` |
| A10 | ML 7d working-set peak ≈ 1.44 GiB; server 7d peak ≈ 1.15 GiB; node allocatable 11.6 Gi, memory limits sum 8525Mi, requests 1439Mi; VM MemAvailable 7d min ≈ 8.2 GiB | ✅ | VictoriaMetrics queries via the vmalert pod, 2026-09-06 |
| A11 | Renovate's docker versioning treats the text after the first hyphen as compatibility, so only `-openvino` tags are offered; the `helm-values` manager reads `repository`/`tag` in `release.yaml` | ✅ | docs.renovatebot.com/modules/versioning/docker; `renovate.json` `helm-values.managerFilePatterns` |
| A12 | Kyverno rejects only `latest` or missing tags | ✅ | `infrastructure/configs/kyverno-policies/disallow-latest-tag-vp.yaml` |
| A13 | `immich-server` has curl 8.14.1; the ML Service is `immich-machine-learning:3003`; `/predict` takes form fields `entries` (JSON) and `text` or `image`; the server→ML NetworkPolicy path is the production path | ✅ | live exec; `immich_ml/main.py` 132–178; the baseline call returned HTTP 200 |
| A14 | Default CLIP model `ViT-B-32__openai`; its textual model is in `/cache` since the baseline call | ✅ | `server/src/config.ts:304`; ML log "Downloading textual model 'ViT-B-32__openai'" 21:09 on 2026-09-06 |
| A15 | The rapidocr package lives at `/opt/venv/lib/python<minor>/site-packages/rapidocr`; the postRenderer mounts an emptyDir at `.../rapidocr/models` | ✅ | live pod: `rapidocr.__file__` under python3.11; `mount` shows the emptyDir there |
| A16 | `/sys/class/drm/card0/gt/gt0/rps_cur_freq_mhz` reads 0 idle (range 800–2200) and `card0` is `0x7d55` today; the card index can change across boots | ✅ | SSH spike; Task 2 step 5 re-checks the index |
| A17 | `journalctl -kb` on the VM works without sudo | ✅ | SSH spike |
| A18 | The `pod.securityContext.supplementalGroups` and container `resources` values render onto the ML Deployment | ✅ | `helm template` 0.13.1 with the intended values, 2026-09-06 |
| A19 | The GPU shares memory with the VM; buffers are shmem charged to the ML cgroup, so 4Gi is the right knob | 🟡 | i915 GEM objects are shmem-backed; validated by `kubectl top` in Task 2 step 10 and the OOM row under Rollback |
| A20 | Intel's compiler cache under `$HOME/.cache` is unwritable in this pod (RoRFS, uid 1000, no home); the runtime disables it silently and OpenVINO's own `cache_dir` on `/cache` carries the compiled blob | 🟡 | Task 2 step 7 checks that the warm call is fast and step 8 that the blob exists; if logs show cache errors, the fix is `NEO_CACHE_DIR=/cache/neo` in a follow-up commit |
| A21 | The `openvino` Python module may not be importable in the image (onnxruntime-openvino bundles the runtime libraries) | 🟡 | `uv.lock` dependency list; the gate uses ORT's own call, which is what Immich uses |
| A22 | A GPU hang under compute does not recover in-guest | ⚠️ | memory `gotcha_immich_vm_virtio_gpu_fbdev_wedge` and the reset-bug rule in `AGENTS.md`; mitigated under Rollback |
| A23 | i915 exposes per-client engine busy time in `/proc/<pid>/fdinfo` (`drm-driver:<TAB>i915`, `drm-engine-*` in ns), readable by the process owner; the OpenVINO session keeps the render node open while a model is loaded (300 s idle TTL) | ✅ | kernel DRM fdinfo interface; the container runs as uid 1000 and `/proc/<pid>/fdinfo` is readable inside the pod (spike). Confirmed on 2026-09-07: the ML worker holds the render node for the session's whole lifetime, and `drm-engine-compute` rises across a call while the video engines stay at 0 |

## File structure

| File | Task | Change |
|---|---|---|
| `apps/immich/release.yaml` | 1 | four hunks: rapidocr mountPath in the ML postRenderer; ML image tag; ML resources; ML pod securityContext |
| `docs/HOMELAB_ANALYSIS.md` | 3 | Immich row: ML on the iGPU |
| `docs/CODEMAPS/apps.md` | 3 | immich row: `-openvino` image |
| `docs/ARCHITECTURE.md` | 3 | immich-vm node label in the mermaid diagram |
| `docs/HOMELAB_HISTORY.md` | 3 | dated entry with the Task 2 numbers |
| `~/.claude/projects/-Users-akhozya-source-code-homelab/memory/project_immich_gpu_transcode.md`, `MEMORY.md` | 3 | `-openvino` OPEN → DONE (outside the repo, no commit) |

## Task 0: Plan review (done by Fable on 2026-09-06)

Codex rounds on this file, contract in the Appendix. Round log:

| Round | Verdict | Findings |
|---|---|---|
| 1 | REQUEST-CHANGES | MEDIUM ×3: the clock cannot attribute GPU activity to ML (immich-server shares the GPU); the blob check accepted an empty directory; `rollout status` can pass against the previous Deployment revision. LOW: "the time is the GPU compile" overstated what curl measures. NIT: tech stack in prose; "when" for a condition. All folded in |
| 2 | REQUEST-CHANGES | MEDIUM: the image-wait loop fell through to `rollout status` after 60 misses. NIT: step 7 expectations in prose. Both folded in (explicit fail after 10 min; table) |
| 3 | REQUEST-CHANGES | MEDIUM: `false` after the loop does not stop a pasted block, so `rollout status` still ran on timeout. Folded in: the two follow-up commands are gated on the flag; both paths executed |
| 4 | APPROVE-WITH-NITS | NIT: passive voice in the wait-block note. Folded in |
| 5 | APPROVE | no findings |

## Task 1: Manifest change

**Files:**
- Modify: `apps/immich/release.yaml`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: the live ML pod shape Task 2 verifies (image tag, GPU share, GIDs, mount path).

- [ ] **Step 1 (Coordinator): worktree** — from the main tree: `git worktree add .claude/worktrees/immich-ml-openvino -b wt-immich-ml-openvino main`. Record BASE = `git rev-parse HEAD`.

- [ ] **Step 2 (Implementer): rapidocr mount path** — in the ML postRenderer patch (target `Deployment` `immich-machine-learning`, the `volumeMounts/-` op), replace:

```yaml
                  # The Python minor version is hardcoded in this path. Bump it when Immich ML
                  # moves Python, roughly once a year. A version-independent symlink does not
                  # work: /opt/venv is root-owned and the container runs as uid 1000.
                  mountPath: /opt/venv/lib/python3.11/site-packages/rapidocr/models
```

with:

```yaml
                  # The Python minor version is hardcoded in this path and is tied to the image
                  # variant: the -openvino image builds on python:3.13, the CPU image on 3.11. Bump it
                  # with the tag. A version-independent symlink does not work: /opt/venv is root-owned
                  # and the container runs as uid 1000.
                  mountPath: /opt/venv/lib/python3.13/site-packages/rapidocr/models
```

- [ ] **Step 3 (Implementer): image tag** — under `machine-learning.controllers.main.containers.main.image`, replace:

```yaml
                tag: v3.1.0  # CPU-only (ROCm gfx1036 not supported)
```

with:

```yaml
                # -openvino: ONNX Runtime with the OpenVINO execution provider on the VM's Meteor Lake
                # iGPU. The version part must match the server tag; Renovate keeps the suffix on bumps.
                # This variant runs Python 3.13, which the rapidocr mountPath in the postRenderer follows.
                tag: v3.1.0-openvino
```

- [ ] **Step 4 (Implementer): resources** — in the same container, replace:

```yaml
              # ML resources bumped 2026-06-28: CPU limit 2x (2000m→4000m) for inference throughput;
              # RAM limit +15% (2Gi→2355Mi) — 7d peak hit ~78% of 2Gi, too close to OOM headroom.
              resources:
                requests:
                  cpu: 200m
                  memory: 512Mi
                limits:
                  cpu: 4000m
                  memory: 2355Mi
```

with:

```yaml
              # gpu.intel.com/i915: the Intel device plugin injects /dev/dri (10 shares per node, the
              # server holds one). OpenVINO keeps model buffers in system RAM charged to this cgroup;
              # the CPU-path 7d peak was ~1.45 GiB, so 4Gi is headroom to trim after a week of metrics.
              resources:
                requests:
                  cpu: 200m
                  memory: 512Mi
                  gpu.intel.com/i915: "1"
                limits:
                  cpu: 4000m
                  memory: 4Gi
                  gpu.intel.com/i915: "1"
```

- [ ] **Step 5 (Implementer): pod block** — under `machine-learning.controllers.main.pod`, replace the two comment lines:

```yaml
            # Follows the server onto immich-vm (dedicated node). CPU inference for now; the
            # -openvino image is a separate change.
```

with:

```yaml
            # Follows the server onto immich-vm (dedicated node); inference runs on its iGPU.
```

and inside that block's `securityContext`, after `fsGroup: 1000`, add:

```yaml
              # The injected /dev/dri nodes are root:video (card*) and root:render (renderD*) on
              # immich-vm; the GIDs let the non-root pod open them. Same block as the server.
              supplementalGroups:
                - 983  # video group on immich-vm
                - 987  # render group on immich-vm
```

- [ ] **Step 6 (Implementer): validate** — from the worktree, with `SCRATCH` set to a scratch directory:

```bash
yamllint apps/immich
kustomize build apps/immich > /dev/null
grep -n 'python3.13/site-packages/rapidocr/models' apps/immich/release.yaml
yq '.spec.values' apps/immich/release.yaml > $SCRATCH/v.yaml
helm template immich oci://ghcr.io/immich-app/immich-charts/immich --version 0.13.1 -f $SCRATCH/v.yaml > $SCRATCH/r.yaml
yq -o=json 'select(.kind=="Deployment" and .metadata.name=="immich-machine-learning") | .spec.template.spec' $SCRATCH/r.yaml \
  | jq -c '{image: .containers[0].image, limits: .containers[0].resources.limits, requests: .containers[0].resources.requests, groups: .securityContext.supplementalGroups}'
```

Expected: lint clean; one grep hit; the jq line is exactly

```
{"image":"ghcr.io/immich-app/immich-machine-learning:v3.1.0-openvino","limits":{"cpu":"4000m","gpu.intel.com/i915":"1","memory":"4Gi"},"requests":{"cpu":"200m","gpu.intel.com/i915":"1","memory":"512Mi"},"groups":[983,987]}
```

(`helm template` does not apply the Flux postRenderer, which is why the mount path is checked by grep.)

- [ ] **Step 7 (Implementer): hand over uncommitted** — `git status --short` must print exactly `M apps/immich/release.yaml`. Do not commit. Report the validation output.

- [ ] **Step 8 (Coordinator): review loop, then commit** — `git diff HEAD -- apps/immich > $SCRATCH/t1.diff`; dispatch `bash ~/.agents/skills/_shared/codex-review.sh --diff $SCRATCH/t1.diff --prompt $SCRATCH/codex-prompt.md` (contract from the Appendix); process findings; re-review delta-scoped; commit when the severity table allows: `git commit -m 'feat(immich): run ML inference on the immich-vm iGPU via the -openvino image' -- apps/immich/release.yaml`.

- [ ] **Step 9 (Coordinator): merge and roll** — `bash ~/.agents/skills/_shared/merge-worktree.sh wt-immich-ml-openvino` (no teardown), then:

```bash
flux reconcile kustomization apps --with-source
flux reconcile helmrelease immich -n immich
ok=0; for i in $(seq 1 60); do kubectl -n immich get deploy immich-machine-learning -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -q -- '-openvino' && { echo "new template on iteration $i"; ok=1; break; }; sleep 10; done
[ "$ok" = 1 ] || echo "no new template after 10 min: stop; check flux get helmrelease immich -n immich"
[ "$ok" = 1 ] && flux get helmrelease immich -n immich
[ "$ok" = 1 ] && kubectl -n immich rollout status deploy/immich-machine-learning --timeout=900s
```

`rollout status` on its own can return green against the previous Deployment revision before helm-controller applies the upgrade, so the loop waits for the new pod template first, and the two commands after it run only if the flag is set. The 2026-09-06 check confirms that a timeout skips both gated commands and success runs them. If the block prints the `stop` line, do not record completion: read `flux get helmrelease immich -n immich` and `kubectl -n immich describe helmrelease immich`, fix the cause, and rerun the block. Expected: the loop prints an iteration number; `flux get` shows `Helm upgrade succeeded` with a release revision one higher than before (`immich.v43` on 2026-09-06); the old pod terminates; the new pod pulls and passes its startup probe (up to 600 s budget). Append `Task 1: complete <sha>` to the ledger and copy it outside the worktree.

## Task 2: Verification (read-only)

**Files:** none. Output is the report file with every number below.

**Interfaces:**
- Consumes: the live pod from Task 1.
- Produces: the numbers Task 3 writes into HISTORY and memory (first and warm call times, max GPU MHz, working-set memory).

Every step is read-only. If step 3 fails, stop there and report `BLOCKED` with the raw output; the coordinator rolls back (see Rollback). Do not soak on the OpenVINO CPU fallback.

- [ ] **Step 1 (Implementer): placement and image**

```bash
kubectl -n immich get pods -l app.kubernetes.io/name=machine-learning -o wide
kubectl -n immich get deploy immich-machine-learning -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Expected: one pod `Running` `1/1` on `immich-vm`; image `ghcr.io/immich-app/immich-machine-learning:v3.1.0-openvino`.

- [ ] **Step 2 (Implementer): injected device and groups**

```bash
kubectl -n immich exec deploy/immich-machine-learning -- sh -c 'id; ls -l /dev/dri'
```

Expected: `groups=1000,983,987`; `/dev/dri` lists a `card*` and a `renderD*` node (the plugin injects the Intel GPU's nodes; `renderD129` on 2026-09-06).

- [ ] **Step 3 (Implementer): the gate — OpenVINO device listing**

```bash
kubectl -n immich exec deploy/immich-machine-learning -- python3 -c "import onnxruntime as ort; print(ort.__version__, ort.get_available_providers(), ort.capi._pybind_state.get_available_openvino_device_ids())"
```

Expected: version `1.24.1`; providers include `OpenVINOExecutionProvider`; the device list contains an entry starting with `GPU` (for example `['CPU', 'GPU']` or `['CPU', 'GPU.0']`). If no `GPU` entry: `BLOCKED`, attach this output plus step 2's.

- [ ] **Step 4 (Implementer): OCR path**

```bash
kubectl -n immich exec deploy/immich-machine-learning -- sh -c 'python3 -c "import rapidocr,os; print(os.path.dirname(rapidocr.__file__))"; mount | grep rapidocr'
```

Expected: `/opt/venv/lib/python3.13/site-packages/rapidocr` and one mount line ending in `python3.13/site-packages/rapidocr/models`. A `python3.11` path in either line means the mount path and the image disagree: report it as a finding.

- [ ] **Step 5 (Implementer): which card is the Intel GPU today**

```bash
ssh -p 65300 akhozya@immich-vm 'for c in /sys/class/drm/card?; do echo "$c $(cat $c/device/device)"; done'
```

Expected: one line with `0x7d55`; use that card in step 6 (`card0` on 2026-09-06).

- [ ] **Step 6 (Implementer): first inference with the GPU clock sampled** — start the sampler (5 minutes, prints the max MHz seen), then run the call:

```bash
ssh -p 65300 akhozya@immich-vm 'for i in $(seq 1 600); do cat /sys/class/drm/card0/gt/gt0/rps_cur_freq_mhz; sleep 0.5; done | sort -n | tail -1' > $SCRATCH/gpu-max.txt &
kubectl -n immich exec deploy/immich-server -- curl -sS --max-time 600 -o /dev/null -w 'HTTP %{http_code} %{time_total}s\n' \
  --form-string 'entries={"clip":{"textual":{"modelName":"ViT-B-32__openai","options":{}}}}' \
  --form-string 'text=a photo of a cat' \
  http://immich-machine-learning:3003/predict
```

Expected: `HTTP 200`. The time is the first-request latency: model load, GPU compile, inference and transport (the ONNX file is already cached). Record it.

- [ ] **Step 7 (Implementer): engine counters, warm call, provider line** — read the ML worker's i915 per-client counters, run the step 6 curl once more, read the counters again, then the log and the sampler result:

```bash
kubectl -n immich exec deploy/immich-machine-learning -- sh -c 'for f in /proc/[0-9]*/fdinfo/*; do grep -qE "drm-driver:[[:space:]]+i915" "$f" 2>/dev/null && { echo "$f"; grep "drm-engine" "$f"; }; done'
# run the step 6 curl again (record its time), then run the exec line above a second time
kubectl -n immich logs deploy/immich-machine-learning --since=30m | grep -A1 'Setting execution providers' | sed 's/\x1b\[[0-9;]*m//g'
wait; cat $SCRATCH/gpu-max.txt
```

Keep the three commands within a minute: the OpenVINO session holds the render node open only while the model is loaded, and the idle TTL is 300 s.

> **Corrected 2026-09-07.** The `grep` above originally matched `"drm-driver: i915"` with a space. i915 fdinfo separates key from value with a TAB, so that pattern matched nothing however busy the GPU was, and the step-7 run on 2026-09-06 reported the counters as unobservable. A re-probe with the pattern below found the fd held for the session's lifetime and `drm-engine-compute` rising across a call. If this step reports no fd, suspect the pattern before the GPU.

| Check | Expected |
|---|---|
| first exec | at least one fdinfo path with `drm-engine-*` lines |
| warm curl | `HTTP 200` in seconds at most (CPU baseline 0.045 s; a similar or slightly slower number on this small text model is fine) |
| second exec vs first | at least one `drm-engine-*` value is higher. This delta is the evidence tied to the ML process; immich-server shares the GPU, so the clock alone cannot attribute activity |
| log line after `Setting execution providers to` | `['OpenVINOExecutionProvider', 'CPUExecutionProvider'], in descending order of` |
| `gpu-max.txt` | a number above 0 (the clock range is 800–2200 MHz) |
| no fdinfo path in the first exec | run the curl and the exec back to back once more; if still none, report it as a finding with the raw output and continue with the remaining checks |

Record the warm time, the counter values before and after, and the max MHz.

- [ ] **Step 8 (Implementer): compiled blob on the cache PVC**

```bash
kubectl -n immich exec deploy/immich-machine-learning -- sh -c 'find /cache -path "*/openvino/*" -type f -size +1M -printf "%TY-%Tm-%Td %TH:%TM %s %p\n"; du -sh /cache'
```

Expected: at least one file larger than 1 MiB under `/cache/clip/ViT-B-32__openai/textual/openvino/` with an mtime at the step 6 call (`cache_dir` is `<model dir>/openvino`); the cache total is in the hundreds of MiB (the textual and visual ONNX files alone are 254 MB and 352 MB). No file, or only an empty `openvino` directory, means no blob was written: report it as a finding.

- [ ] **Step 9 (Implementer): VM kernel journal**

```bash
ssh -p 65300 akhozya@immich-vm 'journalctl -kb --no-pager --since=-1h | grep -iE "GPU HANG|reset|i915.*(error|fail)" | tail -5'
```

Expected: no output. Any `GPU HANG` line: stop, report `BLOCKED`, do not touch the VM.

- [ ] **Step 10 (Implementer): memory and alerts**

```bash
kubectl top pod -n immich -l app.kubernetes.io/name=machine-learning
bash ~/.agents/skills/_shared/check-alerts.sh
```

Expected: ML working set under 4Gi after the two calls; alerts: Watchdog only. Record the working set.

- [ ] **Step 11 (Implementer): report** — a table with: pod node and image, `id` groups, the device list, rapidocr path, first-call seconds, warm-call seconds, engine counter values before and after the warm call, max GPU MHz, blob file and size, cache size, journal result, working set, alerts. Status `DONE` only if every expected value held.

- [ ] **Step 12 (Coordinator): ledger** — append `Task 2: complete` with the five gate results to the ledger and copy it outside the worktree.

## Task 3: Docs and memory

Docs-only: Codex-exempt. The implementer edits, the coordinator commits and merges with `--teardown`.

**Files:**
- Modify: `docs/HOMELAB_ANALYSIS.md`, `docs/CODEMAPS/apps.md`, `docs/ARCHITECTURE.md`, `docs/HOMELAB_HISTORY.md`
- Modify (outside the repo): `~/.claude/projects/-Users-akhozya-source-code-homelab/memory/project_immich_gpu_transcode.md`, `~/.claude/projects/-Users-akhozya-source-code-homelab/memory/MEMORY.md`

- [ ] **Step 1 (Implementer): ANALYSIS** — the Applications table row `| Immich | OIDC | Photo & video management; GPU-accelerated ML |` becomes `| Immich | OIDC | Photo & video management; Intel QSV transcoding and OpenVINO ML inference on the immich-vm iGPU |`.

- [ ] **Step 2 (Implementer): CODEMAPS** — in `docs/CODEMAPS/apps.md`, the `**immich**` row's last cell gains `; ML inference on the iGPU via the `-openvino` image (2026-09-<day>)` where `<day>` is the Task 1 merge date. Keep the row on one line.

- [ ] **Step 3 (Implementer): ARCHITECTURE** — in the mermaid node for immich-vm, `runs immich-server + ML; dedicated node (NoSchedule taint)` becomes `runs immich-server + ML (OpenVINO on the iGPU); dedicated node (NoSchedule taint)`. Nothing else in the diagram changes.

- [ ] **Step 4 (Implementer): HISTORY** — insert a new entry directly above the `### 2026-09-06 — The NAS scrub stalled immich-vm again…` heading, same format as the entries around it:

```markdown
### 2026-09-<day> — Immich ML inference moves to the immich-vm iGPU (OpenVINO)

Immich ML ran on the CPU since it moved to immich-vm on 2026-09-06. The `-openvino` image puts inference on the VM's Meteor Lake Arc iGPU through ONNX Runtime's OpenVINO execution provider. Commit `<task-1 sha>`; plan `docs/plans/2026-09-06-immich-ml-openvino.md`.

| Change | Detail |
|---|---|
| Image | `immich-machine-learning:v3.1.0-openvino` (Python 3.13, onnxruntime-openvino 1.24.1, intel-opencl-icd 26.22) |
| GPU access | `gpu.intel.com/i915: "1"` via the Intel device plugin; pod `supplementalGroups` 983 (video), 987 (render) |
| Memory limit | 2355Mi → 4Gi (OpenVINO keeps model buffers in system RAM); requests unchanged |
| rapidocr mount path | `python3.11` → `python3.13`, tied to the image variant |
| Gate | `get_available_openvino_device_ids()` = `<list>`; first `/predict` `<N> s` (first-request latency, includes the GPU compile), warm `<M> s`; the ML worker's i915 engine counters rose across the warm call; GPU clock peaked at `<MHz>` MHz; journal clean |
| Follow-ups | trim the memory limit after a week of metrics; FP16 (`MACHINE_LEARNING_OPENVINO_PRECISION`) and a larger CLIP model are separate changes |
```

Fill every `<…>` from the Task 2 report. No placeholder may survive.

- [ ] **Step 5 (Implementer): memory** — in `project_immich_gpu_transcode.md`, the facts-table row `| ML placement | immich-vm, CPU image `v3.1.0`; `-openvino` iGPU inference is an OPEN follow-up …` becomes `| ML placement | immich-vm, `v3.1.0-openvino` on the iGPU since 2026-09-<day> (gate: `get_available_openvino_device_ids()` lists `GPU`, the worker's i915 engine counters rise per call; first `/predict` <N> s first-request latency, warm <M> s; memory limit 4Gi, trim after a week) |`. In `MEMORY.md`, the index line for that file replaces `-openvino OPEN` with `-openvino DONE 2026-09-<day>`. Edit with the Write/Edit tools; nothing to commit.

- [ ] **Step 6 (Implementer): check** — `tail -3` each edited repo file and `grep -n '<' docs/HOMELAB_HISTORY.md | grep -E '<(day|task|list|N|M|MHz)' ` must print nothing. `git status --short` lists exactly the four docs files.

- [ ] **Step 7 (Coordinator): commit, merge, teardown** — `git commit -m 'docs: immich ML inference runs on the immich-vm iGPU via OpenVINO' -- docs/HOMELAB_ANALYSIS.md docs/CODEMAPS/apps.md docs/ARCHITECTURE.md docs/HOMELAB_HISTORY.md`; `bash ~/.agents/skills/_shared/merge-worktree.sh wt-immich-ml-openvino --teardown`. Append `Task 3: complete` to the ledger copy outside the worktree before the teardown.

## Rollback

| Symptom | Action | Check |
|---|---|---|
| Task 2 step 3 lists no `GPU` device | revert the Task 1 commit in a worktree (`git revert <sha>`), merge. The `Recreate` rollout returns to the CPU image, which is still on the node. The `python3.11` mount path comes back with it, consistent with that image | rollout green; image tag `v3.1.0`; `/cache/*/openvino` directories may stay (small) |
| ML pod `OOMKilled` (`lastState.terminated.reason`) | raise the memory limit in a follow-up commit; the node has ~1.3 Gi of limit headroom beyond 4Gi before limits exceed allocatable, and requests are unchanged | pod stable for a day of jobs |
| `GPU HANG` or reset in the VM journal, or immich-server QSV transcodes failing at the same time | stop. No in-guest reboot, no `virsh destroy`. Hand over to the operator: the phase2 carve-out recovers the VM. Revert the Task 1 commit after recovery | journal clean after recovery; ML on the CPU image |
| OCR jobs fail with a read-only filesystem error | the mount path and the image's Python minor disagree (Task 2 step 4 catches this before jobs do); fix the path in git | `mount \| grep rapidocr` shows the emptyDir under the package's own `site-packages` |
| Search or face jobs error on the GPU for one model only | Immich docs: try another model; report to the operator rather than changing models in this plan | — |

## Appendix: Codex review contract

Save as `$SCRATCH/codex-prompt.md` and pass with `--prompt`. Inline the verified facts so Codex re-derives nothing; scope re-reviews to the delta.

```markdown
# Static review contract

You are the opposite-family peer reviewer for the homelab GitOps repo (K3s production, Flux, single environment: a merge to `main` deploys to prod).

## Contract
- STATIC, git-only. You may `cat` the single file you were given and read files under the repo. You may not run kubectl, flux, helm, ansible, tests, or any command that mutates or reaches the cluster. The local gates named below already ran; do not re-run them.
- Return ONE message with a verdict. No follow-up questions, no loop.
- Every finding carries a severity: CRITICAL, HIGH, MEDIUM, LOW, NIT. Give file and line. Say what breaks and how you know. If you cannot ground a claim in the diff or a file you read, do not raise it.
- Check the diff against `.claude/review-invariants.md` (Flux healthCheck GVK, Kyverno anchors, NetworkPolicy AND/OR, PSS Baseline hostPath, external access via central cloudflared, image pins, resource limits on every container, readOnlyRootFilesystem needs /tmp, every ingress has a NetworkPolicy, NetworkPolicy ports are container ports). Grep the target file before asserting a name or GVK.
- Writing rules for comments and docs, flag violations: a comment earns its place only by naming a coupling, constraint, gotcha, or rejected alternative; length follows the constraint; active voice, present tense; one idea per sentence, keeping a condition with what it qualifies; a condition starts with "if"; no idiom or figure of speech; in Markdown, enumerable facts go in a table, not prose. Do not apply a per-sentence word cap.
- Do not raise YAGNI on something the operator explicitly asked for; the ask is recorded in the plan's Design section.

## Context you must not re-derive (verified 2026-09-06)
- Goal: immich-machine-learning runs inference on immich-vm's Intel iGPU (Meteor Lake, 0x7d55, i915) through image tag `v3.1.0-openvino`. The server stays on `v3.1.0`.
- The -openvino image runs Python 3.13.14 (the CPU image 3.11.15), so the rapidocr emptyDir mountPath in the ML postRenderer moves from python3.11 to python3.13 in the same commit.
- The Intel device plugin (`-shared-dev-num=10`) injects /dev/dri for `gpu.intel.com/i915: "1"`; immich-server already uses it with pod supplementalGroups [983, 987] (video, render on the VM). renderD* nodes are 0666 root:render, card* are 0660 root:video.
- Immich picks GPU.0 when `get_available_openvino_device_ids()` lists a GPU, else the OpenVINO CPU plugin (ort.py v3.1.0); the compiled blob goes to /cache/<model>/openvino on the existing `immich-ml-cache` PVC.
- ML memory limit 2355Mi → 4Gi is the operator's decision (CPU-path 7d peak ≈ 1.44 GiB; node limits 8525Mi → ~10.3Gi of 11.6Gi allocatable; requests unchanged).
- Renovate docker versioning keeps the `-openvino` suffix on bumps (docs.renovatebot.com/modules/versioning/docker). Kyverno rejects only `latest`/untagged.
- ML Deployment strategy is Recreate (postRenderer). Rollback is one reverted commit.
- `helm template` chart 0.13.1 with the intended values rendered image, resources and supplementalGroups onto the ML Deployment on 2026-09-06.

## What to return
1. Verdict line: SHIP, or FIX (with the highest severity).
2. Findings, most severe first, each: severity, file:line, what breaks, evidence.
3. Writing-rule violations as LOW or NIT.
```
