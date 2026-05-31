# Reboot Pod-Network Wedge — Root Cause + Prevention Plan (v2, post-review)

**Status:** Stage 1 + 2 + 3 IMPLEMENTED. Stage 1 phase2 nat-jump gate (`7743ceeb`); Stage 2 ufw-heal phase-G CNI re-heal (`f3731770`); Stage 3 HA CoreDNS via an ADDITIVE `coredns-ha` Deployment (replicas=3, spread) behind the existing kube-dns Service — NOT the `--disable`+cutover path (that needed a CP reboot + multi-minute DNS gap). The additive approach: zero DNS gap, no reboot, no addon fight, and a botched apply can't cause an outage (addon keeps serving). `--disable` uninstall of the now-redundant addon deferred to a future reboot window. Revised after 3-agent adversarial review (2026-05-31) — v1's root cause + all three fixes were wrong in specifics; corrected below.
**Incident:** 2026-05-30 weekly node-maintenance reboot. worker-node came up `Node.Ready`, phase2's ClusterIP gate PASSED, node was uncordoned — but pod→ClusterIP/DNS was dead cluster-wide ~25 min (CoreDNS `0/1`, mass CrashLoopBackOff on DNS i/o timeout). Cleared only by a **manual** `sudo systemctl restart k3s-agent` at 13:27. Goal: never need that manual step again.

---

## 1. Verified root cause — `ufw-heal` flushes the nat POSTROUTING jumps; portmap never re-adds them

**Not** kube-proxy (KUBE-SERVICES was fine — host-netns `10.43.0.1:443`→401, kube-proxy `:10256`→200, 587 nat rules healthy). **Not** #8793 mark-loss (opposite-polarity symptom; no `iptables-save|restore` of nat occurs). The mechanism, reconstructed from the live journal:

