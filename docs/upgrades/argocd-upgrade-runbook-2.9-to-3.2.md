# ArgoCD Upgrade Runbook: 2.9.3 → 3.2.10

**Erstellt:** 2026-04-30  
**Ziel-Umgebung:** seri-k8s Homelab, k3s v1.32.3+k3s1  
**Von:** ArgoCD 2.9.3  
**Nach:** ArgoCD 3.2.10  

---

## Übersicht

### Upgrade-Pfad (9 Hops, kein Minor-Skip erlaubt)

```
2.9.3 → 2.10.x → 2.11.x → 2.12.x → 2.13.x → 2.14.x → 3.0.x → 3.1.x → 3.2.10
```

### Zeitaufwand-Schätzung

| Phase | Dauer (ca.) |
|---|---|
| Pre-Flight-Checks & Backup | 30–45 min |
| 5× Minor-Hops (2.9→2.14) | 5× 10 min = 50 min |
| Major-Hop 2.14 → 3.0 (Breaking Changes!) | 30–45 min |
| 3.0 → 3.1 → 3.2 | 2× 10 min = 20 min |
| Post-Upgrade-Verifikation | 20–30 min |
| **Gesamt** | **ca. 2.5–3 Stunden** |

> **Empfehlung:** In einem Wartungsfenster durchführen, da ArgoCD während der Hops kurz nicht sync-fähig ist. Laufende Workloads sind davon nicht betroffen.

---

## Frage 1: Breaking Changes bei 2.x → 3.x (argocd-cm Ingress Health Check)

### Dein aktueller Patch (Ingress Health Check in argocd-cm)

Typischerweise sieht der Custom Health Check für Ingress/Traefik-IngressRoute so aus:

```yaml
# argocd-cm ConfigMap (Auszug)
data:
  resource.customizations.health.networking.k8s.io_Ingress: |
    hs = {}
    hs.status = "Healthy"
    hs.message = ""
    return hs
  resource.customizations.health.traefik.io_IngressRoute: |
    hs = {}
    hs.status = "Healthy"
    hs.message = ""
    return hs
```

**Befund: Diese Konfiguration ist von den Breaking Changes NICHT betroffen.**

### Relevante Breaking Changes 2.x → 3.0 (die dich betreffen könnten)

#### ✅ UNBETROFFEN: Custom Health Checks (`resource.customizations.health.*`)
Die Lua-basierten Custom Health Checks in `argocd-cm` bleiben in 3.0 vollständig kompatibel. Das Key-Format `resource.customizations.health.<group>_<kind>` ist unverändert.

#### ⚠️ BETROFFEN: `resource.exclusions` — neue Defaults in 3.0
ArgoCD 3.0 fügt **neue Default-Exclusions** in die `argocd-cm` ein (high-churn K8s-Objekte wie `Endpoints`, `EndpointSlice`, `Lease`, `TokenReview`, etc.). Falls du bereits eigene `resource.exclusions` hast, musst du diese **zusammenführen**, nicht ersetzen.

**Check vorher:**
```bash
kubectl get cm argocd-cm -n argocd -o jsonpath='{.data.resource\.exclusions}'
```

#### ⚠️ BETROFFEN: `resource.compareoptions` — geänderte Defaults in 3.0

Zwei geänderte Default-Behaviors:

1. **`ignoreDifferencesOnResourceUpdates`** — Default wechselt auf `true`. Wenn du das v2-Verhalten brauchst:
   ```yaml
   resource.compareoptions: |
     ignoreDifferencesOnResourceUpdates: false
   ```

2. **`ignoreResourceStatusField`** — Default wechselt von `crd` auf `all`. Wenn du v2-Verhalten brauchst:
   ```yaml
   resource.compareoptions: |
     ignoreResourceStatusField: crd
   ```

#### ⚠️ BETROFFEN: Resource Tracking Method — Default wechselt auf `annotation`
In 3.0 ist `annotation`-basiertes Tracking der neue Default (statt `label`).

**Check vorher:**
```bash
kubectl get cm argocd-cm -n argocd \
  -o jsonpath='{.data.application\.resourceTrackingMethod}'
```
Wenn leer oder `label`: **vor dem 3.0-Hop** auf `annotation` umstellen (noch auf 2.14!):
```bash
kubectl patch cm argocd-cm -n argocd --type merge \
  -p '{"data":{"application.resourceTrackingMethod":"annotation"}}'
```
Danach alle Apps kurz re-synchen und prüfen ob sie `Synced` bleiben.

