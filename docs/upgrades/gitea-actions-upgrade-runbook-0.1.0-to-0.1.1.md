# Gitea Actions Upgrade Runbook: Chart 0.1.0 → 0.1.1

**Datum:** 2026-05-26
**Scope:** Homelab k3s-Cluster (`reckeweg.io`)
**Namespace:** `gitea`
**Von:** Helm Chart 0.1.0 (act_runner 0.6.1)
**Auf:** Helm Chart 0.1.1 (act_runner 0.6.1)
**Risiko:** 🟡 Mittel — Breaking Changes in Ressourcen-Namen, PVC wird neu erstellt
**Deployment-Methode:** ArgoCD GitOps

---

## Übersicht

| | |
|---|---|
| **Ausgangsversion** | Chart 0.1.0 |
| **Zielversion** | Chart 0.1.1 |
| **Upgrade-Strategie** | values.yaml anpassen → Chart-Version erhöhen → ArgoCD Sync |
| **ArgoCD Application** | `gitea-actions` |
| **Downtime** | Minuten — Runner kurz nicht verfügbar während Pod-Neustart |

---

## Breaking Changes

Chart 0.1.1 benennt alle "act runner"-Referenzen in "gitea runner" / "runner" um.

| Ressource | Alt (0.1.0) | Neu (0.1.1) |
|-----------|------------|------------|
| StatefulSet | `gitea-actions-act-runner` | `gitea-actions-runner` |
| PVC-Template | `data-act-runner` | `data-runner` |
| PVC-Name (Pod 0) | `data-act-runner-gitea-actions-act-runner-0` | `data-runner-gitea-actions-runner-0` |
| values-Key | `statefulset.actRunner` | `statefulset.runner` |

**Konsequenz:**
- ArgoCD löscht den alten StatefulSet (`act-runner`) und erstellt einen neuen (`runner`)
- Das neue PVC (`data-runner-gitea-actions-runner-0`) wird frisch angelegt (20Gi, Longhorn)
- Das alte PVC (`data-act-runner-...`) wird orphaned → enthielt nur Docker Layer Cache,
  der sich beim ersten Build neu aufbaut → **kein Datenverlust**
- Das alte PVC muss nach dem Upgrade manuell gelöscht werden

---

## Phase 1: Pre-Upgrade Checks

```bash
# ArgoCD Application Status
kubectl -n argocd get application gitea-actions
# Erwartet: Synced, Healthy

# Aktueller StatefulSet
kubectl get statefulset -n gitea
# Erwartet: gitea-actions-act-runner   1/1

# Aktuelles PVC
kubectl get pvc -n gitea | grep act-runner
# Erwartet: data-act-runner-gitea-actions-act-runner-0   Bound   20Gi

# Keine laufenden Jobs
# https://gitea.reckeweg.io/-/admin/runners → kein aktiver Job
```

---

## Phase 2: values.yaml anpassen

**Datei:** `gitops/config/gitea-actions/values.yaml`

`actRunner` → `runner` umbenennen:

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

---

## Phase 3: Chart-Version erhöhen

**Datei:** `gitops/apps/gitea/gitea-actions.yaml`

```yaml
# ALT
targetRevision: 0.1.0

# NEU
targetRevision: 0.1.1
```

---

## Phase 4: Commit & ArgoCD Sync

```bash
git add gitops/config/gitea-actions/values.yaml
git add gitops/apps/gitea/gitea-actions.yaml
git commit -m "chore: upgrade gitea-actions chart 0.1.0 → 0.1.1

Breaking change: statefulset.actRunner renamed to statefulset.runner.
StatefulSet and PVC names change accordingly — old PVC (Docker cache)
will be orphaned and must be deleted manually after upgrade."
git push
```

In ArgoCD Sync manuell auslösen oder warten bis Auto-Sync greift.

---

## Phase 5: Post-Upgrade Verifikation

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
# Erwartet: data-runner-gitea-actions-runner-0   Bound   20Gi
```

---

## Phase 6: Altes PVC aufräumen

```bash
# Altes orphaned PVC löschen (nur Docker Layer Cache — kein Datenverlust)
kubectl delete pvc -n gitea data-act-runner-gitea-actions-act-runner-0

# Prüfen ob Longhorn Volume freigegeben wird
kubectl get pvc -n gitea | grep act-runner
# Erwartet: keine Ausgabe
```

---

## Rollback

Falls der neue Runner-Pod nicht startet:

```bash
# Chart-Version zurücksetzen
# gitops/apps/gitea/gitea-actions.yaml: targetRevision: 0.1.0
# gitops/config/gitea-actions/values.yaml: runner → actRunner
git revert HEAD
git push
# ArgoCD Sync
```

> **Hinweis:** Der alte StatefulSet `gitea-actions-act-runner` und das alte PVC existieren
> noch bis Phase 6 abgeschlossen ist. Rollback ist bis dahin problemlos möglich.
