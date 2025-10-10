# Cloudflare Access Setup - Simple (One Token for All Devices)

This is the simplified setup using ONE service token shared across all your devices.

## ⏱️ Total Time: ~20 minutes

- Cloudflare setup: 10 minutes
- Configure all 4 devices: 10 minutes

---

## 🎯 What You'll Do

1. Create Cloudflare Access application
2. Create ONE service token
3. Use the SAME token on all 4 devices:
   - iPhone
   - iPad
   - Personal Mac
   - Work Mac

---

## Step 1: Enable Cloudflare Zero Trust (5 minutes)

1. **Go to Cloudflare Zero Trust:**
   ```
   https://one.dash.cloudflare.com/
   ```

2. **Select your account**

3. **Navigate to "Zero Trust"** (left sidebar)

4. **Create a Team (if first time):**
   ```
   Team name: homelab
   ```
   Creates auth domain: `homelab.cloudflareaccess.com`

---

## Step 2: Create Access Application (3 minutes)

1. **Navigate to Applications:**
   ```
   Zero Trust → Access → Applications
   ```

2. **Click "Add an application"**

3. **Select "Self-hosted"**

4. **Configure:**
   ```
   Application name: CouchDB
   Session Duration: 24 hours
   Application domain: couchdb.h0melab.work
   ```

5. **Click "Next"**

6. **Create policy:**
   ```
   Policy name: CouchDB Access
   Action: Allow

   Include rule:
   - Selector: Emails
   - Value: alexander.khozya@gmail.com
   ```
   (This is for browser access only)

7. **Click "Next"** → **"Add application"**

---

## Step 3: Create ONE Service Token (2 minutes)

1. **Navigate to Service Auth:**
   ```
   Zero Trust → Access → Service Auth
   ```

2. **Click "Create Service Token"**

3. **Configure:**
   ```
   Name: Obsidian All Devices
   Duration: No expiration
   ```

4. **Click "Generate token"**

5. **⚠️ SAVE THESE IMMEDIATELY (shown only once):**
   ```
   Client ID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   Client Secret: yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy
   ```

   **Copy both to:**
   - Password manager (1Password, Bitwarden, etc.)
   - Encrypted notes
   - Secure location

   **YOU WON'T SEE THE SECRET AGAIN!**

---

## Step 4: Add Token to Access Policy (2 minutes)

1. **Go back to Applications:**
   ```
   Zero Trust → Access → Applications
   ```

2. **Click on "CouchDB" to edit**

3. **Click on the policy to edit**

4. **Add service token:**
   ```
   Include (add new rule):
   - Selector: Service Auth
   - Value: ☑ Obsidian All Devices
   ```

5. **Click "Save"**

---

## Step 5: Configure All Obsidian Devices (2 minutes per device)

Use the SAME credentials on ALL devices.

### Personal Mac (Configure First)

1. **Open Obsidian**

2. **Settings → Community Plugins → Obsidian LiveSync**

3. **Remote Database Configuration → Additional Headers**

4. **Add Header 1:**
   ```
   Header name: CF-Access-Client-Id
   Header value: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   ```
   (Paste the Client ID you saved)

5. **Add Header 2:**
   ```
   Header name: CF-Access-Client-Secret
   Header value: yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy
   ```
   (Paste the Client Secret you saved)

6. **Click "Check database configuration"**
   ```
   Should show: ✅ Connection successful
   ```

7. **Trigger a sync - should work!**

### iPhone

Repeat with SAME credentials:

1. **Open Obsidian on iPhone**
2. **Settings → Community Plugins → Obsidian LiveSync**
3. **Remote Database Configuration → Additional Headers**
4. **Add the SAME two headers:**
   ```
   CF-Access-Client-Id: [Same Client ID]
   CF-Access-Client-Secret: [Same Client Secret]
   ```
5. **Test sync**

### iPad

Repeat with SAME credentials:

1. **Open Obsidian on iPad**
2. **Settings → Community Plugins → Obsidian LiveSync**
3. **Remote Database Configuration → Additional Headers**
4. **Add the SAME two headers**
5. **Test sync**

### Work Mac

Repeat with SAME credentials:

1. **Open Obsidian on Work Mac**
2. **Settings → Community Plugins → Obsidian LiveSync**
3. **Remote Database Configuration → Additional Headers**
4. **Add the SAME two headers**
5. **Test sync**

---

## Step 6: Test All Devices (5 minutes)

1. **Personal Mac:** Make a change, sync ✅
2. **iPhone:** Open Obsidian, verify change appeared ✅
3. **iPad:** Make another change, sync ✅
4. **Work Mac:** Verify both changes appeared ✅
5. **Personal Mac:** Check all changes are there ✅

If all devices show all changes, you're done! 🎉

---

## 📋 Quick Reference

**What to save in your password manager:**

```
Service: CouchDB Obsidian Access
URL: https://couchdb.h0melab.work

Client ID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
Client Secret: yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy

Used on:
- iPhone Obsidian
- iPad Obsidian
- Personal Mac Obsidian
- Work Mac Obsidian
```

**Obsidian headers (same on all devices):**
```
CF-Access-Client-Id: [Your Client ID]
CF-Access-Client-Secret: [Your Client Secret]
```

