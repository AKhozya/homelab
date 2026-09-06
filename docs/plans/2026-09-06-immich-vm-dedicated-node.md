# immich-vm dedicated node — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. The coordinator (Fable) owns every step marked **Coordinator**; an Opus implementer owns every step marked **Implementer**.

**Goal:** immich-vm runs every Immich workload that can run there and nothing else.

**Architecture:** A `NoSchedule` taint on immich-vm keeps unpinned pods off the node. immich-server, immich-machine-learning and the immich-admin-setup Job get a matching toleration and a `homelab/gpu=intel` nodeSelector. The three per-node agents the VM needs (intel-gpu-plugin, node-exporter, alloy) tolerate the taint; coredns-ha and loki-canary leave the node. The ML model cache moves to a git-declared PVC provisioned on the VM, on a bind mount to its 125 G volume.

**Tech Stack:** k3s v1.36.3, Flux, Helm chart `immich` 0.13.1 (bjw-s common), local-path-provisioner v0.0.36, ansible node-maintenance roles, Codex static review.

**Spec:** the *Design* section of this file. There is no separate spec document; the repo keeps plans in `docs/plans/`.

## Global Constraints

- GitOps only. No `kubectl edit/patch/replace`. Two imperative steps are sanctioned by this plan and nothing else: `kubectl taint` on the Node object, which Flux does not manage and whose source of truth becomes `host_vars/immich-vm.yml`; and `kubectl delete pod` on the two DaemonSet pods that must leave the node.
- Order is load-bearing: Task 1 (ansible) must be **applied on the VM** before Task 2 merges, or local-path creates the cache directory on the VM's 32 G root.
- Every non-docs change is reviewed **before** it is committed, per the pre-commit loop in `AGENTS.md`: the implementer leaves the diff uncommitted in the worktree; the coordinator reviews `git diff HEAD` via `~/.agents/skills/_shared/codex-review.sh --diff <file> --prompt <file>`, processes findings with `superpowers:receiving-code-review`, re-reviews delta-scoped, and commits only when the severity table allows. Docs-only commits are exempt.
- Work happens in worktree `.claude/worktrees/immich-vm-taint` on branch `wt-immich-vm-taint`. Merge with `bash ~/.agents/skills/_shared/merge-worktree.sh wt-immich-vm-taint` (no `--teardown` until Task 4).
- Commit messages: single line, no Claude mention.
- Comments earn their place only by naming a coupling, constraint, gotcha or rejected alternative. Docs: tables for enumerable facts, active voice, one idea per sentence.
- Image pins unchanged. No new dependencies.

---

## Design

### Rules

| Rule | Kubernetes mechanism |
|---|---|
| Every Immich workload that can run on immich-vm runs there | `nodeSelector: homelab/gpu: intel` plus a toleration on each |
| Nothing else runs on immich-vm | taint `homelab/dedicated=immich:NoSchedule` on the node |

### Pinned to immich-vm

| Workload | Change |
|---|---|
| immich-server | toleration (nodeSelector already present) |
| immich-machine-learning | nodeSelector + toleration + cache PVC relocated |
| immich-admin-setup Job | nodeSelector + toleration |

### Immich-related workloads that stay where they are

| Workload | Reason |
|---|---|
| immich-vm-heal CronJob (immich ns) | Starts the VM from outside via the NAS hypervisor. Already has required anti-affinity to `homelab/gpu=intel` |
| immich-backup CronJob (backup-replication ns, W2) | 148 G footprint on W2 against 106 G free on the VM. It would also write the backup onto the NAS array that holds the VM, losing the off-NAS copy |
| immich-init-extensions Job (databases ns) | Database-layer job against the shared CNPG cluster |
| Postgres, Redis | Shared with the fleet |

### Per-node agents on immich-vm

| DaemonSet | Decision | Basis |
|---|---|---|
| intel-gpu-plugin | keep, add toleration | Immich's GPU; no toleration today |
| node-exporter | keep, no edit | VM metrics and the heal watchdog's textfile metrics; already tolerates any `NoSchedule` |
| alloy | keep, no edit | Immich logs to Loki; already tolerates any `NoSchedule` |
| coredns-ha | leave the node | kube-dns `internalTrafficPolicy=Cluster`, so no node-local pod is needed |
| loki-canary | leave the node | not used |

### Mechanics and ordering

1. Ansible: bind mount `/mnt/k8s-storage` → `/home/k8s-storage` on the VM, `k3s_node_taints` for re-joins. Applied by the drift-heal.
2. Flux: tolerations, ML pin, cache PVC, Job pin, intel-gpu-plugin toleration. Verified live.
3. Live: `kubectl taint`, then delete the coredns-ha and loki-canary pods on the VM once. `NoSchedule` never evicts, and the DaemonSet controller does not recreate them on a tainted node.
4. Docs.

