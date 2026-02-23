# SERI Clean Deployment - Installation Guide

## 📦 Package Struktur

```
seri-clean-deploy/
├── README.md                    # Hauptdokumentation
├── INSTALL-GUIDE.md            # Diese Datei
├── GIT-WORKFLOW.md             # Git Update Anleitung
│
├── scripts/                     # Ausführbare Scripts
│   ├── cleanup-cluster.sh
│   ├── install-cluster.sh
│   └── install-argocd.sh
│
└── git-repo/                    # Für dein GitHub Repo
    └── gitops/
        ├── argocd/
        │   ├── apps/
        │   │   └── root-app.yaml
        │   └── install/
        │       └── kustomization.yaml
        └── infrastructure/
            ├── metallb/
            │   ├── app.yaml
            │   └── config.yaml
            ├── cert-manager/
            │   ├── app.yaml
            │   └── cluster-issuer.yaml
            ├── traefik/
            │   └── app.yaml
            ├── longhorn/
            │   └── app.yaml
            └── monitoring/
                └── kube-prometheus-stack.yaml
```

## 🚀 Schritt-für-Schritt Installation

### Schritt 1: Git Repo updaten

```bash
# Gehe in dein lokales Repo
cd ~/git/seri-infrastructure-complete

# Backup erstellen
git checkout -b backup-$(date +%Y%m%d)
git push -u origin backup-$(date +%Y%m%d)

# Zurück zu main
git checkout main

# Alte gitops Struktur löschen
rm -rf gitops/

# Neue Struktur aus Package kopieren
cp -r ~/Downloads/seri-clean-deploy/git-repo/gitops/ .

# Verify
tree gitops/

# Status
git status

# Commit
git add .
git commit -m "refactor: Complete GitOps manifest rewrite with all fixes"

# Push
git push origin main
```

### Schritt 2: Cluster Cleanup

```bash
cd ~/Downloads/seri-clean-deploy/scripts

chmod +x cleanup-cluster.sh
./cleanup-cluster.sh
```

**Dauer:** ~5 Minuten

### Schritt 3: Fresh k3s Installation

```bash
chmod +x install-cluster.sh
./install-cluster.sh
```

**Dauer:** ~10 Minuten

**Erwartete Ausgabe:**
```
✓ DNS Search Domain OK
✓ VLAN IPs OK
✓ SSH OK
All pre-flight checks passed!
...
k3s Cluster Installation Complete!
```

### Schritt 4: ArgoCD Installation

```bash
chmod +x install-argocd.sh
./install-argocd.sh
```

**Dauer:** ~3 Minuten

**Notiere das ArgoCD Password!**

### Schritt 5: Secrets erstellen

```bash
export KUBECONFIG=~/.kube/seri-homelab

# Namespace erstellen (falls nicht exists)
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -

# Cloudflare Secret
read -p "Cloudflare API Token: " CF_TOKEN
kubectl create secret generic cloudflare-api-token \
  --from-literal=api-token=$CF_TOKEN \
  -n cert-manager
```

### Schritt 6: Infrastructure deployen

```bash
# Root App deployen
kubectl apply -f ~/git/seri-infrastructure-complete/gitops/argocd/apps/root-app.yaml

# Watch
kubectl get applications -n argocd -w
```

**Dauer:** 15-20 Minuten

**Erwartetes Endergebnis:**
```
NAME                    SYNC STATUS   HEALTH STATUS
cert-manager            Synced        Healthy
kube-prometheus-stack   Synced        Healthy
longhorn                Synced        Healthy
metallb                 Synced        Healthy
root-infrastructure     Synced        Healthy
traefik                 Synced        Healthy
```

## ✅ Verification

### 1. Nodes
```bash
kubectl get nodes
# Alle 8 sollten Ready sein
```

### 2. Apps
```bash
kubectl get applications -n argocd
# Alle sollten Synced & Healthy sein
```

### 3. Ingresses
```bash
kubectl get ingress -A
# Longhorn, Grafana, Prometheus sollten existieren
```

### 4. Services erreichbar
```bash
curl -k https://grafana.reckeweg.io
curl -k https://longhorn.reckeweg.io
```

## 🔧 Troubleshooting

### Pre-Flight Check schlägt fehl

**DNS Search Domain:**
- UniFi → Networks → VLAN 11/20 → DHCP → Domain Name: [LEER]
- Nodes: `sudo sed -i '/search reckeweg.io/d' /etc/resolv.conf`

**VLAN IPs:**
- Worker NetworkManager Connections neu erstellen (siehe cleanup-cluster.sh)

### Apps stuck in Progressing

```bash
kubectl get pods -A | grep -v Running
kubectl get events -A --sort-by='.lastTimestamp' | tail -20
kubectl describe application <app-name> -n argocd
```

### Ingress keine ADDRESS

Das ist OK - ArgoCD Health Check ignoriert das. Test:
```bash
curl -k https://longhorn.reckeweg.io
```

## 📊 Timeline

| Phase | Dauer |
|-------|-------|
| Git Update | 5 Min |
| Cleanup | 5 Min |
| Install | 10 Min |
| ArgoCD | 3 Min |
| Secrets | 2 Min |
| Deploy | 20 Min |
| **Total** | **45 Min** |

## 🎯 Erfolg!

Nach erfolgreichem Deployment:

- **Grafana:** https://grafana.reckeweg.io (admin/changeme)
- **Longhorn:** https://longhorn.reckeweg.io
- **Prometheus:** https://prometheus.reckeweg.io
- **ArgoCD:** https://argocd.reckeweg.io

Alle Services über DNS erreichbar, TLS funktioniert, Storage ist ready!
