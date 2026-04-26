# Blocky Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace AdGuard Home (2 node-pinned Deployments) with Blocky (single Deployment, 2 replicas, native rolling) on the homelab K3s cluster. Blocky uses shared Redis for cache+state sync and CNPG Postgres for query log.

**Architecture:** GitOps via Flux. New manifests under `apps/base/blocky/` and `apps/staging/blocky/`. Cutover = single commit swapping kustomization references; rollback = `git revert`. Phase 1 (Redis HA via K8s-native operator) is a prerequisite covered by a separate spec. This plan assumes Phase 1 is complete and Redis exposes a `blocky` ACL user.

**Tech Stack:** K3s, Flux v2, SOPS+age, Kustomize, CloudNativePG, Kyverno, Prometheus + Grafana, Blocky DNS v0.29.0.

**Spec:** `docs/superpowers/specs/2026-04-26-blocky-migration-design.md`

---

## Prerequisites

Before starting Task 1, confirm Phase 1 (Redis HA) is complete:
- `kubectl get statefulset -n databases redis` shows operator-managed redis (or replicaset/deployment per chosen operator).
- `kubectl get secret -n databases redis-passwords -o json | jq -r '.data | keys[]'` includes `blocky-password`.
- `kubectl get configmap -n databases redis-acl -o yaml | grep -A1 "user blocky"` shows the new ACL user line.

If any check fails, stop and complete Phase 1 first.

## File Structure

Files **created** by this plan:
```
apps/base/blocky/
  namespace.yaml
  serviceaccount.yaml
  configmap.yaml
  secret.yaml                      # SOPS-encrypted Redis + PG passwords
  deployment.yaml
  service-dns-w1.yaml
  service-dns-w2.yaml
  service-metrics.yaml
  networkpolicy.yaml
  kustomization.yaml
apps/staging/blocky/
  cnpg-database.yaml               # CNPG Database CR
  blocky-db-user.yaml              # SOPS-encrypted PG user secret
  kustomization.yaml
infrastructure/configs/staging/resource-governance/small-tier/
  blocky.yaml                      # LimitRange + ResourceQuota
monitoring/configs/staging/blocky/
  servicemonitor.yaml
  prometheusrule.yaml
  dashboard-blocky.yaml            # community ID 13768 as ConfigMap
  dashboard-blocky-querylog.yaml   # custom Postgres dashboard
  kustomization.yaml
```

Files **modified**:
```
apps/staging/kustomization.yaml                                       # swap adguard-home -> blocky (CUTOVER step)
infrastructure/configs/base/databases/redis/networkpolicy.yaml        # add ingress from blocky ns
infrastructure/configs/base/databases/redis/acl-configmap.yaml        # add blocky user (Phase 1 may have done this — verify)
infrastructure/configs/staging/resource-governance/kustomization.yaml # add blocky.yaml, remove adguard-home.yaml
monitoring/configs/staging/kustomization.yaml                          # add blocky/ subdir
scripts/macos/setup-h0melab-resolver.sh                                # update header comment AdGuard -> Blocky
scripts/macos/README.md                                                # update doc references
docs/HOMELAB_ANALYSIS.md                                               # apps row + HA section
docs/HOMELAB_HISTORY.md                                                # append migration entry
```

Files **removed** (post-soak only, Task 24):
```
apps/base/adguard-home/                                                # entire dir
apps/staging/adguard-home/                                             # entire dir
infrastructure/configs/staging/resource-governance/small-tier/adguard-home.yaml
```

---

### Task 1: Create namespace + ServiceAccount

**Files:**
- Create: `apps/base/blocky/namespace.yaml`
- Create: `apps/base/blocky/serviceaccount.yaml`

- [ ] **Step 1: Create namespace.yaml**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: blocky
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
    kubernetes.io/metadata.name: blocky
```

- [ ] **Step 2: Create serviceaccount.yaml**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: blocky
  namespace: blocky
automountServiceAccountToken: false
```

- [ ] **Step 3: Validate**

Run: `kubectl apply --dry-run=client -f apps/base/blocky/namespace.yaml -f apps/base/blocky/serviceaccount.yaml`
Expected: `namespace/blocky created (dry run)` and `serviceaccount/blocky created (dry run)`. No errors.

- [ ] **Step 4: Commit**

```bash
git add apps/base/blocky/namespace.yaml apps/base/blocky/serviceaccount.yaml
git commit -m "feat(blocky): add namespace and serviceaccount"
```

---

### Task 2: Create CNPG Database + DB user

**Files:**
- Create: `apps/staging/blocky/cnpg-database.yaml`
- Create: `apps/staging/blocky/blocky-db-user.yaml`

- [ ] **Step 1: Generate Postgres password**

```bash
openssl rand -base64 32 | tr -d '\n='
```

Expected: 40+ char random string. Save to clipboard.

- [ ] **Step 2: Create blocky-db-user.yaml (plain, will SOPS-encrypt next)**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: blocky-db-user
  namespace: databases
  labels:
    cnpg.io/reload: "true"
  annotations:
    cnpg.io/cluster: main-postgres
type: kubernetes.io/basic-auth
stringData:
  username: blocky
  password: PASTE_GENERATED_PASSWORD_HERE
```

Replace `PASTE_GENERATED_PASSWORD_HERE` with the password from Step 1.

- [ ] **Step 3: SOPS-encrypt blocky-db-user.yaml**

```bash
sops -e -i apps/staging/blocky/blocky-db-user.yaml
```

Expected: file rewritten with `ENC[AES256_GCM,...]` blocks. Verify: `head -20 apps/staging/blocky/blocky-db-user.yaml`.

- [ ] **Step 4: Create cnpg-database.yaml**

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: blocky
  namespace: databases
spec:
  cluster:
    name: main-postgres
  name: blocky
  owner: blocky
  ensure: present
```

- [ ] **Step 5: Validate**

