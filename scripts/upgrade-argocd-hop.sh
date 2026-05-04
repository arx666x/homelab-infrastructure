#!/bin/bash
# upgrade-argocd-hop.sh
# Upgrades ArgoCD to a target version and applies node affinity + resource limits.
#
# Usage: ./upgrade-argocd-hop.sh v3.3.9
#
# WICHTIG: Ab v3.3 ist --server-side --force-conflicts beim kubectl apply Pflicht,
#          da ArgoCD CRDs das Limit für client-side apply überschreiten.
#
# ACHTUNG: Container-Array niemals per merge-patch patchen — löscht image/command/args!
#          Affinity: merge-patch auf spec.template.spec (kein containers[])
#          Resources: json-patch mit "replace" auf exakten Pfad /containers/0/resources

set -e

TARGET_VERSION=$1

if [[ -z "$TARGET_VERSION" ]]; then
  echo "Usage: $0 <version>  (z.B. $0 v3.3.9)"
  exit 1
fi

echo "===================================================================="
echo "ArgoCD Upgrade → ${TARGET_VERSION}"
echo "===================================================================="

# SSH Known Hosts vor dem Upgrade sichern (werden durch install.yaml überschrieben)
SSH_KEY=$(ssh-keyscan -p 22 git.reckeweg.io 2>/dev/null | grep -v "^#")

# --------------------------------------------------------------------
# 1. Manifeste anwenden (server-side apply ab v3.x Pflicht)
# --------------------------------------------------------------------
echo ""
echo "=== 1/4 Applying manifests (server-side) ==="
kubectl apply -n argocd \
  --server-side \
  --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${TARGET_VERSION}/manifests/install.yaml"

# --------------------------------------------------------------------
# 2. SSH Known Hosts wiederherstellen
# --------------------------------------------------------------------
echo ""
echo "=== 2/4 Restoring SSH known hosts ==="
kubectl patch cm argocd-ssh-known-hosts-cm -n argocd \
  --type merge \
  -p "{\"data\":{\"ssh_known_hosts\":\"${SSH_KEY}\"}}"

# --------------------------------------------------------------------
# 3. Rollout abwarten
# --------------------------------------------------------------------
echo ""
echo "=== 3/4 Waiting for rollout ==="
kubectl rollout status deployment/argocd-server              -n argocd --timeout=300s
kubectl rollout status deployment/argocd-repo-server         -n argocd --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s

# --------------------------------------------------------------------
# 4a. Node Affinity patchen (merge-patch auf spec.template.spec — KEIN containers[])
#     preferred = AMD64 (GMKTec) bevorzugt, Pi als Fallback
# --------------------------------------------------------------------
echo ""
echo "=== 4/4 Patching application-controller: NodeAffinity + Resources ==="

kubectl patch statefulset argocd-application-controller -n argocd \
  --type=merge -p='{
  "spec": {"template": {"spec": {
    "affinity": {
      "nodeAffinity": {
        "preferredDuringSchedulingIgnoredDuringExecution": [
          {
            "weight": 80,
            "preference": {
              "matchExpressions": [{
                "key": "kubernetes.io/arch",
                "operator": "In",
                "values": ["amd64"]
              }]
            }
          }
        ]
      }
    }
  }}}}'

# --------------------------------------------------------------------
# 4b. Resources patchen (json-patch "replace" auf exakten Pfad)
#     NIEMALS den containers[] Array per merge-patch ersetzen —
#     das löscht image, command und args → CrashLoopBackOff (tini ohne Args)
# --------------------------------------------------------------------
kubectl patch statefulset argocd-application-controller -n argocd \
  --type='json' -p='[{
    "op": "replace",
    "path": "/spec/template/spec/containers/0/resources",
    "value": {
      "requests": {"cpu": "250m", "memory": "512Mi"},
      "limits":   {"cpu": "2000m", "memory": "1Gi"}
    }
  }]'

# Restart damit Affinity sofort greift (neues Scheduling)
echo "Restarting application-controller to apply scheduling changes..."
kubectl rollout restart statefulset/argocd-application-controller -n argocd
kubectl rollout status  statefulset/argocd-application-controller -n argocd --timeout=300s

# --------------------------------------------------------------------
# Verifikation
# --------------------------------------------------------------------
echo ""
echo "=== Verification ==="

echo ""
echo "--- Deployed version ---"
kubectl get deployment argocd-server -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

echo ""
echo "--- Controller node placement ---"
kubectl get pod argocd-application-controller-0 -n argocd \
  -o jsonpath='Node: {.spec.nodeName}{"\n"}'

echo ""
echo "--- Controller resources ---"
kubectl get statefulset argocd-application-controller -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].resources}' | jq .

echo ""
echo "--- Application sync status ---"
kubectl get applications -n argocd \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}'

echo ""
echo "===================================================================="
echo "Upgrade to ${TARGET_VERSION} complete."
echo "===================================================================="
