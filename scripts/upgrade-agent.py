#!/usr/bin/env python3
"""
Upgrade Agent — Kubernetes CronJob edition.

Checks Helm chart versions AND git/kustomize image tags, reads upgrade runbooks,
uses Claude to decide, and either creates a Gitea PR (auto-upgrade) or sends
Telegram + email notification (manual review needed).

Runs as a Kubernetes CronJob in namespace 'monitoring'.
Secrets are mounted from Kubernetes secrets — no Gitea Actions secrets needed.

Secret mounts expected:
  /etc/upgrade-agent/secrets/anthropic-api-key   (from upgrade-agent-credentials)
  /etc/upgrade-agent/secrets/gitea-token          (from upgrade-agent-credentials)
  /etc/alertmanager/secrets/alertmanager-credentials/telegram-bot-token
  /etc/alertmanager/secrets/alertmanager-credentials/gmail-password

Environment variables (optional overrides):
  GITEA_BASE_URL      default: https://gitea.reckeweg.io
  GITEA_REPO          default: achim/homelab-infrastructure
  GITEA_SSH_URL       default: git@git.reckeweg.io:achim/homelab-infrastructure.git
  TELEGRAM_CHAT_ID    default: 8677165142
  SMTP_USER           default: achim.reckeweg@gmail.com
  NOTIFY_EMAIL        default: achim.reckeweg@gmail.com
  DRY_RUN             set to "true" to skip git push and notifications
"""

import os
import re
import sys
import json
import subprocess
import smtplib
import logging
import tempfile
import shutil
from dataclasses import dataclass
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from pathlib import Path
from typing import Optional

import anthropic
import httpx
import yaml

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).parent.parent

GITEA_BASE_URL  = os.environ.get("GITEA_BASE_URL",  "https://gitea.reckeweg.io")
GITEA_REPO      = os.environ.get("GITEA_REPO",      "achim/homelab-infrastructure")
GITEA_SSH_URL   = os.environ.get("GITEA_SSH_URL",   "git@git.reckeweg.io:achim/homelab-infrastructure.git")
TELEGRAM_CHAT_ID = int(os.environ.get("TELEGRAM_CHAT_ID", "8677165142"))
SMTP_USER       = os.environ.get("SMTP_USER",   "achim.reckeweg@gmail.com")
NOTIFY_EMAIL    = os.environ.get("NOTIFY_EMAIL", "achim.reckeweg@gmail.com")
DRY_RUN         = os.environ.get("DRY_RUN", "false").lower() == "true"

# Secret file paths (mounted from Kubernetes secrets)
SECRETS_DIR      = Path(os.environ.get("SECRETS_DIR", "/etc/upgrade-agent/secrets"))
ALERTMANAGER_DIR = Path(os.environ.get("ALERTMANAGER_DIR",
                         "/etc/alertmanager/secrets/alertmanager-credentials"))


def _read_secret(path: Path, env_var: str = "") -> str:
    """Read a secret from a mounted file or fall back to an env var."""
    if path.exists():
        return path.read_text().strip()
    if env_var and os.environ.get(env_var):
        return os.environ[env_var]
    return ""


# ---------------------------------------------------------------------------
# Helm chart services
# ---------------------------------------------------------------------------
# source_index: None = single source, int = index in multi-source 'sources' list

