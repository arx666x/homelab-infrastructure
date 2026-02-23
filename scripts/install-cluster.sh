#!/bin/bash
set -e

echo "===================================================================="
echo "SERI k3s Cluster Installation"
echo "===================================================================="

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ===================================================================
# PRE-FLIGHT CHECKS
# ===================================================================

echo -e "\n${YELLOW}=== Pre-Flight Checks ===${NC}\n"

# Check 1: DNS Search Domain
echo "Check 1: DNS Search Domain..."
for ip in 31 32 33 21 22 23 24 25; do
  SEARCH=$(ssh 192.168.11.$ip "cat /etc/resolv.conf | grep 'search reckeweg.io' || true")
  if [ -n "$SEARCH" ]; then
    echo -e "${RED}❌ Node .11.$ip has DNS search domain${NC}"
    echo "Fix: Remove 'Domain Name' in UniFi DHCP settings for VLAN 11 & 20"
    exit 1
  fi
done
echo -e "${GREEN}✓ DNS Search Domain OK${NC}"

# Check 2: VLAN Static IPs
echo "Check 2: VLAN Interface Configuration..."
for ip in 21 22 23 24 25; do
  VLAN_IP=$(ssh 192.168.11.$ip "ip addr show eth0.20 | grep 'inet 192.168.20.$ip' || true")
  DYNAMIC=$(ssh 192.168.11.$ip "ip addr show eth0.20 | grep dynamic || true")
  
  if [ -z "$VLAN_IP" ]; then
    echo -e "${RED}❌ Worker .11.$ip missing VLAN 20 IP${NC}"
    exit 1
  fi
  
  if [ -n "$DYNAMIC" ]; then
    echo -e "${RED}❌ Worker .11.$ip uses DHCP instead of static${NC}"
    exit 1
  fi
done
echo -e "${GREEN}✓ VLAN IPs OK${NC}"

# Check 3: SSH Connectivity
echo "Check 3: SSH Connectivity..."
for ip in 31 32 33 21 22 23 24 25; do
  ssh -o ConnectTimeout=5 192.168.11.$ip "exit" || {
    echo -e "${RED}❌ Cannot SSH to .11.$ip${NC}"
    exit 1
  }
done
echo -e "${GREEN}✓ SSH OK${NC}"

echo -e "\n${GREEN}All pre-flight checks passed!${NC}\n"

# ===================================================================
# K3S INSTALLATION
# ===================================================================

echo -e "${YELLOW}=== Installing k3s Cluster ===${NC}\n"

# Step 1: First Master
echo "Step 1: Installing first master (gmkt-01x)..."
ssh 192.168.11.31 << 'EOF'
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.28.5+k3s1 sh -s - server \
  --cluster-init \
  --node-ip=192.168.20.31 \
  --flannel-iface=enp1s0.20 \
  --flannel-backend=host-gw \
  --disable traefik \
  --disable servicelb \
  --disable metrics-server \
  --write-kubeconfig-mode 644 \
  --tls-san=192.168.20.31 \
  --tls-san=192.168.11.31 \
  --tls-san=k3s.reckeweg.io
EOF

echo "Waiting for k3s to be ready..."
sleep 30

# Get token
K3S_TOKEN=$(ssh 192.168.11.31 "sudo cat /var/lib/rancher/k3s/server/node-token")

echo -e "${GREEN}✓ First master installed${NC}"

# Step 2: Additional Masters
echo "Step 2: Installing additional masters..."

ssh 192.168.11.32 << EOF
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.28.5+k3s1 sh -s - server \
  --server https://192.168.20.31:6443 \
  --token $K3S_TOKEN \
  --node-ip=192.168.20.32 \
  --flannel-iface=enp1s0.20 \
  --disable traefik \
  --disable servicelb \
  --disable metrics-server
EOF

sleep 10

ssh 192.168.11.33 << EOF
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.28.5+k3s1 sh -s - server \
  --server https://192.168.20.31:6443 \
  --token $K3S_TOKEN \
  --node-ip=192.168.20.33 \
  --flannel-iface=enp1s0.20 \
  --disable traefik \
  --disable servicelb \
  --disable metrics-server
EOF

echo -e "${GREEN}✓ Additional masters installed${NC}"

# Step 3: Workers
echo "Step 3: Installing workers..."

for ip in 21 22 23 24 25; do
  echo "Installing worker k3s-0${ip:1}a..."
  ssh 192.168.11.$ip << EOF
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.28.5+k3s1 \
  K3S_URL=https://192.168.20.31:6443 \
  K3S_TOKEN=$K3S_TOKEN \
  sh -s - agent \
    --node-ip=192.168.20.$ip \
    --flannel-iface=eth0.20
EOF
  sleep 5
done

echo -e "${GREEN}✓ Workers installed${NC}"

# Step 4: Get kubeconfig
echo "Step 4: Configuring kubectl..."
mkdir -p ~/.kube
scp 192.168.11.31:/etc/rancher/k3s/k3s.yaml ~/.kube/seri-homelab
sed -i '' 's/127.0.0.1/192.168.11.31/g' ~/.kube/seri-homelab
chmod 600 ~/.kube/seri-homelab
export KUBECONFIG=~/.kube/seri-homelab

echo -e "${GREEN}✓ kubectl configured${NC}"

# Wait for all nodes
echo "Waiting for all nodes to be Ready..."
sleep 60

kubectl get nodes

echo -e "\n${GREEN}===================================================================="
echo "k3s Cluster Installation Complete!"
echo "====================================================================${NC}\n"

echo "Next: Run install-argocd.sh"
