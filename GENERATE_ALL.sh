#!/bin/bash
# Complete file generator for SERI Infrastructure

set -e
BASE="$(pwd)"

echo "Generating all infrastructure files..."

# Create comprehensive documentation
cat > "$BASE/docs/INSTALLATION.md" << 'DOCEOF'
# SERI Infrastructure - Installation Guide

## Step-by-Step Installation

### 1. Initial Setup

```bash
# Clone k3s-ansible
git clone https://github.com/techno-tim/k3s-ansible.git ansible/roles/k3s

# Setup SSH
ssh-keygen -t ed25519
for ip in 31 32 33 21 22 23 24 25; do
  ssh-copy-id achim@192.168.11.$ip
done

# Collect UUIDs
./scripts/collect-uuids.sh > ansible/inventory/hosts-new.ini
```

### 2. Install k3s

```bash
cd ansible
ansible-playbook playbooks/site.yml -i inventory/hosts.ini
```

### 3. Deploy with ArgoCD

```bash
# Get kubeconfig
scp achim@192.168.11.31:~/.kube/config ~/.kube/seri
export KUBECONFIG=~/.kube/seri

# Create secrets
kubectl create ns cert-manager
kubectl create secret generic cloudflare-api-token \
  --from-literal=api-token=YOUR_TOKEN -n cert-manager

# Install ArgoCD
kubectl apply -k gitops/argocd/install/
kubectl apply -f gitops/argocd/apps/root-app.yaml
```
DOCEOF

# Create helper scripts
cat > "$BASE/scripts/collect-uuids.sh" << 'SCRIPT'
#!/bin/bash
# Collect UUIDs from all nodes

NODES=(
    "achim@192.168.11.31:gmkt-01x:master01:nvme1n1p3"
    "achim@192.168.11.32:gmkt-02x:master02:nvme1n1p3"
    "achim@192.168.11.33:gmkt-03x:master03:nvme1n1p3"
    "achim@192.168.11.21:rpi5-01x:worker01:sda3"
    "achim@192.168.11.22:rpi5-02x:worker02:sda3"
    "achim@192.168.11.23:rpi5-03x:worker03:sda3"
    "achim@192.168.11.24:rpi5-04x:worker04:sda3"
    "achim@192.168.11.25:rpi5-05x:worker05:sda3"
)

echo "[master]"
for node in "${NODES[@]}"; do
    IFS=':' read -r ssh host inv part <<< "$node"
    if [[ "$inv" == master* ]]; then
        uuid=$(ssh $ssh "sudo blkid -s UUID -o value /dev/$part" 2>/dev/null)
        [ -n "$uuid" ] && echo "$inv ansible_host=192.168.20.${ssh##*.} mgmt_ip=${ssh#*@} hostname=$host var_disk=${part%p*} var_uuid=$uuid"
    fi
done

echo -e "\n[worker]"
for node in "${NODES[@]}"; do
    IFS=':' read -r ssh host inv part <<< "$node"
    if [[ "$inv" == worker* ]]; then
        uuid=$(ssh $ssh "sudo blkid -s UUID -o value /dev/$part" 2>/dev/null)
        [ -n "$uuid" ] && echo "$inv ansible_host=192.168.20.${ssh##*.} mgmt_ip=${ssh#*@} hostname=$host var_disk=${part%[0-9]*} var_uuid=$uuid"
    fi
done
SCRIPT

chmod +x "$BASE/scripts/collect-uuids.sh"

echo "✓ All files generated successfully!"
echo "✓ Project ready at: $BASE"
