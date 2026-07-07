# Upgrade Runbook: Gitea Actions Runner (act_runner)

## Metadaten
- **Namespace:** gitea
- **Aktuelle Version:** Helm-Chart `actions` 0.1.1, Runner-Image `docker.io/gitea/act_runner:nightly`
- **Quelle:** Helm-Chart-Repo `https://dl.gitea.com/charts/` (Chart `actions`); Runner-Image von Docker Hub (`gitea/act_runner`)
- **ArgoCD App-Name:** gitea-actions
- **Versions-Check-Quelle:** `homelab-version-checker` (CronJob, `gitops/config/monitoring/homelab-version-checker-v2.yaml`) vergleicht per `helm search repo actions --versions` gegen `targetRevision` in `gitops/apps/gitea/gitea-actions.yaml` — generischer Helm-Chart-Versionsvergleich für ArgoCD-Applications, kein Sonder-Mapping wie bei GitHub-Komponenten. Das Runner-Image-Tag (`nightly`) wird davon nicht separat getrackt.
- **Major/Minor-Kriterium:** Standardregel (SemVer-Sprung im Helm-Chart). Chart-Minor-Bumps können trotzdem Breaking Changes enthalten (siehe 0.1.0 → 0.1.1: Ressourcen-Umbenennung `act-runner` → `runner`) — Release Notes des Charts vor jedem Bump prüfen, nicht nur die Versionsnummer.

**Hinweis zu Config-Dateien:** Die aktiv genutzten Helm-Values liegen in `gitops/config/gitea-actions/values.yaml` (referenziert via `valueFiles` aus `gitops/apps/gitea/gitea-actions.yaml`). Die Datei `gitops/config/gitea/actions-values.yaml` sowie `gitops/config/gitea/actions/` (nur `kustomization.yaml` + SealedSecret) sind ältere/andere Config-Pfade aus der ursprünglichen Chart-0.0.x/0.1.0-Einführung (Februar–April 2026, `actRunner`-Key, Image-Tag `0.3.1`, `giteaRootURL` intern) und **nicht mehr der aktuelle Konfigurationsstand** — nicht mit `gitops/config/gitea-actions/values.yaml` verwechseln.

## Changelog

| Datum | Von → Nach | Typ | Ausführung | Status | Begründung | Notiz |
|---|---|---|---|---|---|---|
| unbekannt | ... | ... | ... | ... | Historie vor Einführung des strukturierten Runbooks nicht vollständig rekonstruierbar | — |
| 2026-04-27 | Chart 0.0.3 → 0.1.0 | Minor | Manuell | Abgeschlossen | Erstes funktionsfähiges Setup nach mehreren Config-Iterationen (storageClass-Rendering, k8s-1.28-Kompatibilität) | Mehrere Nachbesserungs-Commits am selben Tag (`05e1118`, `e8e9800`) |
| 2026-04-28 | Chart 0.1.0 entfernt | — | Manuell | Abgeschlossen | Temporär entfernt bis k3s-Upgrade abgeschlossen war | Commit `1d321b8` |
| 2026-04-29 | Chart 0.1.0 neu eingeführt | Minor | Manuell | Abgeschlossen | Neuaufbau mit `existingSecret` (SealedSecret-Referenz statt Klartext) und DinD; mehrere Nachbesserungen am selben Tag (valuesObject → valueFiles wegen YAML-Block-Scalar-Problemen, `actRunner.config` entfernt, `global.storageClass` entfernt wegen nindent-Bug im Chart) | Commits `75382c2`, `1a56196`, `4bb2236`, `a0dff28`, `0afeb13` |
| 2026-05-05 | Runner-Image-Registry-Wechsel | — | Manuell | Abgeschlossen | `docker.gitea.com` als Registry für `act_runner` abgelöst zugunsten von `docker.io/gitea/act_runner:0.6.1` | Commit `cae1225` |
| 2026-05-18 | Resource-Anpassung | — | Manuell | Abgeschlossen | Runner-Resources für Multi-Arch-Builds erhöht; PVC-Size-Änderung wieder zurückgenommen (StatefulSet `volumeClaimTemplates` sind immutable) | Commits `b5a211b`, `f4d3f19` |
| 2026-05-26 | Chart 0.1.0 → 0.1.1 | Minor (Breaking Change) | Manuell | Abgeschlossen | Chart benennt alle `act-runner`-Referenzen in `runner` um (StatefulSet, PVC-Template, values-Key `statefulset.actRunner` → `statefulset.runner`); ArgoCD löscht alten StatefulSet/PVC und legt neue an, altes PVC (nur Docker-Layer-Cache) muss manuell nachträglich gelöscht werden | Vollständiges Vorgehen siehe „Manuelle Vorgehensweise" unten |
| 2026-06-01 | Runner-Image 0.6.1 → nightly | Minor→Major (faktisch) | Manuell | Abgeschlossen | Umstieg auf `nightly`-Tag nötig, um mehrere aufeinanderfolgende Laufzeit-Bugs zu beheben (siehe Stolperfallen); vier Folge-Fixes am selben Tag (Image-Remap, tmpfs-Workaround, `workdir_parent`, schließlich `host://`-Execution) | Commits `c48822c`, `af9e27b`, `15577df`, `d75876c`, `0ca9b2c` |

