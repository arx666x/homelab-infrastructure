# Upgrade Runbook: Headlamp

## Metadaten
- **Namespace:** `headlamp`
- **Aktuelle Version:** `v0.43.0` (Image `ghcr.io/headlamp-k8s/headlamp:v0.43.0`)
- **Quelle:** Container-Image `ghcr.io/headlamp-k8s/headlamp` (kein Helm-Chart — direkte Kubernetes-Manifeste); Releases unter https://github.com/kubernetes-sigs/headlamp/releases
- **ArgoCD App-Name:** `headlamp` (Namespace `headlamp`, Pfad `gitops/config/headlamp`, kein sync-wave-Annotation gesetzt)
- **Versions-Check-Quelle:** Aktuell **nicht** über den automatisierten Upgrade-Agent abgedeckt — siehe „Bekannte Stolperfallen" unten. Manuell: Image-Tag in `gitops/config/headlamp/headlamp.yaml` (zwei Stellen: Hauptcontainer `headlamp` und Init-Container `fix-static-plugins`) gegen https://github.com/kubernetes-sigs/headlamp/releases prüfen
- **Major/Minor-Kriterium:** Kein Helm-Chart, daher keine Chart/App-Kopplung wie bei Gitea. Risiko liegt stattdessen bei den zwei Init-Container-Plugins (Longhorn, Cert-Manager), die unabhängig vom Headlamp-Core versioniert sind und bei Headlamp-Core-Upgrades auf Kompatibilität geprüft werden müssen (siehe Lessons Learned zum Longhorn-Plugin-Fork).

## Changelog

