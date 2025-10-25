# Cloudflare Gateway DNS Filtering Setup

**Created:** 2025-10-25
**Account:** Alexander.khozya@gmail.com
**Account ID:** `***REMOVED-CF-ACCOUNT-ID***`

## Overview

Cloudflare Gateway provides DNS-level filtering for ad blocking, malware protection, and privacy enhancement across your entire homelab network.

## DNS Location: Homelab

**Location ID:** `55e39ccecdf04717ba7a3363e5838da4`
**Created:** 2025-10-25T14:33:37Z
**Updated:** 2025-10-25T14:36:56Z
**ECS Support:** ✅ Enabled (routes to nearest Cloudflare datacenter for optimal performance)

### DNS Server Addresses

Configure your router or devices to use these DNS servers:

**IPv4 DNS Servers:**
- Primary: `172.64.36.1`
- Secondary: `172.64.36.2`

**IPv6 DNS Server:**
- `2a06:98c1:54::20:4351`

**DNS-over-HTTPS (DoH):**
- URL: `https://nvkj3k9t7f.cloudflare-gateway.com/dns-query`

## Active Filtering Policies

### 1. Block Security Threats (Precedence: 10000)
**Rule ID:** `29b4d830-3b18-4408-a0a6-296f8a364fe2`
**Created:** 2025-10-25T14:33:53Z

Blocks:
- Malware (category 117)
- Phishing (category 68)
- Command & Control servers (category 80)
- Cryptomining (category 83)
- DNS Tunneling (category 176)
- Newly Registered Domains (category 175)

### 2. Block Ads (Precedence: 9000)
**Rule ID:** `255a300f-3944-4204-9fa1-c267e5382ad3`
**Created:** 2025-10-25T14:34:05Z

Blocks:
- Advertising domains (category 22)
- Ad-serving platforms

### 3. Block Trackers (Precedence: 8000)
**Rule ID:** `d9c2b108-b991-450c-8510-a99779f7d358`
**Created:** 2025-10-25T14:34:07Z

Blocks:
- Tracking domains (category 155)
- Analytics platforms
- Telemetry services

### 4. Block Major Trackers (Precedence: 7000)
**Rule ID:** `039fa9b2-a247-446f-a24a-b337ffdba018`
**List ID:** `7d5b0733-d1eb-406e-a920-ae3dcb61a7eb`
**Created:** 2025-10-25T14:34:36Z

Blocks specific major tracking platforms:
- Google Analytics (`google-analytics.com`, `googletagmanager.com`, `doubleclick.net`)
- Facebook Pixel (`facebook.com`, `connect.facebook.net`, `facebook.net`, `fbcdn.net`)
- Twitter/X tracking (`analytics.twitter.com`, `ads-twitter.com`)
- TikTok tracking (`analytics.tiktok.com`, `ads.tiktok.com`)
- Pinterest tracking (`analytics.pinterest.com`, `ads.pinterest.com`)
- LinkedIn tracking (`analytics.linkedin.com`, `ads.linkedin.com`)
- Session replay tools (`hotjar.com`, `mouseflow.com`, `luckyorange.com`, `fullstory.com`, `logrocket.com`, `smartlook.com`, `crazyegg.com`)
- Analytics platforms (`segment.com`, `segment.io`, `mixpanel.com`, `amplitude.com`, `heap.io`)
- A/B testing tools (`optimizely.com`, `vwo.com`)

## Configuration Steps

### Option 1: Router-Level Configuration (Recommended)

Configure your router's DHCP server to provide Cloudflare Gateway DNS:

1. Access your router's admin panel
2. Navigate to DHCP/DNS settings
3. Set Primary DNS: `172.64.36.1`
4. Set Secondary DNS: `172.64.36.2`
5. Save and reboot router

**Benefits:**
- Protects all devices on your network automatically
- No per-device configuration needed
- Works for IoT devices, smartphones, smart TVs, etc.

### Option 2: Per-Device Configuration

For individual devices, configure DNS in network settings:

**macOS:**
1. System Settings → Network → [Your Connection] → Details → DNS
2. Add DNS servers: `172.64.36.1` and `172.64.36.2`

**iOS:**
1. Settings → Wi-Fi → [Your Network] → Configure DNS → Manual
2. Add servers: `172.64.36.1` and `172.64.36.2`

**Windows:**
1. Network Settings → Adapter Settings → Properties → IPv4
2. Set DNS servers: `172.64.36.1` and `172.64.36.2`

**Linux:**
```bash
# Edit /etc/resolv.conf or use NetworkManager
nameserver 172.64.36.1
nameserver 172.64.36.2
```

