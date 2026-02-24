# SERI k3s Cluster - FINAL Production-Ready Deployment

**Version:** 3.0 - Complete Rewrite  
**Datum:** 23. Februar 2026  
**Status:** TESTED & WORKING ✅

---

## 🎯 Was ist NEU in Version 3.0?

### Alle 24h Debugging Lessons integriert:

✅ **Apps/Config Trennung** - Keine CRD-Fehler mehr  
✅ **Multi-Source Apps** - Helm Chart + Git Config zusammen  
✅ **Automated Sync** - One-Click Deployment  
✅ **Flannel Backend Fix** - Alle Masters mit host-gw  
✅ **Deep Cleanup** - Containerd State komplett gelöscht  
✅ **Health Check Patch** - ArgoCD ignoriert Ingress ADDRESS  
✅ **Sync Waves** - Korrekte Deployment-Reihenfolge  
✅ **All ignoreDifferences** - Keine Webhook caBundle Probleme

---

## 📦 Package Inhalt

```
seri-final-deploy/
├── QUICKSTART.sh              ⭐ START HIER - Kommandos kopieren
├── README.md                  Dieses File
│
├── scripts/
│   ├── cleanup-cluster.sh     Komplett sauberes Löschen
│   ├── install-cluster.sh     k3s mit Pre-Flight Checks
│   └── install-argocd.sh      ArgoCD mit Patches
│
└── git-repo/
    └── gitops/
        ├── argocd/
        │   └── root-app.yaml           Root Application
        │
        ├── apps/                        ⭐ NUR App Definitionen
        │   ├── metallb.yaml
        │   ├── cert-manager.yaml
        │   ├── traefik.yaml
        │   ├── longhorn.yaml
        │   └── monitoring.yaml
        │
        └── config/                      ⭐ Config separate
            ├── metallb/
            │   └── config.yaml
            └── cert-manager/
                └── cluster-issuer.yaml
```

---

## 🚀 Schnellstart (50 Minuten)

### Option 1: QUICKSTART.sh Kommandos kopieren

```bash
# Öffne QUICKSTART.sh und kopiere die Kommandos Schritt für Schritt
cat QUICKSTART.sh
```

### Option 2: Manuell (für Verständnis)

#### 1. Git Repo Update

```bash
cd ~/git/seri-infrastructure-complete
git checkout -b backup-$(date +%Y%m%d)
git push -u origin backup-$(date +%Y%m%d)
git checkout main
rm -rf gitops/
cp -r ~/Downloads/seri-final-deploy/git-repo/gitops/ .
git add .
git commit -m "refactor: Apps/Config separated"
git push origin main
```

#### 2. Cleanup

```bash
cd ~/Downloads/seri-final-deploy/scripts
chmod +x cleanup-cluster.sh
./cleanup-cluster.sh
```

#### 3. Install

```bash
chmod +x install-cluster.sh install-argocd.sh
./install-cluster.sh
export KUBECONFIG=~/.kube/seri-homelab
./install-argocd.sh
```

#### 4. Secrets

```bash
# Erst den Namespace anlegen - er würde sonst erst durch argocd angelegt.

kubectl create namespace cert-manager

read -p "Cloudflare Token: " CF_TOKEN
kubectl create secret generic cloudflare-api-token \
  --from-literal=api-token=$CF_TOKEN -n cert-manager
```

#### 5. Deploy

```bash
kubectl apply -f ~/git/seri-infrastructure-complete/gitops/argocd/root-app.yaml
kubectl get applications -n argocd -w
```

---

## ✅ Erwartetes Ergebnis

Nach 20 Minuten:

```
NAME                    SYNC STATUS   HEALTH STATUS
root-infrastructure     Synced        Healthy
metallb                 Synced        Healthy
cert-manager            Synced        Healthy
traefik                 Synced        Healthy
longhorn                Synced        Healthy
kube-prometheus-stack   Synced        Healthy
```

Alle Services erreichbar:
- https://grafana.reckeweg.io
- https://longhorn.reckeweg.io
- https://prometheus.reckeweg.io

---

## 🔧 Neue Architektur Erklärung

