# Cluster Reboot + Cluster Roll Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the kube-proxy-wedge blind spot in the reboot path and add a safe, dependency-ordered pod-roll primitive, so cluster maintenance stops causing the 2026-05-24-class cascade.

**Architecture:** Reuse the existing ansible phase1/phase2 reboot flow; add a ClusterIP-DNAT gate (single-sourced on-node probe) to phase2 + a CoreDNS-HA prerequisite. Add two chezmoi skills (`cluster-roll`, `cluster-reboot`) that orchestrate/monitor via kubectl + SSH.

**Tech Stack:** ansible (node-maintenance), bash (skill scripts, shellcheck/shfmt), kubectl/flux, k3s.

**Source spec:** `docs/archive/superpowers/specs/2026-05-24-cluster-reboot-and-roll-skills-design.md` (v2).

**Global constraints:** Claude has no sudo (CP/node sudo steps are printed for the user to run, TTY). GitOps invariants apply. Skill files live in `~/.claude/skills/` (chezmoi → `/chezmoi-sync`). Ansible changes deploy via `node-maintenance-sync` → `node-maintenance-config`; **blocked while `/var/lib/node-maintenance/phase2-pending` is set.**

---

## Task 0 — Shared on-node probe + skill verifier (no node-write risk; do first)

Single source of the ClusterIP verdict. Pure bash, testable against the live healthy cluster now.

**Files:**
- Create: `~/.claude/skills/cluster-reboot/scripts/clusterip-probe.sh` (canonical probe; later also shipped to nodes via ansible in Task 2)
- Create: `~/.claude/skills/cluster-reboot/scripts/verify-clusterip.sh` (SSH wrapper, pure verdict)

- [ ] **Step 1: Write `clusterip-probe.sh`** (runs ON a node; no sudo)

```bash
#!/usr/bin/env bash
# clusterip-probe.sh — verify k3s ClusterIP DNAT works from this node's host netns.
# Exit 0 = healthy (DNAT routed), 1 = wedged. No args.
set -euo pipefail
API_CIP="https://10.43.0.1:443/healthz"
code="$(curl -sS -m5 -k -o /dev/null -w '%{http_code}' "$API_CIP" 2>/dev/null || echo 000)"
case "$code" in
  401|200) echo "clusterip OK (api healthz=$code)"; exit 0 ;;
  *)       echo "clusterip WEDGED (api healthz=$code — DNAT missing/blackholed)"; exit 1 ;;
esac
```

- [ ] **Step 2: Write `verify-clusterip.sh`** (runs on workstation; SSHes node; pure verdict, exit 0/1, NO remediation text)

```bash
#!/usr/bin/env bash
# verify-clusterip.sh <ssh-alias> — run clusterip-probe on a node over SSH.
# Resolves SSH user/port from ~/.ssh/config via the alias. Exit 0 healthy / 1 wedged / 2 bad args.
set -euo pipefail
alias="${1:?usage: verify-clusterip.sh <ssh-alias e.g. ssh_worker_node2>}"
probe='code=$(curl -sS -m5 -k -o /dev/null -w "%{http_code}" https://10.43.0.1:443/healthz 2>/dev/null || echo 000); \
       case "$code" in 401|200) echo "OK $code"; exit 0;; *) echo "WEDGED $code"; exit 1;; esac'
if ssh -o ConnectTimeout=5 "$alias" "$probe"; then
  echo "[$alias] clusterip OK"; exit 0
else
  echo "[$alias] clusterip WEDGED"; exit 1
fi
```

- [ ] **Step 3: shellcheck + shfmt both** (per `/bash-scripting`)

Run: `shellcheck ~/.claude/skills/cluster-reboot/scripts/*.sh && shfmt -d ~/.claude/skills/cluster-reboot/scripts/*.sh`
Expected: no output (clean).

- [ ] **Step 4: Validate against live cluster** (worker-node healthy → expect OK 401; verified this session)

Run: `bash ~/.claude/skills/cluster-reboot/scripts/verify-clusterip.sh ssh_worker_node`
Expected: `[ssh_worker_node] clusterip OK`, exit 0.

- [ ] **Step 5: chmod + commit to dotfiles** (separate chmod call per Bash-tool quirk)

