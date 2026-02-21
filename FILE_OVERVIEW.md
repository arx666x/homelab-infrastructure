# SERI Infrastructure - File Overview

## Directory Structure

```
seri-infrastructure-complete/
├── README.md                       # Main documentation
├── FILE_OVERVIEW.md               # This file
├── GENERATE_ALL.sh                # Helper script
│
├── ansible/                       # Ansible configuration
│   ├── inventory/
│   │   ├── hosts.ini             # Host inventory (UPDATE UUIDs!)
│   │   └── group_vars/
│   │       ├── all.yml           # Global variables
│   │       ├── master.yml        # Master node config
│   │       └── worker.yml        # Worker node config
│   │
│   └── playbooks/
│       ├── site.yml              # Main installation playbook
│       ├── prereq.yml            # System prerequisites
│       ├── setup-vlan-interfaces.yml  # VLAN configuration
│       ├── longhorn-prep.yml     # Storage preparation
│       └── reset.yml             # Cluster reset
│
├── gitops/                        # GitOps manifests
│   ├── CREATE_MANIFESTS.sh       # Manifest generator
│   │
│   ├── argocd/                   # ArgoCD setup
│   │   ├── install/
│   │   │   ├── kustomization.yaml
│   │   │   ├── namespace.yaml
│   │   │   └── ingress.yaml
│   │   │
│   │   └── apps/
│   │       └── root-app.yaml     # Root application
│   │
│   └── infrastructure/           # Core infrastructure
│       ├── cert-manager/
│       │   ├── app.yaml
│       │   └── cluster-issuer.yaml
│       ├── longhorn/
│       │   └── app.yaml
│       ├── traefik/
│       │   └── app.yaml
│       ├── metallb/
│       │   ├── app.yaml
│       │   └── config.yaml
│       └── monitoring/
│           └── kube-prometheus-stack.yaml
│
├── scripts/                       # Helper scripts
│   └── collect-uuids.sh          # Collect disk UUIDs
│
└── docs/                         # Documentation
    ├── INSTALLATION.md           # Detailed installation
    └── QUICK-START.md            # Quick start guide
```

## Next Steps

1. **Clone k3s-ansible role:**
   ```bash
   git clone https://github.com/techno-tim/k3s-ansible.git ansible/roles/k3s
   ```

2. **Update hosts.ini with actual UUIDs:**
   ```bash
   ./scripts/collect-uuids.sh > ansible/inventory/hosts.ini
   ```

3. **Run installation:**
   ```bash
   cd ansible
   ansible-playbook playbooks/site.yml -i inventory/hosts.ini
   ```

4. **Deploy with ArgoCD:**
   ```bash
   kubectl apply -k gitops/argocd/install/
   kubectl apply -f gitops/argocd/apps/root-app.yaml
   ```

## Important Files to Customize

- `ansible/inventory/hosts.ini` - Update UUIDs
- `gitops/infrastructure/cert-manager/cluster-issuer.yaml` - Add Cloudflare token
- `gitops/infrastructure/monitoring/kube-prometheus-stack.yaml` - Change Grafana password

## Service URLs

After deployment:
- ArgoCD: https://argocd.reckeweg.io
- Grafana: https://grafana.reckeweg.io
- Prometheus: https://prometheus.reckeweg.io
- Longhorn: https://longhorn.reckeweg.io
- Traefik: https://traefik.reckeweg.io
