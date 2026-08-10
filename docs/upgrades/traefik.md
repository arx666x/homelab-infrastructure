# Upgrade Runbook: Traefik

## Metadaten
- **Namespace:** `traefik`
- **Aktuelle Version:** Chart v41.2.0 (Traefik Proxy v3.7.10)
- **Quelle:** Helm-Chart-Repo `https://traefik.github.io/charts` (Chart `traefik`)
- **ArgoCD App-Name:** `traefik`
- **Versions-Check-Quelle:** Helm-Repo-Index von `https://traefik.github.io/charts` (Chart-Version, nicht direkt die Proxy-Version)
- **Major/Minor-Kriterium:** Standardregel (SemVer der Chart-Version). Zusätzlich zu beachten: Traefik Helm Chart und Traefik Proxy versionieren unabhängig — ein Chart-Patch kann trotzdem ein Proxy-Minor-Update enthalten (z.B. Chart 40.2.0→40.3.0 brachte Proxy v3.7.1→v3.7.4). Chart-Major-Versionen aktualisieren i.d.R. auch die CRDs — vor jedem Chart-Upgrade (auch Minor/Patch) vorsorglich `helm show crds | kubectl apply --server-side` ausführen, da Helm CRDs nie automatisch aktualisiert.

## Changelog

| Datum | Von → Nach | Typ | Ausführung | Status | Begründung | Notiz |
|---|---|---|---|---|---|---|
| unbekannt | ... | ... | ... | ... | Historie vor Einführung des strukturierten Runbooks nicht vollständig rekonstruierbar | — |
| 2026-05-01 | 26.0.0 → 39.0.0 | Major | Manuell | Abgeschlossen | CRD API Group wechselt (`traefik.containo.us`→`traefik.io`), Rule-Syntax v2→v3, Helm aktualisiert CRDs nicht automatisch — Proxy v2→v3 Sprung | Phased Migration mit v2-Kompatibilitätsmodus; Commits `f018fe1`, `910a099` |
| 2026-05-04 | 39.0.0 → 39.0.8 | Minor | Manuell | Abgeschlossen | Chart-Patch-Serie innerhalb v39; im Zuge dessen auch ArgoCD-Repo-SSH-Key-Problem (ed25519 vs. ssh-rsa) behoben | Commit `91f317f`; ArgoCD-Repo-Verbindung war zeitweise gestört (`knownhosts: key is unknown`) |
| 2026-05-18 | 39.0.8 → 40.0.0 | Major | Manuell | Abgeschlossen | Major Chart-Version, Breaking Changes bei Provider-Benennung (`kubernetesIngressNginx`→`kubernetesIngressNGINX`) und Service-Spec-Syntax; CRD-Update vorab nötig | Proxy v3.6.x → v3.7.0; Commit `fc91003` |
| 2026-05-18 | 40.0.0 → 40.2.0 | Minor | Manuell | Abgeschlossen | Deprecated `traefik-crds` Sub-Chart entfernt, Gateway-API-CRDs entfernt — beides ohne Auswirkung auf unsere Konfiguration | Proxy v3.7.0 → v3.7.1; Commit `d335d70` |
| 2026-06-15 | 40.2.0 → 40.3.0 | Minor | Manuell | Abgeschlossen | Patch-Release ohne Breaking Change, aber Proxy-Sprung v3.7.1→v3.7.4 (Bugfixes) | Commit `0692715` |
| 2026-06-18 | 40.3.0 → 41.0.0 | Major | Manuell | Abgeschlossen | Breaking Changes bei Logging-Keys (`logs.general`→`log` etc.) und `providers.file.content` betreffen unsere minimale Values-Konfiguration nicht | Proxy v3.7.4 → v3.7.5; Commit `bcbbeff` |
| 2026-06-29 | 41.0.0 → 41.0.1 | Minor | Manuell | Abgeschlossen | Patch-Release, nur Chart-Fixes (Fail-fast bei Uppercase-Keys nach RFC 1123), kein Proxy-Versionswechsel | Commit `151a049` |
| 2026-07-13 | 41.0.1 → 41.0.2 | Patch | Manuell | Abgeschlossen | Neues CRD `uplinks.hub.traefik.io` (Fix #1920) — vorab per `helm show crds \| kubectl apply --server-side` angewendet; undokumentierter Proxy-Sprung v3.7.5→v3.7.6 und Hub v3.19.3→v3.20.6 | PR [#5](https://gitea.reckeweg.io/achim/homelab-infrastructure/pulls/5) |
| 2026-08-03 | 41.0.2 → 41.1.0 | Minor | Manuell | Abgeschlossen | Proxy-Sprung v3.7.6→v3.7.9, Hub v3.20.6→v3.20.7; neue/aktualisierte CRDs ausschließlich `hub.traefik.io` (Hub in unseren Values nicht konfiguriert, daher inert); RBAC-Erweiterung (configmaps write für Hub) betrifft uns nicht | `upgrade-agent` hatte den Sprung bereits als PR-Branch vorbereitet (`chore/upgrade-traefik-41.1.0`), Branch war aber auf veraltetem Basisstand (vor den übrigen Fixes des Tages) — nicht gemergt, nur die `targetRevision`-Zeile manuell übernommen. Smoke-Tests (gitea/argocd/grafana) und Log-Check ohne neue Fehler |
| 2026-08-03 | 41.1.0 → 41.1.1 | Patch | Manuell | Abgeschlossen | Reiner Bugfix-Release (Hardened-Image-Registry-Pfad korrigiert, von uns nicht genutzt); Proxy bleibt unverändert bei v3.7.9, keine CRD-Schema-Änderungen | Direkt im Anschluss an den 41.1.0-Hop übersehen und nachgeholt; CRDs trotzdem vorsorglich neu applied (Standardprozedur), Smoke-Tests grün |
| 2026-08-10 | 41.1.1 → 41.2.0 | Minor | Manuell | Abgeschlossen | CRD-Update (neues `ErrorRequestHeaders`-Feld im Middleware-CRD, additiv); Proxy-Sprung v3.7.9→v3.7.10, Hub v3.19.3→v3.20.8 | CRDs vorab applied, danach `targetRevision`-Commit + Push (Gitea+GitHub). Kurzer Connection-Refused-Blip auf der LB-VIP während des Pod-Rollouts (nur 1 Replica, kein HA) — normal, <1min. Alte "middleware existiert nicht"-Warnungen (authentik-forward-auth, mcp-basic-auth, guacamole-redirect-root) aus Vor-Upgrade-Logs verschwanden nach dem Neustart von selbst. Smoke-Tests (gitea/argocd/grafana) grün |

### Reklassifizierungen (Minor → Major)

| Datum Erkennung | Ursprünglicher Changelog-Eintrag (Datum) | Grund der Reklassifizierung | Erneute Benachrichtigung gesendet am |
|---|---|---|---|

## Manuelle Vorgehensweise (bei Major/Breaking Change)

Traefik-Upgrades werden aktuell **manuell** durchgeführt (targetRevision-Änderung + Commit), nicht per Auto-Upgrade-Bot — dafür ist bei jedem Chart-Upgrade eine bewusste CRD-Prüfung nötig.

### Standardablauf (jedes Chart-Upgrade, auch Minor/Patch)

**Schritt 1 — CRDs vorab aktualisieren** (Helm aktualisiert CRDs bei `helm upgrade`/ArgoCD-Sync **nicht automatisch**):

```bash
helm repo update
helm show crds traefik/traefik --version <ZIEL-VERSION> | \
  kubectl apply --server-side --force-conflicts -f -
```

**Schritt 2 — targetRevision in ArgoCD aktualisieren:**

```yaml
# gitops/apps/traefik.yaml
targetRevision: "<ZIEL-VERSION>"
```

ArgoCD übernimmt den Upgrade automatisch (`syncPolicy: automated`). Status prüfen:

```bash
argocd app get traefik
argocd app wait traefik --health
```

**Schritt 3 — Post-Upgrade-Verifikation:**

```bash
# Traefik Proxy Version prüfen
kubectl -n traefik get deploy traefik -o jsonpath='{.spec.template.spec.containers[0].image}'

# Logs auf Errors prüfen
kubectl -n traefik logs deploy/traefik --tail=100 | grep -iE "error|fatal"

# Smoke-Tests
curl -s -o /dev/null -w "%{http_code}" https://gitea.reckeweg.io
curl -s -o /dev/null -w "%{http_code}" https://argocd.reckeweg.io
```

### Major-Migration v2→v3 (Referenzfall 26.0.0 → 39.0.0, 2026-05-01/04)

Dieser Sprung war **kein einfacher `helm upgrade`**, weil drei Kernprobleme gleichzeitig auftraten:

1. **CRD API Group**: `traefik.containo.us` → `traefik.io` — alle IngressRoutes, Middlewares etc. mussten migriert werden.
2. **Helm aktualisiert CRDs nicht automatisch** — CRDs müssen manuell vor dem Chart-Upgrade angewendet werden.
3. **Rule Syntax v2→v3**: `PathPrefix`, `Headers`, `HeadersRegexp`, Regex-Matcher ändern sich — Kompatibilitätsmodus überbrückt dies.

**Ansatz: Phased Migration mit v2-Kompatibilitätsmodus**

```
Phase 1: Bestandsaufnahme & Backup
Phase 2: IngressRoute-Manifeste auf traefik.io umschreiben (kein Downtime)
Phase 3: CRDs manuell upgraden
Phase 4: Helm Chart upgraden (mit defaultRuleSyntax: v2 — kein Traffic-Impact)
Phase 5: Rule Syntax auf v3 migrieren
Phase 6: Alte containo.us CRDs entfernen
```

#### Phase 1: Bestandsaufnahme & Backup

```bash
# Helm Release prüfen
helm -n traefik list

# Aktuelle Traefik-Version
kubectl -n traefik get deploy traefik -o jsonpath='{.spec.template.spec.containers[0].image}'

# Alle Traefik CRDs inventarisieren
kubectl get crd | grep traefik

# Alle IngressRoutes quer über alle Namespaces
kubectl get ingressroute,ingressroutetcp,ingressrouteudp,middleware,tlsoption,tlsstore,traefikservice \
  -A -o wide

# Namespaces mit Traefik-Ressourcen
kubectl get ingressroute -A --no-headers | awk '{print $1}' | sort -u
```

Backup:

```bash
helm -n traefik get values traefik -o yaml > traefik-values-backup-v26.yaml
kubectl get ingressroute -A -o yaml > ingressroutes-backup.yaml
kubectl get middleware -A -o yaml > middlewares-backup.yaml
kubectl get tlsoption -A -o yaml > tlsoptions-backup.yaml
kubectl get traefikservice -A -o yaml > traefikservices-backup.yaml
```

> **Vorab prüfen: ArgoCD Repo-Verbindung.** Ein Repo-Verbindungsfehler verhindert, dass ArgoCD die neue `targetRevision` überhaupt sieht.

```bash
argocd repo list
# Erwartete Ausgabe: STATUS = Successful
```

**Bekannter Fehler bei diesem Upgrade: `knownhosts: key is unknown`** — trat auf, weil ArgoCD 2.8+ `ssh-rsa` (SHA-1) standardmäßig ablehnt und Gitea nur einen RSA-Hostkey präsentierte. Lösung siehe Abschnitt „Bekannte Stolperfallen" und Anhang unten.

CRD-Stand prüfen (erwartet bei v2: `*.traefik.containo.us`, Ziel: `*.traefik.io`):

```bash
kubectl get crd | grep traefik
```

Monitoring-Baseline: Prometheus/Grafana-Traefik-Dashboard aufrufen, Smoke-Test aller kritischen Endpunkte vor dem Upgrade durchführen.

#### Phase 2: IngressRoute-Manifeste migrieren (API Group + Rule Syntax)

> Passiert **vor** dem Helm-Upgrade — die alten CRDs sind noch aktiv, Änderungen werden von Traefik v2 ignoriert und erst beim v3-Upgrade aufgegriffen.

API Group in allen Kustomize-Overlays/Basis-Manifesten ersetzen (`traefik.containo.us/v1alpha1` → `traefik.io/v1alpha1`):

```bash
grep -r "traefik.containo.us" gitops/ --include="*.yaml" -l

find gitops/ -name "*.yaml" -exec \
  sed -i '' 's|traefik.containo.us/v1alpha1|traefik.io/v1alpha1|g' {} +

grep -r "traefik.containo.us" gitops/ --include="*.yaml"
```

Rule Syntax **vorerst belassen** (v2-Kompatibilitätsmodus via `core.defaultRuleSyntax: v2` in Phase 4 überbrückt bestehende Regeln). Relevante Syntax-Änderungen für spätere Migration:

| v2 Syntax | v3 Syntax |
|-----------|-----------|
| `` Headers(`key`, `val`) `` | `` Header(`key`, `val`) `` |
| `` HeadersRegexp(`key`, `re`) `` | `` HeaderRegexp(`key`, `re`) `` |
| `PathPrefix` mit Regex | `PathRegexp` verwenden |
| `` Path(`/route/{id}`) `` (Placeholder) | `` PathRegexp(`/route/[^/]+`) `` |

#### Phase 3: CRDs manuell upgraden

> **Kritisch**: Helm aktualisiert CRDs bei `helm upgrade` **nicht automatisch**. CRDs müssen **vor** dem Chart-Upgrade manuell applied werden.

```bash
helm repo update
helm search repo traefik/traefik

helm show crds traefik/traefik --version 39.0.8 | \
  kubectl apply --server-side --force-conflicts -f -

kubectl get crd | grep traefik
# Jetzt sollten BEIDE Gruppen vorhanden sein: *.traefik.containo.us (alt) und *.traefik.io (neu)
```

#### Phase 4: Helm Chart upgraden

Kritische values-Anpassung (v2-Kompatibilitätsmodus aktivieren, damit bestehende IngressRoutes mit v2-Rule-Syntax weiterlaufen):

```yaml
core:
  defaultRuleSyntax: v2
```

> Entfernte v2-only-Optionen prüfen: `pilot`, `experimental.plugins` (Syntax geändert), `providers.kubernetesIngressNginx` → `providers.kubernetesIngressNGINX` (Groß-/Kleinschreibung).

Dry-Run, dann Upgrade:

```bash
helm upgrade traefik traefik/traefik --version 39.0.8 --namespace traefik \
  --values traefik-values-v39.yaml --dry-run --debug 2>&1 | head -100

helm upgrade traefik traefik/traefik --version 39.0.8 --namespace traefik \
  --values traefik-values-v39.yaml --wait --timeout 5m
```

Post-Upgrade-Check inkl. gezielter Suche nach v2-Deprecation-Warnings:

```bash
kubectl -n traefik get pods -w
kubectl -n traefik get deploy traefik -o jsonpath='{.spec.template.spec.containers[0].image}'
kubectl -n traefik logs deploy/traefik --tail=100
kubectl -n traefik logs deploy/traefik | grep -iE "deprecated|error|warn"

kubectl -n traefik port-forward deploy/traefik 9000:9000 &
curl http://localhost:9000/api/rawdata | jq '.routers | keys'
```

Smoke-Tests:

```bash
curl -s -o /dev/null -w "%{http_code}" https://gitea.reckeweg.io
curl -s -o /dev/null -w "%{http_code}" https://wordpress.reckeweg.io
curl -s -o /dev/null -w "%{http_code}" https://argocd.reckeweg.io
```

#### Phase 5: Rule Syntax auf v3 migrieren

> Kann **nach** Phase 4 in Ruhe durchgeführt werden. Traefik v3 warnt im Log über veraltete v2-Syntax — Logs als Roadmap nutzen.

```bash
kubectl -n traefik logs deploy/traefik | grep -i "deprecated"
```

Syntax-Migration Beispiele:

```yaml
# v2 → v3
match: "Headers(`X-Forwarded-Proto`, `https`)"   →   match: "Header(`X-Forwarded-Proto`, `https`)"
match: "HeadersRegexp(`X-Custom`, `val.*`)"       →   match: "HeaderRegexp(`X-Custom`, `val.*`)"
match: "PathPrefix(`/api/{id}`)"                  →   match: "PathRegexp(`/api/[^/]+`)"
```

Sobald alle IngressRoutes auf v3-Syntax umgestellt sind, `core.defaultRuleSyntax: v2` aus den values entfernen und erneut upgraden.

#### Phase 6: Alte containo.us CRDs entfernen

> **Erst ausführen wenn Phase 5 abgeschlossen** und alle Ressourcen auf `traefik.io` laufen.

```bash
# Sicherstellen dass nichts mehr containo.us nutzt
kubectl get ingressroute -A -o yaml | grep -c "containo.us"
# Muss 0 sein

kubectl delete crd \
  ingressroutes.traefik.containo.us \
  ingressroutetcps.traefik.containo.us \
  ingressrouteudps.traefik.containo.us \
  middlewares.traefik.containo.us \
  middlewaretcps.traefik.containo.us \
  serverstransports.traefik.containo.us \
  tlsoptions.traefik.containo.us \
  tlsstores.traefik.containo.us \
  traefikservices.traefik.containo.us
```

### Kustomize / GitOps-Anpassungen (ArgoCD)

```
gitops/
  apps/
    traefik.yaml              # ArgoCD Application (targetRevision hier setzen)
```

```yaml
# gitops/apps/traefik.yaml
spec:
  source:
    chart: traefik
    repoURL: https://traefik.github.io/charts
    targetRevision: "<ZIEL-VERSION>"
```

Nach Commit ArgoCD-Sync triggern (bei manuellem Sync nötig, `automated` löst i.d.R. selbst aus):

```bash
argocd app sync traefik
argocd app wait traefik --health
```

## Bekannte Stolperfallen / Lessons Learned

| Problem | Ursache | Lösung |
|---------|---------|--------|
| `helm upgrade` schlägt fehl wegen CRD-Konflikten | Helm aktualisiert CRDs nicht automatisch | CRDs vorab manuell via `helm show crds \| kubectl apply --server-side` anwenden |
| IngressRoutes liefern 404 nach Upgrade | `containo.us`-Manifeste nicht migriert | Phase 2 (API-Group-Migration) vollständig ausführen |
| Traefik startet nicht | Veraltete v2-only-Werte in values.yaml (z.B. `pilot`) | values.yaml bereinigen, `helm upgrade --dry-run` nutzen |
| cert-manager-Zertifikate funktionieren nicht | TLS-Konfiguration in Helm values geändert | websecure-Entrypoint-TLS-Config prüfen |
| ArgoCD zeigt OutOfSync | CRD-Version in ArgoCD-Application nicht aktualisiert | `targetRevision` in `gitops/apps/traefik.yaml` anpassen |
| ArgoCD-Sync hat keine Wirkung, zeigt alte Version | Repo-Verbindung schlägt fehl, ArgoCD kann Commits nicht lesen | `argocd repo list` prüfen, SSH-Key-Problem beheben (siehe unten) |
| `knownhosts: key is unknown` trotz eingetragenem Key | ArgoCD 2.8+ lehnt `ssh-rsa` (SHA-1) ab | ed25519-Hostkey in Gitea aktivieren und in ArgoCD eintragen (siehe Anhang) |

### Anhang: Gitea ed25519-Hostkey aktivieren

Falls Gitea nur einen RSA-Hostkey anbietet, muss ein ed25519-Key generiert und in der `app.ini` registriert werden:

```bash
# 1. ed25519-Key im Gitea-Pod generieren
kubectl -n gitea exec deploy/gitea -- \
  ssh-keygen -t ed25519 -f /data/ssh/ssh_host_ed25519_key -N ""

# 2. SSH_SERVER_HOST_KEYS unter [server] in app.ini eintragen (nach START_SSH_SERVER = true)
kubectl -n gitea exec deploy/gitea -- sed -i \
  '/^START_SSH_SERVER = true/a SSH_SERVER_HOST_KEYS = /data/ssh/gitea.rsa, /data/ssh/ssh_host_ed25519_key' \
  /data/gitea/conf/app.ini

# 3. Prüfen — muss unter [server] stehen, nicht unter [oauth2] o.ä.
kubectl -n gitea exec deploy/gitea -- grep -B5 "SSH_SERVER_HOST_KEYS" /data/gitea/conf/app.ini

# 4. Gitea neu starten
kubectl -n gitea rollout restart deploy/gitea
kubectl -n gitea rollout status deploy/gitea

# 5. Verifizieren
ssh-keyscan -t ed25519 git.reckeweg.io 2>/dev/null

# 6. Key in ArgoCD eintragen
ssh-keyscan -t ed25519 git.reckeweg.io 2>/dev/null | argocd cert add-ssh --batch
argocd cert list --cert-type ssh | grep reckeweg
```

> **Hinweis:** Der `ssh_host_ed25519_key` liegt auf dem Longhorn-PVC und überlebt Pod-Neustarts. Bei einem vollständigen Gitea-Redeployment (PVC-Verlust) muss dieser Schritt wiederholt werden. Langfristig: Key als Sealed Secret sichern und per `extraVolumes` in den Pod mounten.

## Rollback-Plan

### Schnell-Rollback auf vorherige Chart-Version

```bash
helm -n traefik rollback traefik
helm -n traefik history traefik
```

> **Wichtig**: Solange die alten `containo.us`-CRDs noch vorhanden sind (Phase 1–4 der v2→v3-Migration), ist ein Rollback auf Traefik v2 problemlos möglich. Erst nach Phase 6 (CRD-Cleanup) ist der Rollback deutlich aufwändiger, da CRDs manuell zurückgespielt werden müssten.

### Fallback-Manifeste

Backup-Dateien aus der Bestandsaufnahme-Phase bereithalten:

```bash
kubectl apply -f traefik-values-backup-v26.yaml   # nur als Referenz
kubectl apply -f ingressroutes-backup.yaml
kubectl apply -f middlewares-backup.yaml
```

Für reine Minor/Patch-Upgrades genügt ein `targetRevision`-Downgrade in `gitops/apps/traefik.yaml` + Commit, da ArgoCD `syncPolicy.automated` mit `selfHeal: true` konfiguriert ist.

## Referenzen

- GitHub Releases: [traefik/traefik-helm-chart Releases](https://github.com/traefik/traefik-helm-chart/releases)
- [Traefik v2→v3 Migration Guide](https://doc.traefik.io/traefik/migrate/v2-to-v3/)
- [Traefik v3 Detail Changes](https://doc.traefik.io/traefik/migrate/v2-to-v3-details/)
- [traefik-helm-chart README](https://github.com/traefik/traefik-helm-chart)
- [Helm CRD Caveat HIP-0011](https://github.com/helm/community/blob/main/hips/hip-0011.md)
