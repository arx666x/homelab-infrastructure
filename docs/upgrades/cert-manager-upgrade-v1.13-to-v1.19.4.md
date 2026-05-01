# cert-manager Upgrade Runbook: v1.13.3 → v1.19.4

**Datum:** 2026-05-01  
**Autor:** Achim Reckeweg  
**Cluster:** reckeweg.io homelab k3s  
**Namespace:** `cert-manager`  
**Install-Methode:** ArgoCD GitOps (Helm Chart via `charts.jetstack.io`)  
**Zielversion:** v1.19.4  

---

## Übersicht

| | |
|---|---|
| **Aktuelle Version** | v1.13.3 |
| **Zielversion** | v1.19.4 |
| **Upgrade-Strategie** | Git-Commit → ArgoCD Auto-Sync |
| **ArgoCD Application** | `argocd/cert-manager` |
| **ClusterIssuer** | `letsencrypt-prod` (Cloudflare DNS-01), `selfsigned-issuer`, `ca-issuer` |
| **Downtime** | Kurze Unterbrechung der Zertifikatserneuerung während Rollout (~1–2 min) |

> **Hinweis zur Installationshistorie:**  
> cert-manager wurde initial via `deploy-direct.sh` (kubectl apply) gebootstrapt.  
> ArgoCD hat die Installation danach übernommen und managed sie seitdem als Helm-Release.  
> `deploy-direct.sh` dient ausschließlich als Disaster-Recovery-Bootstrap — ArgoCD  
> (`selfHeal: true`) würde manuelle `kubectl apply`-Eingriffe sofort überschreiben.

### Warum v1.19.4?

- **CVE-2026-24051** – Go v1.25.7
- **CVE-2025-68121** – Go v1.25.7
- **GO-2026-4394** – OpenTelemetry SDK v1.40.0
- Moderate DoS-Fix im Controller (GHSA-gx3x-vq4p-mhhv)

---

## Wichtige Breaking Changes je Minor-Version

### 1.15
- CRDs werden bei Deinstallation **nicht mehr gelöscht** (Schutzfunktion). Positiver Nebeneffekt für ArgoCD-managed Installs.

### 1.17
- RSA-Hashing: ab 3072-bit-Keys automatisch SHA-384, ab 4096-bit SHA-512. Die interne Root-CA (`seri-root-ca`, RSA 4096) wird beim nächsten Renewal mit SHA-512 neu ausgestellt — das ist gewollt und korrekt.

### 1.18
- ACME HTTP-01 Ingress `pathType` von `ImplementationSpecific` auf `Exact` geändert. **Nicht relevant** — Traefik + DNS-01 (Cloudflare).

### 1.19
- **ACHTUNG:** v1.19.0 hat einen Bug der unnötige Certificate-Renewals auslöst — direkt auf v1.19.4, niemals auf .0 stoppen. ArgoCD `targetRevision: v1.19.4` stellt das sicher.
- **Breaking (Metrics):** Prometheus-Label `path` entfernt aus `certmanager_acme_client_request_count` und `certmanager_acme_client_request_duration_seconds`, ersetzt durch `action`. Grafana-Dashboards und Alerting-Regeln prüfen.

---

## Vorbereitung

### Aktuelle Version und ArgoCD-Status prüfen

```bash
kubectl -n cert-manager get deployment cert-manager \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Erwartet: quay.io/jetstack/cert-manager-controller:v1.13.3

kubectl -n argocd get application cert-manager
# STATUS sollte: Synced / Healthy sein
```

### Backup aller cert-manager Ressourcen

```bash
kubectl get -o yaml \
  clusterissuers,issuers,certificates,certificaterequests,orders,challenges \
  --all-namespaces > cert-manager-backup-$(date +%Y%m%d).yaml

wc -l cert-manager-backup-$(date +%Y%m%d).yaml
```

---

## Upgrade: Ein Git-Commit

Da ArgoCD `automated` mit `selfHeal: true` konfiguriert ist, reicht eine einzige Änderung in Git.

### 1. targetRevision aktualisieren

```bash
# In gitops/apps/cert-manager.yaml
# targetRevision: v1.13.3  →  targetRevision: v1.19.4

# macOS-kompatibel:
sed -i '' 's/targetRevision: v1.13.3/targetRevision: v1.19.4/' gitops/apps/cert-manager.yaml

# Änderung prüfen:
grep targetRevision gitops/apps/cert-manager.yaml
```

### 2. Commit und Push

