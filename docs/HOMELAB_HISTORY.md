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

The table summarises the months before the dated entries below.

## Changelog

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
hooks that rewrite files skip the byte copies. Plan: `docs/plans/2026-09-26-open-source-prep.md`.

### 2026-09-26 — node-maintenance moved out of `docs/`

| From | To |
|---|---|
| `docs/scripts/node-maintenance/` | `node-maintenance/` |
| `docs/scripts/*.sh`, `docs/worker-node-post-install.sh` | `scripts/` |
| `docs/scripts/runbooks/authentik-passkey-rollback.md` | `docs/runbooks/` |

Only the control plane clones the repo. Its installed sync script calls `install.sh` by its old
path, so the move ships in two commits:

| Commit | Change |
|---|---|
| A | moves the tree, leaves a symlink `docs/scripts/node-maintenance → ../../node-maintenance`, and points `lib/sync-from-git.sh` at the new path. The old installed script follows the symlink and installs the new one |
| B | deletes the symlink after the control plane shows the new sync script installed |

`renovate.json` now ignores `node-maintenance/**`. Renovate never read the folder before, because
it sat under the ignored `docs/**`. Entries below this one keep the old path. Plan:
`docs/plans/2026-09-26-open-source-prep.md`.

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

This does not relax the C3 safety rule. The watchdog acts on no new state: a domain still `paused`
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

### 2026-09-08 — The failed NAS drive was replaced and md1 rebuilt clean

`WS21F7E8`, the SMART-failed `md1` member written up on 2026-08-02 and still in
the array when it stalled the 2026-09-06 scrub, was swapped on 2026-09-08. The
NAS came back up at 21:14 BST and rebuilt into the same RaidDevice slot 2. As of
2026-09-10 the array is `[6/6] [UUUUUU]`, `degraded=0`, `array_state=clean`,
`last_sync_action=recover`, `sync_action=idle`, all six members `in_sync`.

| Fact | Value |
|---|---|
| Out | `WS21F7E8` — `ST4000NE001-2MA101`, SMART FAILED, `Reallocated_Sector_Ct` 49152, `Reported_Uncorrect` 65535, `Command_Timeout` 983057 |
| In | `WS24PTRD` — `ST4000NE001-2EN112`, firmware TN05. The Seagate warranty replacement; its model suffix differs from the five originals (`-2MA101`), so the array is no longer six identical units |
| Prior runtime | None recorded. `Power_On_Hours` 50, `Power_Cycle_Count` 1, `Start_Stop_Count` 2, and `Head_Flying_Hours` 50h14m — all equal to the elapsed time since the swap |
| SMART baseline | PASSED. Reallocated 0, Reported_Uncorrect 0, Command_Timeout 0, Current_Pending_Sector 0, Offline_Uncorrectable 0, UDMA_CRC 0, no errors logged |
| Temperature baseline | 52 °C current, 57 °C max, against the 60 °C `Airflow_Temperature_Cel` threshold — 3 °C of margin at its rebuild peak. Compare at the next check; the sibling drives' temperatures need `sudo smartctl` |
| `G-Sense_Error_Rate` | 557 in 50 hours — rotational vibration from the other five bays, expected in a 6-bay chassis |
| Device letter | Now `sdd`, which is the letter the *failing* drive carried after the 2026-09-02 reboot. Same letter, opposite meaning: identify by serial, never by letter |

**A rebuild is not a scrub.** The `recover` read all five surviving members
end-to-end to reconstruct slot 2, so those five are verified readable. It did
not read the new drive back, and it does not compute `mismatch_cnt` — the `0`
in sysfs is uninformative after a `recover`. Both the 2026-08-02 and 2026-09-06
checks were aborted mid-run, so the last completed check predates August.

The next scheduled check is **2026-10-04 00:57** (`/etc/cron.d/mdadm`, first
Sunday). It is left to run on schedule rather than triggered early: the drive
that caused the 87-second read stalls is gone, and the `homelab/dedicated=immich`
taint applied on 2026-09-06 now caps a scrub-class stall to Immich instead of
the five init Jobs. An early check would be `echo check > /sys/block/md1/md/sync_action`,
roughly 8-12 hours for 14.4 TB, on a day the `192.168.1.231` iowait can be watched.

### 2026-09-07 — kube-prometheus-stack 90.0.0 blocked on control-plane ServiceMonitor auth

