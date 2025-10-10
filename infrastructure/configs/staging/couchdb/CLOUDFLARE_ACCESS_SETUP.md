# Setting Up Cloudflare Access for CouchDB

This guide walks you through adding Cloudflare Access (Zero Trust) authentication to CouchDB, providing an additional security layer beyond basic authentication.

## What is Cloudflare Access?

Cloudflare Access is a Zero Trust security solution that:
- Requires authentication before reaching your application
- Supports multiple authentication methods (email OTP, SSO, 2FA)
- Provides detailed access logs
- Works transparently with Cloudflare Tunnels

**With Access enabled:** Internet → Cloudflare Access (Auth) → Cloudflare Tunnel → CouchDB
**Without Access:** Internet → Cloudflare Tunnel → CouchDB ⚠️

## Step 1: Enable Cloudflare Zero Trust

1. **Access Cloudflare Dashboard:**
   - Go to https://one.dash.cloudflare.com/
   - Select your account
   - Go to "Zero Trust" (left sidebar)

2. **Create a Team (if first time):**
   - Choose a team name (e.g., "homelab")
   - This will be part of your auth domain: `<team-name>.cloudflareaccess.com`

## Step 2: Create an Access Application

1. **Navigate to Access:**
   - Zero Trust → Access → Applications
   - Click "Add an application"
   - Choose "Self-hosted"

2. **Configure Application:**
   ```
   Application name: CouchDB
   Session Duration: 24 hours
   Application domain: couchdb.h0melab.work
   ```

3. **Click "Next"**

## Step 3: Create Access Policy

1. **Add Policy:**
   ```
   Policy name: CouchDB Access
   Action: Allow
   ```

2. **Configure Authentication Rules** (Choose one or more):

   **Option A: Email + One-Time PIN (Simplest)**
   ```
   Include rule:
   - Selector: Emails
   - Value: your@email.com
   ```
   Every login requires an OTP sent to your email.

   **Option B: GitHub/Google SSO (Recommended)**
   ```
   Include rule:
   - Selector: Login Methods
   - Value: GitHub (or Google, etc.)

   AND

   - Selector: Emails
   - Value: your@email.com (from your GitHub/Google account)
   ```

   **Option C: IP Restrictions (Additional Layer)**
   Add an additional rule:
   ```
   Require rule:
   - Selector: IP ranges
   - Value: YOUR_HOME_IP/32, YOUR_MOBILE_IP_RANGE
   ```

3. **Click "Next"**, then "Add application"

## Step 4: Test Access

1. **Open CouchDB in browser:**
   ```
   https://couchdb.h0melab.work
   ```

2. **You should see Cloudflare Access login:**
   - If using Email OTP: Enter email, receive code, enter code
   - If using SSO: Click "Sign in with GitHub/Google"

3. **After authentication:**
   - You'll be redirected to CouchDB
   - Enter CouchDB username/password as normal
   - Two layers of auth: Cloudflare Access + CouchDB auth

## Step 5: Configure Obsidian with Service Token

For Obsidian to work with Cloudflare Access, you need a Service Token (machine-to-machine auth).

### Create Service Token

1. **Navigate to Service Auth:**
   - Zero Trust → Access → Service Auth
   - Click "Create Service Token"

2. **Configure Token:**
   ```
   Name: Obsidian LiveSync
   Duration: No expiration (or set expiration as needed)
   ```

3. **Save the credentials:**
   ```
   Client ID: <copy this>
   Client Secret: <copy this - shown only once>
   ```
   **Important:** Store these securely - you won't see the secret again!

### Update Access Policy for Service Token

1. **Edit CouchDB Application:**
   - Zero Trust → Access → Applications
   - Click on "CouchDB"
   - Edit the policy

2. **Add Service Token rule:**
   ```
   Include rule:
   - Selector: Service Auth
   - Value: Obsidian LiveSync (the token you created)
   ```

3. **Save policy**

### Configure Obsidian LiveSync Plugin

1. **Open Obsidian Settings:**
   - Settings → Community Plugins → Obsidian LiveSync

2. **Add Custom Headers:**
   ```
   Header name: CF-Access-Client-Id
   Header value: <paste Client ID>

   Header name: CF-Access-Client-Secret
   Header value: <paste Client Secret>
   ```

3. **Test connection:**
   - Click "Check database configuration"
   - Should connect successfully without browser authentication

## Step 6: Add Rate Limiting (Optional but Recommended)

1. **Navigate to WAF:**
   - Go to Cloudflare Dashboard (not Zero Trust)
   - Select your domain (h0melab.work)
   - Security → WAF → Rate limiting rules

2. **Create Rule:**
   ```
   Rule name: CouchDB Rate Limit

   If:
   - Hostname equals couchdb.h0melab.work
   - URI Path contains /_session

   Then:
   - When rate exceeds: 10 requests per 1 minute
   - For: 1 minute
   - Action: Block
   ```

3. **Save and Deploy**

## Step 7: Verify Security

### Test 1: Browser Access (Human)
```bash
# Open in browser
https://couchdb.h0melab.work

# Expected flow:
1. Cloudflare Access login screen
2. Authenticate (email OTP or SSO)
3. Redirected to CouchDB
4. CouchDB login (username/password)
5. Access granted
```

### Test 2: Obsidian Access (Machine)
```
# With service token in custom headers:
1. Obsidian connects directly
2. Service token validated by Cloudflare
3. CouchDB credentials validated
4. Sync works normally
```

### Test 3: Direct API Access (Should Fail)
```bash
# Without authentication, should get Access denied
curl https://couchdb.h0melab.work

# Expected response:
# Cloudflare Access authentication required
```

## Security Benefits

✅ **Before (Basic Auth Only):**
- Single point of failure: password
- Vulnerable to brute force
- No visibility into access attempts
- No geographic restrictions

✅ **After (Cloudflare Access + Basic Auth):**
- Two authentication layers
- Protection against brute force (Access blocks before reaching CouchDB)
- Detailed access logs in Cloudflare
- Geographic restrictions possible
- IP allowlisting possible
- Device posture checks possible
- Session management and revocation

## Monitoring

### Access Logs
- Zero Trust → Logs → Access requests
- Shows all authentication attempts
- Filter by application (CouchDB)

### Alerts
Set up alerts for:
- Failed authentication attempts (> 5 in 5 min)
- Access from new locations
- Service token usage from unexpected IPs

### Audit
- Review Access logs weekly
- Rotate service tokens quarterly
- Review allowed email addresses monthly

## Troubleshooting

### Obsidian Can't Connect
- Verify service token is active (Zero Trust → Service Auth)
- Check custom headers are correctly entered
- Ensure service token is included in Access policy
- Check Obsidian LiveSync logs

### Browser Shows "Access Denied"
- Verify your email is in the Access policy
- Check if IP restrictions are blocking you
- Try incognito mode (clear Access cookies)
- Check Cloudflare Access logs

### Rate Limiting Triggering Incorrectly
- Adjust rate limits (increase threshold)
- Whitelist your home IP from rate limiting
- Check if Obsidian is making excessive requests

## References

- [Cloudflare Access Documentation](https://developers.cloudflare.com/cloudflare-one/applications/)
- [Service Tokens](https://developers.cloudflare.com/cloudflare-one/identity/service-tokens/)
- [Obsidian LiveSync](https://github.com/vrtmrz/obsidian-livesync)
