# Monthly-Review Overdue Closeout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the three overdue items from the 2026-07-04 monthly review: Kyverno CP→VP migration Phase 3/4 (due ≥07-11, CP-delete target ≤07-18), the resource right-sizing pass (due 07-06), and security-scan ExecStopPost failure-notify (due 07-08); plus stale ANALYSIS deadline rows.

**Architecture:** GitOps-only — every cluster change is a commit merged to `main` + `flux reconcile`. Kyverno migration is two gated commits (Deny-flip, then CP-delete) with live admission tests between. Right-sizing is two waves (stateless apps/infra, then database CRs) with p95-grounded request values. Node-side change (systemd unit) deploys via the node-maintenance sync + drift-heal pipeline.

**Tech Stack:** Flux, Kyverno 1.18.1 (`policies.kyverno.io/v1` ValidatingPolicy), kustomize, Percona/OT-Redis operators, ansible + systemd.

## Phase 2 gate evidence (already verified 2026-07-12 — recorded here so implementer doesn't re-litigate)

| Gate check | Result |
|---|---|
| `kyverno-vp-parity.sh` | Class 1 / 2 / 2e / 3 all EMPTY |
| `vpol status.autogen` | 11 policies + canary show `cronjobs,defaults` configs; `require-non-default-serviceaccount` = `{}` (direct controller match, expected) |
| polr freshness | Pod created 07-12 18:26 (`immich-server-6b7568bb69-2m4dm`) has polr rows from BOTH sources (`kyverno` + `KyvernoValidatingPolicy`), 15 pass / 0 fail, within the hour |
| Report-drop storm | `kyverno_breaker_drops_total` ran 2.6–3/s 07-07→07-11 (trivy scan-job churn + k3s 1.36.2 reboot window; kyverno 3.8.2 rollout replaced pods 07-11), **zero drops since 07-11** — parity data is post-storm |
| Teardown-wedge fix in VP | `require-networkpolicy-vp.yaml` carries `operations: ["CREATE","UPDATE"]` + `deletionTimestamp` skip; all 12 VPs have operations scoping |
| Monitoring deps | Only kyverno alert live = `KyvernoAdmissionControllerDown` (`up`-based, engine-agnostic). No polr-metric alerts. `KyvernoPolicyViolationsDailySummary` from memory no longer exists live |

## Global Constraints

- GitOps only: commit → merge to `main` → `fr`. Never `kubectl apply/edit/patch` (except `--dry-run=server` for gates).
- All edits in worktree `.claude/worktrees/overdue-closeout` (branch `wt-overdue-closeout`), merged to main per-stage — Kyverno gates need live cluster between commits, so merges are sequential, not batched.
- CI billing may still be blocked (2026-07-10) — run local equivalents before every push: `yamllint`, `kubeconform` across the 5 kustomize roots (`/homelab-yaml-validate` skill), plus `ansible-lint` for Task 6.
- Pre-commit Codex static review per AGENTS.md for each substantive batch (Tasks 1–2 combined diff, Task 4+5 combined, Task 6). Docs-only commits exempt.
- Serialize cluster ops: one merge+`fr`+gate at a time. No concurrent session may run `fr`/rollouts (confirm no other Claude session before starting).
- immich untouched — 48h soak until ~2026-07-14 18:35 (its right-sizing + backup re-topology = T7, separate track).
- Images stay pinned; no new dependencies.

---

### Task 0: Preflight

**Files:** none (checks only)

- [ ] **Step 1: Confirm clean main + no concurrent session**

```bash
cd /Users/akhozya/source-code/homelab && git status --porcelain && git pull --ff-only
```
Expected: no output from porcelain (clean), pull up-to-date. Ask user to confirm no other Claude session is mid-cluster-op.

- [ ] **Step 2: Confirm no pending Renovate kyverno-chart PR shipping Kyverno 1.20**

