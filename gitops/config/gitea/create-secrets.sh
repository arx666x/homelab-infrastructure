#!/usr/bin/env bash
# =============================================================================
# Gitea Secrets erstellen - einmalig vor dem ersten ArgoCD-Sync ausführen
#
# Später ersetzen durch:
#   kubeseal --fetch-cert > pub-cert.pem
#   kubeseal --cert pub-cert.pem -f secret.yaml -o yaml > sealed-secret.yaml
#
# Verwendung:
#   chmod +x create-secrets.sh
#   ./create-secrets.sh
# =============================================================================

set -euo pipefail

NAMESPACE="gitea"

echo "→ Namespace sicherstellen..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "Bitte Werte eingeben:"
echo "---------------------"

read -rp "Gitea Admin Username [gitea-admin]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-gitea-admin}"

read -rsp "Gitea Admin Passwort (min. 16 Zeichen): " ADMIN_PASS
echo ""

read -rp "Gitea Admin E-Mail [achim@reckeweg.io]: " ADMIN_EMAIL
ADMIN_EMAIL="${ADMIN_EMAIL:-achim@reckeweg.io}"

read -rsp "PostgreSQL Passwort für 'gitea' User: " DB_PASS
echo ""

read -rsp "PostgreSQL Passwort für 'postgres' Superuser: " DB_ADMIN_PASS
echo ""

# Passwort-Länge prüfen
if [ ${#ADMIN_PASS} -lt 16 ]; then
  echo "❌ Admin-Passwort muss mindestens 16 Zeichen haben!"
  exit 1
fi

echo ""
echo "→ Erstelle gitea-admin-secret..."
kubectl create secret generic gitea-admin-secret \
  --namespace="$NAMESPACE" \
  --from-literal=username="$ADMIN_USER" \
  --from-literal=password="$ADMIN_PASS" \
  --from-literal=email="$ADMIN_EMAIL" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "→ Erstelle gitea-postgresql-secret..."
kubectl create secret generic gitea-postgresql-secret \
  --namespace="$NAMESPACE" \
  --from-literal=password="$DB_PASS" \
  --from-literal=postgres-password="$DB_ADMIN_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "✅ Secrets erfolgreich angelegt in Namespace '$NAMESPACE'."
echo ""
echo "Nächste Schritte:"
echo "  1. gitea.yaml in gitops/apps/ committen und pushen"
echo "  2. kubectl apply -f gitops/apps/gitea.yaml"
echo "  3. argocd app get gitea"
echo ""
echo "Später für Sealed Secrets:"
echo "  kubeseal --fetch-cert > pub-cert.pem"
echo "  kubectl get secret gitea-admin-secret -n gitea -o yaml | \\"
echo "    kubeseal --cert pub-cert.pem -o yaml > gitops/config/gitea/sealed-admin-secret.yaml"
