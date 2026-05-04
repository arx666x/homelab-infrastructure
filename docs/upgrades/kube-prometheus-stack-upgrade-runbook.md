# Runbook: kube-prometheus-stack Upgrade 55.5.0 → 84.5.0

**Umgebung:** homelab k3s-Cluster (`reckeweg.io`)  
**Namespace:** `monitoring`  
**ArgoCD App:** `gitops/apps/monitoring.yaml`  
**Aktueller Stand:**
- Chart: `55.5.0` → `targetRevision: "55.5.0"` in Git
- Prometheus-Operator: `v0.70.0`
- Alle 10 CRDs `monitoring.coreos.com` vorhanden (Stand: 2026-02-23)
- PVCs: Alertmanager (10Gi), Grafana (10Gi), Prometheus (50Gi), Loki (20Gi) — alle `Bound`

---

## Strategie: Stufenweise Upgrade über Breaking-Change-Stationen

Jeder Major-Bump kann CRD-Änderungen enthalten. Die Reihenfolge ist zwingend:

1. **CRDs manuell applyen** (server-side apply, vor dem ArgoCD-Sync)
2. **`targetRevision` in Git ändern** und pushen
3. **ArgoCD sync** abwarten und verifizieren
4. **Weiter zur nächsten Station**

**Stufenplan:**

| Station | Chart-Version | Prometheus-Operator | Besonderheit |
|---------|--------------|---------------------|--------------|
| Start   | 55.5.0       | v0.70.0             | Ist-Zustand  |
| 1       | 61.x → 62.x  | v0.76.0             | CRD-Update   |
| 2       | 66.x → 67.x  | v0.79.0             | **Prometheus 3.x Default** |
| 3       | 68.x → 69.x  | v0.80.0             | CRD-Update   |
| 4       | 70.x → 71.x  | v0.82.0             | CRD-Update   |
| 5       | 72.x → 73.x  | —                   | **K8s ≥1.25 required, PodSecurityPolicy removed** |
| 6       | 74.x → 75.x  | v0.83.0             | CRD-Update + Namenspräfix-Änderung |
| 7       | 75.x → 76.x  | v0.84.1             | CRD-Update   |
| 8       | 76.x → 77.x  | v0.85.0             | CRD-Update   |
| 9       | 77.x → 78.x  | v0.86.0             | CRD-Update   |
| 10      | 78.x → 79.x  | —                   | **Grafana Default-Passwort entfernt** |
| 11      | 79.x → 80.x  | v0.87.0             | CRD-Update   |
| 12      | 80.x → 81.x  | v0.88.0             | CRD-Update   |
| 13      | 81.x → 82.x  | v0.89.0             | CRD-Update   |
| Ziel    | 84.5.0       | aktuell             | —            |

> **Hinweis:** Zwischen den explizit genannten Breaking-Change-Versionen kann man
> innerhalb einer Major-Linie (z. B. 55.x → 61.x) direkt springen, da dort keine
> dokumentierten Breaking Changes auftreten.

---

## Voraussetzungen

### Backup anlegen

```bash
# PrometheusRules sichern
kubectl get prometheusrules -n monitoring -o yaml > ~/monitoring-backup/prometheusrules-$(date +%Y%m%d).yaml

# ServiceMonitor / PodMonitor sichern
kubectl get servicemonitors,podmonitors -n monitoring -o yaml > ~/monitoring-backup/monitors-$(date +%Y%m%d).yaml

# Grafana-Dashboards (falls in ConfigMaps)
kubectl get configmap -n monitoring -l grafana_dashboard=1 -o yaml > ~/monitoring-backup/grafana-dashboards-$(date +%Y%m%d).yaml

# Alertmanager-Config
kubectl get secret -n monitoring alertmanager-kube-prometheus-stack-alertmanager -o yaml > ~/monitoring-backup/alertmanager-secret-$(date +%Y%m%d).yaml

# PVC-Liste dokumentieren
kubectl get pvc -n monitoring > ~/monitoring-backup/pvcs-$(date +%Y%m%d).txt
```

### ArgoCD vorbereiten

Vor dem Upgrade ArgoCD-Auto-Sync für die monitoring-App **deaktivieren**, damit
CRDs zuerst manuell applyed werden können, bevor ArgoCD die neue Chart-Version
ausrollt:

```bash
argocd app set kube-prometheus-stack --sync-policy none
# Alternativ in der ArgoCD-UI: App → Details → Sync Policy → None
```

### Grafana Deployment-Strategy auf Recreate setzen

Grafana verwendet ein RWO-Longhorn-PVC. Beim Rolling Update versucht der neue
Pod das PVC zu mounten während der alte es noch hält — das führt zu einem
`Multi-Attach`-Fehler und der neue Pod hängt in `Init:0/1`.

**Einmalig in `gitops/apps/monitoring.yaml` eintragen** (vor dem ersten Upgrade):

```yaml
grafana:
  persistence:
    enabled: true
    storageClassName: longhorn
    size: 10Gi
  deploymentStrategy:
    type: Recreate   # verhindert Multi-Attach bei jedem Upgrade
```

Mit `Recreate` fährt der alte Pod erst vollständig runter bevor der neue
startet. Kurze Grafana-Downtime (~30s) beim Upgrade, aber kein manuelles
Eingreifen mehr nötig.

### Konflikt-Flag bereithalten

`--force-conflicts` ist bereits in allen CRD-Befehlen dieses Runbooks gesetzt.
Der `argocd-controller` ist Field Manager der CRDs — der Konflikt ist erwartet
und mit diesem Flag sicher auflösbar.

---

## Station 1: Chart 55.5.0 → 62.x (Operator v0.76.0)

### Breaking Change: `*SelectorNilUsesHelmValues` deprecated (62.x)

Falls in `values.yaml` einer der folgenden Werte auf `false` gesetzt ist,
muss er migriert werden:

```yaml
# ALT (deprecated ab 62.x):
prometheus:
  prometheusSpec:
    podMonitorSelectorNilUsesHelmValues: false
    serviceMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    scrapeConfigSelectorNilUsesHelmValues: false
    probeSelectorNilUsesHelmValues: false
thanosRuler:
  thanosRulerSpec:
    ruleSelectorNilUsesHelmValues: false

# NEU (ab 62.x):
prometheus:
  prometheusSpec:
    serviceMonitorSelector:
      matchLabels: null
    # (analog für die anderen Selektoren)
```

> **Prüfen:** `grep -r SelectorNilUsesHelmValues gitops/`

### Schritt 1.1: CRDs für v0.76.0 applyen

```bash
BASE="https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.76.0/example/prometheus-operator-crd"
for crd in alertmanagerconfigs alertmanagers podmonitors probes prometheusagents prometheuses prometheusrules scrapeconfigs servicemonitors thanosrulers; do
  kubectl apply --server-side --force-conflicts -f "${BASE}/monitoring.coreos.com_${crd}.yaml"
done
```

### Schritt 1.2: Chart-Version in Git setzen

```bash
# In gitops/apps/monitoring.yaml:
# targetRevision: "62.3.0"   # (oder höchste verfügbare 62.x)

git add gitops/apps/monitoring.yaml
git commit -m "chore(monitoring): upgrade kube-prometheus-stack 55.5.0 → 62.x"
git push
```

### Schritt 1.3: ArgoCD sync und verifizieren

```bash
argocd app sync kube-prometheus-stack --timeout 300
argocd app wait kube-prometheus-stack --health --timeout 300

# Verifizieren
kubectl get pods -n monitoring
kubectl get prometheusrules -n monitoring
kubectl get servicemonitors -n monitoring
```

---

## Station 2: Chart 62.x → 67.x (Operator v0.79.0 + **Prometheus 3.x**)

> ⚠️ **Kritischer Breaking Change:** Ab Chart 67.x ist **Prometheus 3.x der Default**.
> Prometheus 3.0 hat mehrere Breaking Changes gegenüber 2.x.

### Prometheus 3.x Breaking Changes prüfen

```bash
# Aktuelle Prometheus-Version im Cluster
kubectl get prometheus -n monitoring kube-prometheus-stack-prometheus \
  -o jsonpath='{.spec.version}'

# Laufende Prometheus-Version
kubectl exec -n monitoring \
  $(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus \
    -o jsonpath='{.items[0].metadata.name}') \
  -- /bin/prometheus --version 2>&1 | head -1
```