```bash
gh pr list --search kyverno --state open
```
Expected: empty (or no chart-bump to 1.20+). If a 1.20 bump is open, it stays HELD until this plan's Tasks 1–3 land (repo policy).

- [ ] **Step 3: Create worktree**

```bash
git worktree add .claude/worktrees/overdue-closeout -b wt-overdue-closeout && cd .claude/worktrees/overdue-closeout
```

- [ ] **Step 4: Copy this plan into the worktree** at `docs/superpowers/plans/2026-07-12-monthly-review-overdue-closeout.md` (committed with Task 7's docs commit).

---

### Task 1: Kyverno Phase 3 commit 1 — flip 12 VPs Audit→Deny (Gate A)

**Files:**
- Modify: all 12 `infrastructure/configs/kyverno-policies/*-vp.yaml` (one line each)

**Interfaces:**
- Produces: all 12 ValidatingPolicies enforcing (`validationActions: [Deny]`) while CPs still Enforce — double-enforcement window, verdict-identical per 8-day parity.

- [ ] **Step 1: Flip validationActions in all 12 VP files**

In each of `disallow-host-namespaces-vp.yaml, disallow-host-path-vp.yaml, disallow-latest-tag-vp.yaml, disallow-privilege-escalation-vp.yaml, require-drop-all-capabilities-vp.yaml, require-labels-vp.yaml, require-networkpolicy-vp.yaml, require-non-default-serviceaccount-vp.yaml, require-non-root-vp.yaml, require-readonly-rootfs-vp.yaml, require-resource-limits-vp.yaml, require-seccomp-runtimedefault-vp.yaml`:

```yaml
# before
  validationActions: [Audit]
# after
  validationActions: [Deny]
```

Also update the kustomization.yaml comment block (`Deny flip + CP deletion = Phase 3 after ≥1-week parity soak.` → `Phase 3 Deny-flip landed 2026-07-12; CP deletion follows as the next commit.`).

- [ ] **Step 2: Local validation**

```bash
/homelab-yaml-validate   # yamllint + kubeconform over kustomize roots
```
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add infrastructure/configs/kyverno-policies/
git commit -m "feat(kyverno): Phase 3 — flip 12 ValidatingPolicies Audit->Deny"
```

- [ ] **Step 4: Merge + reconcile** (from main tree)

```bash
git -C /Users/akhozya/source-code/homelab merge wt-overdue-closeout && git -C /Users/akhozya/source-code/homelab push && fr
```

- [ ] **Step 5: Gate A — VP Deny path live, no over-block**

```bash
# (a) all 12 VPs show Deny
kubectl get vpol -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.validationActions}{"\n"}{end}'
# expect: every row "[Deny]" (13 rows incl. vp-canary)

# (b) canary rejection proves the VP Deny path (no CP twin exists for it)
kubectl apply --dry-run=server -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: vp-canary-probe
  namespace: default
  labels: {vp-canary-test: "fail"}
spec:
  containers: [{name: c, image: busybox:1.36.1}]
EOF
# expect: DENIED, message includes vp-canary (post-flip the other Deny VPs/CPs flag this
# limit-less pod too — extra names fine; vp-canary present = VP Deny path proven)

