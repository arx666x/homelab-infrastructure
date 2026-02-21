# Quick Start Guide

## 1. Collect UUIDs
```bash
./scripts/collect-uuids.sh > ansible/inventory/hosts.ini
```

## 2. Install k3s
```bash
cd ansible
git clone https://github.com/techno-tim/k3s-ansible.git roles/k3s
ansible-playbook playbooks/site.yml -i inventory/hosts.ini
```

## 3. Deploy Infrastructure
```bash
export KUBECONFIG=~/.kube/seri
kubectl create ns cert-manager
kubectl create secret generic cloudflare-api-token \
  --from-literal=api-token=YOUR_TOKEN -n cert-manager
kubectl apply -k gitops/argocd/install/
kubectl apply -f gitops/argocd/apps/root-app.yaml
```

Done! Access ArgoCD at https://argocd.reckeweg.io
