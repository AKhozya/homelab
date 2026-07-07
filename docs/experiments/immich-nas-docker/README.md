# Immich on NAS (Intel QSV) — docker-compose experiment (Path A)

Validated 2026-07-07. Reference/fallback for running Immich on the ZL-NAS (Intel Core Ultra 5 125H, Meteor Lake QSV) via docker-compose, OUTSIDE the k8s cluster.

**Status:** deployed empty + fully validated on-box, then torn down (containers only; library + `pgdata` volume kept on NAS) while Path B (VM + k3s node + GPU passthrough, keeps GitOps) is investigated. See memory `project_immich_gpu_transcode` for both paths + resume state.

## Why this exists
AMD nodes (W1/W2) can't do Immich HW transcode/HDR — two open Immich bugs (#27895 NV12, #28932 OpenCL-tonemap; the container ships only Intel's OpenCL ICD). Intel QSV on the NAS fixes both.

## Proven on-box (not assumptions)
- QSV H264 / HEVC-10bit / **HDR tonemap** (`vpp_qsv=tonemap`) / AV1 encode — all pass on the NAS iGPU.
- Immich v3.0.1 boots on the PG17+pgvector image; QSV works through the real `immich_server`.
- **DB migration rehearsed with real data**: PG18 source dump → PG17 restore = 0 errors, 5783 assets / 387 people intact, no re-embed (source + target both pgvector). Post-restore run Immich's schema-drift fix SQL (minor `geodata_places` indexes + drop `user_search`).

## Deploy
1. `cp .env.example .env`, set `DB_PASSWORD`.
2. `docker compose up -d` (all data on pool/1; postgres = named volume `pgdata`).
3. QSV = set Immich admin UI transcode accel to `qsv`, hw-decode on, tonemap on.

## Key config decisions
- DB image `postgres:17-vectorchord0.4.3-pgvector0.8.0` — PG17 is the newest Immich publishes (source is PG18 → one-major downgrade restore, rehearsed clean); pgvector bundled to match source backend.
- `DB_VECTOR_EXTENSION=pgvector` — matches k8s source so embeddings/faces restore intact.
- ML `v3.0.1-openvino` (Intel; the appstore default `armnn` is ARM = wrong).
- QSV via `/dev/dri` + `security_opt: label:disable` (no privileged). immich runs as root → file ownership is a non-issue.
- Dropped Immich's example custom postgres `command:` (it forces `shared_preload_libraries=vectors.so` = the REMOVED pgvecto.rs; the official image self-configures).

## Migration (cutover) outline
Quiesce k8s Immich → trigger fresh k8s backup (library tar → NAS) + `kubectl` DB dump → restore DB + drift-fix SQL + extract library → Cloudflare tunnel + Authentik OIDC → backup to W2 → soak → decommission k8s immich. Library pre-seed = extract the k8s backup CronJob's `immich-library.tar` locally on the NAS (no cross-node transfer). Actual library ~65GB.

Not GitOps-managed (deliberate, Path A trade-off). Path B keeps GitOps if VM GPU-passthrough works.
