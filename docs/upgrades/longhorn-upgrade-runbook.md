# Longhorn Upgrade Runbook: 1.5.3 → 1.7.3

**Cluster:** homelab-infrastructure (seri-k8s)  
**Methode:** ArgoCD / GitOps (`gitops/apps/longhorn.yaml`)  
**Zielversion:** 1.7.3 (stable branch)  
**Upgrade-Pfad:** `1.5.3 → 1.6.x → 1.7.3` (zwei Hops, Minor-Version für Minor-Version)

---

## Kontext & Entscheidungen

### Warum 1.7.3 und nicht 1.6.x direkt?

1.7.3 ist der aktuelle letzte Patch der stabilen 1.7.x-Linie. Das Ziel ist direkt dort zu landen.
Der Upgrade-Pfad erfordert aber einen Zwischenstopp bei **1.6.x** (Longhorn erlaubt keine Überbrückung
zweier Minor-Versionen — der interne `upgradeVersionCheck` blockiert das).

Empfohlener Zwischenstopp: **1.6.2** (letzter gut getesteter Patch von 1.6.x).

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
> (Pre-Flight Checks von Hand durchführen, s. unten). Für 1.6+ wäre es sinnvoll, diese Option  
> wieder auf `true` zu setzen oder ganz zu entfernen.

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

# 4. Engine-Check (relevant für Hop 1 → 1.7.0 workaround war für ältere engines)
# Engine-Namen im alten Format prüfen (relevant wenn Volumes aus pre-1.5.2 existieren)
[ $(kubectl -n longhorn-system get engines.longhorn.io -o name | \
  grep -E '\-e\-[a-z0-9]{8}$' | wc -l) -gt 0 ] \
  && echo "HOLD: alte Engine-Namen gefunden!" \
  || echo "OK: Engine-Namen kompatibel"

# 5. Aktuellen State der Settings sichern
kubectl get settings.longhorn.io -n longhorn-system -o yaml > \
  longhorn-settings-backup-$(date +%Y%m%d).yaml

# 6. System-Backup triggern (manuell, vor dem Upgrade)
kubectl apply -f - <<YAML
apiVersion: longhorn.io/v1beta2
kind: SystemBackup
metadata:
  name: pre-upgrade-$(date +%Y%m%d)
  namespace: longhorn-system
spec:
  volumeBackupPolicy: if-not-present
YAML

# Warten bis SystemBackup completed
kubectl get systembackup -n longhorn-system -w
```

---

## Hop 1: 1.5.3 → 1.6.2

### 1.1 ArgoCD Auto-Sync temporär deaktivieren

Im Longhorn ArgoCD-App den Auto-Sync deaktivieren, damit der Upgrade kontrolliert läuft:

```bash
# Option A: über ArgoCD UI → App longhorn → Disable Auto-Sync
# Option B: kubectl patch
kubectl patch application longhorn -n argocd \
  --type=json \
  -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
```

### 1.2 `gitops/apps/longhorn.yaml` anpassen

```yaml
# Änderung: targetRevision und values
    targetRevision: "1.6.2"
    helm:
      releaseName: longhorn
      values: |
        defaultSettings:
          backupTarget: "nfs://192.168.11.55:/volume1/longhorn-backup"
          defaultDataPath: "/mnt/longhorn"
          defaultReplicaCount: 3
          guaranteedInstanceManagerCpu: 12
        
        persistence:
          defaultClass: true
          defaultClassReplicaCount: 3
          reclaimPolicy: Delete
        
        # preUpgradeChecker wieder aktivieren ab 1.6.x
        # preUpgradeChecker:
        #   jobEnabled: false   ← ENTFERNEN oder auf true lassen
        
        ingress:
          enabled: true
          ingressClassName: traefik
          host: longhorn.reckeweg.io
          tls: true
          tlsSecret: longhorn-tls
          annotations:
            cert-manager.io/cluster-issuer: letsencrypt-prod
            traefik.ingress.kubernetes.io/router.entrypoints: websecure
```

> Die Zeile `preUpgradeChecker.jobEnabled: false` entfernen oder auskommentieren.  
> Ab 1.6.0 ist der Pre-Upgrade-Checker sinnvoll aktiv zu lassen.

### 1.3 Sync auslösen und beobachten

```bash
# Commit & Push nach Gitea
git add gitops/apps/longhorn.yaml
git commit -m "chore: longhorn upgrade 1.5.3 → 1.6.2"
git push

# ArgoCD manuell syncen
argocd app sync longhorn --prune

# Pods beobachten
kubectl get pods -n longhorn-system -w

# Rollout des DaemonSets beobachten
kubectl rollout status daemonset/longhorn-manager -n longhorn-system
```

### 1.4 Engine-Upgrade über Longhorn UI

Nach erfolgreichem Longhorn Manager Upgrade **müssen** alle Volume-Engines auf die neue
Version aktualisiert werden:

```
Longhorn UI → https://longhorn.reckeweg.io
→ Node → Engine Image Upgrade
→ "Upgrade" für alle Volumes wählen
→ oder: Volume-Liste → alle auswählen → "Upgrade Engine"
```

Alternativ per kubectl (bulk upgrade):

```bash
# Aktuelle Engine-Image-Version ermitteln
NEW_EI=$(kubectl -n longhorn-system get engineimage \
  -o jsonpath='{.items[?(@.status.default==true)].metadata.name}')
