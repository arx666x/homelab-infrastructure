#!/bin/bash
set -e

echo "=== SERI Infrastructure Direct Deployment ==="

# 1. MetalLB
echo "1/5 MetalLB..."
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml
echo "Waiting for MetalLB..."
sleep 60
kubectl wait --for=condition=ready pod -l app=metallb -n metallb-system --timeout=300s 2>/dev/null || sleep 30

cat <<EOF | kubectl apply -f -
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
EOF

echo "✓ MetalLB deployed"

# 2. cert-manager
echo "2/5 cert-manager..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.3/cert-manager.yaml
echo "Waiting for cert-manager..."
sleep 90
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=cert-manager -n cert-manager --timeout=300s 2>/dev/null || sleep 30

cat <<EOF | kubectl apply -f -
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
EOF

echo "✓ cert-manager deployed"

# 3. Traefik
echo "3/5 Traefik..."
helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

cat > /tmp/traefik-values.yaml <<EOF
service:
  type: LoadBalancer
  annotations:
    metallb.universe.tf/address-pool: default-pool

persistence:
  enabled: true
  storageClass: "longhorn"
  size: 1Gi

ports:
  web:
    port: 80
  websecure:
    port: 443

logs:
  general:
    level: INFO
EOF

helm install traefik traefik/traefik \
  --namespace traefik --create-namespace \
  -f /tmp/traefik-values.yaml

echo "✓ Traefik deployed"

# 4. Longhorn
echo "4/5 Longhorn (this will take 5-10 minutes)..."
helm repo add longhorn https://charts.longhorn.io >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

helm install longhorn longhorn/longhorn \
  --namespace longhorn-system --create-namespace \
  --set defaultSettings.backupTarget="nfs://192.168.11.55:/volume1/longhorn-backup" \
  --set defaultSettings.defaultDataPath="/mnt/longhorn" \
  --set defaultSettings.defaultReplicaCount=3 \
  --set persistence.defaultClass=true \
  --set ingress.enabled=true \
  --set ingress.host="longhorn.reckeweg.io" \
  --set ingress.annotations."cert-manager\.io/cluster-issuer"="letsencrypt-prod"

echo "✓ Longhorn deploying..."

# 5. Prometheus Stack
echo "5/5 Prometheus Stack..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

cat > /tmp/prometheus-values.yaml <<EOF
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

grafana:
  persistence:
    enabled: true
    storageClassName: longhorn
    size: 10Gi
  adminPassword: changeme
  ingress:
    enabled: true
    hosts:
      - grafana.reckeweg.io
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod

alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: longhorn
          resources:
            requests:
              storage: 10Gi
EOF

helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f /tmp/prometheus-values.yaml

echo ""
echo "=== Deployment Complete! ==="
echo ""
echo "Watch progress:"
echo "  kubectl get pods -A"
echo ""
echo "Services will be available at:"
echo "  Traefik:    http://192.168.20.100"
echo "  Longhorn:   https://longhorn.reckeweg.io (after DNS)"
echo "  Grafana:    https://grafana.reckeweg.io (after DNS)"
echo ""
echo "Longhorn will take 5-10 minutes to fully deploy all components."