# (c) no over-block: re-apply a live compliant pod spec dry-run
kubectl get pod -n n8n -l app=n8n -o json | jq '.items[0] | {apiVersion:"v1",kind:"Pod",metadata:{name:"gate-a-compliant",namespace:.metadata.namespace,labels:.metadata.labels},spec:.spec}' | kubectl apply --dry-run=server -f -
# expect: "created (server dry run)"
```

- [ ] **Step 6: Re-run parity (still clean under Deny)**

```bash
bash docs/scripts/kyverno-vp-parity.sh | grep -v '^===' | grep -v '^\s*$' | wc -l
```
Expected: `0`.

If any Gate A check fails → `git revert` the flip commit, push, `fr`, stop, report.

---

### Task 2: Kyverno Phase 3 commit 2 — delete 12 ClusterPolicies (Gate B)

**Files:**
- Delete: all 12 non-`-vp` policy files in `infrastructure/configs/kyverno-policies/` (`require-labels.yaml`, `disallow-host-namespaces.yaml`, `require-resource-limits.yaml`, `require-non-root.yaml`, `disallow-host-path.yaml`, `disallow-latest-tag.yaml`, `require-non-default-serviceaccount.yaml`, `require-seccomp-runtimedefault.yaml`, `disallow-privilege-escalation.yaml`, `require-drop-all-capabilities.yaml`, `require-networkpolicy.yaml`, `require-readonly-rootfs.yaml`)
- Modify: `infrastructure/configs/kyverno-policies/kustomization.yaml` (remove the 12 CP rows + rewrite header comment: policies are now CEL ValidatingPolicies, Enforce=Deny)

**Interfaces:**
- Consumes: Task 1's Deny-active VPs.
- Produces: VP-only enforcement; Flux prunes the 12 cluster-scoped CPs.

- [ ] **Step 1: Delete CP files + kustomization rows, run local validation, commit**

```bash
git rm infrastructure/configs/kyverno-policies/{require-labels,disallow-host-namespaces,require-resource-limits,require-non-root,disallow-host-path,disallow-latest-tag,require-non-default-serviceaccount,require-seccomp-runtimedefault,disallow-privilege-escalation,require-drop-all-capabilities,require-networkpolicy,require-readonly-rootfs}.yaml
# edit kustomization.yaml, then:
/homelab-yaml-validate
git commit -am "feat(kyverno): Phase 3 — delete 12 ClusterPolicies, ValidatingPolicies sole enforcement"
```

- [ ] **Step 2: Codex static review of Tasks 1+2 combined diff** (git-only, one-message verdict, `.claude/review-invariants.md` rubric). Process findings per receiving-code-review; fix CRITICAL/HIGH before merge.

- [ ] **Step 3: Merge + reconcile, watch prune**

```bash
git -C /Users/akhozya/source-code/homelab merge wt-overdue-closeout && git -C /Users/akhozya/source-code/homelab push && fr
kubectl get cpol
```
Expected: `No resources found` (allow one reconcile cycle).

- [ ] **Step 4: Gate B — VP-only enforcement matrix**

```bash
# (a) violator POD dry-run in home-assistant ns — PSA enforce=privileged there, so the
#     built-in PodSecurity admission (which runs before webhooks) cannot mask Kyverno
#     attribution, and host-field policies get direct live tests. HA ns is excluded from
#     require-non-root + require-readonly-rootfs VPs (those are covered in (a2)).
kubectl apply --dry-run=server -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: gate-b-violator, namespace: home-assistant}
spec:
  hostNetwork: true
  volumes: [{name: h, hostPath: {path: /etc}}]
  containers:
    - name: c
      image: nginx:latest
      securityContext: {allowPrivilegeEscalation: true}
      volumeMounts: [{name: h, mountPath: /h}]
EOF
# expect: DENIED; error names 8 policies: disallow-host-namespaces, disallow-host-path,
# disallow-latest-tag, require-labels, require-resource-limits, require-seccomp-runtimedefault,
# require-drop-all-capabilities, disallow-privilege-escalation.
# (NOT expected: require-non-root/-readonly-rootfs [HA ns excluded], require-non-default-
# serviceaccount [matches controllers only, not Pods], require-networkpolicy [ns has NPs].)

# (a2) violator DEPLOYMENT dry-run in n8n — PSA enforce applies to Pods, not workload
#     objects (Deployments only get warnings), so Kyverno autogen is the denier here.
#     This is the only live test of the autogen'd Deny path — the riskiest migration piece —
#     and the only way to trigger require-non-default-serviceaccount (deployments/STS/DS match).
kubectl apply --dry-run=server -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: gate-b-violator-deploy, namespace: n8n}
spec:
  replicas: 1
  selector: {matchLabels: {app: gate-b-violator}}
  template:
    metadata: {labels: {app: gate-b-violator}}
    spec:
      containers:
        - name: c
          image: nginx:latest
