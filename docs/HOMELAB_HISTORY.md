# Homelab History

The append-only engineering record for the cluster — every review finding, incident, and completed action item since the first commit. Newest entries sit near the top; the canonical audit trail is `git log`.

**Active status:** [HOMELAB_ANALYSIS.md](./HOMELAB_ANALYSIS.md) · **Design rationale:** [ARCHITECTURE.md](./ARCHITECTURE.md) · **Coverage:** October 2025 – present.

## Milestones

| Window | Milestone |
|---|---|
| Oct 2025 | Security hardening pass — PostgreSQL NetworkPolicies, Kyverno policy phases 1–3, SOPS secret encryption, Cloudflare Tunnel, HA for critical components |
| Nov–Dec 2025 | SSO across the app fleet (Authentik OIDC), backup validation (SHA-256), monitoring HA (Prometheus/Alertmanager 2-replica) |
| Q1 2026 | Node maintenance as ansible roles, Authentik passkey-first auth, Blocky DNS migration, Redis Sentinel HA |
| Q2 2026 | DNS decoupling + coredns-ha DaemonSet, CNPG anti-flap hardening, per-app CSP rollout, Flux bootstrap flatten |

The dated changelog and completed-action-item archive below are the detail behind these.

---

### 2026-07-18 — immich-vm modprobe cascade: kernel-modules-hook mislabelled AUR, two weeks of silently-failed patching

An operator `yay -Syyu` on immich-vm surfaced 33 pending packages, which should have been impossible on a node in the weekly flow. Four failures had stacked:

- **`kernel-modules-hook` was mislabelled AUR.** It lives in `extra`, but `base_config/tasks/main.yml` called it "(AUR)" and `setup-node.sh` carried it in `AUR_PKGS`, whose install loop swallowed everything (`2>/dev/null … || true`). immich-vm was bootstrapped 2026-07-10, that step failed, nothing logged it. `phase2.yml:376` meanwhile asserts as fact that "the fleet convention installs kernel-modules-hook" — false for this node.
- **Truncated packages blocked every upgrade.** `ripgrep` (later `zsh-completions`, `zsh-autosuggestions`) had zero-byte `desc`/`files` in `/var/lib/pacman/local/` plus partial `.zst` files in the cache. pacman could therefore neither tell it owned the installed paths (`ripgrep: /usr/bin/rg exists in filesystem`) nor verify the cached files (PGP invalid on a truncated download). Every `-Syu` aborted at "checking for file conflicts", upgrading nothing.
- **The failure was invisible.** PLAY 1b's `yay` sits in a rescue with `failed_when: false` — correct, since a hard fail there strands `phase2-pending` and gates drift-heal cluster-wide (2026-06-20, ~1.7h) — so phase2 recorded `failed=0 rescued=1` on both 2026-07-11 and 2026-07-18. Telegram alerted both times, both went unnoticed. `NodeMaintenanceMissedRun` cannot catch this: it tracks whether the *run* completed, not whether each node's packages moved.
- **The manual upgrade then fired the 2026-05-02 cascade.** `linux-lts 6.18.38-2 → -4` with no hook let `60-mkinitcpio-remove.hook` delete `/usr/lib/modules/6.18.38-2-lts` under the running kernel at 15:01:08. Every subsequent `modprobe` FATAL'd (`br_netfilter not found`). ufw and k3s-agent stayed up only because their modules were already resident — a reload would have reproduced the W1 ufw silent-disable → INPUT chain DROP. Worst node for it: immich-vm never in-guest reboots (reset-bug C3), so the stale-kernel window is long.

Fixes (`d8ecf27b`, `0fdd88f1`): a fleet-parity audit (immich-vm vs W1/W2) found 19 hand-installed, never-declared packages; the 13 repo-installable ones added to `pacman_packages_base` — `arch-audit bc chezmoi duf dust fd github-cli helm kernel-modules-hook kubectl neovim xclip zoxide`. Excluded with reasons recorded in-file: `flux-bin viddy zsh-you-should-use` (AUR-only, list is pacman-only by design), `packagekit pkgstats udisks2` (dependency leftovers). `kernel-modules-hook` removed from `AUR_PKGS` and the stale "(AUR)" comments corrected, so it is declarative with the role's retries instead of bootstrap-only best-effort. `base_config`'s missing-hook `debug` warn escalated to `fail` (node-config is a separate playbook from phase2, so it cannot wedge `phase2-pending`). New `tasks/pkg-upgrade-metric.yml` emits `node_pkg_upgrade_success` from all three `yay` call sites into its own `.prom` file — deliberately not `metrics_file`, which phase2 post-tasks `copy` wholesale on the CP and would clobber; `failed_when: false` so telemetry can never fail the run it reports on. New `NodePackageUpgradeFailed` alert (`== 0` for 1h) fills the per-node gap; it would have fired 2026-07-11. `setup-node.sh`'s AUR loop no longer discards stderr — failures are collected and reported with a retry command, still non-fatal so an optional firmware blob cannot abort bootstrap.

Recovery: truncated packages repaired with `pacman -S --overwrite '/usr/*'` after clearing zero-byte cache files (the corrupt cache was the actual `-Syu` blocker; targeted delete, not `pacman -Sc` — no reason to discard 460+ good entries), hook installed, `linux-modules-cleanup.service` enabled, then a reset-bug-safe cold-cycle (graceful `poweroff` → `immich-vm-heal` watchdog `virsh start`, ~2 min). Verified back on `6.18.38-4-lts` with 6407 modules, `modprobe` working, GPU passthrough intact (`gpu.intel.com/i915: 10`), immich-server Running, 4/4 nodes Ready, zero not-Running pods. Pre-flight confirmed every other workload on the node was 2/2 or 3/3 with PDB headroom, and that the postgres primary (PDB allows 0 disruptions) sits on worker-node.

Likely source of the truncation: `last -x` shows **8 crashes** across 2026-07-10 → 07-13, the VM's build-out window, consistent with unclean shutdowns mid-write (the reset-bug takes the NAS host down with it). Not proven — the current boot mounts clean with no ext4 recovery, and `/usr/bin/rg` is dated Jun 16, predating the cluster join, so that one likely arrived with the image. Detector for recurrence: `find /var/lib/pacman/local -maxdepth 2 -name desc -size 0`. Note zero-byte files alone are **not** a corruption signal — `linux-lts-headers` legitimately ships ~10,900 empty Kconfig marker stubs; the signature is an empty `desc`.

**Open:** `NodePackageUpgradeFailed` cannot fire until the metric series exists, so it is inert until the next scheduled run (2026-07-25 05:30). If `node_pkg_upgrade.prom` does not appear on all four nodes after that run, the alert is silently dead and needs checking.

### 2026-07-17 — claude-telegram 1.27.15: track latest Anthropic SDK/CLI + codex; SDK 0.3.212 tool-gate audit

Follow-on to 1.27.14 (same day): 7-day supply-chain lag on trusted publishers dropped by decision — the SDK tool-surface tripwire test is the safety net. bunfig gained `minimumReleaseAgeExcludes` for the Anthropic SDK + all 8 platform packages (7-day quarantine kept for the ~117 third-party deps; Codex review caught 2 missing platform names — enumerate from bun.lock). Dockerfile codex install dropped the `--before` gate → `@openai/codex@latest`. SDK 0.3.212 tripwire fired on 3 new built-in tools, classified: RefreshMcpTools allowed; SendFeedback denied (external publish channel); ProposeSkills denied (skill-injection persistence). 179/179 tests green, image built/pushed locally (CI still billing-blocked), pod verified: codex 0.144.5, engine CLI 2.1.212, SDK 0.3.212.

Base-image review (user question "does alpine still make sense?"): **stay on alpine** — apk carries current gh + chezmoi (debian stable has neither fresh; switch would resurrect `curl | sh` installs), every runtime binary is musl-safe (SDK ships a musl engine variant, codex is static musl, kubectl/flux static Go), and the alpine base is 22–41 MB smaller compressed than slim/debian.

### 2026-07-17 — claude-telegram 1.27.14: Dockerfile install hardening, shipped via local build (CI billing-blocked)

Dockerfile linter audit (droast) flagged the flux `curl | bash` install — floating version + pipe-to-shell. Fork rework (`9c56118`): flux pinned `ARG FLUX_VERSION=2.9.2` (cluster minor) with sha256 verify against release checksums; kubectl download now checksum-verified; chezmoi switched from `curl get.chezmoi.io | sh` to `apk add chezmoi`; codex un-pinned to latest behind `npm --before=(now−7d)` gate + BUILD_TS layer-bust — mirrors bunfig `minimumReleaseAge`, closing the codex-not-gated asymmetry. apk RUNs consolidated, unpinned-by-design documented in-file.

- **Gate proof**: codex resolved 0.144.1 (0.144.5 was 1 day old — excluded); SDK 0.3.206 vs latest 0.3.212 (same 7-day logic).
- **Ship**: GitHub Actions still billing-blocked (Jul 16 scheduled run failed in 4s) → local escape hatch: CI replica green (typecheck + compile + 179 tests), amd64 build, GHCR push, tag `claude-telegram-v1.27.14`, deployment bump `9cab06fb`.
- **Verified in-pod**: engine CLI 2.1.206 / SDK 0.3.206 lockstep, codex 0.144.1, flux 2.9.2, chezmoi v2.62.5 (37 skills applied), bot polling.
- Codex static review: SHIP, zero findings.

### 2026-07-17 — Redis sentinel "memory leak" root-caused: operator annotation hot loop (live-object fix, no manifest change)

`ContainerMemoryNearLimit` on the sentinel pods had been re-firing through two limit bumps (64→128Mi `1199988d`, 128→192Mi `57bb642a`) and an operator CPU bump (`c214e0cd`) — all symptom-chasing. Actual chain: the 2026-07-03 controllers→configs move (`8595de63`/`d771464d`) put a temporary `kustomize.toolkit.fluxcd.io/prune: disabled` annotation on the Redis CRs for 4 minutes; the opstree operator (v0.24.0) propagated it to its 12 owned children (2 STS, 8 SVC, 2 PDB). After the annotation left the CRs, the operator diffed the children every reconcile but its client-side merge can never delete an annotation → non-convergent update → its own StatefulSet watch re-queued it → self-sustaining ~3.4s loop. Since upstream PR #1533 every sentinel reconcile unconditionally runs SENTINEL MONITOR/SET/RESET, so the sentinels took ~25,400 RESETs/day each (Loki baseline: 5–19/day before Jul 4), each one rewriting `sentinel.conf` (1.5GB written per pod in 2.7d) — the "leak" was ~145Mi of reclaimable dentry/inode slab in the container cgroup (`memory.stat kernel`), process RSS a flat 17Mi. Side effects while looping: sentinel known-replica/sentinel state wiped every 3s (failover-reliability risk), ~76k spurious operator→redis connections/day (`pool.go:380 Conn has unread data`), operator CPU throttling.

Fix was live-object metadata cleanup on operator-owned (non-git) objects — `kubectl annotate … kustomize.toolkit.fluxcd.io/prune-` across the 12 children; the loop stopped instantly (0 STS events, 0 resets, 0 operator errors after; verified via watch + Loki). Residual: the accumulated slab doesn't self-reclaim, so sentinels need a sequential pod restart to clear ~154Mi working-set and silence the alert. Gotcha codified in agent memory (incl.: never `rollout restart` an opstree STS — the injected `restartedAt` template annotation re-arms the same loop; and any future prune-dance over operator-parent CRs must sweep the children afterwards). Same-day closure: symptom-bumps reverted (`9fe9ccb7` — sentinel back to 32Mi/64Mi requests/limits + 10m CPU request, operator CPU limit 200m; the pre-loop 300m sentinel CPU limit from `8447338d` and the kyverno half of `c214e0cd` kept); the revert's pod roll cleared the slab (working set 8–17Mi), alert resolved, quorum verified, no loop re-entry. CI was infra-red (GitHub runner outage, all jobs/all SHAs) — local ladder + trivial-revert classification authorized `fr` per gate rules. Upstream issue filed with full forensics + mitigation: [OT-CONTAINER-KIT/redis-operator#1840](https://github.com/OT-CONTAINER-KIT/redis-operator/issues/1840). Observation window to 2026-07-24: sentinel memory flat, reset rate ≤20/day, operator un-throttled at 200m; the 64Mi limit doubles as canary (loop recurrence re-fires the alert in under a day). Operator chart 0.26.0 (2026-07-15) remains unverified for this bug class.

### 2026-07-17 — Backup replication: W2 safety-net leg retired (NAS sole sink)

The temporary W1→W2 replication step (single-day `--delete` copy over SSH :65300, added 2026-05-22 while the NAS sink was unproven, postponed once from 2026-05-22 +2mo) was removed 3 days ahead of its ~2026-07-20 deadline. The NAS leg has been validated on every run since (pre-sync source validation: age <25h + SHA256 + tar integrity + min size; post-push verify; 30d/keep-2 retention prune), so the W2 copy was redundant — and its `--delete` semantics had already shown a footgun (2026-07-14: cross-job `--delete` interaction with the W2 immich tar path considered during T7 planning).

Changes (`infrastructure/configs/backup-replication/`): W2 sync step + SSH client setup removed from `cronjob.yaml` (steps renumbered 2→7 → 2→6, `openssh-client` dropped from apk install, ssh-key/known-hosts volumes+mounts removed); `ssh-key-secret.yaml` + `ssh-known-hosts-configmap.yaml` deleted (Flux `prune: true` removes the live Secret/ConfigMap); NetworkPolicy W2 `192.168.1.126:65300` egress rule dropped. DR tooling updated: `.backup/secrets-backup.sh`/`secrets-restore.sh` no longer save/restore `backup-replication-ssh-key` (restore gate re-keyed to `nas-rsync-credentials.json`), `.backup/README.md` restore sources 3→2. `SECRETS_ROTATION.md`: `backup-replication-ssh` retired (was next-due 2026-12-18). Unrelated to the weekly `immich-backup` W2 job — that stays.

### 2026-07-16 — CODEMAPS restructure: drift-prone facts removed, content rules added

Fact-check found 17+ stale version pins in the codemaps (immich a full major behind, blocky 2 minors, internal loki contradiction in monitoring.md) plus counts and "Refreshed" headers drifted — hand-copied manifest/live facts were a permanent treadmill. Restructure (Codex-reviewed plan, SHIP-WITH-FIXES): codemaps now carry structure/relations/gotchas only, every fact path-anchored; no versions ("pinned in `<path>`"), no counts (grep or ANALYSIS), no changelog narration. `CODEMAPS/architecture.md` deleted (~80% duplicate of AGENTS.md); unique content moved — named Cloudflare hostname list + coredns `--disable` deadlock → networking.md, SOPS edit pattern + Flux path tree → README index. apps.md fix: home-assistant marked internal-only (absent from tunnel SOPS config; was wrongly "both"). ARCHITECTURE.md:133 fixed — 5 daily backup CronJobs W1-pinned, weekly immich-backup is W2-producer and survives W1 loss (was "all 6 on W1", self-contradicting the T7 entry). Monthly-review skill step 2 rewritten: refresh → verify (no live-fact dump, rule-violation grep). Follow-ups noted: several Helm chart-default images unpinned in git (traefik, CNPG operator, grafana, VM stack, couchdb — escape both the image-pin invariant and CI gate); inert `values.image.tag: v2.7.5` in `apps/immich/release.yaml`. Same-day resolution: chart-default images ruled transitively pinned via the pinned chart version — mirroring them into values would create renovate-blind skew, so the invariant was clarified in AGENTS.md instead of adding pins; the inert immich tag deleted with a `helm template` render-identical proof (chart 0.13.1, values with vs without the block).

### 2026-07-14 — trivy-scan hardening: scan timeout, Docker Hub auth (PAT incident), schedule shift

Three follow-up commits after the smoke runs, plus one security incident:
- **`--timeout 15m`** (`6599bb05`): smoke1 scanned all 81 images but 3 FATAL'd on trivy's default 5m per-scan timeout mid-layer-analysis (scipy/prisma `.so`-heavy layers) — exit 1 by design (partial failure fails the Job).
- **Docker Hub auth** (`c8ffb596` + `ca2fce4a`): ~40/81 images are docker.io; anonymous 100 manifest-pulls/6h/IP is borderline monthly. SOPS `trivy-dockerhub` Secret (dockerconfig scoped to `index.docker.io` via `DOCKER_CONFIG` — not the unscoped `TRIVY_USERNAME`), annual slot in SECRETS_ROTATION. **Gotcha:** first cut had an empty username (`:token`) because the 1Password field was blank — docker's config parser rejects the whole file ("invalid auth configuration file"), killing even anonymous mirror.gcr.io DB pulls; smoke2 failed 81/81 in seconds. **Incident:** during diagnosis the first PAT leaked into the agent transcript via a redaction regex that assumed non-empty username — token revoked + reissued same hour; regenerated secret ships with non-empty-username + rotated-prefix guards.
- **Schedule 04:00→08:00 UTC on the 1st** (`bb0b4621`): 04:00 collided with the node security scan (1st 04:00) and, when the 1st is a Saturday, the weekly upgrade+rolling-reboot window (Sat 04:30) would kill the scan mid-run. Review-night manual run + Saturday caveat codified in `homelab-monthly-review`.
- **Proof + closure:** smoke3 Complete 81/81 in 11min (authenticated); output verified queryable in Loki (`{namespace="trivy-scan"}`); user deleted the 12 orphaned `aquasecurity.github.io` CRDs (cascaded all 88 reports) — teardown fully closed.

### 2026-07-14 — kube-prometheus-stack upgrades wedged by Kyverno vs chart hook Jobs (fixed)

Post-trivy-teardown audit found the kube-prometheus-stack HelmRelease Stalled: the chart's pre-upgrade admission-webhook cert patch Jobs carry no resource limits, so `require-resource-limits` denied them at admission — 87.15.2 and then 87.16.0 (Renovate #920/#923) both failed 4 upgrade attempts and auto-rolled back to 87.15.1. First chart-hook denial since the VP migration (same first-X-since-VP class as the trivy-scan namespace bootstrap below). Side effect: the trivy Alertmanager cleanup (telegram-digest removal) was silently held back with the stalled release. Fix: `prometheusOperator.admissionWebhooks.patch.resources` (10m/32Mi → 100m/64Mi) in release.yaml values; verified via `helm template 87.16.0` that the hook Job renders with limits. Invariant added to `.claude/review-invariants.md` (chart-bump reviewer check: hook Jobs need limits via values).

### 2026-07-14 — trivy-operator removed; replaced by monthly trivy-scan CronJob

Always-on trivy-operator torn down after 10 days in service (installed `dfeb0153` 2026-07-04): ~650Mi RAM 24/7 to re-scan images that only change when Renovate bumps them, 88 VulnerabilityReports on upstream images we don't own = noise over signal (2026-07-05 triage: 0 findings on our own images). Replaced with `monitoring/configs/trivy-scan/` — a monthly CronJob (1st 08:00 UTC — clear of the 1st-04:00 node security scan and the Sat 04:30 weekly reboot window; review-night manual runs codified in the monthly-review skill) in its own `trivy-scan` ns: `rancher/shell:v0.8.0` init collects the unique image set via kubectl (~80 images; rancher/kubectl is shell-less scratch — can't redirect to a file), then `aquasec/trivy:0.71.1` loops `trivy image --severity CRITICAL,HIGH --ignore-unfixed` printing per-image tables to stdout (Loki captures). Partial scan failures fail the Job (no success-theater); 1Gi mem limit (trivy peaks on large images); `ttlSecondsAfterFinished: 86400`; NP = DNS + API server + 443-only registry egress (popeye/trivy-operator patterns). Swept with it: `TrivyCriticalVulnerabilities` VMRule, `scrape-trivy-operator.yaml` VMPodScrape, Alertmanager `telegram-digest` route+receiver, `alertmanagerSpec.retention: 192h` (existed only for the 168h digest repeat_interval), claude-telegram `aquasecurity.github.io` RBAC. Post-reconcile manual GC: aquasecurity CRDs + orphaned VulnerabilityReports (helm uninstall leaves CRDs).

### 2026-07-14 — Immich T7: backup re-topology (W2 producer) + W1 library PVC decommissioned

Closed the Path-B follow-up. Two commits, both Codex static-reviewed (`.claude/review-invariants.md`); CI still billing-blocked since 07-10, gates ran locally (yamllint, kustomize build, kubeconform).

- **Backup re-topology (`4628800d`).** Post-cutover the library is NAS-resident, so the old `immich-backup` CronJob (kube-system, nodeSelector W1) read a **frozen** `/mnt/k8s-storage/*immich-library*` copy = silent success-theater. Re-pointed: CronJob → **`backup-replication` ns / worker-node-2**, pulls the **live** library via the NAS `personal_folder` rsync module → tar+sha on a W2 hostPath → pushes to the NAS `akhozya-pool1` pool. **Two physical copies on different filesystems** (W2 node + NAS pool), keep-2 each (pool keep-2 delegated to backup-replication Step 5b). Reused `nas-rsync-credentials` + the ns-wide egress NP (0 new secret, 0 new NP); only a 1-line `vmrules` description touched. Codex **3 rounds**: R1 HIGH (final dated dir created pre-success → a partial dir pollutes the name-sorted keep-2 window, evicting good copies) + MED (`head -n -2` is GNU-only, silently no-ops under busybox → unbounded growth) → fixed with a `.wip`→atomic-`mv` publish + husk-delete of a partial pool dir + `sort -r | tail -n +3`; R2 confirmed R1 **and found a new HIGH** — `backup-replication` Step 2's `rsync --delete` mirror to W2 `/mnt/extra-storage/backups/` would **wipe the fresh immich copy** 30 min later; fixed by writing the W2 copy to a **sibling** `/mnt/extra-storage/immich-backup/` outside the `--delete` scope (zero change to the critical replication job); R3 SHIP.
- **Gate proof (live).** Ran the repointed job off-schedule: 60.6G tar produced on W2 + pushed to the NAS pool in ~15 min; independent `sha256sum -c` on the NAS-pool copy = OK; tar holds real library content (`library/` 6477, `thumbs/` 18099, `upload/` 6159 entries, sample `./library/admin/2015/…/DSC09701.jpg`).
- **W1 decommission (`a32f6ef8`).** Removed `apps/immich/library-pvc.yaml` + its kustomization line (verified no pod mounts it — server uses the NAS hostPath, ML uses its own PVC). PVC `immich-library` pruned → local-path-provisioner `reclaimPolicy=Delete` auto-deleted PV `pvc-495129ee` + its ~61G on-disk dir (helper pod; no sudo/W1-SSH needed). `existingClaim: immich-library` kept in the HelmRelease as **inert schema filler** (the postRenderer replaces `volumes/0` by index; dropping it changes the persistence shape) — comment updated to say so. immich-server undisturbed (1/1, hostPath). Codex 1 round: SHIP.
- **Soak waived** at ~40h/48h (operator call): the repoint touches only the backup CronJob, not immich serving, and is fully reversible; the irreversible W1 delete was the one gated step and was explicitly confirmed. Post-change: 4/4 nodes Ready, 0 firing alerts, immich queues 0/0, external ping 200.

### 2026-07-13 — immich-vm auto cold-cycle codified in node-maintenance phase2 (kernel-bump reboots automated)

Closed the "patched-but-never-rebooted" gap. The `virtual` group (immich-vm) is carved out of the phase2 in-guest reboot rollout — a GPU-passthrough in-guest reboot re-binds the dirty iGPU → NAS host crash (reset-bug C3) — so a kernel bump previously only fired a **manual** operator-Telegram alert. phase2 PLAY 1b (`19d51c19`) now AUTO cold-cycles the reset-bug-safe way: graceful in-guest `/usr/bin/poweroff` (== `virsh shutdown --mode acpi`, never `reboot`) → wait node leaves Ready (NAS-free proxy for domain "shut off"; ansible never touches the NAS) → nudge the existing `immich-vm-heal` watchdog to cold-`virsh start` it → wait node Ready (7min; the watchdog's 5-min CronJob backstops a raced nudge). Wrapped block/rescue so a stall NEVER hard-fails PLAY 1b (a hard-fail leaves `phase2-pending` stuck → cluster-wide sync+config drift-heal ~1.7h). New `group_vars/virtual.yml` adds `vm_cold_cycle_force` for on-demand testing.

- **Codex 2-round static review** — round 1 HIGH: the four inline `telegram-notify.sh` tasks lacked `failed_when: false`, so a failing rescue-notify would hard-fail the play → the exact `phase2-pending` wedge; fixed all four (incl. the pre-existing yay-alert). Round 2 SHIP.
- **Both paths tested PASS** via `sudo ansible-playbook … --limit immich-vm [-e vm_cold_cycle_force=true]` (`--limit immich-vm` isolates PLAY 1b — delegated tasks bypass `--limit` to localhost/CP, so PLAY 0/1/2 skip = no worker reboots, no `phase2-pending` touch). NON-FORCE = gate skips (kernel current → all 7 cold-cycle tasks skipped, zero downtime, `ok=3 changed=1 failed=0`). FORCE = full cold-cycle (VM uptime 1h12m→2min = genuine, heal-maint job Complete 1/1 21s, node Ready ~1min, external 200 ~2.5min, assets 5791, GPU renderD129, fbdev cmdline intact, `ok=10 failed=0 rescued=0`).
- CI billing-blocked since 07-10 — gates ran locally (yamllint, ansible-lint production profile, `--syntax-check`).

### 2026-07-12 — July overdue closeout: Kyverno CP→VP Phases 2-4 COMPLETE, right-sizing pass, security-scan failure-notify

Closed the three real overdue items from the July monthly review in one worktree pass (`wt-overdue-closeout`; plan `docs/superpowers/plans/2026-07-12-monthly-review-overdue-closeout.md`). All commits Codex-reviewed (static git-only, `.claude/review-invariants.md` rubric).

- **Kyverno migration DONE — 12 CEL ValidatingPolicies are the sole policy engine.** Sequence: `abf5d2c5` flip 12 VPs `[Audit]`→`[Deny]` → Gate A (canary dry-run deny attributed per-policy) → CP+canary deletion → `fc45be04` parity-script retire + VP-era review invariants. 8-day parity soak was clean; breaker-drop storm (07-07→07-11, trivy scan-job churn + k3s reboots) ended before flip. **Gate B: all 12 policies attributed via live admission denies** — required working around three interplays: fine-grained VP webhooks short-circuit (deny names only first failing policy → probe with otherwise-compliant pods), PSA enforce=restricted namespaces mask webhook attribution (probe in PSS-privileged ns), LimitRanger injects default limits before validating webhooks (limit-less probe legitimately passes in LimitRange namespaces — probe in trivy-system). The kyverno.io/v1 removal deadline (1.20, ~Oct 2026) is met early; Renovate kyverno bumps unheld.
  - **Codex catch (HIGH, live-verified):** autogen clones rewrite `object.metadata` → `object.spec.template.metadata`, silently voiding top-level checks like the `skip-terminating` deletionTimestamp matchCondition. `require-networkpolicy-vp` now matches Pods AND controllers directly with `autogen.podControllers.controllers: []`. New review-invariants class added.
- **Right-sizing pass (07-06 item):** 12 workloads' requests raised to 7d p95 (VictoriaMetrics `quantile_over_time(0.95, …[7d])`), limits untouched. Wave 1 `d4d21e18` (8 stateless: stirling-pdf 768→1408Mi, n8n 256→448Mi, blocky 128→256Mi, pricebuddy-apprise 150→224Mi, paperless 512→704Mi, trivy-operator 128→640Mi, vmsingle 512→768Mi, vm-operator 64→160Mi), wave 2 `6cd4c036` (DB CRs: mysql 768→896Mi, orchestrator+haproxy cpu 50→160m, redis-sentinel cpu 10→50m; Percona SmartUpdate roll). Serialized merges; all rollouts converged. immich excluded (Path B 48h soak); Flux controllers excluded (declared cut). Residual: kyverno reports-controller throttle re-check 2026-07-13 (≥0.25 → limit 500m→800m).
- **security-scan failure-notify (07-08 item, `89cd65b3`):** missing lynis/rkhunter was a silent SKIP with exit 0 — now `FAIL=1` + `exit $FAIL`; unit gained `ExecStopPost` telegram-notify on any non-success. Root-cause find: `telegram-notify.sh` + creds were CP-only (install.sh installs locally), so EVERY worker-side notify path was dead — `security_scan` role now distributes script + `/etc/node-maintenance/telegram-{token,chat-id}` (0600, no_log) to all hosts. Applies at drift-heal 03:00 UTC.
- Also closed as already-done: immich-backup Sunday slot verified (`lastSuccessfulTime 2026-07-12T03:07Z`), trivy #2859 soak (closed 07-10 with concurrency 2→1). CI billing-blocked since 07-10 — gates ran locally (yamllint, kubeconform ×5 roots, shellcheck) per plan.

### 2026-07-12 — Immich Path B cutover (4E): server pod + library moved to immich-vm GPU node

Moved the `immich-server` pod off `worker-node` (W1, AMD) onto the `immich-vm` k3s node (Meteor Lake iGPU, Intel QSV) and repointed its photo library from the W1 local-path PVC to the NAS via **virtiofs hostPath** (`/var/lib/immich-library` → container `/data`). Placement + storage + GPU only — CNPG (PG18)/Redis/Cloudflare Tunnel/OIDC/Service/Ingress unchanged (NOT the abandoned Path A data-platform migration). Sequence on main: fence `65d5d2a7` → repoint `218f8f20` → unfence `3b4dca01`. GPU via the non-privileged **Intel device-plugin** (`gpu.intel.com/i915`, render GID 987) — no `/dev/dri` hostPath, no privileged container; namespace stays PSS-privileged only for the library hostPath. Library volume swapped by Kustomize **postRenderer** JSON-patch (chart schema rejects a native hostPath library). Spec `ba250045`, plan `docs/superpowers/plans/2026-07-12-immich-path-b-cutover.md`.

- **Client downtime ≈ 13 min, not "~1 min".** The cutover fenced ALL client HTTP to `:2283` (removed the traefik + cloudflare-tunnel ingress NP rules — cloudflare hits the pod directly, bypassing Traefik, so an app-level fence would leak; NP is the only path-agnostic fence). External returned 502 for the full fenced window `18:22:02 → 18:34:37`. The *data move* was zero-downtime (pre-seeded NAS copy was byte-current — no uploads since Jul-2); the *client outage* was the whole window, incl. the repoint (`18:24`) and the go/no-go pause. uptime-kuma's health ingress was kept during the fence so it didn't false-page.
- **DB↔disk verified post-cutover.** Every active Immich asset resolves to a file on the NAS-backed disk: `5775` active rows (5337 img + 438 vid), on-disk originals `5779` — checked all 5775 `originalPath`s, **missing=0**. The +4 on-disk extras are the harmless direction (soft-deletes/sidecars).
- **Latent transcode break — HW-accel config still points at the AMD device.** Immich's stored config (`system_metadata`) is `accel=vaapi`, `preferredHwDevice=/dev/dri/renderD128` — the W1/AMD render node. The immich-vm pod exposes only `renderD129` (Intel i915); `renderD128` does not exist there, so the next video job would fail HW init / silently CPU-fall-back. No transcode has run since cutover (logs empty) so it has not surfaced. **Fix (operator, passkey-gated — password login is disabled, OIDC-only):** Admin → Settings → Video Transcoding → Acceleration = **Quick Sync (QSV)**, Preferred Device = `/dev/dri/renderD129` (or blank/auto), Save; then run a Transcode job and confirm the pod's ffmpeg uses `hevc_qsv` with no software-fallback log line. The cutover's "raw `hevc_qsv` proven in-pod" gave false confidence — it bypassed Immich's own config path.
- **Backup cronjob is stale post-cutover (T7).** `immich-backup` (kube-system, Sun 03:00 UTC, `nodeSelector: worker-node`) still reads W1 `/mnt/k8s-storage/*immich-library*` — now the frozen pre-cutover copy, not the live NAS library (silent success-theater; loud `exit 1` once the W1 PVC is decommissioned). Next fire `2026-07-19` is after the 48h soak + T7. **T7 must repoint it to pull the NAS library (Task 4 W2-producer design) before 07-19.** Soak-window exposure is negligible: cronjob dormant, current data triply-covered (W1 PVC intact + live NAS + tar `20260712_030000`, sha-verified), uploads OIDC-gated.
- 48h stability soak running (ends ~2026-07-14 18:35). T7 (W2-producer backup + W1 library-PVC / PV `pvc-495129ee` decommission) held for post-soak.

### 2026-07-12 — immich-vm resilience HOTFIX: two live regressions from the codification (same day)

The codification below shipped two regressions to the live cluster, both caught within the hour, root-caused on ground-truth data, Codex-reviewed (2 rounds → CLEAN), fixed forward (main `4ed00d33`, `327d2afa`).

- **`on_reboot=preserve` broke the Tier-2 watchdog every cycle.** The QEMU libvirt driver supports **only `destroy|restart`** for `on_reboot`/`on_poweroff` (`preserve` is `on_crash`-only) — the generic `formatdomain.html` lists all four actions but omits the driver restriction, so the spike + Codex both validated against the schema, not the driver matrix. Live `virsh define` rejected it: *"qemu driver doesn't support the 'preserve' action for 'on_reboot'/'on_poweroff'"* → the watchdog failed `define_failed` every 5 min (was `Completed`). **Fix:** reverted to `on_reboot=restart` (the libvirt default and the live value; test-defined on the NAS at rc=0; next watchdog run went `RESULT=OK`). Both QEMU-supported values are imperfect on a slipped in-guest reboot — `restart`=C4 in-place iGPU wedge (NAS-reboot recoverable), `destroy`=C3 managed-reattach host crash — so **on_reboot cannot be the reset-bug belt**; the real guards stay `kernel.panic=0` + HW-watchdog-off + watchdog-never-destroy. The watchdog drift marker was re-pinned to `<on_reboot>restart</on_reboot>` (Codex round-1 HIGH: don't drop it, or a regen to `destroy` goes undetected). `on_crash=preserve` is unaffected (QEMU supports preserve there).
- **A comment-only edit failed the whole drift-heal.** The Track-2 wording fix to `99-zz-immich-vm-nopanic.conf` made its `copy` task report `changed` → fired its `notify` handler `Apply nopanic sysctl` → `sysctl --system` re-applies **every** `/etc/sysctl.d` file and exits rc=1 on this VM's unsettable `kernel.nmi_watchdog` (*Operation not permitted*) → the immich-vm play failed (the 3 override keys themselves applied fine). **Fix:** the handler now runs `sysctl -p /etc/sysctl.d/99-zz-immich-vm-nopanic.conf` (only its 3 settable keys). Lessons: editing *any* file wired to a `notify:` fires that handler (even a comment), and `sysctl --system` is fragile (one unsettable key → rc=1 for the batch). Runtime state was never wrong (panic/softlockup/hardlockup all stayed 0); no cluster gating (no `phase2-pending`), self-clears on the next config run.

### 2026-07-12 — immich-vm reboot-resilience codified to GitOps (fbdev wedge fix + 4 tracks)

Codified the field-proven fix for the recurring `immich-vm` hard wedge, plus three adjacent resilience tracks. Root cause (spiked + proven live 2026-07-11): **`virtio_gpu` fbdev/fbcon damage-work D-locks on the stalled host virtqueue while holding `drm_modeset_lock` → every GPU/login/shutdown open D-states → box wedges ~hourly.** NOT i915/RAM/dual-driver. Fix = `drm_kms_helper.fbdev_emulation=0 fbcon=off` on the guest UKI cmdline — 12h clean soak + graceful shutdown in 48s (pre-fix hung forever). Was applied manually to the live VM; this makes the repo match and drift-durable. Codex static review: **CLEAN, no findings**.

- **Track 0 (`bf04fe36`)** — generalized the role's i915-cmdline task to idempotent **token-set handling**: ensures `drm_kms_helper.fbdev_emulation=0`, `fbcon=off`, and merges `xe` into `modprobe.blacklist` (→ `i915,xe`, hygiene — binds nothing). Parser unit-tested for idempotence (run-twice = 0 changes) + no double-append. Guest heal probe hardened: `qsv_probe` now `timeout`-bounded + a `qsv_probe_stuck()` pgrep detector emitting a new `immich_gpu_qsv_stuck` gauge (emit_metric 6th arg, default 0 → existing callers unchanged) so a D-state vainfo is surfaced, not silently accumulated (the pre-fix self-heal-that-self-harms). **Gotcha:** `expected_kernel_params` adds fbdev/fbcon (live now) but deliberately keeps `modprobe.blacklist=i915` — base_config greps the RUNNING `/proc/cmdline` with `grep -qFw`, so `i915,xe` there would false-alert until the next operator cold-cycle; `-Fw "…=i915"` already substring-matches the future `i915,xe`. `xe` drift is enforced at the UKI *source* by the role.
- **Track 1 (`1dee4c88`)** — role now manages the guest `~akhozya/.ssh/authorized_keys` exclusively (operator zl-nas key + automation master-node key, the deduped live set — 3× master-node drift collapsed), asserts `~/.ssh` 0700 / file 0600, mirroring base_config's node-maintenance pattern. Closes the "key clears every reboot" onboarding gap (guest `/home` is persistent ext4 LVM, no cloud-init). NAS-side 0771 reset stays operator/appliance (out of IaC).
- **Track 2 (`1dee4c88` + `1fa66312`)** — installs+enables `qemu-guest-agent` (reliable `virsh shutdown --mode agent` + domtime/domfsinfo over the channel already in the domain XML). Docs sweep: removed the **phantom `virsh --timeout 120`** (a flag that does not exist on the NAS libvirt 9.0.0 → errored, never ran) from README, phase2 (incl. the live Telegram alert `:392`), and both plans; corrected the reset-bug `.conf` comments "NAS-side virsh reset" → "NAS host reboot" (`virsh reset` is itself a reset-bug trigger). Canonical procedure everywhere: `virsh shutdown --mode acpi <dom>` → poll domstate → `virsh start`; on hang → alert + NAS host reboot, **never destroy/reset**.
- **Track 3 + 7 (`0df8f020`)** — Tier-2 watchdog now gates `virsh start` on the virtiofs **source** (`/home/akhozya/immich/library`, a btrfs subvol on bcache) being present on the NAS — the lazy-mount races autostart after a NAS reboot (`virsh start` fails "export directory does not exist"). Not-ready → skip + retry next 5-min tick (a persistently-down VM is caught by NodeNotReady). Track 7 attempted `on_reboot: restart → preserve` — **REVERTED same day** (QEMU rejects `preserve` for on_reboot; see the HOTFIX entry above). `on_reboot` stayed `restart`; the watchdog got a `<on_reboot>restart</on_reboot>` drift marker.

Deferred (not this round): Option B (drop `<video>`/`<graphics vnc>` for truly-headless) — blocked on the pre-existing console mismatch (guest `console=hvc0` virtio-console vs the domain's isa-serial ttyS0 → `virsh console` likely dead); fix the console first.

### 2026-07-11 — immich-vm weekly patching was a silent no-op (yay never bootstrapped)

The GPU VM (`immich-vm`) had **not been patched since onboarding** — found on kernel `6.18.38-1-lts` while the rest of the fleet was on `-2`. Root cause: physical nodes seed the `yay` AUR helper once at build via `setup-node.sh`, but the VM's GPU-onboarding path skipped it, so phase2 **PLAY 1b**'s `yay_cmd` (`sudo -u node-maintenance yay -Syyu …`) failed with `yay: command not found`. The old rescue retried once and **swallowed** the failure → the task reported `ok` → the VM drifted un-updated, undetected. (The Saturday roll correctly does *not* reboot the VM — it's in the `virtual` inventory group, carved out of the reboot rollout for the reset-bug; this was a patching gap, not a reboot gap. Surfaced while checking whether the kernel-stale cold-restart alert had fired — it was `skipping`, because the swallowed upstream failure meant nothing was ever pulled.)

Two fixes (Codex-reviewed, 2 rounds):
- **`immich_gpu_node` role** now bootstraps `yay-bin` from the AUR when absent — `stat: /usr/bin/yay` guard so it only fires on a fresh/re-onboarded VM (thereafter the weekly `yay_cmd` self-updates yay). Build/install **split**: `makepkg` refuses root *and* this same role removes akhozya's NOPASSWD (admin-parity), so `makepkg -si` (self-calls `sudo pacman`) would hang → instead pre-install `base-devel`+`git` as root, `makepkg --noconfirm` as akhozya (no `-s`, PKGDEST/BUILDDIR overridden into a tmp dir), then `pacman -U` the artifact as root.
- **phase2 PLAY 1b rescue** no longer swallows: retry once (transient), and if it still fails, `telegram-notify` — deliberately **not** re-raising (a hard-fail would leave `phase2-pending` stuck → gate sync+config drift-heal cluster-wide, per the 2026-06-20 ~1.7h stall). A silent no-op became a page.

Codex round 1 caught a **HIGH**: the first guard used `ansible.builtin.command: command -v yay` — `command` is a shell builtin, unreachable without a shell, so with `failed_when: false` it read "missing" forever → bootstrap every drift-heal. Fixed to `stat`. Also noted: the VM's `akhozya` admin user had **no** authorized key (onboarding gap, same root cause) — added out-of-band via the `node-maintenance` identity.

### 2026-07-11 — Immich GPU-node Tier-2 host watchdog (Path B substrate self-heal)

Shipped the **Tier-2 host VM watchdog** for the Immich GPU node (`immich-vm`, the Arch k3s worker on the zettOS NAS). New under `apps/immich/gpu-node/`: CronJob `immich-vm-heal` (immich ns, every 5 min, nodeAffinity `homelab/gpu NotIn intel` so it runs OFF the node it heals), a **dedicated** `immich-vm-heal` ed25519 key (SOPS), a Job-scoped egress NetworkPolicy (NAS `192.168.1.136:56634` + DNS only), a pinned NAS known-hosts CM, and VMRule group `immich-gpu-node-alerts` (`ImmichVMHealJobFailing` + `ImmichVMHealStale`). The heal script (`immich-vm-heal.sh`, non-root POSIX sh, `alpine/git:2.54.0` for a baked-in ssh) SSHes the NAS and drives `virsh -c qemu:///system`: keeps the domain **defined-from-Git** (semantic marker-drift check — machine=q35, memfd, virtiofs, MAC, full iGPU PCI source address `domain='0x0000' bus='0x00' slot='0x02' function='0x0'`, managed='yes' — NOT a byte-diff, which false-drifts on libvirt's re-emitted runtime addresses) and **running** (`virsh start` on a `shut off` domain = clean cold iGPU reset; this IS the autostart since native/UI autostart is OFF by design). This watchdog is the durable answer to the cold-restart gap proven live 2026-07-10 (NAS power-cut → VM did not auto-start).

**Safety (incident C3):** the script NEVER `virsh destroy`s and NEVER restarts a *running* domain — force-destroy of a passthrough VM re-binds the dirty iGPU to the host i915 → NAS host crash. A wedged-but-running guest is left to `NodeNotReady` + operator. Also hardened the canonical domain XML `on_crash: destroy → preserve` (Codex-caught): `destroy` would tear the domain down on a guest crash — the same dirty-GPU rebind — and leave it `shut off` so the watchdog would auto-start it; `preserve` keeps it `crashed` → alert-only.

**Pod hardening:** immich ns is PSS `privileged` but `require-non-root` (Kyverno Enforce) does NOT exclude it → the watchdog runs non-root + drop-ALL + RoRFS + seccomp + dedicated SA + tight egress. The NAS key is delivered as an env secret and materialized to a `0400` self-owned file in the HOME emptyDir (a secret *volume* mounts root-owned and a non-root process can't fix perms for sshd StrictModes). Alerting is via the VMRule (Job status), not in-pod curl.

**Review:** 3 Codex static rounds (BLOCK: on_crash + hostdev-source-precision; WARNING: absent()-arm + `for:10m` on Stale) → SHIP. Corrected the design doc's stated NAS SSH port (65300 → **56634**; 65300 is the k3s-node port, the NAS *host* admin sshd is 56634).

**Go-live (operator, pending):** append the dedicated pubkey (`ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE2Z/KV9tk+ceo5Pu50nAX5zOp3bbAyKIYOs3eW442eo immich-vm-heal@homelab`) to NAS `~akhozya/.ssh/authorized_keys`, and one `virsh -c qemu:///system define` of the hardened XML so the live domain adopts `on_crash=preserve`. Until the pubkey is added the job fails closed (`ssh_unreachable` → ImmichVMHealJobFailing) — the correct signal. Tier-1 guest self-heal shipped earlier in Step-4; the remaining Path-B piece is 4E (Immich pod cutover), still design-gated.

### 2026-07-10 — UFW reload isolated W2 for 90 min → reload gated + node_isolation_heal watchdog

**Incident:** the firewall role's pre-heal ran `ufw reload` UNCONDITIONALLY on every drift-heal; on W2's Realtek r8169 NIC the reload dropped the k3s↔CP tunnel → 90 min NotReady + SSH-dead (kernel alive — firewall wedge, not a crash), manual power-cycle to recover. W2/NAS are Realtek, CP/W1 Intel igc — only W2 loses the reload↔tunnel race. **Fix** `ff2b486b`: reload now gated on `repaired>0` (verified live). No existing self-heal caught the state ("network-isolated, UFW active, agent process up") → new **`node_isolation_heal`** role (`68f114d0`, workers-only, ships DRY-RUN): probes the CP tunnel, ladder L1 restart `k3s-agent` → L2 staggered self-reboot (W1 15 min / W2 23 min, leaderless so both workers never reboot together), guards (boot-loop uptime, ≤1 reboot/24 h, maint-hold), 22 ladder tests. Post-soak follow-ups (maint-hold wiring, shared cooldown, VMRules, dry-run flip) tracked in memory `gotcha_ufw_reload_node_isolation`.

### 2026-07-10 — immich-vm joined k3s as 4th node (GPU worker)

Path-B STEP-4: the Arch VM on the NAS (`immich-vm`, 192.168.1.231, Intel QSV via passthrough) joined the cluster as a `k3s-agent` worker — the landing node for immich-server (cutover completed 2026-07-12, see above). Onboarded into ansible node-maintenance (`immich_gpu_node` role; in `workers` for k3s + clusterip_heal, in `virtual` to carve it out of in-guest reboots and node_isolation_heal — GPU reset-bug). Node-count references: 4 nodes (3 physical + 1 VM).

### 2026-07-10 — k3s v1.36.1 → v1.36.2 patch + trivy scan concurrency 2→1

**k3s patch upgrade** (`v1.36.1+k3s1` → `v1.36.2+k3s1`, same-minor patch on the stable channel). Binary-swap via `k3s-upgrade` skill: staged the new binary to all 3 nodes (sha256-verified, old kept at `k3s.prev`), activated through the sanctioned serial rolling-restart (CP→W1→W2). Zero workload disruption, ~10 min. No repo commit — k3s is a manual `/usr/local/bin/k3s` binary, not Flux/pacman-managed. Rollback = swap `k3s.prev` back (patch-level is cleanly reversible); cleanup `k3s.prev` after ~1 week stable.

**trivy `scanJobsConcurrentLimit: 2 → 1`** (`5a882546`, CI green; Codex skipped — single-int tuning, no bug-class surface). The upgrade's rolling restart triggered a full-fleet trivy rescan → the upstream #2859 fs-cache-lock storm (`cache may be in use by another process: timeout`), 33 err/min peak. This is the same self-healing churn documented 2026-07-05; it drains on its own and reports are still produced, but concurrency=2 wasn't enough to keep it quiet post-reboot. Serializing scan pods (limit=1) dropped the post-restart error rate to ~0. Trade-off: full-fleet rescan now serial (slower) — fine for 93 workloads. Note: pod-level concurrency can't fix the *intra-pod* multi-container contention (grafana+sidecar, home-assistant init trio) that #2859 also covers; limit=1 only removes pod-vs-pod contention. Verify-time gotcha now documented in the `k3s-upgrade` + `cluster-reboot` skills so the transient scan-Error wave isn't re-investigated as reboot damage.

### 2026-07-06 — rebuilderd (reproducible-build farm) removed cluster-wide

Removed rebuilderd + `archlinux-repro` from both workers: packages, all systemd units (worker / metrics / watchdog / boot-timer / repro-cleanup / sync), the `/mnt/*/repro` + `/mnt/*/rebuilderd-worker` caches, the node-exporter textfile metric, the ansible `rebuilderd` role, the `rebuilderd-alerts` VMRule group, and every rebuilderd-motivated node-alert carve-out (`CPUThrottlingHigh` + `NodeMemoryMajorPagesFaults` worker exclusions dropped; `NodeHighIOWait` 15%/15m→10%/10m; `NodeDiskIOSaturation` 20/1h→10/30m). The `rebuilderd-progress` Claude skill was retired alongside (separate chezmoi repo).

**Why:** the build farm chronically saturated worker-node-2 and disrupted co-located latency-sensitive workloads. 2026-07-06 incident: load ~11, 7.6 GB swap thrash, 17× `cicc`/`nvshmem` cgroup-OOMs starved the node's DNS/flannel path → the co-located MySQL replica lost DNS (`-2` NONAME) → its replication IO thread hit 3/3 retries and stopped → `StatefulSetReplicasMismatch` + `MySQLReplicaExporterDown` that don't self-heal. Same class as the OOM→MySQL-pod-kill incidents that forced `MemoryMax` down 18G→8G (2026-02-21, 04-26, 05-22) and the chronic W2 DiskPressure from the repro cache. The resource-tuning arms race stopped being worth the idle-capacity contribution.

Executed via a one-shot `rebuilderd_teardown` ansible role wired into the workers drift-heal (removed after the nodes verified clean). Plan: `docs/superpowers/plans/2026-07-06-rebuilderd-removal-plan.md`. Codex peer-reviewed (SHIP-WITH-FIXES; all applied).

### 2026-07-05 — trivy CVE triage: ignore-unfixed + weekly digest, 3 upstream issues

First real triage of the 21 `TrivyCriticalVulnerabilities` alerts (trivy-operator installed 07-04). **0 on our own images** (claude-telegram-bot clean) — all 3rd-party. ~90% are base-OS / system-lib CVEs (perl/glib/zlib/mesa/sqlite/mariadb-client/Go-stdlib/chromium/kernel-headers) — the same CVE recurs across 12+ unrelated images = shared base layers, unactionable (only a Debian/base rebuild fixes them). App-level (maintainer-fixable) deps sit in only 4 apps, and none is fixable by an image bump (all already pinned to their latest release).

- **Filed 3 upstream issues** (verified below-fix, no existing tracking): paperless-ngx #13092 (Django 5.2.7→5.2.8 CVE-2025-64459 SQLi; nltk 3.9.2→3.9.3 CVE-2025-14009 **CVSS 10.0** zip-slip), linkwarden #1733 (fast-xml-parser/shell-quote/i18next-fs-backend transitive; handlebars already tracked = upstream Dependabot PR #1654; vitest dev-only N/A), uptime-kuma #7572 (protobufjs 7.2.6→7.5.5 CVE-2026-41242). audiobookshelf form-data = accepted-risk, not filed (transitive via ancient axios 0.27.2, maintainer declines per-CVE bumps — closed #5182).
- **Shipped (`e0756d47`, CI green, Codex-reviewed)**: `trivy.ignoreUnfixed: true` (drops unpatchable base-OS noise — verified **28→14** critical reports; clears authentik/cnpg-postgres/cnpg-pgbouncer/immich ×2/python-slim, slims uptime-kuma 126→71, paperless 35→8) + demoted the alert to a **weekly `telegram-digest`** receiver (compact 1-line-per-image HTML, cap 25 lines for the TG 4096 limit, `group_by:[alertname]`, `repeat_interval:168h`; `critcount` annotation carries the per-image count). `alertmanagerSpec.retention:192h` REQUIRED so 168h isn't GC-capped to ~5d (AM nflog default 120h — Codex catch). HTML parse_mode not MarkdownV2 (CVE IDs / version tags are full of dots+dashes → a MarkdownV2 escape-miss = TG 400-reject = silent non-delivery).
- **Decision**: keep trivy **cluster-wide**, not scoped to our images — its unique value over Renovate is surfacing fixable CVEs on 3rd-party images we're already on the latest of (Renovate's blind spot; proven by the paperless CVSS-10 nltk). We build ~1 image, CI-scannable in its own repo.
- **Gotcha**: do NOT mass-delete VulnerabilityReports to force a re-scan — it drops the metric → alert resolves → re-created reports re-arm `for:6h` (no digest ~6h), AND triggers the upstream #2859 cache-lock scan storm (`cache may be in use by another process: timeout`) on multi-container pods. Both self-heal (retries converge); restart a single workload pod instead.

### 2026-07-04 — Monthly review + first quarterly automation audit

Posture sweep (3 parallel agents: cluster, nodes-SSH, GitHub): **no FAIL findings**. Flux 7/7, CI green, certs 19/19, backups zero failed jobs, disks healthy (W2 extra-storage 28%), node-maintenance all success + updates 0 (weekly run rebooted fleet this morning), Popeye A (90), no open PRs, no rotations due before 2026-10-01.

Shipped (commits `e78a033f`, `492911f9`, `eb0774b7`):
- **Kyverno soak day-0 findings** (the dual-run caught real divergence classes on day 0):
  - `require-networkpolicy` VP twin had `autogen: controllers: []` on a WRONG premise — live polr proves the CP autogen is ACTIVE (namespaces-only exclude). Twin autogen enabled; `npcount` switched to `request.namespace` (autogen clones rewrite `object.metadata` to template metadata; request.* live-verified populated in background reports).
  - **Kyverno suppresses autogen on selector-bearing rules**: the 5 CPs with label-selector excludes (resource-limits, readonly-rootfs, drop-all-capabilities, privilege-escalation, host-namespaces) report Pod-only cluster-wide — they NEVER checked controllers. Their CEL twins do (matchConditions ≠ selectors) — deliberate strengthening, kept.
  - First strengthened-coverage catch: `main-mysql-haproxy` mysql-monit sidecar had no template limits (ran on databases LimitRange defaults 1cpu/1Gi, invisible to the CP). Fixed via Percona CR `sidecarResources` (20m/32Mi–200m/128Mi); haproxy rolled clean.
  - `kyverno-vp-parity.sh` reworked: vp-canary excluded (structural), VP-only all-SKIP groups filtered (report-shape: CP exclude = no row, twin matchCondition = skip row), new **Class 2e** prints fail/error from strengthened coverage. Live after fixes: class1=0, class2=125 (all networkpolicy CP-only — clears as twin-autogen reports regenerate), 2e=1 (mysql-monit, clears on rescan), class3=0.
- **Alertmanager HA was theater**: vmalert `notifier` single service URL pinned one endpoint — alertmanager-0 held ZERO alert state (not even Watchdog). Switched to `notifiers[]` with both pod FQDNs (gossip dedupes); AM-0 verified receiving.
- **n8n statement_timeout claim REFUTED**: trial-removed `DB_POSTGRESDB_STATEMENT_TIMEOUT=0` per n8n#25705 community report (fixed ≥2.17.3) — 2.28.6 crash-looped with `unsupported startup parameter: statement_timeout` (old pod kept serving, zero downtime). Reverted with evidence; workaround stays.

Investigated / closed without code:
- **Redis master on W2** (silent pin drift): 3 sentinel failovers all bounced — ot redis-operator records `status.masterNode` and repairs topology back; sentinel-only pin no longer sticks. Replication healthy, apps clean (master-following Service), W2 flannel issues resolved 06-05 → **drift accepted**, db-primary-pin caveat updated.
- **immich-backup missed 06-28 slot**: pre-hardening `startingDeadlineSeconds: 600` miss; manual make-up ran 06-28 13:57; sds now 3600. Verify 07-05 03:00 UTC slot fires.
- **rkhunter suspects 27→50 lockstep all 3 nodes** (rootkits 0, warnings +25 uniform) — post-update baseline drift; `--propupd` + re-scan DONE same day (user TTY): property-change warnings cleared, remaining 7/node = permanent known-noise set (egrep/fgrep/ldd script-replacements, SSH Protocol legacy check, /etc/.updated + krb5 man hidden files), identical across nodes.
- Upstream re-checks: authentik client-hints shipped 2026.5.0 (we run 2026.5.3; passkey-first solid for a month → watch CLOSED). k8s-sidecar#531 open (loki probes stay disabled). Stirling#6211 open, PR #6475 unmerged (fine on 2.11.0-fat). Passkey lockout watch CLOSED (no edge cases). UR2 vmalert watch CLOSED (129 rules, 0 unhealthy, no FP storms).
- 16:01 Flux linkwarden webhook alert = transient during kyverno Helm v23 no-op upgrade churn (Flux 2.9.0 controllers restart); apps kustomization recovered same cycle.

**Quarterly automation audit** (first run): 20+ automations inventoried, all firing on schedule. Silent-failure risks: security-scan service has no failure notify (only maintenance unit without ExecStopPost — fix queued), repro-cleanup + k3s-image-gc alert only via the disaster they prevent, rebuilderd textfile metrics need staleness guard check. "Kyverno digest CronJob" struck from checklist (digest = VMRule `KyvernoPolicyViolationsDailySummary`, not a CronJob).

**trivy-operator SHIPPED same day** (`dfeb0153`, chart 0.33.2/app 0.31.2): node-collector + compliance OFF (hostPath + missing resources keys), scan jobs labeled `app=trivy-scan-job` (STRING form — chart renders the key with bare `| quote`, a map silently kills all scan jobs; reviewer-caught CRITICAL), container-SC pinned, scan-job priority homelab-batch, NP default-deny + registry-egress class, VMPodScrape + TrivyCriticalVulnerabilities VMRule (scan-stalled alert deliberately NOT shipped — guessed metric = structurally-dead-alert class). First sweep: 19 reports in minutes, 26 Critical CVEs to triage; multi-container pods hit upstream #2859 shared-cache lock race, operator retries converge. Review by k8s-devops-reviewer (Codex quota-locked); validate.sh clusters name-to-file mapping bug found+fixed same pass.

Decisions: image-CVE scanning = **trivy-operator in-cluster** (shipped same day, see above); CSP Tier B/C = continue via per-app browser verify; POP-1100/1110 mysql-primary Service = accepted operator cosmetic (dropped from monthly checks); W2 rebuilderd relocation deferred (28% disk). Skill stocktake: 6 stale skills fixed (csp-reporter refs, retired `validationFailureAction` column, `clusters/staging.yaml` default, ansible role path, PENDING-table ref).

Restart message said CLI 2.1.197 while local was 2.1.201 — investigation found THREE divergent CLI copies: (1) the **actual engine**, the binary vendored in `@anthropic-ai/claude-agent-sdk-linux-x64-musl`, frozen at **2.1.119 (2026-04-23)** because package.json pinned `^0.2.119` (caret on 0.x blocks minor bumps; npm latest was 0.3.201) AND the Dockerfile ran `bun install` against the committed `bun.lock`, so the bi-weekly image rebuild's BUILD_TS cache-bust refreshed **nothing** — the "dependency refresh" was theater since the lock landed; (2) the restart-report version from `npx @anthropic-ai/claude-code` = stale `~/.npm/_npx` cache on the PVC (2.1.197); (3) the image's npm-global 2.1.201 install — **shadowed by the PVC mount at `/home/akhozya`**, unreachable at runtime, dead weight (also the source of the `EBADENGINE` node-20-vs-22 build warn).

Fix (fork `2308383` + image 1.27.4): package.json → `^0.3.195`, Dockerfile deps stage → `bun update` (refreshes ranges past the lock each rebuild) + `COPY bunfig.toml` (7-day `minimumReleaseAge` supply-chain gate now in build context), npm-global CLI install deleted; deployment init `CC` → the SDK-vendored musl binary (one version of truth — engine and plugin-sync CLI are the same file) and the restart message reports that binary's version. SDK 0.3.X vendors CLI 2.1.X lockstep. **Residual**: CI `bun update` resolved 0.3.201 despite the 7d gate (image bun predates `minimumReleaseAge` or `update` bypasses it) — gate ineffective in builds for now; drift stays visible via the now-honest restart message.

---

### 2026-07-04 — Kyverno CP→VP migration Phase 1: 12 CEL ValidatingPolicy twins in Audit + vp-canary

`kyverno.io/v1` ClusterPolicy removal lands Kyverno 1.20 (~Oct 2026). Phase 1 of the 4-phase migration: every CP now has a `policies.kyverno.io/v1` ValidatingPolicy twin (SAME name, `validationActions: [Audit]`) dual-running against the Enforce CP — PolicyReports carry both engines (`source: kyverno` vs `KyvernoValidatingPolicy`), parity compared by `docs/scripts/kyverno-vp-parity.sh` (3 jq classes). **Soak: 2026-07-04 → ≥07-11** (covers weekly CronJobs), then Phase 3 Deny-flip/CP-delete (2 commits, gated).

Design (source-verified against kyverno 1.18.1 `pkg/cel/autogen`): bare-pods `matchConstraints` ONLY (anything more silently kills autogen — CanAutoGen gate); all excludes as `matchConditions` CEL (`request.namespace` for ns — never rewritten by autogen; `object.metadata.?labels[...]` for workload excludes — rewritten to template labels in clones, desired); optional-chain defaults reproduce hard-anchor semantics (`orValue(<fail-value>)`); container-set parity per-CP (ephemeralContainers only where the CP had it; resource-limits: no ephemeral — API-impossible). `require-networkpolicy`: autogen explicitly off, `resource.List` for NP count, both 2026-07-03 teardown-wedge fixes carried. `vp-canary`: Deny from day one, matches only `vp-canary-test=fail` pods — Phase-3 Gate A proof that the VP Deny path is live with no CP masking.

Offline validation (kyverno CLI 1.18.1): 12 VPs × 10-resource corpus → error=0, every targeted assertion exact (autogen fires on controllers, ns/label excludes honored, non-root anyPattern branch non-mixing preserved, canary isolates); `require-networkpolicy` VP against live cluster read-only: pass=85 fail=0 error=0. **Engine finding**: VP emits ONE result per (policy, resource) — multi-validation short-circuit — so `require-resource-limits` reports cp=2/vp=1 structurally; parity script Class 3 carries that exact exception (verify-early-in-soak note inside) and Class 1 compares worst-of-source. Review-invariants: new CEL section (CanAutoGen silent-kill, request.namespace-vs-object rewrite, orValue soft-anchor rebirth, per-CP container sets, 3-class parity).

---

### 2026-07-04 — Loki chart lineage migration → grafana-community 18.4.0

`grafana.github.io` loki chart went GEL-only (frozen at 7.0.0 for OSS) — Renovate was blind to OSS Loki updates. Repointed the HelmRelease to the community fork (`grafana-community/helm-charts`, strict-semver continuation of 6.55.0). Main `8f2e54ea`.

| Change | Detail |
|---|---|
| Chart 7.0.0 → **18.4.0** (app 3.6.7→3.7.3) | New `grafana-community` HelmRepository added ALONGSIDE `grafana` (alloy still consumes the old repo; fork hosts no alloy chart). In-place STS roll (immutables verified identical to live pre-merge), PVC `storage-loki-0` reused, helm history continued (`loki.v30`). |
| `deploymentMode: SingleBinary`→`Monolithic` | 18.x rename; SSD `backend/read/write: replicas: 0` stanzas kept (chart validate.yaml requires them zeroed). |
| postRenderers block **deleted** | priorityClassName now via values (`global.priorityClassName` + separate `lokiCanary.priorityClassName` — global does NOT reach canary); seccompProfile RuntimeDefault chart-native on all 3 workloads. Render-verified before merge. |
| `gateway.image.tag: 1.31.2-alpine` pin | Chart default floats `1.31-alpine` (live had floated `1.29-alpine` — pre-existing image-pin violation this migration fixes). |
| `gateway.metrics.enabled: false` | 18.x default-on nginx exporter sidecar renders with empty resources (Kyverno enforce-limits would block) + port 4040 absent from NetworkPolicy. Enabling later = deliberate change with resources + NP port. |

Verified live: LokiDown silent, alloy dropped-entries rate 0, canary writing with 0 missing, gateway 1-container. Migration plan was 2-round Codex-reviewed pre-implementation; implementation diff PASS zero findings. Render-parity proof: final render byte-identical to pre-validated artifact except the intended image pin.

**Incident (~20 min post-deploy, fixed same day `d1b586ca`):** loki-0 CrashLoopBackOff — chart 18.x newly enables a healthz server + probes on the `loki-sc-rules` sidecar (7.0.0 had neither); k8s-sidecar's health server binds dual-stack and its thread dies on IPv4-only kernels ("Unsupported address family", upstream **kiwigrid/k8s-sidecar#531**, open — reproduces on old 2.5.0 image too, probes are the trigger) → liveness connection-refused → kill every ~2.5 min. Ingest never dropped (distributor ~39 lines/s, alloy drops 0, canary 0 missing). Fix: `sidecar.readinessProbe.enabled=false` + `livenessProbe.enabled=false` (chart flags, restores exact 7.0.0 posture; rules watcher is a separate thread — worked for months with the same silently-dead health thread). Both probes required: readiness alone leaves the pod NotReady forever. Re-enable when #531 ships HEALTH_HOST.

---

### 2026-07-03 — Deferred-item cleanup (post-ultrareview) + Kyverno namespace-teardown deadlock fix

Shipped 4 deferred items from the 2026-07-03 ultrareview backlog, staged as separate merge+reconcile waves to serialize cluster ops. Main `df521682`→`d771464d`.

| Change | Detail |
|---|---|
| Percona `crVersion` 1.0.0→**1.2.0** | Matched ps-operator chart (already 1.2.0 via Renovate #874) — CR + comments had lagged. SmartUpdate rolled replicas-first, primary-last, converged Ready (HA held: PDB `minAvailable:1` + HAProxy; transient `get cluster primary: empty response` during the primary switchover is expected). |
| ClusterIssuer `letsencrypt-staging`→**`letsencrypt-prod`** | The "staging" issuer always pointed at the **prod** ACME server — pure misnomer. Renamed issuer + `privateKeySecretRef` + all 16 Certificate `issuerRef`s; cert-manager re-issued all 16 against prod (old TLS secrets kept serving → no downtime; 16 < 50/week LE limit). Old `letsencrypt-staging` account-key Secret orphaned (harmless). |
| csp-reporter **GC'd** | Dead component: apps middleware `report-uri` already omitted, monitoring's pointed at a browser-unreachable cluster-internal HTTP sink → collected nothing. Removed Deployment+ns+NP+svc+SA + resource-governance entry + stale report-uri. Browser-console is the CSP-verify path. |
| Redis-HA + CouchDB instance CRs → **configs layer** | Operator/instance-layer parity with postgres+mysql. Gapless controllers→configs move via `kustomize.toolkit.fluxcd.io/prune: disabled` (2-stage: annotate live → then move+strip; `infrastructure-configs dependsOn infrastructure-controllers` so controllers reconciles+prunes FIRST — a single-`fr` whole-branch merge would prune-before-adopt = ~1-2min Redis/CouchDB outage). CouchDB zero restart; Redis rolled once — the opstree operator mirrors CR labels onto the StatefulSet, so the Flux ownership-label flip triggered a pod recreate, Sentinel-HA absorbed it. |

**Incident (found + fixed mid-rollout):** Kyverno `require-networkpolicy` (Enforce) **wedged the csp-reporter namespace teardown**. The shared `validate.kyverno.svc-fail` webhook fires on DELETE too, so once the ns's NetworkPolicy was pruned (netpolcount→0) the deny blocked the Deployment/RS/Pod DELETE → ns stuck `Terminating` indefinitely (can't recreate an NP in a Terminating ns → deadlock). Fix: scope the rule to `operations: [CREATE, UPDATE]` + a precondition skipping objects carrying a `deletionTimestamp`. Latent since require-networkpolicy went Enforce (2026-05-25); affects **every** namespace teardown, not just this one. New review-invariant class recorded.

---

### 2026-07-03 — Deprecation audit (helm chart values + repo YAML + Flux/CRD APIs)

Fan-out audit of all 12 HelmRelease values against their pinned upstream charts, every repo apiVersion/field, Flux APIs, and live `apiserver_requested_deprecated_apis`. Every fix proven render-identical via `helm template` before/after diff (except 2 intended changes). Codex static peer review (1 MEDIUM catch: obsidian init-script re-applied legacy CouchDB keys).

**Fixed (this commit):**
- immich: deleted dead `serviceAccount:{create,name}` values block (bjw-s common ≤3.x shape; SA attachment actually done by postRenderer) — was hard-blocking chart 0.13+ (`values.schema.json` rejects it). Render diff: chart now emits its 2 default SAs (harmless; matches post-0.13 state). Deleted dead envs `IMMICH_METRICS` (removed in server 1.119.0; telemetry injected by chart via `immich.metrics.enabled`) + `IMMICH_MEDIA_FFMPEG_ACCEL` (never an upstream var; VAAPI configured in admin UI)
- immich: HelmRepository → `oci://ghcr.io/immich-app/immich-charts` (HTTP repo frozen upstream; 0.13+ OCI-only — Renovate was blind to upgrades)
- flux: Alert `spec.summary` → `spec.eventMetadata.summary` (deprecated; removed at Alert v1 GA, Flux 2.10 ~Q4 2026)
- kube-prometheus-stack: deleted phantom `grafana.rbac.extraPermissions` (key never existed in grafana chart; sidecar RBAC auto-generated)
- kyverno: deleted 3 phantom values keys (`features.backgroundScan.interval` — real key `backgroundScanInterval`; `config.webhookMatchConditions` — real key `matchConditions`; top-level `metricsService` — chart-v2 shape). All no-ops, defaults = intent
- redis-operator: deleted phantom `serviceMonitor.enabled` + entire `serviceAccount` block (keys never existed in chart, any version; SA gated on `rbac.enabled`, `automountServiceAccountToken` value = chart default)
- couchdb: deleted 5 dead ini keys — `[compactions]._default` (2.x daemon; smoosh since 3.0 — **intended 70%/60% fragmentation thresholds were never in effect**), `chttpd.max_http_request_rate` (Cloudant-ism, not a CouchDB option — **believed rate limiting never existed**), `couchdb.delayed_commits` (option removed in 3.0, behavior hardwired), `chttpd_auth.require_valid_user` + `httpd:{enable_cors,WWW-Authenticate}` (3.2 moved to `[chttpd]`; identical effective copies kept). Obsidian init-script: same 3 legacy config-API writes deleted (Codex catch). CouchDB pods roll once (checksum/config)
- loki: deleted deprecated `monitoring.selfMonitoring` block (false = default). **Refuted during proof**: SSD `backend/read/write: replicas: 0` stanzas are NOT redundant — chart validate.yaml hard-fails SingleBinary without them; kept with corrected comment
- percona: `spec.enableVolumeExpansion` → `spec.storageScaling.enableVolumeScaling` (deprecated in operator 1.2.0, removal 1.5.0; unblocked by the crVersion→1.2.0 bump `3769dc87` — field verified against live CRD). Spec-only toggle, no pod-template change → no roll expected

**Tracked (not fixed here):** Kyverno ClusterPolicy→CEL ValidatingPolicy migration deadline (~Oct 2026, kind deprecated since 1.17, removal planned 1.20); Loki chart lineage → grafana-community (7.x = GEL-only); immich 0.13.1 via Renovate now unblocked.

**Verified clean:** traefik 41.0.1 (schema-strict render proof; `traefik.io/v1alpha1` = only CRD version, no v1 exists upstream), cert-manager 1.20.3 (`crds.*` already), cnpg 0.29.0 (zero barmanObjectStore → 1.31 removal no-impact), alloy 1.10.0, vm-operator 0.65.1 (`v1beta1` current for all VM* kinds, no promotion announced), kube-prometheus-stack 87.6.0 (Alertmanager config already modern matchers), ps-operator 1.2.0 values, couchdb chart keys, all Flux v1/v2 APIs + notification v1beta3 (current through 2.9; deprecated 2.10; removal ≥2 minors later), core k8s all-GA, kustomize v5 fields absent, live apiserver deprecated-API metric ~zero (one `Endpoints` read, no removal planned).

### 2026-07-03 — Ultrareview (6-axis: architecture, approaches, solution, quality, docs, security)

6 dimension reviewers + adversarial verification (52 findings survived) + live-cluster spikes + Codex static review. Fixed in worktree, single-env prod.

| Sev | Finding | Fix |
|---|---|---|
| HIGH | pg_dump/mysqldump/pvc backups reported success on partial dumps (`set -e` w/o pipefail; `pg_dump\|tee` masked exit; missing PVC only warned; mysqldump stderr written into `.sql`) | `set -eo pipefail`, per-DB failure accounting + `exit 1` before packaging; mysql `MYSQL_PWD` + stderr→`.err` sidecar + `--set-gtid-purged=OFF`; missing critical PVC now fails the job |
| HIGH | `NoRecentBackups` structurally dead — 48h threshold vs 24h Job TTL; per-ns `max()` masked a stopped sibling CronJob | Rekeyed on `kube_cronjob_status_last_successful_time` (not TTL-reaped), per-cronjob; split daily (>48h) / immich weekly (>9d). Live-verified |
| HIGH | Backup replication validated AFTER rsync — a corrupt backup overwrote the last good W2 copy (`--delete`) + wiped W1 source | Reordered: validate → abort-before-sync on failure; source preserved, W2/NAS untouched |
| HIGH | Grafana egress NP had no 8429 to VMSingle (dead `prometheus:9090` rule) — every metric dashboard silently unreachable | Added 8429→vmsingle, removed dead prometheus rule |
| HIGH | CI Actions on mutable tags feeding a packages:write / PR-write pipeline | SHA-pinned all third-party + `actions/checkout` in the 2 write-privileged workflows (`# vX.Y.Z` for Renovate) |
| MED | CNPG `enableSuperuserAccess: true` on a false "pooler needs it" premise — untracked live `postgres` superuser secret | `false` (pooler uses cert auth; no consumer of the secret) |
| MED | vmsingle `namespaceSelector:{}` on 8429 = cluster-wide metric WRITE/DoS surface | Removed; 4 scoped consumers (vmagent/vmalert/grafana/uptime-kuma) retained |
| MED | Traefik rate-limits enforcing per-**second** (no `period`) — 60× looser than the "/min" comments | Added `period: 1m`, recalibrated (standard 300, high-freq 600) from measured 7d peaks |
| MED/LOW | HA + claude-telegram bare 443/80 egress reached cluster/LAN CIDRs; DNS component UDP-only (no TCP fallback); uptime-kuma dead all-ports /24 ICMP rule (zero ping monitors) | RFC1918-`except` on 443/80; DNS TCP/53 added; ICMP rule → scoped NAS `.136/32:50555` |
| LOW | CI kubeconform schema pinned 1.31 vs live 1.36; dead dependabot.yml (0 PRs, Renovate owns actions); apps automerge no soak | Schema→1.36.1; dependabot deleted; `minimumReleaseAge: 3 days` on apps automerge |
| docs | DR runbook: wrong NAS rsync module (`akhozya`→`akhozya-pool1`), bare `curl\|sh` k3s install (unpinned + collides with Flux traefik/coredns); no-WAL decision contradicted; serial vs fan-out topology; W1/W2 blast radius understated; stale counts; ufw-reset firewall block | Rewrote DR steps (pinned k3s + ansible config), fan-out topology, honest failure table + no-offsite/self-blind-monitoring ceilings, count refresh |
| MED | External dead-man switch: W2 loss kills VMSingle/VMAlert → every in-cluster alert (incl. NodeDown) goes silent with no external witness | Watchdog VMRule (`vector(1)` — needed because `defaultRules.create:false` dropped the built-in) → AM `deadman` webhook receiver (`url_file` from SOPS secret) → healthchecks.io ping/10m. Owner chose healthchecks.io; live-verified end-to-end. **Owner action: set the check to Period 15m / Grace 15m** |
| LOW | `CronJobNotScheduled` + `BackupCronJobMissedSchedule` false-fired on immich-backup — weekly cadence + off-slot runs leave `.status.lastScheduleTime` stale, so KSM `kube_cronjob_next_schedule_time` sits in the past | Excluded `immich-backup` from both daily-tuned rules; `NoRecentImmichBackup` (9d) covers its staleness. Live-verified healthy (lastSuccessful 5d fresh, delta +5.7d) |
| MED | require-labels/-non-root/-seccomp still Audit (toothless — violators only flagged, not blocked); `validationFailureAction` deprecated since Kyverno 1.13 (live 1.18.1) → silent policy flip on a future chart bump | Pulled the deferred 07-04 item forward: promoted all 3 Audit→Enforce after live soak re-verified clean (199/113/199 pass, 0 fail, 0 live seccomp violators, every CronJob/Job template compliant-or-excluded); migrated all 12 policies to per-rule `validate.failureAction` + updated `check-policy-action.sh`/`prepare-enforce.sh`. Proven live: `--dry-run=server` accepts all 12 + positive admission test denied a labels-only violator |

**Deferred (own change / owner call):** Percona `crVersion` 1.0.0→1.1.0 (rolling restart window); ClusterIssuer `letsencrypt-staging`→`-prod` rename (re-issues 16 certs); Redis/CouchDB instance CRs live in controllers layer vs configs (cross-Kustomization move); monitoring-ns Traefik middleware fork; csp-reporter fork-or-GC; offsite backup (awaiting owner decision — external dead-man switch now shipped, see rows above).

---

### December 2025 Review Findings

| Priority | Issue | Status | Action |
|----------|-------|--------|--------|
| P0 | worker-node-2 has no swap | ✅ FIXED | 16GB LVM swap added (2025-12-18) |
| P0 | Stale mariadb backup directory | ✅ FIXED | Archived and removed (2025-12-18) |
| P1 | Kyverno violations returned (22) | ✅ FIXED | Percona operator limits added (2025-12-18) |
| P1 | Popeye score dropped (87/100) | ✅ FIXED | Score restored to 100/100 (2025-12-18) |
| P1 | ContainerMemoryNearLimit alert | ✅ FIXED | PriceBuddy apprise limit increased (2025-12-18) |
| P1 | Monitoring not HA | ✅ FIXED | Prometheus/Alertmanager 2 replicas with anti-affinity (2025-12-18) |
| P1 | MySQL HAProxy no anti-affinity | ✅ FIXED | Added antiAffinityTopologyKey (2025-12-18) |
| P1 | AdGuard Home DNS missing worker-node-2 | ✅ FIXED | Added 192.168.1.126 to DNS rewrites (2025-12-18) |
| P2 | PVC distribution imbalanced | ✅ ACCEPTED | Expected: worker-node-2 only has DB replicas (110Gi vs 600Gi) |
| P2 | Resource governance reduced | ✅ FIXED | Added quotas for pricebuddy, backup-replication, percona-mysql (2025-12-18) |

**Full Details**: See git history for HOMELAB_REVIEW_2025_12_17.md

---

### Code Review Findings (2025-12-23)

**Source:** `CODE_REVIEW_2025_12_23.md` (archived — see `git log`)

#### High Priority (This Month)

| # | Item | Effort | Impact | Status |
|---|------|--------|--------|--------|
| 41 | Add PostgreSQL egress NetworkPolicy | 30 min | Security | ✅ Done (9589c59) |
| 42 | Add Loki health alerts | 1 hour | Observability | ✅ Done (9589c59) |
| 43 | Document secrets rotation schedule | 1 hour | Security | ✅ Done (SECRETS_ROTATION.md updated) |
| 44 | Enforce `disallow-latest-tag` Kyverno policy | 15 min | Security | ✅ Done (9589c59) |
| 45 | Add Traefik service alerts | 1 hour | Observability | ✅ Done (9589c59) |

#### Medium Priority (This Quarter)

| # | Item | Effort | Impact | Status |
|---|------|--------|--------|--------|
| 46 | ~~Create Kustomize components for DRY~~ | N/A | N/A | ❌ Declined (complexity vs benefit) |
| 47 | ~~Standardize NetworkPolicy label selectors~~ | N/A | N/A | ✅ Documented as intentional design |
| 48 | Add backup monitoring Grafana dashboard | 2 hours | Observability | ✅ Done (grafana-dashboards/) |
| 49 | Document RBAC decisions per app | 2 hours | Documentation | ✅ Done (CODE_REVIEW §5.RBAC) |
| 50 | ~~Add Etcd availability alerts~~ | N/A | N/A | ❌ N/A (K3s single-master uses SQLite) |

#### DRY Refactoring Opportunities

**Status**: ❌ Declined (2025-12-23) - Complexity outweighs benefit for homelab scale.

Duplication exists but is acceptable for transparency and ease of maintenance.

---

### ✅ Completed Action Items (Archive)

#### 1. ✅ **COMPLETED: Fix wallabag PVC Namespace Leak** - P0
   - ✅ Deleted duplicate 60GB PVCs in wrong namespace
   - ✅ Recovered 60GB storage
   - ✅ Current PVCs correctly sized: 15GB total (5Gi data + 10Gi images)
   - ✅ Actual usage: 12KB total (8KB data + 4KB images)
   - ✅ No abandoned PVCs remaining on disk
   - Commit: a235309

2. ✅ **COMPLETED: Add Missing NetworkPolicies** - P0
   - ✅ wallabag, n8n, linkding, audiobookshelf
   - ✅ All 7 apps now have NetworkPolicies
   - Commit: a235309

3. ✅ **COMPLETED: BACKUP INFRASTRUCTURE** - P0 **CRITICAL** ⭐
   - ✅ **Status:** FULLY IMPLEMENTED - Complete backup infrastructure operational
   - ✅ **PostgreSQL Backups:** Daily at 2:00 AM, 30-day retention
     - Location: `/mnt/k8s-storage/backups/postgres/`
     - Covers: All 10 databases (Authentik, Immich, Paperless, Grafana, etc.)
     - Method: pg_dump via CronJob, tar.gz compression
   - ✅ **CouchDB Backups:** Daily at 2:30 AM, 30-day retention
     - Location: `/mnt/k8s-storage/backups/couchdb/`
     - Covers: obsidian-personal database
     - Method: couchbackup via CronJob, tar.gz compression
   - ✅ **PVC Backups:** Daily at 3:00 AM, 3-day retention
     - Location: `/mnt/k8s-storage/backups/pvc/`
     - Covers: Home Assistant, Immich library, Paperless, Audiobookshelf
     - Method: tar with selective compression (gzip for configs, uncompressed for media)
     - Optimization: Skips compression on media files (saves 25 min/backup)
   - ✅ **Disaster Recovery Scripts:** Complete in `.backup/` directory
     - `secrets-backup.sh` - Backs up all 50+ Kubernetes secrets
     - `secrets-restore.sh` - Restores secrets to cluster
     - `disaster-recovery.sh` - Automated full cluster recovery
   - ✅ **Documentation:** Comprehensive (3 documents)
     - `docs/BACKUP_STRATEGY.md` - Overall strategy and retention
     - `docs/BACKUP_IMPLEMENTATION.md` - Technical implementation details
     - `docs/BACKUP_COMPRESSION_ANALYSIS.md` - Optimization analysis
   - ✅ **Storage:** 4.2TB available on `/mnt/k8s-storage/backups/` (was 48.9GB root partition)
   - ✅ **Resource Optimization:** 32Mi memory, selective compression
   - 📋 **Next:** Test disaster recovery procedure, implement backup validation
   - Commits: Multiple (470972a, 4f400ae, 2ba824d, 9464f7a, 74f448a, bff6c87)

4. ✅ **COMPLETED: Enable Pod Security Standards** - P1 ⭐
   - ✅ Applied Pod Security Admission at namespace level (all 16 app namespaces)
   - ✅ **100% PSS COMPLIANCE ACHIEVED** (2025-10-26)
   - ✅ **RESTRICTED policy**: 11 apps (authentik, audiobookshelf, homepage, homehub, immich, linkding, mealie, n8n, stirling-pdf, uptime-kuma, obsidian)
   - ✅ **BASELINE policy**: 4 apps (adguard-home, paperless-ngx, wallabag, couchdb)
   - ✅ **PRIVILEGED policy**: 1 app (home-assistant - NET_ADMIN/NET_RAW for Bluetooth)
   - ✅ Fixed security contexts: Wallabag (explicit runAsUser), Immich (runAsNonRoot, proxy sidecar)
   - ✅ PSS Adjustments: Home Assistant (baseline→privileged), Paperless-NGX (restricted→baseline), Stirling PDF (removed root init)
   - Impact: Enhanced pod-level security compliance with Kubernetes security standards
   - Commits: 3c3c0d1, 916b883, ab388f5, 0874dfd, a5e67b8, ca3891c, 7f12be2, 8162673, d3b5036

5. ✅ **COMPLETED: Document Home Assistant Security** - P1 ⭐
   - ✅ Created `apps/base/home-assistant/SECURITY.md` (comprehensive 250+ line documentation)
   - ✅ Explained root requirement and security rationale (7 Linux capabilities documented)
   - ✅ Documented security mitigations (seccomp, capability dropping, privilege escalation disabled)
   - ✅ Risk assessment (MEDIUM risk level with detailed attack vector analysis)
   - ✅ Comparison table with other apps showing Home Assistant's elevated privileges
   - Impact: Clear security documentation for most privileged workload in homelab
   - Commit: 3c3c0d1

6. ✅ **COMPLETED: Complete Immich Pod Security Standards** - P1 ⭐
   - ✅ Fixed Immich Server security context (init container, proxy sidecar)
   - ✅ Removed dri-devices hostPath mount (PSS restricted violation)
   - ✅ Added pod-level securityContext (runAsUser, fsGroup, seccompProfile)
   - ✅ Added wait-for-database init container security context (runAsNonRoot, readOnlyRootFilesystem, capabilities.drop)
   - ✅ Added proxy sidecar security context (nginx with /tmp config, runAsNonRoot, capabilities.drop)
   - ✅ Tested full Immich deployment - both ML and Server running with 2/2 containers
   - ✅ Verified functionality via browser - photo library loading correctly
   - Impact: All 16 homelab applications PSS-compliant (initial completion, refined 2025-10-26)
   - Commits: abca249, aac279b, 7481664, 3263745

7. ✅ **COMPLETED: Node Drain Verification & Final PSS Fixes** - P1 ⭐
   - ✅ Restarted all 16 applications to verify PSS compliance
   - ✅ Fixed 3 apps with PSS violations (Home Assistant, Stirling PDF, Paperless-NGX)
   - ✅ Performed worker node drain with proper kubectl drain command
   - ✅ Recovered from PostgreSQL WAL corruption during drain (zero data loss)
   - ✅ Updated Authentik RAM allocation (1GB request, 1.2GB limit)
   - Impact: **100% PSS compliance validated** for all 16 homelab applications, node drain procedures verified
   - Commits: 0874dfd, a5e67b8, ca3891c, 7f12be2, 8162673, d3b5036, abb323c

8. ✅ **COMPLETED: Pod Security Standards for Jobs** - P1 ⭐
   - ✅ Fixed 6 init/setup jobs with PSS violations (all now working)
   - ✅ **PSS RESTRICTED** (5/6 jobs - 83%): audiobookshelf-init, immich-admin-setup, n8n-user-provision, couchdb-init, uptime-kuma-setup
   - ✅ **PSS BASELINE** (1/6 jobs - 17%): mealie-user-provision (requires root for apt-get install)
   - ✅ Security controls: seccompProfile:RuntimeDefault, allowPrivilegeEscalation:false, capabilities drop ALL, resource limits
   - ✅ mealie job requires: runAsUser:0, capabilities add [CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID]
   - ✅ mealie namespace changed from PSS restricted to baseline (documented limitation)
   - Impact: **100% PSS compliance for jobs** (6/6 working), enhanced job security posture
   - Documentation: `/tmp/PSS_JOBS_SUMMARY.md`
   - Commits: 0bd0be2, 3003c9a, 52dc11e, 101e4f9, ac839ff, 0858cc8

9. ✅ **COMPLETED: Flux Timeout Standardization** - P1 ⭐
   - ✅ Standardized all 6 Flux kustomizations to 45s timeout
   - ✅ **Before**: infrastructure-controllers (5m), infrastructure-configs (10m), apps (5m), monitoring (5m each)
   - ✅ **After**: All kustomizations use consistent 45s timeout
   - ✅ Verified all kustomizations reconciled successfully with new timeout
   - Impact: Predictable reconciliation behavior, faster failure detection
   - Commit: 4cc2834

10. ✅ **COMPLETED: Performance Optimization** - P1 ⭐
   - ✅ Completed performance and security audit (2025-10-26)
   - ✅ Optimized 3 over-provisioned apps (Stirling PDF, Paperless-NGX, Immich ML)
   - ✅ **Memory savings**: 7.5Gi (62.5% reduction)
   - ✅ **Efficiency improvement**: 69% → 91% memory utilization
   - ✅ Created `docs/PERFORMANCE_SECURITY_AUDIT.md` (335+ lines)
   - Impact: Better resource utilization, improved scheduling efficiency
   - Commit: 45664d6

9. ✅ **COMPLETED: Secrets Rotation Framework** - P1 ⭐
   - ✅ Created comprehensive secrets rotation playbook (2025-10-26)
   - ✅ Documented 20+ secrets inventory (DB, Redis, OIDC, TLS)
   - ✅ Defined rotation schedules (90/180/365 day cycles)
   - ✅ Step-by-step procedures with rollback instructions
   - ✅ Emergency rotation protocols
   - ✅ Created `docs/SECRETS_ROTATION.md` (350+ lines)
   - Impact: Established security rotation framework
   - Commit: c4abd54

10. ✅ **COMPLETED: App Alternatives Research** - P1 ⭐
    - ✅ Researched alternatives for all 16 apps (2025-10-26)
    - ✅ Current stack grade: **A+ (96/100)**
    - ✅ 13 apps confirmed best-in-class
    - ✅ Identified Windmill as potential N8N alternative (44% less memory)
    - ✅ Created `docs/APP_ALTERNATIVES_RESEARCH.md` (317+ lines; archived 2026-05-25 → `docs/archive/`)
    - Impact: Validated current infrastructure choices, identified optimization opportunities
    - Commit: c4abd54

#### 11. ✅ **COMPLETED: Add Homepage Dashboard** - P1
    - ✅ Centralized dashboard for all apps
    - Commit: c5b0244

#### 12. ✅ **COMPLETED: Add Uptime Kuma** - P1
    - ✅ Uptime monitoring with automated user setup
    - Commit: 46cc485

#### 13. ✅ **COMPLETED: Add SSO (Authentik)** - P1
    - ✅ SSO platform deployed with PostgreSQL and Redis
    - Commit: 46cc485

#### 14. ✅ **COMPLETED: Create Ingresses for All Apps** - P1
    - ✅ **Completed**: 2025-10-25
    - ✅ **Dual-Access Pattern Implemented**: 10 apps with Traefik Ingress + Cloudflare Tunnel
    - ✅ **Apps Configured**: authentik, stirling-pdf, immich, paperless-ngx, audiobookshelf, mealie, wallabag, n8n, linkding, couchdb
    - ✅ **Features**: Let's Encrypt TLS, AdGuard Home DNS management, NetworkPolicy updates
    - ✅ **Benefit**: Fast local HTTPS access + secure external access via Cloudflare
    - Commits: 2d8921b, ec2f63d

#### 15. ✅ **COMPLETED: Integrate Apps with Authentik SSO** - P2
    - **Completed**: 2025-10-22
    - **Apps Configured via Environment Variables** (3): Paperless-NGX, Linkding, Mealie
    - **Apps Configured via Web UI** (3): Grafana, Immich, Audiobookshelf
    - **Apps with Custom Integration** (1): Home Assistant (hass-oidc-auth, GitOps)
    - **Not Supported** (1): N8N (requires Enterprise plan for SSO/LDAP)
    - **Total OIDC Apps**: 7/10 applications
    - **Configuration Methods**:
      - Declarative (env vars): Paperless-NGX, Linkding, Mealie
      - Database-stored (web UI): Immich, Audiobookshelf
      - Pre-configured: Grafana
      - Custom integration (GitOps): Home Assistant (hass-oidc-auth via HACS)
    - **Note**: N8N Community Edition does not support SSO/LDAP - Enterprise plan required
    - Commit: 5e85276

#### 16. ✅ **COMPLETED: Backup Validation** - P2
    - ✅ **Status:** FULLY VALIDATED - All backups tested and proven restorable
    - ✅ **PostgreSQL:** 2 databases restored successfully (authentik: 178 tables, immich: 49 tables)
    - ✅ **CouchDB:** 337 documents restored successfully
    - ✅ **PVC Backups:** 2,363 files extracted successfully (Home Assistant, Paperless)
    - ✅ **Disaster Recovery Scripts:** All validated (syntax, dependencies, paths)
    - ✅ **Performance:** All restorations complete in <15 seconds
    - ✅ **Data Integrity:** No corruption detected in any backup
    - ✅ **Documentation:** Comprehensive validation report created
    - 📋 **Report:** `docs/BACKUP_VALIDATION_REPORT.md`
    - 🎯 **Next:** Proceed to task #17 (Velero deployment)
    - Date Completed: 2025-10-26

---

### Additional Completed Items (From Comprehensive Review 2025-10-27)

#### 17. ✅ **PostgreSQL NetworkPolicy** - P0-CRITICAL (2025-10-27)
   - Created NetworkPolicy restricting access to app namespaces only
   - Risk: Unrestricted access to all databases from any pod (CVSS: 7.5 HIGH)
   - Files: `infrastructure/configs/base/databases/postgres/networkpolicy.yaml`
   - Commit: a80d4bf

#### 18. ✅ **Duplicate cert-manager ClusterIssuers** - P0-CRITICAL (2025-10-27)
   - Deleted orphaned `controllers/base/cert-manager/clusterissuer.yaml`
   - Kept `infrastructure/configs/base/cert-manager/clusterissuer.yaml`
   - Commit: 2cb9e78

#### 19. ❌ **CNPG WAL Archiving** - P0 REMOVED (Not Implementing)
   - Decision: Not implementing - CNPG barman requires S3/Azure/Google credentials
   - Alternative: Continue with existing pg_dump daily backups (24h RPO acceptable for homelab)
   - barmanObjectStore doesn't support local filesystem paths

#### 20. ✅ **CSP Enforcement** - P1 (2025-10-31)
   - CSP in enforcement mode across all 17 apps (43 days active, zero violations)
   - Policy: `default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'`
   - Monitoring: csp-reporter service → Loki
   - Testing: 85 automated tests (17 apps × 5 scenarios) - 100% pass rate
   - Commits: b8b6306, 7b2c72b, 54c8484, 04df8a4

#### 21. ✅ **Pod Anti-Affinity for PostgreSQL** - P1 (2025-10-29)
   - True cross-node HA with required anti-affinity
   - Instances: 2 (reduced from 3 for 2-node cluster)
   - Anti-affinity: `podAntiAffinityType: "required"` (HARD constraint)
   - main-postgres-5 (Primary): worker-node, main-postgres-6 (Replica): control-plane
   - Commits: cbc71d0, 30c1f8a, 95fe37a, eef307d

#### 22. ✅ **CNPG Port 8000 Binding** - P1 RESOLVED (2025-10-30)
   - Issue: CNPG instance manager silently fails to bind status port 8000 on K3s control-plane
   - Resolution: Removed control-plane toleration, running PostgreSQL on worker-node only
   - Bug report: https://github.com/cloudnative-pg/cloudnative-pg/issues/9013

#### 23. ✅ **PostgreSQL TLS** - ALREADY IMPLEMENTED (2025-10-27)
   - TLS enabled by CloudNativePG, all apps using it (ssl=t in pg_stat_ssl)
   - Minor gap: Could enforce TLS at pg_hba level (host→hostssl)

#### 24. ❌ **Redis Backup** - NOT IMPLEMENTING
   - Redis used only as cache (ephemeral data)
   - Impact: User re-login required, jobs re-queued on pod deletion (acceptable)
   - RDB snapshots on PVC sufficient for cache use case

#### 25. ✅ **Flux Timeout Standardization** - P1 (2025-10-27)
   - All 6 kustomizations standardized to 45s timeout
   - Commit: 4cc2834

#### 26. ✅ **Traefik Health Checks** - ALREADY IMPLEMENTED (2025-10-27)
   - 15/15 apps have readinessProbe and livenessProbe
   - Kubernetes Service endpoints automatically exclude unhealthy pods

#### 27. ✅ **High Availability for Critical Components** - P1 (2025-10-29)
   - Traefik: 2 replicas with pod anti-affinity
   - cert-manager (all 3 components): 2 replicas with pod anti-affinity
   - Cloudflare tunnel: 2 replicas across nodes
   - Control plane tolerations enabled for all
   - Commits: e07474a, 898d969, 6a52f5c, cbc71d0

#### 28. ✅ **Scattered Middleware Configurations** - P1 (2025-10-27)
   - Centralized HTTPS redirect middleware to traefik namespace
   - Before: 15 duplicate middleware files (140 lines)
   - After: Single `traefik/redirect-https` middleware
   - Commit: 9a9ebce

#### 29. ⚠️ **Redis ACLs** - VALID BUT NOT FIXABLE (2025-10-27)
   - Apps don't support key prefixes (broke cache keys when restricted)
   - Current: `~* &* +@all -@dangerous -acl` (all keys, safe commands only)
   - Mitigation: NetworkPolicy restricts Redis access to app namespaces

#### 30. ✅ **Kyverno Phase 1: Service Accounts** - P1 (2025-10-28)
   - require-non-default-serviceaccount policy enabled in Enforce mode
   - Created 16 custom ServiceAccounts, updated 44 manifests, migrated 31 pods
   - Commits: a293197 → 584d3a1

#### 31. ✅ **Kyverno Phase 2: Seccomp Profiles** - P1 (2025-10-28)
   - require-seccomp-runtimedefault policy enabled in Enforce mode
   - Added `seccompProfile: RuntimeDefault` to 23 workloads
   - Commits: 5a68943, 8eaf7ea

#### 32. ⚠️ **Kyverno Phase 3: Resource Limits** - PARTIALLY COMPLETED (2025-10-28)
   - require-resource-limits policy remains in Audit mode
   - 30 violations remain (monitoring sidecars, kube-system)
   - Helm charts don't expose sidecar resource configuration
   - Commit: 5e28d3e

#### 33. ✅ **Backup Integrity Checks (SHA256)** - P2 (2025-10-31)
   - All backup systems generate SHA256 checksums
   - PostgreSQL, CouchDB, PVC backups all validated
   - Bug Fix: PVC script fixed to use relative paths
   - Commit: 0fbbd37

#### 34. ✅ **GPG Secrets Encryption** - P2 (2025-10-31)
   - GPG AES256 encryption with interactive passphrase
   - Files: `.backup/secrets-backup.sh`, `.backup/secrets-restore.sh`
   - Format: `.tar.gz.gpg` encrypted archives

#### 35. ✅ **Rate Limiting Middleware** - P2 (2025-10-31)
   - 100% coverage - All 17 ingresses have rate limiting
   - Standard (11 apps): 100 req/sec, 150 burst
   - High-frequency (5 apps): 200 req/sec, 300 burst

#### 36. ✅ **Security Headers** - P2 (2025-10-31)
   - 100% coverage - All 17 ingresses have security headers
   - HSTS, X-Content-Type-Options, X-Frame-Options, Referrer-Policy, Permissions-Policy, CSP

#### 37. ✅ **PgBouncer Pooler** - VERIFIED (2025-10-31)
   - All apps correctly using `main-postgres-rw-pooler.databases.svc.cluster.local`
   - 3 PgBouncer pods in HA mode

#### 38. ✅ **Database CREATEDB Permissions** - ACCEPTED (2025-10-31)
   - Intentional decision - CREATEDB required for extensions during migrations
   - Immich: 6 extensions, N8N: 1 extension + schema creation
   - Risk mitigated via NetworkPolicies and per-app database users

#### 39. ✅ **Single Instance Redis/CouchDB** - DOCUMENTED (2025-10-31)
   - Redis: Cache data, acceptable loss, <10s restart recovery
   - CouchDB: Obsidian sync, primary data in local vaults, daily backups
   - Trade-off: Simplicity over 99.99% uptime for homelab

#### 40. ✅ **LoadBalancer Documentation** - P2 (2025-10-29)
   - Documented K3s ServiceLB (not MetalLB)
   - Created `infrastructure/controllers/base/servicelb/README.md`
   - Commit: 0da1bd5

#### 41. ✅ **Cloudflare Tunnel Health Checks** - VERIFIED (2025-10-31)
   - Liveness/Readiness probes configured on port 2000
   - ServiceMonitor for Prometheus scraping

#### 42. ✅ **NetworkPolicy Egress Rules** - VERIFIED (2025-11-02)
   - All egress rules validated as legitimate for app functionality
   - 13/16 apps need HTTPS egress for OIDC, external APIs, content fetching
   - Testing: Hardening broke apps, reverted (commit 760d274)

#### 43. ✅ **Prometheus Resource Alerts** - P2 (2025-10-31)
   - 5 new container resource alerts implemented
   - ContainerCPUNearLimit, ContainerMemoryCritical, ContainerNoResourceLimits/Requests

#### 44. ✅ **Extended PVC Backup Retention** - P3 (2025-10-31)
   - Increased from 3 to 7 days
   - Storage impact: +184GB (still only 7.7% of 4.2TB)
   - Commit: 0ac8028

#### 45. ✅ **Secrets Rotation Documentation** - P3 (2025-10-31)
   - Complete baseline rotation tracking in SECRETS_ROTATION.md
   - All rotation dates populated from git history
   - Next rotation dates calculated (Jan-Apr 2026)
   - Commit: ba643a8

#### 46. ✅ **SSH Key Backup Location** - P3 (2025-10-31)
   - Already documented in BACKUP_STRATEGY.md
   - SSH keys and SOPS age key stored in 1Password

#### 47. ✅ **Resource Quotas for All Namespaces** - P3 (2025-10-31)
   - 25 ResourceQuotas deployed (tiered: large/medium/small)
   - Optimized based on actual usage (62% reduction in large/medium tiers)
   - Commits: 8bcf208, 6f0087c

#### 48. ✅ **LimitRanges for All Namespaces** - P3 (2025-10-31)
   - 25 LimitRanges deployed
   - Default: 100m CPU/128Mi RAM request, 1000m CPU/1Gi RAM limit
   - Max per container: 8 CPU/16Gi RAM
   - Commit: 8bcf208

---

## Historical Changelog (2026 — Present; 2025 Oct–Dec archived)

### 2026-07-02 (secret-rotation cadence: 90-day High tier retired → single 180-day) ✅
All scheduled secret rotations move to one 180-day cadence (user decision, 2026-07-01 High batch superseded rather than executed). Ex-High secrets (PG authentik/immich/n8n, MySQL home-assistant, Redis immich → 2026-10-01; Redis admin-password → 2026-10-26) folded into the existing Medium batch. Priority column in SECRETS_ROTATION.md now ranks blast-radius only. Annual infra keys (SSH/deploy/CF mgmt token) and never-rotate classes unchanged.

### 2026-06-29 (CP ClusterIP-wedge auto-heal + Codex pre-commit review loop) ✅
**Maintenance reboot** (post heat-shutdown catch-up: phase1→phase2, all 3 nodes updated, boots CP→W1→W2 ~6min apart, clean) surfaced a gap — the post-reboot **kube-proxy ClusterIP DNAT wedge** hits the **control plane** too, where `clusterip_heal` is workers-only (CP excluded: host-netns probe false-reads + "restart-k3s-on-CP hangs"). Symptom: **uptime-kuma** (deliberately CP-pinned via `nodeSelector`) crashlooped `EAI_AGAIN` on MySQL — EVERY ClusterIP (DNS 10.43.0.10, API 10.43.0.1) dead from CP pods while host + workers were fine. Cleared by a manual `systemctl restart k3s` on the CP (reprogrammed the DNAT, returned cleanly ~30-60s → the "CP restart hangs" caveat **disproven**).
- **Fix** (`c175ab7b`): new `clusterip_heal_cp` ansible role (CP counterpart of `clusterip_heal`). **Pod-netns probe** (nsenter into the coredns-ha pod → curl 10.43.0.1:443/healthz, since host-netns false-reads on the CP) with a **3-state contract** — 0 healthy / 1 wedged **only when EVERY sample is a confirmed connect-failure** / 2 unknown→no-op+preserve-metrics (conservative: the remediation is heavier than a worker's). Remediation = **`timeout 120 systemctl restart k3s`** (hang → give-up+alert, never an indefinite CP wedge). Guards mirror the worker role (cooldown 300s, cap 3/30min, `node_clusterip_heal_giveup` → existing alert); systemd timer OnBoot 2min + every 3min. Deploys on next node-maintenance sync; first live-validates at the next CP reboot.
- **Review loop adopted** (CLAUDE.md): first homelab change through the new **Codex(`xhigh`) static-review → `receiving-code-review` → fix → delta-scoped re-review (cap 3)** pre-commit loop. Codex flagged 2 real false-positive-restart risks (any-bad-sample→wedged; unprobeable-exits-0 cleared the give-up metric) → fixed → round 2 GO. Retired the cavecrew pre-push gate; no Gemini / no PR-babysitting.

### 2026-06-28 (backup-replication: drop rsync `-z` — wasted CPU on LAN) ✅
Step 1 (→worker-node-2 over SSH) + Step 2 (→NAS daemon) used `rsync -avz`. Backups are `.tar.gz` (already compressed) and both hops are LAN → `-z` re-compresses incompressible data, burning CPU on both ends for ~0 size gain. Dropped to `-av`. `infrastructure/configs/backup-replication/cronjob.yaml`.

### 2026-06-28 (backup CronJobs startingDeadlineSeconds 600→3600 — reboot-overrun skip hardening) ✅
6 backup CronJobs (postgres/couchdb/mysql/pvc/immich/backup-replication) fire at 03:00–03:30 with `startingDeadlineSeconds: 600`. A reboot whose recovery overruns the window by >10 min **silently skips** that day's backup (deadline set → no catch-up). Surfaced today after a **planned 5–6 day heat shutdown** (cluster off ~06-23→06-28): `BackupCronJobMissedSchedule`×6 critical + `CronJobNotScheduled`×6 fired. The gap itself was **expected** (cluster powered off; controller healthy — the 06:00-Sun popeye/pg-extension jobs ran today; `*-postreboot` startup jobs backfilled, alerts self-clear after the next on-time 03:00). Bumped deadline to **3600** (catch-up until ~04:00–04:30) so a normal maintenance-reboot overrun still runs the day's backup; `concurrencyPolicy: Forbid` guards overlap. Multi-day shutdowns remain covered by the `*-postreboot` startup jobs, not the deadline.

### 2026-06-28 (immich Redis reboot-survival — point at master-following Service, drop Sentinel client) ✅
**Problem**: after a node reboot Sentinel promotes a new Redis master, but immich's ioredis Sentinel client held the stale old-master connection and never recovered — needed a manual `kubectl rollout restart deploy/immich-server` (recurring; hit again today, obs 6978).
- **Root cause**: ioredis Sentinel uses *passive* failover detection (re-queries sentinels only when the master connection *closes*). On a node reboot the TCP socket to the dead master **half-opens and hangs** (no FIN/RST) → ioredis never detects it, never re-resolves the master ([ioredis#1314](https://github.com/redis/ioredis/issues/1314)).
- **Rejected — `failoverDetector:true`** (`f992bbda`, superseded): active detection via the sentinels' `+switch-master` pub/sub does recover, but triggers a **known ioredis connection leak** — a sentinel-failover test left 301 orphaned subscribe connections (non-draining) and immich-server spinning at ~1.3 CPU. Trades a manual restart for a leak that itself eventually needs one.
- **Fix** (`cc5c02a1`): point immich at the OT operator's master-following Service **`redis-replication-master`** (selector `redis-role=master`) as a **plain** ioredis client. Failover moves to the **infra layer** — on promotion the operator repoints that Service to the new master, so ioredis just reconnects to a stable ClusterIP; no flaky client-side Sentinel discovery. Same pattern paperless already runs. Egress NetworkPolicy unchanged (`redis-replication:6379` already allowed; `sentinel:26379` egress now unused).
- **Verified** (delete master pod = reboot sim): immich auto-recovered in ~18s, pod **RESTARTS=0**, 40 live `ioredis` connections on the re-promoted master, **0** sentinel connections (leak gone), CPU 1344m→2m. No manual restart.
- SOPS secret `immich-redis-url` re-encrypted (sentinels→host); `apps/immich/release.yaml` REDIS_URL comment updated. Note: `cc5c02a1` committed unsigned (1Password agent was locked mid-session).

### 2026-06-28 (backup husk-leak prune fix + immich ML resource bump) ✅
Two small prod fixes shipped this session.
- **Backup husk-leak** (`2e65af1f`): NAS replication `prune_nas_dir` rsync'd `/tmp/empty/` *into* the dated dir, which clears its **contents only** — the empty directory shell ("husk") leaked and accumulated on the NAS. Fixed to operate at the **parent** and scope `--delete` to the target subtree with `--include="/${name}/***" --exclude='*'`, so the dated dir itself is removed; siblings protected by `--exclude='*'` (same idiom as `prune_nas_file`). Clears the chronic empty-dir accumulation noted in memory `reference_nas`. `infrastructure/configs/backup-replication/cronjob.yaml`.
- **Immich ML resources** (`6af4971e`): machine-learning container CPU limit **2000m→4000m** (2×, inference throughput) + RAM limit **2Gi→2355Mi** (+15% — 7-day peak hit ~78% of 2Gi, too thin against OOM). Requests unchanged (200m/512Mi). `apps/immich/release.yaml`.

### 2026-06-28 (NAS admin SSH access + security-posture audit) ✅
Established workstation admin SSH to the backup-sink NAS (`zl-nas`, ZettLab/zettOS Debian 12, `192.168.1.136`): dedicated ed25519 key (`~/.ssh/zl_nas_ed25519`, file-based — deliberately **not** the 1Password agent), port `56634`. Key login is passwordless; `sudo` stays password-gated (no NOPASSWD, by design).
- **Audit verdict — nothing actionable.** No host firewall is loaded (`ufw`/`nftables`/`firewalld` inactive; nft ruleset = libvirt VM-net only, `INPUT policy accept`; `iptables-legacy` empty) → the ZettLab UI "Allow `192.168.1.0/24`" rule is a **no-op**. WAN is safe regardless — via the **router** (zero inbound port-forward), not the NAS rule.
- The one LAN-exposed sensitive service, `zettos-postgresql` (`listen_addresses='*'`), is **auth-blocked**: `pg_hba.conf` permits only `127.0.0.1`/`::1`/local — LAN connections are rejected pre-auth; all real clients are localhost. Appliance-managed configs left untouched (ZettLab clobbers them on update). Details in memory `reference_nas`.
- Appliance is **out of ansible/k3s/UFW scope** — node-maintenance + node-fix patterns do not apply to it.

### 2026-06-20 (phase1 AUR-build cascade — root-owned HOME silently skipped phase2) ✅
Weekly maintenance: yay's AUR *compile* step failed because the build user's HOME `/var/lib/node-maintenance` was `root:root` (couldn't mkdir `~/.cache` → Go GOCACHE denied) → phase1 rc=2 pre-reboot → the `phase2-pending` flag was never set → phase2/worker reboots **silently skipped** (CP got a partial update via the pacman-first path). Fix `a44e12a4`: `base_config` now owns HOME+`.cache`+`.config` for the build user on all hosts (NOPASSWD account, no privilege gain).
- **Follow-on**: a flux-reconcile-nudge timeout (`failed=1`) left `phase2-pending` STUCK → the flag gates BOTH sync and config timers → git-sync + drift-heal silently skipped cluster-wide ~1.7 h, no alert. Clear via `sudo rm` once healthy (work was done — do NOT re-run phase2).
- **Diagnostic trap**: the no-sudo `[ -e …/phase2-pending ]` check FALSE-NEGATIVES when HOME is 0750 (akhozya can't traverse) — defeated the watch-reboot/trigger-reboot interlock. Fixed `b8f95a53`: HOME 0750→0751 (o+x = stat-not-list; `.ssh` stays 0700). Full chain: memory `gotcha_node_maintenance_aur_build`.

### 2026-06-20 (clusterip-heal watchdog — autonomous worker kube-proxy DNAT-wedge self-heal) ✅
The validation reboot after the RebootWatchdogSec fix (below) exposed the *separate*, recurring **post-reboot kube-proxy DNAT wedge** (2026-05-24 class): `worker-node` came back Ready but `10.43.0.1:443` DNAT was missing (kube-proxy `:10256=200`, legacy iptables proxier's atomic `iptables-restore` poisoned by a stale nft chain). The phase2 ClusterIP gate passed it on a flap then it **re-wedged after uncordon** → phase2 PLAY 2 stuck looping `flux reconcile flux-system` (deadline exceeded, ClusterIP blackholed) for ~25min → needed a manual `restart k3s-agent`.
- **Research verdict (deep-dive)**: the architectural root fix — kube-proxy **nftables mode** (GA k8s 1.33, supported on our v1.36) — is **blocked**: host `nft 1.1.6` triggers an open kube-proxy segfault (k8s#136786); `prefer-bundled-bin` doesn't shield it (k3s bundles iptables, not nft). Trades a recoverable wedge for an unrecoverable crashloop → deferred until #136786 fixed + in our k3s.
- **Shipped instead — `clusterip_heal` ansible role (workers-only, Play 4)**: systemd `clusterip-heal-watchdog.timer` (OnBoot 90s + every 3min) → `clusterip-heal.sh` reuses the phase2 `clusterip-probe.sh`; on confirmed wedge while `k3s-agent` active → `systemctl restart k3s-agent`. **Cooldown 5min + cap 3/30min** then backs off and emits `node_clusterip_heal_giveup` for alerting (don't mask a deeper fault). Never the CP (Play 4 `hosts: workers` + the script no-ops where `k3s-agent` is absent; restart-k3s-on-CP hangs). Closes the "human had to restart k3s-agent" gap — every boot/post-uncordon re-wedge self-heals in one cycle.

### 2026-06-20 (worker-node reboot hang → RebootWatchdogSec 10min→2min) ✅
During the maintenance rolling-reboot, `worker-node` wedged in **late systemd-shutdown**: boot -1 journal ends mid-sequence at `Unmounting /home...` (15:49:01) right after `Stopping Flush Journal to Persistent Storage` — i.e. the hang struck the final phase (unmount `/`, `/var`, the multi-device LVM `/mnt/k8s-storage`, then `reboot()`) in an uninterruptible device/dm quiesce. Kernel stayed alive (no panic — so the softlockup/hardlockup `kernel.*_panic` sysctls do **not** cover this class). sshd was already stopped → node unreachable → operator power-cycled at <2min. Next-boot fsck confirmed unclean shutdown (journal recovery on p2/p5/k8s-data, orphaned inode cleared, FAT EFI "not properly unmounted").
- **Why a human was needed**: the SP5100 HW watchdog *was* armed for the reboot, but `RebootWatchdogSec=10min` — the node would have self-reset by ~15:59; the operator (rightly, not knowing it was counting) hit the button first.
- **Fix**: `hardening/files/systemd-watchdog.conf` `RebootWatchdogSec 10min→2min` — a hung reboot self-resets in ~2min (still ~20-40× margin over the normal seconds-long final phase) instead of needing a power button. Applied out-of-band via `node-maintenance-sync` → `node-maintenance-config` (drift-heal, all 3 nodes).
- **Skill**: `cluster-reboot/watch-reboot.sh` now prints the watchdog-window guidance when a worker goes UNREACHABLE mid-run (wait ≥`RebootWatchdogSec` before manual power-cycle); incident logged in `reference-incidents.md`.
- **Collateral (self-healed)**: `authentik-server` (1/2, replica retrying PG `10.43.6.89:5432` mid-failover), `mysql-replica-exporter`, `kube-state-metrics` errored during the DB churn; all recovered once DBs came back — stuck/orphaned pods GC'd + recreated. `worker-node` clusterip OK post-recovery (no kube-proxy wedge). Hang itself is intermittent (dm/NVMe quiesce race) and accepted — watchdog is the safety net, not a deterministic prevent.

### 2026-06-19 (authentik server startupProbe widened — CP cold-start SIGKILL fix) ✅
Follow-on to the lockout-watch close (entry below): root-caused the flagged CP `authentik-server` restarts (16×, exit 137, last ~37h before fix). On the control-plane node, bootstrap+migration-check contends with k3s-server, pushing gunicorn boot to ~146s — past the old 120s startup budget (`initialDelay 60 + 12×5`) → kubelet SIGKILL. Worker replica boots fast (0 restarts). Had self-resolved once a restart won the race; HA replica masked any blip.
- **Fix (`418a9c9f`)**: `apps/authentik/server-deployment.yaml` startupProbe `failureThreshold 12→30` (budget 120s→210s). Kept `initialDelaySeconds 60` + `periodSeconds 5` — the probe marks the pod ready the instant `/-/health/live/` returns 200, so the threshold is a *ceiling* not a wait; raising it (not the dead-time delay) keeps ready-detection fast in the common case while tolerating the slow CP cold-start.
- **Verified**: rolling restart clean, both server pods 1/1 0-restarts (CP pod `…px5dl` booted within the new budget), live `failureThreshold=30`.
- **GOTCHA**: CI was still billing-down (5s "failure", not validation) — local kubeconform `-strict` + yamllint (`.yamllint.yaml`, line-length max 200/warning) were the gate.

### 2026-06-19 (Passkey-only lockout watch CLOSED — no edge cases) ✅
Closed the 14-day lockout watch opened 2026-06-05 when password binding was removed (`40-remove-password-binding.yaml`, passkey-only main flow). Watch criteria: new-device enroll, post-reboot login, Conditional UI autofill.
- **Evidence**: Authentik 2026.5.3 event log `login_failed == 0` since 2026-06-05 (1 `login` success — single user, persistent SSO session); both server pods 1/1, ingress live. User confirmed all 3 edge cases clean.
- **Action**: dropped the `2026-06-19` row from [HOMELAB_ANALYSIS.md](./HOMELAB_ANALYSIS.md) Upcoming-deadlines table. Recovery posture unchanged — username+TOTP → re-enroll passkey, email flow, or `ak create_recovery_key` break-glass.
- **Note**: CP `authentik-server` replica showed 16 restarts (last 35h ago), unrelated to auth — root-caused + fixed same day (startupProbe budget; see entry above).

### 2026-06-15 (vm-operator metrics wedge → ScrapeTargetDown; cluster probe audit → reconcile-staleness alert) ✅
- **Incident:** `ScrapeTargetDown` fired for `victoria-metrics-operator` — its `:8080/metrics` handler wedged (TCP-accept, never sends headers) for ~2–2.5h while the `:8081` health server stayed up, so the pod read `Ready 1/1` and only the scrape alert caught it. Root cause = controller-runtime metrics server is independent of the health server. `kubectl rollout restart` cleared it; coincident renovate #815 then landed operator `v0.71.0`→`v0.72.0` (chart 0.65.1). The `:8081` "connection refused" seen from vmagent was a NetworkPolicy artifact (only `:8080` open cross-pod), not a dead listener — kubelet's `:8081` probe passed the whole time.
- **Probe audit** (multi-agent workflow, 55 main containers, 41 sidecars): probe posture **adequate cluster-wide** — every user-facing app has both probes; gaps are sidecars (skip-by-convention) or stateful/controllers where liveness-on-stateful is a restart-storm anti-pattern. **0 probe changes.** Research then killed the workflow's first alert idea (a dedicated up-gap alert) as **redundant** — generic `ScrapeTargetDown` (`up==0`) already covers a full `:8080` outage.
- **Action (`072eeaac`):** added VMRule `VMOperatorReconcileStalled` — `sum(rate(controller_runtime_reconcile_total{job="victoria-metrics-operator"}[15m])) == 0 for 30m`. Catches "operator up but reconcile loop stalled" — the weak-surface class `ScrapeTargetDown` can't see. TSDB-verified before ship: baseline rate steady ~0.05/s (never 0 over 6h → low-false-positive); absent-series → empty (no double-fire with `ScrapeTargetDown`); firing-direction proven via the currently-0 `reconcile_errors_total`. Loaded `health=ok` inactive.
- **GOTCHA — CI gate-of-record was DOWN:** GitHub Actions billing failure (jobs never start — `in 3s`, "log not found"; annotation = payment/spending-limit). `e3eb39f5` (renovate v0.72.0) and `072eeaac` both deployed **without CI validation** — Flux reconciles regardless of CI. Needs GitHub → Billing & plans fix; until then `/homelab-yaml-validate` is the only gate.

### 2026-06-12 (Flux bootstrap flatten — `clusters/staging/` → `clusters/`) ✅
The Flux bootstrap dir was misleadingly named `staging` (single-env PROD, no staging) and held only `flux-system/` while the 5 Kustomization CRs already sat flat at `clusters/`. Flattened to `clusters/` (root `spec.path: ./clusters`) via a **3-commit deadlock-safe migration** — the root Kustomization's `spec.path` lives inside the dir being deleted, so switch and delete must be separate, individually-reconciled commits (else Flux builds the current path from a tree where it's already gone → reconcile wedge, the CoreDNS-deadlock class).
- **1/3** (`14973410`): added flat `clusters/{flux-system/,kustomization.yaml}` alongside `staging/`, **inert** (root still on `./clusters/staging`, nothing builds `./clusters`). priorityClassName `.*-controller$` patch moved into `clusters/flux-system/kustomization.yaml`. Reconcile = zero churn (verified: PODS/FLUX/ALERTS unchanged, only SHA).
- **2/3** (`6304396e`): flipped both gotk-sync copies' `spec.path` `./clusters/staging` → `./clusters`. Reconcile N (root still on staging) builds old path via Flux **auto-gen** → applies flipped CR → in-cluster `spec.path` becomes `./clusters`; N+1 builds `./clusters`. Verified spec.path flipped live, 7/7 Ready, zero regression.
- **3/3** (this commit): `git rm -r clusters/staging/` + ref swaps — `flux-update.yaml` (reads+**writes** gotk-components path), `renovate.json` glob, `.yamllint`/`.pre-commit` ignores (drop staging), `BACKUP_STRATEGY.md` bootstrap `--path=clusters`, `CODEMAPS/architecture.md`.
- **Proof**: `flux build` (controller-accurate — auto-generates `kustomization.yaml` when absent, per its own docs) renders **byte-identical** at both paths (order-normalized 0-diff, 40 resources, 4 priorityClassName incl notification-controller). Flat layout drops the `../../` escape → builds with kustomize's **default** load-restrictor (now CI-eligible; old layout needed `LoadRestrictionsNone`).
- **GOTCHA — cavecrew false positive**: reviewer flagged "deadlock: `kustomize build ./clusters/staging` fails (no `kustomization.yaml`)". Conflated `kustomize build` CLI (no auto-gen + load-restrictor blocks `../../`) with the Flux kustomize-controller (**auto-generates** the kustomization + `LoadRestrictionsNone`). Refuted via `flux build` exit 0 at both paths + the live cluster *already* reconciling `./clusters/staging` with no `kustomization.yaml` there.
- **NOT** re-bootstrapped via `flux bootstrap` (would regen gotk-components at the CLI's Flux version → drift from v2.8.8 + lose the notification-controller priorityClassName parity) — hand-edited the path field only.

### 2026-06-12 (Pre-public sanitization: git-history rewrite + SSH key rotation)
Audit ahead of possibly making the repo public found 3 secret classes in **git history** (working tree was clean — all SOPS-encrypted). Remediation:
- **History rewrite** (`git filter-repo` on a fresh clone → force-push `e86068a5`→`04503602`, 3515→3475 commits): stripped the `2026-04-11-claude-telegram*` plan/spec docs (held a plaintext ed25519 key) + redacted the Telegram bot token + Cloudflare account-ID/tunnel-UUID across all history. Deleted stale branch `worktree-phase-a-node-config`; deleted + re-pushed all 35 tags onto clean commits. Pre-rewrite backup bundle taken (then deleted). Flux reconciled clean to `04503602`, zero disruption.
- **SSH key rotation** (`b1c83ca1`): the leaked `claude-telegram-bot` ed25519 key was a **GitHub account-wide auth key** + node-SSH key. Rotated additive-first (new key → GitHub + 3 nodes' `authorized_keys` → SOPS `claude-telegram-ssh` → bot restart → verify github+node auth → remove old). Old key deauthorized everywhere → its history/PR-ref copies now inert.
- **Bot github-over-443** (`8cb1e209`): cluster egress blocks `:22`; routed the bot's github SSH via `ssh.github.com:443` so its chezmoi + homelab self-update works again (was silently failing). Node-maintenance sync unaffected (own deploy key + `reset --hard`, self-heals).
- **NOT publishable yet**: GitHub serves 806 `refs/pull/*` (400+ renovate PRs) pinning old commits — un-deletable; only delete+recreate the repo (forkCount=0) or a GitHub Support purge removes them. All live credentials are rotated/dead, so residual = CF account-ID (an identifier) + inert keys. Decision pending.

### 2026-06-07 (require-labels soak fix-forward — 15 violations cleared, polr → 0 cluster-wide) ✅
Daily Kyverno digest fired 23 Audit violations (15 `require-labels` + 8 `require-seccomp-runtimedefault`). Triage: all 8 seccomp = stale objects (4 zero-replica pre-remediation RSes + 3 completed pre-fix popeye Jobs); 15 labels = real soak findings. Fixed forward NOW rather than at flip (`71495e61`) so the remaining ~4-week soak validates the FIX under churn (helm reconcile, CronJob spawns, Job force-recreates) instead of re-reporting knowns — quiet digest makes any new violator visible:
- **3 provision Jobs** (mealie-user-provision, n8n-user-provision, couchdb-init): `app` label on pod template, values deliberately DISTINCT from app labels (`mealie-user-provision` ≠ `mealie`) so app-scoped NetworkPolicies don't start matching Job pods. Flux force-recreated all 3, re-ran clean (succeeded=1).
- **popeye CronJob**: `app: popeye` at jobTemplate pod template (NP is `podSelector: {}`, unaffected).
- **redis-operator**: populated chart's `redisOperator.podLabels` (`app.kubernetes.io/name`) — pulled chart 0.24.0 tgz first to prove podLabels merges into template labels ONLY (selector stays `name:` → no immutable-selector break). Rolled clean.
- **Stale cleanup** (out-of-band, not git-managed): 5 zero-replica RSes (redis-operator ×2, immich-server, loki-gateway, ps-operator) + 3 completed popeye Jobs deleted.
- **Verify**: fresh popeye run from updated template (labeled + seccomp'd, completed) → full polr re-query = **0 fail results cluster-wide, all 12 policies**.

### 2026-06-07 (UR2 non-July-gated cleanup — popeye seccomp, MySQL replica monitoring, CNPG-panels decided-leave) 🔬✅
Swept the UR2 items NOT gated on the 07-04 soak (worktree → cavecrew → CI-green → reconcile → live-verify, each batch):
- **popeye seccomp** (`22471c81`): the new `seccomp-violators.sh` live-pod audit caught `popeye` CronJob as a seccomp violator the 2026-06-06 12/12 check missed — CronJob pods cycle in/out, so point-in-time scans miss them between runs. Added pod-level `seccompProfile: RuntimeDefault` to its jobTemplate (container already had RoRFS/non-root/caps-drop). Verified the live CronJob template carries it.
- **MySQL replica monitoring restored** (`05c40e01` exporter+scrape → `9505b9c1` NP fix → `8e07ae46` alerts). The standalone `mysql-exporter` scrapes the HAProxy WRITER (`:3306` = primary, `read_only=0`) so `SHOW REPLICA STATUS` was empty → replication unmonitored (2 dead alerts removed 2026-06-06). Fix = a 2nd `mysql-replica-exporter` → HAProxy **reader backend `:3307`** (routes to the read-only replica; haproxy abstracts role-rotation, deterministic at `size=2`). Chosen over a Percona CR sidecar (would roll the primary DB + the sidecar must pass 5 Kyverno policies + per-pod scrape) — the standalone reuses the proven exporter scaffold, no DB roll. **Two gotchas hit + fixed mid-flight (caught by verify, not shipped blind):** (1) **NetworkPolicy AND-rule** — added the exporter egress to `:3307` but the `mysql-cluster` ingress NP only allowed `app:mysql-exporter`→3306; the replica exporter (`app:mysql-replica-exporter`→3307) matched no ingress rule → kube-router REJECT = "connection refused", `mysql_up=0`. Fixed by adding the matching ingress allow. (2) **MySQL 8.4 metric names** — 8.4 removed `SHOW SLAVE STATUS`; `SHOW REPLICA STATUS` renames columns, so live metrics are `mysql_slave_status_replica_{sql,io}_running` + `_seconds_behind_source`, NOT legacy `slave_*`/`master`. Pre-verified `prom/mysqld-exporter:v0.19.0` supports 8.4 (PR #837; existing exporter has no slave_status syntax errors on this 8.4 primary), then **split the work** (ship exporter → confirm exact live metric names in VM → write alerts) so MySQLReplicationNotRunning/Lag/ReplicaExporterDown reference real series, not dead ones. Live-verified: `up=1`, `replica_sql/io_running=1`, `seconds_behind_source=0`, 3 alerts loaded `health=ok` inactive.
- **CNPG empty backup panels** decided-LEAVE (user call): 4 barman-backup panels in a 9356-line upstream dashboard JSON sit empty under pg_dump-only; surgical removal = breakage risk + upstream-bump conflict for harmless "No data" tiles.

### 2026-06-06 (UR2 P3 remediation — 5 gated batches + scan-script fix) 🔬✅
Continuation of UR2 — worked the deferred P3 leads (worktree → cavecrew review → CI-green → reconcile → live re-test, each batch):
- **Quick-safe** (`018d23e2`): Flux healthCheck `timeout: 45s`→`2m` on the 3 health-gated Kustomizations (infra-configs + monitoring-controllers/configs — cnpg/operator/VMSingle cold-start on reboot exceeds 45s → false-failed reconcile). HA NetworkPolicy ingress `namespaceSelector: {}` (all-ns) → scoped to traefik + uptime-kuma + same-ns admin-setup Job — HA is LOCAL-ONLY (not in cloudflared route table, verified via SOPS-decrypt), so NO cloudflare-tunnel rule; live HA still 200 via Traefik post-tighten. CouchDB DR restore rewritten — old cmd ran `couchrestore` inside the couchdb pod (no such binary); now an ephemeral `node:alpine` pod runs it from `@cloudant/couchbackup`, iterates `*.couchbackup`, creds from `couchdb-couchdb` secret via `--overrides` (no shell-history leak).
- **Security** (`eb3be28a`): `require-labels` + `require-non-root` `=()` soft anchors → hard anchors (anyPattern / per-container securityContext), Enforce→**Audit** (Audit-first — hard-anchoring a toothless-Enforce blocks pods). `require-non-default-serviceaccount` verified — uses a correct `deny` block, NOT a `=()` footgun, left Enforce. homepage ClusterRole: removed cluster-wide `secrets` (verified homepage reads none via K8s API — k8s widget disabled, no secret env mounts). claude-telegram ClusterRole: core `resources:["*"]` (included secrets) → enumerated core list minus secrets (ops bot must not read every cluster secret). `kubectl auth can-i` confirmed both SAs now denied `get secrets`, ops verbs (list pods / `pods --subresource=exec` create) preserved.
- **Seccomp 8/12** (`d50dd6e0`): pod-level `seccompProfile: RuntimeDefault` added to 8 stateless violators — immich-server (chart values; pod-level because the main container is `privileged` for GPU so a container-level profile would be clobbered), redis-operator + ps-operator + loki + loki-gateway + loki-canary + alloy + node-exporter (postRenderer **strategic-merge** — a JSON6902 `op:add /spec/template/spec/securityContext` would REPLACE the chart's pod securityContext, dropping fsGroup → PVC breakage). All rolled 0-restart; violator count 12→4.
- **Seccomp DB tier → 12/12** (`f03bd985` couchdb, `686175e8` Percona MySQL): pod-level `seccompProfile: RuntimeDefault` via couchdb chart-values `podSecurityContext` + Percona CR `spec.{mysql,proxy.haproxy,orchestrator}.podSecurityContext` (`kubectl explain`-confirmed CRD fields; no pre-existing securityContext → no clobber). Serialized 2-cycle gated roll (couchdb first, then DB tier). couchdb 2/2 Ready 0-restart. Percona operator SmartUpdate rolled all 3 components ~2.5min to `ready` (mysql 2/2, haproxy 2/2, orc 3/3) — primary mysql-1 updated last, intact on W1 (no spurious failover), orc quorum never <2/3; new-pod restart=1 benign (mysql clone `Completed` exit0 + pt-heartbeat connect-before-ready exit2, both Ready). Live violator jq → **0**. Alert sweep: 0 firing; `StatefulSetReplicasMismatch` PENDING cleared ~20s post-roll. **All 12 seccomp violators remediated; only the Audit→Enforce soak-flip remains (07-04).**
- **Tooling**: fixed `kyverno-policy-promotion/scripts/scan-violations.sh` `--force-regen` crash — `echo "...$REGEN_DEPLOY…"` (unbraced var immediately followed by the multibyte `…` ellipsis) made this bash build absorb the lead byte into the variable name → "unbound variable"; fixed to `${REGEN_DEPLOY}...`. Gotcha: a fresh `--force-regen` can report false-clean "0 fails" (the pass>0 gate trips on partial admission reports before the ~1h full background scan completes).
- **Decisions/deferred**: CNPG WAL/PITR **decided-no** (recurring UR1/UR2 flag; memory `decision_cnpg_no_pitr` — pg_dump-only by design, no S3 backend). Soaking to ~07-04: `require-seccomp`/`require-labels`/`require-non-root` Audit→Enforce flips (DB-tier seccomp now done 2026-06-06 → 12/12; flip after a clean `scan-violations.sh --force-regen`). MySQL replica-scrape monitoring still backlog.

### 2026-06-06 (Ultrareview 2 — multi-agent re-scan + 5-batch remediation) 🔬✅
**UR2**: 8-dimension multi-agent scan → dedup → 2-lens adversarial verify. 16 confirmed (3 P1 + 13 P2), 1 refuted, 18 P3 leads. Every confirmed finding personally re-verified live (VMSingle queries / kustomize+flux build / git) — 16/16 held. Shipped in 5 gated batches (worktree → cavecrew review → merge → live re-test):
- **A monitoring** (`2843c86e`+`2dbefa5a`): ~13 dead VMAlert exprs/scrapes repointed to live names — alertmanager scrape selector (`app.kubernetes.io/name`→`app: kube-prometheus-stack-alertmanager`), redis exporter (`app: redis`/`metrics`→`redis-replication`+`component: metrics`/`redis-exporter`), postgres alerts `pg_*`→`cnpg_*`, kyverno `kyverno_policy_rule_results_total`→`kyverno_policy_results_total`, 5 `up{job=}` Down + 4 throttle/node-override job labels (`node-exporter`→`kube-prometheus-stack-prometheus-node-exporter`, `kubelet`→`kube-prometheus-stack-kubelet`, `apiserver`→`kubernetes`, `couchdb`→`couchdb-couchdb`, `kyverno`→`kyverno-svc-metrics`). Removed 3 dead alerts (metrics nonexistent: ContainerCPUNearLimit/HighErrorRate/CloudflareTunnelHighLatency) + KyvernoHighSeverity (`policy_severity` label absent). **gotk_reconcile_condition/suspend_status removed upstream in Flux 2.8.x** → added flux-system VMPodScrape (http-prom:8080) + replaced the 3 dead gotk alerts with `controller_runtime_reconcile_errors_total` + `notification-controller`-down backstops (the `flux-gitops` Alert→telegram already delivers per-object failures). PostgreSQLHighRollbackRate gained a commit-rate floor (mealie low-volume false-positive). RedisHASentinelQuorumLost → kube_pod count (no sentinel exporter).
- **B DR** (`b884c7b5`): `.backup/README.md` postgres+mysql restore loops were non-functional — wrong extract dir (`basename` kept `postgres_`/`mysql_` prefix vs bare `<TIMESTAMP>`), stale PG DB list (omitted `blocky`, included phantom grafana/audiobookshelf/app), wrong mysql inner filename, `main-postgres-1` pod doesn't exist (pods are `-11`/`-12`), and node-file-path passed to `kubectl exec` with no `-i` (pod can't read node `/tmp`). Rewrote both to iterate the actual `*.dump`/`*.sql`, dynamic `cnpg.io/instanceRole=primary` lookup, `-i` stdin streaming (pg_restore reads `-F c` from stdin — confirmed via PG docs; mysql via `-h main-mysql-haproxy`).
- **C bootstrap/flux** (`61cc13a9`): moved `priority-classes/` infra-configs→infra-controllers — **cold-bootstrap/DR deadlock**: infra-configs `dependsOn` infra-controllers, whose healthCheck pods (cert-manager-webhook, kyverno-admission-controller) carry `priorityClassName: homelab-standard` defined ONLY under infra-configs. Live-verified the 3 PriorityClasses survived the infra-configs GC with no deletion gap (Flux ownership-label GC + dependsOn ordering: controllers relabels them before configs GCs). + gotk `priorityClassName` re-applied via kustomize `patches` in flux-system (survives `flux install --export`); `infrastructure/coredns` added to kubeconform matrix (was 5-of-6 reconciliation roots).
- **D security** (`efeeee22`): dropped `traefik-rate-limit-high-frequency` from authentik Ingress (review-invariants: rate-limit breaks SSO auth flow behind shared cloudflared IP); removed `10.0.0.0/8`+`172.16.0.0/12` from HA egress (contained pod CIDR 10.42/16 + svc CIDR 10.43/16 = cluster-wide lateral movement; kept 192.168/16, MySQL+DNS granted separately). `require-seccomp-runtimedefault` `=()` soft anchors → hard anchors + Enforce→**Audit** (was toothless-Enforce; hard anchor surfaced 37 PolicyReport fails; ~22 operator/chart pods need a seccompProfile before re-Enforce). Both canary URLs 200 post-change.
- **E cruft** (`5286a2c1`): immich global tracking tag v2.1.0→v2.7.5; n8n NP stale "staging overlay" comment; removed dead dependabot gomod block (`scripts/analyze-update` Go reimpl orphaned — workflow uses the `.sh`) + dead README link; shellcheck CI gate `-S error`→`-S warning` (0 warnings, stays green).
- **Fallout** (`5d217282`+`03711ab7`): Batch A's newly-live alerts surfaced 3 latent bugs that paged Telegram, all root-caused live + cleared — alertmanager `reloader-web:8080` not scrapable (`up=0`→ScrapeTargetDown; dropped from scrape), RedisHAReplicationBroken false-fired on the replica's `connected_slaves=0` (→`max()`), NodeMemoryMajorPagesFaults exclusion regex `worker-node2` (missing dash) never matched hostname `worker-node-2` so wn2's rebuilderd disk-I/O (7354 majflt/s, 60% mem free) fired it (→`worker-node-2`).
- **Deferred**: 18 P3 leads (unverified — confirm before acting); UR2-4 seccomp re-Enforce (22-pod seccompProfile remediation); `scripts/analyze-update/` Go dir (orphaned, dependabot stopped — left for owner to delete).

### 2026-06-05 (Monthly review — scan rollup, overdue-item closure, passkey-only flow, Redis failover test) ✅
- 🔬 **Security-scan rollup** (June 1 run vs May): warnings 95→32 (CP), 94→31 (W1), 94→31 (W2) — −66%, uniform (rkhunter propupd baseline effect); suspect files 87→27/86→26/86→26; **0 rootkits all nodes**.
- ✅ **UFW heal v5 validated PASS** — W1 linux-lts 6.18.33-1 upgrade + reboot 2026-05-31 22:35 survived: ufw.service + ufw-heal-watchdog.timer active, no UfwDisabled incident. Pending item (open since 2026-05-16) closed.
- ⚖️ **Blocky memory-limit review closed: keep 512Mi** — 30d peak 365Mi (vs 307Mi May soak; 293Mi even in last 24h post node-DNS-decouple). Planned 384Mi would leave 5% headroom; limit ≠ reservation, DNS critical path. No change shipped.
- ✅ **Redis HA: health check + failover smoke test PASS** — pre: 3-sentinel quorum OK, full alert ruleset (RedisDown/PodNotRunning/HighMemory/RejectedConn/SlowQueries). Failover via db-primary-pin: master redis-replication-0 (wn2, drifted there during 06-04 incident) → redis-replication-1 (W1) in 2 attempts (known first-bounce); replica resynced lag=0; immich ioredis errored during transition, self-recovered <3min (no client restart needed — milder than the 2026-05-31 stale-connection case). Both overdue 05-26 items closed.
- 🔐 **Authentik password binding REMOVED** (passkey-only main flow) — new blueprint `40-remove-password-binding.yaml` (`state: absent` on FlowStageBinding order 20 of default-authentication-flow). 6+ weeks clean passkey ops since 2026-04-19. Recovery: username+TOTP via mfa-validate → re-enroll passkey; email recovery if TOTP lost. Accepted tradeoff: TOTP alone = new weakest login path (phishable vs passkey). Rollback: drop blueprint entry, binding re-creatable manually.
- 🔬 **Upstream re-checks**: n8n #25705 OPEN no movement since 04-28 → 07-04; Authentik #20700 (WebAuthn client hints) **CLOSED upstream 03-13** — cluster on 2026.5.2, evaluate enabling → 07-04; #18232/#19580 still open → keep watching.
- ✅ **Skill stocktake (full)**: 21 OK / 3 Improve — cluster-roll SKILL.md still said CoreDNS Deployment+k3s-addon (DaemonSet since 06-05, addon disabled 06-04), monitoring-check baseline "7 enforce + 3 audit" (12 all-Enforce since 05-25), np-coverage.sh comment cited deleted REVIEW.md. All 3 fixed + chezmoi-synced same day.
- ✅ **CODEMAPS refreshed** (6 parallel agents vs live cluster): architecture (Kustomizations 6→7 incl. coredns KS, NP 44→64, Kyverno 12 all-Enforce, DNS-resilience section), apps (9 image bumps, CSP tier membership, F-23 CI gate), networking (64-NP per-ns breakdown, cloudflared 2026.5.2), databases (CNPG failoverDelay/operator-placement backfill, Redis-master state), monitoring (KPS 86.1.1, F-49 NP section, alert-class notes), backup-restore (Wave-10 fields, pg 18.4/node 24.16, 16-app coverage fix).
- 🔬 **Posture sweep addendum** (same day, user-prompted — these were MISSING from the 3-item checklist): Kyverno 12/12 Enforce+Ready, PolicyReports **1753 pass / 0 fail / 0 warn** — no regression. Popeye manual run: **A (90)** vs 100 baseline (2026-05-02) — delta = POP-109/110 resource warns (PODS 19%, → 07-06 right-sizing input) + 14 `databases/` Service lints (Percona/Redis operator-owned: POP-1106 named-port mismatches cosmetic, POP-1100 `main-mysql-mysql-proxy` no-pods-match → P3 investigate). **Trivy: absent from entire stack** (cluster/CI/nodes) — image-CVE scanning gap, decision item → 07-04. Scan timers active ×3 nodes, next 2026-07-01. Passkey-only login live-verified by user (immich→Authentik).
- 🧰 **Lesson → skill**: checklist-following ≠ review completeness. Built `homelab-monthly-review` skill (full posture-surface table + phases); ANALYSIS checklist section reduced to pointer so they can't drift.
- 📋 Next review 2026-07-04 (monthly + first quarterly automation audit, same day). Not pulled in (not yet due): high-pri secret rotation 07-01, W2 replication-step drop ~07-20, right-sizing 07-06.

### 2026-06-05 (Ultrareview closure: REVIEW.md retired + F-ref comment sweep + dead-config cleanup) ✅
**Ultrareview 2026-05-23 backlog fully closed** — every finding (1 P0 + 11 P1 + 17 P2 + P3s + refactors R1-R7) done, won't-do'd with rationale, or deferred-by-decision (mealie/uptime-kuma Job NPs — runtime apt/pip egress; F-22 optional https report endpoint; HISTORY rotation 2026-Q3). `REVIEW.md` deleted (638 lines; full record in git history — last at `60b8d621`). Referrers updated: ANALYSIS header/keyfacts/changelog, ARCHITECTURE doc table.
**Comment sweep**: 43 `F-N`/`Wave-N` review-plan refs removed from 29 yaml/sh files (comments now self-explanatory; dates kept). Stale claims fixed: kyverno-policies kustomization "Audit (Wave 8 soak)" header (all 12 Enforce since 2026-05-25), `require-networkpolicy` NP count, pricebuddy "apprise root writes" (non-root since F-24).
**Dead config removed** (separate commit `9144e2a6`): (1) `csp-tier-middlewares.yaml` — 3 report-only CSP middlewares referenced by zero ingresses (all 14 use `-enforced` variants; report-uri was cluster-internal HTTP = browser-unreachable, the known-dead soak gate); (2) `claude-telegram` ns removed from `require-readonly-rootfs` excludes — RoRFS ×3 + PSS restricted since 2026-05-27 (`3c5ce4aa`), live-verified compliant pre-removal; Kyverno now guards the ns again.

### 2026-06-05 (k3s v1.35.3 → v1.36.1, no-reboot binary swap) ✅
**Method** (k3s is NOT pacman-managed — manual binary at `/usr/local/bin/k3s`, last touched Apr 5): direct GitHub release binary swap, sha256-verified, **no install script** (on agents it rewrites systemd units and needs K3S_URL/K3S_TOKEN; binary swap needs neither — agents stay joined, token/config untouched). Staged on all 3 nodes with old binary kept at `/usr/local/bin/k3s.prev` (v1.35.3 rollback), then activated via the sanctioned `node-maintenance-rolling-restart.service` (serial CP→W1→W2, Ready gate per node, ~6min, pods keep running — only the k3s control process bounces). Sudo via `op://Personal/sudo-homelab/password` single-attempt pattern.
**Verified**: all nodes Ready on v1.36.1+k3s1, watch-reboot all-green (3-surface ClusterIP/loopback/nat-jump), checkpoint `pre-k3s-1.36-upgrade` diff = zero regressions (pods 105/92/0, alerts 0). Skew order correct: server upgraded before agents. Cleanup later: `rm /usr/local/bin/k3s.prev` once stable for a week.

### 2026-06-05 (coredns-ha Deployment → DaemonSet + JobFailed incident RCA) ✅
**Incident (2026-06-04 18:12–~21:00 UTC)**: pod DNS dead on worker-node-2 only. Casualties: `audiobookshelf-init` daily TTL re-run (curl exit 6 ×6 → BackoffLimitExceeded → JobFailed alert, fixed 06-05 by delete+`fr` re-run) + authentik-server crashloop ×17 (liveness 500: name resolution fail for `main-postgres-rw`). CoreDNS pods healthy throughout (0 restarts, 0 SERVFAIL) — **wn2 had ZERO local coredns replica** (skew: W1×1+CP×2), so all wn2 pod DNS crossed flannel VXLAN; node-local VXLAN fault = total DNS loss for wn2 pods. Forensics via VM kube-state metrics (job pod deleted at backoffLimit, Alloy never captured fast-crashloop logs) — see memory `gotcha_worker_node2_flannel_dns`.
**Why skew recurred**: `whenUnsatisfiable: ScheduleAnyway` = soft scoring hint; least-allocated scoring + rolling-update double-counting beat it (after 06-04 23:50 roll: CP×1+**wn2×2+W1×0**). No descheduler → skew permanent until next roll.
**Fix** (`6e7c8581`): `infrastructure/coredns/deployment.yaml` → `daemonset.yaml` — exactly 1 CoreDNS/node, immune to scheduler scoring; DS pods auto-tolerate disk/memory-pressure taints. Flux healthCheck GVK Deployment→DaemonSet (clusters/coredns.yaml), PDB kept. Verified: 1/1/1 across nodes, old Deployment pruned, kube-dns svc selector (`k8s-app=kube-dns`) gave zero-gap cutover.
**flannel drops RESOLVED same day**: timed tcpdump (`kubectl debug node --profile=sysadmin`) around the predicted :XX:29 burst second → top flow = `main-postgres-11`(wn2):5432 → `main-postgres-12`(W1), ~7.7k pkts/~11MB in <1s = **CNPG WAL segment-switch burst** (`archive_timeout=300s`) overrunning wn2 NIC queue (~9% burst drops, TCP retransmits cover). WAL was wn2-egress because of a **spurious failover 06-04 20:37:43 UTC**: CNPG operator runs ON wn2 — during the flaky window its probe to the healthy W1 primary failed over VXLAN → "Current primary isn't healthy" → promoted the wn2-local replica (drop regime began 20:52 = first segment switches). Fix: `kubectl cnpg promote main-postgres main-postgres-12` (06-05 11:34 UTC) — W1 pin restored, cluster healthy. Lesson: operator-on-flaky-node shoots healthy primaries. k3s update NOT needed — not a flannel bug. Third silent casualty of the 06-04 window (after JobFailed + authentik). Diagnostic dead-ends recorded in memory `gotcha_worker_node2_flannel_dns`.
**HARDENED same day** (`47fbf602`): `Cluster.spec.failoverDelay: 30` (filters 1-10s probe blips; +30s RTO on real death) + operator nodeAffinity soft-pref NotIn wn2 + control-plane toleration (REQUIRED: without it replicaCount 2 + hard anti-affinity forces a replica onto wn2 — pref would be dead config). GOTCHA hit during rollout (2nd time today, after coredns): rolling reroll of hard-anti-affinity pods — the OLD Terminating pod still counts → blocks its node → new pod landed wn2 despite pref; one `kubectl delete pod` after the upgrade rescheduled it to W1. Final: operator CP+W1, failoverDelay live, cluster healthy.

### 2026-06-04 (Node DNS decoupled from blocky — circular-dep break) ✅
Nodes' upstream DNS moved off blocky's worker-IP servicelb endpoints (192.168.1.129/.126, DHCP-supplied) to public resolvers (1.1.1.1 + 9.9.9.9). **Why**: CoreDNS (`forward . /etc/resolv.conf`, `dnsPolicy: Default`) inherits the node resolv.conf, so cluster-external DNS (flux→github) flowed CoreDNS → node → blocky pod → kube-proxy servicelb DNAT. A worker kube-proxy/flannel wedge killed blocky reachability AND the node upstream together — self-amplifying (2026-06-04 incident, gotcha_k3s_reboot_ordering delta #3). blocky also hard-deps redis (`required:true`), so it's a poor thing for the cluster's own DNS to depend on.
**Fix** (ansible `hardening` role, node-side — NOT Flux): per-NIC networkd drop-in `[DHCPv4]/[IPv6AcceptRA] UseDNS=no` + `[Network] DNS=` reset (drops DHCP/RA-supplied + W2's static .129); resolved global drop-in `DNS=1.1.1.1 9.9.9.9` + `Domains=~.`. Stays uplink-mode (real IPs in resolv.conf, NOT 127.0.0.53 — k3s would generate its own). Per-host var `primary_network_file` (CP 10-enp3s0, W1 20-ethernet, W2 20-wired-static). Merge `c4fcd922`.
**Applied**: all 3 nodes via drift-heal, then `kubectl rollout restart deploy/coredns-ha` (pods snapshot resolv.conf at creation → must restart to re-read). Verified: every node resolv.conf = public, zero blocky IP; flux fetched github via CoreDNS→public; blocky still serves LAN (router DHCP DNS option untouched → .129/.126 servicelb intact, adblock for LAN devices preserved).
**GOTCHA** `install.sh --sync-only` is NOT file-copy-only — lines 158/164 re-enable `node-maintenance-config.timer` + `systemctl start --wait node-maintenance-config.service` = a full drift-heal across ALL hosts (blocking ~5 min). It bypassed the intended staged W2→W1→CP rollout (landed all-at-once; idempotent + reviewed so harmless here, but for true per-node staging do a manual `rsync ansible/ /etc/node-maintenance/ansible/` + `ansible-playbook --limit <node> --tags <tag>`, NOT install.sh --sync-only). `fe80::1` (router IPv6 RA) persists post-apply — `UseDNS=no` doesn't drop an already-acquired RA lease without reconfigure/reboot; benign (router ≠ cluster).

### 2026-05-31 (immich post-reboot recovery — Redis stale-connection + gunicorn-25.1.0 control-socket boot hang)
Two JobFailed alerts (immich-admin-setup, immich-backup-29669940) were reboot-day blips (immich-server was mid-migration / the 03:00 backup pod was killed during maintenance — not disk, worker-node had 3.7T free; this week's backup re-run manually → Complete). Verifying immich health surfaced two real issues:
- 🔴 **immich-server → read-only Redis replica** (`READONLY You can't write against a read only replica`, ongoing). Redis itself was healthy (Sentinel master `10.42.2.141` writable, 1 slave); immich's **ioredis connection was stale** — pinned to the pre-reboot replica, never followed the Sentinel failover. Fix: `kubectl rollout restart deployment/immich-server` → reconnected to master, errors stopped. (Operational, not git. Same class as the cached-DNS-after-failover gotchas — restart the *client*, not the DB.)
- 🔴 **immich-ml boot hang ~50% of restarts** (`e740597d`+`e2ce645a`). Root cause: **gunicorn 25.1.0** (versionadded) ships a new **control socket**, default path the *relative* `gunicorn.ctl` → joined to the **read-only cwd** → `Errno 30 Read-only file system`. That failed write **intermittently hangs the gunicorn worker fork** (master logs "Control server error" then never forks the worker → `/ping` never serves → startup probe burns its 600s budget → SIGTERM; a fresh pod wins the race and boots fine). NOT benign log noise as first assumed. **Fix:** `GUNICORN_CMD_ARGS: "--no-control-socket"` env on immich-ml (gunicorn reads this env; flag valid in 25.1.0) — disables the unused control CLI socket, **keeps `readOnlyRootFilesystem: true`** (no security regression; immich ns is Kyverno require-readonly-rootfs-excluded + PSS-privileged, so RoRFS:false was the fallback but unneeded). Reusable: ANY RoRFS workload on gunicorn ≥25.1.0 hits this → set `--no-control-socket` (or `--control-socket /run/...` to a writable mount). See `[[immich-ml-gunicorn-control-socket]]` memory.
- 🛡️ **Probe-timeout hardening** (`e740597d` mine + concurrent session's readiness postRenderer): immich-ml AND immich-server probes shipped chart-default `timeoutSeconds: 1` — under reboot CPU-starvation a >1s `/ping` reads as a probe failure → false SIGTERM. Bumped startup+liveness (values, `custom: true`) and readiness (postRenderer SMP) to `timeoutSeconds: 5` on both components; liveness failureThreshold 3→5. Defense-in-depth (the control-socket fix is the actual boot fix).

### 2026-05-31 (F-43 — Home Assistant OIDC SSO re-enabled on hass-oidc-auth v1.1.0) ✅
- ✅ **Re-enabled** (`fcf2d1a8`): hass-oidc-auth **v1.1.0** (2026-05-14, first stable past the alpha/RC line) fixed the auth-page-injection break that made it incompatible with HA 2026.4.0 — the reason it was disabled 2026-04-02 (`0c70695b`). HA now on 2026.5.4 (`hacs.json` min HA 2025.11). Re-added the `oidc-auth-install` init container (downloads the **pinned v1.1.0 release zip** → `/config/custom_components/auth_oidc`, mirrors the HACS init pattern, `.installed-version` sentinel for idempotent upgrades) + restored the `auth_oidc:` **confidential** block in the configmap (`client_secret: !secret oidc_client_secret`, resolved from the existing SOPS `home-assistant-secrets`).
- 🔵 **Authentik side survived the disable** — the `home-assistant` OAuth2 provider + application were never torn down (only the HA side was); discovery endpoint returned 200 and `secrets.yaml` still held `oidc_client_secret`, so the re-enable was config-only. **Live OIDC login verified** by operator.
- 🔐 **Scrubbed** a plaintext client secret committed in `OIDC_SETUP.md` (line 40, in git since the 2026-04 setup) → SOPS-only pointer. The provider's secret is the source of truth.
- 🧠 **Gotcha:** HA's real host is `ha.h0melab.work`; `OIDC_SETUP.md` documented the wrong `homeassistant.h0melab.work` redirect URI (4 refs, fixed). The Authentik provider was already correct — proven by probing the authorize endpoint: `ha.h0melab.work/auth/oidc/callback` → 302 (allowlisted), `homeassistant…` → 400 (rejected). Reusable check: `_shared/oidc-verify.sh`. CI was INFRA-RED (runner billing) — cavecrew + local-validate were the gate of record.

### 2026-05-31 (CoreDNS single-managed convergence via `--disable=coredns` — DNS-deadlock cutover + break-glass) 🔬️
- ⚖️ **Convergence executed** (operator decision): `--disable=coredns` added to `control_plane.yml` k3s_disable (`bd2bd5b5`) so the k3s addon CoreDNS retires, leaving the Flux-managed `coredns-ha` (3 spread replicas) as the single CoreDNS behind kube-dns `10.43.0.10`. Activated on the phase1 update+reboot.
- 🔴 **DNS DEADLOCK on cutover** (~20:46): the CP k3s restart fired `--disable`, which deleted the **entire still-addon-owned** set by `objectset.rio.cattle.io/owner-*` label — kube-dns **Service** (the VIP), `coredns` **CM** (Corefile), **SA**, `system:coredns` **ClusterRole+Binding**, addon **Deployment**. Phase-A "adoption" (`ce8262f8`) had only added kustomize-controller as a field-manager; it never stripped the owner-labels, so k3s still owned them. Flux then **could not recreate** them: kustomize-controller fetches its artifact from `source-controller.flux-system.svc` → resolves via the just-deleted `10.43.0.10:53` → `i/o timeout` → ALL reconciles stalled cluster-wide. The planned `cache 30` + forced `flux reconcile` mitigations were useless (same DNS dependency). **phase2 Flux-Ready preflight failed `exit=2`** (before any worker roll; `Restart=on-failure RestartSec=900` auto-retry).
- 🩹 **Break-glass recovery:** `kubectl apply -k infrastructure/coredns/` recreated SA/RBAC/CM/Service from git → DNS up instantly (Service → 3 coredns-ha endpoints) → Flux unblocked, `flux reconcile kustomization coredns` succeeded, all 7 kustomizations `READY=True` (`5f4d202`). phase2 auto-retry then passed.
- ✅ **Self-sustaining now / no revert:** recreated objects carry **no** owner-label, so future `--disable` restarts find nothing addon-owned to delete → deadlock is a one-time transition cost. `--disable=coredns` stays (removing it → k3s redeploys a conflicting addon).
- 🧠 **Lesson:** a controller that fetches its own source over cluster DNS cannot rebuild that DNS from a deleted state — deadlock, not gap. SSA `force:true` changes field-manager, NOT labels. Safe sequence = strip owner-labels / redeploy under distinct basename and verify `kubectl get` shows none, THEN `--disable`.

### 2026-05-31 (monitoring/controllers base/staging → flat — F-14 monitoring completion) ✅
- 🔄 **Monitoring controllers flattened** (`b53a4cab`): `monitoring/controllers/{base,staging}` split → flat `monitoring/controllers/<component>/` (kube-prometheus-stack/loki-stack/popeye/victoria-metrics). Completes the monitoring side of the F-13/F-14 single-env collapse — `b442c098` had only removed the per-component passthrough overlays, leaving the base/staging dirs.
- **kps namespace fold:** the dropped `staging/kube-prometheus-stack` overlay's only job was `namespace: monitoring` → folded into the flat `kube-prometheus-stack/kustomization.yaml`. loki/popeye/victoria-metrics self-namespace (referenced raw from base, no transform).
- **Proof:** `kustomize build monitoring/controllers` byte-identical to pre-change `…/staging` render (same SHA256, 1058 lines, 17 resources); kubeconform 17/17. Flux applied `b53a4cab` READY=True, path repointed `./monitoring/controllers/staging`→`./monitoring/controllers`, zero workload churn (monitoring pods 26–27h, no restarts).
- 🧠 **Single atomic commit** (dir move + path repoint together) → path-change race window near-zero; drove prompt `flux reconcile source git flux-system` + `kustomization monitoring-controllers`. CI billing-blocked → local ladder + cavecrew gate (user-authorized bypass). Executed in an isolated git worktree off origin/main.

### 2026-05-29 (F-23 image pinning to 3-component + CI image-pin gate) ✅
- ⚖️ **F-23 closed** (`ba65f445`+`693e41a8`+`519ecead`). Two long-parked image-pin violations + the gate gap that let them hide.
- **claude-telegram (own image):** rewrote `claude-telegram-build.yml` version generator 2-component (`1.<minor>`) → **3-component** (`major.minor.patch`). Each scheduled rebuild auto-increments PATCH (dep refresh = patch); minor/major via manual `workflow_dispatch` input (validated `^\d+\.\d+\.\d+$`); transition-safe (3-comp glob, falls back to latest 2-comp `1.NN`→`1.NN.0`). Triggered build → `1.25.0` (GHCR image + git tag `claude-telegram-v1.25.0`). Bumped manifest `:1.24`→`:1.25.0` (chezmoi-init + main + sync). Live: pod Ready, both containers 0-restart, init Completed exit 0 on the fresh build.
- **seleniumbase-scrapper (3rd-party):** upstream publishes only `:latest`+`:v1.0` — no patch tag exists. Digest-pin declined (user pref). So `:v1.0` is the deepest available pin; documented in-manifest + allowlisted in the auditor.
- 🔬 **Root-cause fix, not just instances — new CI gate.** Kyverno's image-pin policy + CI only reject `:latest`/no-tag, so `:v1.0`/`:1.24` (major.minor) floated silently for weeks. Added `scripts/ci/image-pin-audit.sh` + a hard `image-pin` job in `validate.yaml`: asserts every container/init/ephemeral image is `major.minor.patch[-variant]` or `@sha256` digest. Skips HelmRelease docs (chart-version pinning) + SOPS. Allowlist (accept 2-comp) for native-2-component upstreams: postgres/postgresql (`18.4`), seleniumbase-scrapper. Recurses workloads via `yq '.. | select(tag=="!!map" and has("image")) | .image'`; filters yq's `---` multi-doc separators. First CI run green.
- 🧠 Renovate untouched — both images use the default kubernetes manager (3-comp handled natively); `pinDigests:false` leaves the 2-comp allowlisted images alone.
- 🔬 **Pattern (4th this session):** gap-class → write a `.sh` that closes the gate's blind spot → tool finds + gates the instances. np-coverage.sh (per-pod NP) → F-49; image-pin-audit.sh (semver pin) → F-23.

### 2026-05-29 (F-24 pricebuddy apprise sidecar non-root hardening) ✅
- ⚖️ **F-24 closed** (`c21b80a8`): pricebuddy apprise sidecar + its init container now run **non-root**. Sidecar: `runAsUser:1000` + `runAsNonRoot:true` + `readOnlyRootFilesystem:true`, removed cap adds `[CHOWN,SETUID,SETGID,DAC_OVERRIDE,FOWNER]` (kept drop ALL), added `/tmp` (emptyDir `medium:Memory`) + `/plugin` + `/attach` emptyDirs (upstream README "Hardened K8s" pattern). Init: `runAsUser:0→1000`. Pod `fsGroup:33` unchanged.
- 🔍 **Research correction:** the backlog note assumed `v1.4.1` predated PR #273 (non-root default) and needed a bump. Wrong — #273 merged Nov 2025, v1.4.0 shipped May 2026, so the pinned v1.4.1 already has it. No image change. (`docker pull` web-confirmed via Exa.)
- 🧠 **Chose non-root init over removing it.** Upstream's "drop the init" path needs a SOPS secret holding the assembled `tgram://<bot>/<chat>/` URL mounted into /config — more moving parts + a new secret. Making the existing init non-root eliminates the only root with far less risk; init still renders /config/pricebuddy.cfg from the telegram secret each start.
- 🧠 **Reviewer false-positive (documented to prevent recurrence):** cavecrew flagged a HARD BLOCKER — "emptyDir + fsGroup:33 → mode 0o0750, group can't write → init crashes." **Refuted by live evidence:** kubelet's fsGroup ORs in `0o770 + setgid` (never strips bits), so the shared `/config` emptyDir was observed `drwxrwsrwx` (0o2777); apprise image user is `apprise:x:1000:100` so `runAsUser:1000` matches the image's own non-root user; grafana (fsGroup:472, non-root) is healthy cluster-wide on the same mechanism. Re-review with evidence → APPROVED. **fsGroup makes volumes group-WRITABLE — that is its purpose.**
- ✅ **Live verify (notification path, not just pod-up):** Recreate rollout clean; init Completed exit 0 (non-root write to /config succeeded); apprise uid=1000, `/status`=200; `/config/pricebuddy.cfg` owned `1000:33`; **POST `/notify/pricebuddy` → HTTP 200, real telegram delivered**. All 3 containers ready / 0 restarts.
- 🔎 **Surfaced (pre-existing, not in diff):** `jez500/seleniumbase-scrapper:v1.0` is major.minor-only — Kyverno image-pin only catches `:latest`/no-tag, so this class slips CI. Tracked F-23; motivated `image-pin-audit.sh`.

### 2026-05-29 (F-49 monitoring per-pod NetworkPolicy gaps — found by new np-coverage.sh) ✅
- 🔬 **Tooling found it, not a human.** Built `_shared/np-coverage.sh` (per-pod NP auditor) immediately after F-48 because the existing `np-gap.sh` + Kyverno `require-networkpolicy` (F-5) are NAMESPACE-level — a ns with ≥1 NP passes even if a pod inside is selected by none. First live run flagged 3 monitoring gaps that had been invisible to every gate.
- ⚖️ **F-49 closed** (`208dd218`): (1) **deleted** orphan `prometheus-network-policy` — KPS HelmRelease has `prometheus.enabled: false` (stack runs VictoriaMetrics), so its `app.kubernetes.io/name: prometheus` target pod never exists; the NP enforced nothing. Flux pruned it on reconcile. (2) **added** `kube-state-metrics-network-policy` — ksm pod was uncovered; ingress 8080 from monitoring ns (vmagent scrape), egress DNS + k8s API (ksm lists cluster objects). (3) **added** `prometheus-operator-network-policy` — operator pod was uncovered; **selector `app: kube-prometheus-stack-operator`** (the Service selector, NOT `app.kubernetes.io/name` — same label-verification lesson as F-48), ingress 10250 all-source (https = metrics + admission webhook; API-server source IPs vary — cnpg-operator-policy webhook precedent), egress DNS + k8s API.
- ✅ **Live verify:** orphan gone; both new NPs bind their pods; ksm scrape target `health=up` with zero unhealthy targets cluster-wide; ksm + operator Ready / 0 restarts / 0 errors (egress to API intact); `np-coverage.sh` re-run clean except `popeye/popeye-network-policy` ORPHAN — a weekly CronJob with no pod running = the documented expected false-positive.
- 🔬 **Lesson:** ns-level NP coverage gates create a blind spot for individual pods in already-guarded namespaces. The per-pod auditor (`np-coverage.sh`, wired into `/k8s-diagnostics` §5) is the complement; run it after adding any workload to a ns that already has NetworkPolicies. ORPHAN findings also catch dead NPs left behind when a component is disabled (prometheus here).

### 2026-05-29 (F-48 redis-operator NetworkPolicy — closes every-ingress invariant) ✅
- ⚖️ **F-48 closed** (`88a62e50` NP + `703c61fa` egress fix-forward): added `redis-operator-network-policy` in `databases` ns. Ingress: metrics 8080 from monitoring ns (no webhook — HR `webhook: false`). Egress: DNS, k8s API (192.168.1.127/32:6443), redis 6379 + sentinel 26379.
- 🧠 **Two backlog-brief assumptions proven WRONG on live cluster — both would have shipped silently:**
  - Selector is **`name: redis-operator`**, NOT `app.kubernetes.io/name: redis-operator` (the F-46 brief / cnpg-operator-policy shape). The wrong label matches **zero pods** → a NetworkPolicy that looks present but enforces nothing = gap stays open while reported closed. Verified via `kubectl get pod -o jsonpath='{.metadata.labels}'` before writing.
  - Operator does **NOT** reach redis via API exec — it **dials pods directly** (`checkRedisServerRole` → `dial tcp redis-replication-0:6379`). The first commit's minimal egress (DNS + API only) broke role-checks the moment Flux applied it: redis-operator logged 56 × `connect: connection refused` to `redis-replication-0:6379`, earliest timestamp = exactly NP-apply time, zero before. **kube-router renders NP-blocked egress as TCP "connection refused" (RST), not a timeout** — so the symptom looks like "redis is down", not "policy blocked it". Fix-forward added redis(6379)+sentinel(26379) egress (`namespaceSelector databases` AND `podSelector app In [redis-replication,redis-sentinel-sentinel]`, matching immich + redis-ha-network-policy precedent).
- 🧠 **Naming:** reviewer flagged `redis-operator-policy` → renamed `redis-operator-network-policy` per invariant + `percona-operator-network-policy` sibling precedent (`cnpg-operator-policy` is the odd one out, not the rule).
- ✅ **Live verify post-fix:** 0 errors / 90s, RedisReplication CR `MASTER` repopulated (role-check working), operator pod 0 restarts, NP binds the pod (POD-SELECTOR `name=redis-operator`).
- 🔬 **Lesson:** "mirror sibling X policy" is not enough for operator NetworkPolicies — verify (a) the actual pod labels and (b) whether the operator talks to its data plane over the **network** (dial) vs the **API** (exec). A timeout-vs-RST distinction matters: under kube-router, a blocked egress surfaces as "connection refused", masquerading as an app-down problem.

### 2026-05-29 (F-46 redis-operator HR remediation parity) ✅
- ⚖️ **F-46 closed** (`1d473d5f`): added full cnpg-operator HR parity to redis-operator — `install.crds: Create` + `install.remediation.retries: 3` + `maxHistory: 3` + `upgrade.crds: CreateReplace` + `upgrade.remediation.retries: 3` + `remediateLastFailure: true` + `rollback.recreate: true` (kept pre-existing `rollback.cleanupOnFail: true`). Helm upgrade.v2 succeeded; HR `Ready=True` post-reconcile; operator pod stayed `homelab-critical`.
- 🧠 **Reviewer caught parity miss:** first pass omitted `rollback.recreate: true` (cnpg HR has it). Fix-forward in same session before push. Lesson: when "match X HR shape", DIFF the full rollback block too, not just install/upgrade.
- 🔎 **New backlog item F-48:** redis-operator pod has NO NetworkPolicy (live ns audit shows `cnpg-operator-policy` covers cnpg, `redis-ha-network-policy` covers data plane, but operator pod is naked). Hard-invariant gap. Mirror cnpg-operator-policy shape with selector `app.kubernetes.io/name: redis-operator`. Pre-existing since 2026-04-15, surfaced during F-46 review.

### 2026-05-29 (F-30 truly closed — Commit J gap-closure + F-47) ✅

- 🔍 **Self-critique driven fix.** Post-F-30-closure audit (`audit-priority-class.sh --missing`) found 4 source Jobs at priority 0 that the Commit F investigator scope missed: `n8n-user-provision`, `mealie-user-provision`, `obsidian/couchdb-init`, `databases/immich-init-extensions`. Plus flux-system `notification-controller` was punted to F-47 backlog instead of being fixed.
- ⚖️ **F-30 Commit J** (`6da41aa7`, 5 files / 5 insertions): added `priorityClassName: homelab-standard` to all 4 missed Jobs (all have `kustomize.toolkit.fluxcd.io/force: enabled` → Flux delete+recreate, idempotent). Added `priorityClassName: system-cluster-critical` to `notification-controller` Deployment in `clusters/staging/flux-system/gotk-components.yaml` (PARITY with the 3 already-present Flux controllers at lines 2607/3429/4985 — upstream Flux gotk omits notification-controller from this pattern). F-47 closed.
- ✅ **Final audit:** `homelab-critical=35` + `homelab-standard=52` + `system-cluster-critical=6` + `system-node-critical=6`; `--missing` empty. KPS alertmanager STS spot-verified `homelab-standard` (Prom-Op propagated `alertmanagerSpec.priorityClassName` to generated STS). Health snapshot: Flux 6/6, pods 91 running 0 unhealthy, 0 alerts firing.
- 🧠 **Lesson:** trust audit-priority-class output over investigator scope. Investigator caves on overlay/setup-Jobs that aren't under canonical `apps/base/` (the 3 missing jobs live in `apps/staging/`); cluster reality > file-map heuristics. Codified in `audit-priority-class.sh --missing` workflow.

### 2026-05-29 (F-30 fully closed — Commits F + G + H + I) ✅

- ⚖️ **F-30 Commit I** (`77e3bb76` ps-operator critical correction): chart `ps-operator` 1.1.0 has no native `priorityClassName` value (verified upstream `values.yaml` + `deployment.yaml`). Injected via `postRenderers` JSON6902 patch on the `Deployment ps-operator` → `homelab-critical`. Parity with cnpg-operator + redis-operator from Commit E (4 DB control-plane operators all critical).
- ⚖️ **F-30 Commit F** (`60af77f0` apps std-tier authored, 18 files / 18 insertions): `priorityClassName: homelab-standard` injected after `automountServiceAccountToken` on 13 authored app Deployments (audiobookshelf, claude-telegram, home-assistant, homehub, homepage, linkwarden, mealie, n8n, paperless-ngx, pricebuddy, stirling-pdf, uptime-kuma, csp-reporter) + 1 STS (meilisearch) + 4 setup Jobs (audiobookshelf-init, home-assistant-admin-setup, immich-admin-setup, uptime-kuma-setup; all `kustomize.toolkit.fluxcd.io/force: enabled` → Flux delete+recreate, idempotent payload). Std-tier pod count 0→18 post-reconcile.
- ⚖️ **F-30 Commit G** (`a118d38d` HR-managed std-tier, 8 files / 149 insertions): uniform `postRenderers` JSON6902 across all chart-managed workloads — cert-manager (3 deploys), kyverno (4), kube-prometheus-stack (3 deploys + 1 DaemonSet via postRenderer, alertmanager STS via `values.alertmanager.alertmanagerSpec.priorityClassName`), victoria-metrics-operator (1), loki (STS + Deploy + DS), alloy (DS), immich (server + ML — extended existing postRenderers patches), mysql-exporter (direct authored Deployment). Postrenderers chosen uniformly because chart-side values keys vary per chart and several charts (cert-manager 1.20.2, ps-operator, alloy 1.8.2, vm-op 0.63.1) omit the hook entirely. Std-tier pod count 18→48 post-reconcile.
- ⚖️ **F-30 Commit H** (`8a706db0` batch CronJobs, 8 files / 8 insertions): `priorityClassName: homelab-batch` injected in `spec.jobTemplate.spec.template.spec` after `restartPolicy` on all 8 CronJobs — backup-replication, couchdb-backup, mysql-backup, postgres-backup, postgres-update-extensions, immich-backup, pvc-backup, popeye. Future-spawned Jobs inherit the class; existing Succeeded pods stay at priority 0 until TTL.
- ✅ **F-30 fully closed.** Final audit: **35 critical + 48 standard + 8 batch-templates** live. Only un-annotated Running pod left: `flux-system/notification-controller` (1) — `gotk-components.yaml` is self-managed by `flux install`; tracked as new backlog row **F-47**. Full preemption hierarchy now intact (critical evicts standard evicts batch under node pressure).
- 🧮 **Pre-flight CNPG gotcha re-confirmed:** cnpg chart `cloudnative-pg` 0.28.2 natively exposes `priorityClassName` at top-level values (Commit E worked direct). ps-operator 1.1.0 does NOT — required postRenderer fallback. Pattern documented for future operator HRs.
- 🔎 **New backlog item F-47:** flux-system `notification-controller` lacks priorityClassName. Inject `homelab-standard` via patch on `clusters/staging/flux-system/gotk-components.yaml` (other Flux controllers also miss it — confirm coverage via audit).

### 2026-05-28 (F-30 Commit E — critical-tier priorityClassName: DB operators)
- ⚖️ **F-30 Commit E** (`f882c1c9`): `priorityClassName: homelab-critical` on `cnpg-operator` HR + `redis-operator` HR (`values.priorityClassName` on both Helm charts). Without these operators a node outage during a DB primary failure = no automatic promotion → data plane outage. Therefore operators belong in critical tier alongside the DBs they manage. 3 operator pods rolled live (cnpg-operator ×2 + redis-operator ×1).
- 🧮 **Count correction:** prior doc said "30 critical pods" — arithmetic typo (18+4+4+2+3=31, plus 3 operators = **34 total** at homelab-critical/100000).
- 📝 **Memory + codemap updated:** `[[gotchas]]` got CNPG v1.29.x priorityClassName-not-rolling-update + Pooler-separate-CR + DB primary-pin patterns (per engine); also fixed stale "CouchDB ns `couchdb`" → ns `databases`. `CODEMAPS/databases.md` gained a "Scheduling tier (F-30)" section.
- 🔎 **Reviewer side-finding (out-of-scope, parked):** `redis-operator` HR lacks `install.remediation.retries` + `upgrade.remediation.retries` blocks (pre-existing, pre-dates Commit E). Add to REVIEW.md backlog.
- ❓ **mysql-exporter** intentionally skipped (observability, not data-plane) — picks up `homelab-standard` later.

### 2026-05-28 (F-30 Commit C — critical-tier priorityClassName: authored Deployments) ✅
- ⚖️ **F-30 Commit C** (`1bcdbc75`): `priorityClassName: homelab-critical` on the 4 authored critical-tier Deployments — `authentik-server`, `authentik-worker`, `blocky`, `cloudflared`. Field placed after `serviceAccountName` + `automountServiceAccountToken` (consistent across files). All 8 pods rolled clean (HA, multi-replica + anti-affinity preserved traffic), live `homelab-critical` priority=100000 distributed W1+W2.
- ✅ **F-30 critical tier 100% complete.** **30 critical-tier pods** at priority 100000 across all data-plane + ingress + SSO + DNS + monitoring-core:
  - DBs: 4 CNPG (2 instance + 2 pooler) + 7 Percona (2 mysql + 3 orch + 2 haproxy) + 2 CouchDB + 5 Redis (2 replication + 3 sentinel) = **18**
  - Ingress + tunnel: 2 Traefik + 2 cloudflared = **4**
  - SSO: 2 authentik-server + 2 authentik-worker = **4**
  - DNS: 2 blocky = **2**
  - Monitoring core: 1 vmsingle + 1 vmagent + 1 vmalert = **3**
- 📌 Remaining F-30: **standard tier** (~14 apps + meilisearch + csp-reporter + mysql-exporter) and **batch tier** (~16 Jobs/CronJobs) — un-annotated workloads stay at priority 0 (floor); critical hierarchy is now intact, preemption order under node pressure works correctly.

### 2026-05-28 (F-30 Commit D + DB primary-node-pinning to W1)
- ⚖️ **F-30 Commit D** (`ab74c45a`): `priorityClassName: homelab-critical` on the remaining DB-tier components — CouchDB HelmRelease (`values.priorityClassName`, chart `couchdb/couchdb` 4.6.3), RedisReplication CR + RedisSentinel CR (`spec.priorityClassName`, OT operator `redis.redis.opstreelabs.in/v1beta2`). Discovered during B verification: CouchDB + Redis live in `databases` ns alongside Postgres+MySQL — not their own ns. All 7 pods rolled clean on Flux apply (2 couch + 2 redis-replication + 3 redis-sentinel, live `homelab-critical` priority=100000).
- 🔄 **DB primary node-pinning to W1** (operational, no commit). User: "W1 is more performant — primaries should live there." Pre-switchover: CNPG primary=main-postgres-11 on W2; Percona primary=main-mysql-mysql-0 on W2; Redis master=redis-replication-0 on W2.
  - CNPG: `kubectl cnpg promote -n databases main-postgres main-postgres-12` → primary=main-postgres-12 on **W1** ✓
  - Percona: `kubectl exec main-mysql-orc-0 -- orchestrator-client -c graceful-master-takeover-auto -i main-mysql-mysql-0.main-mysql-mysql.databases:3306` → primary=main-mysql-mysql-1 on **W1** ✓ (mysql-0 briefly `downtimed` flag, auto-clears)
  - Redis: `redis-cli -p 26379 sentinel failover myMaster` → master=redis-replication-1 on **W1** ✓ (first failover reverted within seconds — `master_replid2` showed brief role-swap then bounce; second failover stuck. **Caveat:** Sentinel re-fails over dynamically under load/outage — Redis master pinning to W1 is best-effort, not permanent. The HA design treats master as fluid; pinning is courtesy only.)
- 🟰 **CouchDB is multi-master active-active** — no "primary" concept, both nodes accept writes. No switchover applicable.
- ✅ **F-30 critical tier now complete on every data-plane component:** 22 critical-tier pods live `homelab-critical`/100000 (4 CNPG + 7 Percona + 7 Redis/Couch + 3 VM + 2 Traefik) — DB primaries on W1.

### 2026-05-28 (F-30 Commit B + B' — critical-tier priorityClassName: DBs CNPG + Percona + Pooler)
- ⚖️ **F-30 Commit B** (`79f1c1cb`): `priorityClassName: homelab-critical` on CNPG `Cluster` (`spec.priorityClassName`) and Percona `PerconaServerMySQL` per-component (`spec.mysql`, `spec.orchestrator`, `spec.proxy.haproxy`).
- 🩹 **Commit B'** (`ae471421`): follow-on patch — CNPG `Pooler` is a SEPARATE CR (`spec.template.spec`), missed in B. Added `priorityClassName: homelab-critical` on the PgBouncer pod template.
- ✅ **Percona auto-restarted** on operator reconcile (all 7 pods — 2 mysql / 3 orchestrator / 2 haproxy — live `homelab-critical` priority=100000, 19:10–19:11Z).
- 🩹 **CNPG required manual restart trigger.** Operator v1.29.1 doesn't treat `priorityClassName` as a rolling-update trigger — instance pods stayed at priority 0 after spec change. Triggered via `kubectl cnpg restart -n databases main-postgres` (kubectl-cnpg krew plugin; CNPG-official restart, equivalent to `kubectl rollout restart` for Deployments; not a spec mutation; no Flux drift; internally sets `cnpg.io/restart` annotation). Restarts replica first (cluster healthy intermediate state), then needed `kubectl cnpg promote main-postgres main-postgres-11` switchover + second `kubectl cnpg restart` to roll the old primary (-12). Pooler RollingUpdate (`maxSurge:0/maxUnavailable:1`) handled the pgbouncer pods automatically on Kustomization apply.
- ✅ **Final CNPG state**: primary=main-postgres-11, ready=2/2, all 4 instance+pooler pods `homelab-critical`/100000. Health uninterrupted (annotation rolls replica only while cluster healthy; switchover is the only brief moment).
- 🌀 **Parallel-session race:** push raced with bot fix on `apps/base/pricebuddy/deployment.yaml` (`d261abfe`/`598f5fb1` from another session vs `f6309e29` on remote). Resolved via `git pull --rebase` autostash; ended up consolidated by the parallel session.

### 2026-05-28 (F-30 Commit A — critical-tier priorityClassName: VM-core + Traefik)
- ⚖️ **F-30 Commit A** (`85d39527`): injected `priorityClassName: homelab-critical` (value=100000) on `VMSingle`/`VMAgent`/`VMAlert` (`spec.priorityClassName`) + Traefik HelmRelease (`values.priorityClassName`). First of three critical-tier commits (B = CNPG + Percona; C = authored Deployments authentik×2 + blocky + cloudflared).
- 🎯 Why critical-tier first: PriorityClass `homelab-critical/standard/batch` were defined in W9 (2026-05-24) but never injected — `globalDefault: false` meant un-annotated pods = priority 0 (floor). Injecting standard-tier into apps while DBs/ingress/monitoring stayed at 0 would **invert the hierarchy** (a standard app could preempt a DB under pressure). Correct fix: critical tier (operator/Helm-managed: DBs/ingress/monitoring-core) FIRST.
- ✅ Verified live: vmagent / vmalert / vmsingle (×1 each) + traefik (×2) all `Running` with `priorityClassName=homelab-critical` and `priority=100000` post-reconcile (Flux `infrastructure-controllers` + `monitoring-configs` applied rev `85d3952`). VM operator did create-before-terminate rolling update; old vmagent/vmalert pods exited 0 (`Succeeded`).
- 🪜 Lowest-blast bundling: VM-core (metrics blind ~30s, no user impact) + Traefik (rolling, 2-replica ingress no drop) → DB tier next.

### 2026-05-27 (F-39 — claude-telegram RoRFS + PSS restricted)
- 🛡️ **F-39** (`3c5ce4aa`): `readOnlyRootFilesystem: true` on all 3 containers (init `chezmoi-init` + `claude-telegram` + `sync`), `runAsNonRoot: true` at pod level, and a `/tmp` emptyDir mount added to `sync` (init + main already had one). Closes the claude-telegram RoRFS gap deferred from F-6 (Wave 8).
- 🔬 **Live write-audit before editing:** `find / -xdev -type f -mmin -45` inside both running containers showed only the 3 kubelet bind-mounts (`/etc/hosts`, `/etc/hostname`, `/etc/resolv.conf`) — zero writes to the container root fs. HOME (`/home/akhozya`) is a PVC, `/tmp` an emptyDir; all app writes (session/audit/data, chezmoi, git repos) land there. `sync` lacked `/tmp` so git/chezmoi temp writes would EROFS under RoRFS once a 30-min pull cycle hit an update → added the mount preemptively. Init exited before audit; its script is fully HOME+/tmp-relative by inspection.
- 🔒 **PSS baseline→restricted** (`3d080256`): only restricted gap was `runAsNonRoot != true` (everything else — privesc/caps/seccomp/volume-types/non-zero-uid — already compliant). Proven with `kubectl label ns ... enforce=restricted --overwrite --dry-run=server` BEFORE editing (F-45 lesson): pre-change = 1 warning `runAsNonRoot != true`, post-change (new pod) = zero warnings. Label flip does not restart the pod.
- ✅ Verified live: new pod 2/2 Running, RoRFS=true ×3 + runAsNonRoot=true, no EROFS/read-only errors in main or sync logs, ns labels `restricted` ×3, pod still admitted. Init's github SSH-pull `Connection refused (port 22)` is pre-existing F-12 behavior (port-22 egress dropped Wave 1; GitHub intended over 443), `|| true`-tolerated, repos cached on PVC — not introduced by F-39.
- ⚖️ **F-37 closed won't-do (same day):** uptime-kuma ForwardAuth-to-Authentik dropped. App is internal-only (`uptime.h0melab.work`, internal Traefik, no Cloudflare Tunnel mapping) and already self-protects with built-in auth + TOTP 2FA. No app in repo uses ForwardAuth (0 hits); uptime-kuma has no native OIDC, so the finding's only SSO path was brand-new infra (proxy provider + outpost pod + middleware + outpost→authentik NetworkPolicy). Rejected as **net negative — circular dependency**: gating the status dashboard behind Authentik means an Authentik/Postgres/outpost outage locks you out of the tool needed to diagnose that outage. Edge-auth defense-in-depth value applies to internet-exposed apps; this isn't one. Revisit only if uptime-kuma is ever exposed via CF Tunnel.
- 🔄 **F-15 (`002e06f7`) — direction inverted after research.** Finding said "make all app-DB manifests app-owned (blocky pattern)." Research overturned it: CNPG `Database.spec.cluster` is a `LocalObjectReference` → every `Database` CR must live in ns `databases` (where `main-postgres` is); 4 of 7 apps (immich/linkwarden/mealie/paperless-ngx) set `namespace:<app>` in their staging kustomization, which would rewrite the moved CR's ns and break the cluster ref; Flux's canonical model treats DB provisioning as infrastructure (apps `dependsOn` it). So consolidated the OTHER way — moved blocky's `cnpg-database.yaml`(→`blocky-database.yaml`) + `blocky-db-user.yaml` from `apps/staging/blocky/` into `infrastructure/configs/staging/databases/postgres/`. All 7 apps' DB provisioning now in one canonical, ns-correct, infra-owned dir. **Ownership handoff verified clean:** `databaseReclaimPolicy: retain` (DB never dropped) + Flux GC label-protection (skips pruning objects whose `kustomize.toolkit.fluxcd.io/name` points to another Kustomization) + dep order (`infrastructure-configs` adopts/relabels before `apps` reconciles) → the SAME Database CR object was re-owned by `infrastructure-configs`, `applied=true`, AGE 31d preserved (never re-created), blocky pods untouched (2d5h uptime). Lesson: CNPG `Database` CR is namespace-bound to its Cluster — DB provisioning belongs in the infra layer, not co-located in app dirs.

### 2026-05-26 (F-38 — disallow-host-namespaces excludes narrowed)
- 🛡️ **F-38** (`a35481fb`): replaced the whole-namespace `databases` + `monitoring` excludes on the `disallow-host-namespaces` Kyverno ClusterPolicy (Enforce) with a precise label selector. `databases` dropped entirely (verified zero host-namespace pods); `monitoring` narrowed to `app.kubernetes.io/name: prometheus-node-exporter` (the only host-ns workload there — DaemonSet, hostNetwork+hostPID for node metrics). Same selector pattern as F-4/F-6.
- 🔓 **Closed a real gap:** `databases` ns is PSS **privileged** (no host-ns block from PSS) AND was whole-ns excluded from Kyverno → host namespaces were completely unguarded there. Now Kyverno denies them (positive `--dry-run=server` test: hostNetwork pod in `databases` rejected by `host-namespaces` rule). Scan 0-fail; node-exporter pods stay Running.
- 📝 **Doc-drift fix (post-F-38 audit):** corrected stale PSS keyfact in `HOMELAB_ANALYSIS.md` — was "restricted on 14 ns / 2 privileged / 1 baseline", live is 11 `restricted` / 10 `baseline` / 6 `privileged`. Opened **F-45**: audit the 6 privileged ns for baseline-tightening.
- ✅ **F-45 closed not-viable (same day):** investigated all 6 — none can drop to `baseline`. First scan wrongly flagged `databases`/`loki`/`backup-replication` as tightenable; live `--dry-run=server` proved **PSS baseline forbids hostPath volumes** (`violates PodSecurity "baseline:latest": hostPath volumes`), and all 3 use hostPath (Alloy journal / backup-storage CronJobs / backup dir). Corrected before any commit — zero changes shipped, nothing to revert. All 6 privileged justified (host-ns / GPU / NET_ADMIN / hostPath). Lesson: PSS-baseline scans must check hostPath.
- L13-safe: node-exporter label is on both pod + DaemonSet metadata (autogen covers controller); not a Job.

### 2026-05-25 (Ultrareview housekeeping batch — F-44/W13 docs+mem; F-23/F-24 research)
- 📄 **F-44** (`669790ee`): documented `pre-ultrareview-2026-05-23` DR handle + a "Configuration Rollback (Git Tags)" section in `.backup/README.md` (config-rollback path distinct from data restore).
- 🗂️ **W13-hist** (`6790af4a`): rotated 2025 Oct–Dec changelog (1849 lines) → `docs/archive/HOMELAB_HISTORY_2025.md`; main file 3631→1782 lines + pointer. 2026 entries + Completed-Items archive retained.
- 🗃️ **W13-docs** (`79fbca85`): `git mv`'d 10 stale point-in-time docs (kyverno recs/summary, NP egress audit, mysql-operator analysis, app-alternatives, authentik-sso, cloudflare-gateway, k3s-NP-API, notification-review, renovate-updates) → `docs/archive/` + new `docs/archive/README.md` index. Durable conclusions already in CODEMAPS/skills; referrers (REVIEW.md, HISTORY) updated. FIREWALL_SECURITY kept (not flagged).
- 🔗 **W13-mem** (dotfiles `d5ebdd2`): bidirectional links between the two ultrareview memories, chezmoi-synced.
- 🔬 **F-23 research:** `claude-telegram-bot:1.22` is already immutable (unique-tag-per-build workflow, no drift). Literal `1.22.0` needs a 3-component workflow scheme + Renovate regex + rebuild-before-bump → parked.
- 🔬 **F-24 research:** caronc/apprise now ships native non-root + RO-FS by default (upstream PR #273, ~Nov 2025). pricebuddy apprise sidecar hardening is feasible — bump past v1.4.1, adopt upstream pattern, drop root init, verify notifications (attended).
- ⚠️ **F-30 reclassified attended:** priorityClassName injection is NOT a safe partial — `globalDefault:false` makes un-annotated pods priority 0; injecting apps→standard while operator-managed DBs stay at 0 inverts the hierarchy. Correct fix sets critical-tier via operator CRs/Helm first (DB/ingress restarts). See REVIEW.md Resume table.

### 2026-05-25 (worker-node-2 DiskPressure — rebuilderd dep-cache + nspawn-orphan cleanup, weekly→daily)
- 🔴 **W2 DiskPressure → pod evictions.** Evicted/`PodCrashLooping` pods (alloy, loki-canary, node-exporter, claude-telegram) traced NOT to the pods but to **kubelet nodefs = `/mnt/extra-storage`** (NOT the k3s data-dir `/mnt/k8s-storage`) crossing the ~129GiB eviction threshold. `df /` is a red herring — confirm via `/api/v1/nodes/<n>/proxy/stats/summary`. Acute trigger: the day's reboot SIGKILLed in-flight `systemd-nspawn` builds → ~310G orphaned `repro/electron*` roots; `rebuilderd-watchdog.timer` swept them, disk 88%→50%, DiskPressure cleared (after kubelet's ~5min transition period), corpses then deleted.
- ✅ **Daily repro-cleanup on both workers** (commits `ade40be7`/`5ccb60aa`/`ef3e9429`; role `roles/rebuilderd/`): timer `Sun 08:00`→**daily** (`*-*-* 08:00:00`); script now also (a) sweeps stale `.#machine.root*` machinectl snapshot dotdirs (the `for dir in */` glob never matched dotdirs → 12 piled up Dec25–Jan26, line-17 skip was dead code), (b) **`paccache -rk2`** prunes the per-name worker dep-cache (archlinux-repro downloads archive-pinned deps and NEVER prunes → W2 287G / W1 319G unbounded; flock-guarded vs active builds), (c) guards `cd "$REPRO_DIR" || exit` (unguarded cd + service CWD=`/` → `rm -rf` in `/` if mount absent post-reboot). New host_var `rebuilderd_worker_dir`.
- 🧹 **One-time slot reclaim:** stale rebuilderd-worker name-slots from prior higher-concurrency runs removed — W2 `{2,3,6}` (~64G), W1 `{2,3,4,5,6}` (kept `1`).
- 📌 **Open root cause:** W2 rebuilderd sits on cramped 863G `/mnt/extra-storage` while its 3.6T `/mnt/k8s-storage` (k3s disk) is 1% used; W1 runs rebuilderd on its 4.2T disk and never pressures. Relocating W2 → `/mnt/k8s-storage` is the durable fix (PENDING). Memory: `gotcha_worker_node2_diskpressure`.

### 2026-05-25 (Wave 8 Kyverno promote — F-4/F-5/F-6 Audit→Enforce) ✅
- ✅ **3 invariants now machine-enforced.** Promoted `disallow-privilege-escalation`, `require-drop-all-capabilities`, `require-networkpolicy`, `require-readonly-rootfs` from Audit→**Enforce** after a clean fix-forward scan. **12 Kyverno policies, all Enforce.** Commits: `8a4295f2` (F-4/F-6 excludes + homehub init RoRFS) → `60f2a2cb` (F-6 robust Job handling) → `864231ee` (flip). Post-flip: priv-esc 44 pass/0 fail, drop-caps 44/0, networkpolicy 160/0, readonly-rootfs 40/0; live deny confirmed (`validate.kyverno.svc-fail` blocked a RoRFS-violating dry-run pod).
- 🔵 **Soak surfaced more than the soak-start baseline.** F-6 baseline (captured 2026-05-24 at soak start) showed 11 workloads; the full background-controller cycle later revealed **23** (databases StatefulSets, backup CronJobs, 2 setup Jobs). Confirms the skill anti-pattern: a soak-start baseline undercounts because `background: true` hasn't completed a scan cycle — always re-scan after ≥24h before promoting.
- ✅ **Fix-forward over exclude where the app tolerates it.** `homehub` init `setup-config` got `readOnlyRootFilesystem: true` (writes only to a mounted `/app/config` emptyDir; main container already RoRFS). `uptime-kuma-setup` Job flipped RoRFS:false→true (HOME=/tmp + `pip install --user` → all writes land in the mounted /tmp; Flux `force: enabled` recreated it → Completed under RoRFS).
- ✅ **Excludes.** F-4: ns `databases`/`immich`/`percona-mysql` + label-selectors `loki`→alloy, `monitoring`→node-exporter. F-6: + ns `home-assistant`/`paperless-ngx`/`backup-replication`/`claude-telegram` (F-39 gate)/`pricebuddy`/`stirling-pdf`/`mealie` + selectors `loki`→alloy, `monitoring`→grafana. Mixed-namespace workloads (loki, monitoring) use ns+label so the rest of the namespace stays covered.
- 🔬 **Gotcha (L13): a pod-label exclude does NOT cover a Job.** `job-name:`/`app:` selectors matched the generated pods but not the `autogen-*` rule's **Job resource** — a Job's `metadata.labels` carry only Flux labels, so under Enforce the Job admission would be blocked on recreation. Caught pre-flip via repeated `PolicyViolation` events on `job/uptime-kuma-setup`. Fix: ns-scope exclude (mealie) or fix the workload (uptime-kuma). Memory `gotchas` updated.
- ⚙️ **Ops note:** forced a clean re-scan by `kubectl rollout restart deploy/kyverno-reports-controller` + deleting stale PolicyReports (Kyverno-generated, not git-managed) — the periodic background scan (~1h) lags policy changes; controller-level reports clear immediately but per-pod reports are stale until rescan.

### 2026-05-25 (Reboot-safety hardening — CoreDNS HA + phase2 ClusterIP/loopback gates + cluster-roll/reboot skills)
- 🔴 **CP wedge incident + recovery.** A `kubectl scale coredns --replicas=2` would not materialize — deployment controller stuck at `gen=22 observedGeneration=21`, RS frozen at 1. Root cause: the **CP's k3s loopback loadbalancer `127.0.0.1:6443` was wedged** (5/5 curl timeout) while the apiserver was fine on the node IP + ClusterIP — the embedded controller-manager dials the LB, so its sync stalled silently. `sudo systemctl restart k3s` **HUNG** on the CP; recovery = `sudo reboot`. One clean reboot reconverged everything (all-node ClusterIP, loopback→401, Kyverno admission, CoreDNS→2/2). 8 operator/controller crashloopers (flux ×4, cnpg/ps/vm-operator, kube-state-metrics) stuck on ~5min backoff after ClusterIP healed → `kubectl delete pod` reset backoff → recovered in ~8s. Captured in memory `gotcha_k3s_reboot_ordering` (new CP-loopback variant + role-specific LB ports: CP 6443 / worker 6444).
- ✅ **CoreDNS HA** (commit `48ba71dd`): k3s ships CoreDNS as an Addon with `replicas` unset (=1, single point of failure). `k3s_config` role now inserts `replicas: {{ coredns_replicas|default(2) }}` into the addon source manifest (CP-only, idempotent `ansible.builtin.replace`; Addon controller applies on file change; drift-heal restores after any k3s re-extract). `topologySpreadConstraints` already in the shipped manifest spread the 2 replicas. Deployed + verified: `replicas: 2` in `coredns.yaml`, deploy 2/2.
- ✅ **phase2 ClusterIP + CP-loopback gates** (commit `9cb36ae9`): a node can be `Node.Ready` yet wedged. PLAY 1 now gates each rebooted worker on `clusterip-probe.sh` (DNAT `10.43.0.1`) before uncordon, with a **k3s-agent-restart self-heal rescue**; if still wedged the `serial:1` play aborts (worker left cordoned, `phase2-pending` retained, next worker untouched). PLAY 0 gets a **CP loopback `127.0.0.1:6443` gate as its first task** (fail-fast, bounded retry; does NOT auto-restart k3s — it hangs → operator reboots CP). `clusterip-probe.sh` shipped to `/etc/node-maintenance/bin/` on all nodes (single source of the verdict). CI green.
- ✅ **New skills** (dotfiles): `cluster-roll` — ordered tier-by-tier pod recycle (DNS→operators→platform→DNS-cache→apps), per-tier `rollout status` + all-node ClusterIP re-probe gate, Flux-stale-pod (survivor-UID) delete-pod fallback, aborts if CoreDNS<2 or any node wedged — the safe replacement for `kubectl rollout restart -A`. `cluster-reboot` — thin wrapper over phase1/phase2 + `verify-clusterip.sh`/`watch-reboot.sh` monitors (probes BOTH wedge surfaces).

### 2026-05-25 (Reboot-wedge root-cause + detector/mutex hardening) 🔬️
- 🔬 **Root cause corrected (research).** The post-reboot kube-proxy ClusterIP wedge is NOT an apiserver/kube-proxy startup race — it is an **iptables/nft stale-chain conflict**. The host ships `xtables-nft-multi` v1.8.13 (nft backend) with mixed `nft_compat`+legacy `ip_tables` modules and `prefer-bundled-bin` unset, so after a reboot kube-proxy's atomic `iptables-restore` aborts on stale chains (`CHAIN_USER_ADD`/`RULE_APPEND: File exists`); `KUBE-SERVICES` (incl. the `10.43.0.1:443` DNAT) is never programmed and the proxier retries the poisoned state forever, never self-healing. `restart k3s-agent` rebuilds chains clean — which is why it always "fixes" it. Matches k3s#9243 / k8s#71305. Memory `gotcha_k3s_reboot_ordering` rewritten with the corrected cause + 6 mitigations.
- ✅ **#4 prefer-bundled-bin — root-cause fix** (commit `ec59dd1e`; `group_vars/workers.yml`): workers now set `prefer-bundled-bin: true` so k3s uses its bundled iptables instead of the host xtables-nft shim, eliminating the stale-chain `iptables-restore` conflict at the source. Validated on BOTH workers (restart `k3s-agent` → ClusterIP stays healthy, no `File exists` chain errors recur; only the benign `nft-expr-counter` modprobe warning remains). config.yaml drift is alerted-not-restarted, so it lands on each worker's next k3s-agent restart/reboot (CP left unchanged — the wedge surface is the workers). nftables-native kube-proxy (`--proxy-mode=nftables`, GA in k8s 1.33) is noted as the eventual cleaner fix.
- ✅ **#1 dual-signal detector + N=3 sampling** (commit `4e2a6187`; dotfiles `85ffe47`/`4b58c35`): `clusterip-probe.sh` now requires BOTH the `10.43.0.1:443/healthz` DNAT (401|200) AND the kube-proxy `127.0.0.1:10256/healthz` (200 = last sync OK, a direct wedge signal) across N=3 samples — all must pass. e2e #2 had flapped a single-sample ClusterIP-only probe through a genuinely wedged worker; the dual + N-sample gate now rejects it.
- ✅ **#2/#5 phase2 stabilization + CP-health guard** (in `ec59dd1e`): before uncordon, a rebooted worker gets a 45s settle + final re-probe; and PLAY 1 gates each worker reboot on the CP `/readyz` returning `ok` (retry 18×10s) so a still-recovering CP cannot be compounded by the next worker reboot.
- ✅ **flock mutex** (commit `df0cb64b`; `lib/node-maintenance-lock.sh`): `/run/node-maintenance.lock` serializes the units — config/sync run in **skip** mode (`flock -n`, exit 0 if busy), phase1/phase2 in **wait** mode (`flock -w 900`) — so a drift-heal and a reboot (or two heals) can never run ansible concurrently.
- ✅ **Ops fixes:** `node-config-notify` treats an `exec-condition` skip (the pacman-lock guard) as benign rather than a `FAILED` alert (commit `1f6f9294`); `watch-reboot.sh` gates completion on phase1/phase2 being idle so it no longer false-reports "done" in the phase1→phase2 gap (dotfiles `3e9e977`/`1ed9714`).
- 🤖 **Hands-off trigger** (dotfiles `50a713d`): `trigger-reboot.sh` fires phase1 via `op read 'op://Personal/sudo-homelab/password' | ssh sudo -S` (1Password-injected, single attempt — pam_faillock `deny=3`-safe, aborts on an empty fetch), with an idle-guard and `--dry-run`. 3 e2e rolling reboots passed.

### 2026-05-24 (Post-reboot operational fixes — swap by-uuid + drift-heal cascade + stirling probe)
- 🔴 **drift-heal FAILED on `worker-node`** (`Verify swap active`), cascading `node-maintenance-sync` to `exit=1`. Two findings:
  - **Root cause:** `host_vars/worker-node.yml` pinned `swap_path: /dev/nvme1n1p3`, but the rolling reboot renumbered the NVMe controllers — the swap partition (UUID `a6b9e0ba…`) is now `/dev/nvme0n1p3`. NVMe `nvmeXn1` enumeration follows PCIe probe order and is **non-deterministic across reboots**. Git history shows this flip-flopped twice (`c836a618`/`68bbf6fe`) — each "fix" just chased the current number. **Permanent fix** (commit `2ff39465`): `swap_path: /dev/disk/by-uuid/a6b9e0ba-53f4-4335-8d9f-4d4a4e04306b` — the verify task's `readlink -f` resolves the by-uuid symlink to whatever the current device is. Verified live: resolves → `/dev/nvme0n1p3`, `swapon` match, VERIFY PASS. CP (`/swapfile`) + W2 (`/dev/ArchinstallVg/swap` LVM) already stable — no change needed.
  - **Diagnostic note:** `node-maintenance-sync failed` was a *cascade*, not a git problem — `git pull` succeeded (CP at `466b8fca`); sync runs an initial drift-heal and inherits its exit code. Always read `node-maintenance-config.service` journal first.
- ✅ **stirling-pdf** (commit `466b8fca`, prior in session): post-reboot CrashLoopBackOff (48 restarts) — NOT our change. 2.11.0-fat cold boot exceeded the 90s startup-probe budget on a cold node (page cache empty + contention). Clean logs + graceful exit (not OOMKilled) = probe-kill. Widened `startupProbe.failureThreshold` 9→30 (90s→300s). Recovered.
- 📚 Skills updated: `homelab-node-fix` (new "Rolling reboot fallout" section: kube-proxy wedge, NVMe enum, sync-cascade), `k8s-diagnostics` (probe-kill-vs-OOM tell + cold-boot-is-slower note). REVIEW.md gained a "⏭ Resume Here" outstanding-work table.

### 2026-05-24 (Ultrareview backlog batch — Waves 9/10/12/13 + F-14)
- Context: triggered after a user rolling-reboot of all 3 nodes. First fixed a post-reboot incident — `worker-node` kube-proxy failed to program ClusterIP service rules (`10.43.0.1:443` timed out, 8 pods crashlooped on unreachable in-cluster apiserver); resolved by `sudo systemctl restart k3s-agent` on worker-node. Root cause: rolling-reboot spacing too tight (next node rebooted at ~2 min uptime) — see memory `gotcha_k3s_reboot_ordering`. Not W8-related.
- ✅ **Wave 9** (commit `60a8bf32`): HelmRelease tightening. `driftDetection: {mode: enabled}` on 11 HRs (KPS already had it); `timeout: 10m` on KPS/loki/cert-manager/couchdb; `rollback.cleanupOnFail: true` on mysql/redis-operator/traefik/vm-operator/immich; standardized `interval: 6h` (dropped 30m on mysql + redis-operator). F-16/17/18/20.
- ✅ **Wave 10** (commit `d8ef6891`): polish — F-21 HSTS `includeSubDomains; preload`; F-25 immich+home-assistant `audit/warn: baseline` (enforce kept privileged); F-26 Renovate off-hours schedule + `automerge` patch on `apps/**`; F-30 PriorityClasses (homelab-critical/standard/batch, no injection yet); F-31 backup CronJob `startingDeadlineSeconds: 600` + `backoffLimit: 2`; F-32 pinned `fluxcd/flux2/action@main` → `@v2.8.8` (matched live cluster). **Deferred to attended**: F-37 (no Authentik forward-auth Middleware exists — must be built first), F-38 (narrowing `disallow-host-namespaces` Enforce excludes risks operator admission), F-39 (claude-telegram RoRFS needs live write-audit).
- ✅ **Wave 12 day-0** (commit `971a27d2`): created `csp-strict`/`csp-inline`/`csp-permissive` report-only middlewares in `traefik` ns (script-src tiers; rest mirrors global CSP; report-uri → csp-reporter). No ingress swaps; enforced CSP untouched. Rollout calendar-bound. F-22.
- ✅ **F-14 partial** (commit `b442c098`): collapsed dead passthrough kustomizations in `monitoring/controllers/staging` (loki-stack/popeye/victoria-metrics) + `monitoring/configs/staging/victoria-metrics` into staging roots. Render verified byte-identical (17 controllers / 62 configs). `infrastructure/controllers/staging` deferred (orphan couchdb secret wiring).
- ✅ **Wave 13 partial** (commit `ba9b1b7d`): deleted 10 closed-PR baselines + gitignored dir; deleted stale POPEYE report; archived 15 superpowers plans/specs → `docs/archive/`. `.DS_Store` no-op (0 tracked). HISTORY rotation + stale-doc archive deferred (10 docs have live referrers).
- **Deferred to attended session** (high blast radius / needs verification): R5 (NP Kustomize components — DNS egress varies per app, not clean dedup), F-13 (collapse 16 app staging dirs), F-15 (DB-user migration), infra-controllers F-14, F-37/F-38/F-39. All 5 kustomize roots build green; pre-push reviewer + CI gate passed.

### 2026-05-24 (Wave 8 Kyverno F-4/F-5/F-6 — Audit soak shipped)
- 🏷️ **Tag**: `pre-w8-2026-05-24` (annotated, signed) before first commit.
- ✅ **F-4** (commit `f6eac874`): replaced Kyverno optional-anchor `=()` footgun in `disallow-privilege-escalation` + `require-drop-all-capabilities` with the canonical PSS-restricted mandatory pattern — `=()` dropped from `securityContext` + leaf field (now mandatory per-container), kept only on the optional list wrappers `=(initContainers)`/`=(ephemeralContainers)`; added `ephemeralContainers` for PSS parity. Flipped Enforce → **Audit** for soak. Background scan surfaced **9 workloads** (all operator/privileged — redis-operator, redis-replication, couchdb, main-mysql-{haproxy,mysql,orc}, immich-server, alloy, node-exporter, ps-operator). All legitimate excludes, no authored-manifest regressions.
- ✅ **F-5** (commit `252547ff`): new `require-networkpolicy.yaml` — apiCall context counts NetworkPolicies in `{{request.namespace}}`, `deny` if `<1`. Match Pod; exclude kube-system/kube-public/kube-node-lease/default. **Audit**. Result: **40 pass, 0 fail** — every workload namespace already has ≥1 NP (validates the manual "every ingress = NetworkPolicy" discipline). apiCall verified resolving in **background scan** on Kyverno v1.18.1 (RBAC to list networkpolicies confirmed — no `error` results). Promote-ready.
- ✅ **F-6** (commit `252547ff`): new `require-readonly-rootfs.yaml` — mandatory PSS pattern for `readOnlyRootFilesystem: true`. Excludes only system/operator ns (kube-*, flux-system, kyverno) so soak surfaces the full triage set. **Audit**. Result: **26 fail / 49 pass**, 11 controllers: operator/Helm (redis-operator, ps-operator, alloy, grafana) + privileged (home-assistant, immich, paperless-ngx) → exclude; own apps (claude-telegram, homehub, pricebuddy, stirling-pdf) → triage (add RoRFS + `/tmp` emptyDir, or exclude if writable root required).
- 🔧 **kustomization.yaml**: re-grouped into accurate Enforce (8) vs Audit (4) sections — prior comments were stale (Wave 1 had already promoted require-resource-limits/require-non-root/etc to Enforce).
- 📌 **Pre-push reviewer** (cavecrew-reviewer) ran on both commits. F-4: 0 bugs. F-5/F-6: 2 flagged "bugs" (apiCall background resolution, RoRFS pattern syntax) **disproven empirically** post-deploy — background apiCall works (40 pass), PSS mandatory pattern is canonical + admission-accepted.
- ⏭️ **Next**: re-scan ≥2026-05-25 19:30 → add operator/privileged excludes + own-app RoRFS triage → promote all three Audit → Enforce.

### 2026-05-24 (Wave 7 CI gates — yamllint + kubeconform + SOPS check + shellcheck + init-resources)
- ✅ **CI workflow added** (`.github/workflows/validate.yaml`, commits `d65ad41b` → `6fc3ebe3` → `db4bc940` → `cd2c973e`). Jobs (9 total, all green): `yamllint`, `shellcheck`, `sops-check`, `init-resources`, `kubeconform` × 5 (one per kustomize root), `homelab-analysis-drift` (warn-only). Runs on every PR + push to main.
- ✅ **Yamllint baseline cleanup** (commit `7fc45914`, 25 files / 76+ / 80-): EOL appended on 18 files (audiobookshelf/*, clusters/*, monitoring grafana-dashboards/*, multiple kustomization.yaml); trailing whitespace stripped on 5 files (cert-manager/release, traefik/release, vmrules, kps/release, loki-stack/release); `apps/base/authentik/blueprints/30-enforce.yaml` `!Find [...]` multi-line flow → single-line flow (semantics preserved). Final yamllint state: 0 errors, 62 warnings (all legitimate `line-length` on Grafana dashboard JSON / CSP middleware / VMRule PromQL).
- ✅ **`.yamllint.yaml`** — extends `default`; `line-length: max: 200, level: warning`; `indent-sequences: whatever` (K8s mixes 2-/4-space sequence indent legitimately); `truthy: allowed-values: [true, false]` (catches `on:`/`off:` accidents); ignore SOPS-managed files (`*-secret.yaml`, `*credentials*.yaml`, `*-db-user.yaml`, `*.sops.yaml`, etc.) + `clusters/staging/flux-system/gotk-components.yaml` (auto-generated by `flux install`) + `.playwright-mcp/` + `docs/superpowers/`.
- ✅ **`.pre-commit-config.yaml`** — local mirror of CI gates: yamllint, shellcheck-py, trailing-whitespace, end-of-file-fixer + local hooks for sops-check + init-resources. Kubeconform stays CI-only (too slow for pre-commit).
- ✅ **Shared scripts** (`scripts/ci/check-sops-encrypted.sh`, `scripts/ci/check-init-resources.sh`) — single source of truth for CI + pre-commit. `check-init-resources.sh` skips HelmRelease wrappers + operator CRs (Cluster/Pooler/VMAgent) per Wave 1 learnings — operator-managed pods excluded via Kyverno label-selector, not file-level.
- 📌 **Dropped after first run**: `flux build kustomization` job. Needs live cluster (queries server discovery for API versions, errors `dial tcp [::1]:8080: connect: connection refused` in CI). Offline `kustomize build --enable-helm` already runs as part of the kubeconform job — same render path, no cluster required.
- 📌 **Fix-forward chain after initial push**: (a) flux-build needs cluster → drop; (b) `install_kustomize.sh` upstream parses GitHub API in CWD, flaked on 1/5 matrix → pin `KUSTOMIZE_VERSION: v5.5.0` + direct tarball; (c) `sudo` was anti-pattern (`/usr/local/bin` is runner-writable on `ubuntu-latest`) → install tools into `$HOME/.local/bin` and export via `$GITHUB_PATH`. User caught the sudo on review.
- 🏷️ **Tag**: `pre-w7-2026-05-24` (annotated, signed). Wave 1 learning L12 codified — every multi-commit wave gets an annotated tag before the first commit.
- 📊 **CI footprint**: ~45s p95 per run, parallel matrix. Catches L1 (Audit→Enforce regressions via init-resources guard) + L4 (hidden init containers) + L5 (kubeconform == server-side admission for schema) + L8 (HOMELAB_ANALYSIS keyfact drift, warn-only).
- 📌 **Wave 8 next** (REVIEW.md): F-4 (`=()` → mandatory `deny`) + F-5 (require-NetworkPolicy) + F-6 (require-readOnlyRootFilesystem) — each Audit ≥24h → fix-forward → Enforce, per Wave 1 playbook codified in `/kyverno-policy-promotion` skill.

### 2026-05-23 (Kyverno Audit→Enforce promotion + init container debt closure)
- ✅ **F-2b complete**: `disallow-host-path`, `require-non-root`, `require-resource-limits` promoted Audit→Enforce (commits c13d0403, 8383ef35). All 10 Kyverno policies now Enforce.
- 🔍 **F-3 surfaced 5 latent init-container gaps** (Audit mode working as designed):
  - Repo-managed (fixed via F-41): authentik-worker `wait-for-server`, home-assistant `config-setup` + `hacs-install`, paperless-ngx `fix-permissions` — all received `resources: {requests, limits}` blocks sized to workload (busybox/curl init = 10m/16Mi → 50m/32Mi; alpine + wget HACS = 50m/64Mi → 500m/256Mi).
  - Operator-managed (fixed via F-42 exclude): CNPG `main-postgres-rw-pooler` (label `cnpg.io/podRole: pooler`), VMAgent (label `managed-by: vm-operator`).
- 🧪 **Validation chain**: pre-promotion `kubectl get policyreport -A` = 0 fails baseline → F-41 commit → Flux apply → re-scan = 0 fails → F-2b promotion commit → Flux apply → live `kubectl get cpol -o jsonpath` = all 3 Enforce → re-scan = 0 fails → 0 admission rejections → 0 pod restarts in 5min window post-Enforce → 0 VMAlerts firing.
- 📌 **F-2b unblocked by hotfix path**: rather than reverting F-3 (which surfaced the gaps), did "fix-forward" — added in-repo init resources (F-41), added operator-label excludes (F-42), then promoted. Audit mode confirmed safe before Enforce flip. Total elapsed: ~25min from "0 fails baseline" to "0 fails Enforce live."

### 2026-05-23 (Ultrareview — 4-agent consensus + Wave-1 implementation)
- ✅ **4-agent ultrareview** of main branch: arch (ecc:architect), k8s/Flux (k8s-devops-reviewer), security (ecc:security-reviewer), cruft (ecc:code-reviewer). Output: REVIEW.md (retired 2026-06-05, git history) — 1 P0, 11 P1, 17 P2, 9 P3 + 4 doc-drift + 4 CI gaps. Verdict: APPROVE with backlog. No operational blocker.
- ✅ **Pre-flight**: signed annotated git tag `pre-ultrareview-2026-05-23` for rollback. Live `kubectl get policyreport -A` scan → 0 FAIL/WARN/ERROR — Audit→Enforce promotion safe. 0 open PRs (no Renovate conflict).
- ✅ **Wave-1 implementation** (11 findings, 10 parallel cavecrew-builder agents + 1 cavecrew-reviewer):
  - **F-1 (P0)**: Cloudflare ACCOUNT_ID + TUNNEL_UUID moved from plaintext initContainer `command:` field to SOPS-encrypted Secret keys (`CF_ACCOUNT_ID`, `CF_TUNNEL_UUID` in `cloudflare-tunnel-mgmt-token`). Wired via env vars + `secretKeyRef`. `.sops.yaml` `encrypted_regex: ^(data|stringData)$` did not cover `command:`. No regen needed — account ID is non-secret, tunnel credentials JSON already SOPS-encrypted.
  - **F-2a**: `paperless-ngx` added to `require-non-root` exclude list (s6-overlay init requires /run owned by UID 1000 — prior incident commits ca3891c→7f12be2→8162673→d3b5036).
  - **F-3**: `require-resource-limits` Kyverno policy extended to cover `initContainers[*]` via `=()` optional pattern.
  - **F-7**: `monitoring-controllers` + `monitoring-configs` Flux Kustomizations gained `dependsOn` (chain: infrastructure-controllers → monitoring-controllers → monitoring-configs), `retryInterval: 2m`, `healthChecks` (kube-prometheus-stack-operator, **victoria-metrics-operator** [reviewer caught `vm-operator` rename], vmsingle), and SOPS `decryption` parity. Closes bootstrap race.
  - **F-8**: Dead `healthChecks` block removed from `apps.yaml` (was contradicting `wait: false`).
  - **F-9**: Immich allow-all 443 egress restricted with RFC1918 `except` block (cannot reach cluster-internal services).
  - **F-10**: uptime-kuma DB-port egress (3306/5432/6379/26379) scoped to `databases` namespace; non-DB ports remain cluster-wide for uptime monitoring.
  - **F-11/F-12**: n8n 443 egress → RFC1918 except; claude-telegram port 22 egress removed, port 80 → RFC1918 except.
  - **F-19**: `claude-telegram` ResourceQuota + LimitRange added (small-tier). Closes "100% namespace quota coverage" claim.
  - **F-27/F-28/F-29**: `setup-node.sh` → `set -euo pipefail` + grep guard; `analyze-update.sh:65` broken pipe/`||` precedence → if/elif/else; `claude-telegram-build.yml` force-tag dropped, added `git ls-remote` pre-existence guard.
- 🧪 **Validation**: `kustomize build` clean on all touched dirs; `flux build kustomization` clean for monitoring-controllers, monitoring-configs, apps; cloudflared rendered output verified env vars + SOPS-encrypted Secret keys present and hardcoded literals gone.
- 📋 **Decisions captured in REVIEW.md** (resolved this session): no multi-cluster `prod/` roadmap → F-13 collapse path justified; DB ownership → app-owned (blocky pattern); Cloudflare regen → NO (hygiene fix only); n8n egress → RFC1918 except (stock K3s flannel has no FQDN egress); CSP per-app needs → 3-tier strict/inline/permissive (paperless+blocky+claude-tg+obsidian strict, 8 inline, 4 permissive [home-assistant HACS new Function(), immich wasm, pricebuddy Livewire, uptime-kuma Vue runtime compiler]).
- 📌 **Wave-5 deferred** (after Flux reconcile + verification): F-2b Audit→Enforce promotion for `disallow-host-path`, `require-non-root`, `require-resource-limits`.
- 📌 **Backlog (next sprint)**: F-5/F-6 new Kyverno policies (require-networkpolicy, require-readonly-rootfs); F-15 DB user migration to app-owned (5 apps); F-16 driftDetection on 12 HelmReleases; F-17/F-18 timeout+rollback; F-22 CSP 3-tier rollout via existing csp-reporter Report-Only first; R7 CI gates (kubeconform, yamllint, SOPS-check, shellcheck); cruft sweep (.DS_Store, analyze-update/baselines/, POPEYE_CLUSTER_REPORT.txt, archive docs/superpowers/).

### 2026-05-22 (CODEMAPS refresh + HOMELAB_ANALYSIS drift fix)
- ✅ **6 codemap files refreshed to live cluster state** (commit `106107df` + follow-up): drift accumulated since 2026-05-08 (14 days). `README.md` 17→16 apps. `architecture.md` 28→27 ns, 55→53 SOPS secrets, "Traefik IngressRoute" → "Traefik Ingress (class=traefik)" (0 IngressRoute CRDs in use; all 16 ingresses are vanilla K8s `Ingress` resources). `apps.md` 10 image bumps: homepage v1.13.1, authentik 2026.5.0, blocky v0.30.0, stirling-pdf 2.11.0-fat, immich helm 0.12.0, home-assistant 2026.5.4, mealie v3.18.0, n8n 2.21.7, audiobookshelf 2.35.0, claude-telegram 1.22; added meilisearch v1.44.0 note for linkwarden. `databases.md` CNPG image 18.3→18.4, helm chart 0.28.x→0.28.2 (pinned exact), controller 1.29.0→1.29.1 (deploy `cnpg-operator-cloudnative-pg` in `databases` ns, NOT `cnpg-system`), `immich-backup` row added. `monitoring.md` kube-prometheus-stack 84.5.0→85.2.2, victoria-metrics-operator 0.62.1→0.63.1, vm-images v1.140.0→v1.143.0, vm-operator v0.69.0→v0.70.1, grafana 13.0.1→13.0.1-security-01, kube-state-metrics v2.18.0→v2.19.0, node-exporter v1.11.1→v1.11.1-distroless, added loki 3.6.7 + alloy v1.16.1 image lines; scrapes 26+2→37+4 (cluster grew); 12→13 scrape files. `networking.md` traefik chart 40.0.0→40.2.0 + image v3.7.1, blocky v0.29.0→v0.30.0, IngressRoute terminology corrected.
- ✅ **HOMELAB_ANALYSIS.md synced**: Key facts row 55→53 SOPS; APPS table 17→16 (Grafana row removed — already moved to monitoring infra in codemap on 2026-05-08, this finally aligns HA doc); Monthly Review Checklist "Last refresh: 2026-05-08" → 2026-05-22.
- 🔍 **Fact-check methodology**: single `ctx_batch_execute` pass pulled live state for all chart versions (`kubectl get hr -A`), image pins (`kubectl get deploy/sts -A -o json`), CRD counts (vmservicescrape 37, vmpodscrape 4, vmrule 2 / 26 groups, netpol 44, kpol 10, ingress 16, ingressroute 0), ns count 27 (excl flux-system), SOPS file count 53 (`find . -name '*.yaml' -exec grep -l 'sops:'`). Cloudflare Tunnel `cloudflared-config` decoded — 9 svcs in config.yaml match codemap (authentik, couchdb, audiobooks, linkwarden, stirling, mealie, paperless, immich, n8n). Token expiry 2026-12-31 verified against `docs/SECRETS_ROTATION.md`.
- 🧹 **Lint pass**: markdownlint not installed (npx offline disabled) — fell back to manual checks: per-file column count consistency (all tables uniform), trailing-whitespace scan (clean), backtick parity (all even = no broken code spans), heading hierarchy (no skipped levels). All pass.
- 📝 **Gap residual**: codemap monitoring.md "Notable groups" list incomplete vs live 26 groups (alertmanager-overrides, backup-alerts, couchdb-alerts, monitoring-health-alerts, rate-limiting-alerts, resource-exhaustion-alerts, service-alerts, storage-alerts not enumerated — "etc." used). Accepted as deliberate compression, not refreshed.

### 2026-05-22 (Backup overhaul — coverage + retention + immich weekly)
- ⚠️ **Coverage audit**: 5 PVCs missing from daily backup whitelist (mealie, n8n, audiobookshelf-config + -metadata, claude-telegram). Plus stale `uptime-kuma/uptime-kuma-data-pvc` (UK switched to emptyDir).
- ✅ **PVC whitelist updated** (commit `49d6afb2`): added mealie/mealie-data-pvc, n8n/n8n-data-pvc, audiobookshelf/audiobookshelf-config + -metadata. Removed stale uptime-kuma. `claude-telegram/claude-telegram-home-pvc` documented as expendable (session-only state, bot rebuilds on restart). immich/immich-machine-learning, loki, vmsingle, stirling-pipeline/tessdata documented as expendable (regenerable runtime).
- ✅ **immich weekly CronJob**: 63G photo PVC was excluded from daily. Now `immich-backup` CronJob Sunday 03:00 UTC, uncompressed tar (JPEG already compressed), 2-pass tar + sha256, keep-2 retention. Live test: tar 187s (~340 MB/s disk-bound), sha256 914s (~75 MB/s single-thread Celeron N5095), total 18m21s. Fits 30min window before 03:30 replication.
- ✅ **Retention policy** (commits `49d6afb2`, `73f7a611`): W1 source 7d → 30d (`find -mtime +30 -delete`). NAS gets prune step (Step 5b in `backup-replication`): 30d for postgres/mysql/couchdb files (`prune_nas_file` via rsync filter rules `--include=<file> --exclude='*'` against empty source) + 30d for pvc dirs + keep-2 for immich (`prune_nas_dir` via empty-source rsync). Soft-fail (`|| true`) if daemon refuses delete → manual NAS UI fallback. Initial run pruned 162+ files per DB category + 70+ pvc dirs back to 30d window; immich kept latest.
- 🐛 **Bug found + fixed mid-test**: first prune iteration only matched DIRS (regex `^d`). DB backups are top-level FILES — got skipped entirely. Added `prune_nas_file()` helper + separate awk pass for `(postgres|mysql|couchdb)/[a-z]+_[0-9]{8}_[0-9]+\.tar\.gz` pattern. Immich safety verified: file-prune regex requires single `/` + DB-category allow-list — immich's `immich/<TS>/immich-library.tar` (two `/`s, not in allow-list) cannot match.
- 📊 **Redis backup decision**: audit confirmed Redis = cache + queue/broker (DB0 = BullMQ/Celery/Django sessions; DB1 = pure TTL'd cache). No durable user data. Redis HA (2 replicas + 3 sentinels + RDB+AOF) handles single-pod loss. **No backup needed** — documented in BACKUP_STRATEGY.md.
- 📈 **NAS state** post-cleanup: 14.03 GiB → 72 GiB peak during test (incl. 62.5G immich) → trimmed back to natural-only after test artifact removal. 30d window enforced: postgres/mysql/couchdb=60 files each, pvc=636 files / 270 dirs, immich=0 (next Sunday).
- 📚 **Docs**: BACKUP_STRATEGY.md updated with new PVC list, retention policy, immich weekly section, "What's NOT backed up by design" table.

### 2026-05-29 (R5 — shared DNS-egress NetworkPolicy component)
- ✅ **R5 closed** (`6229d4ed` P1 + `611b6320` P2). Repo's **first Kustomize Component**: `apps/base/components/allow-dns-egress/` — an egress-only NP allowing UDP 53 → `kube-system`, wired into 14 app bases via `components:`. Phase 2 then removed the duplicated per-app DNS egress block from those 14 NPs (−122 LOC). NetworkPolicy resources 46 → 60.
- 🔬 **Only DNS was shareable.** Live read of all 16 per-app NPs: only the `kube-system` UDP-53 rule is byte-identical + parameter-free. Postgres/Redis/HTTPS egress + all ingress vary by port/DB-engine → a parameter-less component can't cover them without a named-port refactor of every Deployment (rejected, too broad). The F-9/F-10/F-11/F-12 "3-component" brief (netpol-dns/postgres/redis) was thus reduced to 1.
- 🐛 **Job-isolation footgun avoided.** A naive `podSelector: {}` egress baseline is NOT additive — any egress NP selecting a pod flips it to deny-except-listed. 6 egress-naked provisioning Jobs (audiobookshelf-init, immich-admin-setup, mealie/n8n-user-provision, home-assistant-admin-setup, uptime-kuma-setup) would have been clamped DNS-only → break on helm-hook re-run. Baseline excludes them via `matchExpressions: [{key: batch.kubernetes.io/job-name, operator: DoesNotExist}]` (canonical label on K3s 1.35).
- ⚖️ **blocky + obsidian excluded.** blocky = specialized DNS (kube-dns podSelector, DoT 853, public resolvers). obsidian = ns-wide `podSelector: {}` NP covering its `couchdb-init` Job's DNS — deduping would strip the Job's DNS (baseline excludes Jobs).
- 🔵 **Namespace fix was 2 overlays, not 5.** The nsless component NP needs *some* `namespace:` transformer. home-assistant/n8n/pricebuddy already set it in their **bases**; only authentik + uptime-kuma had none → added overlay `namespace:` to just those 2 (adding to the other 3 = double-declare = build break).
- ✅ **Verified live**: 14 `allow-dns-egress` NPs across correct namespaces, Job-exclusion selector active; DNS (`getent hosts kubernetes.default`) resolves in pods across every shape — incl. homehub + meilisearch whose egress is now `[]` (served solely by the baseline).
- 🔮 **Surfaced R5-followup** (backlog): the 6 naked provisioning Jobs have no egress NP = lateral-movement gap. Per-app egress NP per Job (app port + DB, not shareable). Deliberately out of R5 scope.

### 2026-05-29 (F-13 + F-14 + R6 — collapse base/overlay split, single-env) ✅
- ✅ **F-13 apps flattened** (`b818b17d`+`9179c956`+`181711ec`). `apps/base/<app>/*` + `apps/staging/<app>/*` → `apps/<app>/*` (16 apps, 196 git renames); `apps/base/components` → `apps/components`; per-app kustomizations merged (base resources + staging secrets/certs/jobs, `namespace:` once, `components:`/`configMapGenerator` preserved); new top `apps/kustomization.yaml`; Flux `apps` path `./apps/staging`→`./apps`; CI kubeconform matrix repointed. The base/overlay split was ceremony — single env, no prod roadmap.
- 🔬 **Safety = byte-identical render.** `diff <(kustomize build apps/staging @HEAD) <(kustomize build apps)` EMPTY → Flux adopts every object by unchanged name/ns/GVK → zero churn. Verified live: 16 apps Running, no prune/delete events. All 8 apps that gained a top-level `namespace:` had extras already hardcoding the right ns (transformer = no-op).
- ⚖️ **2-phase prune.** P1 ran `prune:false` during the path repoint (orphan-safe even if render had drifted); P2 (`181711ec`) flipped `prune:true` + renamed 2 misnamed SOPS Secrets (`blocky/configmap.yaml`→`config-secret.yaml`, `stirling-pdf/custom-settings-configmap.yaml`→`custom-settings-secret.yaml`) so the `**/*-secret.yaml` yamllint-ignore glob catches them — the hardcoded `apps/base/...` ignore paths had re-broken CI the instant the files moved (durability fix: glob > path-pin).
- ✅ **F-14 + R6 infra-controllers flattened** (`95b87e53`+`367fc91d`; monitoring subset was `b442c098`). `infrastructure/controllers/staging`(`[../base]` passthrough) → hoisted `base/*` to `infrastructure/controllers/`; path repointed; render byte-identical; backbone unaffected (cert-manager-webhook/kyverno-admission/traefik 2/2).
- 🔍 **couchdb wiring traced (the deferred blocker).** `controllers/staging/couchdb/secret.yaml` (Secret `couchdb-couchdb`) was a **dead duplicate** — referenced by nothing, 0 in the controllers build. The LIVE secret is owned by `infrastructure-configs` from `configs/staging/databases/couchdb/admin-secret.yaml` (chart `createAdminSecret: false`). Deleting the dead dir = zero cluster effect.
- 🐛 **Transient alert (benign).** Deleting the old `staging/` dir in the same commit that repoints `spec.path` → a brief `path not found: .../controllers/staging` Telegram alert: the controller's 1-min ticker fired against the deleted path before flux-system patched the path field. Self-heals on next reconcile (`ReconciliationSucceeded`). Avoid next time with 2 commits (repoint path → delete old dir).
- 🔧 **Tooling**: `~/.claude/hooks/cavecrew-mark.sh` wrapper (sets the pre-push marker without the `$()` that forces a Bash-permission prompt; allowlisted static invocation). dotfiles `b394161`.
- ⚙️ **CI was billing-blocked** (out of Actions minutes) for F-13-P2 + F-14 → local validate ladder (render-diff + yamllint + kubeconform) + cavecrew-reviewer used as gate, `fr` bypass user-authorized.

### 2026-05-29 (R5-followup — per-Job egress NPs, 4/6) ✅
- ✅ **4/6 hardened** (`68dddceb`). One tight egress NP per Job: DNS (UDP 53→`kube-system`) + the single app container-port, selecting the Job pod by canonical `batch.kubernetes.io/job-name` (the R5 baseline excludes Jobs, so each NP carries its own DNS). audiobookshelf-init→app:3005, home-assistant-admin-setup→:8123, immich-admin-setup→immich-server:2283, n8n-user-provision→n8n:5678. NP resources 60 → 64.
- 🔬 **Egress-only + symmetric.** App **ingress** already admitted these Jobs — same-ns `podSelector:{}` (audiobookshelf/mealie/n8n/uptime-kuma), immich's explicit `app: immich-admin-setup` rule, HA's all-ns rule — so no ingress edit needed. Egress target read from each Job's curl/psql command; port = target **container** port (post-DNAT, per kube-router).
- ✅ **Live-proved enforcement.** Deleted+recreated `audiobookshelf-init` via Flux (force:enabled) → ran under its new NP → Complete 1/1 in 21s; logs show DNS resolved + reached app:3005 (HTTP 500 "already initialized", expected idempotent path). Confirms the tight egress doesn't regress the Job.
- ⚖️ **mealie + uptime-kuma deferred (accepted residual).** `mealie-user-provision` (`apt-get install` curl/postgresql-client) + `uptime-kuma-setup` (`pip install uptime-kuma-api`) bootstrap tooling from the **internet at runtime** → any NP must open 443/80→0.0.0.0/0 = theater. Proper fix = bake deps into a pinned custom image; user declined custom images, so these 2 stay naked by decision.

### 2026-05-22 (Drift-heal mid-flight ansible-core upgrade race)
- ⚠️ **Incident**: drift-heal failed on all 3 nodes with `ConfigManager.get_config_value() got an unexpected keyword argument 'templar'` on `base_config : Deploy /etc/logrotate.d/pacman` (copy task). Secondary warning: `cannot import name 'VaultDecryptionContext' from 'ansible._internal._yaml._dumper'` killed `ansible.builtin.core` filter plugin.
- 🔍 **Root cause**: manual `pacman -Syu` at 13:24:02 BST (upgrading ansible-core 2.20.5 → 2.21.0) raced the 10-min drift-heal timer fired at 13:24:16. ansible-playbook imported ConfigManager from 2.20.5 in memory; mid-run the on-disk core flipped to 2.21.0. Next action plugin reload picked up new `copy.py` (passes `templar=` kwarg) while ConfigManager singleton stayed on old import → TypeError. NOT a version bug — `get_config_value()` in on-disk 2.21.0 *does* accept `templar` (verified via `inspect.signature`). Pure timing race.
- ✅ **Fix** (commit `3b5696d7`): two systemd guards prevent recurrence:
  - `node-maintenance-config.service` gets second `ExecCondition=/bin/sh -c '[ ! -e /var/lib/pacman/db.lck ]'` — drift-heal skips its 10-min cycle when pacman holds the DB lock. Skip is safe; next timer cycle catches up.
  - `node-maintenance-phase1.service` gets `ExecStartPre=/usr/bin/pacman -Sy --noconfirm --needed ansible ansible-core` — pre-upgrades ansible runtime BEFORE ansible-playbook starts. Subsequent `yay -Syu` inside phase1 then finds ansible-core current → no mid-play bump.
- 📝 **Verification**: post-deploy drift-heal cycles green on all 3 nodes (CP `ok=100`, W1+W2 `ok=121` each, `changed=0 failed=0 unreachable=0`). systemd status confirms new ExecCondition fires + passes.
- 📚 **Gotcha logged**: memory `gotchas.md` — "Ansible mid-play runtime upgrade race". Don't pin/downgrade — Arch rolling; fix timing instead. Pattern applies to any long-running ansible-playbook that triggers `pacman -Syu` against its own runtime.

### 2026-05-22 (Rebuilderd W2 memory limit reduction)
- ⚠️ **Incident**: cosmic-launcher rebuilderd build on worker-node-2 peaked at 7.4G RAM, combined with concurrent ansible node-maintenance + kernel builds caused node memory pressure. 6 pods CrashLooped across both workers (cert-manager-cainjector ×2, kyverno-cleanup-controller, main-mysql-haproxy, ps-operator, +1). Control plane showed API proxy broken pipes. All self-resolved in ~10min.
- ✅ **Fix**: Reduced rebuilderd systemd cgroup limits on worker-node-2: MemoryMax 12G→8G, MemoryHigh 11G→6G, MAX_MEMORY env 12G→8G. Swap unchanged at 16G (big builds spill to swap instead of pressuring K8s). Commit `f1efef99`. Applies at next drift-heal (03:00 UTC) or manual trigger.
- 📝 **History**: W2 limits trajectory: 18G (initial) → 14G (2026-02-21 DPDK OOM) → 12G (2026-04-26 host OOM) → 8G (2026-05-22 cosmic build pressure).

### 2026-05-14 to 2026-05-15 (Ansible packages parity + mirror-staleness fix)
- ✅ **12 Mac-parity CLI tools added to `pacman_packages_base`** (commit `dac395a5`, 2026-05-14): bat, eza, git-delta, gron, jc, kubectx, kubeconform, shellcheck, shfmt, sops, stern, yamllint. Pkg count 30 → 41. Installed on all 3 nodes via daily drift-heal (`node-config.yml`). taplo intentionally NOT added — not in extra or AUR (Mac-only via Homebrew).
- ✅ **Pacman mirror-staleness self-heal** (commit `811b67e9`, 2026-05-15): packages role gets pre-task `community.general.pacman: update_cache=true force=true` (=`pacman -Syy`) before all install tasks. First run of the 12-pkg addition hit `error: failed retrieving file 'haskell-prettyprinter-*.pkg.tar.zst' : 404` (shellcheck's transitive haskell deps had rotated on london.mirror.pkgbuild.com; local DB stale). Fix re-runs DB refresh under retries=3/delay=30. Daily 03:00/15:00 UTC config now self-heals mirror drift.
- ✅ **Weekly `yay_cmd` bumped `-Syu` → `-Syyu`** (same commit): forces re-download of mirror DB even if cache appears fresh. Saturday 04:30 UTC phase1 + post-reboot phase2 weekly upgrades pick up next run. Covers both pacman + AUR (CP has 8 AUR pkgs: yay, viddy, zsh-you-should-use, 5 firmware blobs). Documented gotcha in memory `gotchas.md`.

### 2026-04 / 2026-05 (Detailed Changelog — archived from HOMELAB_ANALYSIS.md 2026-05-15)
Verbatim chronological entries (2026-04-02 → 2026-05-08) moved here to keep ANALYSIS lean.
- 2026-05-08: **CODEMAPS refresh + monthly cadence + pending sweep** (commit `aa941721`). All 6 `docs/CODEMAPS/*.md` snapshots actualised against live cluster via 6 parallel agents (one per file) briefed with pre-gathered live-state (kubectl + helm + images + cronjobs). Major drift fixes: `databases.md` PXC→Percona Server for MySQL (`ps-operator` 1.1.x), 3 mysql nodes→2+haproxy 2+orc 3 with image pins; `monitoring.md` retention 30d→90d (vmsingle 50Gi PVC), Loki+Alloy moved to own `loki` ns, VMServiceScrape 37→26+2 VMPodScrape, helm + image pins (kps 84.5.0, vm-op 0.62.1, vm v1.140.0); `apps.md` 17→16 apps (Grafana → infra section), all live image tags refreshed, Immich noted as Helm chart, middleware chain expanded; `architecture.md` Traefik ns kube-system→traefik, Kyverno 10 split 7 Enforce + 3 Audit; `networking.md` Traefik chart 40.0.0, NP per-ns counts; `backup-restore.md` CRITICAL_PVCS list verified vs YAML (10/8 apps), W2 chain noted pending. Added monthly cadence: `CODEMAPS/README.md` "When to update" lists Monthly review; `HOMELAB_ANALYSIS.md` Monthly Review Checklist new item #3 CODEMAPS refresh with kubectl snapshot commands + agent dispatch pattern, "Last refresh: 2026-05-08". Pending sweep: nothing strictly overdue (today 2026-05-08; next event = W2 replication drop 2026-05-20). Authentik 2026.5 row retargeted to "Backlog (watch releases)" — upstream still on 2026.2.x (latest 2026.2.3-rc1). UFW heal umbrella row updated to reference both layers: layer 1 prevention `kernel-modules-hook` (commit `6e01c7d0`) + layer 2 recovery heal v4 (commit `476ec535`). 2026-05-02 incident sub-items (P1 ufw line-2, P2 heal v3 ufw-disabled probe, P3 nic_tuning enp3s0→enp4s0) verified covered: P1+P2 in 476ec535 + heal v4, P3 already correct in `host_vars/worker-node.yml` (`nic_tuning_iface: enp4s0`); CP host_vars correctly retains `enp3s0` (no rename on CP).
- 2026-05-07: **Blocky soak observation closed (4d late vs 2026-05-03)**. Window 2026-04-30→2026-05-07: peak RSS 307Mi/283Mi (60% headroom on 512Mi), avg 140-156Mi, p95 latency 4.96 ms / p50 2.61 ms, log_entries 797k rows / 238 MB / ~110k/day stable, CPU throttle ≤0.24%, 0 active alerts. Restarts (4 rqbjj / 1 wwzgn) all on Sat 2026-05-04 maintenance window — Redis transient-unavail at boot (`dial 10.43.191.88:6379 connect: connection refused`), expected; pods stable 3d+ since. **Memory-limit review** (2026-05-26 row): peak 307Mi blocks 256Mi target; 384Mi acceptable (~25% headroom).
- 2026-05-04: **RebuilderdHighFailureRate flap fix**. Alert flapped firing/resolved every ~40min. Source = 2h-window gauge (`rebuilderd-metrics.sh`), denominator straddles old `total >= 20` floor on W1 (~8-25 builds/2h). Reworked: `avg_over_time((bad/clamp_min(total,1))[1h:5m]) > 0.8 and avg_over_time(total[1h:5m]) >= 50`, `for: 30m → 1h`, added `keep_firing_for: 1h` for hysteresis. Description updated to reflect 1h-smoothed ratio.
- 2026-05-03: **Drift-heal firewall race fix — Tier A + lease bump**. Root cause for 2026-05-02 W2 NotReady mid-drift-heal at 23:42:05 UTC: `firewall` role ran against `hosts: all` in **parallel** — all 3 nodes reloaded UFW simultaneously. Each `community.general.ufw` policy task triggers `ufw reload` → `iptables-restore` rebuilds all UFW chains. During rebuild window, INPUT chain transiently lacks K3s/flannel jump rules → kubelet→API HTTP/2 watch streams RST. Five sequential default-policy + rules tasks compounded the disruption beyond kubelet lease grace (40s default). Ships: (1) **`node-config.yml` 3-play split**: non-disruptive roles parallel, **firewall serial:1**, post-firewall parallel — quorum (2/3) always preserved during drift-heal. (2) **Drift fingerprint gate** in `firewall/tasks/main.yml`: pre-task hashes (`/etc/default/ufw` + `ufw status verbose` + sha256 of all ufw_rules_* vars), compares to cache at `/var/lib/ufw-state/ufw-fingerprint`. UFW rules block gated `when: ufw_drift_detected`. Cache updated post-block only when no rescue ran (clean state). Daily drift-heal on healthy node = pure no-op, zero reload. To force re-run after manual edit: `rm /var/lib/ufw-state/ufw-fingerprint`. (3) **Kubelet lease bump 40s→60s** in `roles/hardening/files/k3s-kubelet.yaml` (`nodeLeaseDurationSeconds: 60`, bare int, NOT duration string — common footgun) + `nodeStatusReportFrequency: 1m` (force status post 5m→1m for faster silent-hang detection). (4) **Lockstep CM grace 50s→75s** in `k3s_config/templates/config.yaml.j2` via `kube-controller-manager-arg: node-monitor-grace-period=75s` + `node-monitor-period=5s` — required because kubelet lease bump is no-op without CM grace bump (CM uses default 50s threshold otherwise). Vars in `group_vars/control_plane.yml`. Rule: grace ≥ lease + 1 renewal (60 + 15 = 75). (5) **`rolling-restart-k3s.yml`** new top-level playbook with `serial:1` to restart k3s/k3s-agent CP-first then workers, waits Ready per node, verifies `nodeLeaseDurationSeconds=60` + `nodeStatusReportFrequency=1m0s` via `/api/v1/nodes/<n>/proxy/configz` (defends against historical k3s field-stripping bugs #7578/#8266). Net effect: 99% of drift-heals = zero UFW reload (pure gate skip). Rare drift detected = serial:1 + full L0-L5 safety. Real-failure detection NotReady delayed ~25s (50s→75s).
- 2026-05-02: **Cardinality trim + UK rework + W1 incident**. (1) **Cardinality**: VMAgent `inlineUrlRelabelConfig` added to drop `flag` (1892, VM CLI flag introspection), `config_parameter` (801, VM env vars), `kube_pod_tolerations` (1081), `etcd_bookmark_counts` (364), 6 noisy histogram `_bucket` metrics (apiserver_watch_list/kyverno x2/controller_runtime/workqueue x2/rest_client/vm_promscrape — ~22k series), low-value cAdvisor (`container_memory_(mapped_file|max_usage_bytes|swap|total_inactive_file_bytes)|container_(sockets|threads)|container_spec_cpu_(period|shares)|container_cpu_(system|user)_seconds_total` — ~7k), and loop-device filesystem metrics. Estimated -33-35k series (204k→~170k, 17%). VMSingle 537Mi → unchanged short-term, will trim with retention roll. Verified live: `rate(flag[1m])` empty, `count(flag)` aging out. (2) **Uptime Kuma**: replaced stale standalone Redis monitor with `Redis HA Master` + `Redis HA Sentinel` TCP probes + `Blocky DNS W1` (192.168.1.129) + `Blocky DNS W2` (192.168.1.126) DNS-via-resolver probes. Originally tried via uptime-kuma-api in setup-job — flaky across lib versions and pre-existing data was in MySQL not SQLite, so reverted to admin-only setup-job and added monitors directly via MySQL INSERT. NetworkPolicy: extended `192.168.1.0/24` ipBlock egress to allow TCP+UDP 53 for Blocky DNS LB probes. Pinned UK Deployment + setup-job to control-plane (`nodeSelector: node-role.kubernetes.io/control-plane=true` + matching toleration) so worker-node probes always traverse external network — fixes "monitor blind to its own node failure" (UK was on W1 during incident, W1 SSH/kubelet probes stayed 100%/99.86% green via pod-local loopback while host INPUT was DROPing external L3). PVC dropped (`/app/data` → emptyDir; real state in MySQL). Helm releases audit closed (12 active, kube-prometheus-stack already trimmed). Skill stocktake quick (11 changed): chezmoi-sync L59, monitoring-check VMAlert jq + port-forward + baselines, networkpolicy-helper VMAgent wording — fixed + pushed. Security scan rollup all 3 nodes: 0 rootkits, hardening 77/78/77, baseline drift absorbed via `rkhunter --propupd`. (3) **W1 incident** (~22:48 UTC): post `yay -Syyu` weekly maintenance, kernel pkg upgraded 6.18.26-1-lts → -2-lts, pacman post-install removed `/lib/modules/6.18.26-1-lts` while kernel still running → modprobe couldn't find ip6table_filter → ufw runtime `ip6tables` error → ufw silently disabled → host INPUT chain DROP'd 8260 packets → W1 NotReady (~25 min). UFW heal v3 ran post-reboot and probe-set UNHEALTHY (`missing ufw6-logging-deny ufw6-user-input`); after manual `ufw enable`, `disable;enable` cycle hit `iptables-restore line 2 failed: No chain/target/match by that name`. Recovered via reboot + emergency `iptables -P ACCEPT && iptables -F INPUT` while UFW debug deferred. Pods rescheduled to W1 cleanly post-recovery. NIC udev-renamed `enp3s0` → `enp4s0` on -2-lts boot — ansible `nic_tuning` role now references stale name. **Issues tracked above** (resolution verified 2026-05-08): P1 ufw line-2 failure ✅ FIXED via heal v4 commit `476ec535` (flush-all + force-enable bypasses iptables-restore line 2 error); P2 heal v3 needs ufw-disabled state probe ✅ FIXED via `phase_ufw_state_recover` in firewall-preflight (same commit `476ec535`); P3 nic_tuning interface-name ✅ NOT-DRIFT — `host_vars/worker-node.yml` already had `nic_tuning_iface: enp4s0`, CP `host_vars/gmk-k3s-control-plane.yml` correctly retains `enp3s0` (no rename on CP). Re-test pending = umbrella row "Validate UFW silent-disable auto-heal" tracking. Layer 1 prevention added via `kernel-modules-hook` commit `6e01c7d0` (prevents `/lib/modules/<running-kernel>` wipe). Next Review bumped 2026-05-04 → 2026-06-04. Quarterly automation audit still 2026-07-04.

- 2026-05-02: **Monthly review + audit (early, vs scheduled 2026-05-04)**. Security scan rollup all 3 nodes: 0 rootkits, hardening 77/78/77, baseline drift (egrep/fgrep/ldd→scripts, telnet, W2 hostname) absorbed by `rkhunter --propupd`. April logs 0-byte (ansible deploy initialised them empty 2026-04-18); May = first real scan, June = first real diff baseline. Skill stocktake quick (11 changed since 2026-04-29 caveman compress): 8 Keep, 3 Improve fixed inline — chezmoi-sync L59 Templates gotcha clarified, monitoring-check VMAlert jq path unified to `.data.alerts[]?` + port-forward pattern (direct exec hits Connection refused) + baselines refreshed (VMSingle 537Mi / series 204k, up from 113k @ 2026-04 — flag cardinality growth), networkpolicy-helper L104 "scraped by Prometheus"→"scraped by VMAgent". Zombie helm release audit closed: 12 releases all active, kube-prometheus-stack confirmed trimmed (`prometheus.enabled=false`; operator + grafana + AM + KSM + node-exporter retained — operator manages AM STS); 5 empty kube-prometheus-stack CRDs + 13 empty VM-operator CRDs bundled with chart, risky-to-remove for marginal benefit, no actionable cleanup. Next Review bumped 2026-05-04 → 2026-06-04. Quarterly automation audit still 2026-07-04.
- 2026-04-28: **Ansible review + NOW + 1-2 day + Later + power-down prevention** (10 commits, full session). Final landed list: #1 authorized_keys, #2 /etc/hosts, #3 timesyncd assert+metric, #5 SSH host fingerprint baseline, #6 admin sudoers, #7 K3s tls-san, #11 fail2ban jail.local (systemd backend), #14 phase2 pod-GC ns filter, #15 rebuilderd cleanup template DRY, swap config 3-host, kernel cmdline audit, K3s secrets-encrypt runtime verify, nic_tuning generalized to all 3 nodes (CP igc + W1 igc + W2 r8169 EEE-off), PCIe runtime PM udev rule (SATA + NVMe + Ethernet classes). Dropped after research: #4 pacman_config (reflector owns), #8 K3s data-dir perms (subdir 0755 design), #9 resolved DNS (Blocky chain works), #10 K3s server flags (config.yaml drift-alert covers), #12 sysctl handler (correct semantics), #13 packages retry (works), #16 idempotency CI (deferred), #17 meta deps (cost > benefit), #18 CNI fingerprint (K3s-runtime), #19 ansible-vault (already SOPS), #20 logrotate.conf (per-app sufficient), zram (unused), MTU (correct), /etc/rancher/k3s backup (K3s handles). 4 gotchas saved to memory. Full audit + plan (`docs/scripts/node-maintenance/ANSIBLE_REVIEW_PLAN.md`, 20 confirmed gaps triaged). Verified baseline: drift-alerting wired (`node-config-notify.sh` Telegram on `failed>0` OR `changed>0`), sudoers visudo-validated, journald caps configured, firewall+preflight split intentional. **NOW bucket shipped** (commits `0cd01203` → `820d1c2b` → `04ec29be`): (1) #1 `authorized_keys` template — `base_config` slurps CP pubkey via `delegate_to+run_once`, deploys to workers exclusive 0600. (2) #3 timesyncd assert + textfile metric (`node_time_sync_synchronized`, `_active`, `_drift_seconds`, 60s) — verified live, all 3 nodes synced. (3) #7 K3s `tls-san` block in template, var in `group_vars/control_plane.yml` — drift-alert auto-fires. (4) #8 data-dir perms audit DROPPED — K3s sets `<data-dir>` + all top-level subdirs to 0755 by design (containerd traversal); secrets live in individual mode-0600 files inside. (5) #14 phase2 Failed-pod GC scoped to `phase2_pod_gc_namespaces` (system+infra only, user-app ns skipped). 2 gotchas saved: `when:` on `run_once+delegate_to` skip-trap, K3s subdir 0755 false-positive. **1-2 day bucket shipped (commit `739a578b`)**: #2 `/etc/hosts` blockinfile (with CP `node_ip` override since `ansible_connection: local` makes `ansible_host=127.0.0.1`), #5 SSH host key fingerprint baseline + drift alert, #15 rebuilderd cleanup template (single `cleanup-stale-repro.sh.j2`, deletes per-host duplicates). **Dropped on review**: #9 resolved upstream pinning (would bypass Blocky — verified DHCP already pushes Blocky to nodes), #12 sysctl `changed_when:false` on handler is correct, #17 role meta deps add cost without protection. Later: pacman_config/admin-sudo/fail2ban/idempotency-CI. Never: logrotate.conf system-wide, K3s cert SAN auto-renewal, firewall+preflight consolidation.
- 2026-04-28: **UFW heal v3 — readiness barrier + preflight role + module + ufw-chains-only settle**. Sequel to 2026-04-26 v2: W2 hit `ufw status verbose: ERROR: problem running ip6tables` again at drift-heal 17:54 BST despite v2's modules-load.d entry (`ip6_tables`/`ip6table_filter`/`iptable_filter` were loaded). Root cause: missing nat/mangle/raw table modules — ufw's `iptables-restore` on `before6.rules` references `*mangle`/`*nat` tables; auto-load fails under K3s/fail2ban iptables lock contention. Shipped: (1) **modules-load.d expanded** to 10 modules (added `ip6table_nat`/`ip6table_mangle`/`ip6table_raw` + v4 nat/mangle/raw + `nf_conntrack`); firewall role modprobe loop matched. (2) **`k3s-wait-ready.service`** new oneshot barrier (After=k3s/k3s-agent, RemainAfterExit=yes, 200s budget) that polls API healthz (CP) + critical pods Ready (kube-router/coredns CP-only) + ufw-chain hash stability, touches `/run/k3s-ready` sentinel. `ufw-heal-post-k3s.service` now `After=k3s-wait-ready.service Wants=k3s-wait-ready.service ConditionPathExists=/run/k3s-ready`. Replaces naive `After=k3s.service` (started ≠ ready). (3) **`firewall_preflight` role** — new role inserted before `firewall` in node-config.yml all-hosts play AND before rebuilderd in workers play. Runs `firewall-preflight.sh`: settle wait + modprobe expanded modules + per-chain repair. Defends any role transitively invoking `community.general.ufw`. (4) **Phase A v2 in `ufw-heal-post-k3s.sh`** — replaced old `nft monitor 0-events` gate with `ufw_chains_hash` (sha256 of `:ufw-`/`-A ufw-` lines from iptables-save) stability across 3× 5s windows, max 90s. Workers always churn kube-* chains so full-ruleset hash never converged on first test (W2 reboot 18:41-18:45) — ufw-only hash bounded drift. Same hash fn shared with k3s-wait-ready + firewall-preflight. (5) **fail2ban detected** as deployed-but-unmanaged-by-ansible (active on W2, pacman 1.1.0-8). Race source documented; no role added yet. (6) **Lint cleanup**: pre-existing `risky-shell-pipe` in firewall pre-heal block (added `set -o pipefail`), `name[casing]` in nic_tuning handler, `yaml[commas]` alignment in group_vars/all.yml all fixed — repo passes `production` profile clean. **W2 reboot test 18:41 BST**: all 10 modules loaded post-boot, `/run/k3s-ready` touched at 181s (settle timed out via fallback), heal exit 0 with "ufw active — heal OK" (probe-set healthy, reload attempt 1/3 succeeded), no UfwDisabled/UfwChainsUnhealthy alerts. Refinement: ufw-chains-only hash deployed via second commit. CP + W1 inherit on next drift-heal cycle (15:00 UTC).
- 2026-04-26: **UFW heal v2 + drift-heal cadence 1x→2x/day**. W2 hit `ufw status verbose: ERROR: problem running ip6tables` 30+h after boot — boot-time `ufw-heal-post-k3s.service` doesn't catch runtime drift. Root cause re-audited: real CNI is K3s default flannel + kube-proxy (NOT kube-router as old comments claimed); heal Phase A's `KUBE-ROUTER-INPUT` quiescence probe always timed out. Plus `ip6_tables` kernel module had unloaded mid-runtime. Shipped: (1) heal script v2 — `nft monitor` event-based quiescence (max 60s, 5s windows), phase reorder A→C→B→E→D→F (per-chain `iptables -N` BEFORE `ufw reload`); (2) `/etc/modules-load.d/ufw-iptables.conf` (`ip6_tables`/`ip6table_filter`/`iptable_filter`) + `ufw.service.d/modules.conf` (`After=systemd-modules-load.service`); (3) ansible firewall pre-heal task reordered repair-first; (4) `node-maintenance-config.timer` 1x→2x/day (03:00 + 15:00 UTC, drift window ≤12h). Hourly probe-then-heal pattern researched + rejected (`-w` no-op on iptables-nft, double-heal risk, pacman/rebuilderd lock contention). W2 canary applied 20:27 UTC, `ufw_chains_healthy=1`. Roll W1 + CP next 03:00 UTC drift-heal.
- 2026-04-26: **W2 rebuilderd memory cap 14G→12G**. Reduced `MemoryMax 14G→12G` / `MemoryHigh 13G→11G` / `MAX_MEMORY=12G` to leave more headroom for K8s pods on W2. Updated via ansible (`roles/rebuilderd/files/resources-worker-node-2.conf` + `host_vars/worker-node-2.yml`), drift-applied via `node-maintenance-config.service`, verified live (`MemoryMax=12G`). Also added `docs/scripts/ansible-apply.sh` helper (sync + drift-heal + per-host rebuilderd verify) deployed to CP `~/ansible-apply.sh`.
- 2026-04-26: **W1 rebuilderd memory cap 32G→18G**. Host-level OOM on W1 — rebuilderd cgroup pressure spilled past `MemoryMax=32G`/`MemoryHigh=31G` and triggered host OOM-kills on K8s pods. Reduced to `MemoryMax=18G`/`MemoryHigh=17G` (+`MAX_MEMORY=18G` env for nspawn). Trade-off accepted: heavy LTO builds (python-triton ~40GB, openvdb ~34GB) will OOM inside rebuilderd cgroup again — same failures as pre-2026-02-21 — but K8s stability preserved. Updated via ansible (`roles/rebuilderd/files/resources-worker-node.conf` + `host_vars/worker-node.yml`), drift-applied to W1 live, verified `MemoryMax=19327352832` (=18*1024^3).
- 2026-04-22: **W1 canary reboot + phase2 rebuilderd fleet-wide pause**. Canary-rebooted W1 to validate L1 `ufw-heal-post-k3s.service` under real kube-router race — healer fired at 18:52:19, phase-a hit 120s cap (settle timeout fallback), phase-b reload attempt 1 success, phase-c chain repair clean, phase-e final reload success, probe set healthy, UFW active post-heal. `ufw_state.prom` → 1/1/1. L1 validated end-to-end. Blast radius: zero (2 authentik pods evicted from W1 rescheduled to W2, cold image pull took 7m51s on busy rebuilderd box). Root cause of slow pull: W2's `rebuilderd-worker@1.service` was running 13x python3 build fan-out at ~330% CPU + mem tight (1.1G free, 3.6G swap in use) — disk/network contention. **Fix**: added PLAY 0.5 to `ansible/phase2.yml` (fires post-CP-stabilize, mass-stops `rebuilderd-worker@1.service` on all workers in parallel). `rebuilderd-worker-boot.timer` re-arms each worker at +10min post-its-own-reboot — no explicit restart needed. Per-node stop in PLAY 1 kept as belt-and-suspenders no-op.
- 2026-04-21: **UFW resilience overhaul + drift-heal retry policy**.
  - **Weekly cluster update** ran successfully (phase1 CP + phase2 rolling workers, 0 failures, 16min total). Added CP stabilize pause (4min, Flux + kube-system + traefik + flux-controllers readiness gates) to phase2 PLAY 0 before worker rollout. Bumped CP + per-node stabilize to 4min for DB (CNPG + Percona) failover safety.
  - **W1 post-update UFW broke** again — identified deeper root cause via research (UFW #1987227/#1294544 + K3s #1280/#9807): `ufw-init`'s `ip6tables-restore` silently partial-loads when kube-router + fail2ban race-mutate kernel nft state at boot, leaving `ufw6-logging-deny` + `ufw6-user-*` chains missing. Shipped **3-layer fix**:
    - **L1 — boot healer** `ufw-heal-post-k3s.service` (replaces flaky `ufw-reload-after-k3s.service`): 6-phase bash script — poll kube-router quiescence → `ufw reload` ×3 → per-chain `ip6tables -N` repair (race-free) → verify canary probe set → final reload → status check. 5min timeout.
    - **L2 — drift-heal pre-heal hardened**: `ufw reload` ×3 + detect missing chains + per-chain `iptables -N` / `ip6tables -N` recovery from UFW rules files. Also added `until/retries=5, delay=10s` to every `community.general.ufw` task (SSH rule, default policies, rules loop, routes loop, enable) — survives transient races during module's internal `ufw status verbose`.
    - **L3 — Prometheus alerts**: new VMRule `firewall-alerts` group (UfwDisabled/UfwServiceInactive/UfwChainsUnhealthy, all critical, `for: 5m`). Metrics from `ufw-state-metric.sh` (60s timer, textfile collector) — `ufw_enabled`/`ufw_service_active`/`ufw_chains_healthy` per node. VMRule path: `monitoring/configs/base/victoria-metrics/vmrules.yaml` (vm-operator doesn't auto-convert PrometheusRule → VMRule is source of truth).
  - **Drift-heal retry policy** (Wave 1 + 2): `until/retries` added to all pacman installs (`retries=3, delay=30` — mirror 5xx/GPG/lock races), `fwupdmgr update` (`retries=3, delay=20` — LVFS 5xx), `systemd-resolved` restart handler (`retries=2, delay=5`). Not retried (fail-loud): sshd config validate, preflight health gates, local file ops.
  - **Sync service timeout bump**: `node-maintenance-sync.service TimeoutStartSec=5min → 20min`. 5min was tight when inner config playbook retries stack; two syncs got killed mid-run during 5x stability test even though playbooks finished OK. 20min gives 5min headroom over config's 15min cap.
  - 5x idempotency stress test: 4 consecutive playbook runs, 0 failed, 0 retries triggered — UFW module + pacman passed first attempt every time. Retry machinery = safety net, not routine path.
  - All metrics `1/1/1` on CP, W1, W2 after fix. VMRule `firewall-alerts` loaded in vmalert, 3 rules `inactive/ok`.
  - Memory: existing `gotcha_ufw_ip6tables_post_reboot.md`; retry policy documented in `docs/scripts/node-maintenance/README.md` under "Resilience".
- 2026-04-27: **claude-telegram HTTP trigger** — bot accepts loopback `POST /trigger` (header `X-Trigger-Secret`) that replays prompt as if first allowed user sent it via Telegram. Wired into `node-maintenance-phase2.service` ExecStopPost: on success, CP runs `telegram-notify-claude.sh` → `kubectl exec` curl into pod loopback → bot autonomously reviews alerts + clears stale resources in user's normal DM. Failure path unchanged (alerts chat). Image bumped 1.11 → 1.12 (PR `AKhozya/claude-telegram-bot#1`). Secret added to SOPS `claude-telegram-env.trigger-secret`. Bound to 127.0.0.1 — no Service/NetworkPolicy needed.
- 2026-04-24: **claude-telegram chezmoi-init OOM fix** — init container OOMKilled at 512Mi limit during `npm update -g @anthropic-ai/claude-code` + `bun update @anthropic-ai/claude-agent-sdk`. Bumped to `requests 256Mi / limits 1Gi` (cpu `100m/1000m`). Rolled clean on worker-node-2. Commit `3b2d77e8`.
- 2026-04-20: **W1 post-reboot UFW ip6tables heal** — drift-heal started failing on worker-node at firewall role (`ufw status verbose` → `ERROR: problem running ip6tables`) after W1 reboot 2026-04-19 15:06 BST. Manual `sudo ufw default deny routed` on W1 triggered ufw reload → rebuilt ip6tables → state clean. Re-ran `node-maintenance-config.service` → `worker-node: ok=66 failed=0`. Prevention: added `ufw-reload-after-k3s.service` (oneshot, `After=k3s.service k3s-agent.service ufw.service`, `sleep 15` + `ufw reload`) to `firewall` role tasks + `Reload systemd` handler. Deployed to all 3 nodes via drift-heal. **Superseded 2026-04-21 by `ufw-heal-post-k3s.service`** (6-phase healer — original was too naive for kube-router race window). Memory: `gotcha_ufw_ip6tables_post_reboot.md`.
- 2026-04-20: **Authentik passkey-first migration** — `IdentificationStage.webauthn_stage` (Conditional UI autofill since 2025.12) + `passwordless_flow` (button fallback) wired via 4 custom blueprints in ConfigMap `authentik-blueprints-custom` mounted at `/blueprints/custom/` on server + worker. WebAuthn setup stage tightened to `resident_key_requirement=required` + `user_verification=required`, bound to `default-user-settings-flow` at order 30 for voluntary enrollment. MFA validate enforces `device_classes=[webauthn, totp]` (TOTP retained as recovery 2FA method) + `not_configured_action=configure` + inline `configuration_stages=[webauthn-setup]` (new users still forced to enroll passkey, TOTP not auto-enrolled). Password stage at order 20 of main flow retained as recovery path. RPID stays `authentik.h0melab.work` (preserved). Fresh akadmin passkey re-enrolled 2026-04-20 (zombie 2025-10-21 row had `rp_id=null`, deleted via API). Smoke: 6a Conditional UI + 6b passwordless button + 6c password fallback + 6d OIDC delegation all pass. API path for blueprint instances is `/api/v3/managed/blueprints/?page_size=100` (not `/blueprints/instances/`). Runbook: `docs/scripts/runbooks/authentik-passkey-rollback.md`.
- 2026-04-19: Docs cleanup — deleted 5 stale .md (3 reports + 2 superseded telegram plans v1/v2); HA+PriceBuddy label fix MariaDB→MySQL; caveman-compress 37 repo + 20 memory .md; HOMELAB_ANALYSIS changelog consolidated. MariaDB orphan CRD/CR purge (Phase F fallout): stripped finalizers on 3 sibling CRDs + 13 CRs, cascade-deleted.
- 2026-04-25: **SearXNG retired** — Google rate-limit (429) + low-quality fallback engines. Removed: ns/searxng, `apps/{base,staging}/searxng/`, NetworkPolicy egress (traefik + cloudflared), CF tunnel `search.h0melab.work` route. Manual cleanup needed: Cloudflare DNS CNAME for `search.h0melab.work`. Apps 18 → 17.
- 2026-04-18 → 04-19: **Node config → ansible migration complete** (Phases A-F, 9 roles, plan closed). Roles (apply order): `packages` (pacman declarative + per-host ucode/GPU via host_vars), `base_config` (logrotate/journald 99-caps.conf/sudoers/node-maintenance user/rebuilderd TimeoutStopSec), `k3s_config` (templated config.yaml, drift-alert only, no auto-restart), `k3s_image_gc`, `firewall` (UFW, community.general.ufw additive, lockout-safe), `hardening` (15 configs: sshd/3 sysctls/kubelet/3 k3s service.d/systemd watchdog/resolved LLMNR/NVMe-APST/2 udev/2 tmpfiles.d), `security_scan` (monthly lynis+rkhunter, `/var/log/node-maintenance/security-scan-YYYY-MM.log`, first run 2026-05-01), `rebuilderd` (workers-only resources.conf + units), `ad_hoc` (tag-gated `never` firmware task). Daily drift-heal `node-maintenance-config.timer` (03:00 UTC) → Telegram on `changed>0`/fail. W2 `k3s_data_dir: /mnt/k8s-storage/k3s` host_var captured live state (would have wiped first apply). W1 `/var/lib/rancher` symlink replaced by explicit `data-dir` (zero data move). Drift caught first run: CP missing `inetutils/mesa/vulkan-intel/ufw-extras`; W2 missing `ethtool/go/mesa/vulkan*`. setup-node.sh 706→218 lines (-69%), bootstrap-only (ansible stack CP-only + AUR yay + optional firmware). install-worker.sh 182→50 (-72%). Retired scripts: `setup-ufw-k3s-*`, `setup-rebuilderd-worker-*`, `enable-crash-logging`. Legacy configs ansible-cleaned: 51-kptr-restrict, 99-security-hardening, cpu-governor.
- 2026-04-18: **Node-maintenance system live** — weekly updates `node-maintenance.timer` (Sat 04:30 UTC, Ansible-driven phase1 CP→reboot→phase2 worker loop, SOPS SSH key, Telegram alerts, node-maintenance user). Auto-sync `*:0/10` via read-only GH deploy key (`/root/.ssh/homelab-deploy`), runs `install.sh --sync-only` on HEAD change. Observability: Alloy `loki.source.journal` ingests phase1/2 + sync logs; Grafana dashboard (7 panels, VM+Loki); `NodeMaintenanceMissedRun` VMRule (>8d). E2E fixes: amtool silences (bundled Alertmanager pod), ExecStopPost `$SERVICE_RESULT` check, `ansible_facts['*']` (2.24 prep), `inject_facts_as_vars=False`. First weekly fire 2026-04-25.
- 2026-04-18: PodDisruptionBudgets for 9 HA workloads (authentik server/worker, traefik, cloudflared, main-postgres-rw-pooler, main-mysql-haproxy, main-mysql-orc, couchdb, alertmanager). `minAvailable: 1` 2-replica; `maxUnavailable: 1` 3-replica. CNPG/Percona/Kyverno operator PDBs cover primaries. Node cron/timer audit closed (P3) — no migration candidates.
- 2026-04-13: All 3 nodes → zsh + chezmoi dotfiles (portable .zshrc template, modern CLI tools).
- 2026-04-11: Claude Telegram bot live (Agent SDK, fork of linuz90/claude-telegram-bot).
- 2026-04-09: VictoriaMetrics migration (71% RAM save).
- 2026-04-02: April monthly review, full secrets rotation.

### 2026-05-02 to 2026-05-07 (May Sprint Closures)
Items archived from HOMELAB_ANALYSIS.md PENDING ITEMS table on 2026-05-07.
- ✅ **Uptime Kuma rework** (2026-05-02). Replaced standalone Redis monitor with HA Master + HA Sentinel TCP probes + Blocky DNS probes (W1 192.168.1.129 / W2 192.168.1.126). Pinned UK Deployment + setup-job to control-plane (`nodeSelector` + toleration) so node-targeted probes always traverse external network — fixes monitor-blind-to-own-node-failure (W1 SSH/kubelet probes had stayed 100%/99.86% green via pod-local loopback while host INPUT was DROPing external L3). `/app/data` PVC dropped (state in MySQL; db-config.json regenerates from env, screenshots/error.log ephemeral). New monitors live (MySQL ids 42/43/45/46).
- ✅ **W1 UFW iptables-restore line 2 fail** — kernel-upgrade regression, RESOLVED 2026-05-02 (commit `476ec535`). Root cause: stale ufw kernel chains from previous session block `ufw enable` (re-create attempt against existing chains). `/lib/ufw/ufw-init flush-all` clears stale chains. Patches in `ufw-heal-post-k3s.sh` (phase_b detects "skipping reload\|not enabled" → flush-all + `--force enable`) and `firewall-preflight.sh` (new `phase_ufw_state_recover` runs after modprobe: detects `ENABLED=yes + Status:inactive` → flush-all + force-enable). **Validation tracking**: kept as separate pending row in HOMELAB_ANALYSIS.md (next W1 reboot/kernel upgrade).
- ✅ **UFW heal v3 silent-disable recovery** — RESOLVED 2026-05-02 (commit `476ec535`). `phase_b_reload` previously returned success on `ufw reload` exit-0 even when output said "skipping reload" (no-op when ufw disabled). Now greps for "skipping reload\|not enabled" and triggers flush-all + force-enable recovery. `phase_ufw_state_recover` provides same recovery at drift-heal time.
- 🚫 **Ansible nic_tuning role hardcoded enp3s0** — FALSE ALARM 2026-05-02. Role uses per-host `nic_tuning_iface` host_var; `worker-node.yml` already had `enp4s0` from 2026-04-26 generalisation. Verified live: CP `nic-tune@enp3s0.service active`, W1 `nic-tune@enp4s0.service active` (enp3s0 stays NO-CARRIER), W2 `nic-tune@enp2s0.service active`.
- 🚫 **K3s dual-stack pod networking** — DECIDED 2026-04-26: NOT WORTH IT. No app needs v6-only targets (DoH/CDNs reachable via v4). Migration cost (NP rewrites, CIDR change, breakage risk) >> benefit. v4-only permanent. Blocky pinned `connectIPVersion: v4`.
- ✅ **Audit: zombie helm releases** — DONE 2026-05-02. 12 helm releases all active. kube-prometheus-stack already trimmed (`prometheus.enabled=false` in HelmRelease values; operator + grafana + AM + KSM + node-exporter retained — operator manages AM STS). 5 empty KPS CRDs (prometheuses/prometheusagents/thanosrulers/scrapeconfigs/probes) + 13 empty VM-operator CRDs (vlogs/vlsingles/vlclusters/vlagents, vmanomalies+vmanomalyconfigs, vmclusters/vmdistributed, vmusers/vmauths, vtclusters/vtsingles) bundled by chart — risky-to-remove for marginal benefit. No actionable cleanup.
- ✅ **Blocky 1-week soak observation** — DONE 2026-05-07 (4d late vs 2026-05-03 target). Window 2026-04-30→2026-05-07. Peak RSS 307Mi (rqbjj/W2), 283Mi (wwzgn/W1) — 60% headroom on 512Mi limit. Avg RSS 140-156Mi. p95 latency 4.96 ms / p50 2.61 ms. log_entries 797k rows / 238 MB / ~110k/day stable (range 88k-116k/day). CPU throttle ≤0.24% (negligible). 0 active alerts. Restarts rqbjj=4 / wwzgn=1 — all on Sat 2026-05-04 weekly maintenance window, root cause `dial 10.43.191.88:6379 connect: connection refused` (Redis transient unavail during worker reboot, expected). Pods stable 3d+ since. Verdict: GREEN. Memory-limit review (2026-05-26) blocked by 307Mi peak — 256Mi unsafe; 384Mi acceptable (~25% headroom).

### 2026-04-28 (Ansible Review + NOW Bucket Landed)
- ✅ **Full audit** of `docs/scripts/node-maintenance/ansible/` — 11 roles, 3 playbooks (`phase1`/`phase2`/`node-config`)
- ✅ **Verified baseline**: drift-alerting wired (`ExecStopPost=/usr/local/sbin/node-maintenance-config-notify.sh` → Telegram on `failed>0` OR `changed>0`); sudoers `visudo -c -f` validated; journald caps already 500M/30d/1week; `firewall_preflight` + firewall pre-heal split is intentional (defense-in-depth, documented in `firewall-preflight.sh` header)
- ✅ **Plan saved**: `docs/scripts/node-maintenance/ANSIBLE_REVIEW_PLAN.md` (20 confirmed gaps, triaged NOW/1-2 days/later/never)
- ✅ **NOW bucket SHIPPED** (commits `0cd01203` → `820d1c2b` → `04ec29be`):
  - **#1 `authorized_keys` template**: `base_config` slurps CP node-maintenance pubkey via `delegate_to: control_plane[0]` + `run_once`, deploys to workers exclusive (mode 0600, owner node-maintenance). Source-of-truth = CP's `/var/lib/node-maintenance/.ssh/id_ed25519.pub` (derived from SOPS-decrypted private key at install time). Drift-heal reconciles bootstrap state.
  - **#3 timesyncd assert + textfile metric**: ensures `systemd-timesyncd.service` enabled+active. Deploys `timesyncd-metric.{sh,service,timer}` emitting 3 gauges to `/var/lib/node_exporter/textfile/time_sync.prom` every 60s: `node_time_sync_synchronized`, `node_time_sync_active`, `node_time_sync_drift_seconds`. Verified live: all 3 nodes synchronized=1, CP drift ≈15ms. (Replaces overengineered chrony recommendation — timesyncd already holds ≪100ms in practice for K3s etcd.)
  - **#7 K3s `tls-san`**: block added to `config.yaml.j2`, var `k3s_tls_san: [127.0.0.1, localhost, gmk-k3s-control-plane, 192.168.1.127]` in `group_vars/control_plane.yml`. Drift = template change → existing telegram alert. Restart K3s to regenerate cert.
  - **#8 K3s data-dir perms — DROPPED**: K3s sets `<data-dir>` AND all top-level subdirs (`server/`, `agent/`, `server/cred/`, `server/db/`) to 0755 by design (containerd/kubelet/agent need traversal). Real secrets live in individual files (k3s-server-token, *.crt, *.key — all 0600) which K3s manages itself. Directory-level audit produced false positives on every node. Two attempts both failed (data-dir, then sensitive-subdirs); reverted entirely.
  - **#14 Phase2 Failed-pod GC scoped**: `kubectl delete pod -A` replaced with loop over `phase2_pod_gc_namespaces` list (kube-system, kube-public, flux-system, kyverno, monitoring, traefik, cert-manager, databases, cloudflare-tunnel, backup-replication, node-maintenance). User-app namespaces (immich, paperless, n8n, mealie, etc.) skipped — operator can investigate Failed pods without auto-deletion.
- 🪤 **2 gotchas saved**: (a) `when:` filter on `run_once + delegate_to` task skip-traps the entire task if first batch host fails the condition, leaving registered var as a skip-dict that subsequent hosts choke on. Fix: drop `when` from registering task, gate consumer task instead. (b) ANY ansible directory-level perms audit on K3s data-dir or its subdirs is a false-positive trap — K3s sets all dirs 0755 for traversal; secrets are file-level mode 0600.
- ✅ **1-2 days bucket SHIPPED** (commit `739a578b`):
  - **#2 `/etc/hosts` blockinfile**: `base_config` uses `ansible.builtin.blockinfile` over `groups['all']` loop. CP added `node_ip: 192.168.1.127` host_var to override `ansible_host=127.0.0.1` (set because `ansible_connection: local`). Verified live: all 3 nodes have ANSIBLE-MANAGED block with correct LAN IPs.
  - **#5 SSH host key fingerprint baseline**: `base_config` shell task captures `ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub` → `/var/lib/node-maintenance/ssh-host-fingerprints.txt` (root:root 0644, dir 0750). First run: `BASELINE-CREATED` (changed). Subsequent: `OK` (no change). Drift: `FINGERPRINT-DRIFT` → task fail → telegram alert.
  - **#15 rebuilderd cleanup DRY**: deleted `cleanup-stale-repro-worker-node{,-2}.sh` (per-host duplicates), replaced with single `cleanup-stale-repro.sh.j2` template using `rebuilderd_repro_dir` host_var (W1=`/mnt/k8s-storage/repro`, W2=`/mnt/extra-storage/repro`). `tasks/main.yml` switched `copy:` → `template:`.
- ❌ **Dropped on review** (3 items, plan updated):
  - **#9 systemd-resolved upstream DNS pinning** — would have bypassed home Blocky chain (router DHCP→W1+W2 Blocky→Blocky's own upstream fallback). Verified `/etc/resolv.conf` already shows `nameserver 192.168.1.129 192.168.1.126 fe80::1%2`. `resolvectl status` "Current DNS Server: 9.9.9.9" is GLOBAL fallback (cosmetic systemd-resolved built-in), not what apps use.
  - **#12 sysctl handler audit-trail** — `changed_when:false` on a handler is correct semantics (handler running = upstream task already reported `changed=1`). `command:` module still fails on non-zero rc.
  - **#17 role meta dependencies** — `dependencies:` in meta would force dep role to run on EVERY invocation (slow + noisy when packages already ran via playbook). Playbook role list already enforces correct order. `.ansible-lint` passes production profile without meta files.
- ✅ **Later bucket SHIPPED post-research** (commits `ade9894f` → `49ecf545`):
  - **#6 admin sudoers** — `base_config` deploys `00_<admin_user>` (akhozya/akhozya/z3us per host_var) with content `<user> ALL=(ALL) ALL`, validate via visudo, mode 0440.
  - **swap config** — `base_config` asserts host-specific fstab entry (lineinfile) + active swap path (resolves symlinks for LVM LV → dm-N before grep against `swapon --show`). Per-host vars: CP swapfile/8G, W1 partition/32G UUID, W2 LVM/16G.
  - **#11 fail2ban** — `hardening` deploys `jail.local` (LAN whitelist 192.168.1.0/24, bantime 1h, sshd port 65300 maxretry 3, **systemd backend**). W2 had stray `logpath = /var/log/auth.log` — drift-heal removed.
- ✅ **Post-research adds** (commit `7d5bf28c`):
  - **kernel cmdline audit** — `base_config` asserts `expected_kernel_params` present in `/proc/cmdline` (4 universal in `group_vars/all.yml`: pcie_aspm=off, efi_pstore.pstore_disable=0, printk.always_kmsg_dump=Y, panic=10; workers add 2 AMD: amd_pstate=active, nvme_core.default_ps_max_latency_us=0). Read-only — failed task = telegram alert. Operator fixes via `/boot/loader/entries/*.conf` + reboot.
  - **K3s secrets-encryption runtime verify** — `k3s_config` asserts `k3s secrets-encrypt status` shows `Encryption Status: Enabled`. CP-only, gated on `k3s_secrets_encryption: true`. Catches silent encryption-disable post-restart (config.yaml says enabled but K3s could fail silently on perms/plugin issues).
- ✅ **Power-down prevention** (commits `c54e9020` → `7b4e0ea9`):
  - **NIC tuning generalized**: `nic-tune@.service` replaces `igc-tune@.service`. Always disables EEE + Wake-on-LAN. Speed-force optional via per-iface `EnvironmentFile` (`/etc/nic-tune/<iface>.env`, populated only when `nic_tuning_force_speed` set). CP enp3s0 igc keeps 1Gbps force (gigabit bug workaround); W1 enp4s0 igc + W2 enp2s0 r8169 newly under ansible (W2 EEE flipped `enabled-active → disabled` verified live).
  - **PCIe runtime PM rule**: `udev-60-pci-no-runtime-pm.rules` replaces nvme-only. Per-class rules cover SATA (0x010601), NVMe (0x010802), Ethernet (0x020000) — sets `power/control=on`. Belt-and-suspenders to `pcie_aspm=off` cmdline.
  - **Coverage 4-layer**: NVMe (cmdline + modprobe + udev class + tmpfiles + block runtime PM), SATA (udev ALPM=max_performance + udev class), PCIe link (cmdline ASPM off + udev class runtime PM), Ethernet (cmdline ASPM + udev class + nic-tune service).
  - **Gotcha caught**: `copy: content:` fails on empty/whitespace Jinja output ("src (or content) is required"). Fix: gate task with `when:` on conditional + sibling task to remove file otherwise. Memory: `gotchas.md#ansible-copy-content-empty`.
- 🗓️ **Later**: pacman_config role, admin sudoers, fail2ban tuning, K3s server flags drift detection, idempotency CI, ansible-vault for secrets
- ❌ **Never**: logrotate.conf system-wide tuning (per-app sufficient), K3s cert SAN auto-renewal (K3s handles internally), firewall+preflight consolidation (split intentional)

### 2026-04-26 (Redis HA Migration — Phase 1)
- ✅ **OT-CONTAINER-KIT redis-operator v0.24.0** deployed via Flux HelmRelease
- ✅ **RedisReplication CR**: 1 master (W2) + 1 replica (W1), hard pod anti-affinity, image `quay.io/opstree/redis:v8.6.2` (bumped from v7.4.8 by Renovate during cutover; researched, no breaking changes)
- ✅ **RedisSentinel CR**: 3 sentinels spread across CP/W1/W2 (CP toleration added), quorum 2 of 3, parallelSyncs 1, downAfterMilliseconds 5000
- ✅ **ACL secret** with literal users (admin, paperless, immich, blocky), `default on nopass` for liveness probes (NetworkPolicy restricts namespace access)
- ✅ **Mixed client model**: Immich uses Sentinel via `REDIS_URL=ioredis://<base64-json>`; Paperless uses static `redis-replication-master` Service (Paperless does not support Sentinel)
- ✅ **Cutover successful**: Immich 76 conns + Paperless 8 conns on new cluster, old redis-0 0 app conns
- ✅ **Failover tested**: master pod delete → Sentinel promoted replica → endpoint moved → apps reconnected (HTTP 200/302)
- ✅ **Old redis-0 StatefulSet decommissioned**, PVC `data-redis-0` (5Gi) deleted, all legacy `redis/` dirs removed from git
- ✅ **PrometheusRule `redis-ha` group**: 7 alerts (RedisHADown, RedisHAAllDown, RedisHASentinelQuorumLost, RedisHAReplicationBroken, RedisHAReplicationLag, RedisHAMemoryHigh, RedisHAClientReconnectStorm)
- ⚙️ **Quota bumps**: databases ns `limits.cpu` 17→20, `limits.memory` 18→20Gi, `services` 20→50 (OT operator creates 6 svcs/replication + 3 svcs/sentinel)
- ⚙️ **Plan-vs-actual drift fixed during execution**: OT v1beta2 schema (`serviceType` removed; `secretKeyRef` for sentinel password); Sentinel pod label is `app=redis-sentinel-sentinel` (NP + anti-affinity selectors corrected); `readOnlyRootFilesystem: true` incompatible with OT entrypoint writing `/etc/redis/redis.conf` — set `false`; `protected-mode no` required for nopass default user
- 🔮 **Phase 2 unblocked**: Blocky DNS migration ready

### 2026-04-26 (Blocky DNS Migration — Phase 2)
- ✅ **Replaced AdGuard Home** (2 node-pinned Deployments) with **Blocky v0.29.0** (single Deployment, 2 replicas, hard pod anti-affinity W1+W2, native rolling updates)
- ✅ **Shared Redis HA cache** (database 1) for cross-pod state sync via Phase 1 redis-replication-master
- ✅ **CNPG Postgres query log** — `blocky` database + role added to `cluster.yaml` `managed.roles`, 7-day retention via Blocky native pruning
- ✅ **LAN-facing IPs preserved**: 192.168.1.129 + 192.168.1.126 (K3s servicelb LoadBalancer + externalTrafficPolicy: Local + 2 Services for per-node binding)
- ✅ **HagezI multi/pro.plus/tif + OISD blocklists** active, blocked queries return `0.0.0.0`
- ✅ **DoH upstreams**: Cloudflare Security + Quad9, with Cloudflare/Quad9 IP+IPv6 bootstrap DNS
- ✅ **Custom DNS rewrite** for `*.h0melab.work` → both worker IPs (no manual A records needed for new ingresses)
- ✅ **VMServiceScrape + VMRule** (5 alerts: BlockyDown, BlockyAllReplicasDown, BlockyHighErrorRate, BlockyBlocklistRefreshFailing, BlockyHighLatency); Grafana dashboard ID 13768 deployed as ConfigMap
- ✅ **Mac resolver script** (`scripts/macos/setup-h0melab-resolver.sh`) updated AdGuard → Blocky, synced via chezmoi
- ✅ **Homepage widget** updated AdGuard → Blocky
- ⚙️ **Plan-vs-actual drift fixed during execution**:
  - Plan referenced old `redis.databases.svc.cluster.local` — corrected to `redis-replication-master.databases.svc.cluster.local` (post-Phase 1 svc)
  - NetworkPolicy podSelector `app: redis` → `app: redis-replication`
  - Plan missed `blocky` role addition to CNPG `cluster.yaml` `managed.roles` — added (CNPG does NOT auto-create roles from labeled Secrets)
  - Plan used ServiceMonitor + PrometheusRule, but cluster vm-operator has `VM_ENABLEDPROMETHEUSCONVERTER_*=false` — converted to native VMServiceScrape + VMRule
  - Blocky `queryLog.target` doesn't env-substitute `${PG_PASSWORD}` (Redis password field works) — pivoted from ConfigMap+env-vars to SOPS-encrypted Secret with passwords inlined into config.yml
  - GitOps bootstrap paradox: `apps` depends on `infrastructure-configs`, but resource-governance entry needed `blocky` ns first — split into 2 commits (cutover with deferred governance, re-enable governance post-ns-create)
- 💥 **CP node `enp3s0` NIC link drops** during execution (Intel I225-V/igc): 4 link-down events 21:05-21:10, CP fully isolated from LAN, recovered after physical reboot. Flux source/helm/notification controllers crashlooped post-recovery, fixed by pod delete. Added to PENDING ITEMS as P1.
- ⚙️ **AdGuard pruned**: ns + manifests deleted by Flux (cutover commit removes `apps/staging/kustomization.yaml` adguard entry); resource-governance adguard-home.yaml entry also removed
- 🔮 **Open**: Uptime Kuma DNS probes for both Blocky IPs (manual UI step, scheduled 2026-05-04); Phase 1 redis-ha alerts also need VMRule conversion (separate task, P2)

### 2026-04-26 (Phase 2 Hardening + Stale Cleanup)
Same-day continuation of Phase 2 Blocky migration. Multiple fixes + cleanup:

**Blocky config tuning** (research-driven, per upstream best practices):
- Dropped `multi.txt` (subsumed by pro.plus) and `big.oisd.nl` (heavy overlap) → ~40% fewer entries to load
- `connectIPVersion: dual` → `v4` (K3s podCIDR is v4-only; v6 attempts wasted latency)
- Added `clientLookup.upstream: 10.43.0.10` for PTR-based hostname enrichment in query log
- Caching: `minTime: 60s` → `5m`, `maxTime: 0` → `12h`, explicit `cacheTimeNegative: 30m`
- Bootstrap DNS trimmed 8 → 2 entries (1.1.1.2 + 9.9.9.9)
- `redis.required: false` → `true` (surface failures rather than silent fallback)
- `loading.downloads.timeout: 5m` + `attempts: 5` (tif.txt parse-timeout fix)
- Pivot ConfigMap → SOPS Secret with passwords inlined (queryLog.target doesn't env-substitute)

**Monitoring stack fix**:
- Discovered `vm-operator` has `VM_ENABLEDPROMETHEUSCONVERTER_*=false` → all `PrometheusRule` resources silently dead (vmalert reads only `VMRule`)
- Migrated redis-ha 7-alert group from `prometheus-rules.yaml` to `vmrules.yaml`
- Deleted `monitoring/configs/staging/kube-prometheus-stack/prometheus-rules.yaml` (1183 lines of dead duplicate; all groups already in vmrules.yaml except redis-ha)
- vmalert now loads 25 groups including blocky + redis-ha

**Blocky LB consolidation**:
- 2 LoadBalancer Services on port 53 created K3s servicelb host-port conflict → 2 svclb pods Pending 86min
- Collapsed to single `blocky-dns` Service (servicelb auto-assigns 1 LB IP per worker via ETP=Local) — exposes both 192.168.1.129 + 192.168.1.126

**Uptime Kuma cleanup** (via direct MySQL):
- Deleted: AdGuard, Prometheus, Redis (single-pod), SearXNG (4 stale monitors, FK CASCADE cleaned heartbeats/stats)
- Added: Blocky DNS, Redis HA Master, Redis HA Sentinel, VictoriaMetrics
- Pivoted Blocky probes to ClusterIP DNS name (LB IP not routable from cluster pods due to ETP=Local)
- All 5 new monitors GREEN

**NetworkPolicy fixes**:
- uptime-kuma egress: added 26379 (Sentinel) + 8429 (vmsingle HTTP) + DNS 53 UDP/TCP
- redis-ha ingress: added uptime-kuma ns to Sentinel 26379 allowlist

**igc NIC drop fix** (CP `enp3s0` Intel I225-V):
- Created ansible role `nic_tuning` with systemd unit `igc-tune@.service`
- Forces 1Gbps full duplex + disables Energy Efficient Ethernet (EEE)
- Applied via `node-maintenance-config.service` → confirmed `Speed: 1000Mb/s`, `EEE: disabled`
- Persists across reboots

**CNPG schema fix**:
- Plan T2 missed: `blocky` role must be in `cluster.yaml` `managed.roles` block (CNPG does NOT auto-create roles from labeled Secrets)
- Added; Database CR reconciled successfully

**Backup/restore script refresh**:
- Removed: AdGuard, SearXNG (decommissioned)
- Added: blocky-config (SOPS), blocky-db-user (CNPG), redis-acl-secret, immich-redis-url, claude-telegram (3 secrets)
- DB backup CronJobs unchanged (auto-discover via `\l`/`SHOW DATABASES`/`_all_dbs` — picks up `blocky` PG db automatically)
- Manual PVC backup test: ✅ 10/10 PVCs successful, 0 failed, 55MB total

**Stale resource cleanup**:
- Removed `adguard-home` line from `pvc-backup-cronjob.yaml` CRITICAL_PVCS
- Deleted orphan Prometheus PVCs (~100Gi storage recovered): `prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-{0,1}` (no consumer; we use vmsingle)
- Updated homepage widget AdGuard → Blocky
- Mac resolver script + chezmoi sync (AdGuard → Blocky text refs)

**CP node incident** (2026-04-26 21:05-21:10):
- `enp3s0` NIC link DOWN events × 4 → CP isolated until physical reboot
- Recovered after `sudo reboot`; Flux source/helm/notification controllers crashlooped post-recovery, fixed via pod delete
- Root cause: igc driver behavior at 2.5G with EEE — fixed via `nic_tuning` role above

**IPv6 audit**:
- All 3 nodes have global IPv6 (RA + ULA)
- Pods are IPv4-only (K3s clusterCIDR v4-only) — flagged as Backlog dual-stack consideration
- Old PENDING "W2 missing IPv6" was outdated (node-level OK; pod-level limitation is K3s scope)

**Files touched in this batch**: 23 changes across apps/, infrastructure/, monitoring/, docs/, .backup/, scripts/macos/, dot files (chezmoi)

**Same-day Redis HA failover smoke test** (Sunday-reboot prep):
- Pre-state: r0 master (10.42.2.164/W2), r1 slave; Sentinel quorum agrees
- Action: `kubectl delete pod redis-replication-0`
- t+15s: Sentinel promoted r1 to master (10.42.1.162/W1) — quorum cleanly elected
- t+30s: K8s `redis-replication-master` Service endpoint moved to new master
- r0 recovered (~30s): **OT operator forcibly demoted r1 back to slave + restored r0 as master** (operator-driven topology overrides Sentinel)
- Sentinel kept stale view of r1 as master for ~5 min until manual `SENTINEL reset` + STS rollout restart
- K8s Services followed operator's view (correct)
- **Implication**: apps using static `redis-replication-master` Service (Paperless, Blocky) ALWAYS see correct master via K8s endpoints. Apps using Sentinel discovery (Immich `REDIS_URL=ioredis://sentinels[]...`) may briefly target a slave during operator/Sentinel divergence — ioredis client retries and rediscovers via Sentinel HELLO.
- Immich healthcheck during test: HTTP 200 throughout
- **Sunday-reboot readiness**: ✅ failover works automatically. Manual Sentinel reset only needed if operator's master-restore creates app reconnect storms (none observed in test).

> 📦 **2025 changelog entries (Oct–Dec) archived** → [archive/HOMELAB_HISTORY_2025.md](archive/HOMELAB_HISTORY_2025.md)

---

## 2026 Monthly Reviews (January - April)

*Moved from HOMELAB_ANALYSIS.md on 2026-04-10 to keep the analysis file lean.*

## CRITICAL ACTION ITEMS

**Last Updated**: 2026-04-02 (Monthly Review)
**Source**: HOMELAB_REVIEW_2025_12_17 (archived, see git history)
**Completed Items**: See [HOMELAB_HISTORY.md](./HOMELAB_HISTORY.md) for detailed completed task archive

### April 2026 Monthly Review

**Review Date**: 2026-04-02
**Reviewer**: Staff DevOps/SRE + Staff Software Developer (7-agent parallel audit)
**Overall Status**: ✅ **HEALTHY** - All systems nominal, secrets rotation completed

#### Infrastructure Health

| Component | Status | Details |
|-----------|--------|---------|
| **Nodes** | ✅ 3/3 Ready | K3s v1.35.3, Kernel 6.18.20-1-lts, max 25% memory |
| **Control Plane** | ✅ Healthy | 19% CPU, 19% memory |
| **worker-node** | ✅ Healthy | 21% CPU, 25% memory |
| **worker-node-2** | ✅ Healthy | 16% CPU, 19% memory |
| **Pods** | ✅ All Running | 0 CrashLoop, 42 deployments at target |
| **PostgreSQL** | ✅ 2/2 Ready | Zero replication lag, >99% cache hit |
| **MySQL** | ✅ 2/2 Ready | Async replication |
| **CouchDB** | ✅ 2/2 Running | Full cluster membership |
| **Redis** | ✅ 1/1 Running | 8.83MB used |
| **VictoriaMetrics** | ✅ VMSingle+VMAgent+VMOperator | ~113k series, ~487Mi total |
| **Alerts** | ✅ None firing | Only Watchdog (expected) |
| **Backups** | ✅ All successful | 12h replication cycle, <10s completion |
| **Certificates** | ✅ 20/20 Ready | Nearest expiry 32 days |
| **Flux/GitOps** | ✅ All healthy | 6/6 kustomizations, 10/10 HelmReleases |
| **Kyverno** | ✅ 0 violations | 10 policies (7 enforce, 3 audit) |
| **NetworkPolicies** | ✅ 40 policies | All app namespaces covered |
| **SOPS Secrets** | ✅ 51/51 encrypted | Zero plaintext in git |
| **PVCs** | ✅ 28/28 Bound | All healthy |

#### Code Review Score: 94/100 (A) — Maintained

| Category | Score |
|----------|-------|
| YAML Quality | 9/10 |
| Security Posture | 9/10 |
| Resource Management | 10/10 |
| GitOps Best Practices | 10/10 |
| Monitoring | 9/10 |
| High Availability | 9/10 |
| Image Management | 9/10 |
| Documentation | 9/10 |
| Backup & DR | 10/10 |
| Policy Enforcement | 10/10 |

#### Actions Completed This Review

- ✅ **Full secrets rotation**: 6 PG + 3 MySQL + 2 Redis + 1 CouchDB + 6 OIDC + 1 Authentik secret key
- ✅ **NetworkPolicy**: Fixed AND/OR logic bug in n8n, linkwarden, mealie (3 files)
- ✅ **README.md**: Corrected PostgreSQL replica count (3→2) and audit grade (A- 92→A 94)
- ✅ **PSS labels**: Added Pod Security Standards to 10 infrastructure namespaces
- ✅ **Stirling PDF**: Moved plaintext OIDC secret from ConfigMap to SOPS-encrypted Secret
- ✅ **Linkwarden**: Added to CNPG managed roles (prevents password loss on PG restart)
- ✅ **Cleanup**: Removed 5 redundant OIDC secret files, removed n8n OIDC (unsupported), removed wallabag references
- ✅ **HA OIDC**: Disabled hass-oidc-auth (incompatible with HA 2026.4.0)
- ✅ **Backup scripts**: Fixed missing secrets, wrong names/namespaces, updated for OIDC cleanup
- ✅ **SECRETS_ROTATION.md**: Full rewrite — separated service secrets from user passwords, documented OIDC locations per app

#### Pending Scheduled Items

| Item | Target Date | Priority |
|------|-------------|----------|
| ~~VictoriaMetrics re-evaluation~~ | ~~April 2026~~ | ✅ Done (migrated 2026-04-09, 71% RAM savings) |
| Remove worker-node-2 replication step | ~May 20, 2026 | P2 |
| n8n PgBouncer `statement_timeout` fix — re-check [#25705](https://github.com/n8n-io/n8n/issues/25705) | May 2026 | P3 |
| High-priority secret rotation (PG: authentik/immich/n8n, MySQL: HA, Redis: immich) | 2026-07-01 | P1 |
| Re-evaluate HA OIDC when hass-oidc-auth releases stable version | Backlog | P3 |
| Add PodDisruptionBudgets for HA workloads | Backlog | P3 |

**Next Review**: 2026-05-04 (Monthly)

### March 2026 Monthly Review

**Review Date**: 2026-03-06
**Reviewer**: Staff DevOps/SRE + Staff Software Developer
**Overall Status**: ✅ **HEALTHY** - All systems nominal

#### Infrastructure Health (Staff DevOps/SRE Perspective)

| Component | Status | Details |
|-----------|--------|---------|
| **Nodes** | ✅ 3/3 Ready | K3s v1.35.3, Kernel 6.18.16-lts |
| **Control Plane** | ✅ Healthy | 23% CPU, 13% memory |
| **worker-node** | ✅ Healthy | 20% CPU, 33% memory (rebuilderd active) |
| **worker-node-2** | ✅ Healthy | 31% CPU, 38% memory (rebuilderd active) |
| **Pods** | ✅ 82 Running | 0 CrashLoop, 7 Completed jobs |
| **PostgreSQL** | ✅ 2/2 Ready | v18.3 |
| **MySQL** | ✅ 2/2 Ready | Async replication, no lag |
| **CouchDB** | ✅ 2/2 Running | StatefulSet in databases namespace |
| **Redis** | ✅ 1/1 Running | v8.6.1 |
| **Metrics** | ✅ Prometheus (now VictoriaMetrics) | 90k active series (at time of review) |
| **Alerts** | ✅ None firing | Clean alert state |
| **Backups** | ✅ All successful | NAS + worker-node-2 replication working |
| **Certificates** | ✅ 19/19 Ready | 71+ days until expiration |
| **Flux/GitOps** | ✅ All healthy | All 6 kustomizations reconciled |
| **Scrape Targets** | ✅ 49 active | 0 down |
| **Kyverno** | ✅ 0 violations | Clean |
| **Stale ReplicaSets** | ✅ 0 | Cleaned 4 stale RS this session |

#### Prometheus (at time of review, now replaced by VictoriaMetrics)

- **TSDB Head**: 278k series (includes stale series from kernel reboots + Traefik restarts)
- **Active Series by Job**: ~90k (healthy, down from Feb's 111k)
- **Memory**: 905Mi + 1025Mi / 1300Mi each (70-79%)
- **Top Cardinality**: kubelet 35k (39%), apiserver 17k (19%), kube-state-metrics 10k (11%)
- **Scrape Targets**: 49 active, 0 down
- **Note**: Replaced by VictoriaMetrics on 2026-04-09 (~487Mi total, 71% RAM savings)

#### Storage

| Location | Used | Total | Usage |
|----------|------|-------|-------|
| worker-node `/mnt/k8s-storage` | 413GB | 4.2TB | 11% |
| worker-node-2 `/mnt/extra-storage` | 319GB | 863GB | 39% |

#### n8n PgBouncer statement_timeout (#25705)

- **Status**: Still **OPEN** upstream (triage:pending, Linear GHC-6809)
- **Last activity**: 2026-02-18 (5 comments, no n8n team fix planned)
- **Our workaround**: `DB_POSTGRESDB_STATEMENT_TIMEOUT=0` in deployment — still needed
- **Re-check**: May 2026

#### CSP Policy Update (2026-03-06)

- Added `worker-src blob: 'self'`, `connect-src blob: data:`, `img-src blob:` to global CSP
- **Reason**: Stirling PDF v2.6.0 uses PDF.js web workers, OpenCV.js WASM, canvas blob thumbnails
- **Scope**: Global (all 17 apps), minimal security risk (blob:/data: are locally-generated)
- **Traefik quirk**: Middleware CRD header changes require `rollout restart` to take effect

#### Pending Scheduled Items

| Item | Target Date | Priority |
|------|-------------|----------|
| Remove worker-node-2 replication step | ~May 20, 2026 | P2 |
| ~~ECC session regex fix~~ — PR #408 now in marketplace main, chezmoi patch removed 2026-03-22 | ✅ Done | ~~P3~~ |
| n8n PgBouncer `statement_timeout` fix — re-check [#25705](https://github.com/n8n-io/n8n/issues/25705) | May 2026 | P3 |
| Re-evaluate VictoriaMetrics | April 2026 | P3 |

**Next Review**: 2026-04-06 (Monthly)

### February 2026 Monthly Review

**Review Date**: 2026-02-07
**Reviewer**: Staff DevOps/SRE + Staff Software Developer
**Overall Status**: ✅ **HEALTHY** - Excellent state, minor housekeeping done

#### Infrastructure Health (Staff DevOps/SRE Perspective)

| Component | Status | Details |
|-----------|--------|---------|
| **Nodes** | ✅ 3/3 Ready | K3s v1.35.3, Kernel 6.18.16-lts |
| **Control Plane** | ✅ Healthy | 15% CPU, 19% memory |
| **worker-node** | ✅ Healthy | 19% CPU, 26% memory (rebuilderd active) |
| **worker-node-2** | ✅ Healthy | 8% CPU, 18% memory |
| **Pods** | ✅ 81 Running | 0 CrashLoop, 15 Completed jobs |
| **PostgreSQL** | ✅ 2/2 Ready | v18.3 (upgraded from 18.2, 2026-02-26) |
| **MySQL** | ✅ 2/2 Ready | Async replication, HAProxy active |
| **CouchDB** | ✅ 2/2 Running | StatefulSet in databases namespace |
| **Redis** | ✅ 1/1 Running | v8.6.0 (upgraded from 8.2.2, 2026-02-20) |
| **Prometheus** | ✅ 72% memory | 121k series, 941Mi/1300Mi (at time of review, now VictoriaMetrics) |
| **Alerts** | ✅ None firing | Clean alert state |
| **Backups** | ✅ All successful | NAS + worker-node-2 replication working |
| **Certificates** | ✅ All Ready | 36-86 days until expiration |
| **Flux/GitOps** | ✅ All healthy | All 6 kustomizations reconciled |
| **Resource Governance** | ✅ Complete | 27 quotas, 26 limitranges |
| **Stale ReplicaSets** | ✅ 0 | Cleaned 87 stale RS this session |

#### Prometheus Improvement (at time of review, now replaced by VictoriaMetrics)

- **Series Count**: 111k (↓ 54% from 244k in Jan review)
- **Memory**: 924Mi / 1300Mi (71%, ↓ from 87%)
- **Replicas**: 2 HA (924Mi + 775Mi)
- **Scrape Targets**: 49
- **Note**: Replaced by VictoriaMetrics on 2026-04-09 (~487Mi total, 71% RAM savings)

#### Popeye Health Scan

- **Score**: 86/100 (B grade) - down from 100/100
- **Cause**: Mostly false positives from K3s and Percona operator
- **False Positives** (not actionable):
  - 4 kube-system services with no pods (K3s doesn't run controller-manager/etcd/proxy/scheduler as pods)
  - 5 MySQL operator services with unmatched ports (operator-managed, normal)
  - 5 orphaned ClusterRoleBindings (Flux image controllers not installed, K3s system)
- **Actionable**: config-reloader sidecars missing resource limits (Prometheus + Alertmanager) - P3

#### Kyverno Violations

- **6 violations**: All `require-resource-limits` with null/null namespace (stale ephemeral pod reports)
- **Status**: Not actionable - same as previous reviews

#### Storage

| Location | Used | Total | Usage |
|----------|------|-------|-------|
| worker-node `/mnt/k8s-storage` | 753GB | 4.2TB | 19% |
| worker-node-2 `/mnt/extra-storage` | 204GB | 863GB | 25% |
| worker-node-2 backups | 137MB | - | Today's backup only |
| worker-node-2 repro (rebuilderd) | 34GB | - | Build artifacts |

#### Uptime Kuma Monitors

- **28 monitors**: All current (wallabag/linkding stale monitors already removed)
- **NAS Zettlab** monitor added (id=38)

#### Pending Scheduled Items

| Item | Target Date | Priority |
|------|-------------|----------|
| Remove worker-node-2 replication step | ~May 20, 2026 | P2 |
| ~~Migrate Promtail to Grafana Alloy~~ | ~~Before March 2, 2026~~ | ✅ Done |
| ~~Re-evaluate VictoriaMetrics~~ | ~~April 2026~~ | ✅ Done (migrated 2026-04-09) |
| ~~LTS kernel 6.18~~ | ~~TBD~~ | ✅ Done (6.18.16-lts on all 3 nodes) |
| ~~Authentik worker memory fix — check if [#20537](https://github.com/goauthentik/authentik/issues/20537) landed in 2026.2.x, reduce worker limit 1500Mi→800Mi~~ | ~~March 8, 2026~~ | ✅ Done (v2026.2.1 fixed, reverted to 1200Mi) |
| ~~n8n PgBouncer `statement_timeout` fix — check [#25705](https://github.com/n8n-io/n8n/issues/25705)~~ | ~~March 2026~~ | ✅ Checked (still open, workaround stays) |
| n8n PgBouncer `statement_timeout` fix — re-check [#25705](https://github.com/n8n-io/n8n/issues/25705), remove workaround if fixed upstream | May 2026 | P3 |
| ~~Home Assistant: audit legacy template entities~~ | ~~Before June 2026~~ | ✅ Verified compliant (no legacy templates in config) |
| ~~Authentik: update `/media` mount to `/data/media`~~ | ~~Next Authentik upgrade~~ | ✅ Done |
| ~~Immich: remove unrecognized `PUBLIC_IMMICH_SERVER_URL` env var~~ | ~~Next Immich change~~ | ✅ Done |
| ~~Linkwarden: update Playwright `chromium_headless_shell-1200` path~~ | ~~On Playwright version bump~~ | ✅ Done (version-agnostic wildcard) |

**Monthly Review Checklist** (for next review):
- [x] ~~Helm chart deprecation audit~~ ✅ Completed (2026-02-07) - 2 commits, Kyverno + CouchDB fixes
- [x] ~~Promtail EOL migration status~~ ✅ Migrated to Alloy (2026-02-07)

**Next Review**: 2026-04-06 (Monthly)

---

### January 2026 Comprehensive Review

**Review Date**: 2026-01-09
**Reviewer**: Staff DevOps/SRE + Staff Software Developer
**Overall Status**: ✅ **HEALTHY** - Minor gaps identified

#### Infrastructure Health (Staff DevOps/SRE Perspective)

| Component | Status | Details |
|-----------|--------|---------|
| **Nodes** | ✅ 3/3 Ready | K3s v1.35.3, Kernel 6.18.16-lts |
| **Control Plane** | ✅ Healthy | 14% CPU, 17% memory |
| **worker-node** | ✅ Healthy | 20% CPU, 24% memory (rebuilderd active) |
| **worker-node-2** | ✅ Healthy | 22% CPU, 40% memory (tensorflow building) |
| **Pods** | ✅ 82 Running | 0 CrashLoop, 48 Completed jobs |
| **PostgreSQL** | ✅ 2/2 Ready | Cluster in healthy state |
| **MySQL** | ✅ 2/2 Ready | Async replication, HAProxy active |
| **CouchDB** | ✅ 2/2 Running | StatefulSet in databases namespace |
| **Redis** | ✅ 1/1 Running | Cache healthy |
| **Prometheus** | ⚠️ 87% memory | 244k series, 1125Mi/1300Mi (at time of review, now VictoriaMetrics) |
| **Alerts** | ✅ None firing | Clean alert state |
| **Backups** | ✅ All successful | Replication to worker-node-2 working |
| **Certificates** | ✅ All Ready | 60+ days until expiration |
| **Flux/GitOps** | ✅ All healthy | All kustomizations reconciled |
| **Resource Governance** | ✅ Complete | 26 quotas, 25 limitranges |

#### Security Gaps Found (P2-MEDIUM) - ✅ ALL RESOLVED

| Issue | Namespace | Impact | Status |
|-------|-----------|--------|--------|
| ~~Missing NetworkPolicy~~ | cloudflare-tunnel | Low | ✅ Fixed (8c9bd9b) |
| ~~Missing NetworkPolicy~~ | csp-reporter | Low | ✅ Fixed (8c9bd9b) |
| ~~Missing NetworkPolicy~~ | loki | Medium | ✅ Fixed (8c9bd9b) |
| ~~Missing NetworkPolicy~~ | obsidian | Low | ✅ Fixed (8c9bd9b) |
| ~~Missing NetworkPolicy~~ | traefik | Medium | ✅ Fixed (8c9bd9b) |
| ~~Popeye not scheduled~~ | popeye | Low | ✅ Fixed - Weekly CronJob (8c9bd9b) |

#### Kyverno Policy Violations (Audit Mode - Informational) - ✅ ALL RESOLVED

| Namespace | Policy | Reason | Status |
|-----------|--------|--------|--------|
| backup-replication | require-non-root | rsync needs root | ✅ Exclusion added (8c9bd9b) |
| loki | require-resource-limits | Sidecar missing limits | ✅ Fixed (0510d1d) |
| monitoring | require-resource-limits | Stale ReplicaSets | ✅ Not actionable - old pods |

#### Known Privileged Workloads (Documented Exceptions)

| Workload | Reason | Mitigation |
|----------|--------|------------|
| immich-server | GPU transcoding (VAAPI) | NetworkPolicy, namespace isolation |
| adguard-home | Port 53 binding | NetworkPolicy, dedicated namespace |
| alloy | Host log access (K8s API) | DaemonSet, RBAC-scoped |
| home-assistant | Hardware integrations | NetworkPolicy, capability restrictions |

#### Code Quality (Staff Software Developer Perspective)

| Check | Status | Notes |
|-------|--------|-------|
| Image tags | ✅ All pinned | No :latest or floating tags (fixed 2026-02-20) |
| Security headers | ✅ 100% coverage | All ingresses have middleware |
| Stale ReplicaSets | ✅ 0 found | Clean cluster state |
| Job cleanup | ✅ 13 total | Normal backup job history |
| DRY violations | ⚠️ Acceptable | Documented as intentional for homelab |

#### Prometheus Cardinality Watch

- **Series Count**: 244,658 (↑ from last review)
- **Memory**: 1125Mi / 1300Mi (87%)
- **Action**: Monitor - consider metric drops if >260k

#### Rebuilderd Contribution Status

| Node | Current Build | Progress | ETA |
|------|---------------|----------|-----|
| worker-node | rocfft → next | ✅ Completed | Picking next |
| worker-node-2 | tensorflow 2.20.0 | 57% (20,313/35,367) | ~17:00 UTC |

#### Action Items from This Review

| Priority | Item | Effort | Status |
|----------|------|--------|--------|
| P2 | Add NetworkPolicy to cloudflare-tunnel | 30 min | ✅ Done (8c9bd9b) |
| P2 | Add NetworkPolicy to loki | 30 min | ✅ Done (8c9bd9b) |
| P2 | Add NetworkPolicy to traefik | 30 min | ✅ Done (8c9bd9b) |
| P2 | Add NetworkPolicy to csp-reporter | 15 min | ✅ Done (8c9bd9b) |
| P2 | Add NetworkPolicy to obsidian | 15 min | ✅ Done (8c9bd9b) |
| P3 | Add Popeye CronJob (weekly) | 15 min | ✅ Done (8c9bd9b) |
| P3 | Add Kyverno exclusion for backup-replication | 10 min | ✅ Done (8c9bd9b) |
| P3 | Fix loki-sc-rules sidecar resources | 10 min | ✅ Done (0510d1d) |
| INFO | Investigate null resource-limit violations | 15 min | ✅ Done - stale reports from old ReplicaSets |

---

### Code Review Findings (2026-03-07)

**Overall Score**: 94/100 (A) — up from 93/100 in February 2026

| Category | Score | Change | Notes |
|----------|-------|--------|-------|
| Project Structure | 95/100 | = | Clean GitOps, base/staging pattern |
| Kubernetes Patterns | 93/100 | +1 | Flux healthChecks, removed force:true |
| Database Infrastructure | 92/100 | = | PG+MySQL HA, pooler, managed roles |
| Monitoring Stack | 90/100 | = | Inhibit rules added, duplicate alert removed |
| Security Implementation | 96/100 | +2 | 4 new NetworkPolicies, 100% namespace coverage |
| Backup & DR | 96/100 | = | NAS replication, validation pipeline |
| Code Quality (DRY) | 78/100 | = | DRY violations accepted for homelab simplicity |
| Documentation | 91/100 | +1 | Analysis doc kept current |

#### Findings Implemented (March 2026)

| # | Finding | Severity | Status |
|---|---------|----------|--------|
| 1 | Missing NetworkPolicy for cert-manager, kyverno, percona-mysql, backup-replication | P1 | ✅ Fixed (4 policies, pod CIDR + container ports) |
| 2 | No Alertmanager inhibit rules (alert storms) | P1 | ✅ Fixed (3 rules: NodeDown, severity, InfoInhibitor) |
| 3 | Duplicate AlertmanagerNotificationsFailing alert | P1 | ✅ Fixed (removed, kept percentage-based) |
| 4 | Missing Flux healthChecks on infrastructure-controllers | P1 | ✅ Fixed (cert-manager-webhook, kyverno-admission-controller) |
| 5 | `force: true` on apps Kustomization | P1 | ✅ Fixed (removed) |
| 6 | Percona HelmRepository 24h refresh interval | P1 | ✅ Fixed (24h -> 6h) |
| 7 | cert-manager floating chart version 1.19.x | P1 | ✅ Fixed (pinned to 1.19.4) |
| 8 | Homepage ClusterRole reads all secrets cluster-wide | P1 | ⚠️ Accepted (required for K8s service discovery, documented) |
| 9 | No runbook_url on 111 custom alerts | P2 | ❌ Won't do (no runbooks exist, URLs would point nowhere) |
| 10 | 9 PVCs missing storageClassName: local-path | P2 | ✅ Fixed (9 PVCs + immich storageClass→storageClassName typo) |
| 11 | CPUThrottlingHigh uses hardcoded worker IPs | P2 | ✅ Fixed (cadvisor: node label, node-exporter: node_uname_info join) |
| 12 | Backup cleanup runs inside backup jobs | P2 | ❌ Accepted (low risk for homelab, cleanup is fast) |
| 13 | DRY violations (security contexts, probes, annotations) | P3 | ❌ Accepted (homelab simplicity) |

#### Previous Review Findings (2026-02-20)

#### Findings Implemented

| # | Finding | Severity | Status |
|---|---------|----------|--------|
| 1 | Alertmanager `chat_id` in plain YAML | P1 | ⚠️ Accepted (no `chat_id_file` in Alertmanager, commented) |
| 2 | `StrictHostKeyChecking=no` in backup SSH | P1 | ✅ Fixed (ConfigMap known hosts, `StrictHostKeyChecking=yes`) |
| 3 | PVC backup `hostNetwork: true` unnecessary | P1 | ✅ Fixed (removed) |
| 5 | Duplicated Prometheus metric relabelings | P2 | ✅ Documented (now VictoriaMetrics relabelConfigs) |
| 6 | Redis `readOnlyRootFilesystem: false` | P2 | ✅ Fixed (enabled + emptyDir /tmp) |
| 7 | Alertmanager `group_interval: 10s` too aggressive | P2 | ✅ Fixed (10s → 5m) |
| 8 | Telegram truncation missing count | P2 | ✅ Fixed (shows hidden alert count) |
| 9 | CF tunnel YAML parser fragile | P2 | ⏸️ Deferred (add validation later) |
| 10 | PG instance count discrepancy in docs | P2 | ✅ Fixed (3 → 2) |
| 11 | MySQL buffer pool discrepancy in docs | P2 | ✅ Verified (changelog entries correct) |
| 12 | PVC backup `cd` mid-script | P3 | ✅ Fixed (subshell) |
| 13 | Loki chart stale pin comment | P3 | ✅ Fixed (updated comment) |
| 14 | Meilisearch `readOnlyRootFilesystem` | P3 | ✅ Fixed (enabled + emptyDir /tmp) |
| 15 | Backup `successfulJobsHistoryLimit` | P3 | ❌ Declined (history useful for debugging) |
| 16 | Renovate groups all Helm charts | P3 | ✅ Fixed (removed catch-all group) |

### ✅ Completed P0-CRITICAL Items (Summary)

| Item | Date | Commit | Notes |
|------|------|--------|-------|
| PostgreSQL NetworkPolicy | 2025-10-27 | a80d4bf | Restricts DB access to app namespaces |
| cert-manager ClusterIssuers | 2025-10-27 | 2cb9e78 | Removed duplicate, kept single source |
| CNPG WAL Archiving | N/A | - | ❌ Not implementing (pg_dump acceptable) |

### SECURITY HARDENING (Active)

#### ✅ **Node-Level Hardening** - COMPLETED (2026-02-12)
   - **SSH**: Post-quantum kex (mlkem768x25519-sha256), strong ciphers only (chacha20-poly1305, aes256-gcm, aes128-gcm), ETM MACs only, ed25519/rsa-sha2 host keys
   - **Kernel sysctls**: `secure_redirects=0` (prevent MITM), `log_martians=1` (detect spoofing), `unprivileged_bpf_disabled=1` (block unprivileged BPF)
   - **Kubelet**: `streamingConnectionIdleTimeout=5m` (was 4h default, CIS benchmark)
   - **K3s Secrets-at-Rest**: AES-CBC encryption enabled on control-plane (`k3s secrets-encrypt rotate-keys`)
   - **Coverage**: All 3 nodes (SSH, kernel, kubelet), control-plane (secrets encryption)
   - **Scripts**: `docs/scripts/setup-node.sh` (all hardening), `/tmp/harden-node.sh` (applied to existing nodes)
   - **Commits**: b9211fc0, ec68a7c7, b563df44

#### ✅ **HSTS Max-Age Optimization** - COMPLETED (2026-01-09)
   - **Final**: `max-age=31536000` (1 year) on all 17 ingresses
   - **Gradual Rollout**: ✅ Step 1 (1mo) → ✅ Step 2 (6mo) → ✅ Step 3 (1yr)
   - **Commits**: 5e109cd, 793a247

#### ✅ **Secrets Audit** - PASSED (2026-02-20)
   - **Scope**: Full repository scan - 51 Secret YAML files, all scripts, docs, and configs
   - **Result**: No plaintext secrets found in git-tracked files
   - **SOPS**: All 51 Secret files encrypted with AES256-GCM/age
   - **Scripts**: Use `kubectl get` / placeholders only, no hardcoded values
   - **Gitignore**: `.backup/`, `*.agekey`, `*.key`, `*.pem`, `.env` all excluded
   - **No history rewrite needed**

#### ✅ CSP Enforcement - COMPLETED (2025-10-31)
   - 43 days in production, zero violations, 85 automated tests passed

---

### ⚠️ P1-HIGH (Active Items Only)

#### ✅ **Migrate Promtail to Grafana Alloy** - COMPLETED (2026-02-07)
   - **Status**: ✅ COMPLETED - Alloy v1.12.1 (chart 1.5.1) deployed, Promtail removed
   - **Priority**: ~~P1-HIGH~~ COMPLETED (24 days ahead of EOL deadline)
   - **Details**: Grafana Alloy DaemonSet on all 3 nodes, `loki.source.kubernetes` for K8s API-based log tailing
   - **Labels**: namespace, pod, container, node_name, app (same as Promtail)
   - **Alerts**: AlloyDown, AlloyLogDeliveryFailing (replaced PromtailDown, PromtailTargetsMissing)
   - **Dashboard**: Updated to show Alloy metrics and pod selectors
   - **Commits**: 70371693, 4c6e8b27, 3d710ff7, 216f317e

#### ✅ **Automated Backup Validation Testing** - COMPLETED (2026-02-06)
   - Daily automated validation: SHA256 checksum, tar integrity, size thresholds, age checks
   - Telegram daily report with per-backup status (pass/fail per type)
   - Integrated into backup-replication CronJob (Step 4, before source cleanup)
   - Checks: PostgreSQL >1MB, CouchDB >100KB, MySQL >100KB, PVC >100KB, age <25h

#### ✅ **Kyverno Phase 3: Resource Limits** - COMPLETED (2025-12-18)
   - **0 violations** as of 2025-12-18 (was 22 on 2025-12-17)
   - Fixed by adding resource limits to Percona MySQL operator HelmRelease
   - All non-system pods now have resource limits
   - Commits: f67f9ba (operator limits), 5e28d3e (original fix)

### ✅ Completed P1-HIGH Items (Summary)

| Item | Date | Status | Commits |
|------|------|--------|---------|
| Pod Anti-Affinity PostgreSQL | 2025-10-29 | ✅ 2 instances, required anti-affinity | cbc71d0 |
| CNPG Port 8000 Binding | 2025-10-30 | ✅ Resolved - worker-node only | [#9013](https://github.com/cloudnative-pg/cloudnative-pg/issues/9013) |
| PostgreSQL TLS | 2025-10-27 | ✅ Already implemented | - |
| Redis Backup | - | ❌ Not implementing (cache only) | - |
| Flux Timeout Standardization | 2025-10-27 | ✅ All 6 kustomizations 45s | 4cc2834 |
| Traefik Health Checks | 2025-10-27 | ✅ 15/15 apps compliant | - |
| HA Critical Components | 2025-10-29 | ✅ 2 replicas across nodes | e07474a |
| Scattered Middleware | 2025-10-27 | ✅ Centralized to traefik ns | 9a9ebce |
| Redis ACLs | 2025-10-27 | ⚠️ Accepted (apps don't support prefixes) | - |
| Kyverno Phase 1 (Service Accounts) | 2025-10-28 | ✅ Enforce mode, 31 pods | 584d3a1 |
| Kyverno Phase 2 (Seccomp) | 2025-10-28 | ✅ Enforce mode, 23 workloads | 8eaf7ea |

---

### P2-MEDIUM (Active Items Only)

| Pending Item | Effort | Priority |
|--------------|--------|----------|
| ~~Deploy Velero for cluster backups~~ | ~~4-6h~~ | ❌ Declined |
| ~~Implement backup immutability (S3 object lock/ZFS)~~ | ~~2-4h~~ | ❌ Declined |
| ~~SOPS multi-key encryption~~ | ~~4h~~ | ❌ Declined |

**Velero - DECLINED** (2026-02-06): Flux GitOps already reconstructs all cluster state (RBAC, CRDs, ConfigMaps, namespaces) from Git. Databases have dedicated daily backups with SHA256 validation. PVCs have daily backups. Velero would only help with non-Git stateful resources, which are all already covered. Not worth the operational overhead for a homelab.

**Backup Immutability - DECLINED** (2026-02-06): NAS rsync daemon runs without `--delete`, making backups append-only by design. Remote deletion not possible via rsync protocol. NAS web UI is the only way to delete, requiring physical network access + credentials. For a homelab on a local network, the risk of backup tampering is negligible. S3 object lock would require cloud storage; ZFS would require NAS OS changes (not supported on Zettlab).

**SOPS Multi-Key - DECLINED** (2026-02-06): Multi-key is for team environments where multiple people need independent decryption (e.g., separate keys for CI/CD, teammates). Single operator with one age key stored in 1Password. No CI/CD pipeline needing its own key. Adding complexity for no benefit.

#### **ReadOnlyRootFilesystem Security Hardening** (P2-MEDIUM) - PHASE 1-3 COMPLETE ✅

**Investigation Date**: 2025-12-18
**Implementation Date**: 2025-12-18 (Phase 1+2), 2025-12-23 (Phase 3)
**Current State**: 15/16 apps have readOnlyRootFilesystem enabled (was 3, +12 containers hardened)
**Goal**: Maximize containers with read-only root filesystems to reduce attack surface

##### ✅ **Tier 1: COMPLETED** (2025-12-18)

| App | Container | Status | Commit |
|-----|-----------|--------|--------|
| **paperless-ngx** | main | ✅ Enabled | e1d5e5b |
| **authentik-server** | server | ✅ Enabled | 3c1fddb |
| **authentik-worker** | worker | ✅ Enabled | 5213a69 |

##### ✅ **Tier 2: COMPLETED** (2025-12-18)

| App | Container | Changes | Commit |
|-----|-----------|---------|--------|
| **csp-reporter** | main | Added /tmp emptyDir, full security hardening | 48ba5fc |
| **homepage** | main | Added /tmp emptyDir, automountServiceAccountToken: false | 9e04864 |
| **homehub** | main | Added /tmp emptyDir | d8da2a0 |
| **uptime-kuma** | main | Added /tmp emptyDir, runAsNonRoot to pod spec | 2034718 |

**Verification**: All 7 apps restarted, init containers tested, setup jobs re-run, CSP reports confirmed working

##### ✅ **Tier 3: COMPLETED** (2025-12-23)

| App | Container | Changes | Commit |
|-----|-----------|---------|--------|
| **linkwarden** | main | Already had emptyDirs for /tmp, /app/.next/cache, /home/node/.cache | 3d4d533 |
| **immich-ml** | main | Added /tmp emptyDir via persistence section | 3d4d533 |
| ~~**immich-proxy**~~ | ~~nginx~~ | ~~Removed 2026-03-15 (sidecar was unnecessary)~~ | 7d377a9a |

**Verification**: All 3 apps tested - linkwarden SSO works, immich API responds

##### ❌ **Tier 4: Not Feasible**

| App | Reason | Mitigation |
|-----|--------|------------|
| **pricebuddy** (scraper) | Selenium writes browser data in many locations | Container isolation, NetworkPolicy |
| **pricebuddy** (apprise) | Runs as root, writes to /config | emptyDir already used, root required |
| **stirling-pdf** | Comment: "needs to write temp files and modify system configs" | Has many emptyDir, needs root for nginx/PDF processing |
| **adguard-home** | Runs as root for port 53, writes to multiple locations | Container isolation, PVC for data |
| **home-assistant** | Runs as root, writes plugins/states/custom components everywhere | Official limitation, many capabilities required |
| **immich-server** | Runs as privileged for GPU transcoding | Required for VAAPI hardware acceleration |
| **grafana** | Helm chart complexity, multiple sidecars | Would require extensive chart customization |

##### **Implementation Summary**

**Phase 1** (Tier 1 - Zero Risk): ✅ **COMPLETED 2025-12-18**
- Enabled on paperless-ngx, authentik-server, authentik-worker
- Commits: e1d5e5b, 3c1fddb, 5213a69

**Phase 2** (Tier 2 - Low Risk): ✅ **COMPLETED 2025-12-18**
- Added /tmp emptyDir to csp-reporter, homepage, homehub, uptime-kuma
- Commits: 48ba5fc, 9e04864, d8da2a0, 2034718

**Phase 3** (Tier 3 - Medium Risk): ✅ **COMPLETED 2025-12-23**
- Enabled on linkwarden, immich-ml (immich-proxy removed 2026-03-15)
- Key finding: Immich HOST env var bug - nginx proxy sidecar required
- Key finding: bjw-s chart advancedMounts doesn't work - used postRenderer instead
- Commits: 3d4d533

**Outcome**: 13 containers with readOnlyRootFilesystem (was 3, +10 hardened)
**Security Benefit**: Reduced attack surface, prevents runtime filesystem tampering

### ✅ Completed P2-MEDIUM Items (Summary)

| Item | Date | Status |
|------|------|--------|
| PVC storageClassName + alert hardcoded IPs | 2026-03-07 | ✅ 9 PVCs fixed, immich typo fixed, CPUThrottlingHigh/NodeMemoryMajorPagesFaults use hostnames |
| ReadOnlyRootFilesystem Phase 1-3 | 2025-12-23 | ✅ 9 apps hardened (paperless, authentik×2, csp-reporter, homepage, homehub, uptime-kuma, linkwarden, immich-ml; immich-proxy removed 2026-03-15) |
| Backup Integrity Checks (SHA256) | 2025-10-31 | ✅ All backups generate checksums |
| GPG Secrets Encryption | 2025-10-31 | ✅ AES256 with interactive passphrase |
| Rate Limiting Middleware | 2025-10-31 | ✅ 100% coverage (17 ingresses) |
| Security Headers | 2025-10-31 | ✅ 100% coverage (HSTS, CSP, etc.) |
| PgBouncer Pooler | 2025-10-31 | ✅ All apps using pooler correctly |
| CREATEDB Permissions | 2025-10-31 | ✅ Accepted (required for migrations) |
| Single Redis/CouchDB | 2025-10-31 | ✅ Documented as intentional |
| LoadBalancer Docs | 2025-10-29 | ✅ K3s ServiceLB documented |
| Cloudflare Health Checks | 2025-10-31 | ✅ Already configured |
| NetworkPolicy Egress | 2025-11-02 | ✅ Validated as correct |
| Prometheus Resource Alerts | 2025-10-31 | ✅ 5 new alerts added |

---

### P3-LOW (Active Items Only)

| Pending Item | Priority | Status |
|--------------|----------|--------|
| ~~Re-evaluate VictoriaMetrics~~ | ~~P3~~ | ✅ Completed (2026-04-09, 71% RAM savings) |
| n8n PgBouncer `statement_timeout` re-check | P3 | ⏸️ May 2026 |
| ~~Prometheus/Alertmanager config-reloader resource limits~~ | ~~P3~~ | ❌ Won't do (chart-managed sidecars, <10Mi RAM) |
| ~~Backup alert grouping to Telegram thread~~ | ~~P3~~ | ❌ Won't do (~1 alert/month, not worth complexity) |
| ~~Grafana dashboards for app metrics~~ | ~~P3~~ | ❌ Won't do (apps don't expose custom metrics) |
| ~~PrometheusRules for custom app metrics~~ | ~~P3~~ | ❌ Won't do (no custom app metrics exist) |

### ✅ Completed P3-LOW Items (Summary)

| Item | Date | Status |
|------|------|--------|
| PVC Backup Retention (7 days) | 2025-10-31 | ✅ Increased from 3 to 7 days |
| Secrets Rotation Docs | 2025-10-31 | ✅ Complete tracking in SECRETS_ROTATION.md |
| SSH Key Backup Location | 2025-10-31 | ✅ Documented (1Password) |
| Resource Quotas | 2025-10-31 | ✅ 25 quotas deployed |
| LimitRanges | 2025-10-31 | ✅ 25 LimitRanges deployed |

---

### DEFERRED TASKS (February 2026)

#### 37. **Offsite Backup Replication to NAS** ✅ COMPLETED
   - **Status**: ✅ COMPLETED - NAS replication fully operational (2026-02-06)
   - **Priority**: ~~P0-CRITICAL~~ COMPLETED
   - **Hardware**: Zettlab 6 Ultra (14TB usable)
   - **Constraint**: Runs its own OS, Docker only (no K8s), **no SSH access**
   - **NAS Storage Limit**: **500GB** allocated for homelab backups (current usage: 2.6GB)
   - **Current RPO**: 24 hours (daily replication at 3:30 AM)
   - **Current RTO**: ~30 minutes (restore from NAS or worker-node-2)
   - **Replication Strategy**: NAS is primary backup store, worker-node-2 is temporary safety net
     - Worker-1: creates backups → syncs to NAS + worker-2 → cleaned after replication
     - NAS: accumulates full backup history (no `--delete`, ~190 days at 2.6GB/day)
     - Worker-2: mirrors source with `--delete` (today's backup only, temporary until ~May 20, 2026)
     - NAS connection: rsync daemon protocol, port 50555, SOPS secret (`nas-rsync-credentials`)
     - NAS limitation: module root is read-only, writes go to `backups/homelab/` subfolder
     - **500GB hard limit**: NAS storage allocation, manual pruning via NAS web UI when needed
     - **Alerts**: 400GB warning, 450GB critical (in job logs)
   - **Action**:
     1. ✅ NAS hardware arrived and initial setup (2026-02-05)
     2. ✅ Configure NAS on local network (IP: 192.168.1.136, rsync port 50555)
     3. ✅ Create SOPS-encrypted secret for rsync user/password
     4. ✅ Configure backup replication CronJob (daily at 3:30 AM, rsync daemon protocol)
     5. ✅ Test backup replication (2.6GB transferred, sizes verified)
     6. ✅ Update disaster recovery documentation (README.md, BACKUP_STRATEGY.md, secrets scripts)
   - **TODO**: Remove worker-node-2 replication after extended safety period (~May 20, 2026)
   - **Files**: `infrastructure/configs/staging/backup-replication/` (cronjob.yaml, nas-rsync-secret.yaml)
   - **Benefit**: Protects against node hardware failure (NAS = full history, worker-node-2 = today's safety net)

#### 38. **Second Worker Node** ✅ COMPLETED
   - **Status**: ✅ DEPLOYED - 2025-12-15 (ahead of schedule!)
   - **Priority**: ~~P1-HIGH~~ COMPLETED
   - **Node Details**:
     - **Hostname**: worker-node-2 (192.168.1.126)
     - **User**: z3us
     - **Hardware**: 30GB RAM, 1TB NVMe (system) + 3.6TB NVMe (k8s-storage)
     - **Kernel**: 6.18.16-1-lts
     - **K3s**: v1.35.3+k3s1
   - **Storage**: 3.6TB LVM (`k8s-storage` VG) - 1% used
   - **Current Workloads** (31 pods):
     - PostgreSQL replica (main-postgres-11)
     - CouchDB replica (couchdb-couchdb-0)
     - MySQL replica (main-mysql-mysql-0) + HAProxy + Orchestrator
     - Promtail, Loki canary, system pods
   - **Swap**: ✅ 16GB LVM swap configured (2025-12-18)
   - **LVM Resize** (2025-12-18):
     - Root: 20GB → 50GB (21% used)
     - Home: 932GB → 10GB
     - Swap: 16GB (new LV)
     - Extra: 863GB at /mnt/extra-storage
   - **Remaining Tasks**: ✅ All completed (2025-12-18)
     - ✅ **Monitoring HA enabled** - Alertmanager 2 replicas with anti-affinity (Prometheus replaced by VictoriaMetrics 2026-04-09)
     - ✅ **Uptime Kuma monitors** - Already configured (SSH + kubelet monitors)
     - ✅ **AdGuard Home DNS** - Added 192.168.1.126 to DNS rewrites
   - **Documentation**: SECOND_WORKER_NODE_SETUP.md (archived, see git history)

#### 39. **Switch to LTS Kernel 6.18** ✅ COMPLETED
   - **Status**: ✅ COMPLETED - 2026-03-06
   - **Priority**: ~~P2-MEDIUM~~ COMPLETED
   - **Result**: All 3 nodes switched from mainline `linux` (6.19.6) to `linux-lts` (6.18.16)
   - **K3s**: Upgraded v1.35.1 → v1.35.3 simultaneously
   - **Procedure Used**: Two-phase approach (install LTS → reboot → verify → remove mainline)
   - **Boot Entries**: systemd-boot entries created from existing ones, fallback initramfs enabled
   - **Benefit**: Long-term stability, security backports until Dec 2027

#### 40. **VictoriaMetrics Migration** ✅ COMPLETED
   - **Status**: ✅ COMPLETED - 2026-04-09
   - **Priority**: ~~P3-LOW~~ COMPLETED
   - **Result**: Prometheus server replaced by VictoriaMetrics (VMSingle + VMAgent + VMAlert)
   - **RAM Savings**: 71% (~1,553Mi Prometheus HA → ~487Mi VMSingle+VMAgent+VMOperator)
   - **Series**: ~113k active series
   - **Stack**: VMSingle (storage), VMAgent (scraping), VMAlert (alerting rules), VMOperator, Alertmanager (notifications), Grafana (dashboards), kube-state-metrics, node-exporter
   - **kube-prometheus-stack**: Still deployed with `prometheus.enabled: false` and `defaultRules.create: false` (provides Alertmanager, Grafana, kube-state-metrics, node-exporter)
   - **Background**:
     - First attempt 2025-11-15, aborted due to `metricRelabelConfigs` bug ([#9951](https://github.com/VictoriaMetrics/VictoriaMetrics/issues/9951))
     - Workaround confirmed: Use BOTH `relabelConfig` + `metricRelabelConfig` together
     - Successfully migrated April 2026

---


---

## CHANGELOG (Recent)

*For older entries, see [HOMELAB_HISTORY.md](./HOMELAB_HISTORY.md)*

### 2026-07-04 (Codex CLI wired into claude-telegram bot)
- ✅ **Codex review gate now works from the TG bot** — bot pod previously had no `codex` binary, so the CLAUDE.md pre-commit review gate was mac-only.
  - Image `1.27.7` (fork `ad29203`): `npm install -g @openai/codex@0.142.5` baked in — linux platform dep is codex's static musl binary (alpine-safe), lands in `/usr/bin` outside the PVC shadow; `codex --version` build-time smoke.
  - Init container: writes `~/.codex/config.toml` every start (gpt-5.5 / xhigh / `sandbox_mode = "danger-full-access"` / homelab dir trusted — drift-heals, mirrors mac). Sandbox mode required: pod RuntimeDefault seccomp blocks unprivileged userns → codex's bwrap sandbox can't start (verified in-pod); pod confinement (non-root, RO rootfs, caps dropped, egress-restricted) is the sandbox.
  - Auth = **ChatGPT-plan tokens** (£20 subscription, like Claude's OAuth token — user decision after API-key detour hit zero-credit quota wall): `auth.json` copied from mac into SOPS secret `claude-telegram-codex`, init seeds PVC ONLY-if-absent (codex refreshes tokens in place; re-seeding stale snapshot would clobber). Auth dies later → re-copy mac auth.json to secret, rm PVC copy, restart. API-key path removed (bare `OPENAI_API_KEY` env not honored by codex 0.142.x anyway — verified; `--with-api-key` login worked but stayed unused). Restart TG message now reports Codex version.
  - NetworkPolicy unchanged (443 egress to non-RFC1918 already covers OpenAI).
  - Codex static review (gate): 1 MEDIUM — `| tail -1` after `codex login` masked failure under `set -e` (no pipefail); fixed via capture-to-file + last-line-on-failure-only.

### 2026-06-04 (Configs base/staging flatten)
- ✅ **Flattened the last two `base/staging` overlay splits** — `monitoring/configs/{base,staging}` → `monitoring/configs/` (`081934c0`) + `infrastructure/configs/{base,staging}` → `infrastructure/configs/` (`87deba9e`). Completes the base/overlay collapse program (F-13 apps, F-14 controllers). No base/staging splits remain repo-wide.
  - **Proof:** `kustomize build --enable-helm` render byte-identical pre/post both sides (oracle diff empty — 63 mon / 133 infra resources). Flux re-adopted every object by unchanged name/ns/GVK → zero churn (CNPG/Percona/CouchDB + cloudflared + grafana/vmsingle pod ages unchanged).
  - Flux paths repointed (`monitoring-configs`, `infrastructure-configs` → `./…/configs`); CI kustomize roots + `kyverno_count` find path updated.
  - **Tier-1 cleanups (render-neutral):** dropped redundant `namespace:` transforms on merged `kube-prometheus-stack` (a blanket transform would have corrupted `cloudflared-servicemonitor` → `cloudflare-tunnel`) + `databases/couchdb`; deleted dead `infrastructure/configs/base/resource-governance/` (4 files, no kustomization, unreferenced).
  - **Gotcha:** `mysql/serviceaccount.yaml` collided between base (`main-mysql` cluster SA) and staging (`mysql-jobs` backup SA) when merged into one dir → renamed staging's to `jobs-serviceaccount.yaml` (object name unchanged → render identical; `mysql-backup-cronjob` references the object name, not the filename).
  - Single atomic commit per side + race-safe reconcile (`source git flux-system` → `ks flux-system` → target ks) avoided the path-not-found transient alert. CI green both commits.
  - **Tier-2 follow-ups** (`637c6bdd`, render byte-identical, zero churn): evicted the lone `cloudflared` ServiceMonitor out of `kube-prometheus-stack/` into its own `monitoring/configs/cloudflared/` dir (it targets `cloudflare-tunnel` ns, the only non-KPS object there); dropped the now-redundant `namespace: monitoring` transform from `victoria-metrics/` (all 19 resources self-ns). Investigated a `kube-prometheus-stack/` rename — **declined**: post-eviction the dir is 14 cohesive KPS-stack config objects and the name deliberately parallels `monitoring/controllers/kube-prometheus-stack/` (a gratuitous rename = churn). VMAgent scrape-discovery is `serviceScrapeSelector: {}` (all ServiceMonitors), not the `release` label.
  - **Reframe:** corrected the long-standing misnomer — this is single-env **production**, not "staging" (merge to `main` = deploy to prod). Fixed `CLAUDE.md`, `HOMELAB_ANALYSIS.md`, `ARCHITECTURE.md`, `review-invariants.md` (which also still asserted the now-collapsed apps base/overlay split was the norm).

### 2026-03-16 (SearXNG Deployment)
- ✅ **SearXNG deployed**: Privacy-respecting metasearch engine ⭐
  - Image: `searxng/searxng:2026.3.13-3c1f68c59`
  - Internal: `search.h0melab.work` via Traefik (no auth)
  - External: Cloudflare Tunnel with Authentik SSO
  - JSON API: `/search?q=...&format=json` for n8n/HA automations
  - Security: restricted PSS, readOnlyRootFilesystem, drop ALL
  - NetworkPolicy: dual-access + n8n/HA API consumer rules
  - Renovate: custom regex manager for date+hash image tags
- ✅ **Authentik ↔ Cloudflare Access IdP integration** ⭐
  - Authentik configured as OpenID Connect identity provider in CF Zero Trust
  - Reusable for any future CF Access-protected app
- ✅ **cert-manager NetworkPolicy fix**: Added external DNS egress (UDP/TCP 53) for DNS-01 challenges
- ✅ **`.gitignore` fix**: Added `!secret.yaml` override for SOPS-encrypted secrets (was blocked by global gitignore)

### 2026-03-15 (Remove Immich Nginx Proxy Sidecar)
- ✅ **Nginx proxy sidecar removed from Immich** — unnecessary since v1.88.0 (Nov 2023) ⭐
  - **Root cause**: Sidecar was added due to misleading NestJS log (`[::1]:2283`), but server actually binds to `::` (all interfaces)
  - **Evidence**: `/proc/net/tcp6` confirmed `:::2283 LISTEN`, `wget` to pod IP returned `{"res":"pong"}`
  - **Source code**: `app.listen(port)` without host → INADDR_ANY. `IMMICH_HOST` unset = all interfaces.
  - **Official Helm chart**: No proxy since v1.88.0, targets port 2283 directly
  - **Resources freed**: 50m→500m CPU, 64Mi→256Mi RAM (nginx:1.29.6-alpine container)
  - Pod: 2/2 → 1/1 containers
- ✅ **NetworkPolicy port updates**: Traefik + Cloudflare tunnel egress policies 8080→2283
  - Same class of bug as March 11 audit — port change requires updating ALL source egress policies
- ✅ **Cloudflare tunnel config synced**: SOPS secret updated, init container PUT to CF API (HTTP 200)
- ✅ **Docs updated**: port-forward commands, HOMELAB_ANALYSIS CF tunnel section
- ℹ️ **Gotcha**: Immutable Job spec blocked Flux reconciliation — had to delete completed `immich-admin-setup` Job before Flux could apply new port
- 📋 **Commits**: 7d377a9a, c1f212f7

### 2026-03-11 (NetworkPolicy K8s API Egress Audit)
- ✅ **Loki crash-loop fixed**: `loki-sc-rules` sidecar (kiwigrid/k8s-sidecar) couldn't reach K8s API ⭐
  - Root cause: loki NetworkPolicy (added Jan 9) missing K8s API egress (192.168.1.127:6443)
  - Went undetected because pod wasn't restarted since before policy was applied
  - Exposed by Renovate Loki chart update to v6.54.0 which recreated the pod
- ✅ **Traefik NetworkPolicy fixed**: Missing K8s API egress (ticking time bomb) ⭐
  - Traefik was working via stale HTTP/2 watch connections from startup race window
  - `wget` from inside pod confirmed "Connection refused" on 10.43.0.1:443
  - If API watch dropped (API restart, network hiccup), ALL routing would break
- ✅ **Homepage NetworkPolicy fixed**: Removed stale `component: apiserver` pod selector ⭐
  - Old rule had `port: 443` to `namespaceSelector: {}` — doesn't match after kube-proxy DNAT (port becomes 6443)
  - Replaced with explicit `192.168.1.127:6443` rule
- ✅ **Full audit**: 40 NetworkPolicies across all namespaces checked, all other policies confirmed correct
  - cert-manager, kyverno, percona-mysql, databases, monitoring, flux-system — all have proper API egress
- ℹ️ **Key learning**: Existing TCP connections survive NetworkPolicy changes (conntrack ESTABLISHED). Always restart pods after adding/modifying NetworkPolicies to verify.
- 📋 **Commits**: acea8f23, e84b2705

### 2026-03-09 (Comprehensive Node Audit & Hardening)
- ✅ **Full Arch Linux audit across all 3 nodes** — 18 findings identified and fixed ⭐
- ✅ **Unified setup-node.sh**: Single script replaces per-node scripts (auto-detects CP/worker, Intel/AMD)
  - Added: smartmontools, inetutils, journald config, PermitEmptyPasswords, amd_pstate boot param
  - Added: SSD/NVMe power saving disabled (APST, ASPM, ALPM)
  - Added: Watchdog config (softlockup_panic, hardlockup_panic)
  - Added: K3s ExecStartPost for network hardening re-apply
  - Cleaned: Old cpu-governor.conf, 51-kptr-restrict.conf, 99-security-hardening.conf
- ✅ **Sysctl hardening fix**: secure_redirects=0 added to unified-hardening.conf (was missing after old file removal)
- ✅ **K3s ExecStartPost**: log_martians + secure_redirects re-applied after flannel/cni interface creation
  - Root cause: systemd-sysctl runs before K3s, new interfaces reset network sysctls
- ✅ **Worker-node-2 fixes**: hostname (worker-node2→worker-node-2), pacman (ParallelDownloads 10), fstab (noatime)
- ✅ **Worker-node fixes**: networkd-wait-online interface (enp3s0→enp4s0), stale tmpfiles cleanup
- ✅ **Control-plane fixes**: stale 51-kptr-restrict.conf removed, cpu tmpfiles renamed
- ✅ **Rolling reboot**: W2 → W1 → CP, all verified post-reboot
- ✅ **Cluster health**: 3/3 nodes Ready, 81 running pods, 0 alerts, 0 stale RS after cleanup

### 2026-03-07 (March 2026 Code Review - 94/100, A)
- **Full Codebase Review**: Score improved 93/100 -> 94/100 (+1 point) via 6 parallel agents
- **NetworkPolicy**: Added for cert-manager, kyverno, percona-mysql, backup-replication (4 namespaces)
  - Key learning: K3s API server connects to webhooks via pod CIDR (10.42.0.0/16), not node IPs
  - Container ports (kyverno 9443, cert-manager 10250), NOT Service ports (443)
- **Alertmanager**: Added inhibit rules to suppress alert storms during node outages
  - NodeDown suppresses warning/info severity alerts on same instance
  - Critical severity suppresses warning for same namespace/alertname
  - InfoInhibitor suppresses info severity
- **Alertmanager**: Removed duplicate AlertmanagerNotificationsFailing (kept percentage-based AlertmanagerFailedToSendAlerts)
- **Flux**: Added healthChecks to infrastructure-controllers (cert-manager-webhook, kyverno-admission-controller)
- **Flux**: Increased infrastructure-controllers timeout 45s -> 5m (webhook startup tolerance)
- **Flux**: Removed force: true from apps Kustomization (prevents operator field conflicts)
- **Helm**: Pinned cert-manager chart 1.19.x -> 1.19.4 (prevent silent drift, enable Renovate tracking)
- **Helm**: Standardized Percona HelmRepository interval 24h -> 6h (consistent with all other repos)
- **Security**: Documented Homepage ClusterRole secrets access as accepted risk
- **Findings**: 8 P1, 12 P2, 10 P3 - all P1 fixed, 2 P2 fixed, 2 P2 accepted/won't do, rest deferred
- **P2 Fixes**:
  - 9 PVCs missing `storageClassName: local-path` (pricebuddy, adguard, paperless, uptime-kuma, mealie, audiobookshelf×4) + immich `storageClass`→`storageClassName` typo
  - CPUThrottlingHigh: replaced hardcoded IPs with `node` label filter (`node!~"worker-node|worker-node-2"`)
  - NodeMemoryMajorPagesFaults: replaced hardcoded IPs with `node_uname_info` hostname join
  - runbook_url: won't do (no runbooks exist); backup cleanup: accepted (low risk)
- Commits: cd27a2e9, 21cb1e48

### 2026-03-06 (LTS Kernel + K3s Upgrade)
- ✅ **Kernel: mainline 6.19.6 → LTS 6.18.16** on all 3 nodes ⭐
  - Two-phase approach: install LTS alongside mainline → reboot → verify → remove mainline
  - Rolling order: worker-node-2 → worker-node → control-plane
  - Fallback initramfs enabled on all nodes (mkinitcpio preset updated)
  - Boot entries created from existing ones (preserves per-node kernel params)
  - Mainline `linux` package fully removed after LTS confirmed working
  - Benefit: LTS stability, security backports until Dec 2027
- ✅ **K3s: v1.35.1 → v1.35.3** on all 3 nodes ⭐
  - Control-plane upgraded first (API server before agents)
  - Agent upgrade script auto-reads URL/token from service env file
- ✅ **All pods healthy, 0 alerts firing after upgrade**

### 2026-02-28 (Traefik Alert Fixes)
- ✅ **Fixed all Traefik & rate-limit alerts using wrong `service` label** ⭐
  - **Root cause**: Prometheus renames app-exported `service` label to `exported_service` (collision with scrape target label). All alerts used `service` (always `traefik-metrics`) instead of `exported_service` (actual backend name)
  - **Impact**: TraefikHighLatency showed generic "traefik-metrics" instead of backend name; 6 rate-limit alerts could **never match** specific services (Authentik, CouchDB, N8N, Immich)
  - **Fixed alerts (8)**: TraefikHighLatency, TraefikHighErrorRate, RateLimitHighRejectionRate, RateLimitPossibleBruteForce, RateLimitCouchDBSyncBlocked, RateLimitAPIClientsBlocked, RateLimitPersistentRejections, RateLimitSuddenSpike
  - **WebSocket exclusion**: TraefikHighLatency now filters `code=~"[1-5].."` (excludes code=0 WebSocket connections which are long-lived by design)
  - **Removed dead alert**: TraefikBackendDown (`traefik_service_server_up` metric not exposed by Traefik)
  - **Alert trigger**: CouchDB Obsidian long-poll (`_changes` feed) + transient Grafana 502s pushed p99 >2s
- ✅ **Deferred VictoriaMetrics re-evaluation**: Feb 2026 → April 2026
- 📋 **Commits**: e9881a50, 90e55ace

### 2026-02-27 (Rebuilderd Monitoring Alerts)
- ✅ **Rebuilderd monitoring via node-exporter textfile collector** ⭐
  - **Metrics**: `rebuilderd_worker_active`, `rebuilderd_builds_good_total`, `rebuilderd_builds_bad_total`, `rebuilderd_builds_total`
  - **Collection**: systemd timer every 5 minutes, parses journalctl for last hour
  - **Alerts**: `RebuilderdWorkerDown` (10m critical), `RebuilderdHighFailureRate` (>80% BAD with ≥10 builds, 30m warning)
  - **Motivation**: Worker-node crash-looped 18 hours (21,935 restarts) due to TOML config error, completely unnoticed
  - **Node-exporter**: textfile collector enabled with `DirectoryOrCreate` hostPath mount
  - **Scripts**: Metrics exporter integrated into `setup-rebuilderd-worker-*.sh` (not a separate file)
- 📋 **Commits**: 38925637

### 2026-02-26 (Kernel Update & Rebuilderd 24/7)
- ✅ **Kernel Updated**: 6.18.9-arch1-2 → **6.18.13-arch1-1** on all 3 nodes ⭐
  - Rolling reboot: worker-2 → worker-1 → control-plane
  - All nodes Ready, 0 alerts after reboot, 7 stale RS cleaned
- ✅ **Rebuilderd worker-node switched to 24/7**: Removed 09:00-23:00 schedule ⭐
  - Both workers now run 24/7 with boot timer (10 min after reboot)
  - Fixed build timeout: was default 24h (config from Aug 2025 predated change), now 48h
  - Chromium build (145.0.7632.116) timed out at 24h (84% complete, 46376/55332 steps)
- ✅ **PostgreSQL Upgrade**: 18.2 → **18.3** (CNPG rolling update, zero downtime) ⭐
  - Replica updated first, then primary in-place restart
  - Replication lag: 0 bytes after completion
- ✅ **Renovate CNPG Fix**: Added custom regex manager for `imageName` field ⭐
  - Kubernetes manager doesn't detect CRD-specific fields like CNPG's `imageName`
  - Custom regex manager now tracks `ghcr.io/cloudnative-pg/postgresql` versions
  - Future PostgreSQL updates will get proper Renovate PRs
- ✅ **Full Database Maintenance**: All 3 engines optimized ⭐
  - **PostgreSQL**: VACUUM ANALYZE + VACUUM FULL + REINDEX on all 9 databases
  - **MySQL**: ANALYZE + OPTIMIZE on all 3 databases (69 tables total)
  - **CouchDB**: Compaction on both databases (obsidian-personal 33.9%→0.7% fragmentation)
  - Authentik + Paperless rollout-restarted (stale PgBouncer connections after PG upgrade)
  - 6 stale ReplicaSets + 8 completed pods cleaned
- 📋 **Commits**: 4baebd4d, 56bd4cb7, 858447f9

### 2026-02-22 (Health Check & Cleanup)
- ✅ **Comprehensive Health Check**: All systems healthy, no critical issues ⭐
  - **K3s**: v1.35.1+k3s1 (latest stable), Kernel 6.18.13-arch1-1
  - **Pods**: 81 Running, 0 CrashLoop, 0 alerts firing (Watchdog only)
  - **Databases**: PostgreSQL 2/2 healthy, MySQL 2/2 (lag 0s), CouchDB 2/2, Redis running
  - **Prometheus**: 121k series, 941Mi/1300Mi (72%)
  - **Certificates**: All valid, closest expiry Mar 25 (adguard-home, 31 days)
  - **Backups**: All passed (SHA256 + tar + size + age), NAS + worker-node-2 replication OK
  - **Helm Charts**: All 10 at latest versions, no open Renovate PRs
  - **Kyverno**: 0 violations
- ✅ **Linkwarden Cache Path Fixed**: `/app/.next/cache` → `/data/apps/web/.next/cache` ⭐
  - App runs from `/data/apps/web/`, emptyDir was mounted at wrong path
  - Caused `ENOENT: no such file or directory, mkdir '/data/apps/web/.next/cache'` errors
- ✅ **Cleanup**: 7 stale ReplicaSets deleted, `separated/` audio processing dir removed
- ✅ **mcp-memory-service Updated**: 10.17.0 → 10.17.14 (14 patch versions)
- ✅ **Docs Updated**: K3s v1.35.0→v1.35.1, Kernel 6.18.7→6.18.9, linux-lts 6.12.68→6.12.74, Prometheus 111k→121k, Alloy v1.12.1→v1.13.0
- ⚠️ **Authentik Warning**: "No providers assigned to this outpost" every 5 min — needs admin UI config
- ℹ️ **Cosmetic Issues** (no fix needed):
  - Audiobookshelf: Internal init check logs "already has root user" every ~6 min
  - Stirling PDF: ResourceMonitor oscillates OK↔CRITICAL (Java GC CPU spikes, memory fine at 22%)
  - HA Met.no: Transient DNS errors, self-resolved
  - CF Tunnel CouchDB: Long-poll `_changes` stream cancellations (normal for Obsidian sync)

### 2026-02-21 (Rebuilderd OOM → MySQL Crash Fix)
- ✅ **Root Cause Found**: Rebuilderd DPDK build OOM killed MySQL pods on worker-node-2 ⭐
  - `lto1-ltrans` (GCC LTO linker) exceeded 18GB memory limit in nspawn container
  - Cgroup `/machine.slice/dpdk1926193.scope`: 19.5GB usage, 228,266 failed allocations
  - OOM killer triggered at 20:40:30 UTC, killing MySQL containers as collateral
  - MySQL crash-looped 6 times before stabilizing (~7 minutes recovery)
  - Percona image bump (Feb 16 commit 4a1f9110) applied opportunistically during pod recreation
- ✅ **Fix**: Reduced worker-node-2 MAX_MEMORY 18GB → 14GB ⭐
  - `MemoryMax=14G`, `MemoryHigh=13G`, `MAX_MEMORY=14G` (cgroup + nspawn)
  - Leaves ~16GB for K8s pods; large LTO builds fail inside cgroup instead of pressuring system
  - Script updated: `docs/scripts/setup-rebuilderd-worker-2.sh`
- ✅ **Bump**: Increased worker-node MAX_MEMORY 24GB → 32GB ⭐
  - 13 OOM kills in last 24h (python-triton ~40GB, openvdb ~34GB, zed ~34GB) — all contained in cgroup, no K8s impact
  - K8s actual usage: 13.5GB of 61GB total — plenty of headroom
  - `MemoryMax=32G`, `MemoryHigh=31G`, `MAX_MEMORY=32G` (cgroup + nspawn)
  - Script updated: `docs/scripts/setup-rebuilderd-worker-1.sh`
- ✅ **Swap spillover enabled**: Builds use swap instead of OOM killing ⭐
  - worker-node: `MemorySwapMax=16G` (32GB RAM + 16GB swap = 48GB effective)
  - worker-node-2: `MemorySwapMax=8G` (14GB RAM + 8GB swap = 22GB effective)
  - Leaves half of each node's swap for K8s and system use

### 2026-02-20 (Image Tag Pinning & Database Updates)
- ✅ **PostgreSQL Upgrade**: 18.1 → 18.2 (CNPG rolling update, zero downtime) ⭐
- ✅ **Redis Upgrade**: 8.2.2 → 8.6.0 (was silently drifting on floating `8-alpine` tag) ⭐
- ✅ **Floating Tags Pinned**: 15 image references across 13 files pinned to exact versions ⭐
  - `alpine:3.23` → `3.23.3` (6 refs in backup/replication jobs)
  - `busybox:1.37` → `1.37.0` (2 refs in homehub, adguard-home)
  - `node:24-alpine` → `24.13.1-alpine` (2 refs in csp-reporter, couchdb-backup)
  - `python:3.14-slim` → `3.14.3-slim` (2 refs in mealie, uptime-kuma jobs)
  - `postgres:18-alpine` → `18.2-alpine` (1 ref in postgres-backup)
  - `redis:8-alpine` → `8.6.0-alpine` (2 refs in redis statefulset)
- ✅ **Root cause**: Renovate can't track floating tags (tag name never changes → no PR created)
- ✅ **All 10 PG/Redis consumer apps** rollout-restarted and verified healthy
- ✅ **Intentionally floating**: CNPG helper images (`18-minimal-trixie`, `18-standard-trixie`) for psql jobs — no action needed
- 📋 **Commits**: 456163b0

### 2026-02-20 (February Code Review - 93/100, A)
- ✅ **Full Codebase Review**: Score improved 89/100 → 93/100 (+4 points) ⭐
- ✅ **Security**: Removed `hostNetwork: true` from PVC backup (unnecessary network access)
- ✅ **Security**: SSH host key verification hardened (ConfigMap known hosts, `StrictHostKeyChecking=yes`)
- ✅ **Security**: Redis + Meilisearch `readOnlyRootFilesystem` enabled (emptyDir /tmp)
- ✅ **Alerting**: `group_interval` 10s → 5m (prevents Telegram flood during incidents)
- ✅ **Alerting**: Truncation message now shows hidden alert count
- ✅ **Docs**: Fixed PostgreSQL instance count (3 → 2 throughout)
- ✅ **Maintenance**: PVC backup checksum uses subshell (prevents working directory leak)
- ✅ **Maintenance**: Renovate Helm catch-all group removed (per-chart PRs now)
- ✅ **Maintenance**: Loki chart pin comment updated (stale bug reference)
- ✅ **Maintenance**: Cross-reference comment for duplicated metric relabelings
- ⚠️ **Accepted**: Alertmanager `chat_id` in plain YAML (no `chat_id_file` support)
- ⏸️ **Deferred**: CF tunnel YAML parser hardening, pre-built backup image
- 📊 **Findings**: 3 P1, 8 P2, 6 P3 — 12 fixed, 2 accepted, 2 deferred, 1 declined

### 2026-02-20 (Codebase Review Fixes)
- ✅ **CouchDB Alert Namespace Fix**: Changed `namespace="couchdb"` → `namespace="databases"` in CouchDBPodNotRunning alert ⭐
  - Alert was never matching (CouchDB runs in databases namespace, not couchdb)
- ✅ **NetworkPolicy Egress Hardened**: Alloy + Popeye restricted from `0.0.0.0/0` to `192.168.1.127/32` for K8s API ⭐
  - Matches existing Grafana/Prometheus pattern
- ✅ **Homepage ALLOWED_HOSTS**: Restricted from `*` to `home.h0melab.work` (prevents host header injection)
- ✅ **MySQL Kustomization Path**: Fixed inconsistent relative path (4→3 levels, matches postgres/redis/couchdb siblings)
- ✅ **Worker-node-2 Backup**: Extended safety period to ~May 20, 2026 (was ~Feb 13)
- ✅ **Docs Cleanup**: Deleted 18 obsolete doc files (-6,164 lines)
- 📋 **Commits**: 4053675e

### 2026-02-20 (Cloudflare Tunnel GitOps Sync & Secrets Audit)
- ✅ **CF Tunnel Init Container**: Syncs Git config to CF API on every pod start ⭐
  - Shell parser extracts ingress rules from YAML, PUTs JSON to CF Tunnel Configurations API
  - Image: `curlimages/curl:8.12.1`, readOnlyRootFilesystem, runAsNonRoot, drop ALL
  - Runs as init container — sync before cloudflared starts, fails pod if sync fails
  - Workflow: Edit SOPS config → commit → push → Flux reconciles → rollout restart → synced
  - Commits: fa963b83, 257708e9
- ✅ **Secrets Audit**: Full repo scan — no plaintext secrets in git ⭐
  - 51 Secret YAML files all SOPS-encrypted (AES256-GCM/age)
  - Scripts, docs, configs — no hardcoded credentials
  - `.gitignore` properly excludes `.backup/`, keys, `.env`
  - No git history rewrite needed

### 2026-02-12 (Node Security Hardening)
- ✅ **SSH Hardening**: Post-quantum kex, strong ciphers/MACs only on all 3 nodes ⭐
  - KexAlgorithms: mlkem768x25519-sha256, curve25519-sha256
  - Ciphers: chacha20-poly1305, aes256-gcm, aes128-gcm (no CBC, no 3DES)
  - MACs: hmac-sha2-512-etm, hmac-sha2-256-etm (no MD5, no SHA1, no non-ETM)
  - HostKeyAlgorithms: ssh-ed25519, rsa-sha2-512, rsa-sha2-256 (no DSA, no ECDSA)
  - Config: `/etc/ssh/sshd_config.d/99-hardening.conf`
- ✅ **Kernel Sysctl Hardening**: Applied to all 3 nodes ⭐
  - `net.ipv4.conf.all.secure_redirects=0` (prevent MITM route injection)
  - `net.ipv4.conf.all.log_martians=1` (detect spoofed source addresses)
  - `kernel.unprivileged_bpf_disabled=1` (block unprivileged BPF access; Arch kernel has BPF_JIT_ALWAYS_ON + BPF_UNPRIV_DEFAULT_OFF compiled-in)
  - Config: `/etc/sysctl.d/99-security-hardening.conf`
- ✅ **Kubelet Streaming Timeout**: Reduced from 4h to 5m on all 3 nodes ⭐
  - CIS Kubernetes Benchmark recommendation
  - Config: `/etc/rancher/k3s/kubelet.yaml`
- ✅ **K3s Secrets-at-Rest Encryption**: AES-CBC enabled on control-plane ⭐
  - Correct procedure: `enable` → add flag → restart → `rotate-keys` → restart
  - Active key: `aescbckey-2026-02-12T22:27:05Z`
  - All existing secrets re-encrypted
  - Config flag: `secrets-encryption: true` in `/etc/rancher/k3s/config.yaml`
- ✅ **K3s Config References Updated**: `docs/setup/` configs now include kubelet-arg and secrets-encryption
- ✅ **K3s Optimization**: conntrack ExecStartPost drop-in, eviction thresholds, log rotation (earlier session)
- ✅ **Rebuilderd Fix**: Implicit config deprecation warning resolved on both nodes
- 📊 **Score**: Security 96→98/100, Overall 96→97/100
- 📋 **Commits**: 178a84ee, 39e3f14d, 052fce9a, b9211fc0, ec68a7c7, b563df44

### 2026-02-07 (Promtail → Grafana Alloy Migration)
- ✅ **Promtail Replaced with Grafana Alloy**: Full migration completed 24 days ahead of EOL deadline ⭐
  - **Chart**: grafana/alloy v1.5.1 (app v1.12.1) — replaces promtail 6.17.1 (EOL March 2, 2026)
  - **Config**: `loki.source.kubernetes` — tails logs via K8s API (no hostPath mounts needed)
  - **Labels**: namespace, pod, container, node_name, app (same enrichment as Promtail)
  - **Resources**: 50m/200m CPU, 256Mi/512Mi memory (DaemonSet, 3 pods)
  - **Metrics port**: 12345 (was 3101 for Promtail)
  - **Metric prefix**: `loki_write_*` (e.g., `loki_write_sent_bytes_total`, `loki_write_dropped_entries_total`)
- ✅ **Alerts Updated**: PromtailDown → AlloyDown, PromtailTargetsMissing → AlloyLogDeliveryFailing
- ✅ **Dashboard Updated**: All Promtail references replaced with Alloy metrics and selectors
- ✅ **NetworkPolicy Updated**: Renamed promtail-network-policy → alloy-network-policy, port 12345
- ✅ **Kyverno**: loki namespace exclusion still covers Alloy (namespace-level, no change needed)
- 📋 **Commits**: 70371693, 4c6e8b27, 3d710ff7, 216f317e

### 2026-02-07 (Helm Chart Deprecation Audit)
- ✅ **Helm Chart Deprecation Audit**: Audited all 10 HelmReleases for deprecated fields ⭐
  - **cert-manager**: `installCRDs: true` → `crds: { enabled: true, keep: true }` (deprecated since v1.15.0)
  - **Loki**: Removed deprecated `grafanaAgent: installOperator: false` from selfMonitoring
  - **Alertmanager**: Migrated `match:`/`match_re:` → `matchers:` list syntax (deprecated since v0.22+)
  - **Grafana `rbac.pspEnabled`**: Cosmetic only (PSP removed K8s 1.25+), no fix needed
- ✅ **Promtail → Alloy Migration Complete**: Promtail removed, Alloy v1.12.1 deployed ⭐
  - Grafana Alloy DaemonSet on all 3 nodes using `loki.source.kubernetes` (K8s API)
  - Labels: namespace, pod, container, node_name, app (matches Promtail)
  - NetworkPolicy, alerts, dashboard all updated
  - Commits: 70371693, 4c6e8b27, 3d710ff7, 216f317e
- ✅ **Monthly Helm Audit Checklist**: Added to review template for recurring checks

### 2026-02-07 (Monthly Review + Cleanup)
- ✅ **February Monthly Review Complete**: All systems healthy, A+ maintained ⭐
  - **Infrastructure**: All 3 nodes healthy, 81 running pods, 0 alerts firing
  - **Databases**: PostgreSQL 2/2, MySQL 2/2, CouchDB 2/2, Redis 1/1 - all healthy
  - **Prometheus**: Series 244k→111k (54% reduction), memory 87%→71% (improved)
  - **Certificates**: All valid, 36-86 days until expiration
  - **Popeye**: 86/100 (B) - mostly K3s/Percona false positives, config-reloader limits P3
- ✅ **Stale ReplicaSets Cleaned**: 87 stale RS deleted across 17 namespaces
- ✅ **Replication Order Swapped**: worker-node-2 first (SSH), NAS second (rsync daemon)
  - More reliable destination runs first, ensuring at least one copy on failure
  - Commit: 54f1e2b
- ✅ **CLAUDE.md Updated**: Fixed MySQL secret name, CouchDB namespace, added parallel tool call docs
- ✅ **Uptime Kuma**: 28 monitors verified current, NAS Zettlab monitor active
- 📋 **LTS Kernel**: Arch `linux-lts` still at 6.12.74 (not 6.18), continue waiting

### 2026-02-06 (Automated Backup Validation)
- ✅ **Automated Backup Validation**: Daily integrity checks integrated into replication CronJob ⭐
  - **Checks**: SHA256 checksum, tar integrity, minimum size thresholds, file age (<25h)
  - **Thresholds**: PostgreSQL >1MB, CouchDB >100KB, MySQL >100KB, PVC >100KB
  - **Telegram**: Failure-only notifications (silent on success)
  - **Replication trap**: Sends Telegram alert with failed step name if rsync fails
  - **Flow**: Sync worker-2 → Sync NAS → Verify NAS → Validate backups → Clean source → Check NAS storage
  - **Tested**: Corrupted backup (SHA256/tar/size FAIL), missing backup (MISSING), NAS unreachable (trap)
  - **Files**: `infrastructure/configs/staging/backup-replication/` (cronjob.yaml, backup-telegram-secret.yaml)
- ✅ **Score Update**: Overall 94→96/100 (A+), Backup/DR 95→98/100
  - P1 "Automated Backup Validation" completed (was last remaining P1)
  - 0 P0, 0 P1 active issues
- 📋 **Commits**: 7c3235e (validation + telegram), 6326b3b (failure trap), b1280e8 (failure-only notifications)

### 2026-01-09 (Comprehensive Review + HSTS Final)
- ✅ **Comprehensive Homelab Review Complete**: Staff DevOps/SRE + Software Developer perspective ⭐
  - **Infrastructure**: All 3 nodes healthy, K3s v1.35.0, Kernel 6.18.3
  - **Databases**: PostgreSQL 2/2, MySQL 2/2, CouchDB 2/2, Redis 1/1 - all healthy
  - **Monitoring**: Prometheus at 87% memory (244k series), no alerts firing
  - **Backups**: All jobs successful, replication to worker-node-2 working
  - **Security Gaps Found**: 5 namespaces missing NetworkPolicy (P2)
  - **Code Quality**: All image tags pinned, 100% security headers coverage
  - **Next Review**: 2026-02-09
- ✅ **HSTS Step 3 Complete**: Increased max-age from 6 months to 1 year ⭐
  - `max-age=31536000` (1 year) deployed on all 17 ingresses
  - Gradual rollout complete: 1mo (Oct) → 6mo (Nov) → 1yr (Jan)
  - Files: traefik + monitoring security-headers-middleware.yaml

### 2026-01-26 (Rebuilderd Config Updates)
- ✅ **Build Timeout Increased**: 24 hours → 48 hours (172800 seconds) ⭐
  - **Reason**: python-aotriton build was at 65% (106,500/163,981) when 24h timeout hit
  - **Estimate**: ~13 hours remaining, 48h provides comfortable margin
  - **Both nodes**: Timeout configured in /etc/rebuilderd-worker.conf
- ✅ **worker-node-2 Schedule Changed**: 09:00-23:00 → 24/7 ⭐
  - **Reason**: Dedicated to rebuilderd, no need for schedule
  - **Implementation**: Removed start/stop timers, boot timer starts service 10 min after reboot
  - **worker-node**: Also switched to 24/7 (2026-02-26)
- 📋 **Scripts Updated**: `setup-rebuilderd-worker-1.sh`, `setup-rebuilderd-worker-2.sh`

### 2026-01-06 (Rebuilderd Schedule Change)
- ✅ **Schedule Changed**: 24/7 → 09:00-23:00 daily (14 hours) ⭐
  - **Both nodes**: worker-node (600% CPU) and worker-node-2 (400% CPU)
  - **Rationale**: Reduce resource contention during off-hours
  - **Implementation**: Replaced boot timer with start/stop timers
  - **Graceful shutdown**: TimeoutStopSec=7200 allows current builds to complete
  - **Scripts Updated**: `setup-rebuilderd-worker-1.sh`, `setup-rebuilderd-worker-2.sh`
