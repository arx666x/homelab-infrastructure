# Gitea Upgrade Runbook

**Ziel-Umgebung:** seri-k8s Homelab, k3s-Cluster (`reckeweg.io`)  
**Namespace:** `gitea`  
**Aktuell dokumentiert:** Chart 12.5.3 → 12.6.0 (Gitea App 1.25.5, unverändert)

---

## Architektur & Catch-22

### Setup-Übersicht

```
ArgoCD
  ├── gitea-postgresql  (wave 15) — externes StatefulSet, postgres:16-alpine, Longhorn 10Gi
  ├── gitea             (wave 20) — Helm Chart, Recreate-Strategy, Longhorn 50Gi
  └── gitea-actions     (wave 25) — act-runner + DinD
```

### Das Catch-22-Problem

ArgoCD bezieht die Values-Datei aus dem Gitea-Repo selbst:

```yaml
# gitops/apps/gitea/gitea.yaml
sources:
  - repoURL: https://dl.gitea.com/charts/     # Helm Chart — öffentlich, kein Problem
    chart: gitea
    targetRevision: 12.5.3
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

**Mitigation:** Vor dem Upgrade die ArgoCD-App temporär auf GitHub umstellen (Schritt 1).

> ⚠️ **Lernfeld aus vorherigen Upgrades:**
> - Upgrade auf 1.26.0 (Okt 2025): Initcontainer `configure-gitea` schlug fehl wegen `-o`-Flag, das in
>   1.26.0 entfernt wurde. Gitea blieb in `Init:CrashLoopBackOff` → ArgoCD-Deadlock.
> - Upgrade-Weg von 1.24.6 auf 1.26.0 (via 1.25.x): Registry-Wechsel `docker.gitea.com` → `docker.io`
>   für act_runner war nötig. Gitea selbst weiterhin über `docker.gitea.com/gitea`.

---

## Upgrade 12.5.3 → 12.6.0

**Datum:** 2026-05-18 — **ERFOLGREICH**  
**Aktuell:** Chart 12.5.3 / Gitea 1.25.5  
**Ziel:** Chart 12.6.0 / Gitea 1.26.1  
**Risiko:** 🟡 Mittel — kombinierter Chart- und App-Versions-Bump, DB-Migration

### Befund (2026-05-18)

Chart 12.6.0 ruft im Init-Container `init-app-ini` den Gitea-Binary mit dem Flag `-apply-env` auf.
Dieses Flag existiert in Gitea 1.25.5 nicht:

```
Incorrect Usage: flag provided but not defined: -apply-env
```

Der Pod blieb in `Init:CrashLoopBackOff` hängen. Gitea war nicht erreichbar → ArgoCD-Catch-22
vollständig eingetreten (ArgoCD konnte nicht mehr von `git.reckeweg.io` lesen).

**Rollback-Pfad (dokumentiert für Wiederholung):**

```bash
# 1. Auto-sync deaktivieren (root-infrastructure ZUERST, sonst wird gitea sofort zurückgestellt)
kubectl patch application root-infrastructure -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl patch application gitea -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'

# 2. Auf letzte funktionierende Revision rollbacken
argocd app history gitea   # letzte 12.5.3-Revision notieren
argocd app rollback gitea <ID>

# 3. gitea.yaml im Repo auf 12.5.3 zurücksetzen und pushen
# → git push reicht (pusht auf Gitea + GitHub gleichzeitig)

# 4. root-infrastructure syncen (liest neuen Revert-Commit)
argocd app sync root-infrastructure

# 5. Auto-sync wieder aktivieren
kubectl patch application root-infrastructure -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
kubectl patch application gitea -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

> ⚠️ **Lernfeld:** `root-infrastructure` hat `selfHeal: true` — es stellt die gitea-Application
> sofort zurück wenn ArgoCD drift erkennt. Deshalb muss `root-infrastructure` **zuerst** deaktiviert
> werden, bevor `gitea` deaktiviert wird.

**Ergebnis (2026-05-18):** `helm show chart gitea/gitea --version 12.6.0 | grep appVersion` → `appVersion: 1.26.1`

Chart 12.6.0 erfordert Gitea **1.26.1**. Der Upgrade ist ein kombinierter Chart- und App-Versions-Bump.

### Änderungen Chart 12.5.3 → 12.6.0 (korrigierte Übersicht)

| Bereich | Änderung | Betrifft uns? |
|---------|----------|---------------|
| Gitea App-Version | 1.25.5 → 1.26.1 (Chart-Default) | **Ja** — `image.tag` muss mitgehoben werden |
| Init-Container `init-app-ini` | `-o` Flag → `-apply-env` Flag | Fix: Chart 12.6.0 + App 1.26.1 zusammen upgraden |
| DB-Migration | Gitea führt Migrationen automatisch beim Start aus | Zu beobachten — nach Rollback nicht mehr möglich |
| Subchart-Versionen | Valkey/PostgreSQL-Subcharts können gebumpt sein | Irrelevant — alle Subcharts deaktiviert |