Run: `kubectl apply --dry-run=server -f apps/staging/blocky/cnpg-database.yaml`
Expected: `database.postgresql.cnpg.io/blocky created (server dry run)`. No errors.

- [ ] **Step 6: Commit**

```bash
git add apps/staging/blocky/cnpg-database.yaml apps/staging/blocky/blocky-db-user.yaml
git commit -m "feat(blocky): add CNPG database and user secret"
```

---

### Task 3: Create Blocky SOPS secret (Redis + PG passwords)

**Files:**
- Create: `apps/base/blocky/secret.yaml`

- [ ] **Step 1: Fetch passwords from existing secrets**

```bash
REDIS_PASS=$(kubectl get secret -n databases redis-passwords -o jsonpath='{.data.blocky-password}' | base64 -d)
echo "Redis password length: ${#REDIS_PASS}"
```

Expected: length > 0. If empty, Phase 1 didn't set up `blocky-password` — stop and fix Phase 1.

For PG password, decrypt the file we just created:
```bash
PG_PASS=$(sops -d apps/staging/blocky/blocky-db-user.yaml | yq -r '.stringData.password')
echo "PG password length: ${#PG_PASS}"
```

Expected: length > 0.

- [ ] **Step 2: Create secret.yaml (plain)**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: blocky-secrets
  namespace: blocky
type: Opaque
stringData:
  redis-password: PASTE_REDIS_PASS_HERE
  pg-password: PASTE_PG_PASS_HERE
```

Substitute the actual values.

- [ ] **Step 3: SOPS-encrypt**

```bash
sops -e -i apps/base/blocky/secret.yaml
```

Verify: `head -20 apps/base/blocky/secret.yaml` shows `ENC[AES256_GCM,...]`.

- [ ] **Step 4: Validate**

```bash
sops -d apps/base/blocky/secret.yaml | kubectl apply --dry-run=client -f -
```
Expected: `secret/blocky-secrets created (dry run)`.

- [ ] **Step 5: Commit**

```bash
git add apps/base/blocky/secret.yaml
git commit -m "feat(blocky): add SOPS secret for redis and pg passwords"
```

---

### Task 4: Create Blocky ConfigMap (config.yml)

**Files:**
- Create: `apps/base/blocky/configmap.yaml`

- [ ] **Step 1: Create configmap.yaml**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: blocky-config
  namespace: blocky
data:
  config.yml: |
    ports:
      dns: 53
      http: 4000

    connectIPVersion: dual

    upstreams:
      init:
        strategy: blocking
      groups:
        default:
          - https://security.cloudflare-dns.com/dns-query
          - https://dns.quad9.net/dns-query

    bootstrapDns:
      - upstream: 1.1.1.2
      - upstream: 1.0.0.2
      - upstream: 9.9.9.9
      - upstream: 149.112.112.112
      - upstream: 2606:4700:4700::1112
      - upstream: 2606:4700:4700::1002
      - upstream: 2620:fe::fe
      - upstream: 2620:fe::9

    conditional:
      mapping:
        cluster.local: 10.43.0.10

    customDNS:
      customTTL: 1h
      filterUnmappedTypes: true
      mapping:
        h0melab.work: 192.168.1.129,192.168.1.126

    blocking:
      denylists:
        default:
          - https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/multi.txt
          - https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/pro.plus.txt
          - https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/tif.txt
          - https://big.oisd.nl/
      clientGroupsBlock:
        default:
          - default
      blockType: zeroIp
      blockTTL: 30s
      loading:
        refreshPeriod: 24h

    caching:
      minTime: 60s
      maxTime: 0
      prefetching: true
      prefetchExpires: 2h
      prefetchThreshold: 5

    redis:
      address: redis.databases.svc.cluster.local:6379
      username: blocky
      password: ${REDIS_PASSWORD}
      database: 1
      required: false
      connectionAttempts: 5
      connectionCooldown: 3s

    queryLog:
      type: postgresql
      target: postgres://blocky:${PG_PASSWORD}@main-postgres-rw.databases.svc.cluster.local:5432/blocky?sslmode=require
      logRetentionDays: 7
      flushInterval: 30s
      fields:
        - clientIP
        - clientName
        - responseReason
        - responseAnswer
        - question
        - duration

    prometheus:
      enable: true
      path: /metrics

    log:
      level: info
      format: json

    minTlsServeVersion: "1.3"
```

- [ ] **Step 2: Validate**

```bash
kubectl apply --dry-run=client -f apps/base/blocky/configmap.yaml
```
Expected: `configmap/blocky-config created (dry run)`.

- [ ] **Step 3: Commit**

```bash
git add apps/base/blocky/configmap.yaml
git commit -m "feat(blocky): add blocky config"
```

---

### Task 5: Create Deployment

**Files:**
- Create: `apps/base/blocky/deployment.yaml`

- [ ] **Step 1: Verify Blocky version on Docker Hub**

```bash
curl -s "https://hub.docker.com/v2/repositories/spx01/blocky/tags?page_size=10" | jq -r '.results[] | select(.name | startswith("v")) | .name' | head -5
```

Expected: lists tags including `v0.29.0` or newer. If newer stable exists, use that.

- [ ] **Step 2: Create deployment.yaml**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: blocky
  namespace: blocky
  labels:
    app: blocky
