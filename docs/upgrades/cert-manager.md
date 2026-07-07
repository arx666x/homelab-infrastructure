# Upgrade Runbook: cert-manager

## Metadaten
- **Namespace:** `cert-manager`
- **Aktuelle Version:** v1.20.3
- **Quelle:** Helm-Chart `cert-manager` aus `https://charts.jetstack.io`
- **ArgoCD App-Name:** `cert-manager`
- **Versions-Check-Quelle:** `targetRevision` in `gitops/apps/cert-manager.yaml` (Helm-Chart-Source `charts.jetstack.io`); Release Notes unter https://cert-manager.io/docs/releases/
- **Major/Minor-Kriterium:** cert-manager empfiehlt ausdrücklich, Minor-Versionen immer einzeln nacheinander zu upgraden (kein Überspringen), unabhängig von der Install-Methode. CRD-Migrationen und Breaking Changes zwischen Minor-Versionen können sonst zu inkonsistenten Zuständen führen. Patch-Releases (z.B. x.y.Z) können direkt eingespielt werden. Ausnahme: von einer .0-Minor-Version sollte nie direkt aus produktiv genutzt werden — immer zuerst auf den letzten Patch dieser Minor-Version warten/gehen (siehe v1.19.0-Bug unten).

## Changelog

| Datum | Von → Nach | Typ | Ausführung | Status | Begründung | Notiz |
|---|---|---|---|---|---|---|
| 2026-05-01 | v1.13.3 → v1.14.7 | Minor | Manuell | Abgeschlossen | Minor-by-Minor-Pflicht laut cert-manager-Upgrade-Guide; keine Breaking Changes für diese Installation | Teil der mehrstufigen Nachhol-Migration v1.13.3 → v1.20.3 |
| 2026-05-01 | v1.14.7 → v1.15.5 | Minor | Manuell | Abgeschlossen | CRDs werden ab 1.15 bei Deinstallation nicht mehr automatisch gelöscht (Schutzfunktion, positiv für ArgoCD-managed Installs) | |
| 2026-05-01 | v1.15.5 → v1.16.5 | Minor | Manuell | Abgeschlossen | Helm Schema Validation eingeführt; bestehende Values (`installCRDs: true`) sind valide, kein Handlungsbedarf | |
| 2026-05-01 | v1.16.5 → v1.17.4 | Minor | Manuell | Abgeschlossen | RSA-Hashing ändert sich (ab 3072-bit SHA-384, ab 4096-bit SHA-512); interne Root-CA `seri-root-ca` (RSA 4096) wird beim nächsten Renewal mit SHA-512 neu ausgestellt — gewollt | |
| 2026-05-01 | v1.17.4 → v1.18.6 | Minor | Manuell | Abgeschlossen | ACME HTTP-01 Ingress `pathType` → `Exact`; nicht relevant, da Traefik + DNS-01 (Cloudflare) genutzt wird | |
| 2026-05-01 | v1.18.6 → v1.19.4 | Minor | Manuell | Abgeschlossen | CVE-2026-24051, CVE-2025-68121; v1.19.0 hat einen Bug der unnötige Certificate-Renewals auslöst — deshalb direkt auf Patch v1.19.4 gesprungen, nie auf .0 stehen bleiben. Breaking: Prometheus-Label `path` entfernt aus `certmanager_acme_client_request_count`/`..._duration_seconds`, ersetzt durch `action` | Grafana-Dashboards nach diesem Schritt geprüft |
| 2026-05-03 | v1.19.4 → v1.20.2 | Minor | Manuell | Abgeschlossen | Go 1.26.2 (Dependency-Updates für gemeldete Vulnerabilities); Fix für unnötige Certificate-Renewals bei fehlendem `kind`/`group` in `issuerRef`; Helm-Fix für ungültiges YAML bei gleichzeitiger Definition von `webhook.config` und `webhook.volumes` | Direkter Schritt von v1.19.4 möglich, kein weiteres Minor-Stepping nötig |
| 2026-06-29 | v1.20.2 → v1.20.3 | Minor (Patch) | Manuell | Abgeschlossen | Patch-Release mit Bugfixes und Dependency-Updates, keine Breaking Changes | |

