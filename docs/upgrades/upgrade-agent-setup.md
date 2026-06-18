# Upgrade Agent Setup

Läuft als **Kubernetes CronJob** im Namespace `monitoring` — genau wie der bestehende
Version-Checker. Prüft Helm Chart- und Container Image-Versionen, fragt Claude AI nach
der Upgrade-Einschätzung und erstellt entweder automatisch einen Gitea PR oder
sendet Telegram + E-Mail für manuellen Review.

## Vorhandene Secrets (keine Aktion nötig)

| Secret | Namespace | Inhalt |
|---|---|---|
| `alertmanager-credentials` | `monitoring` | `telegram-bot-token`, `gmail-password` |

Diese sind bereits als Sealed Secrets im Cluster und werden vom Upgrade Agent direkt
eingebunden — keine Duplizierung.

## Neue Secrets (einmalig anlegen)

Nur zwei neue Werte werden benötigt:

| Schlüssel | Woher |
|---|---|
| `anthropic-api-key` | [console.anthropic.com](https://console.anthropic.com) → API Keys → Create Key |
| `gitea-token` | Gitea → Settings → Applications → Token mit `repo` Write-Zugriff |

### Secret anlegen und versiegeln

```bash
kubectl create secret generic upgrade-agent-credentials \
  --namespace monitoring \
  --from-literal=anthropic-api-key='sk-ant-...' \
  --from-literal=gitea-token='...' \
  --dry-run=client -o yaml \
| kubeseal --format yaml \
> gitops/config/monitoring/sealed-upgrade-agent-credentials.yaml

# Danach committen und pushen — ArgoCD wendet es automatisch an
git add gitops/config/monitoring/sealed-upgrade-agent-credentials.yaml
git commit -m "feat(monitoring): add sealed upgrade-agent-credentials"
git push origin main
```

## Wie es funktioniert

1. **Jeden Montag 08:00 Uhr** (Europe/Berlin) startet der CronJob
2. Init-Container klont das Repository (braucht deshalb den `gitea-token`) und holt `helm`
3. Der Agent prüft **7 Helm Charts** und **4 Container Images** auf neuere Versionen
4. Für jeden Fund: GitHub Release Notes holen + Runbook lesen + Claude Opus fragen
5. **AUTO** → Git Branch anlegen, Version bumpen, Gitea PR erstellen + Telegram-Meldung
6. **NOTIFY** → Telegram + E-Mail für manuelle Bearbeitung

## Entscheidungslogik (Claude)

| Bump-Typ | Standard | Überschreibung |
|---|---|---|
| Patch | AUTO | Breaking Changes in Release Notes → NOTIFY |
| Minor | NOTIFY | Runbook: kein Breaking Change, keine CRD-Migration → AUTO |
| Major | NOTIFY | Immer |

## Überwachte Services

### Helm Charts

| Service | App-Datei | Runbook |
|---|---|---|
| metrics-server | `gitops/apps/metrics-server.yaml` | `metrics-server-upgrade-runbook.md` |
| longhorn | `gitops/apps/longhorn.yaml` | `longhorn-upgrade-runbook.md` |
| metallb | `gitops/apps/metallb.yaml` | `metallb-upgrade-runbook.md` |
| kube-prometheus-stack | `gitops/apps/monitoring.yaml` | `kube-prometheus-stack-upgrade-runbook.md` |
| sealed-secrets | `gitops/apps/sealed-secrets.yaml` | `sealed-secrets-upgrade-runbook.md` |
| traefik | `gitops/apps/traefik.yaml` | `traefik-upgrade-runbook.md` |
| cert-manager | `gitops/apps/cert-manager.yaml` | `cert-manager-upgrade-runbook.md` |
| loki-stack | `gitops/apps/loki.yaml` | — |

### Container Images (Git/Kustomize)

| Service | Datei | Quelle |
|---|---|---|
| homeassistant | `gitops/config/homeassistant/deployment.yaml` | GitHub Releases |
| guacamole | `gitops/config/guacamole/guacamole.yaml` | Docker Hub |
| guacd | `gitops/config/guacamole/guacd.yaml` | Docker Hub |
| headlamp | `gitops/config/headlamp/headlamp.yaml` | GitHub Releases |

## Manueller Test

```bash
# Lokal ohne Cluster-Zugriff (Secrets via Env-Variablen)
pip install anthropic httpx pyyaml

export ANTHROPIC_API_KEY=sk-ant-...
export GITEA_TOKEN=...
export TELEGRAM_BOT_TOKEN=...
export SMTP_PASSWORD=...   # Gmail App-Passwort

# Trockenlauf — kein Git-Push, keine Benachrichtigungen
DRY_RUN=true python3 scripts/upgrade-agent.py

# Echter Lauf
python3 scripts/upgrade-agent.py
```

## Manuell im Cluster triggern

```bash
kubectl create job -n monitoring upgrade-agent-manual \
  --from=cronjob/upgrade-agent

# Logs verfolgen
kubectl logs -n monitoring -l job-name=upgrade-agent-manual -f
```