### Warum Apps/Config getrennt?

**Problem vorher:**
```
gitops/infrastructure/
├── metallb/
│   ├── app.yaml         ← Application (erstellt CRDs)
│   └── config.yaml      ← IPAddressPool (BRAUCHT CRDs)
```

Root App mit `directory.recurse` lädt ALLES gleichzeitig:
→ config.yaml wird deployed BEVOR app.yaml CRDs erstellt
→ FEHLER: "CRD not found"

**Lösung jetzt:**
```
gitops/
├── apps/                ← Root App lädt nur diese
│   └── metallb.yaml     ← Multi-Source: Helm + Config
└── config/
    └── metallb/
        └── config.yaml  ← Wird von App selbst geladen
```

Multi-Source App:
```yaml
sources:
  - chart: metallb           # Installiert CRDs
  - path: gitops/config/metallb  # Lädt Config NACH CRDs
```

### Deployment Flow:

1. Root App lädt `apps/*.yaml` (nur App Definitionen)
2. ArgoCD erstellt: metallb, cert-manager, traefik Apps
3. Apps deployen Helm Charts (mit CRDs)
4. Apps laden ihre Config aus `gitops/config/`
5. Sync Waves sorgen für Reihenfolge (0→1→2→3→4)

---

## 📊 Timeline

| Phase | Dauer | Was passiert |
|-------|-------|--------------|
| Git Update | 10 Min | Neue Struktur committen |
| Cleanup | 5 Min | Alles sauber löschen |
| k3s Install | 15 Min | Cluster mit 8 Nodes |
| ArgoCD | 5 Min | GitOps Controller |
| Secrets | 2 Min | Cloudflare Token |
| Apps Deploy | 20 Min | Alle Services |
| **Total** | **57 Min** | Production-Ready! |

---

## 🎓 Lessons Learned (integriert)

1. **CRD Deployment Order** - Apps vor Config deployen
2. **Multi-Source Apps** - Helm + Git zusammen
3. **Flannel Backend** - Muss auf allen Masters gleich sein
4. **Deep Cleanup** - `/var/lib/rancher/k3s` komplett löschen
5. **Sync Waves** - MetalLB=0, cert-manager=1, Traefik=2, ...
6. **ignoreDifferences** - Webhook caBundle driftet immer
7. **Automated Sync** - Root App muss syncPolicy haben
8. **Health Checks** - ArgoCD Ingress ADDRESS Patch

---

## 🆘 Troubleshooting

### Pre-Flight Check schlägt fehl

**DNS Search Domain:**
```bash
# UniFi → VLAN 11/20 → DHCP → Domain Name: [LEER]
for ip in 31 32 33 21 22 23 24 25; do
  ssh 192.168.11.$ip "sudo sed -i '/search/d' /etc/resolv.conf"
done
```

**VLAN IPs fehlen:**
```bash
# Siehe cleanup-cluster.sh - NetworkManager Config
```

### Apps OutOfSync

```bash
kubectl describe application <app-name> -n argocd
# Zeigt genauen Fehler
```

### "invalid capacity 0" Warnung

**Ignorieren!** Das ist harmlos - Pods laufen trotzdem.

---

## 🎯 Was kommt als Nächstes?

1. **ArgoCD Ingress** - Zugriff via https://argocd.reckeweg.io
2. **Gitea** - Eigener Git Server
3. **Migration zu Gitea** - Weg von public GitHub
4. **Backup** - Longhorn Snapshots testen
5. **Monitoring** - Grafana Dashboards
6. **Alerting** - Prometheus AlertManager

---

## 📝 Support

Bei Problemen:
- Check QUICKSTART.sh Kommentare
- `kubectl describe application <name> -n argocd`
- `kubectl get events -A`

---

**Version History:**
- v3.0 (23.02.2026) - Complete rewrite, Apps/Config separated ⭐
- v2.0 (23.02.2026) - Clean deploy (hatte Probleme)
- v1.0 (21.02.2026) - Initial (nicht funktionsfähig)

🚀 **Production-Ready Kubernetes Cluster in unter 1 Stunde!**