`NoExecute` was rejected: it would also require edits to alloy and node-exporter (their tolerations name `effect: NoSchedule`), and one missed toleration would evict a component instantly.

### Accepted trade-offs

| Trade-off | Consequence | Why accepted |
|---|---|---|
| All of Immich shares the NAS-backed VM disk | a scrub-class stall takes ML and the admin-setup Job down with the server | the operator asked for it; the Job is idempotent and re-runs daily |
| The old ML cache on worker-node is deleted by the Helm upgrade | models re-download on first use over the existing `0.0.0.0/0:443` egress rule | the cache is regenerable and excluded from backup by design |
| `k3s_node_taints` is consumed only at registration | the drift-heal writes it and raises the usual "restart k3s" drift alert; the weekly reboot on 2026-09-12 absorbs it | no manual k3s restart on the GPU VM |
| k3s-agent gains `RequiresMountsFor=/mnt/k8s-storage` | if the bind mount fails at boot, the node stays NotReady (alert `NodeDown`) instead of local-path writing PVs to the 32 G root LV | a NotReady node is visible; a silent wrong-volume PV is not. The guest still reaches a shell |

---

## Assumptions and cut corners

Tiers: ✅ verified (official docs or a probe against the live system) · 🟡 single-source · ⚠️ my call.

| # | Claim | Tier | Evidence |
|---|---|---|---|
| A1 | k3s `node-taint` applies only at first registration; live node needs `kubectl taint` | ✅ | docs.k3s.io/cli/agent and /advanced: "only add labels and/or taints at registration time" |
| A2 | `NoSchedule` never evicts running pods | ✅ | kubernetes.io taint-and-toleration: "Pods currently running on the node are not evicted" |
| A3 | DaemonSets auto-tolerate only `node.kubernetes.io/*` taints | ✅ | kubernetes.io DaemonSet § Taints and tolerations |
| A4 | alloy and node-exporter already tolerate any `NoSchedule` | ✅ | live DS specs: `*/Exists/NoSchedule` |
| A5 | `server.controllers.main.pod.tolerations` renders onto immich-server | ✅ | `helm template` chart 0.13.1, spike 2026-09-06 |
| A6 | `machine-learning.controllers.main.pod.{nodeSelector,tolerations}` render onto ML | ✅ | same spike |
| A7 | `machine-learning.persistence.cache.existingClaim` needs `size`, `storageClass`, `accessMode` removed (chart schema `oneOf`); chart then renders no PVC and mounts the claim at `/cache` | ✅ | same spike; schema rejected `nameOverride` and `accessMode` alongside `existingClaim` |
| A8 | Helm upgrade deletes the chart PVC once it leaves the render; no `helm.sh/resource-policy: keep` on it | ✅ | helm/helm#3797 (maintainer: only PVs and namespaces survive an upgrade); rendered and live PVC carry no keep annotation |
| A9 | ML pods match the immich NetworkPolicy (label `app.kubernetes.io/instance: immich`) and keep 443 egress for model downloads | ✅ | rendered pod labels; `apps/immich/networkpolicy.yaml` egress rule |
| A10 | local-path uses `/mnt/k8s-storage` on every node; immich-vm lacks it; the helper does `mkdir -p` | ✅ | `local-path-config` ConfigMap; `ls /mnt` on the VM; helper `setup` script |
| A11 | Bind-mount unit name is `mnt-k8s\x2dstorage.mount` | ✅ | `systemd-escape -p --suffix=mount /mnt/k8s-storage` on the VM |
| A12 | `kubectl taint node immich-vm homelab/dedicated=immich:NoSchedule` is accepted by admission | ✅ | `--dry-run=server` returned the taint |
| A13 | No Kyverno policy touches scheduling fields | ✅ | grep of `infrastructure/configs/kyverno-policies/` |
| A14 | No `KubeDaemonSet*` alert rules exist, so a transient misscheduled count raises nothing | ✅ | grep of `monitoring/` |
| A15 | Device-plugin restart leaves immich-server's allocation intact | ✅ | kubernetes.io device-plugins: pods keep assigned devices; plugin re-registers |
| A16 | Flux `force` annotation recreates the admin-setup Job when its immutable template changes | ✅ | annotation present for exactly this; the daily TTL re-run relies on it |
| A17 | The DaemonSet controller excludes a tainted node from `desiredNumberScheduled` and does not recreate a deleted pod there | 🟡 | scheduler predicate reuse; **verify in Task 3 step 4** |
| A18 | A `main` commit arms a drift-heal within ~10 min | 🟡 | memory `gotcha_node_maintenance_concurrent_ansible`; **verify in Task 1 step 8** (fallback: operator triggers the units) |
| A19 | 10 Gi is enough for the cache; the VM's `/home` has 106 G free | ✅ | current PVC size; `df` on the VM |
| A20 | Capacity: requests 0.9 CPU / 2.1 Gi, limits 7 CPU / 7.3 Gi on 4 CPU / 11.6 Gi | ✅ | live resources |
| A21 | Leaving coredns-ha off the node does not affect DNS for pods on it | ✅ | `kube-dns` `internalTrafficPolicy=Cluster` |
| A22 | The ML image stays CPU-only `v3.1.0` for this change | ⚠️ | keeps the move verifiable on its own; `-openvino` is a follow-up |
| A23 | The taint key is `homelab/dedicated=immich`, not the `homelab/gpu` label key | ⚠️ | says "reserved", not "has a GPU" |
| A24 | `RequiresMountsFor=` in a unit drop-in adds `Requires=` and `After=` on the mount unit for that path, so k3s-agent cannot start while `/mnt/k8s-storage` is unmounted | ✅ | systemd.unit(5); the hardening role already ships k3s drop-ins this way (`roles/hardening/tasks/main.yml:96-108`, no restart handler, applies on the next k3s start) |

