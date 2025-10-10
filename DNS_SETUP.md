# Internal DNS Setup with Cloudflare

This document explains how to configure Cloudflare DNS for internal-only access to your homelab services.

## Overview

Your Traefik LoadBalancer is exposed on both node IPs:
- Master node: `192.168.1.127`
- Worker node: `192.168.1.129`

Traefik listens on ports:
- HTTP: 80
- HTTPS: 443

## Cloudflare DNS Configuration

### Important: DNS Only Mode

**Critical:** Set all records to **DNS Only** (gray cloud icon), NOT **Proxied** (orange cloud icon).
- DNS Only = Cloudflare only provides DNS resolution
- Proxied = Traffic goes through Cloudflare (won't work for private IPs)

### Services to Configure

#### 1. Home Assistant

**Domain:** `ha.h0melab.work`

Create A record(s):
```
Type: A
Name: ha
Content: 192.168.1.127
Proxy status: DNS only (gray cloud)
TTL: Auto
```

**Optional redundancy:** Add second A record with `192.168.1.129`

**Access:** https://ha.h0melab.work (from your home network)

#### 2. Grafana

**Domain:** `grafana.h0melab.work`

Create A record(s):
```
Type: A
Name: grafana
Content: 192.168.1.127
Proxy status: DNS only (gray cloud)
TTL: Auto
```

**Optional redundancy:** Add second A record with `192.168.1.129`

**Access:** https://grafana.h0melab.work (from your home network)

#### 3. Other Services (if needed)

Follow the same pattern for:
- `linkding.h0melab.work` -> 192.168.1.127
- `n8n.h0melab.work` -> 192.168.1.127
- `audiobookshelf.h0melab.work` -> 192.168.1.127

## How It Works

```
┌─────────────────────────────────────────────────────────────┐
│  1. Browser requests: https://grafana.h0melab.work          │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  2. Cloudflare DNS resolves to: 192.168.1.127               │
│     (Internal IP, no proxy)                                 │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  3. Request goes to Traefik LoadBalancer on 192.168.1.127  │
│     (Port 443)                                              │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  4. Traefik routes based on hostname:                       │
│     - grafana.h0melab.work -> Grafana service               │
│     - ha.h0melab.work -> Home Assistant service             │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  5. Service responds with content                           │
└─────────────────────────────────────────────────────────────┘
```

## TLS/HTTPS Certificates

Certificates are automatically managed by cert-manager using Let's Encrypt.

**Note:** Let's Encrypt staging is currently configured. Once you verify everything works:

1. Change issuer from `letsencrypt-staging` to `letsencrypt-prod`
2. Wait for new certificates to be issued
3. Enjoy trusted HTTPS certificates!

Location to change:
- `apps/staging/home-assistant/certificate.yaml`
- `monitoring/configs/staging/kube-prometheus-stack/grafana-certificate.yaml`

## Verification

### Check DNS Resolution

From your home network:
```bash
# Should return 192.168.1.127 (or .129)
dig +short ha.h0melab.work
dig +short grafana.h0melab.work
```

### Check Traefik Service

```bash
kubectl get svc -n traefik traefik
# Should show EXTERNAL-IP: 192.168.1.127,192.168.1.129
```

### Test Access

From any device on your home network (192.168.1.x):
```bash
curl -k https://ha.h0melab.work
curl -k https://grafana.h0melab.work
```

Or simply open in a browser:
- https://ha.h0melab.work
- https://grafana.h0melab.work

## Troubleshooting

### DNS doesn't resolve
- Check Cloudflare DNS is set to "DNS only" (gray cloud)
- Wait a few minutes for DNS propagation
- Clear your local DNS cache: `sudo dscacheutil -flushcache` (macOS)

### Certificate errors
- You're using Let's Encrypt staging, so browser warnings are expected
- Switch to production issuer for trusted certificates

### Connection refused
- Check Traefik is running: `kubectl get pods -n traefik`
- Check service exposure: `kubectl get svc -n traefik traefik`
- Verify ingress: `kubectl get ingress -A`

### Works from one node but not the other
- Both IPs should work identically
- Check network connectivity to both nodes
- Check Traefik pods distribution

## Security Notes

✅ **Internal Only:**
- DNS resolves to private IPs (192.168.1.x)
- Not accessible from the internet
- Even if someone knows the domain, they can't reach your services

✅ **Network Policies:**
- Additional layer of protection
- Restricts which pods can communicate

✅ **No Cloudflare Tunnel:**
- Not using Cloudflare Tunnel = no external exposure
- Using Cloudflare only for DNS resolution

❌ **Don't Proxy:**
- Never enable Cloudflare proxy (orange cloud) for private IPs
- It won't work and may leak your internal IP addresses
