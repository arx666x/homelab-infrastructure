# Headlamp – Kubernetes UI

**URL:** https://headlamp.homelab.reckeweg.io  
**Image:** `ghcr.io/headlamp-k8s/headlamp:v0.40.1`  
**Namespace:** `headlamp`

---

## Dateien

| Datei | Inhalt |
|---|---|
| `gitops/config/headlamp/rbac.yaml` | Namespace, ServiceAccount, ClusterRoleBinding |
| `gitops/config/headlamp/headlamp.yaml` | Deployment, Service, Certificate, Ingress |
| `gitops/apps/headlamp.yaml` | ArgoCD Application |
| `scripts/deploy-headlamp.sh` | Einmaliges Deployment-Script |
| `scripts/headlamp-token.sh` | Login-Token generieren |

---

## Deployment

### Schritt 1 – Git-Repo URL in ArgoCD Application setzen

In `gitops/apps/headlamp.yaml` die `repoURL` anpassen:
```yaml
repoURL: https://github.com/DEIN-USER/DEIN-REPO.git
```

### Schritt 2 – Deployen

```bash
chmod +x scripts/deploy-headlamp.sh scripts/headlamp-token.sh
./scripts/deploy-headlamp.sh
```

Das Script erledigt in dieser Reihenfolge:
1. RBAC anlegen (Namespace, ServiceAccount, ClusterRoleBinding)
2. Headlamp Manifeste anwenden (Deployment, Service, Cert, Ingress)
3. ArgoCD Application registrieren
4. Auf Rollout warten
5. Login-Token ausgeben

### Schritt 3 – Pi-hole DNS-Eintrag

Pi-hole → **Local DNS → DNS Records**:

| Domain | IP |
|---|---|
| `headlamp.homelab.reckeweg.io` | `192.168.20.100` |

### Schritt 4 – Login

1. Browser: `https://headlamp.homelab.reckeweg.io`
2. Token aus Script-Output eintragen
3. Fertig

---

## Token erneuern (nach Ablauf)

```bash
./scripts/headlamp-token.sh
```

---

## Longhorn Plugin installieren

Die Plugins werden über den Plugin Manager installiert - der leider noch nicht 
im Headlamp Deployment enthalten ist.

Nach dem Login in Headlamp kann man über 
1. Zahnrad-Icon → **Plugins**

die installierten Plugins einsehen.<br>

Aber die Installation selber erfolgt über einen zusätzlichen Init Container in der Datei 
**gitops/config/headlamp/headlamp.yaml**<br>
Sollten weitere Plugins gewünscht sein, werden diese hierhinzugefügt<br>
---

## Version aktualisieren

In `gitops/config/headlamp/headlamp.yaml` das Image anpassen:
```yaml
image: ghcr.io/headlamp-k8s/headlamp:v0.41.0   # neue Version
```

Releases: https://github.com/kubernetes-sigs/headlamp/releases

Nach Git-Push synct ArgoCD automatisch.

---

## Troubleshooting

```bash
# Pod Status
kubectl get pods -n headlamp

# Logs
kubectl logs -n headlamp deployment/headlamp

# Cert-Manager Zertifikat prüfen
kubectl get certificate -n headlamp
kubectl describe certificate headlamp-tls -n headlamp

# Ingress prüfen
kubectl get ingress -n headlamp
```