**Validate before build:** A17 and A18 are verified during execution at the steps named; both have a stated fallback.

---

## File structure

| Path | Task | Responsibility |
|---|---|---|
| `docs/scripts/node-maintenance/ansible/host_vars/immich-vm.yml` | 1 | `k3s_node_taints` for re-registration |
| `docs/scripts/node-maintenance/ansible/roles/k3s_config/templates/config.yaml.j2` | 1 | generic comment above `node-taint:` |
| `docs/scripts/node-maintenance/ansible/roles/immich_gpu_node/files/mnt-k8s-storage.mount` | 1 | new: bind-mount unit |
| `docs/scripts/node-maintenance/ansible/roles/immich_gpu_node/files/k3s-agent-local-path-mount.conf` | 1 | new: k3s-agent drop-in `RequiresMountsFor=/mnt/k8s-storage` |
| `docs/scripts/node-maintenance/ansible/roles/immich_gpu_node/tasks/main.yml` | 1 | three tasks: dirs, unit file, enable+start |
| `apps/immich/ml-cache-pvc.yaml` | 2 | new: `immich-ml-cache` PVC |
| `apps/immich/kustomization.yaml` | 2 | register the PVC |
| `apps/immich/release.yaml` | 2 | server toleration; ML pod pin + toleration; cache → `existingClaim` |
| `apps/immich/admin-setup-job.yaml` | 2 | Job pin + toleration |
| `infrastructure/configs/intel-gpu-plugin/daemonset.yaml` | 2 | toleration |
| `infrastructure/configs/backup/pvc-backup-cronjob.yaml` | 2 | exclusion comment names the new PVC |
| `docs/ARCHITECTURE.md`, `docs/HOMELAB_ANALYSIS.md`, `docs/CODEMAPS/apps.md`, `docs/setup/K3S_SETUP.md`, `docs/scripts/node-maintenance/README.md`, `docs/HOMELAB_HISTORY.md` | 3 | record the dedicated node |

Shared toleration block, used verbatim in every manifest:

```yaml
tolerations:
  - key: homelab/dedicated
    operator: Equal
    value: immich
    effect: NoSchedule
```

Codex review prompt, written once to `$SCRATCH/codex-prompt.md` by the coordinator in Task 0 and reused for every dispatch (`$SCRATCH` is the session scratchpad directory).

---

## Task 0: Plan review

**Coordinator.**

- [ ] **Step 1: Commit this plan** in the worktree: `git add docs/plans/2026-09-06-immich-vm-dedicated-node.md && git commit -m 'docs(plans): immich-vm dedicated node — taint, tolerations, ML relocation' -- docs/plans/2026-09-06-immich-vm-dedicated-node.md`
- [ ] **Step 2: Write the Codex prompt** to `$SCRATCH/codex-prompt.md` (STATIC git-only contract, one-message verdict with severity per finding, `.claude/review-invariants.md` rubric, the writing rules, the verified facts A1–A23 inlined so nothing is re-derived).
- [ ] **Step 3: Dispatch** `bash ~/.agents/skills/_shared/codex-review.sh --diff docs/plans/2026-09-06-immich-vm-dedicated-node.md --prompt $SCRATCH/codex-prompt.md`. Exit 3 = no verdict → re-dispatch (not a round).
- [ ] **Step 4: Fold findings** into this file per the severity table; re-dispatch delta-scoped until clean or LOW×2. Amend the plan commit.

---

## Task 1: Node side — bind mount and taint variable