HELM_SERVICES = [
    {
        "name": "metrics-server",
        "app_file": "gitops/apps/metrics-server.yaml",
        "chart": "metrics-server",
        "repo_url": "https://kubernetes-sigs.github.io/metrics-server/",
        "runbook": "docs/upgrades/metrics-server-upgrade-runbook.md",
        "github_repo": "kubernetes-sigs/metrics-server",
        "source_index": None,
    },
    {
        "name": "longhorn",
        "app_file": "gitops/apps/longhorn.yaml",
        "chart": "longhorn",
        "repo_url": "https://charts.longhorn.io",
        "runbook": "docs/upgrades/longhorn-upgrade-runbook.md",
        "github_repo": "longhorn/longhorn",
        "source_index": None,
    },
    {
        "name": "metallb",
        "app_file": "gitops/apps/metallb.yaml",
        "chart": "metallb",
        "repo_url": "https://metallb.github.io/metallb",
        "runbook": "docs/upgrades/metallb-upgrade-runbook.md",
        "github_repo": "metallb/metallb",
        "source_index": 0,
    },
    {
        "name": "kube-prometheus-stack",
        "app_file": "gitops/apps/monitoring.yaml",
        "chart": "kube-prometheus-stack",
        "repo_url": "https://prometheus-community.github.io/helm-charts",
        "runbook": "docs/upgrades/kube-prometheus-stack-upgrade-runbook.md",
        "github_repo": "prometheus-community/helm-charts",
        "github_release_prefix": "kube-prometheus-stack-",
        "source_index": None,
    },
    {
        "name": "sealed-secrets",
        "app_file": "gitops/apps/sealed-secrets.yaml",
        "chart": "sealed-secrets",
        "repo_url": "https://bitnami-labs.github.io/sealed-secrets/",
        "runbook": "docs/upgrades/sealed-secrets-upgrade-runbook.md",
        "github_repo": "bitnami-labs/sealed-secrets",
        "source_index": None,
    },
    {
        "name": "traefik",
        "app_file": "gitops/apps/traefik.yaml",
        "chart": "traefik",
        "repo_url": "https://traefik.github.io/charts",
        "runbook": "docs/upgrades/traefik-upgrade-runbook.md",
        "github_repo": "traefik/traefik-helm-chart",
        "source_index": None,
    },
    {
        "name": "cert-manager",
        "app_file": "gitops/apps/cert-manager.yaml",
        "chart": "cert-manager",
        "repo_url": "https://charts.jetstack.io",
        "runbook": "docs/upgrades/cert-manager-upgrade-runbook.md",
        "github_repo": "cert-manager/cert-manager",
        "source_index": 0,
    },
    {
        "name": "loki-stack",
        "app_file": "gitops/apps/loki.yaml",
        "chart": "loki-stack",
        "repo_url": "https://grafana.github.io/helm-charts",
        "runbook": "",  # no dedicated runbook
        "github_repo": "grafana/loki",
        "source_index": None,
    },
]

# ---------------------------------------------------------------------------
# Git/Kustomize image services
# ---------------------------------------------------------------------------
# These are services tracked via git with pinned container image tags.
# version_type: "ghcr" | "dockerhub"
# current_image_pattern: regex to find the image line in the file

IMAGE_SERVICES = [
    {
        "name": "homeassistant",
        "image_files": ["gitops/config/homeassistant/deployment.yaml"],
        "image_pattern": r"ghcr\.io/home-assistant/home-assistant:([^\s\"']+)",
        "version_type": "ghcr",
        "github_repo": "home-assistant/core",
        "runbook": "",
    },
    {
        "name": "guacamole",
        "image_files": ["gitops/config/guacamole/guacamole.yaml"],
        "image_pattern": r"guacamole/guacamole:([^\s\"']+)",
        "version_type": "dockerhub",
        "dockerhub_image": "guacamole/guacamole",
        "github_repo": "apache/guacamole-client",
        "runbook": "",
    },
    {
        "name": "guacd",
        "image_files": ["gitops/config/guacamole/guacd.yaml"],
        "image_pattern": r"guacamole/guacd:([^\s\"']+)",
        "version_type": "dockerhub",
        "dockerhub_image": "guacamole/guacd",
        "github_repo": "apache/guacamole-server",
        "runbook": "",
    },
    {
        "name": "headlamp",
        "image_files": ["gitops/config/headlamp/headlamp.yaml"],
        "image_pattern": r"ghcr\.io/headlamp-k8s/headlamp:([^\s\"']+)",
        "version_type": "ghcr",
        "github_repo": "headlamp-k8s/headlamp",
        "runbook": "",
    },
]

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Data types
# ---------------------------------------------------------------------------

@dataclass
class UpgradeCandidate:
    name: str
    kind: str               # "helm" | "image"
    files: list[str]        # relative paths to modify
    current_version: str
    latest_version: str
    github_repo: str
    runbook: str
    # optional fields
    github_release_prefix: str = ""
    image_pattern: str = ""
    runbook_content: str = ""
    changelog: str = ""
    decision: str = ""          # AUTO | NOTIFY | SKIP
    decision_reason: str = ""


# ---------------------------------------------------------------------------
# Version utilities
# ---------------------------------------------------------------------------

def parse_version(v: str) -> tuple[int, ...]:
    clean = re.sub(r"\+.*$", "", str(v).lstrip("v"))
    parts = re.findall(r"\d+", clean)
    return tuple(int(p) for p in parts[:3]) if parts else (0,)


