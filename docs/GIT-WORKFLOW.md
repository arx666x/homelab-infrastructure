# SERI Git Repository Update Guide

## Übersicht

Du hast ein **public GitHub Repo**: `https://github.com/arx666x/homelab-infrastructure.git`

Dieses Package enthält **komplett neue, korrigierte Manifeste** die alle Lessons Learned der letzten 24h enthalten.

---

## Option 1: Kompletter Replace (Empfohlen)

**Am saubersten** - lösche alles und ersetze mit neuen Manifesten.

### Schritt 1: Backup erstellen

```bash
cd ~/git/seri-infrastructure-complete

# Backup des aktuellen Stands
git checkout -b backup-before-clean-deploy
git push -u origin backup-before-clean-deploy
```

### Schritt 2: Alte Struktur löschen

```bash
# Zurück zu main
git checkout main

# Lösche alte gitops Struktur
rm -rf gitops/

# Kopiere neue Struktur
cp -r ~/Downloads/git-repo/gitops/ .
```

### Schritt 3: Commit & Push

```bash
# Status ansehen
git status

# Alles stagen
git add .

# Commit mit ausführlicher Message
git commit -m "refactor: Complete rewrite of GitOps manifests

BREAKING CHANGES:
- All manifests rewritten with lessons learned from deployment
- Added correct sync waves (MetalLB=0, cert-manager=1, Traefik=2, Longhorn=3, Prometheus=4)
- Fixed Longhorn ingress configuration (enabled with TLS)
- Fixed Prometheus/Grafana ingress with proper TLS setup
- Added ignoreDifferences for all webhook caBundle issues
- Removed NetworkPolicies that caused connectivity issues
- Optimized retry policies and backoff strategies

Fixes:
- DNS search domain problems
- VLAN static IP configuration
- ArgoCD health checks for Ingress ADDRESS
- Longhorn pre-upgrade hook issues
- Prometheus volume attachment problems

This is a complete, tested deployment configuration ready for production use."

# Push
git push origin main
```

---

## Option 2: Merge mit Historie (Komplizierter)

Falls du die Git-Historie behalten willst:

### Schritt 1: Feature Branch

```bash
cd ~/git/seri-infrastructure-complete

# Neuer Branch
git checkout -b feature/clean-deploy-manifests

# Lösche alte gitops
rm -rf gitops/

# Kopiere neue
cp -r ~/Downloads/git-repo/gitops/ .

# Commit
git add .
git commit -m "refactor: Complete GitOps manifest rewrite"

# Push
git push -u origin feature/clean-deploy-manifests
```

### Schritt 2: Pull Request auf GitHub

1. **GitHub → Pull Requests → New PR**
2. **Base:** `main` ← **Compare:** `feature/clean-deploy-manifests`
3. **Create PR** mit Beschreibung
4. **Merge PR**

---

## Option 3: Neues Repo (Nuclear Option)

Falls du komplett neu starten willst:

```bash
# Neues Repo auf GitHub erstellen
# Name: seri-infrastructure (ohne -complete)

# Lokal
cd ~/git
mkdir seri-infrastructure
cd seri-infrastructure

git init
git branch -M main

# Kopiere neue Struktur
cp -r ~/Downloads/git-repo/gitops/ .

# Initial Commit
git add .
git commit -m "feat: Initial SERI infrastructure GitOps repository"

# Remote
git remote add origin https://github.com/arx666x/seri-infrastructure.git
git push -u origin main
```

Dann in **allen Manifesten** `repoURL` ändern:
```yaml
repoURL: https://github.com/arx666x/seri-infrastructure.git
```

---

## Nach dem Push: Repo auf Private stellen

### GitHub Web UI:

1. **Repository → Settings**
2. **Danger Zone → Change visibility**
3. **Make private**
4. **Bestätigen**

### Wichtig nach Private:

ArgoCD braucht dann **Deploy Key** oder **Personal Access Token**:

```bash
# Deploy Key erstellen
ssh-keygen -t ed25519 -C "argocd-deploy-key" -f ~/.ssh/argocd-deploy

# Public Key zu GitHub hinzufügen
cat ~/.ssh/argocd-deploy.pub
# GitHub → Settings → Deploy keys → Add deploy key

# In ArgoCD registrieren
kubectl create secret generic repo-credentials \
  -n argocd \
  --from-file=sshPrivateKey=~/.ssh/argocd-deploy \
  --from-literal=url=git@github.com:arx666x/homelab-infrastructure.git
```

**ODER:** Behalte es **public** bis Gitea deployed ist, dann migriere.

---

## Empfehlung

**Option 1** (Complete Replace) ist am saubersten:
- ✅ Klare Git History
- ✅ Kein Merge-Konflikt
- ✅ Backup vorhanden (im branch)
- ✅ Schnell

**Backup Branch** kannst du später löschen wenn alles läuft.

---

## Verification

Nach dem Push:

```bash
# Prüfe ob alles committed ist
git status
# Sollte: "working tree clean"

# Prüfe Remote
git remote -v
# Sollte: origin  https://github.com/arx666x/homelab-infrastructure.git

# Prüfe Branch
git branch -a
# Sollte: * main (und evtl backup branch)
```

---

## Nächste Schritte

Nach erfolgreichem Push:

1. **Cleanup Script** ausführen
2. **Install Cluster Script** ausführen
3. **Install ArgoCD Script** ausführen
4. **Root App** deployen → Alles läuft automatisch

🎯 **Viel Erfolg!**
