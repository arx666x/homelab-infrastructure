#!/bin/bash
set -e

echo "===================================================================="
echo "ArgoCD Installation - Final Version"
echo "===================================================================="

export KUBECONFIG=~/.kube/seri-homelab

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "\n${YELLOW}=== Installing ArgoCD ===${NC}\n"

kubectl create namespace argocd

kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.9.3/manifests/install.yaml

echo "Waiting for ArgoCD pods..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s

echo -e "\n${YELLOW}=== Patching ArgoCD Config ===${NC}\n"

# Ingress Health Check Patch
kubectl patch configmap argocd-cm -n argocd --type=merge -p='
data:
  resource.customizations.health.networking.k8s.io_Ingress: |
    hs = {}
    hs.status = "Healthy"
    hs.message = "Ingress is healthy"
    return hs
'

# Restart application controller
kubectl rollout restart statefulset/argocd-application-controller -n argocd

echo "Waiting for controller restart..."
sleep 30

ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

echo -e "\n${GREEN}===================================================================="
echo "ArgoCD Installation Complete!"
echo "====================================================================${NC}\n"

echo "ArgoCD Admin Credentials:"
echo "  Username: admin"
echo "  Password: $ARGOCD_PASSWORD"
echo ""
echo "Access ArgoCD UI:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:80"
echo "  http://localhost:8080"
echo ""
echo "Next Steps:"
echo "  1. Create Cloudflare API token secret"
echo "  2. Deploy infrastructure apps"
