# Gitea Deployment - SERI Homelab

## Zielstruktur im Repo

```
gitops/
├── apps/
│   └── gitea/
│       ├── gitea.yaml              ← ArgoCD App: Gitea Helm Chart       (wave 20)
│       ├── postgresql.yaml         ← ArgoCD App: PostgreSQL StatefulSet  (wave 15)
│       └── gitea-actions.yaml      ← ArgoCD App: act-runner              (wave 25, initial disabled)
└── config/
    └── gitea/
        ├── values.yaml                          ← Gitea Helm Values
        ├── actions-values.yaml                  ← act-runner Helm Values
        ├── create-secrets.sh                    ← Initiales Secret-Setup
        ├── create-sealed-secrets.sh             ← Migration zu SealedSecrets
        ├── sealed-gitea-admin-secret.yaml       ← nach Migration (in Git)
        ├── sealed-gitea-postgresql-secret.yaml  ← nach Migration (in Git)
        └── postgresql/
            └── postgresql-manifests.yaml        ← StatefulSet, Services
```

## IP-Adressen

| Service    | IP             | Zweck                      |
|------------|----------------|----------------------------|
| Traefik    | 192.168.20.100 | HTTP/HTTPS (alle Services) |
| Gitea SSH  | 192.168.20.101 | Git SSH (Port 22)          |

## Versions-Übersicht

| Komponente  | Version                                |
|-------------|----------------------------------------|
| Helm Chart  | 12.4.0                                 |
| Gitea       | 1.25.x                                 |
| PostgreSQL  | 16-alpine (docker.io/library/postgres) |
| Valkey      | 8.0 (bitnami/valkey)                   |
| helm-actions| 0.0.3 (gitea/act_runner:0.2.11)        |

---

## Upgrade-Pfad: Neuaufbau auf Chart 12.4.0

> **Voraussetzung:** Gitea ist derzeit down. ArgoCD braucht GitHub als Source.
> Stelle sicher dass dein GitHub-Repo aktuell ist.

### Schritt 0: Alte ArgoCD App entfernen → GITEA-CLEANUP.md

Die bestehende kaputte Gitea App muss zuerst vollständig entfernt werden.
Dabei werden PostgreSQL-PVC und Gitea-Data-PVC geschützt (cascade=true).

**→ Führe zuerst GITEA-CLEANUP.md vollständig durch, dann weiter hier ab Schritt 1.**

---

### Schritt 1: GitHub-Repo aktualisieren und Secrets anlegen

```bash
kubectl create namespace gitea --dry-run=client -o yaml | kubectl apply -f -

cd gitops/config/gitea
chmod +x create-secrets.sh
./create-secrets.sh
```

### Schritt 2: Dateien in GitHub-Repo committen

```bash
cd ~/workspace/homelab-infrastructure

# Struktur anlegen
mkdir -p gitops/apps/gitea
mkdir -p gitops/config/gitea/postgresql

# Dateien kopieren
cp gitops/apps/gitea/gitea.yaml              gitops/apps/gitea/
cp gitops/apps/gitea/postgresql.yaml         gitops/apps/gitea/
cp gitops/apps/gitea/gitea-actions.yaml      gitops/apps/gitea/
cp gitops/config/gitea/values.yaml           gitops/config/gitea/
cp gitops/config/gitea/actions-values.yaml   gitops/config/gitea/
cp gitops/config/gitea/postgresql/postgresql-manifests.yaml \
   gitops/config/gitea/postgresql/

git add gitops/apps/gitea/ gitops/config/gitea/
git commit -m "feat: gitea 1.25.x, external postgresql, actions vorbereitet"
git push
```

### Schritt 3: PostgreSQL deployen (wave 15)

```bash
kubectl apply -f gitops/apps/gitea/postgresql.yaml

# Warten bis PostgreSQL bereit
kubectl get pods -n gitea -w
# → gitea-postgresql-0: Running, Ready 1/1
```

### Schritt 4: Gitea deployen (wave 20)

```bash
kubectl apply -f gitops/apps/gitea/gitea.yaml

# Deployment beobachten
kubectl get pods -n gitea -w
```

Bei Problemen:
```bash
kubectl logs -n gitea -l app.kubernetes.io/name=gitea -c init-directories
kubectl logs -n gitea -l app.kubernetes.io/name=gitea -c init-app-ini
kubectl logs -n gitea -l app.kubernetes.io/name=gitea -c configure-gitea
```

### Schritt 5: Verifizieren

```bash
kubectl get pods -n gitea
kubectl get certificate -n gitea
curl -I https://gitea.reckeweg.io
ssh -T git@gitea.reckeweg.io
curl -s https://gitea.reckeweg.io/api/v1/version | jq .
```

### Schritt 6: ArgoCD zurück auf Gitea umstellen

In allen drei `*.yaml` unter `gitops/apps/gitea/` die repoURL umstellen:

