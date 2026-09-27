---
name: networkpolicy-helper
description: Use when generating or auditing NetworkPolicy for a homelab app. Template covers dual ingress (internal + Cloudflare Tunnel), DB egress, outbound HTTPS, K3s K8s API ipBlock node-IP:6443. DNS egress is a SHARED component (allow-dns-egress), not per-app. Enforces container-port-not-service-port.
user-invocable: false
---

# NetworkPolicy Helper Skill

## When to Use
- Adding NetworkPolicy to new app
- Debugging "connection refused" errors
- App works without NetworkPolicy but breaks with it

## Authoring — load the template
The full multi-block YAML lives in `reference-template.md` (per-app NP, DB egress blocks, K8s API egress, operator data-plane egress, provisioning-Job NP). Load that file when actually writing a policy and copy the block you need. The rules below govern WHICH blocks apply — read them on every fire before reaching for the template.

## DNS egress is a shared component (R5, 2026-05-29)

DNS egress lives in ONE place: `apps/components/allow-dns-egress/` (egress-only NP, UDP/53→`kube-system`). Wire it into the app's `kustomization.yaml`:
```yaml
components:
  - ../components/allow-dns-egress
```
Then OMIT the per-app DNS egress block (re-adding it = duplication, the thing R5 removed). 14 standard apps use this. **Exceptions, NOT wired** (keep their own DNS, don't touch): `blocky` (kube-dns podSelector + DoT 853 + public resolvers) and `obsidian` (ns-wide `podSelector:{}` NP that also feeds its `couchdb-init` Job's DNS).

Two traps when reasoning about it:
- **An egress NP isolates Job pods.** Any NP with `policyTypes:[Egress]` selecting a pod flips it unrestricted→deny-except-listed. The component EXCLUDES Jobs via `podSelector.matchExpressions:[{key: batch.kubernetes.io/job-name, operator: DoesNotExist}]` (canonical label on K3s ≥1.27) so egress-naked provisioning Jobs aren't clamped DNS-only and broken on next run. A `podSelector:{}` egress NP without this exclusion silently breaks Jobs.
- **A nsless component NP only lands where SOME `namespace:` transformer exists.** The component NP has no `metadata.namespace`; it inherits from a base or overlay `namespace:`. An app with no transformer anywhere (was: authentik, uptime-kuma) lands the NP in `default` — add `namespace:` to its overlay. But do NOT add it where the base already sets it (double-declare = build break).
- An app whose egress was DNS-only ends at `egress: []` (keep `policyTypes:[Ingress, Egress]`; DNS from the baseline). e.g. homehub, meilisearch.

## Hardening a provisioning Job that NEEDS egress (R5-followup, 2026-05-29)

The baseline excludes Jobs → a Job that talks out (setup/init) is egress-**naked** (unrestricted) until you give it its OWN egress NP (template in `reference-template.md` § "Provisioning-Job egress NP"). Rules:
- **Select by `batch.kubernetes.io/job-name: <job>`**, not `app:` — Job pods don't get the app label. (Same canonical label the baseline excludes on.)
- **Egress-only is usually enough** — the app's INGRESS NP almost always already admits the Job (same-ns `podSelector:{}`, or an explicit `app: <job>` rule, or all-ns). Verify, don't add a redundant ingress rule.
- **Port = target CONTAINER port** (post-DNAT under kube-router), not the Service port.
- **curl-image Jobs harden tight; runtime-installer Jobs don't.** A `curlimages/curl` Job with deps pre-baked → tight NP (DNS + app port). A Job that `apt-get install`/`pip install` at runtime (was: mealie, uptime-kuma) needs 443/80→internet to bootstrap → any NP = theater. Proper fix = bake deps into a pinned image (zero-internet Job), else leave naked by decision. Don't ship a wide-internet NP and call it hardened.
- **Verify live by re-running the Job** under its new NP (delete → Flux force-recreates) → must still Complete. A too-tight egress silently breaks the next helm-hook run otherwise.

## Common Mistakes

### 1: Service Port vs Container Port
NP ports = CONTAINER port (post-DNAT under kube-router), NOT the Service port. WRONG = `port: 80` (service); CORRECT = `port: 8000` (container, from the deployment/pod spec). Find it:
```bash
kubectl get deploy <name> -n <ns> -o jsonpath='{.spec.template.spec.containers[0].ports[*].containerPort}'
```

### 2: Missing Dual-Access for Tunnel Apps

