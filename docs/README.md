# SERI k3s Cluster - Clean Deployment Package

**Version:** 2.0 - Clean Restart  
**Datum:** 23. Februar 2026  
**Status:** Production Ready ✅

---

## 📦 Was ist in diesem Package?

### 1. Scripts (direkt ausführbar)
- `cleanup-cluster.sh` - Löscht alten Cluster sauber
- `install-cluster.sh` - Installiert k3s mit allen Fixes
- `install-argocd.sh` - Installiert ArgoCD korrekt konfiguriert

### 2. Git Repository Manifeste (`git-repo/`)
Komplette, getestete GitOps Konfiguration:
```
gitops/
├── argocd/
│   ├── install/kustomization.yaml
│   └── apps/root-app.yaml
└── infrastructure/
    ├── metallb/          (Sync Wave 0)
    ├── cert-manager/     (Sync Wave 1)
    ├── traefik/          (Sync Wave 2)
    ├── longhorn/         (Sync Wave 3)
    └── monitoring/       (Sync Wave 4)
```

### 3. Dokumentation
- `GIT-WORKFLOW.md` - Wie du die Manifeste ins GitHub Repo bringst
- `SERI-Deployment-Documentation.md` - Vollständige Referenz

---

## 🎯 Lessons Learned (integriert)

Alle Probleme der letzten 24h sind gefixt:

### DNS Probleme
✅ **DNS Search Domain Check** - Verhindert `github.com.reckeweg.io`  
✅ **Pi-hole Local DNS Records** - k8s Services auflösbar  
✅ **Conditional Forwarding** - DHCP Hostnamen von Dream Machine

### Netzwerk Probleme
✅ **VLAN Static IP Verification** - Prüft vor Installation  
✅ **NetworkManager Config** - Persistent, kein DHCP override  
✅ **Pod-to-Pod Connectivity** - Master ↔ Worker funktioniert

### ArgoCD Probleme
✅ **Ingress Health Check Patch** - Ignoriert fehlende ADDRESS  
✅ **Sync Waves** - Korrekte Deployment-Reihenfolge  
✅ **ignoreDifferences** - Webhook caBundle wird nicht gesynced  
✅ **Retry Policies** - Vernünftige Backoff-Strategien

### Longhorn Probleme
✅ **preUpgradeChecker disabled** - Kein Hook-Fehler  
✅ **Ingress enabled** - UI ist erreichbar  
✅ **TLS Configuration** - Certificates werden automatisch erstellt

### Prometheus Probleme
✅ **Grafana Ingress mit TLS** - Vollständige Config  
✅ **Prometheus Ingress** - Separater Zugang  
✅ **Storage korrekt** - Longhorn PVCs funktionieren

---

## 🚀 Schnellstart (40 Minuten)

### Voraussetzungen erfüllt?

- ✅ 8 Nodes (3 Masters AMD64, 5 Workers ARM64)
- ✅ VLAN 20 mit statischen IPs konfiguriert
- ✅ Pi-hole DNS läuft
- ✅ Cloudflare Account mit API Token
- ✅ GitHub Repo: `homelab-infrastructure` (public)

### Schritt 1: Git Repo updaten (10 Min)

```bash
# Siehe GIT-WORKFLOW.md für Details
cd ~/git/seri-infrastructure-complete
git checkout -b backup-before-clean-deploy
git push -u origin backup-before-clean-deploy
git checkout main
rm -rf gitops/
cp -r ~/Downloads/git-repo/gitops/ .
git add .
git commit -m "refactor: Complete GitOps manifest rewrite"
git push origin main
```

### Schritt 2: Cluster löschen (5 Min)

```bash
chmod +x cleanup-cluster.sh
./cleanup-cluster.sh
```

### Schritt 3: Cluster installieren (10 Min)

```bash
chmod +x install-cluster.sh
./install-cluster.sh
```

**Erwartetes Ergebnis:**
```
All pre-flight checks passed!
k3s Cluster Installation Complete!
```

### Schritt 4: ArgoCD installieren (3 Min)

```bash
chmod +x install-argocd.sh
./install-argocd.sh
```

**Notiere das ArgoCD Admin Password!**

### Schritt 5: Secrets erstellen (2 Min)

```bash
export KUBECONFIG=~/.kube/seri-homelab

# Cloudflare API Token
kubectl create namespace cert-manager
kubectl create secret generic cloudflare-api-token \
  --from-literal=api-token=<DEIN_TOKEN> \
  -n cert-manager
```

### Schritt 6: Infrastructure deployen (20 Min)

```bash
kubectl apply -f ~/git/seri-infrastructure-complete/gitops/argocd/apps/root-app.yaml

# Watch deployment
kubectl get applications -n argocd -w
```