#### ⚠️ BETROFFEN: RBAC — Fine-Grained Policies (Default geändert)
In 3.0 gilt: `update`/`delete` auf eine Application gilt **nicht** mehr automatisch für Sub-Ressourcen. Betrifft dich nur wenn du eigene RBAC-Policies in `argocd-rbac-cm` hast.

**Workaround** (temporär, während Migration):
```yaml
# argocd-cm
data:
  server.rbac.disableApplicationFineGrainedRBACInheritance: "false"
```

#### ⚠️ BETROFFEN: Logs-RBAC wird enforced
Das Flag `server.rbac.log.enforce.enable` wird in 3.0 entfernt — Logs-RBAC ist jetzt immer aktiv. Falls du dieses Flag in deiner `argocd-cm` hast: **vor dem 3.0-Hop entfernen**.

#### ✅ UNBETROFFEN: Legacy Repository-Konfiguration in argocd-cm
Du nutzt sealed-secrets-basierte Repo-Secrets (kein legacy `repositories:` Feld in argocd-cm) — kein Handlungsbedarf.

#### ✅ UNBETROFFEN (3.1 → 3.2): CronJob-Healthcheck
3.2 ändert den Default-Healthcheck für suspended CronJobs — das betrifft das `resource.customizations.health`-Format aber **nicht** (nur den Built-in-Check für `batch/CronJob`). Dein Ingress-Patch ist davon nicht berührt.

---

## Phase 0: Pre-Flight-Checks

```bash
# 1. Aktuellen Status prüfen — keine App darf degraded sein
kubectl get applications -n argocd \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}'

# 2. ArgoCD-Pods prüfen
kubectl get pods -n argocd

# 3. Aktuelle Version bestätigen
kubectl get deployment argocd-server -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# 4. Aktuelle argocd-cm sichern (Sichtung)
kubectl get cm argocd-cm -n argocd -o yaml

# 5. Resource Tracking Method prüfen
kubectl get cm argocd-cm -n argocd \
  -o jsonpath='{.data.application\.resourceTrackingMethod}'
# Erwartetes Ergebnis bei dir: leer oder "label" → muss auf "annotation" vor 3.0

# 6. Eigene resource.exclusions prüfen
kubectl get cm argocd-cm -n argocd \
  -o jsonpath='{.data.resource\.exclusions}'

# 7. RBAC-Log-Enforce-Flag prüfen (muss vor 3.0 weg)
kubectl get cm argocd-cm -n argocd \
  -o jsonpath='{.data.server\.rbac\.log\.enforce\.enable}'
```

---

## Phase 1: Backup

### 1.1 ArgoCD `admin export` (offizieller Weg)

Exportiert Applications, AppProjects, Repository-Credentials, ConfigMaps:

```bash
# Aktuelle Version aus dem laufenden Deployment lesen
ARGOCD_VERSION=$(kubectl get deployment argocd-server -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].image}' | cut -d: -f2)

echo "ArgoCD Version für Backup: $ARGOCD_VERSION"

# Export via kubectl exec (kein Docker nötig)
kubectl exec -n argocd deploy/argocd-server -- \
  argocd admin export --namespace argocd \
  > argocd-backup-$(date +%Y%m%d-%H%M%S).yaml

echo "Backup-Größe: $(wc -l < argocd-backup-*.yaml) Zeilen"
```

> **Hinweis:** Der Export enthält keine Secrets im Klartext, aber Repo-Credential-Referenzen. Sealed Secrets sind davon unabhängig — die liegen bereits in Git.

### 1.2 Rohe Kubernetes-Ressourcen sichern (Fallback)

```bash
BACKUP_DIR="argocd-backup-raw-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

# Applications und AppProjects
kubectl get applications -n argocd -o yaml > "$BACKUP_DIR/applications.yaml"
kubectl get appprojects -n argocd -o yaml  > "$BACKUP_DIR/appprojects.yaml"

# ConfigMaps (enthält argocd-cm, argocd-rbac-cm, argocd-cmd-params-cm)
kubectl get configmaps -n argocd -o yaml   > "$BACKUP_DIR/configmaps.yaml"

# Secrets (Repository-Credentials, Cluster-Credentials — Sealed, also sicher)
kubectl get secrets -n argocd \
  -l argocd.argoproj.io/secret-type -o yaml > "$BACKUP_DIR/secrets.yaml"

# RBAC
kubectl get cm argocd-rbac-cm -n argocd -o yaml > "$BACKUP_DIR/argocd-rbac-cm.yaml"

echo "Backup abgelegt in: $BACKUP_DIR/"
ls -la "$BACKUP_DIR/"
```

