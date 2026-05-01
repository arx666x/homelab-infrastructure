# Longhorn Upgrade Runbook: 1.5.3 → 1.7.3

**Cluster:** homelab-infrastructure (seri-k8s)  
**Methode:** ArgoCD / GitOps (`gitops/apps/longhorn.yaml`)  
**Zielversion:** 1.7.3 (stable branch)  
**Upgrade-Pfad:** `1.5.3 → 1.6.2 → 1.7.3` (zwei Hops, Minor-Version für Minor-Version)  
**Durchgeführt am:** 2026-04-30

---

## Kontext & Entscheidungen

### Warum 1.7.3 und nicht 1.6.x direkt?

1.7.3 ist der aktuelle letzte Patch der stabilen 1.7.x-Linie. Das Ziel ist direkt dort zu landen.
Der Upgrade-Pfad erfordert aber einen Zwischenstopp bei **1.6.x** (Longhorn erlaubt keine Überbrückung
zweier Minor-Versionen — der interne `upgradeVersionCheck` blockiert das).

Zwischenstopp: **1.6.2** (letzter gut getesteter Patch von 1.6.x).

### Was ändert sich relevant?

| Bereich | 1.5.3 → 1.6.x | 1.6.x → 1.7.x |
|---------|---------------|----------------|
| Engine-Upgrade nach Helm-Upgrade | Manuell über UI erforderlich | Manuell über UI erforderlich |
| CSI Snapshot CRDs | v1beta1 deprecated → nur noch v1 | — |
| `backendStoreDriver` → `dataEngine` | Umbenennung in StorageClass-Parametern | — |
| RecurringJob deprecated fields in Volume Spec | Entfernt in 1.7.0 | — |
| Node Drain Policy neue Optionen | Neue Settings sichtbar | — |
| Longhorn CLI | Nicht vorhanden | Neu in 1.7.0, ersetzt environment check script |
| `preUpgradeChecker.jobEnabled` | War auf `false` gesetzt — **beachten** | — |

> ⚠️ **Wichtig zu `preUpgradeChecker.jobEnabled: false`**  
> Diese Einstellung war in der bestehenden Config aktiv gesetzt. Das bedeutet, der automatische  
> Pre-Upgrade-Check läuft **nicht**. Für dieses Upgrade muss der Checker manuell ersetzt werden  
> (Pre-Flight Checks von Hand durchführen, s. unten). Für 1.6+ diese Option entfernen.

### Hinweis: Helm kennt den Release nicht

Longhorn wurde via ArgoCD mit `ServerSideApply` installiert — Helm hat keinen eigenen
Release-State. Die folgenden Kommandos liefern daher keine nützlichen Ergebnisse:

```bash
helm list -n longhorn-system      # → leer
helm history longhorn -n longhorn-system  # → Error: release not found
```

Den Versions-Check stattdessen über die Pod-Images machen (s. Validierung).

---

## Pre-Flight Checks (vor jedem Upgrade-Hop)

```bash
# 1. Alle Volumes müssen healthy sein
kubectl get volumes.longhorn.io -n longhorn-system \
  -o custom-columns="NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness"
# Erwartung: alle state=attached|detached, robustness=healthy

# 2. Keine degradierten Volumes
kubectl get volumes.longhorn.io -n longhorn-system -o json | \
  jq -r '.items[] | select(.status.robustness != "healthy") | .metadata.name'
# Erwartung: leere Ausgabe

# 3. Alle Longhorn-Pods laufen
kubectl get pods -n longhorn-system | grep -v Running | grep -v Completed
# Erwartung: leere Ausgabe

# 4. Engine-Format prüfen (altes Format -e-xxxxxxxx wäre ein HOLD für 1.7.x)
kubectl -n longhorn-system get engines.longhorn.io -o name
# Erwartung: Format pvc-<uuid>-e-0 (neues Format) → Safe
# HOLD wenn: Format pvc-<uuid>-e-<8-char-random> (altes Format aus pre-1.5.2)

# 5. Aktuellen State der Settings sichern
kubectl get settings.longhorn.io -n longhorn-system -o yaml > \
  longhorn-settings-backup-$(date +%Y%m%d).yaml

# 6. System-Backup triggern
kubectl apply -f - <<YAML
apiVersion: longhorn.io/v1beta2
kind: SystemBackup
metadata:
  name: pre-upgrade-$(date +%Y%m%d)
  namespace: longhorn-system
spec:
  volumeBackupPolicy: if-not-present
YAML

# 7. Warten bis SystemBackup completed
kubectl get systembackup -n longhorn-system -w
# Erwartung: STATE=Ready
```

