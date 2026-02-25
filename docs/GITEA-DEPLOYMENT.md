# Gitea Deployment - Ablauf

## Zielstruktur im Repo

```
gitops/
├── apps/
│   ├── metallb.yaml
│   ├── longhorn.yaml
│   ├── cert-manager.yaml
│   ├── traefik.yaml
│   ├── monitoring.yaml
│   └── gitea.yaml          ← NEU
├── config/
│   ├── argocd/
│   ├── cert-manager/
│   ├── metallb/
│   └── gitea/              ← NEU
│       ├── values.yaml
│       └── create-secrets.sh
```

## IP-Adressen

| Service      | IP               | Zweck                    |
|-------------|------------------|--------------------------|
| Traefik     | 192.168.20.100   | HTTP/HTTPS (alle Services) |
| Gitea SSH   | 192.168.20.101   | Git SSH (Port 22)        |

## Pi-hole DNS

`gitea.reckeweg.io` zeigt bereits auf `192.168.20.100` → ✅ kein weiterer Eintrag nötig.

SSH-Zugriff erfolgt direkt über die IP oder du legst optional einen zweiten Eintrag an:
```
# Optional in Pi-hole (Local DNS → DNS Records):
git.reckeweg.io  →  192.168.20.101
# Dann: git clone git@git.reckeweg.io:user/repo.git
```

## Deployment-Reihenfolge

### Schritt 1: Secrets anlegen (einmalig manuell)

```bash
cd gitops/config/gitea
chmod +x create-secrets.sh
./create-secrets.sh
```

### Schritt 2: Dateien ins Repo und deployen

```bash
# Ins Repo kopieren
cp gitops/apps/gitea.yaml       ~/workspace/seri-infrastructure/gitops/apps/
cp -r gitops/config/gitea/      ~/workspace/seri-infrastructure/gitops/config/

# Committen (create-secrets.sh darf committet werden - enthält keine echten Secrets)
cd ~/workspace/seri-infrastructure
git add gitops/apps/gitea.yaml gitops/config/gitea/
git commit -m "feat: add Gitea with PostgreSQL, Redis, Actions"
git push

# ArgoCD App anlegen
kubectl apply -f gitops/apps/gitea.yaml

# Deployment beobachten
kubectl get pods -n gitea -w
```

### Schritt 3: Verifizieren

```bash
# Alle Pods laufen?
kubectl get pods -n gitea

# Zertifikat ausgestellt?
kubectl get certificate -n gitea

# Services und IPs?
kubectl get svc -n gitea

# Gitea erreichbar?
curl -I https://gitea.reckeweg.io

# SSH testen
ssh -T git@192.168.20.101
# Erwartete Antwort: "Hi gitea-admin! You've successfully authenticated..."
```

## Container Registry nutzen

```bash
# Docker Login
docker login gitea.reckeweg.io -u gitea-admin

# Image pushen
docker tag my-image gitea.reckeweg.io/achim/my-image:latest
docker push gitea.reckeweg.io/achim/my-image:latest

# In Kubernetes als ImagePullSecret einrichten
kubectl create secret docker-registry gitea-registry \
  --docker-server=gitea.reckeweg.io \
  --docker-username=gitea-admin \
  --docker-password=<PASSWORT> \
  -n default
```

## Sealed Secrets Migration (später)

```bash
# Sealed Secrets Controller installieren (via ArgoCD)
# Dann für jedes Secret:
kubectl get secret gitea-admin-secret -n gitea -o yaml | \
  kubeseal --cert pub-cert.pem -o yaml \
  > gitops/config/gitea/sealed-admin-secret.yaml

kubectl get secret gitea-postgresql-secret -n gitea -o yaml | \
  kubeseal --cert pub-cert.pem -o yaml \
  > gitops/config/gitea/sealed-postgresql-secret.yaml

# create-secrets.sh dann löschen, SealedSecrets in Git committen
git add gitops/config/gitea/sealed-*.yaml
git commit -m "feat: migrate Gitea secrets to SealedSecrets"
```
