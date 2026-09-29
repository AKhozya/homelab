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

### 2026-09-29 — immich-vm VNC live on loopback; bot node keys have one copy

| Change | Detail |
|---|---|
| VNC on the NAS loopback | The fix in Git (`aba0768e`) does not reach the NAS by itself, because the heal watchdog does not check `<graphics>`. An in-place edit of the NAS definition changes only the two `listen` values, and a cold restart (`shutdown --mode acpi`, shut off in ~10 s) makes it live. Port 5900 no longer answers from the LAN. The node is Ready and the Immich server and ML pods are Running ~7 min after the start. The server fails its startup probe once on the cold VM. How to apply such a change and reach the console: [gpu-node/README.md](../apps/immich/gpu-node/README.md) |
| Bot node host keys | The bot's SOPS `known_hosts` keeps only the `github.com` keys (`3eb0d6a2`). `node-maintenance/lib/known_hosts` (`391fd839`) is the one copy of the node keys; the bot appends it at start. SSH from the bot to all four nodes passes with `StrictHostKeyChecking yes` |

### 2026-09-28 — SP5 whole-repo review: 209 findings, 198 fixed

Nine review agents read 737 of the 803 files at `8f78a8c8`, and seven fix agents fixed the
findings area by area. Method, counts, decisions and open items are in
[the open-source prep plan](plans/2026-09-26-open-source-prep.md), section SP5.

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

The SP4 secret scan read every ref GitHub serves, not only `main`: `gitleaks git
--log-opts=--all` on a mirror clone. `main` held the same 11 findings as the 2026-07-26 audit,
which judged each one rotated or decommissioned. Four more findings are in commits that only
`refs/pull/*` reach, from before the 2026-06-12 history rewrite. Two of those were working
credentials:

| Token | Where | Why it still worked |
|---|---|---|
| Cloudflare API token `dns_and_certs` (Zone.DNS edit on `h0melab.work`) | `.backup/QUICK_REFERENCE.md`, commit `7349f6cc`, 2025-10-07; 18 PR refs | cert-manager's SOPS file had not changed since 2025-10-06, so it held the same value. The rotation table's "2025-10-19" was never a rotation |
| Telegram bot token for @h0melab_alerts_bot | same commit | Alertmanager, Flux notifications and the backup job use it. Its file had not changed since 2025-10-07 |

The repo owner cannot delete PR refs, and plan decision 7 keeps the repo rather than recreating
it, so rotation was the only fix. The operator made new values for both tokens, and for the
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
hooks that rewrite files skip the byte copies. Plan: `docs/plans/2026-09-26-open-source-prep.md`.

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
integrated GPU through ONNX Runtime's OpenVINO execution provider. Commit: `4a5255cf`. Plan:
`docs/plans/2026-09-06-immich-ml-openvino.md` (removed after `aadf03e6`).

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

### 2026-08-01 — A cached download that no upstream fix could replace skipped a whole week of updates

The weekly `node-maintenance.timer` fired at 05:30:58. `node-maintenance-phase1.service` failed at
05:32:52 with `status=2`, on the `yay -Syyu` task (the package upgrade, which also builds packages
from the AUR, the Arch User Repository):

```
flux-bin-2.9.3_linux_amd64.tar.gz ... FAILED
==> ERROR: One or more files did not pass the validity check!
```

phase1 stops at its first error by design. So it never created `phase2-pending`, and its
`ExecStartPost=systemctl reboot` never ran. phase2, which updates the workers and reboots the nodes
one after another, never ran at all. Telegram got the `❌ ... No reboot` notice, and nothing else
reported a problem for six hours.

**Why the checksum could never match.** The AUR package `flux-bin` had a fixed `_srcver=2.8.6` in
its source URL, while `pkgver` moved on to 2.9.3. The local filename comes from `${pkgver}`. So
every weekly "upgrade" since 2.8.7 downloaded the *same v2.8.6 tarball* and saved it under a new
name. `flux-bin-2.9.0/2.9.1/2.9.2/2.9.3_linux_amd64.tar.gz` all had the same checksum, sha
`c53cc990…`: each was upstream's `flux_2.8.6_linux_amd64.tar.gz`. `pacman -Q flux-bin` reported
`2.9.3-1`, while `flux version --client` reported `v2.8.6`.

AUR commit `45c0b65` "Fix versioning" (2026-07-25 11:44 PDT) corrected the URL and set `pkgrel=2`
with the real checksum `eae4e860…`. This cluster's 2026-07-25 run had succeeded about 6h *before*
that. The next run checked the file already on disk against the corrected checksum and stopped.
**makepkg does not download a source again if it already exists**, so no upstream correction could
replace the file.

**What it affected.** The control plane installed its upgrades from the package repositories
(including `linux-lts 6.18.39 → 6.18.41`), then stopped before the reboot. So the running kernel
differed from the installed one. The other three nodes got no changes: still `6.18.39-1`, uptime 7d
6h.

`AlloyLogDeliveryFailing` then fired on 3 alloy pods, as a *secondary* effect. Loki rejects log
entries older than 168h. Idle pods (svclb-\*, node-exporter, kube-state-metrics) had written nothing
since the Jul 25 boot. Alloy, the log collector, reopens those log streams from the same position,
again and again, with no end. The weekly reboot had also been preventing that, and one missed cycle
exposed the problem.

**The second failure.** Deleting the control plane's cached tarball let phase1 succeed, and the full
cycle ran. But phase2's upgrades on the workers failed on the *same* stale file. The workers set
`SRCDEST=/var/lib/node-maintenance/.cache/makepkg/sources`, and the control plane has no such
override. The rescue block of PLAY 1 (the Ansible error handler) caught the error and carried on.
That is correct: if that step failed the run, it would leave `phase2-pending` in place, and that
file stops drift-heal (the automatic repair of node configuration) on every node (see 2026-06-20).
`node_pkg_upgrade_success` was the only thing that saw the failure:

| Node | Metric value |
|---|---|
| control plane | 1 |
| worker-node | 0 |
| worker-node-2 | 0 |

That metric exists because immich-vm went two weeks without updates in July and nobody noticed. Here
it was the only signal.

**Fix** (`db048f3c`). `yay_cmd` gains `--cleanafter`, and the worker `makepkg.conf` template drops
its `SRCDEST` override. The fix needs both. On the workers, `--cleanafter` logged
`Cleaning (1/1): .cache/yay/flux-bin`, but the tarball stayed in `.cache/makepkg/sources`. The flag
cleans only yay's own folder for each package, so it removes sources *only* while `SRCDEST` is
unset. No node sets `SRCDEST` system-wide in `/etc/makepkg.conf{,.d/}`, and the control plane has
never had a user override. So with the override gone, the workers behave like the control plane,
which is known to work.

**Remaining risk.** `--cleanafter` runs only after a *successful* install. So a failed build still
leaves a source file that later runs reuse instead of downloading a fixed one. This is accepted,
because `NodePackageUpgradeFailed` now makes the failure visible.

### 2026-07-31 — A chart upgrade stopped the VictoriaMetrics operator from acting on changes for two hours while its pod looked healthy

Renovate merged `b1116022`, which moved the victoria-metrics-operator chart from 0.66.3 to 0.67.0
and the operator from v0.73.1 to v0.74.0. Flux applied it at 10:30 UTC. From 10:31:35 the operator
logged only this message:

```
Failed to watch  type=*v1.NetworkPolicy
error=... networkpolicies.networking.k8s.io is forbidden: User
"system:serviceaccount:monitoring:victoria-metrics-operator" cannot list resource
"networkpolicies" ... at the cluster scope
```

The operator logged that message 393 times. `controller_runtime_reconcile_total` stayed at 3 until
12:35. For those 124 minutes, the operator ignored every change to a VictoriaMetrics custom
resource (CR).

**Why nothing else caught it.** All 25 controllers logged `Starting workers` as usual, then waited
and did nothing. The whole time, the pod held `Ready 1/1`, `up=1` and `restartCount 0`, its `:8081`
probes passed, and it kept renewing its leader lease. `controller_runtime_reconcile_errors_total`
stayed at **0**. A reconcile is one pass in which the operator makes the cluster match a resource.
The reconciles never failed; they never returned at all. `VMOperatorReconcileStalled`
(`sum(rate(controller_runtime_reconcile_total[15m])) == 0`) was the only signal, and it fired. This
failure is the opposite of the metrics fault of 2026-06-15, where `up=0` and no scrape happened at
all. An alert written for that fault caught this one.

