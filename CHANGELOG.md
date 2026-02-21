# Changelog

## Version 1.0.0 - Initial Release

### Network Configuration
- Management VLAN: 192.168.11.0/24
- Kubernetes VLAN: 192.168.20.0/24
- Dual-interface setup for separation

### Hardware
- 3x GMKtec M5 Ultra (Masters): 192.168.20.31-33
- 5x Raspberry Pi 5 (Workers): 192.168.20.21-25
- Synology NAS (Backup): 192.168.11.55

### Components
- k3s v1.28.5+k3s1 with HA etcd
- Longhorn 1.5.3 for distributed storage
- Traefik 26.0.0 as ingress controller
- MetalLB 0.13.12 for LoadBalancer
- cert-manager 1.13.3 with Cloudflare DNS-01
- kube-prometheus-stack 55.5.0
- ArgoCD 2.9.3 for GitOps

### Features
- Multi-architecture support (ARM64 + x86_64)
- Automated VLAN configuration
- UUID-based disk mounting
- NFS backups to Synology
- Let's Encrypt certificates
- Full monitoring stack
