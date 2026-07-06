# Runbook: seri.2026 – Bidirektionaler Sync Gitea ↔ SailPoint GitHub

**Ziel:** `seri.2026` liegt primär auf Gitea (Fork des alten, unmaintained GitHub-Projekts inkl.
History). Zusätzlich soll das Projekt unter `achim-reckeweg-sp` auf GitHub verfügbar sein –
aber dort **nicht** als reiner Read-Only-Mirror, sondern als vollwertiges Repo, in dem der
User selbst und Kollegen Änderungen einbringen können. Diese Änderungen sollen wieder
zurück nach Gitea fließen.

## Warum das bestehende `mirror-to-sailpoint.yml`-Pattern hier NICHT passt

Das bestehende Pattern (siehe [gitea-sailpoint-mirror-runbook.md](gitea-sailpoint-mirror-runbook.md))
nutzt `git push --mirror`. Das macht den Zielstand auf GitHub **exakt identisch** zu Gitea –
jeder Branch/Commit, der nur auf GitHub existiert (z.B. ein von einem Kollegen gemergter PR,
der noch nicht nach Gitea zurückgeflossen ist), würde beim nächsten Gitea-Push **gelöscht**.

→ Für `seri.2026` brauchen wir stattdessen:
- Einen **fast-forward-only** Push von Gitea nach GitHub (kein `--mirror`, kein `--force`)
- Einen bewussten, manuellen Rückweg von GitHub nach Gitea

## Architektur

```
Gitea (primär, Source of Truth)              SailPoint GitHub (kollaborativ)
git.reckeweg.io/achim/seri.2026              github.com/achim-reckeweg-sp/seri.2026

  git push main
       │
       ├─► Gitea Action "sync-to-sp-github.yml"
       │      → git push sp-github HEAD:main   (fast-forward only, KEIN --mirror)
       │
       │                                        Kollege/User erstellt Branch + PR
       │                                        PR wird auf GitHub reviewed & gemerged
       │                                                    │
       │                                                    ▼
       │◄────────────── manueller/regelmäßiger Rücksync ────┘
       │   (lokal: fetch sp-github/main, merge, push origin)
       ▼
  Gitea main aktuell
       │
       └─► triggert sync-to-sp-github.yml erneut → schreibt Merge-Commit
             zurück nach GitHub main (ff, da GitHub main jetzt Vorfahre ist)
```