**Files:**
- Modify: `docs/scripts/node-maintenance/ansible/host_vars/immich-vm.yml` (after the `k3s_node_labels` block, line 71)
- Modify: `docs/scripts/node-maintenance/ansible/roles/k3s_config/templates/config.yaml.j2:33`
- Create: `docs/scripts/node-maintenance/ansible/roles/immich_gpu_node/files/mnt-k8s-storage.mount`
- Create: `docs/scripts/node-maintenance/ansible/roles/immich_gpu_node/files/k3s-agent-local-path-mount.conf`
- Modify: `docs/scripts/node-maintenance/ansible/roles/immich_gpu_node/tasks/main.yml` (insert after the "Enable + start immich-library virtiofs mount" task, before the `# ---- Heal watchdog` banner)

**Interfaces:**
- Produces: `/mnt/k8s-storage` mounted on immich-vm (bind of `/home/k8s-storage`); k3s-agent depends on that mount; `node-taint: ["homelab/dedicated=immich:NoSchedule"]` in the VM's `/etc/rancher/k3s/config.yaml`. Task 2 depends on the mount.

- [ ] **Step 1 (Implementer): host_vars** — append after the `k3s_node_labels` list:

```yaml

# Registration-time taint: keeps every non-Immich pod off the NAS-backed VM (the 2026-09-06 scrub
# stall caught five foreign init Jobs here). k3s reads node-taint only when the node first joins,
# so the live node was tainted once with `kubectl taint`; this line covers a re-join.
k3s_node_taints:
  - "homelab/dedicated=immich:NoSchedule"
```

- [ ] **Step 2 (Implementer): template comment** — replace line 33 `# No workloads on control plane` with `# Registration-time taints (k3s applies node-taint only when the node first joins)`.

- [ ] **Step 3 (Implementer): mount unit file** — create `roles/immich_gpu_node/files/mnt-k8s-storage.mount`:

```ini
[Unit]
Description=local-path-provisioner volume root (bind of /home/k8s-storage)
Documentation=https://github.com/AKhozya/homelab

[Mount]
What=/home/k8s-storage
Where=/mnt/k8s-storage
Type=none
Options=bind
# local-path-provisioner writes every PV under /mnt/k8s-storage on every node (nodePathMap default).
# Without this bind the helper pod mkdir -p's the path on the 32 G root LV; the 125 G home LV is
# where the k3s data-dir already lives. WantedBy, not RequiredBy: a mount failure must never prevent
# boot from reaching a shell on this VM (GPU reset-bug). k3s-agent carries RequiresMountsFor= on this
# path (drop-in), so a failed mount leaves the node NotReady instead of writing PVs to root.

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 4 (Implementer): k3s-agent drop-in file** — create `roles/immich_gpu_node/files/k3s-agent-local-path-mount.conf`:

```ini
[Unit]
# local-path PVs live under /mnt/k8s-storage (bind of the home LV). Without this dependency a boot
# with the mount absent lets the kubelet create PV directories on the 32 G root LV. Mirrors the
# hardening role's k3s drop-ins: no restart handler, takes effect on the next k3s-agent start.
RequiresMountsFor=/mnt/k8s-storage
```

- [ ] **Step 5 (Implementer): role tasks** — insert after the `Enable + start immich-library virtiofs mount` task:

```yaml

# ---- local-path volume root ----
# local-path-provisioner uses /mnt/k8s-storage on every node. The VM has no separate data volume,
# so bind the path onto the home LV (same reasoning as k3s_data_dir=/home/k3s in host_vars).
- name: Ensure local-path source and mountpoint dirs
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: root
    group: root
    mode: "0755"
  loop:
    - /home/k8s-storage
    - /mnt/k8s-storage
  tags: [immich-gpu-node, local-path]

- name: Deploy local-path bind mount unit
  ansible.builtin.copy:
    src: mnt-k8s-storage.mount
    dest: '/etc/systemd/system/mnt-k8s\x2dstorage.mount'
    owner: root
    group: root
    mode: "0644"
  tags: [immich-gpu-node, local-path]

- name: Enable + start local-path bind mount
  ansible.builtin.systemd_service:
    name: 'mnt-k8s\x2dstorage.mount'
    enabled: true
    state: started
    daemon_reload: true
  tags: [immich-gpu-node, local-path]

# k3s-agent must not start without the mount (see the drop-in). No restart here: the mount is
# already active on this run, and a k3s restart on the GPU VM is a human gate (k3s_config rationale).
- name: Ensure k3s-agent service.d drop-in dir
  ansible.builtin.file:
    path: /etc/systemd/system/k3s-agent.service.d
    state: directory
    owner: root
    group: root
    mode: "0755"
  tags: [immich-gpu-node, local-path]

