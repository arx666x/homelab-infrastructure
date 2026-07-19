#!/usr/bin/env bash
# =============================================================================
# seal-all-secrets.sh
# Alle Homelab Secrets versiegeln und an die richtige Stelle legen.
#
# Voraussetzungen:
#   - kubeseal installiert und im PATH
#   - pub-cert.pem liegt in gitops/sealed-secrets/
#   - kubectl Zugriff auf den Cluster (für den Export bestehender Secrets)
#
# Verwendung:
#   cd <repo-root>
#   chmod +x gitops/sealed-secrets/seal-all-secrets.sh
#   ./gitops/sealed-secrets/seal-all-secrets.sh
#
# Was dieses Script tut:
#   1. Bestehende Secrets aus dem Cluster exportieren und versiegeln
#   2. Neue Secrets interaktiv abfragen und versiegeln
#   3. SealedSecret-YAMLs an die richtige Stelle unter gitops/config/ legen

# Wann dieses Script verwenden?
#
# 1. NEUES SECRET hinzufügen:
#    - seal_new() Block für die App ergänzen, ausführen, committed sealed-*.yaml
#
# 2. SECRET ROTATION (Passwort ändern):
#    - kubectl delete secret <name> -n <namespace>
#    - Diesen Block im Script ausführen (exportiert neu und versiegelt)
#    - sealed-*.yaml committen und pushen
#
# 3. CLUSTER-NEUBAU (z.B. nach Totalverlust):
#    - Master Key aus Passwortmanager wiederherstellen:
#        kubectl apply -f sealed-secrets-master-key.yaml
#        kubectl rollout restart deployment/sealed-secrets-controller -n kube-system
#    - Dann NICHTS tun — ArgoCD deployt alle SealedSecrets automatisch neu
#    - Dieses Script wird beim Neubau NICHT benötigt
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CERT="$SCRIPT_DIR/pub-cert.pem"

