# SERI Infrastructure - Complete Setup Package

Vollständiges Setup für k3s Cluster auf gemischter ARM64/x86_64 Architektur.

## Hardware-Konfiguration

**Master Nodes (GMKtec NucBox M5 Ultra):**
- 3x AMD Ryzen 7 7730U
- 16GB RAM, 256GB OS SSD, 2TB Longhorn SSD
- IPs: 192.168.20.31-33 (K8s) / 192.168.11.31-33 (Mgmt)
- Hostnames: gmkt-01x, gmkt-02x, gmkt-03x

**Worker Nodes (Raspberry Pi 5):**
- 5x ARM64, 8GB RAM
- 30GB OS partition, 960GB Longhorn partition
- IPs: 192.168.20.21-25 (K8s) / 192.168.11.21-25 (Mgmt)
- Hostnames: rpi5-01x, rpi5-02x, rpi5-03x, rpi5-04x, rpi5-05x

**Infrastructure:**
- Synology NAS: 192.168.11.55 (NFS Backup)
- Domain: reckeweg.io (Cloudflare)

## Network VLANs

- VLAN 11 (192.168.11.0/24): Management
- VLAN 20 (192.168.20.0/24): Kubernetes

## Quick Start

### 1. Prerequisites

```bash
# Clone k3s-ansible role
git clone https://github.com/techno-tim/k3s-ansible.git ansible/roles/k3s

# Install Ansible
pip3 install ansible

# Setup SSH keys
ssh-keygen -t ed25519 -C "achim@reckeweg.io"
ssh-copy-id achim@192.168.11.31  # Repeat for all nodes
```

### 1.5 Ansible konfigurieren

Beim Ausführen von ansible-playbook sind einige Fehler aufgetreten, die meist auf falsche 
Pfade zurückzuführen waren.
Lege die Datei **ansible.cfg** im Verzeichnis ansible an.

```bash
[defaults]
# Inventory
inventory = inventory/hosts.ini

# Roles path - WICHTIG!
roles_path = ./roles:~/.ansible/roles:/usr/share/ansible/roles:/etc/ansible/roles

# SSH Settings
host_key_checking = False
remote_user = achim
private_key_file = ~/.ssh/id_ed25519
timeout = 30

# Performance
gathering = smart
fact_caching = jsonfile
fact_caching_connection = /tmp/ansible_facts
fact_caching_timeout = 86400
forks = 10

# Output
stdout_callback = yaml
display_skipped_hosts = False
display_ok_hosts = True

# Logging
log_path = ./ansible.log

[privilege_escalation]
become = True
become_method = sudo
become_user = root
become_ask_pass = False

[ssh_connection]
ssh_args = -C -o ControlMaster=auto -o ControlPersist=60s -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
pipelining = True
control_path = /tmp/ansible-ssh-%%h-%%p-%%r
```


### 2. Configure Inventory

```bash
# Edit ansible/inventory/hosts.ini
# Update UUIDs using:
./scripts/collect-uuids.sh > ansible/inventory/hosts-generated.ini
```

### 3. Run Installation

```bash
cd ansible

# Step 0: Load kernel modules first
ansible-playbook playbooks/load-kernel-modules.yml -i inventory/hosts.ini
  
# Step 1: Setup VLANs
# Note: Not necessary as I configured this manually already
ansible-playbook playbooks/setup-vlan-interfaces.yml -i inventory/hosts.ini

# Step 2: System prerequisites
ansible-playbook playbooks/prereq.yml -i inventory/hosts.ini

# Step 3: Prepare Longhorn storage
ansible-playbook playbooks/longhorn-prep.yml -i inventory/hosts.ini

# Step 4: Install k3s
ansible-playbook playbooks/site.yml -i inventory/hosts.ini
```

Ich hatte Verbindungsprobleme die letztlich auf Altlasten in der Datei ~/.ssh/known_hosts
zurückzuführen waren.
Ich habe manuell die __alten__ Einträge für die Cluster Knoten entfernt.
Danach folgendes Script ausführen:

```bash
# Für alle Nodes die Host Keys akzeptieren
for ip in 31 32 33 21 22 23 24 25; do
  ssh-keyscan -H 192.168.11.$ip >> ~/.ssh/known_hosts
  ssh-keyscan -H 192.168.20.$ip >> ~/.ssh/known_hosts
done

# Oder manuell einmal zu jedem Node connecten
for ip in 31 32 33 21 22 23 24 25; do
  ssh -o StrictHostKeyChecking=accept-new achim@192.168.11.$ip "echo Connected to $ip"
done
```

### 4. Get Kubeconfig

