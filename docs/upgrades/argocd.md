# Upgrade Runbook: ArgoCD

## Metadaten
- **Namespace:** argocd
- **Aktuelle Version:** 3.5.1
- **Quelle:** GitHub Releases ([argoproj/argo-cd](https://github.com/argoproj/argo-cd/releases)) + `scripts/install-argocd.sh` / `scripts/upgrade-argocd-hop.sh`
- **ArgoCD App-Name:** — (bootstrap via `scripts/install-argocd.sh`, nicht ArgoCD-App-verwaltet)
- **Versions-Check-Quelle:** `homelab-version-checker` (CronJob, `gitops/config/monitoring/homelab-version-checker-v2.yaml`) fragt die GitHub-Releases-API für `argoproj/argo-cd` ab, sammelt **alle** stabilen Releases, sortiert nach SemVer und nimmt das höchste (siehe Stolperfalle zu parallelen Release-Branches). Die laufende Version wird aus dem Image-Tag von `deployment/argocd-server` gelesen.
- **Major/Minor-Kriterium:** Minor-/Patch-Hops (z. B. 3.4.x → 3.4.y) gelten als unkritisch, werden aber weiterhin pro Hop gegen die offizielle Breaking-Changes-Doku geprüft und manuell ausgeführt — es gibt keinen Auto-Upgrade-Mechanismus für ArgoCD selbst, da es nicht als ArgoCD-Application verwaltet wird. Major-Hops (z. B. 2.x → 3.0) erfordern zwingend sequentielle Minor-Hops ohne Skip (siehe Upgrade-Pfad) sowie Pre-Migration-Schritte auf der letzten 2.x-Version.

**Wichtige Abgrenzung:** `gitops/apps/argocd-config.yaml` (ArgoCD-Application `argocd-config`) verwaltet nur Zusatzkonfiguration unter `gitops/config/argocd` (Ingress, SSH-known-hosts-ConfigMap) — **nicht** die ArgoCD-Installation selbst. Die eigentliche Installation/das Upgrade von ArgoCD läuft komplett außerhalb von ArgoCD-Applications über die beiden oben genannten Scripts.

## Changelog

| Datum | Von → Nach | Typ | Ausführung | Status | Begründung | Notiz |
|---|---|---|---|---|---|---|
| unbekannt | ... | ... | ... | ... | Historie vor Einführung des strukturierten Runbooks nicht vollständig rekonstruierbar | — |
| 2026-04-30 | 2.9.3 → 3.2.10 | Major | Manuell | Abgeschlossen | 9 Hops (2.9.3 → 2.14.x → 3.0.x → 3.1.x → 3.2.10), Breaking Changes 2.x→3.0 analysiert (Resource Tracking, RBAC, compareoptions) | Resource Tracking auf `annotation` migriert vor 3.0-Hop |
| 2026-05-04 | 3.2.10 → 3.3.9 | Minor | Manuell | Abgeschlossen | `--server-side --force-conflicts` ab 3.3 Pflicht (CRD-Größe überschreitet client-side-apply-Limit); NodeAffinity+Resource-Limits für Application Controller ergänzt | Script `scripts/upgrade-argocd-hop.sh` eingeführt |
| 2026-05-18 | 3.3.9 → 3.4.1 | Minor | Manuell | Abgeschlossen | Kein Handlungsbedarf; Cluster-Versionsformat-Änderung betrifft nur ApplicationSets mit Cluster-Generator (nicht genutzt) | CLI via brew (danach auf 3.4.2) |
| 2026-05-18 | 3.4.1 → 3.4.2 | Minor (Patch) | Manuell | Abgeschlossen | Patch-Release, keine Breaking Changes, keine Config-Änderungen nötig | CLI via brew bereits aktuell |
| 2026-06-14 | 3.4.2 → 3.4.3 | Minor (Patch) | Manuell | Abgeschlossen | Security-Fix dompurify CVE-2026-41240; sonst Bugfixes (Application Controller Race Condition, gitops-engine nil-pointer) | Nach diesem Hop trat das SSH-known-hosts-Problem auf (siehe Stolperfallen) |
| 2026-06-29 | 3.4.3 → 3.4.4 | Minor (Patch) | Manuell | Abgeschlossen | Patch-Release, kein Breaking Change; Bugfixes Application Controller & UI (RBAC-Regression bei project-scoped Resources, Cluster-Informer Race Condition, Diff-Fehler bei neuen Objekten, Dex-Passwort-Parsing) | — |
| 2026-07-13 | 3.4.4 → 3.4.5 | Minor (Patch) | Manuell (Script, SSH-Fix manuell nachgezogen) | Abgeschlossen | Patch-Release, kein Breaking Change; Bugfixes (Repo-Server Depth-Handling bei Multi-Source, SSA-Auth-Reconciliation, Auto-Sync-Regression bei manifest-generate-paths, UI zeigte gelöschte Ressourcen, Field-Clobbering bei "replace", Dex-Env-Var-Substitution) | `scripts/upgrade-argocd-hop.sh` scheiterte in Schritt 2/4 (SSH-known-hosts-Patch) an ungültigem JSON durch rohe Newlines in `ssh-keyscan`-Output — Notfall-Fix (python3 `json.dumps`) manuell angewandt, siehe Stolperfalle unten. NodeAffinity/Resources blieben durch Server-Side-Apply erhalten (anderer Field-Manager), Schritt 4 des Scripts war nicht nötig |
| 2026-08-03 | 3.4.5 → 3.4.6 | Minor (Patch) | Script (`upgrade-argocd-hop.sh`, bereits mit python3-json.dumps-Fix) | Abgeschlossen | Patch-Release, kein Breaking Change; Bugfixes (AppSet-Patching Fallback auf create bei NotFound, Diff-Filtering für manager-owned descendant fields, Helm-Registry-Passwort via stdin statt CLI-Arg, Repo-Server pprof-Mount, Annotation-Backfill nur wenn live state unset, Progressive-Sync-Fixes, OIDC: Entra-ID uti-Claim + Refresh-Token-Renewal) | Vorlauf-Blocker (nicht ArgoCD-bedingt): direkt vor dem Hop wurden die Cluster-Node-OS-Updates abgeschlossen; dabei fuhr `gitea-postgresql-0` auf `gmkt-02x` unsauber herunter → Katalog-Korruption an Index `UQE_user_badge_unique_user_badge` (0 `pg_attribute`-Zeilen, `cache lookup failed for attribute 1 of relation 49471`) → Gitea-Migration crashte dauerhaft → `git.reckeweg.io:22` nicht erreichbar → fast alle Apps `Sync: Unknown`. Fix: PVC `data-gitea-postgresql-0` aus Longhorn-Backup von 01:02 Uhr (vor dem Reboot) auf neuem PV/PVC restored, altes PV auf `Retain` gepatcht (Forensik-Fallback, noch vorhanden als `pvc-ec243727-...` / Released), danach Gitea-Pod neu gestartet und `argocd-repo-server` neu gerollt. Erst danach der eigentliche Versions-Hop. Siehe auch: unclean-shutdown-Risiko bei Reboots auf Longhorn/Postgres-Workloads generell im Blick behalten (Parallele zum k3s-06a-iSCSI-Incident). **Follow-up 2026-08-03 (später am selben Tag):** Root-Cause-Analyse ergab einen tieferliegenden Bug in `update-master-nodes.yml` — `kubectl drain`/Longhorn-Eviction waren an `k3s_installed_ver != k3s_version` gekoppelt, liefen also nur bei einem k3s-Versionssprung, während der Reboot-Task selbst unconditional immer läuft. Bei reinen OS-Update-Läufen (wie diesem, kein k3s-Bump nötig) wurde dadurch komplett ungedraint gebootet. Fix: Drain/Longhorn-Eviction/Uncordon von diesem Vergleich entkoppelt (laufen jetzt immer). Zusätzlich in beiden Node-Playbooks (`update-master-nodes.yml` und `update-pi-nodes.yml`) einen "Warten bis keine Volumes mehr auf diesem Node attached sind"-Check nach dem Drain ergänzt (nicht nur Replica-Eviction) — siehe auch das am selben Tag ebenfalls korrumpierte Prometheus-Volume auf einem Worker (`docs/upgrades/kube-prometheus-stack.md`), das trotz vorhandener Replica-Eviction betroffen war. |
| 2026-08-10 | 3.4.6 → 3.5.0 | Minor | Script (`upgrade-argocd-hop.sh`) | Abgeschlossen | Kein CRD-Schema-Change. Größte Änderung ist intern Helm 3→4, Breaking Changes betreffen aber ausschließlich OCI-Registries (`--plain-http`/`--insecure-oci-force-http`) — Cluster nutzt ausschließlich klassische HTTPS-Helm-Repos und Gitea-SSH-Sourcen, keine `oci://`-Repos, daher nicht betroffen | Lief beim ersten Versuch fehlerfrei durch (kein SSH-known-hosts-Nacharbeit nötig), NodeAffinity/Resources unverändert erhalten, alle 30 Apps sofort Synced/Healthy |
| 2026-08-21 | 3.5.0 → 3.5.1 | Minor (Patch) | Script (`upgrade-argocd-hop.sh`) | Abgeschlossen | Patch-Release, kein Breaking Change | Teil der Sammel-Update-Runde 2026-08-21; lief beim ersten Versuch fehlerfrei durch, NodeAffinity/Resources (250m/512Mi–2000m/2Gi) unverändert erhalten, Controller auf `gmkt-03x`, alle 30 Apps sofort Synced/Healthy |

### Reklassifizierungen (Minor → Major)

| Datum Erkennung | Ursprünglicher Changelog-Eintrag (Datum) | Grund der Reklassifizierung | Erneute Benachrichtigung gesendet am |
|---|---|---|---|

## Manuelle Vorgehensweise (bei Major/Breaking Change)

### Upgrade-Pfad 2.x → 3.x (kein Minor-Skip erlaubt)

```
2.9.3 → 2.10.x → 2.11.x → 2.12.x → 2.13.x → 2.14.x → 3.0.x → 3.1.x → 3.2.10 → 3.3.9
```

### Zeitaufwand-Schätzung (Major-Upgrade über mehrere Hops)

| Phase | Dauer (ca.) |
|---|---|
| Pre-Flight-Checks & Backup | 30–45 min |
| 5× Minor-Hops (2.9→2.14) | 5× 10 min = 50 min |
| Major-Hop 2.14 → 3.0 (Breaking Changes!) | 30–45 min |
| 3.0 → 3.1 → 3.2 | 2× 10 min = 20 min |
| Post-Upgrade-Verifikation | 20–30 min |
| **Gesamt** | **ca. 2.5–3 Stunden** |

> **Empfehlung:** In einem Wartungsfenster durchführen, da ArgoCD während der Hops kurz nicht sync-fähig ist. Laufende Workloads sind davon nicht betroffen.

### Breaking-Changes-Analyse 2.x → 3.0 (Ingress Health Check Kompatibilität)

Der Cluster nutzt einen Custom Health Check für Ingress/Traefik-IngressRoute in `argocd-cm`:

```yaml
data:
  resource.customizations.health.networking.k8s.io_Ingress: |
    hs = {}
    hs.status = "Healthy"
    hs.message = ""
    return hs
  resource.customizations.health.traefik.io_IngressRoute: |
    hs = {}
    hs.status = "Healthy"
    hs.message = ""
    return hs
```

**Befund: Diese Konfiguration ist von den Breaking Changes NICHT betroffen** — das Key-Format `resource.customizations.health.<group>_<kind>` bleibt in 3.0 unverändert.

Weitere relevante Breaking Changes 2.x → 3.0:

- **Unbetroffen — Custom Health Checks:** bleiben vollständig kompatibel.
- **Betroffen — `resource.exclusions`:** ArgoCD 3.0 fügt neue Default-Exclusions ein (Endpoints, EndpointSlice, Lease, TokenReview, etc.). Eigene `resource.exclusions` müssen gemergt, nicht ersetzt werden.
- **Betroffen — `resource.compareoptions`:** Zwei geänderte Defaults:
  - `ignoreDifferencesOnResourceUpdates` wechselt auf `true` (v2-Verhalten: explizit `false` setzen).
  - `ignoreResourceStatusField` wechselt von `crd` auf `all` (v2-Verhalten: explizit `crd` setzen).
- **Betroffen — Resource Tracking Method:** Default wechselt auf `annotation` (statt `label`). Muss **vor** dem 3.0-Hop, noch auf 2.14, umgestellt werden.
- **Betroffen — RBAC Fine-Grained Policies:** `update`/`delete` auf eine Application gilt nicht mehr automatisch für Sub-Ressourcen. Nur relevant bei eigenen RBAC-Policies in `argocd-rbac-cm`. Workaround: `server.rbac.disableApplicationFineGrainedRBACInheritance: "false"`.
- **Betroffen — Logs-RBAC:** Flag `server.rbac.log.enforce.enable` wird in 3.0 entfernt (Logs-RBAC ist dauerhaft aktiv) — vor dem Hop entfernen, falls gesetzt.
- **Unbetroffen — Legacy Repository-Konfiguration:** Sealed-Secrets-basierte Repo-Secrets, kein legacy `repositories:`-Feld.
- **Unbetroffen (3.1 → 3.2) — CronJob-Healthcheck:** Geänderter Default-Healthcheck für suspended CronJobs betrifft nur den Built-in-Check für `batch/CronJob`, nicht den eigenen Ingress-Patch.

### Phase 0: Pre-Flight-Checks

```bash
# 1. Aktuellen Status prüfen — keine App darf degraded sein
kubectl get applications -n argocd \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}'

# 2. ArgoCD-Pods prüfen
kubectl get pods -n argocd

# 3. Aktuelle Version bestätigen
kubectl get deployment argocd-server -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# 4. Aktuelle argocd-cm sichern (Sichtung)
kubectl get cm argocd-cm -n argocd -o yaml

# 5. Resource Tracking Method prüfen (muss vor 3.0 auf "annotation")
kubectl get cm argocd-cm -n argocd \
  -o jsonpath='{.data.application\.resourceTrackingMethod}'

# 6. Eigene resource.exclusions prüfen
kubectl get cm argocd-cm -n argocd \
  -o jsonpath='{.data.resource\.exclusions}'

# 7. RBAC-Log-Enforce-Flag prüfen (muss vor 3.0 weg)
kubectl get cm argocd-cm -n argocd \
  -o jsonpath='{.data.server\.rbac\.log\.enforce\.enable}'
```

### Phase 1: Backup

**1.1 ArgoCD `admin export`:**

```bash
ARGOCD_VERSION=$(kubectl get deployment argocd-server -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].image}' | cut -d: -f2)

kubectl exec -n argocd deploy/argocd-server -- \
  argocd admin export --namespace argocd \
  > argocd-backup-$(date +%Y%m%d-%H%M%S).yaml
```

**1.2 Rohe Kubernetes-Ressourcen sichern (Fallback):**

```bash
BACKUP_DIR="argocd-backup-raw-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
kubectl get applications -n argocd -o yaml > "$BACKUP_DIR/applications.yaml"
kubectl get appprojects -n argocd -o yaml  > "$BACKUP_DIR/appprojects.yaml"
kubectl get configmaps -n argocd -o yaml   > "$BACKUP_DIR/configmaps.yaml"
kubectl get secrets -n argocd \
  -l argocd.argoproj.io/secret-type -o yaml > "$BACKUP_DIR/secrets.yaml"
kubectl get cm argocd-rbac-cm -n argocd -o yaml > "$BACKUP_DIR/argocd-rbac-cm.yaml"
```

**1.3 Backup auf NAS kopieren:**

```bash
scp -r "$BACKUP_DIR/" nas.reckeweg.io:/volume1/backups/argocd/
scp argocd-backup-*.yaml nas.reckeweg.io:/volume1/backups/argocd/
```

### Phase 2: Minor-Hops 2.9 → 2.14

Für jeden Hop `TARGET_VERSION` anpassen und alle Checks wiederholen:

```bash
TARGET_VERSION="v2.10.18"   # dann v2.11.x, v2.12.x, v2.13.x, v2.14.x

kubectl apply -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${TARGET_VERSION}/manifests/install.yaml"

kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=300s
kubectl rollout status deployment/argocd-application-controller -n argocd --timeout=300s || \
  kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s

kubectl get deployment argocd-server -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

kubectl get applications -n argocd \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}'
```

> **Vor jedem Hop:** aktuelle Patch-Version des Minor prüfen: https://github.com/argoproj/argo-cd/releases

### Phase 3: Vorbereitung für 3.0 (auf 2.14 durchzuführen!)

```bash
# Resource Tracking auf annotation umstellen
kubectl patch cm argocd-cm -n argocd --type merge \
  -p '{"data":{"application.resourceTrackingMethod":"annotation"}}'
# Danach alle Apps refreshen und prüfen ob Synced bleibt

# server.rbac.log.enforce.enable entfernen, falls gesetzt
kubectl get cm argocd-cm -n argocd \
  -o jsonpath='{.data.server\.rbac\.log\.enforce\.enable}'
kubectl patch cm argocd-cm -n argocd --type=json \
  -p='[{"op":"remove","path":"/data/server.rbac.log.enforce.enable"}]'

# RBAC Fine-Grained temporär deaktivieren (Sicherheitsnetz)
kubectl patch cm argocd-cm -n argocd --type merge \
  -p '{"data":{"server.rbac.disableApplicationFineGrainedRBACInheritance":"false"}}'

# Eigene resource.exclusions nach dem 3.0-Hop mit neuen Defaults mergen (Endpoints, Lease, etc.)
```

### Phase 4: Major-Hop → 3.0.x

```bash
TARGET_VERSION="v3.0.10"   # aktuelle Patch-Version prüfen!

kubectl apply -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${TARGET_VERSION}/manifests/install.yaml"

kubectl get crd applications.argoproj.io -o jsonpath='{.spec.versions[*].name}'

kubectl rollout status deployment/argocd-server -n argocd --timeout=600s
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=600s

kubectl get deployment argocd-server -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

kubectl get applications -n argocd \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}'
```

**Post-3.0 Verifikation (kritisch):**

```bash
kubectl get applications -n argocd \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.health.status}{"\n"}{end}'

kubectl get cm argocd-cm -n argocd \
  -o jsonpath='{.data.resource\.customizations\.health\.networking\.k8s\.io_Ingress}'

kubectl get cm argocd-cm -n argocd \
  -o jsonpath='{.data.application\.resourceTrackingMethod}'
# Erwartet: annotation

# UI manuell prüfen: https://argocd.reckeweg.io
```

### Phase 5: Hops 3.0 → 3.1 → 3.2.10

Keine Breaking Changes, die die eigene Konfiguration betreffen (Source Hydrator mit Repo-Root betrifft uns nicht, da Kustomize-Pfade genutzt werden).

```bash
TARGET_VERSION="v3.1.15"
kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${TARGET_VERSION}/manifests/install.yaml"
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s

TARGET_VERSION="v3.2.10"
kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${TARGET_VERSION}/manifests/install.yaml"
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
```

### Ab v3.3: Standard-Hop-Prozedur via Script

Ab dem 3.2.10 → 3.3.9 Hop wird `scripts/upgrade-argocd-hop.sh <version>` genutzt (übernimmt Server-Side-Apply, SSH-known-hosts-Wiederherstellung, Rollout-Wait und NodeAffinity/Resource-Patch für den Application Controller in einem Schritt):

```bash
./scripts/upgrade-argocd-hop.sh v3.4.4
```

Manuell (ohne Script), z. B. für einen reinen Patch-Hop:

```bash
kubectl apply -n argocd \
  --server-side \
  --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.4/manifests/install.yaml"

kubectl rollout status deployment/argocd-server              -n argocd --timeout=300s
kubectl rollout status deployment/argocd-repo-server         -n argocd --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s

# Version bestätigen
kubectl get deployment argocd-server -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# CLI aktualisieren (via brew, sobald Paket verfügbar)
brew upgrade argocd
argocd version --client
```

### Post-Upgrade-Verifikation (generisch, nach jedem Hop)

```bash
kubectl get deployment argocd-server -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

kubectl get pods -n argocd

kubectl get applications -n argocd \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}'

# App-of-Apps explizit prüfen
kubectl get application homelab-infrastructure -n argocd -o jsonpath='{.status}'

# Ingress Health Check verifizieren
kubectl get cm argocd-cm -n argocd -o yaml | grep -A5 "customizations.health"
```

## Bekannte Stolperfallen / Lessons Learned

- **SSH-known-hosts-Henne-Ei-Problem (jedes Upgrade):** `kubectl apply` des `install.yaml` setzt `argocd-ssh-known-hosts-cm` auf den Default zurück (nur GitHub, GitLab, Bitbucket, Azure DevOps — **nicht** `git.reckeweg.io`). Danach kann ArgoCD nicht mehr auf das Gitea-Repo zugreifen, obwohl der korrekte Key in `gitops/config/argocd/argocd-ssh-known-hosts-cm.yaml` im Git-Repo liegt — ArgoCD kann ihn aber nicht laden, weil der Zugriff auf Git selbst blockiert ist. Trat konkret am 2026-06-14 nach dem Upgrade auf v3.4.3 auf: alle Apps zeigten Sync-Status `Unknown` (aber `Healthy`), Fehler `ssh: handshake failed: knownhosts: key is unknown`.

  **Notfall-Fix:**
  ```bash
  GITEA_KEYS=$(ssh-keyscan git.reckeweg.io 2>/dev/null | grep -v "^#")
  CURRENT=$(kubectl get configmap argocd-ssh-known-hosts-cm -n argocd \
    -o jsonpath='{.data.ssh_known_hosts}')
  NEW_CONTENT="${CURRENT}
  ${GITEA_KEYS}"
  kubectl patch configmap argocd-ssh-known-hosts-cm -n argocd \
    --type merge \
    -p "{\"data\":{\"ssh_known_hosts\":$(echo "$NEW_CONTENT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}}"
  kubectl rollout restart deployment -n argocd argocd-repo-server
  kubectl get applications -n argocd \
    -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
  ```
  `scripts/upgrade-argocd-hop.sh` automatisiert diesen Fix bereits als Schritt 2/4 — bei manuellem Vorgehen ohne Script muss er jedes Mal erneut ausgeführt werden. Der dauerhafte Fix liegt in [`gitops/config/argocd/argocd-ssh-known-hosts-cm.yaml`](../../gitops/config/argocd/argocd-ssh-known-hosts-cm.yaml); ArgoCD stellt den ConfigMap danach automatisch aus Git wieder her, aber das Henne-Ei-Problem tritt beim nächsten Upgrade erneut auf.

  **Bug in `scripts/upgrade-argocd-hop.sh` Schritt 2/4 (gefunden 2026-07-13):** Das Script baut den JSON-Patch per simpler String-Interpolation (`"{\"data\":{\"ssh_known_hosts\":\"${SSH_KEY}\"}}"`). `ssh-keyscan` liefert aber mehrzeiligen Output mit rohen Newlines, die in einem JSON-String nicht escaped sind → `Error from server (BadRequest): error decoding patch: invalid character '\n' in string literal`. Schritt 1 (Manifest-Apply) läuft davon unbeeinflusst durch, das Script bricht aber in Schritt 2 ab (`set -e`), Schritt 3/4 (Rollout-Wait, NodeAffinity/Resources) werden **nicht** ausgeführt. Workaround: den Notfall-Fix oben (mit `python3 -c 'import json...'` für korrektes Escaping) manuell ausführen, danach Rollout-Status und NodeAffinity/Resources manuell prüfen (Server-Side-Apply lässt von anderen Field-Managern gesetzte Felder wie NodeAffinity/Resources i. d. R. unangetastet, sicherheitshalber trotzdem verifizieren). **Fix:** `scripts/upgrade-argocd-hop.sh` wurde am 2026-07-13 auf dieselbe `python3 json.dumps`-Methode umgestellt.

- **CrashLoopBackOff durch falschen Patch-Typ auf StatefulSet:** Ein Merge-Patch auf `spec.template.spec.containers[]` überschreibt den gesamten Container-Spec — `image`, `command`, `args` gehen verloren, tini startet ohne Argumente und crasht sofort (`tini (tini version 0.19.0) Usage: tini [OPTIONS] PROGRAM -- [ARGS] | --version`).
  - **Affinity:** immer Merge-Patch auf `spec.template.spec` (nie auf `containers[]`).
  - **Resources:** immer JSON-Patch mit `"op": "replace"` auf den exakten Pfad `/spec/template/spec/containers/0/resources`.
  - **Recovery falls es passiert:** StatefulSet löschen und aus dem offiziellen Manifest neu anwenden, danach Affinity/Resources erneut sicher patchen:
    ```bash
    kubectl delete statefulset argocd-application-controller -n argocd
    kubectl apply -n argocd --server-side --force-conflicts \
      -f "https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.9/manifests/install.yaml"
    kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
    ```

- **Application Controller ohne Resource-Limits überlastet ARM64-Node:** Der Controller lief zeitweise auf `k3s-03a` (Raspberry Pi 5, ARM64) und verbrauchte über 1100m CPU (33 % des Nodes) — kein ArgoCD-Pod hatte Limits gesetzt. Fix (2026-05-04): NodeAffinity (preferred AMD64) + Resource Requests/Limits (250m/512Mi – 2000m/1Gi). Symptome eines überlasteten Controllers: ArgoCD-UI langsam/unerreichbar während Syncs, `kubectl top nodes` zeigt Pi-Node bei 30%+ CPU, `kubectl top pods -n argocd` zeigt Controller bei 1000m+.

- **OOM während Upgrades bei zu niedrigem Memory-Limit:** Das initiale Memory-Limit von 1Gi reichte während Upgrades nicht aus und führte zu OOM-Kills des Application Controllers; auf 2Gi angehoben (Commit `31adf21`).

- **`--server-side --force-conflicts` ab v3.3 Pflicht:** Client-side `kubectl apply` schlägt fehl, weil die ArgoCD-CRDs das Größenlimit für Annotationen bei client-side apply überschreiten.

- **Falsche "neueste Version" durch parallele Release-Branches:** Der Versions-Checker stoppte ursprünglich beim ersten zurückgegebenen stabilen Tag der GitHub-API. Da ArgoCD mehrere Release-Branches parallel pflegt, erschien z. B. v3.2.12 (Bugfix-Release nach v3.4.1) in der API-Antwort weiter oben und wurde fälschlich als neueste Version gemeldet. Fix (2026-05-18, Commit `2ddf234`): alle stabilen Releases sammeln, nach SemVer sortieren, höchste Version zurückgeben.

## Rollback-Plan

```bash
# Vorherige Version wieder anwenden (Beispiel: zurück auf 2.13.x nach fehlgeschlagenem 2.14-Hop)
ROLLBACK_VERSION="v2.13.6"
kubectl apply -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ROLLBACK_VERSION}/manifests/install.yaml"
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s

# Falls argocd-cm modifiziert wurde: aus Backup wiederherstellen
kubectl apply -f argocd-backup-raw-YYYYMMDD-HHMMSS/configmaps.yaml

# Falls Applications/AppProjects verloren gingen: aus Export wiederherstellen
kubectl exec -n argocd deploy/argocd-server -- \
  argocd admin import --namespace argocd - < argocd-backup-YYYYMMDD-HHMMSS.yaml
```

Ab v3.3-Hops zusätzlich: SSH-known-hosts-ConfigMap nach jedem Rollback erneut prüfen/patchen (siehe Stolperfalle oben), da auch der Rollback-`install.yaml` den Default zurücksetzt.

## Referenzen
- GitHub Releases: https://github.com/argoproj/argo-cd/releases
- [ArgoCD Upgrade Overview](https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/overview/)
- [v2.14 → 3.0 Breaking Changes](https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/2.14-3.0/)
- [v3.1 → 3.2 Breaking Changes](https://argo-cd.readthedocs.io/en/latest/operator-manual/upgrading/3.1-3.2/)
- [ArgoCD Disaster Recovery](https://argo-cd.readthedocs.io/en/latest/operator-manual/disaster_recovery/)
- Interne Doku: [`gitops/config/argocd/argocd-ssh-known-hosts-cm.yaml`](../../gitops/config/argocd/argocd-ssh-known-hosts-cm.yaml), `scripts/install-argocd.sh`, `scripts/upgrade-argocd-hop.sh`
