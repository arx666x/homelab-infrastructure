# Longhorn Upgrade Runbook: 1.5.3 → 1.11.1

**Cluster:** homelab-infrastructure (seri-k8s)  
**Methode:** ArgoCD / GitOps (`gitops/apps/longhorn.yaml`)  
**Upgrade-Pfad:** `1.5.3 → 1.6.2 → 1.7.3 → 1.8.2 → 1.9.2 → 1.10.2 → 1.11.1` (sechs Hops)  
**Durchgeführt:** 2026-04-30 (1.5.3→1.7.3) und 2026-05-03 (1.7.3→1.11.1)

---

## Grundregeln

- Longhorn erlaubt nur Upgrades von der jeweils vorherigen Minor-Version — kein Überspringen
- **Helm kennt den Release nicht** — Longhorn wurde via ArgoCD `ServerSideApply` installiert, `helm list` und `helm history` liefern keine Ergebnisse. Version immer über Pod-Images prüfen
- **macOS sed** — immer `sed -i ''` (mit leerem String), nicht `sed -i`
- **Engine Image lazy deployed** — nach dem Manager-Rollout dauert es 1–2 Minuten bis das neue Engine Image als `deployed` erscheint. Erst dann Engine-Upgrade im UI starten
- **UI überspringt Volumes** — besonders Postgres- und Prometheus-Volumes werden beim Engine-Upgrade gern übersprungen (`specImage: ""`). Immer mit `jq`-Abfrage nachprüfen
- **V2 Data Engine:** Dieser Cluster nutzt ausschließlich V1. Alle Hinweise zu V2 (Hugepage, SPDK, UBLK) sind nicht relevant

---

## Wiederverwendbare Kommandos

```bash
# Volumes: alle healthy?
kubectl get volumes.longhorn.io -n longhorn-system \
  -o custom-columns="NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness"

# Pods: alle Running?
kubectl get pods -n longhorn-system | grep -v Running | grep -v Completed

# Engine Images: welche Version hat welchen REFCOUNT?
kubectl get engineimage -n longhorn-system

# Manager-Version bestätigen
kubectl get pods -n longhorn-system -l app=longhorn-manager \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'

# Hängende Engines auf alter Version — Details
kubectl get engines.longhorn.io -n longhorn-system -o json | \
  jq -r '.items[] | select(.spec.engineImage != .status.currentImage or .spec.engineImage == "") |
  {name: .metadata.name, spec: .spec.engineImage, current: .status.currentImage}'

# Longhorn Nodes Status
kubectl get nodes.longhorn.io -n longhorn-system
```

---

## Pre-Flight Checks (vor dem ersten Hop)

```bash
# 1. Alle Volumes healthy
kubectl get volumes.longhorn.io -n longhorn-system \
  -o custom-columns="NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness"

# 2. Keine degradierten Volumes
kubectl get volumes.longhorn.io -n longhorn-system -o json | \
  jq -r '.items[] | select(.status.robustness != "healthy") | .metadata.name'
# Erwartung: leer

# 3. Alle Pods laufen
kubectl get pods -n longhorn-system | grep -v Running | grep -v Completed
# Erwartung: leer

# 4. Engine-Format prüfen (HOLD wenn altes Format -e-xxxxxxxx)
kubectl -n longhorn-system get engines.longhorn.io -o name
# Erwartung: alle enden auf -e-0

# 5. CRD stored versions prüfen (relevant vor 1.10)
kubectl get crds -o json | \
  jq -r '.items[] | select(.metadata.name | contains("longhorn")) |
  select(.status.storedVersions[] | contains("v1beta1")) |
  .metadata.name'
# Erwartung: leer

# 6. Settings sichern
kubectl get settings.longhorn.io -n longhorn-system -o yaml > \
  longhorn-settings-backup-$(date +%Y%m%d).yaml

# 7. System-Backup triggern
kubectl apply -f - <<YAML
apiVersion: longhorn.io/v1beta2
kind: SystemBackup
metadata:
  name: pre-upgrade-$(date +%Y%m%d)
  namespace: longhorn-system
spec:
  volumeBackupPolicy: if-not-present
YAML

kubectl get systembackup -n longhorn-system -w
# Warten bis STATE=Ready

# 8. ArgoCD Auto-Sync deaktivieren
kubectl patch application longhorn -n argocd \
  --type=json \
  -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
```

---

## Standard-Ablauf pro Hop

Jeder Hop folgt demselben Muster:

