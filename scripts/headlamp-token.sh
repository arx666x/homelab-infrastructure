#!/usr/bin/env bash
# =============================================================================
# headlamp-token.sh
# Erstellt einen langlebigen Token für den Headlamp ServiceAccount.
# Einmalig ausführen nach dem ersten Sync – Token dann im Browser eintippen.
# =============================================================================
set -euo pipefail

NAMESPACE="headlamp"
SA="headlamp"
DURATION="8760h"   # 1 Jahr

echo ">>> Warte bis ServiceAccount '${SA}' im Namespace '${NAMESPACE}' existiert..."
kubectl wait --for=condition=exists \
  serviceaccount/${SA} \
  -n ${NAMESPACE} \
  --timeout=120s 2>/dev/null || {
    echo "Warte manuell..."
    until kubectl get sa ${SA} -n ${NAMESPACE} &>/dev/null; do sleep 3; done
}

echo ""
echo ">>> Generiere Token (gültig ${DURATION})..."
TOKEN=$(kubectl create token ${SA} \
  -n ${NAMESPACE} \
  --duration=${DURATION})

echo ""
echo "============================================================"
echo "  Headlamp Login Token"
echo "============================================================"
echo ""
echo "${TOKEN}"
echo ""
echo "============================================================"
echo "  URL: https://headlamp.homelab.reckeweg.io"
echo ""
echo "  Diesen Token beim ersten Login in Headlamp eintragen."
echo "  Pi-hole DNS-Eintrag benötigt:"
echo "    headlamp.homelab.reckeweg.io -> <Traefik LoadBalancer IP>"
echo "============================================================"
