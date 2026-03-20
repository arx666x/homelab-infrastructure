# SERI Network Architecture Guide

## Overview

SERI Homelab nutzt **Split-Horizon DNS** mit zwei getrennten VLANs für Management und Kubernetes.

---

## Network Topology

```
Internet
  ↓
FritzBox (ISP Router)
  ↓
Dream Machine Pro (UniFi)
  ├─ VLAN 11 (Management) - 192.168.11.0/24
  │   ├─ Clients (Laptops, Phones)
  │   ├─ Diskstation (192.168.11.55) - Pi-hole DNS
  │   └─ k3s Nodes Management IPs (.31-.33, .21-.25)
  │
  └─ VLAN 20 (Kubernetes) - 192.168.20.0/24
      ├─ k3s Nodes Kubernetes IPs (.31-.33, .21-.25)
      └─ MetalLB Pool (192.168.20.100-120)
          └─ Traefik LoadBalancer (192.168.20.100)
```

---

## DNS Architecture (Split-Horizon)

### External (Internet)

```
Client (Internet)
  ↓
Public DNS (Cloudflare)
  → *.reckeweg.io → Cloudflare Proxy IPs
  ↓
FritzBox (Port Forward 80/443)
  ↓
Dream Machine
  ↓
Traefik (192.168.20.100)
```

### Internal (LAN)

```
Client (LAN - 192.168.11.x)
  ↓
Pi-hole (192.168.11.55) - Local DNS
  → *.reckeweg.io → 192.168.20.100 (Local Override)
  ↓
Dream Machine (Inter-VLAN Routing)
  ↓
Traefik (192.168.20.100)
```

**Pi-hole Local DNS Records:**
- `longhorn.reckeweg.io` → `192.168.20.100`
- `grafana.reckeweg.io` → `192.168.20.100`
- `prometheus.reckeweg.io` → `192.168.20.100`
- `argocd.reckeweg.io` → `192.168.20.100`

---

## Inter-VLAN Routing

### How Clients reach Kubernetes Services

```
Client (192.168.11.141)
  ↓
1. DNS Query: argocd.reckeweg.io
   Pi-hole → 192.168.20.100
  ↓
2. HTTP Request to 192.168.20.100
   Dream Machine (Layer 3 Router)
   Routes: 192.168.11.0/24 ↔ 192.168.20.0/24
  ↓
3. Traefik LoadBalancer (192.168.20.100)
   Reads HTTP Host Header
   Routes to appropriate backend
  ↓
4. Backend Service (ArgoCD, Grafana, etc.)
```

### Dream Machine Configuration

**Settings → Networks:**
- VLAN 11: DHCP, DNS = 192.168.11.55 (Pi-hole)
- VLAN 20: DHCP disabled, Static IPs only
- **Inter-VLAN Routing:** Enabled (default)

**Firewall:**
- VLAN 11 → VLAN 20: **Allow**
- VLAN 20 → VLAN 11: **Allow** (for NFS backup)

---

## Layer 7 Routing (Traefik)

Traefik inspects **HTTP Host header** to route requests:

```yaml
# All domains point to same IP
DNS: *.reckeweg.io → 192.168.20.100

# Traefik routes by hostname
Ingress Rules:
  - host: argocd.reckeweg.io
    service: argocd-server:80
  
  - host: grafana.reckeweg.io
    service: kube-prometheus-stack-grafana:80
  
  - host: longhorn.reckeweg.io
    service: longhorn-frontend:80
```

**Request Flow:**
1. Client → `https://argocd.reckeweg.io`
2. DNS → `192.168.20.100`
3. TLS to Traefik
4. Traefik reads: `Host: argocd.reckeweg.io`
5. Matches Ingress rule
6. Forwards to `argocd-server` Pod

---

## TLS/Certificate Architecture

### Certificate Issuance

```
cert-manager
  ↓
DNS-01 Challenge (Cloudflare API)
  ↓
Let's Encrypt (ACME)
  ↓
Certificate Issued
  ↓
Stored as Kubernetes Secret
```

**Chain:**
```
ISRG Root X1 (Root CA - publicly trusted)
  ↓
R13 (Intermediate CA)
  ↓
*.reckeweg.io (End Certificate)
```