```bash
chmod +x ~/.claude/skills/cluster-reboot/scripts/clusterip-probe.sh ~/.claude/skills/cluster-reboot/scripts/verify-clusterip.sh
```
Then `/chezmoi-sync` (re-add + commit + push).

---

## Task 1 — CoreDNS HA (Option A): VERIFY k3s Addon behavior, THEN implement

**Risk:** core DNS. The Addon-reconcile + k3s-overwrite-on-restart timing is **unverified** (manifest dir is root-only). Verify empirically before writing the edit mechanism — do NOT assume.

**Files:**
- Modify: `docs/scripts/node-maintenance/ansible/roles/k3s_config/tasks/main.yml` (add CP-only CoreDNS-replicas task)
- Maybe modify: `docs/scripts/node-maintenance/ansible/group_vars/*` (add `coredns_replicas: 2`)

- [ ] **Step 1: Behavior spike (user runs sudo on CP, reports back).** Determine: (a) does AddOn revert a live `kubectl scale coredns --replicas=2` and how fast; (b) does k3s overwrite `coredns.yaml` on `systemctl restart k3s`.

Give user:
```bash
ssh -p 65300 -t akhozya@gmk-k3s-control-plane '
  sudo sed -n "/kind: Deployment/,/replicas:/p" /var/lib/rancher/k3s/server/manifests/coredns.yaml | grep -i replicas;
  sudo sha256sum /var/lib/rancher/k3s/server/manifests/coredns.yaml;
  kubectl -n kube-system scale deploy coredns --replicas=2; sleep 30;
  kubectl -n kube-system get deploy coredns -o jsonpath="{.spec.replicas} reverted?\n"'
```
Expected interpretation: if replicas returns to 1 within 30s → AddOn reconciles continuously (must edit source file). If it stays 2 → applies-on-change (file edit suffices until reboot).

- [ ] **Step 2: Write the ansible task** (CP-only; idempotent; post k3s-wait-ready via drift-heal). Insert in `k3s_config/tasks/main.yml` after the k3s-wait-ready deploy block:

```yaml
- name: CoreDNS HA — set replicas + anti-affinity in k3s addon source (CP)
  when: "'control_plane' in group_names"
  block:
    - name: Set CoreDNS replicas in addon manifest
      ansible.builtin.replace:
        path: /var/lib/rancher/k3s/server/manifests/coredns.yaml
        regexp: '(\n  replicas:) 1(\n)'
        replace: '\g<1> {{ coredns_replicas | default(2) }}\g<2>'
      register: coredns_replicas_edit

    - name: Re-apply CoreDNS addon if changed (AddOn controller picks up file change)
      ansible.builtin.command:
        cmd: k3s kubectl -n kube-system rollout status deploy/coredns --timeout=120s
      when: coredns_replicas_edit.changed
      changed_when: false
```

> NOTE: exact `regexp`/`replace` MUST be adjusted to the real file shape captured in Step 1 (the deployment may set replicas elsewhere or via template). Add `podAntiAffinity` via a second `blockinfile`/`replace` only after confirming the manifest's container/spec indentation in Step 1; if anti-affinity insertion is fragile, ship a `coredns-ha-patch` as a separate `kubectl patch` task instead. Decide in Step 1.

- [ ] **Step 3: Add var** `coredns_replicas: 2` to the appropriate `group_vars` file (match existing var style found in Step 1).

- [ ] **Step 4: Lint** (CP-hosted, per `/homelab-node-fix`)

```bash
cat docs/scripts/node-maintenance/ansible/roles/k3s_config/tasks/main.yml | ssh -p 65300 akhozya@gmk-k3s-control-plane "cat > /tmp/lint.yml && yamllint -d '{extends: relaxed, rules: {line-length: disable}}' /tmp/lint.yml && ansible-lint /tmp/lint.yml || true"
```

- [ ] **Step 5: Commit + push + deploy** (single-line commit; user triggers sudo deploy)

```bash
git add docs/scripts/node-maintenance/ansible/roles/k3s_config/tasks/main.yml docs/scripts/node-maintenance/ansible/group_vars/
git commit -m "node-maintenance: CoreDNS HA replicas=2 via k3s addon source (CP)"
git push
```
Then user runs: `ssh -p 65300 -t akhozya@gmk-k3s-control-plane "sudo systemctl start node-maintenance-sync.service && sudo systemctl start node-maintenance-config.service"`

