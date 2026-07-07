# Upgrade Runbook: WordPress + MySQL

## Metadaten
- **Namespace:** `wordpress`
- **Aktuelle Version:** `wordpress:6.4-apache` (Docker-Image-Tag, per Live-Cluster-Inspektion am 2026-07-07 bestätigt); MySQL 8.0 (`mysql:8.0`)
- **Quelle:** unbekannt — nicht in `gitops/` oder ArgoCD verwaltet; Kustomize-Label (`managed-by=kustomize`) deutet auf ursprüngliche kubectl/kustomize-Anwendung aus einem nicht auffindbaren Verzeichnis hin
- **ArgoCD App-Name:** — (keine ArgoCD-Application vorhanden)
- **Versions-Check-Quelle:** aktuell keine — müsste zuerst durch Wiederherstellung der Kustomize-Quelle oder Migration in `gitops/apps/` nachgerüstet werden
- **Major/Minor-Kriterium:** n/a, bis Quelle geklärt ist

## Changelog

| Datum | Von → Nach | Typ | Ausführung | Status | Begründung | Notiz |
|---|---|---|---|---|---|---|
| unbekannt | ... | ... | ... | ... | Historie vor Einführung des strukturierten Runbooks nicht vollständig rekonstruierbar | — |

### Reklassifizierungen (Minor → Major)

| Datum Erkennung | Ursprünglicher Changelog-Eintrag (Datum) | Grund der Reklassifizierung | Erneute Benachrichtigung gesendet am |
|---|---|---|---|

## Manuelle Vorgehensweise (bei Major/Breaking Change)

**Es gibt aktuell keine GitOps-/Kustomize-Quelle, die diese Deployments deklarativ verwaltet.** Die folgende Vorgehensweise ist generischer, imperativer kubectl-Fallback für ein unmanaged Deployment — kein chart- oder kustomize-spezifisches Verfahren, da keines auffindbar ist.

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

2. **Image-Tag aktualisieren (imperativ, da keine Git-Quelle bekannt)**
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

- **KRITISCH — fehlende GitOps-Anbindung:** Dieser Dienst läuft produktiv (bestätigt unter `https://wordpress.reckeweg.io`, referenziert als Smoke-Test-URL in `docs/upgrades/traefik.md`), ist aber **nirgendwo als Quellcode auffindbar** — weder als ArgoCD-Application (`gitops/apps/`) in diesem Repo, noch als YAML/Kustomize-Overlay in diesem Repo oder in `seri-k8s`. Das Label `managed-by=kustomize` auf den laufenden Deployments beweist, dass ursprünglich ein Kustomize-Verzeichnis existiert haben muss — dessen Ablageort ist aber verloren oder nie eingecheckt worden.
- Exhaustive Suchen durchgeführt (2026-07-07): `git log --all --oneline -i --grep="wordpress"` in diesem Repo → keine Treffer. `grep -ril "wordpress" .` über dieses Repo → nur der Smoke-Test-Verweis in `traefik.md`. Beide Suchen auch gegen `seri-k8s` (separates, unabhängiges Repo) negativ.
- **Handlungsbedarf für den Nutzer:** Vor dem nächsten Upgrade-Versuch muss geklärt werden, woher dieses Deployment ursprünglich kam — z.B. ein lokales Verzeichnis auf einer anderen Maschine, ein gelöschter/nicht gepushter Branch, oder eine rein manuelle `kubectl apply -k`-Anwendung ohne Versionskontrolle. Bis dahin ist jedes Upgrade ein Blindflug ohne Rollback-Garantie über Git hinaus.
- Empfehlung: Sobald die Quelle rekonstruiert oder neu aufgesetzt ist, als ArgoCD-Application unter `gitops/apps/wordpress.yaml` migrieren, damit künftige Upgrades denselben strukturierten Prozess wie die anderen Dienste durchlaufen können.

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

- GitHub Releases: n/a (kein spezifisches Repo bekannt — offizielles WordPress-Docker-Image: https://hub.docker.com/_/wordpress, MySQL: https://hub.docker.com/_/mysql)
- Interne Doku/Slides: keine bekannt
- Querverweis: `docs/upgrades/traefik.md` (Smoke-Test-URL `https://wordpress.reckeweg.io`)
