#!/usr/bin/env python3
"""
Upgrade Agent for seri-infrastructure-complete.

Checks Helm chart versions, reads upgrade runbooks, uses Claude to decide
whether an upgrade is safe for auto-PR or needs manual review with notification.

Required environment variables:
  ANTHROPIC_API_KEY     - Claude API key (console.anthropic.com)
  GITEA_TOKEN           - Gitea API token with repo write access
  TELEGRAM_BOT_TOKEN    - Telegram bot token for notifications
  SMTP_PASSWORD         - Gmail app password for email notifications

Optional:
  GITEA_BASE_URL        - Default: https://gitea.reckeweg.io
  GITEA_REPO            - Default: achim/homelab-infrastructure
  TELEGRAM_CHAT_ID      - Default: 8677165142
  SMTP_USER             - Default: achim.reckeweg@gmail.com
  NOTIFY_EMAIL          - Default: achim.reckeweg@gmail.com
  DRY_RUN               - Set to "true" to skip git push and PR/notification
"""

import os
import re
import sys
import json
import subprocess
import smtplib
import logging
from dataclasses import dataclass, field
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
APPS_DIR = REPO_ROOT / "gitops" / "apps"
RUNBOOKS_DIR = REPO_ROOT / "docs" / "upgrades"

GITEA_BASE_URL = os.environ.get("GITEA_BASE_URL", "https://gitea.reckeweg.io")
GITEA_REPO = os.environ.get("GITEA_REPO", "achim/homelab-infrastructure")
TELEGRAM_CHAT_ID = int(os.environ.get("TELEGRAM_CHAT_ID", "8677165142"))
SMTP_USER = os.environ.get("SMTP_USER", "achim.reckeweg@gmail.com")
NOTIFY_EMAIL = os.environ.get("NOTIFY_EMAIL", "achim.reckeweg@gmail.com")
DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"