EOF
# expect: DENIED; error names AT LEAST: require-non-default-serviceaccount, require-non-root,
# require-readonly-rootfs (the three not provable in (a)) — plus autogen'd others
# (latest-tag, limits, seccomp, drop-caps, privesc). PSA restricted-ns WARNINGS in the
# response are fine; the deny must come from Kyverno policy names.
# Across (a)+(a2): all 11 pod-relevant VPs + SA proven live. Any missing name = that VP
# silently not enforcing → STOP, revert commit 2.

# (b) require-networkpolicy test (real temp ns, dry-run pod)
# DECLARED GitOps EXEMPTION (needs owner sign-off): kubectl create/delete of an empty,
# ephemeral, never-workload-bearing test ns, deleted in the same session. No Flux drift
# (Flux doesn't own it), no config change. Alternative if not approved: skip — policy
# attested by 8-day parity + canary only.
kubectl create ns gate-b-nptest
kubectl apply --dry-run=server -n gate-b-nptest -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: np-probe
  namespace: gate-b-nptest
  labels: {app: np-probe}
spec:
  containers:
    - name: c
      image: busybox:1.36.1
      resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 50m, memory: 32Mi}}
EOF
# expect: DENIED; message INCLUDES require-networkpolicy (npcount 0). The probe also
# violates non-root/seccomp/RoRFS/drop-caps — other names in the message are fine.
kubectl delete ns gate-b-nptest --timeout=120s
# expect: deletes clean. NOTE this is only a smoke check — an empty ns exercises no
# workload-object DELETE, so it does NOT re-prove the 2026-07-03 teardown-wedge fix.
# That fix is code-verified in the VP (operations CREATE/UPDATE + deletionTimestamp skip,
# checked 2026-07-12); the next real namespace teardown is the true regression point.

