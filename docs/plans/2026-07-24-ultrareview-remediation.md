# Ultrareview 2026-07-24 — Remediation Plan

Source review: 11 lens finders over `main` @ `32bf3d0c` → dedup vs accepted decisions → per-finding adversarial refute + second impact pass on high/critical → completeness critic + gap finders → Codex `xhigh` static verification (**48 agree / 0 disagree / 7 severity-adjust**, +3 Codex finds). 58 findings survived, **0 refuted**.

This plan was itself Codex-reviewed (verdict REVISE) and revised; the accepted corrections are recorded in "Plan review outcomes" at the end.

**Already shipped:** H3 CouchDB open-internet exposure — Cloudflare Access Service Auth on `couchdb.h0melab.work`, verified live (tokenless edge → `HTTP/2 403` + `cf-access-aud`; iPhone-on-cellular sync confirmed). Recipe + gotchas in agent memory.

## Execution contract

- **One batch = one worktree = one merge.** `git worktree add .claude/worktrees/<batch> -b wt-<batch>`.
- **Gate per batch:** self-review vs `.claude/review-invariants.md` → `/homelab-yaml-validate` → **Codex STATIC git-only review** (allowed: `git diff/show/log` + file reads; FORBIDDEN: run-anything; demand a one-message verdict) → process via `superpowers:receiving-code-review` → re-review delta-scoped while CRITICAL/HIGH, **cap 3 rounds**. Docs-only commits are exempt.
- **Ship:** merge → `main` → push → `fr` → verify → `worktree-cleanup`. CI watch for manifest paths only, never markdown-only.
- **Batches are dependency-ordered, not severity-ordered.** Rationale per batch below. Batch 0 and 1 are prerequisites; 2→8 may be resequenced if a batch blocks.
- **Do not re-litigate** the 14 accepted decisions (no-PITR, no-offsite, bot RBAC, naked provisioning Jobs, chart-default image pins, rustdesk 1.1.15, single CP, no `@sha256` pins…). Recorded in memory and `.claude/review-invariants.md`.
- **Never commit a command you have not run.** Every runbook/CronJob snippet touched here gets executed (or `--dry-run=server`'d) before commit.
- **Re-derive every line number before editing.** Findings were verified at `32bf3d0c`; ten Renovate PRs merged immediately afterwards (loki 18.5.4, monitoring stack, flux2 action v2.9.3, n8n, paperless, home-assistant, mealie, kube-state-metrics). Line references below may have drifted, and a bump may have already fixed or moved an item — grep for the described code, do not trust the `:NNN`. Confirm each finding still reproduces before fixing it.

## Assumptions

✅ verified · 🟡 single-source · ⚠️ validate before building.

| # | Assumption | Tier | Status |
|---|---|---|---|
| A1 | Findings' file:line accurate at `32bf3d0c` | ✅ | Two independent verifiers + Codex |
| A2 | Kyverno require-resource-limits/seccomp/labels are **Enforce** → a bare `kubectl run` is denied | ✅ | 2026-07-03 promotion; drives B1-2 |
| A3 | couchbackup exit≠0 = fatal; `:t`/`:d` log pairing proves batch completion (`:changes_complete` proves only spooling) | ✅ | Upstream IBM/couchbackup README |
| A4 | `local-path` reclaimPolicy is `Delete` | ✅ | `kubectl get storageclass` |
| A5 | Branch protection unavailable (private repo, Free plan) → CI cannot gate `main` | ✅ | `gh api …/branches/main/protection` → 403 |
| A6 | Flux supports `healthCheckExprs` | ✅ | flux v2.9.3, kustomize-controller v1.9.1 |
| A7 | No in-cluster client uses the Alertmanager **ingress hostname** (VMAlert posts to the Service) | ✅ | `rg am.h0melab.work` → only ingress/cert/externalUrl + a homepage browser href |
| A8 | `prune: disabled` on 12 PVCs is inert until a prune event | ⚠️ | **Spike:** `flux diff kustomization apps` shows no churn |
| A9 | VMSingle actually exposes `status.updateStatus` with `operational`/`failed` values | ⚠️ | **Spike before B4-3.** A6 proves only that Flux supports the field |
| A10 | The 4 dead uptime-kuma egress ports have no live monitor depending on them | ❌ **REFUTED for 5984** | Spike done 2026-07-25 — dumped the monitor table from uptime-kuma's MariaDB backend (it does **not** use the bundled sqlite; `kuma.db` is a 0-byte stub). `5984` is actively probed against `couchdb-svc-couchdb`, so dropping it would have broken a live monitor. 6446/8428/9090 confirmed unprobed and removed (VMSingle is on 8429, Alertmanager on 9093). 3001 and 3005 are also unprobed but left in place as plausibly-returning. |
| A11 | Every Helm-generated hostPath workload in `databases`/`backup-replication` carries a stable, scopeable label | ⚠️ **Spike done, B6-2 NOT shipped** | See "A11 spike result" below. |
| A12 | **No forward-auth exists anywhere in the repo today** — Grafana is native OIDC, so B5 introduces the first consumer (Authentik proxy provider + outpost + Middleware, not just an annotation) | ✅ | `rg forwardAuth` → zero hits |

**Deliberate cut corners:** no PITR/offsite (decided); NAS SMART/RAID stays unmonitored (not readable without sudo — record as accepted risk, do not build an agent); `ephemeralContainers` VP clauses get a comment fix, not a companion policy.

---

## Batch 0 — Urgent + the one decision that shapes everything  *(small, fast)*

Ships first because a credential is **already exposed**, and because B0-2 determines the shape of Batch 1.

| ID | Was | Item | Fix |
|---|---|---|---|
| B0-1 | B3-3 | **Telegram bot token printed to pod logs → Loki** — `apps/pricebuddy/apprise-configmap.yaml:26` (confirmed live in the `apprise-init` container log) | Delete the `cat`. **DECIDED 2026-07-24: do NOT rotate.** Exposure is internal-only and the bot is dedicated: `pricebuddy-telegram` is a separate secret from claude-telegram, so the blast radius is the price-alert chat, not the ops channel. Readers are limited to Grafana/Loki (anonymous off, basic off, login form disabled, Authentik passkey-only OIDC) and anyone with `kubectl logs`. Note Loki retention is 720h, so existing lines carry the token for ~30 days after the fix |
| B0-2 | B5-1 | **CI is not a gate.** Branch protection is unavailable (A5) and Flux syncs `main` every 5 min regardless of the verdict, so a validate-red commit reaches prod | **DECIDED 2026-07-24: option (b) — remove the gating claim.** Amend `AGENTS.md:27` so CI is described as pre-merge validation, not the gate-of-record; the real gate is the per-batch Codex static review + local validation. Do **not** build the `ci-green` promotion ref or repoint `gotk-sync.yaml`. Consequence to state plainly in AGENTS.md: nothing mechanically prevents a validate-red commit from reaching prod within ~5 min |
| B0-3 | B1-8 | DR secrets tarball not gitignored — `.gitignore:42` | Add `.backup/*.tar.gz.gpg` |

---

## Batch 1 — CI validation coverage  *(precedes the fixes it must validate)*

`clusters/` and `immich-vm-heal.sh` are **not covered by CI today**, so later batches would ship changes to them unvalidated.

| ID | Was | Item | Fix |
|---|---|---|---|
| B1-1 | B5-3 | kubeconform matrix omits `clusters/` → Flux Kustomization CRs unvalidated (needed before B4-3 edits `clusters/monitoring.yaml`) | Add `clusters` to the matrix |
| B1-2 | B5-4 | shellcheck scans only `scripts/` + `docs/scripts/`, missing `immich-vm-heal.sh` (needed before B4-4 edits it) | Repo-wide `find` sweep; drop the pre-commit path anchor |
| B1-3 | B5-5 | sops-check gates by **filename only** — a plaintext `kind: Secret` in an off-pattern file passes CI | Content pass: any yaml with `^kind: Secret` must carry `ENC[AES256_GCM` |
| B1-4 | B5-7 | CI kustomize v5.5.0 vs controller-embedded v5.8.1 render skew | Bump `KUSTOMIZE_VERSION` to v5.8.1 |
| B1-5 | B5-6 | gitleaks never runs on markdown-only pushes | B0-2 resolved to (b), so: **split gitleaks into its own tiny workflow** without `paths-ignore` (checkout + scan ≈ 15s), keeping the heavy jobs' doc-skip intact |

---

## Batch 2 — Backup integrity + data-loss guards  *(the silent-loss paths)*

| ID | Was | Item | Fix |
|---|---|---|---|
| B2-1 | B1-1 **HIGH** | couchbackup exit swallowed (`\|\| true`, `:169-174`); success = any `^\[` line → truncated dump gets a valid sha256, passes replication validation, advances `lastSuccessfulTime`, no alert fires | Require **exit 0 AND** every `:t batchN` paired with `:d batchN` in `--log` (**AND, not OR** — a fatal non-zero must never pass); `2> ${DB}.stderr` so stderr stops contaminating the data stream; print stderr+log and `exit 1` **before** packaging. The in-file "may return non-zero on success" comment is unverified folklore — if genuine flakes appear, they surface as loud failures, which is the point |
| B2-2 | B1-3 | "Verify NAS" ends `\|\| echo` → **cannot fail**, then Step 4 `rm -rf`s all source backups unconditionally — `backup-replication/cronjob.yaml:251-264` | Capture the listing once; `grep -q` each Step-1-validated artifact; on any miss `send_report` + `exit 1` **without** cleaning source |
| B2-3 | B1-4 | Emptied critical PVC = uncounted skip → job green forever — `pvc-backup-cronjob.yaml:145` | Treat empty as FAIL (`failed_count++`) |
| B2-4 | B1-5 | NAS capacity tiers never alert; failed listing reads 0 GB — `backup-replication/cronjob.yaml:350-358` | **Script has `set -e` but NOT `pipefail` (`:65`)** and the size pipeline ends in `awk`, so exposing stderr alone is insufficient: capture `rsync --list-only` to a file, check its exit status, *then* compute size. Also `exit 1` when `OVERALL_OK != true` |
| B2-5 | B4-1 | 12 app data PVCs are `local-path` reclaim=**Delete** + Flux-prunable → one Kustomization rename from data loss | `kustomize.toolkit.fluxcd.io/prune: disabled` on each. **Gated on A8** |
| B2-6 | B1-7 | mysql-backup client image drift (8.4.8 vs server 8.4.10) | Bump to 8.4.10; replace blanket renovate `enabled:false` with `allowedVersions: "/^8\\.4\\./"` |
| B2-7 | B1-9 | Codemap misstates `startingDeadlineSeconds` (600 vs 3600) | Correct to 3600 |

**Verification:** force a couchbackup failure and assert the Job exits non-zero leaving no tarball; assert a NAS-unreachable run leaves source backups intact.

---

## Batch 3 — DR restore path  *(own batch: needs live-admission proof)*

| ID | Was | Item | Fix |
|---|---|---|---|
| B3-1 | B1-2 **HIGH** | DR CouchDB restore cannot run — bare `kubectl run` lacks limits/seccomp/labels (**Kyverno denies**, A2) and `wget --method=PUT` is not a busybox flag — `.backup/README.md:282-305` | Ship a pinned restore manifest (resources + `seccompProfile: RuntimeDefault` + `app` label). For the DB pre-create use **Node 24's built-in fetch** (the image is already `node:24.16.0-alpine`) rather than adding curl for one request. **Prove with `--dry-run=server` against live admission before commit** |
| B3-2 | B1-6 | DR PVC-restore runbook covers 3 apps; `CRITICAL_PVCS` backs up 10 — `.backup/README.md:314` | **Not a bare directory loop:** restore needs workload quiescing + a live PV path, and `pvc-backup-cronjob.yaml:88-103` has 14 archive mappings but **no workload kind/name or restore target**. Add that mapping first, then drive the runbook from it |

---

## Batch 4 — Monitoring correctness  *(makes the next failure loud)*

| ID | Was | Item | Fix |
|---|---|---|---|
| B4-1 | B2-1 | `BackupJobRunningTooLong` structurally dead — `and kube_job_complete` (real metric `kube_job_status_complete`, `condition` label) — `vmrules.yaml:516` | `… unless on(namespace,job_name) kube_job_status_complete{condition="true"} == 1` |
| B4-2 | B2-2 | `KyvernoAdmissionControllerDown` group evaluated **hourly** → critical fires 1-2 h late — `vmrules.yaml:883` | `interval: 60s` |
| B4-3 | B2-3 | VMSingle healthCheck vacuous (kstatus: condition-less CR = always Current) — `clusters/monitoring.yaml:51` | `healthCheckExprs` on `status.updateStatus`. **Gated on A9** — confirm the field and its values exist on the live CR first |
| B4-4 | B2-4 | **NAS unmonitored while sole durability substrate** | **Trimmed:** `NodeDiskSpaceLow/Critical` (`vmrules.yaml:162-178`) already covers virtiofs capacity — so add only (i) an `absent()` arm so losing the series alerts, and (ii) a `df` threshold on the NAS backup pool in the existing no-sudo SSH in `immich-vm-heal.sh`. Record SMART/RAID blindness as accepted risk in ARCHITECTURE cut-corners |
| B4-5 | B2-5 | PG + Redis `ConnectionFailure` dead (`and` across mismatched label sets) — `vmrules.yaml:577` | **Delete both rules** rather than repair: zero transactions/clients is not proof of failure, and `cnpg_collector_up == 0` (`:559`) + `redis_up == 0` (`:625`) already alert on real availability |
| B4-6 | B2-6 | Quorum alerts count series not values — `vmrules.yaml:1309` | `count(kube_pod_status_phase{…,phase="Running"} == 1) < 2` |
| B4-7 | B2-7 | `NoRecentImmichBackup` missing from telegram-backup route regex — `release.yaml:216` | Add to the alertname regex |
| B4-8 | B2-8 | NodeDown inhibit rule is a no-op (`equal:[instance]` never matches KSM pod alerts) — `release.yaml:222` | Delete the dead rule |
| B4-9 | B2-9 | No dedicated VMAgent ingestion-liveness alert | `absent(up{job="vmagent-vmagent"})`, `for: 10m` |

---

## Batch 5 — Access control  *(own batch: builds new auth infrastructure)*

Per A12 this is **not** an annotation change — it stands up the repo's first forward-auth path.

| ID | Was | Item | Fix |
|---|---|---|---|
| B5-1 | B3-1 | **Alertmanager `am.h0melab.work` fully unauthenticated** — silences API open to anyone on LAN — `release.yaml:277-289` | Authentik **proxy provider + outpost + Traefik Middleware**, then the ingress annotation. Safe per A7 (no in-cluster client uses the hostname). Alternative if the outpost is unwanted: Traefik basicAuth from a SOPS secret |
| B5-2 | B3-5 | Homepage unauthenticated on LAN while holding a cluster-wide read token — `apps/homepage/ingress.yaml:7` | Reuse the B5-1 outpost/middleware |

---

## Batch 6 — Policy, NetworkPolicy, RBAC hygiene

| ID | Was | Item | Fix |
|---|---|---|---|
| B6-1 | B3-2 | monitoring `rate-limit-standard` missing `period:` → **100 req/second**, not /min (apps tier fixed 2026-07-03; this fork missed) | Add `period: 1m` |
| B6-2 | B3-4 | `disallow-host-path` whole-ns excludes leave monitoring/loki/immich unguarded; couchdb exclude stale | Replace ns-excludes with label-keyed `matchConditions`. **Also narrow `databases` + `backup-replication`** — their hostPath jobs carry scopeable labels (`postgres-backup-cronjob.yaml:17-20`, `backup-replication/cronjob.yaml:19-22`). **Gated on A11** |
| B6-3 | B3-6 | popeye ClusterRole grants get/list on **all Secrets** cluster-wide — `popeye/rbac.yaml:16` | Drop `secrets` + exclude secret linters. Owner call: degrades the unused-secret linter |
| B6-4 | B3-7 | kyverno NP port 443 never matches (container port 9443) | Delete the 443 entry, fix comment |
| B6-5 | B3-8 | mysql-cluster "K8s API" egress selects the empty `default` ns — dead grant | Delete both rules |
| B6-6 | B3-9 | uptime-kuma egress carries 4 dead ports incl. a half-wired CouchDB probe | Drop 6446/5984/8428/9090. **Gated on A10** |
| B6-7 | B3-10 | authentik + obsidian DB egress ns-wide, missing pod-level scoping | Add `podSelector` (`cnpg.io/cluster: main-postgres` / `app: couchdb`) |
| B6-8 | B3-11 | Fossil exclude for deleted `main-mariadb-metrics`; `ephemeralContainers` clauses unreachable at admission | Delete the fossil; correct the 3 comments to say report-only |

---

## Batch 7 — Runtime hygiene + supply chain

| ID | Was | Item | Fix |
|---|---|---|---|
| B7-1 | B4-2 | Both postgres extension jobs exit 0 on SQL failure | `ON_ERROR_STOP=1` **is not sufficient** — the `WHEN OTHERS` handler (`update-extensions-job.yaml:53-59`) catches every error and mislabels it "already at latest version". Log `SQLERRM` and **re-raise** (or drop the handler) |
| B7-2 | B4-3 | homehub setup-config: no `set -e`, raw `sed` substitution of the password | `set -eu`; delimiter-safe `awk`; fail if the placeholder is absent |
| B7-3 | B4-4 | homepage copy-config swallows every `cp` failure as "no ConfigMap files" | Distinguish empty-dir from copy failure under `set -e` |
| B7-4 | B4-5 | HACS from unpinned `latest` zip **and** vacuous verify — `mkdir -p` precedes download so `[ ! -d ]` can never fire | Pin the release tag + `.installed-version` marker (mirror `oidc-auth-install`); verify a real artifact |
| B7-5 | B4-6 | redis-operator `imageTag` frozen v0.24.0 while chart bumped to 0.25.0 — renovate-blind skew | Delete the `imageTag` line (chart default = appVersion, pinned via the chart); fix the stale comment |
| B7-6 | B4-7 | loki gateway nginx bare tag, renovate-blind, a patch behind its in-repo twin | Add `repository:` above the tag |
| B7-7 | B4-8 | HelmRelease values image tags have no pin audit | Extend the yq pass to `spec.values..image.tag`/`imageTag` |
| B7-8 | B4-9 | blocky (LAN DNS, 2 replicas) is the only multi-replica workload without a PDB | Add `apps/blocky/pdb.yaml` (`minAvailable: 1`) |
| B7-9 | B5-8 | cloudflared config-sync parser has no rule-count floor — parse drift silently wipes external access | Hard-fail below the current hostname-rule count |

---

## Batch 8 — Docs currency  *(docs-only, Codex gate exempt)*

| ID | Was | Item |
|---|---|---|
| B8-1 | B5-2 | **Record the CF Access posture** in `docs/ARCHITECTURE.md:94`: the shipped couchdb Service Auth policy, plus a per-hostname decision for the other 8 tunnel hostnames (app-native login MAY be accepted — but it must be written down, since the zone config leaves no repo artifact) |
| B8-2 | B5-9 | Drift bundle: rustdesk row + "Applications (17)" + refreshed platform facts (`HOMELAB_ANALYSIS.md:28`); Kyverno daily-digest removal (`:76`); drop decommissioned AdGuard (`SECRETS_ROTATION.md:138`); wrong Kustomization (`:237`) and nonexistent `flux reconcile --force` (`:270`); missing rotation-inventory rows incl. cert-manager CF API token (`:103`); retired W2 leg + rate-limit copy 300/600 and the authentik no-rate-limit exception (`CODEMAPS/apps.md:33,37`); 16→17 stacks (`ARCHITECTURE.md:64`) |

---

## Plan review outcomes (Codex, verdict REVISE → revised)

**Accepted and folded in:** exit-0 **AND** log-pairing for couchbackup (OR would still admit a fatal); the replication size pipeline needs a captured exit check because the script has `set -e` but no `pipefail`; the DR PVC runbook needs a workload/target mapping before any loop; `ConnectionFailure` rules deleted rather than repaired (real availability alerts already exist); `WHEN OTHERS` must be re-raised or removed, not just paired with `ON_ERROR_STOP`; `databases`/`backup-replication` ns-excludes should also be narrowed; B4-4 trimmed because `NodeDiskSpaceLow` already covers virtiofs; Node built-in fetch instead of adding curl; urgent token rotation pulled to Batch 0; CI-coverage fixes pulled ahead of the batches they must validate; PVC prune protection moved next to the other data-loss guards; new prereqs A9/A11/A12.

**Partially accepted — B0-2 sequencing.** Codex's verdict was that the `ci-green` cutover must be bootstrapped before any production batch. The *decision* is now Batch 0, but the cutover itself is not mandated as a hard prerequisite: repointing a bootstrap-generated `gotk-sync.yaml` is the single highest-structural-risk change in this plan, and front-loading it means the riskiest merge happens with no warm-up. Each batch already carries a Codex static gate plus local validation, which is the control that has actually been catching defects. If the owner picks (a), it ships as its own early batch; if (b), it is a one-line doc change.

---

## A11 spike result — B6-2 deliberately NOT shipped (2026-07-25)

The spike answered its question **yes**: every hostPath workload does carry a scopeable label, so a label-keyed `matchConditions` rewrite of `disallow-host-path` is possible. It also showed the change is bigger and more dangerous than the plan assumed, so it was left unshipped rather than merged unattended.

**What is actually excluded today.** Six whole namespaces — `monitoring`, `loki`, `databases`, `couchdb`, `immich`, `backup-replication` — plus the four system ones. **41 pods in those namespaces mount no hostPath at all** and are therefore unguarded by this policy. That is the real finding: the gap is wide.

**The workload set is larger than a live scan suggests.** Long-running hostPath workloads are only three:

| Workload | Scopeable label |
|---|---|
| `immich/immich-server` | `app.kubernetes.io/name=server`, `app.kubernetes.io/instance=immich` |
| `loki/alloy` (DaemonSet) | `app.kubernetes.io/name=alloy` |
| `monitoring/…-prometheus-node-exporter` (DaemonSet) | `app.kubernetes.io/name=prometheus-node-exporter` |

But **six hostPath CronJobs are invisible to `kubectl get pods`** because their pods exist only while running: `backup-replication/cronjob`, `backup-replication/immich-backup-cronjob`, `databases/{couchdb,mysql,postgres}-backup-cronjob`, and `kube-system/pvc-backup-cronjob`. A narrowing built from a live pod scan would omit all six.

**Why it was not shipped.** Nine distinct selectors must all be correct against a **Deny**-enforcing policy, and the failure mode is a backup Job denied at 03:00 with nobody watching — the exact silent-failure class the rest of this review was spent removing. Nothing is currently broken, so this is hardening, not a fix.

**How to ship it safely.** Flip `validationActions` to `Audit` first, soak, read the PolicyReports to confirm the nine selectors cover every real hostPath pod including a full backup cycle, then flip back to `Deny`. That is the pattern this repo already used for the seccomp/securityContext rollout. Do it in a session where the admission probes can be run and watched.
