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
