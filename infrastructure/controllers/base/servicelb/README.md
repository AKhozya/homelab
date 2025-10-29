# K3s ServiceLB - LoadBalancer Implementation

## Overview

This cluster uses **K3s built-in ServiceLB** (formerly Klipper LoadBalancer) instead of MetalLB for LoadBalancer services.

## Architecture

**ServiceLB** is K3s's built-in LoadBalancer controller that:
- Automatically deploys DaemonSet pods (`svclb-*`) per LoadBalancer service
- Assigns the node's IP address as the EXTERNAL-IP
- Routes traffic from node ports to service endpoints
- Requires no external configuration or IP pool management

### Current Implementation

```
Cluster Nodes:
- gmk-k3s-control-plane: 192.168.1.127 (tainted, no workloads)
- worker-node:           192.168.1.129 (all LoadBalancer services)

LoadBalancer Services:
- traefik:          192.168.1.129:80,443
- adguard-home-dns: 192.168.1.129:53
```

Both services share the worker node IP because ServiceLB assigns the node's IP to all LoadBalancer services.

## ServiceLB Pods

ServiceLB creates DaemonSet pods in `kube-system`:
```bash
kubectl get pods -n kube-system | grep svclb
```

Example output:
```
svclb-adguard-home-dns-adb2d47f-pc6m2     2/2     Running
svclb-traefik-7834697c-fwnwc              2/2     Running
```

Each svclb pod contains:
- **lb-tcp-***: TCP port forwarding container
- **lb-udp-***: UDP port forwarding container (if needed)

## Advantages

✅ **Zero Configuration**: Built into K3s, no additional setup
✅ **Lightweight**: Minimal resource overhead
✅ **Reliable**: Simple architecture with fewer moving parts
✅ **GitOps Friendly**: No external manifests to manage

## Limitations

⚠️ **Shared IP**: All LoadBalancer services use the same node IP
⚠️ **No IP Pool**: Cannot assign specific IPs to different services
⚠️ **Node-Bound**: EXTERNAL-IP is always a cluster node IP
⚠️ **Port Conflicts**: Cannot run multiple services on same port

## When to Use ServiceLB

**Good for**:
- Small homelabs (1-3 worker nodes)
- Limited LoadBalancer services (2-5 services)
- Simple networking requirements
- Avoid external dependencies

**Consider MetalLB instead if**:
- Need dedicated IP per service
- Require L2/BGP networking
- Managing 5+ LoadBalancer services
- Need IP pool management

## Disabling ServiceLB (If Needed)

To disable ServiceLB and install MetalLB:

1. Add K3s server flag:
   ```bash
   --disable servicelb
   ```

2. Restart K3s:
   ```bash
   sudo systemctl restart k3s
   ```

3. Install MetalLB via Flux (see infrastructure/controllers/base/metallb/)

## Current Status

- **Installed**: K3s ServiceLB (built-in)
- **Active Services**: 2 (traefik, adguard-home-dns)
- **Node IP**: 192.168.1.129
- **Status**: ✅ Operational

## References

- [K3s Service Load Balancer](https://docs.k3s.io/networking/networking-services#service-load-balancer)
- [K3s Networking](https://docs.k3s.io/networking)
