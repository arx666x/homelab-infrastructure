# Runbook: Gitea – Code Mirror & Container Build/Push

**Ziel:** Automatisches Spiegeln von Code und Container Images von Gitea (homelab) nach GitHub Personal (arx666x) und SailPoint GitHub (achim-reckeweg-sp) via Gitea Actions.

## Accounts

| Rolle | Platform | Account |
|-------|----------|---------|
| Primäre Entwicklung (R/W) | Gitea | `achim` @ `git.reckeweg.io` |
| Persönliches Backup | GitHub | `arx666x` @ `github.com` |
| SailPoint (Arbeit) | GitHub | `achim-reckeweg-sp` @ `github.com` |

## Repositories

| Gitea (Primary)                              | GitHub Personal (Backup)                             | SailPoint GitHub (Mirror)                                |
|----------------------------------------------|------------------------------------------------------|----------------------------------------------------------|
| `git@git.reckeweg.io:achim/prism.git`        | `git@github.com:arx666x/prism.git`                  | `https://github.com/achim-reckeweg-sp/prism.git`        |
| `git@git.reckeweg.io:achim/trakkws-quarkus.git` | `git@github.com:arx666x/trakkws-quarkus.git`     | `https://github.com/achim-reckeweg-sp/trakkws-quarkus.git` |
| `git@git.reckeweg.io:achim/erp-portal.git`  | `git@github.com:arx666x/erp-portal.git`             | `https://github.com/achim-reckeweg-sp/erp-portal.git`  |
| `git@git.reckeweg.io:achim/seri-k8s.git`    | `git@github.com:arx666x/seri-k8s.git`               | `https://github.com/achim-reckeweg-sp/seri-k8s.git`    |

## Architektur

```
Lokaler Push / Tag
  │
  ├─ git push  →  Gitea (origin)
  │                │
  │                ├─ dual-push remote  →  github.com/arx666x  (Code-Backup, automatisch)
  │                │
  │                ├─ mirror-to-sailpoint.yml  →  github.com/achim-reckeweg-sp  (Code-Mirror)
  │                │
  │                └─ build-and-push.yml  →  (nur bei git tag v*)
  │                        ├── gitea.reckeweg.io/achim/<repo>:<tag>
  │                        ├── ghcr.io/achim-reckeweg-sp/<repo>:<tag>
  │                        └── ghcr.io/arx666x/<repo>:<tag>
  │
  └─ Lokal (ohne Tag)  →  build-push.sh  →  gitea.reckeweg.io/achim/<repo>:latest
```

## Code-Backup via dual-push Remote (einmalig pro Repo)

Das persönliche GitHub wird als zweites Push-Ziel am `origin` Remote eingetragen:

```bash
git remote set-url --add --push origin git@git.reckeweg.io:achim/<repo>.git
git remote set-url --add --push origin git@github.com:arx666x/<repo>.git
```

Prüfen: `git remote -v` → beide URLs müssen unter `origin (push)` erscheinen.

## Gitea Actions Secrets (pro Repo)

| Secret | Wert | Wo erstellen |
|--------|------|-------------|
| `REGISTRY_TOKEN` | Gitea API Token (`write:package`) | gitea.reckeweg.io → Settings → Applications |
| `SAILPOINT_GITHUB_TOKEN` | GitHub PAT (`repo`, `write:packages`) | github.com/achim-reckeweg-sp → Settings → Developer settings → PAT |
| `PERSONAL_GITHUB_TOKEN` | GitHub PAT (`write:packages`) | github.com/arx666x → Settings → Developer settings → PAT |

Secrets in Gitea hinterlegen: `https://gitea.reckeweg.io/achim/<repo>/settings/actions/secrets`

> Secret-Namen werden in Gitea lowercase gespeichert (`registry_token`), in den Workflows
> als uppercase referenziert (`${{ secrets.REGISTRY_TOKEN }}`). Gitea matcht case-insensitiv.