**Root cause: the chart's permissions fell behind the operator's.** Operator v0.74.0 added
`.spec.networkPolicy` to every VictoriaMetrics CRD (the definition of a custom resource type)
([helm-charts#2977](https://github.com/VictoriaMetrics/helm-charts/issues/2977)). In its own
`config/rbac/role.yaml` it grants itself `networkpolicies`, and the v0.74.0 release notes list that
grant as a BUGFIX. The `templates/role.yaml` of chart 0.67.0 still grants only
`ingresses`/`ingresses/finalizers`, and so does the chart on `master`. The operator reads
NetworkPolicies even when the feature is not in use. Nine object factories in the operator always
take the branch
`if cr.Spec.NetworkPolicy == nil { objsToRemove = append(…) }`, and
`finalize.SafeDeleteWithFinalizer` starts with a cached `Get`. So controller-runtime starts a
NetworkPolicy informer (a cached watch on that resource type) that can never sync, and every
reconcile waits on it.

**Fix** (`63c456a2`): an extra ClusterRole and ClusterRoleBinding in
`monitoring/controllers/victoria-metrics/operator-networkpolicy-rbac.yaml` that grant
`networkpolicies` `get/list/watch`. Read-only access is enough, because nothing in this cluster sets
`.spec.networkPolicy`. So the operator only ever `Get`s, and `SafeDeleteWithFinalizer` returns early
on `NotFound`. The operator picked up the new permissions without a pod restart. Within six minutes
the counter rose from 3 to 72, the rate returned to its usual 0.05/s, and the alert cleared.

**Removing the workaround takes two commits, not one.** kustomize-controller deletes the extra role
as soon as it applies a commit without the file. The chart's own grant arrives only when
helm-controller finishes the upgrade. So bump the chart first. Then confirm that
`kubectl get clusterrole victoria-metrics-operator` lists `networkpolicies`. Only then delete the
file.

**Follow-on fix** (`35dfcf57`). The same operator upgrade added a second endpoint
(`targetPort: 8435`) to the VMServiceScrape that it generates for VMAlert. The new endpoint points
at the `config-reloader` sidecar (a helper container in the same pod). `vmalert-network-policy`
allowed only port 8080, so the new scrape got `connection refused` (a REJECT from kube-router) and
`ScrapeTargetDown` fired. The fix added an ingress rule for 8435, limited to
`podSelector: app.kubernetes.io/name: vmagent`. vmagent is the only scraper of that port. The fix did not
widen the existing 8080 rule, which admits the whole namespace. vmagent's own reloader target stayed
healthy the whole time, because that scrape is traffic inside one pod, and NetworkPolicy never
checks such traffic. So if one of two identical targets is up, that says nothing about the policy.

**Process note.** A Telegram bot session shipped `63c456a2` and skipped the pre-commit review loop.
The Codex review done afterwards returned APPROVE-WITH-LOW. Its one finding was the two-commit order
for removing the workaround, described above. The incident summary written in that session also got
two facts wrong. Both are corrected here against live metrics:

| The summary said | Live metrics showed |
|---|---|
| "no controllers started" | all 25 started |
| "flat at 1 for 105 min" | flat at 3 for 124 minutes |

**Closed the same day.** Upstream issue
[#3129](https://github.com/VictoriaMetrics/helm-charts/issues/3129) and PR
[#3130](https://github.com/VictoriaMetrics/helm-charts/pull/3130) (which adds `- networkpolicies` to
`templates/role.yaml`) were filed at about 13:0x UTC. A maintainer merged the PR at 13:21, and chart
**0.67.1** was published at 13:24. Its appVersion stays at v0.74.0, so the new chart carries the
RBAC fix (the fix to its permissions under Kubernetes role-based access control) and nothing else. A
`dyff` of both rendered charts proved that: only the ClusterRole rule and the `helm.sh/chart` label
differ. `6ef450ac` bumped the chart, and the next commit deleted the workaround.

**The two-commit rule proved its worth the first time it was used.** After the bump merged, the
ClusterRole that the chart owns still did NOT list `networkpolicies`. The HelmRelease was stuck on
`no 'victoria-metrics-operator' chart with version matching '0.67.1' found`, because
source-controller's cached index of the HelmRepository was older than the release. If the same
commit had removed the workaround, Flux would have deleted it during that gap and brought the outage
back. `flux reconcile source
helm victoriametrics -n monitoring` refreshed the index, and the upgrade went through (release v21).
Only then did the check command show `[ingresses, ingresses/finalizers, networkpolicies]`.
**The general rule: a Helm chart version bump is not applied until source-controller has re-read
the repository index. Check `lastAppliedRevision`; never assume the merge applied it.**

This is the same kind of bug as [#3102](https://github.com/VictoriaMetrics/helm-charts/issues/3102),
where the chart's ClusterRole lacked the VPA grant (permission for VerticalPodAutoscaler objects).
Chart 0.66.3 fixed that one ten days earlier.

### 2026-07-27 — Backup replication uploaded 129G to the NAS every night and deleted it minutes later

The problem showed up during a check of the first full backup cycle after the couchbackup
`--parallelism 1` fix. That cycle was clean. But the replication log showed
`sent 138,678,853,989 bytes` with `speedup is 1.00`, and a few lines later
`pruning dir: immich/20260712_030000` and `immich/20260705_030002`. The same job, in the same run,
uploaded 129G and then deleted 129G.

**Two jobs worked against each other.** `immich-backup` runs weekly. It writes to
`/mnt/extra-storage/immich-backup` and copies to the NAS **itself**
(`POOL=…/backups/homelab/immich`), keeping 2 generations locally. `backup-replication` runs nightly.
It copies a *different* folder on the node (a hostPath), `/mnt/k8s-storage/backups/`, to the same
root folder on the NAS. That folder still held 129G of old generations from before immich-backup
moved to extra-storage. Step 4's `rm -rf` covers only postgres/couchdb/mysql/pvc, so nothing ever
cleaned the folder. Each night Step 2 uploaded those generations again, because they really were
missing on the NAS. Then Step 4b's `keep-2` (keep the two newest) deleted them again, because the
two newest are the ones immich-backup copied there directly.

`speedup is 1.00` was the sign. It is **not** an rsync tuning problem, because the files really were
missing at the destination. No flag was missing: each night one step uploaded what a later step
deleted. (This is a different matter from the withdrawn 2026-07-26 claim about `-r` without `-t`,
which was wrong; see `e4c3eed7`.)

**Fix:** `--exclude='/immich/'` on the Step 2 rsync. Replication must not touch a path that another
job owns.

**The leading slash is deliberate.** Without it, `immich/` matches at any depth. If the immich
namespace ever gains a critical PVC (a request for persistent storage), the pattern without the
slash would skip a future `pvc/<ts>/immich/…` without any warning. The
namespace has none today, which is why nobody would notice the mistake. Codex caught this. A local
rsync test with sample files proved both behaviours before the change shipped.

What gets backed up is unchanged. `postgres-backup` dumps the immich **database** nightly into
`/source-backups/postgres/` (checked in the same run). The immich **library** reaches the NAS weekly
through immich-backup's own copy. Step 1 checks only postgres/couchdb/mysql/pvc, the "4 validated
artifact(s)". So the exclude cannot affect that check or the Step 3 check on the NAS.

**Verified 2026-07-28** on the first run after the fix that ran without anyone operating it
(`backup-replication-29753490`): `sent 126,326,404 bytes`. That is 120 MiB against the previous 129
GiB, about 1,100 times less. Step 4b deleted only `pvc/20260628_135136`, under the usual 30-day
retention. It deleted no `immich/` folder, which directly shows that the upload-then-delete cycle is
gone. Step 3 still reported all 4 validated artifacts on the NAS, and Step 4 still cleaned the
source. The NAS immich storage pool holds exactly `20260719_030004` and `20260726_030007`, so keep-2
still holds. The 07-26 generation came from immich-backup's own copy, so leaving it out of
replication loses nothing.

A manual cleanup the same day deleted the 129G of old folders on worker-node. The replication log
now shows `/source-backups/immich/` at 4.0K. Nothing further is open here.

### 2026-07-26 — cert-manager PDBs turned on, and a same-day correction to the B6-2 claim about autogen

**The correction comes first, because it overturns something written earlier the same day.** The
B6-2 entry below claimed that Kyverno autogen copies `matchConditions` **word for word** into the
rules it generates for controllers. (Autogen turns a rule written for pods into matching rules for
the controllers that create pods, such as Deployments and CronJobs.) That claim is **wrong**.
Autogen rewrites `object.metadata` to the path of the pod template, in matchConditions as well as in
validations:

| Kind | Rewritten path |
|---|---|
| controllers | `object.spec.template.metadata.labels` |
| CronJobs | `object.spec.jobTemplate.spec.template.metadata.labels` |

Autogen leaves only `request.namespace` unchanged, which is why namespace tests are safe there.
`.claude/review-invariants.md` already recorded this correctly. The claim contradicted that file,
and review should have caught it before it went in.

Why the error happened: the claim came from reading the *old* policy, whose matchConditions held
only `request.namespace`, a value autogen never rewrites. The claim then generalised from that one
case. The offline autogen tests rebuilt the generated rules by hand with `yq`, and rewrote only
`validations`. That produced a policy shape that Kyverno never creates, so the tests confirmed the
wrong model instead of catching it.

The consequences are all cosmetic. **The shipped policy is correct and unchanged**:

- The `app` labels on `metadata` and `spec.jobTemplate.metadata` of the five backup CronJobs were
  not needed, because their pod templates already carried `app`. They are removed, together with
  the comments that stated the false rule.
- The B6-2 plan now marks its assumptions C2/C3 REFUTED, and its offline autogen test rows unsound.

The **live** checks after deploy are what prove the change, and they still hold:

| Check | Result |
|---|---|
| five CronJobs | produced Jobs that admission accepted |
| three controllers that use hostPath | still accepted |
| a pod using hostPath, in each of the five namespaces | denied |

The lesson, now in the invariants file: **read the autogen output, never rebuild it by hand**. Use
`kubectl get vpol <name> -o json | jq .status.autogen`. A hand-built model of a generator tests the
model, not the generator.

**cert-manager PDBs turned on.** A PodDisruptionBudget (PDB) limits how many of an app's pods a
drain (removing application pods from a node before maintenance) may stop at once. The change sets
`podDisruptionBudget.enabled: true` and `minAvailable: 1` on the controller, the webhook and
cainjector. The chart's own values recommend a PDB whenever `replicaCount > 1`, and this repo runs
2. It is safe at 2 replicas: `disruptionsAllowed` comes out at 1, so drains still proceed. That
differs from `main-postgres-primary`, which stays at 0 by design. Required anti-affinity (a rule
that keeps the replicas on different nodes) and node maintenance with `serial: 1` already kept one
replica up. The PDB now enforces that, rather than leaving it to how other settings happen to
combine. Rendering the chart confirmed the change: all three PDBs appear, and each selector (the
labels a PDB uses to choose its pods) matches 2 live pods.

**cnpg-operator stays without a PDB on purpose.** Chart `cloudnative-pg` 0.29.0 has no PDB setting:
the full 27KB of values mentions neither `disruption` nor `pdb`. So covering the operator needs a
separate manifest with a selector kept up to date by hand. If a chart release changed the labels,
that selector would stop matching anything, and nothing would report it. The benefit is small, and
the upkeep is real.

### 2026-07-26 — `PodNotReady` checked the pod phase, not readiness: renamed, and a new alert covers the gap

The alert named `PodNotReady` ran `kube_pod_status_phase{phase!~"Running|Succeeded"}`. That query
checks the pod's **phase**, not its readiness. A pod can stay in phase `Running` while its Ready
condition is false. Kubernetes then removes it from the Service endpoints (the pods that receive
traffic), so it serves nothing, and the alert never sees it. n8n was in that state for ~8h on
2026-07-25, returning HTTP 503 because its database connection pool no longer worked. No alert fired.

| Alert | What it does |
|---|---|
| **`PodPhaseNotRunning`** | the old phase alert: same expression, under a name that says what it checks |
| **`PodRunningNotReady`** | new; covers the gap, with `for: 15m` |

The new rule does not reuse the `PodNotReady` name, on purpose. Reusing it would mix two different
meanings in the alert history. It would also match any silence that names the old alert exactly.

The change adds both names to `silence_alertnames` in the node-maintenance Ansible variables. Before,
that list carried only upstream's `KubePodNotReady`. Without the new names, every node drain (removing
eligible pods from a node before maintenance) would trigger an alert.

The expression needs two guards. Review found both of them; the first draft did not have them.

| Guard | Why it is needed |
|---|---|
| `and on(namespace, pod) kube_pod_status_phase{phase="Running"} == 1` | kube-state-metrics also reports `condition="true"` with value 0 for Job pods in phase Succeeded. This guard stops every CronJob from firing the alert |
| `unless on(namespace, pod) kube_pod_deletion_timestamp` | a pod that is shutting down keeps `phase=Running` while its Ready condition turns false. Without this guard, one pod stuck while shutting down would trigger an alert |

kube-state-metrics reports one series per Ready state, and only the current state's series is
non-zero. So on the `condition="true"` series, `== 0` matches Ready both False and Unknown.

The expression was tested against the live vmsingle database, including a **positive control** (a
query that must return results, to prove the query works). The exact expression returns 0 series (no results).
The same expression with `== 0` changed to `== 1` returns 103. Without that control, a result of
zero would look the same as a broken query. That kind of broken query hid two nights of CouchDB
backup failures earlier in the same week.

### 2026-07-26 — Kyverno namespace excludes audited: 1 unneeded exclude removed, a wholesale narrowing rejected

This follows B6-2, which narrowed `disallow-host-path` (see the next entry). Four other policies
still had excludes that exempt a whole namespace, so the same change looked possible there. The
measurement showed otherwise.

The share of pods that would break each policy, across every app namespace that the policy excludes:

| Policy | Pods | Violate |
|---|---|---|
| `require-readonly-rootfs` | 31 | 21 (67%) |
| `require-non-root` | 37 | 17 (45%) |
| `disallow-privilege-escalation` | 24 | 12 (50%) |
| `require-drop-all-capabilities` | 24 | 13 (54%) |

B6-2 was worth doing because only ~15% of pods in its namespaces needed the exemption. At 45–67%, a
rewrite keyed on labels would need dozens of selectors in policies that deny pods (Deny mode). Those
selectors would be more fragile than the gap they close. **The evidence, not a preference, rejected
the wholesale narrowing.**

Only one exclude could be proved unneeded: **`percona-mysql` is removed from
`disallow-privilege-escalation`**. That namespace holds only `ps-operator`, and the pinned
`ps-operator-1.2.0` chart already sets `allowPrivilegeEscalation: false`. The namespace's
`require-drop-all-capabilities` exclude stays, because the operator does not drop `ALL`. If a later
chart version drops the setting, the HelmRelease fails to apply. That failure is visible, and worth
knowing about.

**Checks of the workload templates, not of the running pods, rejected two more candidates.**
`mealie` looks compliant in a scan of pods. But `Job/mealie-user-provision` runs as root, and its
pod had already finished (Succeeded), so a scan that filtered by phase hid it. `backup-replication`
has no long-running pods at all, and both of its CronJobs violate the policies.

**Review, not measurement, caught a third.** The change had removed `paperless-ngx` from the
`require-non-root` excludes, and review reverted that. `apps/paperless-ngx/deployment.yaml:50` runs a
`fix-permissions` init container (a container that runs before the app starts) as UID 0, the root
user. `.claude/review-invariants.md` records that the container must run as root; otherwise
s6-overlay (the process supervisor in the image) crashes in a loop, CrashLoopBackOff (incident
`71cd0765` to `b8cbe170`). The measurement missed it because the check copied the policy's own logic.
So it answered "does this pass?" rather than "does this run as root?".

That gap is real, and it reaches beyond this change. The first branch of `require-non-root` tests
`runAsNonRoot` at the **pod level**. So a pod-level `true` satisfies the policy, whatever a single
container sets for itself. On that date, any workload could run a root container under the policy.
This change does not fix that; a follow-up records it.

*(Corrected the same day. This paragraph first said "tightening it would deny paperless-ngx and
mealie, both documented and deliberate". That was wrong. `require-non-root` excludes both
namespaces, so the policy never evaluates them, and they are not the reason the expression stays
loose. To harden the policy, audit the namespaces that it does match. The Codex reviewer caught the
error.)*

### 2026-07-26 — B6-2: `disallow-host-path` exempts listed workloads instead of whole namespaces

This was the last open item in the plan that fixed the findings of the 2026-07-24 ultrareview. The
plan file was removed after `d6d67c20`. On 07-25 the work
waited for a supervised Audit soak: a period in which Kyverno only reports violations while someone
watches. Instead, it shipped on proof from tests that give the same result every run. Plan and full
test matrix: the B6-2 hostPath narrowing plan (removed after `0cb04187`).

**The gap was wider than recorded.** The policy exempted six whole namespaces. Five of them
(`monitoring`, `loki`, `databases`, `immich`, `backup-replication`) also set the Pod Security
Standards (PSS, the built-in pod security levels) to **`privileged`**, because their hostPath
workloads need it. So neither the policy nor PSS guarded those namespaces, and every pod in them
could mount any path on the host. A server dry-run showed it. The API server accepted a harmless
pod with an added hostPath mount in all five namespaces. It denied the same pod in
`home-assistant`, which is also `privileged` but was never exempted from this policy. The sixth
namespace, `couchdb`, no longer exists; CouchDB runs in `databases`.

**Autogen (Kyverno's automatic copy of pod rules onto Deployments, Jobs and other controllers) was
believed to be a hidden danger. It was not; see the correction in the cert-manager entry from the same day, above this one.**

**A scan would have missed `couchrestore`.** That one-shot disaster-recovery Job, described in
`.backup/README.md` (now `docs/disaster-recovery/README.md`), mounts a hostPath, and no scan of live pods can see it. Without an allowlist
entry, the policy denies it. That would break ultrareview finding H2 again, which was closed two
days earlier. A test confirmed this: with the entry removed, the Job failed.

**No Audit soak.** Instead, every check ran in both directions, because a Kyverno `skip` result can
mean either "exempted" or "never matched". The tests ran 8 exempt / 8 denied pairs across pods,
controllers, Jobs and CronJobs. They used autogen rules copied from the live `status.autogen`. In
review round 1, Codex rated the Job labels a HIGH finding. Its factual premise was wrong: the API
server fills in those labels as defaults before admission (the step where Kyverno checks a
request). But the hidden fragility that Codex pointed at was accepted and fixed. Round 2 returned no
CRITICAL or HIGH finding.

### 2026-07-26 — CouchDB backups failed for two nights unnoticed; a race in couchbackup's parallel requests

`obsidian-personal`, the Obsidian LiveSync database, failed to back up on **07-25 and 07-26**, with
five retries each night. The cause is a concurrency bug in `@cloudant/couchbackup` 2.11.18. At the
default `--parallelism 5`, some requests reach CouchDB with **no credentials** and get
`Access is denied due to invalid credentials`. The run then dies with `exit=11`, after it has
buffered batches that it never wrote. The small databases (`empty`, `zz-dr-drill`) survive, because
they never open enough connections for the requests to race each other. The fix pins
`--parallelism 1` (`4d84acc5`).

**`.backup/README.md` (now `docs/disaster-recovery/README.md`) already documents the same race for the disaster-recovery restore.** The
2026-07-24 restore drill found it. The write-up covered `couchrestore`, and nobody linked it to
`couchbackup`: same library, same symptom, opposite direction. Anything that calls this package
should assume parallelism 1.

**The failure was two days old and nobody knew**, for two reasons that made each other worse:

- **`vmsingle-vmsingle-0` does not exist.** VMSingle is a *Deployment*, not a StatefulSet, so its
  pod name does not end in a fixed number. Every alert check of the form
  `kubectl exec -n monitoring vmsingle-vmsingle-0 -- wget …` wrote an error to standard error. The
  check discarded standard error with `2>/dev/null`, so the empty standard output looked like "no
  alerts firing". Three critical alerts, `BackupJobFailed`, `JobFailed` and `NoRecentBackups`,
  fired the whole time. Always find the pod by its label, and check for `.status == "success"`
  before you believe an empty result.
- **The old code could not have reported the failure.** Before `e136ae08`, the command ended with
  `> "$DB.raw" 2>&1 || true`. That threw away the exit code and wrote standard error into the same
  file as the backup JSON. The nightly `✅ completed (20.3M)` measured whatever partial JSON was left
  after a `grep "^\["`. It never proved that the backup was complete. So the pre-07-25
  "successes" are **unverified**, not known to be good. The alert only started because Batch 2
  made the script respect the exit code.

`backup-replication` failed on the same nights, and that failure was **correct**. No CouchDB archive
existed, so the job stopped before it copied anything. It kept the source files instead of deleting
the only other copy. That is the Batch 2 guard working as designed: the job runs `rm -rf` only after
the NAS (the network storage server) confirms receipt.

The recovery was checked, not assumed. A manual `couchdb-backup` run printed
`obsidian-personal completed (21.1M, 1s)`, which matches the size and speed before the failure. A
manual `backup-replication` run then reported `OK: all 4 validated artifact(s) present on NAS`. The
old failed Job objects were deleted, and `kube_job_failed` now returns no series.

One item stays open: `zz-dr-drill`, the test database from the 2026-07-24 restore drill. It was
never dropped, and the nightly backup still copies it.

**The NAS sync reported `speedup is 1.00` on the same day. That is NOT a defect.** It was
investigated, and it is recorded here because it looks alarming and someone will notice it again.
The replication moved 138.7 GB, and rsync reported that it reused nothing. That looks as if the job
sends every old backup again every night. It does not. Step 2 uses `rsync -av`. `-a` includes `-t`,
so rsync keeps file modification times (mtimes), and its quick check, which compares size and mtime,
works. Two facts explain the number:

| Fact | Effect |
|---|---|
| Step 4 deletes the source (`postgres`/`couchdb`/`mysql`/`pvc`) after the NAS confirms receipt | on a normal run, nearly every file present is new |
| 129 GB of that run was the **weekly** immich backup, created that morning | it had not been copied yet, because that night's replication had stopped early |

Step 4 leaves `immich/` alone on purpose. `immich-backup-cronjob.yaml` manages those files with its
own keep-2 clean-up, which keeps two snapshots. That is why ~129 GB, two weekly snapshots, correctly
stays in the source tree.

### 2026-07-25 — n8n outage: 8 hours down, no alert, and the pod reported healthy

The outage was found by chance, during work to record a baseline of the monitors for Batch 9. n8n
had served HTTP 503 since **04:47**, and no alert had fired.

The cause was a short PostgreSQL outage during the early-morning node event. n8n's TypeORM
connection pool logged `connect ECONNREFUSED` against the `main-postgres-rw-pooler` ClusterIP (the
Service's internal cluster address). The pool used up its retries and never reconnected. By the time
someone found it, the cluster was healthy: postgres 2/2, and both pooler pods up. A TCP connection
from inside the n8n pod itself reached the ClusterIP *and* both pooler pod IPs. The network had
recovered hours earlier; only the pool had not.

**Two failures kept the outage hidden, and both are worth remembering:**

- **The readiness probe passes while the app cannot be used.** n8n's probe requests `/healthz`,
  which does not use the database. So the pod stayed `1/1 Running` for eight hours with 0 restarts,
  while every real request returned 503. Kubernetes saw nothing wrong.
- **`kubectl rollout restart` did nothing, and reported success.** It printed "successfully rolled
  out". But Flux's drift detection (which resets live objects to match git) removed the
  `kubectl.kubernetes.io/restartedAt` annotation. It reverted the Deployment to its spec in git, and
  scaled the *old* ReplicaSet back to 1. (A ReplicaSet is the object that keeps a set number of
  copies of a pod running.) The original pod survived, with the same name and the same
  8h age. Only `kubectl delete pod` worked, because Flux manages the Deployment, not the pod that the
  Deployment creates. This is the opposite of the usual advice. If you need a restart without a spec
  change while drift detection is on, deleting the pod is the reliable action.

uptime-kuma reported the outage correctly the whole time: its N8N monitor was the only thing that
knew. Its monitors do not send to Alertmanager, so "no alerts firing" never proved health.

### 2026-07-25 — Ultrareview fixes, Batch 9: the items deferred earlier

Earlier batches deferred four items, because each one needed a spike first (a small test run against
the real system). Running those spikes also disproved two more of the plan's instructions.

**uptime-kuma outbound traffic (egress): the plan named the wrong port.** It said to remove
6446/5984/8428/9090. A dump of the monitor table, the authoritative source, showed that a monitor
**actively checks 5984** on `couchdb-svc-couchdb`. Removing that port would have broken a live
monitor. No monitor uses the other three, so they were removed: MySQL is monitored on 3306
directly, VMSingle on **8429** (not 8428), Alertmanager on 9093, and Prometheus no longer exists.
A note for next time: here uptime-kuma does **not** use its bundled SQLite database.
`/app/data/kuma.db` is an empty 0-byte file, and the real data lives in MariaDB. So any question
about the monitors has to be answered from MariaDB.

**The runbook for restoring PVCs (the pods' persistent storage) covered 3 of 14 PVCs and could not
have worked.** It extracted into `pvc-XXXXX`, a placeholder typed as is. The plan said that
`pvc-backup-cronjob.yaml` first needed a table that maps each backup to its workload and target.
The spike disproved that. local-path (the storage provisioner) names every PV (persistent volume) directory
`<pv-uuid>_<namespace>_<pvc-name>`, and the owning workload can be worked out from the PVC. So the
procedure finds both at restore time. A fixed table would go out of date the first time a PVC is recreated, and that
is when a restore is most likely.

The procedure went through three review rounds, and each round caught a real defect:

| Defect | Why it mattered, and the fix |
|---|---|
| a `PV_PATH` computed on the workstation but used on the node | kubectl is not configured on k3s agents. So the node now works out the path itself, with the same glob (filename pattern) that the backup job uses |
| a sequence of destructive steps that was not fail-closed | it did not stop safely on an error |
| an extract on top of the live directory | it leaves behind files that are not in the backup, so the result mixes old and restored files: it is corrupt, not a restore. The procedure now moves the live directory aside and keeps it as a rollback (a copy to go back to) |
| a STEP 3 that used variables set in another shell | it would have left the app scaled to zero while the procedure still read as "still restoring" |

The review also found a `find | head -1` that would pick one of several PV directories without any
warning.

Every block now works out its own inputs. The extract itself still has **not been tested** in an
end-to-end drill, and the runbook says so.

**Two Kyverno comments** explained which containers their policy checks by pointing at matching
ClusterPolicy copies, which `2b5ffb99` deleted. A search of the git history confirmed that both
comments were accurate: the old ClusterPolicy for the latest tag did use
`foreach: list: spec.[initContainers, containers][]`. So the comments were rewritten to make sense
on their own, and to name the gap that follows: nothing checks `kubectl debug` containers for
seccomp or for a floating tag. The gap is deliberate. If the policies enforced these checks on
debug containers too, debugging during an incident would break.

**The narrowing of `disallow-host-path` (B6-2) was NOT shipped, on purpose.** The A11 spike
succeeded: every hostPath workload does carry a label that a rule can target. But the spike also
showed that the change needs **nine** correct selectors in a policy that enforces **Deny**. Six of
the affected workloads are CronJobs, whose pods exist only while they run. So the
`kubectl get pods` scan that such a change would normally be built from cannot see them. 41 pods
across the six excluded namespaces mount no hostPath at the time of writing, and nothing guards
them, so the gap is real. But nothing is broken on that date. If the change is wrong, the result is
a backup Job denied at 03:00 with nobody watching. That is the kind of unreported failure that this
whole review set out to remove. The plan records the full analysis and a rollout path that starts
in Audit mode (Kyverno reports violations without blocking them).

### 2026-07-25 — Ultrareview fixes, Batch 8: bringing the documentation up to date

Every claim was checked again against the cluster or the manifests, not copied from another
document. That check found four errors that the plan had not listed.

**`ARCHITECTURE.md` now records the Cloudflare Access setting for each tunnel hostname.**
Cloudflare Access is Cloudflare's login gate in front of an app. The record sits next to the
existing note that Traefik middleware never applies on the external path. Access policies live in
the Cloudflare zone and leave no file in the repo, so no tool can check them for drift. The table is
the record of the decision:

| Hostname | Cloudflare Access | Why |
|---|---|---|
| `couchdb` | Service Auth, the only hostname on it | Obsidian LiveSync runs without a user interface (headless) and cannot log a person in |
| `authentik` | none, on purpose | gating the identity provider would lock every other app out of its own login |
| the remaining seven | none; each app's own OIDC (OpenID Connect) login | accepted trade-off, written down: their login pages are reachable from the internet, so a login bug in an app is exposed to the internet rather than only to the LAN |

The plan did not ask for the corrections below. They came from checking the documents rather than
trusting them:

| Document | What it said | What is true |
|---|---|---|
| `HOMELAB_ANALYSIS.md` | **n8n uses OIDC** | the repo has no OIDC configuration for it anywhere. n8n single sign-on (SSO) is an Enterprise feature, which `CODEMAPS/apps.md` already said. The two documents had contradicted each other, and the codemap was right |
| `SECURITY.md` | SSO covered "7 of 16 apps" | the 7 was right and the 16 was wrong. The file also left out homepage's new forward-auth (a login check that Traefik makes before it passes a request on) |
| `CODEMAPS/apps.md`, rate limits | the values in use before 2026-07-03 (100/min, 200/min) | the middlewares enforce `average: 300` and `average: 600`, with an explicit `period: 1m` |
| the same codemap, authentik | **authentik is under "high-frequency"** | on purpose, authentik has no rate-limit middleware at all, because throttling the SSO provider breaks the login flow for every app behind it |
| the inventory of secrets to rotate | missing three secrets | they included `cloudflare-api-token`, the DNS-01 credential behind every certificate in the cluster, and `sops-age`, the key that decrypts every secret in this repo. The dates came from the live objects, not from guesses |

**Two runbook commands in `SECRETS_ROTATION.md` could not have worked.**
`flux reconcile kustomization apps --timeout 45s --force` uses a flag that does not exist:
`flux reconcile kustomization` accepts only `--with-source`. The Redis rotation step told the
operator to reconcile `infrastructure-controllers`. But the Redis secrets live under
`infrastructure/configs/databases/redis-ha/`, which belongs to `infrastructure-configs`. The
reconcile would have reported success and applied nothing.

The batch also fixed the remaining places where the documents no longer matched the system:

- the app count, 16 to 17, in `AGENTS.md`, `ARCHITECTURE.md` and the `HOMELAB_ANALYSIS.md` heading
- a RustDesk row
- Homepage's SSO column
- the replication leg from W1 to W2 (the first and second worker nodes), which was retired
- entries for AdGuard, which was decommissioned
- a `KyvernoPolicyViolationsDailySummary` VMRule that exists in neither git nor the cluster

Dated history entries that mention "16 apps" were left as they were, because they were true when
written.

### 2026-07-25 — Ultrareview fixes, Batch 7: failures that reported success, and the software supply chain

Nine items had one thing in common: a failure that reports success. Each one was reproduced before
anything changed. Each fix was then tested against the failure it claims to prevent, not only
against a deploy that went green.

**Bugs of the kind "the check cannot fail."** The HACS installer (HACS is a community add-on
store for Home Assistant) ran `mkdir -p "$HACS_DIR"` and then checked the install with
`[ ! -d "$HACS_DIR" ]`. That tests the directory it had just created, so the check could never
trigger. It also downloaded `releases/latest/download/hacs.zip`, which names no version. It is now
pinned to 2.0.5, and it checks for `__init__.py` and `manifest.json`. The test that decides whether
to install again used to ask whether the directory exists. It now asks whether *both* files exist.
It deliberately does not use a `.installed-version` marker file, as `oidc-auth-install` does: HACS
updates itself through the Home Assistant UI, so a fixed version lock would undo the operator's
in-app updates on every pod restart. The pin sets up a fresh volume; it does not stop the version
from changing later.

**The cloudflared sync counted the hostnames it parsed, then ignored the count.** The script
computed and printed `COUNT`, but never stopped on it. A PUT replaces the whole tunnel
configuration. So if the parser drifted, the sync would publish a shortened ingress list, and every
hostname it missed would lose external access with no warning. A guard now counts the hostnames
straight from the config, and refuses to send the PUT unless the parser's count agrees. The guard
derives the expected count rather than using a fixed minimum, so adding a hostname needs no edit
here. A test in `curlimages/curl:8.21.0` against the real decrypted config:

| Case | Hostnames parsed | Guard |
|---|---|---|
| the config as it is | 9/9 | passes |
| rule indentation drifts | 1/9 | refuses |
| the `ingress:` key is renamed | 0/9 | refuses |

**The postgres extension job reported the opposite of the truth.** Its `WHEN OTHERS` handler, which
catches every error, reported each SQL error as "extension already at latest version" and exited 0.
Testing showed that "already at the latest version" is a `NOTICE`, not an error. So the handler had
only ever run on real failures, and it had reported every one of them as "already at latest".

The first fix was also wrong, and the peer review caught it. That fix collected the failures and
raised an error at the end. It still lost the work: a `DO $$…$$` block is a single transaction, so
the final `RAISE` rolled back every successful `ALTER EXTENSION` with it. A test reproduced this:
the log read `Updated pg_trgm` while the catalog stayed at 1.5. The job now runs one `psql -c` per
extension, each in its own transaction. A test with a deliberately broken extension confirmed the
fix: the broken one fails with its real error, the others succeed and **persist**, and the job
exits 1. The test ran under `/usr/bin/dash`, the shell that the Debian-based CNPG (CloudNativePG) image uses, not just
under alpine's ash.

There were two smaller cases of the same kind. homepage turned every `cp` failure into "No
ConfigMap files to copy (using defaults)" and started with its defaults. homehub put its password
into the config with `sed`, so a `/` or `&` in the secret would corrupt the config with no error.
Homepage now tells four cases apart: not mounted, unreadable, empty, and copy failed. It tests with
plain `ls`, not `ls -A`. A ConfigMap mounted as a volume always holds a `..data` symlink, so `-A`
reports "not empty" even when the ConfigMap has no keys. `cp` would then get a glob pattern that
matched nothing, as literal text. Homehub now uses awk's `index`/`substr`, which treat no character
as special.

**The three supply-chain items have one cause.** `image-pin-audit.sh` skipped `kind: HelmRelease`
on purpose, with a comment that said their pinning was "audited elsewhere". Nothing audited it
anywhere, and that gap is how the other two problems got in:

- The loki gateway had a bare `tag:` with no `repository:`. Renovate could not see it, and it was
  one patch version behind the same image in `apps/rustdesk/beacon-deployment.yaml`.
- `redisOperator.imageTag: "v0.24.0"` kept the operator at that version while Renovate moved the
  chart to 0.25.0 in `eee4565f`. So the 0.25.0 CRDs (custom resource definitions) drove a v0.24.0
  binary.

The audit now covers `spec.values`. A test ran it against the versions of both files from before
the fix: it fails on those two problems and nothing else, and it passes on the fixed tree.

**The Redis operator change shipped in its own commit, with its own reconcile.** Deleting the fixed
tag changes what runs: the chart defaults to `v<appVersion>`, so the deletion upgrades the live
operator. v0.25.0 includes the change "mount config emptyDir volume so sentinel.conf persists across
container restarts". The live sentinel StatefulSet declared a `config` volume that its container
never mounted. So the upgrade was certain to restart the sentinel pods. Checks after the upgrade:

| Check | Result |
|---|---|
| `/etc/redis/sentinel.conf` | now sits on the mounted volume |
| sentinels | all three restarted and rejoined, with `num-other-sentinels 2` |
| replicas that the sentinels found | one (a "slave" in Redis terms) |
| failover | none |
| alerts | none |

The same change removed the seccomp `postRenderer` (a patch that Flux applies to the chart's
output), because chart 0.25.0 offers a `podSecurityContext` value for the same setting. Before the
swap, `dyff` showed that both versions render the same manifests. The setting was then confirmed
live on the upgraded Deployment.

`apps/blocky/pdb.yaml` closes the last item. The plan said that blocky was the only workload with
more than one replica and no PodDisruptionBudget (a limit on how many of its pods a drain may stop
at once). That is **false**: cert-manager (×3) and cnpg-operator also lack one. Only blocky got one.
It is the LAN's DNS resolver, so draining both replicas stops name lookups for every client on the
network. The others are operators that only reconcile resources, and a short outage of them costs
nothing.

### 2026-07-25 — Ultrareview fixes, Batch 5: logins for Alertmanager and homepage

`am.h0melab.work` served `/api/v2/silences` to anyone on the LAN. A live check got a `200`. So any
device on the wifi could silence every alert. Both hosts are LAN-only (neither is in the Cloudflare
tunnel), so the threat is the local network, not the internet.

**The two services use different mechanisms on purpose**, each matched to the service's role:

- **Alertmanager uses Traefik basicAuth** (a username and password that Traefik checks), from a
  Secret encrypted with SOPS. Alertmanager is a tool for responding to incidents, so it must not
  depend on the systems it is used to debug. Behind Authentik, it would depend on postgres and then
  on authentik. A CNPG failover (a switch of the PostgreSQL cluster that CloudNativePG manages to
  another instance) would then take out the alert console at the moment it is needed.
- **homepage uses Authentik forward-auth** through the **embedded outpost** (the proxy that is
  built into the Authentik server). No separate outpost deployment exists, and none was needed.
  `authentik-server` already exposes port 9000. The NetworkPolicies already allowed traffic from
  Traefik to authentik:9000, and already let authentik accept traffic from Traefik. So this batch
  makes **zero** NetworkPolicy changes. homepage is the first proxy provider in the Authentik
  instance; everything else uses OIDC (OpenID Connect) logins.

Checks of Alertmanager after deploy:

| Credentials | Status | Meaning |
|---|---|---|
| none | `401` | refused |
| the right ones | `200` | allowed |
| wrong ones | `401` | refused |

Findings that changed how the work was done:

- **The homepage callback cannot live in the homepage namespace.** An Ingress can only target a
  Service in its own namespace. Routing `/outpost.goauthentik.io/` through an ExternalName alias
  fails: Traefik's `kubernetesIngress` provider defaults `allowExternalNameServices` to **false**,
  and this cluster does not enable it. So Traefik refuses that backend, and it reports nothing. A
  `--dry-run=server` does not catch it, because the object is valid; Traefik only declines to route
  it. So the callback Ingress lives in the **authentik** namespace, where `authentik-server` is a
  normal Service in the same namespace. That also avoids weakening the global default.
- **The callback must be its own Ingress.** Traefik applies the `router.middlewares` annotation to
  every rule in an Ingress. If the callback were part of the protected Ingress, Traefik would demand
  a login on the request that completes the login. The browser would then loop through redirects.
- **Auth comes AFTER the rate limit in both chains.** A 401 or a redirect ends the middleware chain
  early. So if auth came first, login attempts would never reach the rate limit.
- **Traefik's basicAuth Secret must contain exactly ONE key.** The Secret first stored the
  plaintext password next to the htpasswd `users` key. The middleware then failed to build, Traefik
  dropped the router, and the host answered **404 instead of 401**. The Traefik error log showed
  nothing about this outage. The checks after deploy caught it. The fix moved the plaintext into a
  separate Secret that nothing references.

The batch shipped in **two phases, on purpose**. Phase 1 added the middlewares, the blueprint and
the callback route, with nothing referencing them yet. Phase 2 switched the Ingress annotations
over. Without the split, the Alertmanager annotation (in `monitoring-controllers`) would have been
applied before the middleware and Secret (in `monitoring-configs`, which depends on the first).
Traefik would then have pointed at a middleware that did not exist yet. Between the phases, a check
confirmed that the callback path redirected to authentik correctly, before any login depended on it.

No monitor was affected. uptime-kuma checks both apps through their cluster Services, never through
the Ingress hostname. Nothing inside the cluster looks up `am.h0melab.work` either; VMAlert sends
alerts to the Service.

The generated credential is in the SOPS-encrypted `alertmanager-basic-auth-credential` Secret
(`username`/`password`). Next steps: read it with
`kubectl -n monitoring get secret alertmanager-basic-auth-credential -o jsonpath='{.data.password}' | base64 -d`,
move it to 1Password, then delete that Secret and add the entry to `SECRETS_ROTATION.md`.

### 2026-07-25 — Ultrareview fixes, Batch 6: cleaning up policies, NetworkPolicies and RBAC permissions

This batch fixed six of eight items. The two that need a spike first (a small test against the real system) are deferred (see the end of
this entry). Every fix was checked against the live cluster, not against the text of the finding.

- **monitoring `rate-limit-standard` allowed 100 requests per second, not per minute.**
  `rateLimit.average` counts requests per `period`, and the default period is **1s**. So
  `average: 100` with no `period` allowed 60x more than the comment directly above it said ("100
  requests/minute sustained"). The apps tier was corrected on 2026-07-03, but this copy in
  monitoring was missed. The fix adds `period: 1m`.
- **popeye could `get,list` Secrets across the whole cluster.** A `list` returns the full *content*
  of each secret, so a weekly clean-up scanner could read every credential in the cluster at any
  time. The permission is removed. The cost is popeye's check for unused secrets. The CronJob runs
  `--force-exit-zero`, so the rest of the scan still works.
- **The Kyverno NetworkPolicy allowed a port that nothing listens on.** Every kyverno controller
  (admission, background, cleanup, reports) serves its webhook on **9443**, and a check of the live
  pods confirmed it. None listens on 443. The fix removes the unused 443 entry. It also corrects the
  comment, which had said that only the admission controller uses 9443.
- **Two "Kubernetes API" egress rules on `mysql-cluster` matched nothing; one rule that works
  replaces them.** `namespaceSelector` selects the pods in a namespace. `default` holds **zero
  pods**: the API is a Service at 10.43.0.1:443 backed by the control-plane node, not a pod. The
  `ps-operator` pod in `percona-mysql` declares **no container ports at all**. The first attempt
  deleted both rules outright, and review was right to push back. A cluster that runs well now does
  not prove that a restart is safe, because Percona pods can need the API to find their peers during
  bootstrap (their first start) or recovery. `ipBlock: 192.168.1.127/32` on **6443** now replaces both rules. grafana,
  prometheus-operator and kube-state-metrics already use the same pattern here. They do so because
  NetworkPolicy is evaluated after DNAT (the rewrite of the Service address to a real one), so the
  ClusterIP is not the address that matches.
- **The database egress rules of authentik and obsidian allowed the whole database namespace.** Both
  apps' database egress rules now allow traffic only to the pods that serve their database (`cnpg.io/cluster: main-postgres`, `app: couchdb`). The
  `podSelector` sits under the **same** `to` item as the `namespaceSelector`, which means AND, not
  OR. As separate items, they would have widened the permission instead of narrowing it. The
  rendered output confirmed this. `cnpg.io/cluster` was chosen on purpose, because it covers the
  rw-pooler pods (the connection poolers for the read-write service) as well as the database instances, and authentik connects through
  `main-postgres-rw`.
- **Removed a leftover Kyverno exclude** for `main-mariadb-metrics` in
  `require-non-default-serviceaccount`. Percona MySQL replaced MariaDB, and zero such pods exist.

**Deferred.** Both items need a spike first, and the plan scopes their work separately:

| Item | What it needs first |
|---|---|
| A11: narrow the whole-namespace excludes of `disallow-host-path` to label-keyed `matchConditions` | finding the rendered labels of each workload, plus an admission test for each |
| A10: drop uptime-kuma's four unused egress ports | the live list of monitors, because a port that looks unused may serve a configured check |

Also deferred: correcting three `ephemeralContainers` comments in the Kyverno policies. That needs
its own check of whether the code can be reached, not just a text edit.

### 2026-07-25 — Ultrareview fixes, Batch 4: fixing monitoring defects

This batch fixed nine alerting defects. Each one was checked against the live VictoriaMetrics
database before any edit. **One finding was wrong as written** (see the first item). Applying the
plan word for word would have replaced an alert that could never fire with another alert that could
never fire, for a different reason.

- **`BackupJobRunningTooLong` could never fire, but not for the documented reason.** The audit said
  the metric should be `kube_job_status_complete`. On this cluster's kube-state-metrics **v2.19.1,
  that metric does not exist** (0 series; a series is one stream of values for a metric with one set of labels), while
  `kube_job_complete` has 51. The real defect:
  `kube_job_complete` carries a `condition` label (true/false/unknown), and
  `kube_job_status_start_time` does not. `and` matches only series with identical label sets, so it
  produced nothing. The alert now excludes both final **conditions**, with `unless`
  `kube_job_complete{condition="true"}` and `unless` `kube_job_failed{condition="true"}`. It means
  "old, and neither finished nor failed". Review rejected two earlier attempts, and each one missed
  a case:
  - `kube_job_status_active > 0` misses a stuck Job whose pod was evicted or is waiting between
    retries. Such a Job has not ended, and `active == 0`.
  - `kube_job_status_failed > 0` counts failed *pods*. So a Job that lost one pod and is still
    retrying would be excluded, even though it is really stuck.

  `kube_job_failed` showed zero series that day only because nothing had failed. A check of the
  kube-state-metrics (KSM) scrape confirmed that it is a registered STABLE metric family, which
  emits condition metrics only for conditions that are actually present. So the `unless` excludes
  nothing until a Job really fails.
- **`KyvernoAdmissionControllerDown` was evaluated hourly** (`interval: 1h`), so a critical alert
  could arrive up to an hour late. It now runs every 60s.
- **The VMSingle healthCheck checked nothing.** kstatus (the library that decides whether a
  resource is ready) treats a custom resource with no `status.conditions` as Current, and VMSingle
  publishes none. A live check confirmed this: its status carries only
  `updateStatus`/`lastAppliedSpec`/`observedGeneration`. The fix replaces it with
  `healthCheckExprs` on `status.updateStatus` (live value `operational`). The expressions apply only
  when `status.observedGeneration == metadata.generation`. So a stale status from the previous
  generation cannot be read as describing the spec just applied. Only the `current` and `failed`
  cases are given, and Flux treats any value that matches neither as still in progress. The
  operator does not publish its full list of `updateStatus` values (the CRD, its custom resource definition, has no description of
  them). So a full list would risk a value such as `updating` matching nothing, which would leave
  the health check stuck on every rollout. A check confirmed that the field exists in the installed
  CRD schema, and that the edited object passes a server-side dry-run.
- **The PostgreSQL and Redis `ConnectionFailure` alerts were deleted, not repaired.** Neither could
  ever fire: each used `and` across series with different label sets, and each returns 0 series
  live. Also, zero transactions or zero connected clients means idle, not broken.
  `cnpg_collector_up == 0` and `redis_up == 0` already alert on real availability.
- **Three quorum alerts could never fire, each for two reasons that added up.** (A quorum is the
  smallest number of members that must be up for a group, such as the Redis sentinels, to act.) First, `count()`
  counts series, and KSM emits `phase="Running"` with the value **0** for pods that are not running
  (17 such series existed at the time). So the count never dropped. Worse, `count()` over an *empty*
  vector (a query result that holds no series) returns **no series at all**. So in the total outage that each alert names, the comparison
  produced nothing, and the alert stayed quiet. The fix, `(count(... == 1) or vector(0))`, applies to
  `RedisHASentinelQuorumLost`, `MySQLOrchestratorNotRunning` and `RedisHAAllDown`. That reverses the
  failure mode: a missing series now reads as 0 rather than as nothing. So the two redis alerts
  moved from `for: 1m` to `for: 5m`; otherwise a kube-state-metrics restart would trigger an alert. That trades
  four minutes of delay for an alert that fires at all. The last alert is the clearest example. If
  every redis pod is down, its exporter targets vanish and `redis_up` disappears. So "All Redis
  replication pods down" stayed quiet at the moment it mattered. A simulated outage proved the fix:
  with a selector that matches nothing, all three old forms return 0 series, and all three new forms
  fire.
- **`NoRecentImmichBackup` was missing from the regex of the telegram-backup route**, so it went to
  the default receiver.
- **The NodeDown inhibit rule did nothing.** An inhibit rule mutes some alerts while another alert
  fires. NodeDown comes from node-exporter, whose `instance` is `192.168.1.x:9100`. The pod alerts
  that it was meant to mute carry the `instance` of kube-state-metrics (`10.42.3.65:8080`). So
  `equal: [instance]` could never match. The rule is deleted.
- **Two new `absent()` alerts**, which fire when a series disappears:
  - `NASLibraryMountMissing`. `NodeDiskSpaceLow/Critical` already cover the capacity of the
    virtiofs mount (confirmed: node-exporter can see `/var/lib/immich-library`). But they work only
    while the series exists. If the NAS (the network storage server) detaches, the series vanishes, and those alerts go quiet
    instead of firing.
  - `VMAgentIngestionDown`. It works the same way, for the case where nothing scrapes vmagent at all, so
    `up{...} == 0` never evaluates.

SMART/RAID health on the NAS stays unmonitored, because it cannot be read without sudo. It is
recorded as an accepted risk, not worked around.

Checks that ran:

| Check | What it covered |
|---|---|
| expressions | all four new or changed ones, run against live VictoriaMetrics: they parse without errors, and they correctly do not fire |
| yamllint | ran |
| kubeconform | `clusters`, `monitoring/configs`, `monitoring/controllers` |
| kustomize | builds |
| server-side dry-run | the changed Kustomization |

### 2026-07-24 — Ultrareview fixes, Batch 3: the CouchDB disaster-recovery restore, tested end to end

The audit found that the documented CouchDB restore could not run. Kyverno denies a bare
`kubectl run`, and `wget --method=PUT` is not a flag that busybox accepts. Running the restore found
**four** blockers, not two. The last one only appears after part of the restore has already
succeeded.

**A drill tested the complete restore procedure, end to end.** A full restore of the live Obsidian database into a
scratch database completed. The scratch database was dropped afterwards.

| Measure | Result |
|---|---|
| Document revisions | 1505 |
| Documents | 1479, against 1494 live. The gap is edits made after the 03:05 backup |
| Deleted documents | matching live exactly, at 21 |

What blocked it:

1. **Kyverno.** All 12 ValidatingPolicies enforce Deny, so admission rejects a bare `kubectl run`.
   A live test proved it. The fine-grained webhook names only the FIRST failing policy
   (`require-labels`), so fixing one field only reveals the next. The spec now carries everything
   the policies need, including `serviceAccountName: couchdb-jobs` for
   `require-non-default-serviceaccount`, which the audit did not flag.
2. **ResourceQuota, a second rejection after Kyverno passes.** `namespace-quota` on `databases`
   leaves ~800m CPU free on a running cluster (m means thousandths of a CPU core). So the quota
   refused the initial 1-CPU limit. The limits are now sized to fit.
3. **`readOnlyRootFilesystem` breaks npm.** npm's default cache, `~/.npm`, cannot be written, so
   `npm install` fails and couchrestore is not there at all. The fix points `HOME` and
   `npm_config_cache` at the `/tmp` emptyDir (a scratch volume that lasts as long as the pod), and keeps the read-only root filesystem (RoRFS) on
   rather than turning it off.
4. **`--parallelism 5` (the default) breaks authentication partway through the restore.** Some
   requests sent at the same time reach CouchDB with no credentials at all. CouchDB's log shows the
   user as `undefined`, and it returns 401 on `_bulk_docs`. By then several batches have already
   been written, so the failure looks like a partial success rather than a broken command.
   `couchrestore` has no username or password flags, only `--url`. So `--parallelism 1` is the fix,
   and it is now marked as required, not as tuning.

Other corrections:

- The restore is now a **Job that reads the archive from the backup hostPath** (a folder on the node, mounted into the pod), instead of
  streaming it through `kubectl run -i`. The attach of that command timed out and killed the pod.
  The Job picks the newest archive itself and **checks the `.sha256` inside the pod**, so nobody
  needs SSH access to a node. That matters because the SSH key lives in 1Password, which may be
  locked in the middle of an incident.
- The step that creates the database first uses Node's built-in `fetch` with an Authorization
  header. It passes `?n=2` to match `clusterSize: 2`. CouchDB gives new databases n=3 (three copies
  of each document) by default, and logs `Request to create N=3 DB but only 2 node(s)`.
- A `DRILL_SUFFIX` switch restores into `<db>-drill`, so the whole path can be rehearsed without
  touching live data. The switch drops the scratch database first, so a re-run gives the same result
  (couchrestore refuses a target that is not empty).
- The image version had drifted. The fix moved it from `node:24.16.0-alpine` to `24.18.0-alpine`.
  `@cloudant/couchbackup` is pinned to 2.11.18.

A new **NAS-fetch Job** sits next to the existing shell rsync. It reads the `nas-rsync-credentials`
secret, and the namespace's NAS egress policy (the NetworkPolicy that lets its pods connect out to the NAS)
already applies to it. So archives can be pulled back
from the NAS without a shell on a node, and without the password in the operator's environment. A
test pulled the 16.6 MB archive from 2026-07-24.

Both manifests were rendered again *from the committed markdown*, then validated again with
kubeconform and a live `--dry-run=server`. So the documented commands are the ones that ran.

**Deferred:** B3-2. The runbook for restoring PVCs (persistent volume claims) covers 3 apps, while `CRITICAL_PVCS` backs up 10. The
fix first needs a mapping from each workload to its restore target, added to
`pvc-backup-cronjob.yaml`. It moved to its own batch rather than making this one longer.

### 2026-07-24 — Ultrareview fixes, batch 2: backup integrity and guards against data loss

This batch closed the audit's most severe finding and the paths around it that could lose data
without a warning. Backups are the only way to get data back here: there is no point-in-time
recovery (PITR) and no offsite copy, and both are standing decisions. So every one of these
problems failed *quietly*.

- **CouchDB backups reported success when they had failed (the HIGH finding).** The script ran
  `couchbackup … > ${DB}.raw 2>&1 || true`. That line threw away the exit code and mixed the error
  output (stderr) into the backup data. If any line started with `[`, the script then counted the
  run as a success. So a fatal error partway through the dump produced a **truncated dump**. This
  is what happened to that dump:

  | Check on the truncated dump | Result |
  |---|---|
  | checksum | **it got a valid sha256** |
  | replication validation | **passed** |
  | `lastSuccessfulTime` | **advanced** |
  | alert | **none fired** |

  After that, 30-day pruning on the NAS (the network storage box that holds the backups) together
  with deletion of the source copy could leave no
  complete copy of the Obsidian vault. On 2026-07-03 the same class of bug was fixed for the
  postgres, mysql and pvc backups, but that fix missed couchdb.
  Now the script writes stderr to its own file and captures the exit code. It decides whether the
  dump is complete from the `--log` file, in the same way as upstream
  `includes/logfilesummary.js`. A complete dump needs `:changes_complete` **and** a `:d batchN`
  line (batch written) for every `:t batchN` line (batch queued). `:changes_complete` alone only
  proves that couchbackup queued the changes in batches, not that it wrote them. If the check
  fails, the script prints stderr and the end of the log, and stops *before* it packages the dump.
  A database with no documents counts as complete, as it should, rather than failing the whole run
  (on `main` at the time of this entry, it fails). `@cloudant/couchbackup` is now pinned to
  **2.11.18**. Before, the Job installed it without a pinned version, so the tool that produces the
  disaster-recovery backup could change from one run to the next.
- **The replication step "Verify NAS" could never fail.** It ran
  `rsync --list-only | head -20 || echo "failed"`. head exits 0, and the `||` hid every other
  failure. Yet right after it, Step 4 runs `rm -rf` on every source backup. Now the script records
  each backup file that passed Step 1 by its **path relative to the source folder**. Each of those
  files must appear in the listing taken after the sync, and the match must be **exact on the
  listing's path field**. A substring match let `x.tar.gz.sha256` stand in for a missing
  `x.tar.gz`. A name stripped of its folders would never match the nested
  `pvc/<timestamp>/<namespace>/<file>` layout. If any file is missing, the script reports it and
  runs `exit 1` **without** deleting the source copies. If the list of expected files is empty or
  too short, a second check stops the script, because the comparison could then miss a missing
  backup. That check takes the count from a shell variable, not by reading a file again,
  so the expected count cannot fail in the same way as the listing it checks.
- **Replication reported failures as success.** If `OVERALL_OK != true`, the script sent a Telegram
  message but never exited with an error code. So the `kube_job_*` metrics showed success, and no
  alert that reads the Job status fired. The listings for the retention sweep (deleting old backups)
  and for the NAS size also hid failures. The script used `set -e` without `pipefail`, and those
  pipelines ended in `awk`, so a failed listing read as **0 GB**. That value looks the same as a
  healthy, empty NAS, so the 400 GB and 450 GB alert levels could never fire.
- **PVC backup.** If a critical PVC (persistent volume claim: the storage a pod asks for) was
  empty, the script ran `continue` and counted no failure, so the Job reported success for ever.
  The script now counts it as a failure. That matches the reason the script itself gives in the
  branch next to it, which handles a missing PVC.
- **17 PVCs in 12 files now carry the annotation** `kustomize.toolkit.fluxcd.io/prune: disabled`,
  which tells Flux not to delete them. The `local-path` storage has reclaimPolicy **Delete**
  (checked on the live cluster). A Kustomization is the Flux object that applies one folder of
  manifests. If these annotations were absent and a Kustomization were renamed or removed, the
  data would be deleted with it.
- **The mysql backup client moved 8.4.8 → 8.4.10** to match the server,
  `percona-server:8.4.10-10.1`. The Renovate rule for the client had been `enabled: false` for all
  updates, which is how the client fell behind. It is now `allowedVersions: "/^8\\.4\\./"`. The
  codemap (the repo's map of a subsystem) now gives `startingDeadlineSeconds` as 3600, not 600,
  because all three CronJobs set 3600.

The checks went further than a passing CI run, because CI cannot see the shell scripts embedded in
CronJob manifests at all:

| Check | Result |
|---|---|
| meaning of `:t` and `:d` | read from the IBM/couchbackup source |
| completeness check (awk) | tested on 6 sample inputs, **then run again with busybox awk inside the real `node:24.18.0-alpine` image** |
| pinned couchbackup | installed in that image |
| NAS matching | tested against a realistic rsync listing, including the case where a checksum file stands in for its missing backup |
| `flux diff kustomization apps` | the annotations change 17 objects and no others, with no create, delete or replace |
| shellcheck on the extracted embedded shell, compared with `main` | the same number of findings |

Two bugs in the new code showed up only when it ran:

- `$(grep -c … || echo 0)` captures *both* outputs. The result is `0\n0`, which busybox `test`
  rejects as a bad number, and under `set -e` the script stops.
- A blanket `|| true` on the JSON filter hid a grep exit code of ≥2 (a real I/O error) as well as
  the intended exit 1.

Codex ran a static review (it read the diff and ran nothing) for 3 rounds, which reached the round
limit:

| Round | Findings |
|---|---|
| R1 | BLOCK, 3 HIGH: an empty database was rejected, a wrong PVC path, substring matching |
| R2 | HIGH and MED: the filter hid errors, and the expected list could be empty |
| R3 | no HIGH or CRITICAL; one MED, fixed anyway |

### 2026-07-24 — Ultrareview fixes, batch 1: CI validation coverage

This batch closed the gaps that let changes ship without validation. It ran before the fix
batches, because those batches edit `clusters/` and `immich-vm-heal.sh`, and CI checked neither.

- **kubeconform now also checks `clusters`**, so its list of kustomize roots (the folders
  kustomize builds from) grew from 6 to 7. No
  schema check had ever covered the Flux Kustomization custom resources. The check is structural
  only. The custom resource definition types the entries of `healthChecks` and `dependsOn` as plain
  strings, so a name or GVK (group, version and kind) that matches nothing still passes. A reviewer
  still has to check those by hand.
- **shellcheck now runs over the whole repo** instead of `find scripts docs/scripts`. It skips
  `.git` and `.claude/worktrees`, and the pre-commit hook dropped the same folder limit. The run
  covered 42 files, all clean at `-S warning`. Newly covered:

  | Newly covered path |
  |---|
  | `apps/immich/gpu-node/immich-vm-heal.sh` |
  | `.backup/secrets-{backup,restore}.sh` |
  | `.claude/hooks/*.sh` |
  | `docs/worker-node-post-install.sh` |

  The change also corrected a **false comment**. The comment claimed that
  `-S warning` catches the SC2015 class (`A && B || C`). But shellcheck reports SC2015 at *info*
  level (`Analytics.hs`, `info id 2015`), so the check never saw it. The threshold stayed where it
  was: `-S info` shows 15 older findings (SC2016/2162/2086/2012) that need a separate review.
- **`check-sops-encrypted.sh` now also checks the content of each YAML document.** Before, it
  matched file names only, so a plaintext `kind: Secret` in a file with an unexpected name got
  through. Now awk splits every `*.yaml` and `*.yml` file on `^---`, and **each document** must
  contain `ENC[AES256_GCM`. A grep over the whole file would let an encrypted document 1 hide a
  plaintext document 2. The check handles these inputs:

  | Input | Handled |
  |---|---|
  | the kind in quotes | `kind: 'Secret'` and `"Secret"` |
  | a trailing `# comment` | on the kind line and on the separator |
  | CRLF line endings | yes |
  | a file that starts with the separator | documents are numbered correctly after a leading `---` |

  It ignores `kind: SecretStore`, as it should. The script ends with `exit $((missing > 0))`,
  because an exit code counts mod 256 (past its top value it starts again from zero), so a raw
  count could wrap round to zero.
- **gitleaks, the secret scanner, moved to its own workflow, `.github/workflows/gitleaks.yaml`**,
  with no `paths-ignore`. `validate.yaml` skips pushes that change only markdown, so a credential
  pasted into a runbook or plan reached main without a scan. Checkout and scan take about 15s.
- **`KUSTOMIZE_VERSION` v5.5.0 → v5.8.1.** CI had used a different kustomize than the cluster, so it
  rendered a different set of manifests from the one the cluster applies. The version chain was
  checked: kustomize-controller `v1.9.1` uses `sigs.k8s.io/kustomize/api v0.21.1`, which kustomize
  CLI `v5.8.1` also uses. v5.5.0 was pinned to api v0.18.0. **`KUBERNETES_VERSION` 1.36.1 →
  1.36.2**, to match the live cluster, as the file's own comment says to do. The v1.36.2 schemas
  were confirmed to exist upstream.

GitHub Actions runners were blocked by an account billing problem: every job had run 0 steps since
before this batch. So every CI job ran locally instead:

| Gate run locally | Detail |
|---|---|
| kubeconform | all 7 roots at the new versions: 529 resources, 0 invalid |
| shellcheck | the whole repo |
| actionlint, yamllint, init-resources, image-pin, gitleaks | |

9 tests of its behaviour proved the sops checker, not only a passing run.
Codex ran a static review for 3 rounds, which reached the round limit:

| Round | Verdict and findings |
|---|---|
| R1 | REQUEST CHANGES, 2 MED |
| R2 | CHANGES REQUESTED: the `seen` check that skips repeated files still let a secret file with an expected *name* hide a plaintext second document. That was the original bug in a new place |
| R3 | BLOCK, 3 MED: a kind line with a trailing comment, a CRLF separator, and the mod-256 exit code |

All of them were fixed and tested again. Codex withdrew one claim after it was disputed: the diff
never contained the shellcheck severity flag.

### 2026-07-24 — Ultrareview fixes, batch 0: a leaked token, the CI-gate claim, an ignore rule for DR archives

This was the first batch of the plan to fix the findings of the 2026-07-24 ultrareview, a broad
review. The plan file was removed after `d6d67c20`. The review had 58 findings,
and 0 of them were refuted. Finding H3, the exposed CouchDB, was closed the same day with
Cloudflare Access Service Auth.

- **`apps/pricebuddy/apprise-configmap.yaml`.** The apprise init script (an init container runs
  before the app starts) ended with `cat /config/pricebuddy.cfg`. That printed the Telegram bot
  token to the init container's standard output, and so into Loki, the log store. **Loki keeps
  logs for 720 h, so lines already stored hold the token for about 30 days after this fix.** The
  line is deleted, and a comment now states why, so nobody adds it back. **Decision: the token
  was not rotated.** `pricebuddy-telegram` is its own secret, separate from claude-telegram's. So
  a leak exposes only the price-alert chat, not the operations channel. The only people who can
  read the token are Grafana/Loki users, and anyone with `kubectl logs`. For Grafana/Loki,
  anonymous access, basic auth and the login form are all turned off, and sign-in goes only
  through Authentik with a passkey (OIDC).
- **`AGENTS.md` and `docs/HOMELAB_ANALYSIS.md`.** Both described CI as the "CI gate-of-record": the
  check that keeps failing changes out of production. That was false. Branch protection is not
  available: the repo is private on the GitHub Free plan, and `gh api …/branches/main/protection`
  returns 403. Flux syncs `main` every 5 min whatever CI says. So nothing automatic stops a commit
  that fails validation from reaching production. Step 3c of `/gitops-workflow` blocks `fr` when CI
  is red, but that only holds back the manual command that asks Flux to sync at once. The text now
  reads "a signal, NOT a merge gate", and it names the pre-commit review loop and
  `/homelab-yaml-validate` as the checks that stop a bad change before it is committed. **Decision:
  no `ci-green` promotion ref**, a git ref that Flux would follow and that moves only after CI
  passes. Pointing Flux at it means changing `gotk-sync.yaml`, which the Flux bootstrap generated,
  and that is the riskiest structural change available here. The static review of each batch is the
  control that has been catching defects. The same line also corrected a stale count: kubeconform
  covers 6 roots, not 5 (`validate.yaml:138-144`).
- **`.gitignore`.** Added `.backup/*.tar.gz.gpg`. `secrets-backup.sh:235` writes
  `${BACKUP_DIR}/secrets-backup-${TIMESTAMP}.tar.gz.gpg`, and it sets
  `BACKUP_DIR="$(dirname "$0")"`, the script's own folder. So each encrypted disaster-recovery
  bundle landed in a folder that git tracks, with no rule to ignore it.

Gates, all passing:

| Gate | Detail |
|---|---|
| yamllint | |
| `kustomize build` | |
| gitleaks | tree mode. History mode finds 11 values that were already rotated, and CI does not scan history, on purpose (`validate.yaml:91-96`) |
| sops-check | 57 files |
| init-resources, image-pin | |

Codex static review: APPROVE
WITH NITS. Its one nit was the root count, 5 to 6. The batch checked it against the workflow and
fixed it.

### 2026-07-23 — WARP managed-network beacon: device profiles switch between home and away on their own

Added `warp-beacon` to the `rustdesk` namespace (`apps/rustdesk/beacon-*.yaml`). It runs
`nginxinc/nginx-unprivileged:1.30.4-alpine` and serves a self-signed certificate valid for 10 years
(CN `warp-beacon.h0melab.internal`, fingerprint `4B8045EA…B2F3DF`) on **192.168.1.129:18443**. It
uses the same placement as RustDesk: the pod runs on W1 (worker-node), and the servicelb load
balancer with ETP=Local (external traffic policy Local: only the node that runs the pod accepts the
traffic) serves it from there.

| Part | Setting |
|---|---|
| private key | SOPS Secret |
| certificate and nginx.conf | ConfigMap |
| pod security | PSS restricted profile, read-only root filesystem, all outgoing traffic (egress) denied |
| ingress | 8443/TCP from the LAN only |

If a device is away from the LAN, detection must fail. So the beacon is **deliberately not
reachable through the Cloudflare tunnel**. The Cloudflare managed-networks docs say that the probe
times out after 5 s, that the device then uses the default profile, and that it does not retry.

Settings in the Cloudflare Zero Trust dashboard:

| Setting | Value |
|---|---|
| managed network **`home-lan`** | `192.168.1.129:18443` plus the pinned certificate's SHA-256 |
| device profile **"Home LAN - direct"** | precedence 1; matches `Managed network is home-lan`; its split-tunnel Include list holds only `192.0.2.1/32`, a reserved address that carries no traffic. Earlier the same day this profile matched `os == macOS` as a temporary measure; it now matches the managed network |
| **Default** device profile | precedence 2; keeps the `192.168.1.129/32` include |

The result holds for every enrolled device, now and later (a 2nd Mac, Windows). At home, WARP
tunnels nothing, and RustDesk and node SSH go straight over the LAN. Away from home, WARP tunnels the
`.129` route for remote RustDesk. This fixed a problem found the same day: whenever WARP was
Connected, the `.129/32` private-network route (teamnet) pulled SSH from the Mac to W1 into the
tunnel.

Verified end to end:

| Check | Result |
|---|---|
| beacon, from the LAN | fingerprint matched; HTTP 200 in 47 ms |
| Mac profile after WARP was turned off and on | the Mac, whose profile now matches ONLY through the beacon, still received the include list that carries no traffic. This proves that detection works |
| ping, SSH:65300 and RustDesk 21116, with WARP Connected | all passed |

Codex static review: SHIP. Two findings were accepted as risks:

| Finding | Why it was accepted |
|---|---|
| MED: a single replica | failure is safe. Devices probe only when their network changes, and if the beacon is down, devices just get the away profile and its tunnel routes |
| LOW: subPath mounts do not reload when the file changes | replacing the certificate means updating its fingerprint in the dashboard at the same time, so it is a planned event |

CI on the push showed the pattern of the billing block: all 13 jobs failed to start, with 0 steps.
The classifier script first misread it as a real content failure, because one job had no
conclusion. `ci-red-classify.sh` (in dotfiles) was fixed the same day. It now treats jobs with zero
steps as the billing block whatever their conclusion, and it exits 12 on CANCELLED. The fix took 2
Codex rounds.

### 2026-07-23 — node_isolation_heal now acts (dry run turned off after a 13-day trial) and gains safeguards

With `node_isolation_dry_run: false`, the watchdog now acts. It runs on each worker and detects when
the worker is cut off from the control plane. It had run in dry-run mode, logging what it would do,
since 2026-07-10 (`68f114d0`). It acts in two levels:

| Level | Action | Condition |
|---|---|---|
| L1 | `systemctl restart k3s-agent` | the worker has been isolated for ≥6 min |
| L2, last resort | the worker reboots itself | a different delay per worker (W1 15 min, W2 23 min); gated by the `cp_direct` check (a direct connection to the control plane's API server that skips the local load balancer: the worker reboots only if that connection fails too); at most 1 per 24 h; only if uptime is over 30 min |

**Evidence from the trial:**

| Measure | Result |
|---|---|
| length | 13 days |
| false pending actions | zero |
| give-ups | zero |

The only
`wedged=1` sample was a short event of <6 min on W1, during the phase2 reboot window on Saturday
2026-07-18. The new maintenance hold suppresses that kind of event.

Safeguards for turning it on, in the same commit:

- **phase2.yml** creates `/var/lib/node-isolation-heal/maint-hold` on the worker just before each
  planned worker reboot. It removes the file after the worker is uncordoned (allowed to take pods
  again). If the hold file is <1 h old, the watchdog skips its levels. So a hold file left behind by
  mistake expires on its own.
- **Only one script restarts k3s-agent at a time.** `clusterip-heal.sh` and
  `node-isolation-heal.sh` both take a non-blocking `flock` on the shared file
  `/var/lib/k3s-agent-restart/cooldown`. Each script holds the lock from its check, through the
  restart, until it updates the file's time. A check of the file's modification time alone left a
  window where the two scripts could interleave (review finding, HIGH). If the lock itself fails,
  the script **fails closed**: it skips that cycle, and the metrics and alerts for a cut-off node
  still fire (review R2, HIGH). `NIH_SKIP_LOCK=1` skips the lock, for the test harness only,
  because macOS has no flock.
- **New VMRules (alert rules):**

| Alert | Severity | Notes |
|---|---|---|
| `NodeIsolationHealActing` | warning | a node cut off (wedged) for more than 8 m |
| `NodeIsolationHealPendingReboot` | critical, `for: 1m` | fires only on dry-run or guard-blocked states that persist. On the real reboot path, the script sets `pending_action` to zero before it reboots. The metrics text file lives under `/var/lib`, so it survives the reboot, and a stale 2 would page twice (review R3, MED) |
| `NodeIsolationHealRebooted` | critical | the only alert for a completed self-reboot (review R1, MED). It reads a new gauge, `node_isolation_heal_last_reboot_timestamp`, which each cycle writes again from the state file on disk, so the value persists |
| `NodeIsolationHealGaveUp` | critical | |

Rollout: the Ansible part reaches the nodes through the git sync every 10 min and the drift-heal run
at 03:00 UTC. The VMRules reach the cluster through the Flux Kustomization (the object that
applies one folder of manifests) `monitoring-configs`. Gates:

| Gate | Result |
|---|---|
| shellcheck, shfmt, yamllint, ansible-lint | clean |
| tests of the levels | 22/22 |
| VMRules metric audit | the new gauge's series appears after the first run on a node. If a series is absent, the alert that reads it does nothing |

Codex ran a static review for 3 rounds:

| Round | Verdict | Findings |
|---|---|---|
| R1 | BLOCK | lock race (HIGH), alert reliability (MED), stale plan (LOW) |
| R2 | BLOCK | a fallback that failed open (HIGH), an alert that fired twice (MED), plan sections (LOW) |
| R3 | BLOCK | 1 MED: the persisted text file could make an alert fire twice; no HIGH. Fixed after the round, which reached the round limit |

Plan: `docs/plans/2026-07-10-node-isolation-heal.md` (removed after `e26a42aa`).

### 2026-07-20 — Self-hosted RustDesk server (open source) for remote desktop on the LAN

Added `apps/rustdesk/`: the RustDesk rendezvous server (`hbbs`), which helps devices find each
other, and relay (`hbbr`), which forwards their traffic, from
`rustdesk/rustdesk-server:1.1.15`. They run as 1 pod with 2 containers that share a 100Mi
`local-path` PVC (persistent volume claim: a request for disk storage). `/data` holds the ed25519
keypair and `db_v2.sqlite3`. One LoadBalancer Service carries both protocols:

| Port | Protocol |
|---|---|
| 21115 | TCP |
| 21116 | TCP and UDP |
| 21117 | TCP |

The pod is pinned to **W1**
(worker-node), so under servicelb with ETP=Local only **192.168.1.129** carries traffic. The Service
also advertises .126, but traffic sent there goes nowhere, so clients use .129. A NetworkPolicy
(a firewall rule for pods) denies all outgoing traffic (egress), because the server does not
need to open any outgoing connection. A docker test with `--network none` confirmed that.

**`-k _` is not full authentication.** The operator questioned the first description, and it was
corrected against the master source. The flag makes hbbs generate a keypair and require the matching
public key **only** on the TCP `PunchHoleRequest` path, the request to connect to a peer
(`rendezvous_server.rs:682` `LICENSE_MISMATCH`). So an outsider cannot set up a session to your
registered devices without the key. The flag does **not** authenticate device registration
(`RegisterPk`), nor the `PunchHoleSent` and `LocalAddr` handlers. Those handlers are the surface
for the CVE-2026-30784 UDP reflection attack. Session encryption runs peer to peer and does not
depend on the server key.

- **The 17th app, in a new `rustdesk` namespace.** It shipped in 2 commits. The first added the
  namespace, service account and NetworkPolicy, and then Flux had to finish reconciling it. The
  second added the workload. The reason is the problem found on 2026-07-14 with Kyverno's
  `require-networkpolicy` rule during Flux's dry run.
- **The assessment scored it GO, for the LAN only.** Access from the internet (WAN) scored 1/5.
  21116/UDP is required, and the Cloudflare Tunnel carries only HTTP, so it cannot carry that port.
  The rule of zero open inbound ports stays. The chosen path for remote access is WARP through the
  tunnel, which waits on enrolling devices in Zero Trust.
- **CVE-2026-30784** (rustdesk-server#670, still open). `hbbs` sends UDP `PunchHoleResponse`
  packets to addresses an attacker chooses, without checking a key. `-k _` does not guard
  `handle_hole_sent` or `handle_local_addr`. The maintainer's commit `80d3a505` (2026-07-01) only
  made UDP `PunchHoleRequest` unsupported (+2/−10). It does **not** touch the `PunchHoleSent` and
  `LocalAddr` reflection path. So master is **not** a real fix, and building it from source gains
  nothing. Decision: **stay on the pinned 1.1.15.** The main defence is that only the LAN can reach
  the server. The NetworkPolicy that denies all egress is a second layer: a reflected packet to an
  address with no existing connection-tracking entry is new egress, so the policy drops it.
  Renovate will offer a release that really fixes the bug when one ships.
- **Verified:**

| Check | Result |
|---|---|
| pod | 2/2 on W1 |
| load balancer IP | 192.168.1.129 |
| all 3 TCP ports, from the Mac | reachable |
| a real RustDesk client on the Mac | reached hbbs over **UDP 21116** (NAT responses on 21116 and 21115, latency 2.7ms, `register_pk` started). This proves the UDP app path and registration against the self-hosted server |

Peer review: Codex static review of the plan (2 rounds) and of the manifests (1 round, verdict SHIP,
one NIT fixed). Plan: `docs/plans/2026-07-19-rustdesk-server.md` (removed after `92a89d1d`).

### 2026-07-18 — immich-vm modprobe failure chain: kernel-modules-hook wrongly labelled AUR, and two weeks of package upgrades that failed unnoticed

The operator ran `yay -Syyu` on immich-vm and found 33 packages waiting to upgrade. That should have
been impossible on a node that the weekly upgrade covers. Four failures had built up:

- **`kernel-modules-hook` was wrongly labelled as an AUR package** (AUR: the Arch User Repository,
  packages built from source). It is in the official `extra` repository. But
  `base_config/tasks/main.yml` called it "(AUR)", and `setup-node.sh` listed it in `AUR_PKGS`. The
  install loop for that list hid every error (`2>/dev/null … || true`). When immich-vm was set up on
  2026-07-10, that step failed, and nothing logged it. Meanwhile, `phase2.yml:376` states as fact
  that "the fleet convention installs kernel-modules-hook". That was false for this node.
- **Truncated package records blocked every upgrade.** `ripgrep` (and later `zsh-completions` and
  `zsh-autosuggestions`) had zero-byte `desc` and `files` entries in `/var/lib/pacman/local/`, and
  partial `.zst` files in the package cache. So pacman could not tell that it owned the installed
  paths (`ripgrep: /usr/bin/rg exists in filesystem`). Nor could it verify the cached files: a
  truncated download fails the PGP signature check. Every `-Syu` stopped at "checking for file
  conflicts" and upgraded nothing.
- **The failure did not show.** The `yay` step in PLAY 1b sits in an Ansible rescue block with
  `failed_when: false`, so its failure does not stop the run. That is correct: a hard failure there
  leaves the `phase2-pending` marker behind, and the marker blocks drift-heal on every node (this
  happened on 2026-06-20, for ~1.7h). So phase2 recorded `failed=0 rescued=1` on both 2026-07-11
  and 2026-07-18. Telegram sent an alert both times, and nobody noticed either one.
  `NodeMaintenanceMissedRun` cannot catch this, because it tracks whether the *run* completed, not
  whether each node's packages were upgraded.
- **The manual upgrade then set off the same chain of failures as on 2026-05-02.**
  `linux-lts 6.18.38-2 → -4` ran with no hook, so `60-mkinitcpio-remove.hook` deleted
  `/usr/lib/modules/6.18.38-2-lts` while that kernel was still running, at 15:01:08. After that,
  every `modprobe` failed with FATAL (`br_netfilter not found`). ufw and k3s-agent stayed up only
  because their modules were already loaded. A reload would have repeated what happened on W1
  (worker-node): ufw turned itself off without a message, and the INPUT chain was left on DROP.
  immich-vm is the worst node for this. It never reboots from inside the guest (because of the GPU
  reset bug, rule C3), so its running kernel can stay out of step with the installed modules for a
  long time.

Fixes (`d8ecf27b`, `0fdd88f1`):

- A comparison of the packages on each node (immich-vm against W1/W2) found 19 packages that were
  installed by hand and never declared. The 13 that the official repositories carry went into
  `pacman_packages_base`:
  `arch-audit bc chezmoi duf dust fd github-cli helm kernel-modules-hook kubectl neovim xclip zoxide`.
  The file records why the others stay out. `flux-bin viddy zsh-you-should-use` are AUR-only, and
  the list holds pacman packages only, by design. `packagekit pkgstats udisks2` are leftovers from
  dependencies.
- `kernel-modules-hook` left `AUR_PKGS`, and the stale "(AUR)" comments were corrected. So the role
  now declares the hook and installs it with its retries, instead of one best-effort attempt at
  first setup.
- In `base_config`, a missing hook used to raise a `debug` warning; it now raises `fail`.
  node-config is a separate playbook from phase2, so this failure cannot leave `phase2-pending`
  stuck.
- New `tasks/pkg-upgrade-metric.yml` writes `node_pkg_upgrade_success` from all three places that
  call `yay`, into its own `.prom` file. It avoids `metrics_file` on purpose: the phase2 post-tasks
  `copy` that whole file on the control plane, which would overwrite the metric. It sets
  `failed_when: false`, so the metric can never fail the run it reports on.
- New `NodePackageUpgradeFailed` alert (`== 0` for 1h) reports package-upgrade failures on each
  node, which the run-completion alert did not. It would have fired on 2026-07-11.
- The AUR loop in `setup-node.sh` no longer throws away stderr. It collects the failures and reports
  them with a command to retry. They stay non-fatal, so an optional firmware package cannot stop the
  first setup.

Recovery, in this order:

| Step | Detail |
|---|---|
| delete the zero-byte files in the package cache | the corrupt cache was what really blocked `-Syu`. A targeted delete kept 460+ good entries that `pacman -Sc` would have thrown away for no reason |
| repair the truncated packages | `pacman -S --overwrite '/usr/*'` |
| install the hook | |
| enable the cleanup service | `linux-modules-cleanup.service` |
| power the VM off and on in a way that avoids the reset bug | a clean `poweroff`, then the `immich-vm-heal` watchdog ran `virsh start` (~2 min) |

| Check after the restart | Result |
|---|---|
| kernel | back on `6.18.38-4-lts`, with 6407 modules |
| `modprobe` | works |
| GPU passthrough | intact (`gpu.intel.com/i915: 10`) |
| immich-server | Running |
| nodes | 4/4 Ready |
| pods not Running | zero |

Before the restart, checks confirmed that every other workload on the node ran 2/2 or 3/3 with room
under its PodDisruptionBudget (PDB). A PodDisruptionBudget limits voluntary evictions, such as those
during a node drain (evicting eligible pods before node maintenance). They also confirmed that the postgres primary,
whose PDB allows 0 disruptions, runs on worker-node.

Likely cause of the truncation: `last -x` shows **8 crashes** from 2026-07-10 to 07-13, while the
VM was being built. That fits unclean shutdowns in the middle of writes (the reset bug takes the NAS
host down with the VM). This is not proven. The current boot mounted clean, with no ext4 recovery.
`/usr/bin/rg` is dated Jun 16, before the node joined the cluster, so that file likely came with the
image. To detect a repeat: `find /var/lib/pacman/local -maxdepth 2 -name desc -size 0`. Zero-byte
files alone are **not** a sign of corruption: `linux-lts-headers` ships ~10,900 empty Kconfig marker
files on purpose. The sign is an empty `desc`.

**Open:** `NodePackageUpgradeFailed` cannot fire until the metric series exists, so it does nothing
until the next scheduled run (2026-07-25 05:30). If `node_pkg_upgrade.prom` does not appear on all
four nodes after that run, the alert cannot fire and nothing reports that, so it needs checking.

### 2026-07-17 — claude-telegram 1.27.15: follow the latest Anthropic SDK, CLI and codex; audit of the tools in SDK 0.3.212

This followed 1.27.14 on the same day. The operator decided to drop the 7-day wait before installing
new releases from trusted publishers, a wait that protects against a compromised release. The SDK
tool-surface tripwire test now provides the safety: it flags the tools that a new SDK version adds.
bunfig gained `minimumReleaseAgeExcludes` for the Anthropic SDK and all 8 of its platform packages.
The 7-day wait stays for the ~117 third-party dependencies. Codex review caught 2 missing platform
names, so the list should be taken from bun.lock. The Dockerfile's codex install dropped the
`--before` gate and now installs `@openai/codex@latest`.

The SDK 0.3.212 tripwire fired on 3 new built-in tools:

| Tool | Decision |
|---|---|
| RefreshMcpTools | allowed |
| SendFeedback | denied: it publishes to an outside channel |
| ProposeSkills | denied: it could inject skills that persist |

179/179 tests passed. The image was built and pushed locally, because CI was still blocked by
billing. Checked in the pod:

| Component | Version |
|---|---|
| codex | 0.144.5 |
| engine CLI | 2.1.212 |
| SDK | 0.3.212 |

Base image review, after the user asked "does alpine still make sense?": **stay on alpine**.

- apk carries current versions of gh and chezmoi. Debian stable carries neither at a recent version,
  so a switch would bring back `curl | sh` installs.
- Every binary the image runs works with musl (Alpine's C standard library). The SDK ships a musl
  build of its engine, codex is a static musl binary, and kubectl and flux are static Go binaries.
- The compressed alpine base is 22–41 MB smaller than slim or debian.

### 2026-07-17 — claude-telegram 1.27.14: safer installs in the Dockerfile, shipped from a local build (CI blocked by billing)

A Dockerfile linter (droast) flagged the flux install, `curl | bash`: it took whatever version was
newest and piped a script into a shell. Changes in the fork (`9c56118`):

| Tool | Change |
|---|---|
| flux | pinned with `ARG FLUX_VERSION=2.9.2`, the cluster's minor version, and its sha256 is checked against the release checksums |
| kubectl | the download is now checked against its checksum |
| codex | no longer pinned. It installs the latest release that passes an `npm --before=(now−7d)` gate, and a BUILD_TS value forces that layer to rebuild. This matches bunfig's `minimumReleaseAge`. Before, the delay set in bunfig did not cover codex |
| apk | the RUN steps were merged, and a comment in the file says that the apk packages are unpinned by design |

chezmoi now installs with `apk add chezmoi` instead of `curl get.chezmoi.io | sh`.

Results:

- **Proof that the gate works:** codex resolved to 0.144.1, because 0.144.5 was 1 day old and the
  gate excluded it. The SDK resolved to 0.3.206, not the latest 0.3.212, by the same 7-day rule.
- **Shipping:** GitHub Actions was still blocked by billing (the scheduled run on Jul 16 failed in
  4s). So the release took the local fallback path, in this order:

| Step | Detail |
|---|---|
| a local copy of the CI checks | passed: typecheck, compile and 179 tests |
| build | amd64 |
| push | GHCR |
| tag | `claude-telegram-v1.27.14` |
| deployment update | `9cab06fb` |

Checked in the pod:

| Component | Result |
|---|---|
| engine CLI and SDK | engine CLI 2.1.206 with its matching SDK release, 0.3.206 |
| codex | 0.144.1 |
| flux | 2.9.2 |
| chezmoi | v2.62.5, 37 skills applied |
| bot | polling |

Codex static review: SHIP, zero findings.

### 2026-07-17 — Redis sentinel "memory leak" root-caused: operator annotation hot loop (live-object fix, no manifest change)

`ContainerMemoryNearLimit` kept firing on the sentinel pods through two raises of the memory limit
(64→128Mi `1199988d`, then 128→192Mi `57bb642a`) and a raise of the operator's CPU (`c214e0cd`).
All three treated the symptom, not the cause. The real chain of events:

- The 2026-07-03 move of the Redis resources from controllers to configs (`8595de63`/`d771464d`)
  put a temporary `kustomize.toolkit.fluxcd.io/prune: disabled` annotation on the Redis custom
  resources for 4 minutes. (A custom resource is an object of a type that an operator adds to
  Kubernetes; the opstree operator builds Redis from these.)
- The opstree operator (v0.24.0) copied that annotation to the 12 child objects it owns (2
  StatefulSets, 8 Services, 2 PodDisruptionBudgets). A StatefulSet runs pods that keep stable
  names and storage. A PodDisruptionBudget limits voluntary evictions, such as those during a node
  drain.
- After the annotation left the custom resources, the operator compared the children on every
  reconcile (each pass in which it compares the wanted state with the live objects and fixes
  differences). But its client-side merge can never delete an annotation, so no update ever reached
  the wanted state. The operator's own watch on the StatefulSet queued the object again, and that
  made a loop that kept itself going every ~3.4s. This is the "hot loop" in the heading: the same
  update repeated without end.
- Since upstream PR #1533, every sentinel reconcile runs SENTINEL MONITOR/SET/RESET without
  conditions. So each sentinel took ~25,400 RESETs a day (Loki shows 5–19 a day before Jul 4).
  Each RESET rewrote `sentinel.conf`: 1.5GB written per pod in 2.7d.
- The "leak" was ~145Mi of dentry and inode slab (kernel caches of file names and file metadata)
  in the container's cgroup (the kernel's accounting group for the container), which the kernel can
  reclaim (`memory.stat kernel`). The process's own
  memory (RSS) stayed flat at 17Mi.

Side effects while the loop ran:

| Side effect | Detail |
|---|---|
| sentinel state wiped | the sentinels' record of known replicas and other sentinels, every 3s, a risk to failover |
| needless connections from the operator to redis | ~76k a day (`pool.go:380 Conn has unread data`) |
| operator CPU | throttled |

The fix changed metadata on live objects that the operator owns and git does not hold:
`kubectl annotate … kustomize.toolkit.fluxcd.io/prune-` on each of the 12 children. The loop
stopped at once. Afterwards there were 0 StatefulSet events, 0 resets and 0 operator errors (checked
with a watch and in Loki). One problem remained: the slab that had built up is not reclaimed on its
own. So the sentinels needed a restart, one pod at a time, to clear the ~154Mi working set and the
alert. The lesson is recorded in the agent's memory, including two rules. Never run
`rollout restart` (it restarts every pod of a workload) on an opstree StatefulSet: the
`restartedAt` annotation it adds to the pod
template starts the same loop again. And if a future change adds and removes the prune annotation
on custom resources that an operator manages, it must also remove the annotation from their
children afterwards.

Closed the same day: the raises that treated the symptom were reverted (`9fe9ccb7`). The sentinel
went back to 32Mi/64Mi requests/limits and a 10m CPU request, and the operator's CPU limit went back
to 200m. Two earlier changes stayed: the 300m sentinel CPU limit from `8447338d`, set before the
loop began, and the Kyverno half of `c214e0cd`. The revert restarted the pods. After that:

| Check | Result |
|---|---|
| slab | cleared (working set 8–17Mi) |
| alert | resolved |
| sentinel quorum (the number of sentinels that must agree before a failover) | checked |
| loop | did not return |

CI failed for an infrastructure reason: a GitHub runner outage failed all jobs on all commits.
Under the gate rules, the local validation steps and the classification of the change as a
trivial revert allowed running `fr` (the command that tells Flux to sync at once). An upstream
issue went in with the full evidence and the workaround:
[OT-CONTAINER-KIT/redis-operator#1840](https://github.com/OT-CONTAINER-KIT/redis-operator/issues/1840).

Watch period until 2026-07-24:

| Measure | Value |
|---|---|
| sentinel memory | flat |
| reset rate | ≤20 a day |
| operator | not throttled at 200m |

The 64Mi limit also serves as an early warning: if the loop comes back, the alert fires again in
under a day. Operator chart 0.26.0 (2026-07-15) remains unverified for this class of bug.

### 2026-07-17 — Backup replication: the extra copy to W2 retired (the NAS is now the only target)

The temporary step that copied backups from W1 (worker-node) to W2 (the second worker) was
removed 3 days before its deadline of ~2026-07-20. It made a single-day copy with `--delete`
over SSH :65300. It was added on 2026-05-22 while the NAS target was not yet proven, and its
removal was postponed once (from 2026-05-22 +2mo). Every run since then has validated the copy to
the NAS:

| Stage | Check |
|---|---|
| before the sync, on the source | age <25h, SHA256, tar integrity, minimum size |
| after the push | verify the uploaded backup |
| retention | delete backups older than 30d, keeping at least two (keep-2) |

So the W2 copy added nothing. Its `--delete` behaviour had also already shown a risk: on 2026-07-14,
the T7 planning (the Immich backup change, below) considered how a `--delete` in one job would
interact with the W2 immich tar path of another job.

Changes in `infrastructure/configs/backup-replication/`:

| File | Change |
|---|---|
| `cronjob.yaml` | the W2 sync step and the SSH client setup removed; steps 2 to 7 renumbered as 2 to 6; `openssh-client` dropped from the apk install; the ssh-key and known-hosts volumes and mounts removed |
| `ssh-key-secret.yaml`, `ssh-known-hosts-configmap.yaml` | deleted. Flux `prune: true` removes the live Secret and ConfigMap |
| NetworkPolicy | the W2 rule for outgoing traffic (egress) to `192.168.1.126:65300` dropped |

The disaster-recovery tools changed too:

| File | Change |
|---|---|
| `.backup/secrets-backup.sh`/`secrets-restore.sh` | no longer save or restore `backup-replication-ssh-key`. The restore check now looks for `nas-rsync-credentials.json` instead |
| `.backup/README.md` | restore sources go from 3 to 2 |
| `SECRETS_ROTATION.md` | retires `backup-replication-ssh`, which was next due on 2026-12-18 |

None of this touches the weekly `immich-backup` W2 job, which stays.

### 2026-07-16 — CODEMAPS restructured: facts that go stale removed, rules for content added

A fact check found 17+ stale version pins in the codemaps (maps of the repo's code and config).
Examples:

| Codemap fact | Problem |
|---|---|
| immich version | a full major version behind |
| blocky version | 2 minor versions behind |
| loki in monitoring.md | the file contradicted itself |

Counts and "Refreshed" headers had also gone out of date. Facts copied by hand from manifests or
from the live cluster had to be updated again every time the source changed.

The restructure followed a plan that Codex reviewed (SHIP-WITH-FIXES). Codemaps now hold only
structure, relations and known problems, and every fact points to a path. The rules:

| Rule | Instead |
|---|---|
| no versions | "pinned in `<path>`" |
| no counts | grep, or ANALYSIS |
| no history of changes | nothing |

Other changes:

| File | Change |
|---|---|
| `CODEMAPS/architecture.md` | deleted, because ~80% of it repeated AGENTS.md. Its unique content moved. The list of named Cloudflare hostnames and the coredns `--disable` deadlock went to networking.md. The SOPS edit pattern and the Flux path tree went to the README index |
| apps.md | home-assistant is now marked internal-only. It is absent from the tunnel's SOPS config, but apps.md had wrongly said "both" |
| ARCHITECTURE.md:133 | 5 daily backup CronJobs are pinned to W1 (worker-node). The weekly immich-backup makes its copy on W2, the second worker, and survives the loss of W1. The line had said "all 6 on W1", which contradicted the T7 entry (the Immich backup change, below) |
| the monthly-review skill | Step 2 changed from refreshing the codemaps to verifying them: no dump of live facts, and a grep for rule violations |

Follow-ups noted at the time: several Helm chart-default images were unpinned in git (traefik, CNPG
operator, grafana, VM stack, couchdb), so they escaped both the image-pin invariant and the CI
check. And `values.image.tag: v2.7.5` in `apps/immich/release.yaml` had no effect.

Resolved the same day. Chart-default images now count as pinned through the pinned chart version.
Copying them into values would create copies that Renovate does not see, which would drift from the
chart. So AGENTS.md now states the invariant more clearly, and no pins were added. The immich tag
that had no effect was deleted, with a `helm template` proof that the render is identical (chart
0.13.1, values with and without the block).

### 2026-07-14 — trivy-scan hardening: scan timeout, Docker Hub login (and a leaked token), new schedule

Three follow-up commits after the first test runs (smoke runs), plus one security incident:

| Change | Why |
|---|---|
| **`--timeout 15m`** (`6599bb05`) | the run smoke1 scanned all 81 images, but 3 failed with FATAL. They hit trivy's default timeout of 5m per scan while it analysed layers full of `.so` files (scipy, prisma). The Job exited 1 by design, because a partial failure fails the Job |
| **Docker Hub login** (`c8ffb596` and `ca2fce4a`) | about 40/81 images come from docker.io. Anonymous use allows 100 manifest pulls per 6h per IP address, which is close to the limit for a monthly scan. The login is a SOPS Secret, `trivy-dockerhub`: a docker config that applies only to `index.docker.io`, set through `DOCKER_CONFIG`. It does not use `TRIVY_USERNAME`, which would apply to every registry. SECRETS_ROTATION gained a yearly entry for it |
| **Schedule moved from 04:00 to 08:00 UTC on the 1st** (`bb0b4621`) | 04:00 clashed with the node security scan (1st, 04:00). And if the 1st is a Saturday, the weekly upgrade and rolling-reboot window (Sat 04:30) would kill the scan partway through. `homelab-monthly-review` now records the manual run on review night and the Saturday caveat |

**Gotcha** in the Docker Hub login: the first version had an empty username (`:token`), because the
1Password field was blank. Docker's config parser then rejects the whole file ("invalid auth
configuration file"). That broke even the anonymous database downloads from mirror.gcr.io, and
smoke2 failed 81/81 within seconds.

**Incident:** during the diagnosis, the first personal access token (PAT) leaked into the agent's
transcript. The regex that should have hidden it assumed that the username was not empty. The token
was revoked and a new one issued in the same hour. The new secret ships with guards for a non-empty
username and for the rotated token's prefix.

**Proof and closure:** smoke3 finished Complete, 81/81 in 11min, logged in. Its output can be
queried in Loki (`{namespace="trivy-scan"}`). The user deleted the 12 orphaned
`aquasecurity.github.io` CRDs (custom resource definitions, which add object types to Kubernetes),
which also deleted all 88 reports. That completed the removal of trivy-operator.

### 2026-07-14 — kube-prometheus-stack upgrades stuck because Kyverno blocked the chart's hook Jobs (fixed)

An audit after the trivy-operator removal found the kube-prometheus-stack HelmRelease Stalled. A
HelmRelease is the Flux object that installs a Helm chart, and Stalled means Flux stopped retrying
it. Before an upgrade, the chart runs hook Jobs (Jobs that Helm runs at a set point in an upgrade)
that patch the certificate of its admission webhook. An admission webhook is a service that the API
server calls to check or change objects before it stores them. Those Jobs set no resource limits, so
the Kyverno policy `require-resource-limits` refused them at admission. 87.15.2 and then 87.16.0
(Renovate #920/#923) each failed 4 upgrade attempts, and Helm rolled back to 87.15.1 on its own.
This was the first denial of a chart hook since the move to Kyverno ValidatingPolicies (VP). It
belongs to the same class as the trivy-scan namespace setup below: the first time a kind of change
happened since the VP move. Side effect: the stalled release also held back the trivy cleanup in
Alertmanager (removing telegram-digest), without any sign of it.

Fix: `prometheusOperator.admissionWebhooks.patch.resources` (requests 10m/32Mi, limits
100m/64Mi) in the values of release.yaml. `helm template 87.16.0` confirmed that the hook Job
renders with limits. `.claude/review-invariants.md` gained a check for reviewers of chart version
bumps: hook Jobs need their limits set through values.

### 2026-07-14 — trivy-operator removed and replaced by a monthly trivy-scan CronJob

The always-on trivy-operator was removed after 10 days in service (installed in `dfeb0153` on
2026-07-04). It used ~650Mi of RAM 24/7 to scan images again that change only when Renovate updates
them. Its 88 VulnerabilityReports covered upstream images that this project does not own, so they
made the useful findings harder to see. The triage on 2026-07-05 found 0 findings on the project's own
images.

The replacement is `monitoring/configs/trivy-scan/`, a monthly CronJob in its own `trivy-scan`
namespace. It runs on the 1st at 08:00 UTC, clear of the node security scan (1st-04:00) and the
weekly reboot window (Sat 04:30). The monthly-review skill records the manual runs on review night.

| Part | What it does |
|---|---|
| init container `rancher/shell:v0.8.0` (it runs before the main container) | collects the set of unique images through kubectl (~80 images). rancher/kubectl is a scratch image with no shell, so it cannot redirect output to a file |
| main container `aquasec/trivy:0.71.1` | loops `trivy image --severity CRITICAL,HIGH --ignore-unfixed` over the images and prints a table per image to standard output, which Loki collects |
| failure handling | if any scan fails, the Job fails, so a partial scan never reports success |
| memory | limit 1Gi, because trivy peaks on large images |
| cleanup | `ttlSecondsAfterFinished: 86400` |
| NetworkPolicy | DNS, the API server, and outgoing traffic (egress) to registries on 443 only (the same patterns as popeye and trivy-operator) |

Removed along with it:

| Item | Kind |
|---|---|
| `TrivyCriticalVulnerabilities` | VMRule |
| `scrape-trivy-operator.yaml` | VMPodScrape |
| `telegram-digest` | Alertmanager route and receiver |
| `alertmanagerSpec.retention: 192h` | setting that existed only for the digest's 168h repeat_interval |
| `aquasecurity.github.io` | claude-telegram RBAC (role-based access control) permissions |

After Flux reconciled, the aquasecurity
CRDs and the orphaned VulnerabilityReports were deleted by hand, because helm uninstall leaves CRDs
behind.

### 2026-07-14 — Immich T7: backup redesigned (W2 makes the copy) and the W1 library PVC removed

This closed the follow-up from Path B, the design that runs Immich on a GPU virtual machine on
the NAS. It took two commits, and Codex reviewed both statically against
`.claude/review-invariants.md`. CI had been blocked by billing since 07-10, so the gates ran
locally:

| Gate run locally |
|---|
| yamllint |
| kustomize build |
| kubeconform |

- **Backup redesign (`4628800d`).** After the move to Path B, the library lives on the NAS. The old
  `immich-backup` CronJob ran in kube-system, and its nodeSelector (the setting that chooses the
  node) put it on W1 (worker-node). So it read a **frozen** copy,
  `/mnt/k8s-storage/*immich-library*`, and reported success while it backed up stale data. The
  CronJob now runs in the **`backup-replication` namespace on worker-node-2**. It pulls the **live**
  library through the NAS `personal_folder` rsync module, writes a tar archive (the files bundled into one) and its sha checksum (a value used
  to check whether the archive has changed)
  to a hostPath (a folder on the node, mounted into the pod) on W2, and pushes them to the NAS pool
  `akhozya-pool1`. That gives **two physical copies on different filesystems** (the W2 node and the
  NAS pool), each with keep-2 retention. Step 5b of backup-replication applies keep-2 to the pool
  copy. The change reused `nas-rsync-credentials` and the namespace-wide NetworkPolicy for outgoing
  traffic (0 new secret, 0 new NP), and touched only a 1-line `vmrules` description. Codex reviewed
  it in **3 rounds**. R1 found a HIGH: the final dated folder was created before the backup
  succeeded. So a partial folder would enter the keep-2 window, which sorts by name, and push out
  good copies. The same round also found a MED: `head -n -2` works only in GNU head, and under
  busybox it does nothing, so the backups would grow without limit. The fixes: write to `.wip`, then
  publish with an atomic `mv` (a rename done in one step, so the final dated folder appears only after the backup
  succeeds); delete a partial folder left in the pool; and use `sort -r | tail -n +3`. The later
  rounds:

| Round | Result |
|---|---|
| R2 | confirmed R1 **and found a new HIGH**. Step 2 of `backup-replication` mirrors to W2 `/mnt/extra-storage/backups/` with `rsync --delete`, so it would **delete the new immich copy** 30 min later. The fix writes the W2 copy to a **sibling** folder, `/mnt/extra-storage/immich-backup/`, outside what `--delete` covers. That meant zero change to the critical replication job |
| R3 | SHIP |

- **Live proof.** The moved job ran once outside its schedule. It produced a 60.6G tar on W2 and
  pushed it to the NAS pool in ~15 min. A separate `sha256sum -c` on the NAS pool copy returned OK.
  The tar holds real library content, with a sample file `./library/admin/2015/…/DSC09701.jpg`:

| Folder in the tar | Entries |
|---|---|
| `library/` | 6477 |
| `thumbs/` | 18099 |
| `upload/` | 6159 |

- **W1 PVC removed (`a32f6ef8`).** Removed `apps/immich/library-pvc.yaml` and its line in the
  kustomization file (the list of manifests to apply), after checking that no pod mounts the PVC
  (persistent volume claim: a request for disk storage). The server uses the NAS hostPath, and ML
  uses its own PVC. Flux pruned the PVC `immich-library`. Because local-path-provisioner has
  `reclaimPolicy=Delete`, it then deleted the persistent volume (PV) `pvc-495129ee` and its ~61G
  folder on disk through a helper pod, with no sudo or SSH to W1 needed.
  `existingClaim: immich-library` stays in the HelmRelease as **a placeholder that keeps the
  structure the postRenderer expects, without choosing the server's storage**. The postRenderer (a
  step that edits the chart's output) replaces `volumes/0` by its position, and removing the claim
  would change the shape of the persistence block. The comment now says so. immich-server kept
  running (1/1, hostPath). Codex, 1 round: SHIP.
- **The operator ended the watch period early, at ~40h/48h.** The backup move touches only the
  backup CronJob, not the part of immich that serves users, and it can be fully undone. The W1
  delete could not be undone. It was the one step that needed approval, and it had explicit
  confirmation. After the change:

| Check | Result |
|---|---|
| nodes | 4/4 Ready |
| alerts firing | 0 |
| immich queues | 0/0 |
| external ping | 200 |

### 2026-07-13 — node-maintenance phase2 now cold-restarts immich-vm after a kernel update

This change closed the gap in which the VM got patched but never rebooted. The phase2 rollout of
in-guest reboots leaves out the `virtual` group (immich-vm) because of the reset bug, incident C3. A
reboot inside a guest with a passed-through GPU binds the iGPU again while it is still in a dirty
state (not properly reset), and the NAS host crashes. So before this change, a kernel update only
sent the operator a Telegram alert to act on **by hand**.

phase2 PLAY 1b (`19d51c19`) now does a cold restart AUTOMATICALLY, in the order that avoids the
reset bug:

| Step | Detail |
|---|---|
| power off | a graceful `/usr/bin/poweroff` inside the guest. It equals `virsh shutdown --mode acpi`, and it is never `reboot` |
| wait for the node to leave Ready | this stands in for the "shut off" state of the domain (libvirt's name for the VM) without asking the NAS, because Ansible never touches the NAS |
| start | an early run of the existing `immich-vm-heal` watchdog cold-starts the VM with `virsh start` |
| wait for the node to be Ready | up to 7min. If the early run does not start the VM in time, the watchdog's regular scheduled run, every 5-min, is the fallback |

The steps sit in an Ansible block with a rescue section, so a stall NEVER fails PLAY 1b outright. A
failure there would leave `phase2-pending` stuck, which stalls the sync and config drift-heal
runs (the jobs that pull the repo and put each node back to its declared configuration) across the
cluster (~1.7h). A new `group_vars/virtual.yml` adds `vm_cold_cycle_force`, which forces
a cold restart for testing on demand.

- **Codex static review, 2 rounds.** Round 1 found a HIGH issue: the four inline
  `telegram-notify.sh` tasks lacked `failed_when: false`. If a notify in the rescue section failed,
  the play would fail too, and leave the same stuck `phase2-pending`. All four were fixed,
  including the older yay alert. Round 2: SHIP.
- **Both paths passed their tests**, run as
  `sudo ansible-playbook … --limit immich-vm [-e vm_cold_cycle_force=true]`. `--limit immich-vm`
  runs PLAY 1b alone. Tasks delegated to localhost or the control plane (CP) get past `--limit`,
  and PLAY 0/1/2 skip, so no worker rebooted and nothing touched `phase2-pending`.

  | Path | Result |
  |---|---|
  | without force | the gate skips: the kernel is current, so all 7 cold-restart tasks skipped, with zero downtime. `ok=3 changed=1 failed=0` |
  | with force | a full cold restart. VM uptime went from 1h12m to 2min, so the restart was real. The heal-maint Job completed 1/1 in 21s, the node was Ready in ~1min, and external requests returned 200 in ~2.5min. Assets 5791, GPU renderD129, framebuffer device (fbdev) settings intact on the kernel command line. `ok=10 failed=0 rescued=0` |

- CI has been blocked by billing since 07-10, so the checks ran locally: yamllint, ansible-lint
  with the production profile, and `--syntax-check`.

### 2026-07-12 — July overdue items closed: Kyverno CP-to-VP Phases 2-4 complete, a right-sizing pass, and failure alerts for security-scan

One pass in a worktree (`wt-overdue-closeout`; plan
`docs/superpowers/plans/2026-07-12-monthly-review-overdue-closeout.md`, removed after `fc94832c`) closed the three real
overdue items from the July monthly review. Codex reviewed every commit, statically and from git
only, against the `.claude/review-invariants.md` rubric.

**Kyverno migration done: 12 CEL ValidatingPolicies (VPs) are now the only policy engine.** The
steps ran in this order:

| Step | Change |
|---|---|
| `abf5d2c5` | switched the 12 VPs from `[Audit]` to `[Deny]` |
| Gate A | a canary dry-run deny, traced to each policy |
| deletion | the old ClusterPolicies (CPs) and the canary |
| `fc45be04` | retired the parity script and added review invariants for the VP era |

The 8-day parity soak was clean. A soak is an observation period; in this one, both engines ran and
their results were compared. A burst of breaker drops (07-07 to 07-11) ended before the switch. It
came from trivy scan jobs being created and deleted in large numbers, and from k3s reboots.

**Gate B: each of the 12 policies was traced through a live admission deny** (the API server
refusing an object because a policy failed). That needed
workarounds for three interactions:

| Interaction | Workaround |
|---|---|
| the fine-grained VP webhooks (the calls through which the API server asks Kyverno) stop at the first failure, so a deny names only the first failing policy | probe with pods that pass every other policy |
| namespaces with PSA (Pod Security Admission) enforce=restricted hide which webhook denied | probe in a PSS-privileged namespace |
| LimitRanger (the built-in step that applies a namespace's LimitRange defaults) adds default limits before the validating webhooks run, so a probe with no limits rightly passes in namespaces that have a LimitRange | probe in trivy-system |

The kyverno.io/v1 removal deadline (1.20, ~Oct 2026) is met early. Renovate's kyverno updates are
no longer held back.

**Codex catch (HIGH, confirmed live):** the autogen copies (the rules Kyverno generates for the
controllers that create Pods) rewrite `object.metadata` to `object.spec.template.metadata`. That
voids, with no warning, top-level checks such as the `skip-terminating`
deletionTimestamp matchCondition. `require-networkpolicy-vp` now matches Pods AND controllers
directly, with `autogen.podControllers.controllers: []`. The review invariants gained a new class
for this.

**Right-sizing pass (the 07-06 item).** The requests of 12 workloads went up to their 7d p95 (the
level that all but the highest twentieth of samples stay under), from VictoriaMetrics
`quantile_over_time(0.95, …[7d])`. Limits did not change. Wave 1, `d4d21e18`, covered 8 stateless
workloads:

| Workload | Request |
|---|---|
| stirling-pdf | 768 to 1408Mi |
| n8n | 256 to 448Mi |
| blocky | 128 to 256Mi |
| pricebuddy-apprise | 150 to 224Mi |
| paperless | 512 to 704Mi |
| trivy-operator | 128 to 640Mi |
| vmsingle | 512 to 768Mi |
| vm-operator | 64 to 160Mi |

Wave 2, `6cd4c036`, covered the database custom resources (CRs) and included a Percona SmartUpdate
rolling restart:

| Workload | Request |
|---|---|
| mysql | 768 to 896Mi |
| orchestrator and haproxy | cpu 50 to 160m |
| redis-sentinel | cpu 10 to 50m |

The merges went in one at a time, and every rollout reached its intended state. immich was left out
because of its Path B 48h soak. The Flux controllers were left out as a declared cut corner. Still
open: re-check the kyverno reports-controller throttling on 2026-07-13. If it is ≥0.25, raise the
limit from 500m to 800m.

**Failure alerts for security-scan (the 07-08 item, `89cd65b3`).** If lynis or rkhunter was
missing, the scan skipped it, exited 0 and reported nothing. Now it sets `FAIL=1` and ends with
`exit $FAIL`. The unit also gained an `ExecStopPost` telegram-notify that fires on any result other
than success. The search for the root cause found a wider problem. `telegram-notify.sh` and its
credentials existed only on the control plane (CP), because install.sh installs locally. So EVERY
notify path on the workers did not work. The `security_scan` role now copies the script and
`/etc/node-maintenance/telegram-{token,chat-id}` (0600, no_log) to all hosts. The change applies at
the 03:00 UTC drift-heal.

Also closed, because they were already done: the immich-backup Sunday slot was verified
(`lastSuccessfulTime 2026-07-12T03:07Z`), and the trivy #2859 soak ended (closed 07-10, with
concurrency reduced from 2 to 1). CI has been blocked by billing since 07-10, so, as the plan said,
the checks ran locally: yamllint, kubeconform ×5 roots, shellcheck.

### 2026-07-12 — Immich Path B cutover (4E): the server pod and the library moved to the immich-vm GPU node

The `immich-server` pod moved off `worker-node` (W1, AMD) onto the `immich-vm` k3s node (Meteor
Lake iGPU, Intel QSV). Its photo library moved from the local-path PVC on W1 (a PVC is a pod's
claim on persistent disk) to the NAS, through a **virtiofs hostPath** (a folder on the node mounted
into the pod: `/var/lib/immich-library` on the node, `/data` in the container). Only
placement, storage and the GPU changed. CNPG (PG18), Redis, Cloudflare Tunnel, OIDC, the Service
and the Ingress stayed as they were. This is NOT the abandoned Path A, which would have migrated the
data platform.

The commits on main ran in this order: fence (block client access) `65d5d2a7`, repoint (change
the library location) `218f8f20`, unfence (restore client access) `3b4dca01`. The
pod gets the GPU through the non-privileged **Intel device-plugin** (`gpu.intel.com/i915`, render
GID 987), with no `/dev/dri` hostPath and no privileged container. The namespace stays
PSS-privileged only for the library hostPath. A Kustomize **postRenderer** JSON patch (a change
applied to the chart's rendered output) swaps in the library volume, because the chart's schema
rejects a native hostPath library. Spec `ba250045`, plan
`docs/superpowers/plans/2026-07-12-immich-path-b-cutover.md` (removed after `865b398b`).

- **Clients were down for ≈ 13 min, not "~1 min".** The cutover blocked ALL client HTTP to `:2283`
  by removing the NetworkPolicy (NP) ingress rules for traefik and cloudflare-tunnel. Cloudflare
  reaches the pod directly and bypasses Traefik, so a block at the app level would let traffic
  through. An NP is the only block that works whatever path the traffic takes. External requests
  returned 502 for the whole blocked window, `18:22:02 → 18:34:37`. The *data move* caused no
  downtime, because the copy seeded on the NAS beforehand was current to the byte; there had been no
  uploads since Jul-2. But the *client outage* lasted the whole window, including the repoint
  (`18:24`) and the pause to decide whether to go on. uptime-kuma's health ingress stayed open
  during the block, so it would not page falsely.
- **Database and disk checked against each other after the cutover.** Every active Immich asset
  resolves to a file on the NAS-backed disk. There are `5775` active rows (5337 images and 438
  videos) and `5779` originals on disk. All 5775 `originalPath` values were checked:
  **missing=0**. The +4 extra files on disk are in the harmless direction (soft-deleted assets or
  sidecar files, which hold metadata next to a photo).
- **A transcode failure is waiting to happen: the hardware-acceleration config still points at the
  AMD device.** Immich's stored config (`system_metadata`) is `accel=vaapi`,
  `preferredHwDevice=/dev/dri/renderD128`, the render node of the AMD GPU on W1. The immich-vm pod
  exposes only `renderD129` (Intel i915), and `renderD128` does not exist there. So the next video
  job would fail to start hardware acceleration, or fall back to the CPU without warning. No
  transcode has run since the cutover (the logs are empty), so the problem has not shown up yet.

  **Fix (for the operator).** It needs a passkey. Password login is disabled, and sign-in is
  OIDC-only. In Admin, open Settings, then Video Transcoding. Set Acceleration to **Quick Sync
  (QSV)** and Preferred Device to `/dev/dri/renderD129` (or blank/auto), and Save. Then run a
  Transcode job, and confirm that the pod's ffmpeg uses `hevc_qsv` and logs no line about a
  software fallback. The cutover's test ("raw `hevc_qsv` proven in-pod") made the setup look
  ready, but that test bypassed Immich's own config path.
- **The backup CronJob is out of date after the cutover (T7).** `immich-backup` (kube-system,
  Sundays 03:00 UTC, `nodeSelector: worker-node`, so it runs only on that node) still reads
  `/mnt/k8s-storage/*immich-library*` on W1. That folder now holds the frozen copy from before the
  cutover, not the live NAS library. So the backup reports success while it saves stale data. Once
  the W1 PVC is decommissioned, it will fail visibly with `exit 1`. The next run, `2026-07-19`,
  comes after the 48h soak (observation period) and T7. **T7 must point it at the NAS library before
  07-19, using the Task 4 design in which W2 produces the backup.** The risk during the soak is
  negligible. The CronJob will not run in that window, and three copies cover the current data: the
  intact W1 PVC, the live NAS, and the tar `20260712_030000`, whose sha was verified. Uploads also
  need an OIDC login.
- A 48h stability soak is running, and it ends ~2026-07-14 18:35. T7 waits until after the soak:
  the backup produced on W2, and decommissioning the W1 library PVC and its PV `pvc-495129ee`.

### 2026-07-12 — immich-vm resilience HOTFIX: the same day's GitOps change caused two live regressions

The entry below wrote the immich-vm fixes into the repo, and that change shipped two regressions to
the live cluster. Both were caught within the hour and traced to their root cause from live data.
Codex reviewed the fixes in 2 rounds and found them CLEAN. They went forward as new commits on main
(`4ed00d33`, `327d2afa`), not as reverts.

- **`on_reboot=preserve` broke the Tier-2 watchdog on every run.** For `on_reboot` and
  `on_poweroff`, the QEMU libvirt driver supports **only `destroy|restart`**; `preserve` works only
  for `on_crash`. The generic `formatdomain.html` lists all four actions but leaves out the driver's
  restriction. So the spike (a preliminary test) and Codex both checked against the schema, not
  against the table of what each driver supports. On the NAS, the live `virsh define` rejected it:
  *"qemu driver doesn't support the 'preserve' action for 'on_reboot'/'on_poweroff'"*. The watchdog
  then failed with `define_failed` every 5 min, where before it ended `Completed`.

  **Fix:** the setting went back to `on_reboot=restart`, the libvirt default and the live value. A
  test define on the NAS returned rc=0 (success), and the next watchdog run ended `RESULT=OK`.

  Both values that QEMU supports are imperfect if an in-guest reboot slips through. `restart` gives
  C4, the iGPU hanging in place, which a NAS reboot recovers. `destroy` gives C3, a host crash when
  libvirt re-attaches the managed device. So **on_reboot cannot be the safeguard against the reset
  bug**. The real guards stay `kernel.panic=0`, the hardware watchdog turned off, and a watchdog
  that never runs a destroy (a forced power-off of the VM). The watchdog's drift marker was pinned
  again to `<on_reboot>restart</on_reboot>`. Codex's round-1 HIGH finding said not to drop the
  marker, or a regenerated XML with `destroy` would go unnoticed. `on_crash=preserve` is unaffected,
  because QEMU supports preserve there.
- **An edit to a comment failed the whole drift-heal.** The Track-2 wording fix to
  `99-zz-immich-vm-nopanic.conf` made its `copy` task report `changed`. That fired its `notify`
  handler, `Apply nopanic sysctl`, which ran `sysctl --system`. That command applies **every**
  `/etc/sysctl.d` file again. It exits rc=1 on this VM, because `kernel.nmi_watchdog` cannot be set
  there (*Operation not permitted*). So the immich-vm play failed, although the 3 override keys
  themselves applied fine.

  **Fix:** the handler now runs `sysctl -p /etc/sysctl.d/99-zz-immich-vm-nopanic.conf`, which
  applies only that file's 3 keys, all of which can be set.

  Lessons: editing *any* file tied to a `notify:` fires that handler, even if the edit changes only
  a comment. And `sysctl --system` breaks easily: one key that cannot be set gives rc=1 for the
  whole batch. The running state was never wrong: panic, softlockup and hardlockup all stayed 0.
  Nothing blocked the cluster (no `phase2-pending`), and the failure clears by itself on the next
  config run.

### 2026-07-12 — immich-vm reboot resilience written into GitOps: the fbdev hang fix and 4 tracks

This change put into the repo the fix, already proven in the field, for the recurring hard hang of
`immich-vm` (the whole VM stops responding), plus three related resilience tracks. The root cause
was tested and proven live on 2026-07-11. **The `virtio_gpu` framebuffer console code (fbdev/fbcon)
does screen-update work ("damage work"). That work blocks in uninterruptible sleep (D state) on the
stalled host virtqueue while it holds `drm_modeset_lock`. Every attempt to open a GPU device, log in
or shut down then blocks in D state too, so the VM hangs ~hourly.** The cause is NOT i915, RAM or
running two drivers. The fix is `drm_kms_helper.fbdev_emulation=0 fbcon=off` on the kernel command
line of the guest's UKI (unified kernel image). It passed a clean 12h soak, and a graceful shutdown
finished in 48s; before the fix, shutdown hung forever. The fix had been applied by hand to the live
VM. This change makes the repo match, so drift-heal keeps the fix in place. Codex's static review:
**CLEAN, no findings**.

- **Track 0 (`bf04fe36`).** The role's i915-cmdline task became general **handling of a set of
  tokens**, and it is idempotent (a second run changes nothing). It ensures
  `drm_kms_helper.fbdev_emulation=0` and `fbcon=off`, and merges `xe` into `modprobe.blacklist`,
  giving `i915,xe`. Adding xe is hygiene: that driver binds nothing. Unit tests cover the
  parser: running it twice makes 0 changes, and it never appends a value twice.

  The guest's self-heal probe is harder to break now. `qsv_probe` runs under a `timeout`, and a
  new `qsv_probe_stuck()` detector (using pgrep) emits a new `immich_gpu_qsv_stuck` gauge. For
  that, emit_metric takes a 6th argument, which defaults to 0, so existing callers do not change.
  A vainfo stuck in D state now shows up in the metric instead of piling up unseen. Before the
  fix, the self-heal probe itself did that harm.

  **Gotcha:** `expected_kernel_params` adds the fbdev and fbcon settings (live now) but
  deliberately keeps `modprobe.blacklist=i915`. base_config checks the RUNNING `/proc/cmdline`
  with `grep -qFw`, so `i915,xe` there would raise a false alert until the operator's next cold
  restart of the VM (power off, then start). `-Fw "…=i915"` already matches the future `i915,xe`
  as a substring. The role enforces the `xe` entry at the UKI *source*.
- **Track 1 (`1dee4c88`).** The role now owns the guest's `~akhozya/.ssh/authorized_keys` outright.
  The file holds the operator's zl-nas key and the automation key from the master node: the live
  set with duplicates removed. Through drift, the master-node key had appeared 3× and now appears
  once. The role checks that `~/.ssh` is 0700 and the file 0600, following base_config's
  node-maintenance pattern. This closes the onboarding gap in which "the key clears every reboot".
  The guest's `/home` is persistent ext4 on LVM, with no cloud-init. The 0771 reset on the NAS
  side stays with the operator and the appliance, outside infrastructure-as-code.
- **Track 2 (`1dee4c88` and `1fa66312`).** The role installs and enables `qemu-guest-agent`. It
  gives a reliable `virsh shutdown --mode agent`, plus domtime and domfsinfo, over the channel that
  the domain XML already had. A docs sweep removed the **nonexistent `virsh --timeout 120`** from
  the README, from phase2 (including the live Telegram alert at `:392`) and from both plans. The
  NAS runs libvirt 9.0.0, which has no such flag, so the command errored and never ran. The sweep
  also corrected the reset-bug `.conf` comments from "NAS-side virsh reset" to "NAS host reboot",
  because `virsh reset` itself triggers the reset bug (the passed-through GPU is left dirty, and
  binding it again can crash the NAS host). The standard procedure everywhere is now
  `virsh shutdown --mode acpi <dom>`, then polling domstate, then `virsh start`. If the VM hangs,
  alert and reboot the NAS host; **never destroy or reset** the VM.
- **Tracks 3 and 7 (`0df8f020`).** The Tier-2 watchdog now runs `virsh start` only if the virtiofs
  **source** (`/home/akhozya/immich/library`, a btrfs subvolume on bcache) is present on the NAS.
  After a NAS reboot that folder mounts lazily, and the mount can lose the race with autostart;
  `virsh start` then fails with "export directory does not exist". If the source is not ready, the
  watchdog skips and retries on its next 5-min run. NodeNotReady catches a VM that stays down.
  Track 7 tried `on_reboot: restart → preserve`, and it was **reverted the same day**, because
  QEMU rejects `preserve` for on_reboot (see the HOTFIX entry above). `on_reboot` stayed `restart`,
  and the watchdog gained a `<on_reboot>restart</on_reboot>` drift marker.

Deferred to a later round: Option B, which drops `<video>`/`<graphics vnc>` to make the VM truly
headless (no display device at all). An older console mismatch blocks it. The guest uses
`console=hvc0` (virtio-console), but the domain has an isa-serial ttyS0, so `virsh console` likely
does not work. Fix the console first.

### 2026-07-11 — immich-vm weekly patching did nothing and reported success (yay was never installed)

The GPU VM (`immich-vm`) had **not been patched since it joined the cluster**. It was found on
kernel `6.18.38-1-lts`, while the other nodes were on `-2`. The cause: `setup-node.sh` installs
the `yay` AUR helper once, when a physical node is built, but the VM's GPU onboarding path skipped
that step. So the `yay_cmd` in phase2 **PLAY 1b** (`sudo -u node-maintenance yay -Syyu …`) failed
with `yay: command not found`. The old rescue step retried once and then **hid** the failure. The
task reported `ok`, and the VM stayed un-updated, undetected.

The Saturday run is right *not* to reboot the VM. The VM is in the `virtual` inventory group,
which the reboot rollout leaves out because of the reset bug. So this was a gap in patching, not in
rebooting. It came to light during a check on whether the kernel-stale cold-restart alert had
fired. That task was `skipping`, because the hidden failure earlier in the run meant no update was
ever downloaded.

Two fixes, reviewed by Codex in 2 rounds:

- The **`immich_gpu_node` role** now installs `yay-bin` from the AUR if yay is missing. A
  `stat: /usr/bin/yay` check limits this to a fresh or re-onboarded VM. After that, the weekly
  `yay_cmd` updates yay itself. Building and installing are **split** into separate steps, for two
  reasons. `makepkg` refuses to run as root, *and* this same role removes akhozya's NOPASSWD sudo
  (admin parity). So `makepkg -si`, which calls `sudo pacman` itself, would hang. Instead, the role
  installs `base-devel` and `git` as root first. It then runs `makepkg --noconfirm` as akhozya,
  without `-s`, with PKGDEST and BUILDDIR pointed at a temporary folder. Last, it runs `pacman -U`
  on the built package as root.
- The **phase2 PLAY 1b rescue** no longer hides the failure. It retries once, in case the error was
  temporary. If the retry also fails, it sends a `telegram-notify` message. It deliberately does
  **not** raise the failure again. A failed play would leave `phase2-pending` in place, and that
  marker blocks the sync and config drift-heal runs on every node, as in the ~1.7h stall of
  2026-06-20. A failure that did nothing and raised no alert now sends one.

Codex round 1 caught a **HIGH** finding. The first check used
`ansible.builtin.command: command -v yay`. `command` is a shell builtin, and that module runs no
shell, so it cannot reach the builtin. With `failed_when: false`, the check read "missing" every
time, so every drift-heal would have rebuilt yay. The check now uses `stat`. The review also noted
that the VM's `akhozya` admin user had **no** authorized key, an onboarding gap with the same cause.
The key was added outside the normal automation, through the `node-maintenance` identity.

### 2026-07-11 — Tier-2 host watchdog for the Immich GPU node (Path B self-heal for the VM underneath)

This change added the **Tier-2 host VM watchdog** for the Immich GPU node (`immich-vm`, the Arch
k3s worker on the zettOS NAS). New under `apps/immich/gpu-node/`:

| Object | Detail |
|---|---|
| CronJob `immich-vm-heal` | in the immich namespace, every 5 min. nodeAffinity (a rule on which nodes may run a pod) `homelab/gpu NotIn intel` keeps it OFF the node it heals |
| a **dedicated** `immich-vm-heal` ed25519 key | stored with SOPS (encrypted in Git) |
| an egress (outbound traffic) NetworkPolicy for the Job only | allows only the NAS at `192.168.1.136:56634`, and DNS |
| a NAS known-hosts ConfigMap | pinned |
| VMRule group `immich-gpu-node-alerts` | `ImmichVMHealJobFailing` and `ImmichVMHealStale` |

The heal script (`immich-vm-heal.sh`) is a non-root POSIX sh script. It runs on
`alpine/git:2.54.0` because that image already contains ssh. It connects to the NAS over SSH and
drives `virsh -c qemu:///system` to keep two things true:

- The domain stays **defined from Git**. The script checks chosen markers for drift: machine=q35,
  memfd, virtiofs, the MAC, the full iGPU PCI source address
  `domain='0x0000' bus='0x00' slot='0x02' function='0x0'`, and managed='yes'. It does NOT compare
  bytes, because libvirt writes runtime addresses back into the XML it outputs, and a byte
  comparison would report false drift.
- The domain stays **running**. `virsh start` on a `shut off` domain gives the iGPU a clean cold
  reset. This IS the VM's autostart, because the built-in and UI autostart are OFF by design.

This watchdog is the lasting answer to the cold-restart gap proven live on 2026-07-10, when the NAS
lost power and the VM did not start again on its own.

**Safety (incident C3):** the script NEVER runs `virsh destroy` and NEVER restarts a *running*
domain. A forced destroy of a VM with a passed-through GPU hands the iGPU, still in a dirty state,
back to the host's i915 driver, and the NAS host crashes. If the guest hangs but still runs,
`NodeNotReady` and the operator deal with it. The change also hardened the canonical domain XML:
`on_crash: destroy → preserve`, which Codex caught. With `destroy`, a guest crash would tear the
domain down, handing back the dirty GPU in the same way. It would also leave the domain `shut off`,
so the watchdog would start it again automatically. `preserve` keeps the domain `crashed`, which
only raises an alert.

**Pod hardening:** the immich namespace is at the PSS (Pod Security Standards) level `privileged`,
but `require-non-root` (Kyverno, Enforce) does NOT exclude it. So the watchdog runs locked down:

| Setting | Value |
|---|---|
| user | non-root |
| Linux capabilities | ALL dropped |
| root filesystem | read-only |
| seccomp (a filter on the system calls a process may make) | set |
| service account | its own |
| egress | tight |

The NAS key arrives as a secret in an environment variable. The script writes it to a `0400` file it
owns, in the HOME emptyDir (a scratch folder that lives as long as the pod). A secret *volume* would
mount the file owned by root, and a non-root process cannot fix its permissions for sshd
StrictModes. Alerts come from the VMRule, which watches Job status, not from a curl inside the pod.

**Review:** 3 static Codex rounds, ending in SHIP. They raised BLOCK findings on on_crash and on the
precision of the hostdev source, and WARNING findings on the absent() branch and on `for:10m` for
the Stale alert. The review also corrected the NAS SSH port in the design doc from 65300 to
**56634**. 65300 is the SSH port of the k3s nodes; the NAS *host*'s admin sshd listens on 56634.

**Go-live steps (for the operator, pending):**

- Append the dedicated public key to `~akhozya/.ssh/authorized_keys` on the NAS:
  `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE2Z/KV9tk+ceo5Pu50nAX5zOp3bbAyKIYOs3eW442eo immich-vm-heal@homelab`
- Run `virsh -c qemu:///system define` once with the hardened XML, so the live domain takes
  `on_crash=preserve`.

Until the key is added, the Job fails without touching the VM: it reports `ssh_unreachable`, and
ImmichVMHealJobFailing fires. That is the correct signal. The Tier-1 self-heal inside the guest
shipped earlier, in Step-4. The last Path-B piece is 4E, moving the Immich pod, and it still needs
design approval first.

### 2026-07-10 — A UFW reload cut W2 off for 90 min; the reload is now conditional, and a node_isolation_heal watchdog exists

**Incident:** the firewall role's pre-heal step ran `ufw reload` on every drift-heal, with no
condition. On worker W2's Realtek r8169 NIC, the reload dropped the tunnel between k3s and the
control plane (CP). The node stayed NotReady for 90 min and did not answer SSH. The kernel stayed
alive: the firewall had cut the network, the machine had not crashed. Recovery needed a manual
power cycle. W2 and the NAS have Realtek NICs, and the CP and worker W1 have Intel igc. Only W2
loses the race between the reload and the tunnel.

**Fix** `ff2b486b`: the reload now runs only if `repaired>0`, checked live.

No existing self-heal caught this state: isolated from the network, UFW active, agent process up. So
a new **`node_isolation_heal`** role (`68f114d0`) runs on the workers only, and it ships in DRY-RUN
mode (it reports the actions it would take, without taking them). It probes the tunnel to the CP and
escalates in steps:

| Step | Action |
|---|---|
| L1 | restart `k3s-agent` |
| L2 | the node reboots itself, staggered: W1 at 15 min, W2 at 23 min. No node leads, and the stagger keeps both workers from rebooting together |

The role has three guards:

| Guard | Rule |
|---|---|
| boot loop | a minimum uptime |
| reboot limit | ≤1 reboot per 24 h |
| maintenance hold | maint-hold |

22 tests cover the steps. Follow-ups after the soak:

| Follow-up |
|---|
| wire up the maintenance hold |
| a shared cooldown |
| VMRules |
| switch dry-run off |

### 2026-07-10 — immich-vm joined k3s as the 4th node, a GPU worker

Path-B STEP-4: the Arch VM on the NAS (`immich-vm`, 192.168.1.231, Intel QSV through GPU
passthrough) joined the cluster as a `k3s-agent` worker. It is the node that immich-server moves
to; that move finished on 2026-07-12 (see above). The VM joined Ansible node-maintenance through the
`immich_gpu_node` role. It is in `workers`, for k3s and clusterip_heal. It is also in `virtual`,
which leaves it out of in-guest reboots and node_isolation_heal because of the GPU reset bug. Node
counts now read 4 nodes (3 physical + 1 VM).

### 2026-07-10 — k3s patch v1.36.1 → v1.36.2, and trivy scan concurrency cut from 2 to 1

**k3s patch upgrade.** The cluster went from `v1.36.1+k3s1` to `v1.36.2+k3s1`, a patch release
within the same minor version on the stable channel. The `k3s-upgrade` skill swapped the binary. It
copied the new binary to all 3 nodes, checked each copy against its sha256, and kept the old binary
at `k3s.prev`. The approved rolling restart then started the new version one node at a time: the
control plane first, then the workers W1 and W2. Workloads saw no disruption, and the upgrade took
~10 min. There is no repo commit, because k3s is a binary installed by hand at `/usr/local/bin/k3s`,
and neither Flux nor pacman manages it. To roll back, copy `k3s.prev` back into place; a patch-level
change reverses cleanly. Delete `k3s.prev` after ~1 week of stable running.

**trivy `scanJobsConcurrentLimit: 2 → 1`** (`5a882546`, CI green). Codex did not review it,
because the change tunes a single integer and touches no known class of bug. The upgrade's rolling
restart made trivy rescan every workload in the cluster. That rescan set off a burst of errors from
the upstream bug #2859, a lock on trivy's shared file-system cache
(`cache may be in use by another process: timeout`). Errors peaked at 33 per minute. The same
errors, recorded on 2026-07-05, fix themselves: they stop on their own, and trivy still produces
its reports. But a concurrency of 2 was not low enough to stop them after a reboot. Running
scan pods one at a time (limit=1) cut the error rate after the restart to ~0.

The cost is that a rescan of every workload now runs one pod after another, so it takes longer.
That is acceptable for 93 workloads. Pod-level concurrency cannot fix contention between the
containers *inside one pod*, which #2859 also covers. Examples are grafana and its sidecar (a
helper container in the same pod), and home-assistant's three init containers (containers that run
before the app starts). A limit of 1 removes only contention between pods. The `k3s-upgrade` and
`cluster-reboot` skills now describe this effect in their verification steps, so that the short
burst of scan-pod errors is not investigated again as damage from the reboot.

### 2026-07-06 — rebuilderd, the reproducible-build farm, removed from the cluster

The change removed rebuilderd and `archlinux-repro` from both workers. The removal covered:

| Removed | Detail |
|---|---|
| packages | the installed packages |
| systemd units | all of them: worker, metrics, watchdog, boot timer, repro-cleanup, sync |
| caches | `/mnt/*/repro` and `/mnt/*/rebuilderd-worker` |
| metric | the node-exporter textfile metric |
| Ansible role | `rebuilderd` |
| alert rules | the `rebuilderd-alerts` VMRule group |

Every exception or looser threshold that rebuilderd had forced into the node alerts went too:

| Alert | Change |
|---|---|
| `CPUThrottlingHigh` | exclusion for the workers dropped |
| `NodeMemoryMajorPagesFaults` | exclusion for the workers dropped |
| `NodeHighIOWait` | 15%/15m before, 10%/10m now |
| `NodeDiskIOSaturation` | 20/1h before, 10/30m now |

The `rebuilderd-progress` Claude skill, kept in a separate chezmoi repo, was retired at the same
time.

**Why:** the build farm kept overloading worker-node-2 and disrupted workloads on the same node that
need fast responses. In the 2026-07-06 incident, load reached ~11 and the node thrashed 7.6 GB of
swap (repeatedly moved memory pages between RAM and disk). `cicc`/`nvshmem` hit 17 out-of-memory
(OOM) kills inside their cgroup (a group of processes whose resource use the kernel tracks and
limits). Those kills starved the node's DNS and flannel (pod network) path. The MySQL replica on the
same node then lost DNS (`-2` NONAME). Its replication IO thread used all 3/3 retries and stopped.
That raised `StatefulSetReplicasMismatch` and `MySQLReplicaExporterDown`, and neither clears on its
own.

The incident belongs to the same class as the earlier ones in which OOM kills stopped the MySQL
pod. Those incidents forced `MemoryMax` down from 18G to 8G (2026-02-21, 04-26, 05-22). The repro
cache also caused the recurring DiskPressure on W2 (the state Kubernetes sets when a node runs low
on disk). Repeated resource tuning had stopped being worth the build work the farm did with
otherwise idle capacity.

A one-shot `rebuilderd_teardown` Ansible role did the removal. It ran as part of the workers'
drift-heal (the run that puts each node back to its declared configuration), and was itself removed
after the nodes checked clean. Plan: `docs/superpowers/plans/2026-07-06-rebuilderd-removal-plan.md` (removed after `04b30edc`).
Codex reviewed it and returned SHIP-WITH-FIXES; every fix was applied.

### 2026-07-05 — trivy CVE triage: unfixed CVEs ignored, a weekly digest, and 3 upstream issues

A CVE is a publicly listed security flaw. This was the first real triage (sorting each finding by
what can be done about it) of the 21 `TrivyCriticalVulnerabilities` alerts; trivy-operator was
installed 07-04. **0 were on our own images** (claude-telegram-bot is clean); all were in
3rd-party images. ~90% are CVEs in the base operating system or in system libraries (perl, glib,
zlib, mesa, sqlite, mariadb-client, the Go standard library, chromium, kernel-headers). The same
CVE recurs across 12+ unrelated images because they share base layers. Nothing can be done about
those here: only a rebuild of the Debian or other base image fixes them. Dependencies that an
app's maintainer could fix sit in only 4 apps. A newer image fixes none of them, because all of
those apps are already pinned to their latest release.

**Filed 3 upstream issues.** For each, the version in use was checked to be below the fix, with no
existing issue tracking it:

| Project | Issue | Content |
|---|---|---|
| paperless-ngx | #13092 | Django 5.2.7 → 5.2.8, CVE-2025-64459 (SQL injection); nltk 3.9.2 → 3.9.3, CVE-2025-14009, **CVSS 10.0** (the top severity score) zip-slip (an archive entry writes outside its target folder) |
| linkwarden | #1733 | indirect dependencies fast-xml-parser, shell-quote and i18next-fs-backend. handlebars is already tracked by upstream Dependabot PR #1654. vitest runs only in development, so it does not apply |
| uptime-kuma | #7572 | protobufjs 7.2.6 → 7.5.5, CVE-2026-41242 |

The form-data CVE in audiobookshelf is an accepted risk and was not filed. It comes in indirectly
through the old axios 0.27.2, and the maintainer declines to bump dependencies for single CVEs
(closed #5182).

**Shipped** (`e0756d47`, CI green, Codex-reviewed), in two parts.

First, `trivy.ignoreUnfixed: true` drops base-OS CVEs that have no patch. Critical reports went
from **28 to 14** (checked):

| Image | Critical report |
|---|---|
| authentik, cnpg-postgres, cnpg-pgbouncer, immich ×2, python-slim | cleared |
| uptime-kuma | shrank from 126 to 71 |
| paperless | shrank from 35 to 8 |

Second, the alert moved to a less urgent receiver, a **weekly `telegram-digest`**:

| Setting | Value |
|---|---|
| format | compact HTML, 1 line per image |
| length | capped at 25 lines, to fit Telegram's 4096 limit |
| grouping | `group_by:[alertname]` |
| repeat | `repeat_interval:168h` |
| count per image | carried by the `critcount` annotation |

`alertmanagerSpec.retention:192h` is required. Without it, Alertmanager's
notification log (nflog) drops entries after its default 120h, so the 168h repeat would be cut
to ~5d. Codex caught this. The digest uses Telegram's HTML parse_mode, not MarkdownV2, because CVE
IDs and version tags are full of dots and dashes. If MarkdownV2 escaping misses one of them,
Telegram rejects the message with a 400, and the digest is not delivered, with no warning.

**Decision:** trivy keeps scanning the **whole cluster**, not only our images. What it adds over
Renovate (the bot that proposes version updates) is finding fixable CVEs in 3rd-party images whose
latest release we already run. Renovate cannot see those; the paperless nltk CVE, CVSS-10, proved
it. We build ~1 image, and the CI in that image's own repo can scan it.

**Gotcha:** do not delete many VulnerabilityReports (the objects in which trivy stores scan
results) at once to force a rescan. Deleting them drops
the metric, so the alert resolves. The re-created reports then start the `for:6h` wait again, so no
digest goes out for ~6h. The deletion also sets off the burst of cache-lock scan errors from
upstream #2859 (`cache may be in use by another process: timeout`) on pods with several
containers. Both problems fix themselves, because the retries eventually succeed. To force a
rescan, restart a single workload pod instead.

### 2026-07-04 — Monthly review and the first quarterly automation audit

A posture sweep (a check of the overall state of the cluster) ran as 3 parallel agents (cluster,
nodes over SSH, GitHub) and found **no FAIL findings**:

| Area | Result |
|---|---|
| Flux | 7/7 |
| CI | green |
| Certificates | 19/19 |
| Backups | zero failed jobs |
| Disks | healthy (worker W2 extra-storage 28%) |
| node-maintenance | every run succeeded; updates 0 (the weekly run rebooted every node that morning) |
| Popeye (a tool that scans the cluster for misconfigurations) | A (90) |
| Pull requests | none open |
| Rotations | none due before 2026-10-01 |

Shipped (commits `e78a033f`, `492911f9`, `eb0774b7`):

- **Kyverno soak, day-0 findings.** Kyverno is the policy engine that checks resources against
  rules. Each old ClusterPolicy (CP) now has a ValidatingPolicy (VP) twin, and both run side by
  side (see the next entry, on the migration). On day 0 the side-by-side run already caught real
  classes of difference:
  - The `require-networkpolicy` VP twin had `autogen: controllers: []`, set on a wrong premise.
    Autogen is Kyverno's automatic copy of a Pod rule onto the controllers that create Pods. Live
    policy reports (polr) prove that the CP's autogen is active; the CP excludes only
    namespaces. The twin now has autogen enabled, and `npcount` now uses `request.namespace`. The
    reason: the autogen copies rewrite `object.metadata` to the template's metadata. A live check
    confirmed that request.* is filled in background reports.
  - **Kyverno turns autogen off for rules that carry a label selector** (a filter on an object's
    labels). The 5 CPs that exclude by label selector (resource-limits, readonly-rootfs,
    drop-all-capabilities, privilege-escalation, host-namespaces) report on Pods only, across the
    whole cluster. They never checked controllers. Their CEL twins do, because matchConditions are
    not selectors. The stronger check is deliberate, and it stays.
  - The stronger check caught its first problem. The mysql-monit sidecar (a helper container in
    the same pod) of `main-mysql-haproxy` had no limits in its Pod template. It ran on the
    LimitRange defaults of the databases namespace (the limits a namespace gives any container that
    sets none), 1cpu/1Gi, which the CP could not see. `sidecarResources` in the Percona custom
    resource (CR) now sets them (20m/32Mi–200m/128Mi), and haproxy restarted cleanly.
  - `kyverno-vp-parity.sh`, the script that compares the results of the two engines, was reworked:

    | Change | Why |
    |---|---|
    | vp-canary excluded | it differs by design (structural) |
    | VP-only groups whose results are all SKIP filtered out | the reports differ in shape: a CP exclude leaves no row, and the twin's matchCondition leaves a skip row |
    | new **Class 2e** | prints fail and error results that come from the stronger coverage |

    Live results after the fixes:

    | Class | Count | Note |
    |---|---|---|
    | class1 | 0 | |
    | class2 | 125 | all networkpolicy, CP-only; clears as the twin's autogen reports regenerate |
    | 2e | 1 | mysql-monit; clears on the next rescan |
    | class3 | 0 | |

- **Alertmanager high availability (HA) did not work.** vmalert's `notifier` held a single
  Service URL, which sent every alert to one endpoint. alertmanager-0 held no alert state at all,
  not even Watchdog. vmalert now uses `notifiers[]` with the full DNS names (FQDNs) of both pods,
  and the gossip between the Alertmanager pods (the way they share state) removes duplicates. A
  check confirmed that AM-0 now receives alerts.
- **A claim about n8n's statement_timeout proved false.** A community report, n8n#25705, said the
  problem was fixed in ≥2.17.3. On that basis, `DB_POSTGRESDB_STATEMENT_TIMEOUT=0` was removed as a
  trial. Version 2.28.6 then crash-looped (crashed and restarted again and again) with
  `unsupported startup parameter: statement_timeout`. The old pod kept serving, so there was zero
  downtime. The removal was reverted with this evidence, and the workaround stays.

Investigated, and closed without code:

- **Redis master on W2.** The master had drifted off its pinned node with no alert. 3 sentinel
  failovers were each undone, because the ot redis-operator records `status.masterNode` and repairs
  the topology back to it. A pin set through sentinel (the Redis component that runs failovers)
  alone no longer holds. Replication is healthy, and apps are unaffected because they use a Service
  that follows the master. The W2 flannel issues were resolved 06-05. So the drift is **accepted**,
  and the db-primary-pin caveat was updated.
- **immich-backup missed its 06-28 slot.** The miss happened before the hardening, under
  `startingDeadlineSeconds: 600` (how many seconds late a CronJob run may still start). A manual
  make-up run went at 06-28 13:57. The deadline is now 3600. Check that the 07-05 03:00 UTC slot
  fires.
- **rkhunter suspects rose from 27 to 50 on all 3 nodes at once** (rootkits 0; warnings +25, the
  same on each node). The cause was drift from rkhunter's file baseline after the update.
  `--propupd` and a rescan ran the same day in the operator's terminal. The property-change
  warnings cleared. The remaining 7 per node are a permanent set of known noise, identical across
  nodes:

  | Item | Warning |
  |---|---|
  | egrep, fgrep, ldd | replaced by scripts |
  | SSH Protocol | legacy check |
  | /etc/.updated, krb5 man | hidden files |

- Upstream re-checks:

  | Item | Status |
  |---|---|
  | authentik client-hints | shipped in 2026.5.0. We run 2026.5.3, and passkey-first sign-in has worked well for a month, so the watch is closed |
  | k8s-sidecar#531 | open, so the loki probes (the health checks Kubernetes runs on the pods) stay disabled |
  | Stirling#6211 | open; PR #6475 unmerged. Fine on 2.11.0-fat |
  | passkey lockout watch | closed; no edge cases |
  | UR2 vmalert watch | closed: 129 rules, 0 unhealthy, no bursts of false positives |

- The 16:01 Flux alert for the linkwarden webhook was transient. It fired during the disruption from
  a no-op kyverno Helm v23 upgrade (Flux 2.9.0 controllers restart). The apps Kustomization (the
  Flux object that applies the apps) recovered in the same cycle.

**Quarterly automation audit** (first run). It listed 20+ automations, and all run on schedule. It
found three risks of an automation failing without an alert:

| Automation | Risk |
|---|---|
| security-scan service | sends no notice on failure; it is the only maintenance unit without ExecStopPost (a command systemd runs after the service stops). A fix is queued |
| repro-cleanup, k3s-image-gc | alert only through the disaster they exist to prevent |
| rebuilderd textfile metrics | need a check for a staleness guard |

"Kyverno digest CronJob" was struck from the checklist: the digest is the VMRule
`KyvernoPolicyViolationsDailySummary`, not a CronJob.

**trivy-operator shipped the same day** (`dfeb0153`, chart 0.33.2, app 0.31.2). Its settings:

| Setting | Detail |
|---|---|
| node-collector and compliance | off, because of hostPath (a folder mounted from the node) and missing resources keys |
| scan-job label | `app=trivy-scan-job`, in string form (see below) |
| container securityContext (the container's security settings) | pinned |
| scan-job priority | homelab-batch |
| NetworkPolicy | default-deny, plus the registry-egress class (outbound traffic to image registries) |
| monitoring | VMPodScrape and the TrivyCriticalVulnerabilities VMRule |

The label must be a string, because the chart renders the key with a bare `| quote`. A map there
stops every scan job with no error; a reviewer caught this as CRITICAL. A scan-stalled alert was
deliberately not shipped: its metric would have been a guess, and an alert on a guessed metric
belongs to the class of alerts that can never fire. The first sweep produced 19 reports within
minutes, with 26 Critical CVEs (publicly listed security flaws) to triage. Pods with several
containers hit the upstream #2859 race on the shared cache lock, and trivy-operator's retries
eventually succeed. The k8s-devops-reviewer agent did the review, because Codex had hit its quota.
The same pass found and fixed a bug in validate.sh's name-to-file mapping for clusters.

Decisions:

| Topic | Decision |
|---|---|
| image CVE scanning | **trivy-operator in the cluster** (shipped the same day, above) |
| CSP (Content Security Policy) Tier B/C | continue, checked app by app in a browser |
| POP-1100/1110 on the mysql-primary Service | accepted as an operator cosmetic issue; dropped from the monthly checks |
| moving rebuilderd off W2 | deferred (28% disk) |

Skill stocktake: 6 stale skills were fixed (csp-reporter references, the retired
`validationFailureAction` column, the `clusters/staging.yaml` default, an Ansible role path, a
reference to the PENDING table).

The claude-telegram bot's restart message said CLI 2.1.197, while the local CLI was 2.1.201. The
investigation found three CLI copies with different versions:

| Copy | Version | Detail |
|---|---|---|
| (1) the **actual engine**: the binary bundled in `@anthropic-ai/claude-agent-sdk-linux-x64-musl` | frozen at **2.1.119 (2026-04-23)** | package.json pinned `^0.2.119`, and a caret on a 0.x version blocks minor bumps; npm's latest was 0.3.201. The Dockerfile also ran `bun install` against the committed `bun.lock`. So the bi-weekly image rebuild, whose BUILD_TS value forces a fresh build, refreshed **nothing**. The "dependency refresh" had done nothing since the lock file was committed |
| (2) the version in the restart report | 2.1.197 | it came from `npx @anthropic-ai/claude-code`, which read a stale `~/.npm/_npx` cache on the PVC, the pod's persistent disk |
| (3) the image's global npm install | 2.1.201 | it was **hidden by the PVC mounted at `/home/akhozya`**. Nothing could reach it at runtime, so it only added weight. It also caused the `EBADENGINE` build warning about node 20 versus 22 |

The fix is fork commit `2308383` and image 1.27.4:

| Part | Change |
|---|---|
| package.json | now pins `^0.3.195` |
| Dockerfile deps stage | runs `bun update`, which moves past the lock file within the version ranges on each rebuild. It also gains `COPY bunfig.toml`, so the 7-day `minimumReleaseAge` supply-chain delay on new releases is now in the build context |
| global npm CLI install | deleted |
| deployment init `CC` | points to the musl binary bundled with the SDK. The engine and the CLI that syncs plugins now use the same binary |
| restart message | reports that binary's version |

SDK 0.3.X bundles CLI 2.1.X: each SDK release bundles the CLI release with the same X.

**Still open:** in CI, `bun update` resolved 0.3.201 despite the 7d delay. Either the image's bun
predates `minimumReleaseAge`, or `update` bypasses it. For now the delay does not work in builds.
Version drift stays visible, because the restart message now reports the true version.

### 2026-07-04 — Kyverno migration from CP to VP, Phase 1: 12 CEL ValidatingPolicy twins in Audit, plus vp-canary

Kyverno 1.20 (~Oct 2026) removes the `kyverno.io/v1` ClusterPolicy (CP). This entry is Phase 1 of a
4-phase migration. Every CP now has a `policies.kyverno.io/v1` ValidatingPolicy (VP) twin with the
same name and `validationActions: [Audit]`. The twin runs next to the CP, which still enforces.
PolicyReports carry the results of both engines (`source: kyverno` versus
`KyvernoValidatingPolicy`), and `docs/scripts/kyverno-vp-parity.sh` compares them in 3 jq classes.
**Soak: 2026-07-04 until at least 07-11**, long enough to cover the weekly CronJobs. Phase 3 then
switches the VPs to Deny and deletes the CPs, in 2 gated commits.

The design was checked against the kyverno 1.18.1 source, `pkg/cel/autogen`:

| Choice | Detail |
|---|---|
| `matchConstraints` | bare Pods only. Anything more turns autogen off with no warning (the CanAutoGen check) |
| excludes | all written as `matchConditions` in CEL. Namespaces use `request.namespace`, which autogen never rewrites. Workload excludes use `object.metadata.?labels[...]`, which the autogen copies rewrite to the template labels, as intended |
| defaults | optional chaining with `orValue(<fail-value>)` gives the same result as a hard anchor in a CP (a pattern in which a missing field fails the check) |
| container sets | match each CP: ephemeralContainers only where the CP had them. resource-limits leaves out ephemeral containers, because the API does not allow limits on them |
| `require-networkpolicy` | autogen explicitly off; `resource.List` counts the NetworkPolicies; both 2026-07-03 fixes for the teardown hang carried over |
| `vp-canary` | Deny from day one, matching only `vp-canary-test=fail` pods. It is the Phase-3 Gate A proof that the VP deny path works with no CP hiding the result |

**Offline validation** with the kyverno CLI 1.18.1 ran the 12 VPs against a set of 10 test
resources. The result was error=0, and every targeted check matched exactly: autogen fires on
controllers, namespace and label excludes hold, the non-root anyPattern branches still do not mix,
and the canary stays isolated. The `require-networkpolicy` VP, run read-only against the live
cluster, gave pass=85 fail=0 error=0.

**Engine finding:** a VP emits ONE result per (policy, resource) pair, even with several
validations, because the validations short-circuit: evaluation stops once the result is known. So `require-resource-limits` reports cp=2/vp=1
by design. Class 3 of the parity script carries that exact exception, with a note inside to verify
it early in the soak. Class 1 compares the worst result from each source.

The review invariants gained a new CEL section: CanAutoGen turning autogen off with no warning, the
rewrite of object but not of request.namespace, soft-anchor behaviour (checking a field only if it
is present) returning through orValue, container sets per CP, and parity in 3 classes.

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
`prune_nas_file`. This ends the long-running build-up of empty dated folders on the NAS. File: `infrastructure/configs/backup-replication/cronjob.yaml`.

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
| Configuration files that the appliance manages | left untouched | ZettLab overwrites them on update |
| The appliance | outside the scope of Ansible, k3s and UFW | so the node-maintenance and node-fix procedures do not apply to it |
