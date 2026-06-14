# ArgoCD Upgrade Runbook

**Erstellt:** 2026-04-30  
**Zuletzt aktualisiert:** 2026-05-18  
**Ziel-Umgebung:** seri-k8s Homelab, k3s v1.32.3+k3s1  
**Aktuell dokumentiert:** 2.9.3 → 3.4.1  

---

## Übersicht

### Upgrade-Pfad (9 Hops, kein Minor-Skip erlaubt)

```
2.9.3 → 2.10.x → 2.11.x → 2.12.x → 2.13.x → 2.14.x → 3.0.x → 3.1.x → 3.2.10 → 3.3.9
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

---

## Phase 7: Hop 3.2.10 → 3.3.9

**Durchgeführt:** 2026-05-04  
**Status:** ✅ Erfolgreich

### Breaking Changes 3.2 → 3.3

- **`--server-side --force-conflicts` beim `kubectl apply` ab 3.3 Pflicht** — ArgoCD CRDs überschreiten das Limit für client-side apply. Das alte `kubectl apply` ohne diese Flags schlägt fehl.
- **Kustomize** wird von v5.7.0 auf v5.8.1 aktualisiert — keine Breaking Changes.
- **Cluster-Versionsformat** ändert sich leicht (vMajor.Minor.Patch statt Major.Minor) — betrifft nur ApplicationSets mit Cluster Generators, die du nicht nutzt.

### Upgrade-Befehl

```bash
./scripts/upgrade-argocd-hop.sh v3.3.9
```

Das Script erledigt automatisch:
1. `kubectl apply --server-side --force-conflicts`
2. SSH Known Hosts wiederherstellen
3. Rollout abwarten
4. NodeAffinity + Resource Limits patchen (siehe unten)

### Manuell (ohne Script)

```bash
kubectl apply -n argocd \
  --server-side \
  --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.9/manifests/install.yaml"

kubectl rollout status deployment/argocd-server              -n argocd --timeout=300s
kubectl rollout status deployment/argocd-repo-server         -n argocd --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
```

### Post-3.3 Verifikation

```bash
# Version bestätigen
kubectl get deployment argocd-server -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Erwartung: quay.io/argoproj/argocd:v3.3.9

# Alle Apps Synced/Healthy?
kubectl get applications -n argocd \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}'

# argocd CLI aktualisieren
curl -sSL -o /usr/local/bin/argocd \
  "https://github.com/argoproj/argo-cd/releases/download/v3.3.9/argocd-darwin-arm64"
chmod +x /usr/local/bin/argocd
argocd version --client
```

---

## Anhang: Application Controller — NodeAffinity & Resource Limits

**Hintergrund:** Der Application Controller lief auf `k3s-03a` (Raspberry Pi 5, ARM64) und verbrauchte beim Sync über 1100m CPU = 33% des gesamten Nodes. Kein einziger ArgoCD-Pod hatte Resource-Limits gesetzt.

**Lösung (2026-05-04):** NodeAffinity (preferred AMD64) + Resource Limits auf den Application Controller.

### Symptome eines überlasteten Controllers

- ArgoCD UI nicht erreichbar oder sehr langsam während Syncs
- `kubectl top nodes` zeigt Pi-Node bei 30%+ CPU
- `kubectl top pods -n argocd` zeigt application-controller bei 1000m+

### Diagnose

```bash
# Auf welchem Node läuft der Controller?
kubectl get pod argocd-application-controller-0 -n argocd \
  -o jsonpath='Node: {.spec.nodeName}{"\n"}'

# Ressourcenverbrauch
kubectl top pods -n argocd --sort-by=cpu

# Limits gesetzt?
kubectl get statefulset argocd-application-controller -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].resources}' | jq .
# Leer = keine Limits → Problem
```

### Fix: NodeAffinity (preferred AMD64)

```bash
# WICHTIG: merge-patch auf spec.template.spec — NICHT auf containers[]!
# Merge-Patch auf containers[] löscht image/command/args → CrashLoopBackOff
kubectl patch statefulset argocd-application-controller -n argocd \
  --type=merge -p='{
  "spec": {"template": {"spec": {
    "affinity": {
      "nodeAffinity": {
        "preferredDuringSchedulingIgnoredDuringExecution": [
          {
            "weight": 80,
            "preference": {
              "matchExpressions": [{
                "key": "kubernetes.io/arch",
                "operator": "In",
                "values": ["amd64"]
              }]
            }
          }
        ]
      }
    }
  }}}}'
```

### Fix: Resource Limits

```bash
# WICHTIG: json-patch "replace" auf exakten Pfad — NICHT merge-patch mit containers[]!
kubectl patch statefulset argocd-application-controller -n argocd \
  --type='json' -p='[{
    "op": "replace",
    "path": "/spec/template/spec/containers/0/resources",
    "value": {
      "requests": {"cpu": "250m", "memory": "512Mi"},
      "limits":   {"cpu": "2000m", "memory": "1Gi"}
    }
  }]'
