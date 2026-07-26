# ArgoCD Image Updater: Konzept und Umsetzung

**Deployed:** 26. Juli 2026
**Namespace:** `argocd`
**Sync-Wave:** 4 (nach sealed-secrets Wave 2, nach longhorn Wave 3 - SealedSecrets müssen
entschlüsselbar sein, bevor der Controller seine eigenen Secrets lesen kann)
**Betrifft aktuell:** `auditique` (Susanns redesign-Projekt); als Vorlage für weitere Apps
gedacht, die per Container-Registry-Tag statt manuellem Tag-Bump ausgerollt werden sollen.

---

## 1. Konzept

### 1.1 Ausgangsproblem

`auditique.reckeweg.io` lief auf einer fest im Deployment eingetragenen Image-Version
(`gitops/config/auditique/deployment.yaml`, Zeile `image: gitea.reckeweg.io/susann/redesign:vX.Y.Z`).
Ein neues Release bedeutete: Susann taggt und pusht im `redesign`-Repo, `.gitea/workflows/build-and-push.yml`
baut und veröffentlicht das Image - und dann musste jemand (in der Praxis: ich) manuell in dieses
Repo wechseln, den Tag in `deployment.yaml` nachziehen, committen und pushen, damit ArgoCD den
Rest ausrollt. Funktionierte, aber jeder Release brauchte einen manuellen Cross-Repo-Schritt.

Zusätzlich fehlte ein Zwischenschritt: Susann wollte eine Änderung erst intern im Homelab sehen
können, bevor sie öffentlich beim Web-Hoster landet (Nutzer-seitige Erklärung dazu: Datei
`doc/deployment-prozess.md` im separaten `redesign`-Repo, `git@git.reckeweg.io:susann/redesign.git`
- kein Teil dieses Repos, daher kein direkter Link). Das führte zum Tag-Schema `RC-x.x.x`
(Vorschau, nur Homelab) / `GA-x.x.x` (Freigabe, Homelab + Web-Hoster) - und zur Frage, wie der
Homelab-Teil davon automatisiert wird, ohne dass ich jeden RC-Tag manuell nachziehen muss.

### 1.2 Warum ArgoCD Image Updater (und nicht die Alternative)

Zwei Optionen standen zur Wahl:

- **Der Gitea-Workflow committet den Tag selbst** in `homelab-infrastructure` zurück (ein
  zusätzlicher Schritt in `build-and-push.yml`, der nach dem Image-Push per Git-Push den Tag
  nachzieht). Einfacher, aber: braucht ein Cross-Repo-Token im `redesign`-Repo, das Schreibzugriff
  auf `homelab-infrastructure` hat - ein fremdes Repo bekommt damit Schreibrechte auf dieses hier.
- **ArgoCD Image Updater** beobachtet die Registry direkt und committet selbst zurück. Der
  `redesign`-Workflow muss nichts über `homelab-infrastructure` wissen, das Schreibrecht liegt
  komplett auf dieser Seite. Mehr initialer Aufwand (neuer Controller im Cluster), aber sauberer
  getrennt - und deckt sich mit einer bereits vorher notierten Absicht, weg vom manuellen
  Tag-Bump zu kommen.

Entscheidung: ArgoCD Image Updater.

### 1.3 Wichtige Architektur-Entscheidungen

Der Image Updater hatte kurz vor diesem Deploy einen größeren Versionssprung hinter sich: ältere
Anleitungen/Trainingsdaten beschreiben ein reines Annotations-System
(`argocd-image-updater.argoproj.io/image-list` etc.) direkt auf der `Application`. Die tatsächlich
installierte Version (**v1.2.2**) ist CRD-basiert (`ImageUpdater`-Custom-Resource) - Annotations
funktionieren nur noch über einen expliziten `useAnnotations: true`-Kompatibilitätsmodus. Das
wurde vor der Umsetzung anhand des Upstream-Quellcodes verifiziert (nicht nur der Doku, die an
mehreren Stellen widersprüchlich/unvollständig war), siehe Abschnitt 3.4. Umgesetzt wurde direkt
gegen die CRD, kein Annotations-Kompatibilitätsmodus.

Weitere Entscheidungen, mit Begründung:

