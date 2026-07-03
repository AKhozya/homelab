# Firewall Security Configuration

This cluster defends itself in two layers. At the host level, every node runs a UFW firewall that defaults to deny-incoming and only opens the specific ports needed by SSH, the Kubernetes API, and intra-cluster traffic. Inside the cluster, Kubernetes NetworkPolicies wrap each workload so pods can only talk to the peers they actually depend on. Together they give defense in depth: a misconfigured app can't reach the wider network, and a host that slips past the firewall still meets a default-deny pod network.

## Overview
UFW firewall config homelab cluster — services not exposed to internet.

## Security Principles
- **Default Deny**: explicit allow only
- **Local Network Only**: most services → 192.168.1.0/24
- **Pod Network Isolation**: internal pod traffic → 10.42.0.0/16
- **Public Access**: Cloudflare Tunnel only (encrypted, authenticated)

## Rule Management (ansible-owned)

UFW rules are NOT maintained by hand and NOT listed here — a static listing drifts
the day a role changes. Source of truth:

- **Role:** `docs/scripts/node-maintenance/ansible/roles/firewall/` (+ `firewall_preflight`)
- **Per-node rules:** `docs/scripts/node-maintenance/ansible/group_vars/{all,control_plane,workers}.yml` and `host_vars/<node>.yml` (e.g. VXLAN 8472/udp on worker-node-2, route rules)
- **Heal / apply:** `sudo systemctl start node-maintenance-config.service` (drift-heal also runs daily via timer)
- **Inspect live:** `sudo ufw status numbered` on the node

**NEVER `ufw --force reset`.** The role is idempotent-ADDITIVE: a reset strips
role-added rules (VXLAN 8472/udp on W2, route rules) and is not what heals drift —
the ansible run is. To fix a broken firewall, run `node-maintenance-config.service`,
not manual `ufw` commands.

## Blocked Services (Not Exposed)

Services via Cloudflare Tunnel or local network **only**:

### Management & Monitoring
- **Kubernetes API (6443)**: local only
- **Kubelet API (10250)**: localhost only
- **etcd (2379-2380)**: localhost only (control-plane)
- **Prometheus (9090)**: local only
- **Alertmanager (9093)**: internal only
- **Grafana (3000)**: Cloudflare Tunnel only

### Databases
- **PostgreSQL (5432)**: pod network only
- **Redis (6379)**: pod network only
- **CouchDB (5984)**: pod network only
- **CNPG Status (8000)**: pod network only

### Applications
Apps via Cloudflare Tunnel **only**:
- Authentik
- Immich
- Paperless-NGX
- Linkding
- Mealie
- Wallabag
- n8n
- Stirling-PDF
- Homepage
- Uptime Kuma

## Public Access Architecture

```
Internet
   ↓
Cloudflare (CDN + DDoS Protection)
   ↓
Cloudflare Tunnel (encrypted, authenticated)
   ↓
Cloudflare Tunnel Pod (cloudflare-tunnel namespace)
   ↓
Traefik Ingress Controller
   ↓
Application Services
```

**No ports directly exposed to internet.**

## Security Incidents

### 2025-10-30: Critical Vulnerability Discovered & Fixed

**Issue**: K8s API exposed to internet via UFW misconfig

**Vulnerable Rules**:
```bash
[ 1] 6443/tcp         ALLOW IN    Anywhere           # ❌ CRITICAL
[ 9] 65300/tcp (v6)   ALLOW IN    Anywhere (v6)      # ❌ High
[10] 9090/tcp (v6)    ALLOW IN    Anywhere (v6)      # ❌ High
```

**Impact**:
- K8s API (6443) exposed entire internet
- Auth attacks possible
- SSH exposed IPv6
- Prometheus metrics exposed IPv6

**Resolution**:
```bash
sudo ufw delete 1    # Removed: 6443/tcp from Anywhere
sudo ufw delete 8    # Removed: 65300/tcp (v6) from Anywhere
sudo ufw delete 8    # Removed: 9090/tcp (v6) from Anywhere
```

**Timeline**:
- Vuln existed since initial cluster setup
- Discovered: 2025-10-30 (firewall audit)
- Fixed: 2025-10-30 (immediate)
- Risk: Medium (K8s API has auth, exposure unnecessary)

**Post-Fix Verification**:
- Cluster fully functional
- Services accessible locally
- Apps accessible via Cloudflare Tunnel
- No internet-facing ports (except CF Tunnel)

## Verification

### Check UFW Status
```bash
# On each node
sudo ufw status numbered
```

### Check Listening Ports
```bash
# See what's actually listening
sudo ss -tulpn | grep LISTEN
```

### Test External Access (from internet)
```bash
# These should all FAIL (connection refused/timeout):
nmap -Pn <public-ip> -p 6443,10250,5432,9090

# Only Cloudflare Tunnel should work:
curl https://authentik.h0melab.work  # Should work
```

### Test Internal Access (from local network)
```bash
# From your workstation on 192.168.1.0/24:
curl -k https://192.168.1.127:6443  # Kubernetes API - should work
curl http://192.168.1.127:9090      # Prometheus - should work
```

## Maintenance

### Adding New Services
New services needing external access:
1. **Never** expose direct to internet
2. Create Cloudflare Tunnel ingress
3. Use NetworkPolicies for pod-to-pod access
4. Document here

### Regular Audits
Quarterly audit:
```bash
# On each node
sudo ufw status numbered
sudo ss -tulpn | grep LISTEN
```

## References
- UFW Docs: https://help.ubuntu.com/community/UFW
- K8s Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Cloudflare Tunnel: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/