- name: Deploy k3s-agent RequiresMountsFor drop-in
  ansible.builtin.copy:
    src: k3s-agent-local-path-mount.conf
    dest: /etc/systemd/system/k3s-agent.service.d/local-path-mount.conf
    owner: root
    group: root
    mode: "0644"
  register: immich_gpu_k3s_mount_dropin
  tags: [immich-gpu-node, local-path]

- name: Reload systemd for the k3s-agent drop-in
  ansible.builtin.systemd_service:
    daemon_reload: true
  when: immich_gpu_k3s_mount_dropin.changed
  tags: [immich-gpu-node, local-path]
```

- [ ] **Step 6 (Implementer): lint** — from the worktree root:

```bash
yamllint docs/scripts/node-maintenance/ansible/host_vars/immich-vm.yml docs/scripts/node-maintenance/ansible/roles/immich_gpu_node/tasks/main.yml
(cd docs/scripts/node-maintenance/ansible && ansible-lint roles/immich_gpu_node roles/k3s_config)
(cd docs/scripts/node-maintenance/ansible && ansible-playbook node-config.yml --syntax-check)
```
Expected: yamllint and syntax-check clean (the syntax-check prints a harmless "Could not match supplied host pattern" warning). `ansible-lint` baseline on 2026-09-06 before this change: exactly one pre-existing failure, `roles/immich_gpu_node/handlers/main.yml:24` command-instead-of-module. Any new finding is yours.

- [ ] **Step 7 (Implementer): hand over uncommitted** — `git status --short` must list exactly the five files above (two new, three modified) and nothing else. Do not commit. Report the file list and the lint output.

- [ ] **Step 8 (Coordinator): review loop, then commit** — `git diff HEAD -- docs/scripts > $SCRATCH/t1.diff` (new files: `git add -N` them first so they appear), dispatch Codex with the shared prompt, process findings, re-review delta-scoped. When the severity table allows: `git add` the five paths and `git commit -m 'feat(immich-vm): local-path bind mount + registration-time dedicated taint' -- <the five paths>`. Then `bash ~/.agents/skills/_shared/merge-worktree.sh wt-immich-vm-taint`.

- [ ] **Step 9 (Coordinator): confirm the drift-heal applied it (A18)** — poll up to 25 min:

```bash
ssh -p 65300 akhozya@immich-vm 'systemctl is-active "mnt-k8s\x2dstorage.mount"; findmnt -no SOURCE,TARGET /mnt/k8s-storage; systemctl show k3s-agent -p RequiresMountsFor; grep -A1 "^node-taint" /etc/rancher/k3s/config.yaml'
```
Expected: `active`, `/dev/mapper/ArchinstallVg-home[/k8s-storage] /mnt/k8s-storage`, `RequiresMountsFor=/mnt/k8s-storage`, and the taint line. Fallback if nothing changed after 25 min: ask the operator to run on the CP `sudo systemctl start node-maintenance-sync.service && sudo systemctl start node-maintenance-config.service`. A Telegram "k3s config drift" alert for immich-vm is expected and needs no action.

---

## Task 2: Flux manifests — tolerations, ML relocation, Job pin

**Files:**
- Create: `apps/immich/ml-cache-pvc.yaml`
- Modify: `apps/immich/kustomization.yaml:8` (resources list)
- Modify: `apps/immich/release.yaml:189-192` (server pod), `:318-320` (ML controllers.main), ML `persistence.cache` block
- Modify: `apps/immich/admin-setup-job.yaml:18-19`
- Modify: `infrastructure/configs/intel-gpu-plugin/daemonset.yaml:93-95`
- Modify: `infrastructure/configs/backup/pvc-backup-cronjob.yaml:80`

**Interfaces:**
- Consumes: the bind mount from Task 1 (must be `active` first).
- Produces: PVC `immich-ml-cache` in ns `immich`; every Immich pod and intel-gpu-plugin tolerate `homelab/dedicated=immich:NoSchedule`. Task 3 depends on all of them being live before the taint.

- [ ] **Step 1 (Implementer): PVC manifest** — create `apps/immich/ml-cache-pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: immich-ml-cache
  namespace: immich
  labels:
    app.kubernetes.io/name: immich-machine-learning
    app.kubernetes.io/instance: immich