### Reklassifizierungen (Minor → Major)

| Datum Erkennung | Ursprünglicher Changelog-Eintrag (Datum) | Grund der Reklassifizierung | Erneute Benachrichtigung gesendet am |
|---|---|---|---|

## Manuelle Vorgehensweise (bei Major/Breaking Change)

cert-manager wird bei uns ausschließlich manuell (Git-Commit → ArgoCD Auto-Sync) upgegradet, nie automatisiert, da Minor-Schritte nicht übersprungen werden dürfen.

### Vorbereitung

```bash
# Aktuellen Zustand prüfen
kubectl -n cert-manager get deployment cert-manager \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

kubectl -n argocd get application cert-manager
# Erwartet: Synced / Healthy

# Backup
kubectl get -o yaml \
  clusterissuers,issuers,certificates,certificaterequests,orders,challenges \
  --all-namespaces > cert-manager-backup-$(date +%Y%m%d).yaml

# Cloudflare Secret sichern
kubectl -n cert-manager get secret cloudflare-api-token -o yaml > cloudflare-api-token-backup.yaml
```

### Hilfsfunktionen

```bash
# Warten bis ArgoCD Synced + Healthy
wait_argocd() {
  local VERSION=$1
  kubectl -n argocd wait application cert-manager \
    --for=jsonpath='{.status.sync.status}'=Synced --timeout=5m
  kubectl -n argocd wait application cert-manager \
    --for=jsonpath='{.status.health.status}'=Healthy --timeout=5m
}

# Pods und ClusterIssuers prüfen
validate() {
  kubectl -n cert-manager get pods
  kubectl -n cert-manager get deployment cert-manager \
    -o jsonpath='{.spec.template.spec.containers[0].image}'
  kubectl get clusterissuers -o wide
  kubectl get certificates --all-namespaces \
    -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[0].status,EXPIRY:.status.notAfter'
}
```

### Pro Minor-Schritt

```bash
sed -i '' 's/targetRevision: vX.Y.Z/targetRevision: vX.Y+1.W/' gitops/apps/cert-manager.yaml
grep targetRevision gitops/apps/cert-manager.yaml

git add gitops/apps/cert-manager.yaml
git commit -m "chore: upgrade cert-manager vX.Y.Z → vX.Y+1.W"
git push

wait_argocd vX.Y+1.W
validate
```

Wiederholen bis Zielversion erreicht — niemals mehr als eine Minor-Version pro Schritt überspringen.

### Post-Upgrade-Validierung (nach letztem Schritt)

```bash
# Image-Version bestätigen
kubectl -n cert-manager get pods \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'

kubectl -n cert-manager get deployment cert-manager \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
kubectl -n cert-manager get deployment cert-manager-webhook \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# ArgoCD Application final prüfen
kubectl -n argocd get application cert-manager
# SYNC STATUS: Synced / HEALTH STATUS: Healthy

# Alle ClusterIssuers Ready
kubectl get clusterissuers -o wide
# letsencrypt-prod / selfsigned-issuer / ca-issuer: READY = True

# Fehlerhafte CertificateRequests prüfen
kubectl get certificaterequests --all-namespaces | grep -v "Approved\|NAME"
# Leer = alles in Ordnung

# Controller-Logs
kubectl -n cert-manager logs deployment/cert-manager --since=15m | grep -iE "error|failed|panic"
kubectl -n cert-manager logs deployment/cert-manager-webhook --since=15m | grep -iE "error|failed|panic"
```

Bei Metrics-relevanten Änderungen (z.B. v1.19: Label `path` → `action`) zusätzlich betroffene Grafana-Dashboards/Queries prüfen.

### deploy-direct.sh aktualisieren

