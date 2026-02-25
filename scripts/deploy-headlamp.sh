#!/usr/bin/env bash
# =============================================================================
# deploy-headlamp.sh
# Deployt Headlamp auf dem homelab k3s Cluster.
# Legt RBAC + Manifeste an und registriert die ArgoCD Application.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "================================================================"
echo "  Headlamp Deployment – homelab.reckeweg.io"
echo "================================================================"

# 1. ArgoCD prüfen
echo ""
echo ">>> Prüfe ArgoCD..."
kubectl get namespace argocd &>/dev/null || {
  echo "ERROR: Namespace 'argocd' nicht gefunden. Ist ArgoCD installiert?"
  exit 1
}

# 2. RBAC vorab anlegen (ArgoCD braucht den Namespace schon beim ersten Sync)
echo ""
echo ">>> RBAC anlegen (Namespace, ServiceAccount, ClusterRoleBinding)..."
kubectl apply -f "${REPO_ROOT}/gitops/config/headlamp/rbac.yaml"

# 3. Manifeste direkt anwenden (Deployment, Service, Cert, Ingress)
echo ""
echo ">>> Headlamp Manifeste anwenden..."
kubectl apply -f "${REPO_ROOT}/gitops/config/headlamp/headlamp.yaml"

# 4. ArgoCD Application registrieren
echo ""
echo ">>> ArgoCD Application registrieren..."
kubectl apply -f "${REPO_ROOT}/gitops/apps/headlamp.yaml"

# 5. Deployment abwarten
echo ""
echo ">>> Warte auf Rollout..."
kubectl rollout status deployment/headlamp -n headlamp --timeout=180s

# 6. Token generieren
echo ""
bash "${SCRIPT_DIR}/headlamp-token.sh"
