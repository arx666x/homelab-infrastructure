# cert-manager Upgrade Runbook: v1.13.x → v1.19.4

**Datum:** 2026-05-01  
**Autor:** Achim Reckeweg  
**Cluster:** reckeweg.io homelab k3s  
**Komponente:** cert-manager (Helm, Namespace `cert-manager`)  
**Zielversion:** v1.19.4  

---

## Übersicht

| | |
|---|---|
| **Aktuelle Version** | v1.13.x |
| **Zielversion** | v1.19.4 |
| **Upgrade-Strategie** | Minor-by-Minor (1.13 → 1.14 → 1.15 → 1.16 → 1.17 → 1.18 → 1.19.4) |
| **Helm OCI Registry** | `oci://quay.io/jetstack/charts/cert-manager` |
| **Downtime** | Kurze Unterbrechung der Zertifikatserneuerung während Rollout (~1–2 min) |

### Warum v1.19.4?

- **CVE-2026-24051** – Go-Vulnerability (behoben in Go v1.25.7)
- **CVE-2025-68121** – Go-Vulnerability (behoben in Go v1.25.7)
- **GO-2026-4394** – OpenTelemetry SDK Vulnerability (otel SDK auf v1.40.0)
- Moderate-Severity DoS-Fix im cert-manager Controller (GHSA-gx3x-vq4p-mhhv)

---

## Wichtige Breaking Changes je Minor-Version

### 1.14
- Keine breaking changes für Standardinstallationen.

### 1.15
- **CRDs werden bei `helm uninstall` nicht mehr gelöscht** (Schutzfunktion). Ab dieser Version ist kein explizites CRD-Backup mehr zwingend nötig, aber weiterhin empfohlen.
- `AdditionalCertificateOutputFormats` Feature Gate promoted zu GA.

### 1.16
- Keine breaking changes für Standardinstallationen.

### 1.17
- **Neues LTS-Release** (ersetzt 1.12 LTS).
- RSA-Hashing: Ab 3072-bit-Keys wird automatisch SHA-384 statt SHA-256 verwendet; ab 4096-bit SHA-512. Bestehende Zertifikate werden beim nächsten Renewal automatisch aktualisiert.

### 1.18
- **ACME HTTP-01 Ingress pathType** wurde von `ImplementationSpecific` auf `Exact` geändert. Relevant nur, wenn ingress-nginx `< v1.12.6` oder `< v1.13.2` verwendet wird (homelab: prüfen).
- `ValidateCAA` Feature Gate entfernt (war deprecated, war kein Problem wenn nicht gesetzt).

### 1.19
- **ACHTUNG:** v1.19.0 enthält einen Bug, der unnötige Certificate-Renewals auslöst. → Direkt auf **v1.19.4** upgraden, niemals auf v1.19.0 stoppen.
- CRD-based API defaults für `Certificate.Spec.IssuerRef` und `CertificateRequest.Spec.IssuerRef` wurden in 1.19.0 eingeführt und in 1.19.1 wieder zurückgenommen (unnötige Renewals). In v1.19.4 ist dies stabil.
- **Breaking (Metrics):** Label `path` aus `certmanager_acme_client_request_count` und `certmanager_acme_client_request_duration_seconds` entfernt, ersetzt durch `action`. → Grafana-Dashboards und Alerting-Regeln prüfen/anpassen.

---

## Voraussetzungen

```bash
# Kontext prüfen
kubectl config current-context
kubectl cluster-info

# Aktuelle Version prüfen
helm list -n cert-manager
kubectl -n cert-manager get pods
```

---

## Phase 1: Backup

```bash
# Alle cert-manager CRs sichern
kubectl get -o yaml \
  clusterissuers,issuers,certificates,certificaterequests,orders,challenges \
  --all-namespaces > cert-manager-backup-$(date +%Y%m%d).yaml

# Backup verifizieren
wc -l cert-manager-backup-$(date +%Y%m%d).yaml
```

---

## Phase 2: Ingress-nginx-Version prüfen (wegen 1.18 pathType-Change)

```bash
kubectl -n ingress-nginx get deployment ingress-nginx-controller \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

> Wenn ingress-nginx `< v1.12.6` oder `< v1.13.2`: sicherstellen, dass `strict-validate-path-type: false` gesetzt ist, bevor auf 1.18 upgegraded wird. Im homelab-Cluster mit Traefik nicht relevant.

---

## Phase 3: Schrittweises Upgrade (Minor-by-Minor)

> **Wichtig:** Zwischen jedem Schritt prüfen ob alle Pods `Running` sind und keine Failed-CertificateRequests vorliegen.

### Helm Release Name ermitteln

```bash
RELEASE=$(helm list -n cert-manager -q | grep cert-manager | head -1)
echo "Release: $RELEASE"
# Erwartet: cert-manager
```

### 3.1 Upgrade auf v1.14.x (latest patch)

```bash
helm upgrade --reset-then-reuse-values \
  --version v1.14.7 \
  "${RELEASE}" \
  oci://quay.io/jetstack/charts/cert-manager \
  -n cert-manager

