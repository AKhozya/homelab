# Firewall Security Configuration

## Overview
This document describes the UFW firewall configuration for the homelab cluster to ensure services are not exposed to the internet.

## Security Principles
- **Default Deny**: Only explicitly allowed traffic is permitted
- **Local Network Only**: Most services restricted to 192.168.1.0/24
- **Pod Network Isolation**: Internal pod traffic on 10.42.0.0/16
- **Public Access**: Only via Cloudflare Tunnel (encrypted, authenticated)

## Control-Plane Node (192.168.1.127)

### Current UFW Rules
```bash
Status: active

     To                         Action      From
     --                         ------      ----
[ 1] 65300/tcp                  ALLOW IN    192.168.1.0/24    # SSH
[ 2] 6443/tcp                   ALLOW IN    192.168.1.0/24    # Kubernetes API
[ 3] 9090/tcp                   ALLOW IN    192.168.1.0/24    # Prometheus
[ 4] 80                         ALLOW IN    192.168.1.0/24    # HTTP (dev access)
[ 5] Anywhere                   ALLOW IN    192.168.1.127      # Self
[ 6] Anywhere                   ALLOW IN    192.168.1.129      # Worker node
[ 7] 8000/tcp                   ALLOW IN    10.42.0.0/16       # CNPG status API
```

### Setup Commands
```bash
# Reset and configure UFW
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing

# SSH access from local network only
sudo ufw allow from 192.168.1.0/24 to any port 65300 proto tcp

# Kubernetes API from local network only
sudo ufw allow from 192.168.1.0/24 to any port 6443 proto tcp

# Prometheus from local network only
sudo ufw allow from 192.168.1.0/24 to any port 9090 proto tcp

# HTTP from local network only (for development)
sudo ufw allow from 192.168.1.0/24 to any port 80

# Allow all traffic from control-plane (self)
sudo ufw allow from 192.168.1.127

# Allow all traffic from worker node
sudo ufw allow from 192.168.1.129

# CNPG instance manager status API from pod network
sudo ufw allow from 10.42.0.0/16 to any port 8000 proto tcp

# Enable firewall
sudo ufw enable
```

## Worker Node (192.168.1.129)

### Current UFW Rules
```bash
Status: active

     To                         Action      From
     --                         ------      ----
[ 1] 65300/tcp                  ALLOW IN    192.168.1.0/24    # SSH
[ 2] 80                         ALLOW IN    192.168.1.0/24    # HTTP (dev access)
[ 3] Anywhere                   ALLOW IN    192.168.1.127      # Control-plane
[ 4] Anywhere                   ALLOW IN    192.168.1.129      # Self
[ 5] 8000/tcp                   ALLOW IN    10.42.0.0/16       # CNPG status API
```

### Setup Commands
```bash
# Reset and configure UFW
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing

# SSH access from local network only
sudo ufw allow from 192.168.1.0/24 to any port 65300 proto tcp

# HTTP from local network only (for development)
sudo ufw allow from 192.168.1.0/24 to any port 80

# Allow all traffic from control-plane node
sudo ufw allow from 192.168.1.127

# Allow all traffic from worker (self)
sudo ufw allow from 192.168.1.129

# CNPG instance manager status API from pod network
sudo ufw allow from 10.42.0.0/16 to any port 8000 proto tcp

# Enable firewall
sudo ufw enable
```

## Blocked Services (Not Exposed)

These services are **only** accessible via Cloudflare Tunnel or local network:

### Management & Monitoring
- **Kubernetes API (6443)**: Local network only
- **Kubelet API (10250)**: Localhost only
- **etcd (2379-2380)**: Localhost only (control-plane)
- **Prometheus (9090)**: Local network only
- **Alertmanager (9093)**: Internal only
- **Grafana (3000)**: Via Cloudflare Tunnel only

### Databases
- **PostgreSQL (5432)**: Pod network only
- **Redis (6379)**: Pod network only
- **CouchDB (5984)**: Pod network only
- **CNPG Status (8000)**: Pod network only

### Applications
All apps accessible **only** via Cloudflare Tunnel:
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

**No ports are directly exposed to the internet.**

## Security Incidents

### 2025-10-30: Critical Vulnerability Discovered & Fixed

**Issue**: Kubernetes API exposed to internet via UFW misconfiguration

**Vulnerable Rules**:
```bash
[ 1] 6443/tcp         ALLOW IN    Anywhere           # ❌ CRITICAL
[ 9] 65300/tcp (v6)   ALLOW IN    Anywhere (v6)      # ❌ High
[10] 9090/tcp (v6)    ALLOW IN    Anywhere (v6)      # ❌ High
```

**Impact**:
- Kubernetes API (6443) exposed to entire internet
- Anyone could attempt authentication attacks
- SSH exposed on IPv6
- Prometheus metrics exposed on IPv6

**Resolution**:
```bash
sudo ufw delete 1    # Removed: 6443/tcp from Anywhere
sudo ufw delete 8    # Removed: 65300/tcp (v6) from Anywhere
sudo ufw delete 8    # Removed: 9090/tcp (v6) from Anywhere
```

**Timeline**:
- Vulnerability existed since initial cluster setup
- Discovered: 2025-10-30 during firewall audit
- Fixed: 2025-10-30 (immediate)
- Risk: Medium (Kubernetes API has authentication, but exposure unnecessary)

**Post-Fix Verification**:
- ✅ Cluster fully functional
- ✅ All services accessible locally
- ✅ Apps accessible via Cloudflare Tunnel
- ✅ No internet-facing ports (except Cloudflare Tunnel)

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
When adding services that need external access:
1. **Never** expose directly to internet
2. Create Cloudflare Tunnel ingress
3. Use NetworkPolicies for pod-to-pod access
4. Document in this file

### Regular Audits
Run firewall audit quarterly:
```bash
# On each node
sudo ufw status numbered
sudo ss -tulpn | grep LISTEN
```

## References
- UFW Documentation: https://help.ubuntu.com/community/UFW
- Kubernetes Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Cloudflare Tunnel: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/