> **Praxis-Erfahrung:** Das Engine-Format lässt sich nicht zuverlässig per Regex in einem
> One-Liner prüfen (macOS sed/grep Unterschiede). Einfach `kubectl get engines.longhorn.io -o name`
> ausgeben und visuell prüfen ob alle Engines auf `-e-0` enden.

---

## Hop 1: 1.5.3 → 1.6.2

### 1.1 ArgoCD Auto-Sync deaktivieren

```bash
kubectl patch application longhorn -n argocd \
  --type=json \
  -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
# Prüfen: App wird in ArgoCD UI als "OutOfSync" ohne Auto-Sync angezeigt
```

### 1.2 `gitops/apps/longhorn.yaml` anpassen (macOS sed)

```bash
# targetRevision erhöhen
sed -i '' 's/targetRevision: "1.5.3"/targetRevision: "1.6.2"/' gitops/apps/longhorn.yaml

# preUpgradeChecker entfernen
sed -i '' '/preUpgradeChecker:/,/jobEnabled: false/d' gitops/apps/longhorn.yaml

# Prüfen — Erwartung: nur noch targetRevision: "1.6.2", keine preUpgradeChecker-Zeilen
grep -n "targetRevision\|preUpgradeChecker\|jobEnabled" gitops/apps/longhorn.yaml
```

```bash
git add gitops/apps/longhorn.yaml
git commit -m "chore: longhorn upgrade hop1 1.5.3 → 1.6.2, remove preUpgradeChecker"
git push
```

### 1.3 Sync auslösen und Rollout beobachten

ArgoCD UI → App `longhorn` → **Sync** (keine zusätzlichen Optionen nötig).

```bash
# DaemonSet Rollout verfolgen
kubectl rollout status daemonset/longhorn-manager -n longhorn-system
# Erwartung: "daemon set "longhorn-manager" successfully rolled out"

# Alle Manager-Pods auf neuer Version?
kubectl get pods -n longhorn-system -l app=longhorn-manager \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
# Erwartung: alle Pods zeigen longhornio/longhorn-manager:v1.6.2

# Pre/Post-Upgrade Jobs prüfen
kubectl get jobs -n longhorn-system
# Erwartung: longhorn-pre-upgrade und longhorn-post-upgrade mit STATUS=Complete
```

### 1.4 Engine-Upgrade

Nach erfolgreichem Manager-Rollout muss das Engine Image auf alle Volumes angewendet werden.

```bash
# Verfügbare Engine Images prüfen
kubectl get engineimage -n longhorn-system
# Erwartung: neues ei-xxxxxxxx für v1.6.2 mit STATE=deployed, REFCOUNT=0
#            altes ei-xxxxxxxx für v1.5.3 mit REFCOUNT=60 (12 Volumes × 5 Replicas)
```

**Im Longhorn UI** (`https://longhorn.reckeweg.io`):
```
Volume-Tab → alle Volumes auswählen → "Upgrade Engine" → v1.6.2 wählen → Bestätigen
```

> ⚠️ **Praxis-Erfahrung:** Das UI-Upgrade kann einzelne Volumes überspringen, besonders
> aktiv beschriebene Volumes (Postgres, Prometheus). Immer nachprüfen!