echo "New default engine image: $NEW_EI"

# Alle Volumes auf neues Engine Image upgraden
for vol in $(kubectl -n longhorn-system get volumes.longhorn.io -o name); do
  kubectl -n longhorn-system patch $vol \
    --type=merge \
    -p "{\"spec\":{\"engineImage\":\"${NEW_EI}\"}}"
done
```

### 1.5 Validierung nach Hop 1

```bash
# Helm-Version prüfen
helm list -n longhorn-system

# Alle Volumes wieder healthy?
kubectl get volumes.longhorn.io -n longhorn-system \
  -o custom-columns="NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness"

# Engine Images: nur noch die neue Version aktiv?
kubectl get engineimage -n longhorn-system
```

> ✅ Wenn alle Volumes `healthy` und das Engine-Image upgraded ist → weiter mit Hop 2.  
> ⏳ Empfehlung: 1–2 Stunden warten und Backup-Jobs prüfen bevor Hop 2 gestartet wird.

---

## Hop 2: 1.6.2 → 1.7.3

### Pre-Flight Checks wiederholen (s. oben)

Besonders:
```bash
# Nochmal Engine-Namen-Check
[ $(kubectl -n longhorn-system get engines.longhorn.io -o name | \
  grep -E '\-e\-[a-z0-9]{8}$' | wc -l) -gt 0 ] \
  && echo "HOLD: alte Engine-Namen gefunden!" \
  || echo "OK: Safe to upgrade to 1.7.x"
```

### 2.1 `gitops/apps/longhorn.yaml` anpassen

```yaml
    targetRevision: "1.7.3"
```

Der Rest der Values bleibt unverändert.

### 2.2 Sync auslösen

```bash
git add gitops/apps/longhorn.yaml
git commit -m "chore: longhorn upgrade 1.6.2 → 1.7.3"
git push

argocd app sync longhorn --prune
kubectl rollout status daemonset/longhorn-manager -n longhorn-system
```

### 2.3 Engine-Upgrade über Longhorn UI (erneut)

Gleicher Prozess wie in Schritt 1.4.

### 2.4 Validierung nach Hop 2

```bash
# Version prüfen
helm list -n longhorn-system
kubectl -n longhorn-system get pods -l app=longhorn-manager \
  -o jsonpath='{.items[0].spec.containers[0].image}'

# Alle Volumes healthy
kubectl get volumes.longhorn.io -n longhorn-system \
  -o custom-columns="NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness"

# Backup-Target erreichbar?
kubectl -n longhorn-system get setting backup-target

# RecurringJobs laufen?
kubectl get recurringjob -n longhorn-system
```

### 2.5 Longhorn CLI (neu in 1.7.0)

Ab 1.7.0 gibt es eine neue Longhorn CLI, die das alte Environment-Check-Script ablöst:

```bash
# Longhorn CLI pod ephemeral starten
kubectl run longhorn-cli --rm -it \
  --image=longhornio/longhorn-cli:v1.7.3 \
  --restart=Never \
  -n longhorn-system \
  -- check
```

---

## Auto-Sync wieder aktivieren

```bash
# Nach erfolgreichem Upgrade und Validierung
kubectl patch application longhorn -n argocd \
  --type=merge \
  -p='{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

---

## Rollback-Strategie

> ⚠️ Longhorn unterstützt **kein offizielles Downgrade**. Wenn Engine-Datenstrukturen  
> bereits migriert wurden, ist ein Rollback nicht möglich.

**Vor dem Upgrade-Hop 1:**
- `kubectl get settings.longhorn.io -n longhorn-system -o yaml` gesichert
- SystemBackup erstellt
- Helm kann theoretisch zurückgerollt werden (`helm rollback longhorn -n longhorn-system`),  
  **aber nur wenn Volumes noch nicht auf neues Engine Image upgraded wurden**

Im Worst-Case: Restore aus NFS-Backup (`nfs://192.168.11.55:/volume1/longhorn-backup`).

---

## Notes zu den bestehenden Backup-Jobs

Die bestehenden RecurringJob CRs (`daily-incremental-backup`, `weekly-full-backup`) und der
`longhorn-system-backup` CronJob sind mit `apiVersion: longhorn.io/v1beta2` deklariert und
sind damit **kompatibel mit 1.6.x und 1.7.x** — keine Änderungen erforderlich.

Der `serviceAccountName: longhorn-service-account` im CronJob muss weiterhin vorhanden sein —
in 1.7.x wurde daran nichts geändert.

---

## Zeitplan-Empfehlung

| Schritt | Dauer (geschätzt) |
|---------|-------------------|
| Pre-Flight + SystemBackup | 15 min |
| Hop 1 (1.5.3 → 1.6.2) inkl. Engine-Upgrade | 30–45 min |
| Beobachtungsphase nach Hop 1 | 1–2h (Backup-Job abwarten) |
| Pre-Flight Hop 2 | 10 min |
| Hop 2 (1.6.2 → 1.7.3) inkl. Engine-Upgrade | 30–45 min |
| Abschlussvalidierung | 15 min |
| **Gesamt** | **~3–4h** |
