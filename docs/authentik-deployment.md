# Authentik SSO - Deployment-Dokumentation (2026-07-26)

Zentrales SSO für das Homelab. Läuft im `authentik`-Namespace, nutzt die
bestehende `gitea-postgresql`-Instanz (eigene DB/Rolle, keine
Vermischung mit Gitea-Daten). Seit Authentik 2025.10 kein Redis mehr
nötig (Caching/Tasks laufen über Postgres).

## Zugang

- **URL**: https://sso.reckeweg.io
- **Bootstrap-Login**: `akadmin@reckeweg.io` + Passwort aus der lokalen
  Scratchpad-Datei vom Rollout-Tag (nicht im Repo). Bei Bedarf per
  `gitops/sealed-secrets/seal-all-secrets.sh` neu generieren (Abschnitt
  "0. AUTHENTIK") - danach `postgres-setup.sql` mit dem neuen DB-Passwort
  erneut ausführen und alle vier abhängigen App-Secrets im selben Zug
  mitziehen (siehe "Secret-Sync" unten, das ist die häufigste Fehlerquelle).
- **Eigener Account**: `achim` (Mitglied der Gruppe "authentik Admins" -
  das setzt intern `is_superuser`, unabhängig davon was der
  "Berechtigungen"-Tab im Nutzerprofil zeigt, der ist ein separates,
  neueres RBAC-System und zeigt bei Superusern trotzdem nur eine
  Basis-Rolle an).

## Architektur

- `gitops/config/authentik/` - Server + Worker Deployment, ConfigMap,
  SealedSecret, Blueprints-ConfigMap, Ingress/Certificate, ForwardAuth-
  Middleware, Outpost-Passthrough-IngressRoute
- `gitops/apps/authentik.yaml` - ArgoCD Application dafür
- Node-Affinity auf amd64 (gmkt-Nodes), wie `gitea-postgresql`
- Blueprint-ConfigMap wird unter `/blueprints/custom` gemountet (NICHT
  `/blueprints` direkt - überschreibt sonst die eingebauten System-
  Blueprints und crashloopt den internen Worker)

### ForwardAuth-Gate (Apps ohne eigenes Login)

Longhorn, Prometheus, HomeAssistant. "Forward auth (domain level)"-Modus:
ein ProxyProvider + eine Application in Authentik genügt für beliebig
viele `*.reckeweg.io`-Domains, `cookie_domain: reckeweg.io` sorgt dafür,
dass ein Login auf `sso.reckeweg.io` domänenweit gilt. Jede gegatete
Domain braucht zusätzlich eine ungegatete Passthrough-Route für
`/outpost.goauthentik.io/` (siehe
`gitops/config/authentik/outpost-passthrough-ingressroute.yaml`).

Middleware-Referenz auf App-Seite:
`traefik.ingress.kubernetes.io/router.middlewares: authentik-authentik-forward-auth@kubernetescrd`
(Ingress) bzw. `middlewares: [{name: authentik-forward-auth, namespace: authentik}]`
(IngressRoute, z.B. HomeAssistant).

### Native OIDC

| App | Provider-Config | Sonderheiten |
|---|---|---|
| Grafana | `gitops/apps/monitoring.yaml`, `grafana.ini` | **`server.root_url` zwingend nötig** - ohne das baut Grafana die redirect_uri gegen `localhost:3000`. Lokaler Admin-Login bleibt als Fallback aktiv (kein `disable_login_form`). |
| Guacamole | `gitops/config/guacamole/guacamole.yaml`, `OPENID_*`-Env-Vars | Implicit-Flow-only (kein `client_secret` clientseitig genutzt). `OPENID_JWKS_ENDPOINT` muss die In-Cluster-Service-DNS sein, `OPENID_AUTHORIZATION_ENDPOINT`/`REDIRECT_URI` bleiben browserseitig. `POSTGRESQL_AUTO_CREATE_ACCOUNTS=false` - Nutzer müssen als Guacamole-Account vorher existieren. |
| Gitea | `gitops/config/gitea/oidc/` (eigene ArgoCD-Application, `gitea-oidc`) | Login-Quelle lebt in Giteas DB, nicht deklarativ über Helm-Values möglich - Job mit `gitea admin auth add-oauth`. **`--config` ist ein globales Flag** (vor dem Subcommand, nicht danach). App.ini braucht `[security] INSTALL_LOCK = true`, sonst bricht Giteas `MustInstalled()`-Check mit derselben Fehlermeldung wie bei fehlendem `--config` ab. Nach Secret-Rotation zusätzlich `gitea admin auth update-oauth --id 1 --secret ...` nötig - der Job selbst ist nur idempotent fürs Anlegen, nicht fürs Aktualisieren. |
| ArgoCD | `gitops/config/argocd/argocd-cm-oidc-patch.yaml` | **`url`-Feld in argocd-cm zwingend nötig** - ohne das baut ArgoCD die redirect_uri aus dem eingehenden (internen, http) Request statt der echten externen https-URL. Datei deklariert bewusst den **kompletten** `data`-Inhalt von argocd-cm, nicht nur einen Diff (Hintergrund siehe "Vorfall" unten). |
| Headlamp | `gitops/config/headlamp/`, volles OIDC bis in die K8s-API | Siehe [docs/headlamp-oidc-setup.md](headlamp-oidc-setup.md) - eigener, größerer Themenblock. |
| Diskstation (DSM) | Nur Authentik-seitig (`diskstation-oidc-provider`), DSM-Konfiguration manuell | Siehe [docs/diskstation-oidc-setup.md](diskstation-oidc-setup.md). |

