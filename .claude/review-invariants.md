# Review invariants

For the `caveman:cavecrew-reviewer` pre-push gate. The reviewer already enforces CLAUDE.md hard invariants (image pin, every-ingress-has-NetworkPolicy, NP-port=container-port, DB-username=app, SOPS secrets, RoRFS+/tmp, GitOps-only) + CI (yamllint, kubeconform, shellcheck, sops-check, init-resources, image-pin) and catches generic bugs (selector≠template, off-by-one) unaided. This file covers what those miss. Flag real instances only; cite file:line. Verify name/GVK claims by grepping the target file before flagging.

## Established patterns — deviation is a smell

- App = base/overlay split: `apps/base/<app>/` (namespace, serviceaccount, deployment, service, storage, networkpolicy, ingress, certificate, kustomization) + `apps/staging/<app>/` (secrets, provisioning jobs, env patches). Flat single-dir is wrong.
- Namespace = bare app name (`mealie`, `immich`); kustomization sets top-level `namespace:`, children omit it.
- Mandatory pod label `app` OR `app.kubernetes.io/name` (Kyverno require-labels, Enforce). Hand-rolled apps use `app: <app>` as the selector label, not `app.kubernetes.io/*`.
- Ingress middleware chain, ordered: `traefik-redirect-https@kubernetescrd,traefik-security-headers@kubernetescrd,traefik-rate-limit-{standard|high-frequency}@kubernetescrd,traefik-csp@kubernetescrd`. authentik gets NO rate-limit (breaks auth flow). `ingressClassName: traefik`, host `<app>.h0melab.work`, `tls.secretName: <app>-tls-secret` backed by `certificate.yaml`.
- "Dual access" is NOT a second Ingress object — internal = Traefik Ingress; external = a hostname row in centralized SOPS `infrastructure/configs/staging/cloudflare/cloudflared.yaml` + an extra NetworkPolicy ingress from-block (`cloudflare-tunnel` ns). A second Ingress manifest for external is wrong.
- NetworkPolicy name `<app>-network-policy`; `podSelector.matchLabels.app: <app>`; `policyTypes: [Ingress, Egress]`. Ingress from-blocks (all on the container port): `traefik`, `cloudflare-tunnel` (if external), `uptime-kuma` (probe — not `monitoring` ns), same-ns `podSelector: {}` if a provisioning Job calls the app. Egress: DB→`databases` scoped `podSelector cnpg.io/cluster: main-postgres` TCP/5432; outbound HTTPS TCP/443 (bare in baseline — RFC1918 `except` is a per-app hardening, see Networking failure-modes).
- **DNS egress is NOT in the per-app NP anymore (R5, 2026-05-29 `6229d4ed`+`611b6320`).** The 14 standard apps get DNS from the shared component `apps/base/components/allow-dns-egress` (egress-only NP, UDP/53→`kube-system`), wired via `components:\n  - ../components/allow-dns-egress` in the base kustomization. So: a standard per-app NP MISSING a DNS egress block is CORRECT, not a bug — do NOT flag it; and re-adding a per-app DNS block is the regression (duplicates the component). homehub + linkwarden's meilisearch keep `egress: []` (DNS solely from the baseline). EXCEPTIONS keep their own DNS and are NOT wired: `blocky` (kube-dns podSelector + DoT 853 + public resolvers) and `obsidian` (ns-wide `podSelector: {}` NP that also feeds its `couchdb-init` Job's DNS).
- **An egress NP isolates Job pods.** Any NP with `policyTypes:[Egress]` selecting a pod flips it from unrestricted→deny-except-listed. The `allow-dns-egress` baseline deliberately EXCLUDES Jobs via `podSelector.matchExpressions:[{key: batch.kubernetes.io/job-name, operator: DoesNotExist}]` (canonical label on K3s ≥1.27) so the 6 egress-naked provisioning Jobs aren't clamped to DNS-only. A ns-wide `podSelector:{}` egress NP that forgets this exclusion silently breaks Jobs on their next run — flag it. (Those 6 Jobs still have no egress NP = open lateral-movement gap, R5-followup.)
- DB role declared in CNPG `cluster.yaml managed.roles[]` (`ensure: present`, `passwordSecret.name: <app>-db-user`) BEFORE the app; secret `<app>-db-user` under `infrastructure/configs/staging/databases/postgres/`, labels `cnpg.io/cluster: main-postgres` + `cnpg.io/reload: "true"`.
- Image variant suffix is load-bearing, match upstream's exact form: `-rootless`, `-fat`, `-standard-trixie`, or `vX.Y.Z` prefix. authentik pins tag + `imagePullPolicy: Always` (upstream re-publishes same tag).
- New-namespace app = 2-commit bootstrap: app added to `apps/staging/kustomization.yaml` first; governance entry to `infrastructure/configs/base/resource-governance/kustomization.yaml` AFTER Flux creates the ns — avoids the apps→infra-configs circular dep.
- Provisioning Jobs annotate `kustomize.toolkit.fluxcd.io/force: enabled` + set `ttlSecondsAfterFinished`. Deployments set `revisionHistoryLimit: 2`. `startupProbe` when cold-start >30s (Django/Rails/Spring/Authentik).

## Failure modes schema/CI cannot catch