---

## ✅ Security Benefits

**What you get:**
- ✅ Two layers of auth (Cloudflare Access + CouchDB password)
- ✅ Protection against brute force attacks
- ✅ Access logs in Cloudflare
- ✅ Can add rate limiting
- ✅ Can add IP restrictions
- ✅ Can add geographic restrictions
- ✅ Never need to reauthenticate

**What you trade-off vs. per-device tokens:**
- ❌ Can't see which specific device accessed in logs (all show "Obsidian All Devices")
- ❌ Can't revoke one device individually (would need to revoke all and reconfigure)

**For most users, this is the best balance of security and simplicity!**

---

## 🔒 Security Notes

**Shared token is secure because:**
- Token is like a password - only you know it
- All your devices are trusted
- Much easier to manage than 4 tokens
- Still adds Cloudflare Access protection layer

**Keep token secure:**
- Don't share with others
- Store in password manager
- Don't commit to Git
- Rotate quarterly (every 3 months)

---

## 🔄 Token Rotation (Every 3 Months)

When rotating the token:

1. **Create new service token in Cloudflare**
2. **Update all 4 devices with new credentials**
   - Takes 2 minutes per device = 8 minutes total
3. **Revoke old token**
4. **Done!**

Set a calendar reminder: **[Today's date + 3 months]**

---

## 🆘 Troubleshooting

### Sync Not Working

**Check 1: Headers spelled correctly**
```
Must be exactly:
CF-Access-Client-Id (capital CF, hyphens, no spaces)
CF-Access-Client-Secret (capital CF, hyphens, no spaces)
```

**Check 2: Full credentials pasted**
```
Client ID should be: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (36 characters)
Client Secret should be: yyyyyy... (64 characters)
No extra spaces or line breaks
```

**Check 3: Token is in policy**
```
Zero Trust → Access → Applications → CouchDB
→ Edit policy → Verify "Obsidian All Devices" is selected
```

**Check 4: Token is active**
```
Zero Trust → Access → Service Auth
→ Verify "Obsidian All Devices" shows as Active
```

**Check 5: View logs**
```
Zero Trust → Logs → Access requests
→ Filter: Application = CouchDB
→ Look for denied requests
```

### Browser Test (Manual Verification)

To test browser access (separate from Obsidian):

1. **Open browser:**
   ```
   https://couchdb.h0melab.work
   ```

2. **Should see Cloudflare Access login screen**

3. **Enter email:** `alexander.khozya@gmail.com`

4. **Get OTP code via email**

5. **After Access auth, should see CouchDB**

6. **Enter CouchDB username/password**

This verifies Cloudflare Access is working (browser uses email auth, Obsidian uses service token).

---

## 🎯 What Changed in Your Workflow

**Before:**
```
Open Obsidian → Sync → Done
```

**After:**
```
Open Obsidian → Sync → Done
```

**No difference!** The service token works automatically in the background. You'll never see authentication prompts.

---

## 📊 Monitoring

**View access logs:**
```
Zero Trust → Logs → Access requests
Filter by: Application = CouchDB
```

You'll see requests from "Obsidian All Devices" - can't tell which specific device, but can see:
- Timestamp
- IP address
- Success/failure
- Request path

**Set up alerts (optional):**
```
Zero Trust → Settings → Notifications
Create alert:
- Failed auth attempts > 5 in 5 minutes
- Access from unexpected country
- Email: alexander.khozya@gmail.com
```

---

## 🎉 Success Checklist

- [ ] Cloudflare Access application created
- [ ] Service token "Obsidian All Devices" created
- [ ] Token credentials saved securely
- [ ] Token added to CouchDB Access policy
- [ ] Personal Mac Obsidian configured and syncing
- [ ] iPhone Obsidian configured and syncing
- [ ] iPad Obsidian configured and syncing
- [ ] Work Mac Obsidian configured and syncing
- [ ] Cross-device sync tested and working
- [ ] Calendar reminder set for token rotation (3 months)

---

## 💡 Pro Tip

**Mobile devices (iPhone/iPad):**

Use Shortcuts app to save headers for easy reentry if needed:

1. Create a note with your credentials
2. Save in password manager
3. Can copy-paste easily when setting up new device

---

## 🔐 What If Token Is Compromised?

If you suspect the token is compromised:

1. **Revoke immediately:**
   ```
   Zero Trust → Access → Service Auth
   → Find "Obsidian All Devices" → Delete
   ```

2. **Create new token** with same process

3. **Update all 4 devices** with new credentials
   - Takes ~10 minutes total

4. **Devices are locked out until reconfigured**

This is the trade-off of shared token - if compromised, all devices need updating. But incidents are rare with proper token security.

---

## 📚 Additional Resources

- [Cloudflare Access Docs](https://developers.cloudflare.com/cloudflare-one/applications/)
- [Service Tokens Guide](https://developers.cloudflare.com/cloudflare-one/identity/service-tokens/)
- [Obsidian LiveSync Plugin](https://github.com/vrtmrz/obsidian-livesync)

---

**Ready to start? Follow this guide step by step and you'll be done in ~20 minutes!** 🚀