> ⚠️ **DB-Migration ist irreversibel.** Nach erfolgreichem Start von 1.26.1 laufen automatisch
> DB-Migrationen. Ein Rollback auf 1.25.5 wäre danach nicht mehr sicher möglich.
> Vor dem Upgrade sicherstellen dass ein aktuelles PostgreSQL-Backup existiert.

---

### Schritt 1: Pre-Flight-Checks

```bash
# Pods und PVCs gesund?
kubectl get pods -n gitea
kubectl get pvc -n gitea

# API erreichbar?
curl -s https://gitea.reckeweg.io/api/v1/version | jq .version
# → "1.25.5"

# ArgoCD Repo-Verbindung
argocd repo list
# → STATUS = Successful

# PostgreSQL erreichbar?
kubectl -n gitea exec deploy/gitea -- \
  sh -c 'PGPASSWORD=$GITEA__DATABASE__PASSWD psql -h gitea-postgresql -U gitea -c "\l"'

# Keine laufenden Actions Jobs
# https://gitea.reckeweg.io/-/admin/actions → alle Jobs abgeschlossen
```

---

### Schritt 2: DB-Backup vor dem Upgrade

> ⚠️ **Pflicht** — DB-Migration 1.25 → 1.26 ist nicht reversibel.

```bash
kubectl -n gitea exec gitea-postgresql-0 -- \
  sh -c 'PGPASSWORD=$POSTGRES_PASSWORD pg_dump -U gitea gitea | gzip' \
  > gitea-db-backup-pre-1.26.1-$(date +%Y%m%d-%H%M).sql.gz

# Größe prüfen (sollte > 0 sein)
ls -lh gitea-db-backup-pre-1.26.1-*.sql.gz
```

---

### Schritt 3: Beide Änderungen in einem Commit

Zwei Dateien gleichzeitig ändern und in einem einzigen Commit pushen:

**`gitops/config/gitea/values.yaml`** — Image-Tag anheben:
```yaml
image:
  tag: "1.26.1"    # war: "1.25.5"
```

**`gitops/apps/gitea/gitea.yaml`** — Chart-Version anheben:
```yaml
targetRevision: 12.6.0    # war: 12.5.3
```

```bash
git add gitops/config/gitea/values.yaml gitops/apps/gitea/gitea.yaml
git commit -m "feat: gitea upgrade chart 12.5.3 → 12.6.0, app 1.25.5 → 1.26.1"
git push
```

ArgoCD erkennt den Commit und startet den Sync automatisch.

---

### Schritt 4: Upgrade beobachten

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

---

### Schritt 5: Post-Upgrade-Verifikation

```bash
# App-Version korrekt?
kubectl -n gitea get deploy gitea -o jsonpath='{.spec.template.spec.containers[0].image}'
# → docker.gitea.com/gitea:1.26.1

# API antwortet mit neuer Version?
curl -s https://gitea.reckeweg.io/api/v1/version | jq .version
# → "1.26.1"

# SSH funktioniert? (SSH läuft über git.reckeweg.io, nicht gitea.reckeweg.io)
ssh -T git@git.reckeweg.io

# Logs sauber?
kubectl -n gitea logs deploy/gitea --tail=100 | grep -iE "error|fatal|panic"

# ArgoCD-Repo-Verbindung intakt?
argocd repo list | grep reckeweg.io
# → STATUS = Successful
```

---

### Schritt 6: Smoke-Tests

```bash
curl -s -o /dev/null -w "%{http_code}" https://gitea.reckeweg.io
# → 200

argocd app list | grep -v "Synced.*Healthy"
# → keine Ausgabe (alle Apps OK)

kubectl get pods -n gitea -l app.kubernetes.io/name=act-runner
# → act-runner läuft (2/2)
```

---

### Rollback (Catch-22-geprüft, 2026-05-18)

> **Wichtig:** `root-infrastructure` **zuerst** deaktivieren — sonst stellt es die gitea-App
> sofort zurück und der Rollback schlägt fehl.

