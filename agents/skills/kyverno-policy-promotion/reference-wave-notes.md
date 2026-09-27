# Kyverno Policy Promotion — wave notes & situational deep-dives

Situational war-story detail behind SKILL.md's routing rows.

> Era note: incidents below predate the CP→VP migration (complete 2026-07-12) — snippets showing ClusterPolicy syntax (`=()` patterns, `exclude.any` selectors, `failureAction`) are historical; the *lessons* (Job-label gap, report lag, PSS interception, ns-vs-label excludes) carry over to VPs unchanged. Current authoring syntax: SKILL.md + `.claude/review-invariants.md`.

## `=()` vs PSS mandatory-pattern — when absence is benign vs a regression (F-4 W8)

Use `=()` only for fields whose absence is benign (e.g., `=(initContainers)`/`=(ephemeralContainers)` since pods without init/ephemeral are normal). For security-critical fields whose absence = regression (e.g., `allowPrivilegeEscalation`, `capabilities.drop`, `readOnlyRootFilesystem`), use the **canonical PSS mandatory-pattern** shape — drop `=()` from `securityContext` AND the leaf field (making them required per-container), keep `=()` only on the optional list wrappers. Do NOT hand-roll a `deny: NotEquals` block for boolean fields: `false || 'true'` JMESPath coercion (false is falsy) makes them error-prone. Mandatory-pattern matches upstream Kyverno PSS policies. (Validated F-4 W8.)

## A pod-label exclude does NOT cover a Job (W8 2026-05-25)

The `autogen-*` rule evaluates the *controller resource* (Job/CronJob/Deployment/...), and the exclude `selector.matchLabels` is matched against THAT resource's own labels. Helm DaemonSets/Deployments (alloy, node-exporter, grafana) carry `app.kubernetes.io/name` on the workload metadata → label-selector works at both pod and controller level. **Jobs are the exception**: a Job's `metadata.labels` carry only Flux's `kustomize.toolkit.fluxcd.io/*` (the `job-name`/`app` labels live on the pod template), so a `job-name:` selector excludes the pods but NOT the Job → under Enforce the Job admission is blocked on recreation (`force: enabled` recreates it). For a Job: use **ns-scope exclude**, or **fix the workload** (e.g. RoRFS:true when writes are /tmp-isolated), or add an identical label to BOTH Job `metadata.labels` and the pod template. Tell-tale: repeated `PolicyViolation` events on `job/<name>` with rule `autogen-<policy>` while pods look clean. (Memory `[[gotchas]]` "Kyverno pod-label exclude does NOT cover a Job" holds the same finding.)

## Reports lag policy changes — beware false-clean (W8)

The `backgroundScanInterval` (~1h) drives per-pod re-eval, so after an exclude/fix: **controller-scoped** reports clear fast (your reliable signal the exclude works) but **per-pod** reports stay stale, and a soak-start baseline undercounts (F-6 W8: 11 at soak start → 23 after the full cycle). `scan-violations.sh` handles both: `--force-regen` deletes reports + restarts the reports-controller + polls until they repopulate; and a freshness guard exits **3** on `0 fail AND 0 pass` (reports absent = false-clean, not truly clean).

```bash
scan-violations.sh --policy <name> --force-regen   # trustworthy gate after a fix/exclude
```

## PolicyViolation events outlive a fix (~1h TTL) — popeye reads them (2026-06-07)

After fix-forward, polr can be fully clean while `kubectl get events --field-selector reason=PolicyViolation` still lists pre-fix violations; popeye **POP-1503** surfaces those events, false-dirtying its score (2026-06-07: B(89) on events stamped 2min before the fix landed). Purge per-ns (`kubectl delete events -n <ns> --field-selector reason=PolicyViolation`) or wait TTL before any popeye-based verify. Also: `--force-regen` right after deleting reports shows a LOW pass total (~35) from partial admission reports — wait for the background scan to repopulate (full = ~1.3k pass, all ns present) before trusting 0-fail.

