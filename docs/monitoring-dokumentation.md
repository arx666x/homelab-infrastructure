# Monitoring & Alerting

Dieses Dokument beschreibt den Monitoring-Stack des Homelabs und wie er
konfiguriert, betrieben und erweitert werden kann.

---

## Überblick

| Komponente | Zweck | URL | Namespace |
|-----------|-------|-----|-----------|
| Prometheus | Metriken-Sammlung und Alerting-Rules | https://prometheus.reckeweg.io | monitoring |
| Grafana | Dashboards und Visualisierung | https://grafana.reckeweg.io | monitoring |
| Alertmanager | Alert-Routing zu Telegram und E-Mail | https://alertmanager.reckeweg.io | monitoring |
| Loki | Log-Aggregation | intern (kein Ingress) | monitoring |
| Promtail | Log-Collector auf jedem Node | intern (DaemonSet) | monitoring |

Alle Komponenten sind Teil des **kube-prometheus-stack** Helm Charts (Version 55.5.0)
und werden über ArgoCD als GitOps-App verwaltet (`gitops/apps/monitoring.yaml`).

---

## Architektur

```
Nodes/Pods
    │
    ├── node-exporter (Metriken: CPU, RAM, Disk)
    ├── kube-state-metrics (Metriken: Pod/Node Status)
    └── Promtail (Logs → Loki)
         │
         ▼
    Prometheus ──── PrometheusRules ────► Alertmanager
         │                                     │
         ▼                                     ├──► Telegram Bot
      Grafana                                  └──► Gmail (kritische Alerts)
         │
         └── Loki (Log-Datasource)
```

---

## Alerting-Konfiguration

### Channels

| Channel | Alerts | Konfiguration |
|---------|--------|---------------|
| Telegram | Alle Alerts (warning + critical) | Bot-Token im Secret |
| E-Mail (Gmail) | Nur kritische Alerts | App-Password im Secret |

### Alert-Schweregrade

| Severity | Telegram | E-Mail | Beispiele |
|----------|----------|--------|-----------|
| `critical` | ✅ | ✅ | Node down, Longhorn Volume faulted |
| `warning` | ✅ | ❌ | Disk Pressure, CrashLoop, Memory >90% |

### Routing

```
Alle Alerts → Telegram
           └── severity=critical → Telegram + E-Mail
```

### Timing

- `group_wait: 30s` — Wartezeit bevor erste Benachrichtigung
- `group_interval: 5m` — Intervall für gruppierte Alerts
- `repeat_interval: 4h` — Wiederholung bei anhaltenden Alerts

---

## Alert-Regeln

### Node-Alerts

| Alert | Bedingung | Severity | Wartezeit |
|-------|-----------|----------|-----------|
| `NodeNotReady` | Node meldet NotReady | critical | 5m |
| `NodeMemoryPressure` | Memory Pressure aktiv | warning | 2m |
| `NodeDiskPressure` | Disk Pressure aktiv | warning | 2m |
| `NodeHighMemoryUsage` | RAM > 90% | warning | 5m |

### Pod-Alerts

| Alert | Bedingung | Severity | Wartezeit |
|-------|-----------|----------|-----------|
| `PodCrashLooping` | >3 Restarts in 15min | warning | 5m |
| `PodNotReady` | Pod läuft aber nicht Ready | warning | 10m |
| `PodOOMKilled` | Pod durch OOM beendet | warning | sofort |

### Longhorn-Alerts

| Alert | Bedingung | Severity | Wartezeit |
|-------|-----------|----------|-----------|
| `LonghornVolumeUnhealthy` | Volume robustness=faulted | critical | 2m |
| `LonghornVolumeDegraded` | Volume robustness=degraded | warning | 5m |
| `LonghornNodeDown` | Longhorn Node nicht erreichbar | critical | 5m |
| `LonghornDiskAlmostFull` | Disk > 85% voll | warning | 5m |

### k3s-Alerts

| Alert | Bedingung | Severity | Wartezeit |
|-------|-----------|----------|-----------|
| `K3sAgentDown` | kubelet nicht erreichbar | critical | 5m |

---

## Secrets

Die Alertmanager-Credentials werden als manuell erstelltes Kubernetes Secret
verwaltet (noch kein Sealed Secrets – geplant):

```bash
kubectl create secret generic alertmanager-credentials \
  --namespace monitoring \
  --from-literal=telegram-bot-token='<TOKEN>' \
  --from-literal=telegram-chat-id='<CHAT_ID>' \
  --from-literal=gmail-user='achim.reckeweg@gmail.com' \
  --from-literal=gmail-password='<APP_PASSWORD_OHNE_SPACES>'
```

**Wichtig:** Das Gmail App-Password muss ohne Leerzeichen gespeichert werden
(Google zeigt es zur Lesbarkeit mit Spaces an, das eigentliche Passwort
sind die 16 Zeichen ohne Spaces).

Das Secret wird in den Alertmanager Pod gemountet unter:
`/etc/alertmanager/secrets/alertmanager-credentials/`