- [ ] **Step 6: Verify** replicas=2 on different nodes, and survives a CP reboot (user-gated reboot test, or accept next weekly run as live validation).

Run: `kubectl -n kube-system get deploy coredns -o wide; kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide`
Expected: 2/2 Ready, on 2 different nodes.

---

## Task 2 — ClusterIP gate in phase2.yml (homelab PR; CI; protects unattended run)

**Files:**
- Modify: `docs/scripts/node-maintenance/ansible/phase2.yml` (PLAY 0 CP probe; PLAY 1 worker gate)
- Create: ship `clusterip-probe.sh` to nodes — add a `copy` task in `k3s_config` role → `/etc/node-maintenance/bin/clusterip-probe.sh` (reuse Task 0 file as the role `files/` source)

- [ ] **Step 1: Add probe file to role** — copy `clusterip-probe.sh` into `roles/k3s_config/files/`, add deploy task (CP+workers) to `dest: /etc/node-maintenance/bin/clusterip-probe.sh`, `mode: 0755`.

- [ ] **Step 2: PLAY 1 worker gate** — insert between `Wait for node Ready in k8s API` (line ~179-195) and `Uncordon node` (line ~196):

```yaml
- name: ClusterIP gate — verify DNAT on rebooted worker (self-heal kube-proxy if wedged)
  block:
    - name: Probe ClusterIP from the worker
      ansible.builtin.command: /etc/node-maintenance/bin/clusterip-probe.sh
      register: cip_probe
      until: cip_probe.rc == 0
      retries: 12
      delay: 10
      changed_when: false
      # runs on inventory_hostname (the worker); become from play
  rescue:
    - name: Self-heal — restart k3s-agent (kube-proxy re-sync)
      ansible.builtin.systemd_service:
        name: "{{ k3s_service }}"
        state: restarted
    - name: Re-probe ClusterIP after k3s-agent restart
      ansible.builtin.command: /etc/node-maintenance/bin/clusterip-probe.sh
      register: cip_probe2
      until: cip_probe2.rc == 0
      retries: 12
      delay: 10
      changed_when: false
      # if THIS still fails → task error aborts the serial:1 play (worker left cordoned,
      # phase2-pending retained, next worker NOT processed — documented in cluster-reboot SKILL.md)
```

- [ ] **Step 3: PLAY 0 CP gate** — after `CP stabilize — wait Flux kustomizations Ready` and before `CP stabilize pause`, add a `delegate_to: localhost` probe, `until rc==0 retries:12 delay:10`, `changed_when: false`. **Bounded retry, never single-shot.** Comment: checks DNAT routability, complementary to pod-Ready checks above.

- [ ] **Step 4: Lint** (CP-hosted yamllint + ansible-lint, as Task 1 Step 4, on `phase2.yml`).

- [ ] **Step 5: Commit + push; let CI `validate.yaml` pass** (do NOT bypass). Single-line commit.

```bash
git add docs/scripts/node-maintenance/ansible/phase2.yml docs/scripts/node-maintenance/ansible/roles/k3s_config/
git commit -m "node-maintenance: phase2 ClusterIP-DNAT gate + k3s-agent self-heal before uncordon"
git push
```
Verify CI green (`gh run watch` or check Actions).

- [ ] **Step 6: Deploy** (user sudo, mind phase2-pending interlock) + live validation deferred to next phase1 trigger.

---

## Task 3 — `cluster-roll` skill (chezmoi; requires CoreDNS≥2)

**Files:**
- Create: `~/.claude/skills/cluster-roll/SKILL.md`
- Create: `~/.claude/skills/cluster-roll/scripts/cluster-roll.sh`

- [ ] **Step 1: Write `cluster-roll.sh`** — driven by an explicit tier→object map (from spec v2 §(2) table). Structure:

