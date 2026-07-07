# Upgrade Runbook: Guacamole

## Metadaten
- **Namespace:** `guacamole`
- **Aktuelle Version:** `guacamole/guacamole:1.6.0` und `guacamole/guacd:1.6.0` (siehe `gitops/config/guacamole/guacamole.yaml` bzw. `guacd.yaml`, jeweils Deployment- und InitContainer-Image)
- **Quelle:** Docker Hub Images `guacamole/guacamole` und `guacamole/guacd` (kein Helm-Chart, plain Kubernetes-YAML via Kustomize)
- **ArgoCD App-Name:** `guacamole`
- **Versions-Check-Quelle:** Docker-Hub-Tag-Vergleich für `guacamole/guacamole` und `guacamole/guacd` (siehe `IMAGE_SERVICES`-Eintrag in `scripts/upgrade-agent.py`: `image_pattern` matcht die `image:`-Zeile in `gitops/config/guacamole/guacamole.yaml` bzw. `guacd.yaml`, `version_type: dockerhub`, referenzierter GitHub-Upstream für Release Notes: `apache/guacamole-client` bzw. `apache/guacamole-server`)
- **Major/Minor-Kriterium:** Standard-SemVer-Regel des Upgrade-Checkers (`version_bump_type()`): erste Versionsstelle ändert sich → Major, zweite Stelle ändert sich → Minor, sonst Patch. Besonderheit: Es gibt eine begleitende PostgreSQL-Datenbank (Schema-Setup in `gitops/config/guacamole/postgres-setup.sql`), deren Schema-Init nur beim allerersten Start läuft (InitContainer `generate-schema` + `init-schema`, idempotent via `|| true`). In `gitops/apps/guacamole.yaml` ist deshalb ein `ignoreDifferences`-Eintrag für `spec.template.spec.initContainers` des Deployments `guacamole` gesetzt, damit ArgoCD den Drift nach dem Erststart nicht als Sync-Problem meldet. Bei Guacamole-Versionen mit DB-Schema-Änderungen (Upstream-Migrationsskripte) muss das Schema-Upgrade **manuell** eingespielt werden — die InitContainer-Logik führt kein Schema-Upgrade aus, nur eine erstmalige Initialisierung.

## Changelog

| Datum | Von → Nach | Typ | Ausführung | Status | Begründung | Notiz |
|---|---|---|---|---|---|---|
| unbekannt | ... → 1.6.0 | ... | ... | ... | Historie vor Einführung des strukturierten Runbooks nicht vollständig rekonstruierbar | — |
| 2026-03-17 | Ersteinführung: 1.6.0 | — | Manuell | Abgeschlossen | Initiales Deployment von Guacamole als Remote-Access-Gateway (SSH/RDP/VNC), keine Versions-Migration — Startversion 1.6.0 für sowohl `guacamole` als auch `guacd`, Anbindung an bestehende Gitea-PostgreSQL-Instanz | Commit `c355d0a`; Folgefixes am selben Tag/Folgetag: `85012ce` (ArgoCD repoURL-Korrektur), `6a40507` (IngressRoute → Standard-Ingress), `82f57dd` (postgres:16-alpine für init-schema, da `psql` im Guacamole-Image fehlt) |

### Reklassifizierungen (Minor → Major)

| Datum Erkennung | Ursprünglicher Changelog-Eintrag (Datum) | Grund der Reklassifizierung | Erneute Benachrichtigung gesendet am |
|---|---|---|---|

## Manuelle Vorgehensweise (bei Major/Breaking Change)

Es gibt bislang **keine dokumentierte reale Versions-Upgrade-Historie** für Guacamole — seit dem initialen Deployment am 2026-03-17 lief durchgehend Version 1.6.0. Die folgende Vorgehensweise ist daher vorsorglich aus der Architektur und den vorhandenen Stolperfallen abgeleitet, nicht aus einem bereits durchgeführten Upgrade.

### Phase 1: Pre-Upgrade Checks

