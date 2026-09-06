# Immich ML follow-ups: FP16 and a larger CLIP model — research

Researched 2026-09-07 against the live cluster and Immich v3.1.0 source. Both follow-ups were
deferred by `docs/plans/2026-09-06-immich-ml-openvino.md` as "separate changes". They are not
independent: FP16 is the thing that would make a larger model fit.

Tiers: ✅ verified against the live system or primary source · 🟡 single-source · ⚠️ extrapolation.

## Headline

| Question | Answer |
|---|---|
| Should FP16 go on now? | **No.** Open upstream bug breaks OCR, which is live here. |
| Should the CLIP model change now? | **Yes, worth doing — `ViT-B-16-SigLIP2__webli`** — but it needs the memory limit at ~6Gi first, it wipes all 5,874 embeddings, and the re-index is manual. Measure before committing to the limit (§6). |
| Should the 4Gi limit be trimmed, as the plan said? | **No — that follow-up is wrong.** Measured 2,435 Mi with both CLIP towers loaded. Trimming blocks any model upgrade. |

## 1. FP16 (`MACHINE_LEARNING_OPENVINO_PRECISION`)

### Mechanism ✅

`machine-learning/immich_ml/config.py` sets `env_prefix="MACHINE_LEARNING_"` and the field
`openvino_precision: ModelPrecision = ModelPrecision.FP32`, so the env var name in the plan is
right. `schemas.py` defines `ModelPrecision` as exactly `FP16` and `FP32`. `sessions/ort.py:154`
passes it into the OpenVINO provider options as `"precision"`, alongside `device_type` and the
`cache_dir` on `/cache`.

**One global setting, not per-service.** `ort.py` reads a single `settings.openvino_precision`
for every model the container loads — CLIP, facial recognition and OCR alike.

### The blocker ✅

