# Traefik Upgrade Runbook: Chart v26 → v39.0.8 (Proxy v2 → v3)

**Datum:** 2026-05-04  
**Scope:** Homelab k3s-Cluster (`reckeweg.io`) + Colima  
**Namespace:** `traefik`  
**Aktuell:** Chart v26.0.0 / Traefik Proxy v2.x  
**Ziel:** Chart v39.0.8 / Traefik Proxy v3.6.x  
**Risiko:** 🔴 Hoch — CRD API Group wechselt, Rule Syntax ändert sich, Helm-CRD-Upgrade-Caveat

---

## Übersicht & Strategie

Der Upgrade ist **kein einfacher `helm upgrade`**. Drei Kernprobleme:

1. **CRD API Group**: `traefik.containo.us` → `traefik.io` — alle IngressRoutes, Middlewares etc. müssen migriert werden
2. **Helm updated CRDs nicht automatisch** — CRDs müssen manuell vor dem Chart-Upgrade angewendet werden
3. **Rule Syntax v2→v3**: PathPrefix, Headers, HeadersRegexp, Regex-Matcher ändern sich — mit Kompatibilitätsmodus überbrücken

**Ansatz: Phased Migration mit v2-Kompatibilitätsmodus**

```
Phase 1: Bestandsaufnahme & Backup
Phase 2: IngressRoute-Manifeste auf traefik.io umschreiben (kein Downtime)
Phase 3: CRDs manuell upgraden
Phase 4: Helm Chart upgraden (mit defaultRuleSyntax: v2 — kein Traffic-Impact)
Phase 5: Rule Syntax auf v3 migrieren
Phase 6: Alte containo.us CRDs entfernen
```

---

## Phase 1: Bestandsaufnahme & Backup

### 1.1 Aktuellen Stand dokumentieren

```bash
# Helm Release prüfen
helm -n traefik list

# Aktuelle Traefik-Version
kubectl -n traefik get deploy traefik -o jsonpath='{.spec.template.spec.containers[0].image}'

# Alle Traefik CRDs inventarisieren
kubectl get crd | grep traefik

# Alle IngressRoutes quer über alle Namespaces
kubectl get ingressroute,ingressroutetcp,ingressrouteudp,middleware,tlsoption,tlsstore,traefikservice \
  -A -o wide

# Namespaces mit Traefik-Ressourcen
kubectl get ingressroute -A --no-headers | awk '{print $1}' | sort -u
```

### 1.2 Backup Helm Values

```bash
# Aktuelle values exportieren
helm -n traefik get values traefik -o yaml > traefik-values-backup-v26.yaml

# Alle IngressRoutes sichern
kubectl get ingressroute -A -o yaml > ingressroutes-backup.yaml
kubectl get middleware -A -o yaml > middlewares-backup.yaml
kubectl get tlsoption -A -o yaml > tlsoptions-backup.yaml
kubectl get traefikservice -A -o yaml > traefikservices-backup.yaml
```

### 1.3 CRD API Groups prüfen

```bash
# Welche API Groups sind aktuell im Cluster?
kubectl get crd | grep traefik
# Erwartet bei v2: *.traefik.containo.us
# Ziel nach Migration: *.traefik.io
```

### 1.4 Monitoring sicherstellen

- Prometheus/Grafana: Traefik-Dashboard aufrufen → Baseline notieren
- curl-Test aller kritischen Services vor dem Upgrade:

```bash
# Alle IngressRoute-Hosts auflisten
kubectl get ingressroute -A -o jsonpath='{range .items[*]}{.spec.routes[*].match}{"\n"}{end}'

# Smoke-Test wichtiger Endpunkte (Beispiele SERI)
curl -s -o /dev/null -w "%{http_code}" https://gitea.reckeweg.io
curl -s -o /dev/null -w "%{http_code}" https://wordpress.reckeweg.io
curl -s -o /dev/null -w "%{http_code}" https://argocd.reckeweg.io
```

---

## Phase 2: IngressRoute-Manifeste migrieren (API Group + Rule Syntax)

> ⚠️ Diese Phase passiert **vor** dem Helm Upgrade — die alten CRDs sind noch aktiv,
> die Änderungen werden von Traefik v2 ignoriert und beim Upgrade v3 aufgegriffen.

### 2.1 API Group in allen Manifesten ersetzen

Alle Kustomize-Overlays und Basis-Manifeste müssen von `traefik.containo.us/v1alpha1` auf `traefik.io/v1alpha1` umgestellt werden.