## Seccomp live-pod cross-check — point-in-time (2026-06-07)

`scripts/seccomp-violators.sh` reads live pod specs directly (instant, no `backgroundScanInterval` lag) — authoritative during a soak/flip. But it is **point-in-time**: a CronJob/Job pod only appears while running, so a durable seccomp gap lives in the *controller's pod template*, not live pods. Check the CronJob/Job spec too (e.g. popeye surfaced only mid-run, 2026-06-07).

## Positive admission test — prove Deny actually blocks (W8 2026-05-25, VP-era update 2026-07-12)

A clean scan + `Deny` action confirms it's live, but a dry-run create of a violating pod confirms the webhook denies. Gotcha: a *bare* violating pod is intercepted by **PSS admission first** (`violates PodSecurity "restricted:latest"`) — that's NOT proof Kyverno fired. Craft a pod that passes PSS-restricted (runAsNonRoot, drop ALL, seccomp RuntimeDefault, allowPrivEsc false) and violates ONLY the target policy, in a non-excluded ns:

```bash
# e.g. require-readonly-rootfs: PSS-compliant but readOnlyRootFilesystem:false
kubectl run kyv-test -n <non-excluded-ns> --image=nginx:1.27.3 --dry-run=server --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"x","image":"nginx:1.27.3","securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":false,"capabilities":{"drop":["ALL"]}},"resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"50m","memory":"32Mi"}}}]}}'
# Expect (VP era): admission webhook "vpol.validate.kyverno.svc-fail-finegrained-<policy>" denied ... <message>
# (CP-era webhook was the shared "validate.kyverno.svc-fail")
```

VP fine-grained webhooks **short-circuit**: the deny names only the FIRST failing policy, so per-policy attribution needs a probe that is compliant-except-target (Gate B 2026-07-12 proved all 12 this way). Also mind LimitRanger — it injects default limits BEFORE validating webhooks, so a limit-less probe legitimately passes require-resource-limits in any ns with a LimitRange (probe in one without, e.g. trivy-scan).

## Namespace-exclude vs label-exclude precedent (F-38, 2026-05-26, `a35481fb`)

Don't add an entire namespace to `exclude:` to make a violation go away unless you genuinely accept ALL pods in that namespace bypassing the policy. Prefer workload-label exclude over namespace exclude. Precedent: F-38 narrowed `disallow-host-namespaces` whole-ns excludes for `databases`+`monitoring` → a `app.kubernetes.io/name: prometheus-node-exporter` label selector, which closed a real gap (`databases` is PSS `privileged`, so the whole-ns Kyverno exclude left host namespaces totally unguarded there). Verify the narrowed exclude with a positive `--dry-run=server` deny test in the previously-excluded ns.

## PSS namespace level ≠ a Kyverno exclude — and PSS Baseline forbids hostPath (F-45, 2026-05-26)

When a workload needs host access, raising the *namespace* PSS level (`pod-security.kubernetes.io/enforce`) is a blunter, separate lever from a Kyverno label-exclude. Before lowering a ns from `privileged`→`baseline`, scan for hostPath volumes (DaemonSet log collectors, backup Jobs) — Baseline blocks hostPath, so those ns can't drop. Prove any level change with a live `--dry-run=server` of a representative pod into a ns already at the target level *before* editing labels (F-45 2026-05-26: a memory-based assumption that baseline allows hostPath was caught here pre-commit). See `[[gotchas]]` "PSS Baseline FORBIDS hostPath".

## Reference incident — Wave 1, 2026-05-23

- F-3 + F-41 + F-42 + F-2b: extended `require-resource-limits` to init containers (Audit), surfaced 5 latent gaps (3 in-repo + 2 operator-managed), fix-forward (in-repo `resources:` + operator label-exclude), promoted Enforce. Total elapsed: ~25min from "0 fails baseline" to "0 fails Enforce live." Commits: c13d0403 (fix-forward), 8383ef35 (Enforce flip).
- See `[[project-ultrareview-learnings]]` memory file for full incident notes.
