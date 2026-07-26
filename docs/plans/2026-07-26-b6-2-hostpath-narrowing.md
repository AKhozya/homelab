# B6-2 — narrow `disallow-host-path` from namespace excludes to workload identities

Last open item of the [2026-07-24 ultrareview remediation](2026-07-24-ultrareview-remediation.md).
Deferred on 2026-07-25 because nine selectors against a Deny policy risked denying a backup Job
at 03:00 unattended. This plan replaces that soak with deterministic proof.

## The gap, measured

`disallow-host-path` excludes six namespaces wholesale. Five of them (`monitoring`, `loki`,
`databases`, `immich`, `backup-replication`) also enforce **PSS `privileged`**, because their
hostPath workloads require it. So neither layer guards them: every pod in those five namespaces
can mount any host path.

Proven by server dry-run on 2026-07-26 — an innocent running pod plus an injected hostPath
volume was **admitted** in all five, and **denied** in `home-assistant`, which is equally
`privileged` but was never excluded from this policy.

The sixth namespace, `couchdb`, **no longer exists**. CouchDB runs in `databases`.

## Assumptions

✅ verified · 🟡 single-source · ⚠️ assumption

| # | Assumption | Tier | Evidence |
|---|---|---|---|
| C1 | Exactly 8 workloads in the 5 namespaces mount hostPath | ✅ | Cluster-wide sweep of deploy/ds/sts/cronjob/job/pod templates. `intel-gpu-plugin` + `pvc-backup` are in `kube-system`, which stays excluded |
| C2 | Kyverno autogen copies `matchConditions` **verbatim** and rewrites only the validation's volume path | ✅ | Read from the live `status.autogen` of this policy |
| C3 | Consequently every exemption label must exist on the **controller's own** metadata | ✅ | Follows from C2; tested both directions below |
| C4 | The 5 backup CronJobs carry `app` **only on their pod template** | ✅ | Their own metadata has just Flux's kustomize labels |
| C5 | `object.metadata.labels[?'k'].orValue('')` is valid CEL here | ✅ | Server dry-run accepted it; a deliberately broken expression was rejected, so the check is real |
| C6 | `--dry-run=server` exercises the Kyverno webhook | ✅ | Control probe in `home-assistant` denied with this policy's message |
| C7 | PSA evaluates before Kyverno and masks it in `restricted`/`baseline` namespaces | ✅ | First probe attempt was rejected by PodSecurity, never reaching Kyverno |
| C8 | A label exemption is spoofable by anyone able to create pods in those namespaces | ⚠️ | Accepted: narrows blast radius from 5 namespaces to 9 identities, does not seal it. Sealing needs a path allowlist, but node-exporter legitimately mounts `/`, so paths buy little there |
| C9 | Jobs created from these CronJobs carry `app` on their **own** metadata by the time Kyverno sees them | ✅ | Three live Jobs have it despite `jobTemplate.metadata` being empty; `kubectl create job --from=cronjob --dry-run=server` returns it too, so API-server defaulting supplies it ahead of admission. **But only while the Job's own labels are nil** — see below |

## What ships

**1. Policy** — `infrastructure/configs/kyverno-policies/disallow-host-path-vp.yaml`.
Split `exclude-namespaces` into `exclude-system-namespaces` (the 4 system namespaces + `kyverno`)
and `exclude-hostpath-workloads` (label-keyed, per namespace). `couchdb` dropped.

| Namespace | Label | Values |
|---|---|---|
| `monitoring` | `app.kubernetes.io/name` | `prometheus-node-exporter` |
| `loki` | `app.kubernetes.io/name` | `alloy` |
| `immich` | `app.kubernetes.io/name` **and** `app.kubernetes.io/instance` | `server` + `immich` |
| `databases` | `app` | `couchdb-backup`, `mysql-backup`, `postgres-backup`, `couchrestore` |
| `backup-replication` | `app` | `backup-replication`, `immich-backup` |

**2. Five CronJob manifests** get an `app` label in **two** places, neither cosmetic:

