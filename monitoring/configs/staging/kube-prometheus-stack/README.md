# Monitoring Stack — Internal Network Access

Grafana, Prometheus, Alertmanager = **internal-only** for security.

## DNS Configuration (Cloudflare)

Access Grafana via `grafana.h0melab.work` on internal network:

1. **Create A record in Cloudflare DNS:**
   - Name: `grafana`
   - Type: `A`
   - Content: `192.168.1.127` (or `192.168.1.129`)
   - Proxy status: **DNS only** (gray cloud, NOT orange)
   - TTL: Auto

2. **Alternative: two A records for redundancy:**
   ```
   grafana.h0melab.work -> 192.168.1.127
   grafana.h0melab.work -> 192.168.1.129
   ```

## Security Configuration

**NetworkPolicies Applied:**
- Grafana: cluster-only access
- Prometheus: cluster-only access
- Alertmanager: cluster-only access

**Ingress Enabled (Internal DNS Only):**
- Grafana via internal DNS at grafana.h0melab.work
- DNS points to internal IPs (192.168.1.127, 192.168.1.129)
- NOT exposed to internet (DNS only, no proxy)

**Egress Restricted:**
- DNS resolution allowed
- Inter-component comms allowed
- Internet for plugins/updates (Grafana)
- Telegram API for alerts (Alertmanager)

## Accessing Monitoring Stack

### Grafana

**Via Internal DNS (recommended):**
```
https://grafana.h0melab.work
```

**Via kubectl port-forward (alt):**
```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
# Access at: http://localhost:3000
```

**Default credentials:**
- Username: secret `grafana-admin-secret`
- Password: secret `grafana-admin-secret`

Retrieve creds:
```bash
kubectl get secret -n monitoring grafana-admin-secret -o jsonpath='{.data.admin-user}' | base64 -d
kubectl get secret -n monitoring grafana-admin-secret -o jsonpath='{.data.admin-password}' | base64 -d
```

### Prometheus

**Quick access:**
```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# Access at: http://localhost:9090
```

### Alertmanager

**Quick access:**
```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093
# Access at: http://localhost:9093
```

## Remote Access (Away from Home)

Secure options:

1. **VPN** (most secure)
   - WireGuard or Tailscale to home net
   - Access as if home

2. **SSH Tunnel**
   - SSH to homelab machine
   - Port forwarding via SSH

3. **Bastion Host**
   - Secure jump host

**WARNING: Do NOT expose Grafana/Prometheus/Alertmanager directly to internet!**

## What Changed

- Removed external Ingress for Grafana (was: `grafana.h0melab.work`)
- Removed external Ingress for Alertmanager (was: `am.h0melab.work`)
- Added NetworkPolicy for Grafana
- Added NetworkPolicy for Prometheus
- Added NetworkPolicy for Alertmanager
- Certificates remain (can re-enable)

## Re-enabling External Access (Not Recommended)

If external access truly needed:

1. Edit `monitoring/controllers/kube-prometheus-stack/release.yaml`
2. Set `grafana.ingress.enabled: true` and/or `alertmanager.ingress.enabled: true`
3. TLS certs still configured, will work
4. **WARNING: increases attack surface significantly**

Better: VPN or Cloudflare tunnel with auth middleware.
