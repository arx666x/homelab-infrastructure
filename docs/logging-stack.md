# Logging Stack: Loki + Promtail

**Deployed:** Februar 2026  
**Namespace:** `monitoring`  
**Sync-Wave:** 5 (nach kube-prometheus-stack Wave 4)

---

## Übersicht

Der Logging-Stack ergänzt den bestehenden Prometheus/Grafana-Stack um Log-Aggregation. Logs aller Pods und Nodes werden von Promtail gesammelt und an Loki weitergeleitet. Die Visualisierung erfolgt in der bereits laufenden Grafana-Instanz aus `kube-prometheus-stack`.

```
Pods/Nodes
    │
    ▼
Promtail (DaemonSet, läuft auf jedem Node)
    │  http://loki-stack:3100/loki/api/v1/push
    ▼
Loki (StatefulSet, persistiert auf Longhorn)
    │  http://loki-stack.monitoring.svc.cluster.local:3100
    ▼
Grafana (aus kube-prometheus-stack)
    │  grafana.reckeweg.io
    ▼
Browser
```

---

## Komponenten

### Loki
- **Chart:** `grafana/loki-stack` v2.10.3 (AppVersion: v2.9.3)
- **Storage:** Longhorn PVC, 20Gi (`storage-loki-stack-0`)
- **Retention:** 31 Tage (744h), konfiguriert via `limits_config.retention_period`
- **Compactor:** aktiviert für automatisches Retention-Management

### Promtail
- **Deployment:** DaemonSet (automatisch durch den Chart), läuft auf allen Nodes inkl. Control-Plane
- **Tolerations:** `node-role.kubernetes.io/master` und `control-plane` → Logs auch von Master-Nodes
- **Push-URL:** `http://loki-stack:3100/loki/api/v1/push`

### Grafana-Integration
- Grafana läuft **nicht** im loki-stack Chart (`grafana.enabled: false`)
- Die Loki-Datasource wird automatisch vom loki-stack Chart als ConfigMap `loki-stack` im Namespace `monitoring` bereitgestellt
- Label `grafana_datasource: "1"` → Grafana Sidecar lädt sie automatisch

---

## Bekannte Einschränkungen

### Loki Connection-Test in Grafana schlägt fehl
**Symptom:** Roter "Unable to connect" Button in Grafana unter Connections → Data Sources → Loki.

**Ursache:** Grafana 10.2.x sendet `vector(1)+vector(1)` als Health-Check-Query. Das ist eine PromQL-Syntax die Loki 2.x nicht versteht — Loki erwartet LogQL.

**Auswirkung:** Keine. Loki ist voll funktionsfähig. Logs sind in Grafana Explore abfragbar.

**Workaround:** Direkt testen ob Loki antwortet:
```bash
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -n monitoring \
  -- curl -s http://loki-stack.monitoring.svc.cluster.local:3100/ready
# Erwartete Ausgabe: ready

kubectl run -it --rm debug --image=curlimages/curl --restart=Never -n monitoring \
  -- curl -s http://loki-stack.monitoring.svc.cluster.local:3100/loki/api/v1/labels
# Gibt verfügbare Labels zurück
```

**Langfristige Lösung:** Migration vom deprecated `loki-stack` Chart auf den neuen `loki` Chart (Loki 3.x). Dann ist Grafana 10.x kompatibel. Geplant für späteres Upgrade.

---

## Dateistruktur

```
gitops/apps/
  loki.yaml                          # ArgoCD Application für loki-stack
  monitoring.yaml                    # ArgoCD Application für kube-prometheus-stack (inkl. Grafana)

gitops/config/grafana/dashboards/
  dashboard-loki-logs-app.yaml       # Logs/App Dashboard (ID 13639)
  dashboard-loki-stack-monitoring.yaml  # Loki Stack Monitoring (ID 14055)
  dashboard-kubernetes-logs.yaml     # Kubernetes Cluster Logs (custom)
  dashboard-node-logs.yaml           # Node Logs (custom)
```

---

## Dashboards

Dashboards werden als ConfigMaps mit Label `grafana_dashboard: "1"` deployed. Der Grafana-Sidecar (`grafana-sc-dashboard`) lädt sie automatisch ohne Pod-Neustart.

Die ArgoCD Application `grafana-dashboards-loki` (Wave 6) managed den Pfad `gitops/config/grafana/dashboards/`.

| Dashboard | Beschreibung | Quelle |
|-----------|-------------|--------|
| Logs / App | Log-Browser nach Namespace/App/Container | Grafana ID 13639 |
| Loki Stack Monitoring | Promtail-Metriken, Error-Logs von Loki/Promtail | Grafana ID 14055 |
| Kubernetes Cluster Logs | Cluster-weite Logs mit Error/Warning-Zählern | Custom |
| Node Logs | OOM-Kills, Kernel-Panics, System-Logs | Custom |

**Zugriff:** Grafana → Dashboards → Browse → Folder "Loki"

---

## Betrieb

### Logs eines bestimmten Pods ansehen
In Grafana → Explore → Loki-Datasource:
```logql
{namespace="monitoring", pod="loki-stack-0"}
```

### Nur Fehler anzeigen
```logql
{namespace="default"} |~ "(?i)(error|exception|fatal)"
```

### Logs aller ArgoCD-Komponenten
```logql
{namespace="argocd"}
```

### Loki-Status prüfen
```bash
kubectl get pods -n monitoring -l app=loki
kubectl logs -n monitoring loki-stack-0 | tail -20
```

### Promtail-Status prüfen
```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail
kubectl logs -n monitoring -l app.kubernetes.io/name=promtail | tail -20
```

### Verfügbare Labels abfragen
```bash
kubectl exec -n monitoring deployment/kube-prometheus-stack-grafana -c grafana -- \
  curl -s http://loki-stack.monitoring.svc.cluster.local:3100/loki/api/v1/labels
```

---

## Troubleshooting

### Pod crasht mit Config-Parse-Fehler
`retention_period` gehört in `limits_config`, nicht in `storage_config`:
```yaml
# Richtig:
config:
  limits_config:
    retention_period: 744h
  compactor:
    retention_enabled: true

# Falsch (führt zu CrashLoopBackOff):
config:
  storage_config:
    retention_period: 744h  # Existiert nicht!
```

### ArgoCD findet Pfad nicht
Bei neuen Pfaden im Repo kann ArgoCD einen Cache-Fehler zeigen obwohl der Pfad existiert:
```bash
argocd app sync grafana-dashboards-loki --force
```

### Doppelte Datasources in Grafana
Entsteht wenn sowohl `additionalDataSources` im kube-prometheus-stack als auch der loki-stack Chart eine Datasource registrieren. Lösung: `additionalDataSources` für Loki aus `monitoring.yaml` entfernen — der loki-stack Chart übernimmt das automatisch via ConfigMap `loki-stack`.

### repoURL stimmt nicht
ArgoCD kennt nur Repos die explizit registriert sind:
```bash
argocd repo list
# Korrekte URL für dieses Cluster:
# git@git.reckeweg.io:achim/homelab-infrastructure.git
```

---

## Geplante Verbesserungen

- [ ] Migration von `loki-stack` (deprecated) auf `loki` Chart v3.x
  - Behebt Grafana 10.x Health-Check-Kompatibilität
  - Ermöglicht neuere Loki-Features (TSDB storage, bessere Retention)
  - Erfordert Schema-Migration von boltdb-shipper auf tsdb
- [ ] ServiceMonitor für Loki/Promtail Metriken in Prometheus aktivieren
- [ ] Alerting-Regeln für Log-Anomalien (z.B. zu viele Errors, OOM-Kills)