```

### Restart & Verifikation

```bash
kubectl rollout restart statefulset/argocd-application-controller -n argocd
kubectl rollout status  statefulset/argocd-application-controller -n argocd --timeout=300s

# Läuft er jetzt auf AMD64?
kubectl get pod argocd-application-controller-0 -n argocd \
  -o jsonpath='Node: {.spec.nodeName}{"\n"}'
# Erwartung: gmkt-01x, gmkt-02x oder gmkt-03x

# Ressourcenverbrauch nach einigen Minuten
kubectl top pods -n argocd --sort-by=cpu
# Controller sollte bei <500m CPU liegen (außer direkt nach Restart)
```

### ⚠️ Kritischer Fallstrick: CrashLoopBackOff durch falschen Patch

**Problem:** Merge-Patch auf `containers[]` Array überschreibt den gesamten Container-Spec. `image`, `command` und `args` gehen verloren. tini startet ohne Argumente und crasht sofort.

**Symptom:**
```
tini (tini version 0.19.0)
Usage: tini [OPTIONS] PROGRAM -- [ARGS] | --version
```

**Recovery:** StatefulSet löschen und aus Manifest neu anwenden:
```bash
kubectl delete statefulset argocd-application-controller -n argocd
kubectl apply -n argocd \
  --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.9/manifests/install.yaml"
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
```

Danach Affinity und Resources mit den sicheren Patch-Befehlen oben neu setzen.

### Durchgeführte Upgrades

| Datum | Von | Auf | Ergebnis | Besonderheiten |
|---|---|---|---|---|
| 2026-04-30 | 2.9.3 | 3.2.10 | ✅ | 9 Hops, Resource Tracking auf annotation migriert |
| 2026-05-04 | 3.2.10 | 3.3.9 | ✅ | `--server-side --force-conflicts` Pflicht; NodeAffinity+Limits gesetzt |
| 2026-05-18 | 3.3.9 | 3.4.1 | ✅ | Kein Handlungsbedarf; CLI via brew (3.4.2) |
| 2026-05-18 | 3.4.1 | 3.4.2 | ✅ | Patch-Release, kein Breaking Change; CLI via brew bereits aktuell |
| 2026-06-14 | 3.4.2 | 3.4.3 | ✅ | Patch-Release; Security-Fix dompurify CVE-2026-41240; kein Breaking Change |

---

## Phase 9: Patch-Hop 3.4.1 → 3.4.2

**Durchgeführt:** 2026-05-18  
**Status:** ✅ Erfolgreich

Patch-Release — keine Breaking Changes, keine Konfigurationsänderungen erforderlich.

```bash
kubectl apply -n argocd \
  --server-side \
  --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.2/manifests/install.yaml"

kubectl rollout status deployment/argocd-server              -n argocd --timeout=300s
kubectl rollout status deployment/argocd-repo-server         -n argocd --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s

# Version bestätigen
kubectl get deployment argocd-server -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Erwartung: quay.io/argoproj/argocd:v3.4.2

# CLI (war bereits auf 3.4.2 via brew)
argocd version --client
```

---

## Phase 8: Hop 3.3.9 → 3.4.1

**Durchgeführt:** 2026-05-18  
**Status:** ✅ Erfolgreich

### Breaking Changes 3.3 → 3.4

#### ⚠️ PRÜFEN: Cluster-Versionsformat geändert (Cluster-Generator)

Das Format der Kubernetes-Version wechselt von `Major.Minor` auf `vMajor.Minor.Patch`.

Betrifft ApplicationSets, die den **Cluster Generator** mit dem Label `argocd.argoproj.io/kubernetes-version` nutzen.

**Check vorher:**
```bash
kubectl get applicationsets -n argocd -o yaml | grep "kubernetes-version"
# Leer = kein Handlungsbedarf
```

#### ⚠️ HINWEIS: Application-Healthstatus `Missing` geändert

`Missing` erscheint ab 3.4 nur noch, wenn **alle** Ressourcen einer Application fehlen (vor dem ersten Sync). Einzelne fehlende Ressourcen werden künftig im Sync-Status, nicht im Health-Status angezeigt.

Mögliche Auswirkung: Bestehende Apps können kurz einen abweichenden Health-Status zeigen, normalisieren sich nach dem ersten Refresh automatisch.

#### ✅ UNBETROFFEN: gRPC DNS-Verhalten

`GRPC_ENABLE_TXT_SERVICE_CONFIG` wechselt auf `false` (Default). Betrifft nur TXT-basierte gRPC-Service-Konfiguration — in dieser Umgebung nicht genutzt.

#### ✅ UNBETROFFEN: Dex `ContinueOnConnectorFailure`

Dex 2.45.0 aktiviert `ContinueOnConnectorFailure` standardmäßig. Dex ist in dieser Umgebung kein primärer Auth-Provider — kein Handlungsbedarf.

#### ✅ UNBETROFFEN: Custom Health Checks (Ingress/IngressRoute)

Der Ingress/IngressRoute-Health-Check in `argocd-cm` bleibt vollständig kompatibel.

#### ✅ UNBETROFFEN: `--server-side --force-conflicts`

Weiterhin erforderlich (seit 3.3) — keine Änderung.

---

### Upgrade-Befehl

```bash
kubectl apply -n argocd \
  --server-side \
  --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.1/manifests/install.yaml"

