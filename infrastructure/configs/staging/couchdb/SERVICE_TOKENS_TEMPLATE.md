# CouchDB Service Tokens - Secure Storage Template

**IMPORTANT:** Store this in your password manager (1Password, Bitwarden, etc.) or encrypted notes.

**DO NOT commit this file with real credentials to Git!**

---

## Service Token 1: iPhone

```
Token Name: Obsidian - iPhone
Created: [Date]
Last Rotated: [Date]

Client ID:
[Paste iPhone Client ID here]

Client Secret:
[Paste iPhone Client Secret here]

Status: Active
Notes: Used on iPhone 15 Pro
```

---

## Service Token 2: iPad

```
Token Name: Obsidian - iPad
Created: [Date]
Last Rotated: [Date]

Client ID:
[Paste iPad Client ID here]

Client Secret:
[Paste iPad Client Secret here]

Status: Active
Notes: Used on iPad Pro
```

---

## Service Token 3: Personal Mac

```
Token Name: Obsidian - Personal Mac
Created: [Date]
Last Rotated: [Date]

Client ID:
[Paste Personal Mac Client ID here]

Client Secret:
[Paste Personal Mac Client Secret here]

Status: Active
Notes: Used on personal MacBook
```

---

## Service Token 4: Work Mac

```
Token Name: Obsidian - Work Mac
Created: [Date]
Last Rotated: [Date]

Client ID:
[Paste Work Mac Client ID here]

Client Secret:
[Paste Work Mac Client Secret here]

Status: Active
Notes: Used on work MacBook Pro
```

---

## Quick Copy Format for Obsidian Configuration

### iPhone
```
CF-Access-Client-Id: [iPhone Client ID]
CF-Access-Client-Secret: [iPhone Client Secret]
```

### iPad
```
CF-Access-Client-Id: [iPad Client ID]
CF-Access-Client-Secret: [iPad Client Secret]
```

### Personal Mac
```
CF-Access-Client-Id: [Personal Mac Client ID]
CF-Access-Client-Secret: [Personal Mac Client Secret]
```

### Work Mac
```
CF-Access-Client-Id: [Work Mac Client ID]
CF-Access-Client-Secret: [Work Mac Client Secret]
```

---

## Token Management

**Where to manage tokens:**
```
https://one.dash.cloudflare.com/
→ Zero Trust → Access → Service Auth
```

**Rotation Schedule:**
- Next rotation due: [Date + 3 months]
- Rotation frequency: Quarterly (every 3 months)

**Revocation Log:**
```
Date       | Token         | Reason
-----------|---------------|------------------
[Date]     | [Token name]  | [Reason]
```

---

## Emergency Response

**If a device is lost or stolen:**

1. Immediately revoke the token:
   - Go to Cloudflare Zero Trust
   - Access → Service Auth
   - Find the token → Delete

2. Check access logs for suspicious activity:
   - Zero Trust → Logs → Access requests
   - Filter by the compromised token

3. Other devices continue working normally

**If all tokens need emergency revocation:**

1. Revoke all 4 tokens in Cloudflare
2. CouchDB will reject all Obsidian requests
3. Create new tokens when ready
4. Reconfigure all devices with new tokens