```bash
# ArgoCD App Status
argocd app get guacamole

# Aktuelle Image-Tags bestätigen
grep -A1 "image: guacamole/guacamole" gitops/config/guacamole/guacamole.yaml
grep "image: guacamole/guacd" gitops/config/guacamole/guacd.yaml

# Pods laufen?
kubectl get pods -n guacamole -o wide

# DB-Connectivity prüfen (externe Gitea-PostgreSQL)
kubectl get secret guacamole-db-secret -n guacamole -o jsonpath='{.data.hostname}' | base64 -d
```

Release Notes des Ziel-Tags gegen die aktuelle Version prüfen (insbesondere auf DB-Schema-Migrationsskripte, siehe Apache-Guacamole-Upgrade-Doku — bei Versionssprüngen über mehrere Minor-Releases hinweg müssen ggf. mehrere Migrations-SQL-Skripte nacheinander eingespielt werden).

### Phase 2: Wartungsfenster & Backup

```bash
# PostgreSQL-Datenbank von Guacamole sichern (liegt in der externen Gitea-PostgreSQL-Instanz)
kubectl exec -it -n gitea <gitea-postgresql-pod> -- \
  pg_dump -U gitea -d guacamole > /tmp/guacamole-db-backup-$(date +%Y%m%d).sql

# Aktuelle Manifeste sichern
cp gitops/config/guacamole/guacamole.yaml /tmp/guacamole-deployment-backup-$(date +%Y%m%d).yaml
cp gitops/config/guacamole/guacd.yaml /tmp/guacd-deployment-backup-$(date +%Y%m%d).yaml

git status
git log --oneline -3 -- gitops/config/guacamole/
```

### Phase 3: Upgrade durchführen

```bash
# Image-Tags in beiden Manifesten anheben (Guacamole und guacd sollten auf derselben
# Minor-Version gehalten werden, da beide Teil desselben Apache-Guacamole-Release-Zyklus sind)
#   gitops/config/guacamole/guacamole.yaml   → 2x image: guacamole/guacamole:<neu>
#                                               (Deployment-Container UND InitContainer generate-schema)
#   gitops/config/guacamole/guacd.yaml       → image: guacamole/guacd:<neu>

git add gitops/config/guacamole/guacamole.yaml gitops/config/guacamole/guacd.yaml
git commit -m "chore: upgrade guacamole/guacd <alt> → <neu>"
git push

argocd app sync guacamole
```

Falls das Ziel-Release ein DB-Schema-Upgrade erfordert (siehe Apache-Guacamole-Upgrade-Doku für den jeweiligen Versionssprung): das mitgelieferte Upgrade-SQL-Skript **manuell** gegen die Datenbank fahren, bevor bzw. unmittelbar nachdem die neuen Pods hochkommen — die vorhandene InitContainer-Logik (`generate-schema` + `init-schema`) erzeugt nur das Erst-Schema und führt `|| true` aus, überspringt also bereits vorhandene Tabellen stillschweigend statt sie zu migrieren.

### Phase 4: Upgrade beobachten

```bash
kubectl get pods -n guacamole -w

# Neue Image-Version in laufenden Pods bestätigen
kubectl get pod -n guacamole -l app=guacamole -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'
kubectl get pod -n guacamole -l app=guacd -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'

# InitContainer-Logs prüfen (generate-schema / init-schema)
kubectl logs -n guacamole -l app=guacamole -c generate-schema --tail=20
kubectl logs -n guacamole -l app=guacamole -c init-schema --tail=20
```

### Phase 5: Post-Upgrade Verifikation

```bash
# HTTP erreichbar?
curl -sk https://guacamole.reckeweg.io/guacamole/ -o /dev/null -w "%{http_code}\n"
# 200 erwartet

# Login testen (lokales Konto, Phase 1 — OIDC ist aktuell deaktiviert: OPENID_ENABLED=false)
# guacd erreichbar von guacamole aus?
kubectl exec -it -n guacamole deploy/guacamole -- nc -zv guacd 4822

argocd app get guacamole   # Sync Status: Synced, Health Status: Healthy
```

### Phase 6: Post-Upgrade Housekeeping