# (c) compliant pod still admitted (same n8n dry-run as Gate A step 5c) — expect created (server dry run)
```

- [ ] **Step 5: polr convergence spot-check (next background-scan cycle, ~1h)**

```bash
kubectl get polr -A -o json | jq '[.items[].results[].source] | unique'
```
Expected: eventually `["KyvernoValidatingPolicy"]` only; fail rows stay 0. (CP-sourced rows age out as reports regenerate — don't block on full convergence, just confirm no new `fail`.)

---

### Task 3: Kyverno Phase 4 — canary + tooling retire

**Files:**
- Delete: `infrastructure/configs/kyverno-policies/vp-canary.yaml` (+ its kustomization row + comment)
- Delete: `docs/scripts/kyverno-vp-parity.sh` (dual-engine comparison is meaningless post-CP; git history keeps it)
- Modify: `.claude/review-invariants.md` — Kyverno section: retire CP-era rows (autogen suppression on selector excludes, `=()` soft-anchor applies to CPs), keep/reword CEL rows (CanAutoGen silent-kill, `request.namespace` vs object rewrite, `orValue` soft-anchor rebirth) as the now-primary bug-classes
- Modify (chezmoi repo, NOT this worktree): `~/.claude/skills/kyverno-policy-promotion/` — `SKILL.md` + `scripts/scan-violations.sh`, `check-policy-action.sh`, `prepare-enforce.sh` from cpol/ClusterPolicy to vpol/ValidatingPolicy semantics (`validationActions` not `validate.failureAction`); then `/chezmoi-sync`

**Interfaces:**
- Consumes: Task 2's VP-only state (canary served its Gate-A/B purpose).

- [ ] **Step 1: Delete canary + parity script, update review-invariants, validate, commit**

```bash
git rm infrastructure/configs/kyverno-policies/vp-canary.yaml docs/scripts/kyverno-vp-parity.sh
# edit kustomization.yaml + .claude/review-invariants.md
/homelab-yaml-validate
git commit -am "chore(kyverno): Phase 4 — retire vp-canary + parity script, VP-era review invariants"
```

- [ ] **Step 2: Merge + `fr`; confirm canary pruned**

```bash
kubectl get vpol vp-canary
```
Expected: `NotFound`.

- [ ] **Step 3: Update the skill (chezmoi side) + `/chezmoi-sync`.** Verify with `bash ~/.claude/skills/kyverno-policy-promotion/scripts/check-policy-action.sh` listing 12 vpol Deny.

---

### Task 4: Right-sizing wave 1 — stateless apps + infra (requests→p95)

**Files (verify current value in-file before each edit; all are `resources.requests` on the main container unless noted):**

| File | Change (memory unless noted) | Grounding (7d p95 / max) |
|---|---|---|
| `apps/stirling-pdf/deployment.yaml` | requests 768Mi → **1408Mi** | 1347 / 1357Mi (limit 2Gi) |
| `apps/n8n/deployment.yaml` | requests 256Mi → **448Mi** | 408 / 520Mi |
| `apps/blocky/deployment.yaml` | requests 128Mi → **256Mi** | 222 / 339Mi |
| `apps/pricebuddy/deployment.yaml` | **`apprise` sidecar** requests 150Mi → **224Mi** (main `pricebuddy` container is 256Mi req vs 133Mi current — leave it; downsizing out of scope) | apprise current 198Mi (`kubectl top --containers` 07-12) |
| `apps/paperless-ngx/deployment.yaml` | requests 512Mi → **704Mi** | 666 / 677Mi |
| `infrastructure/controllers/trivy-operator/release.yaml` | operator requests 128Mi → **640Mi** | 607 / 638Mi (limit 768Mi) |
| `monitoring/configs/victoria-metrics/vmsingle.yaml` | requests 512Mi → **768Mi** | 739 / 805Mi (limit 1500Mi) |
| `monitoring/controllers/victoria-metrics/operator-release.yaml` | requests 64Mi → **160Mi** | 137 / 148Mi (limit 256Mi) |

Rules: request stays < limit; if a container's max exceeded its limit at any point the limit is wrong too — flag, don't silently bump. Where a pod has multiple containers, attribute with `kubectl top pod -n <ns> --containers` before editing (paperless especially).

- [ ] **Step 1: Edit the 8 files, local validation, commit**

```bash
/homelab-yaml-validate
git commit -am "fix(resources): right-size memory requests to 7d p95 (POP-110 pass, 8 workloads)"
```

- [ ] **Step 2: Merge + `fr`** — Flux rolls each Deployment (brief per-app blips; single-replica apps restart once). Immich excluded (soak).

- [ ] **Step 3: Verify**

```bash
kubectl get pods -A | grep -Ev 'Running|Completed'   # expect empty after rollouts settle
```
And node reservation still sane: `kubectl describe nodes | grep -A4 'Allocated resources'` — memory stays well under 80% on every node (pre-change: 9–21%).

---

### Task 5: Right-sizing wave 2 — database CRs (separate merge; rolls DB pods)

**Files:**
- Modify: `infrastructure/configs/databases/mysql/cluster.yaml`
  - `spec.mysql.resources.requests.memory`: 768Mi → **896Mi** (p95 870Mi, limit 1536Mi)
  - `spec.orchestrator.resources.requests.cpu`: 50m → **160m** (p95 156m, limit 750m)
  - `spec.proxy.haproxy.resources.requests.cpu`: 50m → **160m** (p95 154m, limit 500m)
- Modify: `infrastructure/configs/databases/redis-ha/redis-sentinel.yaml`
  - `resources.requests.cpu`: 10m → **50m** (p95 44m, limit 300m)

**Interfaces:**
- Consumes: wave 1 settled (Task 4 Step 3 green).
- Produces: Percona SmartUpdate roll (replicas-first, primary-last — proven safe 2026-07-03 crVersion bump); sentinel STS roll under quorum.

- [ ] **Step 1: Edit, validate, commit**

```bash
/homelab-yaml-validate
git commit -am "fix(resources): right-size DB CR requests to 7d p95 (mysql mem, orc/haproxy/sentinel cpu)"
```

- [ ] **Step 2: Codex static review of Tasks 4+5 combined diff** (same constraints as Task 2 Step 2).

- [ ] **Step 3: Merge + `fr`, watch the roll**

```bash
kubectl get ps -n databases -w   # Percona cluster back to ready
kubectl get pods -n databases -l app.kubernetes.io/component=sentinel
```
Expected: SmartUpdate converges Ready; 3 sentinels Running throughout (quorum 2 held). Transient `get cluster primary: empty response` during switchover is expected (seen 2026-07-03).

---

### Task 6: security-scan failure-notify (ExecStopPost + script hardening + worker notify distribution)

**Files:**
- Modify: `docs/scripts/node-maintenance/ansible/roles/security_scan/files/node-maintenance-security-scan.service` (ExecStopPost)
- Modify: `docs/scripts/node-maintenance/ansible/roles/security_scan/files/security-scan.sh` (exit nonzero on missing tools)
- Modify: `docs/scripts/node-maintenance/ansible/roles/security_scan/tasks/main.yml` (distribute notify script + creds to all hosts)

**Interfaces:**
- Consumes: `/usr/local/sbin/telegram-notify.sh` + `/etc/node-maintenance/telegram-{token,chat-id}` — **CP-only today** (installed by CP-side `install.sh:130`; workers never get them — the firewall role's `check-phase2-flag-age.sh` already guards `[ -x "$NOTIFY" ]` for exactly this reason, i.e. worker-side notifies are silently dead cluster-wide). Ansible control node = CP (drift-heal runs `node-config.yml` from CP against all hosts), so CP-local files can be `copy`'d to workers.

**Reality check (Codex-verified):** `security-scan.sh` is `set -uo pipefail` (no `-e`) with deliberate `|| true` on every tool invocation — lynis/rkhunter exit nonzero on *warnings*, which are normal monthly noise. A bare ExecStopPost would fire only on timeout/OOM/kill. Two real silent-failure classes need closing: (1) tool NOT INSTALLED → script prints "SKIP", exits 0, forever-silent; (2) unit-level death (45-min timeout, OOM). Mid-run tool crash stays swallowed — indistinguishable from warning-exits without per-tool exit-code taxonomy (declared cut C3).

- [ ] **Step 1: Harden security-scan.sh — missing tool = failure**

Add `FAIL=0` after the `trap` line; in the lynis `else` branch change `echo "lynis not installed — SKIP"` to also set `FAIL=1`, same for the rkhunter `else` branch; append as last line of the script:

```bash
exit "$FAIL"
```

(Note: the `FAIL=1` assignments must live OUTSIDE the `{...} >>"$SUMMARY"` block or in it — either works since the block isn't a subshell; keep the echo inside for the log, set the flag on the same line: `{ echo "lynis not installed — SKIP"; FAIL=1; }`.)

- [ ] **Step 2: Add ExecStopPost to the unit's `[Service]` section** (mirrors the proven sync.service pattern; `%%` = systemd escaping; `-x` guard mirrors check-phase2-flag-age for any node where notify is absent):

```ini
ExecStopPost=/bin/sh -c '[ "$SERVICE_RESULT" != "success" ] && [ -x /usr/local/sbin/telegram-notify.sh ] && /usr/local/sbin/telegram-notify.sh "❌ security-scan failed on $(hostname) (result=$SERVICE_RESULT exit=$EXIT_STATUS). Log: /var/log/node-maintenance/security-scan-$(date -u +%%Y-%%m).log" || true'
```

- [ ] **Step 3: Distribute notify script + creds to workers (ansible)** — append to `roles/security_scan/tasks/main.yml`:

```yaml
- name: Deploy telegram-notify.sh (CP-installed copy → all hosts)
  ansible.builtin.copy:
    src: /usr/local/sbin/telegram-notify.sh
    dest: /usr/local/sbin/telegram-notify.sh
    owner: root
    group: root
    mode: "0750"
  tags: [security-scan]