### Reklassifizierungen (Minor → Major)

| Datum Erkennung | Ursprünglicher Changelog-Eintrag (Datum) | Grund der Reklassifizierung | Erneute Benachrichtigung gesendet am |
|---|---|---|---|
| 2026-06-01 | 2026-05-05 (Runner-Image 0.6.1) | Der scheinbar simple Registry-/Versions-Wechsel auf `act_runner:0.6.1` erwies sich am 2026-06-01 als nicht produktionsstabil für `ubuntu-latest`-Jobs (symlink-/mkdirat-Probleme in mehreren Runner-Images); erforderte vier aufeinanderfolgende Not-Fixes bis zur `host://`-Execution-Lösung, faktisch eine Breaking-Change-Behandlung trotz Patch-Versionssprung | — (kein separater E-Mail-Alert-Mechanismus für Runner-Image-Tags; nur Chart-Version wird vom Checker überwacht) |

## Manuelle Vorgehensweise (bei Major/Breaking Change)

Beispiel: Chart-Upgrade 0.1.0 → 0.1.1 (Ressourcen-Umbenennung `act-runner` → `runner`).

### Breaking Changes 0.1.0 → 0.1.1

| Ressource | Alt (0.1.0) | Neu (0.1.1) |
|-----------|------------|------------|
| StatefulSet | `gitea-actions-act-runner` | `gitea-actions-runner` |
| PVC-Template | `data-act-runner` | `data-runner` |
| PVC-Name (Pod 0) | `data-act-runner-gitea-actions-act-runner-0` | `data-runner-gitea-actions-runner-0` |
| values-Key | `statefulset.actRunner` | `statefulset.runner` |

**Konsequenz:**
- ArgoCD löscht den alten StatefulSet (`act-runner`) und erstellt einen neuen (`runner`).
- Das neue PVC (`data-runner-gitea-actions-runner-0`) wird frisch angelegt (Longhorn).
- Das alte PVC (`data-act-runner-...`) wird orphaned → enthielt nur Docker Layer Cache, der sich beim ersten Build neu aufbaut → **kein Datenverlust**.
- Das alte PVC muss nach dem Upgrade manuell gelöscht werden.

### Phase 1: Pre-Upgrade Checks

```bash
# ArgoCD Application Status
kubectl -n argocd get application gitea-actions
# Erwartet: Synced, Healthy

# Aktueller StatefulSet
kubectl get statefulset -n gitea

# Aktuelles PVC
kubectl get pvc -n gitea | grep act-runner

# Keine laufenden Jobs
# https://gitea.reckeweg.io/-/admin/runners → kein aktiver Job
```

### Phase 2: values.yaml anpassen

**Datei:** `gitops/config/gitea-actions/values.yaml`

`actRunner` → `runner` umbenennen (Key-Rename, Inhalt bleibt gleich):

```yaml
# ALT
  actRunner:
    registry: docker.io
    repository: gitea/act_runner
    tag: "0.6.1"

# NEU
  runner:
    registry: docker.io
    repository: gitea/act_runner
    tag: "0.6.1"
```

### Phase 3: Chart-Version erhöhen

**Datei:** `gitops/apps/gitea/gitea-actions.yaml`

```yaml
# ALT
targetRevision: 0.1.0
# NEU
targetRevision: 0.1.1
```

### Phase 4: Commit & ArgoCD Sync

```bash
git add gitops/config/gitea-actions/values.yaml
git add gitops/apps/gitea/gitea-actions.yaml
git commit -m "chore: upgrade gitea-actions chart 0.1.0 → 0.1.1

Breaking change: statefulset.actRunner renamed to statefulset.runner.
StatefulSet and PVC names change accordingly — old PVC (Docker cache)
will be orphaned and must be deleted manually after upgrade."
git push
```

In ArgoCD Sync manuell auslösen oder auf Auto-Sync warten.

### Phase 5: Post-Upgrade Verifikation

```bash
# Neuer StatefulSet läuft
kubectl get statefulset -n gitea
# Erwartet: gitea-actions-runner   1/1

# Neuer Pod läuft
kubectl get pods -n gitea | grep runner
# Erwartet: gitea-actions-runner-0   2/2   Running

# Runner in Gitea registriert
# https://gitea.reckeweg.io/-/admin/runners → Runner "gitea-actions-runner-0" online

# Neues PVC vorhanden
kubectl get pvc -n gitea
# Erwartet: data-runner-gitea-actions-runner-0   Bound
```

> **Hinweis zu 2/2:** DinD ist als Kubernetes Native Sidecar implementiert (Init-Container mit `restartPolicy: Always`, ab Kubernetes 1.29 verfügbar). Der Pod zeigt `2/2 Running` — DinD zählt als Sidecar-Init-Container und erscheint in `kubectl logs` als `dind (init)`, läuft aber dauerhaft mit.

### Phase 6: Altes PVC aufräumen