Apps reached via both Traefik AND CF Tunnel need BOTH ingress rules — a `traefik` namespaceSelector block AND a `cloudflare-tunnel` namespaceSelector block, each on `{container-port}` (both in the `reference-template.md` per-app template). Omitting the tunnel block = external access dies silently.

**Tunnel apps (need both)** — source of truth is the cloudflared NP's egress list (`infrastructure/configs/cloudflare/networkpolicy.yaml`), by target namespace: monitoring (grafana), uptime-kuma, audiobookshelf, authentik, databases (couchdb), immich, linkwarden, mealie, n8n, paperless-ngx, stirling-pdf. Derive from that file, don't trust this snapshot.

### 3: Missing K8s API Egress

Pods calling the K8s API (operators, sidecars) need an egress block to the control-plane node IP (template in `reference-template.md` § "K8s API egress block").

**API egress form — node-IP:6443, not ClusterIP:443.** Under kube-router (K3s NP enforcer), egress is evaluated POST-DNAT against the real backend, so the `kubernetes.default` ClusterIP `10.43.0.1:443` is already rewritten to `<CP-node>:6443` by the time the policy sees it — a `10.43.0.1/32:443` rule does NOT match. Proven: `cnpg-operator-policy` + `redis-operator-network-policy` work with ONLY `192.168.1.127/32:6443` and no ClusterIP rule (live, 210d+). Use the node IP + 6443.

**Operator NetworkPolicies — two traps (F-48 2026-05-29; why/history in memory `gotchas.md` "Operator NetworkPolicies: verify pod labels AND data-plane dial"):**
1. **Verify the actual pod labels first** — `kubectl get pod <op> -o jsonpath='{.metadata.labels}'`. ot-helm redis-operator is labelled `name: redis-operator`, NOT `app.kubernetes.io/name:`. A wrong selector matches ZERO pods → the NP is present but enforces nothing = gap stays open while reported closed (silent).
2. **An operator that dials its data plane needs egress to the managed pods, not just the API.** redis-operator dials redis(6379)+sentinel(26379) directly (`checkRedisServerRole`); CNPG's manager dials instances on 5432+8000. Don't assume API-exec. Grep operator logs for `dial tcp` to confirm, then add the data-plane egress block (`reference-template.md` § "Operator data-plane egress block").

Naming: `<app>-network-policy` (`percona-operator-network-policy` is the precedent; `cnpg-operator-policy` is the legacy odd-one-out).

### 4: Missing Database Egress

Apps talking to a DB need an egress block to the `databases` namespace on the engine port — PostgreSQL `5432` (via PgBouncer), MySQL `3306` (via HAProxy), Redis `6379`. Blocks in `reference-template.md` § "Database egress blocks".

### 5: Missing uptime-kuma / monitoring ingress

Two distinct sources — don't conflate:
- **uptime-kuma** ns — HTTP uptime probe on the app's **container port** (every externally-monitored app, e.g. mealie).
- **monitoring** ns — VMAgent metrics scrape on **metrics-port** (only if the app exposes `/metrics`; often 9090, 9187, 9121).

Both are `namespaceSelector` ingress rules — in the `reference-template.md` per-app template (uptime-kuma block on `{container-port}`, monitoring block on `{metrics-port}`).

## Debugging

```bash
# Test connectivity from pod
kubectl exec -n <ns> <pod> -- nc -zv <target> <port>

# Check NetworkPolicy is applied
kubectl get networkpolicy -n <ns>

# Describe for details
kubectl describe networkpolicy <name> -n <ns>
```

**REJECT vs DROP — read the error verb (kube-router; memory `gotchas.md` "kube-router renders NP-blocked egress as connection refused (RST)"):**
- `connection refused` to a peer that is **Running+Ready and listening** = kube-router actively REJECTed a policy-blocked egress with a RST. It looks identical to "nothing is listening" / app-down — but the cause is a MISSING EGRESS rule on the SOURCE pod, not the destination. Check the source NP before touching the target.
- `connection timed out` = packet silently DROPped — no matching rule, wrong CNI, or the target genuinely unreachable.
- Confirm causation: correlate the error's earliest log timestamp against the NP's apply time (`kubectl get netpol <x> -o jsonpath` AGE / Flux apply). F-48: 56 × "connection refused" to a 2/2-Running redis pod, earliest ts = exactly NP-apply → the NP, not redis.

## Tools Allowed
- `Bash(kubectl *)`
- `Read`
- `Edit`
- `Write`
