#!/bin/bash
echo "=== Complete Longhorn Cleanup ==="

# 1. Helm Release löschen (falls vorhanden)
echo "Removing Helm release..."
helm uninstall longhorn -n longhorn-system --no-hooks || true

# 2. ArgoCD Application löschen (ghost state)
echo "Removing ArgoCD Application..."
kubectl get application longhorn -n argocd -o json | jq '.metadata.finalizers = []' > /tmp/longhorn-app.json
kubectl replace -f /tmp/longhorn-app.json || true
kubectl delete application longhorn -n argocd --force --grace-period=0 || true

# 3. Alle Longhorn CRs löschen
echo "Removing Longhorn Custom Resources..."
for crd in volumes engines replicas snapshots volumeattachments orphans backups backupvolumes \
           backingimages backingimagemanagers instancemanagers recurringjobs settings \
           sharemanagers supportbundles systembackups systemrestores nodes engineimages backuptargets; do
  echo "  Cleaning ${crd}..."
  kubectl get ${crd}.longhorn.io -n longhorn-system -o name 2>/dev/null | \
    xargs -I {} kubectl patch {} -n longhorn-system -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
  kubectl delete ${crd}.longhorn.io -n longhorn-system --all --force --grace-period=0 2>/dev/null || true
done

# 4. Webhooks löschen
echo "Removing webhooks..."
kubectl delete validatingwebhookconfiguration longhorn-webhook-validator --ignore-not-found=true
kubectl delete mutatingwebhookconfiguration longhorn-webhook-mutator --ignore-not-found=true

# 5. Namespace finalizers entfernen und löschen
echo "Removing namespace..."
kubectl patch namespace longhorn-system -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
kubectl delete namespace longhorn-system --force --grace-period=0 2>/dev/null || true

# Wait for namespace deletion
echo "Waiting for namespace deletion..."
for i in {1..30}; do
  if ! kubectl get namespace longhorn-system 2>/dev/null; then
    echo "Namespace deleted successfully"
    break
  fi
  echo "  Still deleting... ($i/30)"
  sleep 2
done

# Force delete if still there
if kubectl get namespace longhorn-system 2>/dev/null; then
  echo "Force deleting namespace via API..."
  kubectl get namespace longhorn-system -o json | jq '.spec.finalizers = []' | \
    kubectl replace --raw /api/v1/namespaces/longhorn-system/finalize -f - || true
fi

# 6. CRDs finalizers entfernen und löschen
echo "Removing CRDs..."
kubectl get crd -o name | grep longhorn | \
  xargs -I {} kubectl patch {} -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
kubectl delete crd -l app.kubernetes.io/name=longhorn --force --grace-period=0 2>/dev/null || true

# 7. ClusterRoles und ClusterRoleBindings
echo "Removing cluster-wide resources..."
kubectl delete clusterrole -l app.kubernetes.io/name=longhorn --ignore-not-found=true
kubectl delete clusterrolebinding -l app.kubernetes.io/name=longhorn --ignore-not-found=true

# Final verification
echo ""
echo "=== Cleanup Verification ==="
echo "Namespace:"
kubectl get namespace longhorn-system 2>&1 || echo "✓ Namespace deleted"
echo ""
echo "CRDs:"
kubectl get crd | grep longhorn || echo "✓ No Longhorn CRDs"
echo ""
echo "ArgoCD App:"
kubectl get application longhorn -n argocd 2>&1 || echo "✓ ArgoCD App deleted"
echo ""
echo "=== Cleanup Complete ==="