```bash
#!/usr/bin/env bash
set -euo pipefail
SHARED=~/.claude/skills/_shared
VERIFY=~/.claude/skills/cluster-reboot/scripts/verify-clusterip.sh
NODES=(ssh_master_node ssh_worker_node ssh_worker_node2)

preflight() {
  # abort if CoreDNS < 2
  local r; r=$(kubectl -n kube-system get deploy coredns -o jsonpath='{.spec.replicas}')
  [ "${r:-0}" -ge 2 ] || { echo "ABORT: CoreDNS replicas=$r (<2). Run Task1 first."; exit 1; }
  # abort if any node wedged
  for n in "${NODES[@]}"; do bash "$VERIFY" "$n" >/dev/null || { echo "ABORT: $n wedged"; exit 1; }; done
}

# tier objects: "ns/kind/name" lists per tier (DNS, operators, platform, dnscache, apps)
# roll_tier <name> <objects...>: kubectl rollout restart each, then scoped rollout status --timeout=180s,
#   settle 20s, then re-verify clusterip on all nodes. On 'rollout status' showing stale pod (Flux-managed
#   restartedAt reverted) → kubectl delete pod fallback (see SKILL.md Flux caveat).
```

(Full tier object lists + `roll_tier`/Flux-stale-detection in the file; flags `--from-tier <name>`, `--tier <name>`, `--dry-run` by NAME.)

- [ ] **Step 2: shellcheck + shfmt** clean.

- [ ] **Step 3: `--dry-run` against live cluster** — prints the ordered plan, every workload from `kubectl get deploy,sts -A` mapped to a tier or SKIP (no orphans).

Run: `bash ~/.claude/skills/cluster-roll/scripts/cluster-roll.sh --dry-run`
Expected: tiers 1-5 listed with real objects; SKIP list shown; exit 0. Cross-check no namespace missing.

- [ ] **Step 4: Write `SKILL.md`** — frontmatter (when to fire: recycle pods, NOT reboots); tier table; rules (abort if CoreDNS<2/node wedged; skip data STS; CoreDNS roll-in-place; Authentik→pooler→DNS chain; Flux-stale-pod fallback); cross-refs.

- [ ] **Step 5: Live single-tier test** — `--tier dnscache` (lowest-risk, recovers itself), verify pods cycle + gate passes.

- [ ] **Step 6: `/chezmoi-sync`.**

---

## Task 4 — `cluster-reboot` skill (chezmoi; references merged gate)

**Files:**
- Create: `~/.claude/skills/cluster-reboot/SKILL.md`
- Create: `~/.claude/skills/cluster-reboot/scripts/watch-reboot.sh`
- (scripts from Task 0 already present)

- [ ] **Step 1: Write `watch-reboot.sh`** — polls `phase2-pending` (via SSH to CP), each node Node.Ready, `verify-clusterip.sh` per node, `_shared/pod-health.sh` baseline. On Ready-but-wedged → print remediation pointing at `rolling-restart-k3s.yml`. Bounded loop, no sudo.

- [ ] **Step 2: shellcheck + shfmt** clean.

- [ ] **Step 3: Write `SKILL.md`** — when/why; trigger (`sudo systemctl start node-maintenance-phase1.service`); 4-play chain; **partial-completion resume model** (serial:1 gate-fail aborts → failing worker cordoned + flag retained + next worker un-processed → re-trigger after remediation); the min commit containing the Task 2 gate; cross-refs (`/homelab-node-fix`, `/k8s-diagnostics`, `rolling-restart-k3s.yml`, `gotcha_k3s_reboot_ordering`).

- [ ] **Step 4: Dry validation** — `watch-reboot.sh` against the (idle) cluster prints all-green; verify-clusterip OK on all 3.

- [ ] **Step 5: `/chezmoi-sync`.**

---

## Self-review notes (spec coverage)

- Spec §(0) CoreDNS HA → Task 1 (verify-first). §(1) cluster-reboot + ansible gate → Tasks 2 + 4 + 0.
  §(2) cluster-roll → Task 3 + 0. Single-sourced probe → Task 0 file reused in Task 2 role.
- Deploy sequence respected: Task 1 (CoreDNS, prereq) → Task 2 (gate PR) → Task 3 (roll, needs ≥2) →
  Task 4 (reboot wrapper, refs merged gate). Task 0 first (no node risk, unblocks 2+4).
- Open item carried into execution: Task 1 Step 1 spike resolves the regexp/anti-affinity mechanism —
  intentionally a verify-then-write task, not a placeholder.