```bash
git add gitops/apps/cert-manager.yaml
git commit -m "chore: upgrade cert-manager v1.13.3 → v1.19.4 (CVE-2026-24051, CVE-2025-68121)"
git push
```

### 3. ArgoCD Sync beobachten

ArgoCD erkennt die Änderung und startet den Helm-Upgrade automatisch (Auto-Sync).
Optional manuell triggern falls nicht innerhalb von ~3 Minuten:

```bash
# Manueller Sync (optional)
argocd app sync cert-manager

# Sync-Status beobachten
kubectl -n argocd get application cert-manager -w

# Oder über ArgoCD CLI
argocd app get cert-manager
```

---

## Post-Upgrade-Validierung

### Image-Version bestätigen

```bash
kubectl -n cert-manager get deployment cert-manager \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Erwartet: quay.io/jetstack/cert-manager-controller:v1.19.4

kubectl -n cert-manager get deployment cert-manager-webhook \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Erwartet: quay.io/jetstack/cert-manager-webhook:v1.19.4
```

### Alle Pods Running

```bash
kubectl -n cert-manager get pods
# Alle 3 Pods: 1/1 Running
```

### ArgoCD Application Synced/Healthy

```bash
kubectl -n argocd get application cert-manager
# SYNC STATUS: Synced
# HEALTH STATUS: Healthy
```

### ClusterIssuers bereit

```bash
kubectl get clusterissuers -o wide
# letsencrypt-prod:  READY = True
# selfsigned-issuer: READY = True
# ca-issuer:         READY = True
```

### Zertifikatsstatus aller Namespaces

```bash
kubectl get certificates --all-namespaces \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[0].status,REASON:.status.conditions[0].reason,EXPIRY:.status.notAfter'
# Alle READY = True
```

### Auf fehlerhafte CertificateRequests prüfen

```bash
kubectl get certificaterequests --all-namespaces | grep -v "Approved\|NAME"
# Leer = alles in Ordnung
```

### Controller-Logs auf Fehler prüfen

```bash
kubectl -n cert-manager logs deployment/cert-manager --since=15m | grep -iE "error|failed|panic"
kubectl -n cert-manager logs deployment/cert-manager-webhook --since=15m | grep -iE "error|failed|panic"
```

### Grafana: Metrics-Label prüfen

Das Label `path` wurde in cert-manager 1.19 aus den ACME-Metrics entfernt und durch `action` ersetzt.
In Grafana folgende Queries prüfen und ggf. anpassen:

- `certmanager_acme_client_request_count` — Label `path` → `action`
- `certmanager_acme_client_request_duration_seconds` — Label `path` → `action`

---

## deploy-direct.sh aktualisieren

Das Script dient als Disaster-Recovery-Bootstrap. Version ebenfalls aktualisieren
damit Bootstrap und ArgoCD-Zielzustand konsistent bleiben:

```bash
sed -i '' 's|cert-manager/releases/download/v1.13.3|cert-manager/releases/download/v1.19.4|' deploy-direct.sh

# Prüfen:
grep cert-manager deploy-direct.sh | grep download
```

> **Wichtig:** Das Script deployed cert-manager initial via `kubectl apply` (Static Manifests).
> Das ist für den Bootstrap-Fall korrekt und intentional — ArgoCD übernimmt danach
> automatisch die Verwaltung als Helm-Release und bringt den Cluster in den GitOps-Zielzustand.
> Ein manueller `kubectl apply`-Eingriff im laufenden Betrieb würde von ArgoCD (`selfHeal: true`)
> innerhalb weniger Minuten überschrieben.

---

## Rollback

Falls nach dem Upgrade Probleme auftreten:

```bash
# In gitops/apps/cert-manager.yaml zurücksetzen
sed -i '' 's/targetRevision: v1.19.4/targetRevision: v1.13.3/' gitops/apps/cert-manager.yaml

git add gitops/apps/cert-manager.yaml
git commit -m "revert: cert-manager zurück auf v1.13.3"
git push
```

ArgoCD syncronisiert automatisch auf die vorherige Version zurück.

---

## Referenzen

- [cert-manager Release Notes 1.19](https://cert-manager.io/docs/releases/release-notes/release-notes-1.19/)
- [cert-manager Upgrade Guide](https://cert-manager.io/docs/installation/upgrade/)
- [cert-manager GitHub Releases](https://github.com/cert-manager/cert-manager/releases)
- [CVE-2025-68121](https://www.cve.org/CVERecord?id=CVE-2025-68121)
- [CVE-2026-24051](https://www.cve.org/CVERecord?id=CVE-2026-24051)
