# Immich → NAS (Intel QSV) migration — VALIDATED plan

Status: v6 (research + spikes + 2 Codex rounds folded). Date 2026-07-07.
Decision (user): run Immich on the NAS via docker-compose (already installed, running, empty). Goal: HW transcode + HDR + no crash, existing library/metadata preserved.

## 0. Why NAS (settled, validated)
NAS = Intel Core Ultra 5 125H (Meteor Lake, Xe-LPG i915, host-level GPU, no VM). QSV = Immich's first-class Intel path; **HDR→SDR tonemapping works on Intel with HEVC-10bit decode** (MTL qualifies; kernel 6.12-zettos clears the old i915 lockup range 5.18–6.1.3). AMD nodes can't (Immich OpenCL tonemap ships Intel-ICD-only). k3s-on-NAS = validated NOT viable. W1-config-fix (HDR passthrough) = the GitOps-preserving fallback if this stalls.

## 1. Validated evidence base (research wcgr9tnum + live spikes)
- Immich **v3.0.1**. Source k8s = `immich-server:v3.0.1`, **pgvector** backend, **Postgres 18** (CNPG 18.4). Target = same Immich version + a supported backend.
- v3 **REMOVED pgvecto.rs**. Backends now: pgvector or VectorChord. Official DB image bundles both + auto-detects → can restore a pgvector dump.
- Immich postgres images: majors **14/15/16/17 only, NO PG18** (ghcr-verified). Source PG18 → PG18→PG17 downgrade restore (rehearse).
- Media NOT in DB dump — copy `UPLOAD_LOCATION/{library,upload,profile}` (~300GB), keep SAME path. thumbs/encoded-video regenerate.
- ML `release-openvino` correct (user set; may fall back to CPU — user pinned `MACHINE_LEARNING_DEVICE=cpu`). AV1 hw ENCODE on 125H iGPU UNCONFIRMED — verify; H264/HEVC10 certain.
- Live: NAS containerd appliance, GPU host i915, user Immich FRESH (library 0B), NOT yet reachable on :2283 (verify), `akhozya` not in docker group (blocks live checks; awaiting `sudo usermod -aG docker akhozya`).

## 2. Target compose fixes (your compose ~90% right; 4 changes)
1. **DB image** → **`ghcr.io/immich-app/postgres:17-vectorchord0.4.3-pgvector0.8.0-pgvectors0.2.1`** — a CANDIDATE (PG17 + bundled pgvector to match source backend). **Whether it accepts the PG18 dump is rehearsal-gated (§3), not assumed.** NAS postgres dir empty → wipe + re-init at PG17.
2. **Pin** `immich-server:release`→`:v3.0.1`; ML → versioned openvino tag (not floating). Redis: **record the resolved valkey image/version and confirm it against Immich v3.0.1's official compose support matrix** (pin ≠ compat).
3. **Set `DB_VECTOR_EXTENSION=pgvector`** (match source → embeddings restore, no re-embed).
4. **QSV**: keep `/dev/dri` + `security_opt: label:disable`; set Immich admin-UI transcode accel=**qsv**, hw-decode ON, tonemap ON.
Config notes: (a) compose points postgres+model-cache at **`/zettos/pool/2` (NVMe) which is NOT a mount** → currently root overlay (111G/83G-free); confirm/redirect to real fast storage or pool/1 before load. (b) `shared_buffers=4GB`/`shm 2gb` vs actual **30Gi RAM** (comment "96GB" wrong) → OK. (c) creds `postgres/postgres` LAN-only — harden or accept.