```bash
mkdir -p ~/.kube
scp achim@192.168.11.31:~/.kube/config ~/.kube/seri-homelab
sed -i 's|https://127.0.0.1:6443|https://192.168.11.31:6443|g' ~/.kube/seri-homelab
export KUBECONFIG=~/.kube/seri-homelab
kubectl get nodes
```

### 5. Deploy Infrastructure with ArgoCD

```bash
# Create Cloudflare secrets
kubectl create namespace cert-manager
kubectl create secret generic cloudflare-api-token \
  --from-literal=api-token=YOUR_CLOUDFLARE_API_TOKEN \
  -n cert-manager

kubectl create namespace traefik
kubectl create secret generic cloudflare-credentials \
  --from-literal=email=achim@reckeweg.io \
  --from-literal=api-token=YOUR_CLOUDFLARE_API_TOKEN \
  -n traefik

# Install ArgoCD
kubectl apply -k gitops/argocd/install/

# Wait for ArgoCD to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

# Deploy infrastructure
kubectl apply -f gitops/argocd/apps/root-app.yaml

# Deploy applications
kubectl apply -f gitops/argocd/apps/root-apps.yaml
```

### 6. Access Services

```bash
# Port-forward ArgoCD (or wait for ingress)
kubectl port-forward svc/argocd-server -n argocd 8080:80

# Access at: http://localhost:8080
# Username: admin
# Password: (from step 5)
```

## Components Deployed

### Core Infrastructure
- **k3s**: v1.28.5+k3s1 (HA etcd, 3 masters)
- **Longhorn**: Distributed storage (~10.8TB raw, ~3.6TB usable with replica 3)
- **Traefik**: Ingress controller with Let's Encrypt
- **MetalLB**: LoadBalancer (192.168.20.100-120)
- **cert-manager**: Certificate management with Cloudflare DNS-01

### Monitoring Stack
- **Prometheus**: Metrics collection (30 day retention)
- **Grafana**: Dashboards and visualization
- **Loki**: Log aggregation
- **Promtail**: Log collection
- **AlertManager**: Alert routing

### Applications
- **ArgoCD**: GitOps continuous delivery
- **Gitea**: Git hosting
- **Gollum**: Wiki

## Service URLs

After DNS configuration:
- ArgoCD: https://argocd.reckeweg.io
- Grafana: https://grafana.reckeweg.io
- Prometheus: https://prometheus.reckeweg.io
- Longhorn: https://longhorn.reckeweg.io
- Traefik: https://traefik.reckeweg.io
- Gitea: https://gitea.reckeweg.io
- Gollum: https://wiki.reckeweg.io

## DNS Configuration

Add these A records in Cloudflare for reckeweg.io:

```
*.reckeweg.io            A  192.168.20.100  # Wildcard to MetalLB
argocd.reckeweg.io       A  192.168.20.100
grafana.reckeweg.io      A  192.168.20.100
prometheus.reckeweg.io   A  192.168.20.100
longhorn.reckeweg.io     A  192.168.20.100
traefik.reckeweg.io      A  192.168.20.100
gitea.reckeweg.io        A  192.168.20.100
wiki.reckeweg.io         A  192.168.20.100
```

## Documentation

See `docs/` folder for:
- `INSTALLATION.md`: Detailed installation guide
- `NETWORK.md`: Network configuration
- `TROUBLESHOOTING.md`: Common issues and solutions
- `PXE-BOOT.md`: PXE boot setup (optional)

## Directory Structure

```
seri-infrastructure/
├── ansible/                 # Ansible configuration
│   ├── inventory/          # Host inventory
│   ├── playbooks/          # Playbooks
│   ├── templates/          # Jinja2 templates
│   └── roles/              # k3s-ansible role (clone separately)
├── gitops/                 # GitOps manifests
│   ├── argocd/            # ArgoCD setup
│   ├── infrastructure/     # Core infrastructure
│   └── applications/       # Applications
├── scripts/                # Helper scripts
├── docs/                   # Documentation
└── pxe-server/            # PXE boot (optional)
```

## Maintenance

### Update k3s
```bash
cd ansible
ansible-playbook playbooks/upgrade.yml -i inventory/hosts.ini
```

### Backup
```bash
# Longhorn automatically backs up to NFS: nfs://192.168.11.55:/volume1/longhorn-backup
# Configure backup schedules in Longhorn UI
```

### Reset Cluster
```bash
cd ansible
ansible-playbook playbooks/reset.yml -i inventory/hosts.ini
```

## Support

For issues or questions:
1. Check `docs/TROUBLESHOOTING.md`
2. Review ArgoCD UI for sync status
3. Check pod logs: `kubectl logs -n <namespace> <pod-name>`

## License

Private infrastructure for SERI project.
