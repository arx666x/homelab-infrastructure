#!/bin/bash
set -e

echo "===================================================================="
echo "SERI Cluster Complete Cleanup"
echo "===================================================================="

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 1. k3s auf allen Nodes deinstallieren
echo -e "\n${YELLOW}=== Step 1: Uninstalling k3s ===${NC}\n"

# Masters
for ip in 31 32 33; do
  echo "Uninstalling k3s on Master .11.$ip..."
  ssh achim@192.168.11.$ip "sudo /usr/local/bin/k3s-uninstall.sh" 2>/dev/null || true
done

# Workers
for ip in 21 22 23 24 25; do
  echo "Uninstalling k3s on Worker .11.$ip..."
  ssh achim@192.168.11.$ip "sudo /usr/local/bin/k3s-agent-uninstall.sh" 2>/dev/null || true
done

echo -e "${GREEN}✓ k3s uninstalled${NC}"

# 2. Cleanup Longhorn Daten
echo -e "\n${YELLOW}=== Step 2: Cleaning Longhorn data ===${NC}\n"

for ip in 31 32 33 21 22 23 24 25; do
  echo "Cleaning /mnt/longhorn on .11.$ip..."
  ssh achim@192.168.11.$ip "sudo rm -rf /mnt/longhorn/*" 2>/dev/null || true
done

echo -e "${GREEN}✓ Longhorn data cleaned${NC}"

# 3. Cleanup Kubeconfig
echo -e "\n${YELLOW}=== Step 3: Cleaning local kubeconfig ===${NC}\n"

rm -f ~/.kube/seri-homelab 2>/dev/null || true

echo -e "${GREEN}✓ Kubeconfig cleaned${NC}"

# 4. Verify cleanup
echo -e "\n${YELLOW}=== Step 4: Verification ===${NC}\n"

# Check k3s process
for ip in 31; do
  RUNNING=$(ssh achim@192.168.11.$ip "pgrep k3s || true")
  if [ -z "$RUNNING" ]; then
    echo -e "${GREEN}✓ No k3s process on .11.$ip${NC}"
  else
    echo -e "${RED}✗ k3s still running on .11.$ip${NC}"
  fi
done

echo -e "\n${GREEN}===================================================================="
echo "Cleanup Complete!"
echo "====================================================================${NC}\n"

echo "Next steps:"
echo "1. Verify VLAN 20 static IPs are still configured"
echo "2. Run install-cluster.sh for fresh deployment"
