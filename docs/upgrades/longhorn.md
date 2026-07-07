# Upgrade Runbook: Longhorn

## Metadaten
- **Namespace:** longhorn-system
- **Aktuelle Version:** 1.12.0
- **Quelle:** Helm-Chart `longhorn` von `https://charts.longhorn.io`
- **ArgoCD App-Name:** longhorn (Haupt-Chart), longhorn-backup (Companion-App für Backup-CronJobs, Pfad `gitops/config/longhorn`)
- **Versions-Check-Quelle:** `targetRevision` in `gitops/apps/longhorn.yaml`; Longhorn erlaubt nur Upgrades von der jeweils vorherigen Minor-Version (kein Überspringen von Minors)
- **Major/Minor-Kriterium:** Longhorn selbst versioniert nur `x.y.z` ohne offizielles Major/Minor-Breaking-Schema wie SemVer es nahelegt — in der Praxis gilt jeder Minor-Schritt (`x.Y.z`) als potenziell breaking, weil Longhorn zwingend sequenziell durch jede Minor-Version hoppen muss und dabei wiederholt CRD-Timing-Bugs auftraten (siehe Changelog). Patch-Releases innerhalb derselben Minor-Version (`x.y.Z`) gelten als unkritisch.

## Changelog

| Datum | Von → Nach | Typ | Ausführung | Status | Begründung | Notiz |
|---|---|---|---|---|---|---|
| unbekannt | ... | ... | ... | ... | Historie vor Einführung des strukturierten Runbooks nicht vollständig rekonstruierbar | — |
| 2026-04-30 | 1.5.3 → 1.6.2 | Minor | Manuell | Abgeschlossen | Hop 1 der Acht-Hop-Kette; `preUpgradeChecker.jobEnabled: false` musste vor dem Upgrade aus der Config entfernt werden | ~90 min inkl. Debug hängender Volumes |
| 2026-04-30 | 1.6.2 → 1.7.3 | Minor | Manuell | Abgeschlossen | Hop 2, Standard-Ablauf ohne Besonderheiten | ~35 min |
| 2026-05-03 | 1.7.3 → 1.8.2 | Minor | Manuell | Abgeschlossen | Hop 3, Standard-Ablauf ohne Besonderheiten | ~45 min |
| 2026-05-03 | 1.8.2 → 1.9.2 | Minor | Manuell | Abgeschlossen | Hop 4; v1.9.0/v1.9.1 übersprungen wegen bekannter Bugs im longhorn-manager, direkt 1.9.2 verwendet | ~45 min |
| 2026-05-03 | 1.9.2 → 1.10.2 | Minor | Manuell | Abgeschlossen | Hop 5; v1.10.0 übersprungen wegen nil-pointer-dereference-Bug; CRD-Timing-Bug (fehlende Volume-Felder `backupBlockSize`/`replicaRebuildingBandwidthLimit`) manuell gepatcht | ~90 min inkl. Volume-Feld-Bug, siehe Stolperfallen |
| 2026-05-03 | 1.10.2 → 1.11.1 | Minor | Manuell | Abgeschlossen | Hop 6; v1.11.0 übersprungen wegen Memory-Leak im instance-manager und Node-Validator-Regression; CRD-Timing-Bug (fehlendes Node-Status-Feld `healthDataLastCollectedAt`) sowie ArgoCD-CRD-Webhook-Konflikt manuell behoben | ~120 min inkl. Node-Status-Bug + ~5 min ArgoCD-CRD-Fix |
| 2026-05-05 | 1.11.1 → 1.11.2 | Minor | Manuell | Abgeschlossen | Patch-artiger Minor-Schritt, keine bekannten Breaking Changes | — |
| 2026-06-14 | 1.11.2 → 1.12.0 | Minor | Manuell | Abgeschlossen | Hop 7; direkter Minor-Hop ohne Breaking Changes für V1-only-Setup; kein CRD-Timing-Bug, kein Webhook-Umbau nötig; CSI-Storage-Capacity-Bug (Zero-Capacity-Knoten) war bereits gefixt | Problemlos, kein Workaround nötig |

### Reklassifizierungen (Minor → Major)

| Datum Erkennung | Ursprünglicher Changelog-Eintrag (Datum) | Grund der Reklassifizierung | Erneute Benachrichtigung gesendet am |
|---|---|---|---|

## Manuelle Vorgehensweise (bei Major/Breaking Change)

Longhorn-Upgrades laufen bei uns grundsätzlich manuell, Hop für Hop über jede Minor-Version (kein Überspringen möglich). Grundregeln:

- **Helm kennt den Release nicht** — Longhorn wurde via ArgoCD `ServerSideApply` installiert, `helm list`/`helm history` liefern keine Ergebnisse. Version immer über Pod-Images prüfen.
- **macOS sed** — immer `sed -i ''` (mit leerem String), nicht `sed -i`.
- **Engine Image lazy deployed** — nach dem Manager-Rollout dauert es 1–2 Minuten bis das neue Engine Image als `deployed` erscheint. Erst dann Engine-Upgrade im UI starten.
- **UI überspringt Volumes** — besonders Postgres- und Prometheus-Volumes werden beim Engine-Upgrade gern übersprungen (`specImage: ""`). Immer mit `jq`-Abfrage nachprüfen.
- **V2 Data Engine:** Dieser Cluster nutzt ausschließlich V1. Alle Hinweise zu V2 (Hugepage, SPDK, UBLK) sind nicht relevant.

### Pre-Flight Checks (vor dem ersten Hop)

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

### Standard-Ablauf pro Hop

1. **targetRevision anpassen**

   ```bash
   sed -i '' 's/targetRevision: "ALT"/targetRevision: "NEU"/' gitops/apps/longhorn.yaml
   grep -n "targetRevision" gitops/apps/longhorn.yaml

   git add gitops/apps/longhorn.yaml
   git commit -m "chore: longhorn upgrade hopX ALT → NEU"
   git push
   ```

2. **Sync & Rollout** — ArgoCD UI → App `longhorn` → **Sync** (keine weiteren Optionen).

   ```bash
   kubectl rollout status daemonset/longhorn-manager -n longhorn-system
   # Erwartung: "daemon set "longhorn-manager" successfully rolled out"

   kubectl get pods -n longhorn-system -l app=longhorn-manager \
     -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
   # Erwartung: alle Pods → longhornio/longhorn-manager:vNEU

   kubectl get jobs -n longhorn-system | grep -E "pre-upgrade|post-upgrade"
   # Erwartung: Complete
   ```

3. **Engine Image abwarten**

   ```bash
   kubectl get engineimage -n longhorn-system -w
   # Warten bis neue Version STATE=deployed
   ```

4. **Engine-Upgrade im UI** — `https://longhorn.reckeweg.io` → Volume-Tab → alle auswählen → **Upgrade Engine** → neue Version.

   ```bash
   kubectl get engineimage -n longhorn-system -w
   # Ziel: alte Version REFCOUNT=0, neue Version REFCOUNT=60

   # Hängende Volumes prüfen
   kubectl get engines.longhorn.io -n longhorn-system -o json | \
     jq -r '.items[] | select(.status.currentImage | contains("vALT")) |
     {name: .metadata.name, specImage: .spec.engineImage, currentImage: .status.currentImage}'
   # Falls specImage="" → nochmals im UI für diese Volumes triggern
   ```

5. **Validierung**

   ```bash
   kubectl get volumes.longhorn.io -n longhorn-system \
     -o custom-columns="NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness"
   kubectl get engineimage -n longhorn-system
   # Ziel: alte Version REFCOUNT=0, neue Version REFCOUNT=60, alle Volumes healthy
   ```

### Hop-spezifische Besonderheiten (aus der 1.5.3 → 1.12.0-Kette)

**Hop 1 (1.5.3 → 1.6.2):** Zusätzlich `preUpgradeChecker.jobEnabled: false` aus der Config entfernen:

```bash
sed -i '' '/preUpgradeChecker:/,/jobEnabled: false/d' gitops/apps/longhorn.yaml
```

**Hop 4 (1.8.2 → 1.9.2):** v1.9.0/v1.9.1 überspringen (bekannte Manager-Bugs), direkt 1.9.2. Nach dem Engine-Upgrade CRD-Check vor Hop 5 (siehe Anhang CRD-Migration).

**Hop 5 (1.9.2 → 1.10.2):** v1.10.0 überspringen (nil-pointer-dereference-Bug), direkt 1.10.2. v1beta1 wird in 1.10 vollständig entfernt.

