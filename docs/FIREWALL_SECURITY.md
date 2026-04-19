# Firewall Security Configuration

## Overview
UFW firewall config for homelab cluster — services not exposed to internet.

## Security Principles
- **Default Deny**: only explicit allow permitted
- **Local Network Only**: most services → 192.168.1.0/24
- **Pod Network Isolation**: internal pod traffic → 10.42.0.0/16
- **Public Access**: Cloudflare Tunnel only (encrypted, authenticated)

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

Services **only** via Cloudflare Tunnel or local network:

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
All apps **only** via Cloudflare Tunnel:
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

**Issue**: Kubernetes API exposed to internet via UFW misconfiguration

**Vulnerable Rules**:
```bash
[ 1] 6443/tcp         ALLOW IN    Anywhere           # ❌ CRITICAL
[ 9] 65300/tcp (v6)   ALLOW IN    Anywhere (v6)      # ❌ High
[10] 9090/tcp (v6)    ALLOW IN    Anywhere (v6)      # ❌ High
```

**Impact**:
- K8s API (6443) exposed to entire internet
- Auth attacks possible
- SSH exposed on IPv6
- Prometheus metrics exposed on IPv6

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
- Risk: Medium (K8s API has auth, but exposure unnecessary)

**Post-Fix Verification**:
- Cluster fully functional
- All services accessible locally
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
