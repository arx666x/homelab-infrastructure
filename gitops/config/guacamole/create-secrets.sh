#!/usr/bin/env bash
# =============================================================================
# Guacamole – Secrets anlegen
# Analog zu gitops/config/gitea/create-secrets.sh
#
# Ausführen BEVOR die ArgoCD-App deployed wird.
# Secrets werden NICHT in Git gespeichert.
# =============================================================================
set -euo pipefail

NAMESPACE="guacamole"

# Namespace vorab anlegen falls noch nicht vorhanden
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# -----------------------------------------------------------------------------
# Phase 1: Datenbank-Secret (immer benötigt)
# -----------------------------------------------------------------------------
# Hostname anpassen – bei Gitea's PostgreSQL typischerweise:
#   gitea-postgresql.gitea.svc.cluster.local
# Falls eine eigene PG-Instanz: entsprechend anpassen.

read -rsp "PostgreSQL Passwort für User 'guacamole': " PG_PASSWORD
echo

kubectl create secret generic guacamole-db-secret \
  --namespace "$NAMESPACE" \
  --from-literal=hostname="gitea-postgresql.gitea.svc.cluster.local" \
  --from-literal=database="guacamole" \
  --from-literal=username="guacamole" \
  --from-literal=password="$PG_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✓ guacamole-db-secret angelegt"

# -----------------------------------------------------------------------------
# Phase 2: OIDC-Secret (optional – nur wenn Keycloak deployed ist)
# OPENID_ENABLED muss in guacamole.yaml zusätzlich auf "true" gesetzt werden.
# -----------------------------------------------------------------------------
read -rp "Keycloak OIDC-Secret jetzt anlegen? (j/N): " SETUP_OIDC
if [ "$(echo "$SETUP_OIDC" | tr '[:upper:]' '[:lower:]')" = "j" ]; then
  KEYCLOAK_BASE="https://keycloak.reckeweg.io/realms/seri"

  kubectl create secret generic guacamole-oidc-secret \
    --namespace "$NAMESPACE" \
    --from-literal=issuer="${KEYCLOAK_BASE}" \
    --from-literal=authorization_endpoint="${KEYCLOAK_BASE}/protocol/openid-connect/auth" \
    --from-literal=jwks_endpoint="${KEYCLOAK_BASE}/protocol/openid-connect/certs" \
    --from-literal=client_id="guacamole" \
    --from-literal=redirect_uri="https://guacamole.reckeweg.io/guacamole/" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo "✓ guacamole-oidc-secret angelegt"
  echo "  → Danach OPENID_ENABLED in gitops/config/guacamole/guacamole.yaml auf 'true' setzen"
else
  echo "  OIDC-Secret übersprungen – kann später mit diesem Script nachgeholt werden"
fi

echo ""
echo "Nächster Schritt: PostgreSQL-User und Datenbank anlegen"
echo "  kubectl exec -it -n gitea gitea-postgresql-0 -- psql -U gitea -d gitea"
echo "  Dann postgres-setup.sql ausführen (oder manuell die 3 SQL-Statements)."
