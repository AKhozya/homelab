# Cloudflare Access Setup - 4 Device Configuration

This guide walks you through setting up Cloudflare Access with separate service tokens for each of your devices.

## 🎯 Devices to Configure

1. iPhone
2. iPad
3. Personal Mac
4. Work Mac

## 📋 Setup Checklist

- [ ] Step 1: Enable Cloudflare Zero Trust
- [ ] Step 2: Create Access Application for CouchDB
- [ ] Step 3: Create 4 Service Tokens
- [ ] Step 4: Configure Access Policy
- [ ] Step 5: Configure Obsidian on iPhone
- [ ] Step 6: Configure Obsidian on iPad
- [ ] Step 7: Configure Obsidian on Personal Mac
- [ ] Step 8: Configure Obsidian on Work Mac
- [ ] Step 9: Test all devices
- [ ] Step 10: Set up monitoring

---

## Step 1: Enable Cloudflare Zero Trust

1. **Go to Cloudflare Zero Trust Dashboard:**
   ```
   https://one.dash.cloudflare.com/
   ```

2. **Select your account**

3. **Navigate to Zero Trust** (left sidebar)

4. **Create a Team (if first time):**
   - Team name: `homelab` (or any name you prefer)
   - This creates your auth domain: `<team-name>.cloudflareaccess.com`
   - Click "Continue"

---

## Step 2: Create Access Application

1. **Navigate to Applications:**
   ```
   Zero Trust → Access → Applications
   ```

2. **Click "Add an application"**

3. **Select "Self-hosted"**

4. **Configure Application:**
   ```
   Application name: CouchDB
   Session Duration: 24 hours (this is for browser access, not Obsidian)
   Application domain: couchdb.h0melab.work
   ```

5. **Click "Next"**

