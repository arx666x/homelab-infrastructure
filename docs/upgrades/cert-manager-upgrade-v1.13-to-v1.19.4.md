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
| **Upgrade-Strategie** | Minor-by-Minor via Git-Commit → ArgoCD Auto-Sync |
| **ArgoCD Application** | `argocd/cert-manager` |
| **ClusterIssuers** | `letsencrypt-prod` (Cloudflare DNS-01), `selfsigned-issuer`, `ca-issuer` |
| **Downtime** | Kurze Unterbrechung der Zertifikatserneuerung pro Schritt (~1–2 min) |

> **Hinweis zur Installationshistorie:**  
> cert-manager wurde initial via `deploy-direct.sh` (kubectl apply, Static Manifests) gebootstrapt.  
> ArgoCD managed die Installation seitdem als Helm-Release (`charts.jetstack.io`).  
> `deploy-direct.sh` dient ausschließlich als Disaster-Recovery-Bootstrap —  
> ArgoCD (`selfHeal: true`) überschreibt manuelle `kubectl`-Eingriffe im laufenden Betrieb.

> **Warum Minor-by-Minor?**  
> cert-manager empfiehlt ausdrücklich, immer einen Minor-Schritt auf einmal zu upgraden —  
> unabhängig von der Install-Methode (Static Manifests oder Helm/ArgoCD).  
> CRD-Migrationen und Breaking Changes zwischen Minor-Versionen können sonst  
> zu inkonsistenten Zuständen führen.

### Warum v1.19.4?

- **CVE-2026-24051** – Go v1.25.7
- **CVE-2025-68121** – Go v1.25.7
- **GO-2026-4394** – OpenTelemetry SDK v1.40.0
- Moderate DoS-Fix im Controller (GHSA-gx3x-vq4p-mhhv)

---

## Upgrade-Pfad

```
v1.13.3 → v1.14.7 → v1.15.5 → v1.16.5 → v1.17.4 → v1.18.6 → v1.19.4
```

Jeder Schritt = ein Git-Commit + ArgoCD-Sync + Validierung.

---

## Wichtige Breaking Changes je Minor-Version

### 1.14
- Keine Breaking Changes für diese Installation.

### 1.15
- CRDs werden bei Deinstallation nicht mehr gelöscht (Schutzfunktion). Positiv für ArgoCD-managed Installs.

### 1.16
- Helm Schema Validation eingeführt — ungültige Helm Values werden rejected. Die aktuellen Values (`installCRDs: true`) sind valide, kein Handlungsbedarf.

### 1.17
- RSA-Hashing: ab 3072-bit automatisch SHA-384, ab 4096-bit SHA-512. Die interne Root-CA (`seri-root-ca`, RSA 4096) wird beim nächsten Renewal mit SHA-512 neu ausgestellt — gewollt und korrekt.

### 1.18
- ACME HTTP-01 Ingress `pathType` → `Exact`. **Nicht relevant** — Traefik + DNS-01 (Cloudflare).

### 1.19
- **ACHTUNG:** v1.19.0 hat einen Bug der unnötige Certificate-Renewals auslöst — immer direkt auf den letzten Patch (v1.19.4), niemals auf .0 stoppen.
- **Breaking (Metrics):** Prometheus-Label `path` entfernt aus `certmanager_acme_client_request_count` und `certmanager_acme_client_request_duration_seconds`, ersetzt durch `action`. Grafana-Dashboards nach Schritt 6 prüfen.

---

## Vorbereitung

### Aktuellen Zustand prüfen

```bash
kubectl -n cert-manager get deployment cert-manager \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Erwartet: quay.io/jetstack/cert-manager-controller:v1.13.3

kubectl -n argocd get application cert-manager
# Erwartet: Synced / Healthy
```

### Backup

```bash
kubectl get -o yaml \
  clusterissuers,issuers,certificates,certificaterequests,orders,challenges \
  --all-namespaces > cert-manager-backup-$(date +%Y%m%d).yaml

wc -l cert-manager-backup-$(date +%Y%m%d).yaml

# Cloudflare Secret sichern
kubectl -n cert-manager get secret cloudflare-api-token -o yaml > cloudflare-api-token-backup.yaml
```

---

## Hilfsfunktionen

```bash
# Warten bis ArgoCD Synced + Healthy
wait_argocd() {
  local VERSION=$1
  echo "==> Warte auf ArgoCD Sync für cert-manager ${VERSION}..."
  kubectl -n argocd wait application cert-manager \
    --for=jsonpath='{.status.sync.status}'=Synced --timeout=5m
  kubectl -n argocd wait application cert-manager \
    --for=jsonpath='{.status.health.status}'=Healthy --timeout=5m
  echo "==> ArgoCD: Synced + Healthy"
}

# Pods und ClusterIssuers prüfen
validate() {
  echo "--- Pods ---"
  kubectl -n cert-manager get pods
  echo "--- Image ---"
  kubectl -n cert-manager get deployment cert-manager \
    -o jsonpath='{.spec.template.spec.containers[0].image}'
  echo ""
  echo "--- ClusterIssuers ---"
  kubectl get clusterissuers -o wide
  echo "--- Certificates ---"
  kubectl get certificates --all-namespaces \
    -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[0].status,EXPIRY:.status.notAfter'
}
```

---

## Schritt 1: v1.13.3 → v1.14.7

```bash
sed -i '' 's/targetRevision: v1.13.3/targetRevision: v1.14.7/' gitops/apps/cert-manager.yaml
grep targetRevision gitops/apps/cert-manager.yaml

git add gitops/apps/cert-manager.yaml
git commit -m "chore: upgrade cert-manager v1.13.3 → v1.14.7"
git push

wait_argocd v1.14.7
validate
```