Wichtiger Grundsatz (siehe auch bestehende Regel „Gitea ist primär"): Jede Änderung, egal auf
welcher Seite sie entsteht, landet am Ende in Gitea `main`. Von dort verteilt sich alles
automatisch weiter nach GitHub. Der GitHub-Zweig wird nie automatisch gemergt oder
force-gepusht – nur fast-forward.

---

## Schritt 1: Leeres Repo auf GitHub anlegen

1. Als `achim-reckeweg-sp` auf GitHub einloggen
2. **New repository** → Name: `seri.2026`
3. Visibility: Private oder Public – je nach Lizenz des ursprünglichen Upstream-Projekts prüfen
4. ⚠️ **Kein** README/.gitignore/License initialisieren (leer lassen, sonst schlägt der
   initiale Mirror-Push fehl)

## Schritt 2: Einmaliger initialer Full-History-Push

Analog zum ursprünglichen Fork-Vorgang – hier ist `--mirror` beim allerersten Push unkritisch,
weil das GitHub-Repo noch leer ist:

```bash
git clone --mirror git@git.reckeweg.io:achim/seri.2026.git /tmp/seri.2026.git
cd /tmp/seri.2026.git

git push --mirror https://x-access-token:<SP_TOKEN>@github.com/achim-reckeweg-sp/seri.2026.git

cd /tmp && rm -rf seri.2026.git
```

`<SP_TOKEN>`: GitHub PAT (classic, Scope `repo`) vom Firmen-Account `achim-reckeweg-sp`
(Firmen-Laptop, YubiKey nötig – siehe bestehendes Runbook, Phase 1.1). Kann derselbe Token
sein wie `SAILPOINT_GITHUB_TOKEN`, sofern der Scope passt.

## Schritt 3: Gitea Secret setzen (nur für dieses Repo)

`https://gitea.reckeweg.io/achim/seri.2026/settings/actions/secrets`

| Secret | Wert |
|--------|------|
| `SP_SERI2026_TOKEN` | GitHub PAT aus Schritt 2 |

Eigener Secret-Name, damit klar getrennt ist: Dieses Token/dieser Workflow macht **keinen**
`--mirror`-Push wie die anderen Repos.

## Schritt 4: Gitea Action für Fast-Forward-Sync nach GitHub

**Pfad:** `.gitea/workflows/sync-to-sp-github.yml`

```yaml
name: Sync main to SailPoint GitHub (fast-forward only)

on:
  push:
    branches:
      - main

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - name: Push main to SailPoint GitHub (no mirror, no force)
        env:
          SP_TOKEN: ${{ secrets.SP_SERI2026_TOKEN }}
        run: |
          set -euo pipefail
          rm -rf /tmp/seri2026-sync
          git clone --branch main --single-branch \
            "https://x-access-token:${{ secrets.GITHUB_TOKEN }}@gitea.reckeweg.io/achim/seri.2026.git" \
            /tmp/seri2026-sync
          cd /tmp/seri2026-sync
          git push "https://x-access-token:${SP_TOKEN}@github.com/achim-reckeweg-sp/seri.2026.git" HEAD:main
          cd /
          rm -rf /tmp/seri2026-sync
```

> **Kein `actions/checkout` verwenden!** Der Gitea-Runner in diesem Cluster läuft mit
> `ubuntu-latest:host://` (siehe ConfigMap `gitea-actions-runner-configmap`, Namespace `gitea`) –
> Jobs laufen also direkt im `act_runner`-Image, nicht in einem separaten Container mit
> vorinstalliertem Node.js. `actions/checkout@v4` ist eine JS-Action (`using: node20`) und
> schlägt dort mit `Cannot find: node in PATH` fehl. Deshalb hier ein einfaches `git clone`
> statt der Action – braucht kein Node. `${{ secrets.GITHUB_TOKEN }}` ist der von Gitea Actions
> automatisch bereitgestellte, repo-scoped Token (GitHub-kompatible Namensgebung), damit auch
> private Gitea-Repos geklont werden können.

**Wichtig:** Kein `--force`, kein `--mirror` beim Push nach GitHub. Wenn GitHub `main`
inzwischen Commits enthält, die auf Gitea noch fehlen (z.B. frisch gemergter Kollegen-PR),
schlägt dieser Push mit `non-fast-forward` fehl. Das ist gewollt – es zeigt an, dass zuerst
Schritt 6 (Rücksync) nötig ist, bevor wieder automatisch weitergeschrieben werden darf.

## Schritt 5: Kollegen-Zugriff & Review auf GitHub einrichten

**Repository → Settings → Collaborators and teams**
→ Kollegen mit `Write`-Zugriff hinzufügen (nicht `Admin` – siehe unten, warum das wichtig ist).
Am schnellsten mit [scripts/add-sailpoint-collaborator.sh](../../seri-k8s/scripts/add-sailpoint-collaborator.sh)
in seri-k8s (dort dokumentiert und für alle SailPoint-Repos nutzbar).

**Repository → Settings → Rules → Rulesets → New ruleset** (nicht die alten "Branch protection
rules" – bei persönlichen GitHub-Accounts ist Rulesets der aktuelle Weg):

| Feld | Wert |
|------|------|
| Ruleset Name | `Enforce Pull Request` |
| Enforcement status | `Active` |
| Bypass list | `Repository admin` (Rolle, keine Einzelperson wählbar bei persönlichen Accounts) |
| Target branches | `Include default branch` |
| Rules | ✅ Require a pull request before merging (Require approvals: 1) · ✅ Restrict deletions · ✅ Block force pushes |

> **Warum "Repository admin" als Bypass reicht:** Der Owner eines Repos unter dem eigenen
> Account (`achim-reckeweg-sp`) ist automatisch Admin – eine gezielte Personenauswahl gibt es
> bei persönlichen Accounts hier nicht. Der PAT aus Schritt 3 (`SP_SERI2026_TOKEN`)
> authentifiziert sich ebenfalls als `achim-reckeweg-sp` und erbt damit dieselbe Rolle – der
> Fast-Forward-Sync aus Schritt 4 kann also weiterhin direkt auf `main` pushen. Kollegen mit
> `Write`-Zugriff (nicht Admin) fallen **nicht** unter den Bypass und müssen zwingend über PRs.

Damit ist der Kollaborations-Workflow auf GitHub identisch zu jedem normalen
Open-Source-Projekt: Branch → PR → Review → Merge auf `main`. Die Merge-Methode
(Settings → General → Pull Requests) ist auf "Allow squash merging" beschränkt – die
Ruleset-Regeln oben schränken die Merge-Methode nicht zusätzlich ein, das Zusammenspiel
ist unkritisch.

## Schritt 6: Rücksync GitHub → Gitea (manuell, bei Bedarf)

Da Gitea primär bleiben soll (siehe bestehende Regel) und Gitea aus dem Homelab heraus keine
eingehenden Verbindungen von GitHub Actions annehmen muss, erfolgt der Rückweg **ausgehend**
vom lokalen Arbeitsplatz – kein Port-Forwarding oder VPN-Exposure nötig.

Script `sync-github-to-gitea.sh` (lokal ausführen, sooft ein PR auf GitHub gemerged wurde):

```bash
#!/bin/bash
set -euo pipefail

cd ~/dev/seri.2026   # lokaler Checkout, origin = Gitea

git remote add sp-github https://github.com/achim-reckeweg-sp/seri.2026.git 2>/dev/null || true

git fetch sp-github main
git checkout main
git pull --ff-only origin main
git merge --no-ff sp-github/main -m "chore: merge changes from SailPoint GitHub"

git push origin main
# → triggert automatisch sync-to-sp-github.yml, welcher den Merge-Commit
#   als Fast-Forward zurück nach GitHub main schreibt (kein Konflikt,
#   da GitHub main jetzt Vorfahre des Merge-Commits ist)
```

Bei Merge-Konflikten (beide Seiten haben dieselbe Stelle geändert) löst `git merge` das wie
gewohnt lokal auf – anschließend normal `git add`/`git commit`/`git push origin main`.

---

## Zusammenfassung: Wer darf was

| Ort | Wer schreibt direkt | Wie kommen Änderungen rein |
|-----|---------------------|------------------------------|
| Gitea `achim/seri.2026` | Nur User | Direkter Push (Source of Truth) |
| GitHub `achim-reckeweg-sp/seri.2026` `main` | Nur der Sync-Bot (PAT) | Fast-Forward aus Gitea, automatisch |
| GitHub `achim-reckeweg-sp/seri.2026` andere Branches | User + Kollegen | Normale Branches/PRs |
| Rückweg PR → Gitea | Nur User | Manuell via `sync-github-to-gitea.sh` |

## Bekannte Einschränkungen

| Thema | Beschränkung |
|-------|-------------|
| Automatisierung Rückweg | Bewusst manuell/on-demand – volle Automatik würde Konfliktauflösung unbeaufsichtigt laufen lassen |
| Sync-Workflow-Fehler | `non-fast-forward` beim Push nach GitHub ist ein Signal, keine Störung – erst Schritt 6 ausführen |
| Token-Rotation | `SP_SERI2026_TOKEN` in Gitea Secrets manuell erneuern, wenn PAT abläuft |
| Verwechslungsgefahr | Nicht das bestehende `mirror-to-sailpoint.yml` für dieses Repo wiederverwenden (macht `--mirror`, würde GitHub-Kollegenarbeit löschen) |