### Option 3: Mobile Devices (Works on Cellular/4G/5G!)

**iPhone/iPad - DNS-over-HTTPS Profile (Recommended):**
1. **Download the profile:** `/docs/cloudflare-gateway-mobile-doh.mobileconfig`
2. **Transfer to your device:** AirDrop or email to yourself
3. **Install:** Open the file → Settings → Profile Downloaded → Install
4. **Enable:** Settings → General → VPN & Device Management → DNS → Select "Cloudflare Gateway"
5. **Verify:** Works on Wi-Fi AND cellular networks!

**Android - Private DNS (DNS-over-TLS):**
1. Settings → Network & Internet → Private DNS
2. Select "Private DNS provider hostname"
3. **Note:** Android doesn't support custom DoH hostnames easily
4. **Alternative:** Use the Cloudflare 1.1.1.1 app:
   - Install "1.1.1.1: Faster Internet" from Play Store
   - Open app → Settings (gear icon)
   - Advanced → Connection options → DNS-over-HTTPS
   - Enter: `https://nvkj3k9t7f.cloudflare-gateway.com/dns-query`

**Alternative - Per-Network (Wi-Fi only):**
- **iOS:** Settings → Wi-Fi → [Network] → Configure DNS → Manual
  - Add: `172.64.36.1` and `172.64.36.2`
- **Android:** Settings → Wi-Fi → [Network] → Advanced → DNS
  - Add: `172.64.36.1` and `172.64.36.2`

### Option 4: DNS-over-HTTPS (Browsers)

For browsers or systems supporting DoH:

**Firefox:**
1. Settings → Privacy & Security → DNS over HTTPS
2. Use custom provider: `https://nvkj3k9t7f.cloudflare-gateway.com/dns-query`

**Chrome/Edge:**
1. Settings → Privacy and security → Security → Use secure DNS
2. Enter: `https://nvkj3k9t7f.cloudflare-gateway.com/dns-query`

## Verification

Test that filtering is working:

```bash
# Should be blocked (ad domain)
nslookup ads.google.com 172.64.36.1

# Should be blocked (tracker)
nslookup google-analytics.com 172.64.36.1

# Should work (normal site)
nslookup github.com 172.64.36.1
```

Blocked domains will return a Cloudflare Gateway block page IP.

## Management

### View Analytics
Visit: https://one.dash.cloudflare.com/ → Analytics → Gateway

### Modify Rules
1. Dashboard: https://one.dash.cloudflare.com/
2. Navigate to Gateway → Firewall Policies → DNS
3. Edit rules or add exceptions

### Add Exceptions (Allow specific domains)

If a site breaks due to blocking, create an allow rule:

```bash
curl -X POST https://api.cloudflare.com/client/v4/accounts/***REMOVED-CF-ACCOUNT-ID***/gateway/rules \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name":"Allow Example Domain",
    "precedence":20000,
    "enabled":true,
    "action":"allow",
    "filters":["dns"],
    "traffic":"dns.fqdn == \"example.com\""
  }'
```

Higher precedence = evaluated first, so use 20000+ for allow rules.

## Security Considerations

✅ **Protected:**
- All DNS queries encrypted between you and Cloudflare
- Malware/phishing sites blocked automatically
- Ad trackers cannot profile your browsing
- No local blocklist maintenance needed

⚠️ **Limitations:**
- Only blocks DNS-level requests (IP-based tracking still works)
- Some sites may break if they require blocked trackers
- Cloudflare can see your DNS queries (trade-off for convenience)

## Backup/Restore

Configuration is stored in Cloudflare account. To back up:

```bash
# Export rules
curl https://api.cloudflare.com/client/v4/accounts/***REMOVED-CF-ACCOUNT-ID***/gateway/rules \
  -H "Authorization: Bearer YOUR_TOKEN" > gateway-rules-backup.json

# Export lists
curl https://api.cloudflare.com/client/v4/accounts/***REMOVED-CF-ACCOUNT-ID***/gateway/lists \
  -H "Authorization: Bearer YOUR_TOKEN" > gateway-lists-backup.json
```

## Monitoring

Check query logs and blocked requests:
- Dashboard: https://one.dash.cloudflare.com/ → Logs → Gateway

Set up alerts for suspicious activity:
- Dashboard: https://one.dash.cloudflare.com/ → Notifications

## Next Steps

1. ✅ Configure router DNS (recommended first step)
2. ⏳ Monitor analytics for 24-48 hours to see blocking effectiveness
3. ⏳ Add allow rules for any broken legitimate sites
4. ⏳ Consider enabling browser-based DoH for extra privacy on public WiFi
