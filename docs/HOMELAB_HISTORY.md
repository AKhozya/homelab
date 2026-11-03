# Homelab History

The engineering record for the cluster: review findings, incidents and finished work. It keeps the last three months of dated entries, newest first. A new entry goes at the top, and each monthly review deletes the entries older than three months. Git keeps every deleted entry, so `git log -p -- docs/HOMELAB_HISTORY.md` is the full record.

**Active status:** [HOMELAB_ANALYSIS.md](./HOMELAB_ANALYSIS.md) · **Design rationale:** [ARCHITECTURE.md](./ARCHITECTURE.md) · **Coverage:** the last three months below; the Milestones table summarises October 2025 onward.

## Milestones

| Window | Milestone |
|---|---|
| Oct 2025 | Security hardening pass — PostgreSQL NetworkPolicies, Kyverno policy phases 1–3, SOPS secret encryption, Cloudflare Tunnel, HA for critical components |
| Nov–Dec 2025 | SSO across the app fleet (Authentik OIDC), backup validation (SHA-256), monitoring HA (Prometheus/Alertmanager 2-replica) |
| Q1 2026 | Node maintenance as ansible roles, Authentik passkey-first auth, Blocky DNS migration, Redis Sentinel HA |
| Q2 2026 | DNS decoupling + coredns-ha DaemonSet, CNPG anti-flap hardening, per-app CSP rollout, Flux bootstrap flatten |
| Q3 2026 | immich-vm joins as a GPU worker, Kyverno moves to CEL ValidatingPolicies, trivy-operator becomes a monthly CronJob, ultrareview fix batches, node heal watchdogs, RustDesk and the WARP beacon |

The table summarises the months before the dated entries below.

## Changelog

### 2026-11-03 — Monthly review: Uptime Kuma had no alert channel, MySQL moves to crVersion 1.3.0, n8n drops its statement-timeout workaround

The November review ran on the evening of the weekly-style upgrade and rolling reboot (21:44–22:17 UTC, all 4 nodes, kernel `6.18.60-1-lts`, phase1 and phase2 `success`).

**Uptime Kuma had no notification channel.** On 2026-11-03, Settings → Notifications showed "Not available", so no Kuma monitor could notify anyone. The Homepage Dashboard monitor recorded failures from 2026-08-14 to 2026-11-03, and nobody acted on them. Homepage v2 checks the Host header, and only `home.h0melab.work` was allowed (fixed in `37e70d8f`). Kuma now feeds the existing alert path instead of a channel of its own (`a8ee7202`):

| Piece | What it does |
|---|---|
| `VMServiceScrape uptime-kuma` | VMAgent scrapes Kuma `/metrics` every 60s, with a Kuma API key as the basic-auth password (Kuma 2.5.9 `apiAuth`; 60 requests a minute) |
| `UptimeKumaMonitorDown` | `monitor_status == 0` for 5m. A paused monitor drops its series (`stop()` calls `prometheus.remove()`), so it never alerts |
| `UptimeKumaMetricsDown` | the scrape fails or disappears for 10m |
| Service label + NetworkPolicy | `VMServiceScrape` selects Service metadata labels; Kuma admits only VMAgent on 3001 |

An end-to-end test proved delivery. A temporary monitor at `http://127.0.0.1:9/` fired at 23:02. Alertmanager's Telegram counter went 7 → 8, and 8 → 9 when the alert resolved, with 0 failures. Kuma alerts depend on VMAlert, Alertmanager and Telegram. If that chain fails, the healthchecks.io dead-man switch (Watchdog) is the only signal; the operator confirmed its warnings arrive.

**MySQL.** The pt-heartbeat sidecar used 51.9 of 64 MiB and fired `ContainerMemoryNearLimit`; the limit is now 96 MiB (`be127a54`). `crVersion` stayed at 1.2.0 after Renovate moved the ps-operator chart to 1.3.0 on 2026-10-29, because Renovate does not edit it; it is now 1.3.0 (`b993320b`). The operator rolled HAProxy, MySQL and orchestrator, and the cluster reported `ready` at 23:17 UTC. Each roll moved the primary to worker-node-2; `db-primary-pin` moved it back to worker-node. PriceBuddy logged read-only errors for about two minutes after the first switch and recovered without a restart. After each re-pin, `MySQLReplicaExporterDown` fired. HAProxy writes its `mysql-replicas` server list when its pod starts. The re-pin swapped the roles, so that list named the new primary. Restarting the two HAProxy pods one at a time (23:32) rebuilt the list. `mysql_up` then returned to 1.

**n8n** no longer needs `DB_POSTGRESDB_STATEMENT_TIMEOUT=0` (`4ccf808f`). The 2026-07-04 crash loop ran on `@n8n/typeorm` 0.3.20-17, before n8n-io/typeorm#50. n8n 2.46.4 vendors typeorm and runs `SET statement_timeout` after connecting, which PgBouncer accepts. The pod started clean. The December review checks a month of logs for statement timeouts.

| Sweep | Result |
|---|---|
| Security scans | 0 rootkits on 4 nodes; counts unchanged from October |
| Kyverno | 12 policies, all Deny; 2667 pass, 0 fail |
| Certificates | the 2026-10-31 renewals with the rotated Cloudflare token worked: earliest expiry moved to 2026-12-16 |
| Backups | all 6 CronJobs on schedule |
| Image CVEs (fixable) | CRITICAL 84, HIGH 1382 over 79 images (October: 248 and 3522 over 84). uptime-kuma fell from 177 CRITICAL to 5 on the slim image |
| Popeye | B (89), 15 minutes after the reboot; only the known operator-Service errors |
| Stirling-PDF 3.2.2 | 30-day peak 1414 MiB of 2 GiB, no restarts; watch closed |
| k3s | no 1.38 release yet; the Dashboard-approval row stays |

**Docs, comments and skills.** Three read-only review passes found stale statements; each was checked against the repo or cluster before a fix. The repo copy says a push reaches `main` only through a PR: the ruleset has no bypass actors. Grafana keeps sqlite on an emptyDir, not a PVC. coredns-ha skips immich-vm. The CouchDB LiveSync devices log in as the admin. The CNPG operator's unread PodMonitor is off. In dotfiles: Authentik and Immich connect to Postgres directly, not through the pooler. `kyverno-policy-promotion`'s description failed YAML parsing and now parses. The `sync-agents` denylist lost 23 entries for deleted skills.

| Operator decision | Result |
|---|---|
| `gh-homelab` deploy key | yearly, like the other deploy keys: it can push branches but cannot reach `main` without a merge. Next 2027-08-03 |
| `fr` in `~/.zshrc` | not changed: it skips `coredns` and gives three Kustomizations 90s against a 2m Flux timeout. A patch is waiting for the operator |

HISTORY trimmed to entries from 2026-08-03 on; the Q3 2026 Milestones row covers the July entries that went.

### 2026-11-03 — The same three alerts came back, because the fix was never merged

This week's post-reboot review re-derived the 2026-10-31 finding below from scratch — `ContainerMemoryNearLimit` pending on `loki/alloy-9fqkd`, twice (once as the container, once as the pod cgroup), RSS 48Mi against 649Mi of cache. The diagnosis matched because the cause was unchanged: the branch holding the fix was committed and never merged, so none of it ever reached the cluster. **A fix that stops at a commit is not a fix.** `merge-worktree.sh` exits 4 from the in-cluster bot, which has no GitHub login — when it does, the compare URL it prints needs an owner to act on it, or the work is invisible a week later.

One new finding on top of that branch:

| Finding | Evidence | Fix |
|---|---|---|
| `CloudflareTunnelNoConnections` counted requests per POD. Cloudflare routes a request to one of the two `cloudflared` replicas, so a healthy replica can serve zero for hours, and a restarted one starts its counter at 0 | pending on `cloudflared-…-m5mm6` 15 min after the reboot: 0 requests, while its peer served 73 and **both** held 4 HA connections | `sum by (namespace) (increase(…[2h]))`. Proven live: per-pod returned the idle replica, the sum returned none, and `>= 0` returned the namespace at 450, so the `== 0` direction still matches. A single dead replica is `CloudflareTunnelPodNotRunning`'s job |

The description's "4 hours" against a 2h window reads like drift and is not: a 2h lookback that must hold `== 0` for a 2h `for` only fires after ~4h of silence. This review changed it to "2 hours" and then put it back, with a comment on the rule so the next reader does not repeat the round trip.

Verifying the `CPUThrottlingHigh` claim below turned up the same defect in a third place. The CloudNativePG dashboard's CPU- and memory-vs-request panels carried **both** wrong job labels — `job="kubelet"` (live: `kube-prometheus-stack-kubelet`) with the phantom `metrics_path="/metrics/cadvisor"`, and `job="kube-state-metrics"` (live: `kube-prometheus-stack-kube-state-metrics`). Six selectors across four panels, matching 0 of 236 cadvisor and 0 of 119 KSM series. After the fix the memory panel returns 0.366 and the CPU panel 0.6 for `main-postgres-*`. The lesson generalises: **a vendored dashboard or mixin rule carries the job labels of the stack it was written for**, and this cluster renames both of them. Grep any import for `job="kubelet"`, `job="kube-state-metrics"` and `metrics_path` before trusting its panels.

`FluxResourceNotReady` was pending on `flux-system`, `monitoring-controllers` and `monitoring-configs` and needed no fix: a reconciliation blip during the rolling reboot. `gotk_resource_info{ready=~"False|Unknown"}` already returned 0 series and all 7 Kustomizations were Ready, so it aged out inside its 15m `for` window.

`pt-heartbeat` on `main-mysql-mysql-1` at 81% of its 64Mi limit is the same page-cache artifact as alloy, but unlike alloy it is worth a limit bump: its cache is bounded by the image's files, not by a log stream. Stable at working_set 52Mi / RSS 19Mi across 7 days. The 2026-11 monthly review raised the limit to 96Mi in its own PR (`be127a54`), which puts the peak at 54%; the Percona operator rolled the MySQL pods to apply it.

### 2026-10-31 — One cadvisor relabel had killed a dashboard, doubled an alert and hidden a dead rule

The post-reboot alert review opened on a single critical, `ContainerMemoryCritical` on `loki/alloy-qxxp6`, firing twice. Pulling that thread found one wrong line in `scrape-kubelet-cadvisor.yaml` and two consequences of it, plus an unrelated rule that could never fire.

| Finding | Evidence | Fix |
|---|---|---|
| `metricRelabelConfigs` rewrote `container` with `name`. kubelet already sets `container` to the container NAME and `"POD"` for the pause container; under containerd `name` is the container ID | the Loki/Alloy dashboard panels join `on (pod, container)` against kube-state-metrics, where `container` is the name — the alloy memory panel returned **0 series** | drop the rewrite |
| the two container-memory alerts counted the per-POD cgroup series as well as the container, so every container pages twice | 361 cadvisor series, 236 with `image!=""` — 125 pod cgroups | add `image!=""`. Not `container!=""`: the pod cgroup carries neither label, and only `image` is immune to a relabel on `container` |
| `CPUThrottlingHigh` was dead. Upstream's copy matches `metrics_path="/metrics/cadvisor"`, a label prometheus-operator stamps on ServiceMonitor samples and the VictoriaMetrics operator does not | both selectors matched **0 of 200** live series; with the matcher removed, 111 | drop the `metrics_path` matcher. `job` alone is unambiguous — kubelet-cadvisor is the only producer |
| the alloy alert itself was a false positive by construction | immich-vm at 05:04: working_set 754Mi of a 768Mi limit, but **RSS 47Mi and cache 703Mi**. alloy tails the host journal over a hostPath, so its working_set is reclaimable page cache. It self-cleared to 17.6% within the hour, unassisted | exclude `pod!~"alloy-.*"` from both ratio alerts. Raising the limit does not help: page cache parks just under whatever limit the cgroup has. A real leak still pages through `ContainerOOMKilled` |