### Flux / Helm
- `healthChecks[]`/`dependsOn[]` must match a real name AND real apiVersion/kind — wrong GVK/name silently never matches → Kustomization stuck NotReady forever. (Wave 1: `vm-operator` vs `victoria-metrics-operator`)
- `dependsOn` only gates on the dependency's Ready condition, which requires `wait: true` or `healthChecks` ON THE DEPENDENCY — else readiness is never proven and ordering races admission. (Flux docs / F-7)
- `wait: false` + a `healthChecks` block = dead config, gates nothing. (F-8)
- HelmRelease without `upgrade.remediation.retries` (default 0) = a failed upgrade is left stuck with no auto-rollback. (Flux docs)
- Renaming a Kustomization with `prune: true` deletes+recreates ALL its workloads (set `prune: false` first); `force: true` delete-recreates any resource on immutable-field conflict (clusterIP, selector) = downtime — scope it. (Flux docs)

### Kyverno
- `=(field)` optional anchor makes the check conditional — a container OMITTING the field passes (default `allowPrivilegeEscalation: true` slips through). It is NOT "too strict." Fix: a mandatory `deny`, not `=()`. (F-4 — reviewers commonly misread the direction)
- A rule whose `match`/`exclude` names any kind beyond `Pod` (or uses `names`/label selectors with JSON-patch mutate) makes Kyverno silently skip controller autogen → Deployments/StatefulSets go unguarded while the Pod rule "passes." Match `kind: Pod` only. (Kyverno #4306 / Wave 1)
- A Job label-exclude does NOT cover the autogen Job rule (Job `metadata.labels` carry only Flux labels, not pod-template labels) → Job recreate denied under Enforce. Use ns-scope exclude or fix the workload. (W8)
- A whole-namespace `exclude` on a PSS-privileged ns leaves host-namespaces/escalation fully unguarded there. Fix: workload `selector.matchLabels`. (F-38)
- Rules reading `request.userInfo`/Roles/Subjects must set `background: false` — that data is absent from background scans, so the rule silently no-ops outside admission. (Kyverno docs)

### NetworkPolicy
- AND/OR trap: `namespaceSelector` + `podSelector` under ONE `from`/`to` list item = AND; as SEPARATE list items = OR. One indent level turns "prometheus pod in monitoring ns" into "any pod in monitoring OR prometheus in ANY ns" — no API error. (CNCF / Apr 2026 n8n·linkwarden·mealie)
- `0.0.0.0/0` (or bare 443) egress without an `except:` for RFC1918 (10/8, 172.16/12, 192.168/16) lets a compromised pod reach cluster-internal services. (F-9 immich, F-11 n8n)
- DB-port egress (5432/3306/6379) must be scoped via `namespaceSelector` to `databases`, not `{}` (all-ns). (F-10)
- A pod selected for Egress with NO egress rule denies all egress including DNS → every lookup hangs ~30s (not "refused"). `namespaceSelector` matches namespace LABELS, not names — use `kubernetes.io/metadata.name`. (k8s docs)
- `hostNetwork: true` pods bypass NetworkPolicy entirely. (CNI docs)

### securityContext / PSS
- PSS Baseline forbids `hostPath` (its own control, independent of Restricted's volume allowlist) — a securityContext-clean pod still gets denied; a ns mounting hostPath (log collectors, backup Jobs) cannot drop below `privileged`. Prove a level change with `--dry-run=server` first. (F-45 — prior memory assumed the opposite)
- A PSS rejection leaves the Deployment "successfully applied" while the ReplicaSet silently fails to create pods — the violation surfaces only in ReplicaSet events, not Deployment status. (k8s docs)
- PSS Restricted needs `seccompProfile: RuntimeDefault` on the pod or EVERY container+init — one omission fails the whole pod; Baseline checks none of this. PSA is non-mutating (validates, never defaults) — relying on a defaulted field needs Kyverno mutate. (k8s docs)
- Don't delete a documented init/securityContext exclude — it resurrects a known crashloop. paperless-ngx s6-overlay needs the root `fix-permissions` init owning `/run` (else `CrashLoopBackOff: /run belongs to uid 0`). (incident ca3891c→d3b5036)

### Secrets / DB
- A plaintext secret literal in a ConfigMap where the app does NOT env-substitute (e.g. blocky `queryLog.target` parsed by pgx) — `.sops.yaml` encrypts only `^(data|stringData)$`, and sops-check guards `kind: Secret` only, so this leaks. Fix: a SOPS Secret with the literal inlined. (F-1 / blocky)
- A CNPG/Percona role must be in `Cluster.spec.managed.roles[]`, not just a labeled Secret → else `role does not exist (42704)` and the password is lost on PG restart. (linkwarden)
- An internal ingress missing the Authentik forward-auth middleware is exposed without SSO, not just unstyled. (F-37)

### Kustomize
- `commonLabels` mutates `spec.selector.matchLabels`, which is immutable on existing Deployments → `kubectl apply`/Flux fails. Use the `labels` transformer with `includeSelectors: false` for metadata-only labels. (Kustomize docs)
- `namePrefix`/`nameSuffix` auto-rewrites built-in name refs (Service selectors, configMapKeyRef) but NOT custom-resource refs, `patchesJson6902` targets, or external consumers — those break silently. configMap/secretGenerator append a content-hash suffix that breaks any consumer outside the same kustomization referencing a literal name. (Kustomize #972)

### Shell
- `A | grep -q X && echo Y || echo Z` — the pipe binds tighter than `||`, so the middle branch breaks; shellcheck misses the logic. Use `set -euo pipefail`, not bare `set -e`. (F-27 setup-node.sh, F-28 analyze-update.sh)

## Maintenance

Append a finding here when a review or incident reveals a class CI/CLAUDE.md miss. Drop an entry once CI or a Kyverno policy starts catching it mechanically (it then belongs in the gate, not here). Keep each line one fact + the incident/source that justifies it.