---

## Schritt 2: v1.14.7 → v1.15.5

```bash
sed -i '' 's/targetRevision: v1.14.7/targetRevision: v1.15.5/' gitops/apps/cert-manager.yaml
grep targetRevision gitops/apps/cert-manager.yaml

git add gitops/apps/cert-manager.yaml
git commit -m "chore: upgrade cert-manager v1.14.7 → v1.15.5"
git push

wait_argocd v1.15.5
validate
```

---

## Schritt 3: v1.15.5 → v1.16.5

```bash
sed -i '' 's/targetRevision: v1.15.5/targetRevision: v1.16.5/' gitops/apps/cert-manager.yaml
grep targetRevision gitops/apps/cert-manager.yaml

git add gitops/apps/cert-manager.yaml
git commit -m "chore: upgrade cert-manager v1.15.5 → v1.16.5"
git push

wait_argocd v1.16.5
validate
```

---

## Schritt 4: v1.16.5 → v1.17.4

```bash
sed -i '' 's/targetRevision: v1.16.5/targetRevision: v1.17.4/' gitops/apps/cert-manager.yaml
grep targetRevision gitops/apps/cert-manager.yaml

git add gitops/apps/cert-manager.yaml
git commit -m "chore: upgrade cert-manager v1.16.5 → v1.17.4"
git push

wait_argocd v1.17.4
validate
```

---

## Schritt 5: v1.17.4 → v1.18.6

```bash
sed -i '' 's/targetRevision: v1.17.4/targetRevision: v1.18.6/' gitops/apps/cert-manager.yaml
grep targetRevision gitops/apps/cert-manager.yaml

git add gitops/apps/cert-manager.yaml
git commit -m "chore: upgrade cert-manager v1.17.4 → v1.18.6"
git push

wait_argocd v1.18.6
validate
```

---

## Schritt 6: v1.18.6 → v1.19.4 (Ziel)

```bash
sed -i '' 's/targetRevision: v1.18.6/targetRevision: v1.19.4/' gitops/apps/cert-manager.yaml
grep targetRevision gitops/apps/cert-manager.yaml

git add gitops/apps/cert-manager.yaml
git commit -m "chore: upgrade cert-manager v1.18.6 → v1.19.4 (CVE-2026-24051, CVE-2025-68121)"
git push

wait_argocd v1.19.4
validate
```

---

## Post-Upgrade-Validierung (nach Schritt 6)

### Image-Version bestätigen

```bash
kubectl -n cert-manager get deployment cert-manager \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Erwartet: quay.io/jetstack/cert-manager-controller:v1.19.4

kubectl -n cert-manager get deployment cert-manager-webhook \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Erwartet: quay.io/jetstack/cert-manager-webhook:v1.19.4
```

### ArgoCD Application final prüfen

```bash
kubectl -n argocd get application cert-manager
# SYNC STATUS:   Synced
# HEALTH STATUS: Healthy
```

### Alle ClusterIssuers Ready

```bash
kubectl get clusterissuers -o wide
# letsencrypt-prod:  READY = True
# selfsigned-issuer: READY = True
# ca-issuer:         READY = True
```

### Fehlerhafte CertificateRequests prüfen

```bash
kubectl get certificaterequests --all-namespaces | grep -v "Approved\|NAME"
# Leer = alles in Ordnung
```

### Controller-Logs

```bash
kubectl -n cert-manager logs deployment/cert-manager --since=15m | grep -iE "error|failed|panic"
kubectl -n cert-manager logs deployment/cert-manager-webhook --since=15m | grep -iE "error|failed|panic"
```

### Grafana: Metrics-Label prüfen

Label `path` wurde durch `action` ersetzt. Folgende Queries in Grafana prüfen:

- `certmanager_acme_client_request_count` — Label `path` → `action`
- `certmanager_acme_client_request_duration_seconds` — Label `path` → `action`

---

## deploy-direct.sh aktualisieren

Nach erfolgreichem Upgrade die Bootstrap-Version konsistent halten:

```bash
sed -i '' 's|cert-manager/releases/download/v1.13.3|cert-manager/releases/download/v1.19.4|' deploy-direct.sh
grep "releases/download" deploy-direct.sh
```

> **Hinweis:** `deploy-direct.sh` deployed cert-manager als Bootstrap via Static Manifests.  
> ArgoCD übernimmt nach dem ersten Sync die Verwaltung als Helm-Release.  
> Die Version im Script und `gitops/apps/cert-manager.yaml` sollten immer übereinstimmen.

---

## Rollback

Im Fehlerfall auf die letzte funktionierende Version zurückkehren — Beispiel Rollback von Schritt 3:

```bash
sed -i '' 's/targetRevision: v1.16.5/targetRevision: v1.15.5/' gitops/apps/cert-manager.yaml

git add gitops/apps/cert-manager.yaml
git commit -m "revert: cert-manager zurück auf v1.15.5"
git push
```

ArgoCD syncronisiert automatisch auf die vorherige Version zurück.

---

## Referenzen

- [cert-manager Upgrade Guide](https://cert-manager.io/docs/installation/upgrade/)
- [cert-manager Release Notes 1.19](https://cert-manager.io/docs/releases/release-notes/release-notes-1.19/)
- [cert-manager GitHub Releases](https://github.com/cert-manager/cert-manager/releases)
- [CVE-2025-68121](https://www.cve.org/CVERecord?id=CVE-2025-68121)
- [CVE-2026-24051](https://www.cve.org/CVERecord?id=CVE-2026-24051)