6. **Create a placeholder policy (we'll update this later):**
   ```
   Policy name: Allow Service Tokens
   Action: Allow

   Include rule:
   - Selector: Emails
   - Value: alexander.khozya@gmail.com (your email for browser access)
   ```

7. **Click "Next"**, then **"Add application"**

---

## Step 3: Create 4 Service Tokens

Now create separate tokens for each device.

### Token 1: iPhone

1. **Navigate to Service Auth:**
   ```
   Zero Trust → Access → Service Auth
   ```

2. **Click "Create Service Token"**

3. **Configure:**
   ```
   Name: Obsidian - iPhone
   Duration: No expiration
   ```

4. **Click "Generate token"**

5. **SAVE THESE CREDENTIALS IMMEDIATELY:**
   ```
   Client ID: [Copy this - you'll need it for iPhone]
   Client Secret: [Copy this - SHOWN ONLY ONCE]
   ```

   **Store in a secure location** (password manager, encrypted note, etc.)

### Token 2: iPad

Repeat the process:

1. **Click "Create Service Token"**

2. **Configure:**
   ```
   Name: Obsidian - iPad
   Duration: No expiration
   ```

3. **Click "Generate token"**

4. **SAVE CREDENTIALS:**
   ```
   Client ID: [Copy for iPad]
   Client Secret: [Copy for iPad - SHOWN ONLY ONCE]
   ```

### Token 3: Personal Mac

1. **Click "Create Service Token"**

2. **Configure:**
   ```
   Name: Obsidian - Personal Mac
   Duration: No expiration
   ```

3. **Click "Generate token"**

4. **SAVE CREDENTIALS:**
   ```
   Client ID: [Copy for Personal Mac]
   Client Secret: [Copy for Personal Mac - SHOWN ONLY ONCE]
   ```

### Token 4: Work Mac

1. **Click "Create Service Token"**

2. **Configure:**
   ```
   Name: Obsidian - Work Mac
   Duration: No expiration
   ```

3. **Click "Generate token"**

4. **SAVE CREDENTIALS:**
   ```
   Client ID: [Copy for Work Mac]
   Client Secret: [Copy for Work Mac - SHOWN ONLY ONCE]
   ```

### ✅ Verify All Tokens Created

You should now see 4 service tokens in the list:
```
✓ Obsidian - iPhone
✓ Obsidian - iPad
✓ Obsidian - Personal Mac
✓ Obsidian - Work Mac
```

---

## Step 4: Update Access Policy

Now add all service tokens to the CouchDB Access application.

1. **Navigate to Applications:**
   ```
   Zero Trust → Access → Applications
   ```

2. **Find "CouchDB" application and click to edit**

3. **Click on the policy (first tab should be "Policies")**

4. **Edit the "Allow Service Tokens" policy**

5. **Update the Include rules:**
   ```
   Include (keep existing):
   - Selector: Emails
   - Value: alexander.khozya@gmail.com

   Include (add new):
   - Selector: Service Auth
   - Value: Select all 4 tokens:
     ☑ Obsidian - iPhone
     ☑ Obsidian - iPad
     ☑ Obsidian - Personal Mac
     ☑ Obsidian - Work Mac
   ```

6. **Click "Save"**

---

## Step 5: Configure Obsidian on iPhone

1. **Open Obsidian on iPhone**

2. **Go to Settings:**
   ```
   Settings (⚙️) → Community plugins → Obsidian LiveSync
   ```

3. **Scroll to "Remote Database Configuration"**

4. **Find "Additional Headers" or "Custom Headers" section**
   (May need to expand "Advanced" section)

5. **Add Header 1:**
   ```
   Header name: CF-Access-Client-Id
   Header value: [Paste iPhone Client ID]
   ```

6. **Add Header 2:**
   ```
   Header name: CF-Access-Client-Secret
   Header value: [Paste iPhone Client Secret]
   ```

7. **Save settings**

8. **Test connection:**
   ```
   Click "Check database configuration"
   Should show: ✅ Connection successful
   ```

9. **Trigger a sync:**
   ```
   Tap sync button
   Should sync normally ✅
   ```

---

## Step 6: Configure Obsidian on iPad

Repeat the same process with iPad credentials:

1. **Open Obsidian on iPad**

2. **Settings → Community plugins → Obsidian LiveSync**

3. **Remote Database Configuration → Additional Headers**

4. **Add Header 1:**
   ```
   Header name: CF-Access-Client-Id
   Header value: [Paste iPad Client ID]
   ```

5. **Add Header 2:**
   ```
   Header name: CF-Access-Client-Secret
   Header value: [Paste iPad Client Secret]
   ```

6. **Save and test connection**

---

## Step 7: Configure Obsidian on Personal Mac

1. **Open Obsidian on Personal Mac**

2. **Settings → Community plugins → Obsidian LiveSync**

3. **Remote Database Configuration → Additional Headers**

4. **Add Header 1:**
   ```
   Header name: CF-Access-Client-Id
   Header value: [Paste Personal Mac Client ID]
   ```

5. **Add Header 2:**
   ```
   Header name: CF-Access-Client-Secret
   Header value: [Paste Personal Mac Client Secret]
   ```

6. **Save and test connection**

---

## Step 8: Configure Obsidian on Work Mac

1. **Open Obsidian on Work Mac**

2. **Settings → Community plugins → Obsidian LiveSync**

3. **Remote Database Configuration → Additional Headers**

4. **Add Header 1:**
   ```
   Header name: CF-Access-Client-Id
   Header value: [Paste Work Mac Client ID]
   ```

5. **Add Header 2:**
   ```
   Header name: CF-Access-Client-Secret
   Header value: [Paste Work Mac Client Secret]
   ```

6. **Save and test connection**

---

## Step 9: Test All Devices

Test each device one by one:

### iPhone
```
1. Open Obsidian
2. Make a change (add a line to a note)
3. Trigger sync
4. Verify: ✅ Sync successful
```

### iPad
```
1. Open Obsidian
2. Verify changes from iPhone appeared
3. Make a different change
4. Trigger sync
5. Verify: ✅ Sync successful
```

### Personal Mac
```
1. Open Obsidian
2. Verify changes from iPad appeared
3. Make a different change
4. Trigger sync
5. Verify: ✅ Sync successful
```

### Work Mac
```
1. Open Obsidian
2. Verify all changes appeared
3. Make a final change
4. Trigger sync
5. Verify: ✅ Sync successful
```

### Cross-Device Verification
```
1. Check iPhone - should see all changes
2. Check iPad - should see all changes
3. Check Personal Mac - should see all changes
4. Check Work Mac - should see all changes
```

---

## Step 10: Set Up Monitoring

### View Access Logs

1. **Navigate to Logs:**
   ```
   Zero Trust → Logs → Access requests
   ```

2. **Filter by application:**
   ```
   Application: CouchDB
   ```

3. **You should see requests from each service token:**
   ```
   ✓ Obsidian - iPhone (requests from iPhone)
   ✓ Obsidian - iPad (requests from iPad)
   ✓ Obsidian - Personal Mac (requests from Personal Mac)
   ✓ Obsidian - Work Mac (requests from Work Mac)
   ```

### Set Up Alerts (Optional)

1. **Navigate to Notifications:**
   ```
   Zero Trust → Settings → Notifications
   ```

2. **Create alert for failed authentications:**
   ```
   Alert name: CouchDB Failed Auth
   Condition: Failed authentication attempts > 5
   Time period: 5 minutes
   Action: Send email to alexander.khozya@gmail.com
   ```

---

## 📱 Quick Reference Card

Save this for future reference:

```
Device          | Service Token Name       | Status
----------------|--------------------------|--------
iPhone          | Obsidian - iPhone        | Active
iPad            | Obsidian - iPad          | Active
Personal Mac    | Obsidian - Personal Mac  | Active
Work Mac        | Obsidian - Work Mac      | Active
```

**Header Names (same for all devices):**
```
CF-Access-Client-Id
CF-Access-Client-Secret
```

**Where to configure:**
```
Obsidian Settings → Community Plugins → Obsidian LiveSync
→ Remote Database Configuration → Additional Headers
```

---

## 🔧 Troubleshooting

### iPhone/iPad Not Syncing

1. **Check headers are correctly entered:**
   - No extra spaces
   - Complete Client ID and Secret
   - Header names exactly: `CF-Access-Client-Id` and `CF-Access-Client-Secret`

2. **Check Cloudflare Access logs:**
   - Zero Trust → Logs → Access requests
   - Look for denied requests
   - Verify service token name matches

3. **Verify service token is in policy:**
   - Zero Trust → Access → Applications → CouchDB
   - Check "Obsidian - iPhone" is selected in Service Auth

### Work Mac Behind Corporate Firewall

If your work Mac is behind a corporate firewall:

1. **Check if Cloudflare is blocked:**
   ```bash
   curl -I https://couchdb.h0melab.work
   ```

2. **If blocked, options:**
   - Use corporate VPN with split tunneling
   - Whitelist `*.h0melab.work` in corporate firewall
   - Use mobile hotspot for Obsidian sync

### Token Compromised

If you suspect a token is compromised:

1. **Revoke the token:**
   ```
   Zero Trust → Access → Service Auth
   → Find token → Delete
   ```

2. **Create new token with same name**

3. **Update Obsidian on that device with new credentials**

4. **Other devices are unaffected**

---

## 🔒 Security Benefits

✅ **Per-Device Tracking:**
- See which device accessed CouchDB in logs
- Identify unusual access patterns
- Audit trail per device

✅ **Selective Revocation:**
- Lost iPhone? Revoke only iPhone token
- Selling iPad? Revoke iPad token
- Other devices continue working

✅ **Access Control:**
- Can set per-token policies in future
- Geographic restrictions per device
- Time-based access per device

---

## 🔄 Token Rotation Schedule

**Recommended rotation schedule:**

```
Quarterly (every 3 months):
1. Create new service token
2. Update Obsidian on device
3. Revoke old token
4. Takes 2 minutes per device
```

**Annual rotation (minimum):**
```
Once a year, rotate all 4 tokens for best security
```

---

## 📞 Support

If you encounter issues:

1. **Check Cloudflare Access logs first**
2. **Verify service token is active**
3. **Double-check header spelling**
4. **Test with browser:**
   ```
   Open: https://couchdb.h0melab.work
   Should prompt for Cloudflare Access login
   After auth, should show CouchDB
   ```

---

## ✅ Final Verification Checklist

- [ ] 4 service tokens created in Cloudflare
- [ ] All 4 tokens added to CouchDB Access policy
- [ ] iPhone Obsidian configured and syncing
- [ ] iPad Obsidian configured and syncing
- [ ] Personal Mac Obsidian configured and syncing
- [ ] Work Mac Obsidian configured and syncing
- [ ] Cross-device sync tested and working
- [ ] Access logs showing all 4 devices
- [ ] Monitoring/alerts configured (optional)
- [ ] Credentials saved securely

**Congratulations!** 🎉 Your CouchDB is now protected by multi-layered security:
- Cloudflare Access (Zero Trust)
- NetworkPolicy (Kubernetes)
- Basic Auth (CouchDB)
- Per-device tracking and revocation
