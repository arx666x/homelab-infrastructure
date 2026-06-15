# Metrics Server Upgrade Runbook

**Scope:** Homelab k3s-Cluster (`reckeweg.io`)  
**Namespace:** `kube-system`  
**Deployment-Methode:** ArgoCD GitOps (`gitops/apps/metrics-server.yaml`)

---

## Was ist der Metrics Server?

Der **Kubernetes Metrics Server** ist ein In-Cluster-Dienst, der Ressourcenmetriken (CPU, RAM) von Kubelets sammelt und über die **Metrics API** (`metrics.k8s.io/v1beta1`) bereitstellt. Er ist **kein Monitoring-System** – er liefert keine Langzeitdaten und speichert keine Zeitreihen. Stattdessen liefert er Momentaufnahmen für Kubernetes-eigene Features:

| Nutzer | Zweck |
|---|---|
| `kubectl top nodes` / `kubectl top pods` | Live-Ressourcenverbrauch anzeigen |
| Horizontal Pod Autoscaler (HPA) | CPU/RAM-basiertes Auto-Scaling |
| Vertical Pod Autoscaler (VPA) | Ressourcen-Empfehlungen |

> **Verhältnis zu Prometheus/Grafana:** Prometheus (kube-prometheus-stack) scrapt ebenfalls Metriken, aber unabhängig vom Metrics Server. Für HPA und `kubectl top` ist der Metrics Server zwingend erforderlich – Prometheus allein reicht nicht.

**In diesem Cluster** läuft der Metrics Server mit `--kubelet-insecure-tls`, da die kubelet-Zertifikate selbstsigniert sind (typisch für k3s).

---

## Upgrade durchführen

### Risikobewertung

| Release-Typ | Risiko | Besonderheiten |
|---|---|---|
| Patch (x.y.**Z**) | 🟢 Niedrig | Keine API-Änderungen, kein Downtime-Risiko |
| Minor (x.**Y**.0) | 🟡 Mittel | Changelog prüfen, insbesondere Metrics-API-Version |
| Major (**X**.0.0) | 🔴 Hoch | Breaking Changes möglich, HPA-Kompatibilität prüfen |

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

### Phase 3: Post-Upgrade Verifikation

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

### Rollback

```bash
sed -i '' 's/targetRevision: "3.13.1"/targetRevision: "3.13.0"/' gitops/apps/metrics-server.yaml

git add gitops/apps/metrics-server.yaml
git commit -m "revert: metrics-server zurück auf 3.13.0"
git push
```

---

## Durchgeführte Upgrades

| Datum | Von | Auf | Ergebnis | Besonderheiten |
|---|---|---|---|---|
| 2026-06-15 | 3.13.0 | 3.13.1 | ✅ Erfolgreich | Patch-Release, keine Breaking Changes |

---

## Referenzen

- [Metrics Server GitHub Releases](https://github.com/kubernetes-sigs/metrics-server/releases)
- [Metrics Server Helm Chart](https://kubernetes-sigs.github.io/metrics-server/)
- Lokale ArgoCD App: `gitops/apps/metrics-server.yaml`
