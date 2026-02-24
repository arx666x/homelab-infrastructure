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
   # If this works → Browser issue (see BROWSER-ISSUES.md)
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

**All traffic stays internal** when accessing from LAN - never hits internet!
