# Upgrade Runbook: kube-prometheus-stack

## Metadaten
- **Namespace:** `monitoring`
- **Aktuelle Version:** 87.19.2 (Helm Chart; Prometheus-Operator v0.92.1)
- **Quelle:** Helm-Chart-Repo `https://prometheus-community.github.io/helm-charts` (Chart: `kube-prometheus-stack`); Prometheus-Operator CRD-Releases: `https://github.com/prometheus-operator/prometheus-operator/releases`; offizielles `UPGRADE.md`: `https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/UPGRADE.md`
- **ArgoCD App-Name:** `kube-prometheus-stack`
- **Versions-Check-Quelle:** homelab-version-checker vergleicht `targetRevision` in `gitops/apps/monitoring.yaml` gegen die neueste Chart-Version im Helm-Repo-Index von `prometheus-community.github.io/helm-charts`
- **Major/Minor-Kriterium:** Standardregel mit Verschärfung — Minor-Bumps (x.**Y**.z) werden nur dann automatisch ausgeführt, wenn (a) keine CRD-Schema-Änderung am Prometheus-Operator vorliegt und (b) die Release Notes keinen Breaking Change nennen. Da dieser Chart praktisch jeden Minor-Sprung mit einem Operator-Bump (und damit potenziell CRD-Änderungen) koppelt, werden viele nominell "minor" Versionssprünge in der Praxis wie Major-Changes behandelt (CRDs vorab server-side applyen). Reine Patch-Releases ohne Operator-Bump (z.B. 86.2.0→86.2.3) gelten als unkritisch.

## Changelog

