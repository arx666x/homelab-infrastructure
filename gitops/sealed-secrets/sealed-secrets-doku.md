# Sealed Secrets – Migration & Betriebshandbuch

**Homelab SERI – reckeweg.io**
Datum: 20. März 2026
Controller: `sealed-secrets-controller` v2.15.4 (Namespace: `kube-system`)
Repo: `git@git.reckeweg.io:achim/homelab-infrastructure.git`

---

## Inhaltsverzeichnis

1. [Überblick](#1-überblick)
2. [Schlüsselverwaltung](#2-schlüsselverwaltung)
3. [Secret-Inventar](#3-secret-inventar)
4. [Alltäglicher Betrieb](#4-alltäglicher-betrieb)
5. [Cluster-Neuaufbau](#5-cluster-neuaufbau)
6. [Fehlerbehebung](#6-fehlerbehebung)
7. [Migrationsdokumentation](#7-migrationsdokumentation-20032026)

---

## 1 Überblick

Sealed Secrets ist eine Lösung von Bitnami, die es ermöglicht, Kubernetes Secrets sicher in einem Git-Repository zu speichern. Ein asymmetrisches RSA-Schlüsselpaar wird im Cluster erzeugt. Secrets werden mit dem öffentlichen Schlüssel verschlüsselt ("versiegelt") und können nur vom Controller im Cluster entschlüsselt werden.

### Warum Sealed Secrets?

Vorher wurden Secrets imperativ mit `kubectl create secret` angelegt und waren nur im Cluster vorhanden. Nachteile:

- Secrets gingen bei einem Cluster-Neuaufbau verloren
- Kein GitOps-Workflow möglich – Secrets waren nicht im Repo
- `create-secrets.sh` Skripte mussten manuell ausgeführt werden
- Keine Nachvollziehbarkeit welche Secrets existieren

Mit Sealed Secrets:

- Alle Secrets liegen verschlüsselt im Git-Repo
- Cluster-Neuaufbau: ArgoCD stellt alles automatisch wieder her
- Kein manueller Schritt mehr nach dem ersten Setup
- Volle GitOps-Kompatibilität mit ArgoCD

### Komponenten

| Komponente | Name | Namespace | Pfad im Repo |
|---|---|---|---|
| Controller | `sealed-secrets-controller` | `kube-system` | `gitops/apps/sealed-secrets.yaml` |
| Public Cert | `pub-cert.pem` | – | `gitops/sealed-secrets/pub-cert.pem` |
| Seal Script | `seal-all-secrets.sh` | – | `gitops/sealed-secrets/seal-all-secrets.sh` |

---

## 2 Schlüsselverwaltung

### 2.1 Schlüsselpaar

Der Controller erzeugt beim ersten Start automatisch ein RSA-Schlüsselpaar im Namespace `kube-system`:

- **Private Key + Certificate**: automatisch als Secret im Cluster gespeichert
- **Public Certificate** (`pub-cert.pem`): exportiert und im Repo unter `gitops/sealed-secrets/` gespeichert

> **Hinweis:** `pub-cert.pem` ist nicht geheim und kann bedenkenlos im Git-Repo gespeichert werden. Es wird nur zum Verschlüsseln verwendet – Entschlüsseln ist damit nicht möglich.

### 2.2 Master Key Backup

Der private Master Key ist im Passwort-Manager hinterlegt. Ohne diesen Key können versiegelte Secrets nach einem Cluster-Verlust nicht wiederhergestellt werden.

> **KRITISCH:** Der Master Key darf ausschließlich im Passwort-Manager aufbewahrt werden – niemals im Git-Repo.

Master Key exportieren (für Backup):

```bash
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-master-key.yaml
```

Master Key nach Cluster-Neuaufbau wiederherstellen:

```bash
kubectl apply -f sealed-secrets-master-key.yaml
kubectl rollout restart deployment/sealed-secrets-controller -n kube-system
```

### 2.3 Public Certificate erneuern

Falls das Zertifikat rotiert wurde (z.B. nach Key-Erneuerung):

```bash
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  > gitops/sealed-secrets/pub-cert.pem

git add gitops/sealed-secrets/pub-cert.pem
git commit -m "chore: update sealed secrets public cert"
git push
```

---

## 3 Secret-Inventar

Alle SealedSecrets nach der Migration:

| App | Secret-Name | Namespace | Datei im Repo |
|---|---|---|---|
| gitea | `gitea-admin-secret` | `gitea` | `gitops/config/gitea/postgresql/sealed-admin-secret.yaml` |
| gitea | `gitea-postgresql-secret` | `gitea` | `gitops/config/gitea/postgresql/sealed-postgresql-secret.yaml` |
| guacamole | `guacamole-db-secret` | `guacamole` | `gitops/config/guacamole/sealed-db-secret.yaml` |
| guacamole | `guacamole-oidc-secret` | `guacamole` | `gitops/config/guacamole/sealed-oidc-secret.yaml` *(Phase 2 – Keycloak)* |
| monitoring | `alertmanager-credentials` | `monitoring` | `gitops/config/monitoring/sealed-alertmanager-credentials.yaml` |
| monitoring | `grafana-admin-secret` | `monitoring` | `gitops/config/monitoring/sealed-grafana-admin-secret.yaml` |
| windows-ad | `ad-ldaps-pkcs12-password` | `windows-ad` | `gitops/config/windows-ad/sealed-ldaps-pkcs12-password.yaml` |
| windows-ad | `ldap-service-credentials` | `windows-ad` | `gitops/config/windows-ad/sealed-ldap-service-credentials.yaml` |
| windows-ad | `windows-ad-ca` | `windows-ad` | `gitops/config/windows-ad/sealed-windows-ad-ca.yaml` |

---

## 4 Alltäglicher Betrieb

### 4.1 Neues Secret hinzufügen

**Schritt 1** – Secret erstellen und direkt versiegeln:

```bash
kubectl create secret generic mein-neues-secret \
  --namespace=mein-namespace \
  --from-literal=username='meinuser' \
  --from-literal=password='meinpasswort' \
  --dry-run=client -o json \
  | kubeseal --cert gitops/sealed-secrets/pub-cert.pem --format yaml \
  > gitops/config/meine-app/sealed-mein-secret.yaml
```

**Schritt 2** – SealedSecret in die `kustomization.yaml` der App eintragen:

```yaml
# gitops/config/meine-app/kustomization.yaml
resources:
  - andere-ressource.yaml
  - sealed-mein-secret.yaml   # neu hinzufügen
```

**Schritt 3** – Committen und pushen:

```bash
git add gitops/config/meine-app/
git commit -m "feat: add sealed secret for meine-app"
git push
```

ArgoCD synct automatisch und der Controller entschlüsselt das Secret im Cluster.

### 4.2 Secret rotieren (Passwort ändern)

**Schritt 1** – Altes Secret aus dem Cluster löschen:

```bash
kubectl delete secret mein-secret -n mein-namespace
```

**Schritt 2** – Neues Secret erstellen und versiegeln:

```bash
kubectl create secret generic mein-secret \
  --namespace=mein-namespace \
  --from-literal=password='neues-passwort' \
  --dry-run=client -o json \
  | kubeseal --cert gitops/sealed-secrets/pub-cert.pem --format yaml \
  > gitops/config/meine-app/sealed-mein-secret.yaml
```

**Schritt 3** – Committen und pushen:

```bash
git add gitops/config/meine-app/sealed-mein-secret.yaml
git commit -m "chore: rotate password for mein-secret"
git push
```

### 4.3 Bestehendes Secret aus dem Cluster versiegeln

Falls ein Secret bereits im Cluster existiert:

```bash
kubectl get secret mein-secret -n mein-namespace -o json \
  | jq 'del(.metadata.resourceVersion, .metadata.uid,
            .metadata.creationTimestamp,
            .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration")' \
  | kubeseal --cert gitops/sealed-secrets/pub-cert.pem --format yaml \
  > gitops/config/meine-app/sealed-mein-secret.yaml
```

### 4.4 seal-all-secrets.sh

Das Script `gitops/sealed-secrets/seal-all-secrets.sh` verarbeitet alle bekannten Secrets des Homelabs in einem Durchlauf. Für jedes Secret prüft es:

- **Secret existiert im Cluster** → direkter Export und Versiegelung
- **Secret existiert nicht** → interaktive Eingabe der Werte und Versiegelung

Wann das Script verwenden:

- Beim ersten Aufsetzen eines neuen Clusters (nach Master Key Restore), falls Secrets nicht mehr im Cluster sind
- Bei der Rotation mehrerer Secrets gleichzeitig
- Nach größeren Cluster-Rebuilds

> **Hinweis:** Nach einem normalen Cluster-Neuaufbau stellt ArgoCD alle SealedSecrets automatisch aus dem Repo wieder her. Das Script wird in diesem Fall **nicht** benötigt.

---

## 5 Cluster-Neuaufbau

Der große Vorteil von Sealed Secrets: nach einem Totalverlust des Clusters ist die Wiederherstellung vollständig automatisiert.

### Wiederherstellungsreihenfolge

1. k3s Cluster neu aufbauen

2. **Master Key wiederherstellen** *(zwingend vor ArgoCD!)*:
   ```bash
   kubectl apply -f sealed-secrets-master-key.yaml
   kubectl rollout restart deployment/sealed-secrets-controller -n kube-system
   ```

3. ArgoCD installieren und Root-App anwenden

4. ArgoCD synct alle Apps automatisch – inkl. aller SealedSecrets

5. Fertig. Kein weiterer manueller Eingriff nötig.

> **Wichtig:** Der Master Key muss vor ArgoCD wiederhergestellt werden, sonst kann der Controller die SealedSecrets nicht entschlüsseln und alle Apps bleiben im Degraded-Status.

---

## 6 Fehlerbehebung

### 6.1 „already exists and is not managed by SealedSecret"

**Ursache:** Das Secret wurde früher imperativ angelegt und hat kein `managed-by` Label.

**Lösung:** Altes Secret löschen, der Controller legt es neu an:

```bash
kubectl delete secret <name> -n <namespace>
# Controller reagiert innerhalb von Sekunden
```

Falls der Fehler nach dem Löschen weiterhin angezeigt wird (Controller-Cache):

```bash
kubectl rollout restart deployment/sealed-secrets-controller -n kube-system
```

### 6.2 „couldn't find key \<keyname\> in Secret"

**Ursache:** Das SealedSecret enthält nicht alle Keys die die App erwartet.

**Lösung:** Secret um den fehlenden Key erweitern und neu versiegeln:

```bash
kubectl get secret <name> -n <namespace> -o json \
  | jq '.data["neuer-key"] = ("wert" | @base64)' \
  | kubeseal --cert gitops/sealed-secrets/pub-cert.pem --format yaml \
  > gitops/config/<app>/sealed-<name>.yaml

git add gitops/config/<app>/sealed-<name>.yaml
git commit -m "fix: add missing key to <name>"
git push
```

### 6.3 Diagnosebefehle

Status aller SealedSecrets:

```bash
kubectl get sealedsecrets -A
```

Details zu einem spezifischen SealedSecret:

```bash
kubectl describe sealedsecret <name> -n <namespace>
```

Controller-Logs:

```bash
kubectl logs -n kube-system deployment/sealed-secrets-controller --tail=50
```

ArgoCD App-Status:

```bash
argocd app list
argocd app get <app-name>
argocd app diff <app-name>
```

---

## 7 Migrationsdokumentation (20.03.2026)

### 7.1 Ausgangslage

Vor der Migration wurden Secrets auf zwei Arten verwaltet:

- **Imperativ** via `create-secrets.sh` Skripte (gitea, guacamole, windows-ad)
- **Inline** als Helm-Values in ArgoCD Application YAMLs (`monitoring.yaml`: `adminPassword: changeme`)

Keine der Secrets war im Git-Repo gespeichert. Bei einem Cluster-Verlust wären alle Zugangsdaten verloren gewesen.

### 7.2 Durchgeführte Schritte

1. Sealed Secrets Controller via ArgoCD deployed (`gitops/apps/sealed-secrets.yaml`)
2. Master Key exportiert und im Passwort-Manager gesichert
3. Public Certificate exportiert nach `gitops/sealed-secrets/pub-cert.pem`
4. `seal-all-secrets.sh` erstellt und ausgeführt – alle 8 Secrets versiegelt
5. `kustomization.yaml` Dateien angelegt für `gitea/postgresql`, `guacamole`, `monitoring`, `windows-ad`
6. `monitoring.yaml` bereinigt: `adminPassword` entfernt, `existingSecret` Referenz ergänzt
7. `monitoring-secrets` ArgoCD App angelegt für die neuen Monitoring SealedSecrets
8. Alte `create-secrets.sh` Skripte entfernt
9. Alle 21 ArgoCD Apps auf Synced/Healthy gebracht

### 7.3 Aufgetretene Probleme und Lösungen

**Problem: „already exists and is not managed by SealedSecret"**

Alle imperativ angelegten Secrets mussten zuerst gelöscht werden. Danach musste der Controller neu gestartet werden, da er den Lösch-Status gecacht hatte.

**Problem: Grafana Pod im `CreateContainerConfigError`**

Der Key `admin-user` fehlte im `grafana-admin-secret`. Das Secret wurde um den fehlenden Key erweitert und neu versiegelt:

```bash
kubectl get secret grafana-admin-secret -n monitoring -o json \
  | jq '.data["admin-user"] = ("admin" | @base64)' \
  | kubeseal --cert gitops/sealed-secrets/pub-cert.pem --format yaml \
  > gitops/config/monitoring/sealed-grafana-admin-secret.yaml
```

**Problem: `kube-prometheus-stack` OutOfSync wegen PrometheusRules**

Die PrometheusRules für `KubeControllerManagerDown`, `KubeProxyDown` und `KubeSchedulerDown` sind in k3s nicht vorhanden und erzeugten beim Deaktivieren leere Rules mit `null`-Wert, die Kubernetes ablehnte. Lösung: `ignoreDifferences` in der ArgoCD App ergänzt und die Rules manuell gelöscht.

**Problem: CDI-Operator OutOfSync**

Der CDI-Operator schreibt das vollständige OpenAPI-Schema in seine CRD zurück. Gelöst durch Ergänzung von `/spec/versions` und `/spec/conversion` in den `ignoreDifferences` der `cdi-operator` App.
