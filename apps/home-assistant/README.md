# Home Assistant — Internal Network Access

Home Assistant = **internal-only** for security.

## DNS Configuration (Cloudflare)

Access via `ha.h0melab.work` on internal network:

1. **Create A record in Cloudflare DNS:**
   - Name: `ha`
   - Type: `A`
   - Content: `192.168.1.127` (or `192.168.1.129`)
   - Proxy status: **DNS only** (gray cloud, NOT orange)
   - TTL: Auto

2. **Alternative: two A records for redundancy:**
   ```
   ha.h0melab.work -> 192.168.1.127
   ha.h0melab.work -> 192.168.1.129
   ```

## Accessing Home Assistant

### Via Internal DNS (recommended)

Once DNS configured:
```
https://ha.h0melab.work
```

Works from any device on home net (192.168.1.x).

### Via kubectl port-forward (alt)

```bash
kubectl port-forward -n home-assistant svc/home-assistant 8123:8123
# Access at: http://localhost:8123
```

## Remote Access (Away from Home)

Secure options:

1. **VPN** (most secure)
   - WireGuard or Tailscale to home net
   - Access HA via VPN

2. **Home Assistant Cloud (Nabu Casa)**
   - Official paid ($6.50/month)
   - Supports HA development
   - Secure remote + Alexa/Google Assistant

3. **Cloudflare Tunnel** (if must)
   - Only if truly needed
   - Creates external exposure — attack surface up
   - Contact admin for proper security setup

## Security Features

- NetworkPolicy restricts external access
- Internal cluster access allowed
- Egress for updates + integrations
- Local network access for IoT discovery
- Pod runs with minimal capabilities
- Seccomp profile enabled
