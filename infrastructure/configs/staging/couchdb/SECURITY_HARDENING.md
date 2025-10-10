# CouchDB Security Hardening

CouchDB is currently exposed to the internet via Cloudflare Tunnel at `couchdb.h0melab.work`. This document outlines recommended security hardening measures.

## Current Security Posture

⚠️ **Current Protection:**
- Basic HTTP authentication (username/password only)
- CORS restrictions
- `require_valid_user: true` setting

⚠️ **Concerns:**
- Vulnerable to credential stuffing/brute force attacks
- No additional authentication layers
- Single point of failure (compromised password = full access)

## Recommended Hardening Measures

### 1. Cloudflare Access (Zero Trust) - HIGHEST PRIORITY

Add Cloudflare Access to require authentication before reaching CouchDB.

**Benefits:**
- Additional authentication layer (2FA, SSO, OTP)
- Protection against brute force attacks
- Access logs and analytics
- Device posture checks
- Geographic restrictions

**Implementation:**

1. **Enable Cloudflare Access:**
   - Go to Cloudflare Dashboard → Zero Trust → Access
   - Create an application for `couchdb.h0melab.work`

2. **Configure Access Policy:**
   ```
   Application Name: CouchDB
   Application Domain: couchdb.h0melab.work
   Session Duration: 24 hours (or shorter)

   Policy Rules:
   - Require: Email (your email)
   - Require: One-time PIN (OTP)
   OR
   - Require: GitHub/Google SSO
   ```

3. **Update Cloudflare Tunnel Config:**
   No changes needed - Access works transparently with tunnels

**Obsidian Compatibility:**
- Cloudflare Access provides a token after authentication
- Obsidian LiveSync plugin supports custom headers for authentication
- Alternative: Use a service token for Obsidian

### 2. IP Allowlist (Geographic/Network Restrictions)

Restrict access to specific IP ranges or countries.

**Cloudflare Firewall Rules:**
```
Rule 1: Block all except home network
- Field: IP Address
- Operator: is not in
- Value: YOUR_HOME_IP, YOUR_MOBILE_CARRIER_IP_RANGE
- Action: Block

Rule 2: Block by country (optional)
- Field: Country
- Operator: is not in
- Value: [Your country code]
- Action: Block
```

**Limitation:** Dynamic IPs may require frequent updates

### 3. Rate Limiting

Prevent brute force attacks by limiting request rates.

**Cloudflare Rate Limiting:**
```
Rule: Protect CouchDB login
- If hostname is couchdb.h0melab.work
- And URI path is /_session
- And request count > 5 requests per 1 minute
- Then: Challenge (Captcha) or Block
```

### 4. NetworkPolicy (Kubernetes)

Restrict CouchDB pods to only accept connections from Cloudflare tunnel.

**See:** `infrastructure/configs/base/couchdb/networkpolicy.yaml` (created below)

### 5. Client Certificates (Advanced)

Use mutual TLS (mTLS) for certificate-based authentication.

**Benefits:**
- Strongest authentication method
- No password to compromise
- Per-device certificates

**Limitations:**
- Complex setup for mobile devices
- Obsidian plugin may not support client certificates

## Recommended Implementation Order

1. ✅ **Add NetworkPolicy** (Immediate - no Obsidian config changes)
2. ✅ **Enable Cloudflare Access** (High priority - requires Obsidian reconfiguration)
3. ✅ **Add Rate Limiting** (Immediate - transparent to Obsidian)
4. 🔄 **IP Allowlist** (Optional - may break mobile access)
5. 🔄 **Client Certificates** (Future consideration)

## Obsidian Configuration with Cloudflare Access

### Option A: Service Token (Recommended)

1. Create a Service Token in Cloudflare Access
2. Add custom header in Obsidian LiveSync:
   ```
   CF-Access-Client-Id: <service-token-id>
   CF-Access-Client-Secret: <service-token-secret>
   ```

### Option B: Manual Authentication

1. User authenticates via browser first
2. Cloudflare sets authentication cookie
3. Obsidian uses cookie for subsequent requests
4. Re-authenticate when session expires

## Monitoring and Alerts

**Set up Cloudflare alerts for:**
- Failed authentication attempts (> 5 in 5 minutes)
- Access from unknown countries
- Large data transfers
- Unusual access patterns

## References

- [Cloudflare Access Documentation](https://developers.cloudflare.com/cloudflare-one/applications/)
- [Obsidian LiveSync Custom Headers](https://github.com/vrtmrz/obsidian-livesync)
- [CouchDB Security Documentation](https://docs.couchdb.org/en/stable/intro/security.html)
