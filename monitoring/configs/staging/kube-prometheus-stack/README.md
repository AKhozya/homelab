# Monitoring Stack - Internal Network Access

The monitoring stack (Grafana, Prometheus, Alertmanager) is configured for **internal network access only** for security.

## DNS Configuration (Cloudflare)

To access Grafana via `grafana.h0melab.work` on your internal network:

1. **Create an A record in Cloudflare DNS:**
   - Name: `grafana`
   - Type: `A`
   - Content: `192.168.1.127` (or `192.168.1.129`)
   - Proxy status: **DNS only** (gray cloud, NOT orange)
   - TTL: Auto

2. **Alternative: Create two A records for redundancy:**
   ```
   grafana.h0melab.work -> 192.168.1.127
   grafana.h0melab.work -> 192.168.1.129
   ```

## Security Configuration

✅ **Network Policies Applied:**
- Grafana: Only accessible from within Kubernetes cluster
- Prometheus: Only accessible from within Kubernetes cluster
- Alertmanager: Only accessible from within Kubernetes cluster

✅ **Ingress Enabled (Internal DNS Only):**
- Grafana accessible via internal DNS at grafana.h0melab.work
- DNS points to internal IPs (192.168.1.127, 192.168.1.129)
- NOT exposed to the internet (DNS only, no proxy)

✅ **Egress Restricted:**
- DNS resolution allowed
- Inter-component communication allowed
- Internet access for plugins/updates (Grafana)
- Telegram API for alerts (Alertmanager)

## Accessing the Monitoring Stack

### Grafana

**Via Internal DNS (Recommended):**
```
https://grafana.h0melab.work
```

**Via kubectl port-forward (Alternative):**
```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
# Access at: http://localhost:3000
```

**Default credentials:**
- Username: Stored in secret `grafana-admin-secret`
- Password: Stored in secret `grafana-admin-secret`

To retrieve credentials:
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

## Remote Access (When Away from Home)

If you need to access the monitoring stack when away from home, consider these secure options:

1. **VPN** (Most Secure)
   - Set up WireGuard or Tailscale to access your home network
   - Access monitoring through the VPN as if you were home

2. **SSH Tunnel**
   - SSH into your homelab machine
   - Set up port forwarding through SSH

3. **Bastion Host**
   - Access through a secure jump host

**Do NOT expose Grafana/Prometheus/Alertmanager directly to the internet!**

## What Changed

- ❌ Removed external Ingress for Grafana (was: `grafana.h0melab.work`)
- ❌ Removed external Ingress for Alertmanager (was: `am.h0melab.work`)
- ✅ Added NetworkPolicy for Grafana
- ✅ Added NetworkPolicy for Prometheus
- ✅ Added NetworkPolicy for Alertmanager
- ✅ All certificates remain in place (can be re-enabled if needed)

## Re-enabling External Access (Not Recommended)

If you absolutely need external access, you can:

1. Edit `monitoring/controllers/base/kube-prometheus-stack/release.yaml`
2. Set `grafana.ingress.enabled: true` and/or `alertmanager.ingress.enabled: true`
3. The TLS certificates are still configured and will work
4. **However, this increases your attack surface significantly**

Better approach: Use a VPN or create a Cloudflare tunnel with proper authentication middleware.