```bash
# Fortschritt beobachten
kubectl get engineimage -n longhorn-system -w
# Ziel: v1.5.3 REFCOUNT=0, v1.6.2 REFCOUNT=60

# Welche Engines hängen noch auf der alten Version?
kubectl get engines.longhorn.io -n longhorn-system \
  -o custom-columns="NAME:.metadata.name,IMAGE:.spec.engineImage,CURRENT:.status.currentImage" \
  | grep "v1.5.3"

# Details für hängende Engines (spec.engineImage="" bedeutet: Upgrade nicht beauftragt)
kubectl get engines.longhorn.io -n longhorn-system -o json | \
  jq -r '.items[] | select(.status.currentImage | contains("v1.5.3")) |
  {name: .metadata.name, specImage: .spec.engineImage, currentImage: .status.currentImage}'
```

> **Praxis-Erfahrung:** Wenn `specImage: ""` — das Upgrade wurde für diese Volumes gar nicht
> beauftragt. Im UI nochmals explizit für diese Volumes triggern. Alternativ per kubectl:

```bash
# Neues default Engine Image ermitteln
NEW_EI=$(kubectl -n longhorn-system get engineimage \
  -o jsonpath='{.items[?(@.status.default==true)].spec.image}')
echo "Target: $NEW_EI"

# Einzelne Engine manuell patchen
kubectl -n longhorn-system patch engines.longhorn.io <engine-name> \
  --type=merge -p "{\"spec\":{\"engineImage\":\"${NEW_EI}\"}}"
```

### 1.5 Validierung nach Hop 1

```bash
# Manager-Version bestätigen
kubectl get pods -n longhorn-system -l app=longhorn-manager \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'

# Alle Volumes healthy?
kubectl get volumes.longhorn.io -n longhorn-system \
  -o custom-columns="NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness"
# Erwartung: alle attached/healthy

# Engine Images: v1.5.3 auf REFCOUNT=0?
kubectl get engineimage -n longhorn-system
```

> ✅ Wenn alle Volumes `healthy` und v1.5.3 auf `REFCOUNT: 0` → Hop 1 abgeschlossen.  
> ⏳ Empfehlung: 1–2 Stunden warten und einen Backup-Job abwarten bevor Hop 2 gestartet wird.

---

## Hop 2: 1.6.2 → 1.7.3

### Pre-Flight Checks wiederholen (s. oben)

Engine-Format nochmals prüfen:
```bash
kubectl -n longhorn-system get engines.longhorn.io -o name
# Erwartung: alle enden auf -e-0 → Safe to upgrade to 1.7.x
```

### 2.1 `gitops/apps/longhorn.yaml` anpassen

```bash
sed -i '' 's/targetRevision: "1.6.2"/targetRevision: "1.7.3"/' gitops/apps/longhorn.yaml

grep -n "targetRevision" gitops/apps/longhorn.yaml
# Erwartung: targetRevision: "1.7.3"

git add gitops/apps/longhorn.yaml
git commit -m "chore: longhorn upgrade hop2 1.6.2 → 1.7.3"
git push
```

### 2.2 Sync auslösen und Rollout beobachten

ArgoCD UI → App `longhorn` → **Sync**.

```bash
kubectl rollout status daemonset/longhorn-manager -n longhorn-system

kubectl get pods -n longhorn-system -l app=longhorn-manager \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
# Erwartung: alle Pods zeigen longhornio/longhorn-manager:v1.7.3
```

### 2.3 Engine Image abwarten

Das neue Engine Image v1.7.3 wird lazy deployed und erscheint erst nach 1–2 Minuten:

```bash
kubectl get engineimage -n longhorn-system -w
# Erst STATE=deploying, dann STATE=deployed
# Erst wenn deployed → Engine-Upgrade im UI starten
```

### 2.4 Engine-Upgrade (wie Hop 1)

```bash
# Fortschritt beobachten
kubectl get engineimage -n longhorn-system -w
# Ziel: v1.6.2 REFCOUNT=0, v1.7.3 REFCOUNT=60
```

