# Home Assistant - Internal Network Access

Home Assistant is configured for **internal network access only** for security.

## DNS Configuration (Cloudflare)

To access Home Assistant via `ha.h0melab.work` on your internal network:

1. **Create an A record in Cloudflare DNS:**
   - Name: `ha`
   - Type: `A`
   - Content: `192.168.1.127` (or `192.168.1.129`)
   - Proxy status: **DNS only** (gray cloud, NOT orange)
   - TTL: Auto

2. **Alternative: Create two A records for redundancy:**
   ```
   ha.h0melab.work -> 192.168.1.127
   ha.h0melab.work -> 192.168.1.129
   ```

## Accessing Home Assistant

### Via Internal DNS (Recommended)

Once DNS is configured, access Home Assistant at:
```
https://ha.h0melab.work
```

This works from any device on your home network (192.168.1.x).

### Via kubectl port-forward (Alternative)

```bash
kubectl port-forward -n home-assistant svc/home-assistant 8123:8123
# Access at: http://localhost:8123
```

## Remote Access (When Away from Home)

If you need to access Home Assistant when away from home, consider these secure options:

1. **VPN** (Most Secure)
   - Set up WireGuard or Tailscale to access your home network
   - Access Home Assistant through the VPN as if you were home

2. **Home Assistant Cloud (Nabu Casa)**
   - Official paid service ($6.50/month)
   - Supports Home Assistant development
   - Includes secure remote access, Alexa/Google Assistant integration

3. **Cloudflare Tunnel** (If you must)
   - Only enable if really needed
   - Creates external exposure which increases attack surface
   - Contact admin to set this up with proper security measures

## Security Features

- ✅ Network Policy restricts all external access
- ✅ Internal cluster access allowed
- ✅ Egress allowed for updates and integrations
- ✅ Local network access for IoT device discovery
- ✅ Pod runs with minimal required capabilities
- ✅ Seccomp profile enabled