### 1.3 Backup auf Synology/NAS kopieren

```bash
# Beispiel: scp auf Synology NAS
scp -r "$BACKUP_DIR/" nas.reckeweg.io:/volume1/backups/argocd/
scp argocd-backup-*.yaml nas.reckeweg.io:/volume1/backups/argocd/
```

### 1.4 Backup verifizieren

```bash
# YAML-Syntax check
python3 -c "
import yaml, sys
with open('$(ls -t argocd-backup-*.yaml | head -1)') as f:
    docs = list(yaml.safe_load_all(f))
print(f'Backup OK: {len(docs)} Ressourcen exportiert')
"
```

---

## Phase 2: Upgrade-Hops 2.9 → 2.14

Für jeden Hop: `MANIFEST_URL` anpassen und alle 5 Checks wiederholen.

### Upgrade-Skript (einmal pro Hop ausführen)

```bash
# TARGET_VERSION anpassen pro Hop!
TARGET_VERSION="v2.10.18"   # dann v2.11.x, v2.12.x, v2.13.x, v2.14.x

kubectl apply -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${TARGET_VERSION}/manifests/install.yaml"

# Rollout abwarten
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=300s
kubectl rollout status deployment/argocd-application-controller -n argocd --timeout=300s || \
  kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s

# Version verifizieren
kubectl get deployment argocd-server -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
echo ""

# Apps prüfen (alle Synced/Healthy?)
kubectl get applications -n argocd \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}'
```

### Aktuelle Patch-Versionen pro Minor

> Immer die neueste Patch-Version des jeweiligen Minor nehmen:

| Hop | Version (Stand April 2026) |
|---|---|
| 2.9 → 2.10 | `v2.10.18` |
| 2.10 → 2.11 | `v2.11.13` |
| 2.11 → 2.12 | `v2.12.9` |
| 2.12 → 2.13 | `v2.13.6` |
| 2.13 → 2.14 | `v2.14.10` |

> **Vor jedem Hop:** Aktuelle Patch-Version prüfen: https://github.com/argoproj/argo-cd/releases

---

## Phase 3: Vorbereitung für 3.0 (auf 2.14 liegend!)

Diese Schritte **vor dem 3.0-Hop** auf Version 2.14 durchführen:

### 3.1 Resource Tracking auf `annotation` umstellen

```bash
kubectl patch cm argocd-cm -n argocd --type merge \
  -p '{"data":{"application.resourceTrackingMethod":"annotation"}}'

# Alle Apps refreshen (optional aber empfohlen)
# In der ArgoCD UI: alle Apps → Refresh → prüfen ob Synced bleibt
```

### 3.2 `server.rbac.log.enforce.enable` entfernen (falls vorhanden)

```bash
# Prüfen ob das Flag gesetzt ist
kubectl get cm argocd-cm -n argocd \
  -o jsonpath='{.data.server\.rbac\.log\.enforce\.enable}'

# Falls "true" oder gesetzt: entfernen
kubectl patch cm argocd-cm -n argocd --type=json \
  -p='[{"op":"remove","path":"/data/server.rbac.log.enforce.enable"}]'
```

### 3.3 RBAC Fine-Grained temporär deaktivieren (Sicherheitsnetz)

```bash
# Temporäres Kompatibilitäts-Flag setzen (v2-Verhalten beibehalten)
kubectl patch cm argocd-cm -n argocd --type merge \
  -p '{"data":{"server.rbac.disableApplicationFineGrainedRBACInheritance":"false"}}'
```

### 3.4 Eigene resource.exclusions mergen

Falls du eigene `resource.exclusions` in `argocd-cm` hast: Nach dem 3.0-Hop prüfen ob die neuen ArgoCD-Default-Exclusions (Endpoints, Lease, etc.) mit deinen Einträgen konfligieren.

---

## Phase 4: Major-Hop → 3.0.x

```bash
TARGET_VERSION="v3.0.10"   # aktuelle Patch-Version prüfen!

kubectl apply -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${TARGET_VERSION}/manifests/install.yaml"

# CRDs sind bei diesem Hop besonders wichtig — separat prüfen
kubectl get crd applications.argoproj.io \
  -o jsonpath='{.spec.versions[*].name}'
echo ""

# Rollout abwarten (länger timeout wegen CRD-Migrationen)
kubectl rollout status deployment/argocd-server -n argocd --timeout=600s
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=600s

# Version verifizieren
kubectl get deployment argocd-server -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
echo ""

# Apps ausführlich prüfen
kubectl get applications -n argocd \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}'
```