**Bekannte Prometheus 3.x Breaking Changes:**

- `remote_write` API-Änderungen (Remote Write 2.0)
- Einige deprecated Flags wurden entfernt
- Native Histogramme als Default in manchen Metriken
- `--query.lookback-delta` Default geändert

**Falls ihr explizit auf Prometheus 2.x bleiben wollt:**

```yaml
# In values.yaml Overlay explizit pinnen:
prometheus:
  prometheusSpec:
    image:
      tag: v2.55.0
```

### Schritt 2.1: Histogram-Filter (neu ab Chart 67.x / 68.x)

Chart 67.x/68.x dropped standardmäßig mehrere High-Cardinality-Buckets.
Falls eigene Relabeling-Rules diese Metriken gezielt behalten, jetzt prüfen:

```bash
kubectl get prometheusrules -n monitoring -o yaml | grep -E "apiserver_request_sli|apiserver_request_slo|etcd_request_duration|csi_operations|storage_operation"
```

### Schritt 2.2: CRDs für v0.79.0 applyen

```bash
BASE="https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.79.0/example/prometheus-operator-crd"
for crd in alertmanagerconfigs alertmanagers podmonitors probes prometheusagents prometheuses prometheusrules scrapeconfigs servicemonitors thanosrulers; do
  kubectl apply --server-side --force-conflicts -f "${BASE}/monitoring.coreos.com_${crd}.yaml"
done
```

### Schritt 2.3: Chart-Version in Git setzen und sync

```bash
# targetRevision: "67.x.x"
git add gitops/apps/monitoring.yaml
git commit -m "chore(monitoring): upgrade kube-prometheus-stack 62.x → 67.x (Prometheus 3.x)"
git push

argocd app sync kube-prometheus-stack --timeout 300
argocd app wait kube-prometheus-stack --health --timeout 300

# Prometheus-Version verifizieren
kubectl exec -n monitoring \
  $(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus \
    -o jsonpath='{.items[0].metadata.name}') \
  -- /bin/prometheus --version 2>&1 | head -1
```

---

## Station 3: Chart 67.x → 69.x (Operator v0.80.0)

### Schritt 3.1: CRDs für v0.80.0

```bash
BASE="https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.80.0/example/prometheus-operator-crd"
for crd in alertmanagerconfigs alertmanagers podmonitors probes prometheusagents prometheuses prometheusrules scrapeconfigs servicemonitors thanosrulers; do
  kubectl apply --server-side --force-conflicts -f "${BASE}/monitoring.coreos.com_${crd}.yaml"
done
```

### Schritt 3.2: Sync auf 69.x

```bash
# targetRevision: "69.x.x"
git add gitops/apps/monitoring.yaml
git commit -m "chore(monitoring): upgrade kube-prometheus-stack 67.x → 69.x"
git push

argocd app sync kube-prometheus-stack --timeout 300
argocd app wait kube-prometheus-stack --health --timeout 300
```

---

## Station 4: Chart 69.x → 71.x (Operator v0.82.0)

### Schritt 4.1: CRDs für v0.82.0

```bash
BASE="https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.82.0/example/prometheus-operator-crd"
for crd in alertmanagerconfigs alertmanagers podmonitors probes prometheusagents prometheuses prometheusrules scrapeconfigs servicemonitors thanosrulers; do
  kubectl apply --server-side --force-conflicts -f "${BASE}/monitoring.coreos.com_${crd}.yaml"
done
```

### Schritt 4.2: `podDisruptionBudget.enabled` prüfen (71.x Breaking Change)

Ab Chart 71.x muss `podDisruptionBudget.enabled: true` explizit gesetzt sein,
wenn ein PDB gewünscht wird. Default ist jetzt `false`.

```bash
grep -r podDisruptionBudget gitops/
```

### Schritt 4.3: Sync auf 71.x

```bash
# targetRevision: "71.x.x"
git add gitops/apps/monitoring.yaml
git commit -m "chore(monitoring): upgrade kube-prometheus-stack 69.x → 71.x"
git push

argocd app sync kube-prometheus-stack --timeout 300
argocd app wait kube-prometheus-stack --health --timeout 300
```

---

## Station 5: Chart 71.x → 73.x (**K8s 1.25+ Required + PodSecurityPolicy entfernt**)

