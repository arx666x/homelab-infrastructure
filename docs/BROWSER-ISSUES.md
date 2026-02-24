# Browser Compatibility Issues - SERI Homelab

## TL;DR

**Use Safari for Homelab dashboards** - it works perfectly! ✅

Chrome has aggressive experimental network features that conflict with split-horizon DNS.

---

## The Problem

**Symptoms:**
- `curl https://argocd.reckeweg.io` → ✅ Works
- Safari → ✅ Works  
- Chrome → ❌ `ERR_ECH_FALLBACK_CERTIFICATE_INVALID`
- Chrome → ❌ `ERR_QUIC_PROTOCOL_ERROR`

**Root Cause:** Chrome's experimental privacy/performance features conflict with:
- Split-horizon DNS (internal IPs override public DNS)
- Valid Let's Encrypt certificates served from non-public IPs

---

## Why This Happens

### It's NOT a Certificate Problem!

**Certificate Chain is VALID:**
```
ISRG Root X1 (Root CA - publicly trusted)
  ↓
R13 (Intermediate CA - Let's Encrypt)
  ↓
argocd.reckeweg.io (End Certificate)
```

This is a **fully trusted certificate chain** - same as any public website!

### The Split-Horizon DNS Issue

**What Chrome does:**

1. **Local DNS Query:** `argocd.reckeweg.io`
   - Pi-hole responds: `192.168.20.100` (internal IP)

2. **Connect to internal IP:** `192.168.20.100`
   - Receives valid Let's Encrypt certificate

3. **ECH/DoH Validation:**
   - Chrome uses **DNS over HTTPS** (bypassing Pi-hole)
   - Queries **Cloudflare DNS** (public)
   - Gets: `argocd.reckeweg.io` → Cloudflare IPs (104.x.x.x, 172.x.x.x)

4. **Mismatch Detection:**
   - Certificate says: `argocd.reckeweg.io`
   - Public DNS says: Cloudflare IPs
   - Connected to: `192.168.20.100`
   - Chrome: "IP doesn't match public DNS!" → **ERROR**

**This is Chrome being "too smart" for split-horizon DNS!**

---

## Chrome Problematic Features

### 1. ECH (Encrypted Client Hello)

**What it does:** Encrypts SNI (Server Name Indication) for privacy

**Why it breaks:** Validates certificate against **public DNS**, ignoring local DNS overrides

**Status:** Enabled by default in Chrome 131+, cannot be disabled via flags

### 2. QUIC / HTTP/3

**What it does:** Uses UDP instead of TCP for faster connections

**Why it breaks:** Traefik's QUIC support is incomplete, causes protocol errors

**Error:** `ERR_QUIC_PROTOCOL_ERROR`

### 3. DNS over HTTPS (DoH)

**What it does:** Encrypts DNS queries via HTTPS to Cloudflare/Google

**Why it breaks:** Bypasses Pi-hole's local DNS overrides

**Default:** Enabled ("Use secure DNS")

---

## Solutions

### Option 1: Use Safari (Recommended) ✅

**Safari works perfectly because:**
- No ECH support yet
- Conservative QUIC implementation
- Respects system DNS (Pi-hole)

**Setup:**
1. Use Safari for all homelab dashboards
2. Chrome for internet browsing

**No configuration needed!**

---

### Option 2: Disable Chrome Features

**Warning:** Settings may reset after Chrome updates!

#### Step 1: Disable Secure DNS (DoH)

```
chrome://settings/security
→ "Use secure DNS" → OFF
→ Restart Chrome
```

#### Step 2: Disable QUIC

```
chrome://flags/#enable-quic
→ "Experimental QUIC protocol" → Disabled
→ Relaunch Chrome
```

#### Step 3: Reset All Flags (if needed)

```
chrome://flags/
→ "Reset all" button (top right)
→ Relaunch Chrome
```

**After Chrome updates:** You may need to repeat these steps!

---

### Option 3: Chrome Site Settings

For each domain individually:

1. Visit `https://argocd.reckeweg.io` (will error)
2. Click **padlock icon** in address bar
3. Click **"Site settings"**
4. Under **"Insecure content"** → **Allow**
5. Reload page

**Repeat for:**
- grafana.reckeweg.io
- prometheus.reckeweg.io
- longhorn.reckeweg.io

---

### Option 4: Launch Chrome with Flags

**macOS:**
```bash
open -a "Google Chrome" --args \
  --disable-features=EncryptedClientHello,UseDnsHttpsSvcb \
  --ignore-certificate-errors
```

**Linux:**
```bash
google-chrome \
  --disable-features=EncryptedClientHello,UseDnsHttpsSvcb \
  --ignore-certificate-errors
```

**Create an app/shortcut** for this command for convenience.

---

### Option 5: Use Firefox

Firefox works better than Chrome for homelab:

1. **Download Firefox**
2. **Disable DoH:**
   ```
   about:preferences#general
   → Network Settings
   → "Enable DNS over HTTPS" → OFF
   ```

Firefox is more conservative with experimental features.

---

## Browser Compatibility Matrix

| Browser | Works? | Configuration Needed |
|---------|--------|---------------------|
| Safari | ✅ Yes | None |
| Firefox | ✅ Yes | Disable DoH |
| Chrome | ⚠️ Partial | Disable DoH + QUIC |
| Edge | ⚠️ Partial | Same as Chrome (Chromium-based) |
| Brave | ⚠️ Partial | Same as Chrome (Chromium-based) |

---

## Testing & Verification

### Verify It's a Browser Issue

```bash
# 1. Test with curl (always works)
curl -v https://argocd.reckeweg.io

# Should show:
# - Connected to 192.168.20.100
# - SSL certificate verify ok
# - HTTP/2 200

# 2. Test with Safari
# Open Safari → https://argocd.reckeweg.io
# Should load perfectly

# If both work → It's Chrome's experimental features
```

### Check DNS Resolution

```bash
# What IP does your browser get?
nslookup argocd.reckeweg.io

# Should return: 192.168.20.100
# Not: Cloudflare IPs (104.x, 172.x)
```

### Chrome DevTools Inspection

1. Open DevTools: `Cmd+Option+I`
2. **Network Tab**
3. Try loading `https://argocd.reckeweg.io`
4. Look for:
   - `ERR_QUIC_PROTOCOL_ERROR` → Disable QUIC
   - `ERR_ECH_FALLBACK_CERTIFICATE_INVALID` → Chrome ECH issue
   - `net::ERR_CERT_AUTHORITY_INVALID` → Different problem (check certificates)

---

## Why This Doesn't Affect Public Websites

**Public websites don't use split-horizon DNS:**

```
Public Site (example.com):
- Public DNS: example.com → 1.2.3.4
- You connect to: 1.2.3.4
- Certificate for: example.com
- Everything matches! ✅

Homelab (argocd.reckeweg.io):
- Pi-hole (local): argocd.reckeweg.io → 192.168.20.100
- Public DNS: argocd.reckeweg.io → Cloudflare IPs
- You connect to: 192.168.20.100
- Chrome validates against: Public DNS
- Mismatch! ❌
```

Chrome's ECH assumes **DNS and IP always match globally** - which isn't true for split-horizon!

---

## Future-Proofing

### When Chrome Updates

Chrome updates **may re-enable** experimental features. After updates:

1. Check if homelab dashboards still work
2. If not, repeat "Disable Chrome Features" steps
3. Or switch to Safari permanently

### Alternative: External Access Only

If Chrome issues persist, configure:

1. **Internal:** Use Safari/Firefox
2. **External:** Set up proper external access
   - FritzBox port forwarding
   - Public IPs in public DNS
   - Chrome will work externally (no split-horizon)

---

## Recommended Setup

**For daily use:**

```
Safari/Firefox → Internal homelab dashboards
  ↓
  - argocd.reckeweg.io
  - grafana.reckeweg.io
  - prometheus.reckeweg.io
  - longhorn.reckeweg.io

Chrome → Everything else (internet browsing)
```

**Benefits:**
- No configuration needed
- Survives browser updates
- No experimental features to fight

---

## Support & Troubleshooting

### Still having issues?

1. **Verify DNS:**
   ```bash
   nslookup argocd.reckeweg.io
   # Must return: 192.168.20.100
   ```

2. **Test with curl:**
   ```bash
   curl -v https://argocd.reckeweg.io
   # Must succeed
   ```

3. **Try Safari:**
   - If Safari works → Browser issue
   - If Safari fails → DNS/Network issue

4. **Check Pi-hole:**
   - Admin → Local DNS
   - Verify records exist

### Error Reference

| Error | Cause | Fix |
|-------|-------|-----|
| `ERR_QUIC_PROTOCOL_ERROR` | QUIC enabled | Disable QUIC flag |
| `ERR_ECH_FALLBACK_CERTIFICATE_INVALID` | ECH + Split-horizon | Use Safari |
| `ERR_NAME_NOT_RESOLVED` | DNS issue | Check Pi-hole |
| `ERR_CONNECTION_REFUSED` | Service down | Check pods |
| `ERR_CERT_AUTHORITY_INVALID` | Certificate issue | Check cert-manager |

---

## Summary

**The Real Problem:** Chrome's ECH validates certificates against **public DNS**, incompatible with split-horizon DNS setups.

**The Real Solution:** Use Safari (or Firefox) for internal dashboards.

**Your certificates are valid!** This is NOT a security issue - it's Chrome being incompatible with standard enterprise networking practices (split-horizon DNS).

---

**Last Updated:** February 24, 2026  
**Chrome Version Tested:** 131+  
**Status:** Safari recommended ✅