spec:
  # Declared here, not by the chart: local-path binds a PV to the node of first use, and the chart's
  # own PVC was bound to worker-node. A new claim lets ML follow the immich-vm nodeSelector.
  # Regenerable model cache — excluded from pvc-backup by design.
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 10Gi
```

- [ ] **Step 2 (Implementer): register it** — in `apps/immich/kustomization.yaml` add `  - ml-cache-pvc.yaml` directly after `  - release.yaml`.

- [ ] **Step 3 (Implementer): server toleration** — in `apps/immich/release.yaml`, under `server.controllers.main.pod`, directly after the two `nodeSelector` lines (`homelab/gpu: intel`), insert the shared toleration block at the same indentation as `nodeSelector`.

- [ ] **Step 4 (Implementer): ML pin** — under `machine-learning.controllers.main`, insert a `pod:` block before `containers:` at the same indentation:

```yaml
          pod:
            # Follows the server onto immich-vm (dedicated node). CPU inference for now; the
            # -openvino image is a separate change.
            nodeSelector:
              homelab/gpu: intel
            tolerations:
              - key: homelab/dedicated
                operator: Equal
                value: immich
                effect: NoSchedule
```

- [ ] **Step 5 (Implementer): cache → existingClaim** — replace the ML `persistence.cache` item:

```yaml
        cache:
          enabled: true
          type: persistentVolumeClaim
          # existingClaim excludes size/storageClass/accessMode (chart schema oneOf). The claim is
          # apps/immich/ml-cache-pvc.yaml; the old chart-owned PVC on worker-node is deleted by this upgrade.
          existingClaim: immich-ml-cache
```

- [ ] **Step 6 (Implementer): Job pin** — in `apps/immich/admin-setup-job.yaml`, after `priorityClassName: homelab-standard`, insert at the same indentation:

```yaml
      # Immich-only node. Trade-off accepted 2026-09-06: a scrub-class stall on the VM holds this
      # Job too; it is idempotent and the daily force re-run retries it.
      nodeSelector:
        homelab/gpu: intel
      tolerations:
        - key: homelab/dedicated
          operator: Equal
          value: immich
          effect: NoSchedule
```

- [ ] **Step 7 (Implementer): intel-gpu-plugin toleration** — in `infrastructure/configs/intel-gpu-plugin/daemonset.yaml`, after the `nodeSelector` block (`homelab/gpu: intel`), insert the shared toleration block at the same indentation as `nodeSelector`.

- [ ] **Step 8 (Implementer): backup comment** — in `infrastructure/configs/backup/pvc-backup-cronjob.yaml` change `#   - immich/immich-machine-learning — regenerable ML cache` to `#   - immich/immich-ml-cache — regenerable ML cache (on immich-vm since 2026-09-06)`.

- [ ] **Step 9 (Implementer): validate** — run the `homelab-yaml-validate` ladder on the touched files. Minimum:

```bash
yamllint apps/immich infrastructure/configs/intel-gpu-plugin infrastructure/configs/backup
kubeconform -strict -summary apps/immich/ml-cache-pvc.yaml apps/immich/admin-setup-job.yaml infrastructure/configs/intel-gpu-plugin/daemonset.yaml
kustomize build apps/immich > /dev/null
yq '.spec.values' apps/immich/release.yaml > $SCRATCH/v.yaml
helm template immich oci://ghcr.io/immich-app/immich-charts/immich --version 0.13.1 -f $SCRATCH/v.yaml > $SCRATCH/r.yaml
yq 'select(.kind=="Deployment") | .metadata.name + " tol=" + ((.spec.template.spec.tolerations // []) | length | tostring) + " ns=" + (.spec.template.spec.nodeSelector | tostring)' $SCRATCH/r.yaml
yq 'select(.kind=="PersistentVolumeClaim") | .metadata.name' $SCRATCH/r.yaml
```
Expected: lint clean; `immich-server tol=1 ns={"homelab/gpu":"intel"}`, `immich-machine-learning tol=1 ns={"homelab/gpu":"intel"}`; the PVC query prints nothing (chart no longer owns one). `kubectl apply --dry-run=server -f apps/immich/ml-cache-pvc.yaml` must also pass.

- [ ] **Step 10 (Implementer): hand over uncommitted** — `git status --short` must list exactly the six files (one new, five modified) and nothing else. Do not commit. Report the file list and the validation output.

- [ ] **Step 11 (Coordinator): review loop, then commit** — `git add -N apps/immich/ml-cache-pvc.yaml && git diff HEAD -- apps infrastructure > $SCRATCH/t2.diff`, Codex dispatch, findings, delta re-review. When the table allows: `git add` the six paths and `git commit -m 'feat(immich): pin every Immich workload to immich-vm, relocate the ML cache, tolerate the dedicated taint' -- <paths>`. Merge with `merge-worktree.sh`. Then `flux reconcile source git flux-system && flux reconcile kustomization infrastructure-configs && flux reconcile kustomization apps && flux reconcile helmrelease immich -n immich`.

- [ ] **Step 12 (Coordinator): verify live** — all must hold before Task 3:

```bash
kubectl -n immich get pods -o wide                                    # server + ML Running on immich-vm; admin-setup Completed on immich-vm
kubectl -n immich get pvc                                             # only immich-ml-cache, Bound
kubectl get pv -o json | jq -r '.items[] | select(.spec.claimRef.name=="immich-ml-cache") | .spec.hostPath.path + " @ " + .spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]'   # /mnt/k8s-storage/... @ immich-vm
ssh -p 65300 akhozya@immich-vm 'df -h /mnt/k8s-storage | tail -1'   # ArchinstallVg-home
kubectl get pods -A --field-selector spec.nodeName=immich-vm -o json | jq -r '.items[] | .metadata.name + " tol=" + ([.spec.tolerations[]?|select(.key=="homelab/dedicated")]|length|tostring)'   # server, ML, admin-setup, intel-gpu-plugin = 1
kubectl get node immich-vm -o jsonpath='{.status.allocatable.gpu\.intel\.com/i915}{"\n"}'   # 10
kubectl -n immich logs deploy/immich-machine-learning --tail=20       # model download or "ready" lines, no crash
bash ~/.agents/skills/_shared/check-alerts.sh | grep -v Watchdog       # empty
```
Old PVC `immich-machine-learning` and its PV must be gone. If the old PVC survives (A8 wrong), stop and report; do not delete it by hand without the operator's word.

---

## Task 3: Live taint, converge, docs

**Coordinator throughout** (live steps prompt the operator).

- [ ] **Step 1: taint** — `kubectl taint node immich-vm homelab/dedicated=immich:NoSchedule`. Verify: `kubectl get node immich-vm -o jsonpath='{.spec.taints}'`.

- [ ] **Step 2: remove the two foreign DaemonSet pods once**:

```bash
kubectl -n kube-system delete pod -l app=coredns-ha --field-selector spec.nodeName=immich-vm
kubectl -n loki delete pod -l app.kubernetes.io/component=canary,app.kubernetes.io/instance=loki --field-selector spec.nodeName=immich-vm
```

- [ ] **Step 3: verify convergence (A17)** — wait 60 s, then:

```bash
kubectl get pods -A --field-selector spec.nodeName=immich-vm --no-headers | awk '{print $1"/"$2, $4}'
kubectl -n kube-system get ds coredns-ha -o jsonpath='desired={.status.desiredNumberScheduled} current={.status.currentNumberScheduled} mis={.status.numberMisscheduled}{"\n"}'
kubectl -n loki get ds loki-canary -o jsonpath='desired={.status.desiredNumberScheduled} current={.status.currentNumberScheduled} mis={.status.numberMisscheduled}{"\n"}'
```
Expected pods on the node: immich-server, immich-machine-learning, intel-gpu-plugin, alloy, node-exporter (plus admin-setup until its TTL). coredns-ha `desired=3 current=3 mis=0`, loki-canary `desired=2 current=2 mis=0`. If a deleted pod comes back on immich-vm, A17 is wrong: stop and report.

- [ ] **Step 4: DNS from the node still works (A21)** — `kubectl -n immich exec deploy/immich-server -- getent hosts immich-machine-learning.immich.svc.cluster.local` resolves.

- [ ] **Step 5: docs** in the worktree (docs-only, review-exempt):
  - `docs/ARCHITECTURE.md:29` mermaid node text → `runs immich-server + ML; dedicated node (NoSchedule taint); library via NAS virtiofs`.
  - `docs/ARCHITECTURE.md:38` replace `the ML PV (\`...immich-machine-learning\`) stays W1-bound, so ML still follows W1` with `ML moved to immich-vm on 2026-09-06 with a git-declared cache PVC on the VM's local-path bind mount; immich-vm carries a \`homelab/dedicated=immich:NoSchedule\` taint, so only Immich pods and the per-node agents run there`.
  - `docs/ARCHITECTURE.md:142` drop `Immich ML PV still here — the server moved to \`immich-vm\` 2026-07-12` and `immich-server (on \`immich-vm\`, minus ML)` → `Immich (all on \`immich-vm\`)`; `:143` first cell → `Immich web/API + ML down (server, ML and admin-setup are pinned there; heal, backup and DB-init jobs stay off it)`.
  - `docs/HOMELAB_ANALYSIS.md:5` append after `joined 2026-07-10` → `, dedicated to Immich via a NoSchedule taint since 2026-09-06`.
  - `docs/CODEMAPS/apps.md:13` → `server + ML pods on \`immich-vm\` (dedicated node, taint \`homelab/dedicated=immich\`)`.
  - `docs/setup/K3S_SETUP.md` Node Scheduling list: add `- **immich-vm**: tainted \`homelab/dedicated=immich:NoSchedule\` — Immich pods + per-node agents only (\`host_vars/immich-vm.yml\`)`.
  - `docs/scripts/node-maintenance/README.md:11` role phrase → `immich_gpu_node\` (immich-vm only: GPU-node substrate — heal script, watchdog units, sysctl/cmdline guards, local-path bind mount)`.
  - `docs/HOMELAB_HISTORY.md`: in the 2026-09-06 entry's follow-up table, replace the fence row status with `shipped <sha-task1>, <sha-task2>; taint applied <time>`; add a two-column table after it (`Change | Detail`) with rows for the taint, the tolerations, the ML cache relocation, the two DaemonSet pods that left, and the four exceptions.
  - Commit: `docs: immich-vm is a dedicated Immich node`. Merge with `merge-worktree.sh`.