**This is a FULLY TRUSTED certificate chain!**
Not self-signed, not internal CA.

### TLS Termination

```
Client (HTTPS)
  ↓
Traefik (TLS Termination)
  ↓ HTTP (internal)
Backend (ArgoCD, Grafana - insecure mode)
```

**ArgoCD runs in `--insecure` mode:**
- Traefik: Handles TLS (HTTPS from clients)
- ArgoCD: Accepts HTTP (from Traefik)

---

## Why PING fails but HTTPS works

```bash
ping 192.168.20.100
# FAIL - Traefik doesn't respond to ICMP

curl https://argocd.reckeweg.io
# SUCCESS - Traefik responds to HTTP/HTTPS
```

**Traefik LoadBalancer:**
- Listens on: TCP 80, TCP 443
- Does NOT respond to: ICMP (ping)

This is **normal** and **correct**!

---

## Known Issue: Cloudflare ECH (Encrypted Client Hello)

### Symptom

After setting up cert-manager with valid Let's Encrypt certificates, services are accessible in **Safari on macOS** but fail in other browsers/devices:

| Client | Behavior |
|--------|----------|
| Safari (macOS) | ✅ Works |
| Chrome (macOS) | ❌ `ERR_ECH_FALLBACK_CERTIFICATE_INVALID` |
| Safari (iOS/iPadOS) | ❌ Blank/grey page after 10–20s timeout |

Crucially: `openssl s_client` and `curl` confirm the Let's Encrypt certificate is valid and correctly issued. The problem is **not** the certificate itself.

### Root Cause

Cloudflare automatically enables **ECH (Encrypted Client Hello)** for all proxied domains. ECH is a modern TLS extension that encrypts the SNI (Server Name Indication) field in the ClientHello, preventing passive observers from seeing which hostname a client is connecting to.

The conflict arises because:
1. Cloudflare advertises ECH support via `HTTPS` DNS records and publishes ECH keys
2. Chrome (since ~v117) and iOS/iPadOS (since iOS 18) actively attempt ECH
3. Traefik does **not** support ECH — it cannot decrypt the ECH-encrypted ClientHello
4. The ECH handshake fails and falls back to unencrypted SNI
5. Cloudflare's fallback validation then detects a certificate mismatch → connection aborted

Safari on macOS does not yet implement ECH, so it never attempts ECH and connects normally via standard TLS — which is why it works while Chrome and iOS fail.

### Solution: Disable ECH via Cloudflare API

The ECH setting is **not exposed in the Cloudflare Dashboard UI** (as of 2026). It must be disabled via the API.

**Step 1: Create an API Token**