spec:
  replicas: 2
  revisionHistoryLimit: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 0
      maxUnavailable: 1
  selector:
    matchLabels:
      app: blocky
  template:
    metadata:
      labels:
        app: blocky
    spec:
      serviceAccountName: blocky
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 100
        runAsGroup: 100
        fsGroup: 100
        seccompProfile:
          type: RuntimeDefault
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/hostname
                    operator: In
                    values:
                      - worker-node
                      - worker-node-2
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - topologyKey: kubernetes.io/hostname
              labelSelector:
                matchLabels:
                  app: blocky
      containers:
        - name: blocky
          image: spx01/blocky:v0.29.0
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            capabilities:
              add: ["NET_BIND_SERVICE"]
              drop: ["ALL"]
          ports:
            - { containerPort: 53, name: dns-tcp, protocol: TCP }
            - { containerPort: 53, name: dns-udp, protocol: UDP }
            - { containerPort: 4000, name: http, protocol: TCP }
          env:
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: blocky-secrets
                  key: redis-password
            - name: PG_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: blocky-secrets
                  key: pg-password
          resources:
            requests:
              cpu: "50m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
          livenessProbe:
            httpGet: { path: /, port: 4000 }
            initialDelaySeconds: 30
            periodSeconds: 30
            failureThreshold: 3
          readinessProbe:
            httpGet: { path: /, port: 4000 }
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 3
          startupProbe:
            httpGet: { path: /, port: 4000 }
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 30
          volumeMounts:
            - { name: tmp, mountPath: /tmp }
            - { name: config, mountPath: /app/config.yml, subPath: config.yml, readOnly: true }
      volumes:
        - { name: tmp, emptyDir: { sizeLimit: 64Mi } }
        - name: config
          configMap:
            name: blocky-config
```

- [ ] **Step 3: Validate**

```bash
kubectl apply --dry-run=server -f apps/base/blocky/deployment.yaml
```

Expected: `deployment.apps/blocky created (server dry run)`. **No Kyverno admission errors.** If Kyverno blocks, the error message names the violated policy — fix the manifest before continuing.

- [ ] **Step 4: Commit**

```bash
git add apps/base/blocky/deployment.yaml
git commit -m "feat(blocky): add deployment with anti-affinity and rolling update"
```

---

### Task 6: Create LoadBalancer Services (W1, W2) + metrics Service

**Files:**
- Create: `apps/base/blocky/service-dns-w1.yaml`
- Create: `apps/base/blocky/service-dns-w2.yaml`
- Create: `apps/base/blocky/service-metrics.yaml`

- [ ] **Step 1: Create service-dns-w1.yaml**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: blocky-dns-w1
  namespace: blocky
  annotations:
    # K3s servicelb assigns LB IP = node IP where pod with matching selector runs.
    # externalTrafficPolicy: Local routes traffic only to pod on same node.
    # With anti-affinity ensuring 1 pod per worker, this service binds to W1's IP (192.168.1.129).
    description: "DNS service bound to worker-node via servicelb Local policy. Expected LB IP: 192.168.1.129"
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  ports:
    - { port: 53, targetPort: 53, protocol: TCP, name: dns-tcp }
    - { port: 53, targetPort: 53, protocol: UDP, name: dns-udp }
  selector:
    app: blocky
```

- [ ] **Step 2: Create service-dns-w2.yaml**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: blocky-dns-w2
  namespace: blocky
  annotations:
    description: "DNS service bound to worker-node-2 via servicelb Local policy. Expected LB IP: 192.168.1.126"
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  ports:
    - { port: 53, targetPort: 53, protocol: TCP, name: dns-tcp }
    - { port: 53, targetPort: 53, protocol: UDP, name: dns-udp }
  selector:
    app: blocky
```

Note: With K3s servicelb + `Local` + 2 LoadBalancer Services + 1 pod per node, both Services get LB IPs (one per node where a pod runs). If only one Service existed, K3s would still assign 2 IPs (one per worker) — so why two Services? Because we want each node to have its own dedicated Service object for Uptime Kuma probes and clean per-node routing semantics. Both Services have identical selectors; differentiation comes from K3s servicelb's per-node IP assignment.

- [ ] **Step 3: Create service-metrics.yaml**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: blocky-metrics
  namespace: blocky
  labels:
    app: blocky
spec:
  type: ClusterIP
  ports:
    - { port: 4000, targetPort: 4000, protocol: TCP, name: http }
  selector:
    app: blocky
```

- [ ] **Step 4: Validate**

```bash
kubectl apply --dry-run=client -f apps/base/blocky/service-dns-w1.yaml -f apps/base/blocky/service-dns-w2.yaml -f apps/base/blocky/service-metrics.yaml
```

Expected: all three services created (dry run).

- [ ] **Step 5: Commit**

```bash
git add apps/base/blocky/service-dns-w1.yaml apps/base/blocky/service-dns-w2.yaml apps/base/blocky/service-metrics.yaml
git commit -m "feat(blocky): add LB and metrics services"
```

---

### Task 7: Create NetworkPolicy

**Files:**
- Create: `apps/base/blocky/networkpolicy.yaml`

- [ ] **Step 1: Create networkpolicy.yaml**

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: blocky-network-policy
  namespace: blocky
spec:
  podSelector:
    matchLabels:
      app: blocky
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # DNS from anywhere (LAN clients via servicelb)
    - ports:
        - { protocol: TCP, port: 53 }
        - { protocol: UDP, port: 53 }
    # Prometheus scrape from monitoring ns
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - { protocol: TCP, port: 4000 }
  egress:
    # CoreDNS for cluster.local
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
    # Redis (databases ns)
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: databases
          podSelector:
            matchLabels:
              app: redis
      ports:
        - { protocol: TCP, port: 6379 }
    # CNPG primary (direct, not via pooler)
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: databases
          podSelector:
            matchLabels:
              cnpg.io/cluster: main-postgres
      ports:
        - { protocol: TCP, port: 5432 }
    # Public DNS resolvers - DoT 853 + plain bootstrap 53
    - to:
        - { ipBlock: { cidr: 1.1.1.2/32 } }
        - { ipBlock: { cidr: 1.0.0.2/32 } }
        - { ipBlock: { cidr: 9.9.9.9/32 } }
        - { ipBlock: { cidr: 149.112.112.112/32 } }
        - { ipBlock: { cidr: 2606:4700:4700::1112/128 } }
        - { ipBlock: { cidr: 2606:4700:4700::1002/128 } }
        - { ipBlock: { cidr: 2620:fe::fe/128 } }
        - { ipBlock: { cidr: 2620:fe::9/128 } }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
        - { protocol: TCP, port: 853 }
    # HTTPS for DoH + blocklist downloads (CDNs cannot be IP-pinned)
    - ports:
        - { protocol: TCP, port: 443 }
