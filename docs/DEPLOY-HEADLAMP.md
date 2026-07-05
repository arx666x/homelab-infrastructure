# Headlamp – Kubernetes UI

**URL:** https://headlamp.homelab.reckeweg.io  
**Image:** `ghcr.io/headlamp-k8s/headlamp:v0.43.0`  
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

Das Longhorn-Plugin ist das offizielle Plugin von Giant Swarm
(https://github.com/giantswarm/headlamp-longhorn, Image `gsoci.azurecr.io/giantswarm/headlamp-longhorn`).
Ursprünglich hatten wir einen eigenen Fork (`gitea.reckeweg.io/achim/headlamp-longhorn`) im Einsatz,
weil Plugin-Routen mit `:namespace` das Dashboard unter Headlamp v0.40.1 zum Absturz brachten
([kubernetes-sigs/headlamp#4863](https://github.com/kubernetes-sigs/headlamp/issues/4863)).
Der Fix landete im Headlamp-Core selbst (PR #5679, ausgeliefert mit v0.43.0) - seitdem
funktioniert das offizielle Plugin ohne Fork.
---

## Version aktualisieren

In `gitops/config/headlamp/headlamp.yaml` das Image anpassen (beide Stellen: Hauptcontainer
und `fix-static-plugins` Init-Container müssen auf derselben Version bleiben):
```yaml
image: ghcr.io/headlamp-k8s/headlamp:v0.44.0   # neue Version
```

Releases: https://github.com/kubernetes-sigs/headlamp/releases

Nach Git-Push synct ArgoCD automatisch.

---

## Session-Dauer (Token-Eingabe seltener)

Headlamp fragt standardmäßig alle 24h erneut nach dem Token, unabhängig davon, wie lange
der Token selbst gültig ist (`-session-ttl`, Default 86400s, seit v0.41.0 konfigurierbar,
siehe [kubernetes-sigs/headlamp#4538](https://github.com/kubernetes-sigs/headlamp/issues/4538)).
Wir setzen `-session-ttl=31536000` (1 Jahr), passend zur Token-Laufzeit aus `headlamp-token.sh`.

Für komplett tokenlosen Zugriff: Headlamp Desktop-App (nutzt lokale kubeconfig) oder
echtes OIDC/SSO (z.B. mit Keycloak, siehe Phase 2 in `docs/GUACAMOLE.md`) sind die nächsten
Ausbaustufen, falls gewünscht.

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