```bash
# 1. Beide Auto-syncs deaktivieren (root-infrastructure ZUERST)
kubectl patch application root-infrastructure -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl patch application gitea -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'

# 2. Letzte 12.5.3-Revision aus History ermitteln und rollbacken
argocd app history gitea
argocd app rollback gitea <letzte-12.5.3-ID>

# 3. Beide Dateien im Repo zurücksetzen und pushen
#    gitops/config/gitea/values.yaml: image.tag "1.26.1" → "1.25.5"
#    gitops/apps/gitea/gitea.yaml: targetRevision 12.6.0 → 12.5.3
git add gitops/config/gitea/values.yaml gitops/apps/gitea/gitea.yaml
git commit -m "revert: gitea rollback 12.6.0/1.26.1 → 12.5.3/1.25.5"
git push

# 4. root-infrastructure syncen (liest Revert-Commit)
argocd app sync root-infrastructure

# 5. Auto-syncs reaktivieren
kubectl patch application root-infrastructure -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
kubectl patch application gitea -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

> ⚠️ Falls DB-Migration bereits gelaufen ist: Rollback auf 1.25.5 **nicht sicher**.
> In diesem Fall PostgreSQL-Backup einspielen oder auf 1.26.1 verbleiben und Fehler debuggen.

---

## Checkliste 12.5.3 → 12.6.0 (zweiter Versuch)

**Vorbereitung**

- [x] Erster Versuch gescheitert: `-apply-env` Flag fehlt in 1.25.5 (2026-05-18)
- [x] Ursache geklärt: Chart 12.6.0 erfordert App-Version 1.26.1 (2026-05-18)
- [x] DB-Backup erstellt: `gitea-db-backup-pre-1.26.1-20260518-1401.sql.gz` (266K) (2026-05-18)
- [x] Gitea API antwortet: `1.25.5` (2026-05-18)
- [x] ArgoCD Repo-Status: `Successful` (2026-05-18)
- [x] Keine laufenden Actions Jobs (2026-05-18)

**Durchführung**

- [x] `values.yaml`: `image.tag: "1.26.1"` gesetzt (2026-05-18)
- [x] `gitea.yaml`: `targetRevision: 12.6.0` gesetzt (2026-05-18)
- [x] Commit + Push (2026-05-18)
- [x] ArgoCD Sync gestartet — Pod terminiert
- [x] Alle Init-Container ohne Fehler durchgelaufen (`Init:0/3 → 1/3 → 2/3 → Running`)
- [x] Image `docker.gitea.com/gitea:1.26.1-rootless` bestätigt (2026-05-18)
- [x] API antwortet mit `1.26.1` (2026-05-18)
- [x] SSH-Verbindung `git@git.reckeweg.io` funktioniert (2026-05-18)
- [x] Keine Error-Logs (2026-05-18)
- [x] ArgoCD: `Synced to 12.6.0 / Healthy` (2026-05-18)
- [x] Alle Smoke-Tests ✅ (2026-05-18)

---

## Bekannte Fallstricke

| Problem | Ursache | Lösung |
|---------|---------|--------|
| Init-Container `configure-gitea` crasht | Chart nutzt neues App-Default-Image das `-o`-Flag nicht kennt | `image.tag: "1.25.5"` in values.yaml ist Fix — sicherstellen dass values gezogen werden |
| ArgoCD zeigt `ComparisonError: Unable to resolve refs` | Gitea war während Sync down, ArgoCD kann values nicht lesen | GitHub-Fallback aus Schritt 1 aktivieren |
| Gitea startet, aber ArgoCD-Repo bleibt `Failed` | SSH-Hostkey hat sich geändert | `argocd cert list --cert-type ssh \| grep reckeweg` → ggf. Key neu eintragen |
| `knownhosts: key is unknown` nach Upgrade | Pod-Neustart mit neuem SSH-Key (nur bei PVC-Verlust) | Anhang: ed25519-Hostkey (siehe [Traefik-Runbook Anhang](traefik-upgrade-runbook.md)) |
| act-runner verliert Verbindung | Token abgelaufen oder Runner-State inkonsistent | `kubectl -n gitea rollout restart statefulset/act-runner` |
| Longhorn-PVC im Provisioning hängt | Recreate-Strategy löscht Pod bevor alter PVC gemounted wird | `kubectl get pvc -n gitea -w` — sollte sich nach wenigen Sekunden lösen |

---

## Referenzen

- [Gitea Helm Chart Changelog](https://gitea.com/gitea/helm-gitea/releases)
- [Gitea Release Notes 1.25.x](https://blog.gitea.com/release-of-1.25.0/)
- [GITEA-DEPLOYMENT.md](../GITEA-DEPLOYMENT.md) — initiale Deployment-Dokumentation
- [GITEA-CLEANUP.md](../GITEA-CLEANUP.md) — vollständiger Neuaufbau falls nötig
- [Traefik-Upgrade-Runbook Anhang: ed25519-Hostkey](traefik-upgrade-runbook.md) — SSH-Hostkey-Reparatur ArgoCD ↔ Gitea