> **Hinweis:** SailPoint GitHub erfordert YubiKey für interaktive Anmeldung.
> Tokens werden einmalig vom Firmen-Laptop erstellt und danach als Gitea Secrets hinterlegt.

## Gitea Actions Workflows

Beide Workflows liegen in jedem Repo unter `.gitea/workflows/`:

| Datei | Trigger | Funktion |
|-------|---------|----------|
| `mirror-to-sailpoint.yml` | Push auf beliebigen Branch | Code nach github.com/achim-reckeweg-sp spiegeln |
| `build-and-push.yml` | Push eines Tags `v*` | Multi-arch Container bauen und in alle 3 Registries pushen |

### build-and-push.yml – Ablauf

1. *(Optional)* Pre-build Schritte — falls das Dockerfile Pre-built Artefakte erwartet
2. Multi-arch Build (`linux/amd64` + `linux/arm64`) via Docker Buildx + QEMU
3. Push → `gitea.reckeweg.io/achim/<repo>:<tag>` + `:latest`
4. Push → `ghcr.io/achim-reckeweg-sp/<repo>:<tag>` + `:latest` (im selben Build)
5. `imagetools create` (kein Rebuild!) → `ghcr.io/arx666x/<repo>:<tag>` + `:latest`

### Projekt-spezifische Variationen

Der generische Workflow funktioniert für Projekte bei denen das Dockerfile alles selbst baut
(z.B. Multi-stage Build). Für Projekte die Pre-built Artefakte benötigen, muss der Workflow
um Build-Schritte **vor** dem Docker Build erweitert werden.

**Beispiel: trakkws-quarkus** (Quarkus + Vite Dokumentation)

Das Dockerfile erwartet:
- `target/trakkws-quarkus-runner.jar` — Quarkus uber-jar (Maven Build)
- `documentation/dist` — API-Dokumentation (Vite Build, via Maven npm-Plugin)

Beide Artefakte sind gitignored und werden im CI gebaut. Da Maven nicht im Runner Image
vorinstalliert ist, wird Maven 3.9.x explizit geladen:

```yaml
- name: Set up JDK 21
  uses: actions/setup-java@v4
  with:
    java-version: '21'
    distribution: 'temurin'

- name: Install Maven
  run: |
    curl -fsSL https://archive.apache.org/dist/maven/maven-3/3.9.9/binaries/apache-maven-3.9.9-bin.tar.gz \
      | tar xz -C /opt
    echo "/opt/apache-maven-3.9.9/bin" >> $GITHUB_PATH

- name: Build JAR and documentation
  run: mvn clean package -Pjvm -DskipTests
```

> **Hinweis:** Das Maven-Profil `-Pjvm` baut automatisch auch die Vite-Dokumentation
> via Maven npm-Plugin (`npm-install-documentation`, `npm-build-documentation`).

### Container Pakete mit Repository verknüpfen (einmalig nach erstem Push)

Nach dem ersten erfolgreichen Build erscheinen die Pakete **nicht** automatisch auf der Repository-Seite,
sondern zunächst nur auf der Profil-Ebene. Dort muss die Verknüpfung einmalig hergestellt werden.

**Gitea:**
1. `https://gitea.reckeweg.io/achim/-/packages` → Paket anklicken
2. Rechte Sidebar → "Repository" → "Link this package to a repository"

**GitHub Personal (arx666x):**
1. `https://github.com/users/arx666x/packages` → Paket anklicken
2. "Package settings" → "Connect Repository" → Repo auswählen

**GitHub SailPoint (achim-reckeweg-sp):**
1. `https://github.com/users/achim-reckeweg-sp/packages` → Paket anklicken
2. "Package settings" → "Connect Repository" → Repo auswählen

Nach der Verknüpfung erscheint das Paket in der Repository-Sidebar unter "Packages".

---

## Phase 1: Einmalig vom Firmen-Laptop (SailPoint GitHub Token)

### 1.1 SailPoint GitHub Personal Access Token erstellen

