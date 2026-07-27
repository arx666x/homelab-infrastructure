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

### Update-Alerts

| Alert | Bedingung | Severity | Wartezeit |
|-------|-----------|----------|-----------|
| `OSUpdatesPending` | `node_os_updates_pending > 0` | warning | 3d |
| `OSRebootRequired` | `/var/run/reboot-required` vorhanden | warning | 1h |

Gilt für k3s-Nodes UND die DNS-Nodes (dns01, später dns02) — siehe
[OS-Update-Tracking](#os-update-tracking) unten.

### DNS-Alerts

| Alert | Bedingung | Severity | Wartezeit |
|-------|-----------|----------|-----------|
| `DnsNodeDown` | `up{job="dns-node-exporter"} == 0` | critical | 2m |
| `KeepalivedExporterDown` | `up{job="dns-keepalived-exporter"} == 0` | warning | 5m |

`DnsNodeDown` ist critical, weil dns01 aktuell der einzige DNS/Pi-hole-Node
ist (dns02 noch nicht provisioniert) — kein Failover, ein Ausfall betrifft
sofort das gesamte Netz. `KeepalivedExporterDown` sagt nur etwas über das
Monitoring selbst aus, nicht über den VRRP-Status (siehe unten).

---

## OS-Update-Tracking

`apt-daily.timer` / `apt-daily-upgrade.timer` sind clusterweit deaktiviert
(siehe `update-pi-nodes.yml` / `update-master-nodes.yml`), damit Updates nur
über die kontrollierten Update-Playbooks landen. Das heißt aber auch: ohne
zusätzlichen Mechanismus aktualisiert sich der apt-Cache nie von selbst und
niemand sieht, wie viele Updates anstehen.

`ansible/playbooks/os-update-check.yml` schließt diese Lücke — ein
systemd-Timer (alle 6h) auf jedem k3s- und DNS-Node:

1. `apt-get update` (read-only, installiert nichts)
2. zählt simulierte Upgrades (`apt-get -s upgrade | grep -c '^Inst '`)
3. prüft `/var/run/reboot-required`
4. schreibt beides als node-exporter-Textfile-Collector-Metriken
   (`node_os_updates_pending`, `node_os_reboot_required`) nach
   `/var/lib/node_exporter/textfile_collector/os_updates.prom`

Der Textfile-Collector selbst wird über
`prometheus-node-exporter.extraArgs` + `extraHostVolumeMounts` in
`gitops/apps/monitoring.yaml` aktiviert (Standard-Chart hat ihn nicht an).

```bash
ansible-playbook -i inventory/hosts.ini playbooks/os-update-check.yml
ansible-playbook -i inventory/hosts.ini playbooks/os-update-check.yml --tags remove
```

---

## Chart-/Image-Upgrade-Überwachung (Upgrade Agent)

Während `os-update-check.yml` (oben) nur **OS-Pakete** auf den Nodes zählt,
prüft der **Upgrade Agent** (`scripts/upgrade-agent.py`) die Anwendungsebene:
Helm-Chart-Versionen der ArgoCD-Apps und gepinnte Container-Image-Tags. Läuft
als eigener Kubernetes CronJob im Namespace `monitoring`, **jeden Montag
08:00 Uhr Europe/Berlin**.

**Vollständige Setup- und Betriebs-Doku:**
[docs/upgrade-agent-setup.md](upgrade-agent-setup.md)

### Ansatz

1. Prüft aktuell **8 Helm Charts** (u.a. Longhorn, Traefik, cert-manager,
   kube-prometheus-stack) und **4 Container-Images** (Home Assistant,
   Guacamole/guacd, Headlamp) gegen die jeweils neueste stabile Version
   (Helm-Repo bzw. GitHub Releases/Docker Hub).
2. Für jeden Fund: lädt das passende Upgrade-Runbook aus `docs/upgrades/`
   sowie die GitHub Release Notes und fragt **Claude Opus** nach einer
   Minor/Major-Einstufung und einer AUTO/NOTIFY-Entscheidung.
3. **AUTO** (i.d.R. Patch, teils risikoarme Minor-Bumps laut Runbook) → Version
   wird direkt auf `main` committed und gepusht — ArgoCD deployt automatisch.
4. **NOTIFY** (jeder Major-Bump, riskante Minor-Bumps) → kein automatischer
   Commit; stattdessen ein Gitea-PR-Branch zum manuellen Review plus Telegram-
   und E-Mail-Benachrichtigung.

Diese Benachrichtigungen laufen **nicht** über Alertmanager/Prometheus,
sondern werden vom Script direkt per Telegram-Bot-API und SMTP verschickt
(dieselben Zugangsdaten wie oben unter [Secrets](#secrets) — via
`alertmanager-credentials`, im Agent-Pod eingebunden unter
`/etc/alertmanager/secrets/alertmanager-credentials/`).

### Git-Sync-Lücke (behoben 2026-07-27)

Der Agent klont/committet ausschließlich über eine HTTPS-Verbindung zu Gitea
(`gitea-token`-Secret) — bis 2026-07-27 gab es dabei **kein GitHub-Remote**.
Das lokale Dual-Push-Setup (`origin` mit zwei `pushurl`-Einträgen, siehe
[GIT-WORKFLOW.md](GIT-WORKFLOW.md)) deckt nur manuelle Pushes vom Laptop ab,
nicht die autonomen Commits des Agents — GitHub konnte dadurch hinter Gitea
zurückfallen und bei einem späteren manuellen Push zu Non-Fast-Forward-
Kollisionen führen. Behoben durch `.gitea/workflows/mirror-to-github.yml`
(Gitea Action, spiegelt jeden Push — egal von wem — automatisch nach
GitHub; selbes Muster wie `mirror-to-sailpoint.yml`, siehe
[gitea-sailpoint-mirror-runbook.md](gitea-sailpoint-mirror-runbook.md)).

**Kein `actions/checkout` — bewusst.** Der `act_runner:nightly`-Container hat
kein `node`-Binary, und die Runner-Labels laufen `host://` (siehe
[gitea-actions-runner.md](upgrades/gitea-actions-runner.md), Umstieg auf
`host://` wegen `/var/run`-Symlink-Problemen) — JS-basierte Actions wie
`actions/checkout@v4` scheitern dort mit `Cannot find: node in PATH`
(bestätigt per `kubectl exec` in den Runner-Pod: kein `node` im Image, `apk`
vorhanden aber nur ephemer). Betrifft grundsätzlich **jeden** Workflow auf
diesem Runner, nicht nur diesen hier. Stattdessen — wie bei
`mirror-to-sailpoint.yml` und `build-and-push.yml` in
prism/erp-portal/seri-k8s/trakkws-quarkus — reines `git clone --mirror` in
einem `run:`-Step mit dem automatisch von Gitea Actions bereitgestellten
`secrets.GITEA_TOKEN`.

**`git push --mirror` schlägt an GitHub-PR-refs fehl.** `homelab-infrastructure`
hat (im Gegensatz zu prism/erp-portal/seri-k8s) offene Gitea-PRs — vom
Upgrade Agent per NOTIFY-Pfad angelegt. `git clone --mirror` zieht dafür lokal
`refs/pull/N/head`-Refs; ein `git push --mirror` versucht diese nach GitHub zu
schreiben, was dort als "hidden ref" abgelehnt wird (`deny updating a hidden
ref`) und den kompletten Push abbrechen lässt — inklusive der eigentlich
erfolgreichen Branch-/Tag-Refs. Fix: statt `--mirror` gezielt nur
`refs/heads/*` und `refs/tags/*` pushen (`git push --prune ... '+refs/heads/*:refs/heads/*'
'+refs/tags/*:refs/tags/*'`) — `--prune` sorgt weiterhin dafür, dass gelöschte
Branches/Tags auch auf GitHub verschwinden, ohne den PR-ref-Namespace
anzufassen.

**Setup (einmalig, siehe Gitea-Secret unten):** Der Workflow braucht ein
Repo-Secret `PERSONAL_GITHUB_TOKEN` (GitHub PAT, Scope `repo`, Account
`arx666x`) unter
`https://gitea.reckeweg.io/achim/homelab-infrastructure/settings/actions/secrets`
— **bereits angelegt** (2026-07-27). `secrets.GITEA_TOKEN` braucht keine
manuelle Einrichtung (automatisch von Gitea Actions pro Repo bereitgestellt).
Rotation bei Ablauf: neuen PAT erzeugen und dasselbe Secret überschreiben —
kein Redeploy nötig, der nächste Push nutzt automatisch den neuen Wert.

## DNS-Node-Monitoring (dns01, später dns02)

dns01 (Debian 13/trixie, Raspberry Pi 5, aarch64) liegt außerhalb des
k3s-Clusters — eigene `[dns]`-Inventory-Gruppe in `ansible/inventory/hosts.ini`.
Damit greift weder das node-exporter-DaemonSet noch ein ServiceMonitor.
`ansible/playbooks/dns-exporters.yml` installiert stattdessen zwei
eigenständige systemd-Services:

| Exporter | Port | Zweck |
|----------|------|-------|
| `node_exporter` | 9100 | OS/CPU/RAM/Disk + Textfile-Collector (Updates, s.o.) |
| `keepalived_exporter` | 9165 | VRRP-Status (`keepalived_vrrp_state`, `keepalived_up`) |

Beide werden in `gitops/apps/monitoring.yaml` unter
`prometheus.prometheusSpec.additionalScrapeConfigs` als static targets
gescraped (dns01 hat keine Kubernetes-Service-Discovery zur Verfügung).

`keepalived_exporter` braucht Root-Rechte — er schickt `SIGDATA`/`SIGSTATS`
an den keepalived-Prozess und liest die Dump-Dateien unter `/tmp/keepalived.data`
bzw. `/tmp/keepalived.stats`. Kein spezielles Compile-Flag nötig (Debians
keepalived-Paket unterstützt das Standardmäßig).

**Bewusst noch kein Alert auf den VRRP-Zustand selbst** (`keepalived_vrrp_state`):
mit nur einem DNS-Node ist "nicht MASTER" gleichbedeutend mit "kein DNS im
ganzen Netz" — das deckt `DnsNodeDown` bereits ab. Ein sinnvoller
Failover-Alert (z. B. "kein Node ist MASTER") ergibt erst Sinn, sobald dns02
provisioniert ist.

```bash
ansible-playbook -i inventory/hosts.ini playbooks/dns-exporters.yml
ansible-playbook -i inventory/hosts.ini playbooks/dns-exporters.yml --tags remove
```

### Offen: Pi-hole-Metriken

Pi-hole v6.7 (FTL) hat **kein** eingebautes Prometheus-Endpoint, und der
verbreitete `eko/pihole-exporter` zielt auf die alte v5-API
(`/admin/api.php`) — die existiert auf dieser Instanz nicht mehr (`/api` ist
jetzt der einzige Weg, Session-Auth via `POST /api/auth`). Geplanter Ansatz:
ein kleines Script authentifiziert sich mit einem Pi-hole **Application
Password** gegen `/api/auth`, liest `/api/stats/summary` +
`/api/dns/blocking` und schreibt die Werte in denselben Textfile-Collector
wie die Update-Metriken. Blockiert auf: Application Password muss einmalig
über die Pi-hole-Weboberfläche (Settings → API) erzeugt werden.

---

## Secrets

Die Monitoring-Secrets werden seit 20.03.2026 als **Sealed Secrets** verwaltet
und sind im Repo unter `gitops/config/monitoring/` gespeichert.

| Secret | Datei | Keys |
|--------|-------|------|
| `alertmanager-credentials` | `sealed-alertmanager-credentials.yaml` | `gmail-password`, `telegram-bot-token` |
| `grafana-admin-secret` | `sealed-grafana-admin-secret.yaml` | `admin-user`, `admin-password` |

Das Secret `alertmanager-credentials` wird in den Alertmanager Pod gemountet unter:
`/etc/alertmanager/secrets/alertmanager-credentials/`

**Wichtig:** Das Gmail App-Password muss ohne Leerzeichen gespeichert werden
(Google zeigt es zur Lesbarkeit mit Spaces an, das eigentliche Passwort
sind die 16 Zeichen ohne Spaces).

Secret rotieren (z.B. neues Gmail App-Password):

```bash
kubectl delete secret alertmanager-credentials -n monitoring

kubectl create secret generic alertmanager-credentials \
  --namespace monitoring \
  --from-literal=gmail-password='<NEUES_APP_PASSWORD>' \
  --from-literal=telegram-bot-token='<TOKEN>' \
  --dry-run=client -o json \
  | kubeseal --cert gitops/sealed-secrets/pub-cert.pem --format yaml \
  > gitops/config/monitoring/sealed-alertmanager-credentials.yaml

git add gitops/config/monitoring/sealed-alertmanager-credentials.yaml
git commit -m "chore: rotate alertmanager credentials"
git push
```

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

- ~~Sealed Secrets für Alertmanager-Credentials~~ ✅ Erledigt (20.03.2026)
- Grafana-Dashboards für Node-Übersicht und Longhorn-Status
- AlertmanagerConfig CRD statt inline Helm Values (nach Sealed Secrets Migration)
- Windows AD VM Monitoring (QEMU Guest Agent Metriken)

---

## k3s PrometheusRules — null-Rules Problem (20.03.2026)

### Problem

Bei der Sealed Secrets Migration wurde `monitoring.yaml` angepasst. Dabei
entstanden durch das Deaktivieren von k3s-inkompatiblen Rule-Gruppen drei
PrometheusRule-Objekte mit `rules: null` statt `rules: []`:

```
kube-prometheus-stack-kubernetes-system-controller-manager
kube-prometheus-stack-kubernetes-system-scheduler
kube-prometheus-stack-kubernetes-system-kube-proxy
```

Kubernetes lehnt PrometheusRules mit `rules: null` ab:

```
PrometheusRule is invalid: spec.groups[0].rules:
  Invalid value: "null": must be of type array: "null"
```

ArgoCD blieb dauerhaft im `OutOfSync`-Status da es die Rules anlegen wollte,
Kubernetes sie aber ablehnte.

### Ursache

Der kube-prometheus-stack Helm Chart v55.5.0 generiert beim Deaktivieren
einer Rule-Gruppe (`kubeControllerManager: false`) das PrometheusRule-Objekt
weiterhin, befüllt aber `rules` mit `null` statt einem leeren Array. Dies
ist ein bekanntes Verhalten in dieser Chart-Version.

`ignoreDifferences` in ArgoCD hilft bei `Missing`-Resources nicht — es
ignoriert nur Drift bei bereits bestehenden Resources.

### Lösung

**Schritt 1** — Rule-Gruppen korrekt deaktivieren in `monitoring.yaml`:

```yaml
defaultRules:
  rules:
    kubeProxy: false
    kubeControllerManager: false
    kubeScheduler: false
  disabled:
    KubeSchedulerDown: true
    KubeControllerManagerDown: true
    KubeProxyDown: true
```

**Schritt 2** — Die drei PrometheusRules einmalig mit validen leeren Rules
im Cluster anlegen (damit ArgoCD sie nicht neu anlegen muss):

```bash
for name in controller-manager scheduler kube-proxy; do
kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kube-prometheus-stack-kubernetes-system-${name}
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: kubernetes-system-${name}
      rules: []
EOF
done
```

**Schritt 3** — `ignoreDifferences` in `monitoring.yaml` ergänzen damit
ArgoCD künftige Spec-Änderungen durch den Operator ignoriert:

```yaml
ignoreDifferences:
  # ... bestehende Einträge ...
  - group: monitoring.coreos.com
    kind: PrometheusRule
    name: kube-prometheus-stack-kubernetes-system-controller-manager
    namespace: monitoring
    jsonPointers:
      - /spec
  - group: monitoring.coreos.com
    kind: PrometheusRule
    name: kube-prometheus-stack-kubernetes-system-scheduler
    namespace: monitoring
    jsonPointers:
      - /spec
  - group: monitoring.coreos.com
    kind: PrometheusRule
    name: kube-prometheus-stack-kubernetes-system-kube-proxy
    namespace: monitoring
    jsonPointers:
      - /spec
```

**Schritt 4** — `RespectIgnoreDifferences=true` in `syncOptions`:

```yaml
syncOptions:
  - CreateNamespace=true
  - ServerSideApply=true
  - RespectIgnoreDifferences=true
```

### Hinweis für zukünftige Chart-Upgrades

Bei einem Upgrade von kube-prometheus-stack prüfen ob das `null`-Problem
in der neuen Version behoben ist:

```bash
helm template kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --version <NEUE_VERSION> \
  --set defaultRules.rules.kubeControllerManager=false \
  | grep -c "kubernetes-system-controller-manager"
```

Ergibt der Befehl `0` → Problem behoben, `ignoreDifferences` und die
manuell angelegten leeren Rules können entfernt werden.
