# Upgrade Runbook: WordPress + MySQL

## Metadaten
- **Namespace:** `wordpress`
- **Aktuelle Version:** `wordpress:6.4-apache` (Docker-Image-Tag, per Live-Cluster-Inspektion am 2026-07-07 bestätigt); MySQL 8.0 (`mysql:8.0`)
- **Quelle:** Manuell installiert (kubectl/kustomize direkt gegen den Cluster, `managed-by=kustomize`-Label). **Bewusst nicht in GitOps/ArgoCD verwaltet** — dieser Dienst gehört nicht ins Tracking dieses Repos.
- **ArgoCD App-Name:** — (keine ArgoCD-Application, absichtlich)
- **Versions-Check-Quelle:** keine — läuft außerhalb des homelab-version-checkers, kein automatischer Check vorgesehen
- **Major/Minor-Kriterium:** n/a — Upgrades erfolgen ausschließlich manuell, nach Bedarf

## Changelog

| Datum | Von → Nach | Typ | Ausführung | Status | Begründung | Notiz |
|---|---|---|---|---|---|---|
| unbekannt | ... | ... | ... | ... | Historie vor Einführung des strukturierten Runbooks nicht rekonstruierbar (Deployment liegt außerhalb von Git) | — |

### Reklassifizierungen (Minor → Major)

| Datum Erkennung | Ursprünglicher Changelog-Eintrag (Datum) | Grund der Reklassifizierung | Erneute Benachrichtigung gesendet am |
|---|---|---|---|

## Manuelle Vorgehensweise (bei Major/Breaking Change)

Es gibt bewusst keine GitOps-/Kustomize-Quelle in diesem Repo für diese Deployments — Upgrades laufen ausschließlich imperativ per `kubectl`.

1. **Vorbereitung / Backup**
   ```bash
   # Aktuellen Zustand dokumentieren
   kubectl -n wordpress get deployment wordpress -o yaml > wordpress-deployment-backup-$(date +%Y%m%d).yaml
   kubectl -n wordpress get deployment mysql -o yaml > mysql-deployment-backup-$(date +%Y%m%d).yaml

   # MySQL-Datenbank-Dump (WordPress-Inhalte, essentiell vor jedem Upgrade)
   kubectl -n wordpress exec deployment/mysql -- \
     mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" --all-databases > wordpress-db-backup-$(date +%Y%m%d).sql

   # Persistente Volumes / wp-content sichern, falls PVC vorhanden
   kubectl -n wordpress get pvc
   ```

2. **Image-Tag aktualisieren**
   ```bash
   kubectl -n wordpress set image deployment/wordpress wordpress=wordpress:<neue-version>-apache
   kubectl -n wordpress rollout status deployment/wordpress
   ```

3. **MySQL-Upgrade (falls betroffen) getrennt und vorsichtig behandeln**
   ```bash
   kubectl -n wordpress set image deployment/mysql mysql=mysql:<neue-version>
   kubectl -n wordpress rollout status deployment/mysql
   ```
   MySQL-Major-Upgrades (z.B. 8.0 → 8.4 oder 8.x → 9.x) können inkompatible Storage-Engine-/Auth-Plugin-Änderungen mit sich bringen — vorher Release Notes von MySQL prüfen und Restore-Fähigkeit des Dumps aus Schritt 1 sicherstellen.

4. **Smoke-Test**
   ```bash
   curl -s -o /dev/null -w "%{http_code}" https://wordpress.reckeweg.io
   # Login/Admin-Bereich manuell prüfen
   ```

## Bekannte Stolperfallen / Lessons Learned

- **Absichtlich nicht in GitOps verwaltet.** Dieser Dienst läuft produktiv (bestätigt unter `https://wordpress.reckeweg.io`, referenziert als Smoke-Test-URL in `docs/upgrades/traefik.md`), ist aber weder als ArgoCD-Application noch als YAML/Kustomize-Overlay in diesem oder im `seri-k8s`-Repo hinterlegt — das ist beabsichtigt, kein Versehen. Kein automatischer Check, kein ArgoCD-Self-Heal, kein Git-Rollback.
- Da nichts in Git liegt, ersetzt dieses Runbook die fehlende deklarative Quelle durch eine rein imperative Vorgehensweise (kubectl `set image` / `rollout undo`). Vor jedem Upgrade unbedingt Backup + DB-Dump anlegen (siehe oben), da es keinen anderen Wiederherstellungsweg gibt.

## Rollback-Plan

Da kein Deployment-Manifest in Git existiert, ist ein Git-basierter Rollback (wie bei ArgoCD-verwalteten Diensten) nicht möglich. Generischer kubectl-Fallback:

```bash
# Rollout-Historie prüfen (funktioniert nur, wenn Revision-History nicht durch zwischenzeitliche Änderungen verloren ging)
kubectl -n wordpress rollout history deployment/wordpress
kubectl -n wordpress rollout undo deployment/wordpress

kubectl -n wordpress rollout history deployment/mysql
kubectl -n wordpress rollout undo deployment/mysql

# Falls rollout undo nicht ausreicht: manuell auf vorheriges Image zurücksetzen
kubectl -n wordpress set image deployment/wordpress wordpress=wordpress:<alte-version>-apache
kubectl -n wordpress set image deployment/mysql mysql=mysql:<alte-version>

# Datenbank-Restore aus Backup, falls Migration die DB verändert hat
kubectl -n wordpress exec -i deployment/mysql -- \
  mysql -u root -p"$MYSQL_ROOT_PASSWORD" < wordpress-db-backup-<datum>.sql
```

## Referenzen

- GitHub Releases: n/a (kein spezifisches Repo — offizielles WordPress-Docker-Image: https://hub.docker.com/_/wordpress, MySQL: https://hub.docker.com/_/mysql)
- Interne Doku/Slides: keine bekannt
- Querverweis: `docs/upgrades/traefik.md` (Smoke-Test-URL `https://wordpress.reckeweg.io`)
