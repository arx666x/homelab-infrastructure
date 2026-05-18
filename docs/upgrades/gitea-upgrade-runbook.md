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

**Datum:** (offen)  
**Aktuell:** Chart 12.5.3 / Gitea 1.25.5  
**Ziel:** Chart 12.6.0 / Gitea 1.25.5 (App-Version bleibt eingefroren)  
**Risiko:** 🟢 Niedrig — Chart-Only-Bump, kein App-Versions- oder DB-Migrations-Schritt

> **Warum App-Version eingefroren?**  
> Gitea 1.26.0 hat einen Breaking Change im Init-Container (`configure-gitea` verwendet `-o`-Flag
> nicht mehr). Solange das upstream Chart keinen Fix enthält, bleibt das Image auf `1.25.5` fixiert
> (`image.tag: "1.25.5"` in `gitops/config/gitea/values.yaml`).

### Änderungen Chart 12.5.x → 12.6.x

| Bereich | Änderung | Betrifft uns? |
|---------|----------|---------------|
| Gitea App-Version | Chart-Default aktualisiert | **Nein** — `image.tag` explizit auf `1.25.5` fixiert |
| Init-Container | Ggf. Anpassungen in `configure-gitea` | Zu prüfen (Logs nach Upgrade) |
| Subchart-Versionen | Valkey/PostgreSQL-Subcharts können gebumpt sein | Irrelevant — alle Subcharts deaktiviert |
| RBAC/ServiceAccount | Mögliche Ergänzungen | Zu prüfen mit `helm diff` |

---

### Schritt 1: Catch-22 entschärfen — ArgoCD-App auf GitHub umstellen

> Dieser Schritt ist **zwingend** falls die neue Version nicht sofort startet.
> Er schützt ArgoCD davor, nach einem fehlgeschlagenen Gitea-Start einzufrieren.

```bash
# Aktuellen Zustand sichern
cp gitops/apps/gitea/gitea.yaml gitops/apps/gitea/gitea.yaml.bak
```

In `gitops/apps/gitea/gitea.yaml` die values-Source temporär auf GitHub umstellen:

```yaml
# Von:
  - repoURL: git@git.reckeweg.io:achim/homelab-infrastructure.git
    targetRevision: HEAD
    ref: values
# Zu:
  - repoURL: https://github.com/arx666x/homelab-infrastructure.git
    targetRevision: HEAD
    ref: values
```

```bash
# Änderung in BEIDE Repos pushen:
git add gitops/apps/gitea/gitea.yaml
git commit -m "temp: switch gitea values source to github for upgrade safety"
git push                                    # → Gitea (local source)
git push github main                        # → GitHub (fallback target)

# ArgoCD manuell neu laden damit die Repo-Source sofort wechselt:
argocd app get gitea
# Warten bis ArgoCD auf github zeigt (oder manuell sync triggern):
argocd app sync gitea --dry-run
```

> **Voraussetzung:** GitHub-Remote muss als `github` konfiguriert sein:
> `git remote get-url github` → `https://github.com/arx666x/homelab-infrastructure.git`

---

### Schritt 2: Pre-Flight-Checks

```bash
# Gitea Gesundheit
kubectl get pods -n gitea
kubectl get pvc -n gitea
argocd app get gitea

# API erreichbar?
curl -s https://gitea.reckeweg.io/api/v1/version | jq .version
# → "1.25.5"

# ArgoCD Repo-Verbindung prüfen
argocd repo list
# Alle Repos: STATUS = Successful

# Postgres läuft?
kubectl -n gitea exec deploy/gitea -- \
  sh -c 'PGPASSWORD=$GITEA__DATABASE__PASSWD psql -h gitea-postgresql -U gitea -c "\l"'

# Laufende Jobs / offene PRs notieren (können während Downtime nicht neu gesynct werden)
argocd app list | grep -v Synced
```

**Snapshot: aktuelle Chart-Version bestätigen**

```bash
helm list -n gitea
# NAME   NAMESPACE  REVISION  CHART          APP VERSION
# gitea  gitea      X         gitea-12.5.3   1.25.5
```

---

### Schritt 3: targetRevision in Gitea-App aktualisieren

> Da die values-Source in Schritt 1 auf GitHub umgestellt wurde, können wir jetzt die
> Chart-Version ändern. Der Commit muss auf GitHub gepusht sein, bevor ArgoCD synct.

```bash
# gitops/apps/gitea/gitea.yaml
# targetRevision: 12.5.3  →  targetRevision: 12.6.0
```

```yaml
# gitops/apps/gitea/gitea.yaml (relevanter Ausschnitt)
sources:
  - repoURL: https://dl.gitea.com/charts/
    chart: gitea
    targetRevision: 12.6.0          # ← geändert
    helm:
      valueFiles:
        - $values/gitops/config/gitea/values.yaml
  - repoURL: https://github.com/arx666x/homelab-infrastructure.git   # temporär GitHub
    targetRevision: HEAD
    ref: values
```

```bash
git add gitops/apps/gitea/gitea.yaml
git commit -m "feat: gitea chart upgrade 12.5.3 → 12.6.0 (app 1.25.5 stays pinned)"
git push
git push github main
```

---

### Schritt 4: Upgrade beobachten

ArgoCD startet den Sync automatisch (`syncPolicy: automated`).

