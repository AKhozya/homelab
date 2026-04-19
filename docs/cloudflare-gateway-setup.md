# Cloudflare Gateway DNS Filtering Setup

**Created:** 2025-10-25
**Account:** Alexander.khozya@gmail.com
**Account ID:** `***REMOVED-CF-ACCOUNT-ID***`

## Overview

Cloudflare Gateway = DNS-level filtering for ad block, malware protection, privacy across homelab network.

## DNS Location: Homelab

**Location ID:** `55e39ccecdf04717ba7a3363e5838da4`
**Created:** 2025-10-25T14:33:37Z
**Updated:** 2025-10-25T14:36:56Z
**ECS Support:** Enabled (routes to nearest CF datacenter)

### DNS Server Addresses

Configure router/devices to use these DNS servers:

**IPv4 DNS Servers (Network-Authenticated):**
- Primary: `172.64.36.1`
- Secondary: `172.64.36.2`
- **Authentication Required:** only works from authorized network `89.36.71.24/32`
- Home IP changes → update network list in CF Gateway settings

**IPv6 DNS Server:**
- `2a06:98c1:54::20:4351`

**DNS-over-HTTPS (DoH) (Recommended for Router):**
- URL: `https://nvkj3k9t7f.cloudflare-gateway.com/dns-query`
- Works from any network (unique subdomain auth)
- More secure than plain IPv4 DNS

### Understanding Endpoint Authentication

**Why IPv4 DNS needs auth:**
- IPv4 (172.64.36.x) **shared** across CF Gateway customers
- CF requires source network verification
- Your authorized network: `89.36.71.24/32`

**Why Other Endpoints Don't:**
- DoH URL = **unique subdomain** `nvkj3k9t7f`
- DoT hostname unique to account
- IPv6 address unique to location
- No source IP checks — unique identifier = auth

**In CF UI:**
- IPv4 DNS may show "requires network authentication"
- Normal + expected
- Working correctly if home IP matches authorized network

## Active Filtering Policies

### Priority: Allow Essential Services

Highest precedence — ensure critical services work:

#### 1. Allow Apple Essential Services (Precedence: 15000)
**Rule ID:** `ccc8d24d-9eef-40a4-b07a-017562883d3e`
**Created:** 2025-10-25T15:14:17Z

Allows:
- `*.apple.com` — core Apple services
- `*.mzstatic.com` — App Store CDN
- `*.apple-dns.net` — Apple DNS
- `*.cdn-apple.com` — Apple content delivery
- `*.icloud.com` — iCloud

**Why:** Required for Apple Maps, App Store, iOS core

#### 2. Allow Microsoft Essential Services (Precedence: 14900)
**Rule ID:** `b8160349-b855-4440-ac8a-33c66c7f90f8`
**Created:** 2025-10-25T15:14:24Z

Allows:
- `*.bing.com` — Bing search/rewards
- `*.microsoft.com` — MS services
- `*.msn.com` — MSN
- `*.live.com` — MS Live

**Why:** Required for Bing Rewards, Office, MS functionality

### Blocking Policies

#### 3. Block Security Threats (Precedence: 10000)
**Rule ID:** `29b4d830-3b18-4408-a0a6-296f8a364fe2`
**Created:** 2025-10-25T14:33:53Z

Blocks:
- Malware (category 117)
- Phishing (category 68)
- C&C servers (category 80)
- Cryptomining (category 83)
- DNS Tunneling (category 176)
- Newly Registered Domains (category 175)

#### 4. Block Ads (Precedence: 9000)
**Rule ID:** `255a300f-3944-4204-9fa1-c267e5382ad3`
**Created:** 2025-10-25T14:34:05Z

Blocks:
- Advertising domains (category 22)
- Ad-serving platforms

#### 5. Block Trackers (Precedence: 8000)
**Rule ID:** `d9c2b108-b991-450c-8510-a99779f7d358`
**Created:** 2025-10-25T14:34:07Z

Blocks:
- Tracking domains (category 155)
- Analytics platforms
- Telemetry services

#### 6. Block Major Trackers (Precedence: 7000)
**Rule ID:** `039fa9b2-a247-446f-a24a-b337ffdba018`
**List ID:** `7d5b0733-d1eb-406e-a920-ae3dcb61a7eb`
**Created:** 2025-10-25T14:34:36Z

Blocks major tracking platforms:
- Google Analytics (`google-analytics.com`, `googletagmanager.com`, `doubleclick.net`)
- Facebook Pixel (`facebook.com`, `connect.facebook.net`, `facebook.net`, `fbcdn.net`)
- Twitter/X tracking (`analytics.twitter.com`, `ads-twitter.com`)
- TikTok tracking (`analytics.tiktok.com`, `ads.tiktok.com`)
- Pinterest tracking (`analytics.pinterest.com`, `ads.pinterest.com`)
- LinkedIn tracking (`analytics.linkedin.com`, `ads.linkedin.com`)
- Session replay (`hotjar.com`, `mouseflow.com`, `luckyorange.com`, `fullstory.com`, `logrocket.com`, `smartlook.com`, `crazyegg.com`)
- Analytics platforms (`segment.com`, `segment.io`, `mixpanel.com`, `amplitude.com`, `heap.io`)
- A/B testing (`optimizely.com`, `vwo.com`)

## Configuration Steps

### Option 1: Router-Level Configuration (Recommended)

Configure router DHCP to provide CF Gateway DNS:

**Router supports DoH (Best):**
1. Access router admin
2. DNS settings
3. Enable DoH, set URL: `https://nvkj3k9t7f.cloudflare-gateway.com/dns-query`
4. Save + reboot

