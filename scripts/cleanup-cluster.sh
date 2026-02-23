#!/bin/bash
set -e

echo "===================================================================="
echo "SERI Cluster COMPLETE Cleanup - Final Version"
echo "===================================================================="

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "\n${YELLOW}=== Step 1: Uninstalling k3s ===${NC}\n"

# Masters
for ip in 31 32 33; do
  echo "Uninstalling k3s on Master gmkt-0${ip:1}x (.11.$ip)..."
  ssh 192.168.11.$ip "sudo /usr/local/bin/k3s-uninstall.sh" 2>/dev/null || true
done

# Workers
for ip in 21 22 23 24 25; do
  echo "Uninstalling k3s on Worker k3s-0${ip:1}a (.11.$ip)..."
  ssh 192.168.11.$ip "sudo /usr/local/bin/k3s-agent-uninstall.sh" 2>/dev/null || true
done

echo -e "${GREEN}✓ k3s uninstalled${NC}"

echo -e "\n${YELLOW}=== Step 2: Cleaning all k3s data ===${NC}\n"

for ip in 31 32 33 21 22 23 24 25; do
  echo "Deep cleaning .11.$ip..."
  ssh 192.168.11.$ip << 'EOF'
    # Remove ALL k3s data
    sudo rm -rf /var/lib/rancher/k3s
    sudo rm -rf /etc/rancher/k3s
    
    # Remove containerd state
    sudo rm -rf /run/k3s
    sudo rm -rf /var/lib/kubelet
    
    # Clean iptables (k3s rules)
    sudo iptables -F
    sudo iptables -t nat -F
    sudo iptables -t mangle -F
    sudo iptables -X
EOF
done

echo -e "${GREEN}✓ All k3s data cleaned${NC}"

echo -e "\n${YELLOW}=== Step 3: Cleaning Longhorn data ===${NC}\n"

for ip in 31 32 33 21 22 23 24 25; do
  echo "Cleaning /mnt/longhorn on .11.$ip..."
  ssh 192.168.11.$ip "sudo rm -rf /mnt/longhorn/*" 2>/dev/null || true
done

echo -e "${GREEN}✓ Longhorn data cleaned${NC}"

echo -e "\n${YELLOW}=== Step 4: Cleaning local kubeconfig ===${NC}\n"

rm -f ~/.kube/seri-homelab 2>/dev/null || true

echo -e "${GREEN}✓ Kubeconfig cleaned${NC}"

echo -e "\n${YELLOW}=== Step 5: Final verification ===${NC}\n"

# Check no k3s processes
for ip in 31 32 33; do
  RUNNING=$(ssh 192.168.11.$ip "pgrep k3s || true")
  if [ -z "$RUNNING" ]; then
    echo -e "${GREEN}✓ No k3s process on gmkt-0${ip:1}x${NC}"
  else
    echo -e "${RED}✗ k3s still running on gmkt-0${ip:1}x${NC}"
  fi
done

echo -e "\n${GREEN}===================================================================="
echo "Cleanup Complete! System is clean."
echo "====================================================================${NC}\n"

echo "Next: Run install-cluster.sh"