### Post-3.0 Verifikation (kritisch!)

```bash
# 1. Health Checks funktionieren noch? (Ingress/IngressRoute)
kubectl get applications -n argocd \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.health.status}{"\n"}{end}'

# 2. argocd-cm Ingress-Patch noch vorhanden?
kubectl get cm argocd-cm -n argocd \
  -o jsonpath='{.data.resource\.customizations\.health\.networking\.k8s\.io_Ingress}'

# 3. Resource-Tracking-Method bestätigt auf annotation?
kubectl get cm argocd-cm -n argocd \
  -o jsonpath='{.data.application\.resourceTrackingMethod}'
# Erwartetes Ergebnis: annotation

# 4. ArgoCD UI aufrufen und einige Apps manuell prüfen
# https://argocd.reckeweg.io
```

---

## Phase 5: Hops 3.0 → 3.1 → 3.2.10

Keine Breaking Changes die deine Konfiguration betreffen.

```bash
# 3.0 → 3.1
TARGET_VERSION="v3.1.15"
kubectl apply -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${TARGET_VERSION}/manifests/install.yaml"
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
# [Checks wiederholen]

# 3.1 → 3.2.10
TARGET_VERSION="v3.2.10"
kubectl apply -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${TARGET_VERSION}/manifests/install.yaml"
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
# [Checks wiederholen]
```

> **Hinweis 3.1 → 3.2:** Falls du Source Hydrator mit Repo-Root (`""` oder `"."`) verwendest: Das ist ab 3.2 nicht mehr erlaubt. In deiner SERI-Konfiguration nicht der Fall (du nutzt Kustomize-Pfade).

---

## Phase 6: Post-Upgrade-Verifikation (Ziel: 3.2.10)

```bash
# 1. Finale Version bestätigen
kubectl get deployment argocd-server -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
echo ""

# 2. Alle Pods Running
kubectl get pods -n argocd

# 3. Alle Applications Synced & Healthy
kubectl get applications -n argocd \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}'

# 4. App-of-Apps (homelab-infrastructure) explizit prüfen
kubectl get application homelab-infrastructure -n argocd -o jsonpath='{.status}'

# 5. Ingress Health Check verifizieren (muss noch Healthy sein)
kubectl get cm argocd-cm -n argocd -o yaml | grep -A5 "customizations.health"

# 6. argocd CLI Version aktualisieren
# macOS:
brew upgrade argocd
# oder direkt:
curl -sSL -o /usr/local/bin/argocd \
  "https://github.com/argoproj/argo-cd/releases/download/v3.2.10/argocd-darwin-arm64"
chmod +x /usr/local/bin/argocd
argocd version --client
```

---

## Rollback-Prozedur

Falls nach einem Hop etwas schiefläuft:

```bash
# Vorherige Version wieder anwenden (Beispiel: zurück auf 2.13.x nach fehlgeschlagenem 2.14 Hop)
ROLLBACK_VERSION="v2.13.6"
kubectl apply -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ROLLBACK_VERSION}/manifests/install.yaml"
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s

# Falls argocd-cm modifiziert wurde: aus Backup wiederherstellen
kubectl apply -f argocd-backup-raw-YYYYMMDD-HHMMSS/configmaps.yaml

# Falls Applications/AppProjects verloren: aus Export wiederherstellen
kubectl exec -n argocd deploy/argocd-server -- \
  argocd admin import --namespace argocd - < argocd-backup-YYYYMMDD-HHMMSS.yaml
```

---

## Zusammenfassung: Was du vor dem ersten Hop tun musst

1. **Backup ausführen** (Phase 1) — auf NAS sichern
2. **Alle Apps auf Synced/Healthy** bringen (keine degraded Apps)
3. **Resource Tracking prüfen** — auf `annotation` umstellen (auf 2.14, vor 3.0-Hop)
4. **`server.rbac.log.enforce.enable`** entfernen falls gesetzt (vor 3.0)
5. **Ingress-Health-Check-Konfiguration** ist kompatibel — **kein Handlungsbedarf**

---

*Referenzen:*
- [ArgoCD Upgrade Overview](https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/overview/)
- [v2.14 → 3.0 Breaking Changes](https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/2.14-3.0/)
- [v3.1 → 3.2 Breaking Changes](https://argo-cd.readthedocs.io/en/latest/operator-manual/upgrading/3.1-3.2/)
- [ArgoCD Disaster Recovery](https://argo-cd.readthedocs.io/en/latest/operator-manual/disaster_recovery/)
- [GitHub Releases](https://github.com/argoproj/argo-cd/releases)