**Router only supports traditional DNS:**
1. Access router admin
2. DHCP/DNS settings
3. Primary DNS: `172.64.36.1`
4. Secondary DNS: `172.64.36.2`
5. Save + reboot
6. **Important:** only works if home IP = `89.36.71.24`
7. Home IP changes → update network list in CF Gateway

**Benefits:**
- Protects all devices automatically
- No per-device config
- Works for IoT, phones, smart TVs

### Option 2: Per-Device Configuration

Individual devices — DNS in network settings:

**macOS:**
1. System Settings → Network → [Connection] → Details → DNS
2. Add: `172.64.36.1` + `172.64.36.2`

**iOS:**
1. Settings → Wi-Fi → [Network] → Configure DNS → Manual
2. Add: `172.64.36.1` + `172.64.36.2`

**Windows:**
1. Network Settings → Adapter Settings → Properties → IPv4
2. DNS: `172.64.36.1` + `172.64.36.2`

**Linux:**
```bash
# Edit /etc/resolv.conf or use NetworkManager
nameserver 172.64.36.1
nameserver 172.64.36.2
```

### Option 3: Mobile Devices Protection

**Mobile DNS Profiles Not Recommended**

DoH profiles for iOS/Android tested → issues with essential services (Apple Maps, App Store, MS) even with allow rules. 3rd party ads/trackers blocked, but aggressive filtering breaks legitimate services.

**Recommended Mobile Protection:**

Home WiFi = full protection via router DNS. For cellular (4G/5G):

**Option A: VPN Back Home (Best)**
1. Enable VPN server on home router (WireGuard/OpenVPN)
2. Configure VPN on iPhone/iPad
3. Connect to home VPN on cellular
4. All DNS routes through home router → Gateway DNS
5. Full protection + everything works

**Option B: Accept Trade-off**
- **Home:** full protection via router DNS
- **Cellular:** no ad/tracker block, all services work
- Most browsing at home anyway

**Option C: Per-Network DNS (Wi-Fi Only)**
Additional WiFi (office, friends):
- **iOS:** Settings → Wi-Fi → [Network] → Configure DNS → Manual
  - Add: `172.64.36.1` + `172.64.36.2`
- **Android:** Settings → Wi-Fi → [Network] → Advanced → DNS
  - Add: `172.64.36.1` + `172.64.36.2`

### Option 4: DNS-over-HTTPS (Browsers)

Browsers supporting DoH:

**Firefox:**
1. Settings → Privacy & Security → DNS over HTTPS
2. Custom provider: `https://nvkj3k9t7f.cloudflare-gateway.com/dns-query`

**Chrome/Edge:**
1. Settings → Privacy and security → Security → Use secure DNS
2. Enter: `https://nvkj3k9t7f.cloudflare-gateway.com/dns-query`

## Verification

Test filtering works:

```bash
# Should be blocked (ad domain)
nslookup ads.google.com 172.64.36.1

# Should be blocked (tracker)
nslookup google-analytics.com 172.64.36.1

# Should work (normal site)
nslookup github.com 172.64.36.1
```

Blocked domains return CF Gateway block page IP.

## Management

### View Analytics
Visit: https://one.dash.cloudflare.com/ → Analytics → Gateway

### Modify Rules
1. Dashboard: https://one.dash.cloudflare.com/
2. Gateway → Firewall Policies → DNS
3. Edit rules / add exceptions

### Update Authorized Network (If Home IP Changes)

Home IP changes → IPv4 DNS stops working:

**Via Dashboard:**
1. https://one.dash.cloudflare.com/
2. Gateway → Locations
3. Click "Homelab" location
4. Update network IP to new public IP

**Via API:**
```bash
curl -X PUT https://api.cloudflare.com/client/v4/accounts/***REMOVED-CF-ACCOUNT-ID***/gateway/locations/55e39ccecdf04717ba7a3363e5838da4 \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Homelab",
    "networks": [{"network": "YOUR.NEW.IP.ADDRESS/32"}]
  }'
```

**Find current public IP:**
```bash
curl ifconfig.me
```

### Add Exceptions (Allow specific domains)

Site breaks due to blocking → create allow rule:

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

Higher precedence = evaluated first → use 20000+ for allow rules.

## Security Considerations

**Protected:**
- All DNS queries encrypted between you + CF
- Malware/phishing blocked auto
- Ad trackers can't profile browsing
- No local blocklist maintenance

**Limitations:**
- Only blocks DNS-level (IP-based tracking still works)
- Some sites may break if require blocked trackers
- CF sees your DNS queries (trade-off for convenience)

## Backup/Restore

Config stored in CF account. Backup:

```bash
# Export rules
curl https://api.cloudflare.com/client/v4/accounts/***REMOVED-CF-ACCOUNT-ID***/gateway/rules \
  -H "Authorization: Bearer YOUR_TOKEN" > gateway-rules-backup.json

# Export lists
curl https://api.cloudflare.com/client/v4/accounts/***REMOVED-CF-ACCOUNT-ID***/gateway/lists \
  -H "Authorization: Bearer YOUR_TOKEN" > gateway-lists-backup.json
```

## Monitoring

Query logs + blocked requests:
- Dashboard: https://one.dash.cloudflare.com/ → Logs → Gateway

Alerts for suspicious activity:
- Dashboard: https://one.dash.cloudflare.com/ → Notifications

## Next Steps

1. Configure router DNS (recommended first)
2. Monitor analytics 24-48h → blocking effectiveness
3. Add allow rules for broken legit sites
4. Consider browser DoH for extra privacy on public WiFi