### 1. targetRevision anpassen

```bash
sed -i '' 's/targetRevision: "ALT"/targetRevision: "NEU"/' gitops/apps/longhorn.yaml
grep -n "targetRevision" gitops/apps/longhorn.yaml

git add gitops/apps/longhorn.yaml
git commit -m "chore: longhorn upgrade hopX ALT → NEU"
git push
```

### 2. Sync & Rollout

ArgoCD UI → App `longhorn` → **Sync** (keine weiteren Optionen).

```bash
kubectl rollout status daemonset/longhorn-manager -n longhorn-system
# Erwartung: "daemon set "longhorn-manager" successfully rolled out"

kubectl get pods -n longhorn-system -l app=longhorn-manager \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
# Erwartung: alle Pods → longhornio/longhorn-manager:vNEU

kubectl get jobs -n longhorn-system | grep -E "pre-upgrade|post-upgrade"
# Erwartung: Complete
```

### 3. Engine Image abwarten

```bash
kubectl get engineimage -n longhorn-system -w
# Warten bis neue Version STATE=deployed
```

### 4. Engine-Upgrade im UI

Longhorn UI → `https://longhorn.reckeweg.io` → Volume-Tab → alle auswählen → **Upgrade Engine** → neue Version

```bash
# Fortschritt beobachten
kubectl get engineimage -n longhorn-system -w
# Ziel: alte Version REFCOUNT=0, neue Version REFCOUNT=60

# Hängende Volumes prüfen
kubectl get engines.longhorn.io -n longhorn-system -o json | \
  jq -r '.items[] | select(.status.currentImage | contains("vALT")) |
  {name: .metadata.name, specImage: .spec.engineImage, currentImage: .status.currentImage}'
# Falls specImage="" → nochmals im UI für diese Volumes triggern
```

### 5. Validierung

```bash
kubectl get volumes.longhorn.io -n longhorn-system \
  -o custom-columns="NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness"
kubectl get engineimage -n longhorn-system
# Ziel: alte Version REFCOUNT=0, neue Version REFCOUNT=60, alle Volumes healthy
```

---

## Hop 1: 1.5.3 → 1.6.2

**Zusätzlich:** `preUpgradeChecker.jobEnabled: false` aus der Config entfernen:

```bash
sed -i '' 's/targetRevision: "1.5.3"/targetRevision: "1.6.2"/' gitops/apps/longhorn.yaml
sed -i '' '/preUpgradeChecker:/,/jobEnabled: false/d' gitops/apps/longhorn.yaml
grep -n "targetRevision\|preUpgradeChecker\|jobEnabled" gitops/apps/longhorn.yaml
# Erwartung: nur targetRevision: "1.6.2", keine preUpgradeChecker-Zeilen

git add gitops/apps/longhorn.yaml
git commit -m "chore: longhorn upgrade hop1 1.5.3 → 1.6.2, remove preUpgradeChecker"
git push
```

Dann Standard-Ablauf: Sync → Rollout → Engine-Upgrade → Validierung.

---

## Hop 2: 1.6.2 → 1.7.3

Standard-Ablauf mit `sed -i '' 's/1.6.2/1.7.3/'`.

---

## Hop 3: 1.7.3 → 1.8.2

Standard-Ablauf mit `sed -i '' 's/1.7.3/1.8.2/'`.

---

## Hop 4: 1.8.2 → 1.9.2

> ℹ️ v1.9.0 und v1.9.1 haben bekannte Bugs im longhorn-manager — direkt 1.9.2 verwenden.

Standard-Ablauf mit `sed -i '' 's/1.8.2/1.9.2/'`.

**Nach dem Engine-Upgrade:** CRD-Check vor Hop 5 durchführen:

```bash
kubectl get crds -o json | \
  jq -r '.items[] | select(.metadata.name | contains("longhorn")) |
  select(.status.storedVersions[] | contains("v1beta1")) |
  .metadata.name'
# Erwartung: leer → safe for 1.10
# Falls nicht leer: siehe Abschnitt "CRD-Migration" am Ende
```

---

## Hop 5: 1.9.2 → 1.10.2

> ⚠️ v1.10.0 hat einen bekannten Bug (nil pointer dereference) — direkt 1.10.2 verwenden.  
> v1beta1 wird in 1.10 vollständig entfernt.

Standard-Ablauf mit `sed -i '' 's/1.9.2/1.10.2/'`.

