#!/usr/bin/env bash
# =============================================================================
# cleanup-headlamp.sh
# Entfernt fehlgeschlagene Headlamp ArgoCD Applications und Kubernetes-Reste.
# Vor dem erneuten Deployment ausführen.
# =============================================================================
set -euo pipefail

echo "================================================================"
echo "  Headlamp – Cleanup fehlgeschlagener Deployments"
echo "================================================================"

# 1. ArgoCD Application entfernen (falls vorhanden)
echo ""
echo ">>> ArgoCD Application entfernen..."
if kubectl get application headlamp -n argocd &>/dev/null; then
  # Finalizer entfernen damit ArgoCD nicht auf Sync wartet
  kubectl patch application headlamp -n argocd \
    -p '{"metadata":{"finalizers":[]}}' \
    --type=merge
  kubectl delete application headlamp -n argocd
  echo "  Application 'headlamp' gelöscht."
else
  echo "  Keine ArgoCD Application 'headlamp' gefunden – ok."
fi

# 2. Namespace headlamp komplett löschen (räumt alle Ressourcen darin auf)
echo ""
echo ">>> Namespace 'headlamp' entfernen..."
if kubectl get namespace headlamp &>/dev/null; then
  kubectl delete namespace headlamp --timeout=60s
  echo "  Namespace 'headlamp' gelöscht."
else
  echo "  Namespace 'headlamp' nicht vorhanden – ok."
fi

# 3. ClusterRoleBinding entfernen (ist cluster-scoped, nicht im Namespace)
echo ""
echo ">>> ClusterRoleBinding entfernen..."
if kubectl get clusterrolebinding headlamp-cluster-admin &>/dev/null; then
  kubectl delete clusterrolebinding headlamp-cluster-admin
  echo "  ClusterRoleBinding 'headlamp-cluster-admin' gelöscht."
else
  echo "  ClusterRoleBinding nicht vorhanden – ok."
fi

# 4. Helm Releases aufräumen (falls ein Helm-Versuch stattfand)
echo ""
echo ">>> Prüfe auf verwaiste Helm Releases..."
for NS in headlamp kube-system default; do
  if helm list -n "${NS}" 2>/dev/null | grep -q headlamp; then
    echo "  Gefunden in Namespace '${NS}', wird entfernt..."
    helm uninstall headlamp -n "${NS}" || true
  fi
done
echo "  Helm-Check abgeschlossen."

echo ""
echo "================================================================"
echo "  Cleanup abgeschlossen."
echo "  Du kannst jetzt deploy-headlamp.sh ausführen."
echo "================================================================"