```

- [ ] **Step 2: Validate**

```bash
kubectl apply --dry-run=server -f apps/base/blocky/networkpolicy.yaml
```

Expected: `networkpolicy.networking.k8s.io/blocky-network-policy created (server dry run)`.

- [ ] **Step 3: Commit**

```bash
git add apps/base/blocky/networkpolicy.yaml
git commit -m "feat(blocky): add network policy"
```

---

### Task 8: Update Redis NetworkPolicy to allow Blocky ingress

**Files:**
- Modify: `infrastructure/configs/base/databases/redis/networkpolicy.yaml:28-44`

- [ ] **Step 1: Read current redis NP**

```bash
cat infrastructure/configs/base/databases/redis/networkpolicy.yaml
```

Note the existing ingress rules (uptime-kuma, paperless-ngx, immich, same-namespace, monitoring).

- [ ] **Step 2: Add blocky ingress rule**

Edit `infrastructure/configs/base/databases/redis/networkpolicy.yaml`. Insert this block after the existing immich ingress rule (before "same namespace" rule):

```yaml
    # Allow ingress from blocky namespace
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: blocky
      ports:
        - protocol: TCP
          port: 6379
```

- [ ] **Step 3: Validate**

```bash
kubectl apply --dry-run=server -f infrastructure/configs/base/databases/redis/networkpolicy.yaml
```

Expected: `networkpolicy.networking.k8s.io/redis-network-policy configured (server dry run)`.

- [ ] **Step 4: Commit**

```bash
git add infrastructure/configs/base/databases/redis/networkpolicy.yaml
git commit -m "feat(redis): allow ingress from blocky ns"
```

---

### Task 9: Verify Redis ACL has blocky user (Phase 1 should have done this — check)

**Files:**
- Verify only: `infrastructure/configs/base/databases/redis/acl-configmap.yaml`

- [ ] **Step 1: Inspect ACL configmap**

```bash
grep "user blocky" infrastructure/configs/base/databases/redis/acl-configmap.yaml
```

Expected: line like `user blocky on >${REDIS_BLOCKY_PASSWORD} ~* &* +@all -@dangerous +keys +flushdb +info` (similar to paperless/immich pattern).

If missing, add to ACL configmap:

```yaml
data:
  users.acl: |
    user default off nopass ~* &* +@all
    user admin on >${REDIS_ADMIN_PASSWORD} ~* &* +@all
    user paperless on >${REDIS_PAPERLESS_PASSWORD} ~* &* +@all -@dangerous +keys +flushdb +info
    user immich on >${REDIS_IMMICH_PASSWORD} ~* &* +@all -@dangerous +keys +flushdb +info
    user blocky on >${REDIS_BLOCKY_PASSWORD} ~* &* +@all -@dangerous +keys +info
```

Note: `blocky` user has `+keys +info` for cache management but NOT `+flushdb` (Blocky should never flush; if it does, that's a bug).

- [ ] **Step 2: If modified, validate + commit**

```bash
kubectl apply --dry-run=server -f infrastructure/configs/base/databases/redis/acl-configmap.yaml
git add infrastructure/configs/base/databases/redis/acl-configmap.yaml
git commit -m "feat(redis): add blocky ACL user"
```

If file already had blocky user (Phase 1 created it), skip the commit.

---

### Task 10: Create base kustomization

**Files:**
- Create: `apps/base/blocky/kustomization.yaml`

- [ ] **Step 1: Create kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: blocky
resources:
  - namespace.yaml
  - serviceaccount.yaml
  - secret.yaml
  - configmap.yaml
  - deployment.yaml
  - service-dns-w1.yaml
  - service-dns-w2.yaml
  - service-metrics.yaml
  - networkpolicy.yaml
```

- [ ] **Step 2: Validate kustomize build**

```bash
kustomize build apps/base/blocky/ | head -40
```

Expected: prints YAML without errors. First doc is Namespace.

- [ ] **Step 3: Commit**

```bash
git add apps/base/blocky/kustomization.yaml
git commit -m "feat(blocky): add base kustomization"
```

---

### Task 11: Create staging kustomization

**Files:**
- Create: `apps/staging/blocky/kustomization.yaml`

- [ ] **Step 1: Create kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base/blocky
  - cnpg-database.yaml
  - blocky-db-user.yaml
```

- [ ] **Step 2: Validate kustomize build (with SOPS decryption simulated)**

```bash
kustomize build apps/staging/blocky/ 2>&1 | head -40
```

Expected: prints YAML. Will show encrypted secret values — that's fine, Flux decrypts in cluster.

- [ ] **Step 3: Commit**

```bash
git add apps/staging/blocky/kustomization.yaml
git commit -m "feat(blocky): add staging kustomization"
```

---

### Task 12: Create resource-governance entry

**Files:**
- Create: `infrastructure/configs/staging/resource-governance/small-tier/blocky.yaml`
- Modify: `infrastructure/configs/staging/resource-governance/kustomization.yaml`

- [ ] **Step 1: Create blocky.yaml**

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: blocky
spec:
  limits:
    - type: Container
      default:
        cpu: 500m
        memory: 512Mi
      defaultRequest:
        cpu: 50m
        memory: 128Mi
      max:
        cpu: 2000m
        memory: 2Gi
      min:
        cpu: 10m
        memory: 16Mi
    - type: Pod
      max:
        cpu: 4000m
        memory: 4Gi
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: namespace-quota
  namespace: blocky
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "3"
    limits.memory: 4Gi
    pods: "10"
    services: "5"
    persistentvolumeclaims: "1"
```