> ⚠️ **Voraussetzung: Kubernetes ≥ 1.25**

```bash
kubectl version --short | grep Server
```

Falls der Cluster noch auf < 1.25 läuft: **Erst Cluster upgraden, dann weitermachen.**

### PodSecurityPolicy entfernt

Ab Chart 73.x sind alle `PodSecurityPolicy`-Ressourcen und die Felder
`global.pspEnabled` / `global.pspAnnotations` entfernt.

```bash
# Prüfen ob PSP noch in values.yaml gesetzt ist:
grep -r pspEnabled gitops/
grep -r pspAnnotations gitops/
# Falls gefunden: aus allen Overlays entfernen
```

### Ingress API-Versionen: deprecated APIs entfernt

Chart 73.x entfernt Support für deprecated K8s Ingress API-Versionen.
Betrifft nur, wenn ihr Ingress-Objekte für Grafana/Prometheus über den Chart
deployt (nicht Traefik IngressRoute). Wahrscheinlich nicht relevant.

### Schritt 5.1: Sync auf 73.x

Kein CRD-Update nötig für diesen Schritt.

```bash
# targetRevision: "73.x.x"
git add gitops/apps/monitoring.yaml
git commit -m "chore(monitoring): upgrade kube-prometheus-stack 71.x → 73.x (PSP removed, K8s 1.25+)"
git push

argocd app sync kube-prometheus-stack --timeout 300
argocd app wait kube-prometheus-stack --health --timeout 300
```

---

## Station 6: Chart 73.x → 75.x (Operator v0.83.0 + Namenspräfix-Änderung)

### Breaking Change: `additionalPrometheusRules` Präfix geändert (74.x)

Falls `additionalPrometheusRules` oder `additionalPrometheusRulesMap` in
`values.yaml` verwendet wird: Die erstellten Objekte werden jetzt mit
`{{ template "kube-prometheus-stack.fullname" $ }}` statt dem alten
`kube-prometheus-stack.name`-Template prefixed.

```bash
# Prüfen:
grep -r additionalPrometheusRules gitops/
```

Wenn verwendet: Die alten PrometheusRule-Objekte werden gelöscht und mit
neuem Namen neu erstellt. Das ist unkritisch (kurze Lücke in Alert-Evaluation).

### Schritt 6.1: CRDs für v0.83.0

```bash
BASE="https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.83.0/example/prometheus-operator-crd"
for crd in alertmanagerconfigs alertmanagers podmonitors probes prometheusagents prometheuses prometheusrules scrapeconfigs servicemonitors thanosrulers; do
  kubectl apply --server-side --force-conflicts -f "${BASE}/monitoring.coreos.com_${crd}.yaml"
done
```

### Schritt 6.2: Sync auf 75.x

```bash
# targetRevision: "75.x.x"
git add gitops/apps/monitoring.yaml
git commit -m "chore(monitoring): upgrade kube-prometheus-stack 73.x → 75.x"
git push

argocd app sync kube-prometheus-stack --timeout 300
argocd app wait kube-prometheus-stack --health --timeout 300
```

---

## Station 7: Chart 75.x → 76.x (Operator v0.84.1)

> ⚠️ **Prometheus-Operator v0.84.0+ erfordert Kubernetes ≥ 1.25** (wegen CEL in CRDs)
> — sollte bereits erfüllt sein.

### Schritt 7.1: CRDs für v0.84.1

```bash
BASE="https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.84.1/example/prometheus-operator-crd"
for crd in alertmanagerconfigs alertmanagers podmonitors probes prometheusagents prometheuses prometheusrules scrapeconfigs servicemonitors thanosrulers; do
  kubectl apply --server-side --force-conflicts -f "${BASE}/monitoring.coreos.com_${crd}.yaml"
done
```

### Schritt 7.2: Sync auf 76.x

```bash
# targetRevision: "76.x.x"
git add gitops/apps/monitoring.yaml
git commit -m "chore(monitoring): upgrade kube-prometheus-stack 75.x → 76.x (operator v0.84.1)"
git push

argocd app sync kube-prometheus-stack --timeout 300
argocd app wait kube-prometheus-stack --health --timeout 300
```

---

