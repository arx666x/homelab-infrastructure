# upgrade-argocd-hop.sh
TARGET_VERSION=$1
SSH_KEY=$(ssh-keyscan -p 22 git.reckeweg.io 2>/dev/null | grep -v "^#")

kubectl apply -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${TARGET_VERSION}/manifests/install.yaml"

# SSH Key sofort nach apply wiederherstellen
kubectl patch cm argocd-ssh-known-hosts-cm -n argocd \
  --type merge \
  -p "{\"data\":{\"ssh_known_hosts\":\"${SSH_KEY}\"}}"

kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s

kubectl get deployment argocd-server -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
echo ""

kubectl get applications -n argocd \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}'

