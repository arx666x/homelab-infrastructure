# Upgrade Runbook: Gitea

## Metadaten
- **Namespace:** `gitea`
- **Aktuelle Version:** Chart 12.7.0 / Gitea App 1.27.0
- **Quelle:** Helm-Chart `gitea` von `https://dl.gitea.com/charts/` ([Chart-Releases](https://gitea.com/gitea/helm-gitea/releases)); Values werden zusätzlich aus dem eigenen Repo (`git@git.reckeweg.io:achim/homelab-infrastructure.git`, `gitops/config/gitea/values.yaml`) als zweite Helm-Source gezogen
- **ArgoCD App-Name:** `gitea` (sync-wave 20)
- **Zugehörige ArgoCD-Apps:** `gitea-postgresql` (sync-wave 15, externes StatefulSet, postgres:16-alpine, Longhorn 10Gi) und `gitea-valkey` (sync-wave 16, externes StatefulSet) — beide sind Datastore-Abhängigkeiten von Gitea, kein eigenständiger Eintrag in der Service-Liste, werden aber in dieser Datei mitdokumentiert. Ergänzend läuft `gitea-actions` (sync-wave 25, act-runner + DinD) — hat ein eigenes Runbook: [gitea-actions-runner.md](gitea-actions-runner.md)
- **Versions-Check-Quelle:** `helm show chart gitea/gitea --version <x>` gegen `https://dl.gitea.com/charts/`; App-Version ergibt sich aus dem Chart-`appVersion`-Default, nicht unabhängig versioniert
- **Major/Minor-Kriterium:** Chart- und App-Version sind gekoppelt — ein Chart-Minor-Bump kann eine neue Gitea-App-Version erzwingen (Breaking-Change-Potential trotz "Minor"-Chart-Nummer). Vor jedem Upgrade `helm show chart gitea/gitea --version <neu> | grep appVersion` prüfen und Chart-Changelog auf Init-Container-Änderungen (z.B. Flag-Änderungen in `init-app-ini`) durchsehen.

## Changelog

| Datum | Von → Nach | Typ | Ausführung | Status | Begründung | Notiz |
|---|---|---|---|---|---|---|
| unbekannt | ... → 1.23.x | unbekannt | Manuell | Abgeschlossen | Historie vor Einführung des strukturierten Runbooks nicht vollständig rekonstruierbar | Commit `be7b105`: Umstieg auf 1.23.x, Wiki-Unterverzeichnisse in 1.22 nicht unterstützt |
| unbekannt | 1.23.x → 1.24.6 | unbekannt | Manuell | Abgeschlossen | Historie vor Einführung des strukturierten Runbooks nicht vollständig rekonstruierbar | Commit `ed1f43a`: Umbau auf externes PostgreSQL, Actions vorbereitet |
| 2025-10 (ca., aus Commit-Historie) | 1.24.6 → 1.26.0 | Major | Manuell | Abgeschlossen | Direkter Sprung über mehrere App-Versionen; Registry-Wechsel für act_runner nötig | Commit `bffa2bf`; Init-Container `configure-gitea` schlug initial wegen entferntem `-o`-Flag fehl (Grund für spätere Vorsicht bei Chart-Bumps) |
| 2026-05-18 | Chart 12.5.3 → 12.6.0 (App 1.25.5 → 1.26.1) | Minor (Chart) / faktisch Major (App-Zwang) | Manuell | Reklassifiziert (Minor→Major) | Ursprünglich als reiner Chart-Minor-Bump eingestuft; erster Versuch scheiterte, weil Chart 12.6.0 zwingend App 1.26.1 voraussetzt (`-apply-env`-Flag existiert nicht in 1.25.5) | Siehe Reklassifizierungs-Tabelle unten; zweiter Versuch mit kombiniertem Chart+App-Bump erfolgreich |
| 2026-07-27 | Chart 12.6.0 → 12.7.0 (App 1.26.1 → 1.27.0) | Minor (Chart) / faktisch Major (App-Zwang) | Manuell | Abgeschlossen | Chart erzwingt wieder vollen App-Minor-Sprung (1.26→1.27); diesmal aber keine Init-Container/Template-Änderung im Chart-Diff (12.6.0 vs 12.7.0: nur Chart.yaml-Metadaten + neue, standardmäßig deaktivierte Gateway-API-Sektion in values.yaml) — Upgrade lief im Gegensatz zum letzten Mal im ersten Versuch durch | Vorab-Diff der Chart-Templates (`helm pull --untar` beider Versionen) bestätigte fehlendes Breaking-Change-Risiko; DB-Backup trotzdem vorab gezogen |

### Reklassifizierungen (Minor → Major)

| Datum Erkennung | Ursprünglicher Changelog-Eintrag (Datum) | Grund der Reklassifizierung | Erneute Benachrichtigung gesendet am |
|---|---|---|---|
| 2026-05-18 | 2026-05-18 (Chart 12.5.3 → 12.6.0) | Init-Container `init-app-ini` rief `-apply-env` auf, ein Flag das in Gitea 1.25.5 nicht existiert (`Incorrect Usage: flag provided but not defined: -apply-env`) → Pod blieb in `Init:CrashLoopBackOff`, Gitea war nicht erreichbar, ArgoCD-Catch-22 trat vollständig ein | 2026-05-18 (gleicher Tag, Runbook direkt im Anschluss aktualisiert) |

## Manuelle Vorgehensweise (bei Major/Breaking Change)

### Architektur & Catch-22-Problem

```
ArgoCD
  ├── gitea-postgresql  (wave 15) — externes StatefulSet, postgres:16-alpine, Longhorn 10Gi
  ├── gitea-valkey      (wave 16) — externes StatefulSet
  ├── gitea             (wave 20) — Helm Chart, Recreate-Strategy, Longhorn 50Gi
  └── gitea-actions     (wave 25) — act-runner + DinD (siehe gitea-actions-runner.md)
```

ArgoCD bezieht die Values-Datei für die `gitea`-App aus dem Gitea-Repo selbst:

```yaml
# gitops/apps/gitea/gitea.yaml
sources:
  - repoURL: https://dl.gitea.com/charts/     # Helm Chart — öffentlich, kein Problem
    chart: gitea
    targetRevision: 12.6.0
    helm:
      valueFiles:
        - $values/gitops/config/gitea/values.yaml
  - repoURL: git@git.reckeweg.io:achim/homelab-infrastructure.git   # ← Gitea selbst!
    targetRevision: HEAD
    ref: values
```

**Konsequenz:** Während Gitea down ist (Recreate-Upgrade), kann ArgoCD für *alle anderen* Apps,
die dieses Repo als Source haben, keine neuen Syncs starten. Ein fehlgeschlagener Start der
neuen Gitea-Version führt zu einem echten Deadlock.

**Mitigation:** Vor dem Upgrade die ArgoCD-App notfalls temporär auf GitHub als Values-Quelle
umstellen (Fallback, historisch in Commit `3232064`/`2e652e4` durchgespielt).

### Schritt 1: Pre-Flight-Checks

```bash
# Pods und PVCs gesund?
kubectl get pods -n gitea
kubectl get pvc -n gitea

# API erreichbar? Aktuelle Version notieren
curl -s https://gitea.reckeweg.io/api/v1/version | jq .version

# ArgoCD Repo-Verbindung
argocd repo list
# → STATUS = Successful

# PostgreSQL erreichbar?
kubectl -n gitea exec deploy/gitea -- \
  sh -c 'PGPASSWORD=$GITEA__DATABASE__PASSWD psql -h gitea-postgresql -U gitea -c "\l"'

# Keine laufenden Actions Jobs
# https://gitea.reckeweg.io/-/admin/actions → alle Jobs abgeschlossen
```

### Schritt 2: Ziel-Version prüfen

```bash
helm show chart gitea/gitea --version <neue-chart-version> | grep appVersion
```

Chart- und App-Version sind gekoppelt — **immer beide zusammen** anheben, niemals nur den Chart
oder nur `image.tag` isoliert ändern (siehe Lessons Learned).

### Schritt 3: DB-Backup vor dem Upgrade

> Pflicht bei jedem App-Versions-Bump — DB-Migrationen sind i.d.R. nicht reversibel.

```bash
kubectl -n gitea exec gitea-postgresql-0 -- \
  sh -c 'PGPASSWORD=$POSTGRES_PASSWORD pg_dump -U gitea gitea | gzip' \
  > gitea-db-backup-pre-<neue-version>-$(date +%Y%m%d-%H%M).sql.gz

ls -lh gitea-db-backup-pre-*.sql.gz
```

### Schritt 4: Beide Änderungen in einem Commit

**`gitops/config/gitea/values.yaml`** — Image-Tag anheben:
```yaml
image:
  tag: "<neue-app-version>"
```

**`gitops/apps/gitea/gitea.yaml`** — Chart-Version anheben:
```yaml
targetRevision: <neue-chart-version>
```

```bash
git add gitops/config/gitea/values.yaml gitops/apps/gitea/gitea.yaml
git commit -m "feat: gitea upgrade chart <alt> → <neu>, app <alt> → <neu>"
git push
```

ArgoCD erkennt den Commit und startet den Sync automatisch.

### Schritt 5: Upgrade beobachten

```bash
kubectl get pods -n gitea -w
# Erwartete Sequenz (Recreate-Strategy):
#   gitea-xxx   Running → Terminating
#   gitea-yyy   Init:0/3 → Init:1/3 → Init:2/3 → Running
```

Bei Hänger in Init-Containern sofort Logs prüfen:

```bash
kubectl logs -n gitea -l app.kubernetes.io/name=gitea -c init-app-ini --tail=50
kubectl logs -n gitea -l app.kubernetes.io/name=gitea -c configure-gitea --tail=50
```

**Erwartete Downtime:** 60–120 Sekunden

### Schritt 6: Post-Upgrade-Verifikation

```bash
# App-Version korrekt?
kubectl -n gitea get deploy gitea -o jsonpath='{.spec.template.spec.containers[0].image}'

# API antwortet mit neuer Version?
curl -s https://gitea.reckeweg.io/api/v1/version | jq .version

# SSH funktioniert? (SSH läuft über git.reckeweg.io, nicht gitea.reckeweg.io)
ssh -T git@git.reckeweg.io

# Logs sauber?
kubectl -n gitea logs deploy/gitea --tail=100 | grep -iE "error|fatal|panic"

# ArgoCD-Repo-Verbindung intakt?
argocd repo list | grep reckeweg.io
```

### Schritt 7: Smoke-Tests

```bash
curl -s -o /dev/null -w "%{http_code}" https://gitea.reckeweg.io
# → 200

argocd app list | grep -v "Synced.*Healthy"
# → keine Ausgabe (alle Apps OK)

kubectl get pods -n gitea -l app.kubernetes.io/name=act-runner
# → act-runner läuft (2/2)
```

## Bekannte Stolperfallen / Lessons Learned

- **Chart- und App-Version sind gekoppelt.** Ein reiner Chart-Minor-Bump kann stillschweigend
  eine neue Pflicht-App-Version mitbringen. Beim Upgrade 12.5.3 → 12.6.0 (2026-05-18) scheiterte
  der erste Versuch, weil Chart 12.6.0 das Flag `-apply-env` im Init-Container `init-app-ini`
  nutzt, das in Gitea 1.25.5 nicht existiert (`Incorrect Usage: flag provided but not defined:
  -apply-env`). Fix: `image.tag` in `values.yaml` und `targetRevision` in `gitea.yaml` immer
  **gemeinsam** in einem Commit anheben, vorher `helm show chart gitea/gitea --version <x> |
  grep appVersion` prüfen.
- **DB-Migration ist irreversibel.** Nach erfolgreichem Start der neuen App-Version laufen
  automatisch DB-Migrationen. Ein Rollback auf die alte Version ist danach nicht mehr sicher
  möglich — vor jedem App-Versions-Bump PostgreSQL-Backup erstellen.
- **ArgoCD-Catch-22:** Während Gitea (Recreate-Strategy) down ist, kann ArgoCD nicht von
  `git.reckeweg.io` lesen, wenn dieses Repo als Values-Source für die `gitea`-App selbst dient.
  Ein fehlgeschlagener Start der neuen Version blockiert dann auch alle anderen Apps, die dieses
  Repo referenzieren. Bei Bedarf GitHub temporär als Values-Fallback nutzen.
- **`root-infrastructure` hat `selfHeal: true`** — es stellt die `gitea`-Application sofort
  zurück, wenn ArgoCD Drift erkennt. Bei Rollback/Wartung deshalb **immer `root-infrastructure`
  zuerst** deaktivieren, danach `gitea`, sonst schlägt der Eingriff fehl.
- **Registry-Historie:** act_runner-Image war früher auf `docker.gitea.com` gehostet, dann auf
  `docker.io/gitea/act_runner` umgezogen (Commit `cae1225`); Gitea selbst lief zeitweise über
  `docker.gitea.com/gitea` (rootless-Image). Bei Registry-bezogenen Fehlern (`ImagePullBackOff`)
  prüfen, ob sich die Registry-URL erneut geändert hat.
- **Longhorn-PVC im Provisioning hängt gelegentlich** — Recreate-Strategy löscht den alten Pod,
  bevor der PVC vollständig neu gemountet ist. Meist löst sich das nach wenigen Sekunden von
  selbst (`kubectl get pvc -n gitea -w` beobachten).
- **SSH-Hostkey-Wechsel:** Nach PVC-Verlust/Neustart kann sich der SSH-Hostkey von
  `git.reckeweg.io` ändern (`knownhosts: key is unknown`), was die ArgoCD-Repo-Verbindung bricht.
  Reparatur-Anleitung siehe [Traefik-Runbook Anhang](traefik.md).
- Keine Hinweise in der bisherigen Historie auf eine Verbindung zur phpLDAPadmin→LDAP Account
  Manager (LAM)-Migration — die beiden Themen sind unabhängig, LAM wird hier nicht weiter
  dokumentiert.
- **Vorab-Diff der Chart-Templates deckt die `-apply-env`-Falle zuverlässig auf.** Seit dem
  Vorfall vom 2026-05-18 lohnt sich vor jedem Chart-Bump: beide Chart-Versionen lokal ziehen
  (`helm pull gitea-charts/gitea --version <alt>/<neu> --untar --untardir <dir>`) und
  `templates/gitea/deployment.yaml` sowie `scripts/init-containers/` diffen. Bei 12.6.0→12.7.0
  waren beide Dateien identisch — einziger inhaltlicher Unterschied war eine neue, standardmäßig
  deaktivierte Gateway-API-Sektion in `values.yaml`. Das gab vorab Sicherheit, dass der App-Zwang
  (1.26→1.27) diesmal nicht denselben Init-Container-Fehler wie beim letzten Mal auslösen würde.
- **ArgoCD synct einen Chart+App-Doppel-Commit gelegentlich in zwei Wellen.** Beim Upgrade
  2026-07-27 zeigte `argocd app history gitea` zwei Sync-Operationen auf denselben Commit-Hash
  innerhalb von ~70 Sekunden — die erste erzeugte einen Pod-Recreate ohne Versionswechsel
  (Chart blieb kurzzeitig bei 12.6.0), erst die zweite Welle brachte 12.7.0. Grund vermutlich
  Timing zwischen dem `HEAD`-Values-Source (Gitea-Repo selbst) und dem Chart-Source-Refresh im
  ArgoCD-Repo-Server. Kein Eingriff nötig, hat sich selbst aufgelöst — führt aber zu **zwei**
  Downtime-Fenstern hintereinander statt einem (insgesamt ca. 130s statt der üblichen 60–120s).
  Falls das reproduzierbar öfter auftritt, ggf. `argocd app get gitea --hard-refresh` vor dem
  manuellen Beobachten erwägen.
- **`[git.config]` mit Punkten im Key bricht `init-app-ini`** (Vorfall 2026-09-01). Der Chart
  rendert jede `gitea.config`-Sektion zu Env-Vars. Der Sektionsname wird dabei escaped
  (`git.config` → `GIT_0X2E_CONFIG`), der **Key aber nicht**: aus `pack.threads` wird
  `GITEA__GIT_0X2E_CONFIG__PACK.THREADS`, und `config_environment.sh` bricht ab mit
  `export: ... not a valid identifier` → `Init:CrashLoopBackOff`, Gitea nicht erreichbar.
  `helm template` zeigt das **nicht** — die Sektion rendert sauber, der Fehler entsteht erst
  zur Laufzeit im Init-Container. Wer `[git.config]` braucht, muss die Punkte im Key selbst
  escapen (`pack_0X2E_threads`) und das vorher am Image verifizieren, nicht nur am Template.
- **Der ArgoCD-Catch-22 ist beim Vorfall 2026-09-01 real eingetreten.** Weil Gitea down war,
  konnte ArgoCD den Korrektur-Commit nicht von `git.reckeweg.io` holen — und der Fix lag genau
  in diesem Repo. Auflösung nur per direktem Cluster-Eingriff (Secret-Patch, siehe nächster
  Punkt). Lehre: Bei jeder Änderung an `values.yaml`, die den Pod-Start betreffen kann, vorher
  den GitHub-Values-Fallback vorbereiten — nicht erst, wenn es brennt.
- **ArgoCD entfernt einen aus den Values gelöschten Key nicht aus dem Live-Secret.**
  `gitea-inline-config` hatte keine `managedFields`, ArgoCD sah den Key deshalb nicht als
  eigenes Feld, prunete ihn beim Sync des Revert-Commits nicht und meldete die Application
  trotzdem `Synced/Healthy`. Die Deployment-Checksum änderte sich aber → neuer Pod → gleicher
  Crash. Ein Git-Revert allein reicht bei Key-**Entfernung** also nicht; der Live-Stand muss
  geprüft und der Key manuell gepatcht werden:
  ```bash
  kubectl -n gitea get secret gitea-inline-config -o json | jq -r '.data|keys'
  kubectl -n gitea patch secret gitea-inline-config --type=json \
    -p '[{"op":"remove","path":"/data/<key>"}]'
  kubectl -n gitea delete pod -l app=gitea
  ```
  Wichtig: erst patchen, wenn ArgoCDs Soll-Stand bereits der korrigierte Commit ist — sonst
  schreibt selfHeal den Key sofort zurück (genau das passierte beim ersten Versuch).

## Offene Punkte (beim nächsten Upgrade mit erledigen)

- **`pack`-Tuning gegen RAM-Spitzen beim Klonen großer Repos.** Am 2026-08-31 wurde Gitea
  mehrfach OOMKilled (`exitCode 137`, 4 Restarts): kein Leak — die Baseline liegt konstant bei
  ~150Mi, der Verbrauch springt in unter einer Minute von 128Mi auf ~1006Mi und fällt sofort
  zurück. Auslöser ist der `mirror-to-github`-Workflow, der bei **jedem** Push ein
  `git clone --mirror` macht; Gitea bedient das mit `git upload-pack`/`pack-objects` im eigenen
  Container-cgroup. `pack-objects` liest `nproc`, sieht alle 16 Node-CPUs und startet
  entsprechend viele Threads mit unbegrenztem Delta-Window. Größte Repos:
  `susann/redesign.git` ~935Mi, `achim/seri.2026.git` ~713Mi.

  **Sofortmaßnahme (erledigt, Commit `d42d803`):** Limit 1Gi → 2Gi, Request 256Mi → 512Mi.
  Nachgemessen mit der echten Last (`git clone --mirror` von `seri.2026`): Peak 828Mi, keine
  Restarts. Reicht damit für den Ist-Zustand.

  **Offen:** die Spitze an der Wurzel deckeln statt nur Kopfraum zu geben —
  `pack.threads=2`, `pack.windowMemory=64m`, `pack.deltaCacheSize=128m`. Der direkte Weg über
  eine `[git.config]`-Sektion in `values.yaml` hat am 2026-09-01 Gitea zweimal lahmgelegt
  (siehe Stolperfallen); die Escape-Variante `pack_0X2E_threads` ist plausibel, **aber
  ungetestet**. Deshalb bewusst zurückgestellt: nicht isoliert deployen, sondern **beim
  nächsten ohnehin anstehenden Gitea-Upgrade** mit anhängen — da ist das Wartungsfenster,
  das DB-Backup und der GitHub-Values-Fallback sowieso vorbereitet. Vorher am Image
  verifizieren, dass `environment-to-ini` das `_0X2E_` auch im Key dekodiert, z.B.:
  ```bash
  kubectl -n gitea exec deploy/gitea -c gitea -- env \
    GITEA__GIT_0X2E_CONFIG__PACK_0X2E_THREADS=2 gitea help >/dev/null
  # bzw. Testcontainer mit dem Chart-Init-Script, NICHT direkt in main mergen
  ```
  Wird das Tuning wirksam, kann das Limit bei 2Gi bleiben (Sicherheitspuffer) oder später
  wieder gesenkt werden.

## Rollback-Plan

> **Wichtig:** `root-infrastructure` **zuerst** deaktivieren — sonst stellt es die `gitea`-App
> sofort zurück und der Rollback schlägt fehl.

```bash
# 1. Beide Auto-syncs deaktivieren (root-infrastructure ZUERST)
kubectl patch application root-infrastructure -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl patch application gitea -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'

# 2. Letzte funktionierende Revision aus History ermitteln und rollbacken
argocd app history gitea
argocd app rollback gitea <letzte-funktionierende-ID>

# 3. Beide Dateien im Repo zurücksetzen und pushen
#    gitops/config/gitea/values.yaml: image.tag zurück auf alte Version
#    gitops/apps/gitea/gitea.yaml: targetRevision zurück auf alte Chart-Version
git add gitops/config/gitea/values.yaml gitops/apps/gitea/gitea.yaml
git commit -m "revert: gitea rollback <neu> → <alt>"
git push

# 4. root-infrastructure syncen (liest Revert-Commit)
argocd app sync root-infrastructure

# 5. Auto-syncs reaktivieren
kubectl patch application root-infrastructure -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
kubectl patch application gitea -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

> Falls die DB-Migration bereits gelaufen ist: Rollback auf die alte Version **nicht sicher**.
> In diesem Fall PostgreSQL-Backup einspielen oder auf der neuen Version verbleiben und Fehler
> debuggen.

## Referenzen

- GitHub Releases / Chart-Changelog: https://gitea.com/gitea/helm-gitea/releases
- Gitea Release Notes 1.25.x: https://blog.gitea.com/release-of-1.25.0/
- Interne Doku: [GITEA-DEPLOYMENT.md](../GITEA-DEPLOYMENT.md) — initiale Deployment-Dokumentation
- Interne Doku: [GITEA-CLEANUP.md](../GITEA-CLEANUP.md) — vollständiger Neuaufbau falls nötig
- [gitea-actions-runner.md](gitea-actions-runner.md) — Runbook für die abhängige `gitea-actions`-App
- [Traefik-Runbook Anhang: ed25519-Hostkey](traefik.md) — SSH-Hostkey-Reparatur ArgoCD ↔ Gitea
