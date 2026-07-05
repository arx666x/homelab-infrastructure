# kubernetes-mcp-server – Read-only MCP-Zugriff für Claude Desktop

**URL:** https://k8s-mcp.reckeweg.io
**Image:** `ghcr.io/containers/kubernetes-mcp-server:v0.0.63`
**Namespace:** `mcp`
**Projekt:** https://github.com/containers/kubernetes-mcp-server

---

## Architektur

```
Claude Desktop (Mac)
   └─ mcp-remote (lokale stdio-Bridge, via npx)
        └─ HTTPS + Basic-Auth ───────────► k8s-mcp.reckeweg.io (Traefik Ingress)
                                              ├─ Middleware: IP-Allowlist (192.168.11.0/24)
                                              ├─ Middleware: Basic-Auth (Sealed Secret)
                                              └─ kubernetes-mcp-server Pod
                                                    ├─ ServiceAccount: mcp-viewer
                                                    └─ ClusterRoleBinding → ClusterRole "view"
                                                         (read-only, KEIN Zugriff auf Secret-Inhalte)
```

Claude Desktop unterstützt bei Custom Connectors kein einfaches Bearer-Token-Feld – es
erwartet für Remote-MCP-Server vollen OAuth 2.1 (inkl. Dynamic Client Registration). Um das
zu vermeiden, läuft `mcp-remote` als lokale stdio-Bridge auf dem Mac: Claude Desktop sieht
nur einen lokalen Prozess, `mcp-remote` reicht die HTTP-Basic-Auth-Credentials an den
tatsächlichen Server im Cluster weiter.

Der MCP-Server selbst hat **keine** eigene Kubernetes-Kubeconfig – er läuft mit der
in-cluster ServiceAccount-Config seines Pods (Standard client-go-Verhalten). Rechte kommen
ausschließlich über die ClusterRoleBinding auf die eingebaute `view`-Rolle.

---

## Dateien

| Datei | Inhalt |
|---|---|
| `gitops/config/mcp/rbac.yaml` | Namespace, ServiceAccount `mcp-viewer`, ClusterRoleBinding auf `view` |
| `gitops/config/mcp/deployment.yaml` | Deployment (`--read-only`, Port 8080), Service |
| `gitops/config/mcp/ingress.yaml` | Traefik Middlewares (IP-Allowlist, Basic-Auth), Certificate, Ingress |
| `gitops/config/mcp/sealed-mcp-basic-auth.yaml` | SealedSecret mit htpasswd-Credentials für Basic-Auth |
| `gitops/apps/kubernetes-mcp-server.yaml` | ArgoCD Application |

Sync erfolgt automatisch über `gitops/argocd/root-app.yaml` (App-of-Apps, `directory.recurse: true`).

---

## Sicherheitsmodell

Zwei unabhängige Schutzschichten vor dem MCP-Server, zusätzlich zur RBAC-Einschränkung:

1. **Netzwerk:** Traefik `IPAllowList`-Middleware erlaubt nur Quell-IPs aus `192.168.11.0/24`
   (Heimnetz-VLAN). Von außerhalb ist der Hostname zwar öffentlich auflösbar
   (Let's Encrypt benötigt das für die Zertifikatsausstellung), aber Anfragen aus anderen
   Quell-IPs werden von Traefik mit 403 abgelehnt.
2. **Basic-Auth:** Zusätzlich verlangt Traefik gültige Basic-Auth-Credentials
   (`gitops/config/mcp/sealed-mcp-basic-auth.yaml`).
3. **RBAC:** Selbst bei kompromittierten Credentials ist der Zugriff auf die eingebaute
   `view`-ClusterRole beschränkt – kein Schreibzugriff, keine Secret-Inhalte lesbar.
4. **`--read-only`-Flag:** Zusätzliche Absicherung auf Anwendungsebene, unabhängig von RBAC.

Die Basic-Auth-Zugangsdaten (Username `claude`) liegen **nicht** im Git-Repo im Klartext –
nur die von `kubeseal` verschlüsselte Fassung. Das Passwort selbst wurde einmalig generiert
und muss separat (Passwort-Manager) hinterlegt werden, siehe unten.

---

## Pi-hole DNS-Eintrag

Wie bei allen anderen `*.reckeweg.io`-Services zeigt auch `k8s-mcp.reckeweg.io` auf die
feste Traefik-LoadBalancer-IP (MetalLB Pool `192.168.20.100-120`):

Pi-hole → **Local DNS → DNS Records**:

| Domain | IP |
|---|---|
| `k8s-mcp.reckeweg.io` | `192.168.20.100` |

Ohne diesen Eintrag löst der Hostname im Heimnetz nicht auf (Let's Encrypt/HTTP-01
braucht die öffentliche DNS-Auflösung nur für die Zertifikatsausstellung, nicht für den
eigentlichen Zugriff aus dem LAN).

---

## Deployment

Kein manuelles `kubectl apply` nötig – ArgoCD deployt automatisch nach dem Git-Push
(`automated.prune: true`, `automated.selfHeal: true`).

```bash
git add gitops/config/mcp gitops/apps/kubernetes-mcp-server.yaml docs/DEPLOY-KUBERNETES-MCP-SERVER.md
git commit -m "..."
git push
```

Danach in ArgoCD prüfen:

```bash
kubectl get application kubernetes-mcp-server -n argocd
kubectl get pods -n mcp
kubectl get certificate -n mcp
```

---

## Claude Desktop Konfiguration (Mac)

Voraussetzung: Node.js (für `npx`) lokal installiert.

In `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "k8s-homelab": {
      "command": "npx",
      "args": [
        "-y",
        "mcp-remote",
        "https://k8s-mcp.reckeweg.io/mcp",
        "--header",
        "Authorization:Basic BASE64_USER_PASS"
      ]
    }
  }
}
```

`BASE64_USER_PASS` ist `base64("claude:<Passwort>")`, z.B.:

```bash
echo -n "claude:<PASSWORT>" | base64
```

Das Passwort selbst wurde beim Erstellen der SealedSecret generiert und dir separat
mitgeteilt – **nicht im Repo gespeichert**. Falls verloren: Passwort neu generieren und
Secret neu versiegeln (siehe unten).

Nach Speichern: Claude Desktop neu starten. Der Connector erscheint dann unter
**Settings → Connectors** als `k8s-homelab` mit ausschließlich lesenden Tools
(`--read-only`, ClusterRole `view`).

---

## Basic-Auth-Passwort rotieren

```bash
NEW_PASS=$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-32)
htpasswd -nbB claude "$NEW_PASS" > /tmp/mcp-htpasswd.txt

kubectl create secret generic mcp-basic-auth \
  --from-file=users=/tmp/mcp-htpasswd.txt \
  --namespace mcp \
  --dry-run=client -o yaml \
  | kubeseal --cert gitops/sealed-secrets/pub-cert.pem --format yaml \
  > gitops/config/mcp/sealed-mcp-basic-auth.yaml

rm /tmp/mcp-htpasswd.txt
echo "Neues Passwort: $NEW_PASS"   # in Passwort-Manager sichern, dann löschen
```

Danach `sealed-mcp-basic-auth.yaml` committen/pushen und die `claude_desktop_config.json`
mit dem neuen Base64-Wert aktualisieren.

---

## Version aktualisieren

In `gitops/config/mcp/deployment.yaml` das Image anpassen:

```yaml
image: ghcr.io/containers/kubernetes-mcp-server:v0.0.64   # neue Version
```

Releases: https://github.com/containers/kubernetes-mcp-server/releases

Nach Git-Push synct ArgoCD automatisch.

---

## Troubleshooting

```bash
# Pod-Status
kubectl get pods -n mcp

# Logs
kubectl logs -n mcp deployment/kubernetes-mcp-server

# RBAC prüfen
kubectl get clusterrolebinding mcp-viewer-view -o yaml
kubectl auth can-i --list --as=system:serviceaccount:mcp:mcp-viewer

# Zertifikat prüfen
kubectl get certificate -n mcp
kubectl describe certificate k8s-mcp-tls -n mcp

# Ingress / Middlewares prüfen
kubectl get ingress -n mcp
kubectl get middleware -n mcp

# Von innerhalb des Heimnetzes testen (401 = Basic-Auth greift, 403 = IP-Allowlist greift)
curl -i https://k8s-mcp.reckeweg.io/mcp
```