- `metadata.labels` — required by C3, or autogen's CronJob rule denies the CronJob itself.
- `spec.jobTemplate.metadata.labels` — the Job would inherit this from the pod template anyway
  (C9), but Kubernetes only performs that copy while the Job's own labels are nil. Adding any
  unrelated label to `jobTemplate.metadata` later would suppress the copy, strip `app` from the
  Job, and deny the backup — with nothing in the diff to suggest why. Setting it explicitly
  removes the trap. Raised by Codex as "Jobs are unlabelled"; that part was wrong, the latent
  fragility is real.

`couchrestore` is in the allowlist but has no running workload: it is the one-shot DR Job in
`.backup/README.md`. A live pod scan cannot see it. Omitting it re-breaks the restore path that
ultrareview H2 closed on 2026-07-24.

## Proof

Kyverno CLI 1.18.2, offline, plus live server dry-run. Autogen rules reproduced from the live
`status.autogen` shape, so the CronJob and controller rules are the real ones.

Every check is run in **both directions** — a `skip` alone is ambiguous between "exempted" and
"never matched", so each exemption is paired with a stripped-label control that must fail.

| Check | Expect | Result |
|---|---|---|
| 5 labelled CronJobs vs autogen CronJob rule | exempt | 5 skip |
| 5 **unlabelled** CronJobs (current `main`) vs same rule | **deny** | 5 fail |
| 3 Helm controllers, real labels, vs autogen defaults rule | exempt | 3 skip |
| Same 3 with `app.kubernetes.io/name` stripped | **deny** | 3 fail |
| Both DR Jobs (`nas-fetch`, `couchrestore`) | exempt | 2 skip |
| `couchrestore` with its allowlist entry removed | **deny** | 1 fail |
| 7 exempt pod identities | exempt | 7 skip |
| 7 non-exempt pods incl. immich wrong-instance, home-assistant, n8n | **deny** | 7 fail |
| Policy CEL against live cluster | compiles | ok |
| yamllint · kubeconform · kustomize build | clean | ok |

The second row is the one that mattered: **without the CronJob label change, all five backup
CronJobs are denied at apply time** and Flux cannot reconcile `infrastructure-configs`. That is
the failure the 2026-07-25 deferral feared, and it is now excluded by test rather than by soak.

## Why no Audit soak

The deferral called for Audit → soak past a full backup cycle → Deny. A soak would have had to
span the weekly `immich-backup` (next 2026-08-02). The probes above cover every workload the soak
would have observed, including CronJobs that are not running, and cover the negative direction
that PolicyReports cannot show at all. Shipping straight to Deny.

Residual risk: a hostPath workload that exists in neither git nor the cluster. `couchrestore` was
that class and is handled; the sweep found no other.

## Rollout

1. Merge → push → `flux reconcile`.
2. Re-run the probe suite against the live policy.
3. For each of the five, run the full API pipeline — defaulting, then admission — against the
   real generated Job without creating unmanaged state. A live `create job` would fall outside
   the GitOps carve-out, which covers only the one-shot DR Jobs in `.backup/README.md`:

   ```bash
   kubectl -n databases create job couchdb-backup-admission-probe \
     --from=cronjob/couchdb-backup --dry-run=server -o yaml
   ```

   The positional Job name is required; without it the command fails before reaching admission.
   Repeat for `mysql-backup` and `postgres-backup` in `databases`, and `backup-replication` and
   `immich-backup` in `backup-replication`.
4. Confirm the next scheduled runs, all UTC: postgres 03:00, couchdb 03:05, mysql 03:15,
   replication 03:30 — nightly. `immich-backup` is **weekly, Sunday 03:00**; it last ran
   2026-07-26, so the next is **2026-08-02**. Step 3 is what covers it in the meantime.
5. Rollback is `git revert` — one policy file plus label lines in five CronJobs.

## Follow-up, not in scope

Other Kyverno policies still carry namespace-wide excludes; node-exporter and alloy lost their
exemptions under other policies when their labels were altered during probing, which is how those
excludes surfaced. Worth the same treatment, separately.