Renovate merged the chart bump to `90.0.0` (#1125). The Helm upgrade failed, Flux rolled back, and the release stayed on `89.2.3` while `FluxControllerReconcileErrors` fired. Chart 90.0.0 added a `fail` in `_helpers.tpl`: every enabled control-plane component defaults `serviceMonitor.authorization` to a Secret the chart renders only when `prometheus.enabled`, `prometheus.serviceAccount.create` and `createTokenSecret` are all true. This cluster sets `prometheus.enabled: false`, so the render aborted.

Nothing consumed those ServiceMonitors: no `Prometheus` CR exists and every `VM_ENABLEDPROMETHEUSCONVERTER_*` env on the vm-operator is `false`. vmagent scrapes through the hand-written VMServiceScrapes in `monitoring/configs/`.

| Component | Treatment | Why |
|---|---|---|
| `kubelet`, `kubeApiServer`, `coreDns` | `serviceMonitor.authorization: null` | The chart gates each Grafana dashboard on the component's `enabled` flag, and these three dashboards hold data |
| `kubeControllerManager`, `kubeScheduler`, `kubeProxy`, `kubeEtcd` | `enabled: false` | No VMServiceScrape, VMPodScrape, VMStaticScrape, VMScrapeConfig or vmagent `additionalScrapeConfigs` selects them, so their dashboards were empty |

The scrapes survive because their selectors never pointed at chart objects: the kubelet VMServiceScrapes target the Service that **prometheus-operator** creates (`prometheusOperator.kubeletService`, gated only on itself), `coredns` targets the addon `kube-dns` Service via `k8s-app=kube-dns`, and `apiserver` targets `default/kubernetes`.

The three retained chart ServiceMonitors now carry no `authorization`. If anyone enables `VM_ENABLEDPROMETHEUSCONVERTER_SERVICESCRAPE` on the vm-operator later, the converter turns them into unauthenticated VMServiceScrapes that duplicate the hand-written ones and fail against kubelet `https-metrics:10250` and `default/kubernetes`, which both require a bearer token. Clear or exclude them before flipping that flag.

Measured against the live 89.2.3 release, the change removes 4 ServiceMonitors, 4 kube-system Services and 4 empty dashboards. Renovate PR #1123 (89.2.4) merged as an empty diff, superseded by #1125.

The `VMServiceScrape ... webhook ... EOF` Flux dry-run alert at 21:22 was unrelated and transient — it landed 14 seconds after commit `4326adbc`, `monitoring-configs` reconciled Ready at the same revision, and the vm-operator shows 0 restarts with no webhook or TLS errors in its log.
No CI job rendered charts, so every existing job passed: `kubeconform` validates the HelmRelease custom resource, never the chart's own templates. The `helm-render` job closes that gap.

| Property | Value |
|---|---|
| Job / script | `helm-render` in `.github/workflows/validate.yaml`, `scripts/ci/helm-render-check.sh` |
| Added in | `2cdaa5c8`, hardened in `703f3bc5` |
| Coverage | 12 HelmRelease charts at their pinned versions; 11 HTTP repos and 1 OCI |
| Result on `4326adbc` (pre-fix) | `FAIL kube-prometheus-stack@90.0.0`, exit 1 |
| Result on the fix | 12/12 rendered, exit 0 |
| Runtime | 9 s local, against an isolated helm repo config |
| Required flag | `--api-versions monitoring.coreos.com/v1`, or traefik's `servicemonitor.yaml` aborts with "You have to deploy monitoring.coreos.com/v1 first" against a CRD the cluster has |
| Silent-skip guards | Empty discovery, a malformed manifest, a HelmRepository name collision and an incomplete `spec.chart.spec` each exit 1; releases pair with values by document index |
| Known gap | The `image-pin` and `kubeconform` jobs still download yq without a checksum; `helm-render` verifies its own |

### 2026-09-06 — Immich ML inference moves to the immich-vm iGPU (OpenVINO)

Immich ML moved to immich-vm earlier on 2026-09-06 and ran there on the CPU. The `-openvino` image puts inference on the VM's Meteor Lake Arc iGPU through ONNX Runtime's OpenVINO execution provider. Commit `4a5255cf`; plan `docs/plans/2026-09-06-immich-ml-openvino.md`.

| Change | Detail |
|---|---|
| Image | `immich-machine-learning:v3.1.0-openvino` (Python 3.13, onnxruntime-openvino 1.24.1, intel-opencl-icd 26.22) |
| GPU access | `gpu.intel.com/i915: "1"` via the Intel device plugin; pod `supplementalGroups` 983 (video), 987 (render) |
| Memory limit | 2355Mi → 4Gi (OpenVINO keeps model buffers in system RAM); requests unchanged |
| rapidocr mount path | `python3.11` → `python3.13`, tied to the image variant |
| Gate | `get_available_openvino_device_ids()` = `['CPU', 'GPU']`; first `/predict` `4.52 s` (first-request latency, includes the GPU compile), warm `0.022 s`; the ML worker's i915 `drm-engine-compute` counter rose 112240128 ns → 124969624 ns (12.73 ms) across one /predict while render/copy/video/video-enhance stayed at 0 ns; a cold session reload from the compiled blob answered in 1.09 s; GPU clock peaked at 1517 MHz; journal clean |
| Follow-ups | trim the memory limit after a week of metrics; FP16 (`MACHINE_LEARNING_OPENVINO_PRECISION`) and a larger CLIP model are separate changes |

### 2026-09-06 — The NAS scrub stalled immich-vm again, and five unrelated init Jobs waited on it

At 18:23 local, `PodsPending` and `PodPhaseNotRunning` fired for five pods at
once: `audiobookshelf-init`, `home-assistant-admin-setup`, `immich-admin-setup`,
`n8n-user-provision` and `couchdb-init`. They are the daily Flux force + TTL
re-run of the init Jobs, created at 18:11. The scheduler put all five on
`immich-vm`, and every one sat in `ContainerCreating` with
`FailedCreatePodSandBox … DeadlineExceeded` for 33 minutes. `NodeHighIOWait`
fired on `192.168.1.231` alongside them.

The cause was the monthly mdadm check on the NAS `md1` array (first Sunday,
00:57). The SMART-failed member (serial `WS21F7E8`, written up on 2026-08-02)
had not been swapped: the RMA drive was still in transit. The check ran fast
until about 06:30, then reached that drive's bad region and each read took up to
87 s. `immich-vm`'s disk image lives on that array, so containerd on the VM could
not create a pod sandbox inside its deadline.

| Evidence | Value |
|---|---|
| immich-vm iowait | 0-3% overnight, ~50% from 06:30, 73% by 17:30 |
| Check progress | 66.2% at 853 KB/s, ETA 17 days |
| Reads queued on the failed drive | 5, later 32 (`/sys/block/sdd/inflight`); every other member 0 |
| Device letter | `sdb` in August, `sdd` now: the 2026-09-02 NAS reboot shifted it. Identify by serial |
| `iostat -dx %util` on the members | 0 on all six. Since kernel 5.x `io_ticks` only advances when an IO starts or completes, so one stuck read registers nothing. `inflight` is the tell |

Four of the five Jobs have nothing to do with Immich. They landed on
`immich-vm` because nothing keeps them off it. `immich-server` pins itself there
with a `homelab/gpu=intel` nodeSelector, but the node carries no taint, so any
unpinned pod can be scheduled there, and the scheduler prefers the emptiest
node:

| Node | Running pods | CPU requested | Memory requested |
|---|---|---|---|
| worker-node | 56 | 5170m of 32 | 15.4 Gi of 61 |
| worker-node-2 | 27 | 2280m of 16 | 6.0 Gi of 30 |
| immich-vm | 6 | 520m of 4 | 1.1 Gi of 11.6 |

The 2026-08-02 scrub caught `popeye` and `postgres-update-extensions` the same
way, and that was recorded as a known symptom rather than fixed.

The operator stopped the check with `echo idle > /sys/block/md1/md/sync_action`.
The write sat in D-state for 2.5 minutes while the 32 queued reads drained at
about one per 15 s; that wait is expected, not a hang. The check reported `idle`
at 18:45:07. All five Jobs succeeded within 30 s, without any Job deletion,
because the kubelet retries sandbox creation on its own. `NodeDown` for
`192.168.1.231` fired briefly during the drain and cleared. Every alert was
resolved by 18:47.

| Follow-up | Status |
|---|---|
| Swap `WS21F7E8` (RaidDevice slot 2, currently `sdd`) before the next check on 2026-10-04 | done 2026-09-08 — `WS24PTRD` rebuilt into slot 2; see the 2026-09-08 entry |
| Fence `immich-vm` with a `NoSchedule` taint so only Immich and per-node DaemonSets run there | shipped `83eb9674` + `230eeb8a`; taint applied 21:27 BST |

| Change | Detail |
|---|---|
| Taint | `homelab/dedicated=immich:NoSchedule` applied to immich-vm at 21:27 BST on 2026-09-06 with `kubectl taint`; `k3s_node_taints` in `host_vars/immich-vm.yml` covers a re-join because k3s reads `node-taint` only at first registration |
| Tolerations | immich-server, immich-machine-learning, the immich-admin-setup Job, intel-gpu-plugin; alloy and node-exporter already tolerated any NoSchedule taint |
| ML relocation | immich-machine-learning pinned to immich-vm; its model cache is now the git-declared PVC `immich-ml-cache` (10 Gi, local-path) under `/mnt/k8s-storage`, a bind mount of `/home/k8s-storage` on the VM's 125 G home volume; k3s-agent carries `RequiresMountsFor=/mnt/k8s-storage`; Helm deleted the old chart-owned PVC on worker-node |
| Pods that left the VM | coredns-ha, loki-canary, kube-state-metrics, prometheus-operator (deleted once; NoSchedule never evicts). Five pods remain: immich-server, immich-machine-learning, intel-gpu-plugin, alloy, node-exporter |
| Stays off the VM by design | immich-vm-heal (starts the VM from outside), immich-backup (148 G on worker-node-2, would land on the same NAS array), immich-init-extensions (databases namespace), Postgres and Redis (shared) |

### 2026-09-05 — An aliased preflight skipped the weekly reboot, and Loki began rejecting a week-old log line every hour

`AlloyLogDeliveryFailing` fired hourly on both workers from 04:48Z. Nothing was
wrong with Alloy or with Loki. Two unrelated defects lined up, and the weekly
reboot had been hiding the second one for months.

phase1 gates the reboot on every Flux Kustomization reporting `Ready=True`. Flux
reports `Ready=Unknown/Progressing` for roughly one second of each 60s reconcile,
so a single sample finds all-True only 76-83% of the time — measured against the
live healthy cluster at 5 failures in 30 samples. The retry cadence was
`retries: 3, delay: 30`. The trap is `gcd(delay, interval)`, not the tempting
"delay must not divide 60":

| delay | gcd(delay,60) | distinct phases sampled |
|---|---|---|
| 7s | 1 | 60 |
| 24s | 12 | 5 |
| 30s | 30 | 2 |

At `delay: 30` the four attempts behaved like two. All four hit `Progressing`,
phase1 exited 2, and no node rebooted.

That mattered because of a coincidence nobody had noticed. `OnCalendar=Sat
*-*-* 04:30:00 UTC` is a 168h cycle, and Loki's chart-default
`reject_old_samples_max_age` is also 168h. Alloy's `loki.source.kubernetes`
re-opens every tailer hourly and replays the last log line of each idle
container — svclb, config-reloader, metrics-server, cainjector, kyverno. The
weekly reboot refreshed those lines about an hour before they aged out, every
week. The first skipped reboot let them cross 168h, and Loki answered
`has timestamp too old`.

No logs were lost. Loki discarded 480 entries per 12h; Alloy reported 6143
against 1,228,685 sent, because its client marks a whole batch dropped on a 400
and the co-batched fresh entries were stored. Read
`loki_discarded_samples_total` for the true figure —
`loki_write_dropped_entries_total` is an upper bound.

| Fix | Change |
|---|---|
| preflight aliasing | `retries: 20, delay: 7`; 7 is coprime with 60, so the 21 attempts sample distinct phases. Measured longest failure run: 2 |
| zero-margin reject window | `reject_old_samples_max_age: 720h`, matching `retention_period` |

The predicate itself stayed `!= "True"`. An earlier draft relaxed it to
`== "False"` so that `Unknown` would pass; review caught that this fails open,
because a kustomize-controller that dies mid-reconcile leaves `Unknown` set
forever and the gate would then wave a reboot through on a broken cluster.

Shipped in `0e78e618`. The re-run that night passed the preflight on its first
attempt with no retries, rebooted all four nodes cleanly (`failed=0
unreachable=0 rescued=0`, `pkg-upgrade: OK` on every node), and the alert
cleared. immich-server needed three restarts to pass its startup probe on the
GPU VM cold start before going Ready — its startup budget is tight, and is worth
widening separately.

### 2026-08-20 — A power cut, and both workers rebooted themselves an hour after the power returned

Mains power died at 12:35 and came back at 16:03. All four nodes and the NAS booted on their own. What needed explaining was not the outage — it was the hour after it, in which both workers rebooted themselves and the control-plane restarted `k3s` eight times, with nobody logged in.

The control-plane booted at 16:03:17 with its kube-proxy ClusterIP DNAT wedged — the failure class `clusterip_heal_cp` exists for. That watchdog restarted `k3s` at 16:05 (recovered), at 16:24 (probe rc=1, not confirmed healthy) and at 17:18 (probe rc=2); `k3s` settled at 17:20:45. While the apiserver flapped, both workers scored themselves CP-isolated (`cp_direct=0 kubelet=0 gw=1`), escalated through L1 `k3s-agent` restarts, and reached the self-reboot rung of `node_isolation_heal`. The staggered index worked: worker-node (index 0) went first, worker-node-2 (index 1) seventeen minutes later, so the two workers never rebooted together.

| Time (BST) | Event |
|---|---|
| 12:35–12:42 | power lost — CP 12:36:06, worker-node 12:36:25, worker-node-2 12:35:44, immich-vm 12:42:14 |
| 16:03 | power restored, all four nodes and the NAS boot |
| 16:05 | CP ClusterIP DNAT wedged → `clusterip-heal-cp` restarts `k3s` #1, recovered |
| 16:24 | wedged again → `k3s` restart #2, probe rc=1, not confirmed |
| 16:39:52 | worker-node SELF-REBOOT after 1177s isolated, L1 restarts did not recover it |
| 16:56:49 | worker-node-2 SELF-REBOOT after 1501s isolated (stagger index=1) |
| 17:18 | CP wedged a third time → `k3s` restart, up at 17:20:45 |
| 17:21 | both workers log `recovered (tunnel up; cp=1 kubelet=1 gw=1)` — stable since |

Every recovery step was automatic. The manual work was clearing the residue the outage left behind: two terminal authentik pods (`Error` and `Init:Error`, from the 16:03 boot — the reboot-leftover class that nothing reaps), and two `immich-vm-heal` Jobs that hit `DeadlineExceeded` while immich-vm was still booting. Both alert pairs cleared on deletion. `NodeIsolationHealRebooted` is not clearable by hand — its rule is `time() - node_isolation_heal_last_reboot_timestamp < 3600`, so it expired by itself at 17:56:49.

**Open item.** The third CP wedge fired at 17:18, 75 minutes after boot. The first two fit the cold-start race; this one does not, so the wedge is not purely a boot artifact. The nftables root fix stays deferred on kubernetes#136786. If it recurs outside a boot window, that is the thing to chase.

Verified after recovery, with no configuration change made: no pstore blobs and no filesystem errors on any node after the hard power loss; Postgres 2/2 (primary `main-postgres-12`), MySQL 2/2 with haproxy 2/2 and orchestrator 3/3, CouchDB 2, Redis replication 2 plus 3 sentinels; Flux 7/7; all 16 ingress hosts answering through LAN Traefik; NAS `md1` raid6 `[6/6]` and `md0` `[2/2]`, with the known SMART-failed `sdb` unchanged and still awaiting its RMA replacement.

### 2026-08-14 — extension ownership cannot be given to the app role, and immich picks its vector extension by availability

Yesterday's crashloop raised the obvious question: which other extensions does a superuser own
rather than the app that needs them, and can that be handed over? An audit of every extension in
all eight databases answers the first part — only immich's `vector`, `cube` and `earthdistance` are
owned by `postgres-admin`. `mealie.pg_trgm`, `n8n.uuid-ossp` and immich's
`pg_trgm`/`unaccent`/`uuid-ossp` are owned by their app role, and `plpgsql` is `postgres`-owned in
every database and inert, because no app updates it. Of the three, only `vector` matters: immich
v3.1.0 only ever runs `ALTER EXTENSION` against the vector-family extension, so `cube` and
`earthdistance` are create-once.

Handing ownership over fails twice, both checked against the live cluster on PostgreSQL 18.6:

| Attempt | Result |
|---|---|
| `ALTER EXTENSION vector OWNER TO immich` | `syntax error at or near "OWNER"` — PostgreSQL has no `OWNER TO` form for extensions |
| move `pg_extension.extowner` by hand, then update as the owner | `permission denied to update extension` / `Must be superuser to update this extension.` |

The second is the decisive one. `vector` is `superuser=t, trusted=f`, and PostgreSQL demands
superuser to run an untrusted extension's update script whatever the owner is. The check ran in a
rolled-back transaction against `pageinspect`, which carries the same two flags and ships real
upgrade scripts. So a privileged job that runs the `ALTER` before the app starts is the only design
that works, which is what `postgres-update-extensions` and `immich-init-extensions` already are.

CNPG 1.30's declarative `Database.spec.extensions` does not replace them. `updateDatabaseExtension`
emits `ALTER EXTENSION … UPDATE TO` only if `spec.version` is set and differs from the installed
version, so an entry without a `version` creates the extension once and never updates it, and a
pinned version is a manual bump renovate cannot see.

The audit did surface the next instance of this class. Immich selects its vector extension by
availability rather than by what is installed — `VECTOR_EXTENSIONS = [VectorChord, Vector]`, first
name present in `pg_available_extensions` wins. If a CNPG image ever ships `vchord`, immich runs
`CREATE EXTENSION vchord` as the non-superuser `immich` role, which is fatal for an untrusted
extension, and then tries to drop `vector`. The `standard` image ships pgvector and no vchord today,
so `0e00822a` pins `DB_VECTOR_EXTENSION: pgvector` to keep an upstream image change from switching
extensions. A migration to VectorChord now needs that value changed on purpose.

One residual has no automated repair: if an image ever ships pgvector older than the installed
version, immich throws `invalidDowngrade` at bootstrap, and no job can fix it, because
`ALTER EXTENSION` cannot downgrade. The remedy is pinning the image back.

### 2026-08-13 — a CNPG minor bump left Immich crashlooping, and the job that repairs it ran 3m35s too early

Renovate's `4607a47a` moved `ghcr.io/cloudnative-pg/postgresql` from `18.4-standard-trixie` to
`18.6-standard-trixie` across eight files, the CNPG `Cluster` among them. The 18.6 image ships
pgvector **0.8.6**; the `immich` database still held **0.8.2**. Immich updates pgvector itself at
startup, but connects as DB user `immich`, which does not own the extension, so
`ALTER EXTENSION vector UPDATE TO '0.8.6'` failed with `must be owner of extension vector`
(SQLSTATE 42501), the microservices worker exited 1, and `immich-server` crashlooped. PG 18 has no
`ALTER EXTENSION … OWNER TO` form, so immich can never hold that ownership and only a
`postgres-admin` connection can raise the installed version.

Postgres itself was never down. The page read `ScrapeTargetDown{job="immich-server"}`, and the
cluster reported `Cluster in healthy state` throughout.

`postgres-update-extensions` already repairs exactly this as `postgres-admin`, but ran weekly on
Sunday 06:00 UTC. The commit merged on a Thursday, so immich would have remained unavailable for
about three more days. Running that CronJob manually raised vector to 0.8.6 and immich recovered.

`immich-init-extensions` should have prevented the outage on its own: renovate edits its image tag
in the same commit, and `kustomize.toolkit.fluxcd.io/force` re-creates the immutable Job. It did
re-run — 3m35s too early, because Flux starts the Job and the rolling upgrade together.

| Time (UTC) | Event |
|---|---|
| 18:03:37 | `immich-init-extensions` pod starts |
| 18:03:39 | `main-postgres-11` starts on 18.6 |
| 18:07:12 | `main-postgres-12` starts on 18.6 and becomes primary |

The Job therefore read the extension catalogue from the outgoing 18.4 primary, and its
`CREATE EXTENSION IF NOT EXISTS` never raises an installed version in any case.

These changes fix both causes. The Job waits for the primary to report its own image's
`server_version` before it touches extensions. `postgres --version` minus its
`postgres (PostgreSQL) ` prefix is that string exactly, so the wait is a string compare with no
version parsing. The CronJob runs daily, because if a CNPG rebuild ships a newer extension under an
unchanged tag, renovate has nothing to bump and nothing re-creates the Job.

The per-extension `ALTER … UPDATE` loop now lives in `update-extensions.sh`, which
`configMapGenerator` packages as the `postgres-extension-update` ConfigMap that both workloads
mount. The first attempt duplicated the loop and the peer review rejected that: two prior
corrections already fixed this loop for reporting success on a failed update, and a third
correction reaching one copy and not the other is the likely failure. A generated name carries a
content hash, so editing the script renames the ConfigMap, kustomize rewrites both volume
references, and Flux re-creates the forced init Job. A standalone `.sh` also brings the script
under the repo-wide shellcheck job, which never saw it inside a YAML block scalar.

These checks extracted the Job's script with `yq`, took the shared script as it stands, and ran
both under `/bin/dash` (the CNPG image's `/bin/sh`) against stubbed `psql`/`postgres`.

| Check | Result |
|---|---|
| Roll completes after 3 polls | Job waits, then updates all 3 extensions, exit 0 |
| Extension name containing a space | survives the read loop unsplit |
| One `ALTER` fails | siblings' successes persist, `FAILED vector` reported, exit 1 |
| Empty extension list | exit 1 rather than a silent success |
| Roll never completes | exit 1 at 120 attempts |
| Mutant: remove the `sed` prefix strip | KILLED |
| Mutant: `RC=1` → `RC=0` | KILLED |
| Mutant: Job stops calling the shared script | KILLED |

### 2026-08-08 — k3s v1.36.2 → v1.36.3, and the rolling restart that ran without its lock

Same-minor patch on the stable channel — `stable` and `latest` both return `v1.36.3+k3s1`. Binary
swap via the `k3s-upgrade` skill: a sha256-verified download staged to all four nodes, previous
binary kept at `k3s.prev`. The sanctioned serial restart then ran CP → W1 → W2 → immich-vm at
13:34:57, 13:35:42, 13:36:20, 13:36:58. No repo commit covers the upgrade itself — k3s is a manual
`/usr/local/bin/k3s` binary, not Flux- or pacman-managed. Pods held at 108 total / 0 unhealthy,
Flux stayed 7/7, and the Watchdog dead-man stayed the only firing alert. `k3s.prev` was removed the
same day by choice: a patch downgrade means re-staging the binary, a minor one means
restore-from-backup.

The rolling restart still exited 4 and sent its Telegram failure alert.

| Fact | Value |
|---|---|
| Drift-heal run | 13:30:33–13:36:54, triggered by the sync timer pulling `cae7d3d2` |
| Rolling restart run | started 13:34:41, no lock held |
| immich-vm restart module | ran 13:36:52, node up on v1.36.3 at 13:37:00 |
| Ansible verdict | `UNREACHABLE: Data could not be sent to remote host "192.168.1.231"`, exit 4 |
| node-maintenance SSH masters to immich-vm | two, ports 41928 and 31690, both the drift-heal's |

Two ansible runs executed as root on the control plane at once. Ansible defaults there are
`ssh_args = -C -o ControlMaster=auto -o ControlPersist=60s` with `control_path_dir = ~/.ansible/cp`,
so both runs share one SSH master per host. For immich-vm the rolling restart opened no master of
its own; it attached to the drift-heal's. immich-vm was its last host, and the drift-heal finished
two seconds after the restart module ran. Closing that master killed the in-flight channel. W1 and
W2 were unaffected because their restarts finished before 13:36:54.

The restart itself succeeded, and the checkpoint matched before and after. What was lost is the gate: immich-vm
skipped its Ready wait and kubelet-configz verify. Both were run by hand afterwards — all four nodes
report `leaseDuration=60 reportFrequency=1m0s`.

`node-maintenance-lock.sh` has existed since 2026-05-25 for this case, and `config`, `phase1` and
`phase2` all use it. `rolling-restart` was added later and never wrapped. It now runs under
`node-maintenance-lock.sh wait --` (`f3c6abd7`) — `wait`, not `skip`, because an operator triggers it
by hand and a silent no-op would read as "restart done". `TimeoutStartSec` went 15min → 25min: `wait`
mode is `flock -w 900`, so a 15-minute cap could expire on a queued run before ansible started.
Verified live on the control plane — the wrapper blocks while the lock is held and acquires once it
is released.

`KUBERNETES_VERSION` in `.github/workflows/validate.yaml` moved 1.36.2 → 1.36.3 to track the cluster,
as that file's own comment instructs; the `v1.36.3-standalone-strict` schemas are present upstream.

### 2026-08-08 — The maintenance trigger answered 403 for two weeks

Phase 1 and phase 2 both completed. All four nodes rebooted in order, `PLAY RECAP` reported
`failed=0` on every host, and `node_maintenance_last_run_unixtime` was written. The last line of the
run was `curl: (22) The requested URL returned error: 403` — the `ExecStopPost` that asks Claude to
review the post-reboot alerts. `ExecStopPost=… || true` discarded it.

| Fact | Value |
|---|---|
| Reboot window | 04:33–05:26 UTC |
| Trigger secret in SOPS | rotated 2026-07-31 (`c0301bcb`) |
| Trigger secret on the CP | `/etc/node-maintenance/claude-trigger-secret`, mtime 2026-04-27 |
| Bot response | HTTP 403 — the secret check rejects before the body is read |
| Runs with no alert review | 2026-08-01 and 2026-08-08, `curl: (22) … 403` in both journals |

One secret, two copies, one of them rotated. `install.sh` also had no line for
`telegram-notify-claude.sh`: someone placed the CP copy by hand in April and no sync path touched it,
so editing the file in git would have deployed nothing.

`telegram-notify-claude.sh` now reads the secret from the bot's own `$TRIGGER_SECRET` inside the pod,
and the CP keeps no copy. Reading it grants nothing new — whoever can `kubectl exec` into that
container can already read the variable. The script sends its own Telegram alert if the POST fails,
because its caller's `|| true` discards a non-zero exit. `install.sh` installs it now, in both full
and `--sync-only` mode.

Three more faults, same unit and same run:

**`StartLimitIntervalSec` and `StartLimitBurst` sat under `[Service]`.** Both belong in `[Unit]`.
systemd logged `Unknown key 'StartLimitIntervalSec' in section [Service], ignoring` on every reload,
so the 3-attempts-in-2h cap the file documents never applied to the phase 2 retry. Moved.

**Nothing removes the pods a graceful node shutdown leaves behind.** Each evicted pod ends in a
terminal phase. The ReplicaSet controller ignores terminal pods it owns, and the pod-GC controller
acts only past `--terminated-pod-gc-threshold`, default 12500. This run left 11 — 10 `Succeeded`, 1
`Failed`, which kept `PodPhaseNotRunning` firing; 2026-08-01 left 14 and 4 alerts. Phase 2's GC missed
them twice over: it matched `status.phase=Failed` only, and only inside `phase2_pod_gc_namespaces`. It
selects by owner now — terminal pods controlled by a ReplicaSet, StatefulSet or DaemonSet,
cluster-wide — and re-tests the phase server-side at delete time, since StatefulSet names are stable.
Job-owned pods stay, and so do pods with no controller. `phase2_pod_gc_namespaces` is gone.

**The CouchDB size floor stopped two nights of replication.** `backup-replication` aborts at Step 1
if any source backup fails validation. A client-side LiveSync rebuild recreated `obsidian-personal`
on 2026-08-06 15:52 UTC, after that morning's dump. Every dump from 2026-08-07 on came out at 88K
instead of 15.8M, under the 100KB CouchDB floor, so both the 08-07 and 08-08 runs stopped before the
rsync — `kube_cronjob_status_last_successful_time` for `backup-replication` still pointed at
2026-08-06 03:30 UTC. The source backups stayed on worker-node, which is what the abort is for, and
both nights sent the "Backup Validation FAILED" Telegram report. A size floor catches a truncated
dump; it cannot also track how much data the vault holds. It is 20KB now, and per-database
completeness stays the `couchdb-backup` job's own check.

### 2026-08-07 — The sync path ran the drift-heal playbook twice on every push

`node-maintenance-sync.service` needed 12min59s to deploy one commit (`fe0ff835`). It ran the full
`node-config` ansible playbook across all four hosts twice.

| Fact | Value |
|---|---|
| Run 1 — `install.sh:163` starts `node-maintenance-config.service` unconditionally | 18:30:29 → 18:38:22 BST (7min53s) |
| Run 2 — `sync-from-git.sh:63-66` starts the same unit once `install.sh --sync-only` returns | 18:38:22 → 18:43:24 BST (5min02s) |
| `node-maintenance-sync.service` `TimeoutStartSec` | 20min |
| `node-maintenance-config.service` `TimeoutStartSec` | 15min |
| Callers of `install.sh` | `sync-from-git.sh:57` (always `--sync-only`), plus a flagless manual bootstrap |

A 2026-06-05 entry already recorded the doubling as a gotcha. It drift-healed every host at once and
so bypassed a staged W2→W1→CP rollout. That entry told operators to stage with a manual `rsync` plus
`ansible-playbook --limit`, never `install.sh --sync-only`. The doubling itself stayed for two months.

Fix: gate the `install.sh` run on `SYNC_ONLY -eq 0`.

| Path | Playbook runs, before → after |
|---|---|
| Flagless manual bootstrap | 1 → 1, from `install.sh` |
| Sync timer, HEAD changed | 2 → 1, from `sync-from-git.sh` |
| Sync timer, fresh clone | 2 → 1 — `sync-from-git.sh` passes `--sync-only` on this path too |
| Standalone `install.sh --sync-only` | 1 → 0 — the behaviour the 2026-06-05 gotcha warns against |

`README.md:35` and `:117` already described the fixed shape: `install.sh --sync-only` does
daemon-reload and file perms, then `node-maintenance-config.service` re-applies. The guard took
effect on the run that deployed it, because `sync-from-git.sh` invokes `install.sh` from the freshly
pulled repo. That run confirmed it:

| Measure | Before (`fe0ff835`) | After (`4aa51ae5`) |
|---|---|---|
| `install.sh --sync-only` | 7min53s, drift-heal included | 2s |
| Playbook runs | 2 | 1 |
| Sync unit wall clock | 12min59s | 4min37s (`Result=success`) |
| Unused share of the 20min `TimeoutStartSec` | ~7min | ~15min |

The doubling cost time, not correctness. The playbook is safe to repeat, and the second run reported
`changed=0`. If one host had run slow, systemd would have killed the deploy: two ~6min runs plus the
git fetch left roughly 7min of the 20min limit.

Error propagation is unchanged. `sync-from-git.sh` sets `set -euo pipefail`, so a failed `systemctl
start --wait` still fails the unit and fires the `ExecStopPost` Telegram alert.

The 18:30 run also caused a 3-minute disruption, which is what surfaced all of the above:

| Symptom | Detail |
|---|---|
| Readiness and liveness probe timeouts | `worker-node`, `worker-node-2`, `immich-vm` — 17:32:30 → 17:35:39 UTC, one event each |
| Flux `apps` dry-run failure | `vpol.validate.kyverno.svc-fail-finegrained-require-labels`: `EOF`, recovered on retry at the same revision |

The per-host `ufw reload` caused both. `1a1b36ac` added immich-vm's missing `ufw_rules_base` entry,
and the drift-heal applies it one node at a time. The doubling did not cause it.

### 2026-08-07 — A comment sweep found three live defects, including a boot barrier guarding nothing

A repo-wide comment and Markdown pass (`fb62fa8c`, `7ae66800`, `03af5ed1` — every comment-bearing
file, ~330 of them, read comment by comment) meant checking each claim against the live system.
Three claims turned out to be code defects rather than stale prose; fixed in `1a1b36ac`.

**`k3s-wait-ready.sh` settled nothing on the control plane.** The barrier exists so
`ufw-heal-post-k3s` does not race kube-proxy and kube-router still writing iptables, and gates on
`/run/k3s-ready`. Phase 2 waited for pods matching `k8s-app=kube-router` — but K3s runs kube-router
inside the k3s process, so that selector matches zero pods and the wait could only time out. All
three phases then shared one deadline, so the dead wait ate the whole 300s and phase 3 — the
ufw-chain stability check the barrier exists for — ran already expired and took zero samples. The
CP journal had been printing the proof at every boot:

```
pods: timeout / WARN: critical pods not ready
iptables: timeout (last_stable=0/3) / WARN: iptables not stable
complete (elapsed=304s, sentinel=/run/k3s-ready)
```

Fix: drop the kube-router selector (`CRITICAL_POD_LABELS` is coredns only) and give each phase its
own budget clamped to the global deadline (90 + 60 + 120 ≤ 300), so a timed-out phase cannot starve
the ones after it. New `roles/k3s_config/tests/test-wait-ready.sh` pins both; three mutants confirm
it goes red when either is undone. Takes effect at each node's next boot.

**immich-vm had no UFW node-allow rule.** `ufw_rules_base` carried `.127`, `.129` and `.126` but
never gained `.231` when the node joined 2026-07-10. Traffic mostly worked because 8472/udp and
10250/tcp are open from anywhere. Added in its siblings' shape; applies on the next drift-heal, one
node at a time, with a ufw reload each.

**Two helpers in the drift-heal alert path were dead code.** `extract_fatal_summary()` and
`extract_journal_window()` were defined and never called, so the fatal dump carried no journalctl
time window and only a 300-char-trimmed raw fatal line. Both are wired into the dump now; the
script's paths became env-overridable so `lib/tests/test-notify.sh` can drive all five branches in
a temp dir.

**A fourth defect fell out of deploying the first three** (`76494c76`). The drift-heal that shipped
them alerted `applied 9 change(s) [gmk-k3s-control-plane: 3,immich-vm: 3 worker-node: 3,worker-node-2: 3]` —
nine reported against twelve listed, and an alternating separator. Both from the same function.
The counts came from `grep -oE 'changed=[0-9]+' "$LOG" | tail -3`, the last **three** matches in the
whole log: written for a 3-node cluster, so the first host has been dropping off every alert since
immich-vm joined 2026-07-10. `FAILED` used the identical formula, so a failure on the
first-listed host would not have reached the count either. The separator was `paste -sd', ' -` —
`paste -d` reads its argument as a round-robin *list* of delimiters, so fields joined with `,` then
` ` alternately. Fix: `recap_body()`/`recap_rows()` anchor every count to the actual `PLAY RECAP`
host rows matching ansible's canonical `ok= changed= unreachable= failed=` sequence, which also
retired a third hardcoded ceiling (`extract_recap()` printed `recap+5` lines — fine at 4 hosts,
silently truncating at 6). The row match deliberately stops after `failed=` rather than anchoring
the trailing `skipped/rescued/ignored` set: coupling to the exact field list would zero every count
if a callback ever changed it, which is worse than the stray-line collision it would prevent.

The sweep also corrected facts that had drifted: coredns-ha described as a "Deployment (3 spread
replicas)" in three places when it is a DaemonSet; both worker `host_vars` headers understating
their hardware by half (W1 is 16c/32t 64GB, W2 8c/16t 32GB); `kustomize-controller v1.9.1` against
a live v1.9.4 (the `KUSTOMIZE_VERSION` pin it justifies is still correct — v1.9.4 embeds the same
kustomize/api v0.21.1); a "pre-commit gitleaks hook" that does not exist, the coverage being
`gitleaks.yaml`; and two Alertmanager inhibit-rule comments describing matchers the rules do not
use. A semantic render proof — all 7 kustomize roots built, comments stripped from string values,
diffed against the pre-sweep tree — came back identical on every root, so nothing reaching the
cluster changed.

Worth keeping: none of the four could fail a check. A barrier waiting on a pod that cannot exist
still exits 0, still touches its sentinel, and boot proceeds; CI sees a passing shellcheck. The
first three surfaced only because a comment asserted something checkable and the check got run. The
fourth is the sharper lesson — it was on screen in every drift-heal alert for a month, and reading
the numbers rather than the headline is what caught it. Two of the four — the missing UFW rule and
the alert counts — share a root with most of the stale comments above: a hardcoded 3 that nobody
revisited when immich-vm made this a 4-node cluster on 2026-07-10.

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
- The trap is recorded in the agent's memory notes (`gotchas.md` 2026-08-07).

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
would be a design change, and this change did not build one. Instead, `.backup/README.md` Step 6
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

### 2026-08-05 — A one-line Renovate tag bump made the MySQL replica unrebuildable

Renovate PRs #1008 and #1007 merged at 19:31 UTC, nine seconds apart:
`percona/percona-server` `8.4.10-10.1 → 9.7.1-1.1` and `percona/percona-mysql-router`
`8.4.10 → 9.7.1`. Flux applied, the StatefulSet recreated `main-mysql-mysql-0` at 19:35 on the
9.7 image, and it never came up:

```
[Clone] Client: Command COM_INIT: error: 3864: Clone Donor MySQL version: 8.4.10-10
        is different from Recipient MySQL version 9.7.1-1..
[Server] Received SHUTDOWN from user <via user signal>. Shutting down mysqld
```

The clone plugin refuses a cross-major donor, so the operator's bootstrap shut mysqld down —
cleanly, exit 0, which is why the pod looked like a graceful restart rather than a crash. 51
restarts and ~90 minutes later `PodCrashLooping` fired. Apps never noticed: HAProxy kept routing to
`main-mysql-mysql-1`, still on 8.4, so the visible damage was `mysql.ready 1/2` — HA gone, single
copy of the data.

**What made it worse than a bad pod.** Two things. First, the StatefulSet is
`updateStrategy: OnDelete`, which is the *only* reason the primary survived — its live template said
`9.7.1-1.1`, so any `delete pod`, drain, or reboot of `worker-node` would have rebuilt the primary
on 9.7 and taken MySQL down entirely. Second, 9.7 mysqld upgraded pod-0's data dictionary in place
before dying, so the revert alone could not fix it:

```
[ERROR] [MY-014061] [InnoDB] Invalid MySQL server downgrade:
        Cannot downgrade from 90701 to 80410. Downgrade is only permitted between patch releases.
```

MySQL has no downgrade path, so that datadir became 9.x-only — the replica had to be rebuilt from
its PVC up, re-cloning from the 8.4 primary.

**Why nothing caught it.** The server image is not chart-managed: `ps-operator` (chart 1.2.0) ships
only the operator Deployment and CRDs, and every data-plane image lives in the
`PerconaServerMySQL` CR. So Renovate's `kubernetes` manager — pointed at `/\.yaml$/` — saw a bare
`image: percona/percona-server:…`, resolved the newest docker tag, and opened a PR with no notion
that the tag must satisfy `crVersion: "1.2.0"`'s support matrix (8.0/8.4 only). The coupling existed
only as a YAML comment. CI cannot see it either: the tag is pinned and well-formed, so `image-pin`
and `kubeconform` both pass; the failure is runtime-only. The major-update rule assigned a reviewer
but set no version ceiling, and a human merge was all it took.

**Fix** (`b43b0cc7`). Pins reverted to `8.4.10-10.1` / router `8.4.10`, plus `allowedVersions`
ceilings so the class cannot recur: `/^8\.4\./` on `percona-server` + `percona-mysql-router`
(later `percona-xtrabackup`) and `/^18\./` on `ghcr.io/cloudnative-pg/postgresql`, which had the
identical exposure via the `imageName` customManager. Patch PRs still flow; majors are invisible
until someone widens the ceiling on purpose, alongside the operator bump and a real upgrade path.

**Rejected:** flipping `upgradeOptions.apply` from `disabled` to `8.4-recommended`. Percona's Version
Service is matrix-aware, which is exactly the missing check, but it patches `.spec.mysql.image` in
the CR — a field Flux owns — and would upgrade the database with no PR, no diff, and no review.
Whoever set `disabled` was right.

**Also found:** `backup.image` had been on `percona-xtrabackup:9.7.1` since #928 (2026-07-15), three
weeks before the server bump. Inert — `backup.enabled: false`, zero `ps-backup` objects — but a 9.x
XtraBackup cannot back up an 8.4 server, so it was wrong-by-default for whoever enabled it. Repinned
to `8.4.0-6.1`. A ceiling alone would not have fixed this one: Renovate never downgrades, so the
stale-high pin needed a deliberate tag pick.

### 2026-08-01 — A cached tarball no upstream fix could displace skipped a whole patch week

The weekly `node-maintenance.timer` fired at 05:30:58. `node-maintenance-phase1.service` died at
05:32:52, `status=2`, on the `yay -Syyu` task:

```
flux-bin-2.9.3_linux_amd64.tar.gz ... FAILED
==> ERROR: One or more files did not pass the validity check!
```

phase1 is fail-fast by design, so it never created `phase2-pending`, its
`ExecStartPost=systemctl reboot` never fired, and phase2 — worker updates and the rolling reboot —
never ran at all. Telegram got the `❌ ... No reboot` notice; nothing else complained for six hours.

**Why the checksum could never be satisfied.** AUR `flux-bin` carried a hardcoded `_srcver=2.8.6` in
its source URL while `pkgver` advanced to 2.9.3, and the local filename derives from `${pkgver}`. So
every weekly "upgrade" since 2.8.7 downloaded the *same v2.8.6 tarball* and parked it under a new
name — `flux-bin-2.9.0/2.9.1/2.9.2/2.9.3_linux_amd64.tar.gz` all sha `c53cc990…`, which is upstream's
`flux_2.8.6_linux_amd64.tar.gz`. `pacman -Q flux-bin` read `2.9.3-1` while `flux version --client`
read `v2.8.6`. AUR commit `45c0b65` "Fix versioning" (2026-07-25 11:44 PDT) corrected the URL and
bumped `pkgrel=2` with the real sum `eae4e860…`. Our 2026-07-25 run had gone through ~6h *before*
that. The next run validated the already-present file against the corrected sum and aborted —
**makepkg does not re-download a source that already exists**, so no amount of upstream correction
could dislodge it.

**Blast radius.** CP took its repo upgrades (incl. `linux-lts 6.18.39 → 6.18.41`) then stopped before
the reboot, leaving a running/installed kernel mismatch. All three other nodes were untouched — still
`6.18.39-1`, uptime 7d 6h. `AlloyLogDeliveryFailing` then fired on 3 alloy pods as a *downstream*
effect: Loki rejects entries older than 168h, idle pods (svclb-\*, node-exporter, kube-state-metrics)
had emitted nothing since the Jul 25 boot, and alloy re-opens those streams from the same offset
forever. The weekly reboot had been implicitly preventing that; one missed cycle surfaced it.

**The second bite.** Clearing the CP's cached tarball let phase1 succeed and the full cycle ran — but
phase2's worker upgrades failed on the *same* stale file, because workers redirect
`SRCDEST=/var/lib/node-maintenance/.cache/makepkg/sources`, which the CP has no override for. PLAY 1's
rescue swallowed it (correctly — a hard failure there strands `phase2-pending` and gates drift-heal
cluster-wide, 2026-06-20). `node_pkg_upgrade_success` was the only thing that saw it: CP=1,
worker-node=0, worker-node-2=0. That metric exists because immich-vm went two weeks unpatched
undetected in July; it paid for itself here.

**Fix** (`db048f3c`). `yay_cmd` gains `--cleanafter`, and the worker `makepkg.conf` template drops its
`SRCDEST` override. Both are needed: measured on the workers, `--cleanafter` logged
`Cleaning (1/1): .cache/yay/flux-bin` while the tarball survived in `.cache/makepkg/sources` — it
cleans only yay's own per-package tree, so it covers sources *only* while `SRCDEST` is unset. No
system-wide `SRCDEST` exists in `/etc/makepkg.conf{,.d/}` on any node, and the CP has never had a user
override, so unset falls back to the CP's proven-working behaviour.

**Residual.** `--cleanafter` only fires after a *successful* install, so a failed build still leaves a
shadowing source — accepted, since the failure is now visible via `NodePackageUpgradeFailed`.

### 2026-07-31 — A chart bump silently stopped the VM operator reconciling for two hours

Renovate merged `b1116022` (victoria-metrics-operator chart 0.66.3 → 0.67.0, operator v0.73.1 →
v0.74.0). Flux applied it at 10:30 UTC. From 10:31:35 the operator logged nothing but

```
Failed to watch  type=*v1.NetworkPolicy
error=... networkpolicies.networking.k8s.io is forbidden: User
"system:serviceaccount:monitoring:victoria-metrics-operator" cannot list resource
"networkpolicies" ... at the cluster scope
```

393 times, and `controller_runtime_reconcile_total` sat flat at 3 until 12:35 — 124 minutes in
which every VM CR change was ignored.

**Why nothing else caught it.** All 25 controllers logged `Starting workers` normally, then parked.
The pod held `Ready 1/1`, `up=1`, `restartCount 0`, `:8081` probes green and a renewing leader
lease the whole time. `controller_runtime_reconcile_errors_total` stayed at **0** — the reconciles
never failed, they never returned. `VMOperatorReconcileStalled`
(`sum(rate(controller_runtime_reconcile_total[15m])) == 0`) was the sole signal, and it fired. This
is the opposite failure mode to the 2026-06-15 metrics-wedge (`up=0`, no scrape at all); an alert
written for one caught the other.

**Root cause — chart-vs-operator RBAC drift.** Operator v0.74.0 added `.spec.networkPolicy` to every
VM CRD ([helm-charts#2977](https://github.com/VictoriaMetrics/helm-charts/issues/2977)) and grants
itself `networkpolicies` in its own `config/rbac/role.yaml`; the v0.74.0 notes ship that grant as a
BUGFIX. Chart 0.67.0's `templates/role.yaml` still grants only `ingresses`/`ingresses/finalizers`,
on `master` too. The read is not gated on the feature: nine factories take a
`if cr.Spec.NetworkPolicy == nil { objsToRemove = append(…) }` branch unconditionally, and
`finalize.SafeDeleteWithFinalizer` opens with a cached `Get` — so controller-runtime starts a
NetworkPolicy informer that can never sync, and every reconcile parks on it.

**Fix** (`63c456a2`) — supplementary ClusterRole + ClusterRoleBinding at
`monitoring/controllers/victoria-metrics/operator-networkpolicy-rbac.yaml` granting
`networkpolicies` `get/list/watch`. Read-only is enough because nothing here sets
`.spec.networkPolicy`, so the operator only ever `Get`s and `SafeDeleteWithFinalizer` returns early
on `NotFound`. RBAC was picked up live — no pod restart. Counter 3 → 72 within six minutes,
rate back to the 0.05/s baseline, alert cleared.

**Removing the workaround is two commits, not one.** kustomize-controller prunes the file the moment
it applies, while the chart's own grant only lands when helm-controller finishes the upgrade. Bump
the chart, confirm `kubectl get clusterrole victoria-metrics-operator` lists `networkpolicies`, then
delete the file.

**Follow-on** (`35dfcf57`) — the same operator upgrade added a second endpoint (`targetPort: 8435`)
to the VMServiceScrape it generates for VMAlert, pointing at the `config-reloader` sidecar.
`vmalert-network-policy` allowed only 8080, so the new scrape came back `connection refused`
(kube-router REJECT) and `ScrapeTargetDown` fired. Added an 8435 ingress rule scoped to
`podSelector: app.kubernetes.io/name: vmagent` — the only scraper of that port — rather than
widening the existing namespace-wide 8080 block.
vmagent's own reloader target was healthy throughout because that scrape is same-pod traffic, which
NetworkPolicy never evaluates — a reminder that "one of the two identical targets is up" says
nothing about the policy.

**Process note.** `63c456a2` was shipped from a Telegram bot session that skipped the pre-commit
review loop. The retro-active Codex review returned APPROVE-WITH-LOW; its one finding was the
two-commit removal ordering above. The incident summary written in that session also had two facts
wrong — "no controllers started" (all 25 did) and "flat at 1 for 105 min" (flat at 3 for 124) —
both corrected here against live metrics.

**Closed the same day.** Upstream issue
[#3129](https://github.com/VictoriaMetrics/helm-charts/issues/3129) + PR
[#3130](https://github.com/VictoriaMetrics/helm-charts/pull/3130) (`- networkpolicies` added to
`templates/role.yaml`) were filed at ~13:0x UTC, merged by a maintainer at 13:21, and chart
**0.67.1** was published at 13:24 — appVersion unchanged at v0.74.0, so the bump carries the RBAC
fix and nothing else (proved by a `dyff` of both rendered charts: only the ClusterRole rule and the
`helm.sh/chart` label differ). Bumped in `6ef450ac`, workaround deleted in the follow-up commit.

**The two-commit rule paid for itself on the first try.** After merging the bump, the chart-owned
ClusterRole still did NOT list `networkpolicies` — the HelmRelease was stuck on
`no 'victoria-metrics-operator' chart with version matching '0.67.1' found`, because
source-controller's cached HelmRepository index predated the release. A same-commit removal would
have pruned the workaround into exactly that gap and re-opened the outage. `flux reconcile source
helm victoriametrics -n monitoring` refreshed the index, the upgrade went through (release v21),
and only then did the gate command show `[ingresses, ingresses/finalizers, networkpolicies]`.
**Generalises: a Helm chart version bump is not applied until source-controller has re-indexed the
repo — check `lastAppliedRevision`, never assume the merge did it.**

Same class as
[#3102](https://github.com/VictoriaMetrics/helm-charts/issues/3102) (chart ClusterRole missing the
VPA grant), fixed in chart 0.66.3 ten days earlier.

### 2026-07-27 — Replication was uploading 129G to the NAS every night and deleting it minutes later

Found while verifying the first full backup cycle after the couchbackup `--parallelism 1` fix.
That cycle was clean, but the replication log showed `sent 138,678,853,989 bytes` with
`speedup is 1.00`, then `pruning dir: immich/20260712_030000` and `immich/20260705_030002` a few
lines later. Same job, same run: upload 129G, delete 129G.

**Two jobs were fighting.** `immich-backup` (weekly) writes to `/mnt/extra-storage/immich-backup`
and publishes to the NAS **itself** (`POOL=…/backups/homelab/immich`), keeping 2 local
generations. `backup-replication` (nightly) syncs a *different* hostPath,
`/mnt/k8s-storage/backups/`, to the same NAS root — and that directory still held 129G of stale
generations from before immich-backup moved to extra-storage. Step 4's `rm -rf` covers only
postgres/couchdb/mysql/pvc, so nothing ever cleaned it. Each night Step 2 re-uploaded those dirs
(genuinely absent on the NAS), and Step 4b's `keep-2` pruned them again because the two newest are
the ones immich-backup pushed directly.

`speedup is 1.00` was the tell, and it is **not** an rsync tuning problem — the files really were
missing at the destination. No flag was missing; the pipeline was circular. (Not to be confused
with the retracted 2026-07-26 claim about `-r` without `-t`, which was wrong — see `e4c3eed7`.)

**Fix:** `--exclude='/immich/'` on the Step 2 rsync. Replication has no business touching a path
another job owns.

**Anchored deliberately.** `immich/` unanchored matches at any depth and would silently drop a
future `pvc/<ts>/immich/…` if that namespace ever gains a critical PVC — it has none today, which
is exactly why the mistake would go unnoticed. Codex catch; proved both ways with a local rsync
fixture before shipping.

Coverage is unchanged: the immich **database** is dumped nightly by `postgres-backup` into
`/source-backups/postgres/` (verified in the same run), and the immich **library** reaches the NAS
weekly from immich-backup's own push. Step 1 validates only postgres/couchdb/mysql/pvc — the "4
validated artifact(s)" — so the exclude cannot affect validation or the Step 3 NAS check.

**Verified 2026-07-28** on the first unattended run after the fix (`backup-replication-29753490`):
`sent 126,326,404 bytes` — 120 MiB against the previous 129 GiB, a ~1,100× drop. Step 4b pruned
only `pvc/20260628_135136` (ordinary 30-day retention); no `immich/` dir was pruned, which is the
direct evidence the upload-then-delete cycle is gone. Step 3 still reported all 4 validated
artifacts on the NAS and Step 4 still cleaned the source. The NAS immich pool holds exactly
`20260719_030004` and `20260726_030007` — keep-2 intact, and the 07-26 generation arrived from
immich-backup's own push, so excluding it from replication costs nothing.

The 129G of stale worker-node dirs were deleted manually the same day; `/source-backups/immich/`
now measures 4.0K in the replication log. Nothing further is open here.

### 2026-07-26 — cert-manager PDBs enabled; and a same-day correction to the B6-2 autogen claim

**Correction first, because it invalidates something written earlier today.** The B6-2 entry below
claimed Kyverno autogen copies `matchConditions` **verbatim** into its controller clones. That is
**wrong**. Autogen rewrites `object.metadata` to the pod-template path in matchConditions as well
as in validations — `object.spec.template.metadata.labels` for controllers,
`object.spec.jobTemplate.spec.template.metadata.labels` for CronJobs. Only `request.namespace` is
left alone, which is precisely why namespace tests are safe there. `.claude/review-invariants.md`
already recorded this correctly; the claim contradicted it and should have been caught on the way in.

Root cause of the error: the reading came from the *old* policy, whose matchConditions contained
nothing but `request.namespace` — a value that is never rewritten — and generalised from that one
case. The offline autogen tests were then built by hand-reproducing the rules with `yq`, rewriting
only `validations`. That reproduced a policy shape Kyverno never emits, so those tests confirmed
the mistaken model instead of catching it.

Consequences, all cosmetic — **the shipped policy is correct and unchanged**:

- The five backup CronJobs' `app` labels on `metadata` and `spec.jobTemplate.metadata` were
  unnecessary; their pod templates already carried `app`. Removed, along with the comments that
  asserted the false rule.
- The B6-2 plan's assumptions C2/C3 are marked REFUTED, and its offline autogen test rows marked
  unsound. The **live** post-deploy probes are what validate the change and they stand: five
  CronJobs produced admittable Jobs, three hostPath controllers still admitted, and a hostPath pod
  was denied in each of the five namespaces.

Lesson, now in the invariants file: **read autogen, never reconstruct it** —
`kubectl get vpol <name> -o json | jq .status.autogen`. A hand-built model of a generator tests the
model, not the generator.

**cert-manager PDBs enabled** (`podDisruptionBudget.enabled: true`, `minAvailable: 1` on the
controller, webhook and cainjector). The chart's own values recommend it whenever
`replicaCount > 1`, and this repo runs 2. Safe at 2 replicas: `disruptionsAllowed` lands on 1 so
drains still proceed — unlike `main-postgres-primary`, which sits at 0 by design. Required
anti-affinity plus `serial: 1` node maintenance already kept one replica up; this makes it
structural rather than incidental. Verified by rendering the chart: all three PDBs materialise and
their selectors match 2 live pods each.

**cnpg-operator deliberately left without one.** Chart `cloudnative-pg` 0.29.0 exposes no PDB
value (checked the full 27KB of values — zero mentions of `disruption` or `pdb`), so covering it
needs a standalone manifest with a hand-maintained selector that would go silently inert on a
chart relabel. Marginal benefit, real upkeep.

### 2026-07-26 — `PodNotReady` measured phase, not readiness — renamed, and the real gap closed

The alert named `PodNotReady` ran `kube_pod_status_phase{phase!~"Running|Succeeded"}`. That is
**phase**, not readiness: a pod that stays `Running` while its Ready condition is false is pulled
from Service endpoints and serves nothing, and the alert never sees it. n8n sat exactly there for
~8h on 2026-07-25 returning HTTP 503 with a dead DB pool. Nothing fired.

- The phase alert keeps its expression under an honest name, **`PodPhaseNotRunning`**.
- New **`PodRunningNotReady`** covers the gap, `for: 15m`.

Deliberately *not* reusing the `PodNotReady` name for the new rule — it would merge two different
meanings in alert history and collide with any silence matching the old name exactly.

Both names added to `silence_alertnames` in the node-maintenance ansible vars, which previously
carried only upstream's `KubePodNotReady`; without that, every node drain would page.

Two guards in the expression are load-bearing, both found in review rather than by writing it:

- `and on(namespace, pod) kube_pod_status_phase{phase="Running"} == 1` — kube-state-metrics
  reports `condition="true"` value 0 for Succeeded Job pods too, so this stops every CronJob
  firing it.
- `unless on(namespace, pod) kube_pod_deletion_timestamp` — a terminating pod keeps
  `phase=Running` while Ready flips false, so one stuck terminating would page.

`condition="true"` is one-hot, so `== 0` covers Ready both False and Unknown.

Verified against live vmsingle, including a **positive control**: the exact expression returns 0
series, and the same expression with `== 0` flipped to `== 1` returns 103. Without that control a
zero would be indistinguishable from a broken query — the failure mode that hid two nights of
CouchDB backup failures earlier in the same week.

### 2026-07-26 — Kyverno namespace-exclude audit: 1 dead exclude removed, wholesale narrowing rejected

Follow-up to B6-2, which narrowed `disallow-host-path`. Four other policies still carried
whole-namespace excludes, so the same treatment looked applicable. **Measurement says otherwise.**

Violation rates across every app namespace those policies exclude:

| Policy | Pods | Violate |
|---|---|---|
| `require-readonly-rootfs` | 31 | 21 (67%) |
| `require-non-root` | 37 | 17 (45%) |
| `disallow-privilege-escalation` | 24 | 12 (50%) |
| `require-drop-all-capabilities` | 24 | 13 (54%) |

B6-2 was worth doing because only ~15% of pods in its namespaces needed the exemption. At 45–67%
a label-keyed rewrite means dozens of selectors against Deny policies — more fragile than the hole
it closes. **Wholesale narrowing rejected on evidence, not taste.**

Exactly one exclude was provably dead: **`percona-mysql` removed from
`disallow-privilege-escalation`**. That namespace holds only `ps-operator`, and the pinned
`ps-operator-1.2.0` chart already sets `allowPrivilegeEscalation: false`. Its
`require-drop-all-capabilities` exclude stays — the operator does not drop `ALL`. If a future
chart bump drops the setting the HelmRelease fails to apply: loud, and worth knowing.

**Two candidates were rejected after checking workload templates rather than running pods.**
`mealie` looks compliant by pod scan, but `Job/mealie-user-provision` runs as root and its pod had
already Succeeded, so a phase-filtered scan hid it. `backup-replication` has no long-running pods
at all; both its CronJobs violate.

**A third was caught in review, not by measurement.** `paperless-ngx` was staged for removal from
`require-non-root` and reverted: `apps/paperless-ngx/deployment.yaml:50` runs a `fix-permissions`
init container as UID 0, which `.claude/review-invariants.md:54` documents as required — s6-overlay
CrashLoopBackOffs without it (incident `ca3891c`→`d3b5036`). The measurement missed it because the
check replicated the policy's own logic and so answered "does this pass?" rather than "does this
run as root?".

That gap is real and wider than this change: `require-non-root`'s first branch is a **pod-level**
`runAsNonRoot` test, so a pod-level `true` satisfies the policy no matter what an individual
container overrides. Any workload can run a root container under it today. Not fixed here, and
recorded as a follow-up.

*(Corrected same day: this first read "tightening it would deny paperless-ngx and mealie, both
documented and deliberate". Wrong — both namespaces are ns-excluded from `require-non-root`, so
they are never evaluated and are not what holds the expression loose. Hardening it means auditing
the namespaces the policy actually matches. Codex catch.)*

### 2026-07-26 — B6-2: `disallow-host-path` narrowed from namespace excludes to workload identities

Last open item of the 2026-07-24 ultrareview remediation plan (removed after `d6d67c20`).
Deferred on 07-25 pending a supervised Audit soak; shipped instead on deterministic proof. Plan
and full test matrix: the B6-2 hostPath narrowing plan (removed after `0cb04187`).

**The gap was wider than recorded.** The policy excluded six namespaces wholesale. Five of them
(`monitoring`, `loki`, `databases`, `immich`, `backup-replication`) also enforce PSS
**`privileged`**, because their hostPath workloads require it — so neither layer guarded them and
every pod in those namespaces could mount any host path. Demonstrated by server dry-run: an
innocent pod plus an injected hostPath was admitted in all five and denied in `home-assistant`,
which is equally `privileged` but was never excluded here. The sixth namespace, `couchdb`, no
longer exists; CouchDB runs in `databases`.

**Autogen was believed to be a landmine. It was not — see the correction below.**

**`couchrestore` would have been missed.** The one-shot DR Job in `.backup/README.md` mounts
hostPath and is invisible to any live scan. Without an allowlist entry it is denied — re-breaking
ultrareview H2, closed two days earlier. Confirmed by removing the entry and watching it fail.

**No Audit soak.** Every check ran in both directions, because a Kyverno `skip` is ambiguous
between "exempted" and "never matched": 8 exempt / 8 denied pairs across pods, controllers, Jobs
and CronJobs, using autogen rules reproduced from the live `status.autogen`. Codex round 1 raised
the Job labels as a HIGH; the factual premise was disproved (API-server defaulting supplies them
before admission) but the latent fragility was accepted and fixed. Round 2 returned no
CRITICAL/HIGH.

### 2026-07-26 — CouchDB backups silently failing two nights; couchbackup parallelism race

`obsidian-personal` — the Obsidian LiveSync database — failed to back up on **07-25 and 07-26**,
five retries each night. Root cause is a concurrency bug in `@cloudant/couchbackup` 2.11.18: at
the default `--parallelism 5` some requests reach CouchDB with **no credentials**, get
`Access is denied due to invalid credentials`, and the run dies with `exit=11` having spooled
batches it never wrote. The small databases (`empty`, `zz-dr-drill`) survive because they never
open enough connections to race. Fixed by pinning `--parallelism 1` (`4d84acc5`).

**This is the same race already documented for the DR restore** in `.backup/README.md`, found
during the 2026-07-24 restore drill. It was written up for `couchrestore` and never connected to
`couchbackup` — same library, same symptom, opposite direction. Anything invoking this package
should assume parallelism 1.

**The failure was two days old and nobody knew**, for two compounding reasons:

- **`vmsingle-vmsingle-0` does not exist.** VMSingle is a *Deployment*, not a StatefulSet. Every
  alert check of the form `kubectl exec -n monitoring vmsingle-vmsingle-0 -- wget …` errored to
  stderr, and with `2>/dev/null` the empty stdout read as "no alerts firing". Three critical
  alerts — `BackupJobFailed`, `JobFailed`, `NoRecentBackups` — were firing the whole time. Always
  resolve the pod by label and assert `.status == "success"` before believing an empty result.
- **The previous code could not have reported it.** Before `e136ae08` the invocation ended
  `> "$DB.raw" 2>&1 || true`: the exit code was discarded and stderr was merged into the file
  holding the backup JSON. The nightly `✅ completed (20.3M)` measured whatever partial JSON
  survived a `grep "^\["` — it never proved completeness. So the pre-07-25 "successes" are
  **unverified**, not known-good; the alert only started because Batch 2 began honouring the
  exit code.

`backup-replication` failed the same nights as a **correct cascade**: no CouchDB archive existed,
so it aborted before syncing and preserved the source rather than deleting the only other copy —
the Batch 2 receipt-before-`rm -rf` guard doing exactly its job.

Recovery was verified rather than assumed: a manual `couchdb-backup` run produced
`obsidian-personal completed (21.1M, 1s)` — matching the pre-failure size and speed — and a manual
`backup-replication` run reported `OK: all 4 validated artifact(s) present on NAS`. Stale failed
Job objects were deleted and `kube_job_failed` now returns no series.

One thing is still open: `zz-dr-drill`, the scratch database from the 2026-07-24 restore drill,
was never dropped and is still being backed up nightly.

**A `speedup is 1.00` on the NAS sync was investigated the same day and is NOT a defect** —
recorded here because it looks alarming and will be re-noticed. The replication moved 138.7 GB
and reported no rsync reuse, which reads like the whole history being re-sent every night. It is
not. Step 2 uses `rsync -av`, and `-a` implies `-t`, so mtimes are preserved and the size+mtime
quick-check works. Two facts explain the number: Step 4 deletes the source
(`postgres`/`couchdb`/`mysql`/`pvc`) after a verified NAS receipt, so on a normal run nearly
every file present IS new; and 129 GB of that particular run was the **weekly** immich backup,
created that morning and never synced because that night's replication had aborted. Step 4
deliberately omits `immich/` — `immich-backup-cronjob.yaml` owns that lifecycle with its own
keep-2 sweep, which is why ~129 GB (two weekly snapshots) legitimately sits in the source tree.

### 2026-07-25 — n8n outage: 8 hours down, no alert, pod reporting healthy

Found incidentally while capturing a monitor baseline for Batch 9. n8n had been serving HTTP 503
since **04:47**, and nothing had fired.

Root cause was a transient PostgreSQL blip during the early-morning node event: n8n's TypeORM
pool logged `connect ECONNREFUSED` against the `main-postgres-rw-pooler` ClusterIP, exhausted
its retries, and never reconnected. By the time it was found the cluster was healthy — postgres
2/2, both pooler pods up, and a TCP connect from inside the n8n pod itself succeeded to the
ClusterIP *and* both pooler pod IPs. The network had recovered hours earlier; only the pool
had not.

**Two failures made it silent, and both are worth remembering:**

- **The readiness probe passes while the app is unusable.** n8n's probe hits `/healthz`, which
  does not touch the database, so the pod sat `1/1 Running` for eight hours with 0 restarts
  while every real request returned 503. Kubernetes had no idea anything was wrong.
- **`kubectl rollout restart` silently did nothing.** It reported "successfully rolled out", but
  Flux's drift detection stripped the `kubectl.kubernetes.io/restartedAt` annotation, reverted
  the Deployment to its git spec, and scaled the *old* ReplicaSet back to 1. The original pod
  survived, same name, same 8h age. Only `kubectl delete pod` worked, because Flux manages the
  Deployment and not the pod it creates. This is the inverse of the usual advice: for a
  no-spec-change restart under drift detection, deleting the pod is the reliable action.

uptime-kuma had it right the whole time — its N8N monitor was the only thing that knew. Its
monitors are not wired to Alertmanager, so "no alerts firing" was never evidence of health.

### 2026-07-25 — Ultrareview remediation Batch 9: the deferred items

Four items earlier batches deferred because each needed a spike first. Two more of the plan's
prescriptions were refuted by actually running those spikes.

**uptime-kuma egress — the plan named the wrong port.** It said to drop 6446/5984/8428/9090.
Dumping the authoritative monitor table showed **5984 is actively probed** against
`couchdb-svc-couchdb`, so removing it would have broken a live monitor. The other three are
genuinely unprobed and were removed: MySQL is monitored on 3306 directly, VMSingle on **8429**
(not 8428), Alertmanager on 9093, and Prometheus no longer exists. Worth recording for next
time: uptime-kuma does **not** use its bundled sqlite here — `/app/data/kuma.db` is a 0-byte
stub and the real data lives in MariaDB, so any monitor question has to be asked there.

**The PVC restore runbook documented 3 of 14 PVCs and could not have worked.** Its extract
target was a literal `pvc-XXXXX` placeholder. The plan said this needed a workload/target
mapping added to `pvc-backup-cronjob.yaml` first — refuted: local-path names every PV directory
`<pv-uuid>_<namespace>_<pvc-name>`, and the owning workload is derivable from the PVC, so both
are discovered at restore time. A hardcoded table would go stale the first time a PVC is
recreated, which is exactly when a restore is most likely.

Three review rounds went into that procedure, each catching a real defect: a `PV_PATH` computed
on the workstation but used on the node (kubectl is not configured on k3s agents, so it is now
resolved node-side by the same glob the backup job uses); a destructive sequence that was not
fail-closed; an overlay extract that leaves files absent from the backup behind — a corrupt
hybrid rather than a restore, so the live directory is now moved aside and kept as a rollback;
a `find | head -1` that would silently pick one of several PV directories; and a STEP 3 that
inherited variables from another shell and would have left the app scaled to zero while
reading as "still restoring". Every block now rediscovers its own inputs. The extract itself is
still **not drilled** end-to-end, and the runbook says so.

**Two Kyverno comments** justified their container-set by pointing at ClusterPolicy twins
deleted in `2b5ffb99`. Git archaeology confirmed both were accurate — the old latest-tag CP
really did use `foreach: list: spec.[initContainers, containers][]` — so the comments were
rewritten to stand alone and to name the resulting gap: `kubectl debug` containers are not
checked for seccomp or for a floating tag. Deliberate; extending enforcement would break debug
during an incident.

**`disallow-host-path` narrowing (B6-2) was deliberately NOT shipped.** The A11 spike succeeded
— every hostPath workload does carry a scopeable label — but it also showed the change needs
**nine** correct selectors against a **Deny**-enforcing policy, and that six of the affected
workloads are CronJobs whose pods exist only while running and are therefore invisible to the
`kubectl get pods` scan such a change would naturally be built from. 41 pods across the six
excluded namespaces currently mount no hostPath and are unguarded, so the gap is real — but
nothing is broken today, and the failure mode of getting it wrong is a backup Job denied at
03:00 with nobody watching, which is the precise silent-failure class this whole review existed
to remove. Full analysis and the Audit-first rollout path are recorded in the plan.

### 2026-07-25 — Ultrareview remediation Batch 8: documentation currency

Every claim was re-derived from the cluster or the manifests rather than from another document, which turned up four inaccuracies the plan had not listed.

**Recorded the Cloudflare Access posture** per tunnel hostname in `ARCHITECTURE.md`, next to the existing note that Traefik middleware never applies on the external path. Access policies live in the Cloudflare zone and leave no repo artifact, so nothing can drift-check them — the table is the decision record. `couchdb` is the one hostname on Service Auth, because Obsidian LiveSync is headless and cannot authenticate a human; `authentik` is deliberately ungated (gating the identity provider locks every other app out of its own login); the remaining seven rely on app-native OIDC, with the accepted trade-off written down: their login pages are internet-reachable, so an app-level auth bug is exposed to the internet rather than the LAN.

**Corrections the plan did not ask for, found by checking rather than trusting:**

- `HOMELAB_ANALYSIS.md` listed **n8n as OIDC**. It has no OIDC configuration anywhere in the repo — n8n SSO is an Enterprise feature, which `CODEMAPS/apps.md` already said. Two docs had been contradicting each other; the codemap was right.
- `SECURITY.md` claimed SSO covered "7 of 16 apps". The 7 was right, the 16 was not, and homepage's new forward-auth was missing.
- The rate-limit figures in `CODEMAPS/apps.md` were the pre-2026-07-03 values (100/min, 200/min) — the middlewares actually enforce `average: 300` and `average: 600` with an explicit `period: 1m`. The codemap also listed **authentik under high-frequency**; authentik carries no rate-limit middleware at all, deliberately, since throttling the SSO provider breaks the auth flow for everything behind it.
- The rotation inventory was missing three secrets, including `cloudflare-api-token` — the DNS-01 credential behind every certificate in the cluster — and `sops-age`, the key that decrypts every secret in this repo. Dates were read from the live objects, not guessed.

**Two runbook commands in `SECRETS_ROTATION.md` could not have worked.** `flux reconcile kustomization apps --timeout 45s --force` uses a flag that does not exist — `flux reconcile kustomization` accepts only `--with-source`. And the Redis rotation told the operator to reconcile `infrastructure-controllers`, but the Redis secrets live under `infrastructure/configs/databases/redis-ha/`, which belongs to `infrastructure-configs`; the reconcile would have reported success while picking up nothing.

Remaining drift cleared: 16→17 apps in `AGENTS.md`, `ARCHITECTURE.md` and the `HOMELAB_ANALYSIS.md` heading, a RustDesk row, Homepage's SSO column, the retired W1→W2 replication leg, decommissioned AdGuard entries, and a `KyvernoPolicyViolationsDailySummary` VMRule that exists in neither git nor the cluster. Dated historical entries mentioning "16 apps" were left untouched — they were true when written.

### 2026-07-25 — Ultrareview remediation Batch 7: runtime hygiene and supply chain

Nine items sharing one shape: a failure that reports success. Every one was reproduced before it was touched, and each fix was proven against the failure it claims to prevent rather than against a green deploy.

**Backups of the class "the check cannot fail."** The HACS installer ran `mkdir -p "$HACS_DIR"` and then verified the install with `[ ! -d "$HACS_DIR" ]` — the directory it had just created, so the check could never fire. It also pulled `releases/latest/download/hacs.zip`, unpinned. Now pinned to 2.0.5 and verified on `__init__.py` + `manifest.json`. The idempotency key moved from directory-exists to *both* artifacts existing, deliberately not to a `.installed-version` marker like `oidc-auth-install` uses: HACS updates itself through the Home Assistant UI, so a hard version lock would revert the operator's in-app updates on every pod restart. The pin bootstraps a fresh volume; it does not hold the version down.

**The cloudflared sync counted its own work and threw the number away.** `COUNT` was computed and echoed, never gated, and a PUT is authoritative for the whole tunnel — so any parser drift would publish a truncated ingress and silently drop external access for every hostname it missed. The guard now counts hostnames straight from the config and refuses to PUT unless the parser agrees. Derived rather than a hardcoded floor, so adding a hostname needs no edit here. Proven in `curlimages/curl:8.21.0` against the real decrypted config: passes at 9/9, refuses at 1/9 when rule indentation drifts, refuses at 0/9 when the `ingress:` key is renamed.

**The postgres extension job told the exact opposite of the truth.** Its `WHEN OTHERS` handler reported every SQL error as "extension already at latest version" and exited 0. Testing showed already-at-latest is a `NOTICE`, not an error — so that handler had only ever fired on genuine failures, and had been relabelling all of them.

The first fix was also wrong, and the peer review caught it: collecting failures and raising at the end still lost the work, because a `DO $$…$$` block is a single transaction, so the final `RAISE` rolled back every successful `ALTER EXTENSION` with it. Reproduced exactly — the log read `Updated pg_trgm` while the catalog stayed at 1.5. The job now runs one `psql -c` per extension, each its own transaction. Verified with a deliberately broken extension: the bad one fails with its real error, the others succeed and **persist**, the job exits 1. Confirmed under `/usr/bin/dash`, the actual shell in the Debian-based CNPG image, not just under alpine's ash.

Two smaller instances of the same class: homepage turned every `cp` failure into "No ConfigMap files to copy (using defaults)" and started on defaults; homehub substituted its password with `sed`, so a `/` or `&` in the secret would corrupt the config silently. Homepage now separates unmounted, unreadable, empty and copy-failed. It tests with plain `ls`, not `ls -A` — a projected ConfigMap always carries a `..data` symlink, so `-A` reports non-empty even at zero keys and would hand `cp` an unmatched literal glob. Homehub uses awk `index`/`substr`, which has no metacharacter surface at all.

**The supply-chain trio is one story.** `image-pin-audit.sh` explicitly skipped `kind: HelmRelease`, with a comment claiming their pinning was "audited elsewhere". It was not audited anywhere — and that blind spot is precisely how the other two got in: the loki gateway carried a bare `tag:` with no `repository:`, invisible to Renovate and a patch behind the same image in `apps/rustdesk/beacon-deployment.yaml`; and `redisOperator.imageTag: "v0.24.0"` froze the operator while Renovate moved the chart to 0.25.0 in `eee4565f`, leaving 0.25.0 CRDs driving a v0.24.0 binary. The audit now covers `spec.values`, and was validated by running it against the pre-fix versions of both files — it fails on exactly those two and stays clean on the fixed tree.

**Redis operator: shipped as its own commit and its own reconcile.** Deleting the frozen tag is not cosmetic — the chart defaults to `v<appVersion>`, so it upgrades the live operator. v0.25.0 carries "mount config emptyDir volume so sentinel.conf persists across container restarts", and the live sentinel StatefulSet declared a `config` volume its container never mounted, so the upgrade was always going to roll the sentinel pods. Verified afterwards: `/etc/redis/sentinel.conf` now sits on the mounted volume, all three sentinels rolled and rejoined, `num-other-sentinels 2`, one slave discovered, no failover, no alerts. The seccomp `postRenderer` was dropped in the same change because chart 0.25.0 exposes a `podSecurityContext` values hook — proven render-identical with `dyff` before the swap, and confirmed live on the upgraded Deployment.

`apps/blocky/pdb.yaml` closes the last item. The plan claimed blocky was the only multi-replica workload without a PodDisruptionBudget; that is **false** — cert-manager (×3) and cnpg-operator also lack one. Only blocky was given one: it is the LAN DNS resolver, so draining both replicas blackholes name resolution for every client on the network, while the others are reconcile-only operators where brief unavailability costs nothing.

### 2026-07-25 — Ultrareview remediation Batch 5: authentication for Alertmanager and homepage

`am.h0melab.work` served `/api/v2/silences` to anyone on the LAN — a `200`, verified live — so any device on the wifi could suppress all alerting. Both hosts are LAN-only (neither is in the Cloudflare tunnel), so the threat is the local network, not the internet.

**Deliberately two different mechanisms**, matched to each service's role:

- **Alertmanager -> Traefik basicAuth** from a SOPS Secret. It is an incident-response tool, so it must not depend on the stack it is used to debug: putting it behind Authentik would couple it to postgres -> authentik, and a CNPG failover would take out the alert console exactly when it is needed. Verified after deploy: `401` with no credentials, `200` with, `401` with wrong ones.
- **homepage -> Authentik forward-auth** via the **embedded outpost**. No separate outpost deployment exists or was needed — `authentik-server` already exposes port 9000, and Traefik->authentik:9000 egress plus authentik's ingress-from-traefik were already permitted, so this batch adds **zero** NetworkPolicy changes. First proxy provider in the instance; everything else uses OIDC.

Findings that changed the shape of the work:

- **The homepage callback cannot live in the homepage namespace.** An Ingress can only target a Service in its own namespace, and routing `/outpost.goauthentik.io/` via an ExternalName alias fails: Traefik's `kubernetesIngress` provider defaults `allowExternalNameServices` to **false** and it is not enabled here, so Traefik silently refuses that backend. A `--dry-run=server` does not catch it — the object is valid, Traefik just declines to route it. The callback Ingress therefore lives in the **authentik** namespace, where `authentik-server` is a normal same-namespace Service, which also avoids weakening that global default.
- **The callback must be its own Ingress.** Traefik applies the `router.middlewares` annotation to every rule in an Ingress, so folding the callback into the protected Ingress would authenticate the request that completes the login — a redirect loop.
- **Auth goes AFTER rate-limit in both chains.** A 401 or redirect short-circuits the chain, so auth placed earlier would leave login attempts unthrottled.
- **Traefik's basicAuth Secret must contain exactly ONE key.** Storing the plaintext password alongside the htpasswd `users` key made the middleware fail to build; Traefik dropped the router and the host answered **404 instead of 401** — a silent outage with nothing in the Traefik error log. Caught in post-deploy verification and fixed by splitting the plaintext into a separate, unreferenced Secret.

Shipped in **two phases on purpose**: phase 1 added the middlewares, blueprint and callback route with nothing referencing them; phase 2 flipped the ingress annotations. Without the split, the Alertmanager annotation (in `monitoring-controllers`) would have applied before the middleware and Secret (in `monitoring-configs`, which depends on it), leaving Traefik pointing at a middleware that did not exist yet. Between phases the callback path was confirmed to redirect correctly to authentik before anything was gated on it.

No monitor was affected: uptime-kuma probes both apps via cluster Services, never the ingress hostname, and nothing in-cluster resolves `am.h0melab.work` (VMAlert posts to the Service).

The generated credential is in the SOPS-encrypted `alertmanager-basic-auth-credential` Secret (`username`/`password`) — read it with `kubectl -n monitoring get secret alertmanager-basic-auth-credential -o jsonpath='{.data.password}' | base64 -d`, move it to 1Password, then delete that Secret and add the entry to `SECRETS_ROTATION.md`.

### 2026-07-25 — Ultrareview remediation Batch 6: policy, NetworkPolicy and RBAC hygiene

Six of eight items; the two spike-gated ones are deferred (below). Every fix verified against live cluster state rather than against the finding text.

- **monitoring `rate-limit-standard` enforced 100 req/second, not per minute.** `rateLimit.average` is per `period` and the default period is **1s**, so `average: 100` with no `period` was 60x looser than the comment directly above it claimed ("100 requests/minute sustained"). The apps tier was corrected on 2026-07-03; this monitoring fork was missed. Added `period: 1m`.
- **popeye held cluster-wide `get,list` on Secrets.** A `list` returns full secret *content*, so a weekly hygiene scanner had standing read access to every credential in the cluster. Removed. Cost is popeye's unused-secret linter; the CronJob runs `--force-exit-zero` so the rest of the scan is unaffected.
- **Kyverno NetworkPolicy allowed a port nothing listens on.** Every kyverno controller (admission, background, cleanup, reports) serves its webhook on **9443** — verified against the live pods; none listens on 443. Removed the dead 443 entry and corrected the comment, which attributed 9443 to the admission controller alone.
- **Two dead "Kubernetes API" egress rules on `mysql-cluster`, replaced with one that works.** `namespaceSelector` selects pod namespaces: `default` holds **zero pods** (the API is a Service at 10.43.0.1:443 backed by the control-plane node, not a pod), and the `ps-operator` pod in `percona-mysql` declares **no container ports at all**. Deleting them outright was the first attempt and review pushed back correctly: steady-state health is not evidence of restart safety, since Percona pods can need the API for peer discovery during bootstrap or recovery. Both dead rules are now replaced by `ipBlock: 192.168.1.127/32` on **6443** — the same pattern grafana, prometheus-operator and kube-state-metrics already use here, because NetworkPolicy is evaluated after DNAT so the ClusterIP is not the address that matches.
- **authentik and obsidian had namespace-wide database egress.** Both now scope to the serving pods (`cnpg.io/cluster: main-postgres`, `app: couchdb`) with `podSelector` under the **same** `to` item as `namespaceSelector` — AND, not OR; as separate items it would have widened the grant instead of narrowing it. Confirmed in the rendered output. `cnpg.io/cluster` deliberately chosen because it covers the rw-pooler pods as well as the instances, and authentik connects via `main-postgres-rw`.
- **Removed a fossil Kyverno exclude** for `main-mariadb-metrics` in `require-non-default-serviceaccount` — MariaDB was replaced by Percona MySQL and zero such pods exist.

**Deferred, both spike-gated and needing work the plan scopes separately:** narrowing `disallow-host-path`'s whole-namespace excludes to label-keyed `matchConditions` (A11 — needs per-workload rendered-label discovery plus an admission probe for each), and dropping uptime-kuma's four dead egress ports (A10 — needs the live monitor list first, since a port that looks dead may back a configured probe). Also deferred: correcting three `ephemeralContainers` comments in the Kyverno policies, which needs its own reachability check rather than a text edit.

### 2026-07-25 — Ultrareview remediation Batch 4: monitoring correctness

Nine alerting defects, every one verified against live VictoriaMetrics before editing. **One finding was refuted as written** — see the first item; applying the plan verbatim would have replaced a dead alert with a differently-dead one.

- **`BackupJobRunningTooLong` was dead — but not for the documented reason.** The audit said the metric should be `kube_job_status_complete`; on this cluster's kube-state-metrics **v2.19.1 that metric does not exist** (0 series) while `kube_job_complete` has 51. The real defect is that `kube_job_complete` carries a `condition` label (true/false/unknown) which `kube_job_status_start_time` does not, so `and` — which matches only identical label sets — produced nothing. Now excludes both TERMINAL **conditions** — `unless` `kube_job_complete{condition="true"}`, `unless` `kube_job_failed{condition="true"}` — meaning "old, and neither finished nor failed". Two earlier attempts were rejected in review, each with its own blind spot: `kube_job_status_active > 0` misses a stuck Job whose pod was evicted or sits between retries (nonterminal, `active == 0`), and `kube_job_status_failed > 0` counts failed *pods*, so a Job that lost one pod and is still retrying would be excluded while genuinely stuck. `kube_job_failed` shows zero series today only because nothing has failed — verified against the KSM scrape that it is a registered STABLE family emitting condition metrics only for conditions actually present, so the `unless` excludes nothing until a Job really fails.
- **`KyvernoAdmissionControllerDown` evaluated hourly** (`interval: 1h`) → a critical reported up to an hour late. Now 60s.
- **VMSingle healthCheck was vacuous.** kstatus treats a CR with no `status.conditions` as Current, and VMSingle publishes none — confirmed live, its status carries only `updateStatus`/`lastAppliedSpec`/`observedGeneration`. Replaced with `healthCheckExprs` on `status.updateStatus` (live value `operational`), gated on `status.observedGeneration == metadata.generation` so a stale status from the previous generation cannot be read as describing the spec just applied. Only `current` and `failed` arms are given — Flux treats anything matching neither as in-progress, and the operator's full `updateStatus` vocabulary is not published (the CRD ships no description), so enumerating it would risk a value like `updating` matching nothing and wedging the gate on every rollout. Verified the field exists in the installed CRD schema and that the edited object passes a server-side dry-run.
- **PostgreSQL + Redis `ConnectionFailure` deleted rather than repaired.** Both were dead (`and` across mismatched label sets — each returns 0 series live), and zero transactions or zero connected clients means idle, not broken. Real availability is already alerted on by `cnpg_collector_up == 0` and `redis_up == 0`.
- **Three quorum alerts could never fire, each for two compounding reasons.** `count()` counts series, and KSM emits `phase="Running"` valued **0** for pods that are not running (17 such series exist right now), so the count never dropped. Worse, `count()` over an *empty* vector returns **no series at all** — so in the total-outage case each alert names, the comparison produced nothing and stayed silent. Both fixed with `(count(... == 1) or vector(0))` on `RedisHASentinelQuorumLost`, `MySQLOrchestratorNotRunning`, and `RedisHAAllDown`. That inverts the failure mode — absence now reads as 0 rather than as nothing — so the two redis alerts moved from `for: 1m` to `for: 5m`, or a kube-state-metrics restart would page. Four minutes of latency in exchange for an alert that fires at all. The last is the sharpest example: when every redis pod is down its exporter targets vanish, `redis_up` disappears, and "All Redis replication pods down" was silent precisely when it mattered. Proven by simulating the outage with a selector matching nothing — all three old forms return 0 series, all three new forms fire.
- **`NoRecentImmichBackup` was missing from the telegram-backup route regex**, so it went to the default receiver.
- **The NodeDown inhibit rule was a no-op.** NodeDown derives from node-exporter, whose `instance` is `192.168.1.x:9100`; the pod alerts it was meant to suppress carry kube-state-metrics' `instance` (`10.42.3.65:8080`), so `equal: [instance]` could never match. Deleted.
- **Two new `absent()` alerts.** `NASLibraryMountMissing` — `NodeDiskSpaceLow/Critical` already cover the virtiofs mount's capacity (confirmed: `/var/lib/immich-library` is visible to node-exporter), but only while the series exists; if the NAS detaches the series vanishes and those alerts go quiet instead of firing. `VMAgentIngestionDown` — same shape, for the case where vmagent stops being scraped entirely and `up{...} == 0` therefore never evaluates.

SMART/RAID health on the NAS stays unmonitored — not readable without sudo — and is recorded as an accepted risk rather than worked around.

Gates: all four new/changed expressions executed against live VictoriaMetrics (parse clean, correctly non-firing); yamllint; kubeconform on `clusters`, `monitoring/configs`, `monitoring/controllers`; kustomize builds; server-side dry-run of the changed Kustomization.

### 2026-07-24 — Ultrareview remediation Batch 3: CouchDB DR restore path, drilled end-to-end

The audit found the documented CouchDB restore could not run (bare `kubectl run` denied by Kyverno; `wget --method=PUT` is not a busybox flag). Running it turned up **four** blockers, not two — the last of which only appears after part of the restore has already succeeded.

**Now drilled end-to-end**: a full restore of the live Obsidian database into a scratch target completed — 1505 document revisions, 1479 docs against 1494 live (the gap is edits made after the 03:05 backup), deleted-doc counts matching exactly at 21. Scratch database dropped afterwards.

What actually blocked it:

1. **Kyverno.** All 12 ValidatingPolicies are Deny-enforcing; a bare `kubectl run` is rejected at admission. Proven live — and the fine-grained webhook names only the FIRST failing policy (`require-labels`), so fixing one field just reveals the next. The spec now carries all of it, including `serviceAccountName: couchdb-jobs` for `require-non-default-serviceaccount`, which the audit did not flag.
2. **ResourceQuota, a second rejection after Kyverno passes.** `namespace-quota` on `databases` leaves ~800m CPU free on a running cluster, so the initial 1-CPU limit was refused. Limits now sized to fit.
3. **`readOnlyRootFilesystem` breaks npm** — its default `~/.npm` is unwritable, so `npm install` fails and couchrestore is simply absent. Fixed with `HOME` and `npm_config_cache` in the `/tmp` emptyDir, keeping RoRFS on rather than disabling it.
4. **`--parallelism 5` (the default) breaks authentication mid-restore.** Some concurrent requests reach CouchDB carrying no credentials at all — its log shows the user as `undefined` and returns 401 on `_bulk_docs` — after several batches have already been written, so it reads as partial success rather than a broken command. `couchrestore` has no username/password flags, only `--url`, so `--parallelism 1` is the fix and is now marked as required, not tuning.

Also corrected: the restore is now a **Job reading the archive from the backup hostPath** instead of streaming through `kubectl run -i` (whose attach timed out and killed the pod); it selects the newest archive itself and **verifies the `.sha256` in-pod**, so no node SSH is needed — which matters because that key lives in 1Password and may be locked mid-incident. The DB pre-create uses Node's built-in `fetch` with an Authorization header, and passes `?n=2` to match `clusterSize: 2` (CouchDB defaults new databases to n=3 and logs `Request to create N=3 DB but only 2 node(s)`). A `DRILL_SUFFIX` switch restores into `<db>-drill` so the whole path can be rehearsed without touching live data, and drops the scratch DB first so re-runs are idempotent (couchrestore refuses a non-empty target). Image drift fixed (`node:24.16.0-alpine` → `24.18.0-alpine`) and `@cloudant/couchbackup` pinned to 2.11.18.

Added a **NAS-fetch Job** alongside the existing shell rsync: it reads the `nas-rsync-credentials` secret and inherits the namespace's NAS egress policy, so archives can be pulled back without a node shell or the password in the operator's environment. Verified pulling the 16.6 MB 2026-07-24 archive.

Both manifests were re-rendered *from the committed markdown* and re-validated with kubeconform plus a live `--dry-run=server`, so the documented commands are the ones that were executed.

**Deferred:** B3-2 (PVC restore runbook covers 3 apps while `CRITICAL_PVCS` backs up 10) needs a workload/target mapping added to `pvc-backup-cronjob.yaml` first — split into its own batch rather than stretch this one further.

### 2026-07-24 — Ultrareview remediation Batch 2: backup integrity + data-loss guards

Closes the audit's highest-severity finding and the silent-loss paths around it. Backups are the only durability substrate here (no PITR, no offsite — both standing decisions), so every one of these failed *quietly*.

- **CouchDB backup success-theater (the HIGH).** `couchbackup … > ${DB}.raw 2>&1 || true` discarded the exit code and merged stderr into the data stream; success was then "any line starts with `[`". A mid-stream fatal produced a **truncated dump that earned a valid sha256, passed replication validation, advanced `lastSuccessfulTime`, and fired no alert** — then 30-day NAS pruning plus source deletion could leave no complete copy of the Obsidian vault. The identical class was fixed for postgres/mysql/pvc on 2026-07-03; couchdb was missed. Now: stderr to its own file, exit code captured, and completeness computed from the `--log` mirroring upstream `includes/logfilesummary.js` — require `:changes_complete` **and** every `:t batchN` cancelled by a `:d batchN` (`:changes_complete` alone only proves spooling). Fails with stderr + log tail *before* packaging. A zero-document database is correctly treated as complete rather than failing the whole run (it fails on `main` today). `@cloudant/couchbackup` pinned to **2.11.18** — it was installing unpinned, floating the tool that produces the DR artifact.
- **Replication "Verify NAS" could not fail** — `rsync --list-only | head -20 || echo "failed"` (head exits 0; the `||` swallowed the rest), yet Step 4 `rm -rf`s every source backup immediately after. Now each artifact that passed Step 1 is recorded by its **source-relative path** and must appear in the post-sync listing, matched **exactly on the listing's path field** — a substring match let `x.tar.gz.sha256` vouch for a missing `x.tar.gz`, and a flattened name would never match the nested `pvc/<timestamp>/<namespace>/<file>` layout. On any miss: report and `exit 1` **without** cleaning source. A guard also blocks the vacuous case where the list is empty or short, counted from a shell variable rather than re-read from a file so the expectation cannot share a failure mode with what it audits.
- **Replication reported failures as success.** `OVERALL_OK != true` sent a Telegram message but never exited non-zero, so `kube_job_*` stayed green and every status-keyed alert stayed silent. The retention-sweep and NAS-size listings also hid failures: `set -e` without `pipefail` and pipelines ending in `awk` meant a failed listing read as **0 GB**, indistinguishable from a healthy empty NAS, so the 400/450 GB tiers could never fire.
- **PVC backup**: an empty critical PVC was an uncounted `continue` → green forever. Now counted as a failure, matching the adjacent missing-PVC branch's own stated reasoning.
- **17 PVCs across 12 files** annotated `kustomize.toolkit.fluxcd.io/prune: disabled`. `local-path` reclaimPolicy is **Delete** (verified live), so a Kustomization rename or removal would take the data with it.
- **mysql backup client 8.4.8 → 8.4.10** to match `percona-server:8.4.10-10.1`; the renovate rule changed from blanket `enabled: false` (which is how it drifted) to `allowedVersions: "/^8\\.4\\./"`. Codemap `startingDeadlineSeconds` 600 → 3600 (all three CronJobs say 3600).

Verification went beyond a green run, because CI cannot see embedded CronJob shell at all. The `:t`/`:d` semantics were read off IBM/couchbackup source; the completeness awk was tested on 6 fixtures **and re-run under busybox awk inside the real `node:24.18.0-alpine` image**; the pinned couchbackup was installed in that image; NAS matching was tested against a realistic rsync listing including the sidecar-vouching case; `flux diff kustomization apps` proved the annotations touch exactly 17 objects with no create/delete/replace. Extracted embedded shell shellchecked against `main`: finding counts identical. Two bugs of my own were caught only by executing: `$(grep -c … || echo 0)` captures *both* outputs, yielding `0\n0` that busybox `test` rejects as a bad number and aborts under `set -e`; and a blanket `|| true` on the JSON filter masked grep exit ≥2 (real I/O error) as well as the intended exit 1. Codex STATIC review, 3 rounds to cap: R1 BLOCK (3 HIGH — empty-DB rejection, wrong PVC path, substring matching), R2 HIGH+MED (filter masking, vacuous list), R3 no HIGH/CRITICAL, one MED fixed anyway.

### 2026-07-24 — Ultrareview remediation Batch 1: CI validation coverage

Closes the gaps that let changes ship unvalidated. Sequenced before the fix batches because those edit `clusters/` and `immich-vm-heal.sh`, neither of which CI touched.

- **kubeconform matrix + `clusters`** (6 roots → 7). The Flux Kustomization CRs were never schema-validated. Structural only — the CRD types `healthChecks`/`dependsOn` entries as strings, so a name or GVK matching nothing still passes; that stays a manual review item.
- **shellcheck repo-wide** instead of `find scripts docs/scripts`, pruning `.git` and `.claude/worktrees`; same anchor dropped from the pre-commit hook. Newly covers `apps/immich/gpu-node/immich-vm-heal.sh`, `.backup/secrets-{backup,restore}.sh`, `.claude/hooks/*.sh`, `docs/worker-node-post-install.sh` — 42 files, all clean at `-S warning`. Corrected a **false comment** while there: it claimed `-S warning` catches the SC2015 `A && B || C` class, but shellcheck emits SC2015 at *info* (`Analytics.hs`, `info id 2015`), so the gate never saw it. Threshold left alone — `-S info` surfaces 15 pre-existing findings (SC2016/2162/2086/2012) needing their own pass.
- **`check-sops-encrypted.sh` gained a per-document content pass.** Filename matching alone let a plaintext `kind: Secret` in an off-pattern file through. Now every `*.yaml`/`*.yml` is split on `^---` in awk and **each document** must carry `ENC[AES256_GCM` — file-wide grep would let an encrypted document 1 vouch for a plaintext document 2. Handles quoted `kind: 'Secret'`/`"Secret"`, trailing `# comment` on both the kind line and the separator, CRLF, and leading-`---` numbering; `kind: SecretStore` correctly ignored. `exit $((missing > 0))` because a raw count wraps mod 256.
- **gitleaks split into `.github/workflows/gitleaks.yaml`** with no `paths-ignore`. `validate.yaml` skips markdown-only pushes, so a credential pasted into a runbook or plan was reaching main unscanned. Checkout + scan is ~15s.
- **`KUSTOMIZE_VERSION` v5.5.0 → v5.8.1** — CI was rendering a different tree than the cluster. Chain verified: kustomize-controller `v1.9.1` → `sigs.k8s.io/kustomize/api v0.21.1` → kustomize CLI `v5.8.1` (v5.5.0 pinned api v0.18.0). **`KUBERNETES_VERSION` 1.36.1 → 1.36.2** to match the live cluster, as the file's own comment instructs; v1.36.2 schemas confirmed present upstream.

Gates (CI runners are billing-blocked — all jobs 0-step since before this batch — so every job was replicated locally): all 7 kubeconform roots under the new versions, 529 resources, 0 invalid; repo-wide shellcheck; actionlint; yamllint; init-resources; image-pin; gitleaks. The sops checker was proven with 9 behavioural tests, not just a green run. Codex STATIC review, 3 rounds to cap: R1 REQUEST CHANGES (2 MED), R2 CHANGES REQUESTED (the `seen` dedupe still let a *named* secret file hide a plaintext second document — the original bug relocated), R3 BLOCK (3 MED: comment-suffixed kind, CRLF separator, mod-256 exit) — all fixed and retested. One Codex claim contested and withdrawn: the shellcheck severity flag was never in the diff.

### 2026-07-24 — Ultrareview remediation Batch 0: token leak, CI-gate claim, DR tarball ignore

First batch of the 2026-07-24 ultrareview remediation plan (removed after `d6d67c20`; 58 findings, 0 refuted; H3 CouchDB exposure closed same day via Cloudflare Access Service Auth).

- **`apps/pricebuddy/apprise-configmap.yaml`** — the apprise init script ended with `cat /config/pricebuddy.cfg`, printing the Telegram bot token to init-container stdout and therefore into Loki (**720 h retention — existing lines carry the token for ~30 days after this fix**). Deleted; a comment now names the constraint so it isn't re-added. **Decision: not rotated.** `pricebuddy-telegram` is a dedicated secret separate from claude-telegram, so the blast radius is the price-alert chat, not the ops channel; readers are limited to Grafana/Loki (anonymous off, basic off, login form disabled, Authentik passkey-only OIDC) and anyone with `kubectl logs`.
- **`AGENTS.md` + `docs/HOMELAB_ANALYSIS.md`** — the "CI gate-of-record" invariant was false. Branch protection is unavailable (private repo on the GitHub Free plan; `gh api …/branches/main/protection` → 403) and Flux syncs `main` every 5 min regardless of the CI verdict, so nothing mechanically stops a validate-red commit from reaching prod; `/gitops-workflow` step 3c blocking `fr` on red only withholds the manual nudge. Reworded to "a signal, NOT a merge gate", naming the pre-commit review loop and `/homelab-yaml-validate` as the gates that actually hold. **Decision: no `ci-green` promotion ref** — repointing a bootstrap-generated `gotk-sync.yaml` is the highest-structural-risk change available here, and the per-batch static review is the control that has actually been catching defects. Stale count corrected in the same line: kubeconform covers 6 roots, not 5 (`validate.yaml:138-144`).
- **`.gitignore`** — added `.backup/*.tar.gz.gpg`. `secrets-backup.sh:235` writes `${BACKUP_DIR}/secrets-backup-${TIMESTAMP}.tar.gz.gpg` with `BACKUP_DIR="$(dirname "$0")"`, so an encrypted DR bundle landed in a tracked directory with no ignore rule.

Gates: yamllint, `kustomize build`, gitleaks (tree mode — history mode's 11 hits are already-rotated values CI deliberately skips, `validate.yaml:91-96`), sops-check (57 files), init-resources, image-pin — all green. Codex STATIC review: APPROVE WITH NITS, one nit (the 5→6 root count) verified against the workflow and fixed.

### 2026-07-23 — WARP managed-network beacon: home/away device profiles auto-switch

Added `warp-beacon` to the `rustdesk` namespace (`apps/rustdesk/beacon-*.yaml`): `nginxinc/nginx-unprivileged:1.30.4-alpine` serving a 10-year self-signed cert (CN `warp-beacon.h0melab.internal`, fingerprint `4B8045EA…B2F3DF`) on **192.168.1.129:18443** (same W1 servicelb ETP=Local pin as RustDesk). Key in SOPS Secret; cert+nginx.conf in ConfigMap; PSS-restricted, RoRFS, deny-all-egress; ingress 8443/TCP from LAN only — **deliberately NOT tunnel-reachable**, off-LAN detection must fail (per CF managed-networks docs: 5 s probe timeout → default profile, no retry).

Zero Trust side (dashboard): managed network **`home-lan`** = `192.168.1.129:18443` + pinned cert SHA-256; device profile **"Home LAN - direct"** (precedence 1, match `Managed network is home-lan`, split-tunnel Include = inert `192.0.2.1/32` only) — retargeted from the interim same-day `os == macOS` profile; **Default** (precedence 2) keeps the `192.168.1.129/32` include. Net effect for every enrolled device, current and future (2nd Mac, Windows): at home → tunnel nothing, RustDesk + node SSH direct on LAN; away → tunneled `.129` route for remote RustDesk. This closes the same-day gotcha where the `.129/32` teamnet route hijacked Mac→W1 SSH whenever WARP was Connected.

Verified end-to-end: beacon fingerprint match + 200 in 47 ms from LAN; after a WARP cycle the Mac (profile now matches ONLY via beacon) still received the inert include → detection proven; ping + SSH:65300 + RustDesk 21116 all green with WARP Connected. Codex STATIC review SHIP (accepted MED: single replica — safe degradation, probes fire only on network change and a beacon outage just means away-profile/tunnel routes; accepted LOW: subPath mounts don't hot-reload — cert rotation is a coordinated event with the dashboard fingerprint). CI on the push was the billing-block fail-to-start signature (all 13 jobs, 0 steps) — classifier initially miscalled it content-red over a null-conclusion job; `ci-red-classify.sh` (dotfiles) fixed same day (conclusion-agnostic zero-step + explicit CANCELLED exit 12, 2 Codex rounds).

### 2026-07-23 — node_isolation_heal ACTIVE (dry-run off after 13-day soak) + interlocks

`node_isolation_dry_run: false` — the worker CP-isolation watchdog (dry-run since 2026-07-10, `68f114d0`) now acts: L1 `systemctl restart k3s-agent` at ≥6 min isolated; staggered L2 self-reboot (W1 15 min / W2 23 min, `cp_direct`-gated, ≤1/24 h, uptime>30 min) as last resort. **Soak evidence:** 13 days, zero false pending actions, zero giveups; the only `wedged=1` sample was a <6 min blip on W1 during the 2026-07-18 Saturday phase2 reboot window — exactly the class the new maint-hold suppresses.

Activation interlocks (same commit):

- **phase2.yml** touches worker-local `/var/lib/node-isolation-heal/maint-hold` right before each orchestrated worker reboot and removes it after uncordon — the watchdog skips its ladder while the hold is <1 h old; a stuck hold ages out.
- **k3s-agent restart serialization**: `clusterip-heal.sh` and `node-isolation-heal.sh` both take a non-blocking `flock` on the shared `/var/lib/k3s-agent-restart/cooldown`, held check→restart→touch (mtime-only check left an interleave window — review HIGH). Lock-infra failure **fails closed** (skip cycle; wedged metrics/alerts still fire — review R2 HIGH); `NIH_SKIP_LOCK=1` is a test-harness-only bypass (macOS has no flock).
- **VMRules**: `NodeIsolationHealActing` (warn, wedged >8 m), `NodeIsolationHealPendingReboot` (critical, `for: 1m` — fires on persistent dry-run/guard-blocked states only; the active reboot path zeroes `pending_action` before rebooting, since the textfile survives the boot under `/var/lib` and a stale 2 would double-page — review R3 MED), `NodeIsolationHealRebooted` (critical — new persistent `node_isolation_heal_last_reboot_timestamp` gauge re-emitted from the on-disk state file each cycle; the sole alert for a completed self-reboot — review R1 MED), `NodeIsolationHealGaveUp` (critical).

Rollout: ansible side lands via the 10-min git sync + 03:00 UTC drift-heal; vmrules via Flux `monitoring-configs`. Gates: shellcheck/shfmt/yamllint/ansible-lint clean, ladder tests 22/22, vmrules metric audit (new gauge's series appears after first node run; absent series = alert no-op). Codex STATIC review 3 rounds (R1 BLOCK: lock race HIGH + alert-reliability MED + stale plan LOW; R2 BLOCK: fail-open fallback HIGH + double-fire MED + plan sections LOW; R3 BLOCK: 1 MED persisted-textfile double-fire, no HIGH — fixed post-round, cap reached). Plan: `docs/plans/2026-07-10-node-isolation-heal.md`.

### 2026-07-20 — RustDesk server (OSS) self-hosted, LAN remote desktop

Added `apps/rustdesk/` — RustDesk rendezvous (`hbbs`) + relay (`hbbr`) from `rustdesk/rustdesk-server:1.1.15`, 1 pod / 2 containers sharing a 100Mi `local-path` PVC (`/data` holds the ed25519 keypair + `db_v2.sqlite3`). One mixed-protocol LoadBalancer Service (21115/TCP, 21116/TCP+UDP, 21117/TCP), pod pinned to **W1** so under servicelb ETP=Local only **192.168.1.129** carries traffic (.126 advertised but blackholes — clients use .129). Deny-all-egress NetworkPolicy (server needs no upstream; verified by docker spike with `--network none`).

**`-k _` is not full authentication** (corrected against master source after operator flag). It makes hbbs auto-generate a keypair and enforce the matching public key **only** on the TCP `PunchHoleRequest` (connect-to-a-peer) path (`rendezvous_server.rs:682` `LICENSE_MISMATCH`) — so an outsider can't broker a session to your registered devices without it. It does **not** authenticate device registration (`RegisterPk`) nor the `PunchHoleSent`/`LocalAddr` handlers, which is the CVE-2026-30784 UDP-reflection surface. Session crypto is peer-to-peer, independent of the server key.

- **17th app; new `rustdesk` namespace.** 2-commit bootstrap (ns+SA+NP → reconcile barrier → workload) per the 2026-07-14 Kyverno `require-networkpolicy` dry-run gotcha.
- **Scored GO, LAN-only.** WAN scored 1/5: 21116/UDP is mandatory and can't traverse the Cloudflare Tunnel (HTTP-only), and zero-inbound-ports stands. WARP-via-tunnel chosen as the remote-access path (pending Zero Trust enrollment).
- **CVE-2026-30784** (rustdesk-server#670, open): `hbbs` reflects UDP `PunchHoleResponse` to attacker-chosen addresses without key validation (`-k _` doesn't gate `handle_hole_sent`/`handle_local_addr`). Maintainer commit `80d3a505` (2026-07-01) only made UDP `PunchHoleRequest` unsupported (+2/−10) — it does **not** touch the `PunchHoleSent`/`LocalAddr` reflection path, so master is **not** a real fix and self-building it gains nothing. Decision: **stay on pinned 1.1.15** — primary mitigation is LAN-only reachability; deny-all-egress NP is defense-in-depth (reflection to any no-conntrack-tuple address = new egress = dropped). Renovate picks up a genuinely-fixed release when one ships.
- **Verified:** pod 2/2 on W1; LB IP 192.168.1.129; all 3 TCP ports reachable from Mac; a real Mac RustDesk client hit hbbs over **UDP 21116** (NAT responses on 21116+21115, 2.7ms latency, `register_pk` initiated) — proving the UDP app path + registration against the self-hosted server. Peer review: Codex STATIC, plan (2 rounds) + manifests (1 round, verdict SHIP, one NIT fixed). Plan: `docs/plans/2026-07-19-rustdesk-server.md`.

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

### 2026-07-04 — Kyverno CP→VP migration Phase 1: 12 CEL ValidatingPolicy twins in Audit + vp-canary

`kyverno.io/v1` ClusterPolicy removal lands Kyverno 1.20 (~Oct 2026). Phase 1 of the 4-phase migration: every CP now has a `policies.kyverno.io/v1` ValidatingPolicy twin (SAME name, `validationActions: [Audit]`) dual-running against the Enforce CP — PolicyReports carry both engines (`source: kyverno` vs `KyvernoValidatingPolicy`), parity compared by `docs/scripts/kyverno-vp-parity.sh` (3 jq classes). **Soak: 2026-07-04 → ≥07-11** (covers weekly CronJobs), then Phase 3 Deny-flip/CP-delete (2 commits, gated).

Design (source-verified against kyverno 1.18.1 `pkg/cel/autogen`): bare-pods `matchConstraints` ONLY (anything more silently kills autogen — CanAutoGen gate); all excludes as `matchConditions` CEL (`request.namespace` for ns — never rewritten by autogen; `object.metadata.?labels[...]` for workload excludes — rewritten to template labels in clones, desired); optional-chain defaults reproduce hard-anchor semantics (`orValue(<fail-value>)`); container-set parity per-CP (ephemeralContainers only where the CP had it; resource-limits: no ephemeral — API-impossible). `require-networkpolicy`: autogen explicitly off, `resource.List` for NP count, both 2026-07-03 teardown-wedge fixes carried. `vp-canary`: Deny from day one, matches only `vp-canary-test=fail` pods — Phase-3 Gate A proof that the VP Deny path is live with no CP masking.

Offline validation (kyverno CLI 1.18.1): 12 VPs × 10-resource corpus → error=0, every targeted assertion exact (autogen fires on controllers, ns/label excludes honored, non-root anyPattern branch non-mixing preserved, canary isolates); `require-networkpolicy` VP against live cluster read-only: pass=85 fail=0 error=0. **Engine finding**: VP emits ONE result per (policy, resource) — multi-validation short-circuit — so `require-resource-limits` reports cp=2/vp=1 structurally; parity script Class 3 carries that exact exception (verify-early-in-soak note inside) and Class 1 compares worst-of-source. Review-invariants: new CEL section (CanAutoGen silent-kill, request.namespace-vs-object rewrite, orValue soft-anchor rebirth, per-CP container sets, 3-class parity).

### 2026-07-04 — Loki chart moved to the grafana-community fork, 18.4.0

The loki chart at `grafana.github.io` now serves only GEL (Grafana Enterprise Logs). For open-source
(OSS) Loki it stopped at 7.0.0, so Renovate could not see OSS Loki updates. The HelmRelease (the
Flux resource that installs a Helm chart) now points at the community fork (`grafana-community/helm-charts`), which continues from 6.55.0 with strict
semantic versioning. Commit on main: `8f2e54ea`.

| Change | Detail |
|---|---|
| Chart 7.0.0 → 18.4.0 (app 3.6.7 → 3.7.3) | A new `grafana-community` HelmRepository sits beside `grafana`. The old repository stays because alloy still uses it, and the fork has no alloy chart. The StatefulSet replaced its pod in place: before the merge, the fields that Kubernetes does not allow to change were checked and matched the live object. The PVC (persistent volume claim, the pod's request for lasting storage) `storage-loki-0` was reused, and the Helm release history carried on (`loki.v30`) |
| `deploymentMode: SingleBinary` renamed `Monolithic` | 18.x renamed the mode. The simple-scalable (SSD) blocks `backend/read/write: replicas: 0` stay, because the chart's validate.yaml requires them set to zero |
| postRenderers block deleted | priorityClassName now comes from values: `global.priorityClassName`, plus a separate `lokiCanary.priorityClassName`, because the global value does not reach the canary (the test component that writes log lines and reads them back). The chart itself now sets seccompProfile RuntimeDefault on all 3 workloads. The rendered output was checked before the merge |
| `gateway.image.tag: 1.31.2-alpine` pin | The chart default, `1.31-alpine`, is a floating tag: a tag that can point at a newer image later. The live gateway used the floating tag `1.29-alpine`, which already broke the image-pin rule. This migration fixes that |
| `gateway.metrics.enabled: false` | 18.x turns on an nginx exporter sidecar by default. It renders with empty resources, which the Kyverno enforce-limits policy would block, and its port 4040 is missing from the NetworkPolicy. Turning it on later needs a deliberate change that adds resources and the NetworkPolicy port |

| Live check | Result |
|---|---|
| LokiDown alert | not firing |
| alloy dropped-entries rate | 0 |
| canary | writing, 0 missing |
| gateway | 1 container |

Codex reviewed the migration plan in 2 rounds before implementation. Its review of the
implementation diff passed with zero findings. The final render was byte-identical to the render
validated earlier, except for the intended image pin.

**Incident, about 20 minutes after deploy (fixed the same day, `d1b586ca`).** loki-0 went into
CrashLoopBackOff, restarting over and over. Chart 18.x newly turns on a health server (healthz) and
probes for the `loki-sc-rules` sidecar; 7.0.0 had neither. The k8s-sidecar health server binds
dual-stack (to both IP versions at once). On a kernel with IPv4 only, its thread dies with
"Unsupported address family". This is upstream issue **kiwigrid/k8s-sidecar#531**, still open. It reproduces on
the old 2.5.0 image too, so the probes are the trigger. The liveness probe (a health check that
restarts the container when it fails) then got connection refused, and Kubernetes killed the container about every 2.5 min. Ingest never stopped: the
distributor took about 39 lines/s, alloy dropped 0, and the canary had 0 missing.

The fix sets two chart flags, `sidecar.readinessProbe.enabled=false` and
`livenessProbe.enabled=false`. They restore the exact 7.0.0 setup. The rules watcher runs in a
separate thread, and it worked for months while the same health thread was dead. Both flags are
needed: if only the liveness probe is disabled, the failing readiness probe keeps the pod NotReady
for ever. Turn the probes back on when #531 ships HEALTH_HOST.

### 2026-07-04 — Codex CLI added to the claude-telegram bot

The Codex review gate now works from the Telegram bot. Before this change, the bot pod had no
`codex` binary, so the pre-commit review gate in CLAUDE.md worked only on the Mac.

| Area | Detail |
|---|---|
| Image | Image `1.27.7` (fork commit `ad29203`) runs `npm install -g @openai/codex@0.142.5` at build time. The Linux platform dependency is Codex's static musl binary, which runs on Alpine. It installs to `/usr/bin`, outside the paths that the PVC (the pod's persistent storage) mount hides. The build runs `codex --version` as a quick check |
| Config | The init container (a container that runs before the app starts) writes `~/.codex/config.toml` on every start, so the file returns to these settings at each restart. The settings match the Mac: model gpt-5.5, reasoning xhigh, `sandbox_mode = "danger-full-access"`, and the homelab directory trusted |
| Sandbox | That sandbox mode is required. The pod's RuntimeDefault seccomp profile blocks unprivileged user namespaces, so Codex's bwrap sandbox cannot start (checked inside the pod). The pod's own limits act as the sandbox: it runs as non-root, with a read-only root filesystem, capabilities dropped (Linux privileges removed) and restricted egress (outgoing network traffic limited) |
| Login | Codex logs in with **ChatGPT-plan tokens** (the £20 subscription), in the same way Claude uses its OAuth token. The user chose this after a try with an API key failed: the account had zero credit, so it hit its quota. `auth.json` was copied from the Mac into the SOPS secret `claude-telegram-codex`. The init container copies it to the PVC only if no copy exists there. Codex refreshes its tokens in place, so copying the old snapshot again would overwrite them |
| If the login stops working | Copy the Mac's auth.json into the secret again, delete the copy on the PVC, and restart |
| API key | The API-key path is gone. Codex 0.142.x ignores a bare `OPENAI_API_KEY` environment variable anyway (checked). A `--with-api-key` login worked but was never used |
| Restart message | The Telegram message sent on restart now shows the Codex version |
| NetworkPolicy | No change. Its egress rule for port 443 to addresses outside the RFC1918 private ranges already covers OpenAI |

The Codex static review (the gate) found 1 MEDIUM issue. `| tail -1` after `codex login` hid a
failed login under `set -e`, because pipefail was not set. The fix writes the output to a file and
prints its last line only on failure.

### 2026-07-03 — Deferred-item cleanup (post-ultrareview) + Kyverno namespace-teardown deadlock fix

This change shipped 4 items that the 2026-07-03 ultrareview had deferred. Each went out as its own
merge and Flux reconcile, one after another, so that cluster operations did not overlap. Main moved
from `df521682` to `d771464d`.

| Change | Detail |
|---|---|
| Percona `crVersion` 1.0.0 → 1.2.0 | The custom resource (CR) now matches the ps-operator chart, which Renovate had already moved to 1.2.0 (#874). The CR and its comments had fallen behind. SmartUpdate restarted the replicas first and the primary last, and the cluster reached Ready. The database stayed available through a PodDisruptionBudget (`minAvailable:1`) and HAProxy. A brief `get cluster primary: empty response` during the primary switchover is expected |
| ClusterIssuer `letsencrypt-staging` renamed `letsencrypt-prod` | The "staging" issuer had always pointed at the production ACME server. Only the name was wrong. The rename covered the issuer, its `privateKeySecretRef` and the `issuerRef` of all 16 Certificates. cert-manager re-issued all 16 from the production server. The old TLS secrets kept serving meanwhile, so nothing went down, and 16 is under the Let's Encrypt limit of 50 a week. The old `letsencrypt-staging` account-key Secret now has no owner, which does no harm |
| csp-reporter removed | It did nothing. The apps' middleware already left out `report-uri`. The monitoring middleware sent reports to a cluster-internal HTTP endpoint that browsers cannot reach, so it collected nothing. Removed: the Deployment, namespace, NetworkPolicy, Service and ServiceAccount, its resource-governance entry and the stale report-uri. To check CSP, read the browser console |
| Redis-HA and CouchDB instance CRs moved to the configs layer | Operators now sit in the controllers layer and instances in the configs layer, as for postgres and mysql. The move from controllers to configs left no gap. It used `kustomize.toolkit.fluxcd.io/prune: disabled` in 2 stages: first annotate the live objects, then move them and remove the annotation. The stages matter because `infrastructure-configs dependsOn infrastructure-controllers`, so controllers reconciles and prunes first. A merge of the whole branch with a single `fr` (Flux reconcile) would prune the objects before configs adopted them, which means a Redis and CouchDB outage of about 1-2 minutes. CouchDB did not restart. Redis restarted once: the opstree operator copies CR labels onto the StatefulSet, so the change of the Flux ownership label recreated a pod. Redis Sentinel, which moves the master role to a healthy pod, kept Redis available through that restart |

**Incident, found and fixed during the rollout.** The Kyverno policy `require-networkpolicy`, in
Enforce mode, blocked the deletion of the csp-reporter namespace. The shared
`validate.kyverno.svc-fail` webhook also runs on DELETE. Once Flux pruned the namespace's
NetworkPolicy (netpolcount fell to 0), the policy denied the DELETE of the Deployment, ReplicaSet
and Pod. The namespace stayed in `Terminating` indefinitely. Nobody can create a NetworkPolicy in a
Terminating namespace, so this was a deadlock. The fix limits the rule to
`operations: [CREATE, UPDATE]` and adds a precondition that skips objects carrying a
`deletionTimestamp`. The fault had existed unnoticed since require-networkpolicy moved to Enforce
(2026-05-25). It affects **every** namespace deletion, not only this one. A new class of bug went
into the review invariants.

### 2026-07-03 — Deprecation audit of Helm chart values, repo YAML, and Flux and CRD APIs

The audit ran in parallel over the values of all 12 HelmReleases against their pinned upstream charts,
every apiVersion and field in the repo, the Flux APIs, and the live
`apiserver_requested_deprecated_apis` metric. A before-and-after `helm template` diff proved that
every fix renders the same output, except 2 intended changes. The Codex static peer review caught 1
MEDIUM issue: the obsidian init script re-applied legacy CouchDB keys.

**Fixed in this commit:**

| Component | Change |
|---|---|
| immich | Deleted the unused `serviceAccount:{create,name}` values block. It had the shape of bjw-s common ≤3.x, and the postRenderer attaches the ServiceAccount anyway. The block stopped any upgrade to chart 0.13+, because `values.schema.json` rejects it. In the render diff, the chart now emits its 2 default ServiceAccounts. That is harmless and matches the state after 0.13. Also deleted two unused environment variables: `IMMICH_METRICS`, removed in server 1.119.0 (the chart injects telemetry through `immich.metrics.enabled`), and `IMMICH_MEDIA_FFMPEG_ACCEL`, never an upstream variable (VAAPI is set in the admin UI) |
| immich | The HelmRepository now points at `oci://ghcr.io/immich-app/immich-charts`. Upstream stopped updating the HTTP repository, and 0.13+ ships only as OCI, so Renovate could not see upgrades |
| flux | Alert `spec.summary` became `spec.eventMetadata.summary`. The old field is deprecated. It goes away when Alert v1 becomes generally available (GA), in Flux 2.10, around Q4 2026 |
| kube-prometheus-stack | Deleted `grafana.rbac.extraPermissions`, a key that never existed in the grafana chart. The chart generates the sidecar's RBAC (its access permissions) itself |
| kyverno | Deleted 3 values keys that the chart does not have: `features.backgroundScan.interval` (the real key is `backgroundScanInterval`), `config.webhookMatchConditions` (the real key is `matchConditions`) and a top-level `metricsService` (a chart-v2 shape). None of them did anything, and the defaults match the intent |
| redis-operator | Deleted `serviceMonitor.enabled` and the whole `serviceAccount` block. No version of the chart has these keys. The chart creates the ServiceAccount based on `rbac.enabled`, and the `automountServiceAccountToken` value equals the chart default |
| couchdb | Deleted 5 ini keys that had no effect, listed in the rows below. The obsidian init script's 3 matching legacy config-API writes were deleted too (the Codex catch). The CouchDB pods restart once, because the config checksum changes (checksum/config) |
| couchdb `[compactions]._default` | A setting for the CouchDB 2.x compaction daemon, which smoosh replaced in 3.0. **The intended 70%/60% fragmentation thresholds were never in effect** |
| couchdb `chttpd.max_http_request_rate` | A Cloudant setting, not a CouchDB option. **The rate limiting it was believed to give never existed** |
| couchdb `couchdb.delayed_commits` | The option was removed in 3.0, and the behaviour is now fixed |
| couchdb `chttpd_auth.require_valid_user` and `httpd:{enable_cors,WWW-Authenticate}` | 3.2 moved these to `[chttpd]`, where identical working copies stay |
| loki | Deleted the deprecated `monitoring.selfMonitoring` block (false is the default). The proof step disproved one planned cut: the SSD blocks `backend/read/write: replicas: 0` are needed, because the chart's validate.yaml fails a SingleBinary render without them. They stay, with a corrected comment |
| percona | `spec.enableVolumeExpansion` became `spec.storageScaling.enableVolumeScaling`. Operator 1.2.0 deprecates the old field, and 1.5.0 removes it. The crVersion upgrade to 1.2.0 (`3769dc87`) made the change possible, and the field was checked against the live CRD (the custom resource definition in the running cluster). The setting changes only the spec, not the pod template, so no pod restart was expected |

**Tracked, not fixed here:**

| Item | Status |
|---|---|
| Migration from Kyverno ClusterPolicy to CEL ValidatingPolicy | due around Oct 2026. The kind is deprecated since 1.17, and its removal is planned for 1.20 |
| Moving the Loki chart to grafana-community | needed because 7.x serves only GEL |
| immich 0.13.1 through Renovate | now unblocked |

**Checked and clean:**

| Component | Result |
|---|---|
| traefik 41.0.1 | a render with strict schema checks proves it. `traefik.io/v1alpha1` is the only CRD version, and upstream has no v1 |
| cert-manager 1.20.3 | already uses `crds.*` |
| cnpg 0.29.0 | no barmanObjectStore in use, so its removal in 1.31 has no impact |
| alloy 1.10.0 | clean |
| vm-operator 0.65.1 | `v1beta1` is current for all VM* kinds, and no promotion is announced |
| kube-prometheus-stack 87.6.0 | the Alertmanager config already uses modern matchers |
| ps-operator 1.2.0 values | clean |
| couchdb chart keys | clean |
| all Flux v1/v2 APIs | clean |
| notification v1beta3 | current through 2.9, deprecated in 2.10, removed at least 2 minor versions later |
| core k8s APIs | all GA |
| kustomize v5 fields | absent |
| live API server deprecated-API metric | about zero: one `Endpoints` read, with no removal planned |

### 2026-07-03 — Ultrareview on 6 axes: architecture, approaches, solution, quality, docs, security

6 reviewers each covered one axis. An adversarial check tried to disprove each finding, and 52
findings survived. The review also used probes against the live cluster and a Codex static review.
The fixes were made in a git worktree. The cluster has a single environment, which is production.

| Severity | Finding | Fix |
|---|---|---|
| HIGH | The pg_dump, mysqldump and PVC backups (copies of the apps' persistent volume claims, their stored data) reported success on partial dumps. Causes: `set -e` without pipefail; `pg_dump\|tee` hid the exit code; a missing PVC only raised a warning; mysqldump wrote its stderr into the `.sql` file | `set -eo pipefail`. If any database backup fails, the job records the failure and runs `exit 1` before packaging. mysql gets `MYSQL_PWD`, stderr goes to a separate `.err` file, and `--set-gtid-purged=OFF` is set. A missing critical PVC now fails the job |
| HIGH | `NoRecentBackups` could never fire: its threshold was 48h, but Jobs are deleted after 24h (their TTL). A `max()` per namespace also hid a sibling CronJob that had stopped | The alert now reads `kube_cronjob_status_last_successful_time` per CronJob, a value that the TTL does not delete. It is split into daily (>48h) and the weekly immich backup (>9d). Checked live |
| HIGH | Backup replication validated the backup after rsync. So a corrupt backup overwrote the last good copy on the second worker, W2 (`--delete`), and wiped the source on the first worker, W1 | New order: validate first, and if that fails, stop before the sync. The source stays, and W2 and the NAS stay untouched |
| HIGH | Grafana's egress NetworkPolicy (the rules for its outgoing traffic) did not allow port 8429 to VMSingle. It still had an unused rule for `prometheus:9090`. No metric dashboard could reach its data, and nothing reported the fault | Allowed 8429 to vmsingle, and removed the unused prometheus rule |
| HIGH | CI used GitHub Actions by tags that can move, in a pipeline with packages:write and pull-request write permission | Pinned every third-party action, and `actions/checkout` in the 2 workflows with write permission, to a commit SHA, with a `# vX.Y.Z` comment for Renovate |
| MED | CNPG had `enableSuperuserAccess: true` because of a false belief that the pooler (the connection pooler in front of PostgreSQL, which lets apps reuse database connections) needs it. That left a live `postgres` superuser secret that nothing tracked | Set to `false`. The pooler uses certificate auth, and nothing reads the secret |
| MED | vmsingle's `namespaceSelector:{}` on 8429 let any namespace in the cluster write metrics to it, or flood it (denial of service) | Removed. The 4 named clients (vmagent, vmalert, grafana, uptime-kuma) keep their access |
| MED | Traefik rate limits counted per **second**, because no `period` was set. That is 60 times looser than the "/min" in their comments | Added `period: 1m`, and reset the limits from the measured 7-day peaks: standard 300, high-frequency 600 |
| MED/LOW | The bare 443/80 egress rules of Home Assistant and claude-telegram reached cluster and LAN address ranges. The DNS component allowed UDP only, with no TCP fallback. uptime-kuma had an unused ICMP rule for all ports on a /24, and it has zero ping monitors | An RFC1918 `except` on 443/80, which blocks the private ranges. Added TCP/53 for DNS. The ICMP rule became a rule scoped to the NAS, `.136/32:50555` |
| LOW | CI's kubeconform schema was pinned to 1.31 while the cluster ran 1.36. dependabot.yml did nothing (0 PRs; Renovate handles actions). Apps automerged with no waiting period | Schema moved to 1.36.1. Deleted dependabot. Added `minimumReleaseAge: 3 days` to the apps automerge |
| docs | The disaster recovery (DR) runbook had the wrong NAS rsync module (`akhozya` instead of `akhozya-pool1`). It had a bare `curl\|sh` k3s install, which pins no version and clashes with the traefik and coredns that Flux installs. It contradicted the no-WAL decision (the decision not to archive PostgreSQL's write-ahead log, the record of every change that point-in-time recovery replays), and it described a serial topology, where each copy feeds the next, but the real one is fan-out, where one source feeds every copy. It understated what losing W1 or W2 does, had outdated counts, and had a firewall block that resets ufw | Rewrote the DR steps with a pinned k3s and the Ansible config. Described the fan-out topology. Added an honest failure table and the limits of having no offsite backup and monitoring that cannot see its own failure. Refreshed the counts |
| MED | No external dead-man switch. If W2 goes down, VMSingle and VMAlert go with it, so every in-cluster alert, NodeDown included, stops, and nothing outside the cluster notices | A Watchdog VMRule (`vector(1)`, needed because `defaultRules.create:false` removed the built-in one) feeds the Alertmanager `deadman` webhook receiver (`url_file` from a SOPS secret), which pings healthchecks.io every 10m. The owner chose healthchecks.io. Checked live from end to end. **Owner action: set the check to Period 15m and Grace 15m** |
| LOW | `CronJobNotScheduled` and `BackupCronJobMissedSchedule` fired falsely on immich-backup. The weekly schedule and runs outside the usual slot leave `.status.lastScheduleTime` out of date, so the kube-state-metrics value `kube_cronjob_next_schedule_time` stays in the past | Excluded `immich-backup` from both rules, which are tuned for daily jobs. `NoRecentImmichBackup` (9d) catches a stale immich backup. Checked live and healthy: the last success was 5d old, delta +5.7d |
| MED | require-labels, require-non-root and require-seccomp were still in Audit mode, which only flags violators and does not block them. `validationFailureAction` is deprecated since Kyverno 1.13 (the cluster ran 1.18.1), so a future chart upgrade could change the policy mode with no warning | Brought forward the item deferred to 07-04. Moved all 3 from Audit to Enforce, after a live check again found them clean: 199/113/199 pass, 0 fail, 0 live seccomp violators, and every CronJob and Job template compliant or excluded. Moved all 12 policies to the per-rule `validate.failureAction`, and updated `check-policy-action.sh`/`prepare-enforce.sh`. Proved live: `--dry-run=server` accepts all 12, and an admission test denied a violator that broke only the labels rule |

**Deferred, each to its own change or to an owner decision:**

| Item | Detail |
|---|---|
| Percona `crVersion` 1.0.0 → 1.1.0 | needs a window for a rolling restart |
| Renaming ClusterIssuer `letsencrypt-staging` to `-prod` | re-issues 16 certificates |
| The Redis and CouchDB instance CRs | they live in the controllers layer, not configs. Moving them is a move between Kustomizations |
| A fork of the Traefik middleware for the monitoring namespace | no further detail |
| csp-reporter | fork it or remove it |
| Offsite backup | waiting on the owner's decision. The external dead-man switch has now shipped; see the findings table above |

### 2026-07-02 — Secret rotation: the 90-day High tier retired for a single 180-day cadence

All scheduled secret rotations now follow one 180-day cadence. The user decided this, and the
2026-07-01 High batch was replaced rather than carried out. The former High secrets joined the
existing Medium batch:

| Secrets | Next rotation |
|---|---|
| PostgreSQL authentik, immich and n8n; MySQL home-assistant; Redis immich | 2026-10-01 |
| Redis admin-password | 2026-10-26 |

The priority column in SECRETS_ROTATION.md now ranks only by blast radius (how much a leak of the
secret would expose). The yearly infrastructure keys (SSH, deploy key, Cloudflare management token)
and the classes that are never rotated did not change.

### 2026-06-29 — Automatic repair of stuck ClusterIP routing on the control plane, and a Codex pre-commit review loop

A maintenance reboot caught up after the heat shutdown. It ran phase1 then phase2 and updated all
3 nodes. It booted the control plane, the first worker (W1) and the second worker (W2) in that order, about 6min apart, without problems.
The reboot exposed a gap. After a reboot, kube-proxy's DNAT rules (address-rewriting rules) for ClusterIP (the cluster's
internal service addresses) can get stuck, and this hits the **control plane** too. But
`clusterip_heal` covered only the workers. It left the control plane out for two reasons: a probe
from the host network namespace gives false readings there, and a caveat said
"restart-k3s-on-CP hangs".

The symptom: **uptime-kuma**, pinned to the control plane on purpose with a `nodeSelector`,
crashed and restarted repeatedly with `EAI_AGAIN` on MySQL. From pods on the control plane, every ClusterIP (DNS
10.43.0.10, API 10.43.0.1) failed, while the host and the workers were fine. A manual
`systemctl restart k3s` on the control plane cleared it. The restart reprogrammed the DNAT and
returned cleanly in about 30-60s, which **disproved** the belief that a control-plane restart hangs.

**Fix (`c175ab7b`).** A new Ansible role, `clusterip_heal_cp`, is the control-plane version of
`clusterip_heal`. It probes from inside a pod's network namespace: it uses nsenter to enter the
coredns-ha pod and requests 10.43.0.1:443/healthz with curl, because a probe from the host namespace gives false
readings on the control plane. The probe returns one of 3 states:

| State | Meaning |
|---|---|
| 0 | healthy |
| 1 | stuck, but **only if every sample is a confirmed connection failure** |
| 2 | unknown: do nothing, and keep the metrics as they are |

The rules are cautious because the repair restarts the whole Kubernetes service on the control
plane, which is heavier than the repair on a worker. The repair is **`timeout 120 systemctl restart k3s`**. If the restart hangs, the role gives up and raises an
alert, so the control plane never stays stuck indefinitely. The safeguards copy the worker role: a
300s cooldown, at most 3 repairs per 30min, and `node_clusterip_heal_giveup`, which feeds the
existing alert. A systemd timer runs the role 2min after boot and then every 3min. The role deploys
on the next node-maintenance sync. It gets its first live test at the next control-plane reboot.

**Review loop adopted (CLAUDE.md).** This was the first homelab change to go through the new
pre-commit loop: a Codex static review (`xhigh` reasoning), then `receiving-code-review`, a fix,
and a re-review of only the changed part, for at most 3 rounds. Codex found 2 real risks of a
needless restart: any bad sample counted as stuck, and a probe that could not run exited 0, which
cleared the give-up metric. Both were fixed, and round 2 approved the change. The cavecrew pre-push
gate was retired. No Gemini review, and no watching of pull requests after the push.

### 2026-06-28 — backup-replication: rsync `-z` dropped, because it wasted CPU on the LAN

Step 1 (to worker-node-2 over SSH) and Step 2 (to the rsync daemon on the NAS) used `rsync -avz`.
The backups are `.tar.gz` files, already compressed, and both hops stay on the LAN. So `-z`
compressed data that cannot shrink further, spending CPU on both ends for a size gain of about 0.
Both steps now use `-av`. File: `infrastructure/configs/backup-replication/cronjob.yaml`.

### 2026-06-28 — Backup CronJobs: startingDeadlineSeconds raised from 600 to 3600, so a backup delayed by a reboot overrun can still start

6 backup CronJobs (postgres, couchdb, mysql, pvc, immich, backup-replication) start at 03:00–03:30.
They had `startingDeadlineSeconds: 600`. If recovery from a reboot ran more than 10 min past that
window, the CronJob skipped that day's backup, and no error showed it. With a deadline set, the
controller does not catch up a missed run later.

This showed up on the day of this entry, after a **planned heat shutdown of 5–6 days** (the cluster
was off from about 06-23 to 06-28). 6 critical `BackupCronJobMissedSchedule` alerts and 6
`CronJobNotScheduled` alerts fired. The gap itself was **expected**: the cluster was powered off,
and the controller was healthy, since the Sunday 06:00 popeye and pg-extension jobs ran that day.
The `*-postreboot` startup jobs filled in the missed backups. The alerts clear by themselves after
the next on-time 03:00 run.

The deadline is now **3600** seconds, which allows a late start until about 04:00–04:30. So a
normal maintenance reboot that runs long still runs that day's backup. `concurrencyPolicy: Forbid`
prevents two runs from overlapping. The `*-postreboot` startup jobs, not the deadline, still cover
shutdowns of several days.

### 2026-06-28 — immich Redis survives reboots: pointed at the Service that follows the master, Sentinel client dropped

**Problem.** After a node reboot, Sentinel promotes a new Redis master. immich's ioredis Sentinel
client kept its connection to the old master and never recovered, so it needed a manual
`kubectl rollout restart deploy/immich-server`. This kept happening, and it happened again on the
day of this entry (obs 6978).

**Root cause.** ioredis in Sentinel mode detects a failover passively: it asks the sentinels again
only when the master connection *closes*. If a node reboots, the TCP connection to the dead
master is left **half-open and hangs**, with no FIN or RST (the signals that close or reset a TCP
connection). So ioredis never notices and never
looks up the master again ([ioredis#1314](https://github.com/redis/ioredis/issues/1314)).

**Rejected: `failoverDetector:true`** (`f992bbda`, later replaced). Active detection through the
sentinels' `+switch-master` pub/sub messages (published event messages) does recover. But it triggers a **known ioredis
connection leak**. A sentinel failover test left 301 orphaned subscribe connections that never
closed, and immich-server running at about 1.3 CPU. That swaps a manual restart for a leak that
also needs a restart in the end.

**Fix (`cc5c02a1`).** immich now connects as a **plain** ioredis client to
**`redis-replication-master`**, a Service of the OT (opstree) operator that follows the master
(selector `redis-role=master`). Failover now happens in the **infrastructure layer**. If a
replica is promoted, the operator points that Service at the new master, so ioredis reconnects to
the same ClusterIP. The client no longer relies on unreliable Sentinel discovery. paperless already
uses the same pattern. The egress NetworkPolicy did not change: `redis-replication:6379` was
already allowed, and the `sentinel:26379` egress is now unused.

**Checked** by deleting the master pod to simulate a reboot. No manual restart was needed:

| Check | Result |
|---|---|
| immich recovery | automatic, in about 18s |
| immich pod RESTARTS | **0** |
| live `ioredis` connections on the master after it was promoted again | 40 |
| sentinel connections | **0** (the leak is gone) |
| CPU | 1344m → 2m |

The change re-encrypted the SOPS secret `immich-redis-url` with the host in place of the sentinels,
and updated the REDIS_URL comment in `apps/immich/release.yaml`. Note: `cc5c02a1` is unsigned,
because the 1Password agent locked during the session.

### 2026-06-28 — Backup prune left empty folders on the NAS; immich machine-learning resources raised

Two small production fixes shipped in this session.

**Empty folders left by the backup prune (`2e65af1f`).** In NAS replication, `prune_nas_dir` ran
rsync from `/tmp/empty/` *into* the dated folder. That clears only the folder's **contents**, so
the empty folder itself stayed and piled up on the NAS. The fix runs rsync on the **parent** folder
and limits `--delete` to the target folder with `--include="/${name}/***" --exclude='*'`, so the
dated folder itself is removed. `--exclude='*'` protects the folders beside it, in the same way as
`prune_nas_file`. This ends the long-running build-up of empty folders noted in the operator's
memory note `reference_nas`. File: `infrastructure/configs/backup-replication/cronjob.yaml`.

**Immich machine-learning resources (`6af4971e`).** The machine-learning container's limits went up:

| Limit | Before | After | Why |
|---|---|---|---|
| CPU | 2000m | 4000m | 2×, for inference throughput |
| RAM | 2Gi | 2355Mi | +15%: the 7-day peak reached about 78% of 2Gi, too little room before an out-of-memory kill |

Requests did not change (200m/512Mi). File: `apps/immich/release.yaml`.

### 2026-06-28 — NAS admin SSH access and a security audit

The workstation now has admin SSH access (remote terminal access) to the NAS that receives the
backups (`zl-nas`, ZettLab's zettOS, based on Debian 12, at `192.168.1.136`). It uses a dedicated
ed25519 key stored as a file (`~/.ssh/zl_nas_ed25519`), on port `56634`. The key is a file on
purpose, not a key held by the 1Password agent. Login with the key needs no password. `sudo` still
asks for one, by design: there is no NOPASSWD rule (a sudo rule that runs admin commands without a
password).

The audit found nothing to act on:

| Subject | Finding | Why |
|---|---|---|
| Host firewall | none is loaded. `ufw`, `nftables` and `firewalld` are all inactive. The nft ruleset holds only the network for libvirt (the software that manages the VMs), with `INPUT policy accept`, and `iptables-legacy` is empty | so the rule "Allow `192.168.1.0/24`" in the ZettLab UI has no effect |
| Access from the internet (WAN) | safe regardless of the NAS rule | the router forwards no inbound port |
| `zettos-postgresql` | the one sensitive service exposed to the LAN (`listen_addresses='*'`), but authentication blocks it | the database's connection rules in `pg_hba.conf` allow only `127.0.0.1`, `::1` and local connections, so the database rejects a LAN connection before any login check. Every real client runs on the NAS itself |
| Configuration files that the appliance manages | left untouched | ZettLab overwrites them on update. Details are in the operator's memory note `reference_nas` |
| The appliance | outside the scope of Ansible, k3s and UFW | so the node-maintenance and node-fix procedures do not apply to it |