## Station 8: Chart 76.x → 77.x (Operator v0.85.0)

### Schritt 8.1: CRDs für v0.85.0

```bash
BASE="https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.85.0/example/prometheus-operator-crd"
for crd in alertmanagerconfigs alertmanagers podmonitors probes prometheusagents prometheuses prometheusrules scrapeconfigs servicemonitors thanosrulers; do
  kubectl apply --server-side --force-conflicts -f "${BASE}/monitoring.coreos.com_${crd}.yaml"
done
```

### Schritt 8.2: Sync auf 77.x

```bash
# targetRevision: "77.x.x"
git add gitops/apps/monitoring.yaml
git commit -m "chore(monitoring): upgrade kube-prometheus-stack 76.x → 77.x"
git push

argocd app sync kube-prometheus-stack --timeout 300
argocd app wait kube-prometheus-stack --health --timeout 300
```

---

## Station 9: Chart 77.x → 78.x (Operator v0.86.0)

### Schritt 9.1: CRDs für v0.86.0

```bash
BASE="https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.86.0/example/prometheus-operator-crd"
for crd in alertmanagerconfigs alertmanagers podmonitors probes prometheusagents prometheuses prometheusrules scrapeconfigs servicemonitors thanosrulers; do
  kubectl apply --server-side --force-conflicts -f "${BASE}/monitoring.coreos.com_${crd}.yaml"
done
```

### Schritt 9.2: Sync auf 78.x

```bash
# targetRevision: "78.x.x"
git add gitops/apps/monitoring.yaml
git commit -m "chore(monitoring): upgrade kube-prometheus-stack 77.x → 78.x"
git push

argocd app sync kube-prometheus-stack --timeout 300
argocd app wait kube-prometheus-stack --health --timeout 300
```

---

## Station 10: Chart 78.x → 79.x (**Grafana Default-Passwort entfernt**)

> ⚠️ **Breaking Change:** Das bisherige Grafana-Default-Passwort `prom-operator`
> wird entfernt. Ab 79.x wird ein zufälliges Passwort generiert.

**Vorher das aktuelle Grafana-Admin-Passwort sichern oder explizit setzen:**

```bash
# Aktuelles Passwort auslesen (falls noch default):
kubectl get secret -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d

# Option A: Explizit in values.yaml setzen (via Sealed Secret empfohlen):
# grafana:
#   adminPassword: "DeinSicheresPasswort"

# Option B: Nach dem Upgrade aus dem generierten Secret lesen:
# kubectl get secret -n monitoring kube-prometheus-stack-grafana \
#   -o jsonpath='{.data.admin-password}' | base64 -d
```

Kein CRD-Update für diesen Schritt nötig.

### Schritt 10.1: Sync auf 79.x

```bash
# targetRevision: "79.x.x"
git add gitops/apps/monitoring.yaml
git commit -m "chore(monitoring): upgrade kube-prometheus-stack 78.x → 79.x (Grafana random password)"
git push

argocd app sync kube-prometheus-stack --timeout 300
argocd app wait kube-prometheus-stack --health --timeout 300

# Grafana-Passwort nach dem Upgrade sichern:
kubectl get secret -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d
echo  # Newline
```

---

## Station 11: Chart 79.x → 80.x (Operator v0.87.0)

### Schritt 11.1: CRDs für v0.87.0

```bash
BASE="https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.87.0/example/prometheus-operator-crd"
for crd in alertmanagerconfigs alertmanagers podmonitors probes prometheusagents prometheuses prometheusrules scrapeconfigs servicemonitors thanosrulers; do
  kubectl apply --server-side --force-conflicts -f "${BASE}/monitoring.coreos.com_${crd}.yaml"
done
```

### Schritt 11.2: Sync auf 80.x

```bash
# targetRevision: "80.x.x"
git add gitops/apps/monitoring.yaml
git commit -m "chore(monitoring): upgrade kube-prometheus-stack 79.x → 80.x"
git push

argocd app sync kube-prometheus-stack --timeout 300
argocd app wait kube-prometheus-stack --health --timeout 300
```

---

## Station 12: Chart 80.x → 81.x (Operator v0.88.0)

### Schritt 12.1: CRDs für v0.88.0