| Entscheidung | Begründung |
|---|---|
| **Vendored Install-Manifest statt Helm-Chart** | Es gibt keinen offiziellen Helm-Chart für argocd-image-updater (auch nicht im `argo-helm`-Repo) - nur ein `install.yaml`. Wird als vendorierte Kopie unter `gitops/config/argocd-image-updater/install.yaml` gepflegt, drei leere Platzhalter-Ressourcen (ConfigMap/ConfigMap/Secret) entfernt, siehe 2.1. |
| **`update-strategy: newest-build` statt `semver`** | `RC-x.x.x`/`GA-x.x.x` ist kein gültiges Semver. `newest-build` sortiert nach Push-Zeitpunkt in der Registry statt nach Versionsnummer - passt zur in `deployment-prozess.md` dokumentierten Regel "der zuletzt gebaute Tag gewinnt". |
| **`allowTags: regexp:^(RC\|GA)-`** | Filtert die alten `vX.Y.Z`-Tags und alles andere aus der Registry heraus. `vX.Y.Z`-Tags sind bewusst rein informell (siehe deployment-prozess.md) und sollen nichts auslösen. |
| **Write-back `git:secret:...` statt `argocd`** | Der `argocd`-Write-back-Modus patcht `spec.source.kustomize.images` direkt auf dem *live* Application-Objekt - nicht in Git. Das `root-infrastructure` App-of-Apps hat `selfHeal: true` und würde diese Änderung beim nächsten Sync sofort wieder zurückdrehen, weil sie nicht im Git-Stand steht. Git-Write-back committet direkt in `gitops/config/auditique/kustomization.yaml` - danach sind Git und Cluster deckungsgleich, kein Konflikt. |
| **Dediziertes SSH-Keypaar statt Wiederverwendung des ArgoCD-Sync-Keys** | Der bestehende ArgoCD-Repo-Credential ist (vermutlich, nicht verifiziert) read-only, da ArgoCD zum Ausrollen nur Lesezugriff braucht. Statt das zu verifizieren/ändern: ein neues, für genau diesen Zweck erzeugtes SSH-Keypaar mit Schreibrecht, sauber getrennt (Least Privilege, einfache Rotation ohne den Sync-Key anzufassen). |
| **`auditique` von reinem Manifest-Verzeichnis auf Kustomize umgestellt** | Der Image Updater verlangt zwingend eine `Helm`- oder `Kustomize`-App (aus dem Quellcode/den Docs verifiziert - reine Verzeichnis-Apps werden nicht unterstützt). `gitops/config/auditique/kustomization.yaml` wurde neu angelegt, mit einem `images:`-Override-Eintrag als Ziel für den Write-back. |
| **Registry-Credentials & Git-Write-back-Key als eigene SealedSecrets** | Konsistent mit dem bestehenden Sealed-Secrets-Muster im Repo (siehe `gitops/sealed-secrets/seal-all-secrets.sh`) statt imperativ angelegter Secrets, die einen Cluster-Neuaufbau nicht überleben würden. |

---

## 2. Umsetzung

### 2.1 Dateien

```
gitops/apps/argocd-image-updater.yaml       ArgoCD Application (sync-wave 4)
gitops/config/argocd-image-updater/
├── install.yaml                            Vendored Upstream-Manifest v1.2.2 (CRD, RBAC,
│                                            Deployment, Service, NetworkPolicy) - die drei
│                                            leeren Platzhalter-Ressourcen aus dem Original
│                                            (ConfigMap argocd-image-updater-config,
│                                            ConfigMap argocd-image-updater-ssh-config,
│                                            Secret argocd-image-updater-secret) wurden entfernt
├── registries-configmap.yaml               Echte argocd-image-updater-config ConfigMap:
│                                            registries.conf für gitea.reckeweg.io
├── imageupdater-auditique.yaml             Die ImageUpdater-CR für auditique (siehe 2.3)
├── sealed-git-writeback-secret.yaml        SealedSecret, Key sshPrivateKey - Git-Write-back
├── sealed-gitea-registry-creds.yaml        SealedSecret, dockerconfigjson - Registry-Zugang
└── kustomization.yaml                      bindet alles zusammen

gitops/config/auditique/
├── kustomization.yaml                      neu: macht auditique zur Kustomize-App,
│                                            images: Override-Ziel für den Write-back
└── deployment.yaml                         Kommentar aktualisiert, image:-Tag ist jetzt nur
                                             noch der initiale Kustomize-Basiswert
```

Kein Helm-Chart-Repo-Eintrag nötig, da `install.yaml` direkt als Kustomize-Resource eingebunden
wird (Muster: `resources: [install.yaml, ...]`, keine `helm:`-Sektion).

### 2.2 Registry-Zugang (`registries-configmap.yaml`)

```yaml
registries:
- name: Gitea Homelab Registry
  prefix: gitea.reckeweg.io
  api_url: https://gitea.reckeweg.io
  credentials: pullsecret:argocd/gitea-registry-creds
```

`gitea-registry-creds` ist ein `kubernetes.io/dockerconfigjson`-Secret (Susanns Gitea-Zugang,
Scope `package`, Lesezugriff reicht). Wird über `gitops/sealed-secrets/seal-all-secrets.sh`,
Abschnitt "ArgoCD Image Updater", interaktiv erzeugt (Token maskiert abgefragt) - nicht Teil
dieses Repos im Klartext.

### 2.3 Die ImageUpdater-Ressource

```yaml
apiVersion: argocd-image-updater.argoproj.io/v1alpha1
kind: ImageUpdater
metadata:
  name: auditique
  namespace: argocd
spec:
  writeBackConfig:
    method: "git:secret:argocd/argocd-image-updater-git-creds"
    gitConfig:
      branch: main
      writeBackTarget: "kustomization"
  applicationRefs:
    - namePattern: "auditique"
      images:
        - alias: auditique-web
          imageName: gitea.reckeweg.io/susann/redesign
          commonUpdateSettings:
            updateStrategy: newest-build
            allowTags: "regexp:^(RC|GA)-"
            pullSecret: "pullsecret:argocd/gitea-registry-creds"
```