**Erwartetes Ergebnis nach 15-20 Min:**
```
NAME                    SYNC STATUS   HEALTH STATUS
cert-manager            Synced        Healthy
kube-prometheus-stack   Synced        Healthy
longhorn                Synced        Healthy
metallb                 Synced        Healthy
root-infrastructure     Synced        Healthy
traefik                 Synced        Healthy
```

---

## ✅ Verification

### 1. Alle Nodes Ready?

```bash
kubectl get nodes
# Alle sollten "Ready" sein
```

### 2. Alle Apps Healthy?

```bash
kubectl get applications -n argocd
# Alle sollten "Synced" und "Healthy" sein
```

### 3. Services erreichbar?

```bash
# Grafana
curl -k https://grafana.reckeweg.io
# Sollte: Login-Seite

# Longhorn
curl -k https://longhorn.reckeweg.io
# Sollte: Redirect oder UI

# ArgoCD
curl -k https://argocd.reckeweg.io
# Sollte: Login-Seite
```

### 4. DNS funktioniert?

```bash
nslookup longhorn.reckeweg.io
# Sollte: 192.168.20.100

nslookup gmkt-01x.reckeweg.io
# Sollte: 192.168.11.31
```

---

## 🌐 Zugriff auf Services

### Grafana
- **URL:** https://grafana.reckeweg.io
- **User:** admin
- **Pass:** changeme

### Longhorn
- **URL:** https://longhorn.reckeweg.io

### Prometheus
- **URL:** https://prometheus.reckeweg.io

### ArgoCD
- **URL:** https://argocd.reckeweg.io
- **User:** admin
- **Pass:** `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`

---

## 🔧 Troubleshooting

### Problem: Pre-Flight Check schlägt fehl

**DNS Search Domain:**
```bash
# UniFi Console → VLAN 11 & 20 → DHCP → Domain Name: [LEER]
# Dann auf allen Nodes:
for ip in 31 32 33 21 22 23 24 25; do
  ssh achim@192.168.11.$ip "sudo sed -i '/search reckeweg.io/d' /etc/resolv.conf"
done
```

**VLAN IPs:**
```bash
# Siehe cleanup-cluster.sh für Worker VLAN Config
```

### Problem: Apps stuck in "Progressing"

```bash
# Pods checken
kubectl get pods -A | grep -v Running | grep -v Completed

# Events checken
kubectl get events -A --sort-by='.lastTimestamp' | tail -20

# App Details
kubectl describe application <app-name> -n argocd
```

### Problem: Ingress keine ADDRESS

**Das ist OK!** - ArgoCD Health Check ist gepatcht, ignoriert das.

Test ob es funktioniert:
```bash
curl -k https://longhorn.reckeweg.io
```

---

## 📊 Timeline

| Phase | Dauer | Status |
|-------|-------|--------|
| Git Update | 10 Min | Manual |
| Cleanup | 5 Min | Automated |
| k3s Install | 10 Min | Automated |
| ArgoCD | 3 Min | Automated |
| Secrets | 2 Min | Manual |
| Apps Deploy | 20 Min | Automated |
| **Total** | **~50 Min** | |

---

## 🎓 Was du gelernt hast

1. **DNS ist kritisch** - Search Domains können alles brechen
2. **VLAN Config muss persistent sein** - NetworkManager vs DHCP
3. **ArgoCD Sync Waves** - Deployment-Reihenfolge ist wichtig
4. **Helm Hooks** - Können mit ArgoCD Probleme machen
5. **Pod-to-Pod Network** - Master ↔ Worker Connectivity testen
6. **Longhorn Replicas** - Brauchen funktionierendes Netzwerk
7. **Certificate Automation** - cert-manager + Ingress = auto TLS

---

## 📝 Nächste Schritte

Nach erfolgreichem Deployment:

1. **Gitea deployen** - Eigener Git Server
2. **Migration zu Gitea** - Weg von public GitHub
3. **Backup Strategy** - Longhorn Backups testen
4. **Monitoring** - Grafana Dashboards konfigurieren
5. **Alerting** - Prometheus AlertManager setup
6. **Documentation** - Runbooks für Ops

---

## 🆘 Support

Bei Problemen:
1. Check Pre-Flight Checks
2. Check `kubectl get events`
3. Check ArgoCD Logs
4. Siehe SERI-Deployment-Documentation.md

---

**Version History:**
- v2.0 (23.02.2026) - Clean deploy with all fixes
- v1.0 (21.02.2026) - Initial deployment (problematic)

🎯 **Viel Erfolg mit deinem Production-Ready k3s Cluster!**