### Bewusst ausgeschlossen

`auditique` (redesign, statische Seite ohne Login), `kubernetes-mcp-server`
(Basic-Auth, programmatischer Zugriff), `windows-ad`/`cert-distribution`
(keine HTTP-UI), `chromeiq` (noch keine Web-Oberfläche), TrueNAS-Admin-UI
(kein natives OIDC verfügbar).

## Secret-Sync - die häufigste Fehlerquelle

`authentik-secret` enthält u.a. `GRAFANA_OIDC_CLIENT_SECRET`,
`GITEA_OIDC_CLIENT_SECRET`, `ARGOCD_OIDC_CLIENT_SECRET`,
`HEADLAMP_OIDC_CLIENT_SECRET`, `DISKSTATION_OIDC_CLIENT_SECRET` - diese
Werte werden per `!Env`-Tag ins jeweilige Blueprint (`client_secret: !Env
[VAR, ""]`) übernommen. Die vier/fünf abhängigen App-Secrets
(`grafana-oidc-secret`, `gitea-oidc-secret`, `argocd-oidc-secret`,
`headlamp-oidc-secret`) müssen **exakt denselben Wert** enthalten wie
`authentik-secret` - bei jeder Rotation **alle gemeinsam** neu
generieren, nicht nur `authentik-secret` allein. Live passiert am
2026-07-26: mehrfache Einzel-Regenerierung von `authentik-secret`
während des Debuggings hat die Werte auseinanderlaufen lassen ->
"invalid_client" bei Grafana, ArgoCD und Headlamp gleichzeitig.

Prüfen, ob alles synchron ist:
```bash
for pair in "monitoring:grafana-oidc-secret:GRAFANA" "headlamp:headlamp-oidc-secret:HEADLAMP" "argocd:argocd-oidc-secret:ARGOCD" "gitea:gitea-oidc-secret:GITEA"; do
  ns=$(echo $pair | cut -d: -f1); secret=$(echo $pair | cut -d: -f2); prefix=$(echo $pair | cut -d: -f3)
  app_val=$(kubectl get secret $secret -n $ns -o jsonpath='{.data.client_secret}' | base64 -d)
  auth_val=$(kubectl get secret authentik-secret -n authentik -o jsonpath="{.data.${prefix}_OIDC_CLIENT_SECRET}" | base64 -d)
  [ "$app_val" = "$auth_val" ] && echo "$ns/$secret: MATCH" || echo "$ns/$secret: MISMATCH!!"
done
```
`seal-all-secrets.sh` regeneriert bei einem Lauf im Authentik-Abschnitt
alle fünf gemeinsam - der sicherste Weg, das nicht wieder zu verpassen.

## Bekannte Stolperfallen (live gefunden, 2026-07-26)

- **`!Env`-Tag braucht zwingend zwei Listenelemente**:
  `!Env [VAR, "default"]`, nicht `!Env [VAR]` - sonst `IndexError: list
  index out of range` in der `authentik_blueprints`-Migration, die die
  komplette Migrationskette an genau der Stelle abbricht und die DB in
  einem inkonsistenten Zwischenzustand zurücklässt (spätere Migrationen
  wie `to_2025_12_group_duplicate.py` scheitern dann an fehlenden
  Tabellen). Fix: DB komplett neu anlegen (`DROP DATABASE` +
  `postgres-setup.sql` erneut), NICHT nur den Blueprint-Fehler beheben
  und weiterlaufen lassen.