kubectl rollout status deployment/argocd-server              -n argocd --timeout=300s
kubectl rollout status deployment/argocd-repo-server         -n argocd --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
```

### Post-3.4 Verifikation

```bash
# Version bestätigen
kubectl get deployment argocd-server -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Erwartung: quay.io/argoproj/argocd:v3.4.1

# Alle Apps Synced/Healthy?
kubectl get applications -n argocd \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}'

# Cluster-Generator-Labels prüfen (Versionsformat)
kubectl get applicationsets -n argocd -o yaml | grep "kubernetes-version"

# Ingress Health Check noch aktiv?
kubectl get cm argocd-cm -n argocd -o yaml | grep -A5 "customizations.health"

# argocd CLI aktualisieren (via brew)
brew upgrade argocd
argocd version --client
```

| Datum | Von | Auf | Ergebnis | Besonderheiten |
|---|---|---|---|---|
| 2026-05-18 | 3.3.9 | 3.4.1 | ✅ | Kein Handlungsbedarf; CLI via brew (3.4.2) |

---

## Phase 10: Patch-Hop 3.4.2 → 3.4.3

**Durchgeführt:** 2026-06-14  
**Status:** ✅ Erfolgreich

Patch-Release — kein Breaking Change. Enthält Security-Fix für dompurify (CVE-2026-41240) und diverse Bugfixes (Race Condition im Application Controller, nil-pointer in gitops-engine, `app wait` Verhalten).

```bash
kubectl apply -n argocd \
  --server-side \
  --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.3/manifests/install.yaml"

kubectl rollout status deployment/argocd-server              -n argocd --timeout=300s
kubectl rollout status deployment/argocd-repo-server         -n argocd --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s

# Version bestätigen
kubectl get deployment argocd-server -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Erwartung: quay.io/argoproj/argocd:v3.4.3

# CLI (via brew, sobald Paket verfügbar)
brew upgrade argocd
argocd version --client
```

---

## Troubleshooting: Alle Apps `Unknown` nach ArgoCD-Upgrade

**Symptom:** Nach einem ArgoCD-Upgrade zeigen alle oder viele Apps den Sync-Status `Unknown` (aber `Healthy`). In den App-Conditions steht:

```
Failed to load target state: failed to generate manifest for source 1 of 1:
rpc error: code = Unknown desc = failed to list refs:
ssh: handshake failed: knownhosts: key is unknown
```

**Ursache:** ArgoCD-Upgrades via `kubectl apply` setzen die `argocd-ssh-known-hosts-cm` auf den Installations-Default zurück. Der Default enthält nur GitHub, GitLab, Bitbucket und Azure DevOps — **nicht** `git.reckeweg.io`. ArgoCD kann dann nicht mehr auf das Gitea-Repo zugreifen.

**Henne-Ei-Problem:** Der Key liegt in `gitops/config/argocd/argocd-ssh-known-hosts-cm.yaml` im Git-Repo — aber ArgoCD kann ihn nicht aus Git laden, weil der Key für den Git-Zugriff fehlt. Der Cluster steckt fest.

> **Passiert:** 2026-06-14 nach dem Upgrade auf v3.4.3

### Notfall-Fix

```bash
# Schritt 1: Aktuellen Key von Gitea scannen und in den ConfigMap patchen
GITEA_KEYS=$(ssh-keyscan git.reckeweg.io 2>/dev/null | grep -v "^#")
CURRENT=$(kubectl get configmap argocd-ssh-known-hosts-cm -n argocd \
  -o jsonpath='{.data.ssh_known_hosts}')
NEW_CONTENT="${CURRENT}
${GITEA_KEYS}"
kubectl patch configmap argocd-ssh-known-hosts-cm -n argocd \
  --type merge \
  -p "{\"data\":{\"ssh_known_hosts\":$(echo "$NEW_CONTENT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}}"

# Schritt 2: Repo-Server neustarten damit er den neuen ConfigMap einliest
kubectl rollout restart deployment -n argocd argocd-repo-server

# Schritt 3: Warten bis alle Apps wieder Synced sind (ca. 30–60s)
kubectl get applications -n argocd \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

**Dauerhafter Fix:** Die Keys liegen in [`gitops/config/argocd/argocd-ssh-known-hosts-cm.yaml`](../../gitops/config/argocd/argocd-ssh-known-hosts-cm.yaml) im Repo. ArgoCD stellt den ConfigMap nach dem Notfall-Fix automatisch aus Git wieder her — aber das Henne-Ei-Problem bleibt: **Beim nächsten Upgrade muss der Notfall-Fix erneut ausgeführt werden**, bevor ArgoCD den Fix aus Git laden kann.