### ⚠️ Bekanntes Problem: Volume-Felder fehlen (CRD-Timing-Bug)

Der 1.10.2 Manager kennt neue Volume-Felder (`backupBlockSize`, `replicaRebuildingBandwidthLimit`)
die in bestehenden Volume-Objekten noch nicht vorhanden sind. Das führt zu einem CrashLoop:

```
strict decoding error: unknown field "spec.backupBlockSize"
```

**Fix — sofort nach dem Sync ausführen (Webhooks müssen weg sein):**

```bash
# Webhooks löschen
kubectl delete mutatingwebhookconfiguration longhorn-webhook-mutator 2>/dev/null || true
kubectl delete validatingwebhookconfiguration longhorn-webhook-validator 2>/dev/null || true

# Alle Volumes mit korrekten Feldwerten patchen
for vol in $(kubectl get volumes.longhorn.io -n longhorn-system -o name); do
  kubectl patch $vol -n longhorn-system \
    --type=json \
    -p '[{"op":"add","path":"/spec/backupBlockSize","value":"2097152"},
        {"op":"add","path":"/spec/replicaRebuildingBandwidthLimit","value":0}]'
  echo "Patched: $vol"
done
```

Korrekte Werte:
- `backupBlockSize`: `"2097152"` (2MB Default) oder `"16777216"` (16MB)
- `replicaRebuildingBandwidthLimit`: Integer `0` (= unlimited), **nicht** String

```bash
# Manager beobachten — sollte jetzt stabil werden
kubectl get pods -n longhorn-system -l app=longhorn-manager -w
```

Falls der Manager wegen `guaranteed-instance-manager-cpu` crasht:
```bash
kubectl -n longhorn-system get setting guaranteed-instance-manager-cpu -o jsonpath='{.value}'
# Muss "12" sein — wenn "0":
kubectl -n longhorn-system patch setting guaranteed-instance-manager-cpu \
  --type=merge -p '{"value":"12"}'
```

---

## Hop 6: 1.10.2 → 1.11.1

> ℹ️ v1.11.0 hatte kritische Bugs (memory leak im instance-manager, Node Validator Regression) — direkt 1.11.1 verwenden.

Standard-Ablauf mit `sed -i '' 's/1.10.2/1.11.1/'`.

### ⚠️ Bekanntes Problem: Node-Status-Feld fehlt in CRD (CRD-Timing-Bug)

Der 1.11.1 Manager kennt das neue Node-Status-Feld `healthDataLastCollectedAt` nicht
in der alten CRD-Definition. Das führt zu einem CrashLoop:

```
strict decoding error: unknown field "status.diskStatus.<disk-id>.healthDataLastCollectedAt"
```

**Fix — Longhorn Node-Objekte komplett löschen und neu anlegen lassen:**

```bash
# Schritt 1: Webhooks löschen
kubectl delete mutatingwebhookconfiguration longhorn-webhook-mutator 2>/dev/null || true
kubectl delete validatingwebhookconfiguration longhorn-webhook-validator 2>/dev/null || true

# Schritt 2: Node-Status bereinigen (Feld via Raw API entfernen)
for node in $(kubectl get nodes.longhorn.io -n longhorn-system -o name | sed 's|node.longhorn.io/||'); do
  echo "Processing $node..."
  kubectl get node.longhorn.io/$node -n longhorn-system -o json | \
    jq 'del(.status.diskStatus[].healthDataLastCollectedAt)' | \
    kubectl replace --raw \
      /apis/longhorn.io/v1beta2/namespaces/longhorn-system/nodes/$node/status \
      -f -
done

# Schritt 3: Prüfen ob Feld wirklich weg ist
kubectl get nodes.longhorn.io -n longhorn-system -o json | \
  jq '.items[] | {node: .metadata.name, hasField: (.status.diskStatus[].healthDataLastCollectedAt != null)}'
# Erwartung: alle hasField: false
```

Falls das Feld hartnäckig bleibt (etcd-Cache) → Longhorn Node-Objekte komplett löschen:

```bash
# Finalizers entfernen damit delete nicht hängt
for node in $(kubectl get nodes.longhorn.io -n longhorn-system -o name); do
  kubectl patch $node -n longhorn-system \
    --type=json \
    -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
done

# Alle Nodes löschen — Manager erstellt sie beim Start neu (ohne das problematische Feld)
kubectl delete nodes.longhorn.io -n longhorn-system --all --force --grace-period=0
```

Falls der Manager trotzdem nicht startet → `upgradeVersionCheck: false` temporär setzen:

```bash
# In gitops/apps/longhorn.yaml unter dem root-level helm values hinzufügen:
#   upgradeVersionCheck: false

git add gitops/apps/longhorn.yaml
git commit -m "fix: disable upgradeVersionCheck temporarily for 1.11.1 upgrade"
git push
# ArgoCD sync → Manager sollte jetzt starten
```

**Nach erfolgreichem Start wieder entfernen:**

```bash
sed -i '' '/upgradeVersionCheck: false/d' gitops/apps/longhorn.yaml
sed -i '' '/# Temporär für Upgrade/d' gitops/apps/longhorn.yaml
git add gitops/apps/longhorn.yaml
git commit -m "fix: re-enable upgradeVersionCheck after 1.11.1 upgrade"
git push
```

### Nach dem Upgrade: Volumes erholen sich selbst

Nach dem Node-Delete-Workaround können Volumes kurzzeitig `degraded` oder `detached` erscheinen.
Das ist normal — Longhorn rebuildet Replicas automatisch. Einfach beobachten:

```bash
kubectl get volumes.longhorn.io -n longhorn-system \
  -o custom-columns="NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness" -w
# Alle Volumes kehren binnen 10–30 Minuten zu healthy zurück
```

---

## Abschluss

### Auto-Sync wieder aktivieren

```bash
kubectl patch application longhorn -n argocd \
  --type=merge \
  -p='{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

### Abschlussvalidierung

```bash
# Manager-Version
kubectl get pods -n longhorn-system -l app=longhorn-manager \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'

# Alle Volumes healthy
kubectl get volumes.longhorn.io -n longhorn-system \
  -o custom-columns="NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness"

# Engine Images finaler State
kubectl get engineimage -n longhorn-system
# Erwartung: alle alten Versionen REFCOUNT=0, v1.11.1 REFCOUNT=60

# Nodes alle Ready
kubectl get nodes.longhorn.io -n longhorn-system

# RecurringJobs laufen?
kubectl get recurringjob -n longhorn-system

# SystemBackups vorhanden?
kubectl get systembackup -n longhorn-system
```

### ArgoCD OutOfSync (resources: {})

Nach dem Upgrade zeigt ArgoCD `resources: {}` Drift — harmlos, Longhorn schreibt diese Felder
zur Laufzeit zurück. Fix in `gitops/apps/longhorn.yaml`:

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

---

## Anhang: CRD-Migration (nur falls v1beta1 noch vorhanden)

Falls nach Hop 4 noch v1beta1 storedVersions gefunden werden:

```bash
# Betroffene CRDs anzeigen
kubectl get crds -o json | \
  jq -r '.items[] | select(.metadata.name | contains("longhorn")) |
  select(.status.storedVersions[] | contains("v1beta1")) |
  .metadata.name'

# storedVersions auf v1beta2 setzen
kubectl patch crd engines.longhorn.io --type=json \
  -p='[{"op":"replace","path":"/status/storedVersions","value":["v1beta2"]}]' \
  --subresource=status

# Storage-Migration triggern
kubectl get engines.longhorn.io -n longhorn-system -o json | kubectl apply -f -
```

---

## Anhang: Rollback-Strategie

> ⚠️ Kein offizielles Downgrade möglich sobald Engine-Datenstrukturen migriert wurden.

- Settings-Backup: `longhorn-settings-backup-<datum>.yaml`
- SystemBackup: `pre-upgrade-<datum>` (STATE=Ready)
- NFS-Backup: `nfs://192.168.11.55:/volume1/longhorn-backup`

---

## Zeitplan (tatsächlich benötigt)

| Hop | Datum | Dauer |
|-----|-------|-------|
| Hop 1: 1.5.3 → 1.6.2 | 2026-04-30 | ~90 min (inkl. Debug hängender Volumes) |
| Hop 2: 1.6.2 → 1.7.3 | 2026-04-30 | ~35 min |
| Hop 3: 1.7.3 → 1.8.2 | 2026-05-03 | ~45 min |
| Hop 4: 1.8.2 → 1.9.2 | 2026-05-03 | ~45 min |
| Hop 5: 1.9.2 → 1.10.2 | 2026-05-03 | ~90 min (inkl. Volume-Feld-Bug) |
| Hop 6: 1.10.2 → 1.11.1 | 2026-05-03 | ~120 min (inkl. Node-Status-Bug) |
| **Gesamt** | | **~7h** |