```bash
BASE="https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.88.0/example/prometheus-operator-crd"
for crd in alertmanagerconfigs alertmanagers podmonitors probes prometheusagents prometheuses prometheusrules scrapeconfigs servicemonitors thanosrulers; do
  kubectl apply --server-side --force-conflicts -f "${BASE}/monitoring.coreos.com_${crd}.yaml"
done
```

### Schritt 12.2: Sync auf 81.x

```bash
# targetRevision: "81.x.x"
git add gitops/apps/monitoring.yaml
git commit -m "chore(monitoring): upgrade kube-prometheus-stack 80.x → 81.x"
git push

argocd app sync kube-prometheus-stack --timeout 300
argocd app wait kube-prometheus-stack --health --timeout 300
```

---

## Station 13 (Final): Chart 81.x → 84.5.0 (Operator v0.89.0)

### Schritt 13.1: CRDs für v0.89.0

```bash
BASE="https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.89.0/example/prometheus-operator-crd"
for crd in alertmanagerconfigs alertmanagers podmonitors probes prometheusagents prometheuses prometheusrules scrapeconfigs servicemonitors thanosrulers; do
  kubectl apply --server-side --force-conflicts -f "${BASE}/monitoring.coreos.com_${crd}.yaml"
done
```

### Schritt 13.2: Finales Ziel in Git setzen

```bash
# targetRevision: "84.5.0"
git add gitops/apps/monitoring.yaml
git commit -m "chore(monitoring): upgrade kube-prometheus-stack 81.x → 84.5.0 (final)"
git push

argocd app sync kube-prometheus-stack --timeout 300
argocd app wait kube-prometheus-stack --health --timeout 300
```

---

## Abschluss-Verifikation

```bash
# Operator-Version
kubectl get deployment -n monitoring kube-prometheus-stack-operator \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
echo

# Alle Pods healthy
kubectl get pods -n monitoring

# CRD-Versionen
kubectl get crds | grep monitoring.coreos.com

# Prometheus-Version
kubectl exec -n monitoring \
  $(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus -o name | head -1) \
  -- /bin/prometheus --version 2>&1 | head -1

# Grafana erreichbar
curl -s -o /dev/null -w "%{http_code}" https://grafana.reckeweg.io/api/health

# Alertmanager healthy
kubectl get alertmanager -n monitoring

# ArgoCD-App-Status
argocd app get kube-prometheus-stack
```

**Erwartete Ergebnisse nach erfolgreichem Upgrade auf 84.5.0:**
- Prometheus-Operator: `v0.90.1`
- Prometheus: `3.11.3`
- Grafana HTTP Status: `200`
- Alle 10 CRDs: `Healthy`
- ArgoCD: `Synced to 84.5.0`, `Health Status: Healthy`

### Auto-Sync wieder aktivieren (optional)

```bash
argocd app set kube-prometheus-stack --sync-policy automated --self-heal --auto-prune
```

---

## Troubleshooting

### CRD-Konflikt beim apply

```
error: Apply failed with 3 conflicts: conflicts with "argocd-controller" using apiextensions.k8s.io/v1
- .metadata.annotations.controller-gen.kubebuilder.io/version
- .metadata.annotations.operator.prometheus.io/version
- .spec.versions
```

Der `argocd-controller` ist Field Manager der CRDs — erwartet und normal.
`--force-conflicts` ist bereits in allen CRD-Befehlen dieses Runbooks gesetzt.
Falls doch ohne Flag ausgeführt: einfach `--force-conflicts` ergänzen:

```bash
kubectl apply --server-side --force-conflicts -f <url>
```

### ArgoCD meldet OutOfSync nach CRD-Update

Das ist expected — ArgoCD vergleicht den Ist-Zustand (neue CRDs) mit dem Soll-Zustand
(alte Chart-Version). Deshalb immer CRDs applyen **und dann sofort** `targetRevision`
ändern + sync.

Falls ArgoCD trotzdem meckert (bekanntes Problem mit PrometheusRule `/spec`):

```yaml
# In der ArgoCD-App-Definition (monitoring.yaml):
ignoreDifferences:
  - group: monitoring.coreos.com
    kind: PrometheusRule
    jsonPointers:
      - /spec
```

### ArgoCD sync hängt: "another operation is already in progress"

