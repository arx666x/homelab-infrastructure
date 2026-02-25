#!/usr/bin/env bash
# =============================================================================
# headlamp-token.sh
# Generiert einen Login-Token für Headlamp (gültig 1 Jahr).
# Einmalig nach dem Deployment ausführen – Token dann im Browser eintippen.
# =============================================================================
set -euo pipefail

NAMESPACE="headlamp"
SA="headlamp"

echo ">>> Warte auf ServiceAccount '${SA}' im Namespace '${NAMESPACE}'..."
until kubectl get sa "${SA}" -n "${NAMESPACE}" &>/dev/null; do
  echo "  Noch nicht bereit, warte 3s..."; sleep 3
done

echo ""
echo ">>> Generiere Token (gültig 1 Jahr)..."
TOKEN=$(kubectl create token "${SA}" -n "${NAMESPACE}" --duration=8760h)

echo ""
echo "================================================================"
echo "  Headlamp Login Token"
echo "================================================================"
echo ""
echo "${TOKEN}"
echo ""
echo "================================================================"
echo "  URL:     https://headlamp.reckeweg.io"
echo "  Pi-hole: headlamp.reckeweg.io -> 192.168.20.100"
echo "================================================================"
