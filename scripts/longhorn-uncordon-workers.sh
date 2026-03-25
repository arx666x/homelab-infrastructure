#!/bin/bash
# longhorn-uncordon-workers.sh
# Nodes nach dem Netzteil-Tausch wieder in den Cluster aufnehmen.

set -euo pipefail

WORKERS=(k3s-01a k3s-02a k3s-03a k3s-04a k3s-05a)

echo "========================================"
echo " Phase 1: Warten bis alle Nodes Ready"
echo "========================================"
echo "Prüfe alle 10 Sekunden..."
while true; do
  not_ready=$(kubectl get nodes "${WORKERS[@]}" --no-headers \
    | grep -v " Ready" | wc -l | tr -d ' ')

  if [ "$not_ready" -eq 0 ]; then
    echo "  ✓ Alle Worker-Nodes sind Ready!"
    break
  fi
  echo "  → Noch $not_ready Node(s) nicht Ready ($(date +%H:%M:%S))"
  sleep 10
done

echo ""
echo "========================================"
echo " Phase 2: Longhorn Eviction zurücksetzen"
echo "========================================"
for node in "${WORKERS[@]}"; do
  disk=$(kubectl -n longhorn-system get node.longhorn.io/"$node" \
    -o jsonpath='{.spec.disks}' | jq -r 'keys[0]')
  echo "→ $node  (disk: $disk)"
  kubectl -n longhorn-system patch node.longhorn.io/"$node" \
    --type=merge \
    -p "{\"spec\":{
      \"allowScheduling\": true,
      \"evictionRequested\": false,
      \"disks\": {
        \"$disk\": {
          \"allowScheduling\": true,
          \"evictionRequested\": false
        }
      }
    }}"
done

echo ""
echo "========================================"
echo " Phase 3: Kubernetes Uncordon"
echo "========================================"
for node in "${WORKERS[@]}"; do
  echo "→ Uncordon $node"
  kubectl uncordon "$node"
done

echo ""
echo "========================================"
echo " Phase 4: Status prüfen"
echo "========================================"
echo ""
echo "--- Kubernetes Nodes ---"
kubectl get nodes -o wide

echo ""
echo "--- Longhorn Volumes ---"
kubectl -n longhorn-system get volumes 2>/dev/null || echo "(Longhorn API nicht erreichbar)"

echo ""
echo "--- ArgoCD Applications ---"
kubectl -n argocd get applications 2>/dev/null || echo "(ArgoCD nicht erreichbar)"

echo ""
echo "========================================"
echo " ✓ Fertig! Cluster läuft wieder normal."
echo "  Longhorn synchronisiert Replicas im Hintergrund."
echo "========================================"