Bei hängenden Volumes wieder:
```bash
kubectl get engines.longhorn.io -n longhorn-system \
  -o custom-columns="NAME:.metadata.name,IMAGE:.spec.engineImage,CURRENT:.status.currentImage" \
  | grep "v1.6.2"

kubectl get engines.longhorn.io -n longhorn-system -o json | \
  jq -r '.items[] | select(.status.currentImage | contains("v1.6.2")) |
  {name: .metadata.name, specImage: .spec.engineImage, currentImage: .status.currentImage}'
```

### 2.5 Abschlussvalidierung

```bash
# Manager-Version
kubectl get pods -n longhorn-system -l app=longhorn-manager \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'

# Alle Volumes healthy
kubectl get volumes.longhorn.io -n longhorn-system \
  -o custom-columns="NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness"

# Engine Images finaler State
kubectl get engineimage -n longhorn-system
# Erwartung:
# v1.5.3  REFCOUNT=0
# v1.6.2  REFCOUNT=0
# v1.7.3  REFCOUNT=60

# RecurringJobs laufen?
kubectl get recurringjob -n longhorn-system

# SystemBackups vorhanden?
kubectl get systembackup -n longhorn-system
```

### 2.6 Longhorn CLI (neu in 1.7.0)

```bash
kubectl run longhorn-cli --rm -it \
  --image=longhornio/longhorn-cli:v1.7.3 \
  --restart=Never \
  -n longhorn-system \
  -- check
```

---

## Auto-Sync wieder aktivieren

```bash
kubectl patch application longhorn -n argocd \
  --type=merge \
  -p='{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

---

## ArgoCD OutOfSync nach Upgrade

Nach dem Upgrade zeigt ArgoCD `resources: {}` Drift für Longhorn DaemonSet und Deployments.
Das ist harmlos — Longhorn schreibt diese Felder zur Laufzeit zurück.

Fix: `ignoreDifferences` in `gitops/apps/longhorn.yaml` ergänzen:

```yaml
  ignoreDifferences:
    # ... bestehende Einträge ...
    - group: apps
      kind: DaemonSet
      jqPathExpressions:
        - .spec.template.spec.containers[].resources
        - .spec.template.spec.initContainers[].resources
    - group: apps
      kind: Deployment
      jqPathExpressions:
        - .spec.template.spec.containers[].resources
        - .spec.template.spec.initContainers[].resources
```

> **Hinweis:** `jqPathExpressions` mit `[]` deckt alle Container-Indizes ab — besser als
> `jsonPointers` mit hartkodiertem Index (`/0`, `/1`, ...).

---

## Rollback-Strategie

> ⚠️ Longhorn unterstützt **kein offizielles Downgrade**. Wenn Engine-Datenstrukturen
> bereits migriert wurden, ist ein Rollback nicht möglich.

- Settings-Backup vorhanden: `longhorn-settings-backup-<datum>.yaml`
- SystemBackup vorhanden: `pre-upgrade-<datum>` (STATE=Ready bestätigt)
- Im Worst-Case: Restore aus NFS-Backup (`nfs://192.168.11.55:/volume1/longhorn-backup`)

---

## Notes zu den bestehenden Backup-Jobs

Die RecurringJob CRs (`daily-incremental-backup`, `weekly-full-backup`) und der
`longhorn-system-backup` CronJob sind mit `apiVersion: longhorn.io/v1beta2` deklariert —
kompatibel mit 1.6.x und 1.7.x, keine Änderungen erforderlich.

---

## Zeitplan (tatsächlich benötigt: 2026-04-30)

| Schritt | Dauer |
|---------|-------|
| Pre-Flight + SystemBackup | 15 min |
| Hop 1 (1.5.3 → 1.6.2) Rollout | 15 min |
| Engine-Upgrade Hop 1 (inkl. Debug hängender Volumes) | 75 min |
| Hop 2 (1.6.2 → 1.7.3) Rollout | 15 min |
| Engine-Upgrade Hop 2 | 20 min |
| ArgoCD ignoreDifferences bereinigen | 15 min |
| **Gesamt** | **~2.5h** |