Upstream issue [#27941 "OCR fails with FP16 on OpenVINO"](https://github.com/immich-app/immich/issues/27941)
is **open**, labelled `machine-learning`, with no linked fix and no cross-referenced PR. FP16
produces `inf` values, `boxScore` arrives null, and the OCR job dies on a not-null constraint:

```
PostgresError: null value in column "boxScore" of relation "asset_ocr" violates not-null constraint
```

The reporter asks for per-service precision (FP32 for OCR, FP16 elsewhere) precisely because the
setting is global. That has not shipped.

### Why it bites this cluster ✅

OCR is live and has produced real data: **8,025 `asset_ocr` rows across 1,084 assets**. The
Immich config overrides the OCR model to `ESLAV__PP-OCRv5_mobile` (East Slavic), a deliberate
non-default choice, and job concurrency for OCR is set to 2. This is not an idle feature.

**Verdict: FP16 is blocked while OCR is enabled.** It unblocks when upstream ships per-service
precision, or if you turn OCR off.

### What FP16 would buy 🟡

PR [#23576](https://github.com/immich-app/immich/pull/23576), which added the setting, says FP16
"can substantially lower memory usage and processing time for a very slight effect on quality".
No number is given. That memory saving is the lever that would make a bigger model fit — see §3.

## 2. Changing the CLIP model — the mechanics come first

### Any model change wipes every embedding ✅

`server/src/services/smart-info.service.ts:44-60`:

```ts
const modelChange = oldConfig && oldConfig.machineLearning.clip.modelName !== newConfig...modelName;
const isDimSizeChange = dbDimSize !== dimSize;
if (!modelChange && !isDimSizeChange) { return; }
if (isDimSizeChange) { await this.databaseRepository.setDimensionSize(dimSize); }
else { await this.databaseRepository.deleteAllSearchEmbeddings(); }
```

`setDimensionSize` (`database.repository.ts:307-325`) runs `delete from smart_search` inside a
transaction, then rebuilds the `dim_size_constraint`. So **both branches delete every embedding** —
a same-dimension model change is not cheaper than a different-dimension one.

### Immich does not re-index for you ✅

Line 62 of the same file, immediately after the delete:

```ts
// TODO: A job to reindex all assets should be scheduled, though user
```

Nothing queues the re-index. **Smart search returns nothing from the moment the model changes
until someone manually runs the Smart Search job** from the admin UI. On this library that is
5,874 assets through the visual encoder on the iGPU.

### Current state ✅

| Fact | Value |
|---|---|
| Configured CLIP model | `ViT-B-32__openai` — the Immich default (`server/src/config.ts:304`). The live `machineLearning` config carries only an OCR override, no `clip` key |
| Assets (not deleted) | 5,881 |
| `smart_search` embeddings | 5,874 |
| Embedding dimension | 512 |
| `smart_search` table size | 32 MB, indexes `smart_search_pkey` + `clip_index` |
| Faces indexed | 4,146 (`face_search`) — unaffected by a CLIP change |

## 3. Memory is the real constraint, and the plan under-measured it

### Measured on the live pod ✅

| State | Working set |
|---|---|
| Idle, no model loaded | 237 Mi |
| CLIP **textual** tower loaded | 842–850 Mi |
| CLIP **textual + visual** loaded | **2,435 Mi** |

The plan's Task 2 recorded 237 Mi, and my first recap reported 842 Mi. Both were wrong as a
picture of steady state: 237 Mi was taken after the 300 s idle TTL unloaded the model, and 842 Mi
is the textual tower alone. A search-time pod carries both towers, and the Smart Search job runs
the visual tower — the larger half (336 MB of ONNX on disk against 492 MB textual, but far more
resident once OpenVINO compiles it for the GPU).

**This corrects the plan's stated follow-up.** 2,435 Mi is *above* the CPU path's 1.44 GiB 7-day
peak, not below it, which is exactly the "expect higher RAM usage" the Immich docs warn about for
OpenVINO. The 4Gi raise was justified. Trimming it would leave ~1.6 GiB of headroom and foreclose
any model upgrade.

### Scaling to other models ⚠️

Do **not** size a pod from Immich's docs "Memory (MiB)" column. It disagrees with the real download
size in rank: the docs call `ViT-L-16-SigLIP2-256__webli` (2,830 MiB) *smaller* than
`ViT-B-16-SigLIP2__webli` (3,038 MiB), while on disk the L model is 3,396 MiB against the B model's
1,464 MiB — because the L model ships a 1,000 MiB token-embedding table plus ~80 external weight
tensors alongside a 1 MiB `model.onnx`.

The estimates in §4 instead scale the real `textual/` + `visual/` download size (excluding the
`rknpu/` Rockchip files Immich does not fetch) by the one ratio measured on this pod:
583 MiB on disk → 2,198 Mi attributable resident = **3.77×**. That is an extrapolation from a single
model on the OpenVINO iGPU path, where compiled GPU buffers are shmem charged to the container
cgroup. Treat it as an order of magnitude, and measure before committing to a limit — §6.

### Node headroom ✅

| Fact | Value |
|---|---|
| `immich-vm` allocatable memory | 12,133,872 Ki = **11,849 Mi** |
| Sum of memory *limits* on the node | **10,266 Mi** (includes ML's 4096) |
| Sum of memory *requests* | 1,439 Mi |
| Actual node usage right now | 4,095 Mi (34%) |

Requests are what the scheduler enforces, and they are tiny, so a bigger limit will still schedule.
Limits summing past allocatable is overcommit, not a hard block — but it is the thing that turns a
simultaneous peak into an OOM. Raising ML from 4Gi to 6Gi, which is what §4 recommends, puts
committed limits at ~12,314 Mi against 11,849 Mi allocatable — about 104%.

## 4. Candidate models — you search in English AND Russian

Immich's docs are explicit for this case: `xlm` and `siglip2` models "understand search text
regardless of the current language setting" and are "recommended for mixed language search, where
the same user might search in different languages at different times". `nllb` models expect the
query to match a per-user language setting, so they are **out** for mixed EN/RU despite topping the
Ukrainian table. ✅

### Sizing, corrected

The docs' "Memory (MiB)" column and the real download size disagree in *rank*, so the docs column
cannot be used to size a pod. The `ViT-L-16-SigLIP2` models publish `textual/model.onnx` at 1 MiB
but ship the weights beside it as external data — a **1,000 MiB `text.token_embedding.weight`**
plus ~80 external MatMul tensors. Counting only `*.onnx` misses ~2 GiB. ✅

Estimates below use the real `textual/` + `visual/` download size (excluding the `rknpu/` Rockchip
variants Immich does not fetch) and the measured ratio from the one model we have on the live pod:
583 MiB on disk → 2,198 Mi attributable resident = **3.77×**. ⚠️ Still an extrapolation from a
single model, and the docs/disk rank disagreement is a warning that it may not transfer.

| Model | RU | EN | Disk (MiB) | Est. pod | vs 4Gi | Verdict |
|---|---|---|---|---|---|---|
| `ViT-B-32__openai` *(current)* | not benchmarked | 69.9% | 583 | 2,435 Mi *(measured)* | fits | English-only; collapses on Cyrillic |
| **`ViT-B-16-SigLIP2__webli`** | **80.9%** | **84.9%** | 1,464 | ~5,757 Mi (5.6 GiB) | needs ~6Gi | **best mixed EN/RU that could fit** |
| `ViT-B-32-SigLIP2-256__webli` | 78.1% | 82.3% | 1,471 | ~5,783 Mi | needs ~6Gi | same memory, worse both languages; only wins on latency (3.3 ms) |
| `XLM-Roberta-Base-ViT-B-32__laion5b` | 76.4% | 76.9% | 1,418 | ~5,583 Mi | needs ~6Gi | worse than the above on both languages |
| `ViT-L-16-SigLIP2-256__webli` | 83.1% | 85.0% | 3,396 | ~13,040 Mi (12.7 GiB) | **exceeds the node** | docs claim 2,830 MiB — do not believe it |
| `ViT-L-16-SigLIP2-384__webli` | 83.7% | 85.5% | 3,398 | ~13,048 Mi | **exceeds the node** | same |

### The recommendation

**`ViT-B-16-SigLIP2__webli`.** Against today's model it is +15 points English (69.9 → 84.9) and
takes Russian from unusable to 80.9%. English-only models score ~20% on Russian in this benchmark
(`ViT-B-16-SigLIP__webli`: 81.9% EN, 20.4% RU), and the current model is a weaker English-only CLIP
that Immich did not even benchmark for Russian — so treat today's Russian search as broken. 🟡

Cost: the ML memory limit goes 4Gi → ~6Gi. Committed limits on `immich-vm` then reach ~12,314 Mi
against 11,849 Mi allocatable — about 104% overcommit. Requests stay at 1,439 Mi so scheduling is
unaffected, and the node is actually using 4,095 Mi, but a simultaneous peak is what overcommit
turns into an OOM.

### This is where FP16 would have paid for itself

FP16 is the setting that would roughly halve those weights and plausibly keep
`ViT-B-16-SigLIP2__webli` inside the existing 4Gi. It is blocked by the open OCR bug in §1. That is
the coupling the plan missed when it listed the two follow-ups as independent.

## 5. The two open questions, and where they stand

| Question | Status |
|---|---|
| What language do you type search queries in? | **Answered 2026-09-07: English and Russian, mixed.** That rules the `nllb` family out (it expects the query to match a per-user language setting) and points at `siglip2`, which is what §4 is built on |
| Is OCR staying on? | **Open.** It gates FP16 entirely (§1), and FP16 is the lever that would bring a multilingual model back inside the current 4Gi limit. If OCR were turned off, the whole memory problem in §4 changes shape |

## 6. If the model change goes ahead — safe order

The memory estimate is the weak link, and there is a way to settle it before committing to
anything. Immich's ML service downloads and loads whatever `modelName` a `/predict` call names, so
the candidate can be measured **without touching Immich's config**, which means without deleting a
single embedding.

| Step | Why this order |
|---|---|
| 1. Raise the ML memory limit 4Gi → 6Gi in git, through the normal review loop | Do this *first*. Probing at today's 4Gi would OOM-kill the ML pod if the estimate is right |
| 2. Probe-load the candidate: one `/predict` with `modelName: ViT-B-16-SigLIP2__webli`, visual and textual, then `kubectl top` after ~45 s | Measures the real footprint. Immich's config is untouched, so search keeps working on the current embeddings throughout. Costs a ~1.5 GiB download onto the 10Gi cache PVC (828M used today) |
| 3. If it fits: change the model in the Immich **admin UI** | `machineLearning.clip.modelName` lives in the DB `system_metadata`, not in `release.yaml`. This is one of the few Immich settings GitOps does not own |
| 4. Expect search to return nothing immediately | Every embedding is deleted the moment the config saves |
| 5. Manually queue Smart Search over all assets | Nothing does it for you (§2); 5,874 assets through the visual encoder on the iGPU |
| 6. Watch `kubectl top` during the job | Smart Search job concurrency defaults to 2, so two visual encoders may be resident at once — the §4 estimates are for one |
| 7. If it does not fit: revert the limit commit | Nothing else has changed, so there is nothing else to undo |

Take a Postgres backup before step 3. The daily CNPG logical backup covers it, but a model trial is
not cheaply reversible without one — reverting the model means another full re-index.

## Sources

| Claim | Source |
|---|---|
| env var name, precision enum, global scope | `immich_ml/config.py`, `schemas.py`, `sessions/ort.py:142-156` at tag v3.1.0 |
| FP16 breaks OCR, open, unfixed | github.com/immich-app/immich/issues/27941 (state=open, no linked fix, checked 2026-09-07) |
| FP16 lowers memory "substantially" | github.com/immich-app/immich/pull/23576 |
| model change deletes embeddings, no auto re-index | `server/src/services/smart-info.service.ts:44-62`, `server/src/repositories/database.repository.ts:307-325` at v3.1.0 |
| default CLIP model | `server/src/config.ts:304` |
| recall / memory / latency per model per language | `docs/docs/features/searching.md`, immich-app/immich `main` |
| OpenVINO uses more RAM than CPU | docs.immich.app/features/ml-hardware-acceleration |
| live counts, config, node capacity, working sets | this cluster, 2026-09-07 |
