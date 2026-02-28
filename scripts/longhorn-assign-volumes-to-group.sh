#!/bin/bash
# assign-volumes-to-group.sh
# Weist alle Longhorn Volumes der 'default' RecurringJob-Gruppe zu.
# Kann selektiv mit einem Volume-Namen aufgerufen werden.

NAMESPACE="longhorn-system"
GROUP="default"

if [ -n "$1" ]; then
  # Einzelnes Volume
  echo "Weise Volume '$1' der Gruppe '$GROUP' zu..."
  kubectl label volume "$1" -n "$NAMESPACE" \
    "recurring-job-group.longhorn.io/${GROUP}=enabled" --overwrite
  echo "Fertig."
else
  # Alle Volumes
  echo "Weise ALLE Volumes der Gruppe '$GROUP' zu..."
  VOLUMES=$(kubectl get volumes -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}')
  for vol in $VOLUMES; do
    echo "  → $vol"
    kubectl label volume "$vol" -n "$NAMESPACE" \
      "recurring-job-group.longhorn.io/${GROUP}=enabled" --overwrite
  done
  echo "Fertig. Alle Volumes wurden der Gruppe '$GROUP' zugewiesen."
fi