# Farben
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${GREEN}→${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
error()   { echo -e "${RED}✗${NC} $*"; exit 1; }

# Hilfsfunktion: Secret aus Cluster exportieren und versiegeln
seal_from_cluster() {
  local name=$1
  local namespace=$2
  local outfile=$3

  info "Exportiere und versiegle: $name ($namespace) → $outfile"

  kubectl get secret "$name" -n "$namespace" -o json \
    | jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp,
               .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration")' \
    | kubeseal --cert "$CERT" --format yaml \
    > "$REPO_ROOT/$outfile"

  success "$outfile"
}

# Hilfsfunktion: Secret interaktiv erstellen und versiegeln
seal_new() {
  local name=$1
  local namespace=$2
  local outfile=$3
  shift 3
  # Restliche Args: key=value Paare (Werte werden interaktiv abgefragt)

  local kubectl_args=()
  for key in "$@"; do
    # Nur tatsächlich geheime Felder maskiert abfragen (Passwort/Token/Secret).
    # Usernames, Hostnames, E-Mails etc. dürfen sichtbar eingegeben werden -
    # einfacher zu tippen/kontrollieren, ohne Sicherheitsgewinn beim Maskieren.
    if [[ "$key" =~ (password|passwd|token|secret) ]]; then
      read -rsp "  $name / $key: " val
      echo ""
    else
      read -rp "  $name / $key: " val
    fi
    kubectl_args+=("--from-literal=${key}=${val}")
  done

  kubectl create secret generic "$name" \
    --namespace="$namespace" \
    "${kubectl_args[@]}" \
    --dry-run=client -o json \
    | kubeseal --cert "$CERT" --format yaml \
    > "$REPO_ROOT/$outfile"

  success "$outfile"
}

# Cert prüfen
[ -f "$CERT" ] || error "pub-cert.pem nicht gefunden unter $CERT"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║        Homelab Sealed Secrets – Vollständig          ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# 1. GITEA
# =============================================================================
echo "── Gitea ──────────────────────────────────────────────"

if kubectl get secret gitea-admin-secret -n gitea &>/dev/null; then
  seal_from_cluster "gitea-admin-secret" "gitea" \
    "gitops/config/gitea/postgresql/sealed-admin-secret.yaml"
else
  warn "gitea-admin-secret nicht im Cluster – interaktiv eingeben:"
  seal_new "gitea-admin-secret" "gitea" \
    "gitops/config/gitea/postgresql/sealed-admin-secret.yaml" \
    "username" "password" "email"
fi

if kubectl get secret gitea-postgresql-secret -n gitea &>/dev/null; then
  seal_from_cluster "gitea-postgresql-secret" "gitea" \
    "gitops/config/gitea/postgresql/sealed-postgresql-secret.yaml"
else
  warn "gitea-postgresql-secret nicht im Cluster – interaktiv eingeben:"
  seal_new "gitea-postgresql-secret" "gitea" \
    "gitops/config/gitea/postgresql/sealed-postgresql-secret.yaml" \
    "password" "postgres-password"
fi

# =============================================================================
# 2. GUACAMOLE
# =============================================================================
echo ""
echo "── Guacamole ──────────────────────────────────────────"

if kubectl get secret guacamole-db-secret -n guacamole &>/dev/null; then
  seal_from_cluster "guacamole-db-secret" "guacamole" \
    "gitops/config/guacamole/sealed-db-secret.yaml"
else
  warn "guacamole-db-secret nicht im Cluster – interaktiv eingeben:"
  seal_new "guacamole-db-secret" "guacamole" \
    "gitops/config/guacamole/sealed-db-secret.yaml" \
    "hostname" "database" "username" "password"
fi

if kubectl get secret guacamole-oidc-secret -n guacamole &>/dev/null; then
  seal_from_cluster "guacamole-oidc-secret" "guacamole" \
    "gitops/config/guacamole/sealed-oidc-secret.yaml"
else
  warn "guacamole-oidc-secret nicht im Cluster – wird übersprungen (optional, Phase 2)"
fi

# =============================================================================
# 3. MONITORING (Grafana + Alertmanager)
# =============================================================================
echo ""
echo "── Monitoring ─────────────────────────────────────────"

if kubectl get secret alertmanager-credentials -n monitoring &>/dev/null; then
  seal_from_cluster "alertmanager-credentials" "monitoring" \
    "gitops/config/monitoring/sealed-alertmanager-credentials.yaml"
else
  warn "alertmanager-credentials nicht im Cluster – interaktiv eingeben:"
  echo "  (Gmail App-Passwort und Telegram Bot-Token)"
  seal_new "alertmanager-credentials" "monitoring" \
    "gitops/config/monitoring/sealed-alertmanager-credentials.yaml" \
    "gmail-password" "telegram-bot-token"
fi

if kubectl get secret grafana-admin-secret -n monitoring &>/dev/null; then
  seal_from_cluster "grafana-admin-secret" "monitoring" \
    "gitops/config/monitoring/sealed-grafana-admin-secret.yaml"
else
  warn "grafana-admin-secret nicht im Cluster – interaktiv eingeben:"
  seal_new "grafana-admin-secret" "monitoring" \
    "gitops/config/monitoring/sealed-grafana-admin-secret.yaml" \
    "admin-password"
fi

# =============================================================================
# 4. WINDOWS-AD
# =============================================================================
echo ""
echo "── Windows AD ─────────────────────────────────────────"

if kubectl get secret ad-ldaps-pkcs12-password -n windows-ad &>/dev/null; then
  seal_from_cluster "ad-ldaps-pkcs12-password" "windows-ad" \
    "gitops/config/windows-ad/sealed-ldaps-pkcs12-password.yaml"
else
  warn "ad-ldaps-pkcs12-password nicht im Cluster – interaktiv eingeben:"
  seal_new "ad-ldaps-pkcs12-password" "windows-ad" \
    "gitops/config/windows-ad/sealed-ldaps-pkcs12-password.yaml" \
    "password"
fi

if kubectl get secret ldap-service-credentials -n windows-ad &>/dev/null; then
  seal_from_cluster "ldap-service-credentials" "windows-ad" \
    "gitops/config/windows-ad/sealed-ldap-service-credentials.yaml"
else
  warn "ldap-service-credentials nicht im Cluster – interaktiv eingeben:"
  seal_new "ldap-service-credentials" "windows-ad" \
    "gitops/config/windows-ad/sealed-ldap-service-credentials.yaml" \
    "username" "password"
fi

if kubectl get secret windows-ad-ca -n windows-ad &>/dev/null; then
  seal_from_cluster "windows-ad-ca" "windows-ad" \
    "gitops/config/windows-ad/sealed-windows-ad-ca.yaml"
else
  warn "windows-ad-ca nicht im Cluster – bitte manuell von Synology laden:"
  echo "  curl -sf http://diskstation:6666/Windows-Server-2025-AD-SERI-X86/windows-server-2025-ad-seri.certs/ca.cer -o /tmp/ca.crt"
  echo "  kubectl create secret generic windows-ad-ca --namespace=windows-ad \\"
  echo "    --from-file=ca.crt=/tmp/ca.crt --dry-run=client -o json \\"
  echo "    | kubeseal --cert $CERT --format yaml \\"
  echo "    > gitops/config/windows-ad/sealed-windows-ad-ca.yaml"
fi

# =============================================================================
# 5. CERT-DISTRIBUTION
# =============================================================================
echo ""
echo "── Cert-Distribution ──────────────────────────────────"

if kubectl get secret cert-distributor-dsm-credentials -n cert-distribution &>/dev/null; then
  seal_from_cluster "cert-distributor-dsm-credentials" "cert-distribution" \
    "gitops/config/cert-distribution/sealed-secret-dsm-credentials.yaml"
else
  warn "cert-distributor-dsm-credentials nicht im Cluster - interaktiv eingeben:"
  echo "  (Account und Passwort des DSM-Service-Accounts, siehe Runbook)"
  seal_new "cert-distributor-dsm-credentials" "cert-distribution" \
    "gitops/config/cert-distribution/sealed-secret-dsm-credentials.yaml" \
    "dsm-user" "dsm-password"
fi

# Der SSH-Key für die TrueNAS-/Pi-hole-Anbindung wird NICHT hier abgefragt
# (kein Passwort-Prompt sinnvoll für einen Private Key). Derselbe Key wird
# für BEIDE Ziele verwendet (musicbox + dns01), jeweils mit unterschiedlichem
# command= in authorized_keys. Rotation manuell:
#   ssh-keygen -t ed25519 -f /tmp/cert-distributor-key -N "" -C "cert-distributor@cert-distribution.cluster"
#   kubectl create secret generic cert-distributor-ssh-key --namespace=cert-distribution \
#     --type=kubernetes.io/ssh-auth --from-file=ssh-privatekey=/tmp/cert-distributor-key \
#     --dry-run=client -o json \
#     | kubeseal --cert "$CERT" --format yaml \
#     > gitops/config/cert-distribution/sealed-secret-ssh-key.yaml
#   # Public Key (/tmp/cert-distributor-key.pub) danach auf BEIDEN Boxen neu
#   # in authorized_keys hinterlegen (siehe Runbook Abschnitt 3.2 + 8.2),
#   # Private Key lokal löschen.

# =============================================================================
# Zusammenfassung
# =============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Fertig! Nächste Schritte:                           ║"
echo "║                                                      ║"
echo "║  1. git diff gitops/config/                          ║"
echo "║  2. Neue sealed-*.yaml Dateien prüfen                ║"
echo "║  3. git add gitops/config/**/*sealed*.yaml           ║"
echo "║  4. git commit -m 'feat: migrate to sealed secrets'  ║"
echo "║  5. git push                                         ║"
echo "║                                                      ║"
echo "║  ArgoCD synct automatisch – die alten imperativen    ║"
echo "║  Secrets werden durch SealedSecrets ersetzt.         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
