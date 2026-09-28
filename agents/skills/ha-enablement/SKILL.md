---
name: ha-enablement
description: Use when enabling HA (2+ replicas) on a homelab workload. Pre-flight checklist covering ResourceQuota 2x, anti-affinity (hard vs soft), gossip/cluster ports, helm chart config, storage type, post-HA validation.
user-invocable: false
---

# HA Enablement Skill

## When to Use
- Enabling HA for stateless app
- Adding replicas to monitoring components
- Spreading DB replicas across nodes

## Pre-Flight Checklist

### 1. Resource Quota Check
Rolling updates need 2x resources temporarily.
```bash
bash ~/.agents/skills/_shared/quota.sh <namespace>
bash ~/.agents/skills/_shared/quota.sh <namespace> --json   # parse via jq
```
**Action**: Increase quota 2x before HA, reduce after stable.

### 2. Anti-Affinity

**Hard** (MUST be on different nodes):
```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: <app-name>
        topologyKey: kubernetes.io/hostname
```

**Soft** (prefer different nodes):
```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app: <app-name>
          topologyKey: kubernetes.io/hostname
```

**Rule**: Hard when nodes >= replicas. Soft when nodes < replicas.

**Hard-anti-affinity reroll race (hit 2× on 2026-06-05: coredns spread, cnpg-operator):** during a
rolling update the OLD **Terminating** pod still counts for anti-affinity → blocks its node → the
new pod lands on whatever node is left, IGNORING any soft nodeAffinity preference. Placement after
any reroll/helm-upgrade of hard-anti-affinity workloads is therefore semi-random and NEVER
self-heals (scheduler only decides at admission). Post-rollout: check `kubectl get pods -o wide`;
wrong node → `kubectl delete pod <p>` once — reschedules cleanly when nothing is Terminating.
Also: a soft nodeAffinity pref is **dead config** unless every preferred node is actually
schedulable (taints/tolerations) — verify with the toleration math, not assumption.

### 3. NetworkPolicy Updates

HA components need gossip/cluster ports (Alertmanager 9094, Loki 7946, Redis Sentinel 26379, VMAgent 8429). See `/networkpolicy-helper` for the template (must allow TCP + UDP for gossip).

### 4. Helm Chart Config

**kube-prometheus-stack** (Prometheus pod removed — TSDB is VictoriaMetrics):
```yaml
alertmanager:
  alertmanagerSpec:
    replicas: 2
    podAntiAffinity: "hard"
```

**VictoriaMetrics** (vmsingle is single-tenant by design — scale via vmcluster if needed):

VictoriaMetrics components are CRDs managed by `victoria-metrics-operator`, not Helm sub-chart values. The CR is Git-managed: edit `monitoring/configs/victoria-metrics/vmagent.yaml` in a worktree, then commit and deploy it through `/gitops-workflow`. A live edit is a GitOps violation that Flux reverts.

```bash
kubectl get vmagent -n monitoring        # confirm name (e.g. vmagent)
```

VMAgent CR shape (vmagents.operator.victoriametrics.com):
```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMAgent
metadata:
  name: vmagent
  namespace: monitoring
spec:
  replicaCount: 2          # scale-out scrapers (each writes to vmsingle independently)
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels:
              app.kubernetes.io/name: vmagent
          topologyKey: kubernetes.io/hostname
```

**Percona MySQL**:
```yaml
mysql:
  size: 2  # Replicas
  affinity:
    antiAffinityTopologyKey: kubernetes.io/hostname
haproxy:
  size: 2
  affinity:
    antiAffinityTopologyKey: kubernetes.io/hostname
```

### 5. Storage

| Type | HA? | Notes |
|------|-----|-------|
| local-path | No | Data stuck to node |
| NFS/Ceph | Yes | Shared storage |
| StatefulSet PVC | Yes | Each replica gets own PVC |

DBs: StatefulSet with per-replica PVCs (CNPG, Percona handle this).

### 6. Verify
```bash
# Pod-spread check (PASS = replicas across distinct nodes)
bash ~/.agents/skills/ha-enablement/scripts/verify-spread.sh -n <ns> -l <label-selector>
# example: -n monitoring -l app.kubernetes.io/name=alertmanager
# example: -n databases -l cnpg.io/cluster=main-postgres,cnpg.io/podRole=instance
#   (bare cluster label also matches pooler pods → spread can PASS while both PG instances co-locate)

# Test failover (drain one node) — destructive, run only in maintenance window
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
# ... verify service still works ...
kubectl uncordon <node>
```

## Current HA Components

| Component | Replicas | Anti-Affinity | Notes |
|-----------|----------|---------------|-------|
| Alertmanager | 2 | Hard | + gossip 9094 |
| Blocky DNS | 2 | Hard | Redis cache sync |
| PostgreSQL (CNPG) | 2 | Hard | Streaming replication |
| MySQL (Percona) | 2 | Hard | Async replication |
| HAProxy (MySQL) | 2 | Hard | Connection routing |
| CouchDB | 2 | Soft | StatefulSet |
| Authentik server | 2 | Soft | Stateless |
| Authentik worker | 2 | Soft | Stateless |

## Post-HA Checklist
- [ ] Both pods on different nodes
- [ ] Service endpoints show both pods
- [ ] NetworkPolicy allows inter-pod comms
- [ ] Failover tested (drain node)
- [ ] ResourceQuota reduced back
- [ ] HOMELAB_ANALYSIS.md updated

## Tools Allowed
- `Bash(kubectl *)`
- `Read`
- `Edit`