---

## k3s-spezifische Anpassungen

k3s implementiert `kube-proxy`, `kube-scheduler` und `kube-controller-manager`
anders als Standard-Kubernetes — diese laufen nicht als eigenständige Pods.
Die entsprechenden Default-Alerts wurden daher deaktiviert:

```yaml
defaultRules:
  rules:
    kubeProxy: false
  disabled:
    KubeSchedulerDown: true
    KubeControllerManagerDown: true
```

---

## Betrieb

### Test-Alert senden

```bash
# Port-forward zum Alertmanager:
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093 &

# Test-Alert senden:
curl -X POST http://localhost:9093/api/v2/alerts \
  -H "Content-Type: application/json" \
  -d '[{
    "labels": {
      "alertname": "TestAlert",
      "severity": "critical",
      "node": "k3s-03a"
    },
    "annotations": {
      "summary": "Test Alert vom Homelab",
      "description": "Manueller Test-Alert"
    }
  }]'
```

### Aktive Alerts anzeigen

```bash
# Alle aktiven Alerts:
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093 &
curl -s http://localhost:9093/api/v2/alerts | python3 -m json.tool

# Oder über Prometheus UI:
# https://prometheus.reckeweg.io/alerts
```

### Alert silencen (temporär stumm schalten)

Über die Alertmanager UI: https://alertmanager.reckeweg.io
→ Silences → New Silence

Oder per API:
```bash
curl -X POST http://localhost:9093/api/v2/silences \
  -H "Content-Type: application/json" \
  -d '{
    "matchers": [{"name": "alertname", "value": "NodeNotReady", "isRegex": false}],
    "startsAt": "2026-03-19T00:00:00Z",
    "endsAt": "2026-03-20T00:00:00Z",
    "createdBy": "achim",
    "comment": "Geplante Wartung"
  }'
```

### Alertmanager neu starten (nach Config-Änderung)

```bash
kubectl rollout restart statefulset/alertmanager-kube-prometheus-stack-alertmanager -n monitoring
kubectl rollout status statefulset/alertmanager-kube-prometheus-stack-alertmanager -n monitoring
```

### Config-Validierung

```bash
# Aktuelle Config anzeigen:
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 \
  -c alertmanager -- cat /etc/alertmanager/config_out/alertmanager.env.yaml

# Reconciliation-Status:
kubectl describe alertmanager -n monitoring kube-prometheus-stack-alertmanager \
  | grep -A3 "Reconciled"
```

---

## Neue Alert-Rules hinzufügen

Alert-Rules werden direkt in `gitops/apps/monitoring.yaml` unter
`additionalPrometheusRulesMap` definiert:

```yaml
additionalPrometheusRulesMap:
  homelab-rules:
    groups:
      - name: meine-gruppe
        interval: 1m
        rules:
          - alert: MeinNeuerAlert
            expr: <prometheus_expression>
            for: 5m
            labels:
              severity: warning    # oder critical
            annotations:
              summary: "Kurzbeschreibung"
              description: "Detailbeschreibung mit {{ $labels.node }}"
```

PromQL-Expressions können in der Prometheus UI entwickelt und getestet werden:
https://prometheus.reckeweg.io

---

## Troubleshooting

### Keine Nachrichten in Telegram

```bash
# 1. Alertmanager Logs prüfen:
kubectl logs -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 \
  -c alertmanager | tail -30

# 2. Reconciliation OK?
kubectl describe alertmanager -n monitoring kube-prometheus-stack-alertmanager \
  | grep -A5 "Conditions"

# 3. Secret vorhanden?
kubectl get secret alertmanager-credentials -n monitoring

# 4. Bot-Token testen:
curl "https://api.telegram.org/bot<TOKEN>/getMe"
```

### PrometheusOperatorSyncFailed Alert

Tritt auf wenn der Operator die Alertmanager-Config nicht laden kann.
Häufigste Ursache: Falsche Matcher-Syntax in der Config.

Alertmanager 0.26 erwartet **String-Syntax** für Matcher:
```yaml
# RICHTIG:
matchers:
  - severity = critical

# FALSCH (Map-Syntax):
matchers:
  - name: severity
    value: critical
```

### Alertmanager zeigt noch Default-Config

```bash
# Config im Secret prüfen:
kubectl get secret -n monitoring alertmanager-kube-prometheus-stack-alertmanager \
  -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d | head -20

# Wenn Default-Config → ArgoCD sync erzwingen und Alertmanager neu starten:
kubectl annotate application kube-prometheus-stack -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
kubectl rollout restart statefulset/alertmanager-kube-prometheus-stack-alertmanager -n monitoring
```

---

## Geplante Erweiterungen

- Sealed Secrets für Alertmanager-Credentials (ersetzt manuelles Secret)
- Grafana-Dashboards für Node-Übersicht und Longhorn-Status
- AlertmanagerConfig CRD statt inline Helm Values (nach Sealed Secrets Migration)
- Windows AD VM Monitoring (QEMU Guest Agent Metriken)