```bash
kubectl delete pvc -n gitea data-act-runner-gitea-actions-act-runner-0

kubectl get pvc -n gitea | grep act-runner
# Erwartet: keine Ausgabe
```

## Bekannte Stolperfallen / Lessons Learned

- **`ubuntu-latest`-Runner-Images mit `/var/run`-Symlink brechen `act_runner`-Extraktion:** `act_runner` hardcodet den Extraktionspfad `/var/run/act/`. Moderne Runner-Images (u. a. `docker.gitea.com/runner-images:ubuntu-latest`) haben `/var/run` als Symlink auf `/run`, wodurch `mkdirat var/run: file exists` fehlschlägt. Chronologie der Fixversuche am 2026-06-01:
  1. Remap auf `catthehacker/ubuntu:act-22.04`-Images (echtes `/var/run`-Verzeichnis) — Commit `af9e27b`.
  2. tmpfs-Mount auf `/var/run` als Workaround (`options: "--tmpfs /var/run:rw,nosuid,exec"`) — Commit `15577df`. Nicht ausreichend, da `CopyToContainer` im Docker-Daemon direkt auf dem Overlay-Filesystem arbeitet und Runtime-Mounts umgeht.
  3. `workdir_parent: /tmp/act` gesetzt, um Extraktion komplett an `/var/run` vorbeizuleiten — Commit `d75876c`.
  4. Endgültige Lösung: Umstieg auf **`host://`-Execution** statt `docker://` für alle Runner-Labels (`ubuntu-latest:host://`, `ubuntu-22.04:host://`, `ubuntu-20.04:host://`) — Jobs laufen direkt im Runner-Pod, `git` ist im `act_runner:nightly`-Image unter `/usr/bin/git` verfügbar. Damit entfällt das Symlink-Problem grundsätzlich, da keine Container mehr für die Job-Ausführung erstellt werden. Commit `0ca9b2c`.
- **Registry-Wechsel `docker.gitea.com` → `docker.io/gitea/act_runner`:** Die ursprüngliche Chart-Doku (`gitops/config/gitea/actions-values.yaml`) referenzierte `docker.gitea.com/act_runner`; diese Registry wurde zugunsten von `docker.io/gitea/act_runner` abgelöst (Commit `cae1225`, 2026-05-05).
- **`global.storageClass` löst nindent-Bug im Chart-Helper aus:** Führt zu YAML-Rendering-Fehlern; stattdessen `storageClass` direkt unter `persistence` setzen (Commit `a0dff28`).
- **`valuesObject` mit verschachtelten YAML-Block-Scalars problematisch:** ArgoCD-`valuesObject` (inline in der Application) verursachte Parse-Fehler bei mehrzeiligen `config:`-Blöcken; Umstieg auf `valueFiles` mit separater `values.yaml` über einen zweiten Git-Source (`ref: values`) behoben (Commits `1a56196`, `0afeb13`).
- **StatefulSet-PVC-Größe ist immutable:** Eine versuchte PVC-Size-Änderung musste zurückgenommen werden, da `volumeClaimTemplates` eines StatefulSets nach Erstellung nicht mehr änderbar sind (Commit `f4d3f19`, 2026-05-18). Für eine PVC-Größenänderung ist ein manueller PVC-Ersatz (wie beim 0.1.0→0.1.1-Rename) nötig.
- **Alte Config-Datei `gitops/config/gitea/actions-values.yaml` nicht mehr aktuell:** Stammt aus der Chart-0.1.0-Einführungsphase (Februar/April 2026) und wird von der aktuell aktiven ArgoCD-Source nicht mehr referenziert — nur `gitops/config/gitea-actions/values.yaml` ist live. Verwirrungsgefahr bei künftigen Änderungen.

## Rollback-Plan

Falls der neue Runner-Pod nach einem Chart-Upgrade nicht startet:

```bash
# Chart-Version zurücksetzen
# gitops/apps/gitea/gitea-actions.yaml: targetRevision auf vorherige Version
# gitops/config/gitea-actions/values.yaml: entsprechenden values-Key zurückbenennen
git revert HEAD
git push
# ArgoCD Sync abwarten
```

> **Hinweis:** Beim 0.1.0→0.1.1-Rename existieren der alte StatefulSet `gitea-actions-act-runner` und das alte PVC noch bis Phase 6 (PVC-Cleanup) abgeschlossen ist — Rollback ist bis dahin problemlos möglich, da keine Daten gelöscht wurden.

Für Runner-Image-Probleme (z. B. `nightly`-Tag instabil): Tag in `gitops/config/gitea-actions/values.yaml` auf die letzte bekannt funktionierende Version zurücksetzen und Runner-Labels ggf. wieder auf `docker://`-Execution umstellen (siehe Stolperfallen), falls `host://` in einer neueren Chart-/Image-Version Probleme verursacht.

## Referenzen
- GitHub Releases / Chart-Quelle: https://gitea.com/gitea/helm-actions, Helm-Repo `https://dl.gitea.com/charts/`
- act_runner Image: https://hub.docker.com/r/gitea/act_runner
- Interne Doku: `gitops/apps/gitea/gitea-actions.yaml`, `gitops/config/gitea-actions/values.yaml`
