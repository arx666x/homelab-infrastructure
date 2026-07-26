# Headlamp OIDC-Login gegen die Kubernetes-API - manueller Schritt

Teil des Authentik-SSO-Rollouts (siehe Plan). Dieser eine Schritt ist bewusst
**nicht** von Claude ausgeführt worden, obwohl technischer Zugriff (SSH via
`ansible/inventory/hosts.ini`, `ansible_user=achim.reckeweg`) bestünde:
Änderungen an der Authentifizierungs-Konfiguration des laufenden
Kubernetes-API-Servers auf allen drei Control-Plane-Nodes sind eine
sicherheitsrelevante System-Änderung an production-artiger, gemeinsam
genutzter Infrastruktur - das führt ihr bitte selbst aus, nachdem ihr die
GitOps-Seite (bereits erledigt: `gitops/config/headlamp/headlamp.yaml`,
`rbac.yaml`) geprüft und gemerged habt.

## Was die GitOps-Seite schon erledigt hat

- `gitops/config/headlamp/headlamp.yaml`: `-in-cluster` entfernt, durch
  `-oidc-client-id=headlamp`, `-oidc-idp-issuer-url=...`,
  `-oidc-scopes=openid,profile,email,groups` ersetzt; Client-Secret kommt aus
  `headlamp-oidc-secret` (SealedSecret, bereits versiegelt)
- `gitops/config/headlamp/rbac.yaml`: neue `ClusterRoleBinding
  headlamp-oidc-user-admin` für `User "oidc:achim.reckeweg@gmail.com"` -
  **falls eine andere Mail-Adresse als Authentik-Login-Identität genutzt
  werden soll, hier anpassen**. Die alte `ServiceAccount`-Bindung
  (`headlamp-cluster-admin`) bleibt unverändert bestehen - bewusst als
  Offline-Notfallzugang, siehe Break-Glass-Abschnitt im Plan.

## Was noch fehlt: k3s-apiserver-Flags auf allen drei Control-Plane-Nodes

**Bestätigt (2026-07-26): `/etc/rancher/k3s/config.yaml` existiert auf
keinem der drei Nodes.** Euer k3s ist per `ansible/playbooks/install-k3s-direct.yml`
imperativ installiert (`curl -sfL https://get.k3s.io | ... sh -s - server
--tls-san=... [...]`) - die Flags stecken im generierten
`/etc/systemd/system/k3s.service` (`ExecStart`), nicht in einer separaten
Config-Datei.

Trotzdem lädt `k3s server` bei jedem Start zusätzlich
`/etc/rancher/k3s/config.yaml`, falls vorhanden, und mergt sie mit den im
systemd-Unit fest einprogrammierten Flags (z.B. den ganzen `--tls-san`-Werten) -
eine neu angelegte Datei mit **ausschließlich** dem `kube-apiserver-arg`-Block
ist rein additiv, es gibt nichts Bestehendes zu überschreiben:

```bash
ssh gmkt-02x "sudo test -f /etc/rancher/k3s/config.yaml && echo exists || echo missing"
```

(Achtung: für `gmkt-01x` per Hostname klappt das aktuell nicht - siehe
DNS-Hinweis in [docs/diskstation-oidc-setup.md](diskstation-oidc-setup.md),
IP `192.168.20.31` direkt verwenden.)

**Update (2026-07-26): `oidc-username-claim` von `email` auf
`preferred_username` geändert.** Die Datei existiert auf allen drei Nodes
bereits (erster Rollout erfolgreich) - dieser Schritt ist also ein
**Bearbeiten**, kein Neuanlegen. Live bestätigter Fehler mit `email` als
Claim: `Unable to authenticate the request: oidc: email not verified` -
Kubernetes' OIDC-Authenticator verlangt bei `--oidc-username-claim=email`
zusätzlich einen wahren `email_verified`-Claim, den es ohne
E-Mail-Verifizierungs-Flow (kein SMTP im Cluster konfiguriert) nie geben
wird. Betrifft jeden User, nicht nur einen einzelnen Account.
`preferred_username` (Authentik-Username-Feld, z.B. "achim") umgeht diese
Prüfung komplett. `gitops/config/headlamp/rbac.yaml` wurde entsprechend auf
`oidc:achim` als Subject umgestellt.

Datei auf allen drei Nodes mit exakt diesem Inhalt anlegen bzw. aktualisieren:

```yaml
kube-apiserver-arg:
  - "oidc-issuer-url=https://sso.reckeweg.io/application/o/headlamp/"
  - "oidc-client-id=headlamp"
  - "oidc-username-claim=preferred_username"
  - "oidc-username-prefix=oidc:"
  - "oidc-groups-claim=groups"
  - "oidc-signing-algs=RS256"
```

Auf allen drei Nodes identisch anwenden (`gmkt-01x` per IP `192.168.20.31`,
`gmkt-02x`, `gmkt-03x` - siehe `ansible/inventory/hosts.ini`), dann je Node:

```bash
sudo systemctl restart k3s
```

**Nacheinander, nicht gleichzeitig** - erst einen Node neu starten, warten bis
`kubectl get nodes` ihn wieder `Ready` zeigt, dann den nächsten. Bei einem
3-Node-etcd-Quorum bleibt der Cluster so durchgehend schreibfähig.

## Absicherung / Rollback

- `--oidc-*`-Flags fügen einen **zusätzlichen** Authenticator hinzu, sie
  ersetzen NICHT das bestehende zertifikatsbasierte Kubeconfig-Auth (das,
  worüber euer normales `kubectl` bereits läuft). Ein Fehler in den
  OIDC-Flags bricht also nicht den bestehenden `kubectl`-Zugriff.
- Rollback: Block wieder aus `config.yaml` entfernen, `systemctl restart k3s`
  je Node.
- Nach dem Rollout zuerst mit bestehendem `kubectl`-Zugriff bestätigen, dass
  der k3s-Dienst auf allen drei Nodes sauber neu gestartet ist
  (`systemctl status k3s`, `kubectl get nodes`), bevor der alte
  ServiceAccount-Token-Login-Pfad in Headlamp als obsolet betrachtet wird.

## Danach: Login-Test

In einem Inkognito-Fenster `https://headlamp.reckeweg.io` aufrufen - sollte
zu Authentik weiterleiten, nach Login zurück zu Headlamp mit vollem Zugriff
(RBAC über `headlamp-oidc-user-admin`). Bekanntes Risiko: Login-Loops bei
falscher Redirect-URI/Claim-Konfiguration (siehe GitHub-Issue
kubernetes-sigs/headlamp#4539) - falls das auftritt, zuerst
`kubectl logs -n headlamp deploy/headlamp` prüfen.