| Datum | Von → Nach | Typ | Ausführung | Status | Begründung | Notiz |
|---|---|---|---|---|---|---|
| unbekannt | ... → 55.5.0 | ... | ... | ... | Historie vor Einführung des strukturierten Runbooks nicht vollständig rekonstruierbar | Ausgangszustand bei Runbook-Erstellung am 2026-05-02: Chart 55.5.0, Operator v0.70.0 |
| 2026-05-03 | 55.5.0 → 62.x | Major | Manuell | Abgeschlossen | CRD-Update (Operator v0.76.0); `*SelectorNilUsesHelmValues`-Felder deprecated | Station 1 der Stufenmigration |
| 2026-05-03 | 62.x → 67.x | Major | Manuell | Abgeschlossen | Prometheus 3.x wird Default (Operator v0.79.0) — größter Breaking-Change-Schritt der gesamten Migration | Station 2; Remote-Write-2.0-API, native Histogramme als Default in Teilen |
| 2026-05-03 | 67.x → 69.x | Major | Manuell | Abgeschlossen | CRD-Update (Operator v0.80.0) | Station 3 |
| 2026-05-03 | 69.x → 71.x | Major | Manuell | Abgeschlossen | CRD-Update (Operator v0.82.0); `podDisruptionBudget.enabled` jetzt explizit nötig | Station 4 |
| 2026-05-03 | 71.x → 73.x | Major | Manuell | Abgeschlossen | Kubernetes ≥1.25 erforderlich, PodSecurityPolicy entfernt | Station 5 |
| 2026-05-03 | 73.x → 75.x | Major | Manuell | Abgeschlossen | CRD-Update (Operator v0.83.0); Namenspräfix-Änderung bei `additionalPrometheusRules` | Station 6 |
| 2026-05-03 | 75.x → 76.x | Major | Manuell | Abgeschlossen | CRD-Update (Operator v0.84.1, CEL-Validierung erfordert K8s ≥1.25) | Station 7 |
| 2026-05-03 | 76.x → 77.x | Major | Manuell | Abgeschlossen | CRD-Update (Operator v0.85.0) | Station 8 |
| 2026-05-03 | 77.x → 78.x | Major | Manuell | Abgeschlossen | CRD-Update (Operator v0.86.0) | Station 9 |
| 2026-05-03 | 78.x → 79.x | Major | Manuell | Abgeschlossen | Grafana-Default-Passwort `prom-operator` entfernt, zufälliges Passwort ab jetzt | Station 10 |
| 2026-05-03 | 79.x → 80.x | Major | Manuell | Abgeschlossen | CRD-Update (Operator v0.87.0) | Station 11 |
| 2026-05-03 | 80.x → 81.x | Major | Manuell | Abgeschlossen | CRD-Update (Operator v0.88.0) | Station 12 |
| 2026-05-03 | 81.x → 84.5.0 | Major | Manuell | Abgeschlossen | CRD-Update (Operator v0.89.0) | Station 13; letzter Schritt der ursprünglichen 22-Stunden-Stufenmigration vom 2026-05-03 |
| 2026-05-18 | 84.5.0 → 85.1.3 | Minor | Manuell | Abgeschlossen | Distroless-Images werden Default für prometheus/prometheus-node-exporter; kein CRD-Update (Operator bleibt v0.90.1); Cluster betroffen nicht, da keine private Registry im Einsatz | Station 14 |
| 2026-05-26 | 85.1.3 → 85.3.3 | Minor | Manuell | Abgeschlossen | Reines Maintenance-Release, kein CRD-Update; Grafana v12.4.0→v12.4.1, ThanosRuler `extraEnv`-Support | Station 15 |
| 2026-06-14 | 85.3.3 → 86.2.0 | Major | Manuell | Abgeschlossen | CRD-Update (Operator v0.90.1→v0.91.0) + Prometheus 3.12; neue Validierungen in ScrapeConfig/AlertmanagerConfig/Prometheus/ThanosRuler | Station 16 |
| 2026-06-15 | 86.2.0 → 86.2.3 | Minor (Patch) | Manuell | Abgeschlossen | Reines Dependency-Patch via Renovate, kein CRD-Update (Operator bleibt v0.91.0); Grafana 12.4.2→12.4.5, kube-state-metrics 7.4.0→7.4.1 | Station 17 |
| 2026-06-29 | 86.2.3 → 87.3.0 | Major | Manuell | Abgeschlossen | CRD-Update (Operator v0.91.0→v0.92.0); alle 10 CRDs Schema-Änderungen; PrometheusTopologySharding/PrometheusShardRetentionPolicy Beta; Grafana 12.4.5→12.7.1, kube-state-metrics 7.4.1→7.5.1 | Station 18 (finale Station der ursprünglichen Stufenmigration) |
| 2026-07-06 | 87.3.0 → 87.10.1 | Minor | Automatisch | Abgeschlossen | Automatisches Minor-Update durch homelab-version-checker, kein Breaking-Change laut Release Notes | Teil von Commit `a7d6250` (gemeinsam mit sealed-secrets 2.19.0→2.19.1); ursprünglich fälschlich als PR (#3/#4) erzeugt, dann manuell direkt auf `main` committet; Operator-Patch-Bump v0.92.0→v0.92.1 in diesem Schritt enthalten, aber im ursprünglichen Commit nicht erwähnt (nachträglich per Chart.yaml-Diff verifiziert) |
| 2026-07-13 | 87.10.1 → 87.15.1 | Minor | Automatisch | Abgeschlossen | Nur Dependency-Image-Updates (kube-state-metrics 7.5.x→7.8.1, prometheus-node-exporter, Prometheus 3.13.1), kein Operator/CRD-Change, keine Breaking Changes laut Release Notes | Commit `af699f0` durch upgrade-agent; bislang nicht in diesem Changelog erfasst, jetzt nachgetragen |
| 2026-07-20 | 87.15.1 → 87.17.0 | Minor | Automatisch | Abgeschlossen | Scrape-Config-Ergänzung (kube-scheduler resource metrics, PR #7118), externalUrl-Fix (PR #7107), node-exporter-Dependency-Bump v4.56.1; kein Operator/CRD-Change | Commit `35e4ad9` durch upgrade-agent; bislang nicht in diesem Changelog erfasst, jetzt nachgetragen |
| 2026-07-27 | 87.17.0 → 87.19.2 | Minor | Manuell | Abgeschlossen | kube-state-metrics Dependency-Major-Bump 7.8.1→8.0.0 (Chart-Upgrade-Hinweis: nur Drop von `CiliumNetworkPolicy`-Support, hier nicht genutzt, kein Cilium im Cluster), Grafana 12.7.2→12.8.1; kein Operator/CRD-Change (Operator bleibt v0.92.1) | Auf Wunsch des Nutzers direkt ausgeführt (nicht über upgrade-agent); Release-Notes/Dependency-Diff vorab per GitHub-Compare-API geprüft |

**Nicht produktiv gelandeter Zwischenschritt:** Commit `85b2150` ("chore: upgrade kube-prometheus-stack 86.2.3 → 86.3.2", Auto-Upgrade durch den upgrade-agent, 2026-06-22) existiert nur auf dem nie gemergten Branch `origin/chore/upgrade-kube-prometheus-stack-86.3.2`. Er wurde durch die manuelle Migration auf 87.3.0 (`ab63282`, 2026-06-29) überholt und ist nie in `main`/den Cluster gelangt — daher kein Eintrag in der Changelog-Tabelle oben.

### Reklassifizierungen (Minor → Major)

| Datum Erkennung | Ursprünglicher Changelog-Eintrag (Datum) | Grund der Reklassifizierung | Erneute Benachrichtigung gesendet am |
|---|---|---|---|

## Manuelle Vorgehensweise (bei Major/Breaking Change)

### Strategie: Stufenweises Upgrade über Breaking-Change-Stationen

Jeder Major-Bump kann CRD-Änderungen enthalten. Die Reihenfolge ist zwingend:

1. **CRDs manuell applyen** (server-side apply, vor dem ArgoCD-Sync)
2. **`targetRevision` in Git ändern** und pushen
3. **ArgoCD-Sync** abwarten und verifizieren
4. **Weiter zur nächsten Station**

> Zwischen den unten dokumentierten Breaking-Change-Versionen kann man innerhalb
> einer Major-Linie direkt springen, da dort keine dokumentierten Breaking
> Changes auftreten (siehe Changelog-Tabelle oben für die real durchgeführten Sprünge).

### Voraussetzungen

**Backup anlegen:**

```bash
kubectl get prometheusrules -n monitoring -o yaml > ~/monitoring-backup/prometheusrules-$(date +%Y%m%d).yaml
kubectl get servicemonitors,podmonitors -n monitoring -o yaml > ~/monitoring-backup/monitors-$(date +%Y%m%d).yaml
kubectl get configmap -n monitoring -l grafana_dashboard=1 -o yaml > ~/monitoring-backup/grafana-dashboards-$(date +%Y%m%d).yaml
kubectl get secret -n monitoring alertmanager-kube-prometheus-stack-alertmanager -o yaml > ~/monitoring-backup/alertmanager-secret-$(date +%Y%m%d).yaml
kubectl get pvc -n monitoring > ~/monitoring-backup/pvcs-$(date +%Y%m%d).txt
```

**ArgoCD vorbereiten:** Vor dem Upgrade Auto-Sync für die monitoring-App deaktivieren, damit CRDs zuerst manuell applyed werden können:

```bash
argocd app set kube-prometheus-stack --sync-policy none
# Alternativ in der ArgoCD-UI: App → Details → Sync Policy → None
```

**Grafana Deployment-Strategy auf `Recreate`:** Grafana verwendet ein RWO-Longhorn-PVC. Beim Rolling Update versucht der neue Pod das PVC zu mounten während der alte es noch hält — das führt zu `Multi-Attach`-Fehler, neuer Pod hängt in `Init:0/1`. Bereits dauerhaft in `gitops/apps/monitoring.yaml` gesetzt:

```yaml
grafana:
  persistence:
    enabled: true
    storageClassName: longhorn
    size: 10Gi
  deploymentStrategy:
    type: Recreate   # verhindert Multi-Attach bei jedem Upgrade
```

Kurze Grafana-Downtime (~30s) beim Upgrade, aber kein manuelles Eingreifen mehr nötig.

**Konflikt-Flag:** `--force-conflicts` ist in allen CRD-Befehlen dieses Runbooks gesetzt. Der `argocd-controller` ist Field Manager der CRDs — der Konflikt ist erwartet und mit diesem Flag sicher auflösbar.

### Generisches Vorgehen pro Station (CRD-Update nötig)

```bash
# 1. CRDs für die Ziel-Operator-Version applyen
BASE="https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/vX.Y.Z/example/prometheus-operator-crd"
for crd in alertmanagerconfigs alertmanagers podmonitors probes prometheusagents prometheuses prometheusrules scrapeconfigs servicemonitors thanosrulers; do
  kubectl apply --server-side --force-conflicts -f "${BASE}/monitoring.coreos.com_${crd}.yaml"
done

# 2. targetRevision in gitops/apps/monitoring.yaml setzen, committen, pushen
git add gitops/apps/monitoring.yaml
git commit -m "chore(monitoring): upgrade kube-prometheus-stack <ALT> → <NEU>"
git push

# 3. Sync abwarten
argocd app sync kube-prometheus-stack --timeout 300
argocd app wait kube-prometheus-stack --health --timeout 300

# 4. Verifizieren
kubectl get pods -n monitoring
kubectl get prometheusrules -n monitoring
kubectl get servicemonitors -n monitoring
```

### Dokumentierte Breaking-Change-Stationen (aus der historischen Migration 55.5.0 → 87.3.0)

| Station | Chart-Version | Operator | Besonderheit |
|---------|--------------|---------------------|--------------|
| Start   | 55.5.0       | v0.70.0             | Ist-Zustand bei Runbook-Erstellung |
| 1       | 55.5.0 → 62.x  | v0.76.0             | `*SelectorNilUsesHelmValues` deprecated |
| 2       | 62.x → 67.x  | v0.79.0             | **Prometheus 3.x wird Default** |
| 3       | 67.x → 69.x  | v0.80.0             | CRD-Update |
| 4       | 69.x → 71.x  | v0.82.0             | `podDisruptionBudget.enabled` jetzt explizit nötig |
| 5       | 71.x → 73.x  | —                   | **K8s ≥1.25 erforderlich, PodSecurityPolicy entfernt** |
| 6       | 73.x → 75.x  | v0.83.0             | CRD-Update + Namenspräfix-Änderung `additionalPrometheusRules` |
| 7       | 75.x → 76.x  | v0.84.1             | CEL-Validierung in CRDs → K8s ≥1.25 |
| 8       | 76.x → 77.x  | v0.85.0             | CRD-Update |
| 9       | 77.x → 78.x  | v0.86.0             | CRD-Update |
| 10      | 78.x → 79.x  | —                   | **Grafana Default-Passwort entfernt** |
| 11      | 79.x → 80.x  | v0.87.0             | CRD-Update |
| 12      | 80.x → 81.x  | v0.88.0             | CRD-Update |
| 13      | 81.x → 84.5.0| v0.89.0             | CRD-Update |
| 14      | 84.5.0 → 85.1.3 | v0.90.1 (unverändert) | Distroless Images Default |
| 15      | 85.1.3 → 85.3.3 | v0.90.1 (unverändert) | Maintenance (Grafana 12.4.1) |
| 16      | 85.3.3 → 86.2.0 | **v0.91.0**           | CRD-Update + Prometheus 3.12 |
| 17      | 86.2.0 → 86.2.3 | v0.91.0 (unverändert) | Maintenance (Grafana 12.4.5, kube-state-metrics 7.4.1) |
| 18      | 86.2.3 → 87.3.0 | **v0.92.0**           | CRD-Update + Grafana 12.7.1 + kube-state-metrics 7.5.1 |
| 19      | 87.3.0 → 87.10.1 | v0.92.0 → v0.92.1 | Automatisches Minor-Update (Commit `a7d6250`); Operator-Patch-Bump ohne CRD-Schema-Änderung |
| 20      | 87.10.1 → 87.15.1 | v0.92.1 (unverändert) | Automatisches Minor-Update (Commit `af699f0`), reine Dependency-Image-Updates |
| 21      | 87.15.1 → 87.17.0 | v0.92.1 (unverändert) | Automatisches Minor-Update (Commit `35e4ad9`), Scrape-Config-Ergänzung kube-scheduler-Metriken |
| 22      | 87.17.0 → 87.19.2 | v0.92.1 (unverändert) | Manuelles Minor-Update, kube-state-metrics Dependency-Major-Bump 7.8.1→8.0.0 (CiliumNetworkPolicy-Drop, nicht genutzt), Grafana 12.8.1 |

### Besondere Breaking Changes im Detail

**Prometheus 3.x Default (Station 2, Chart 67.x):** Kritischster Schritt der gesamten Migration.

```bash
# Aktuelle Prometheus-Version im Cluster
kubectl get prometheus -n monitoring kube-prometheus-stack-prometheus -o jsonpath='{.spec.version}'

kubectl exec -n monitoring \
  $(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}') \
  -- /bin/prometheus --version 2>&1 | head -1
```

Bekannte Breaking Changes: `remote_write` API-Änderungen (Remote Write 2.0), einige deprecated Flags entfernt, native Histogramme als Default in manchen Metriken, `--query.lookback-delta` Default geändert. Falls explizit auf Prometheus 2.x verbleiben:

```yaml
prometheus:
  prometheusSpec:
    image:
      tag: v2.55.0
```

Chart 67.x/68.x droppt zudem standardmäßig mehrere High-Cardinality-Buckets — falls eigene Relabeling-Rules diese gezielt behalten, prüfen:

```bash
kubectl get prometheusrules -n monitoring -o yaml | grep -E "apiserver_request_sli|apiserver_request_slo|etcd_request_duration|csi_operations|storage_operation"
```

**PodSecurityPolicy entfernt (Station 5, Chart 73.x):** Voraussetzung K8s ≥1.25.

```bash
kubectl version --short | grep Server
grep -r pspEnabled gitops/
grep -r pspAnnotations gitops/
```

**Grafana Default-Passwort entfernt (Station 10, Chart 79.x):** Vorher aktuelles Passwort sichern oder explizit setzen (idealerweise via Sealed Secret):

```bash
kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d
```

**CRD-Update v0.91.0 (Station 16, Chart 86.2.0):** ScrapeConfig-Mutual-Exclusion für basicAuth/authorization/oauth2, neues `healthFilter`; AlertmanagerConfig-Validierungen für VictorOps/OpsGenie/Email; neue Feature-Gates `PrometheusShardRetentionPolicy`/`PrometheusTopologySharding`; SigV4-Feld `externalId`; ThanosRuler `cipherSuites`/`curves`.

**CRD-Update v0.92.0 (Station 18, Chart 87.3.0):** Alle 10 CRDs Schema-Änderungen (keine neuen CRD-Arten). `PrometheusTopologySharding`/`PrometheusShardRetentionPolicy` Beta (jetzt standardmäßig aktiv); URL-Validierung für OAuth2 `tokenUrl` und RemoteRead `url`; neues Feld `staleSeriesCompactionThreshold` in TSDBSpec; neues Feld `payload` im Webhook-Receiver.

### Abschluss-Verifikation

```bash
kubectl get deployment -n monitoring kube-prometheus-stack-operator \
  -o jsonpath='{.spec.template.spec.containers[0].image}'; echo

kubectl get pods -n monitoring
kubectl get crds | grep monitoring.coreos.com

kubectl exec -n monitoring \
  $(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus -o name | head -1) \
  -- /bin/prometheus --version 2>&1 | head -1

curl -s -o /dev/null -w "%{http_code}" https://grafana.reckeweg.io/api/health
kubectl get alertmanager -n monitoring
argocd app get kube-prometheus-stack
```

**Erwartete Ergebnisse nach erfolgreichem Upgrade auf 87.3.0 (Referenzwerte der letzten Major-Station):**
- Prometheus-Operator: `v0.92.0`
- Prometheus: `3.x` (Distroless-Image)
- Alertmanager: `v0.32.2`
- Grafana: `12.7.1`, HTTP Status: `200`
- kube-state-metrics: `7.5.1`
- Alle 10 CRDs: `Healthy`
- ArgoCD: `Synced`, `Health Status: Healthy`

Auto-Sync danach wieder aktivieren:

```bash
argocd app set kube-prometheus-stack --sync-policy automated --self-heal --auto-prune
```

## Bekannte Stolperfallen / Lessons Learned

- **CRD-Konflikt beim apply:** `argocd-controller` ist Field Manager der CRDs — Konflikt ist erwartet und normal, immer `--server-side --force-conflicts` verwenden.
- **ArgoCD meldet OutOfSync nach CRD-Update:** Erwartet, da ArgoCD Ist-Zustand (neue CRDs) mit Soll-Zustand (alte Chart-Version) vergleicht. Deshalb immer CRDs applyen **und dann sofort** `targetRevision` ändern + sync. Bei bekanntem PrometheusRule-`/spec`-Problem in der ArgoCD-App-Definition:
  ```yaml
  ignoreDifferences:
    - group: monitoring.coreos.com
      kind: PrometheusRule
      jsonPointers:
        - /spec
  ```
- **ArgoCD-Sync hängt: "another operation is already in progress":** Tritt auf, wenn ein vorheriger Sync nicht sauber abgeschlossen wurde.
  ```bash
  argocd app terminate-op kube-prometheus-stack
  sleep 10 && argocd app sync kube-prometheus-stack --timeout 300
  # Falls weiterhin blockiert:
  kubectl patch application kube-prometheus-stack -n argocd --type merge -p='{"operation": null}'
  kubectl rollout restart statefulset -n argocd argocd-application-controller
  argocd app sync kube-prometheus-stack --timeout 300
  ```
- **Prometheus-Operator startet nicht nach CRD-Update:** Race Condition (Operator startet bevor CRD `Established` ist) — `kubectl rollout restart deployment -n monitoring kube-prometheus-stack-operator`.
- **Grafana CrashLoopBackOff: "Only one datasource per organization can be marked as default":** Tritt bei jedem Grafana-Versionssprung auf, solange `loki-stack` die Loki-Datasource mit `isDefault: true` deployed. **Dauerhaft gefixt am 2026-05-03** in `gitops/apps/loki.yaml` mit explizitem Datasource-Override (`isDefault: false`, `defaultDatasourceEnabled: false`). Notfall-Sofortfix falls ArgoCD den Fix noch nicht gesynct hat (erst anwenden, wenn Grafana bereits crasht, nicht vorher):
  ```bash
  kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -w
  kubectl patch configmap loki-stack -n monitoring --type merge \
    -p='{"data":{"loki-stack-datasource.yaml":"apiVersion: 1\ndatasources:\n- name: Loki\n  type: loki\n  access: proxy\n  url: \"http://loki-stack:3100\"\n  version: 1\n  isDefault: false\n  jsonData:\n    {}"}}'
  kubectl rollout restart deployment -n monitoring kube-prometheus-stack-grafana
  ```
- **Grafana sync-Fehler "spec.strategy.rollingUpdate Forbidden when type is Recreate":** Tritt auf, wenn das Deployment im Cluster noch `RollingUpdate` gesetzt hat, aber values.yaml bereits `Recreate` konfiguriert.
  ```bash
  kubectl patch deployment -n monitoring kube-prometheus-stack-grafana --type merge \
    -p='{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
  kubectl patch application kube-prometheus-stack -n argocd --type merge -p='{"operation": null}'
  argocd app sync kube-prometheus-stack --timeout 300
  ```
- **Grafana-Passwort nach 79.x unbekannt:** `kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d`
- **Auto-Upgrade-Vorsicht bei diesem Chart:** Anders als bei den meisten anderen Diensten koppelt kube-prometheus-stack Minor-Versionssprünge fast immer an Operator/CRD-Änderungen. Ein rein numerisch als "Minor" erkannter Sprung (z.B. 86.2.3→87.3.0 wäre nominell minor, enthielt aber ein CRD-Update auf v0.92.0) kann trotzdem manuelles Eingreifen erfordern — der Versions-Checker sollte für diesen Chart nicht blind auf SemVer-Minor vertrauen.
- **Sub-Dependency-Major-Bumps innerhalb eines Chart-Minor-Releases:** Der Chart bündelt kube-state-metrics, Grafana und weitere Sub-Charts als Dependencies mit eigenem SemVer. Ein chart-seitig "minor" Sprung (z.B. 87.17.0→87.19.2) kann intern einen Major-Bump einer Dependency enthalten (hier: kube-state-metrics 7.8.1→8.0.0). Vor jedem Auto-/Manuell-Upgrade lohnt ein Blick auf `dependencies:` im `Chart.yaml` der Ziel-Version (`curl -s https://raw.githubusercontent.com/prometheus-community/helm-charts/kube-prometheus-stack-<VERSION>/charts/kube-prometheus-stack/Chart.yaml`) sowie ggf. das `Upgrading to vX` im README der Dependency, bevor man sich nur auf die Chart-eigene Versionsnummer verlässt.
- **Nie gemergter Zwischenschritt 86.3.2:** Der upgrade-agent hatte am 2026-06-22 automatisch 86.2.3→86.3.2 als PR-Branch vorbereitet (`origin/chore/upgrade-kube-prometheus-stack-86.3.2`), der jedoch nie gemergt wurde, da die manuelle Migration auf 87.3.0 bereits am 2026-06-29 direkt ab dem gleichen Basisstand (86.2.3) durchgeführt wurde. Branch kann bei Aufräumarbeiten gelöscht werden, sofern nicht anderweitig benötigt.

## Rollback-Plan
- CRD-Rollback ist riskant (ältere CRD-Version kann neuere Felder nicht validieren) — im Zweifel CRDs auf der neueren Version belassen und nur `targetRevision` zurücksetzen.
- `targetRevision` in `gitops/apps/monitoring.yaml` auf die vorherige funktionierende Version setzen, committen, pushen:
  ```bash
  git add gitops/apps/monitoring.yaml
  git commit -m "revert: kube-prometheus-stack zurück auf <ALT>"
  git push
  argocd app sync kube-prometheus-stack --timeout 300
  argocd app wait kube-prometheus-stack --health --timeout 300
  ```
- Nach Rollback: Grafana-Dashboards, Alertmanager-Config und PrometheusRules aus dem Pre-Upgrade-Backup wiederherstellen, falls durch den fehlgeschlagenen Versuch verändert.
- Auto-Sync erst nach bestätigt stabilem Zustand wieder aktivieren (`argocd app set kube-prometheus-stack --sync-policy automated --self-heal --auto-prune`).

## Referenzen
- Offizielles UPGRADE.md: https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/UPGRADE.md
- prometheus-operator CRD Releases: https://github.com/prometheus-operator/prometheus-operator/releases
- ArtifactHub: https://artifacthub.io/packages/helm/prometheus-community/kube-prometheus-stack
- Lokale ArgoCD App: `gitops/apps/monitoring.yaml`