- Bestehende Verbindungsdefinitionen (SSH/RDP/VNC) in der UI stichprobenartig testen.
- Falls das Upgrade neue Umgebungsvariablen oder Auth-Extensions einführt (z.B. spätere Aktivierung von Keycloak-OIDC laut `OPENID_ENABLED`), Doku in `docs/GUACAMOLE.md` gegenprüfen und ggf. aktualisieren.

## Bekannte Stolperfallen / Lessons Learned

- **`psql` fehlt im offiziellen `guacamole/guacamole`-Image** — der InitContainer, der das SQL-Schema in Postgres einspielt, kann daher nicht mit dem Guacamole-Image selbst laufen. Fix: zweistufiger InitContainer-Ansatz — `generate-schema` (Image `guacamole/guacamole`) erzeugt nur das SQL-Skript, `init-schema` (Image `postgres:16-alpine`) spielt es per `psql` ein. Entdeckt und gefixt am 2026-03-18 (Commit `82f57dd`).
- **Traefik `IngressRoute` funktionierte initial nicht** — wurde durch Standard-Kubernetes-`Ingress` ersetzt. Fix am 2026-03-18 (Commit `6a40507`); Details zur genauen Ursache sind im Commit nicht weiter ausgeführt — vor einem erneuten Wechsel zurück auf `IngressRoute` den damaligen Grund verifizieren.
- **Externe PostgreSQL-Instanz hat keinen `postgres`-Superuser** — die mit Gitea ausgelieferte PostgreSQL-Installation legt nur den `gitea`-User an (mit `CREATEDB`-Recht, aber kein Superuser). Die Guacamole-Datenbank muss daher mit dem `gitea`-User angelegt werden, nicht mit `postgres` (siehe `gitops/config/guacamole/postgres-setup.sql` und `docs/GUACAMOLE.md`).
- **`ignoreDifferences` für InitContainers ist beabsichtigt, kein Bug** — `gitops/apps/guacamole.yaml` ignoriert Drift in `spec.template.spec.initContainers` des Deployments, weil die Schema-Init nur beim allerersten Start effektiv etwas tut; spätere Sync-Vorgänge dürfen hier nicht als "nicht synced" markiert werden. Bei Upgrades, die tatsächlich ein neues InitContainer-Verhalten brauchen (z.B. eine echte Migrations-Logik), diesen `ignoreDifferences`-Eintrag im Hinterkopf behalten — er verdeckt ggf. auch gewollte Änderungen am InitContainer-Spec bis zum nächsten vollständigen Diff-Review.
- **OIDC/Keycloak-Integration ist aktuell nicht aktiv** (`OPENID_ENABLED=false`, Phase 2 laut `docs/GUACAMOLE.md`) — reines lokales `guacadmin`-Login. Bei zukünftigen Versions-Upgrades mit Änderungen an der OIDC-Extension ist das Risiko dadurch aktuell nicht schlagend, sollte aber beim Aktivieren von Phase 2 erneut geprüft werden.

## Rollback-Plan

```bash
# Image-Tags in beiden Manifesten auf die vorherige Version zurücksetzen
git revert <upgrade-commit-hash>
git push

argocd app sync guacamole --force
kubectl get pods -n guacamole -w
```

Bei DB-Schema-Änderungen durch das fehlgeschlagene Upgrade: das vor dem Upgrade gezogene `pg_dump`-Backup zurückspielen, bevor die alten Images wieder hochgefahren werden:

```bash
kubectl exec -it -n gitea <gitea-postgresql-pod> -- \
  psql -U gitea -d guacamole < /tmp/guacamole-db-backup-<datum>.sql
```

## Referenzen

- GitHub Releases: https://github.com/apache/guacamole-client/releases (Webapp), https://github.com/apache/guacamole-server/releases (guacd)
- Apache Guacamole Upgrade-Doku: https://guacamole.apache.org/doc/gug/upgrading-guacamole.html
- Interne Doku: `docs/GUACAMOLE.md` (Architektur, Auth-Phasen, Setup-Anleitung)
- Lokales Repo: `gitops/apps/guacamole.yaml`, `gitops/config/guacamole/`
