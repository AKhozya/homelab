# NetworkPolicy Helper — authoring templates

Loaded on demand from `networkpolicy-helper/SKILL.md`. SKILL.md holds the rules that govern WHEN/HOW to use each block; load this file when actually authoring a policy and copy the relevant block. Every comment/port/label/ipBlock here is load-bearing — preserve it.

## Template: Complete NetworkPolicy (per-app)

Copy this, then DELETE the blocks the app doesn't need. `{container-port}` = container port, not Service port (§ "Service Port vs Container Port" in SKILL.md). DNS egress is NOT here — supplied by the shared `allow-dns-egress` component (§ "DNS egress is a shared component" in SKILL.md).

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {app}-network-policy
  namespace: {app}
spec:
  podSelector:
    matchLabels:
      app: {app}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Web traffic via Traefik
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: traefik
      ports:
        - protocol: TCP
          port: {container-port}
    # Cloudflare Tunnel (if external)
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: cloudflare-tunnel
      ports:
        - protocol: TCP
          port: {container-port}
    # Uptime probe via uptime-kuma (external apps)
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: uptime-kuma
      ports:
        - protocol: TCP
          port: {container-port}
    # Prometheus scraping (if metrics exposed)
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: {metrics-port}
  egress:
    # DNS is NOT here — supplied by the shared allow-dns-egress component.
    # Wire it in the BASE kustomization.yaml instead:
    #   components:
    #     - ../components/allow-dns-egress
    # (see "DNS egress is a shared component" in SKILL.md). Do NOT add a per-app DNS block.
    # Database (if needed)
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: databases
      ports:
        - protocol: TCP
          port: 5432  # PostgreSQL
    # External HTTPS (if needed)
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
      ports:
        - protocol: TCP
          port: 443
```

## Database egress blocks (drop into `egress:`)

```yaml
egress:
  # PostgreSQL via PgBouncer
  - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: databases
    ports:
      - protocol: TCP
        port: 5432
  # MySQL via HAProxy
  - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: databases
    ports:
      - protocol: TCP
        port: 3306
  # Redis
  - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: databases
    ports:
      - protocol: TCP
        port: 6379
```

## K8s API egress block (operators, sidecars)

API egress form — node-IP:6443, not ClusterIP:443 (see SKILL.md § "K8s API Egress" for the kube-router POST-DNAT why).

```yaml
egress:
  - to:
      - ipBlock:
          cidr: 192.168.1.127/32  # control-plane node (real API endpoint)
    ports:
      - protocol: TCP
        port: 6443
```

## Operator data-plane egress block (operator → managed pods)

An operator that dials its data plane needs egress to the managed pods, not just the API (see SKILL.md § "K8s API Egress" trap 2). redis-operator dials redis(6379)+sentinel(26379) via `checkRedisServerRole`; CNPG's manager dials instances on 5432+8000. Grep operator logs for `dial tcp` to confirm.

```yaml
  - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: databases
        podSelector:
          matchExpressions:
            - {key: app, operator: In, values: [redis-replication, redis-sentinel-sentinel]}
    ports:
      - {protocol: TCP, port: 6379}
      - {protocol: TCP, port: 26379}
```

## Provisioning-Job egress NP (R5-followup, 2026-05-29)

The `allow-dns-egress` baseline EXCLUDES Jobs → a Job that talks out (setup/init) is egress-**naked** (unrestricted) until you give it its OWN egress NP. Governing rules in SKILL.md § "Hardening a provisioning Job that NEEDS egress". Template:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: <job>-egress
  namespace: <app>
spec:
  podSelector:
    matchLabels:
      batch.kubernetes.io/job-name: <job>   # Jobs DON'T carry the app: label per-app NPs use
  policyTypes: [Egress]
  egress:
    - to:                                    # DNS — baseline excludes Jobs, so repeat it here
        - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}
      ports: [{protocol: UDP, port: 53}]
    - to:                                    # the one app it provisions, CONTAINER port
        - podSelector: {matchLabels: {app: <app>}}
      ports: [{protocol: TCP, port: <container-port>}]
```

## Reasons and examples behind the SKILL.md rules

| Rule in SKILL.md | Reason or example |
|---|---|
| Runtime-installer Jobs don't harden | A Job that `apt-get install`/`pip install` at runtime (was: mealie, uptime-kuma) needs 443/80→internet to bootstrap → any NP = theater. |
| Verify live by re-running the Job | A too-tight egress silently breaks the next helm-hook run otherwise. |
| Mistake 1: container port, not Service port | WRONG = `port: 80` (service); CORRECT = `port: 8000` (container, from the deployment/pod spec). |
| Mistake 2: both tunnel and Traefik ingress | Omitting the tunnel block = external access dies silently. |
| Operator NP: verify the pod labels first | A wrong selector matches ZERO pods → the NP is present but enforces nothing = gap stays open while reported closed (silent). |