Tritt auf wenn ein vorheriger Sync nicht sauber abgeschlossen wurde.

```bash
# Schritt 1: Operation terminieren
argocd app terminate-op kube-prometheus-stack

# Schritt 2: Kurz warten, dann nochmal versuchen
sleep 10 && argocd app sync kube-prometheus-stack --timeout 300
```

Falls immer noch blockiert:

```bash
# Operation-Status direkt aus dem Kubernetes-Objekt löschen
kubectl patch application kube-prometheus-stack -n argocd \
  --type merge \
  -p='{"operation": null}'

# ArgoCD Application-Controller neustarten (StatefulSet, kein Deployment!)
kubectl rollout restart statefulset -n argocd argocd-application-controller

# Dann sync
argocd app sync kube-prometheus-stack --timeout 300
```

### Prometheus-Operator startet nicht nach CRD-Update

Race Condition (Operator startet bevor CRD `Established` ist):

```bash
kubectl rollout restart deployment -n monitoring kube-prometheus-stack-operator
```

### Grafana CrashLoopBackOff: "Only one datasource per organization can be marked as default"

Tritt bei jedem Grafana-Versionssprung auf solange `loki-stack` Chart 2.10.3
die Loki-Datasource mit `isDefault: true` deployed.

> ✅ **Dauerhaft gefixt am 2026-05-03:** `gitops/apps/loki.yaml` enthält jetzt einen
> expliziten Datasource-Override mit `isDefault: false`. Dieser Abschnitt dient nur
> noch als Fallback falls der Fix verloren geht.

**Dauerhafter Fix in `gitops/apps/loki.yaml`** (bereits eingecheckt):

```yaml
grafana:
  enabled: false
  sidecar:
    datasources:
      enabled: true
      defaultDatasourceEnabled: false
  # Verhindert isDefault: true im Datasource ConfigMap
  datasources:
    loki-stack-datasource.yaml:
      apiVersion: 1
      datasources:
        - name: Loki
          type: loki
          access: proxy
          url: "http://loki-stack:3100"
          version: 1
          isDefault: false
          jsonData: {}
```

**Notfall-Sofortfix** (falls ArgoCD den Fix noch nicht gesynct hat):

**Wichtig:** Den Patch erst anwenden wenn Grafana bereits mit der neuen Version
gestartet ist und crasht — nicht vorher.

```bash
# Schritt 1: Warten bis Grafana in CrashLoopBackOff ist
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -w

# Schritt 2: Loki-ConfigMap patchen
kubectl patch configmap loki-stack -n monitoring \
  --type merge \
  -p='{"data":{"loki-stack-datasource.yaml":"apiVersion: 1\ndatasources:\n- name: Loki\n  type: loki\n  access: proxy\n  url: \"http://loki-stack:3100\"\n  version: 1\n  isDefault: false\n  jsonData:\n    {}"}}'

# Schritt 3: Grafana neustarten
kubectl rollout restart deployment -n monitoring kube-prometheus-stack-grafana
```

### Grafana sync-Fehler: "spec.strategy.rollingUpdate Forbidden when type is Recreate"

Tritt auf wenn das Grafana-Deployment im Cluster noch `RollingUpdate` gesetzt hat,
aber in der values.yaml bereits `Recreate` konfiguriert ist. ArgoCD kann das
Deployment nicht patchen weil Kubernetes `rollingUpdate`-Parameter bei `Recreate`
ablehnt.

```bash
# Strategy direkt im Cluster korrigieren
kubectl patch deployment -n monitoring kube-prometheus-stack-grafana \
  --type merge \
  -p='{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'

# Dann stuck operation clearen und sync
kubectl patch application kube-prometheus-stack -n argocd \
  --type merge -p='{"operation": null}'

argocd app sync kube-prometheus-stack --timeout 300
```

### Grafana-Passwort nach 79.x unbekannt

```bash
kubectl get secret -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

---

## Referenzen

- [Offizielles UPGRADE.md](https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/UPGRADE.md)
- [prometheus-operator CRD Releases](https://github.com/prometheus-operator/prometheus-operator/releases)
- [ArtifactHub: kube-prometheus-stack](https://artifacthub.io/packages/helm/prometheus-community/kube-prometheus-stack)