- **ArgoCDs `selfHeal: true` dreht ungepushte `kubectl apply`-Fixes
  zurück** - jede direkte Änderung an einer Ressource, die zu einer
  git-getrackten Application gehört, muss zuerst committed+gepusht
  werden, sonst reconciled ArgoCD sie beim nächsten Zyklus wieder auf
  den (alten) Git-Stand zurück. Bei Bedarf sofortigen Sync erzwingen:
  `kubectl annotate application <name> -n argocd
  argocd.argoproj.io/refresh=hard --overwrite` - **immer erst die
  übergeordnete `root-infrastructure`-Application hart refreshen**, die
  verwaltet die einzelnen Application-Objekte selbst (App-of-Apps-Muster,
  `path: gitops/apps`).
- **Plain `kubectl apply -f` (ohne `--server-side`) kann bestehende
  Felder in einer ConfigMap löschen**, die vorher separat (z.B. auch
  wieder per `kubectl apply`) gesetzt wurden - das Drei-Wege-Merge von
  client-side apply entfernt alles, was in einer früheren
  `last-applied-configuration`-Annotation stand, aber nicht in der neuen
  Datei ist. Live passiert mit `argocd-cm`: hat 9 bestehende
  `resource.customizations.*`/`resource.exclusions`-Einträge gelöscht.
  Für alles, was potenziell fremdverwaltete Felder teilt: immer
  `kubectl apply --server-side [--force-conflicts]`.
- **Headlamp**: `-oidc-*`-Flags brauchen zwingend `-in-cluster` mit
  dabei, sonst verweigert Headlamp den Start
  ("flags are only meant to be used in inCluster mode or with
  --oidc-use-cookie"). Zusätzlich explizites `-oidc-callback-url` nötig,
  sonst landet die redirect_uri nicht bei der in Authentik hinterlegten.
  `--oidc-username-claim=email` scheitert ohne SMTP/E-Mail-Verifizierung
  im Cluster IMMER mit `oidc: email not verified` (Kubernetes'
  OIDC-Authenticator verlangt bei diesem Claim zusätzlich
  `email_verified=true`) - `preferred_username` verwenden.
  **Trotz all dieser Fixes bleibt der eigentliche Login-Flow instabil**
  (Redirect läuft durch, UI hängt bei "Redirecting to main page…") -
  deckt sich mit einem offenen, ungelösten Upstream-Issue
  ([kubernetes-sigs/headlamp#4539](https://github.com/kubernetes-sigs/headlamp/issues/4539)).
  Alter Token-Login (`headlamp-token.sh`, `headlamp-cluster-admin`
  ClusterRoleBinding) bleibt bewusst als Fallback bestehen.
- **Diskstation/Chrome**: nach heutigem Stand ungeklärte
  Netzwerk-Eigenheit - Chrome konnte zeitweise pauschal keine Dienste
  mit eigener IP im Management-VLAN (192.168.11.x) erreichen, während
  Kubernetes-VLAN-Dienste (192.168.20.x) problemlos gingen. DNS-seitig
  (Diskstation-Pi-hole, dns01, dns02, VIP `.56`) mehrfach als 100%
  konsistent verifiziert - liegt clientseitig (Chrome-Verbindungs-Caching
  bzw. Safari-Tab-Suspension bei WebSockets), nicht an Authentik/Traefik/
  DNS. Kein weiterer Handlungsbedarf serverseitig identifiziert.

## Offene Punkte

- Navidrome-Caddy-ForwardAuth (musicbox) - dokumentiert in
  `docs/myhomeismycastle-cert-distribution-runbook.md`, noch nicht
  angewendet (kein SSH-Zugriff von hier aus möglich)
- Headlamp-OIDC - siehe oben, wartet auf Upstream-Fix
- Diskstation - Login-Flow im Browser noch nicht sauber reproduzierbar
  bestätigt (Netzwerk-Flakiness, nicht Konfiguration)
- Passkeys/WebAuthn für Nutzer - Stage muss noch angelegt und in den
  User-Settings-Flow eingehängt werden (Anleitung im Chat-Verlauf vom
  2026-07-26, nicht separat dokumentiert)
- ChromeIQ, Diskstation-DSM-UI selbst (kein natives OIDC), TrueNAS-UI
  (kein natives OIDC) - siehe Ausschluss-Liste oben

## Verwandte Dokumente

- [docs/headlamp-oidc-setup.md](headlamp-oidc-setup.md)
- [docs/diskstation-oidc-setup.md](diskstation-oidc-setup.md)
- [docs/myhomeismycastle-cert-distribution-runbook.md](myhomeismycastle-cert-distribution-runbook.md) (Navidrome-Abschnitt)