- name: Distribute telegram credentials (CP-local files → all hosts, 0600)
  ansible.builtin.copy:
    src: "/etc/node-maintenance/{{ item }}"
    dest: "/etc/node-maintenance/{{ item }}"
    owner: root
    group: root
    mode: "0600"
  loop:
    - telegram-token
    - telegram-chat-id
  no_log: true
  tags: [security-scan]
```

SECRET-SPRAWL NOTE (owner decision): this puts the bot token on all 3 nodes (root 0600) instead of CP-only. Same trust domain, and it un-silences EVERY worker-side notify path (check-phase2-flag-age, this scan, future heal scripts). Decline → keep Step 2's `-x` guard, workers stay notify-silent (half-close, declare in ANALYSIS).

- [ ] **Step 4: Lint + commit**

```bash
ansible-lint docs/scripts/node-maintenance/ansible/ && shellcheck docs/scripts/node-maintenance/ansible/roles/security_scan/files/security-scan.sh
git commit -am "feat(node-maintenance): security-scan failure notify — ExecStopPost + missing-tool exit + worker notify distribution"
```

- [ ] **Step 5: Merge + deploy via node pipeline** — sync timer pulls ≤10 min; role tasks apply at drift-heal (03:00 UTC) or when the user runs `sudo systemctl start node-maintenance-config.service`.

- [ ] **Step 6: Verify on CP + one worker (next day or post-manual-heal)**

```bash
ssh -p 65300 akhozya@gmk-k3s-control-plane 'grep ExecStopPost /etc/systemd/system/node-maintenance-security-scan.service'
ssh -p 65300 akhozya@worker-node 'test -x /usr/local/sbin/telegram-notify.sh && echo notify-present; grep -c ExecStopPost /etc/systemd/system/node-maintenance-security-scan.service'
```
Expected: ExecStopPost line on both; `notify-present` on worker (if Step 3 approved). Declared corner: the failure path fires next on a real failure or the 08-01 scan — pattern byte-parallel to sync/phase2 notifies proven in production.

---

### Task 7: Docs + memory closeout

**Files:**
- Modify: `docs/HOMELAB_ANALYSIS.md` — Upcoming-deadlines rows: strike 07-05 (verified: cronjob lastSuccessful 2026-07-12T03:07Z + NAS tar SHA-verified), 07-06 (partial c214e0cd 07-04 + this pass), 07-08 (ExecStopPost shipped; trivy soak closed 07-10 — concurrency 2→1 `5a882546`, gotcha recorded), rewrite the Kyverno Phase row to "Phases 2–4 DONE <date>, ~Oct-2026 ceiling met early"; platform table "12 Kyverno policies (all Enforce)" → CEL ValidatingPolicies wording
- Modify: `docs/HOMELAB_HISTORY.md` — one entry: overdue closeout (Kyverno Phase 3/4 with gate evidence, right-sizing tables with p95 grounding, ExecStopPost)
- Add: this plan file at `docs/superpowers/plans/2026-07-12-monthly-review-overdue-closeout.md`
- Memory (outside repo): update `project_deprecation_audit_2026-07.md` (Kyverno VP migration COMPLETE), `project_maintenance_schedules.md` (drop closed rows), `MEMORY.md` index hooks

- [ ] **Step 1: Edit docs, commit** (`docs: close July overdue items — kyverno VP-only, right-sizing, scan notify`), merge, push. Docs-only — no Codex review needed.

- [ ] **Step 2: Update memory files.**

---

### Task 8 (conditional, +24h): kyverno reports-controller limit re-check

**Files:**
- Maybe modify: `infrastructure/controllers/kyverno/release.yaml` `reportsController.resources.limits.cpu`

Post-CP-deletion the dual-engine report load halves — current data (limit-pinned at 500m, throttle peaks 0.96–0.99 during dual-run) may self-resolve.

- [ ] **Step 1: ≥24h after Task 2 merged, re-measure**

```bash
# via vmsingle port-forward
max_over_time((rate(container_cpu_cfs_throttled_periods_total{namespace="kyverno",pod=~"kyverno-reports-controller.*"}[5m])/rate(container_cpu_cfs_periods_total{namespace="kyverno",pod=~"kyverno-reports-controller.*"}[5m]))[24h:5m])
```

- [ ] **Step 2: Decide** — peak throttle ratio < 0.25 → close, no change (note in ANALYSIS). ≥ 0.25 → bump `limits.cpu: 500m → 800m` (requests unchanged), commit `fix(kyverno): reports-controller cpu limit 500m->800m (post-migration throttle persists)`, merge, `fr`.

---

## Deliberate cuts + assumptions (declared, with grounding status)

| # | Item | Status |
|---|---|---|
| C1 | Flux controllers (helm 209/389Mi, source 226/272Mi, kustomize 153/164Mi vs 64Mi requests) NOT right-sized | CUT — needs flux-system gotk patches (invasive) for a requests-only cosmetic warn; controllers are restart-tolerant. Revisit if a node shows memory pressure |
| C2 | immich-server (952Mi/512Mi in Popeye) NOT right-sized | CUT — 48h soak until ~07-14 18:35; pre-cutover pod data anyway. Fold into T7 immich track |
| C3 | ExecStopPost failure path untested live | CUT — byte-parallel to proven sync/phase2 notifies; forcing a scan failure not worth 45 min |
| C4 | Breaker-drop storm (07-07→07-11) not root-caused | ACCEPTED — correlated with trivy churn + k3s 1.36.2 reboots + ended at kyverno 3.8.2 rollout; drops 0 for >24h; parity/freshness independently proven post-storm |
| A1 | p95 targets include the storm + weekly-reboot churn week | ACCEPTED — slight over-provision is the safe direction for requests; headroom 16–21% |
| A2 | VP Deny == CP Enforce verdicts | GROUNDED — 8-day two-engine parity all-clean + offline CLI corpus (07-04) + Gate A/B live admission tests in-plan |
| A3 | Gate B two-violator strategy (Pod in PSA-privileged HA ns + Deployment in n8n) names every violated policy in the deny response | GROUNDED in design (each field maps to one policy; HA ns dodges PSA masking; Deployment dodges PSA entirely and exercises autogen) — if Kyverno truncates the aggregate message, fall back to per-policy single-violation objects before declaring failure |
| A6 | ~~host-path/host-namespaces untestable live~~ | RESOLVED by Codex review — home-assistant ns is PSA `enforce: privileged`, giving direct live admission tests for both host policies. Full 12/12 live coverage across Gate B (a)+(a2)+(b) |
| A7 | PSA `enforce` label denies Pods only, not Deployments (warn-only on workloads) — Gate B (a2) relies on this | GROUNDED in upstream PSA semantics (workload resources get warnings, admission denial applies to Pods); if a Deployment dry-run in n8n unexpectedly PSA-denies, rerun (a2) in home-assistant ns and drop non-root/RoRFS from expected names |
| A8 | Distributing the Telegram bot token to worker nodes (Task 6 Step 3) is acceptable secret sprawl | OWNER DECISION — same trust domain (root 0600 on cluster nodes), fixes all worker-side silent notifies; fallback documented (`-x` guard, workers stay silent) |
| A4 | No VMRule depends on CP-era metrics | GROUNDED — live scan: only `KyvernoAdmissionControllerDown` (up-based). Stale memory claim about a daily-summary rule refuted |
| A5 | Sentinel/Percona request changes roll cleanly | GROUNDED by precedent (07-03 crVersion SmartUpdate; sentinel quorum roll 1199988d) — still gated behind wave-1-settled + watched live |