Reviving `CPUThrottlingHigh` exposed a duplicate. `ContainerCPUThrottling` in `pod-alerts` covered the same condition at `severity: warning`, and nothing had noticed the overlap because the better rule was dead. It is deleted: its expr was `rate(container_cpu_cfs_throttled_seconds_total[5m]) * 100 > 25`, throttled-seconds per second rather than a fraction of the container's quota, so `25` was not the "25% of the time" its description claimed and a multi-threaded container could exceed 100; and with no `image!=""` it fired twice. The surviving rule's `severity: info` changes nothing about who hears it — `InfoInhibitor` is absent (the chart's `defaultRules` are off, so no rule emits it), the matching `inhibit_rule` can therefore never activate, and `info` falls through to the default `telegram` receiver. Keeping both would have sent three Telegram messages per throttling event.

Checked and **not** a defect: `traefik_service_requests_total` and the five `RateLimit*` rules that read it had no series, because Traefik restarted during the reboot and served no request for the next 25 minutes (access log empty, `traefik_open_connections` 8). Those rules are rate-based — absent means no traffic, not no monitoring.

A 142-rule sweep for empty selectors produced the `CPUThrottlingHigh` find. `_shared/vmrules-metric-audit.sh` could not run it: the script needs `yq` and the claude-telegram pod has none. Reading the already-parsed exprs from vmalert's `/api/v1/rules` sidesteps the YAML parser and is worth folding into that script.

Cluster hygiene was otherwise clean after the reboot: 0 failed pods, 0 controller-owned terminal pods (phase2 PLAY 2 swept them), 0 unbound PVCs, 0 released PVs, all 12 HelmReleases and all 7 Kustomizations Ready.

### 2026-10-08 — The k3s version lives in git, and Renovate bumps it

On 2026-10-07 the cluster moved from k3s v1.37.0+k3s1 to v1.37.1+k3s1 with the old skill: a Mac-side script copied the binary to each node with sudo, then the rolling restart activated it. Nothing in git named the version, so no tool noticed a new release. `267b0f19` (PR #1255) pins it as `k3s_version` in `node-maintenance/ansible/group_vars/all.yml`.

| Part | Change |
|---|---|
| Renovate | a regex custom manager for `k3s-io/k3s` with `+k3sN`-aware versioning; one PR per minor plus a separate patch PR; minor PRs wait for Dependency Dashboard approval. `ignorePaths` no longer hides all of `node-maintenance/`, only `requirements.yml` |
| drift-heal | its last play compares each node's `kubeletVersion` with `k3s_version` and starts the rolling restart for an allowed upgrade; a refused version fails the run and alerts |
| rolling restart | preflight refuses a skipped minor, a major change, a downgrade or an inventory mismatch before touching any node; the CP downloads the binary once with a sha256 check; each node gets it immediately before its own restart, CP first. The wait now also requires `k3s_version` and a heartbeat newer than the restart. `TimeoutStartSec` 25 → 40 min |
| rejected | staging the binary ahead (a reboot or heal watchdog would activate it on one node alone); re-running `install.sh`; system-upgrade-controller (its Jobs have no `resources` field, so `require-resource-limits` refuses them) |
| verified live | the drift-heal on the merged SHA logged verdict `same` and queued nothing; a config-only rolling restart skipped the download and swap, and its heartbeat wait used at most 15 of 30 retries (81 s on worker-node) |
| skill | `k3s-upgrade` now follows the pin (dotfiles `6db2a1f`, then `9667ab3` with the test below); `stage-k3s.sh` is gone |
| follow-up `84d0eafa` (PR #1257) | `--check` on the rolling restart now runs end to end: it restarts nothing, skips the waits and still reads each node's live `configz`. It failed at the first node before, also before PR #1255. The cache keeps only the current version. The verdict template no longer trips ansible-lint's `jinja[spacing]` |

End-to-end test the same day, on production:

| Step | Result |
|---|---|
| pin set back to v1.37.0 (PR #1258) | the drift-heal refuses it as `downgrade` and changes no node. Telegram sends two alerts: the drift-heal's and `node-maintenance-sync failed`, because the sync runs the drift-heal synchronously; later syncs succeed |
| rollback with `-e k3s_allow_downgrade=true` | all 4 nodes reach v1.37.0, rc 0; the heartbeat wait uses at most 16 of 30 retries |
| Renovate | a Dashboard "run again" tick lists the update under "Awaiting Schedule"; ticking it there opens PR #1259 outside the 18:00-23:00 window |
| PR #1259 merged, no further operator action | the drift-heal queues the rolling restart 4 min after the CP syncs; all nodes reach v1.37.1, `Result=success`; the cleanup removes the v1.37.0 cache file |

### 2026-10-05 — Every change to `main` goes through a PR

The owner asked for no more direct pushes: every change must reach `main` through a PR.

| Item | Evidence | Change |
|---|---|---|
| `main` ruleset `24432813` | Before: 1 approval, merge/squash/rebase, the repo admin role as a bypass actor (mode `always`). Read back after the change: no bypass actor, `current_user_can_bypass` = `never`. | 0 approvals and merge commits only. The ruleset keeps its two required checks (`ci-ok`, `gitleaks secret scan`) and still blocks force pushes and deletion. |
| Direct push refused | An empty commit pushed to `main` got `GH013 ... Changes must be made through a pull request`, and `main` still pointed at the same commit. | — |
| `merge-worktree.sh` | 53 test cases run against a bare repo and a fake `gh`. PR #1235 was its first use on GitHub. The first run stopped on a failed `ci-ok` (shellcheck SC2120 in the new test file) and merged nothing. The second run merged `a17d9b53`. It then synced the main tree and removed the worktree. The merge commit's own run on `main` passed. | In order, the script pushes the branch, opens or reuses the PR, waits for both checks, merges with a merge commit, and fast-forwards the main tree. If there is no GitHub login (the in-cluster bot), it pushes the branch, prints a compare URL and exits 4. |
| PR checks and the merge result | PR runs check out GitHub's test merge (`refs/remotes/pull/<n>/merge`). The ruleset does not require an up-to-date branch. | The gitops-workflow skill waits for the merge commit's own run on `main` before `fr`. |
| Docs and runbooks | SECRETS_ROTATION.md, the DR rollback (`reset --hard` and a force push), the authentik rollback, K3S_SETUP.md, node-maintenance and two hook messages told readers to push to `main`. | Each now tells readers to merge through a PR (`bc26d263`, merged in `a17d9b53`). The DR rollback commits the tag's tree with `git restore --source` instead. |

### 2026-10-05 — Sweep follow-ups: checks, fixes and open questions

| Item | Evidence | Change |
|---|---|---|
| DR and secrets-rotation runbooks, skipped by the second sweep | The operator approved the sweep. | The sweep fixes false claims and moves two misplaced entries. Every code block stays byte-identical (`99eabf81`). |
| `K3S_SETUP.md` virsh commands | On the NAS, `virsh -c qemu:///system list --all --title` names the domain `0398541a-…` with title `immich-vm`. `domstate immich-vm` fails. `virsh` without `-c qemu:///system` lists nothing. | The commands use the domain name and `-c qemu:///system` (`655f78cf`). |
| authentik passkey rollback | In a throwaway worktree, `git revert bada5b6a` stops on a conflict. `kustomize build apps/authentik` succeeds after the rollback removes blueprints 10, 20 and 30. Blueprint 50 refers only to default flows. | The runbook removes the blueprints by hand and stages the kustomization edit. It keeps phase 0 (`655f78cf`). |
| `ARCHITECTURE.md` counts | The intro says the page avoids drifting numbers. | The page drops the drifting counts (`655f78cf`). |
| Home Assistant PSS exception, review overdue since 2026-01-26 | Live `/proc` status shows `CapEff` = `CapBnd` = the five manifest capabilities. The pod uses no host namespace. | The doc records the review and sets the next one for 2027-01-04. It leaves open whether HA uses NET_BIND_SERVICE and the other four capabilities (`68629bee`). |
| Stirling-PDF on 3.0.2 | The upstream v3.0.2 embedded Dockerfiles contain no nginx. 2000 live log lines contain no nginx line. | The Deployment drops the two `/var/lib/nginx` emptyDirs. The PSS note and the 443-egress comment describe 3.0.2 (`4e48b99f`). The pod restarted and started cleanly. |
| uptime-kuma setup Job pinned to the control plane | The only recorded reason was consistency (`5a15287f`). | The Job drops the pin (`1e6639e5`). |
| uptime-kuma setup first-attempt timeouts | In Loki, 14 of 31 setup pods over 29 days to 2026-10-05 logged a needSetup `TimeoutError`. A 30s timeout (`447b56ce`) did not help. That message miscounts the runs as 18 of 30. | The script retries the connect and needSetup together (`683c7988`). The next run retried once and finished with 0 restarts. |
| `cluster-roll` Flux-stale fallback | The fallback deleted every surviving pod at once. That bypasses PDBs and can take a workload fully down. | The fallback calls `restart-workload.sh`, which deletes one pod at a time and honours PDBs. A stub test covers the fallback. All three mutated versions fail the test (dotfiles `1f8d641`, `agents/` `1c47cbab`). |
| `watch-reboot.sh` "restart k3s on the CP HANGS" | `restart k3s` returned cleanly on a healthy CP on 2026-06-29 and on 2026-10-04 at 21:16 UTC. | The message says the restart can hang if the CP API server is unstable (dotfiles `1f8d641`). |
| private labels C3, C4 and Tier-2 | | The immich-vm domain XML, the README, vmrules and the immich-gpu-heal give-up log name the problems instead. The update re-records three heal-harness fixtures. All 78 scenarios pass (`7d82bd6d`, `1c88c50e`, `b2080c8d`). |

Open: the immich-vm libvirt domain has `Autostart: enable` on the NAS (link dated 2026-07-11). The README and the heal CronJob say autostart is off by design.

### 2026-10-04 — Second sweep: low-confidence comments, Markdown docs and skill scripts

The operator asked for everything the first comment sweep left, except Flux's generated `gotk-*.yaml`.

| Scope | Result | Commits |
|---|---|---|
| 137 low-confidence comment findings | re-checked against the code: 116 applied, 16 skipped (12 sit in pod templates), 5 left for the operator | `ad277775`..`a971f6c2` |
| Markdown: HOMELAB_HISTORY.md | 13 removed-plan paths replaced by the commit that removed the plan, 18 private labels decoded | `77ed8260` |
| Markdown: 23 other docs, AGENTS.md and CLAUDE.md included | false claims fixed, among them the README dependency tree, a CVE ID, and AGENTS.md calling a reminder hook enforcing | `77ed8260` |
| `docs/disaster-recovery/README.md`, `docs/SECRETS_ROTATION.md` | not swept: the permission check blocked edits to these runbooks | none |
| 43 files in 16 of the operator's own dotfiles skills plus `_shared` (third-party skills untouched) | 15 false comments fixed, private labels and doc pointers removed; `agents/` refreshed | dotfiles `566820c`, `8cfc2e08` |

| Review | Result |
|---|---|
| repo, 22 chunks then two deltas | round 1: 10 HIGH; round 2: 2 HIGH; round 3: approved |
| skills, operator rule: iterate until no finding, NIT included | 5 full passes and 8 delta reviews; the last full pass approved all 6 chunks with no finding |
| Kustomize roots rendered with comments stripped | all 21 touched roots match |

Review caught first-round rewrites that were wrong. The docs now state:

| Topic | Correct behaviour |
|---|---|
| Flux `wait` | `wait: true` ignores `healthChecks`; `wait: false` still runs them |
| Traefik `burst` | sets the token-bucket size; it does not limit requests in flight |
| `emptyDir.sizeLimit` on a disk-backed emptyDir | kubelet evicts the pod; the limit does not cap writes |
| shell `&&` and `||` | equal precedence, grouped left to right |

### 2026-10-04 — W1's two-month `CertificateExpirationWarning` came from a dead install's control-plane state, not from its own certificates

Since 2026-08-08 the `k3s-cert-monitor` on worker-node had warned that "node certificates require attention — restart k3s on this node to trigger automatic rotation", naming leaf certificates that expire 2026-11-08. The advice was unachievable: every file it listed is a **server** certificate (`admin/`, `supervisor/`, `auth-proxy/`, `api-server/`, `scheduler/`, `controller-manager/`, `cloud-controller/`, `etcd/`), W1 runs `k3s-agent` only, and an agent cannot re-issue those. A rotation of all three agents' certificates on 2026-10-04 left the warning firing unchanged, which is what pointed at the real cause.

The monitor scans `<data-dir>/server/tls`, and W1's data dir is `/mnt/k8s-storage/rancher/k3s` (per-host `k3s_data_dir`). That path still held the full server state of the single-node install from 2025-11-08 whose unit files the 2026-09-26 cleanup removed — it deleted `k3s.service`, its env file and `k3s-uninstall.sh`, and left the data. `/var/lib/rancher/k3s/` holds only `agent/`, so the tree's `agent-token` and `node-token` symlinks into `/var/lib/rancher/k3s/server/token` were dangling and no second tree existed.

That state included CA private keys, so the first question was whether they sign anything this cluster trusts:

| | Live cluster | W1's stale tree |
|---|---|---|
| Server CA | `CN=k3s-server-ca@1759844691`, created Oct 7 2025 | `CN=k3s-server-ca@1762561602`, created Nov 8 2025 |
| sha256 | `C1:0E:84:8C…63:A9:0A:43` | `C3:8F:D4:35…90:61:75:B5` |

Different CA, a month apart, and the client CA likewise (`k3s-client-ca@1762561602`). The install never joined this cluster, so its `server-ca.key` mints nothing the live API server accepts, and the tree was `0700`/`0600` root-only, out of reach of any pod. `db/state.db` was 7.1 MB with a zero-length WAL and an mtime of Nov 8 2025 — written once, never reopened.

The directory was renamed to `server.stale-20261104-dead-install` rather than deleted, which both takes it out of the monitor's scan path and keeps it recoverable; `agent/` under either prefix was left alone, since the live kubelet serves out of it. After the agent restart at 21:30:14 UTC the monitor logged its broadcaster and emitted no event, where before the warning had followed in the same second. W1 Ready, no unhealthy pod, and `kubectl logs` against a pod on it still worked. Delete the renamed directory at a monthly review once nothing has missed it.

### 2026-10-04 — The `gateway-api-crd` addon has been failing since the k3s v1.37.0 upgrade

k3s v1.37.0 moved the Gateway API CRDs out of the traefik chart into a packaged component of their own, and that component is a `HelmChart` CR. This cluster sets `disable-helm-controller: true`, so the `helm.cattle.io` group is not registered and the deploy controller cannot resolve the kind. Since the 2026-09-26 upgrade it retried `/var/lib/rancher/k3s/server/manifests/gateway-api-crd.yaml` every ~18s:

| Measure | Value |
|---|---|
| Event | `Addon/gateway-api-crd ApplyManifestFailed … the server could not find the requested resource` |
| Count | ~38k, in two event objects spanning 2026-09-26 → now |
| Alerts raised | none. No rule watches addon events, so the loop was invisible to `/monitoring-check` |
| Damage | none beyond the event spam. Every apply failed, so the addon owns no objects |

`gateway-api-crd` joins `traefik` and `coredns` in `k3s_disable` (`node-maintenance/ansible/group_vars/control_plane.yml`). The live `gateway.networking.k8s.io/v1` CRDs come from the traefik chart, and no manifest in this repo declares a Gateway, GatewayClass or HTTPRoute, so nothing consumes them.

The k3s_config role is drift-alert only, so the entry reaches `/etc/rancher/k3s/config.yaml` on the next sync but takes effect only on the next `systemctl restart k3s` on the control plane — pair it with the node-certificate rotation that W1's `CertificateExpirationWarning` (leaf certificates expire 2026-11-08) also needs. Before that restart, `kubectl get crd -l objectset.rio.cattle.io/owner-name=gateway-api-crd` must return nothing: if it lists CRDs, the addon does own them and `--disable` deletes them, which is the 2026-05-31 coredns deadlock pattern.

The operator restarted k3s at 21:16 UTC the same day. The ownership check ran a minute after that restart rather than before it, and returned nothing while the nine `gateway.networking.k8s.io` resources stayed registered, so the addon owned no CRD and `--disable` deleted none. Run it before the restart on any other node: after the fact it can no longer distinguish "owned nothing" from "owned them and deleted them". The retry loop stopped: no `gateway` line in the control-plane journal since the restart, where the old cadence gave one every ~18s. Nodes Ready 4/4, no unhealthy pod, Flux all Ready, Watchdog the only alert, and `kubectl logs` still reaches a kubelet — the API-server-to-kubelet break that the 2026-09-26 certificate rotation caused did not recur. W1's `CertificateExpirationWarning` stays open: a control-plane restart does not re-issue an agent's leaf certificates, so W1 needs `k3s certificate rotate` with its agent stopped before 2026-11-08.

### 2026-10-04 — Comment sweep: false comments fixed, plan pointers removed

A repo-wide pass judged every code comment against the code it covers. Agents re-checked each sure or fairly-sure finding against the code before editing, and left the low-confidence ones unchanged.

| Measure | Count |
|---|---|
| comment lines scanned | 6,264 in 502 files |
| findings | 449 |
| findings rated sure or fairly sure, acted on | 312 |
| low-confidence findings, left unchanged | 137 |

| Kind of finding | Flagged | Fix applied to the acted-on subset |
|---|---|---|
| false | 97 | the comment now matches the code, or goes |
| pointer to a plan, review ID or private note | 52 | the comment states the problem itself; pointers to removed design plans are gone |
| internal label (Tier-2, Track-0, skill names) | 28 | plain words |
| restates the code | 123 | cut |
| wordier than its point | 136 | shortened; SHAs, dates and repro commands kept |
| wrong block | 12 | moved or rewritten |
| commented-out code | 1 | kept, by operator decision |

| Gate | Result |
|---|---|
| Codex round 1: 23 chunks | 11 HIGH findings |
| Codex round 2: the 53 files changed since round 1 | 3 HIGH findings |
| Codex round 3: the 8 files changed since round 2 | approved |
| Kustomize roots rendered with comments stripped | 31 of 34 match; the other 3 differ by a blank script line and SQL comments |

| Also fixed | Commit |
|---|---|
| `worktree-guard.sh`: an early `awk` exit could SIGPIPE `git`, and under pipefail the hook then exited non-zero, which lets the edit through | `018f940e` |
| `install.sh --help` ran the root check first and printed `set -euo pipefail` | `9ab1d93f` |
| a heal-harness scenario held a `systemctl` stub that the next `behave` call overwrote | `8034bbde` |
| the postgres PodMonitor had no reader; VMPodScrape `postgres` scrapes CNPG | `5dc08f16` |
| CoreDNS NodeHosts lacked immich-vm | `a816753f` |
| `setup-node.sh` listed 8 of 16 roles and said "daily" | `768c1b96` |
| `ufw-heal-watchdog.service` claimed exit 1 does not fail the unit; nothing set that, and the operator chose to keep the alert | `ce12d016` |
| the rustdesk Service annotation and the networking map said servicelb advertises .126; it advertises only .129 | `78dacdd9` |

`ufw-heal-post-k3s.sh` and `firewall-preflight.sh` disagreed on how `nft monitor` behaves. In 30 days of phase-a logs on W1, W2 and the CP, its count varies between 0 and several hundred in back-to-back windows while the sampled UFW chain hash stays the same. Both comments now state that measurement.

### 2026-10-04 — LAN outage: the router lost power, 16:39 to 21:19 BST

From 16:39 BST (first seen) every node and the NAS stopped answering on the LAN: no ping, no ARP reply. 192.168.1.1 still answered ping from the operator's Mac. Cloudflare returned 530 for every public hostname.

| Observation | Source |
|---|---|
| no node rebooted: boot times are 2026-10-03 05:33 to 12:20, node-local time | `uptime -s` on each node |
| cloudflared logged `lookup ... on 10.43.0.10:53: server misbehaving`, and Flux failed to look up github.com | pod logs, `flux get sources git` |
| after recovery: CNPG 2/2 healthy, Percona `ready`, Redis and CouchDB pods Running | `kubectl get` |

The nodes answered again at 21:19 BST. The operator reports that the router lost power. A refresh of Flux's GitRepository and HelmRepositories cleared their outage errors. cloudflared recovered on its own. The bot came back when the comment sweep's rollout replaced its pod.

### 2026-10-03 — The repo is public

The operator makes the repo public after a pre-public audit. The audit finds no live credential:

| Audit check | Scope | Result |
|---|---|---|
| gitleaks and text searches | a mirror of every ref GitHub serves: 1 branch, 52 tags, 469 PR refs | the 15 known findings, all rotated or dead |
| gitleaks and text searches | 1,230 issues and PRs, 917 comments, 40 retained run logs | none |
| does GitHub still serve it | the 14 secret-bearing commits that the June history rewrite removed | GitHub answers 422 "No commit found" for all 14 |

| Change | Proof |
|---|---|
| visibility `PUBLIC` | `gh repo view --json visibility` |
| if an outside contributor opens a PR from a fork, its workflows run only after the owner approves | `approval_policy` reads `all_external_contributors` |
| private vulnerability reporting on; `docs/SECURITY.md` points to it | `{"enabled":true}` |
| ruleset `24432813` on `main`: a PR with 1 approval and a successful `gitleaks secret scan`; the admin role bypasses it | `gh api repos/AKhozya/homelab/rulesets/24432813` |
| the `@claude` workflow goes. If the owner mentioned `@claude` on a stranger's issue, that text would reach a run that holds the owner's Claude token | `31b49cd9` |
| `renovate.json` drops `automerge` from its `apps/**` patch rule | `31b49cd9` |
| `docs/plans/` leaves git; the plans stay as local, gitignored files | this entry's commit |

### 2026-10-03 — Monthly review cuts: CI, backup alerts, kustomize wrappers, node-script writes

The October review ran three audits. The operator approved the repo changes below. The ledger `~/homelab-monthly-review-2026-10.md` holds each audit's findings.

| Audit | Scope |
|---|---|
| automation (quarterly; the first ran 2026-07-04, see that date's entry) | timers, CronJobs, workflows, Mac LaunchAgents, and what reports each failure |
| over-engineering | dead code, single-use indirection, custom code that a library or this repo already provides |
| memory health | the agent's homelab memory against the repo and skills |

| Area | Change | Proof |
|---|---|---|
| CI | this change deletes `renovate-analysis.yaml`, `scripts/analyze-update.sh` and `analyze-update-gh.sh` (−644 lines). Renovate PR bodies already carry the release notes | `gh pr view 1229 --json body` contains a Release Notes section |
| CI | the shellcheck job lints `git ls-files '*.sh' '*.bash'` through `xargs` | the same 204 files as the old `find`; a failing file fails the pipeline |
| CI | a composite action, `.github/actions/install-yq`, replaces four copies of the yq install | actionlint; the action fails if `YQ_VERSION` or `YQ_SHA256` does not reach it |
| CI | the HOMELAB_ANALYSIS drift job now compares each count with its keyfact line and emits `::warning::` on a mismatch or a missing line. It printed both sides before and compared nothing | run locally: 54/59/12 match; an edited doc gives both warnings |
| CI | `claude-telegram-build.yml` drops the two-part-tag fallback | 51 three-part tags exist |
| alerts | `JobFailed`, `CronJobNotScheduled` and `PodPhaseNotRunning` exclude `.*backup.*`. `BackupJobFailed` (critical) covers the Jobs; `BackupCronJobMissedSchedule` covers the five daily CronJobs and `NoRecentImmichBackup` (9d) the weekly `immich-backup`; the inhibit rule needs an equal alertname, so a failed backup paged twice. Trade-offs: a missed nightly backup pages after about 70 min instead of 15, and a backup pod stuck Pending after about 2 h instead of 10 min | server dry-run; the selectors split the 6 backup CronJobs from the other 3; vmalert-tool: a Failed pvc-backup pod does not fire `PodPhaseNotRunning`, a Failed popeye pod does |
| kustomize | the parent lists each resource file directly. This change deletes the four one-resource `kustomization.yaml` wrappers | `kustomize build` of `infrastructure/configs` and `infrastructure/controllers` is byte-identical before and after |
| node scripts | `firewall-preflight.sh` and `ufw-state-metric.sh` write through the library's `textfile_write` instead of a fixed `.tmp` name and `mv` | harness 78/78, one stderr fixture re-recorded; 3 mutants killed |
| deleted | `scripts/update-firmware.sh` (the README gives the `pacman` and `fwupdmgr` commands), `node-maintenance/sync-node-maintenance.sh` (the README gives its `ssh` line; this change also deletes its `NODE_MAINT_CP_*` overrides), the comment-only `firewall_preflight/defaults/main.yml` | whole-tree grep: no other caller |
| agents/ | the snapshot takes dotfiles `91d9b57`: `kb-hygiene/scripts/lint-skill-scripts.sh` skips vendored skills | 15-check test; 6 Codex rounds |

| Audit cut not made | Why |
|---|---|
| `write_state()` delegators | 24 call sites; removing 4 one-line functions adds `"$STATE"` to each call |
| env overrides nobody sets (`CLUSTERIP_PROBE_SAMPLES`, `SETTLE_*`, the `NODE_MAINT_*` ones in `lib/sync-from-git.sh`) | a hardcoded value keeps the same line, and the probe override is a documented knob for manual runs |
| trim the Secrets backup to the Secrets not in git | the operator keeps it; it is part of the DR path |

### 2026-10-03 — GaveUp alerts stay firing while the heal watchdog retries

The W1 review (`99d6729d`; series tip `c7162caf`) lists two follow-ups. This change closes both:

| Follow-up | Fix |
|---|---|
| on `c7162caf`, `ClusterIPHealGaveUp` and `ImmichGPUHealGaveUp` can resolve while a fault persists. If the 30-min restart window expires, the script tries its 3 restarts again, and the gauge reads 0 for up to about 22 min on a worker (a restart over 60s pushes each 300s cooldown to the next 3-min run) | `keep_firing_for: 30m` on both rules, which also covers one run lost to the shared lock and up to 2 min of scrape and evaluation. Trade-offs: after a real recovery each alert clears 30 min later, and a fault that returns inside those 30 min pages only through the paired warning (`ClusterIPHealWedged`, `ImmichGPURenderDown`) |
| on `c7162caf`, `immich-gpu-heal.sh` writes `qsv_stuck 0` on every path after the Intel GPU check where the render node is down | those paths now write the measured value. The no-GPU branch exits before the probe check and still writes 0 |

| Test | Result |
|---|---|
| VMRule field | `kubectl explain` cannot show it: the CRD's `spec` preserves unknown fields. The operator API schema lists `keep_firing_for` (operator PR #711) |
| `vmalert-tool unittest` v1.152.0 | gauge 1 at 0-15 min, 0 at 16-37, 1 at 38-48, then 0: both alerts fire at the 30, 35, 37 and 75 min checks and have cleared at the 85 min check |
| mutants, rules | 4 killed: each `keep_firing_for` removed, each cut to 20m |
| heal harness | 78 of 78, with the new scenarios `immich-gpu-heal--giveup-qsv-stuck` and `--cooldown-qsv-stuck` |
| mutants, script | 2 killed: the giveup and cooldown paths without `"$qsv_stuck"`. The other four paths have no scenario of their own |

### 2026-10-03 — Heal scripts keep their stderr; alerts read the immich-gpu-heal gauges

The 2026-10-03 monthly review found three gaps on `e805e202`:

| Gap on `e805e202` | Fix |
|---|---|
| `clusterip-heal.sh` (top level) and `node-isolation-heal.sh` (`do_l1`) open the restart lock with `exec 9>>"$F" 2>/dev/null`. An `exec` with no command applies its redirects to the whole shell, so the journal loses every later stderr line of that run, such as a `mktemp` error from a failed save | `{ exec 9>>"$F"; } 2>/dev/null` hides only the open error |
| no rule reads the `immich_gpu_*` gauges | three rules in `immich-gpu-node-alerts`, below |
| `PodPhaseNotRunning` and `JobFailed` fire for every failed `immich-vm-heal` run. A NAS reboot fails some runs, and each failed Job stays for its 1 h TTL. In the 30 days to 2026-10-03 the two rules fired for 6 pods and 7 Jobs, while `ImmichVMHealJobFailing` never fired | both rules exclude the CronJob's pods and Jobs in namespace `immich`. This review found the change uncommitted in the worktree `heal-alert-exclude`, last touched 2026-09-08 |

| Alert | Expr | `for` | Severity |
|---|---|---|---|
| `ImmichGPURenderDown` | `immich_gpu_render_ok == 0`, which includes a GPU missing from the PCI bus | 8m | warning |
| `ImmichGPUHealGaveUp` | `immich_gpu_heal_giveup == 1` | 3m, to reduce pages from a value written before a reboot | critical |
| `ImmichGPUQSVProbeStuck` | `immich_gpu_qsv_stuck == 1` | 10m | warning |

| Gauge with no rule | Reason |
|---|---|
| `immich_gpu_qsv_ok` | the run after the hourly probe writes -1 over its result |
| `immich_gpu_virtiofs_ok` | a down mount drops the series that `NASLibraryMountMissing` reads |

| Test | Result |
|---|---|
| heal harness | all scenarios pass. 7 stderr fixtures change: 5 gain the `mktemp` error the old redirect hid, and the 2 `lock-unavailable` scenarios lose bash's own open error |
| mutants, scripts | 4 killed: the old `exec` form and the group without `2>/dev/null`, at both sites |
| `vmalert-tool unittest` v1.152.0, the vmalert version running in the cluster | each new rule is silent before its `for` ends and fires after it. A failed heal pod or Job in `immich` fires neither `PodPhaseNotRunning` nor `JobFailed`; a pod with the same name in another namespace still fires |
| mutants, rules | 10 killed: each exclusion removed, each exclusion widened to every namespace, each `for` shortened, each comparison inverted |

| Follow-up | Detail |
|---|---|
| `ImmichGPUHealGaveUp` and `ClusterIPHealGaveUp` | if the fault persists, each alert resolves and fires again after its 30-min restart window expires |
| `immich-gpu-heal.sh` | writes `qsv_stuck 0` on every path where the render node is down |

### 2026-10-03 — Heal watchdogs save their state before they act, and skip the action if the save fails

If `/var/lib` turns read-only or full, a watchdog cannot save its state file. On `126c7748` and earlier, `state_write` returns 0 anyway and no watchdog checks it, so each limit that reads the state file stops working:

| Watchdog | Limit lost | Result on `126c7748` |
|---|---|---|
| clusterip-heal | 3 restarts / 30 min cap | if the shared cooldown file stays writable, a k3s-agent restart every 6 min; if it does not, every 3 min |
| clusterip-heal-cp | cap and cooldown | `systemctl restart k3s` on the CP every 3 min |
| immich-gpu-heal | cap and cooldown | a `load-i915` restart every 3 min |
| node-isolation-heal L2 | 1 reboot / 24 h cap | reboots limited only by the 30-min uptime guard |

| Part | Behaviour now |
|---|---|
| `state_write` | returns 1 if the save fails |
| clusterip-heal, clusterip-heal-cp, immich-gpu-heal | save the incremented count before the restart and skip the restart if that save fails. After the restart command returns or times out, they save again. If that save succeeds, the next run measures the cooldown from that moment; if it fails, from the first save. A failed or timed-out restart counts toward the cap; before, only the CP's timeout path counted |
| node-isolation-heal | if the save before L1 or L2 fails, skips that action. A failed L2 save is a third reboot guard (`giveup 1`) |

| Failure | Alert that shows the skipped action |
|---|---|
| `/var/lib` read-only or full | the metric file stops changing too, so `NodeHealWatchdogStale` fires |
| only the state file fails | `ClusterIPHealWedged`, `NodeIsolationHealActing` or `NodeIsolationHealGaveUp`. **None for immich-gpu-heal**: no rule reads its gauges, a gap that predates this change |

| Test | Result |
|---|---|
| harness scenarios | 67 → 76: a failed save before the action, a failed save after it, a failed record-only save under `set -e`, and a clock that moves 200 s during a restart (success, failure and timeout) |
| mutants | 17 killed: each of the 5 guards replaced with `if false`, each of the 8 new `|| true` removed, each of the 3 saves after a restart deleted, and `|| true` put back in `state_write` |
| harness clock | the runner creates the shared cooldown file at `FAKE_NOW - 3600`. The scripts read its mtime with the real `stat`. If a script creates it, every scenario that reaches a cooldown check without its own mtime reports a cooldown from 19:55 UTC on 2026-10-03, 300 s before `FAKE_NOW` |

**Found, not fixed:** an `exec` with no command applies its redirects to the whole shell, so the journal loses every later stderr line of that run:

| File | Line |
|---|---|
| `clusterip-heal.sh` | `exec 9>>"$SHARED_RESTART_COOLDOWN" 2>/dev/null` |
| `node-isolation-heal.sh` | the same line in `do_l1` |

### 2026-10-02 — Monthly review: the 180-day secret rotation run end to end by the agent, Immich off the pooler, Loki sidecar probes back

This was the October monthly review, and also the quarterly automation audit. It covered the 180-day rotation that was due on 2026-10-01. For the first time the agent ran the whole rotation itself, merges included, on the operator's instruction. The method is now in the `secrets-rotation` skill, with new helpers in dotfiles (`bd266d6`, `51fe39a`, `5ecc336`).

**Rotation.** The batch covered the database passwords that were due (Blocky's PostgreSQL user is due 2026-12-05), the passwords of the Redis ACL users immich, paperless, blocky and admin, the CouchDB admin, the Authentik secret key and all nine OIDC client secrets. The check for each batch:

| Batch | Commits | Proof |
|---|---|---|
| MySQL: uptime-kuma, pricebuddy, home-assistant | `927b9db3` | MySQL showed sessions from each new pod |
| PostgreSQL: mealie, linkwarden, paperless, immich, n8n | `fd0048f5` | PgBouncer logged logins from each new pod's IP. The only failures came from the old paperless pod during its restart |
| CouchDB admin, three copies | `f93a6b43` | `_session` returned 200 on both nodes with the new value, and membership showed 2 of 2 |
| Redis immich, paperless, blocky, admin (the 2026-10-26 items done early) | `54b00722`, `c7446798`, `1517297a` | consumers connected as their user from each new pod. blocky resolved names on both LB addresses. Sentinel quorum was OK |
| Authentik database password and secret key | `0dbd6068` | every `authentik` Postgres session started after the change. Health returned 200 |
| OIDC: grafana, paperless, mealie, home-assistant, stirling-pdf, linkwarden | `617556ce` | Authentik PATCH returned 200, then each app restarted |
| OIDC: Immich and Audiobookshelf | none: a live update of each app's own database row | each row held the new value after its app restarted |
| OIDC: Cloudflare Access | none: a dashboard change | the operator pasted the secret. Cloudflare's **Test** then passed |

What the run taught, now written into the skill and into `docs/SECRETS_ROTATION.md`:

| Lesson | Detail |
|---|---|
| Redis passwords rotate in three overlapping passes | A single swap refuses every client between the Redis restart and the client's own restart. blocky needs Redis to start, and blocky serves DNS |
| A Redis replication restart leaves both pods `role:master` for about 50s | The sentinels kept the old master's dead IP until they restarted. `redis-restart.sh` now waits until the cluster settles |
| `ACL SETUSER <user> !<hash>` removes an old password from a running Redis | The last pass needed no restart. The ACL Secret is mounted with `subPath`, so `ACL LOAD` would re-read the old file |
| Changing the Authentik secret key only ends Authentik sessions | This holds since authentik 2023.6, per the official configuration docs |
| If `--tail=-1` is not given, `kubectl logs -l` returns only 10 lines per pod | The first "0 failed logins" check had read only 20 lines |
| An agent must not type a secret into a web form | For Cloudflare, the agent put the value on the clipboard and emptied the field. The operator pasted it. The first paste went into a field that still held the old value, and Authentik logged `Invalid client secret` |

**Fixed during the review:**

| Change | Commit |
|---|---|
| The Loki sidecar probes are back on: k8s-sidecar#531 is fixed in 2.10.0, and the chart ships 2.11.2 | `8b3d4e68` |
| The Loki sidecar gets 200m CPU and a startupProbe. At 50m its start took 84s, against a liveness limit near 90s. It now starts in 25s | `ff65f775` |
| immich-server connects to `main-postgres-rw` directly. Through the transaction-mode pooler, its startup advisory lock failed on every start (`you don't own a lock of type ExclusiveLock`), and the startupProbe killed it. A start now takes 11s | `14b84b59` |
| `backup-nightly-verify` no longer reports a false failure. It expected exactly 4 artifacts, but the job now validates one per PVC archive (17 last night) | dotfiles `bd266d6` |
| `NodeHealWatchdogStale` alerts if a heal-watchdog textfile stops updating for 25 minutes. The existing heal alerts fire only on the value `1`, so a dead writer went unseen. A 30-day backtest fired 0 times. `scripts/ansible-apply.sh` is deleted: nothing live called it | this commit |
| Image bumps from the trivy baseline. uptime-kuma moves to `2.5.5-slim-rootless`, which omits the bundled Chromium and MariaDB: fixable CRITICAL/HIGH 177/1661 → 8/127. The pricebuddy scraper moves to `v1.0.1` (22/224 → 0/12), the first patch tag upstream has published, so its two-part pin allowlist is gone. The trivy-scan init image moves from the stray `rancher/shell:v7.0.0` (kubectl 1.35, two minors behind) to `v0.8.2` (4/172 → 0/32), and a Renovate rule keeps it on v0. CouchDB stays on the chart default until the chart moves past 4.6.3 | this commit |
| `redis-master.sh` now logs in as the ACL user `admin`. Before, `info` and `exec` failed with `AUTH failed` | dotfiles `5ecc336` |
| Docs corrected: Actions jobs succeed again since 2026-10-01 (first green run 17:18Z); the 8472/udp rule names a source; the DB backups have no local age sweep; Grafana is LAN-only; the Alertmanager NetworkPolicy sources; the pooler's clients | this commit |

**Posture sweep.**

| Check | Result |
|---|---|
| Rootkits | the scans detected none on any node. The new scan warnings are package upgrades: `pacman -Qkk` shows no altered files |
| Kyverno | 0 fails |
| Certificates | 18 of 18 Ready |
| Database primaries | all on worker-node |
| Popeye | A (90) |
| trivy | 84 images; 248 CRITICAL and 3,522 HIGH fixable findings, the first recorded baseline. Uptime Kuma accounts for 177 of the CRITICALs |
| Immich memory since 2026-09-07 | ML peaked at 70% of 7Gi and immich-vm at 48% of its RAM. Neither crossed the 80% threshold, so the re-check row is closed |
| Upstream watches | n8n #25705 is closed, but its fix PR #27295 is unmerged, so the workaround stays. Stirling#6211 is still open |

Not caused by the review: at about 10:58Z a NAS firmware auto-update rebooted the NAS without first shutting down immich-vm. The `immich-vm-heal` CronJob started the VM again at 11:00, and the node was Ready by 11:01.

**Open, for the operator to decide:**

| Item | Detail |
|---|---|
| Redis ACL `user default on nopass ~* &* +@all` | **Fixed the same day** (`d0cd7938`): `default` holds the admin password, the RedisReplication sets `redisSecret`, replicas log in as `admin` (`masteruser`). Before the merge, a runtime `CONFIG SET masteruser/masterauth` on both pods let either pod follow the other. During the roll both pods reported `role:master` for about 13s. Afterwards the replica link was up, sentinel quorum passed, immich, paperless and blocky were connected, and an unauthenticated `PING` got `NOAUTH` |
| `timesyncd-metric`, `node_pkg_upgrade_success`, `crictl` prune | **Fixed the same day** (`95d38c65`). The upstream clock alerts replace the custom metric. The package metric file now carries a last-run timestamp. `NodePackageUpgradeStale` alerts on its age. The image prune runs `crictl --timeout=120s`. We did not use `imageMaximumGCAge`: the kubelet resets image age on restart, and 3 nodes reboot weekly. The image GC still has no failure notice. We accepted that, because the kubelet starts its own image GC at 85% disk usage |
| NAS firmware auto-update | it can stop immich-vm at any hour without a clean shutdown. **Accepted by the operator 2026-10-02**: the `immich-vm-heal` CronJob restarts the VM within 5 minutes |
| Watchdog metrics | **Fixed the same day.** `NodeHealWatchdogStale` (`deb48511`) catches a heal script that stops writing. node-exporter's systemd collector is on (this change). It reads the host's system bus through the read-only `/host/root` mount, so it needs no new hostPath. The scrape keeps only the `failed` state: about 1.2k series, against up to about 6k unfiltered. `NodeSystemdUnitFailed` and `NodeSystemdCollectorFailed` alert on it. Its first finding: 4 TPM NvPCR units on immich-vm failed at every boot or login since systemd 262. A drop-in now skips them there (`ConditionVirtualization=!vm`, `74fc16db`) |
| Shared shell helpers | **Fixed the same day (this merge).** `base_config` installs `node-script-lib.sh` (`textfile_write`, `state_write`, `ufw_chains_hash`); the 4 heal watchdogs, `firewall-preflight`, `k3s-wait-ready` and `ufw-heal-post-k3s` source it. A whole-script harness (67 scenarios, stubbed host commands) shows identical exit codes, output, metric and state files and restart/reboot calls before and after. Canary on worker-node-2 with the CP sync paused: the heal units ran clean, then a reboot ran `k3s-wait-ready` (16 s) and `ufw-heal-post-k3s` on the library, and both network gates passed. A first canary was void: a Renovate merge to main made the CP sync put main's scripts back mid-test |
| `agents/` snapshot | **Fixed the same day** (`2684a4b5`): the new helpers are allowlisted, `hyperframes-studio` is denylisted, and `--check` exits 0 |

### 2026-10-02 — daily Flux webhook EOF alerts; a Flux readiness alert that can fire

| Finding | Detail |
|---|---|
| What fails | A webhook pod resets a kept-alive connection as the API server sends a request on it. The API server reports EOF and does not retry an admission call, so one Flux dry-run fails. The next reconcile, a minute later, passes |
| How often | In 4.8 days k3s logged 54 resets ("Proxy error ... connection reset by peer") against Kyverno, CNPG, cert-manager and the VictoriaMetrics operator. Six of them hit a live call |
| Likely reason | controller-runtime webhooks close idle connections at 90s, the same limit as the API server's client. Kyverno closes them at 5 minutes, and why it reset first is not known |
| Ruled out | Kyverno did not restart. The failure times follow no schedule. The control plane also reset connections to webhook pods on its own node, so traffic between nodes is not needed |
| Alert filter | The flux-gitops Alert drops the EOF and connection-reset wording for any webhook. It also drops every cancelled health check, which the Flux 2.9.6 upgrade (`aca65a08`) caused. The 2026-09-29 filter (`6de3f590`) matched only Kyverno's "rejected ... unknown reason" wording, so EOF still reached Telegram |
| Backstop | `FluxControllerReconcileErrors` stayed at 0 through the 2026-10-02 failure: kustomize-controller v1.9.6 returns a nil error after a failed reconcile. kube-state-metrics now publishes `gotk_resource_info` for Kustomizations, HelmReleases, HelmCharts, GitRepositories and HelmRepositories. `FluxResourceNotReady` fires after 15 minutes at Ready=False or Unknown |

### 2026-09-29 — immich-vm VNC live on loopback; bot node keys have one copy

| Change | Detail |
|---|---|
| VNC on the NAS loopback | The fix in Git (`aba0768e`) does not reach the NAS by itself, because the heal watchdog does not check `<graphics>`. An in-place edit of the NAS definition changes only the two `listen` values, and a cold restart (`shutdown --mode acpi`, shut off in ~10 s) makes it live. Port 5900 no longer answers from the LAN. The node is Ready and the Immich server and ML pods are Running ~7 min after the start. The server fails its startup probe once on the cold VM. How to apply such a change and reach the console: [gpu-node/README.md](../apps/immich/gpu-node/README.md) |
| Bot node host keys | The bot's SOPS `known_hosts` keeps only the `github.com` keys (`3eb0d6a2`). `node-maintenance/lib/known_hosts` (`391fd839`) is the one copy of the node keys; the bot appends it at start. SSH from the bot to all four nodes passes with `StrictHostKeyChecking yes` |

### 2026-09-28 — Whole-repo review before going public: 209 findings, 198 fixed

Nine review agents read 737 of the 803 files at `8f78a8c8`, and seven fix agents fixed the
findings area by area. The review was part of the open-source prep plan, which left git in
`f1477f56`.

| Area | What changed | Commits |
|---|---|---|
| node-maintenance | Drift-heal removes the CP `kubectl proxy` unit. Every sync refreshes the Telegram token from its Secret, takes the maintenance lock and records the applied commit. A failed Telegram send writes a gauge, and an alert watches it | `17f60674` `2a09e2b0` `901f5722` `de137101` |
| node-maintenance | phase1 runs its preflight before `pacman -Syu`. A phase2 retry skips the workers it already finished, and phase2 alerts on an unreachable immich-vm and skips it | `badf6379` `7b9d596d` |
| node-maintenance | The firewall role sets UFW default policies only if they differ, and a rescued rule batch fails the run. The role deletes the no-source flannel 8472/udp rule. After a UFW `flush-all`, the healer restores portmap's three nat rules, with no k3s restart | `9e674eb7` `1bc2817c` `00e92313` `891751ea` |
| node-maintenance | The yearly SSH-key rotation installs and checks the new key before it removes the old one. The bot's read-only `agent-diag` key now reaches immich-vm | `17f60674` `445aefa3` |
| backups | Replication checks all 14 PVC archives (checksum and `tar -t`) and matches the count against pvc-backup's list. If one backup type fails, the other types still reach the NAS and the Job still fails. replication and pvc-backup no longer retry, because a retry after the source cleanup reported every backup as missing | `54b4069a` `dca36ccf` `527375a2` `ebf72957` |
| infrastructure | cloudflared egress on 7844 and 443 reaches public addresses only. The resource-limits exclusions apply only in the operator namespaces. CoreDNS `NodeHosts` drops the two global IPv6 entries | `0f65dbfa` `55478c1a` |
| monitoring | Four alert rules that could not fire now fire, and three that could never match are gone. Alertmanager 9093 admits only its client namespaces. Kyverno `resourceFilters` return to the chart defaults plus `flux-system` | `a0b68286` `228e19f7` `ac1a21b3` |
| monitoring | monitoring-configs waits for VMSingle health, and CoreDNS no longer waits on infrastructure-controllers. The Traefik Middlewares moved to `infrastructure/configs/traefik-middlewares` in two pushes, so a fresh cluster installs their CRD first | `10e08eb3` `71535f59` `a39dd523` |
| apps | The Telegram chat ID, the bot's allowed-user ID and the Home Assistant admin name moved into SOPS. The bot's exec bindings live in one list in `rolebindings.yaml` | `09c2abb6` `ab161f5c` `fa066ca3` |
| apps | immich upgrades use RetryOnFailure, so a failed upgrade never rolls back onto a migrated schema. The n8n, mealie and audiobookshelf setup Jobs fail on real errors. Home Assistant drops NET_RAW and NET_ADMIN | `aba0768e` `fa066ca3` `5f7058a7` |
| tooling | validate.yaml checks every tool download against its SHA-256. The secrets backup lists its archive before it deletes plaintext. `.claude/settings.json` denies force deletes and Secret reads. `setup-node.sh` takes the node role | `86d71b8e` `c31e5670` `d8d83e8a` `082832b0` `dfebaebd` `154e00b8` |
| docs | SECRETS_ROTATION restarts Redis pods one at a time by UID and rotates MySQL by `ALTER USER` through HAProxy, with no password on a command line. The node-maintenance token needs no manual refresh. The DR runbook suspends Flux during volume restores and applies CoreDNS before `flux bootstrap` | `5bbdeab4` `75ce6fc2` `3dd77ea6` `1d3ff3d0` `b7571489` `4ccb3986` |
| agent skills | 56 of 57 findings fixed. cluster-roll refuses an unmapped workload, and `pin.sh` parses the real MySQL pod name. Runbooks change live objects only through Git. The DB helpers keep passwords off the command line | `ea8b0e53` `06c4ac8d` `e7433112` `fbf8e18d` `36db2847` `beb9c4eb` `6aab6dc2` |

### 2026-09-28 — immich-vm's sshd listens on 65300 only

immich-vm's sshd still listened on port 22 as well as 65300, from a hand edit to
`/etc/ssh/sshd_config.d/10-port.conf` when the VM joined on 2026-07-10. The 2026-09-27 firewall
change had already deleted the UFW rule that allowed 22, and a connection test from the Mac on
the LAN failed. The
`hardening` role now writes that file with `Port 65300` only, on hosts that set
`sshd_port_dropin` (immich-vm). The other three nodes set the port in the main `sshd_config`, and
a second `Port` line for the same port would bind it twice. If sshd fails on immich-vm, use the
virsh console. The role's `sshd -t` now runs on every drift-heal, not only after a copy, so a
config that sshd rejects fails every run until someone fixes it.

### 2026-09-28 — three tokens rotated before the repo goes public

The pre-public secret scan read every ref GitHub serves, not only `main`: `gitleaks git
--log-opts=--all` on a mirror clone. `main` held the same 11 findings as the 2026-07-26 audit,
which judged each one rotated or decommissioned. Four more findings are in commits that only
`refs/pull/*` reach, from before the 2026-06-12 history rewrite. Two of those were working
credentials:

| Token | Where | Why it still worked |
|---|---|---|
| Cloudflare API token `dns_and_certs` (Zone.DNS edit on `h0melab.work`) | `.backup/QUICK_REFERENCE.md`, commit `7349f6cc`, 2025-10-07; 18 PR refs | cert-manager's SOPS file had not changed since 2025-10-06, so it held the same value. The rotation table's "2025-10-19" was never a rotation |
| Telegram bot token for @h0melab_alerts_bot | same commit | Alertmanager, Flux notifications and the backup job use it. Its file had not changed since 2025-10-07 |

The repo owner cannot delete PR refs, and the open-source prep plan keeps the repo rather than
recreating it, so rotation was the only fix. The operator made new values for both tokens, and for the
claude-telegram bot's token too, and saved each in 1Password. `scripts/rotate-token.sh` checked
each value with its issuer and wrote it into the SOPS files (`52ce08aa`). Cloudflare reports the
new token active. A test alert raised Alertmanager's Telegram send count with 0 failures, and
claude-telegram restarted with its new token. cert-manager first uses the new token at the
renewals due 2026-10-31. The procedure is section 6 of `docs/SECRETS_ROTATION.md`.

Two lessons. A scan of `main` alone missed both tokens. A rotation table's date can be wrong,
but a value is never newer than its SOPS file's `sops.lastmodified`.

### 2026-09-27 — firewall: no-source rules closed over IPv6; key-only SSH everywhere

Every node has a public IPv6 address. A UFW rule with no source address opens its port over
IPv6 too. Before this change, the firewall role only added rules, so these rules stayed open:

| Rule | Nodes | Now |
|---|---|---|
| 6443/tcp from any source | control plane | deleted. The LAN-only 6443 rule stays |
| 10250/tcp from any source | all four | deleted. Node-IP and pod-network rules cover every caller |
| 22/tcp from any source | immich-vm (build-time rule) | deleted |

`group_vars/all.yml` gains `ufw_rules_absent`, and the role deletes each rule in it. The role
skips its rule tasks while a fingerprint of the rule lists and the live rules is unchanged. The
new list is part of that drift fingerprint, so adding an entry makes the role run its rule tasks
again, even on a healthy node. If a rule is in both the list to add and the list to delete, a check
stops the Ansible run.

`99-hardening.conf` now sets three sshd options on every node. Before, only immich-vm lacked them:

| Option | immich-vm before | Every node now |
|---|---|---|
| `PasswordAuthentication` | `yes` (OpenSSH default; its `sshd_config` had no line) | `no` |
| `KbdInteractiveAuthentication` | `no` (`99-archlinux.conf`) | `no` |
| `PermitRootLogin` | `prohibit-password` (default) | `no` |

Anonymous requests to the API server and the kubelet return 401, before and after the change.

### 2026-09-27 — skills, helpers and rules copied into `agents/`

`agents/` now holds a read-only copy of the operator's agent setup, for readers of the repo.
The operator keeps the original files in a separate dotfiles repository, and no tool loads `agents/`.

| Path | Content |
|---|---|
| `agents/skills/` | the skills and `_shared/` helpers named in `agents/sync/allowlist.txt`, byte for byte |
| `agents/rules/AGENTS.global.md` | a byte copy of `~/.codex/AGENTS.md` |
| `agents/rules/CLAUDE.global.md` | a hand-edited export of `~/.claude/CLAUDE.md`; line 1 records the source's sha256 |
| `scripts/sync-agents.sh` | `--update` refreshes the copies. `--check` reports copies that differ from dotfiles, gaps in the allowlist, forbidden entries, secrets and private terms |

The monthly review runs `--check`. `renovate.json` ignores `agents/**`, and the two pre-commit
hooks that rewrite files skip the byte copies. This was part of the open-source prep plan, which
left git in `f1477f56`.

### 2026-09-26 — node-maintenance moved out of `docs/`

| From | To |
|---|---|
| `docs/scripts/node-maintenance/` | `node-maintenance/` |
| `docs/scripts/*.sh`, `docs/worker-node-post-install.sh` | `scripts/` (`scripts/worker-node-post-install.sh` deleted in `12025040`) |
| `docs/scripts/runbooks/authentik-passkey-rollback.md` | `docs/runbooks/` |

Only the control plane clones the repo. Its installed sync script calls `install.sh` by its old
path, so the move ships in two commits:

| Commit | Change |
|---|---|
| A | moves the tree, leaves a symlink `docs/scripts/node-maintenance → ../../node-maintenance`, and points `lib/sync-from-git.sh` at the new path. The old installed script follows the symlink and installs the new one |
| B | deletes the symlink after the control plane shows the new sync script installed |

`renovate.json` now ignores `node-maintenance/**`. Renovate never read the folder before, because
it sat under the ignored `docs/**`. Entries below this one keep the old path. This was part of the
open-source prep plan, which left git in `f1477f56`.

### 2026-09-26 — Kernel 6.18.54, k3s v1.36.3 → v1.36.4 → v1.37.0, and a certificate rotation that broke `kubectl exec`

**The certificate rotation.** The operator ran `sudo k3s certificate rotate` on the control plane,
W1 and W2 while k3s was running. The command expects k3s to be stopped first. It moves the leaf
certificates aside (the certificates issued to each component, as opposed to the certificate
authority that signs them), and k3s writes replacements only when it next starts. The running API server
therefore lost `/var/lib/rancher/k3s/server/tls/client-kube-apiserver.crt`. Every call from the API
server to a kubelet failed, which broke `kubectl logs`, `exec` and `port-forward` across the cluster.

| Check | Result during the fault |
|---|---|
| API server `/readyz` | `ok` |
| Node Ready, all four nodes | `True` |
| ClusterIP probes (requests through the cluster's internal service addresses) | passed |
| `kubectl logs` | `open .../tls/client-kube-apiserver.crt: no such file or directory` |

Only a call from the API server to a kubelet showed the fault.

The first manual phase1 run failed on it with `exit=2` and rebooted nothing: before it upgrades
anything, it adds an Alertmanager silence through `kubectl exec`. The rotation left the
certificate authority unchanged (`k3s-server-ca@1759844691`). So `sudo systemctl restart k3s` on the
control plane made k3s write new leaf certificates, and `kubectl logs` worked again. The k3s agents on W1
and W2 kept the certificates they had loaded in memory. The phase2 reboot of each worker restarted
its agent, which wrote new ones. Each kubelet's `:10250` certificate then showed a `notBefore` from
that reboot.

**OS upgrade.** The second phase1 run completed. All four nodes moved from `6.18.53-1-lts` to
`6.18.54-1-lts`. Phase2 reported `failed=0` on every host.

**k3s patch, v1.36.3 → v1.36.4.** The `stable` channel named v1.36.4. The `k3s-upgrade` skill
checked the new program file against its published sha256 checksum and copied it to all four nodes.
The rolling restart, one node at a time, then started the new version. The `pre-k3s-v1.36.4` checkpoint matched after the
restart: no unhealthy pods and Flux 7/7.

**k3s minor, v1.36.4 → v1.37.0.** The `latest` channel named v1.37.0. The skill ran the same steps.
Checks before staging:

| Check | Result |
|---|---|
| k3s v1.37.0 release notes | name no removed flag or config key that this cluster uses |
| Kubernetes 1.37 "ACTION REQUIRED" notes | none apply. SELinux is not in `/sys/kernel/security/lsm` on any node, and no node kernel lists `selinuxfs`. The API server serves only `scheduling.k8s.io/v1`. `kubelet.yaml` does not set `eventRecordQPS` |
| `apiserver_requested_deprecated_apis` | no series carries a `removed_release` label (the label names the release that removes a deprecated API that a client still calls) |
| Datastore | embedded SQLite. `sqlite3 .backup` copied it to `/var/lib/rancher/k3s/server/db/state.db.pre-v1.37.0` (root, 0600, `integrity_check` = ok) |

The copy exists because the old binaries were already deleted. The `k3s-upgrade` skill treats a
minor-version downgrade as a restore from backup, not a binary swap.

| After activation | Result |
|---|---|
| Kubelet version, all four nodes | `v1.37.0+k3s1` |
| `pre-k3s-v1.37.0` checkpoint | matched |
| Unhealthy pods | 0 |
| Flux Kustomizations | 7/7 Ready |
| Firing alerts | Watchdog only |

**W1 leftovers removed.** Three files from a k3s server install dated 2025-12-31 remained on W1:

| File | State | Why it went |
|---|---|---|
| `/etc/systemd/system/k3s.service` | disabled, never active | W1 runs `k3s-agent.service` |
| `/etc/systemd/system/k3s.service.env` | empty | belonged to the unit above |
| `/usr/local/bin/k3s-uninstall.sh` | server uninstaller | if an operator runs it on W1, it deletes `/etc/rancher/k3s` and `/var/lib/kubelet` on a working agent |

`k3s-image-gc.service` and `k3s-wait-ready.service` name `k3s.service` only in `After=`. Both
units already run on W2 and immich-vm, where no `k3s.service` exists. `k3s-agent-uninstall.sh` stays.

**CI follows the cluster version.** `KUBERNETES_VERSION` in `.github/workflows/validate.yaml` and the
default in `scripts/ci/helm-render-check.sh` moved 1.36.3 → 1.37.0. `yannh/kubernetes-json-schema`
publishes `v1.37.0-standalone-strict`. The account had used its GitHub Actions minutes, so every gate
ran locally:

| Gate | Result |
|---|---|
| kubeconform, 7 roots | 552 resources, 0 invalid, at both 1.36.3 and 1.37.0 |
| helm-render at 1.37.0 | 12 charts render |
| yamllint, shellcheck (46 scripts), sops-check, init-resources, image-pin, gitleaks dir | all exit 0 |

The first local kubeconform run reported `0 resource found` and exited 0. The script passed it a
`mktemp` path, and kubeconform skipped that file because it has no extension. CI sends the rendered
manifests straight to kubeconform on standard input, with no file in between, so the local copy
now does the same. If image-pin passes, it prints nothing. A copy
of `apps/paperless-ngx/deployment.yaml` with its tags set to `:latest` made it exit 1.

### 2026-09-19 — The immich-vm watchdog read a `paused` domain mid-start and paged

During the weekly reboot, the `immich-vm` step powers the VM off, then starts an early watchdog
run with a one-off Job (`phase2.yml` PLAY "Nudge immich-vm-heal watchdog"). On 2026-09-19 that Job
ran `virsh start` at 04:55:10. The watchdog's regular 5-minute run had started at 04:55:02, and it
read `domstate` at 04:55:07. QEMU shows a domain (the VM, as the virtualization software names it) as `paused` for a moment
while it starts, and the
read fell in that moment. The watchdog treats every state other than `running` or `shut off` as
one only the operator may act on, so the run failed. `JobFailed` paged for a VM that was booting
normally. The 05:00 run logged `OK=domain_running`.

The same problem was already known from the shutdown step of the reboot. Phase2 has a 20 s "Settle
before watchdog nudge" pause, so that a run does not check the VM while it is `in shutdown`. A pause
at that point cannot cover the moment that the early run itself creates, so the fix belongs in the
watchdog: it now reads a `paused` or `in shutdown` state a second time, 20 s later, before it
decides.

This does not relax the safety rule: the watchdog never destroys or restarts a running domain,
because that can crash the NAS host. The watchdog acts on no new state: a domain still `paused`
20 s later fails as before. It re-reads no other state, because it must start a `shut off` domain
on the run that finds it, not wait.

### 2026-09-11 — Immich v3.2.0 renamed a sign-up error and failed the admin-setup Job

`immich-admin-setup` decided that an admin already exists by searching the error body of
`POST /api/auth/admin-sign-up` for `already has an admin`. Immich v3.2.0, deployed 2026-09-10 23:03
UTC, changed that message to `Admin setup is
not available`. The search stopped matching on the next daily run.
The script ran its error branch, `exit 1`, on all five attempts. The Job exhausted the retries that
`backoffLimit` allows, and `JobFailed` fired.

The Job now reads `isInitialized` from `GET /api/server/config`. The field needs no login, and
`ServerConfigSchema` at v3.2.0 types it `z.boolean()`, so a fresh server returns it too. The Job
handles three cases:

| Field value | Job |
|---|---|
| `true` | skips and exits 0 |
| `false` | goes on to sign-up |
| anything else | prints the body and exits 1, without a POST |

If the Job cannot read the state, it stops with an error rather than sign up without knowing it, because a
POST to a server that already has an admin returns the same error text that this change stops
relying on. Disaster recovery still works: a database restored empty reports `false`.

| Fact | Value |
|---|---|
| Commit | `a92afa53` |
| Failing window | 2026-09-11 20:28–20:30 UTC, 5 attempts, all HTTP 400 |
| Evidence | Loki, `{namespace="immich", pod="immich-admin-setup-bwcq9"}` |
| Verified after | Job `Complete 1/1`, `kube_job_status_failed` 0, alert resolved in VMAlert and Alertmanager |

The incident taught two things about tooling. First, the grafana-pod `kubectl exec` recipe for
reading the standard output of a Job pod that no longer exists does not work: that image has neither `sh`
nor `curl`. Loki is now read over `kubectl port-forward -n loki svc/loki`. Second, the LogQL filter
`|= "admin"` hid the `{"message": …}` line that named the cause, because a Job prints its diagnosis
on the line after its headline.

### 2026-09-08 — The failed NAS drive was replaced, and md1 rebuilt clean

`WS21F7E8` was the `md1` member drive that failed SMART, the drive's built-in health check. It was
written up on 2026-08-02, and it was still in the array when it stalled the 2026-09-06 scrub.
The drive was swapped on 2026-09-08. The NAS came back up at 21:14 BST and rebuilt the array onto
the new drive, in the same position, RaidDevice slot 2. On 2026-09-10 the array reported:

| Field | Meaning |
|---|---|
| `[6/6] [UUUUUU]` | six of six members present, all up |
| `degraded=0` | no member missing |
| `array_state=clean` | no unfinished writes |
| `last_sync_action=recover` | the last sync was the rebuild |
| `sync_action=idle` | no sync running |
| all six members `in_sync` | every member holds current data |

| Fact | Value |
|---|---|
| Out | `WS21F7E8`: `ST4000NE001-2MA101`, SMART FAILED, `Reallocated_Sector_Ct` 49152, `Reported_Uncorrect` 65535, `Command_Timeout` 983057 |
| In | `WS24PTRD`: `ST4000NE001-2EN112`, firmware TN05. It is the Seagate warranty replacement. Its model suffix differs from that of the five original drives (`-2MA101`), so the six drives in the array are no longer identical |
| Earlier use | None recorded. `Power_On_Hours` 50, `Power_Cycle_Count` 1, `Start_Stop_Count` 2 and `Head_Flying_Hours` 50h14m all equal the time since the swap |
| SMART baseline | PASSED. Reallocated 0, Reported_Uncorrect 0, Command_Timeout 0, Current_Pending_Sector 0, Offline_Uncorrectable 0, UDMA_CRC 0, no errors logged |
| Temperature baseline | 52 °C now and 57 °C maximum, against the 60 °C `Airflow_Temperature_Cel` threshold. At its peak during the rebuild, the drive stayed 3 °C below the threshold. Compare at the next check. Reading the other drives' temperatures needs `sudo smartctl` |
| `G-Sense_Error_Rate` | 557 in 50 hours. The cause is rotational vibration from the other five drive bays, which is expected in a 6-bay chassis |
| Device letter | Now `sdd`. The *failing* drive carried that letter after the 2026-09-02 reboot. The letter is the same, but it now names a different drive, so identify a drive by its serial number, never by its letter |

**A rebuild is not a scrub.** A scrub reads every drive in the array and counts the places where
the stored data and its parity disagree. Parity is recovery data computed from the stored data. The `recover` read all five surviving members from start to end to rebuild
slot 2, so those five drives are known to be readable. It did not read back what it wrote to the new
drive. It also does not compute `mismatch_cnt`, so after a `recover` the `0` in sysfs (the Linux
interface that reports kernel state as files) tells you nothing. The 2026-08-02 and 2026-09-06 checks were both stopped part-way, so the last check that
completed dates from before August.

The next scheduled check runs at **2026-10-04 00:57** (`/etc/cron.d/mdadm`, on the first Sunday of
the month). It stays on schedule, not started early, for two reasons:

| Reason | Detail |
|---|---|
| The failing drive is gone | it caused the 87-second read stalls |
| The taint limits a stall to Immich | the `homelab/dedicated=immich` taint, applied on 2026-09-06, now keeps a stall like the scrub's to Immich, instead of reaching the five init Jobs |

A taint marks a node. If a new pod does not tolerate the taint, Kubernetes does not schedule it on
that node. To start a check early, run `echo check > /sys/block/md1/md/sync_action`. It takes
roughly 8-12 hours for 14.4 TB, so run it on a day when someone can watch the iowait of
`192.168.1.231`. Iowait is the time the CPU sits idle waiting for the disk.

### 2026-09-07 — kube-prometheus-stack 90.0.0 was blocked by control-plane ServiceMonitor authorization

Renovate, the bot that proposes dependency updates, merged the chart update to `90.0.0` (#1125). A
chart is a package of templates that Helm renders into Kubernetes objects. The Helm upgrade failed.
Flux, the tool that applies this repository to the cluster, rolled it back, and the release stayed on
`89.2.3` while `FluxControllerReconcileErrors` fired.

Chart 90.0.0 added a `fail` to `_helpers.tpl`, which stops the render with an error. For every enabled
control-plane component, `serviceMonitor.authorization` now defaults to a Secret. If
`prometheus.enabled`, `prometheus.serviceAccount.create` and `createTokenSecret` are all true, the
chart creates that Secret; otherwise it does not. This cluster sets `prometheus.enabled: false`, so the
render stopped. (A ServiceMonitor is an object that tells a monitoring agent which Service to collect
metrics from.)

No monitoring agent used those ServiceMonitors to collect metrics. No `Prometheus` custom resource (an object of a
type that an add-on defines, not one built into Kubernetes) exists, and every
`VM_ENABLEDPROMETHEUSCONVERTER_*` environment variable on the vm-operator is `false`. Those variables
would make the VictoriaMetrics operator convert ServiceMonitors into its own objects. vmagent, the
agent that collects the metrics, uses the hand-written VMServiceScrapes in `monitoring/configs/`.

| Component | Treatment | Why |
|---|---|---|
| `kubelet`, `kubeApiServer`, `coreDns` | `serviceMonitor.authorization: null` | If a component's `enabled` flag is off, the chart does not create its Grafana dashboard, and these three dashboards hold data |
| `kubeControllerManager`, `kubeScheduler`, `kubeProxy`, `kubeEtcd` | `enabled: false` | No VMServiceScrape, VMPodScrape, VMStaticScrape, VMScrapeConfig or vmagent `additionalScrapeConfigs` selects them, so their dashboards were empty |

The scrapes still work, because their selectors (the label queries that pick which Service to
scrape) never pointed at objects the chart creates:

| Scrape | Target |
|---|---|
| kubelet VMServiceScrapes (the kubelet is the agent on each node that runs its pods) | the Service that **prometheus-operator** creates (`prometheusOperator.kubeletService`, which only its own setting controls) |
| `coredns` | the addon's `kube-dns` Service, selected by `k8s-app=kube-dns` |
| `apiserver` | `default/kubernetes` |

The three chart ServiceMonitors that remain now carry no `authorization`. If anyone later enables
`VM_ENABLEDPROMETHEUSCONVERTER_SERVICESCRAPE` on the vm-operator, the converter will turn them into
VMServiceScrapes that send no credentials. Those would duplicate the hand-written ones. They would
also fail against kubelet `https-metrics:10250` and `default/kubernetes`, because both require a
bearer token (a credential sent with each request). Clear or exclude the three ServiceMonitors before you turn that setting on.

Compared with the live 89.2.3 release, the change removes 4 ServiceMonitors, 4 kube-system Services
and 4 empty dashboards. Renovate pull request #1123 (89.2.4) merged with an empty diff. #1125
superseded it.

The Flux dry-run alert `VMServiceScrape ... webhook ... EOF` at 21:22 was unrelated and brief.
Three facts show that:

| Fact | Detail |
|---|---|
| Timing | it fired 14 seconds after commit `4326adbc` |
| Flux | `monitoring-configs` reconciled to Ready at the same revision |
| vm-operator | 0 restarts, and no webhook or TLS errors in its log |

No CI job rendered the charts, so every existing job passed. `kubeconform` validates the HelmRelease
custom resource, never the chart's own templates. The `helm-render` job adds that missing check.

| Property | Value |
|---|---|
| Job and script | `helm-render` in `.github/workflows/validate.yaml`, `scripts/ci/helm-render-check.sh` |
| Added in | `2cdaa5c8`, made stricter in `703f3bc5` |
| Coverage | 12 HelmRelease charts at their pinned versions: 11 from HTTP repositories and 1 from an OCI registry |
| Result on `4326adbc` (before the fix) | `FAIL kube-prometheus-stack@90.0.0`, exit 1 |
| Result on the fix | 12/12 rendered, exit 0 |
| Runtime | 9 s locally, with its own separate Helm repository config |
| Required flag | `--api-versions monitoring.coreos.com/v1`. Without it, traefik's `servicemonitor.yaml` stops with "You have to deploy monitoring.coreos.com/v1 first", although the cluster has that CRD (custom resource definition) |
| Guards against skipping a chart without notice | Finding no charts, a malformed manifest, a HelmRepository name collision and an incomplete `spec.chart.spec` each exit 1. Releases pair with values by document index |
| Known gap | The `image-pin` and `kubeconform` jobs still download yq without a checksum. `helm-render` verifies its own |

### 2026-09-06 — Immich machine-learning inference moved to the immich-vm integrated GPU (OpenVINO)

Earlier on 2026-09-06, the Immich machine-learning (ML) service moved to immich-vm and ran there on
the CPU. The `-openvino` image runs inference, the model computations, on the VM's Meteor Lake Arc
integrated GPU through ONNX Runtime's OpenVINO execution provider. Commit: `4a5255cf`. The design plan was removed after `aadf03e6`.

| Change | Detail |
|---|---|
| Image | `immich-machine-learning:v3.1.0-openvino` (Python 3.13, onnxruntime-openvino 1.24.1, intel-opencl-icd 26.22) |
| GPU access | `gpu.intel.com/i915: "1"` through the Intel device plugin. The pod's `supplementalGroups` are 983 (video) and 987 (render) |
| Memory limit | raised from 2355Mi to 4Gi, because OpenVINO keeps model buffers in system RAM. Requests (the resources Kubernetes reserves for the pod when it schedules it) unchanged |
| rapidocr mount path | changed from `python3.11` to `python3.13`. The path follows the image variant |

Gate results:

| Check | Result |
|---|---|
| `get_available_openvino_device_ids()` | `['CPU', 'GPU']` |
| First `/predict` | `4.52 s`. This first-request time includes compiling the model for the GPU |
| A warm request, after the first | `0.022 s` |
| GPU compute counter | the ML worker's i915 `drm-engine-compute` counter rose from 112240128 ns to 124969624 ns (12.73 ms) during one /predict request, while the render, copy, video and video-enhance counters stayed at 0 ns |
| Cold session reload from the compiled model file | answered in 1.09 s |
| GPU clock | peaked at 1517 MHz |
| Journal | clean: no errors in the system log |

Follow-ups: lower the memory limit after a week of metrics. FP16 (a number format with lower precision)
(`MACHINE_LEARNING_OPENVINO_PRECISION`) and a larger CLIP model are separate changes.

### 2026-09-06 — The NAS scrub stalled immich-vm again, and five unrelated init Jobs waited on it

At 18:23 local time, `PodsPending` and `PodPhaseNotRunning` fired for five pods at once:

| Pod |
|---|
| `audiobookshelf-init` |
| `home-assistant-admin-setup` |
| `immich-admin-setup` |
| `n8n-user-provision` |
| `couchdb-init` |

They were the daily re-run of the init Jobs (one-off tasks that set up an app), created at 18:11.
Flux's force setting and each Job's TTL (the time after which Kubernetes deletes a finished Job)
drive that daily re-run.
The scheduler put all five on `immich-vm`. Every one stayed in `ContainerCreating` for 33 minutes,
with `FailedCreatePodSandBox … DeadlineExceeded`: the node could not create the pod's sandbox, the
environment its containers run in, before the deadline. `NodeHighIOWait` fired at the same time on
`192.168.1.231`, the address of immich-vm.

The cause was the monthly mdadm check of the NAS `md1` array, which starts on the first Sunday at
00:57. mdadm is the Linux software-RAID tool, and its check reads the array to test that it is
consistent. The member drive that had failed SMART, the drive's own health check (serial `WS21F7E8`, written up on 2026-08-02) was still
in the array, because its warranty replacement (RMA) drive was still in transit. The check ran fast
until about 06:30. Then it reached that drive's bad region, and each read took up to 87 s. The disk
image of `immich-vm` lives on that array, so containerd (the container runtime) on the VM could not create a pod sandbox
before its deadline.

| Evidence | Value |
|---|---|
| immich-vm iowait (CPU time spent waiting for the disk) | 0-3% overnight, ~50% from 06:30, 73% by 17:30 |
| Check progress | 66.2% at 853 KB/s, estimated 17 days to finish |
| Reads queued on the failed drive | 5, later 32 (`/sys/block/sdd/inflight`). Every other member had 0 |
| Device letter | `sdb` in August, `sdd` now, because the 2026-09-02 NAS reboot changed it. Identify a drive by its serial number |
| `iostat -dx %util` on the members | 0 on all six. Since kernel 5.x, `io_ticks` advances only when a read or write starts or completes, so one stuck read shows nothing. `inflight` is what shows the stall |

Four of the five Jobs have nothing to do with Immich. They ran on `immich-vm` because nothing kept
them off it. `immich-server` pins itself to that node with a `homelab/gpu=intel` nodeSelector (a rule that places a pod only on
nodes with a given label). But
the node carried no taint, a mark that keeps off every pod that does not accept it. So the scheduler
could place any pod without a pin there, and it prefers the emptiest node:

| Node | Running pods | CPU requested | Memory requested |
|---|---|---|---|
| worker-node | 56 | 5170m of 32 | 15.4 Gi of 61 |
| worker-node-2 | 27 | 2280m of 16 | 6.0 Gi of 30 |
| immich-vm | 6 | 520m of 4 | 1.1 Gi of 11.6 |

The 2026-08-02 scrub affected `popeye` and `postgres-update-extensions` in the same way. That time,
the problem was recorded as a known symptom and not fixed.

The operator stopped the check with `echo idle > /sys/block/md1/md/sync_action`. The write waited in
D-state (a sleep that waits on the disk and cannot be interrupted) for 2.5 minutes, while the 32
queued reads finished at about one per 15 s. That wait is expected; it is not a hang. The check
reported `idle` at 18:45:07. All five Jobs succeeded within 30 s, and nobody had to delete a Job,
because the kubelet (the agent on each node that runs its pods) retries sandbox creation by itself.
`NodeDown` for `192.168.1.231` fired briefly while the queue emptied, then cleared. Every alert had resolved by 18:47.

| Follow-up | Status |
|---|---|
| Swap `WS21F7E8` (RaidDevice slot 2, currently `sdd`) before the next check on 2026-10-04 | done 2026-09-08: `WS24PTRD` was rebuilt into slot 2. See the 2026-09-08 entry |
| Give `immich-vm` a `NoSchedule` taint so that only Immich and the DaemonSets that run on every node run there | shipped in `83eb9674` and `230eeb8a`. Taint applied at 21:27 BST |

| Change | Detail |
|---|---|
| Taint | `homelab/dedicated=immich:NoSchedule` applied to immich-vm at 21:27 BST on 2026-09-06 with `kubectl taint`. `k3s_node_taints` in `host_vars/immich-vm.yml` covers a re-join, because k3s reads `node-taint` only when the node first registers |
| Tolerations (which let a pod run on the tainted node) | immich-server, immich-machine-learning, the immich-admin-setup Job and intel-gpu-plugin. alloy and node-exporter already tolerated any NoSchedule taint |
| ML moved | immich-machine-learning is pinned to immich-vm. Its model cache is now the PVC (PersistentVolumeClaim, a request for lasting storage) `immich-ml-cache`, declared in git (10 Gi, local-path), under `/mnt/k8s-storage`. That path is a bind mount (a directory made visible at a second path) of `/home/k8s-storage` on the VM's 125 G home volume. k3s-agent carries `RequiresMountsFor=/mnt/k8s-storage`. Helm deleted the old PVC that the chart owned on worker-node |
| Pods that left the VM | coredns-ha, loki-canary, kube-state-metrics and prometheus-operator, each deleted once, because a NoSchedule taint never evicts a running pod. Five pods remain: immich-server, immich-machine-learning, intel-gpu-plugin, alloy and node-exporter |
| Stays off the VM by design | immich-vm-heal (it starts the VM from outside), immich-backup (148 G on worker-node-2; on the VM it would sit on the same NAS array), immich-init-extensions (it lives in the databases namespace, a separate group of objects), Postgres and Redis (shared) |

### 2026-09-05 — Pre-reboot checks whose retries sampled the same moments skipped the weekly reboot, and Loki began rejecting a week-old log line every hour

From 04:48Z, `AlloyLogDeliveryFailing` fired every hour on both workers. Alloy (the log collector)
and Loki (the log store) had no fault. Two unrelated defects combined, and the weekly reboot had
hidden the second one for months.

A Flux Kustomization is one set of manifests that Flux applies from a folder of this repository.
phase1, the first maintenance stage, checks them before the reboot. If any Kustomization does not
report `Ready=True`, no node reboots. Flux reports `Ready=Unknown/Progressing` for roughly one
second of each 60s reconcile, the regular pass in which Flux compares the cluster with the repository
and applies the differences. So a single check finds all of them True only 76-83% of the time. A
measurement against the live, healthy cluster found 5 failures in 30 samples. The check retried with
`retries: 3, delay: 30`. What decides how many different points within the reconcile cycle the
retries see is
`gcd(delay, interval)`, the greatest common divisor of the delay and the reconcile interval. The rule
"delay must not divide 60" looks right, but it is not the test:

| delay | gcd(delay,60) | different points within the reconcile cycle |
|---|---|---|
| 7s | 1 | 60 |
| 24s | 12 | 5 |
| 30s | 30 | 2 |

With `delay: 30`, the four attempts acted like two. All four found a Kustomization in `Progressing`,
phase1 exited 2, and no node rebooted.

The skipped reboot mattered because of a coincidence nobody had noticed. The timer `OnCalendar=Sat
*-*-* 04:30:00 UTC` repeats every 168h, and Loki's chart default for
`reject_old_samples_max_age` is also 168h. Every hour, Alloy's `loki.source.kubernetes` re-opens
each log reader and sends again the last log line of each idle container: svclb, config-reloader,
metrics-server, cainjector and kyverno. Each week, the reboot refreshed those lines about an
hour before they grew too old. The first skipped reboot let them pass 168h, and Loki answered
`has timestamp too old`.

No logs were lost. Loki discarded 480 entries per 12h. Alloy reported 6143 dropped against 1,228,685
sent. The figures differ because, if Loki answers 400, Alloy's client marks the whole batch as
dropped, while Loki stored the fresh entries in that batch. For the true figure, read `loki_discarded_samples_total`.
`loki_write_dropped_entries_total` is only an upper bound.

| Fix | Change |
|---|---|
| retries of the checks before rebooting, which sampled the same moments | `retries: 20, delay: 7`. 7 and 60 share no common factor greater than one, so the 21 attempts sample different points within the reconcile cycle. Longest measured run of failures: 2 |
| the log age limit, with no allowance for delay | `reject_old_samples_max_age: 720h`, matching `retention_period` |

The condition itself stayed `!= "True"`. An earlier draft relaxed it to `== "False"`, so that
`Unknown` would pass. Review found that this change fails open: if the check cannot tell the state,
it allows the reboot. A kustomize-controller (the part of Flux that applies Kustomizations) that dies during a reconcile leaves `Unknown` set
forever, so the check would then allow a reboot on a broken cluster.

Shipped in `0e78e618`. The re-run that night passed the checks before rebooting on its first attempt, with no
retries. It rebooted all four nodes without errors (`failed=0
unreachable=0 rescued=0`, `pkg-upgrade: OK` on every node), and the alert
cleared. immich-server needed three restarts before it passed its startup probe (the check that
decides whether a new container has finished starting) and became Ready,
during the cold start of the GPU VM. Its startup time allowance is tight, and is worth widening in a
separate change.

### 2026-08-20 — A power cut, and both workers rebooted themselves an hour after the power returned

Mains power failed at 12:35 and returned at 16:03. All four nodes and the NAS booted by themselves.
The outage itself needed no explanation. The hour after it did: in that hour both workers rebooted
themselves, and the control plane restarted `k3s` eight times, with nobody logged in.

The control plane booted at 16:03:17 with its kube-proxy ClusterIP DNAT wedged: the rules that route
traffic sent to a cluster-internal service address (a ClusterIP) to a pod were stuck. The watchdog
`clusterip_heal_cp` exists for that kind of failure. It restarted `k3s` three times:

| Restart | Result |
|---|---|
| 16:05 | recovered |
| 16:24 | probe rc=1, health not confirmed |
| 17:18 | probe rc=2 |

`k3s` settled at 17:20:45.

While the API server kept going up and down, both workers judged themselves cut off from the control
plane (`cp_direct=0 kubelet=0 gw=1`: the direct check of the control plane's API server and the
kubelet check failed, and the gateway check passed). They went through the first step of
`node_isolation_heal`, the L1 restarts of `k3s-agent` (the cluster service on each worker), and
reached its last step, a reboot of the node itself. The stagger worked. A worker with a higher index waits longer before it reboots itself:
worker-node (index 0) went first, and worker-node-2 (index 1) seventeen minutes later, so the two
workers never rebooted at the same time.

| Time (BST) | Event |
|---|---|
| 12:35–12:42 | power lost: control plane 12:36:06, worker-node 12:36:25, worker-node-2 12:35:44, immich-vm 12:42:14 |
| 16:03 | power restored; all four nodes and the NAS boot |
| 16:05 | control-plane ClusterIP DNAT wedged. `clusterip-heal-cp` restarts `k3s` (#1), which recovers |
| 16:24 | wedged again. `k3s` restart #2, probe rc=1, health not confirmed |
| 16:39:52 | worker-node reboots itself after 1177s cut off. The L1 restarts had not recovered it |
| 16:56:49 | worker-node-2 reboots itself after 1501s cut off (stagger index=1) |
| 17:18 | control plane wedged a third time. `k3s` restart, up at 17:20:45 |
| 17:21 | both workers log `recovered (tunnel up; cp=1 kubelet=1 gw=1)`, and have stayed stable since |

Every recovery step was automatic. The manual work was deleting what the outage left behind:

| Leftover | Detail |
|---|---|
| two authentik pods in a terminal state (a final state that a pod never leaves) | `Error` and `Init:Error`, from the 16:03 boot. They belong to the class of pods a reboot leaves behind and nothing deletes |
| two `immich-vm-heal` Jobs | they hit `DeadlineExceeded` while immich-vm was still booting |

Both pairs of alerts cleared when these were deleted. `NodeIsolationHealRebooted` cannot be cleared
by hand. Its rule is `time() - node_isolation_heal_last_reboot_timestamp < 3600`, so it expired by
itself at 17:56:49.

**Open item.** The third control-plane wedge happened at 17:18, 75 minutes after boot. The first two
fit the race that happens during a cold start: a timing fault, while the node is still starting,
whose result depends on which of two steps finishes first. The third does not, so the wedge is not
only a boot problem. The fix for the root cause uses nftables (the Linux packet filter).
That fix stays deferred, waiting on kubernetes#136786. If the
wedge happens again outside a boot window, that recurrence is what to investigate.

Checks after recovery, with no configuration change made:

| Check | Result |
|---|---|
| pstore blobs (saved kernel crash records) and filesystem errors after the hard power loss | none on any node |
| Postgres | 2/2 (primary `main-postgres-12`) |
| MySQL | 2/2, with haproxy 2/2 and orchestrator 3/3 |
| CouchDB | 2 |
| Redis | replication 2, plus 3 sentinels |
| Flux | 7/7 |
| Ingress hosts | all 16 answer through LAN Traefik |
| NAS | `md1` raid6 `[6/6]` and `md0` `[2/2]`. The known SMART-failed `sdb` is unchanged and still waits for its RMA replacement |

### 2026-08-14 — Extension ownership cannot be given to the app's role, and Immich picks its vector extension by what is available

The previous day's crashloop (a container that crashes and restarts over and over) raised two
questions. An extension is an add-on module inside a database. Which other extensions does a
superuser (a database account with every privilege) own, instead of the app that needs them? And
can that ownership be handed over? An audit of every extension in all eight databases answered the
first question:

| Owner | Extensions |
|---|---|
| `postgres-admin` | only immich's `vector`, `cube` and `earthdistance` |
| each app's own database role (its database account) | `mealie.pg_trgm`, `n8n.uuid-ossp` and immich's `pg_trgm`/`unaccent`/`uuid-ossp` |
| `postgres` | `plpgsql`, in every database. This ownership has no effect, because no app updates it |

Of the three extensions in the first row, only `vector` matters. immich v3.1.0 runs
`ALTER EXTENSION` only against the vector-family extension, so `cube` and `earthdistance` are
created once and never updated.

Two attempts to hand ownership over failed. Both ran against the live cluster on PostgreSQL 18.6:

| Attempt | Result |
|---|---|
| `ALTER EXTENSION vector OWNER TO immich` | `syntax error at or near "OWNER"`. PostgreSQL has no `OWNER TO` form for extensions |
| change `pg_extension.extowner` by hand, then update as the new owner | `permission denied to update extension` / `Must be superuser to update this extension.` |

The second attempt settles the question. `vector` is `superuser=t, trusted=f`: it needs a superuser
to install, and it is not marked as safe for other users. PostgreSQL requires a superuser to run an
untrusted extension's update script, whoever the owner is. The test ran inside a transaction that was
then rolled back, against `pageinspect`, which carries the same two flags and ships real upgrade
scripts. So the only design that works is a privileged job that runs the `ALTER` before the app
starts. `postgres-update-extensions` and `immich-init-extensions` already work that way.

CNPG 1.30's declarative `Database.spec.extensions` does not replace those jobs. (CNPG, short for
CloudNativePG, is the operator, the software that manages the Postgres cluster.) If `spec.version` is set and differs
from the installed version, `updateDatabaseExtension` emits `ALTER EXTENSION … UPDATE TO`; otherwise
it does not emit that update statement. So an entry without a `version` creates the extension once and never updates it. An entry
with a fixed version needs a manual update that renovate cannot see.

The audit did find the next problem of the same kind. Immich picks its vector extension by what is
available, not by what is installed. In `VECTOR_EXTENSIONS = [VectorChord, Vector]`, the first name
present in `pg_available_extensions` wins. If a CNPG image ever ships `vchord`, immich will run
`CREATE EXTENSION vchord` as the `immich` role, which is not a superuser. That is fatal for an
untrusted extension, and immich then tries to drop `vector`. The `standard` image ships pgvector and
no vchord today. So `0e00822a` sets `DB_VECTOR_EXTENSION: pgvector`, so that a change in the upstream
image cannot switch extensions. A move to VectorChord now needs someone to change that value on
purpose.

One remaining risk has no automatic repair. If an image ever ships a pgvector older than the
installed version, immich throws `invalidDowngrade` at startup. No job can fix that, because
`ALTER EXTENSION` cannot downgrade. The fix is to pin the image back to the version it ran before.

### 2026-08-13 — A CNPG minor-version update left Immich crashlooping, and the job that repairs it ran 3m35s too early

Renovate's commit `4607a47a` moved `ghcr.io/cloudnative-pg/postgresql` from `18.4-standard-trixie`
to `18.6-standard-trixie` across eight files, including the CNPG `Cluster`. The 18.6 image ships
pgvector **0.8.6**, but the `immich` database still held **0.8.2**. Immich updates pgvector itself at
startup. It connects as database user `immich`, which does not own the extension. So
`ALTER EXTENSION vector UPDATE TO '0.8.6'` failed with `must be owner of extension vector`
(SQLSTATE 42501). The microservices worker exited 1, and `immich-server` crashlooped (its container
crashed and restarted over and over). PG 18 has no
`ALTER EXTENSION … OWNER TO` form. So immich can never own the extension, and only a
`postgres-admin` connection can raise the installed version.

Postgres itself never went down. The alert that paged was `ScrapeTargetDown{job="immich-server"}`,
and the cluster reported `Cluster in healthy state` the whole time.

`postgres-update-extensions`, a CronJob (a Job that Kubernetes runs on a schedule), already repairs
this case, as `postgres-admin`, but it ran weekly, on
Sunday at 06:00 UTC. The commit merged on a Thursday, so immich would have stayed unavailable for
about three more days. A manual run of that CronJob raised vector to 0.8.6, and immich recovered.

`immich-init-extensions`, a one-off Job that prepares the database extensions, should have prevented
the outage by itself. Renovate edits its image tag in
the same commit, and `kustomize.toolkit.fluxcd.io/force` makes Flux re-create the Job, because the
existing Job's pod template, including its image, cannot be changed in place. The Job did run again, but 3m35s too early, because Flux starts the Job
and the rolling upgrade at the same time. In the rolling upgrade, the Postgres instances restart on
the new image one at a time, and one of them becomes the primary, the instance that accepts writes.

| Time (UTC) | Event |
|---|---|
| 18:03:37 | `immich-init-extensions` pod starts |
| 18:03:39 | `main-postgres-11` starts on 18.6 |
| 18:07:12 | `main-postgres-12` starts on 18.6 and becomes primary |

So the Job read the extension catalogue from the outgoing 18.4 primary. And its
`CREATE EXTENSION IF NOT EXISTS` never raises an installed version in any case.

These changes fix both causes. First, the Job now waits until the primary reports the
`server_version` of the Job's own image before it touches extensions. The output of
`postgres --version`, without its `postgres (PostgreSQL) ` prefix, is that string, character for
character, so the wait compares two strings and parses no version numbers. Second, the CronJob runs daily. If a CNPG
rebuild ships a newer extension under an unchanged tag, renovate has nothing to update, and nothing
re-creates the Job.

The loop that runs `ALTER … UPDATE` for each extension now lives in `update-extensions.sh`.
`configMapGenerator` packages it as the `postgres-extension-update` ConfigMap (a Kubernetes object
that holds files or settings), which both workloads mount. The first attempt copied the loop into both workloads, and the peer review rejected that. Two
earlier corrections had already fixed this loop for reporting success on a failed update. The likely
failure is a third correction that reaches one copy and not the other. A generated ConfigMap name
carries a hash of the content. So editing the script renames the ConfigMap, kustomize (the tool that builds the
manifests, the Kubernetes configuration files) rewrites both
volume references, and Flux re-creates the forced init Job. As a separate `.sh` file, the script
also falls under the repo-wide shellcheck job, which never saw it inside a YAML block scalar (a
multi-line string in the YAML).

For the checks below, `yq` extracted the Job's script, and the shared script was used as it stands.
Both ran under `/bin/dash` (the CNPG image's `/bin/sh`) against fake versions of `psql`/`postgres`.
A mutant is a deliberate break in the code. KILLED means the checks failed on it, as they should.

| Check | Result |
|---|---|
| Rolling upgrade completes after 3 polls | Job waits, then updates all 3 extensions, exit 0 |
| Extension name containing a space | stays whole through the read loop |
| One `ALTER` fails | the other extensions' successful updates stay, `FAILED vector` reported, exit 1 |
| Empty extension list | exit 1 rather than a success that reports nothing wrong |
| Rolling upgrade never completes | exit 1 at 120 attempts |
| Mutant: remove the `sed` that strips the prefix | KILLED |
| Mutant: change `RC=1` to `RC=0` | KILLED |
| Mutant: Job stops calling the shared script | KILLED |

### 2026-08-08 — k3s v1.36.2 → v1.36.3, and the rolling restart that ran without its lock

This was a patch update within the same minor version, on the stable channel: `stable` and `latest`
both return `v1.36.3+k3s1`. The `k3s-upgrade` skill swapped the program file. It downloaded the
new file, checked its sha256 checksum, and copied it to all four nodes. It kept the previous file at
`k3s.prev`. The approved restart, one node at a time, then ran in this order:

| Node | Restart time |
|---|---|
| control plane | 13:34:57 |
| first worker (W1) | 13:35:42 |
| second worker (W2) | 13:36:20 |
| immich-vm | 13:36:58 |

No repo commit covers the upgrade itself, because k3s is a manual `/usr/local/bin/k3s` binary that
neither Flux nor pacman manages.

| Check during the upgrade | Result |
|---|---|
| Pods | held at 108, with 0 unhealthy |
| Flux | stayed 7/7 |
| Firing alerts | only the Watchdog dead-man alert, which always fires to prove that alerting works |

`k3s.prev` was deleted the same day, on purpose. A patch
downgrade means copying the old binary to the nodes again; a minor-version downgrade means a restore
from backup.

Even so, the rolling restart exited 4 and sent its Telegram failure alert.

| Fact | Value |
|---|---|
| Drift-heal run (the Ansible run that re-applies each node's configuration) | 13:30:33–13:36:54, started by the sync timer after it pulled `cae7d3d2` |
| Rolling restart run | started 13:34:41, held no lock |
| immich-vm restart module | ran 13:36:52, node up on v1.36.3 at 13:37:00 |
| Ansible result | `UNREACHABLE: Data could not be sent to remote host "192.168.1.231"`, exit 4 |
| node-maintenance SSH master connections to immich-vm | two, ports 41928 and 31690, both belonging to the drift-heal |

Two Ansible runs ran as root on the control plane at the same time. The Ansible defaults there are
`ssh_args = -C -o ControlMaster=auto -o ControlPersist=60s` with `control_path_dir = ~/.ansible/cp`.
So both runs share one SSH master connection per host, and each run's SSH sessions to that host
travel inside it. For immich-vm, the rolling restart opened no master connection of its own; it
used the drift-heal's. immich-vm was the restart's last host, and the drift-heal finished two seconds
after the restart module ran. Closing that master connection killed the restart's channel, which was
still in use. W1 and W2 were not affected, because their restarts finished before 13:36:54.

The restart itself succeeded, and the checkpoint (a saved snapshot of cluster state) matched before
and after. What was lost is the
check that follows the restart: immich-vm skipped the wait for its node to report Ready, and the
check of the live configuration of the kubelet, the agent on each node that runs its pods
(kubelet-configz). Both were run by hand afterwards, and
all four nodes report `leaseDuration=60 reportFrequency=1m0s`.

`node-maintenance-lock.sh` has existed for this case since 2026-05-25, and `config`, `phase1` and
`phase2` all use it. It holds a lock, so that only one maintenance run works at a time.
`rolling-restart` was added later, and nobody wrapped it in the lock script. It now runs under
`node-maintenance-lock.sh wait --` (`f3c6abd7`). It uses `wait`, not `skip`, because an operator
starts it by hand, and a run that did nothing and reported nothing would look like "restart done".
`TimeoutStartSec` went from 15min to 25min. `wait` mode is `flock -w 900`, which waits for the lock,
so with a 15-minute limit a queued run could time out before Ansible started. A live test on the
control plane confirmed the wrapper: it blocks while another run holds the lock, and takes the lock
once it is released.

`KUBERNETES_VERSION` in `.github/workflows/validate.yaml` moved from 1.36.2 to 1.36.3 to match the
cluster, as that file's own comment instructs. The `v1.36.3-standalone-strict` schemas exist upstream.

### 2026-08-08 — The maintenance trigger answered 403 for two weeks

Phase 1 (which updates and reboots the control plane) and phase 2 (which then updates the workers
one at a time) both completed:

| Check | Result |
|---|---|
| Reboots | all four nodes rebooted in order |
| `PLAY RECAP` | `failed=0` on every host |
| Run record | the run wrote `node_maintenance_last_run_unixtime` |

The last line of the run was `curl: (22) The requested URL returned error: 403`. It came from the `ExecStopPost` step,
which asks Claude to review the alerts after the reboot. `ExecStopPost=… || true` ignored the
error.

| Fact | Value |
|---|---|
| Reboot window | 04:33–05:26 UTC |
| Trigger secret in SOPS | rotated 2026-07-31 (`c0301bcb`) |
| Trigger secret on the control plane | `/etc/node-maintenance/claude-trigger-secret`, mtime 2026-04-27 |
| Bot response | HTTP 403. The secret check rejects the request before it reads the body |
| Runs with no alert review | 2026-08-01 and 2026-08-08, `curl: (22) … 403` in both journals |

The secret had two copies, and only one of them was rotated. `install.sh` also had no line for
`telegram-notify-claude.sh`. Someone had placed the control plane's copy by hand in April, and no
sync path updated it, so editing the file in git would have deployed nothing.

`telegram-notify-claude.sh` now reads the secret from the bot's own `$TRIGGER_SECRET` inside the pod,
and the control plane keeps no copy. Reading the secret there gives no one new access, because
anyone who can `kubectl exec` into that container (run a command inside it) can already read the
variable. If the POST fails, the script sends its own Telegram alert, because its caller's `|| true`
discards a non-zero exit code. `install.sh` now installs the script, in both full and `--sync-only` mode.

The same unit had three more faults in the same run:

**`StartLimitIntervalSec` and `StartLimitBurst` were under `[Service]`.** Both belong in `[Unit]`.
systemd logged `Unknown key 'StartLimitIntervalSec' in section [Service], ignoring` on every reload.
So the limit that the file documents, 3 attempts in 2h, never applied to the phase 2 retry. Both
settings have moved.

**Nothing removes the pods that a graceful node shutdown leaves behind.** The shutdown evicts each
pod (removes it from the node), and each evicted pod ends in a terminal phase, a final state it never
leaves. The ReplicaSet controller (which keeps a set number of copies of a pod running) ignores the
terminal pods it owns. If their number stays at or below `--terminated-pod-gc-threshold`, which
defaults to 12500, the pod garbage collector does nothing. This run left 11 such pods, 10 `Succeeded`
and 1 `Failed`, which kept `PodPhaseNotRunning` firing. The run on 2026-08-01 left 14 pods and 4
alerts. Before this change, phase 2's cleanup missed these pods for two reasons: it matched only
`status.phase=Failed`, and only inside `phase2_pod_gc_namespaces`. It now selects by owner: terminal
pods controlled by a ReplicaSet, StatefulSet or DaemonSet, in every namespace. (A StatefulSet gives
each pod a stable name; a DaemonSet runs a pod on each eligible node.) At delete
time it checks the phase again on the server, because a StatefulSet pod keeps the same name when it
is re-created. It leaves pods owned by a Job, and pods with no controller. `phase2_pod_gc_namespaces`
is gone.

**The CouchDB minimum-size check stopped two nights of replication.** If any source backup fails
validation, `backup-replication` stops at Step 1. A LiveSync rebuild, started from the client side,
re-created `obsidian-personal` on 2026-08-06 15:52 UTC, after that morning's dump. From 2026-08-07
on, every dump came out at 88K instead of 15.8M. That is under the 100KB minimum for CouchDB, so the
08-07 and 08-08 runs both stopped before the rsync. `kube_cronjob_status_last_successful_time` for
`backup-replication` still pointed at 2026-08-06 03:30 UTC. The source backups stayed on
worker-node, which is the purpose of the stop, and both nights sent the "Backup Validation FAILED"
Telegram report. A minimum size catches a truncated dump, but it cannot also follow how much data
the vault holds. The minimum is 20KB now. Checking that each database is complete stays the job of
`couchdb-backup` itself.

### 2026-08-07 — The sync path ran the drift-heal playbook twice on every push

`node-maintenance-sync.service` needed 12min59s to deploy one commit (`fe0ff835`). It ran the full
`node-config` Ansible playbook, the drift-heal that re-applies each node's configuration, across all
four hosts twice.

| Fact | Value |
|---|---|
| Run 1: `install.sh:163` starts `node-maintenance-config.service` every time, with no condition | 18:30:29 to 18:38:22 BST (7min53s) |
| Run 2: `sync-from-git.sh:63-66` starts the same unit once `install.sh --sync-only` returns | 18:38:22 to 18:43:24 BST (5min02s) |
| `node-maintenance-sync.service` `TimeoutStartSec` | 20min |
| `node-maintenance-config.service` `TimeoutStartSec` | 15min |
| Callers of `install.sh` | `sync-from-git.sh:57` (always `--sync-only`), plus a manual first-time setup with no flag |

A 2026-06-05 entry had already recorded the double run as a known problem. The double run re-applied
the configuration to every host at once, and so bypassed a staged rollout (W2, then W1, then the
control plane). That entry told operators to stage a rollout with a manual `rsync` plus
`ansible-playbook --limit`, and never with `install.sh --sync-only`. The double run itself stayed in
place for two months.

The fix: if `SYNC_ONLY -eq 0`, that is, if the run has no sync-only flag, `install.sh` starts the
playbook. Otherwise it does not.

| Path | Playbook runs before | Playbook runs after |
|---|---|---|
| Manual first-time setup, no flag | 1 | 1, from `install.sh` |
| Sync timer, HEAD changed (the checked-out commit changed) | 2 | 1, from `sync-from-git.sh` |
| Sync timer, fresh clone | 2 | 1. `sync-from-git.sh` passes `--sync-only` on this path too |
| Standalone `install.sh --sync-only` | 1, the behaviour the 2026-06-05 entry warns against | 0 |

`README.md:35` and `:117` already described the fixed behaviour: `install.sh --sync-only` runs
systemd's daemon-reload (systemd rereads its unit files) and sets file permissions, then `node-maintenance-config.service` re-applies
the configuration. The guard took effect on the run that deployed it, because `sync-from-git.sh`
runs `install.sh` from the repo it has just pulled. That run confirmed the fix:

| Measure | Before (`fe0ff835`) | After (`4aa51ae5`) |
|---|---|---|
| `install.sh --sync-only` | 7min53s, drift-heal included | 2s |
| Playbook runs | 2 | 1 |
| Sync unit total time | 12min59s | 4min37s (`Result=success`) |
| Unused share of the 20min `TimeoutStartSec` | ~7min | ~15min |

The double run cost time, but it did not make the result wrong. The playbook is safe to repeat, and the second run
reported `changed=0`. But if one host had run slow, systemd would have killed the deploy. Two runs of
about 6min each, plus the git fetch, left only about 7min of the 20min limit.

Errors still propagate as before. `sync-from-git.sh` sets `set -euo pipefail`, so a failed `systemctl
start --wait` still fails the unit and fires the `ExecStopPost` Telegram alert.

The 18:30 run also caused a 3-minute disruption, and that disruption led to finding all of
the above:

| Symptom | Detail |
|---|---|
| Readiness and liveness probe timeouts (the checks that decide whether a container is ready for traffic and still alive) | `worker-node`, `worker-node-2`, `immich-vm`: 17:32:30 to 17:35:39 UTC, one event each |
| Flux `apps` dry-run failure (Flux tests each change against the API server before it applies it) | `vpol.validate.kyverno.svc-fail-finegrained-require-labels`: `EOF`, recovered on retry at the same revision |

The `ufw reload` on each host caused both. `1a1b36ac` added immich-vm's missing `ufw_rules_base`
entry, and the drift-heal applies it one node at a time. The double run did not cause the
disruption.

### 2026-08-07 — A comment review found three live defects, including a boot barrier that guarded nothing

A pass over every comment and Markdown file in the repo (`fb62fa8c`, `7ae66800`, `03af5ed1`) read
every file that carries comments, about 330 of them, comment by comment. That meant checking each
claim against the live system. Three claims turned out to be code defects, not out-of-date text.
`1a1b36ac` fixed them.

**`k3s-wait-ready.sh` did not do its job on the control plane.** The script is a boot-time barrier:
it holds later boot steps back, and when it finishes it creates `/run/k3s-ready`. It exists so that
`ufw-heal-post-k3s` does not run while kube-proxy and kube-router, the parts that write the node's
network rules, are still writing iptables rules.
Its phase 2 waited for pods matching `k8s-app=kube-router`. But K3s runs kube-router inside the k3s
process, so that selector (a label query that picks pods) matches zero pods, and the wait could only time out. All three phases
shared one deadline, so the useless wait used up the whole 300s. Phase 3, the check that the ufw
chains (groups of firewall rules) are stable, is the reason the barrier exists. It started with its time already spent, and
took zero samples. The control plane's journal had printed the proof at every boot:

```
pods: timeout / WARN: critical pods not ready
iptables: timeout (last_stable=0/3) / WARN: iptables not stable
complete (elapsed=304s, sentinel=/run/k3s-ready)
```

The fix drops the kube-router selector, so `CRITICAL_POD_LABELS` is coredns only. It also gives each
phase its own time limit, capped by the overall deadline (90 + 60 + 120 ≤ 300), so a phase that
times out cannot use up the time of the phases after it. The new test
`roles/k3s_config/tests/test-wait-ready.sh` checks both changes. Three mutants (deliberate breaks in
the code) confirm that, if either change is undone, the test fails. The fix takes effect at each
node's next boot.

**No UFW rule allowed traffic from immich-vm as a node.** `ufw_rules_base` listed `.127`, `.129` and
`.126`, but never gained `.231` when immich-vm joined on 2026-07-10. Traffic mostly worked, because
8472/udp and 10250/tcp are open from anywhere. The new rule has the same form as the other nodes'
rules. It applies on the next drift-heal, one node at a time, with a ufw reload on each.

**Two helpers in the drift-heal alert path were never called.** `extract_fatal_summary()` and
`extract_journal_window()` were defined but unused. So the report of a fatal error carried no
journalctl time window (the log lines from around the time of the failure), only the raw fatal line cut to 300 characters. The report calls both now.
Environment variables can now override the script's paths, so `lib/tests/test-notify.sh` can test
all five branches in a temporary directory.

**Deploying the first three fixes exposed a fourth defect** (`76494c76`). The drift-heal that shipped
them sent this alert:
`applied 9 change(s) [gmk-k3s-control-plane: 3,immich-vm: 3 worker-node: 3,worker-node-2: 3]`. It
reported nine changes but listed twelve, and its separator alternated. The same function caused
both faults.

The counts came from `grep -oE 'changed=[0-9]+' "$LOG" | tail -3`, which keeps the last **three**
matches in the whole log. That command was written for a 3-node cluster, so since immich-vm joined on
2026-07-10, every alert had left out the first host. `FAILED` used the same formula, so a failure on
the first host in the list would not have been counted either. The separator came from
`paste -sd', ' -`. `paste -d` reads its argument as a *list* of delimiters that it uses in turn, so
it joined the fields with `,` and ` ` alternately.

The fix: `recap_body()`/`recap_rows()` take every count from the real host rows of the `PLAY RECAP`,
the rows that match Ansible's standard `ok= changed= unreachable= failed=` sequence. That also
removed a third hard-coded limit: `extract_recap()` printed `recap+5` lines, which works at 4 hosts
but cuts the output without warning at 6. The row match stops after `failed=` on purpose, and does
not require the `skipped/rescued/ignored` fields that follow. If the match depended on the exact
field list and a callback plugin (the plugin that formats Ansible's output) ever changed that list,
every count would drop to zero. That is worse than the stray matching line that a stricter match
would keep out.

The sweep also corrected facts that had gone out of date:

| Wrong claim | Correction |
|---|---|
| coredns-ha is a "Deployment (3 spread replicas)", in three places | it is a DaemonSet, which runs a pod on each eligible node |
| both worker `host_vars` headers gave half the real hardware | W1 is 16c/32t 64GB, W2 8c/16t 32GB |
| `kustomize-controller v1.9.1` | the live version is v1.9.4. The `KUSTOMIZE_VERSION` pin that the comment justifies is still correct, because v1.9.4 embeds the same kustomize/api v0.21.1 |
| a "pre-commit gitleaks hook" | it does not exist. `gitleaks.yaml` provides the coverage |
| two comments on Alertmanager inhibit rules (rules that mute one alert while another fires) | they described matchers that the rules do not use |

A render check that compares meaning then showed that nothing reaching the cluster changed. It built
all 7 kustomize roots, stripped comments from string values, and compared the result with the tree
before the sweep. Every root came back identical.

None of the four defects could fail a check. A barrier that waits for a pod that
cannot exist still exits 0 and still creates its marker file, and the boot goes on. CI sees a
passing shellcheck. The first three were found only because a comment claimed something that
could be checked, and someone ran the check. The fourth teaches more. It was on screen in every
drift-heal alert for a month, and reading the numbers, not the headline, is what caught it. Two of
the four, the missing UFW rule and the alert counts, share a cause with most of the out-of-date
comments above: a hard-coded 3 that nobody revisited when immich-vm made this a 4-node cluster on
2026-07-10.

### 2026-08-07 — A NAS reboot left a dead CoreDNS address that received a quarter of cluster DNS queries

The NAS went down at about 12:52 local time and came back at 13:11. The outage fell outside any
scrub (the NAS's scheduled read of every disk). Nobody read the cause, because the NAS journal needs
sudo. immich-vm went down with the NAS and did not start again by itself.

coredns-ha, the cluster's DNS server, runs as a DaemonSet (one pod per node). DaemonSet pods
tolerate the `unreachable` condition forever. So the dead node's CoreDNS pod stayed
`Running`/`ready=true` in the kube-dns EndpointSlice, the list of addresses behind the DNS service.
kube-proxy kept sending about 25% of cluster DNS queries to a dead IP address.

Authentik, paperless, uptime-kuma, pricebuddy, linkwarden and mysql-haproxy crash-looped (failed
and restarted again and again) for about 2 hours, each failing with
`failed to resolve *.svc.cluster.local`. Because Authentik failed, `home.h0melab.work` returned 500.
Nodes and Flux looked healthy the whole time, even though the DNS service still listed the dead
node's pod. uptime-kuma was one of the failing apps, so the most obvious source of an alert was
itself down.

The fixes ran live, with no manifest change:

| Action | Effect |
|---|---|
| Deleted the dead coredns pod | A deletion sets the pod's deletionTimestamp, which flips its endpoint to `ready=false` even though the kubelet (the Kubernetes agent on each node) on the dead node never confirms. DNS recovered at once |
| Deleted the crash-looped pods | skipped their 5-minute backoffs (the wait between restarts, which grows after each crash) |
| Deleted the stuck `immich-vm-heal` Job | The Job had started at the moment the NAS booted and hung for about 50 minutes. Because of `concurrencyPolicy: Forbid`, it blocked every later heal run |

The next scheduled heal run started the VM. The node went Ready, and every node and app was healthy
after that.

Follow-ups:

- Set `activeDeadlineSeconds` (a time limit after which Kubernetes stops the run) on the heal
  CronJob, because a hung run must not block the healer.
- The cause of the NAS reboot is still unread. If the NAS goes down outside a scrub again, the open
  question about the failing disk `sdb` grows beyond "it fails only during a scrub".

### 2026-08-07 — The Telegram bot's polling stayed stuck after an outage, waiting out its own retry delay

A morning outage of the internet link (WAN) and DNS hit several nodes, from about 06:40 to 11:15
UTC:

| Component | Symptom |
|---|---|
| the bot's `getUpdates` calls (how it fetches new Telegram messages) | failed with `FailedToOpenSocket` |
| the bot's sync sidecar (a helper container in the bot's pod that syncs files from Git) | could not resolve `ssh.github.com` |
| source-controller (the Flux part that fetches Git and Helm sources) | failed its GitHub and Helm fetches until 11:03 |

The outage ended on its own, but the bot stayed down. The grammY runner (the library loop that polls
Telegram) was waiting out an exponential backoff (a retry delay that grows after each failure)
hours long before its next retry. So the pod stayed 2/2 Ready, and its `pgrep` liveness probe
(the health check Kubernetes uses to decide whether to restart a container) passed, while 7
updates waited on Telegram's side (`getWebhookInfo
pending_update_count` showed them, and that read-only check proved the fault). A manual rollout
restart cleared the queue.

The fixes shipped as bot version **1.32.0** plus a change to the Deployment:

- **A liveness check based on a poll heartbeat.** A grammY transformer (code that sees every call
  the bot makes to Telegram) updates `/tmp/claude-telegram-poll-heartbeat`
  after every successful `getUpdates`. The livenessProbe now checks how recently that file changed
  (10 min, `find -mmin`) instead of whether the process exists. So Kubernetes restarts a stuck
  poller about 13 min after polling stops. If a real outage makes the pod restart again and again,
  `PodCrashLooping` reports it.
- **Secrets removed from console output.** The logs of failed polls printed the full bot token.
  Bun fetch errors carry the request URL as a property of the error, and the Telegram API puts the
  token in the URL. The bot now removes known secrets from every argument it writes to the console.
  It inspects each argument to unlimited depth, because Bun prints error chains at any depth but
  cuts plain objects off at depth 2. The leak made a token rotation necessary, because Loki keeps
  the leaked lines for 720h. It is the second rotation, after the transcript leak of 2026-07-31.

### 2026-08-06 — The bot could edit the Deployment that restricts the bot

After the fixes in the entry below, a review of the bot's Kubernetes permissions (RBAC) found that
the bot could edit the control that restricts it. The `claude-telegram-exec` ClusterRole granted
three verbs (allowed actions) together. It was bound in 16 namespaces, **including `claude-telegram`
itself**. So the bot's ServiceAccount could `patch` its own Deployment. A `patch` on a Deployment is
a `patch` on `spec.template`, which sets the command, image, `serviceAccountName` and mounts
(storage made available inside a container). That includes the init container that runs the
git-config sweep (the step that removes dangerous git settings before the bot starts). So the bot,
which the sweep restricts, could edit the sweep. Flux reverts such a change within its 1m interval.
That limits how long a changed spec lives, but not what ran before Flux reverted it.

```
kubectl auth can-i --as=system:serviceaccount:claude-telegram:claude-telegram \
  -n claude-telegram patch deployment/claude-telegram   → yes
```

**Fixing only that permission would have changed nothing real.** The same binding granted `jobs create`.
A Job starts a new Pod that passes admission checks (the checks Kubernetes runs before it lets a
pod start), with any ServiceAccount and any mounts, and
that Pod never runs the init container. So the change narrowed all three verbs. Exec below means
running a command inside a container:

| verb | before | after |
|---|---|---|
| `pods/exec` create | 16 namespaces | 14; `claude-telegram` and `popeye` no longer bound |
| `apps` patch | 16 namespaces | removed everywhere |
| `batch/jobs` create,delete | 16 namespaces | `popeye` only, through a separate `claude-telegram-jobs` role |

Evidence for the removals: the 45 transcript files in the pod contain **zero** `rollout restart`
calls and **zero** `create job` calls, but 113 `exec` calls:

| Namespace | exec calls |
|---|---|
| monitoring | 77 |
| databases | 15 |
| paperless-ngx | 10 |
| loki | 5 |
| immich | 5 |
| stirling-pdf | 1 |

**Nine more namespaces keep the exec grant on purpose:**

| Namespace |
|---|
| audiobookshelf |
| blocky |
| homehub |
| homepage |
| linkwarden |
| mealie |
| pricebuddy |
| rustdesk |
| uptime-kuma |

The review considered them, and they show zero recorded exec calls. Do not propose removing them
again on that evidence alone. `popeye` lost the grant because its documented workflow (create a Job,
read its logs) provably needs no exec. For ordinary apps, zero use across a 30-day window does not
show that exec is not needed, and exec is the standard tool when an app misbehaves. Revisit the
question with a longer window, not by repeating the same query. The transcripts date from before the
bot's permissions were restricted, so they show what the bot did when it was *less* restricted. That
is why zero use of two verbs is the strong signal.

**A correction to an earlier reading.** The claim "`rollout restart` is an operator action, so the
bot losing it changes nothing" is wrong, and the Codex review caught the error. The skills from the
dotfiles repo, which the bot installs when it starts, do call for it, at 32 call sites.
`monitoring-check` names `kubectl rollout restart deploy vmagent-vmagent -n monitoring` as a
numbered step, and `cluster-roll` uses it as its basic operation. The removal is still safe. The
bot has `pods delete` **cluster-wide** through `claude-telegram-ops`. Deleting a pod that a
Deployment manages restarts it, and that permission cannot change what the pod runs.
`cluster-roll` already falls back to deleting pods, as its documentation describes. If the bot
tries a rollout restart, it gets a visible `Forbidden` error, not a silent failure. Follow-up, in
the dotfiles repo: change the skill steps that the bot uses to delete pods instead. The
database guidance in `AGENTS.md` stays as written, because that step really is an operator action
from a workstation.

The grant went because of least privilege (give each account only the access it needs) and zero
observed use, not because of the GitOps rule. RBAC has no way to express "patch only the
restartedAt annotation".

The same change moved `GIT_EXEC_RE` (the pattern of git settings that can run commands) into a
ConfigMap, `claude-telegram-git-exec`. Before, the init container and the sync container each held
a copy written into the code. The copies were identical byte for byte, but nothing checked that
they stayed so. The bot can `get` ConfigMaps in its own namespace but cannot `patch` them, so the
bot, which the sweep restricts, can only read the pattern. Both containers check that the pattern is
not empty, rather than fall back to a default. An empty pattern would match nothing, and every
sweep would report success.

**A trap when checking permissions:** `kubectl auth can-i ... create pods/exec` returns **no** even
when the grant exists. The correct form for a subresource is `create pods --subresource=exec`. The
slash form reports a grant as missing when it exists.

### 2026-08-06 — Only a side effect of the disaster-recovery script let an empty cluster bootstrap

A review at maximum effort covered `33183ce1..bdaab827`: 67 files from the claude-telegram
hardening work, node-maintenance and monitoring. It produced 19 findings. Each survived an
adversarial check (a second reviewer trying to disprove it), three rounds of Codex rulings, and a
first-hand check against the code. Two findings were withdrawn after that check against the code,
and are recorded here so that nobody files them again.

**The finding that mattered.** The `infrastructure-configs` Kustomization (a Flux unit that applies one
folder of manifests) creates objects inside the `homepage` and `rustdesk` namespaces. They are a
ResourceQuota (a cap on the resources a namespace may use) and a LimitRange (default and maximum
resource sizes for each container) from `resource-governance`, and the claude-telegram RoleBindings
(grants of permissions inside a namespace). But the namespaces themselves come from
`apps/*/namespace.yaml`, which belongs to the `apps` Kustomization. And `clusters/apps.yaml`
declares `dependsOn: infrastructure-configs`, so the apps Kustomization waits for that one to be
Ready. On an empty cluster, `infrastructure-configs` fails with `namespaces "homepage" not found`
and never reaches Ready. So `apps` never runs, and no retry can supply the missing namespace. A
cluster that is already running hides the problem.

Only `.backup/secrets-restore.sh` kept the problem from happening. The script creates 21 namespaces
in advance, as a side effect of restoring secrets into them. `homepage` has no secret to restore.
The only secret of `rustdesk` (the beacon key) lives in git, encrypted with SOPS, and that script
does not back it up. So those were the two namespaces the script missed:

```bash
comm -23 <(ls apps/*/namespace.yaml | sed 's|apps/||;s|/namespace.yaml||' | sort) \
         <(grep -oE 'kubectl create namespace [a-z0-9-]+' .backup/secrets-restore.sh | awk '{print $4}' | sort -u)
```

The script now creates both namespaces explicitly, as literal lines, so the grep in the audit
command above keeps working. The circular dependency itself is deliberate and stays. For changes to
a running cluster, `.claude/review-invariants.md:18` already prescribes the workaround in 2 commits.

**A correction.** The review first blamed the new RoleBindings for the deadlock. That was wrong.
`resource-governance` has put 54 namespaced objects into the same namespaces, which the apps layer owns,
since `17c45cc0` (2026-06-04), two months before the base commit of the review. The RoleBindings
followed a pattern that already existed. Finding the real cause changed the fix from "restructure
the RBAC layout" to "add two lines to the DR script".

**Permissions for the coding agent.** `.claude/settings.json` approved these commands without asking:

| Entries | Why they were a risk |
|---|---|
| `kubectl exec`, `port-forward` and `create job` | together, they gave code execution inside the cluster under the operator's cluster-admin kubeconfig (the file with the operator's full administrator access). That is the same reach that `apps/claude-telegram/rbac.yaml` exists to deny the bot |
| `bash` against two skills trees | the trees live in the dotfiles repo, outside this repo's review step, and one of them rewrites live database passwords |

All five entries are removed. The two `deny` entries stay, and each gained its spelling with a
space. `--from=cronjob/backup-replication` was blocked, but `--from cronjob/backup-replication` ran
and returned `job.batch/spike-bypass`. The rules match the command text, and do not know that both
spellings pass the same option.

**Hardening of the bot's start-up.** `GIT_EXEC_RE` missed these git settings that can run commands:

| Setting |
|---|
| `gpg.program` |
| `diff.<driver>.command` |
| `remote.<n>.uploadpack` |
| `core.alternateRefsCommand` |
| `uploadpack.packObjectsHook` |
| `protocol.ext.allow` (which enables `ext::` remotes) |

A test ran the extended pattern against 31
keys it must match and 13 keys it must not match.

The sweep never covered the fork checkout `~/source-code/claude-telegram-bot`, although `set_remote`
manages it.

The sweep is documented to stop on any error at both ends (to fail closed). Its hooks step was the
only one that carried on after an error. That step is now a recursive remove of `.git/hooks`. A
recursive remove needs write permission on `.git`, not on `hooks/`, so the chmod that defeated the
old step does not defeat the new one. The exit codes were checked in the running Alpine pod.

`chezmoi apply` runs `run_*` scripts from the source **directory**, not from the git index. If a hard
reset leaves untracked files in place, an untracked script stays there, and the sync can run it on
its 30-minute timer. The sweep now cleans the source directory to match git.

Last, the step that rewrites `settings.json` did nothing, and reported no error, when the file held
`[]`, `5`, `"oops"` or `true`. In JavaScript's non-strict mode, setting a property on a primitive
value does nothing, and `JSON.stringify` drops properties added to an array. So in each case the
step wrote the bad content back with no hooks block, and exited 0.

Two rounds of Codex review then found that this first version stopped protecting anything as soon as
the pod finished starting. The sweep ran only in the init container (the container that runs before
the bot starts). Everything it removes is state on the PVC (the pod's persistent disk), and the bot
can write that state back as soon as the init container exits. After that, the sync sidecar (the
helper container that runs beside the bot and syncs its files) runs git and `chezmoi apply` against
that state every 30 minutes. A key planted at 00:01 ran at 00:30. The sidecar now runs the whole
sweep again before every cycle. It skips the cycle rather than sync without a completed sweep.

Round two then disproved an assumption of the fix itself: pinning `remote.origin.url` is not
enough. A bare `git fetch` and `@{u}` both find their remote through `branch.<name>.remote` and
`branch.<name>.merge`. Those are ordinary settings, and no pattern can strip them without breaking
normal use. So an attacker can add a second remote and send the fetch there, past the pinned
origin. And the `run_*` scripts in that repo are **tracked**, so no cleaning can remove them. Both
fetches now name `origin <branch>` explicitly. If the fetch or reset fails, the sidecar skips
`chezmoi apply`. Checking that change found a detail that would have broken the dotfiles sync
completely: the dotfiles repo uses **`master`**, not `main`.

None of this fixed an actual break-in. All three checkouts on the PVC hold only `.sample` hooks and
no config keys that can run commands.

**The disaster-recovery gap this change did not close.** Creating the two namespaces in advance
removes one deadlock and exposes the next. `require-networkpolicy` is a Kyverno ValidatingPolicy
with the Deny action. It counts NetworkPolicies with `resource.List(...)` against the **live** namespace.
kustomize-controller first runs a server-side dry run (a test apply on the API server) of its whole
set, before it saves any of it. So if a workload and the NetworkPolicy that would satisfy the rule
arrive in the same set, they still fail with `Namespace must declare at least one
NetworkPolicy`. On a rebuild, that happens in every namespace at once. An ordered bootstrap layer
would be a design change, and this change did not build one. Instead, `.backup/README.md` (now `docs/disaster-recovery/README.md`) Step 6
now documents the failure. It gives a tested workaround that applies namespaces and policies
first (23 namespaces, 58 policies, clean in a server-side dry run). The proper fix is worth doing
before the next DR drill.

**SSH to the nodes.** `agent-diag`, the only command the bot's node SSH key may run, accepted any
path for `cat` and `ls`. It runs as the operator's own login account. So the bot could read any file
that account can read, and send it out through the outbound port 443 that the pod is allowed to use.
Paths now must start with an allowed prefix, and a path containing `..` is refused before the prefix
is tested. The original finding said this gave cluster-admin access, and that claim is
**refuted**: the account's home holds no kubeconfig, and the account cannot read
`/etc/rancher/k3s/k3s.yaml`. `ps -o`/`-eo` were allowlist entries that never worked, because every
call failed the operand check. They are removed, since `ps aux` already shows RSS (memory in use).
The spellings for the journal of the previous boot (`-b-1`, `--boot=-1`, `--list-boots`) now work.
The separated form `-b -1` cannot work, because the check treats a lone `-1` as an option.

**Timer.** August's security scan was set for the 8th, a Saturday. The weekly reboot at Sat 04:30
UTC fell inside the scan's 04:00–05:00 window. With the usual `Persistent=true`, the clash is
survivable: a missed run catches up at the next boot. But the temporary schedule change also set
`Persistent=false`, so the scan would have been lost. The scan moved to the 9th. The date stays in
wildcard form, so if nobody reverts the change, the scan still runs every month rather than never
again.

**Withdrawn findings. Do not file them again.**

| # | Withdrawn finding | Why |
|---|---|---|
| 1 | "The RoleBindings introduce a bootstrap deadlock" | it blamed the wrong change, see above |
| 2 | "The bot lost the approved `rollout restart` in database namespaces" | not a defect, see below |

For the second finding: `rbac.yaml` lists every excluded namespace
with a reason. It keeps read access plus `pods
delete` there, and documents the one-line change that turns the grant back on.

Two test runs proved nothing, and are recorded as such rather than as results:

| Test | Why it proved nothing |
|---|---|
| the path-traversal test `bash ~/.claude/skills/../../../x.sh` | it ran, but so did its control with an absolute path. The session's permission mode approved `bash` either way |
| a check of `*-*-09` with `systemd-analyze calendar` before deploy | it could not run: the session had no SSH, no local systemd and no container runtime. So `systemctl list-timers` after the Ansible run is the real proof |

### 2026-08-05 — A one-line Renovate image-tag change left the MySQL replica impossible to rebuild

Two pull requests from Renovate (the bot that proposes dependency updates), #1008 and #1007, merged
at 19:31 UTC, nine seconds apart:

| Image | Change |
|---|---|
| `percona/percona-server` | `8.4.10-10.1 → 9.7.1-1.1` |
| `percona/percona-mysql-router` | `8.4.10 → 9.7.1` |

Flux applied the change. The StatefulSet (the Kubernetes controller that manages the MySQL pods)
recreated `main-mysql-mysql-0` at 19:35 on the 9.7 image,
and the pod never came up:

```
[Clone] Client: Command COM_INIT: error: 3864: Clone Donor MySQL version: 8.4.10-10
        is different from Recipient MySQL version 9.7.1-1..
[Server] Received SHUTDOWN from user <via user signal>. Shutting down mysqld
```

The clone plugin copies data from a running server (the donor) to a new one, and it refuses a donor
on a different major version. So the Percona operator's start-up step shut mysqld down cleanly, with
exit 0. That is why the pod looked like a normal restart rather than a crash. `PodCrashLooping`
fired after 51 restarts and about 90 minutes. Apps never noticed, because HAProxy kept sending
traffic to `main-mysql-mysql-1`, still on 8.4. The only visible damage was `mysql.ready 1/2`: no
high availability, and only one copy of the data.

**Why this was worse than one broken pod.** There were two reasons. First, the StatefulSet uses
`updateStrategy: OnDelete`, so a change to its template does not update existing pods. That is the
*only* reason the primary survived. Its live template said `9.7.1-1.1`, so any `delete pod`, drain,
or reboot of `worker-node` would have rebuilt the primary on 9.7 and taken MySQL down completely.
Second, the 9.7 mysqld upgraded the data dictionary (MySQL's internal record of how its databases
are built) of pod-0 in place before it died, so reverting the tag alone could not fix the replica:

```
[ERROR] [MY-014061] [InnoDB] Invalid MySQL server downgrade:
        Cannot downgrade from 90701 to 80410. Downgrade is only permitted between patch releases.
```

MySQL has no downgrade path, so only 9.x could use that data directory. The replica had to be
rebuilt from its storage volume (PVC) up, cloning again from the 8.4 primary.

**Why no check caught it.** The Helm chart does not manage the server image. `ps-operator` (chart
1.2.0) installs only the operator Deployment and the CRDs (definitions of custom Kubernetes resource
types). Every image that runs the database itself is set in the `PerconaServerMySQL` custom resource
(CR). So Renovate's `kubernetes` manager, set to read files matching `/\.yaml$/`, saw a bare
`image: percona/percona-server:…`. It looked up the newest docker tag and opened a PR. It had no way
to know that the tag must be in the support matrix (the list of supported version combinations) of
`crVersion: "1.2.0"`, which lists only 8.0 and 8.4. The link between the tag and the operator
version existed only as a YAML comment. CI cannot see it either. The tag is pinned and well formed,
so `image-pin` and `kubeconform` both pass, and the failure shows only at run time. The Renovate
rule for major updates assigned a reviewer but set no upper version limit, so one human merge was
enough.

**Fix** (`b43b0cc7`). The pins went back to `8.4.10-10.1`, and the router pin to `8.4.10`.
`allowedVersions` limits now stop this kind of change from happening again:

| Pattern | Images |
|---|---|
| `/^8\.4\./` | `percona-server` and `percona-mysql-router` (later also `percona-xtrabackup`) |
| `/^18\./` | `ghcr.io/cloudnative-pg/postgresql`, which had the same exposure through the `imageName` customManager |

Patch PRs still arrive. Renovate proposes no major version until someone raises the limit on
purpose, together with the operator upgrade and a real upgrade path.

**Rejected:** changing `upgradeOptions.apply` from `disabled` to `8.4-recommended`. Percona's
Version Service knows the support matrix, which is the missing check. But it patches
`.spec.mysql.image` in the CR, a field Flux owns, and it would upgrade the database with no PR, no
diff and no review. Whoever set `disabled` was right.

**Also found:** `backup.image` had used `percona-xtrabackup:9.7.1` since #928 (2026-07-15), three
weeks before the server change. It had no effect, because of `backup.enabled: false` and zero
`ps-backup` objects. But a 9.x XtraBackup cannot back up an 8.4 server. So if someone had enabled
backups, that image could not have backed up the server. The image is now pinned to `8.4.0-6.1`. A
version limit alone would not have fixed this one. Renovate never downgrades, so a pin that was too
new needed a tag chosen by hand.