1. Am Firmen-Laptop anmelden: [https://github.com/achim-reckeweg-sp](https://github.com/achim-reckeweg-sp)
2. **Settings → Developer settings → Personal access tokens → Tokens (classic)**
3. **Generate new token (classic)**
   - Note: `gitea-mirror-token`
   - Expiration: `No expiration` (oder nach Policy anpassen)
   - Scope: ✅ **repo** (Full control of private repositories – deckt auch public Repos ab)
4. Token kopieren und **sofort sichern** (wird nur einmal angezeigt)

### 1.2 SailPoint GitHub Repositories anlegen

Für jedes Repository einmal:

1. Auf GitHub als `achim-reckeweg-sp` einloggen
2. **New repository** anlegen:
   - Name: `prism` / `trakkws-quarkus` / `seri-k8s` / `erp-portal`
   - Visibility: **Private** (oder Public je nach Anforderung)
   - ⚠️ **KEIN** README, .gitignore oder License initialisieren (leer lassen!)
3. Wiederholen für alle 4 Repositories

---

## Phase 2: Gitea Secrets konfigurieren (einmalig, pro Repository)

Dies geht über die Gitea Web UI (`https://gitea.reckeweg.io`) oder via API.

### 2.1 Secret via Web UI setzen

Für jedes Repository:

1. `https://gitea.reckeweg.io/achim/<repo>/settings/secrets`
2. **Add Secret**:
   - Name: `SAILPOINT_GITHUB_TOKEN`
   - Value: Der Token aus Phase 1.1

### 2.2 Alternativ: Secret via Gitea API setzen (Script für alle Repos)

```bash
#!/bin/bash
# set-sailpoint-secrets.sh
# Voraussetzung: GITEA_TOKEN und SAILPOINT_TOKEN als Umgebungsvariablen gesetzt

GITEA_URL="https://gitea.reckeweg.io"
GITEA_USER="achim"
REPOS=("prism" "trakkws-quarkus" "seri-k8s" "erp-portal")

if [[ -z "$GITEA_TOKEN" || -z "$SAILPOINT_TOKEN" ]]; then
  echo "ERROR: Bitte GITEA_TOKEN und SAILPOINT_TOKEN setzen"
  exit 1
fi

for REPO in "${REPOS[@]}"; do
  echo "→ Setting secret for ${REPO}..."
  RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PUT "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${REPO}/actions/secrets/SAILPOINT_GITHUB_TOKEN" \
    -H "Authorization: token ${GITEA_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"data\": \"${SAILPOINT_TOKEN}\"}")
  
  if [[ "$RESPONSE" == "204" || "$RESPONSE" == "201" ]]; then
    echo "  ✓ Secret gesetzt (HTTP ${RESPONSE})"
  else
    echo "  ✗ Fehler (HTTP ${RESPONSE})"
  fi
done
```

Ausführen:

```bash
export GITEA_TOKEN="dein-gitea-token"   # Gitea → Settings → Applications
export SAILPOINT_TOKEN="ghp_xxx..."      # Token aus Phase 1.1
bash set-sailpoint-secrets.sh
```

---

## Phase 3: Gitea Actions Workflow (pro Repository)

Folgende Datei in jedem Repository anlegen:

**Pfad:** `.gitea/workflows/mirror-to-sailpoint.yml`

```yaml
name: Mirror to SailPoint GitHub

on:
  push:
    branches:
      - '**'
  delete: {}

jobs:
  mirror:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout (full history)
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Mirror to SailPoint GitHub
        env:
          SAILPOINT_TOKEN: ${{ secrets.SAILPOINT_GITHUB_TOKEN }}
          REPO_NAME: ${{ github.repository }}
        run: |
          # Reponame aus "achim/prism" → "prism" extrahieren
          SHORT_NAME="${REPO_NAME##*/}"
          
          git remote add sailpoint \
            "https://x-access-token:${SAILPOINT_TOKEN}@github.com/achim-reckeweg-sp/${SHORT_NAME}.git"
          
          git push --mirror sailpoint
```

> **Hinweis zu `delete: {}`:** Löschevents (z.B. Branch-Deletes) werden ebenfalls gespiegelt.
> Falls das nicht gewünscht ist, diesen Trigger entfernen.

### Workflow in allen Repositories anlegen

```bash
#!/bin/bash
# create-mirror-workflows.sh
# Repos müssen lokal ausgecheckt sein

REPOS=(
  "$HOME/dev/prism"
  "$HOME/dev/trakkws-quarkus"
  "$HOME/dev/seri-k8s"
  "$HOME/dev/erp-portal"
)

WORKFLOW_DIR=".gitea/workflows"
WORKFLOW_FILE="mirror-to-sailpoint.yml"

WORKFLOW_CONTENT='name: Mirror to SailPoint GitHub

on:
  push:
    branches:
      - '"'"'**'"'"'
  delete: {}

jobs:
  mirror:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout (full history)
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Mirror to SailPoint GitHub
        env:
          SAILPOINT_TOKEN: ${{ secrets.SAILPOINT_GITHUB_TOKEN }}
          REPO_NAME: ${{ github.repository }}
        run: |
          SHORT_NAME="${REPO_NAME##*/}"
          git remote add sailpoint \
            "https://x-access-token:${SAILPOINT_TOKEN}@github.com/achim-reckeweg-sp/${SHORT_NAME}.git"
          git push --mirror sailpoint
'

for REPO_PATH in "${REPOS[@]}"; do
  if [[ ! -d "$REPO_PATH" ]]; then
    echo "⚠️  Nicht gefunden: ${REPO_PATH} – übersprungen"
    continue
  fi
  
  echo "→ ${REPO_PATH}"
  mkdir -p "${REPO_PATH}/${WORKFLOW_DIR}"
  echo "$WORKFLOW_CONTENT" > "${REPO_PATH}/${WORKFLOW_DIR}/${WORKFLOW_FILE}"
  
  cd "$REPO_PATH"
  git add "${WORKFLOW_DIR}/${WORKFLOW_FILE}"
  git commit -m "ci: add Gitea Action to mirror to SailPoint GitHub"
  git push
  echo "  ✓ Committed und gepusht"
done
```

> **Pfade anpassen:** Die `REPOS`-Liste mit den tatsächlichen lokalen Pfaden ergänzen.

---

## Phase 4: ERP-Portal aus seri-k8s extrahieren

Das ERP-Portal liegt aktuell in `achim/seri-k8s` und soll in ein eigenes Repository `achim/erp-portal` ausgelagert werden.

### 4.1 Neues Repository anlegen

```bash
# Auf Gitea (Web UI): Neues leeres Repo "erp-portal" unter achim/ anlegen
# Dann lokal:

cd ~/dev   # oder dein Arbeitsverzeichnis
git clone git@git.reckeweg.io:achim/seri-k8s.git erp-portal-extract
cd erp-portal-extract
```

### 4.2 Git History für ERP-Portal-Pfad filtern

```bash
# git-filter-repo installieren (falls nicht vorhanden)
brew install git-filter-repo

# Nur den ERP-Portal Unterordner behalten, History bereinigen
# Anpassen: Pfad entsprechend der tatsächlichen Struktur in seri-k8s
git filter-repo --path apps/erp-portal/ --path-rename apps/erp-portal/:

# Prüfen ob die History korrekt ist
git log --oneline | head -20
ls -la
```

> **Pfad anpassen:** Den tatsächlichen Unterordnerpfad in `seri-k8s` prüfen und anpassen
> (z.B. `apps/erp-portal/`, `erp-portal/`, oder ähnliches).

### 4.3 In neues Repository pushen

```bash
# Remote umbiegen auf das neue leere Repo
git remote set-url origin git@git.reckeweg.io:achim/erp-portal.git
git push -u origin --all
git push origin --tags
```

### 4.4 ERP-Portal aus seri-k8s entfernen

```bash
cd ~/dev/seri-k8s   # lokaler Checkout von seri-k8s

# ERP-Portal Ordner entfernen
git rm -r apps/erp-portal/   # Pfad anpassen!
git commit -m "chore: extract erp-portal to own repository"
git push
```

### 4.5 ArgoCD Application für erp-portal aktualisieren

Falls erp-portal via ArgoCD deployed wird, die Application YAML auf das neue Repository zeigen lassen:

```yaml
# gitops/apps/erp-portal.yaml (Pfad anpassen)
spec:
  source:
    repoURL: git@git.reckeweg.io:achim/erp-portal.git
    targetRevision: HEAD
    path: k8s/overlays/homelab   # oder colima
```

---

## Phase 5: Initiales Mirror (einmalig, nach Setup)

Nach dem ersten Push triggert die Action automatisch. Für den **allerersten Mirror** (bestehende History) empfiehlt sich ein manueller Push:

```bash
# Einmalig pro Repository – initiales Mirror pushen
REPOS=("prism" "trakkws-quarkus" "seri-k8s" "erp-portal")
SAILPOINT_TOKEN="ghp_xxx..."  # Token aus Phase 1.1

for REPO in "${REPOS[@]}"; do
  echo "→ Initial mirror: ${REPO}"
  
  # Temporäres bare clone
  git clone --mirror "git@git.reckeweg.io:achim/${REPO}.git" "/tmp/${REPO}.git"
  cd "/tmp/${REPO}.git"
  
  git push --mirror \
    "https://x-access-token:${SAILPOINT_TOKEN}@github.com/achim-reckeweg-sp/${REPO}.git"
  
  cd /tmp
  rm -rf "${REPO}.git"
  echo "  ✓ ${REPO} gespiegelt"
done
```

---

## Verifikation

### Gitea Actions prüfen

Nach dem ersten Push auf ein Repository:

1. `https://gitea.reckeweg.io/achim/<repo>/actions` aufrufen
2. Den letzten Workflow-Run anklicken
3. Logs auf Fehler prüfen

### Gitea Runner prüfen

Gitea Actions benötigt einen Runner. Prüfen ob einer verfügbar ist:

```bash
# Gitea Web UI → Admin → Runners
# https://gitea.reckeweg.io/-/admin/runners
```

Falls kein Runner vorhanden oder aktiv ist → siehe Abschnitt "Gitea Runner einrichten" unten.

---

## Anhang: Gitea Runner einrichten (falls noch nicht vorhanden)

Falls Gitea Actions noch keinen aktiven Runner haben:

```bash
# Auf einem k8s Node oder separatem Host:
docker run -d \
  --name gitea-runner \
  --restart unless-stopped \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v gitea-runner-data:/data \
  -e GITEA_INSTANCE_URL="https://gitea.reckeweg.io" \
  -e GITEA_RUNNER_REGISTRATION_TOKEN="TOKEN_AUS_GITEA_ADMIN" \
  -e GITEA_RUNNER_NAME="homelab-runner" \
  gitea/act_runner:latest
```

Token: `https://gitea.reckeweg.io/-/admin/runners` → **Create new runner**

Alternativ als Kubernetes Deployment – bei Bedarf separat dokumentieren.

---

## Bekannte Einschränkungen

| Thema | Beschränkung |
|-------|-------------|
| SailPoint GitHub | Interaktiver Login erfordert YubiKey (nur Firmen-Laptop) |
| Token Rotation | `SAILPOINT_GITHUB_TOKEN` in Gitea Secrets manuell aktualisieren wenn Token abläuft |
| Mirror-Richtung | Nur Gitea → SailPoint (nicht zurück) |
| `git.reckeweg.io` | Ausschliesslich SSH – Docker Registry und HTTPS über `gitea.reckeweg.io` |
| Docker Images | Container Registry auf `gitea.reckeweg.io` (Port 443, HTTPS) |
