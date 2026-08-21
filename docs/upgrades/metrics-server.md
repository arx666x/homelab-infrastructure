# Upgrade Runbook: Metrics Server

## Metadaten
- **Namespace:** `kube-system`
- **Aktuelle Version:** Chart v3.14.0
- **Quelle:** Helm-Chart-Repo `https://kubernetes-sigs.github.io/metrics-server/` (Chart `metrics-server`)
- **ArgoCD App-Name:** `metrics-server`
- **Versions-Check-Quelle:** Helm-Repo-Index von `https://kubernetes-sigs.github.io/metrics-server/`
- **Major/Minor-Kriterium:** Standardregel (SemVer der Chart-Version). Zusätzlich beachten: Kompatibilität mit der Metrics API (`metrics.k8s.io/v1beta1`) und HPA-Verhalten prüfen, da Metrics Server direkt von HPA/VPA und `kubectl top` konsumiert wird.

## Changelog

| Datum | Von → Nach | Typ | Ausführung | Status | Begründung | Notiz |
|---|---|---|---|---|---|---|
| unbekannt | ... | ... | ... | ... | Historie vor Einführung des strukturierten Runbooks nicht vollständig rekonstruierbar | — |
| 2026-06-15 | 3.13.0 → 3.13.1 | Minor | Manuell | Abgeschlossen | Patch-Release, keine Breaking Changes, keine API-Änderungen | Commit `87d7d8c` ("chore: upgrade metrics-server 3.13.0 → 3.13.1 + Upgrade-Runbook") |
| 2026-08-21 | 3.13.1 → 3.14.0 | Minor | Manuell | Abgeschlossen | Chart-Bump auf App v0.9.0 — Security-Fix (CVE-2025-47907, CVE-2025-47906 via Go 1.26.4-Bump), sonst nur Dependency-Updates (Kubernetes-Libs auf v1.36.2), keine Änderungen an metrics.k8s.io-API oder HPA-Verhalten | Teil der Sammel-Update-Runde 2026-08-21 |

### Reklassifizierungen (Minor → Major)

| Datum Erkennung | Ursprünglicher Changelog-Eintrag (Datum) | Grund der Reklassifizierung | Erneute Benachrichtigung gesendet am |
|---|---|---|---|

## Manuelle Vorgehensweise (bei Major/Breaking Change)

### Was ist der Metrics Server?

Der Kubernetes Metrics Server ist ein In-Cluster-Dienst, der Ressourcenmetriken (CPU, RAM) von Kubelets sammelt und über die Metrics API (`metrics.k8s.io/v1beta1`) bereitstellt. Er ist **kein Monitoring-System** — er liefert keine Langzeitdaten und speichert keine Zeitreihen, sondern nur Momentaufnahmen für:

| Nutzer | Zweck |
|---|---|
| `kubectl top nodes` / `kubectl top pods` | Live-Ressourcenverbrauch anzeigen |
| Horizontal Pod Autoscaler (HPA) | CPU/RAM-basiertes Auto-Scaling |
| Vertical Pod Autoscaler (VPA) | Ressourcen-Empfehlungen |

> **Verhältnis zu Prometheus/Grafana:** Prometheus (kube-prometheus-stack) scrapt ebenfalls Metriken, aber unabhängig vom Metrics Server. Für HPA und `kubectl top` ist der Metrics Server zwingend erforderlich — Prometheus allein reicht nicht.

In diesem Cluster läuft der Metrics Server mit `--kubelet-insecure-tls`, da die kubelet-Zertifikate selbstsigniert sind (typisch für k3s).

### Risikobewertung nach Release-Typ

| Release-Typ | Risiko | Besonderheiten |
|---|---|---|
| Patch (x.y.**Z**) | Niedrig | Keine API-Änderungen, kein Downtime-Risiko |
| Minor (x.**Y**.0) | Mittel | Changelog prüfen, insbesondere Metrics-API-Version |
| Major (**X**.0.0) | Hoch | Breaking Changes möglich, HPA-Kompatibilität prüfen |

### Phase 1: Pre-Upgrade Checks

```bash
# ArgoCD Application Status
kubectl -n argocd get application metrics-server
# Erwartet: SYNC STATUS = Synced, HEALTH STATUS = Healthy

# Aktuelle Chart-Version im Cluster
helm list -n kube-system | grep metrics-server

# Metrics Server Pod läuft?
kubectl -n kube-system get pod -l app.kubernetes.io/name=metrics-server

# Metrics API erreichbar?
kubectl top nodes
kubectl top pods -A
```

### Phase 2: Upgrade durchführen

```bash
# Aktuelle Version prüfen
grep targetRevision gitops/apps/metrics-server.yaml

# Version setzen (Beispiel: 3.13.0 → 3.13.1)
sed -i '' 's/targetRevision: "3.13.0"/targetRevision: "3.13.1"/' gitops/apps/metrics-server.yaml

# Ergebnis prüfen
grep targetRevision gitops/apps/metrics-server.yaml
```

```bash
git add gitops/apps/metrics-server.yaml
git commit -m "chore: upgrade metrics-server 3.13.0 → 3.13.1"
git push
```

ArgoCD übernimmt den Sync automatisch (`syncPolicy: automated` mit `prune` und `selfHeal`).

### Phase 3: Post-Upgrade-Verifikation

```bash
# Pod-Version bestätigen
kubectl -n kube-system get pod -l app.kubernetes.io/name=metrics-server \
  -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'

helm list -n kube-system | grep metrics-server
# CHART-Spalte muss metrics-server-3.13.1 zeigen

# Metrics API funktionsfähig?
kubectl top nodes
kubectl top pods -n kube-system

# Logs — keine Fehler?
kubectl -n kube-system logs deployment/metrics-server --since=5m \
  | grep -iE "error|panic|fatal" || echo "Keine Fehler"

# ArgoCD Final-Status
kubectl -n argocd get application metrics-server
# SYNC STATUS:   Synced
# HEALTH STATUS: Healthy
```

Bei einem Major-Upgrade zusätzlich: HPA-Ressourcen im Cluster daraufhin prüfen, dass sie weiterhin Metriken beziehen (`kubectl get hpa -A` → `TARGETS`-Spalte darf nicht `<unknown>` zeigen).

## Bekannte Stolperfallen / Lessons Learned

- `--kubelet-insecure-tls` ist erforderlich, da k3s selbstsignierte kubelet-Zertifikate verwendet — bei Entfernen dieser Option in einem künftigen Upgrade würde die Metrics-Erfassung stillschweigend fehlschlagen.
- Metrics Server liefert nur Momentaufnahmen, keine Historie — nach einem Upgrade kann `kubectl top` kurzzeitig `<unknown>` zeigen, bis der erste Scrape-Zyklus durchgelaufen ist; das ist kein Fehler.

## Rollback-Plan

```bash
sed -i '' 's/targetRevision: "3.13.1"/targetRevision: "3.13.0"/' gitops/apps/metrics-server.yaml

git add gitops/apps/metrics-server.yaml
git commit -m "revert: metrics-server zurück auf 3.13.0"
git push
```

ArgoCD synct den Rollback automatisch. Danach Phase-3-Verifikation erneut durchführen.

## Referenzen

- GitHub Releases: [kubernetes-sigs/metrics-server Releases](https://github.com/kubernetes-sigs/metrics-server/releases)
- Helm Chart: [kubernetes-sigs.github.io/metrics-server](https://kubernetes-sigs.github.io/metrics-server/)
- Interne Doku: ArgoCD Application `gitops/apps/metrics-server.yaml`