## 3. DB migration — VALIDATED on real data 2026-07-07 ✅ (Rancher rehearsal)
PROVEN: dumped real prod DB (PG18.4, 214MB, 5783 assets/387 people) → restored into PG17 target → **rc=0, ZERO errors, counts exact, Immich v3.0.1 serves it (ping 200)**. pgvector 0.8.2→0.8.0 fine. No re-embed.
- **Dump method** (exec-stream drops at 214MB → websocket 1006): `kubectl exec <primary> -c postgres -- sh -c 'pg_dump --dbname=immich --clean --if-exists --no-owner --no-privileges | gzip -c > /var/lib/postgresql/data/immich-dump.sql.gz'` then `kubectl cp <ns>/<pod>:/…/immich-dump.sql.gz ./dump.gz -c postgres`, then `rm` the pod file. (pg_dump, NOT pg_dumpall — shared CNPG cluster.)
- **Restore**: `zcat dump.gz | docker exec -i immich_postgres psql -U postgres -d immich` into the EMPTY container-created DB (dump has --clean/--if-exists).
- **Post-restore drift-fix (KNOWN + trivial)**: `immich-admin schema-check` flags minor drift on `geodata_places` (4 missing indexes + PK) + stale `user_search` function — photos/albums/faces UNAFFECTED. Apply Immich's auto-generated fix SQL (DROP FUNCTION user_search; 4× CREATE INDEX on geodata_places; ADD PK). One-shot, non-urgent.

### (original strategy notes)
Both ends = Immich v3.0.1 + pgvector → schema match, embeddings transfer. Only gap = PG18→PG17 (a downgrade with NO official support → MUST rehearse the EXACT prod command).
1. **REHEARSE (disposable target), using Immich's documented backup command + `--clean --if-exists` restore flags** (verify against live docs, not memory): `pg_dump` source → restore into a throwaway `postgres:17-…pgvector…` → boot immich v3.0.1 → confirm login + albums/faces/shares + **smart-search returns results**. GREEN gate before any cutover.
2. **Real run**: restore into a **freshly recreated EMPTY DB / data dir** (do NOT boot Immich first, then restore — a full-schema dump into an Immich-initialized DB corrupts/mixes state; use clean-empty + `--clean/--if-exists`). Boot Immich AFTER restore (it runs any pending migrations).
3. **Fallback (only if rehearsal red)** = target on **VectorChord** + **regenerate Smart Search + Face Detection** (re-embed). This is a SEPARATE path needing its OWN rehearsal (face re-detection can create duplicate/unnamed faces — validate). The "data-only load excluding embedding tables" idea is NOT the fallback (FK/trigger/sequence/migration-table ordering traps) unless separately runbooked + rehearsed.