kubectl -n cert-manager rollout status deployment/cert-manager
kubectl -n cert-manager rollout status deployment/cert-manager-cainjector
kubectl -n cert-manager rollout status deployment/cert-manager-webhook
kubectl -n cert-manager get pods
```

### 3.2 Upgrade auf v1.15.x

```bash
helm upgrade --reset-then-reuse-values \
  --version v1.15.5 \
  "${RELEASE}" \
  oci://quay.io/jetstack/charts/cert-manager \
  -n cert-manager

kubectl -n cert-manager rollout status deployment/cert-manager
kubectl -n cert-manager rollout status deployment/cert-manager-cainjector
kubectl -n cert-manager rollout status deployment/cert-manager-webhook
kubectl -n cert-manager get pods
```

### 3.3 Upgrade auf v1.16.x

```bash
helm upgrade --reset-then-reuse-values \
  --version v1.16.5 \
  "${RELEASE}" \
  oci://quay.io/jetstack/charts/cert-manager \
  -n cert-manager

kubectl -n cert-manager rollout status deployment/cert-manager
kubectl -n cert-manager rollout status deployment/cert-manager-webhook
kubectl -n cert-manager get pods
```

### 3.4 Upgrade auf v1.17.x

```bash
helm upgrade --reset-then-reuse-values \
  --version v1.17.4 \
  "${RELEASE}" \
  oci://quay.io/jetstack/charts/cert-manager \
  -n cert-manager

kubectl -n cert-manager rollout status deployment/cert-manager
kubectl -n cert-manager rollout status deployment/cert-manager-webhook
kubectl -n cert-manager get pods
```

### 3.5 Upgrade auf v1.18.x

```bash
helm upgrade --reset-then-reuse-values \
  --version v1.18.6 \
  "${RELEASE}" \
  oci://quay.io/jetstack/charts/cert-manager \
  -n cert-manager

kubectl -n cert-manager rollout status deployment/cert-manager
kubectl -n cert-manager rollout status deployment/cert-manager-webhook
kubectl -n cert-manager get pods
```

### 3.6 Upgrade auf v1.19.4 (Zielversion)

```bash
helm upgrade --reset-then-reuse-values \
  --version v1.19.4 \
  "${RELEASE}" \
  oci://quay.io/jetstack/charts/cert-manager \
  -n cert-manager

kubectl -n cert-manager rollout status deployment/cert-manager
kubectl -n cert-manager rollout status deployment/cert-manager-cainjector
kubectl -n cert-manager rollout status deployment/cert-manager-webhook
kubectl -n cert-manager get pods
```

---

## Phase 4: Post-Upgrade-Validierung

### Version verifizieren

```bash
helm list -n cert-manager
kubectl -n cert-manager get pods -o wide

# Image-Version prüfen
kubectl -n cert-manager get deployment cert-manager \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Erwartet: quay.io/jetstack/cert-manager-controller:v1.19.4
```

### Zertifikatsstatus prüfen

```bash
# Alle Certificates im Cluster
kubectl get certificates --all-namespaces

# Auf READY=True prüfen — alle sollten True sein
kubectl get certificates --all-namespaces \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[0].status,REASON:.status.conditions[0].reason'

# Etwaige Failed CertificateRequests
kubectl get certificaterequests --all-namespaces | grep -v Approved
```

### ClusterIssuers prüfen

```bash
kubectl get clusterissuers -o wide
# READY sollte True sein
```

### Cert-Manager Controller Logs auf Fehler prüfen

```bash
kubectl -n cert-manager logs deployment/cert-manager --since=10m | grep -i error
kubectl -n cert-manager logs deployment/cert-manager-webhook --since=10m | grep -i error
```

### Metrics-Label-Check (Prometheus/Grafana)

```bash
# Prüfen ob das alte 'path' Label noch in Queries verwendet wird
# In Grafana: certmanager_acme_client_request_count und
# certmanager_acme_client_request_duration_seconds
# Das Label 'path' wurde durch 'action' ersetzt
```

---

## Phase 5: Kustomize-Overlay anpassen (falls version gepinnt)

Falls die Helm-Chart-Version in den Kustomize-Overlays oder ArgoCD-Applications gepinnt ist:

```bash
# In gitops/apps/ nach cert-manager suchen
grep -r "cert-manager" gitops/apps/ --include="*.yaml" | grep "targetRevision\|version"

# Version auf v1.19.4 aktualisieren und committen
```

---

## Rollback-Prozedur

Im Fehlerfall auf die vorherige Version zurollen:

```bash
# Helm History anzeigen
helm history cert-manager -n cert-manager

# Rollback auf vorige Revision
helm rollback cert-manager -n cert-manager

# Status prüfen
kubectl -n cert-manager get pods
kubectl get certificates --all-namespaces
```

> **Hinweis:** Ein Rollback über mehrere Minor-Versionen kann CRD-Inkompatibilitäten erzeugen. Im Zweifel Backup aus Phase 1 verwenden.

---

## Referenzen

- [cert-manager Release Notes 1.19](https://cert-manager.io/docs/releases/release-notes/release-notes-1.19/)
- [cert-manager Upgrade Guide](https://cert-manager.io/docs/installation/upgrade/)
- [cert-manager GitHub Releases](https://github.com/cert-manager/cert-manager/releases)
- [CVE-2025-68121](https://www.cve.org/CVERecord?id=CVE-2025-68121)
- [CVE-2026-24051](https://www.cve.org/CVERecord?id=CVE-2026-24051)
