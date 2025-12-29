# K3s NetworkPolicy API Server Access

## Problem

Pods with restrictive NetworkPolicies cannot reach the Kubernetes API server (10.43.0.1:443).

**Symptoms:**
- Pods crash-loop with "connection refused" to 10.43.0.1:443
- Operators (CNPG, Percona, etc.) fail to watch CRDs
- Error: `dial tcp 10.43.0.1:443: connect: connection refused`

## Root Cause

**NetworkPolicy `namespaceSelector` does NOT work for API server access.**

The Kubernetes API server runs on the control-plane node (192.168.1.127:6443), not as a pod. When you use:

```yaml
egress:
  - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: default
    ports:
      - port: 443
```

This rule matches **pods in the default namespace**, but the API server is not a pod. Traffic to `10.43.0.1:443` gets DNATed to `192.168.1.127:6443` (node IP), which doesn't match any pod selector.

## Solution

Use `ipBlock` to allow traffic to the control-plane node directly:

```yaml
egress:
  # Allow access to Kubernetes API server
  # API server runs on control-plane node, not as a pod, so we use ipBlock
  - to:
      - ipBlock:
          cidr: 192.168.1.127/32  # control-plane node IP
    ports:
      - protocol: TCP
        port: 6443  # Kubernetes API server port
```

## Affected Components

Any pod that needs to communicate with the Kubernetes API server:

1. **Operators**: CNPG, Percona MySQL, cert-manager, etc.
2. **Database pods**: PostgreSQL pods that fetch cluster configuration
3. **Controllers**: Any custom controller watching CRDs
4. **Service mesh**: Components that need API server access

## Files Changed (2025-12-29)

- `infrastructure/controllers/base/databases/postgres/networkpolicy.yaml` - CNPG operator
- `infrastructure/configs/base/databases/postgres/networkpolicy.yaml` - PostgreSQL pods

## Cluster Details

| Component | Value |
|-----------|-------|
| Control-plane IP | 192.168.1.127 |
| API server port | 6443 |
| ClusterIP service | 10.43.0.1:443 |
| Pod CIDR | 10.42.0.0/16 |
| Service CIDR | 10.43.0.0/16 |

## Testing

To verify a pod can reach the API server:

```bash
# From inside a pod
kubectl exec -it <pod> -- nc -zv 10.43.0.1 443

# Or check connectivity
kubectl exec -it <pod> -- wget -qO- --timeout=5 https://kubernetes.default.svc/healthz --no-check-certificate
```

## Related: UFW Configuration

If UFW is enabled on nodes, ensure these rules exist:

```bash
# INPUT chain - allow traffic from pod/service networks
ufw allow from 10.42.0.0/16 comment "K3s pod network"
ufw allow from 10.43.0.0/16 comment "K3s service network"

# FORWARD chain - allow pod-to-node routed traffic (CRITICAL)
ufw route allow from 10.42.0.0/16 to 192.168.1.0/24 comment "K3s pod-to-node"
ufw route allow from 192.168.1.0/24 to 10.42.0.0/16 comment "K3s node-to-pod"
```

See `docs/scripts/setup-ufw-k3s-*.sh` for complete UFW setup scripts.

## Incident Timeline (2025-12-29)

1. **00:00 UTC (Dec 28)**: Pods started crash-looping after kube-prometheus-stack upgrade
2. **11:30 UTC**: Investigation began - identified API server connectivity issue
3. **11:45 UTC**: Fixed NetworkPolicy with `ipBlock` instead of `namespaceSelector`
4. **11:50 UTC**: All pods recovered
5. **12:20 UTC**: All alerts cleared

**Lesson learned**: Always use `ipBlock` for API server access in NetworkPolicies, never `namespaceSelector`.