## 4. Media migration
Preflight: **sample the source DB for actual stored asset/profile path prefixes** (don't trust chart defaults) → reproduce the container mount so the in-DB prefix stays valid (host path may differ; DB prefix must not). `rsync` library (~300GB, size TBD) → NAS UPLOAD_LOCATION preserving `{library,upload,profile}` + ownership. Check NAS backup for a pre-seed (rsync-delta). Final delta under the §8 quiesce window. Verify count+hash. Skip thumbs/encoded-video (regenerate, throttled §8).

## 5. QSV / HDR — VALIDATED ON-BOX 2026-07-07 ✅
Ran throwaway `docker run` on `immich-server:release` (ffmpeg 7.1.4-Jellyfin), `/dev/dri`+`--security-opt label:disable`. ALL PASSED: H264 QSV 14.3×; HEVC **10-bit** QSV 6.6×; **HDR→SDR `vpp_qsv=tonemap=1` 7.36×** (the AMD-impossible payoff — CONFIRMED); **AV1 QSV 11.7×** (was research-unconfirmed → now confirmed). GPU premise fully proven. Residual: a real HDR *file* end-to-end through Immich's own pipeline (nice-to-have; synthetic p010 tonemap already succeeded).

## 6. External access + OIDC
Keep SAME public hostname → Authentik OIDC redirect URIs + bookmarks unchanged. Re-point Cloudflare Tunnel → NAS host:2283; update SOPS `cloudflared.yaml` + egress ipBlock (current only reaches in-cluster ns). Port change → update Authentik provider. Mobile re-login (same host = smooth).

## 7. Backup (NAS primary → node) — target CONFIRMED before cutover
No offsite (accepted posture). Back up NAS Immich to a **confirmed 2nd box**: **W2 `/mnt/extra-storage`** (dedicated disk, freed post-rebuilderd) — do NOT depend on freeing the old W1 PV (circular: can't back up TO the disk that hosts the thing being decommissioned). VERIFY W2 free space ≥ library size FIRST. Mechanism: NAS-side nightly cron — `pg_dump` + `rsync --delete` library delta → SSH (:65300) to a W2 dir. **HARD GATE**: first full backup + restore-test BEFORE the §8 tunnel flip / before uploads resume.

## 8. Cutover + rollback (quiesce-fenced)
1. Fix compose (§2), re-init PG17 DB, boot fresh Immich, verify QSV (§5). 2. Rehearse DB restore (§3-1) — GREEN gate.
3. **QUIESCE source** (not just `flux suspend` — that stops reconciliation, NOT the pod): put Immich in maintenance / **block ingress + disable uploads**, then scale the workload down, **wait for background jobs + Redis queues to drain**. `flux suspend helmrelease immich` so Flux won't fight the scale-down.
4. Final `pg_dump` → restore into fresh-empty NAS DB (§3-2) + library delta (§4).
5. First NAS→W2 backup + restore-test (§7).
6. Verify on NAS (temp URL): photos, HW-transcoded video, HDR, OIDC login, albums/faces/shares, smart-search.
7. Flip Cloudflare tunnel/DNS → NAS. **Keep uploads DISABLED until acceptance** (enforceable rollback control — NOT "keep the window short").
8. Accept → enable uploads. Throttle bulk regeneration (thumbs/transcodes/embeddings) via Immich job concurrency limits, or delay until after backup + acceptance (avoid hammering the NAS).
9. Soak; then decommission k8s Immich (remove `apps/immich/**` from Flux, free W1 300Gi PV, DB user, backup CronJob, ServiceMonitor, NetworkPolicy; update docs). Keep last k8s backup archived.
Rollback: before flip = un-suspend + scale up k8s Immich (untouched). After flip but uploads-disabled = re-point tunnel back, no NAS writes lost. True PONR = deleting W1 PV/DB after soak.

## 9. Open on-box verifications (need docker — awaiting `usermod -aG docker akhozya`)
QSV+HDR proof; Immich health + version; DB extensions; pool/2 reality (where postgres writes); library actual size; W2 backup free space; PG18→17 restore rehearsal; source stored-path-prefix sample; resolved valkey version.

## 10. Ranked risks + mitigations
- **R1 CRITICAL — PG18→PG17 restore** (no PG18 image): rehearse EXACT prod command on disposable target; GREEN before flip. Red → VectorChord+re-embed fallback (own rehearsal). Never flip on an unrehearsed restore.
- **R2 CRITICAL — quiesce**: `flux suspend` ≠ stopped Immich; block uploads + drain jobs/queues before the final dump or it races live writes.
- **R3 HIGH — image pins**: `:v3.0.1` + versioned openvino; validate valkey version vs v3 matrix; disable zettOS auto-update.
- **R4 HIGH — media path**: preflight the in-DB path prefix; reproduce the mount prefix; verify count+hash.
- **R5 HIGH — rollback after flip**: uploads stay disabled until acceptance (enforceable), else post-flip NAS writes are unrecoverable to k8s.
- **R6 MED — QSV tonemap on-box** (2-1 evidence): verify a real HDR clip before trusting; passthrough fallback.
- **R7 MED — OpenVINO iGPU→CPU fallback + RAM**: validate a Smart Search job; CPU acceptable.
- **R8 MED — postgres on non-existent NVMe pool/2** → lands on root overlay; confirm disk+capacity.
- **R9 MED — backup target**: confirm W2 free space before cutover; don't rely on freeing W1 PV.
- **R10 MED — regen load**: throttle post-cutover thumbs/transcode/embedding jobs.

## 11. Gate
Codex STATIC review: round 1 (10 findings) + round 2 (9 findings) folded → v6. Per-change Codex review at each commit boundary during execution (cloudflared edit, decommission diff).
