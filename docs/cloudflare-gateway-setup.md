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

**IPv4 DNS Servers (Network-Authenticated):**
- Primary: `172.64.36.1`
- Secondary: `172.64.36.2`
- ⚠️ **Authentication Required:** Only works from authorized network `89.36.71.24/32`
- If your home IP changes, update the network list in Cloudflare Gateway settings

**IPv6 DNS Server:**
- `2a06:98c1:54::20:4351`

**DNS-over-HTTPS (DoH) (Recommended for Router):**
- URL: `https://nvkj3k9t7f.cloudflare-gateway.com/dns-query`
- ✅ Works from any network (uses unique subdomain authentication)
- More secure than plain IPv4 DNS

### Understanding Endpoint Authentication

**Why IPv4 DNS Requires Authentication:**
- IPv4 addresses (172.64.36.x) are **shared** across Cloudflare Gateway customers
- Cloudflare requires source network verification to prevent unauthorized use
- Your authorized network: `89.36.71.24/32`

**Why Other Endpoints Don't:**
- DoH URL uses your **unique subdomain**: `nvkj3k9t7f`
- DoT hostname is also unique to your account
- IPv6 address is unique to your location
- These don't need source IP checks - the unique identifier is the authentication

**In the Cloudflare UI:**
- IPv4 DNS may show as "requires network authentication" or similar
- This is normal and expected behavior
- The endpoint is working correctly if your home IP matches the authorized network

## Active Filtering Policies

### Priority: Allow Essential Services

These rules have the highest precedence to ensure critical services work correctly:

#### 1. Allow Apple Essential Services (Precedence: 15000)
**Rule ID:** `ccc8d24d-9eef-40a4-b07a-017562883d3e`
**Created:** 2025-10-25T15:14:17Z

Allows:
- `*.apple.com` - Core Apple services
- `*.mzstatic.com` - App Store CDN
- `*.apple-dns.net` - Apple DNS infrastructure
- `*.cdn-apple.com` - Apple content delivery
- `*.icloud.com` - iCloud services

**Why:** Required for Apple Maps, App Store, and iOS core functionality

#### 2. Allow Microsoft Essential Services (Precedence: 14900)
**Rule ID:** `b8160349-b855-4440-ac8a-33c66c7f90f8`
**Created:** 2025-10-25T15:14:24Z

Allows:
- `*.bing.com` - Bing search and rewards
- `*.microsoft.com` - Microsoft services
- `*.msn.com` - MSN services
- `*.live.com` - Microsoft Live services

**Why:** Required for Bing Rewards, Office, and Microsoft functionality

### Blocking Policies

#### 3. Block Security Threats (Precedence: 10000)
**Rule ID:** `29b4d830-3b18-4408-a0a6-296f8a364fe2`
**Created:** 2025-10-25T14:33:53Z

Blocks:
- Malware (category 117)
- Phishing (category 68)
- Command & Control servers (category 80)
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

**If your router supports DNS-over-HTTPS (Best Option):**
1. Access your router's admin panel
2. Navigate to DNS settings
3. Enable DoH and set URL: `https://nvkj3k9t7f.cloudflare-gateway.com/dns-query`
4. Save and reboot router

**If your router only supports traditional DNS:**
1. Access your router's admin panel
2. Navigate to DHCP/DNS settings
3. Set Primary DNS: `172.64.36.1`
4. Set Secondary DNS: `172.64.36.2`
5. Save and reboot router
6. ⚠️ **Important:** This only works if your home IP is `89.36.71.24`
7. If your home IP changes, update the network list in Cloudflare Gateway

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

### Option 3: Mobile Devices Protection

**⚠️ Mobile DNS Profiles Not Recommended**

DNS-over-HTTPS profiles for iOS/Android were tested but cause issues with essential services (Apple Maps, App Store, Microsoft services) even with allow rules configured. While third-party ads and trackers are blocked, the aggressive filtering breaks too many legitimate services.

**Recommended Approach for Mobile Protection:**

Your home WiFi already provides full protection via router DNS. For protection on cellular (4G/5G) networks:

**Option A: VPN Back to Home (Best Solution)**
1. Enable VPN server on your home router (WireGuard or OpenVPN)
2. Configure VPN on your iPhone/iPad
3. Connect to home VPN when on cellular
4. All DNS queries route through home router → Gateway DNS
5. ✅ Full protection + everything works

**Option B: Accept Trade-off**
- ✅ **At home:** Full protection via router DNS
- ❌ **On cellular:** No ad/tracker blocking, but all services work
- Most of your browsing is likely at home anyway

**Option C: Per-Network DNS (Wi-Fi Only)**
For additional WiFi networks (office, friends' homes):
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

### Update Authorized Network (If Your Home IP Changes)

If your home IP changes and IPv4 DNS stops working:

**Via Dashboard:**
1. Go to: https://one.dash.cloudflare.com/
2. Navigate to Gateway → Locations
3. Click on "Homelab" location
4. Update the network IP to your new public IP

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

**Find your current public IP:**
```bash
curl ifconfig.me
```

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