1. 13:02 boot — k3s/kube-proxy/flannel program nat cleanly (bundled iptables v1.8.11).
2. **UFW comes up disabled** after reboot (known recurring drift — ip6tables module race; the `UfwDisabled` class). So `ufw-heal-post-k3s.service` (`After=k3s-wait-ready`) hits its **disabled-recovery branch**: `phase-b: reload no-op (ufw disabled) — recovering: flush-all + force-enable`.
3. `/lib/ufw/ufw-init flush-all` calls `flush_builtins()` **unconditionally** (independent of `MANAGE_BUILTINS=no`), running `iptables -t nat -F POSTROUTING` (+PREROUTING/OUTPUT) → **deletes the `-j CNI-HOSTPORT-MASQ`, `-j KUBE-POSTROUTING`, `-j FLANNEL-POSTRTG` jump rules** from the built-in POSTROUTING chain.
4. Flannel self-heals ~16s later (13:08:19 "Some iptables rules are missing; deleting and recreating") and re-adds `FLANNEL-POSTRTG`. **portmap CNI does NOT** — it is not a daemon (k8s#93091): `CNI-HOSTPORT-*` jumps are only created at pod-sandbox setup, never reconciled. So pod→ClusterIP/DNS masquerade stays broken.
5. Wedge persists 13:08→13:27 until **manual `systemctl restart k3s-agent`** rebuilds all chains.

**Why `flush-all` runs at all:** UFW booting *disabled* is the trigger. Every incident-day heal run hit the disabled-recovery path. Keep UFW enabled across boot and the nat-flushing branch never fires.

**Why the shipped mitigations missed it:**
- `prefer-bundled-bin: true` (active) governs k3s's own iptables calls — irrelevant to a `flush-all` issued by UFW.
- phase2's gate (`clusterip-probe.sh`) probes **host netns** (`10.43.0.1:443` + `:10256/healthz`) — both pass during a pod-netns masquerade wedge → false-pass → uncordoned a broken node.

**Confirmation still needed (root, during Stage-2 reboot test):** `iptables -t nat -S POSTROUTING` immediately before/after a `flush-all`, showing the CNI-HOSTPORT/KUBE/FLANNEL jumps disappear. (Couldn't capture read-only.)

---

## 2. Corrected assumptions (v1 errors caught in review)

| v1 claim | Corrected |
|---|---|
| Trigger = `ufw reload` → nat re-serialize (#8793 mark-loss) | `ufw reload` never touches nat here (`MANAGE_BUILTINS=no`, no `*nat` in before.rules). Trigger = `ufw-init flush-all` `iptables -t nat -F POSTROUTING` on the disabled-recovery path. Symptom = flushed jumps, not a dropped mark. |
| Stage-2 fix = symlink bundled binary / scope `ufw reload` | Neither stops a `-F` flush; symlink path `/var/lib/rancher/k3s/...` doesn't exist (data-dir `/mnt/k8s-storage/rancher/k3s`). |
| Stage-1 probe `nsenter --net … getent hosts …` detects pod DNS | `nsenter --net` ≠ `--mount` → host binary reads **host** resolv.conf (LAN DNS, no `cluster.local`) → NOTFOUND always. Probe never greens → would strand every worker. Only the `curl 10.43.0.1:443` half is valid under `--net`. |
| Stage-3 `--disable=coredns` is safe / "no DNS gap" | `--disable` **actively deletes** the addon-owned Deployment + kube-dns Service (clusterIP 10.43.0.10) by `objectset.rio.cattle.io/owner-*` label, regardless of Flux ownership. No zero-gap path on a single clusterIP. |
| HA CoreDNS mitigates the §1 wedge | It does NOT. A CNI-masquerade wedge breaks pod→10.43.0.10 regardless of replica count; CoreDNS `0/1` was a symptom. Stage 3 only helps the separate rolling-reboot replica-availability mode. |
| nftables proxy-mode is the root fix | Wrong chain set (CNI portmap, not kube-proxy). Dropped from plan. |

---

## 3. Prevention — corrected

### Stage 1 — IMPLEMENTED — Detection + auto-heal that actually sees a pod-netns wedge (closes "no manual")
**Shipped:** phase2.yml PLAY 1 adds a nat-POSTROUTING-jump gate after the host-netns ClusterIP gate, before settle/uncordon: asserts `iptables -t nat -S POSTROUTING` contains `-j CNI-HOSTPORT-MASQ` + `-j KUBE-POSTROUTING` (6×10s); if missing → rescue restarts k3s-agent → re-assert; persistent fail → serial:1 aborts, worker stays cordoned. Chosen over the static-netcheck-DaemonSet / nsenter forms for lowest risk (root-side, no new workload/Kyverno surface, no DNS-gap, avoids the `nsenter --net` resolv.conf bug the review caught). Takes effect on the next maintenance reboot. Follow-up (Stage 1b, optional): an end-to-end netcheck-DaemonSet probe for broader wedge coverage than the structural jump-check.

Original design notes (alternatives considered):
Add a gate to phase2 PLAY 1 (before uncordon) that detects pod→ClusterIP/DNS failure. Two valid implementations — pick in review:
- **(preferred) static `netcheck` DaemonSet + `kubectl exec`.** A pinned, Kyverno-compliant DaemonSet (busybox-class, image-pinned, limits, RoRFS+`/tmp`, NP, non-root); gate does `kubectl exec <netcheck-on-node> -- sh -c 'nslookup kubernetes.default.svc.cluster.local && wget -qO- https://10.43.0.1:443/healthz'`. Runs natively in the pod's own mount+net ns (correct resolv.conf), **no root**, reusable over SSH from `verify-clusterip.sh`. Cost: one boilerplate manifest.
- **(alt) host-netns POSTROUTING-jump check (root, cheap):** assert `iptables -t nat -S POSTROUTING` contains `-j CNI-HOSTPORT-MASQ` and `-j KUBE-POSTROUTING`. Directly detects this exact wedge; structural, not end-to-end. Good as a fast first-pass; pair with an end-to-end check.
- **(alt) `nsenter --net --mount --target <pause-pid>`** into a DaemonSet pod — only if not using the netcheck pod; needs the pause-container PID via `crictl inspect` (root); keep **phase2-only** (no NOPASSWD for SSH reuse). Drop the `--net`-only + `getent` form entirely.
Requirements: **tri-state** — pod/exec not-ready-yet = RETRY inside the `until` window (12×10s), not FAIL; only a found-but-failing target = WEDGED → existing restart-k3s-agent rescue → re-probe → abort-cordoned if still bad. N≥3 samples. Target a Ready DaemonSet pod by status (`alloy` DESIRED=3), not `loki-canary` (DESIRED=2, absent on CP). containerd sock = `/run/k3s/containerd/containerd.sock` (runtime dir, NOT the data-dir) on all nodes.
**This is the load-bearing stage: a recurrence self-heals with no operator action.** Land + validate first (reboot ONE worker).

### Stage 2 — IMPLEMENTED — Root fix: heal the CNI nat jump that ufw-heal's flush-all wipes
**Shipped:** `ufw-heal-post-k3s.sh` gains **phase-G** — when phase-b's disabled-recovery `flush-all` ran (`RECOVERED_FROM_DISABLED=1`) AND `-j CNI-HOSTPORT-MASQ` is missing from nat POSTROUTING AND the node is a worker (`k3s-agent.service` active), restart k3s-agent to rebuild CNI chains. CP-safe (never restarts `k3s` server — hangs). Boot-only (watchdog excluded), runs before phase-f so the UFW status check stays authoritative. Chosen over neutering UFW's `flush-all` (can't, it's UFW's own script) or nat snapshot/restore (host-vs-bundled iptables mismatch would propagate #8793 corruption). Covers BOTH planned and unplanned reboots (phase2's Stage-1 gate only covers planned). Takes effect at the next boot after the firewall role redeploys the script.

Approaches considered (and why phase-G won):
- **A. Keep UFW enabled across boot** so the disabled-recovery `flush-all` branch never fires. Addresses the trigger. Ties to the existing UFW-boots-disabled drift (ip6tables module ordering / `ufw.service` `Wants=`). Best if reliable.
- **B. Make `flush_builtins`/`flush-all` filter-only** — never `iptables -t nat -F`. UFW manages no nat here (`MANAGE_BUILTINS=no`, before.rules nat-count=0), so scoping the flush to filter+mangle loses nothing and protects CNI/flannel/kube nat jumps. One-line guard. Lowest-risk direct fix.
- **C. Post-heal CNI reconcile kick** — if any nat flush happened, force portmap to rebuild (restart svclb/hostPort pods, or a gated `k3s-agent` restart). Belt-and-suspenders; overlaps Stage 1's rescue.
Lean **B (+A)**. Node config → ansible `firewall`/`k3s_config` role (outside GitOps by necessity). Validate one worker, reboot-test, soak 24–48h, then second worker, CP last.

### Stage 3 — IMPLEMENTED (additive) — HA CoreDNS for rolling-reboot replica availability (NOT a §1 fix)
**Shipped:** `infrastructure/controllers/coredns-ha/` — a SECOND CoreDNS Deployment (`coredns-ha`, replicas=3, kube-system) whose pods carry `k8s-app: kube-dns`, so the existing `kube-dns` Service (10.43.0.10) load-balances across them + the addon's 2. Unique selector `app: coredns-ha` (no pod cross-adoption); reuses the addon's `coredns` ConfigMap + ServiceAccount; topologySpread hostname ScheduleAnyway (one-per-node, never strands Pending); PDB minAvailable=1; RoRFS + `/tmp`; image-pinned 1.14.2. Validated: kustomize/kubeconform/yamllint + Kyverno server-dry-run accepted. **Zero-gap, no reboot, no `--disable` risk** — the k3s addon is untouched, so a botched apply can't take DNS down (addon keeps serving). Result: any single node down leaves ≥2 CoreDNS serving.
**Why not the `--disable`+self-manage cutover (original design below):** it deletes the kube-dns Service by owner-label (DNS gap) and only activates on a CP k3s restart (hangs → CP reboot) = a multi-minute cluster-wide DNS outage on a healthy cluster. The additive layer reaches the same HA goal with none of that. The redundant addon can be `--disable`d at a future reboot window to converge on a single managed CoreDNS.

Original `--disable` design (deferred — for the eventual single-managed-CoreDNS convergence):
- **Mechanism:** `--disable=coredns` + self-manage in Flux, deployed under a **distinct addon basename** with the `objectset.rio.cattle.io/owner-*` labels **stripped**, so the k3s addon-delete (owner-label keyed) can't tear it down (k3s#1317 supported pattern). Dedicated Kustomization with **`force: true`** (current `infrastructure-controllers` is `force:false` → SSA conflicts with the `deploy@<node>` field manager). No autoscaler exists (Q5 resolved); k3s addon manifest is the replica source and actively re-asserts → co-management without `force` fights.
- **Cutover is an attended, sub-minute DNS gap, NOT zero-gap** (single clusterIP can't be owned by two Services simultaneously). Do it in a window, reboot flow paused, `cache 30` serving stale, `flux reconcile` pre-queued; delete-addon-then-Flux-create ordering so 10.43.0.10 is free at create. Rollback: revert commit (Flux prunes, frees IP) → remove `--disable` → k3s restart re-creates addon.
- **replicas=3, one-per-node** (`topologySpread maxSkew=1 hostname ScheduleAnyway` — do NOT also add a separate podAntiAffinity; same mechanism). replicas=2+ScheduleAnyway can co-locate → one node's reboot kills all DNS.
- **Reboot play must become CoreDNS-aware:** gate each node's reboot on "≥1 CoreDNS Ready on a node other than the one about to reboot" + wait the moved replica Ready before the next node. Neither Stage-1 resolve-probe nor the PDB gates this.
- PDB `minAvailable=1` + `unhealthyPodEvictionPolicy: AlwaysAllow` — safe (phase2 only cordons, never drains; PDB can't block).
- **Drop the kube-system NetworkPolicy from the critical path** — `require-networkpolicy` excludes kube-system (not invariant-mandated), and a CoreDNS ingress NP risks the outage it's meant to prevent: the `allow-dns-egress` Component only opens **UDP/53** egress, so an ingress NP would break **TCP/53** DNS. If kept: widen `allow-dns-egress` to TCP/53 FIRST, ship the CoreDNS NP Audit-only.
- Faithful-repro gaps to handle: pin image `rancher/mirrored-coredns-coredns:1.14.2`; Corefile `hosts /etc/coredns/NodeHosts` loses k3s auto-maintenance → own a NodeHosts refresh or drop the `hosts` plugin; add `seccompProfile: RuntimeDefault` (improvement); carry SA/RBAC, tolerations, priorityClass, RoRFS+`/tmp`, clusterIP pin.

### Dropped — nftables kube-proxy proxy-mode
Targets KUBE-* chains; the wedge is CNI portmap. Not in this plan.

---

## 4. Open questions for the next review pass
1. Stage 2: confirm B (filter-only flush) leaves all CNI/flannel/kube nat jumps intact and breaks no UFW function; verify A (UFW-enabled-across-boot) is achievable given the ip6tables-module drift history. Capture the root-level POSTROUTING before/after-flush proof.
2. Stage 1: static-netcheck-DaemonSet vs nsenter `--net --mount` — which is simpler to ship + maintain given Kyverno boilerplate and the SSH-reuse requirement? Does the netcheck pod on a freshly-rebooted node come Ready in time, or also race the wedge?
3. Stage 3: is the attended sub-minute DNS gap acceptable, or pursue a kubelet `--cluster-dns` repoint to a temporary second resolver to avoid it (heavier)? Confirm `force:true` adoption doesn't fight k3s before `--disable`.
4. Does the CoreDNS-aware reboot gate belong in phase2 generally (any single-replica critical addon), not just CoreDNS?

---

## 5. Sequencing
1. **Stage 1** (detection+auto-heal) — independent, removes the manual requirement even if the wedge recurs. Land + reboot-test ONE worker first.
2. **Stage 2** (root fix, B+A) — one worker, reboot-test (the real scenario), soak 24–48h, second worker, CP last.
3. **Stage 3** (decoupled HA CoreDNS) — only after 1–2; attended cutover in a window; replicas=3 + CoreDNS-aware reboot gate; NP dropped/Audit-first.
Invariants: GitOps for CoreDNS manifests; ansible for node config; one-node-first; attended; image-pin; NP-per-workload (CoreDNS NP exempt/deferred).

---

## 6. Evidence appendix
- Timeline (worker-node): 13:02 boot clean → 13:07 ufw-heal `flush-all`×3 (UFW disabled) → 13:08:19 flannel re-adds FLANNEL-POSTRTG (portmap does NOT) → wedge 13:08–13:27 → 13:27:31 manual `k3s-agent` restart clears it → ~13:41 a real reboot followed. phase2 PLAY 2 `failed=1` at "verify source-controller Available" (DNS down).
- `ufw-heal-post-k3s.{service,sh}` (`roles/firewall/files/`): `After=k3s-wait-ready`; disabled-recovery path runs `ufw-init flush-all` → `flush_builtins()` → `iptables -t nat -F POSTROUTING` (host `/usr/sbin/iptables` v1.8.13). `/etc/default/ufw` `MANAGE_BUILTINS=no`; before.rules/before6.rules `*nat` count = 0.
- `clusterip-probe.sh` (`roles/k3s_config/files/`): host-netns dual signal, N=3 — structurally blind to pod-netns wedge.
- phase2 gate: `phase2.yml` PLAY 1 ~232–288 (`become:true`); existing rescue = restart k3s-agent. Sock `/run/k3s/containerd/containerd.sock`.
- CoreDNS live: deploy `replicas` owned by `deploy@gmk-k3s-control-plane`; objects carry `objectset.rio.cattle.io/owner-{gvk,name}=Addon/coredns`; pods currently on CP + worker-node-2; Corefile `hosts /etc/coredns/NodeHosts`; no HPA/autoscaler. kube-dns→CoreDNS (blocky-dns is a separate LAN LoadBalancer). All 12 Kyverno enforce policies exclude kube-system. `infrastructure-controllers` Kustomization `prune:true force:false`.
- phase1.yml Flux-Ready preflight flake (separate, already fixed `a085baff`: retries 3×30s).
- Sources: k8s#93091 (portmap not a daemon — CNI-HOSTPORT rules don't self-heal), ufw `MANAGE_BUILTINS`/`flush_builtins` (Launchpad ufw #364558), k3s#1317 (addon override = `--disable` + self-manage under different name), k3s#7203 (flannel/FORWARD + firewall). Superseded: #8793 (mark-loss — wrong polarity, not this incident); nftables KEP-3866 (wrong chain set).
