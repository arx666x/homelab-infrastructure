#!/bin/bash
# longhorn-drain-workers.sh
# Evakuiert alle Pi-Worker-Nodes sauber und fährt sie herunter.
# Ausführen von einem Master-Node oder vom Mac mit aktivem kubeconfig.

set -euo pipefail

WORKERS=(k3s-01a k3s-02a k3s-03a k3s-04a k3s-05a)
WORKER_IPS=(192.168.20.21 192.168.20.22 192.168.20.23 192.168.20.24 192.168.20.25)
SSH_USER="achim"

echo "========================================"
echo " Phase 1: KubeVirt VM stoppen (falls aktiv)"
echo "========================================"
if kubectl -n windows-ad get vmi windows-ad &>/dev/null 2>&1; then
  echo "→ Windows-AD VM gefunden, stoppe..."
  virtctl stop windows-ad -n windows-ad
  sleep 5
else
  echo "→ Keine laufende VM gefunden, überspringe."
fi

echo ""
echo "========================================"
echo " Phase 2: Kubernetes Cordon (kubectl)"
echo "========================================"
for node in "${WORKERS[@]}"; do
  echo "→ Cordon $node"
  kubectl cordon "$node"
done

echo ""
echo "========================================"
echo " Phase 3: Longhorn Disk + Node Eviction"
echo "========================================"
for node in "${WORKERS[@]}"; do
  disk=$(kubectl -n longhorn-system get node.longhorn.io/"$node" \
    -o jsonpath='{.spec.disks}' | jq -r 'keys[0]')
  echo "→ $node  (disk: $disk)"
  kubectl -n longhorn-system patch node.longhorn.io/"$node" \
    --type=merge \
    -p "{\"spec\":{
      \"allowScheduling\": false,
      \"evictionRequested\": true,
      \"disks\": {
        \"$disk\": {
          \"allowScheduling\": false,
          \"evictionRequested\": true
        }
      }
    }}"
done

echo ""
echo "========================================"
echo " Phase 4: Warten bis Longhorn-Replicas evakuiert"
echo "========================================"
echo "Prüfe alle 10 Sekunden ob noch Replicas auf Pi-Nodes laufen..."
while true; do
  remaining=$(kubectl -n longhorn-system get replicas.longhorn.io \
    -o custom-columns='NODE:.spec.nodeID' --no-headers \
    | grep -E "^k3s-0" | wc -l | tr -d ' ')

  echo "  → Noch $remaining Replica(s) auf Pi-Nodes ($(date +%H:%M:%S))"

  if [ "$remaining" -eq 0 ]; then
    echo "  ✓ Alle Replicas evakuiert!"
    break
  fi
  sleep 10
done

echo ""
echo "========================================"
echo " Phase 5: Longhorn PDBs löschen"
echo "========================================"
kubectl -n longhorn-system delete pdb \
  -l longhorn.io/component=instance-manager \
  --ignore-not-found=true
echo "→ PDBs gelöscht (werden nach dem Neustart automatisch neu erstellt)"

echo ""
echo "========================================"
echo " Phase 6: Kubernetes Drain"
echo "========================================"
for node in "${WORKERS[@]}"; do
  kubectl drain "$node" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --force \
    --timeout=120s &
done
wait
echo "→ Alle Nodes gedrained"

echo ""
echo "========================================"
echo " Phase 7: Nodes herunterfahren"
echo "========================================"
for ip in "${WORKER_IPS[@]}"; do
  echo "→ Shutdown $ip"
  ssh -o ConnectTimeout=5 "${SSH_USER}@${ip}" "sudo shutdown -h now" &
done
wait

echo ""
echo "========================================"
echo " ✓ Fertig! Alle Worker-Nodes werden heruntergefahren."
echo ""
echo " Nach dem Netzteil-Tausch und Neustart:"
echo "   ./longhorn-uncordon-workers.sh"
echo "========================================"