- [ ] **Step 6: memory** — update `project_immich_gpu_transcode.md` and `gotcha_nas_sdb_failing_scrub_only.md` (fence shipped; ML on the VM; `-openvino` follow-up open), and the MEMORY.md index lines.

---

## Task 4: Next-day verification and teardown

**Coordinator**, on 2026-09-07 after 18:15 local.

- [ ] **Step 1:** `kubectl get jobs -A -o json | jq -r '.items[] | select(.metadata.creationTimestamp > "2026-09-07T17:00:00Z") | .metadata.namespace + "/" + .metadata.name'` lists the five init Jobs; `kubectl get pods -A -o wide | grep -E 'audiobookshelf-init|home-assistant-admin-setup|n8n-user-provision|couchdb-init'` shows worker-node or worker-node-2, never immich-vm; `immich-admin-setup` shows immich-vm.
- [ ] **Step 2:** `kubectl get pods -A --field-selector spec.nodeName=immich-vm` unchanged from Task 3 step 3. Alerts: only Watchdog.
- [ ] **Step 3:** `bash ~/.agents/skills/_shared/merge-worktree.sh wt-immich-vm-taint --teardown` once nothing is left on the branch.

---

## Rollback

What `kubectl taint node immich-vm homelab/dedicated:NoSchedule-` does and does not do:

| Effect | Taint removal |
|---|---|
| Other pods may schedule on immich-vm again | yes, on the scheduler's next pass (asynchronous) |
| ML placement | unchanged: its nodeSelector still pins it to the VM |
| Old ML cache on worker-node | already deleted by the Helm upgrade; not restored |
| Tolerations in git | unchanged; harmless without the taint |

**Never `git revert` the whole Task 2 commit while the taint is present.** That commit also carries the tolerations for immich-server, the admin-setup Job and intel-gpu-plugin; without them the server's replacement pod cannot schedule onto the tainted node it is pinned to, and Immich goes down. Rollbacks below are targeted edits, or remove the taint first.

| Symptom | Action | Readiness check |
|---|---|---|
| ML pod Pending on immich-vm (PVC unbound) | `kubectl -n immich describe pvc immich-ml-cache`; if the helper failed on `/mnt/k8s-storage`, fix the mount (Task 1) and let the provisioner retry | PVC `Bound`, `kubectl -n immich rollout status deploy/immich-machine-learning` |
| immich-server not Ready after the roll | a startup-probe timeout is the known cold-start issue: wait one more restart. Revert the server toleration only if the failure is in the toleration, and only after removing the taint | `kubectl -n immich rollout status deploy/immich-server` |
| A per-node agent missing from the node after the taint | remove the taint (command above), fix its toleration in git, merge, then re-taint | `kubectl get pods -A --field-selector spec.nodeName=immich-vm -o wide` lists a `Running` `1/1` pod for intel-gpu-plugin, node-exporter and alloy, checked again after the taint is re-applied. Aggregate DaemonSet counts do not prove the node is covered |
| Undo the ML relocation only | targeted git change; the server, Job and intel-gpu-plugin tolerations stay. Delete the ML `pod:` block (Task 2 step 4), which removes ML's nodeSelector and its toleration together, as intended: ML must leave the tainted node; restore the cache item to `type: persistentVolumeClaim`, `size: 10Gi`, `storageClass: local-path`, `accessMode: ReadWriteOnce` and drop `existingClaim`; delete `apps/immich/ml-cache-pvc.yaml` and its kustomization line. Merge. Flux prunes the git PVC (its PV on the VM is deleted); the chart recreates its own 10 Gi PVC, bound to whichever node schedules ML first; models re-download | `kubectl -n immich get pvc` shows `immich-machine-learning` `Bound`; `kubectl -n immich rollout status deploy/immich-machine-learning` green; immich-server untouched |
| Undo the node-side change | `git revert` the Task 1 commit and merge; the drift-heal removes nothing on its own, so the mount unit and drop-in stay until an operator removes them. Both are harmless with no PV under the path | `systemctl show k3s-agent -p RequiresMountsFor` (informational) |
| Old ML PVC survived (A8) | report to the operator; deletion is theirs to approve | — |