> ⚠️ **CRD-Timing-Bug — fehlende Volume-Felder.** Der 1.10.2-Manager kennt neue Volume-Felder (`backupBlockSize`, `replicaRebuildingBandwidthLimit`), die in bestehenden Volume-Objekten noch nicht vorhanden sind → CrashLoop mit `strict decoding error: unknown field "spec.backupBlockSize"`.
>
> Fix sofort nach dem Sync (Webhooks müssen weg sein):
> ```bash
> kubectl delete mutatingwebhookconfiguration longhorn-webhook-mutator 2>/dev/null || true
> kubectl delete validatingwebhookconfiguration longhorn-webhook-validator 2>/dev/null || true
>
> for vol in $(kubectl get volumes.longhorn.io -n longhorn-system -o name); do
>   kubectl patch $vol -n longhorn-system \
>     --type=json \
>     -p '[{"op":"add","path":"/spec/backupBlockSize","value":"2097152"},
>         {"op":"add","path":"/spec/replicaRebuildingBandwidthLimit","value":0}]'
> done
> ```
> Korrekte Werte: `backupBlockSize`: `"2097152"` (2MB Default) oder `"16777216"` (16MB); `replicaRebuildingBandwidthLimit`: Integer `0` (unlimited), **nicht** String.
>
> Falls der Manager wegen `guaranteed-instance-manager-cpu` crasht: Setting muss `"12"` sein, sonst patchen:
> ```bash
> kubectl -n longhorn-system patch setting guaranteed-instance-manager-cpu --type=merge -p '{"value":"12"}'
> ```

**Hop 6 (1.10.2 → 1.11.1):** v1.11.0 überspringen (Memory-Leak im instance-manager, Node-Validator-Regression), direkt 1.11.1.

> ⚠️ **CRD-Timing-Bug — fehlendes Node-Status-Feld.** Der 1.11.1-Manager kennt das neue Feld `healthDataLastCollectedAt` nicht in der alten CRD-Definition → CrashLoop mit `strict decoding error: unknown field "status.diskStatus.<disk-id>.healthDataLastCollectedAt"`.
>
> Fix — Webhooks löschen, dann Node-Status via Raw API bereinigen:
> ```bash
> kubectl delete mutatingwebhookconfiguration longhorn-webhook-mutator 2>/dev/null || true
> kubectl delete validatingwebhookconfiguration longhorn-webhook-validator 2>/dev/null || true
>
> for node in $(kubectl get nodes.longhorn.io -n longhorn-system -o name | sed 's|node.longhorn.io/||'); do
>   kubectl get node.longhorn.io/$node -n longhorn-system -o json | \
>     jq 'del(.status.diskStatus[].healthDataLastCollectedAt)' | \
>     kubectl replace --raw \
>       /apis/longhorn.io/v1beta2/namespaces/longhorn-system/nodes/$node/status -f -
> done
> ```
> Falls das Feld hartnäckig bleibt (etcd-Cache): Finalizers entfernen und Node-Objekte komplett löschen (Manager legt sie beim Start neu an, ohne das Feld):
> ```bash
> for node in $(kubectl get nodes.longhorn.io -n longhorn-system -o name); do
>   kubectl patch $node -n longhorn-system --type=json \
>     -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
> done
> kubectl delete nodes.longhorn.io -n longhorn-system --all --force --grace-period=0
> ```
> Falls der Manager immer noch nicht startet: `upgradeVersionCheck: false` temporär in den Helm-Values setzen, nach erfolgreichem Start wieder entfernen.

> ⚠️ **ArgoCD OutOfSync — CRD-Webhook-Konflikt.** Nach dem Upgrade auf 1.11.1 meldet ArgoCD einen Sync-Fehler für 5 CRDs (`spec.conversion.strategy: Required value` / `webhookClientConfig: Forbidden`), weil Longhorn 1.11.1 den Conversion-Webhook abgeschafft hat, die bestehenden CRDs im Cluster aber noch den alten Webhook-Eintrag tragen. Longhorn selbst läuft dabei korrekt (Healthy) — nur ArgoCD kann nicht synchen.
>
> Fix:
> ```bash
> for crd in backingimages.longhorn.io backuptargets.longhorn.io engineimages.longhorn.io nodes.longhorn.io volumes.longhorn.io; do
>   kubectl patch crd $crd --type=json -p='[{"op": "remove", "path": "/spec/conversion"}]'
> done
> argocd app sync longhorn
> ```

Nach dem Node-Delete-Workaround können Volumes kurzzeitig `degraded`/`detached` erscheinen — normal, Longhorn rebuildet Replicas automatisch (10–30 Minuten).

### Abschluss (nach dem letzten Hop)

```bash
# Auto-Sync wieder aktivieren
kubectl patch application longhorn -n argocd \
  --type=merge \
  -p='{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'

# Manager-Version, Volumes, Engine Images, Nodes, RecurringJobs, SystemBackups final prüfen
kubectl get pods -n longhorn-system -l app=longhorn-manager \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
kubectl get volumes.longhorn.io -n longhorn-system \
  -o custom-columns="NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness"
kubectl get engineimage -n longhorn-system
kubectl get nodes.longhorn.io -n longhorn-system
kubectl get recurringjob -n longhorn-system
kubectl get systembackup -n longhorn-system
```

