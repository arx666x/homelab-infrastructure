#!/usr/bin/env bash
# =============================================================================
# deploy-argocd.sh
# Deployt Headlamp via ArgoCD:
#   1. RBAC (Namespace, ServiceAccount, ClusterRoleBinding)
#   2. ArgoCD Application -> ArgoCD übernimmt Helm-Deployment
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================================"
echo "  Headlamp Deployment via ArgoCD"
echo "============================================================"

# 1. Prüfe ob ArgoCD läuft
echo ""
echo ">>> Prüfe ArgoCD..."
kubectl get namespace argocd &>/dev/null || {
  echo "ERROR: Namespace 'argocd' nicht gefunden. Ist ArgoCD installiert?"
  exit 1
}

# 2. RBAC anlegen (Namespace + ServiceAccount + ClusterRoleBinding)
echo ""
echo ">>> RBAC anlegen..."
kubectl apply -f "${SCRIPT_DIR}/../gitops/config/headlamp/rbac.yaml"

# 3. ArgoCD Application anlegen
echo ""
echo ">>> ArgoCD Application deployen..."
kubectl apply -f "${SCRIPT_DIR}/../gitops/apps/headlamp.yaml"

# 4. Sync abwarten
echo ""
echo ">>> Warte auf ArgoCD Sync..."
sleep 5

# argocd CLI verwenden falls vorhanden, sonst kubectl polling
if command -v argocd &>/dev/null; then
  argocd app wait headlamp \
    --health \
    --sync \
    --timeout 300 \
    --grpc-web 2>/dev/null || echo "argocd CLI nicht eingeloggt – prüfe Status manuell."
else
  echo "argocd CLI nicht gefunden – warte auf Deployment via kubectl..."
  until kubectl get deployment headlamp -n headlamp &>/dev/null; do
    echo "  Warte auf Deployment-Objekt..."; sleep 5
  done
  kubectl rollout status deployment/headlamp -n headlamp --timeout=300s
fi

echo ""
echo ">>> Deployment erfolgreich!"
echo ""

# 5. Token generieren
echo ">>> Login-Token generieren..."
bash "${SCRIPT_DIR}/headlamp-token.sh"
