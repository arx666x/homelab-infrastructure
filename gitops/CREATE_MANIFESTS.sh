#!/bin/bash
# Generate all GitOps manifests

BASE="$(dirname "$0")"

# Longhorn
mkdir -p "$BASE/infrastructure/longhorn"
cat > "$BASE/infrastructure/longhorn/app.yaml" << 'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: longhorn
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.longhorn.io
    chart: longhorn
    targetRevision: 1.5.3
    helm:
      values: |
        defaultSettings:
          backupTarget: nfs://192.168.11.55:/volume1/longhorn-backup
          defaultDataPath: /mnt/longhorn
          defaultReplicaCount: 3
        persistence:
          defaultClass: true
        ingress:
          enabled: true
          host: longhorn.reckeweg.io
          annotations:
            cert-manager.io/cluster-issuer: letsencrypt-prod
  destination:
    server: https://kubernetes.default.svc
    namespace: longhorn-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
YAML

# Cert-Manager
mkdir -p "$BASE/infrastructure/cert-manager"
cat > "$BASE/infrastructure/cert-manager/app.yaml" << 'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.jetstack.io
    chart: cert-manager
    targetRevision: v1.13.3
    helm:
      values: |
        installCRDs: true
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager
  syncPolicy:
    automated:
      prune: true
    syncOptions:
      - CreateNamespace=true
YAML

cat > "$BASE/infrastructure/cert-manager/cluster-issuer.yaml" << 'YAML'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: achim@reckeweg.io
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - dns01:
        cloudflare:
          apiTokenSecretRef:
            name: cloudflare-api-token
            key: api-token
YAML

# Traefik
mkdir -p "$BASE/infrastructure/traefik"
cat > "$BASE/infrastructure/traefik/app.yaml" << 'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: traefik
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://traefik.github.io/charts
    chart: traefik
    targetRevision: 26.0.0
    helm:
      values: |
        service:
          type: LoadBalancer
          annotations:
            metallb.universe.tf/loadBalancerIPs: "192.168.20.100"
        ports:
          web:
            redirectTo:
              port: websecure
          websecure:
            tls:
              enabled: true
  destination:
    server: https://kubernetes.default.svc
    namespace: traefik
  syncPolicy:
    automated:
      prune: true
    syncOptions:
      - CreateNamespace=true
YAML

# MetalLB
mkdir -p "$BASE/infrastructure/metallb"
cat > "$BASE/infrastructure/metallb/app.yaml" << 'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: metallb
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://metallb.github.io/metallb
    chart: metallb
    targetRevision: 0.13.12
  destination:
    server: https://kubernetes.default.svc
    namespace: metallb-system
  syncPolicy:
    automated:
      prune: true
    syncOptions:
      - CreateNamespace=true
YAML

cat > "$BASE/infrastructure/metallb/config.yaml" << 'YAML'
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.20.100-192.168.20.120
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
  - default-pool
YAML

# Monitoring
mkdir -p "$BASE/infrastructure/monitoring"
cat > "$BASE/infrastructure/monitoring/kube-prometheus-stack.yaml" << 'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kube-prometheus-stack
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://prometheus-community.github.io/helm-charts
    chart: kube-prometheus-stack
    targetRevision: 55.5.0
    helm:
      values: |
        prometheus:
          prometheusSpec:
            retention: 30d
            storageSpec:
              volumeClaimTemplate:
                spec:
                  storageClassName: longhorn
                  resources:
                    requests:
                      storage: 50Gi
          ingress:
            enabled: true
            hosts: [prometheus.reckeweg.io]
            annotations:
              cert-manager.io/cluster-issuer: letsencrypt-prod
        grafana:
          enabled: true
          persistence:
            enabled: true
            storageClassName: longhorn
            size: 10Gi
          ingress:
            enabled: true
            hosts: [grafana.reckeweg.io]
            annotations:
              cert-manager.io/cluster-issuer: letsencrypt-prod
          adminPassword: changeme
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
    syncOptions:
      - CreateNamespace=true
YAML

echo "✓ All GitOps manifests created"