cert-manager wurde initial via `deploy-direct.sh` (kubectl apply, Static Manifests) gebootstrapt. ArgoCD (`selfHeal: true`) managed die Installation seitdem als Helm-Release und überschreibt manuelle `kubectl`-Eingriffe im laufenden Betrieb — `deploy-direct.sh` dient ausschließlich als Disaster-Recovery-Bootstrap. Nach jedem erfolgreichen Upgrade die Bootstrap-Version konsistent halten:

```bash
sed -i '' 's|cert-manager/releases/download/vOLD|cert-manager/releases/download/vNEW|' deploy-direct.sh
grep "releases/download" deploy-direct.sh
```

Die Version im Script und in `gitops/apps/cert-manager.yaml` sollten immer übereinstimmen.

## Bekannte Stolperfallen / Lessons Learned

- **v1.19.0 niemals als Zielversion verwenden:** Bug löst unnötige Certificate-Renewals aus. Immer direkt auf den letzten Patch dieser Minor-Version (v1.19.4) upgraden.
- **Fehlendes `kind`/`group` in `issuerRef`** kann beim Upgrade auf 1.19.x zu unnötigen Renewals führen — mit v1.20.2 behoben.
- **Metrics-Label-Breaking-Change in 1.19:** `path`-Label aus `certmanager_acme_client_request_count` / `certmanager_acme_client_request_duration_seconds` entfernt, ersetzt durch `action`. Grafana-Dashboards/Alerts nach dem Upgrade prüfen.
- **RSA-Hashing-Änderung in 1.17:** Root-CAs ≥3072-bit werden beim nächsten Renewal automatisch mit stärkerem Hash (SHA-384/512) neu signiert — bei uns gewollt (`seri-root-ca`, RSA 4096), aber in anderen Umgebungen ggf. auf Kompatibilität prüfen.
- **Minor-Stepping ist keine Empfehlung, sondern Voraussetzung:** CRD-Migrationen zwischen Minor-Versionen können bei übersprungenen Schritten zu inkonsistenten Zuständen führen.
- **`deploy-direct.sh` und `gitops/apps/cert-manager.yaml` können auseinanderlaufen**, wenn nach einem Upgrade vergessen wird, das Bootstrap-Script zu aktualisieren — regelmäßig gegenprüfen.

## Rollback-Plan

Im Fehlerfall auf die letzte funktionierende Version zurückkehren, Beispiel:

```bash
sed -i '' 's/targetRevision: vNEW/targetRevision: vOLD/' gitops/apps/cert-manager.yaml

git add gitops/apps/cert-manager.yaml
git commit -m "revert: cert-manager zurück auf vOLD"
git push
```

ArgoCD (`selfHeal: true`) synchronisiert automatisch zurück. Bei mehrstufigen Rollbacks (mehr als einen Minor-Schritt zurück) ebenfalls einzeln durchgehen, nicht überspringen. Vor dem Rollback ggf. das Backup der ClusterIssuers/Certificates (`cert-manager-backup-*.yaml`) zur Wiederherstellung heranziehen, falls CRD-Zustände durch das fehlgeschlagene Upgrade beschädigt wurden.

## Referenzen

- GitHub Releases: https://github.com/cert-manager/cert-manager/releases
- [cert-manager Upgrade Guide](https://cert-manager.io/docs/installation/upgrade/)
- [cert-manager Release Notes 1.19](https://cert-manager.io/docs/releases/release-notes/release-notes-1.19/)
- [cert-manager Release Notes 1.20](https://cert-manager.io/docs/releases/release-notes/release-notes-1.20/)
- [CVE-2025-68121](https://www.cve.org/CVERecord?id=CVE-2025-68121)
- [CVE-2026-24051](https://www.cve.org/CVERecord?id=CVE-2026-24051)
- ArgoCD Application: `gitops/apps/cert-manager.yaml`
- ClusterIssuer-Konfiguration: `gitops/config/cert-manager/cluster-issuer.yaml`, `gitops/config/cert-manager/internal-ca-issuer.yaml`