- [ ] **Step 2: Add to kustomization (do NOT remove adguard-home yet — that's the cutover step)**

Edit `infrastructure/configs/staging/resource-governance/kustomization.yaml`. Add `- small-tier/blocky.yaml` next to `- small-tier/adguard-home.yaml`.

- [ ] **Step 3: Validate**

```bash
kubectl apply --dry-run=server -f infrastructure/configs/staging/resource-governance/small-tier/blocky.yaml
```

Expected: LimitRange + ResourceQuota created (server dry run).

- [ ] **Step 4: Commit**

```bash
git add infrastructure/configs/staging/resource-governance/small-tier/blocky.yaml infrastructure/configs/staging/resource-governance/kustomization.yaml
git commit -m "feat(blocky): add resource governance"
```

---

### Task 13: Create monitoring assets (ServiceMonitor + PrometheusRule + dashboards)

**Files:**
- Create: `monitoring/configs/staging/blocky/servicemonitor.yaml`
- Create: `monitoring/configs/staging/blocky/prometheusrule.yaml`
- Create: `monitoring/configs/staging/blocky/dashboard-blocky.yaml`
- Create: `monitoring/configs/staging/blocky/kustomization.yaml`
- Modify: `monitoring/configs/staging/kustomization.yaml`

- [ ] **Step 1: Create servicemonitor.yaml**

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: blocky
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
      - blocky
  selector:
    matchLabels:
      app: blocky
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
```

- [ ] **Step 2: Create prometheusrule.yaml**

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: blocky-alerts
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: blocky
      rules:
        - alert: BlockyDown
          expr: up{job="blocky-metrics"} == 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Blocky DNS pod down on {{ $labels.instance }}"
        - alert: BlockyAllReplicasDown
          expr: count(up{job="blocky-metrics"} == 1) == 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "Both Blocky pods down — DNS LAN-wide outage"
        - alert: BlockyHighErrorRate
          expr: |
            sum(rate(blocky_response_total{response_code!~"NOERROR|NXDOMAIN"}[5m]))
            /
            sum(rate(blocky_response_total[5m])) > 0.05
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Blocky error rate >5% for 10m"
        - alert: BlockyBlocklistRefreshFailing
          expr: increase(blocky_failed_downloads_total[1h]) > 0
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "Blocklist download failing — lists may go stale"
        - alert: BlockyHighLatency
          expr: histogram_quantile(0.95, sum(rate(blocky_request_duration_seconds_bucket[5m])) by (le)) > 0.1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Blocky p95 query latency >100ms"
```

- [ ] **Step 3: Fetch Blocky dashboard from grafana.com**

```bash
curl -sL "https://grafana.com/api/dashboards/13768/revisions/latest/download" -o /tmp/blocky-dashboard.json
jq -r '.title' /tmp/blocky-dashboard.json
```

Expected: prints "Blocky" or similar title. If 404, search alternative dashboard ID via grafana.com.

- [ ] **Step 4: Wrap dashboard JSON as ConfigMap**

```bash
DASH=$(cat /tmp/blocky-dashboard.json)
cat > monitoring/configs/staging/blocky/dashboard-blocky.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: blocky-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  blocky.json: |
$(echo "$DASH" | sed 's/^/    /')
EOF
```

Verify: `head -10 monitoring/configs/staging/blocky/dashboard-blocky.yaml` and `wc -l monitoring/configs/staging/blocky/dashboard-blocky.yaml`.

- [ ] **Step 5: Create monitoring kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - servicemonitor.yaml
  - prometheusrule.yaml
  - dashboard-blocky.yaml
```

- [ ] **Step 6: Add monitoring/blocky to parent kustomization**

Edit `monitoring/configs/staging/kustomization.yaml`. Add `- blocky` to resources list.

- [ ] **Step 7: Validate**

```bash
kustomize build monitoring/configs/staging/blocky/ | head -10
kubectl apply --dry-run=server -f monitoring/configs/staging/blocky/servicemonitor.yaml -f monitoring/configs/staging/blocky/prometheusrule.yaml
```

Expected: build prints YAML; dry-run shows servicemonitor + prometheusrule created.

- [ ] **Step 8: Commit**

```bash
git add monitoring/configs/staging/blocky/ monitoring/configs/staging/kustomization.yaml
git commit -m "feat(blocky): add monitoring (servicemonitor, alerts, dashboard)"
```

---

### Task 14: Pre-cutover validation pass

- [ ] **Step 1: Lint all new manifests**

```bash
kustomize build apps/base/blocky/
kustomize build apps/staging/blocky/
kustomize build monitoring/configs/staging/blocky/
```

All three should print YAML without errors.

- [ ] **Step 2: Server dry-run all blocky resources**

```bash
sops -d apps/base/blocky/secret.yaml | kubectl apply --dry-run=server -f -
sops -d apps/staging/blocky/blocky-db-user.yaml | kubectl apply --dry-run=server -f -
kubectl apply --dry-run=server -f apps/base/blocky/namespace.yaml
kubectl apply --dry-run=server -f apps/base/blocky/serviceaccount.yaml
kubectl apply --dry-run=server -f apps/base/blocky/configmap.yaml
kubectl apply --dry-run=server -f apps/base/blocky/deployment.yaml
kubectl apply --dry-run=server -f apps/base/blocky/service-dns-w1.yaml
kubectl apply --dry-run=server -f apps/base/blocky/service-dns-w2.yaml
kubectl apply --dry-run=server -f apps/base/blocky/service-metrics.yaml
kubectl apply --dry-run=server -f apps/base/blocky/networkpolicy.yaml
kubectl apply --dry-run=server -f apps/staging/blocky/cnpg-database.yaml
kubectl apply --dry-run=server -f infrastructure/configs/staging/resource-governance/small-tier/blocky.yaml
kubectl apply --dry-run=server -f monitoring/configs/staging/blocky/servicemonitor.yaml
kubectl apply --dry-run=server -f monitoring/configs/staging/blocky/prometheusrule.yaml
```

Expected: every resource shows `created (server dry run)` or `configured (server dry run)`. **Zero Kyverno admission errors.** If any policy blocks, fix the manifest and re-run.

- [ ] **Step 3: Push branch (if not already on main)**

```bash
git push
```

This pushes all the per-task commits but **does NOT trigger a real Blocky deployment** because nothing in `apps/staging/kustomization.yaml` references `blocky/` yet.

- [ ] **Step 4: Optional — apply Database CR ahead of cutover to give CNPG time**

Manually apply only the Database CR + db-user secret so CNPG provisions the DB and role in advance:

```bash
sops -d apps/staging/blocky/blocky-db-user.yaml | kubectl apply -f -
kubectl apply -f apps/staging/blocky/cnpg-database.yaml
```

Wait + verify:
```bash
kubectl get database -n databases blocky
kubectl exec -n databases main-postgres-1 -- psql -U postgres -c "\du blocky"
```

Expected: Database CR `Status: Reconciled`, role `blocky` exists with attributes.

Verify role can create tables:
```bash
PG_PASS=$(sops -d apps/staging/blocky/blocky-db-user.yaml | yq -r '.stringData.password')
kubectl exec -n databases main-postgres-1 -- psql "postgres://blocky:${PG_PASS}@localhost:5432/blocky" -c "CREATE TABLE _ping(x int); DROP TABLE _ping;"
```

Expected: `CREATE TABLE` and `DROP TABLE` succeed. If permission denied, grant ownership:
```bash
kubectl exec -n databases main-postgres-1 -- psql -U postgres -d blocky -c "ALTER SCHEMA public OWNER TO blocky;"
```

---

### Task 15: CUTOVER — swap kustomization references

**Files:**
- Modify: `apps/staging/kustomization.yaml`

- [ ] **Step 1: Inspect current apps kustomization**

```bash
cat apps/staging/kustomization.yaml | grep -nE "adguard|blocky"
```

Note line numbers and exact text for `adguard-home` reference.

- [ ] **Step 2: Edit kustomization — add blocky, remove adguard-home**

Edit `apps/staging/kustomization.yaml`:
- Add line: `  - blocky` (alphabetical position, near other apps)
- Remove line: `  - adguard-home`

- [ ] **Step 3: Validate full apps build**

```bash
kustomize build apps/staging/ > /tmp/apps-built.yaml
grep -c "namespace: blocky" /tmp/apps-built.yaml
grep -c "namespace: adguard-home" /tmp/apps-built.yaml
```

Expected: blocky count > 0, adguard-home count == 0.

- [ ] **Step 4: Commit cutover**

```bash
git add apps/staging/kustomization.yaml
git commit -m "feat(blocky): replace adguard with blocky"
git push
```

- [ ] **Step 5: Trigger Flux reconcile**

```bash
fr
```

Watch:
```bash
watch -n 2 'kubectl get pods -n adguard-home; echo "---"; kubectl get pods -n blocky'
```

Expected sequence (~60-120 sec total):
- AdGuard pods enter `Terminating`
- Blocky namespace appears, Blocky pod starts `Pending` → `ContainerCreating` → `Running`
- Blocky pods become `Ready`
- AdGuard pods gone
- Blocky LB Services get IPs:
  ```
  kubectl get svc -n blocky blocky-dns-w1 -o jsonpath='{.status.loadBalancer.ingress[0].ip}'  # 192.168.1.129
  kubectl get svc -n blocky blocky-dns-w2 -o jsonpath='{.status.loadBalancer.ingress[0].ip}'  # 192.168.1.126
  ```

If LB IPs do NOT match expected node IPs, see Rollback (Task 17).

---

### Task 16: Post-cutover verification

- [ ] **Step 1: Pod state**

```bash
kubectl get pods -n blocky -o wide
```

Expected: 2 pods, both `Running` and `Ready`, on `worker-node` and `worker-node-2`.

- [ ] **Step 2: Container logs (no errors)**

```bash
kubectl logs -n blocky -l app=blocky --tail=80
```

Expected: lines mentioning "blocklists loaded", "Redis connected", "started DNS server on :53". No fatal/panic/error lines.

- [ ] **Step 3: DNS resolution test (sequential, not parallel — fragile)**

```bash
dig +short @192.168.1.129 google.com
```
Expected: returns one or more IP addresses.

```bash
dig +short @192.168.1.129 doubleclick.net
```
Expected: returns `0.0.0.0` (blocked).

```bash
dig +short @192.168.1.129 grafana.h0melab.work
```
Expected: returns `192.168.1.129` and `192.168.1.126` (auto-subdomain mapping).

```bash
dig +short @192.168.1.126 google.com
```
Expected: returns IP addresses (W2 instance also serving).

- [ ] **Step 4: From a LAN client browser**

Open `https://grafana.h0melab.work` from a Mac/laptop on LAN. Expected: page loads (custom DNS rewrite working end-to-end).

- [ ] **Step 5: Postgres query log accumulating**

```bash
kubectl exec -n databases main-postgres-1 -- psql -U postgres -d blocky -c "SELECT count(*) FROM log_entries;"
```
Expected: number > 0, growing on subsequent queries.

```bash
kubectl exec -n databases main-postgres-1 -- psql -U postgres -d blocky -c "SELECT request_ts, client_ip, question_name, response_code FROM log_entries ORDER BY request_ts DESC LIMIT 10;"
```
Expected: 10 recent queries from real LAN clients.

- [ ] **Step 6: Prometheus targets up**

```bash
kubectl exec -n monitoring deploy/kube-prometheus-stack-prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=up{job="blocky-metrics"}' 2>/dev/null | jq '.data.result'
```

Expected: 2 results, both `value: ["...", "1"]`.

- [ ] **Step 7: No firing alerts**

```bash
kubectl exec -n monitoring deploy/kube-prometheus-stack-prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/alerts' 2>/dev/null | \
  jq -r '.data.alerts[] | select(.labels.alertname | startswith("Blocky")) | "\(.state) \(.labels.alertname)"'
```

Expected: empty output (no Blocky alerts firing).

- [ ] **Step 8: Kyverno reports clean**

```bash
kubectl get policyreport -n blocky -o json | jq -r '.items[].results[] | select(.result=="fail") | .policy'
```

Expected: empty (no policy failures).

If any verification step fails, see Task 17 (Rollback).

---

### Task 17: Rollback procedure (only if Task 16 fails)

- [ ] **Step 1: Identify cutover commit**

```bash
git log --oneline -5
```

Find the commit `feat(blocky): replace adguard with blocky`.

- [ ] **Step 2: Revert**

```bash
git revert --no-edit <CUTOVER_SHA>
git push
fr
```

- [ ] **Step 3: Verify AdGuard restored**

```bash
kubectl get pods -n adguard-home
dig +short @192.168.1.129 google.com
```

Expected: 2 AdGuard pods Running, DNS resolves.

- [ ] **Step 4: Diagnose Blocky failure**

Capture logs/events from before revert:
```bash
kubectl logs -n blocky -l app=blocky --tail=200 --previous > /tmp/blocky-logs.txt
kubectl describe pod -n blocky -l app=blocky > /tmp/blocky-describe.txt
kubectl get events -n blocky --sort-by='.lastTimestamp' > /tmp/blocky-events.txt
```

Investigate the root cause before retry. Do NOT re-execute Task 15 until root cause fixed and changes committed.

---

### Task 18: Update Mac resolver script

**Files:**
- Modify: `scripts/macos/setup-h0melab-resolver.sh`
- Modify: `scripts/macos/README.md`
- Modify: `~/.local/bin/setup-h0melab-resolver` (chezmoi-managed)

- [ ] **Step 1: Update header comment in script**

Edit `scripts/macos/setup-h0melab-resolver.sh`. Replace lines referring to "LAN AdGuard instances" with "LAN Blocky instances". Specifically:

Old (line 3-5 area):
```
# Configure macOS per-domain resolver so *.h0melab.work always resolves
# via LAN AdGuard instances (W1 + W2), bypassing VPN-pushed public DNS.
```

New:
```
# Configure macOS per-domain resolver so *.h0melab.work always resolves
# via LAN Blocky instances (W1 + W2), bypassing VPN-pushed public DNS.
```

IPs (`192.168.1.129`, `192.168.1.126`) remain unchanged.

- [ ] **Step 2: Update README.md references**

Edit `scripts/macos/README.md`. Replace "AdGuard" with "Blocky" in the explanatory text. Keep IPs unchanged.

- [ ] **Step 3: Sync chezmoi'd version**

```bash
cp scripts/macos/setup-h0melab-resolver.sh ~/.local/bin/setup-h0melab-resolver
chezmoi add ~/.local/bin/setup-h0melab-resolver
git -C ~/.local/share/chezmoi add -A
git -C ~/.local/share/chezmoi commit -m "Update setup-h0melab-resolver: AdGuard -> Blocky"
git -C ~/.local/share/chezmoi push
```

- [ ] **Step 4: Re-run on local Mac to confirm still works**

```bash
~/.local/bin/setup-h0melab-resolver
```

Expected: script completes without errors, verification block at end shows `OK` for `grafana.h0melab.work`.

- [ ] **Step 5: Commit homelab repo updates**

```bash
git add scripts/macos/setup-h0melab-resolver.sh scripts/macos/README.md
git commit -m "docs(macos): update resolver script for blocky"
git push
```

---

### Task 19: Update HOMELAB_ANALYSIS + HISTORY

**Files:**
- Modify: `docs/HOMELAB_ANALYSIS.md`
- Modify: `docs/HOMELAB_HISTORY.md`

- [ ] **Step 1: Update apps table in HOMELAB_ANALYSIS.md**

Find the apps table (search for "AdGuard Home"). Replace the AdGuard row with:
```
| Blocky | - | DNS filter, **HA: 2 replicas (W1+W2), single Deployment, native rolling, Redis cache sync** |
```

Find the HA section, update language describing AdGuard's dual-deployment workaround.

- [ ] **Step 2: Update HOMELAB_HISTORY.md**

Append entry:

```markdown
## 2026-04-26 — Replaced AdGuard Home with Blocky DNS

- Migrated network DNS resolver from AdGuard Home (2 separate Deployments, node-pinned) to Blocky (1 Deployment, 2 replicas, anti-affinity).
- Native k8s rolling updates now possible.
- Shared Redis (databases ns, db index 1) for cache + state sync via pub/sub channel `blocky_sync_enabled`.
- Query log to CNPG `blocky` Postgres database, 7-day retention via Blocky native pruning.
- LAN-facing IPs unchanged: 192.168.1.129 (W1), 192.168.1.126 (W2). Zero client-side DHCP/DNS reconfig required.
- Removed: AdGuard web UI ingress, dual PVCs, AdGuard-specific dual-deployment manifests.
- Spec: `docs/superpowers/specs/2026-04-26-blocky-migration-design.md`
- Plan: `docs/superpowers/plans/2026-04-26-blocky-migration.md`
```

- [ ] **Step 3: Commit**

```bash
git add docs/HOMELAB_ANALYSIS.md docs/HOMELAB_HISTORY.md
git commit -m "docs: update analysis + history for blocky migration"
git push
```

---

### Task 20: Update Uptime Kuma DNS probes

**Files:**
- Modify: Uptime Kuma config (in-app, not git-tracked).

- [ ] **Step 1: Open Uptime Kuma**

Navigate to `https://uptime.h0melab.work` (or whatever the local URL is).

- [ ] **Step 2: Locate AdGuard monitor**

Find existing monitor for AdGuard (likely HTTP probe to web UI). Edit it.

- [ ] **Step 3: Change to DNS monitor type**

- Type: `DNS`
- Hostname to resolve: `google.com`
- Resolver server: `192.168.1.129`
- Port: `53`
- Resolve type: `A`
- Save.

- [ ] **Step 4: Add second monitor for W2**

Duplicate, change Resolver server to `192.168.1.126`. Save.

- [ ] **Step 5: Verify both probes show UP**

Wait 1-2 minute intervals. Both should be green.

---

### Task 21: 7-day soak observation

- [ ] **Step 1: Daily check during soak**

For 7 days, daily check:
```bash
kubectl get pods -n blocky
kubectl exec -n monitoring deploy/kube-prometheus-stack-prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/alerts' 2>/dev/null | \
  jq -r '.data.alerts[] | select(.labels.alertname | startswith("Blocky")) | "\(.state) \(.labels.alertname)"'
kubectl exec -n databases main-postgres-1 -- psql -U postgres -d blocky -c "SELECT count(*), max(request_ts) FROM log_entries;"
```

Expected each day: pods Ready, no Blocky alerts firing, log_entries growing, max request_ts is recent.

- [ ] **Step 2: Memory observation**

```bash
kubectl top pods -n blocky
```

Note peak memory across the week. Should stay below 384Mi (leaving room to scale `limits` down at the 1-month review).

- [ ] **Step 3: Postgres DB size check**

```bash
kubectl exec -n databases main-postgres-1 -- psql -U postgres -d blocky -c \
  "SELECT pg_size_pretty(pg_database_size('blocky'));"
```

Expected after 7 days: < 100MB. If much larger, investigate field set or row volume.

---

### Task 22: Cleanup AdGuard manifests (after clean 7-day soak)

**Files:**
- Remove: `apps/base/adguard-home/` (entire dir)
- Remove: `apps/staging/adguard-home/` (entire dir)
- Remove: `infrastructure/configs/staging/resource-governance/small-tier/adguard-home.yaml`
- Modify: `infrastructure/configs/staging/resource-governance/kustomization.yaml`

- [ ] **Step 1: Confirm 7-day soak passed**

Check Task 21 verification still passes today.

- [ ] **Step 2: Remove AdGuard manifests**

```bash
git rm -r apps/base/adguard-home/
git rm -r apps/staging/adguard-home/
git rm infrastructure/configs/staging/resource-governance/small-tier/adguard-home.yaml
```

- [ ] **Step 3: Update resource-governance kustomization**

Edit `infrastructure/configs/staging/resource-governance/kustomization.yaml`. Remove the line `- small-tier/adguard-home.yaml`.

- [ ] **Step 4: Validate**

```bash
kustomize build apps/staging/ > /tmp/apps-after-cleanup.yaml
grep -c "adguard" /tmp/apps-after-cleanup.yaml
```

Expected: 0.

- [ ] **Step 5: Commit + push**

```bash
git add infrastructure/configs/staging/resource-governance/kustomization.yaml
git commit -m "chore: remove adguard manifests after blocky soak"
git push
fr
```

- [ ] **Step 6: Verify residual AdGuard cleanup**

```bash
kubectl get all,pvc -n adguard-home 2>/dev/null
```

Expected: only the namespace (now empty). If you want, drop the namespace itself:
```bash
kubectl delete namespace adguard-home
```

(K8s `delete namespace` is destructive — confirmed safe here because all manifests removed and migration is post-soak. Per CLAUDE.md safety hook, this command may be blocked; if so, delete remaining resources individually first.)

---

## Self-Review Notes

**Spec coverage:**
- Architecture topology (Section 1) → Tasks 1, 5, 6
- Configuration schema (Section 2) → Task 4 + verified upstream syntax
- Networking (Section 3) → Tasks 6, 7, 8
- Security/Compliance (Section 4) → Task 5 (deployment securityContext) + Task 12 (resource governance) + Task 14 (Kyverno admission verification)
- Observability (Section 5) → Task 13 + Task 16 step 6 + Task 20
- Cutover/Rollback (Section 6) → Tasks 14, 15, 16, 17

**Risk coverage:**
- Blocklist startup failure → startupProbe failureThreshold=30 (Task 5) + verification step 2 (Task 16)
- CNPG role lacking CREATE → Task 14 step 4 verifies + grants if needed
- PgBouncer prepared statements → Task 4 config uses `main-postgres-rw` direct endpoint
- svclb IP allocation race → Task 15 step 5 verifies; Task 17 covers rollback
- customDNS subdomain coverage → Task 16 step 3 explicitly tests `grafana.h0melab.work`
- HaGeZi false positive → no specific task; addressed reactively via `whiteLists` if encountered
- w2 missing IPv6 → `connectIPVersion: dual` in Task 4 config tolerates it

**Cut-corners / uncertainty annotations** (re-research findings already incorporated):
- Blocky version v0.29.0 verified via Docker Hub + GitHub releases (Task 5 step 1 re-verifies before commit)
- Grafana dashboard ID 13768 verified to exist (Task 13 step 3 re-fetches)
- CNPG Database CR shape verified against `paperless-database.yaml` pattern in repo (Task 2)
- Redis NP file path corrected to `infrastructure/configs/base/databases/redis/networkpolicy.yaml` (Task 8)
- Blocky `queryLog.fields` valid values verified against docs (Task 4 uses verified set)
- Blocky `customDNS.mapping` IPv4+IPv6 mixed comma format verified (Task 4 uses `192.168.1.129,192.168.1.126` correctly)

**Open items (intentionally deferred, not cut corners):**
- 1-month memory review for `limits` tuning — flag for `/schedule`
- 1-month K8s-native Redis operator health check — Phase 1 follow-up, separate spec
- DoH/DoT to clients — out of scope per spec
- Per-client filtering groups — out of scope per spec
- worker-node-2 IPv6 fix — separate networking change
