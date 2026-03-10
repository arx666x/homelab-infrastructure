# Longhorn Backup Konfiguration

**Umgebung:** homelab / reckeweg.io  
**Storage:** Longhorn 1.5.3  
**Backup-Ziel:** NFSv4 (Synology NAS)  
**GitOps:** ArgoCD / App-of-Apps Pattern  

---

## Übersicht

| Job | Zeitplan | Retention | Typ |
|-----|----------|-----------|-----|
| `weekly-full-backup` | Sonntag 02:00 | 13 Wochen | Volume Backup (RecurringJob) |
| `daily-incremental-backup` | Mo–Sa 03:00 | 90 Tage | Volume Backup (RecurringJob) |
| `longhorn-system-backup` | Sonntag 01:00 | manuell | System Backup (CronJob) |

**Tagesablauf Sonntag:**
```
01:00  → System Backup  (Longhorn-Konfiguration + Metadaten)
02:00  → Wöchentliches Volume Backup
```

**Tagesablauf Mo–Sa:**
```
03:00  → Tägliches inkrementelles Volume Backup
```

---

## Hinweis zu "voll" vs. "inkrementell"

Longhorn erstellt intern immer **blockbasierte Deltas** – es gibt keinen technischen Unterschied zwischen Voll- und Inkremental-Backup. Die Unterscheidung bezieht sich hier auf die Retention-Strategie:

- Der **wöchentliche Job** dient als langfristiger Referenzpunkt (13 Wochen ≈ 3 Monate).
- Der **tägliche Job** ergänzt die Granularität innerhalb der Woche (90 Tage ≈ 3 Monate).

Longhorn löscht ältere Backups **automatisch**, sobald ein neuer Snapshot erstellt wird und die `retain`-Grenze überschritten wird. Es ist kein separater Cleanup-Job notwendig.

---

## Repo-Struktur

```
gitops/apps/
├── longhorn.yaml                         # ArgoCD App: Longhorn Helm-Chart
├── longhorn-backup.yaml                  # ArgoCD App: Backup-Ressourcen
└── longhorn/
    ├── 01-weekly-backup.yaml             # RecurringJob: wöchentlich
    ├── 02-daily-backup.yaml              # RecurringJob: täglich
    └── 03-system-backup-cronjob.yaml     # CronJob: System Backup

scripts/
└── longhorn-assign-volumes-to-group.sh   # Bootstrapping: Volumes der Gruppe zuweisen
```

`longhorn.yaml` deployt den Longhorn Helm-Chart direkt aus `https://charts.longhorn.io`.  
`longhorn-backup.yaml` ist eine separate ArgoCD Application die auf `gitops/apps/longhorn/` zeigt.  
Durch das App-of-Apps Pattern werden beide automatisch von der Root-App erkannt und deployt.

---

## Deployment

### 1. Backup-Ziel prüfen

In der Longhorn UI unter **Settings → General → Backup Target** muss das NFS-Ziel eingetragen sein:

```
nfs://<NAS-IP>:/<pfad-zum-backup-share>
```

### 2. Volumes der Backup-Gruppe zuweisen

Dieser Schritt muss **einmalig vor dem ersten Sync** ausgeführt werden, damit die RecurringJobs Volumes finden:

```bash
chmod +x scripts/longhorn-assign-volumes-to-group.sh
./scripts/longhorn-assign-volumes-to-group.sh
```

Labels prüfen:
```bash
# Alle Volumes mit Labels
kubectl get volumes -n longhorn-system \
  -o custom-columns='NAME:.metadata.name,GROUP:.metadata.labels.recurring-job-group\.longhorn\.io/default'

# Volumes OHNE Label (sollte leer sein)
kubectl get volumes -n longhorn-system \
  -l '!recurring-job-group.longhorn.io/default'
```

### 3. GitOps Deployment

```bash
git add gitops/apps/longhorn/ gitops/apps/longhorn-backup.yaml
git commit -m "feat: add longhorn backup jobs (weekly, daily, system)"
git push
```

ArgoCD erkennt die neue `longhorn-backup` Application automatisch über das App-of-Apps Pattern und deployt die Ressourcen. Status prüfen:

```bash
kubectl get application -n argocd
argocd app get longhorn-backup
kubectl get recurringjob -n longhorn-system
kubectl get cronjob -n longhorn-system
```

---

## Bekannte Stolpersteine

### `spec.name` ist Pflichtfeld bei RecurringJobs

Longhorn erwartet `spec.name` zusätzlich zu `metadata.name`. Fehlt es, lehnt der Admission Webhook die Ressource ab:

```
admission webhook "validator.longhorn.io" denied the request: 
invalid job {Name: Groups:[default] Task:backup ...}
```

Beide RecurringJob-YAMLs müssen daher so aufgebaut sein:

```yaml
metadata:
  name: weekly-full-backup
spec:
  name: weekly-full-backup   # ← Pflichtfeld, nicht vergessen
  ...
```

### `spec.volumeBackupPolicy` ist Pflichtfeld bei SystemBackup

Ab Longhorn 1.5.x erwartet das `SystemBackup`-Objekt das Feld `spec.volumeBackupPolicy`. Fehlt es, schlägt `kubectl apply` mit folgendem Fehler fehl:

```
Internal error occurred: replace operation does not apply: 
doc is missing path: /spec/volumeBackupPolicy: missing value
```

Das Objekt wird dabei trotzdem als "created" gemeldet, existiert aber nicht wirklich. Der CronJob muss das Feld explizit setzen:

```yaml
spec:
  volumeBackupPolicy: if-not-present
```

Mögliche Werte:

| Wert | Bedeutung |
|------|-----------|
| `if-not-present` | Volume-Backup nur wenn noch keines existiert (empfohlen) |
| `always` | Immer neues Volume-Backup erstellen |
| `disabled` | Nur Longhorn-Konfiguration, keine Volume-Backups |

`if-not-present` ist empfohlen da separate RecurringJobs die Volume-Backups übernehmen.

### ArgoCD Sync-Verzögerung

ArgoCD pollt das Repo standardmäßig alle **3 Minuten**. Änderungen sind daher nicht sofort aktiv. Manuell anstoßen:

```bash
argocd app sync longhorn-backup
```

---

## System Backups

System Backups sichern die **Longhorn-Konfiguration** (Volumes-Metadaten, RecurringJobs, Settings, CRDs) – keine Dateiinhalte der PVCs.

Sie sind in der Longhorn UI unter **Setting → System Backup** sichtbar.

Der CronJob erstellt jeden Sonntag um 01:00 Uhr ein `SystemBackup`-Objekt mit dem Format `system-backup-YYYYMMDD-HHMM`.

**Manuell testen:**
```bash
kubectl create job --from=cronjob/longhorn-system-backup manual-test -n longhorn-system
kubectl logs -n longhorn-system -l job-name=manual-test -f
```

**Status prüfen:**
```bash
kubectl get systembackup -n longhorn-system
```

**Alte System Backups löschen** (kein automatisches Retention – manuell erforderlich):
```bash
kubectl get systembackup -n longhorn-system \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.creationTimestamp}{"\n"}{end}'

kubectl delete systembackup <name> -n longhorn-system
```

---

## Referenzen

- [Longhorn Recurring Snapshots and Backups](https://longhorn.io/docs/1.5.3/snapshots-and-backups/scheduling-backups-and-snapshots/)
- [Longhorn System Backup](https://longhorn.io/docs/1.5.3/advanced-resources/system-backup-restore/backup-longhorn-system/)
- [Longhorn RecurringJob CRD Reference](https://longhorn.io/docs/1.5.3/references/longhorn-client-python/recurringjob/)