# Services to track: app_file is relative to REPO_ROOT
SERVICES = [
    {
        "name": "metrics-server",
        "app_file": "gitops/apps/metrics-server.yaml",
        "chart": "metrics-server",
        "repo_url": "https://kubernetes-sigs.github.io/metrics-server/",
        "runbook": "docs/upgrades/metrics-server-upgrade-runbook.md",
        "github_repo": "kubernetes-sigs/metrics-server",
        "source_index": None,  # single source
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
        "source_index": 0,  # first source in multi-source app
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
        "repo_url": "https://bitnami-labs.github.io/sealed-secrets/",  # trailing slash required
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
        "source_index": 0,  # first source in multi-source app
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
    app_file: str
    chart: str
    repo_url: str
    runbook: str
    github_repo: str
    current_version: str
    latest_version: str
    source_index: Optional[int]
    github_release_prefix: str = ""
    runbook_content: str = ""
    changelog: str = ""
    decision: str = ""          # AUTO, NOTIFY, SKIP
    decision_reason: str = ""


# ---------------------------------------------------------------------------
# Version utilities
# ---------------------------------------------------------------------------

def parse_version(version: str) -> tuple[int, ...]:
    """Extract numeric components from a version string."""
    clean = version.lstrip("v")
    parts = re.findall(r"\d+", clean)
    return tuple(int(p) for p in parts[:3]) if parts else (0,)


def version_bump_type(old: str, new: str) -> str:
    """Return 'patch', 'minor', or 'major'."""
    o = parse_version(old)
    n = parse_version(new)
    if len(o) < 3:
        o = o + (0,) * (3 - len(o))
    if len(n) < 3:
        n = n + (0,) * (3 - len(n))

    if n[0] != o[0]:
        return "major"
    if n[1] != o[1]:
        return "minor"
    return "patch"


# ---------------------------------------------------------------------------
# Helm version lookup
# ---------------------------------------------------------------------------

def get_latest_helm_version(chart: str, repo_url: str) -> Optional[str]:
    """Use helm show chart to get the latest available version."""
    try:
        result = subprocess.run(
            ["helm", "show", "chart", chart, "--repo", repo_url],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            log.warning("helm show chart failed for %s: %s", chart, result.stderr.strip())
            return None
        data = yaml.safe_load(result.stdout)
        return data.get("version")
    except (subprocess.TimeoutExpired, Exception) as e:
        log.warning("Failed to get latest version for %s: %s", chart, e)
        return None


# ---------------------------------------------------------------------------
# ArgoCD app YAML parsing
# ---------------------------------------------------------------------------

def get_current_version(app_file: str, source_index: Optional[int]) -> Optional[str]:
    """Read targetRevision from an ArgoCD Application YAML."""
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


def set_version_in_file(app_file: str, old_version: str, new_version: str) -> None:
    """Replace targetRevision in the app YAML file (in-place)."""
    path = REPO_ROOT / app_file
    content = path.read_text()
    # Escape dots and optional leading 'v' prefix
    old_escaped = re.escape(old_version)
    # Replace exactly — match the version value in targetRevision lines
    updated = re.sub(
        rf'(targetRevision:\s*["\']?){old_escaped}(["\']?)',
        lambda m: f'{m.group(1)}{new_version}{m.group(2)}',
        content,
        count=1
    )
    if updated == content:
        raise ValueError(f"Version {old_version} not found in {app_file}")
    path.write_text(updated)


# ---------------------------------------------------------------------------
# GitHub release notes
# ---------------------------------------------------------------------------

def fetch_github_releases(github_repo: str, current: str, latest: str,
                           prefix: str = "") -> str:
    """Fetch release notes between current and latest from GitHub API."""
    url = f"https://api.github.com/repos/{github_repo}/releases"
    headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
    github_token = os.environ.get("GITHUB_TOKEN")
    if github_token:
        headers["Authorization"] = f"Bearer {github_token}"

    try:
        resp = httpx.get(url, headers=headers, params={"per_page": 20}, timeout=15)
        if resp.status_code != 200:
            return f"(GitHub API returned {resp.status_code})"
        releases = resp.json()
    except Exception as e:
        return f"(Could not fetch releases: {e})"

    current_clean = current.lstrip("v")
    latest_clean = latest.lstrip("v")

    relevant = []
    for rel in releases:
        tag = rel.get("tag_name", "").lstrip("v")
        if prefix:
            tag = tag.removeprefix(prefix)
        tag = tag.lstrip("v")
        if tag == current_clean:
            break
        if parse_version(tag) <= parse_version(current_clean):
            continue
        if parse_version(tag) > parse_version(latest_clean):
            continue
        body = rel.get("body", "").strip()
        relevant.append(f"### {rel.get('tag_name')}\n{body[:2000]}")

    if not relevant:
        return "(No release notes found between current and latest version)"
    return "\n\n".join(relevant)


# ---------------------------------------------------------------------------
# Claude decision
# ---------------------------------------------------------------------------

def ask_claude(candidate: UpgradeCandidate, client: anthropic.Anthropic) -> tuple[str, str]:
    """
    Ask Claude whether this upgrade is safe to auto-apply.
    Returns (decision, reason) where decision is AUTO, NOTIFY, or SKIP.
    """
    bump = version_bump_type(candidate.current_version, candidate.latest_version)

    prompt = f"""You are an expert Kubernetes homelab administrator reviewing a Helm chart upgrade.
Your job is to decide whether this upgrade can be applied automatically or requires manual review.

## Service: {candidate.name}
## Chart: {candidate.chart}
## Version change: {candidate.current_version} → {candidate.latest_version} ({bump} bump)

## Upgrade Runbook (cluster-specific notes):
{candidate.runbook_content[:8000]}

## Release Notes / Changelog:
{candidate.changelog[:6000]}

## Decision criteria:
- AUTO: Patch bumps with no breaking changes in release notes. Minor bumps that the runbook explicitly marks as low-risk and no CRD migrations.
- NOTIFY: Minor bumps with breaking changes, CRD changes, API removals, or anything the runbook marks as requiring manual steps. Also minor bumps where release notes mention schema changes, migration scripts, or configuration format changes.
- NOTIFY: Major bumps always.
- SKIP: If latest version is same as current (should not happen here, but be safe).

Respond with a JSON object only, no other text:
{{
  "decision": "AUTO" | "NOTIFY" | "SKIP",
  "reason": "One or two sentences explaining why.",
  "risks": ["list", "of", "specific", "risks", "if", "NOTIFY"]
}}"""

    response = client.messages.create(
        model="claude-opus-4-8",
        max_tokens=512,
        thinking={"type": "adaptive"},
        messages=[{"role": "user", "content": prompt}]
    )

    text = ""
    for block in response.content:
        if block.type == "text":
            text = block.text
            break

    try:
        # Strip markdown code fences if present
        clean = re.sub(r"```(?:json)?\n?", "", text).strip()
        data = json.loads(clean)
        decision = data.get("decision", "NOTIFY")
        risks = data.get("risks", [])
        reason = data.get("reason", "")
        if risks:
            reason += " Risks: " + "; ".join(risks)
        return decision, reason
    except json.JSONDecodeError:
        log.warning("Claude returned non-JSON for %s: %s", candidate.name, text)
        return "NOTIFY", f"Claude response could not be parsed. Manual review needed. Raw: {text[:200]}"


# ---------------------------------------------------------------------------
# Git + Gitea PR
# ---------------------------------------------------------------------------

def create_pr(candidate: UpgradeCandidate) -> Optional[str]:
    """Create a git branch, commit the version bump, push, and open a Gitea PR."""
    branch = f"chore/upgrade-{candidate.name}-{candidate.latest_version}"
    app_path = REPO_ROOT / candidate.app_file

    if DRY_RUN:
        log.info("[DRY RUN] Would create PR: %s → %s (%s)",
                 candidate.current_version, candidate.latest_version, candidate.name)
        return None

    try:
        # Ensure we're on main and up-to-date
        subprocess.run(["git", "-C", str(REPO_ROOT), "checkout", "main"],
                       check=True, capture_output=True)
        subprocess.run(["git", "-C", str(REPO_ROOT), "pull", "--ff-only"],
                       check=True, capture_output=True)

        # Create branch
        subprocess.run(["git", "-C", str(REPO_ROOT), "checkout", "-b", branch],
                       check=True, capture_output=True)

        # Apply version change
        set_version_in_file(candidate.app_file, candidate.current_version, candidate.latest_version)

        # Commit
        rel_path = candidate.app_file
        subprocess.run(
            ["git", "-C", str(REPO_ROOT), "add", rel_path],
            check=True, capture_output=True
        )
        msg = (f"chore: upgrade {candidate.name} "
               f"{candidate.current_version} → {candidate.latest_version}\n\n"
               f"Auto-upgrade by upgrade-agent.\n"
               f"Reason: {candidate.decision_reason}")
        subprocess.run(
            ["git", "-C", str(REPO_ROOT), "commit", "-m", msg],
            check=True, capture_output=True
        )

        # Push to both remotes
        for remote in ["origin", "github"]:
            result = subprocess.run(
                ["git", "-C", str(REPO_ROOT), "remote", "get-url", remote],
                capture_output=True
            )
            if result.returncode == 0:
                subprocess.run(
                    ["git", "-C", str(REPO_ROOT), "push", remote, branch],
                    check=True, capture_output=True
                )

        # Return to main
        subprocess.run(["git", "-C", str(REPO_ROOT), "checkout", "main"],
                       check=True, capture_output=True)

    except subprocess.CalledProcessError as e:
        log.error("Git operation failed: %s", e.stderr.decode() if e.stderr else e)
        subprocess.run(["git", "-C", str(REPO_ROOT), "checkout", "main"],
                       capture_output=True)
        return None

    # Create Gitea PR via API
    token = os.environ.get("GITEA_TOKEN", "")
    if not token:
        log.warning("GITEA_TOKEN not set, skipping PR creation")
        return branch

    bump = version_bump_type(candidate.current_version, candidate.latest_version)
    pr_body = (
        f"## Auto-Upgrade: {candidate.name}\n\n"
        f"| | |\n|---|---|\n"
        f"| Chart | `{candidate.chart}` |\n"
        f"| Bump type | **{bump}** |\n"
        f"| From | `{candidate.current_version}` |\n"
        f"| To | `{candidate.latest_version}` |\n\n"
        f"**Claude assessment:** {candidate.decision_reason}\n\n"
        f"---\n"
        f"_Created automatically by upgrade-agent. Review, merge, or close._"
    )

    api_url = f"{GITEA_BASE_URL}/api/v1/repos/{GITEA_REPO}/pulls"
    try:
        resp = httpx.post(
            api_url,
            headers={
                "Authorization": f"token {token}",
                "Content-Type": "application/json",
            },
            json={
                "title": f"chore: upgrade {candidate.name} to {candidate.latest_version}",
                "body": pr_body,
                "head": branch,
                "base": "main",
                "labels": [],
            },
            timeout=15
        )
        if resp.status_code in (200, 201):
            pr_url = resp.json().get("html_url", "")
            log.info("PR created: %s", pr_url)
            return pr_url
        else:
            log.error("Gitea API error %s: %s", resp.status_code, resp.text[:200])
            return branch
    except Exception as e:
        log.error("Failed to create Gitea PR: %s", e)
        return branch


# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------

def send_telegram(message: str) -> None:
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    if not token:
        log.warning("TELEGRAM_BOT_TOKEN not set, skipping Telegram notification")
        return
    if DRY_RUN:
        log.info("[DRY RUN] Telegram: %s", message[:100])
        return

    url = f"https://api.telegram.org/bot{token}/sendMessage"
    try:
        resp = httpx.post(url, json={
            "chat_id": TELEGRAM_CHAT_ID,
            "text": message,
            "parse_mode": "HTML",
        }, timeout=10)
        if resp.status_code != 200:
            log.warning("Telegram API error: %s", resp.text[:100])
    except Exception as e:
        log.warning("Telegram send failed: %s", e)


def send_email(subject: str, body: str) -> None:
    password = os.environ.get("SMTP_PASSWORD", "")
    if not password:
        log.warning("SMTP_PASSWORD not set, skipping email notification")
        return
    if DRY_RUN:
        log.info("[DRY RUN] Email: %s", subject)
        return

    msg = MIMEMultipart("alternative")
    msg["Subject"] = subject
    msg["From"] = SMTP_USER
    msg["To"] = NOTIFY_EMAIL
    msg.attach(MIMEText(body, "plain"))

    try:
        with smtplib.SMTP("smtp.gmail.com", 587) as server:
            server.ehlo()
            server.starttls()
            server.login(SMTP_USER, password)
            server.sendmail(SMTP_USER, NOTIFY_EMAIL, msg.as_string())
        log.info("Email sent: %s", subject)
    except Exception as e:
        log.warning("Email send failed: %s", e)


def notify_manual_review(candidate: UpgradeCandidate) -> None:
    bump = version_bump_type(candidate.current_version, candidate.latest_version)
    subject = f"[Homelab] Manual upgrade needed: {candidate.name} {candidate.latest_version}"
    body = (
        f"Service: {candidate.name}\n"
        f"Chart:   {candidate.chart}\n"
        f"Bump:    {bump} ({candidate.current_version} → {candidate.latest_version})\n\n"
        f"Reason:  {candidate.decision_reason}\n\n"
        f"Runbook: {GITEA_BASE_URL}/{GITEA_REPO}/src/branch/main/{candidate.runbook}\n\n"
        f"Release notes:\n{candidate.changelog[:1500]}"
    )

    tg_message = (
        f"<b>🔔 Manual upgrade needed</b>\n"
        f"<b>{candidate.name}</b>: {candidate.current_version} → {candidate.latest_version} ({bump})\n"
        f"<i>{candidate.decision_reason[:300]}</i>\n\n"
        f"Runbook: {GITEA_BASE_URL}/{GITEA_REPO}/src/branch/main/{candidate.runbook}"
    )

    send_email(subject, body)
    send_telegram(tg_message)


def notify_auto_pr(candidate: UpgradeCandidate, pr_url: Optional[str]) -> None:
    bump = version_bump_type(candidate.current_version, candidate.latest_version)
    link = pr_url or "(PR creation failed — check logs)"
    tg_message = (
        f"<b>✅ Auto-upgrade PR created</b>\n"
        f"<b>{candidate.name}</b>: {candidate.current_version} → {candidate.latest_version} ({bump})\n"
        f"<i>{candidate.decision_reason[:200]}</i>\n"
        f"PR: {link}"
    )
    send_telegram(tg_message)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def check_dependencies() -> None:
    for dep in ["helm", "git"]:
        result = subprocess.run(["which", dep], capture_output=True)
        if result.returncode != 0:
            log.error("Required tool not found: %s", dep)
            sys.exit(1)

    if not os.environ.get("ANTHROPIC_API_KEY"):
        log.error("ANTHROPIC_API_KEY is not set")
        sys.exit(1)


def main() -> None:
    check_dependencies()

    client = anthropic.Anthropic(api_key=os.environ["ANTHROPIC_API_KEY"])

    candidates: list[UpgradeCandidate] = []

    log.info("Checking %d services for updates...", len(SERVICES))

    for svc in SERVICES:
        name = svc["name"]
        try:
            current = get_current_version(svc["app_file"], svc.get("source_index"))
            if not current:
                log.warning("Could not read current version for %s", name)
                continue

            latest = get_latest_helm_version(svc["chart"], svc["repo_url"])
            if not latest:
                log.warning("Could not fetch latest version for %s", name)
                continue

            current_clean = current.lstrip("v")
            latest_clean = latest.lstrip("v")

            if parse_version(current_clean) >= parse_version(latest_clean):
                log.info("%s: up to date (%s)", name, current)
                continue

            log.info("%s: update available %s → %s", name, current, latest)
            candidates.append(UpgradeCandidate(
                name=name,
                app_file=svc["app_file"],
                chart=svc["chart"],
                repo_url=svc["repo_url"],
                runbook=svc["runbook"],
                github_repo=svc["github_repo"],
                current_version=current,
                latest_version=latest,
                source_index=svc.get("source_index"),
                github_release_prefix=svc.get("github_release_prefix", ""),
            ))
        except Exception as e:
            log.error("Error checking %s: %s", name, e)

    if not candidates:
        log.info("All services are up to date. Nothing to do.")
        send_telegram("✅ <b>Upgrade Agent</b>: All Helm charts are up to date.")
        return

    log.info("Found %d update(s). Fetching release notes and asking Claude...", len(candidates))

    for c in candidates:
        # Load runbook
        runbook_path = REPO_ROOT / c.runbook
        if runbook_path.exists():
            c.runbook_content = runbook_path.read_text()[:10000]
        else:
            log.warning("Runbook not found: %s", c.runbook)
            c.runbook_content = "(No runbook available)"

        # Fetch changelog
        c.changelog = fetch_github_releases(
            c.github_repo, c.current_version, c.latest_version, c.github_release_prefix
        )

        # Ask Claude
        log.info("Asking Claude about %s (%s → %s)...", c.name, c.current_version, c.latest_version)
        try:
            c.decision, c.decision_reason = ask_claude(c, client)
        except Exception as e:
            log.error("Claude API error for %s: %s — defaulting to NOTIFY", c.name, e)
            c.decision = "NOTIFY"
            c.decision_reason = f"Claude API unavailable: {e}"
        log.info("%s decision: %s — %s", c.name, c.decision, c.decision_reason[:100])

    # Act on decisions
    for c in candidates:
        if c.decision == "AUTO":
            log.info("Auto-upgrading %s...", c.name)
            pr_url = create_pr(c)
            notify_auto_pr(c, pr_url)

        elif c.decision == "NOTIFY":
            log.info("Sending manual review notification for %s...", c.name)
            notify_manual_review(c)

        else:
            log.info("Skipping %s (decision: %s)", c.name, c.decision)

    auto_count = sum(1 for c in candidates if c.decision == "AUTO")
    notify_count = sum(1 for c in candidates if c.decision == "NOTIFY")
    log.info("Done. Auto-PRs: %d, Manual notifications: %d", auto_count, notify_count)


if __name__ == "__main__":
    main()