**Homelab (gitops-Repo):**

```bash
# Vorkommen finden
grep -r "traefik.containo.us" gitops/ --include="*.yaml" -l

# Ersetzen (macOS-kompatibel)
find gitops/ -name "*.yaml" -exec \
  sed -i '' 's|traefik.containo.us/v1alpha1|traefik.io/v1alpha1|g' {} +

# Gegenchecken
grep -r "traefik.containo.us" gitops/ --include="*.yaml"
```

**Colima-Overlays (seri-k8s):**

```bash
find . -name "*.yaml" -exec \
  sed -i '' 's|traefik.containo.us/v1alpha1|traefik.io/v1alpha1|g' {} +
```

**Verifizieren & committen:**

```bash
git diff
git add -A
git commit -m "feat: migrate Traefik CRD apiVersion from containo.us to traefik.io"
git push
```

### 2.2 Rule Syntax — vorerst belassen (v2-Kompatibilitätsmodus)

> Die Rule Syntax (PathPrefix, Host, Headers etc.) wird **nicht** jetzt geändert.
> Der Kompatibilitätsmodus `defaultRuleSyntax: v2` in Phase 4 sorgt dafür,
> dass alle bestehenden Regeln weiter funktionieren.

**Was sich in v3 ändert (für spätere Phase 5):**

| v2 Syntax | v3 Syntax |
|-----------|-----------|
| `Headers(\`key\`, \`val\`)` | `Header(\`key\`, \`val\`)` |
| `HeadersRegexp(\`key\`, \`re\`)` | `HeaderRegexp(\`key\`, \`re\`)` |
| `PathPrefix` mit Regex | `PathRegexp` verwenden |
| `Path(\`/route/{id}\`)` (Placeholder) | `PathRegexp(\`/route/[^/]+\`)` |

---

## Phase 3: CRDs manuell upgraden

> ⚠️ **Kritisch**: Helm aktualisiert CRDs bei `helm upgrade` **nicht automatisch**.
> CRDs müssen **vor** dem Chart-Upgrade manuell applied werden.

### 3.1 Repo aktualisieren

```bash
helm repo update
helm search repo traefik/traefik
# Ziel: v39.0.8 anzeigen
```

### 3.2 Neue CRDs (traefik.io) anwenden

```bash
# CRDs aus dem neuen Chart extrahieren und anwenden
helm show crds traefik/traefik --version 39.0.8 | \
  kubectl apply --server-side --force-conflicts -f -
```

### 3.3 CRD-Status prüfen

```bash
kubectl get crd | grep traefik
# Jetzt sollten BEIDE Gruppen vorhanden sein:
# *.traefik.containo.us  (alt, noch aktiv)
# *.traefik.io           (neu)
```

---

## Phase 4: Helm Chart upgraden

### 4.1 Neue values.yaml vorbereiten

Ausgehend von `traefik-values-backup-v26.yaml` — kritische Anpassungen für v3:

```yaml
# traefik-values-v39.yaml

# ==========================================
# KRITISCH: v2-Kompatibilitätsmodus aktivieren
# Damit funktionieren bestehende IngressRoutes mit v2 Rule Syntax
# ==========================================
core:
  defaultRuleSyntax: v2

# Entrypoints — Syntax prüfen (ggf. angepasst in v3)
ports:
  web:
    port: 80
    exposedPort: 80
  websecure:
    port: 443
    exposedPort: 443
    tls:
      enabled: true

# MetalLB LoadBalancer IP beibehalten
service:
  type: LoadBalancer
  annotations:
    metallb.universe.tf/loadBalancerIPs: "192.168.20.100"

# Traefik Namespace
# (bereits via Helm -n traefik gesetzt)

# Logs — für Post-Upgrade-Diagnose
logs:
  general:
    level: INFO
  access:
    enabled: true

# cert-manager Integration (falls genutzt)
# certificatesResolvers: ...  ← aus Backup übernehmen

# Dashboard
ingressRoute:
  dashboard:
    enabled: false  # eigene IngressRoute verwenden
```

> **Entfernte v2-only-Optionen prüfen**: `pilot`, `experimental.plugins` (Syntax geändert),
> `providers.kubernetesIngressNginx` → `providers.kubernetesIngressNGINX` (Groß-/Kleinschreibung).

### 4.2 Dry-Run

```bash
helm upgrade traefik traefik/traefik \
  --version 39.0.8 \
  --namespace traefik \
  --values traefik-values-v39.yaml \
  --dry-run \
  --debug 2>&1 | head -100
```

