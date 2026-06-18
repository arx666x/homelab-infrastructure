# Upgrade Agent Setup

Automatically checks Helm chart versions weekly, uses Claude AI to assess safety,
and either creates a Gitea PR (auto-upgrade) or sends Telegram + email notification (manual review).

## Required Gitea Secrets

Configure these in **Gitea → Repository → Settings → Actions → Secrets**:

| Secret name | Value |
|---|---|
| `ANTHROPIC_API_KEY` | API key from [console.anthropic.com](https://console.anthropic.com) → API Keys |
| `GITEA_TOKEN` | Gitea user token with **repo write** scope (Settings → Applications → Generate Token) |
| `TELEGRAM_BOT_TOKEN` | Existing Alertmanager bot token |
| `GMAIL_APP_PASSWORD` | Existing Gmail app password used by Alertmanager |

## How it works

1. **Monday 08:00 UTC** — Gitea Actions triggers `.gitea/workflows/auto-upgrade.yml`
2. Script reads `gitops/apps/*.yaml` for current chart versions
3. Queries each Helm chart repository for the latest available version
4. For each update found:
   - Fetches GitHub release notes
   - Reads the cluster-specific runbook from `docs/upgrades/`
   - Asks Claude Opus 4.8 for an upgrade decision
5. **AUTO decision** → creates a branch, commits the version bump, opens a Gitea PR + Telegram notification
6. **NOTIFY decision** → sends Telegram message + email for manual action

## Decision policy

| Bump type | Default decision | Override condition |
|---|---|---|
| Patch | AUTO | Breaking changes in release notes → NOTIFY |
| Minor | NOTIFY | Runbook explicitly marks as low-risk, no CRD changes → AUTO |
| Major | NOTIFY | Always |

## Monitored services

| Service | App file | Runbook |
|---|---|---|
| metrics-server | `gitops/apps/metrics-server.yaml` | `metrics-server-upgrade-runbook.md` |
| longhorn | `gitops/apps/longhorn.yaml` | `longhorn-upgrade-runbook.md` |
| metallb | `gitops/apps/metallb.yaml` | `metallb-upgrade-runbook.md` |
| kube-prometheus-stack | `gitops/apps/monitoring.yaml` | `kube-prometheus-stack-upgrade-runbook.md` |
| sealed-secrets | `gitops/apps/sealed-secrets.yaml` | `sealed-secrets-upgrade-runbook.md` |
| traefik | `gitops/apps/traefik.yaml` | `traefik-upgrade-runbook.md` |
| cert-manager | `gitops/apps/cert-manager.yaml` | `cert-manager-upgrade-runbook.md` |

## Manual run

```bash
export ANTHROPIC_API_KEY=sk-ant-...
export GITEA_TOKEN=...
export TELEGRAM_BOT_TOKEN=...
export GMAIL_APP_PASSWORD=...

# Dry-run (no git push, no notifications sent)
DRY_RUN=true python3 scripts/upgrade-agent.py

# Live run
python3 scripts/upgrade-agent.py
```

## Dependencies

```bash
pip install anthropic httpx pyyaml
```

`helm` and `git` must be available in PATH.