Go to [https://dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens) → **Create Token** → Custom Token with these permissions:

| Permission | Value |
|------------|-------|
| Zone → Settings | Edit |
| Zone → Zone | Read |

> **Important:** The permission needed is **Zone → Settings → Edit**, NOT "Account: SSL and Certificates - Edit" — that is a different scope and will not work.

**Step 2: Find your Zone ID**

Your Zone ID is visible in the Cloudflare Dashboard on the Overview page for `reckeweg.io` (right sidebar). For this setup:
```
Zone ID: 9defaf36407ee5ce11a88802f4fac101
```

**Step 3: Check current ECH status**

```bash
curl "https://api.cloudflare.com/client/v4/zones/<ZONE_ID>/settings/ech" \
  -H "Authorization: Bearer <API_TOKEN>"
```

Expected response when enabled:
```json
{"result":{"id":"ech","value":"on","modified_on":null,"editable":true},"success":true}
```

**Step 4: Disable ECH**

```bash
curl -X PATCH "https://api.cloudflare.com/client/v4/zones/<ZONE_ID>/settings/ech" \
  -H "Authorization: Bearer <API_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"value": "off"}'
```

Expected response:
```json
{"result":{"id":"ech","value":"off","modified_on":null,"editable":true},"success":true}
```

**Step 5: Verify**

After disabling ECH, re-test in Chrome and on iOS/iPadOS. DNS changes propagate quickly since Cloudflare removes the ECH keys from the `HTTPS` DNS record immediately. A hard refresh (`Cmd+Shift+R`) or clearing the browser DNS cache may be needed.

### Why not just disable the Cloudflare Proxy?

Switching DNS records from "Proxied" (orange cloud) to "DNS only" (grey cloud) would also avoid ECH, but has tradeoffs:
- Your home IP address becomes publicly visible in DNS
- You lose Cloudflare's DDoS protection and caching
- Disabling ECH via API keeps the proxy active with all its benefits

For a homelab with a dynamic IP and no sensitive exposure, either approach is acceptable. Disabling ECH is the cleaner solution.

---

## Network Testing

### From Client (Mac)

```bash
# 1. DNS Resolution
nslookup argocd.reckeweg.io
# Should return: 192.168.20.100

# 2. Routing
traceroute 192.168.20.100
# Should show: Mac → Dream Machine → gmkt-01x

# 3. HTTP
curl -v https://argocd.reckeweg.io
# Should connect and return HTML

# 4. Ping (expected to fail)
ping 192.168.20.100
# Will fail - this is OK!

# 5. Verify certificate issuer
echo | openssl s_client -connect argocd.reckeweg.io:443 -servername argocd.reckeweg.io 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates
# Should show: issuer=C=US, O=Let's Encrypt, CN=R13
```

### From Kubernetes Node

```bash
ssh gmkt-01x

# Test internal service
curl http://argocd-server.argocd.svc.cluster.local

# Test Traefik LoadBalancer
curl -k https://192.168.20.100

# Test with hostname
curl -k -H "Host: argocd.reckeweg.io" https://192.168.20.100
```

---

## Services & Ports

| Service | Internal Port | Traefik Route | External URL |
|---------|---------------|---------------|--------------|
| ArgoCD | 80 (HTTP) | argocd.reckeweg.io | https://argocd.reckeweg.io |
| Grafana | 80 (HTTP) | grafana.reckeweg.io | https://grafana.reckeweg.io |
| Prometheus | 9090 (HTTP) | prometheus.reckeweg.io | https://prometheus.reckeweg.io |
| Longhorn | 80 (HTTP) | longhorn.reckeweg.io | https://longhorn.reckeweg.io |

**All services:**
- Run HTTP internally (insecure)
- Traefik provides TLS (HTTPS externally)
- Certificate from Let's Encrypt

---

## Troubleshooting

### Service not reachable from browser

1. **Check DNS:**
   ```bash
   nslookup <service>.reckeweg.io
   # Should return 192.168.20.100
   ```

2. **Check with curl:**
   ```bash
   curl -v https://<service>.reckeweg.io
   # If this works → Browser issue (see below)
   ```

3. **Check Ingress:**
   ```bash
   kubectl get ingress -A
   # Should show all services with PORT 80,443
   ```

4. **Check Certificate:**
   ```bash
   kubectl get certificate -A
   # All should be READY=True
   ```

5. **Chrome shows `ERR_ECH_FALLBACK_CERTIFICATE_INVALID` / iOS shows blank page:**
   → See **Known Issue: Cloudflare ECH** section above.
   → Quick check: does Safari on macOS work but Chrome/iOS not? → ECH is the cause.

### Inter-VLAN Routing issues

```bash
# From Mac - test route
traceroute 192.168.20.100

# Should show:
# 1. 192.168.11.1 (Dream Machine)
# 2. 192.168.20.31 (or other k3s node)

# If stops at Dream Machine:
# → Check UniFi Firewall Rules
# → Verify Inter-VLAN Routing enabled
```

### DNS not resolving locally

```bash
# Check Pi-hole
# Admin → Local DNS → DNS Records
# Verify: <service>.reckeweg.io → 192.168.20.100

# Test Pi-hole directly
nslookup argocd.reckeweg.io 192.168.11.55
```

---

## Summary

**Key Concepts:**
1. **Two VLANs:** Management (11) + Kubernetes (20)
2. **Split-Horizon DNS:** Internal IPs override public DNS
3. **Inter-VLAN Routing:** Dream Machine routes between VLANs
4. **Layer 7 Routing:** Traefik inspects HTTP Host header
5. **TLS Termination:** Traefik handles HTTPS, backends use HTTP
6. **Valid Certificates:** Let's Encrypt via DNS-01 (fully trusted)
7. **ECH disabled on Cloudflare:** Required for Chrome and iOS compatibility (Traefik does not support ECH)

**All traffic stays internal** when accessing from LAN - never hits internet!