### 4.3 Upgrade durchführen

```bash
helm upgrade traefik traefik/traefik \
  --version 39.0.8 \
  --namespace traefik \
  --values traefik-values-v39.yaml \
  --wait \
  --timeout 5m
```

### 4.4 Post-Upgrade-Check

```bash
# Pod-Status
kubectl -n traefik get pods -w

# Version verifizieren
kubectl -n traefik get deploy traefik -o jsonpath='{.spec.template.spec.containers[0].image}'
# Erwartet: traefik:v3.6.x

# Logs auf Errors/Warnings prüfen
kubectl -n traefik logs deploy/traefik --tail=100

# Spezifisch auf v2-Deprecation-Warnings achten
kubectl -n traefik logs deploy/traefik | grep -iE "deprecated|error|warn"

# Traefik-API (intern)
kubectl -n traefik port-forward deploy/traefik 9000:9000 &
curl http://localhost:9000/api/rawdata | jq '.routers | keys'
```

### 4.5 Smoke-Tests

```bash
curl -s -o /dev/null -w "%{http_code}" https://gitea.reckeweg.io
curl -s -o /dev/null -w "%{http_code}" https://wordpress.reckeweg.io
curl -s -o /dev/null -w "%{http_code}" https://argocd.reckeweg.io
# Alle sollten 200/301/302 zurückgeben
```

---

## Phase 5: Rule Syntax auf v3 migrieren

> Diese Phase kann **nach** Phase 4 in Ruhe durchgeführt werden.
> Traefik v3 warnt im Log über veraltete v2-Syntax — Logs als Roadmap nutzen.

### 5.1 Deprecation-Warnings aus Logs extrahieren

```bash
kubectl -n traefik logs deploy/traefik | grep -i "deprecated"
```

### 5.2 Syntax-Migration

**Headers/HeadersRegexp:**

```yaml
# v2
match: "Headers(`X-Forwarded-Proto`, `https`)"
# v3
match: "Header(`X-Forwarded-Proto`, `https`)"

# v2
match: "HeadersRegexp(`X-Custom`, `val.*`)"
# v3
match: "HeaderRegexp(`X-Custom`, `val.*`)"
```

**Regex in PathPrefix (selten, aber relevant):**

```yaml
# v2 (regex in PathPrefix war möglich)
match: "PathPrefix(`/api/{id}`)"
# v3
match: "PathRegexp(`/api/[^/]+`)"
```

### 5.3 Kompatibilitätsmodus deaktivieren

Sobald alle IngressRoutes auf v3-Syntax umgestellt sind:

```yaml
# traefik-values-v39.yaml — diese Sektion entfernen
core:
  defaultRuleSyntax: v2  # ← entfernen
```

```bash
helm upgrade traefik traefik/traefik \
  --version 39.0.8 \
  --namespace traefik \
  --values traefik-values-v39.yaml \
  --wait
```

---

## Phase 6: Alte containo.us CRDs entfernen

> ⚠️ **Erst ausführen wenn Phase 5 abgeschlossen** und alle Ressourcen auf `traefik.io` laufen.

### 6.1 Sicherstellen dass keine Ressourcen mehr containo.us nutzen

```bash
kubectl get ingressroute -A -o yaml | grep -c "containo.us"
# Muss 0 sein
```

### 6.2 Alte CRDs löschen

```bash
kubectl delete crd \
  ingressroutes.traefik.containo.us \
  ingressroutetcps.traefik.containo.us \
  ingressrouteudps.traefik.containo.us \
  middlewares.traefik.containo.us \
  middlewaretcps.traefik.containo.us \
  serverstransports.traefik.containo.us \
  tlsoptions.traefik.containo.us \
  tlsstores.traefik.containo.us \
  traefikservices.traefik.containo.us
```

---

## Rollback-Plan

### Schnell-Rollback auf Chart v26

```bash
# Helm Rollback auf vorherige Revision
helm -n traefik rollback traefik

# Revision History prüfen
helm -n traefik history traefik
```

> **Wichtig**: Solange die alten `containo.us` CRDs noch vorhanden sind (Phase 1–4),
> ist ein Rollback auf Traefik v2 problemlos möglich. Erst nach Phase 6 ist der Rollback
> deutlich aufwändiger (CRDs müssten manuell zurückgespielt werden).

### Fallback-Manifeste

Backup-Dateien aus Phase 1.2 liegen bereit:

```bash
kubectl apply -f traefik-values-backup-v26.yaml   # nur als Referenz
kubectl apply -f ingressroutes-backup.yaml
kubectl apply -f middlewares-backup.yaml
```

---

## Kustomize / GitOps-Anpassungen (ArgoCD)

Da Traefik im Homelab via Kustomize/ArgoCD verwaltet wird, müssen die Helm-Values in die GitOps-Struktur übertragen werden.

**Typische Struktur:**

```
gitops/
  apps/
    traefik.yaml              # ArgoCD Application
  config/
    traefik/
      values.yaml             # Helm values → hier v39-Values eintragen
```

**ArgoCD Application anpassen:**

```yaml
# gitops/apps/traefik.yaml
spec:
  source:
    chart: traefik
    repoURL: https://traefik.github.io/charts
    targetRevision: "39.0.8"   # ← von 26.0.0 auf 39.0.8
    helm:
      valueFiles:
        - values.yaml
```

**Nach Commit ArgoCD sync triggern:**

```bash
argocd app sync traefik
argocd app wait traefik --health
```

---

## Checkliste

### Phase 1 — Vorbereitung
- [ ] Helm-Release und aktuelle Version dokumentiert
- [ ] Alle IngressRoutes/Middlewares per `kubectl get -A` inventarisiert
- [ ] Backup-YAMLs erstellt (`ingressroutes-backup.yaml` etc.)
- [ ] Aktuelle Helm-Values exportiert (`traefik-values-backup-v26.yaml`)
- [ ] Smoke-Test-Baseline aller kritischen Endpunkte
- [ ] Grafana-Dashboard Screenshot

### Phase 2 — Manifest-Migration
- [ ] `traefik.containo.us/v1alpha1` → `traefik.io/v1alpha1` in **allen** Repos ersetzt
- [ ] `grep -r "traefik.containo.us"` gibt keine Treffer mehr
- [ ] Geänderte Manifeste committed & gepushed

### Phase 3 — CRD-Upgrade
- [ ] `helm repo update` ausgeführt
- [ ] Neue CRDs via `helm show crds | kubectl apply --server-side` angewendet
- [ ] Beide CRD-Gruppen (containo.us + traefik.io) im Cluster sichtbar

### Phase 4 — Helm Upgrade
- [ ] `traefik-values-v39.yaml` mit `core.defaultRuleSyntax: v2` erstellt
- [ ] Dry-Run ohne Fehler
- [ ] `helm upgrade` erfolgreich
- [ ] Traefik Pod läuft mit v3.6.x Image
- [ ] Keine Error-Logs (nur ggf. v2-Deprecation-Warnings)
- [ ] Smoke-Tests alle ✅

### Phase 5 — Rule Syntax
- [ ] Deprecation-Warnings aus Logs analysiert
- [ ] Alle IngressRoutes auf v3 Syntax umgestellt
- [ ] `core.defaultRuleSyntax: v2` aus values entfernt
- [ ] Erneuter Helm upgrade + Smoke-Test

### Phase 6 — Cleanup
- [ ] Kein Manifest mehr referenziert `containo.us`
- [ ] Alte CRDs gelöscht
- [ ] Backup-Dateien archiviert oder gelöscht

---

## Bekannte Fallstricke

| Problem | Ursache | Lösung |
|---------|---------|--------|
| `helm upgrade` schlägt fehl wegen CRD-Konflikten | Helm updated CRDs nicht | Phase 3: CRDs manuell vorab anwenden |
| IngressRoutes liefern 404 nach Upgrade | containo.us Manifeste nicht migriert | Phase 2 vollständig ausführen |
| Traefik startet nicht | Veraltete v2-only-Werte in values.yaml (z.B. `pilot`) | values.yaml bereinigen, `helm upgrade --dry-run` nutzen |
| cert-manager Zertifikate funktionieren nicht | TLS-Konfiguration in Helm values geändert | websecure entrypoint TLS-Config prüfen |
| ArgoCD zeigt OutOfSync | CRD-Version in ArgoCD-Application nicht aktualisiert | targetRevision in `gitops/apps/traefik.yaml` anpassen |

---

## Referenzen

- [Traefik v2→v3 Migration Guide](https://doc.traefik.io/traefik/migrate/v2-to-v3/)
- [Traefik v3 Detail Changes](https://doc.traefik.io/traefik/migrate/v2-to-v3-details/)
- [traefik-helm-chart README](https://github.com/traefik/traefik-helm-chart)
- [Helm CRD Caveat HIP-0011](https://github.com/helm/community/blob/main/hips/hip-0011.md)