def version_bump_type(old: str, new: str) -> str:
    o = parse_version(old) + (0, 0, 0)
    n = parse_version(new)  + (0, 0, 0)
    if n[0] != o[0]: return "major"
    if n[1] != o[1]: return "minor"
    return "patch"


def is_prerelease(v: str) -> bool:
    return bool(re.search(r"(alpha|beta|rc|dev|pre|snapshot|\.ea[\.\d]|-ea[\.\d])", v, re.I))


# ---------------------------------------------------------------------------
# Helm version lookup  (uses helm binary — never loads index.yaml in Python)
# ---------------------------------------------------------------------------

_helm_repos: dict[str, str] = {}


def _helm_ensure_repo(repo_url: str) -> str:
    if repo_url in _helm_repos:
        return _helm_repos[repo_url]
    alias = f"r{len(_helm_repos)}"
    subprocess.run(["helm", "repo", "add", alias, repo_url, "--force-update"],
                   capture_output=True)
    subprocess.run(["helm", "repo", "update", alias], capture_output=True)
    _helm_repos[repo_url] = alias
    return alias


def helm_latest_stable(chart: str, repo_url: str) -> Optional[str]:
    alias = _helm_ensure_repo(repo_url)
    result = subprocess.run(
        ["helm", "search", "repo", f"{alias}/{chart}", "--versions", "--output", "json"],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode != 0 or not result.stdout.strip():
        return None
    try:
        entries = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    stable = [e for e in entries if not is_prerelease(e.get("version", ""))]
    if not stable:
        stable = entries
    stable.sort(key=lambda e: parse_version(e.get("version", "0")), reverse=True)
    return stable[0].get("version") if stable else None


# ---------------------------------------------------------------------------
# ArgoCD app YAML parsing
# ---------------------------------------------------------------------------

def get_helm_current_version(app_file: str, source_index: Optional[int]) -> Optional[str]:
    path = REPO_ROOT / app_file
    with open(path) as f:
        doc = yaml.safe_load(f)
    spec = doc.get("spec", {})
    if source_index is not None:
        sources = spec.get("sources", [])
        if source_index < len(sources):
            return sources[source_index].get("targetRevision")
    else:
        return spec.get("source", {}).get("targetRevision")
    return None


# ---------------------------------------------------------------------------
# Image version lookup
# ---------------------------------------------------------------------------

def get_image_current_version(image_files: list[str], pattern: str) -> tuple[Optional[str], Optional[str]]:
    """Returns (version, first_file_containing_it)."""
    for rel_path in image_files:
        path = REPO_ROOT / rel_path
        if not path.exists():
            continue
        m = re.search(pattern, path.read_text())
        if m:
            return m.group(1), rel_path
    return None, None


def github_latest_release(repo: str, prerelease_ok: bool = False) -> Optional[str]:
    url = f"https://api.github.com/repos/{repo}/releases?per_page=30"
    headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
    if token := os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {token}"
    try:
        resp = httpx.get(url, headers=headers, timeout=15, follow_redirects=True)
        if resp.status_code != 200:
            return None
        releases = resp.json()
    except Exception as e:
        log.warning("GitHub releases fetch failed for %s: %s", repo, e)
        return None

    stable = [r for r in releases
              if not r.get("prerelease") and not r.get("draft")
              and not is_prerelease(r.get("tag_name", ""))]
    if not stable:
        return None
    stable.sort(key=lambda r: parse_version(r.get("tag_name", "0")), reverse=True)
    return stable[0].get("tag_name")


def dockerhub_latest(image: str) -> Optional[str]:
    url = f"https://hub.docker.com/v2/repositories/{image}/tags?page_size=50&ordering=last_updated"
    try:
        resp = httpx.get(url, timeout=15, follow_redirects=True)
        if resp.status_code != 200:
            return None
        candidates = [t["name"] for t in resp.json().get("results", [])
                      if re.match(r"^\d+\.\d+\.\d+$", t.get("name", ""))
                      and not is_prerelease(t["name"])]
    except Exception as e:
        log.warning("Docker Hub fetch failed for %s: %s", image, e)
        return None
    if not candidates:
        return None
    candidates.sort(key=parse_version, reverse=True)
    return candidates[0]


# ---------------------------------------------------------------------------
# Release notes
# ---------------------------------------------------------------------------

def fetch_release_notes(github_repo: str, current: str, latest: str,
                        prefix: str = "") -> str:
    url = f"https://api.github.com/repos/{github_repo}/releases?per_page=20"
    headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
    if token := os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {token}"
    try:
        resp = httpx.get(url, headers=headers, timeout=15, follow_redirects=True)
        if resp.status_code != 200:
            return f"(GitHub API returned {resp.status_code})"
        releases = resp.json()
    except Exception as e:
        return f"(Could not fetch: {e})"

    current_v = parse_version(current)
    latest_v  = parse_version(latest)
    relevant  = []
    for rel in releases:
        tag = rel.get("tag_name", "")
        tag_stripped = tag.lstrip("v")
        if prefix:
            tag_stripped = tag_stripped.removeprefix(prefix).lstrip("v")
        v = parse_version(tag_stripped)
        if v <= current_v or v > latest_v:
            continue
        body = rel.get("body", "").strip()
        relevant.append(f"### {tag}\n{body[:2000]}")

    return "\n\n".join(relevant) if relevant else "(No release notes found)"


# ---------------------------------------------------------------------------
# Claude decision
# ---------------------------------------------------------------------------

def ask_claude(c: UpgradeCandidate, client: anthropic.Anthropic) -> tuple[str, str]:
    bump = version_bump_type(c.current_version, c.latest_version)
    kind_label = "Helm chart" if c.kind == "helm" else "container image"

    runbook_section = (
        f"## Cluster-specific Upgrade Runbook:\n{c.runbook_content[:8000]}"
        if c.runbook_content else
        "## Cluster-specific Upgrade Runbook:\n(Not available for this service)"
    )

    prompt = f"""You are a Kubernetes homelab administrator reviewing an upgrade candidate.
Decide whether this upgrade can be applied automatically (AUTO) or requires manual review (NOTIFY).

## Service: {c.name}
## Type: {kind_label}
## Version change: {c.current_version} → {c.latest_version} ({bump} bump)

{runbook_section}

## Release Notes / Changelog:
{c.changelog[:6000]}

## Decision rules:
- AUTO: Patch bumps with no breaking changes in release notes. Minor bumps only if release notes
  explicitly contain no breaking changes AND no CRD migrations AND no configuration format changes.
- NOTIFY: Minor bumps with breaking changes, CRD schema changes, API removals, required migration
  steps, or anything the runbook marks as requiring manual intervention.
- NOTIFY: All major bumps without exception.
- NOTIFY: When release notes are unavailable and bump is minor or major.

Respond with JSON only, no other text:
{{
  "decision": "AUTO" | "NOTIFY",
  "reason": "One or two sentences explaining the decision.",
  "risks": ["specific risk 1", "specific risk 2"]
}}"""

    response = client.messages.create(
        model="claude-opus-4-8",
        max_tokens=512,
        thinking={"type": "adaptive"},
        messages=[{"role": "user", "content": prompt}]
    )

    text = next((b.text for b in response.content if b.type == "text"), "")

    try:
        clean = re.sub(r"```(?:json)?\n?", "", text).strip().rstrip("`")
        data  = json.loads(clean)
        decision = data.get("decision", "NOTIFY")
        reason   = data.get("reason", "")
        risks    = data.get("risks", [])
        if risks:
            reason += " Risks: " + "; ".join(risks)
        return decision, reason
    except json.JSONDecodeError:
        log.warning("Claude non-JSON response for %s: %s", c.name, text[:200])
        return "NOTIFY", f"Could not parse Claude response — manual review required."


# ---------------------------------------------------------------------------
# Git operations & Gitea PR
# ---------------------------------------------------------------------------

def apply_version_change(work_dir: Path, c: UpgradeCandidate) -> None:
    """Apply the version change in the working directory."""
    if c.kind == "helm":
        # Replace targetRevision in the ArgoCD app YAML
        for rel_path in c.files:
            path = work_dir / rel_path
            content = path.read_text()
            old_escaped = re.escape(c.current_version)
            updated = re.sub(
                rf"(targetRevision:\s*[\"']?){old_escaped}([\"']?)",
                lambda m: f"{m.group(1)}{c.latest_version}{m.group(2)}",
                content, count=1
            )
            if updated == content:
                raise ValueError(f"{c.current_version} not found in {rel_path}")
            path.write_text(updated)
    else:
        # Replace image tag in manifest file(s)
        for rel_path in c.files:
            path = work_dir / rel_path
            content = path.read_text()
            updated = re.sub(
                c.image_pattern,
                lambda m: m.group(0).replace(c.current_version, c.latest_version),
                content
            )
            if updated == content:
                raise ValueError(f"Image tag {c.current_version} not found via pattern in {rel_path}")
            path.write_text(updated)


def create_pr(c: UpgradeCandidate) -> Optional[str]:
    """Clone repo, apply change, push branch, open Gitea PR."""
    gitea_token = _read_secret(SECRETS_DIR / "gitea-token", "GITEA_TOKEN")
    if not gitea_token and not DRY_RUN:
        log.error("GITEA_TOKEN not available — skipping PR for %s", c.name)
        return None

    branch = f"chore/upgrade-{c.name}-{c.latest_version.lstrip('v')}"
    bump   = version_bump_type(c.current_version, c.latest_version)

    if DRY_RUN:
        log.info("[DRY RUN] Would create PR branch %s for %s", branch, c.name)
        return None

    work_dir = Path(tempfile.mkdtemp(prefix="upgrade-agent-"))
    try:
        # Build HTTPS clone URL with embedded token
        https_url = f"https://upgrade-agent:{gitea_token}@{GITEA_BASE_URL.removeprefix('https://')}/{GITEA_REPO}.git"

        log.info("Cloning repo for %s...", c.name)
        result = subprocess.run(
            ["git", "clone", "--depth=1", https_url, str(work_dir / "repo")],
            capture_output=True, text=True, timeout=120
        )
        if result.returncode != 0:
            log.error("git clone failed: %s", result.stderr.strip())
            return None

        repo_dir = work_dir / "repo"
        git = ["git", "-C", str(repo_dir)]

        subprocess.run(git + ["config", "user.email", "upgrade-agent@reckeweg.io"], check=True, capture_output=True)
        subprocess.run(git + ["config", "user.name", "Upgrade Agent"], check=True, capture_output=True)
        subprocess.run(git + ["checkout", "-b", branch], check=True, capture_output=True)

        apply_version_change(repo_dir, c)

        for rel_path in c.files:
            subprocess.run(git + ["add", rel_path], check=True, capture_output=True)

        commit_msg = (
            f"chore: upgrade {c.name} {c.current_version} → {c.latest_version}\n\n"
            f"Auto-upgrade ({bump} bump) by upgrade-agent.\n"
            f"Assessment: {c.decision_reason}"
        )
        subprocess.run(git + ["commit", "-m", commit_msg], check=True, capture_output=True)
        subprocess.run(git + ["push", "origin", branch], check=True, capture_output=True)

    except subprocess.CalledProcessError as e:
        log.error("Git operation failed for %s: %s", c.name,
                  e.stderr.decode() if e.stderr else str(e))
        return None
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)

    # Create Gitea PR via API
    pr_body = (
        f"## Auto-Upgrade: {c.name}\n\n"
        f"| Field | Value |\n|---|---|\n"
        f"| Type | `{c.kind}` |\n"
        f"| Bump | **{bump}** |\n"
        f"| From | `{c.current_version}` |\n"
        f"| To | `{c.latest_version}` |\n"
        f"| Files | {', '.join(f'`{f}`' for f in c.files)} |\n\n"
        f"**Claude assessment:** {c.decision_reason}\n\n"
        f"---\n_Auto-created by upgrade-agent. Review, test, merge or close._"
    )
    api_url = f"{GITEA_BASE_URL}/api/v1/repos/{GITEA_REPO}/pulls"
    try:
        resp = httpx.post(
            api_url,
            headers={"Authorization": f"token {gitea_token}", "Content-Type": "application/json"},
            json={
                "title": f"chore: upgrade {c.name} to {c.latest_version}",
                "body": pr_body,
                "head": branch,
                "base": "main",
            },
            timeout=15
        )
        if resp.status_code in (200, 201):
            pr_url = resp.json().get("html_url", "")
            log.info("PR created: %s", pr_url)
            return pr_url
        log.error("Gitea PR API error %s: %s", resp.status_code, resp.text[:200])
        return branch
    except Exception as e:
        log.error("Failed to create Gitea PR: %s", e)
        return branch


# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------

def send_telegram(message: str) -> None:
    token = _read_secret(ALERTMANAGER_DIR / "telegram-bot-token", "TELEGRAM_BOT_TOKEN")
    if not token:
        log.warning("Telegram bot token not available")
        return
    if DRY_RUN:
        log.info("[DRY RUN] Telegram: %s", message[:120])
        return
    try:
        resp = httpx.post(
            f"https://api.telegram.org/bot{token}/sendMessage",
            json={"chat_id": TELEGRAM_CHAT_ID, "text": message, "parse_mode": "HTML"},
            timeout=10
        )
        if resp.status_code != 200:
            log.warning("Telegram error: %s", resp.text[:100])
    except Exception as e:
        log.warning("Telegram send failed: %s", e)


def send_email(subject: str, body: str) -> None:
    password = _read_secret(ALERTMANAGER_DIR / "gmail-password", "SMTP_PASSWORD")
    if not password:
        log.warning("Gmail password not available")
        return
    if DRY_RUN:
        log.info("[DRY RUN] Email: %s", subject)
        return
    msg = MIMEMultipart("alternative")
    msg["Subject"], msg["From"], msg["To"] = subject, SMTP_USER, NOTIFY_EMAIL
    msg.attach(MIMEText(body, "plain"))
    try:
        with smtplib.SMTP("smtp.gmail.com", 587) as s:
            s.ehlo(); s.starttls(); s.login(SMTP_USER, password)
            s.sendmail(SMTP_USER, NOTIFY_EMAIL, msg.as_string())
        log.info("Email sent: %s", subject)
    except Exception as e:
        log.warning("Email send failed: %s", e)