### Anhang: CRD-Migration (nur falls v1beta1 noch vorhanden, vor Hop 5)

```bash
kubectl get crds -o json | \
  jq -r '.items[] | select(.metadata.name | contains("longhorn")) |
  select(.status.storedVersions[] | contains("v1beta1")) |
  .metadata.name'

kubectl patch crd engines.longhorn.io --type=json \
  -p='[{"op":"replace","path":"/status/storedVersions","value":["v1beta2"]}]' \
  --subresource=status

kubectl get engines.longhorn.io -n longhorn-system -o json | kubectl apply -f -
```

## Bekannte Stolperfallen / Lessons Learned

- Longhorn erlaubt nur Upgrades von der jeweils vorherigen Minor-Version — kein Überspringen von Minor-Versionen, daher immer Hop-für-Hop.
- Mehrere Minor-Versionen (1.9.0/1.9.1, 1.10.0, 1.11.0) hatten bekannte Bugs — jeweils direkt auf das nächste Patch-Release innerhalb der Minor-Version gezielt.
- Wiederkehrendes Muster: neue CRD-Felder werden vom Manager vor dem eigentlichen CRD-Rollout erwartet ("CRD-Timing-Bug") → CrashLoop direkt nach dem Sync. Immer zuerst prüfen, ob es sich um dieses Muster handelt, bevor tiefer debuggt wird.
- ArgoCD `resources: {}`-Drift nach dem Upgrade ist harmlos — Longhorn schreibt Resource-Felder zur Laufzeit zurück. Wird über `ignoreDifferences` in `gitops/apps/longhorn.yaml` für DaemonSet/Deployment (`*.resources`-jqPathExpressions) abgefangen.
- **Worker-Node Cordon/Uncordon bei Hardware-Wartung (nicht upgrade-spezifisch, aber eng verwandt):** Für Wartungsarbeiten, die ein gleichzeitiges Herunterfahren aller Pi-Worker erfordern (z.B. Netzteil-Tausch), existieren zwei Skripte:
  - `scripts/longhorn-drain-workers.sh` — stoppt laufende KubeVirt-VMs, cordoned alle Worker, setzt Longhorn-Node/Disk-Eviction (`allowScheduling: false`, `evictionRequested: true`), wartet bis alle Replicas von den Pi-Nodes evakuiert sind, löscht Instance-Manager-PDBs, drained die Nodes und fährt sie herunter.
  - `scripts/longhorn-uncordon-workers.sh` — Gegenstück nach dem Wiedereinschalten: wartet bis alle Nodes `Ready`, setzt Longhorn-Eviction zurück (`allowScheduling: true`, `evictionRequested: false`), uncordoned die Nodes.
  - Beide Skripte sind fest auf die Worker `k3s-01a` … `k3s-05a` zugeschnitten. Diese Prozedur ist **kein** Teil eines regulären Longhorn-Hops, aber relevant wenn eine Upgrade-Wartung mit einem Hardware-Eingriff kombiniert wird — dann zuerst drainen, dann Longhorn-Hop(s) durchführen, danach uncordonen.

## Rollback-Plan

> ⚠️ Kein offizielles Downgrade möglich, sobald Engine-Datenstrukturen migriert wurden.

- Settings-Backup: `longhorn-settings-backup-<datum>.yaml` (siehe Pre-Flight-Check 6)
- SystemBackup: `pre-upgrade-<datum>` (STATE=Ready, siehe Pre-Flight-Check 7)
- NFS-Backup-Target: `nfs://192.168.11.55:/volume1/longhorn-backup`
- Rollback ist nur zwischen den Hops sinnvoll möglich (bevor die nächste Minor-Version begonnen wird) — ein Rollback nach erfolgreichem Engine-Upgrade auf eine neue Minor-Version wird von Longhorn nicht unterstützt.

## Referenzen

- GitHub Releases: https://github.com/longhorn/longhorn/releases
- Helm-Chart-Repo: https://charts.longhorn.io
- Interne Doku/Skripte: `scripts/longhorn-drain-workers.sh`, `scripts/longhorn-uncordon-workers.sh`, `scripts/longhorn-assign-volumes-to-group.sh`
- ArgoCD-Manifeste: `gitops/apps/longhorn.yaml`, `gitops/apps/longhorn-backup.yaml`, `gitops/config/longhorn/`