```bash
# Upgrade-Verlauf live verfolgen
kubectl get pods -n gitea -w
# Erwartete Sequenz (Recreate-Strategy):
#   gitea-xxx   Running → Terminating   (alter Pod wird beendet)
#   gitea-yyy   Pending → Init:0/3 → Init:1/3 → Init:2/3 → Running

# Init-Container-Logs falls Hänger
kubectl logs -n gitea -l app.kubernetes.io/name=gitea -c init-directories --tail=50
kubectl logs -n gitea -l app.kubernetes.io/name=gitea -c init-app-ini --tail=50
kubectl logs -n gitea -l app.kubernetes.io/name=gitea -c configure-gitea --tail=50

# ArgoCD Sync-Status
argocd app get gitea
argocd app wait gitea --health --timeout 300
```

**Erwartete Downtime:** 60–120 Sekunden (Recreate + Init-Container)

---

### Schritt 5: Post-Upgrade-Verifikation

```bash
# Pod läuft?
kubectl get pods -n gitea
# → gitea-xxx   1/1   Running

# Helm-Version bestätigen
helm list -n gitea
# → gitea-12.6.0

# App-Version unverändert?
kubectl -n gitea get deploy gitea -o jsonpath='{.spec.template.spec.containers[0].image}'
# → docker.gitea.com/gitea:1.25.5

# API antwortet
curl -s https://gitea.reckeweg.io/api/v1/version | jq .version
# → "1.25.5"

# SSH-Verbindung
ssh -T git@gitea.reckeweg.io
# → Hi <user>! You've successfully authenticated...

# Logs auf Errors
kubectl -n gitea logs deploy/gitea --tail=100 | grep -iE "error|fatal|panic"

# ArgoCD synct wieder von Gitea (test: eine App manuell refreshen)
argocd app get argocd --refresh
```

---

### Schritt 6: GitHub-Fallback zurückstellen → Gitea als Source

Sobald der neue Pod stabil läuft (mindestens 5 Minuten beobachten):

```bash
# gitops/apps/gitea/gitea.yaml — values-Source zurück auf Gitea
```

```yaml
# Von (GitHub-Fallback):
  - repoURL: https://github.com/arx666x/homelab-infrastructure.git
    targetRevision: HEAD
    ref: values
# Zu (Gitea):
  - repoURL: git@git.reckeweg.io:achim/homelab-infrastructure.git
    targetRevision: HEAD
    ref: values
```

```bash
git add gitops/apps/gitea/gitea.yaml
git commit -m "chore: restore gitea values source to self-hosted gitea after upgrade"
git push
git push github main       # GitHub-Spiegel auch aktuell halten

# Kurz warten bis ArgoCD die neue Repo-Source aufnimmt
sleep 30
argocd app get gitea
```

---

### Schritt 7: Smoke-Tests

```bash
# Web-UI
curl -s -o /dev/null -w "%{http_code}" https://gitea.reckeweg.io
# → 200

# ArgoCD kann Gitea-Repo lesen
argocd repo list | grep reckeweg.io
# → STATUS = Successful

# Alle Apps noch Synced/Healthy?
argocd app list | grep -v "Synced.*Healthy"

# act-runner noch online (falls enabled)
kubectl get pods -n gitea -l app.kubernetes.io/name=act-runner
# Gitea UI: https://gitea.reckeweg.io/-/admin/actions/runners
# → Runner sollte als "idle" oder "active" erscheinen
```

---

### Rollback

Falls der neue Pod nicht startet oder kritische Fehler auftreten:

**Option A: ArgoCD targetRevision zurücksetzen**

```bash
# gitops/apps/gitea/gitea.yaml
# targetRevision: 12.6.0  →  12.5.3

git add gitops/apps/gitea/gitea.yaml
git commit -m "revert: gitea chart rollback 12.6.0 → 12.5.3"
git push github main     # GitHub als Fallback-Source ist noch aktiv!
# → ArgoCD synct sofort auf 12.5.3 zurück
```

**Option B: Helm direkt (wenn ArgoCD-Deadlock)**

Falls Gitea nicht startet und ArgoCD blockiert ist:

```bash
# Aktuellen Helm-State prüfen
helm list -n gitea

# Auf vorherige Revision zurückrollen
helm -n gitea rollback gitea

# Revision-History
helm -n gitea history gitea
```

> **Wichtig:** Nach einem erfolgreichen Rollback die ArgoCD-App wieder auf den alten
> targetRevision-Stand bringen und committen, damit ArgoCD nicht erneut auf 12.6.0 syncen will.

---

## Checkliste 12.5.3 → 12.6.0

**Vorbereitung**

- [ ] Backup-Commit: `gitea.yaml.bak` lokal gesichert
- [ ] GitHub-Remote verfügbar und aktuell (`git push github main`)
- [ ] Gitea API antwortet: `curl https://gitea.reckeweg.io/api/v1/version`
- [ ] ArgoCD Repo-Status: alle `Successful`
- [ ] Keine laufenden Gitea Actions Jobs (`/-/admin/actions`)

**Durchführung**

- [ ] Schritt 1: `repoURL` auf GitHub umgestellt und in beide Repos gepusht
- [ ] Schritt 3: `targetRevision: 12.6.0` committed und gepusht (Gitea + GitHub)
- [ ] Schritt 4: ArgoCD Sync beobachtet — Pod neu gestartet
- [ ] Schritt 4: Alle Init-Container ohne Fehler durchgelaufen
- [ ] Schritt 5: `gitea-12.6.0` in `helm list -n gitea` bestätigt
- [ ] Schritt 5: Image-Tag noch `1.25.5` (unverändert)
- [ ] Schritt 5: API-Version bestätigt
- [ ] Schritt 6: `repoURL` zurück auf `git@git.reckeweg.io` umgestellt
- [ ] Schritt 7: Alle Smoke-Tests ✅
- [ ] ArgoCD Repo-Status nach Rückstellung: `Successful`

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