def notify_manual_review(c: UpgradeCandidate) -> None:
    bump = version_bump_type(c.current_version, c.latest_version)
    runbook_url = f"{GITEA_BASE_URL}/{GITEA_REPO}/src/branch/main/{c.runbook}" if c.runbook else "(no runbook)"
    subject = f"[Homelab] Manual upgrade needed: {c.name} {c.latest_version}"
    body = (
        f"Service:  {c.name}\n"
        f"Type:     {c.kind}\n"
        f"Bump:     {bump} ({c.current_version} → {c.latest_version})\n\n"
        f"Reason:   {c.decision_reason}\n\n"
        f"Runbook:  {runbook_url}\n\n"
        f"Release notes:\n{c.changelog[:1500]}"
    )
    tg = (
        f"<b>🔔 Manual upgrade needed</b>\n"
        f"<b>{c.name}</b>: {c.current_version} → {c.latest_version} ({bump})\n"
        f"<i>{c.decision_reason[:300]}</i>"
        + (f"\nRunbook: {runbook_url}" if c.runbook else "")
    )
    send_email(subject, body)
    send_telegram(tg)


def notify_auto_pr(c: UpgradeCandidate, pr_url: Optional[str]) -> None:
    bump = version_bump_type(c.current_version, c.latest_version)
    link = pr_url or "(PR creation failed — check logs)"
    send_telegram(
        f"<b>✅ Auto-upgrade PR created</b>\n"
        f"<b>{c.name}</b>: {c.current_version} → {c.latest_version} ({bump})\n"
        f"<i>{c.decision_reason[:200]}</i>\nPR: {link}"
    )