`writeBackTarget: "kustomization"` sorgt dafür, dass der neue Tag ins `images:`-Array von
`gitops/config/auditique/kustomization.yaml` geschrieben wird (statt in eine separate
`.argocd-source-auditique.yaml`, die für Helm-Parameter gedacht ist).

### 2.4 Git-Write-back-Credential

Eigenes ED25519-Keypaar, einmalig lokal generiert (`ssh-keygen`), privater Schlüssel direkt
versiegelt (`kubeseal`) und **nie** im Klartext committet oder in einer Chat-Session sichtbar
gemacht - nur der öffentliche Schlüssel musste manuell als **schreibfähiger** Deploy-Key im
`homelab-infrastructure`-Repo in Gitea hinterlegt werden (Repo → Settings → Deploy Keys, "Write
access"). Der öffentliche Schlüssel steht als Kommentar in
`sealed-git-writeback-secret.yaml` für spätere Rotation.

Secret-Format (von `argocd-image-updater` selbst so erwartet, siehe
`pkg/argocd/gitcreds.go` im Upstream-Quellcode):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: argocd-image-updater-git-creds
  namespace: argocd
data:
  sshPrivateKey: <base64>
```

Bewusst **kein** Volume-Mount, kein `argocd-image-updater-ssh-config` genutzt - der Controller
liest das Secret zur Laufzeit direkt per Kubernetes-API, wenn `writeBackConfig.method` das
`git:secret:<namespace>/<name>`-Format hat.

SSH-`known_hosts` für `git.reckeweg.io` werden **nicht** separat gepflegt - der Deployment
mountet die bereits bestehende `argocd-ssh-known-hosts-cm` (aus `gitops/config/argocd/`), die
ArgoCD selbst für den Sync verwendet und die den Host bereits enthält.

### 2.5 RBAC

Die Standard-Namespace-scoped-Installation (Option 1 aus den Upstream-Docs, Controller läuft im
`argocd`-Namespace) reicht vollständig aus: die mitgelieferte `Role`/`RoleBinding`
(`argocd-image-updater`) erlaubt bereits `get/list/watch` auf `secrets`/`configmaps` im
`argocd`-Namespace - keine zusätzliche RBAC nötig, um `gitea-registry-creds` oder
`argocd-image-updater-git-creds` zu lesen.

---

## 3. Betrieb

### 3.1 Reconcile-Intervall

Der Controller prüft alle **2 Minuten** (`interval=2m0s`, Standardwert) auf neue Tags. Nach einem
frischen `RC-`/`GA-`Tag also bis zu 2 Minuten Wartezeit, bis das Homelab die neue Version zeigt.

### 3.2 Status prüfen

```sh
kubectl get imageupdater -n argocd
# NAME        APPS   IMAGES   LAST CHECKED   READY
# auditique   1      1        ...            True

kubectl logs -n argocd -l app.kubernetes.io/name=argocd-image-updater --tail=30
```

### 3.3 Bekannte, harmlose Log-Meldungen

- `"no tags found for image ... in registry"`, `images_skipped=1, errors=0` - kein Fehler,
  bedeutet nur: aktuell existiert kein Tag, der auf `^(RC|GA)-` matcht (z. B. wenn seit dem
  letzten `vX.Y.Z`-Release noch kein `RC-`/`GA-`Tag gepusht wurde).
- `"could not fetch secret ... not found"` - nur relevant, falls dauerhaft: einmalig direkt nach
  Erst-Deploy erwartet, solange `sealed-gitea-registry-creds.yaml` noch der Kommentar-Platzhalter
  war (vor dem ersten Lauf von `seal-all-secrets.sh`).

### 3.4 Quelle für die CRD-Doku

Die öffentliche ReadTheDocs-Dokumentation war zum Zeitpunkt der Umsetzung an mehreren Stellen
unvollständig bzw. widersprüchlich (u. a. keine funktionierenden Deep-Links, `docs/git.md`
404, Detail zum `git:secret:...`-Format fehlte komplett). Verifiziert wurde daher zusätzlich
direkt gegen `github.com/argoproj-labs/argocd-image-updater` (`docs/configuration/applications.md`,
`docs/configuration/images.md`, `docs/basics/authentication.md`, `docs/install/installation.md`,
sowie `pkg/argocd/gitcreds.go` für das exakte Secret-Format). Bei zukünftigen Änderungen an dieser
Konfiguration lohnt sich derselbe Weg über den Quellcode, nicht nur die Doku-Website.

---

## 4. Nächste Schritte / mögliche Erweiterungen

- Weitere Apps auf dasselbe Muster umstellen, falls sich der manuelle Tag-Bump auch dort als
  Reibungspunkt zeigt (aktuell nur `auditique` konfiguriert).
- SSH-Key-Rotation: neues Keypaar generieren, `sealed-git-writeback-secret.yaml` neu versiegeln
  (Befehl siehe Kommentar in der Datei), alten Deploy-Key in Gitea löschen, neuen einspielen.