| Datum | Von → Nach | Typ | Ausführung | Status | Begründung | Notiz |
|---|---|---|---|---|---|---|
| 2026-02-25 | – → initial | Major (Ersteinrichtung) | Manuell | Abgeschlossen | Initiales Deployment, kein Helm-Chart, direkte Kubernetes-Manifeste | Commits `cffbda0`, `59b9473`, `3602cba`; DNS von `headlamp.homelab.reckeweg.io` auf `headlamp.reckeweg.io` umgestellt |
| unbekannt | initial → vor v0.40.1 | unbekannt | Manuell | Abgeschlossen | Historie vor Einführung des strukturierten Runbooks nicht vollständig rekonstruierbar (mehrere Debugging-Commits zu Dashboard-Absturz zwischen 2026-03-10 und 2026-03-11) | Commits `5f4d5df`, `7d43cf8`, `b784a51`, `0bd5d2a`, `ea58069`: Wechsel zwischen `-kubeconfig` und `-in-cluster`, Plugin-Ausschluss zur Fehlereingrenzung |
| 2026-03-11 | offizielles Longhorn-Plugin → eigener Fork (`gitea.reckeweg.io/achim/headlamp-longhorn`) | Minor (Plugin-Austausch, kein Core-Upgrade) | Manuell | Abgeschlossen | Offizielles Giant-Swarm-Plugin verursachte unter Headlamp v0.40.1 einen Dashboard-Absturz bei Detail-Routes mit `:namespace` ([kubernetes-sigs/headlamp#4863](https://github.com/kubernetes-sigs/headlamp/issues/4863)); Fork entfernt `:namespace` aus den Routen als Workaround | Commit `de2ae71`; Fork-Image über eigene Gitea-Registry ausgeliefert |
| 2026-04-30 | (Konfiguration, kein Versions-Bump) | — | Manuell | Abgeschlossen | ArgoCD zeigte permanentes Drift auf `resources: {}` in Init-/Hauptcontainern | Commit `8e17041`: `ignoreDifferences` für `.spec.template.spec.containers[].resources` und `initContainers[].resources` ergänzt |
| 2026-07-05 | `v0.40.1` → `v0.43.0`, Longhorn-Plugin: eigener Fork → offizielles Giant-Swarm-Plugin `0.1.1` | Minor (Core-Version) / **funktional bedeutsam** (Plugin-Quelle) | Manuell | Abgeschlossen | Der `:namespace`-Route-Absturz, der ursprünglich den Fork nötig gemacht hatte, wurde upstream in Headlamp selbst behoben ([kubernetes-sigs/headlamp#5679](https://github.com/kubernetes-sigs/headlamp/issues/5679), ausgeliefert mit v0.43.0) — der Fork ist damit obsolet und wurde durch das offizielle Plugin (`gsoci.azurecr.io/giantswarm/headlamp-longhorn:0.1.1`) ersetzt. Zusätzlich `-session-ttl=31536000` gesetzt (verfügbar seit v0.41.0), damit die Browser-Session zur 1-Jahres-Token-Laufzeit aus `headlamp-token.sh` passt, statt alle 24h erneut nach dem Token zu fragen | Commit `be0cae3`; betrifft `gitops/config/headlamp/headlamp.yaml` und `docs/DEPLOY-HEADLAMP.md` |

### Reklassifizierungen (Minor → Major)

| Datum Erkennung | Ursprünglicher Changelog-Eintrag (Datum) | Grund der Reklassifizierung | Erneute Benachrichtigung gesendet am |
|---|---|---|---|

## Manuelle Vorgehensweise (bei Major/Breaking Change)

Headlamp wird nicht über Helm, sondern über direkte Kubernetes-Manifeste plus ArgoCD betrieben.
Es gibt kein automatisiertes Chart-Upgrade — jeder Versions-Bump ist ein manueller Edit der
Image-Tags in `gitops/config/headlamp/headlamp.yaml`.

### Schritt 1: Pre-Flight-Checks

```bash
kubectl get pods -n headlamp
kubectl get deploy headlamp -n headlamp -o jsonpath='{.spec.template.spec.containers[0].image}'
argocd app get headlamp
```

### Schritt 2: Release-Notes prüfen

Releases: https://github.com/kubernetes-sigs/headlamp/releases

Insbesondere prüfen:
- Änderungen an Plugin-API/Plugin-Loading (betrifft Longhorn- und Cert-Manager-Plugin)
- Änderungen an CLI-Flags (`-in-cluster`, `-plugins-dir`, `-session-ttl`, etc.)
- Bekannte Dashboard-/Routing-Bugs, die eigene Workarounds nötig machen könnten

### Schritt 3: Image-Tag an zwei Stellen anheben

In `gitops/config/headlamp/headlamp.yaml` müssen **Hauptcontainer** (`headlamp`) und
Init-Container **`fix-static-plugins`** auf derselben Version bleiben:

```yaml
# Init-Container fix-static-plugins
image: ghcr.io/headlamp-k8s/headlamp:v<neu>

# Hauptcontainer
image: ghcr.io/headlamp-k8s/headlamp:v<neu>
```

```bash
git add gitops/config/headlamp/headlamp.yaml
git commit -m "feat(headlamp): upgrade v<alt> → v<neu>"
git push
```

ArgoCD synct automatisch (`prune: true`, `selfHeal: true`).

### Schritt 4: Upgrade beobachten

```bash
kubectl rollout status deployment/headlamp -n headlamp --timeout=180s
kubectl get pods -n headlamp -w
```

### Schritt 5: Plugin-Kompatibilität prüfen

Nach jedem Core-Upgrade beide Plugins im Browser testen:
- Longhorn-Plugin: Volumes-Ansicht, Detail-Routes mit Namespace-Parameter aufrufen
- Cert-Manager-Plugin: Certificates-Ansicht

Bei Absturz/Fehlverhalten: Browser-Konsole prüfen, ggf. Plugin-Init-Container-Logs:

```bash
kubectl logs -n headlamp -l app.kubernetes.io/name=headlamp -c install-longhorn-plugin
kubectl logs -n headlamp -l app.kubernetes.io/name=headlamp -c install-cert-manager-plugin
```

### Schritt 6: Post-Upgrade-Verifikation

```bash
curl -s -o /dev/null -w "%{http_code}" https://headlamp.reckeweg.io
# → 200

kubectl -n headlamp get deploy headlamp -o jsonpath='{.spec.template.spec.containers[0].image}'
```

Neuen Token bei Bedarf erzeugen: `bash scripts/headlamp-token.sh`

## Bekannte Stolperfallen / Lessons Learned

- **Longhorn-Plugin: Fork → offizielles Plugin (wichtigste Lektion).** Zwischen 2026-03-11 und
  2026-07-05 lief ein **eigener Fork** des Longhorn-Plugins
  (`gitea.reckeweg.io/achim/headlamp-longhorn`), weil das offizielle Giant-Swarm-Plugin unter
  Headlamp v0.40.1 beim Aufruf von Detail-Routes mit `:namespace`-Parameter zum Dashboard-Absturz
  führte ([kubernetes-sigs/headlamp#4863](https://github.com/kubernetes-sigs/headlamp/issues/4863)).
  Der Fork entfernte `:namespace` manuell aus den betroffenen Routen. Mit Headlamp **v0.43.0**
  wurde der zugrundeliegende Bug upstream im Headlamp-Core selbst behoben
  ([kubernetes-sigs/headlamp#5679](https://github.com/kubernetes-sigs/headlamp/issues/5679),
  Commit `be0cae3`, 2026-07-05) — seitdem läuft wieder das offizielle Plugin
  (`gsoci.azurecr.io/giantswarm/headlamp-longhorn:0.1.1`).
  **Handlungsanweisung für künftige Neuinstallationen/Wiederherstellungen:** Den alten Fork
  **nicht** erneut einsetzen, solange Headlamp auf v0.43.0 oder neuer bleibt — das offizielle
  Plugin ist der bevorzugte, wartungsfreie Weg. Der Fork sollte nur reaktiviert werden, falls ein
  zukünftiges Headlamp-Upgrade den `:namespace`-Bug erneut einführt (unwahrscheinlich, aber bei
  Downgrades unter v0.43.0 zu beachten).
- **Der automatisierte Upgrade-Agent kennt Headlamp aktuell nicht.** In `scripts/upgrade-agent.py`
  wurde der Headlamp-Eintrag in `IMAGE_SERVICES` mit Commit `2f3145f` (2026-06-18) explizit
  auskommentiert, mit der Begründung "wir nutzen einen eigenen Fork, Re-add erst nach Bestätigung
  des Upstream-Fixes". Der Upstream-Fix ist seit `be0cae3` (2026-07-05) bestätigt und der Fork
  bereits abgelöst — der Kommentar in `upgrade-agent.py` ist damit **veraltet** und Headlamp fehlt
  seither in der automatischen Versionsprüfung. Dies sollte nachgezogen werden (Headlamp wieder in
  `IMAGE_SERVICES` aufnehmen), ist aber außerhalb des Scopes dieses Runbooks.
- **Zwei Stellen für den Image-Tag:** Sowohl der Hauptcontainer `headlamp` als auch der
  Init-Container `fix-static-plugins` referenzieren dasselbe Headlamp-Image und müssen bei jedem
  Upgrade synchron gehalten werden — `fix-static-plugins` kopiert Static-Plugin-Assets aus dem
  Image, ein Versions-Mismatch führt zu fehlenden/falschen Sidebar-Einträgen.
  Der Workaround selbst (Bug in v0.40.1, dass Static Plugins sonst nicht in der Sidebar erscheinen)
  wurde nicht erneut gegen v0.43.0 verifiziert, ob er noch nötig ist.
- **`-in-cluster` vs. `-kubeconfig`:** Es gab eine Testphase (Commits `5f4d5df`, `7d43cf8`,
  im März 2026), in der auf `-kubeconfig=/headlamp/kubeconfig/config` umgestellt wurde, um
  Token-Eingabe im Browser zu vermeiden. Wurde wieder auf `-in-cluster` zurückgedreht, da
  Dashboard-Probleme weiter bestanden — die Ursache war letztlich das Longhorn-Plugin, nicht der
  Auth-Modus. Bare-Test ohne jedes Plugin (Commit `b784a51`) bestätigte das.
- **`resources: {}`-Drift in ArgoCD:** Da Resources direkt im Manifest gepflegt und teils per
  `kubectl`/lokalem Patch verändert wurden, zeigte ArgoCD dauerhaftes Drift. Fix seit Commit
  `8e17041` (2026-04-30): `ignoreDifferences` auf `.spec.template.spec.containers[].resources`
  und `initContainers[].resources` in `gitops/apps/headlamp.yaml`.
- **Kein Helm-Chart, direkte Manifeste:** Anders als bei den meisten anderen Services in diesem
  Repo gibt es für Headlamp keine Chart-Versionierung — Upgrades bedeuten reines Image-Tag-Bump
  in `gitops/config/headlamp/headlamp.yaml`. `scripts/deploy-headlamp.sh` und
  `scripts/cleanup-headlamp.sh` decken Ersteinrichtung bzw. vollständigen Rückbau ab, sind aber
  nicht für inkrementelle Upgrades gedacht.

## Rollback-Plan

Kein Helm-Rollback verfügbar (keine Chart-Historie). Rollback erfolgt über Git-Revert des
Image-Tags:

```bash
# 1. Image-Tag in gitops/config/headlamp/headlamp.yaml zurücksetzen
#    (Hauptcontainer UND fix-static-plugins Init-Container)
git revert <upgrade-commit>
# oder manuell:
#   image: ghcr.io/headlamp-k8s/headlamp:v<alte-version>
git add gitops/config/headlamp/headlamp.yaml
git commit -m "revert: headlamp rollback v<neu> → v<alt>"
git push

# 2. ArgoCD synct automatisch, oder manuell anstoßen
argocd app sync headlamp

# 3. Rollout prüfen
kubectl rollout status deployment/headlamp -n headlamp --timeout=180s
```

Bei komplett zerstörtem Deployment (z.B. nach fehlgeschlagenem Experiment):

```bash
bash scripts/cleanup-headlamp.sh   # entfernt ArgoCD-App, Namespace, ClusterRoleBinding
bash scripts/deploy-headlamp.sh    # deployt neu inkl. RBAC, Manifeste, ArgoCD-Registrierung, Token
```

> Wichtig: Beim Neuaufbau **nicht** versehentlich den alten Longhorn-Plugin-Fork
> (`gitea.reckeweg.io/achim/headlamp-longhorn`) wieder einsetzen — siehe Lessons Learned.
> Aktuelles `headlamp.yaml` referenziert bereits korrekt das offizielle Plugin.

## Referenzen

- GitHub Releases: https://github.com/kubernetes-sigs/headlamp/releases
- Bug-Historie Longhorn-Plugin-Fork: [kubernetes-sigs/headlamp#4863](https://github.com/kubernetes-sigs/headlamp/issues/4863) (Ursache), [kubernetes-sigs/headlamp#5679](https://github.com/kubernetes-sigs/headlamp/issues/5679) (Fix in v0.43.0)
- Session-TTL-Feature: [kubernetes-sigs/headlamp#4538](https://github.com/kubernetes-sigs/headlamp/issues/4538)
- Offizielles Longhorn-Plugin: https://github.com/giantswarm/headlamp-longhorn
- Interne Doku: `docs/DEPLOY-HEADLAMP.md`
- Deployment-/Cleanup-Skripte: `scripts/deploy-headlamp.sh`, `scripts/cleanup-headlamp.sh`, `scripts/headlamp-token.sh`