def notify_all_current() -> None:
    send_telegram("✅ <b>Upgrade Agent</b>: All services are up to date.")


# ---------------------------------------------------------------------------
# Check functions
# ---------------------------------------------------------------------------

def check_helm_services() -> list[UpgradeCandidate]:
    candidates = []
    for svc in HELM_SERVICES:
        name = svc["name"]
        try:
            current = get_helm_current_version(svc["app_file"], svc.get("source_index"))
            if not current:
                log.warning("%s: could not read current version", name)
                continue
            latest = helm_latest_stable(svc["chart"], svc["repo_url"])
            if not latest:
                log.warning("%s: could not fetch latest version from Helm repo", name)
                continue
            if parse_version(current) >= parse_version(latest):
                log.info("%s (helm): up to date (%s)", name, current)
                continue
            log.info("%s (helm): update available %s → %s", name, current, latest)
            candidates.append(UpgradeCandidate(
                name=name, kind="helm",
                files=[svc["app_file"]],
                current_version=current, latest_version=latest,
                github_repo=svc.get("github_repo", ""),
                github_release_prefix=svc.get("github_release_prefix", ""),
                runbook=svc.get("runbook", ""),
            ))
        except Exception as e:
            log.error("%s (helm): error during check: %s", name, e)
    return candidates