```yaml
# Von:
repoURL: https://github.com/arx666x/homelab-infrastructure.git
# Zu:
repoURL: git@git.reckeweg.io:achim/homelab-infrastructure.git
```

```bash
kubectl apply -f gitops/apps/gitea/gitea.yaml
kubectl apply -f gitops/apps/gitea/postgresql.yaml
# gitea-actions.yaml NOCH NICHT - erst nach Token-Setup
```

---

## Actions aktivieren (Schritt 7 - nach Gitea-Stabilisierung)

Actions ist in Gitea selbst bereits enabled (`[actions] ENABLED=true` in values.yaml).
Der act-runner wird erst deployed wenn du den Token manuell geholt hast.

### Token holen

```
https://gitea.reckeweg.io/-/admin/actions/runners
→ "Create new runner" → Token kopieren
```

### Secret anlegen

```bash
kubectl create secret generic gitea-actions-secret \
  --from-literal=token=<DEIN_TOKEN> \
  -n gitea
```

Oder als SealedSecret (empfohlen nach Migration):
```bash
kubectl create secret generic gitea-actions-secret \
  --from-literal=token=<DEIN_TOKEN> \
  --dry-run=client -o yaml | \
kubeseal --cert pub-cert.pem \
  --scope namespace-wide \
  -o yaml > gitops/config/gitea/sealed-gitea-actions-secret.yaml

git add gitops/config/gitea/sealed-gitea-actions-secret.yaml
git commit -m "feat: add sealed actions runner secret"
git push
```

### ArgoCD App aktivieren

In `gitops/apps/gitea/gitea-actions.yaml` die syncPolicy aktivieren:

```yaml
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

```bash
kubectl apply -f gitops/apps/gitea/gitea-actions.yaml
```

### Verifizieren

```bash
kubectl get pods -n gitea -l app.kubernetes.io/name=act-runner
kubectl logs -n gitea -l app.kubernetes.io/name=act-runner

# In Gitea UI prüfen:
# https://gitea.reckeweg.io/-/admin/actions/runners
# → Runner sollte als "online" erscheinen
```

---

## Sealed Secrets Migration (alle Secrets)

```bash
kubeseal --fetch-cert \
  --controller-namespace kube-system \
  --controller-name sealed-secrets > pub-cert.pem

cd gitops/config/gitea
chmod +x create-sealed-secrets.sh
./create-sealed-secrets.sh   # gitea-admin + gitea-postgresql

# gitea-actions-secret separat (Token erst nach Gitea-Deploy verfügbar)
kubectl create secret generic gitea-actions-secret \
  --from-literal=token=<TOKEN> \
  --dry-run=client -o yaml | \
kubeseal --cert pub-cert.pem --scope namespace-wide -o yaml \
  > sealed-gitea-actions-secret.yaml

git add sealed-gitea-admin-secret.yaml \
        sealed-gitea-postgresql-secret.yaml \
        sealed-gitea-actions-secret.yaml
git commit -m "feat: alle gitea secrets als sealed-secrets"
git rm create-secrets.sh
git commit -m "chore: remove plain secret scripts"
git push
```

---

## Architektur-Übersicht

```
ArgoCD
  ├── gitea-postgresql  (wave 15)
  │     └── gitea ns
  │           ├── StatefulSet: gitea-postgresql (postgres:16-alpine)
  │           ├── Service: gitea-postgresql (ClusterIP :5432)
  │           └── PVC: data-gitea-postgresql-0 (Longhorn 10Gi)
  │
  ├── gitea  (wave 20)
  │     └── gitea ns
  │           ├── Deployment: gitea (gitea:1.25.x)
  │           ├── StatefulSet: gitea-valkey (bitnami/valkey:8.0)
  │           ├── PVC: gitea (Longhorn 50Gi)
  │           ├── Service: gitea-http (ClusterIP :3000)
  │           ├── Service: gitea-ssh (LoadBalancer 192.168.20.101:22)
  │           └── Ingress: gitea.reckeweg.io → Traefik
  │
  └── gitea-actions  (wave 25, initial disabled)
        └── gitea ns
              ├── StatefulSet: act-runner (gitea/act_runner:0.2.11 + DinD)
              └── PVC: runner-data (Longhorn 1Gi)
```

---

## Hinweis: helm-actions Chart-Reife

Das offizielle `gitea/actions` Chart ist noch sehr jung (v0.0.3, Stand 2025).
Sollte es Probleme geben, gibt es als Alternative das Community-Chart von shoce:
```bash
helm repo add shoce https://shoce.github.io/helm-gitea-actions/
helm show values shoce/helm-gitea-actions
```
Beide Charts unterstützen `provisioning.enabled: true` für automatisches
Token-Holen via Gitea API - das wäre der nächste Schritt für vollständig
GitOps-konformes Token-Management ohne manuellen Schritt.
```
