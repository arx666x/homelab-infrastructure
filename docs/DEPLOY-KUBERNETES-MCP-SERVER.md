# kubernetes-mcp-server – Read-only MCP-Zugriff für Claude Desktop

**URL:** https://k8s-mcp.reckeweg.io
**Image:** `ghcr.io/containers/kubernetes-mcp-server:v0.0.63`
**Namespace:** `mcp`
**Projekt:** https://github.com/containers/kubernetes-mcp-server

**Referenzen:**
- https://github.com/containers/kubernetes-mcp-server/blob/main/docs/getting-started-kubernetes.md
- https://github.com/containers/kubernetes-mcp-server/blob/main/docs/getting-started-claude-code.md

---

## Architektur

```
Claude Desktop (Mac)
   └─ mcp-remote (lokale stdio-Bridge, via npx)
        └─ HTTPS + Basic-Auth ───────────► k8s-mcp.reckeweg.io (Traefik Ingress)
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
| `gitops/config/mcp/rbac.yaml` | Namespace, ServiceAccount `mcp-viewer`, ClusterRoleBinding auf `view`, plus ClusterRole `mcp-viewer-nodes` (Node-Metriken) |
| `gitops/config/mcp/deployment.yaml` | Deployment (`--read-only`, Port 8080), Service |
| `gitops/config/mcp/ingress.yaml` | Traefik Middleware (Basic-Auth), Certificate, Ingress |
| `gitops/config/mcp/sealed-mcp-basic-auth.yaml` | SealedSecret mit htpasswd-Credentials für Basic-Auth |
| `gitops/apps/kubernetes-mcp-server.yaml` | ArgoCD Application |

Sync erfolgt automatisch über `gitops/argocd/root-app.yaml` (App-of-Apps, `directory.recurse: true`).

---

## Sicherheitsmodell

Drei unabhängige Schutzschichten vor dem MCP-Server:

1. **Basic-Auth:** Traefik verlangt gültige Basic-Auth-Credentials
   (`gitops/config/mcp/sealed-mcp-basic-auth.yaml`), bevor eine Anfrage überhaupt den
   Pod erreicht.
2. **RBAC:** Selbst bei kompromittierten Credentials ist der Zugriff auf die eingebaute
   `view`-ClusterRole beschränkt – kein Schreibzugriff, keine Secret-Inhalte lesbar.
   Zusätzlich gibt es die schlanke ClusterRole `mcp-viewer-nodes` (`get`/`list` auf
   `nodes`, `get` auf `nodes/metrics`), damit Node-CPU/Memory/Conditions lesbar sind –
   `view` deckt zwar `metrics.k8s.io` (Pods/Nodes) ab, aber nicht die core-v1
   Node-Objekte selbst oder das `nodes/metrics`-Subresource.
3. **`--read-only`-Flag:** Zusätzliche Absicherung auf Anwendungsebene, unabhängig von RBAC.

Auf eine Traefik-`IPAllowList`-Middleware wurde bewusst verzichtet: Externer Zugriff
außerhalb des Heimnetzes ist ohnehin nur per VPN möglich, eine zusätzliche
IP-Einschränkung auf Ingress-Ebene bringt hier keinen echten Mehrwert. Sie hätte zudem
mit dem clusterweiten Traefik-Service (`externalTrafficPolicy: Cluster`, siehe
Troubleshooting-Hinweis unten) zuverlässig zu False-Positive-403-Fehlern geführt, da
kube-proxy bei node-übergreifendem Forwarding die echte Quell-IP per SNAT ersetzt.

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

Nach Speichern: Claude Desktop **komplett beenden** (⌘Q, nicht nur das Fenster
schließen) und neu öffnen – die App liest `claude_desktop_config.json` nur beim Start ein.
Der Connector erscheint dann unter **Settings → Connectors** als `k8s-homelab` mit
ausschließlich lesenden Tools (`--read-only`, ClusterRole `view`).

---

## Verbindung prüfen

**`claude mcp list` funktioniert hier NICHT** – das ist ein Befehl der Claude Code CLI
(`npm install -g @anthropic-ai/claude-code`), einem separaten Terminal-Tool. Die
`getting-started-claude-code.md`-Referenz oben bezieht sich darauf, nicht auf die
Desktop-App. Für Claude Desktop (unsere Konfiguration über
`claude_desktop_config.json`) stattdessen:

1. **Settings → Developer** (bzw. **Connectors**, je nach App-Version) – zeigt
   `k8s-homelab` mit Status (running/error) und ggf. einer kurzen Fehlermeldung.
2. **Werkzeug-Icon im Chat-Eingabefeld** – sobald die Verbindung steht, tauchen dort die
   vom Server bereitgestellten (Read-only-)Tools auf.
3. **Logs** bei Verbindungsproblemen:
   ```
   ~/Library/Logs/Claude/mcp-server-k8s-homelab.log
   ~/Library/Logs/Claude/mcp.log
   ```
   Hier landen auch Fehler von `mcp-remote` selbst (z. B. 401 von Traefik bei
   falschem Basic-Auth-Base64-Wert, DNS-Fehler falls der Pi-hole-Eintrag fehlt, etc.).

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
kubectl get clusterrolebinding mcp-viewer-view mcp-viewer-nodes -o yaml
kubectl auth can-i --list --as=system:serviceaccount:mcp:mcp-viewer
kubectl auth can-i get nodes --as=system:serviceaccount:mcp:mcp-viewer
kubectl auth can-i get nodes/metrics --as=system:serviceaccount:mcp:mcp-viewer

# Zertifikat prüfen
kubectl get certificate -n mcp
kubectl describe certificate k8s-mcp-tls -n mcp

# Ingress / Middlewares prüfen
kubectl get ingress -n mcp
kubectl get middleware.traefik.io -n mcp

# Testen (401 = Basic-Auth greift, Endpoint erreichbar)
curl -i https://k8s-mcp.reckeweg.io/mcp
```

**Hinweis:** Es gibt sowohl `middlewares.traefik.io` als auch das ältere Alias
`middlewares.traefik.containo.us` als CRD im Cluster. `kubectl get middleware` ohne
API-Gruppen-Suffix kann je nach Cluster auf die falsche Gruppe auflösen und
"not found" liefern, obwohl die Ressource existiert – im Zweifel `middleware.traefik.io`
explizit angeben.