def check_image_services() -> list[UpgradeCandidate]:
    candidates = []
    for svc in IMAGE_SERVICES:
        name = svc["name"]
        try:
            current, found_in = get_image_current_version(svc["image_files"], svc["image_pattern"])
            if not current:
                log.warning("%s: could not read current image tag", name)
                continue

            if svc["version_type"] == "ghcr":
                raw_latest = github_latest_release(svc["github_repo"])
                latest = raw_latest.lstrip("v") if raw_latest else None
                # Preserve 'v' prefix style from current tag
                if latest and current.startswith("v"):
                    latest = "v" + latest
            else:
                latest = dockerhub_latest(svc["dockerhub_image"])

            if not latest:
                log.warning("%s: could not fetch latest image version", name)
                continue

            current_cmp = current.lstrip("v")
            latest_cmp  = latest.lstrip("v")

            if parse_version(current_cmp) >= parse_version(latest_cmp):
                log.info("%s (image): up to date (%s)", name, current)
                continue

            log.info("%s (image): update available %s → %s", name, current, latest)
            candidates.append(UpgradeCandidate(
                name=name, kind="image",
                files=[found_in] if found_in else svc["image_files"],
                current_version=current, latest_version=latest,
                github_repo=svc.get("github_repo", ""),
                runbook=svc.get("runbook", ""),
                image_pattern=svc["image_pattern"],
            ))
        except Exception as e:
            log.error("%s (image): error during check: %s", name, e)
    return candidates


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def check_dependencies() -> None:
    missing = [t for t in ["helm", "git"] if subprocess.run(
        ["which", t], capture_output=True).returncode != 0]
    if missing:
        log.error("Required tools not found: %s", ", ".join(missing))
        sys.exit(1)

    anthropic_key = _read_secret(SECRETS_DIR / "anthropic-api-key", "ANTHROPIC_API_KEY")
    if not anthropic_key:
        log.error("Anthropic API key not found (secret file or ANTHROPIC_API_KEY env var)")
        sys.exit(1)


def main() -> None:
    check_dependencies()

    anthropic_key = _read_secret(SECRETS_DIR / "anthropic-api-key", "ANTHROPIC_API_KEY")
    client = anthropic.Anthropic(api_key=anthropic_key)

    log.info("=== Upgrade Agent starting (DRY_RUN=%s) ===", DRY_RUN)
    log.info("Checking %d Helm services and %d image services...",
             len(HELM_SERVICES), len(IMAGE_SERVICES))

    candidates: list[UpgradeCandidate] = []
    candidates.extend(check_helm_services())
    candidates.extend(check_image_services())

    if not candidates:
        log.info("All services are up to date.")
        notify_all_current()
        return

    log.info("Found %d update(s). Fetching release notes and asking Claude...", len(candidates))

    for c in candidates:
        # Load runbook if available
        if c.runbook:
            runbook_path = REPO_ROOT / c.runbook
            if runbook_path.exists():
                c.runbook_content = runbook_path.read_text()[:10000]

        # Fetch release notes from GitHub
        if c.github_repo:
            c.changelog = fetch_release_notes(
                c.github_repo, c.current_version, c.latest_version, c.github_release_prefix
            )

        # Claude decision
        log.info("Asking Claude about %s (%s → %s)...",
                 c.name, c.current_version, c.latest_version)
        try:
            c.decision, c.decision_reason = ask_claude(c, client)
        except Exception as e:
            log.error("Claude API error for %s: %s — defaulting to NOTIFY", c.name, e)
            c.decision = "NOTIFY"
            c.decision_reason = f"Claude API unavailable ({e}) — manual review required."

        log.info("%s → %s: %s", c.name, c.decision, c.decision_reason[:100])

    # Act
    auto_count = notify_count = 0
    for c in candidates:
        if c.decision == "AUTO":
            pr_url = create_pr(c)
            notify_auto_pr(c, pr_url)
            auto_count += 1
        else:
            notify_manual_review(c)
            notify_count += 1

    log.info("=== Done. Auto-PRs: %d | Manual notifications: %d ===",
             auto_count, notify_count)


if __name__ == "__main__":
    main()
