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

# Hilfsfunktion: Secret mit zufaellig generierten Werten erstellen und
# versiegeln (kein Interactive-Prompt) - fuer Werte, die niemand sich merken
# muss (Signing-Keys, OIDC-Client-Secrets, generierte DB-Passwoerter). Args:
# key1 key2 ... (jeweils per openssl rand -hex 32 befuellt). Gibt die
# generierten Werte auf stdout aus (key=value je Zeile), damit der Aufrufer
# sie bei Bedarf an einer zweiten Stelle wiederverwenden kann (z.B. denselben
# Client-Secret-Wert in einem !Env-referenzierten authentik-secret UND im
# jeweiligen App-Secret).
seal_generated() {
  local name=$1
  local namespace=$2
  local outfile=$3
  shift 3

  local kubectl_args=()
  for key in "$@"; do
    local val
    val=$(openssl rand -hex 32)
    echo "${key}=${val}"
    kubectl_args+=("--from-literal=${key}=${val}")
  done

  kubectl create secret generic "$name" \
    --namespace="$namespace" \
    "${kubectl_args[@]}" \
    --dry-run=client -o json \
    | kubeseal --cert "$CERT" --format yaml \
    > "$REPO_ROOT/$outfile"

  success "$outfile" >&2
}

# Cert prüfen
[ -f "$CERT" ] || error "pub-cert.pem nicht gefunden unter $CERT"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║        Homelab Sealed Secrets – Vollständig          ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# 0. AUTHENTIK (+ OIDC-Client-Secrets fuer Grafana/Gitea/ArgoCD/Headlamp)
# =============================================================================
echo "── Authentik ──────────────────────────────────────────"

# Alle Werte werden generiert, nicht abgefragt - reine Zufallsstrings, die
# niemand sich merken muss. Die vier OIDC-Client-Secrets muessen IDENTISCH
# im jeweiligen App-Secret UND hier in authentik-secret landen, weil
# gitops/config/authentik/blueprints-configmap.yaml sie per !Env aus den
# Env-Vars des authentik-server/-worker-Pods liest (siehe Kommentar dort) -
# deshalb hier in EINEM Block generiert statt ueber seal_generated() einzeln,
# damit derselbe Wert zweimal verwendet werden kann.
if kubectl get secret authentik-secret -n authentik &>/dev/null; then
  warn "authentik-secret existiert bereits im Cluster - fuer eine Rotation"
  warn "ALLER Werte (inkl. der vier OIDC-Client-Secrets unten) muesst ihr"
  warn "dieses Secret UND die vier App-seitigen *-oidc-secret Secrets von"
  warn "Hand loeschen und diesen Block erneut laufen lassen - sonst laufen"
  warn "Authentik-Provider und App-Secret auseinander."
  seal_from_cluster "authentik-secret" "authentik" \
    "gitops/config/authentik/sealed-secret.yaml"
else
  info "Generiere Authentik-Secrets + OIDC-Client-Secrets..."
  AUTHENTIK_SECRET_KEY=$(openssl rand -hex 32)
  AUTHENTIK_DB_PASSWORD=$(openssl rand -base64 32)
  AUTHENTIK_BOOTSTRAP_PASSWORD=$(openssl rand -base64 24)
  AUTHENTIK_BOOTSTRAP_TOKEN=$(openssl rand -hex 32)
  GRAFANA_OIDC_CLIENT_SECRET=$(openssl rand -hex 32)
  GITEA_OIDC_CLIENT_SECRET=$(openssl rand -hex 32)
  ARGOCD_OIDC_CLIENT_SECRET=$(openssl rand -hex 32)
  HEADLAMP_OIDC_CLIENT_SECRET=$(openssl rand -hex 32)
  DISKSTATION_OIDC_CLIENT_SECRET=$(openssl rand -hex 32)

  kubectl create secret generic authentik-secret \
    --namespace=authentik \
    --from-literal="AUTHENTIK_SECRET_KEY=${AUTHENTIK_SECRET_KEY}" \
    --from-literal="AUTHENTIK_POSTGRESQL__PASSWORD=${AUTHENTIK_DB_PASSWORD}" \
    --from-literal="AUTHENTIK_BOOTSTRAP_PASSWORD=${AUTHENTIK_BOOTSTRAP_PASSWORD}" \
    --from-literal="AUTHENTIK_BOOTSTRAP_TOKEN=${AUTHENTIK_BOOTSTRAP_TOKEN}" \
    --from-literal="GRAFANA_OIDC_CLIENT_SECRET=${GRAFANA_OIDC_CLIENT_SECRET}" \
    --from-literal="GITEA_OIDC_CLIENT_SECRET=${GITEA_OIDC_CLIENT_SECRET}" \
    --from-literal="ARGOCD_OIDC_CLIENT_SECRET=${ARGOCD_OIDC_CLIENT_SECRET}" \
    --from-literal="HEADLAMP_OIDC_CLIENT_SECRET=${HEADLAMP_OIDC_CLIENT_SECRET}" \
    --from-literal="DISKSTATION_OIDC_CLIENT_SECRET=${DISKSTATION_OIDC_CLIENT_SECRET}" \
    --dry-run=client -o json \
    | kubeseal --cert "$CERT" --format yaml \
    > "$REPO_ROOT/gitops/config/authentik/sealed-secret.yaml"
  success "gitops/config/authentik/sealed-secret.yaml"

  warn "DISKSTATION_OIDC_CLIENT_SECRET wird NICHT gesealt (DSM ist nicht"
  warn "GitOps-verwaltet) - manuell in die DSM SSO-Client-Maske"
  warn "'Anwendungsschluessel' eintragen, siehe docs/diskstation-oidc-setup.md:"
  warn "${DISKSTATION_OIDC_CLIENT_SECRET}"

  warn "AUTHENTIK_POSTGRESQL__PASSWORD muss identisch in"
  warn "gitops/config/authentik/postgres-setup.sql eingetragen und einmalig"
  warn "gegen gitea-postgresql ausgefuehrt werden: ${AUTHENTIK_DB_PASSWORD}"

  kubectl create secret generic grafana-oidc-secret --namespace=monitoring \
    --from-literal="client_secret=${GRAFANA_OIDC_CLIENT_SECRET}" \
    --dry-run=client -o json | kubeseal --cert "$CERT" --format yaml \
    > "$REPO_ROOT/gitops/config/monitoring/sealed-grafana-oidc-secret.yaml"
  success "gitops/config/monitoring/sealed-grafana-oidc-secret.yaml"

  kubectl create secret generic gitea-oidc-secret --namespace=gitea \
    --from-literal="client_secret=${GITEA_OIDC_CLIENT_SECRET}" \
    --dry-run=client -o json | kubeseal --cert "$CERT" --format yaml \
    > "$REPO_ROOT/gitops/config/gitea/sealed-oidc-secret.yaml"
  success "gitops/config/gitea/sealed-oidc-secret.yaml"

  # app.kubernetes.io/part-of: argocd Label ist Pflicht, sonst kann
  # argocd-cm den Wert nicht per $argocd-oidc-secret:client_secret lesen.
  kubectl create secret generic argocd-oidc-secret --namespace=argocd \
    --from-literal="client_secret=${ARGOCD_OIDC_CLIENT_SECRET}" \
    --dry-run=client -o json \
    | kubectl label --local -f - app.kubernetes.io/part-of=argocd -o json \
    | kubeseal --cert "$CERT" --format yaml \
    > "$REPO_ROOT/gitops/config/argocd/sealed-oidc-secret.yaml"
  success "gitops/config/argocd/sealed-oidc-secret.yaml"

  kubectl create secret generic headlamp-oidc-secret --namespace=headlamp \
    --from-literal="client_secret=${HEADLAMP_OIDC_CLIENT_SECRET}" \
    --dry-run=client -o json | kubeseal --cert "$CERT" --format yaml \
    > "$REPO_ROOT/gitops/config/headlamp/sealed-oidc-secret.yaml"
  success "gitops/config/headlamp/sealed-oidc-secret.yaml"

  unset AUTHENTIK_SECRET_KEY AUTHENTIK_DB_PASSWORD AUTHENTIK_BOOTSTRAP_PASSWORD \
    AUTHENTIK_BOOTSTRAP_TOKEN GRAFANA_OIDC_CLIENT_SECRET GITEA_OIDC_CLIENT_SECRET \
    ARGOCD_OIDC_CLIENT_SECRET HEADLAMP_OIDC_CLIENT_SECRET DISKSTATION_OIDC_CLIENT_SECRET
fi

if kubectl get secret guacamole-oidc-secret -n guacamole &>/dev/null; then
  seal_from_cluster "guacamole-oidc-secret" "guacamole" \
    "gitops/config/guacamole/sealed-oidc-secret.yaml"
else
  warn "guacamole-oidc-secret nicht im Cluster - Werte kommen NICHT aus"
  warn "diesem Script (Guacamole braucht issuer/authorization_endpoint/"
  warn "jwks_endpoint/client_id/redirect_uri, keine Zufallswerte) - siehe"
  warn "Kommentar in gitops/config/authentik/blueprints-configmap.yaml"
  warn "(guacamole-oidc.yaml) fuer die erwarteten URLs."
fi

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
# 6. CHROMEIQ
# =============================================================================
echo ""
echo "── ChromeIQ ───────────────────────────────────────────"

if kubectl get secret chromeiq-postgresql-secret -n chromeiq &>/dev/null; then
  seal_from_cluster "chromeiq-postgresql-secret" "chromeiq" \
    "gitops/config/chromeiq/sealed-postgresql-secret.yaml"
else
  warn "chromeiq-postgresql-secret nicht im Cluster – interaktiv eingeben:"
  seal_new "chromeiq-postgresql-secret" "chromeiq" \
    "gitops/config/chromeiq/sealed-postgresql-secret.yaml" \
    "password" "postgres-password"
fi

# Typesense-API-Key: kein Login-Passwort, das sich jemand merken muss - wird
# wie TRAKKWS_JWT_SECRET/AUTHENTIK_SECRET_KEY im Schwesterrepo automatisch
# generiert statt interaktiv abgefragt.
if kubectl get secret chromeiq-typesense-secret -n chromeiq &>/dev/null; then
  seal_from_cluster "chromeiq-typesense-secret" "chromeiq" \
    "gitops/config/chromeiq/sealed-typesense-secret.yaml"
else
  info "chromeiq-typesense-secret nicht im Cluster – generiere neuen API-Key:"
  TYPESENSE_API_KEY="$(openssl rand -hex 32)"
  kubectl create secret generic "chromeiq-typesense-secret" \
    --namespace="chromeiq" \
    --from-literal="api-key=${TYPESENSE_API_KEY}" \
    --dry-run=client -o json \
    | kubeseal --cert "$CERT" --format yaml \
    > "$REPO_ROOT/gitops/config/chromeiq/sealed-typesense-secret.yaml"
  success "gitops/config/chromeiq/sealed-typesense-secret.yaml"
fi

# SMB-Credentials fuer die Musicbox-Library-Freigabe (//musicbox/music) -
# echter SMB-User "chromeiq", read-only Zugriff. Erstes SMB-Volume in
# diesem Cluster, s. gitops/apps/csi-driver-smb.yaml und
# gitops/config/chromeiq/smb-pv.yaml (nodeStageSecretRef erwartet exakt
# die Keys "username"/"password").
if kubectl get secret chromeiq-smb-secret -n chromeiq &>/dev/null; then
  seal_from_cluster "chromeiq-smb-secret" "chromeiq" \
    "gitops/config/chromeiq/sealed-smb-secret.yaml"
else
  warn "chromeiq-smb-secret nicht im Cluster – interaktiv eingeben:"
  seal_new "chromeiq-smb-secret" "chromeiq" \
    "gitops/config/chromeiq/sealed-smb-secret.yaml" \
    "username" "password"
fi

# Last.fm-API-Key fuer die Interpret-Seiten-Bio (ciq-backend/internal/
# lastfm/client.go) - Achims eigener Key von last.fm/api/account/create,
# kein Passwort das er sich merken muss, aber auch nicht generierbar wie
# der Typesense-Key. Achim hat den Key ueber die Optionen-Seite (externe
# Links, Last.fm-Zeile, API-Key-Spalte) statt im Chat uebergeben.
if kubectl get secret chromeiq-lastfm-secret -n chromeiq &>/dev/null; then
  seal_from_cluster "chromeiq-lastfm-secret" "chromeiq" \
    "gitops/config/chromeiq/sealed-lastfm-secret.yaml"
else
  warn "chromeiq-lastfm-secret nicht im Cluster – interaktiv eingeben:"
  seal_new "chromeiq-lastfm-secret" "chromeiq" \
    "gitops/config/chromeiq/sealed-lastfm-secret.yaml" \
    "api-key"
fi

# JWT-Signing-Key fuer die lokale Nutzerverwaltung (konzeptdokument 3.9,
# Entscheidung 2026-08-09) - wie der Typesense-API-Key ein generierter
# Wert, den sich niemand merken muss, kein interaktiver Prompt noetig.
if kubectl get secret chromeiq-jwt-secret -n chromeiq &>/dev/null; then
  seal_from_cluster "chromeiq-jwt-secret" "chromeiq" \
    "gitops/config/chromeiq/sealed-jwt-secret.yaml"
else
  info "chromeiq-jwt-secret nicht im Cluster – generiere neuen Signing-Key:"
  JWT_SECRET="$(openssl rand -hex 32)"
  kubectl create secret generic "chromeiq-jwt-secret" \
    --namespace="chromeiq" \
    --from-literal="secret=${JWT_SECRET}" \
    --dry-run=client -o json \
    | kubeseal --cert "$CERT" --format yaml \
    > "$REPO_ROOT/gitops/config/chromeiq/sealed-jwt-secret.yaml"
  success "gitops/config/chromeiq/sealed-jwt-secret.yaml"
fi

# SMTP-Relay fuer Passwort-Reset-Mails (konzeptdokument 3.9) - bewusst
# derselbe Gmail-App-Passwort-Wert wie fuer Alertmanager
# (gitops/config/monitoring/sealed-alertmanager-credentials.yaml, Key
# "gmail-password"), damit nicht zwei App-Passwoerter im selben Google-
# Konto verwaltet werden muessen. Username bewusst fest verdrahtet statt
# aus dem Monitoring-Secret uebernommen: dessen "gmail-user"-Key hat einen
# verwaisten schliessenden ">" (nie aufgefallen, weil Alertmanagers eigene
# Config den Username stattdessen hart im YAML traegt statt aus dem Secret
# zu lesen) - hier richtig gesetzt.
if kubectl get secret chromeiq-smtp-secret -n chromeiq &>/dev/null; then
  seal_from_cluster "chromeiq-smtp-secret" "chromeiq" \
    "gitops/config/chromeiq/sealed-smtp-secret.yaml"
else
  if kubectl get secret alertmanager-credentials -n monitoring &>/dev/null; then
    info "chromeiq-smtp-secret nicht im Cluster – uebernehme Gmail-App-Passwort aus monitoring:"
    SMTP_PASS="$(kubectl get secret alertmanager-credentials -n monitoring -o jsonpath='{.data.gmail-password}' | base64 -d)"
    kubectl create secret generic "chromeiq-smtp-secret" \
      --namespace="chromeiq" \
      --from-literal="host=smtp.gmail.com" \
      --from-literal="port=587" \
      --from-literal="username=achim.reckeweg@gmail.com" \
      --from-literal="password=${SMTP_PASS}" \
      --from-literal="from-address=achim.reckeweg@gmail.com" \
      --dry-run=client -o json \
      | kubeseal --cert "$CERT" --format yaml \
      > "$REPO_ROOT/gitops/config/chromeiq/sealed-smtp-secret.yaml"
    unset SMTP_PASS
    success "gitops/config/chromeiq/sealed-smtp-secret.yaml"
  else
    warn "weder chromeiq-smtp-secret noch alertmanager-credentials im Cluster – interaktiv eingeben:"
    seal_new "chromeiq-smtp-secret" "chromeiq" \
      "gitops/config/chromeiq/sealed-smtp-secret.yaml" \
      "host" "port" "username" "password" "from-address"
  fi
fi

# Reminder: sealed-*.yaml erst in gitops/config/chromeiq/kustomization.yaml
# aufnehmen, nachdem sie hier echt generiert wurden (s. Kommentare in den
# Platzhalter-Dateien) - sonst crashloopt Postgres/Typesense mangels Passwort.
# Das gilt jetzt auch fuer sealed-smb-secret.yaml + smb-pv.yaml/
# ciq-backend.yaml, sobald diese ebenfalls in der kustomization.yaml stehen.

# =============================================================================
# 7. ARGOCD IMAGE UPDATER
# =============================================================================
echo ""
echo "── ArgoCD Image Updater ──────────────────────────────"

# Registry-Pull-Secret fuer gitea.reckeweg.io - der Image Updater braucht das,
# um Tags/Push-Zeitpunkte fuer gitea.reckeweg.io/susann/redesign zu lesen
# (siehe gitops/config/argocd-image-updater/registries-configmap.yaml).
# Token: Susanns Gitea-Account -> Settings -> Applications -> Manage Access
# Tokens, Scope "package" (read reicht).
if kubectl get secret gitea-registry-creds -n argocd &>/dev/null; then
  seal_from_cluster "gitea-registry-creds" "argocd" \
    "gitops/config/argocd-image-updater/sealed-gitea-registry-creds.yaml"
else
  info "Registry-Zugang fuer Susanns redesign-Projekt (gitea.reckeweg.io/susann/redesign) -"
  info "der ArgoCD Image Updater braucht das, um neue RC-/GA-Image-Tags zu sehen."
  warn "gitea-registry-creds nicht im Cluster – interaktiv eingeben:"
  read -rp "  Gitea-Benutzername (i.d.R. susann): " GITEA_REGISTRY_USER
  read -rsp "  Registry-Token (Susanns Gitea Access Token, Scope 'package'): " GITEA_REGISTRY_TOKEN
  echo ""
  kubectl create secret docker-registry "gitea-registry-creds" \
    --namespace="argocd" \
    --docker-server="gitea.reckeweg.io" \
    --docker-username="${GITEA_REGISTRY_USER}" \
    --docker-password="${GITEA_REGISTRY_TOKEN}" \
    --dry-run=client -o json \
    | kubeseal --cert "$CERT" --format yaml \
    > "$REPO_ROOT/gitops/config/argocd-image-updater/sealed-gitea-registry-creds.yaml"
  unset GITEA_REGISTRY_USER GITEA_REGISTRY_TOKEN
  success "gitops/config/argocd-image-updater/sealed-gitea-registry-creds.yaml"
fi

# Reminder: sealed-gitea-registry-creds.yaml erst in
# gitops/config/argocd-image-updater/kustomization.yaml aufnehmen, nachdem sie
# hier echt generiert wurde (s. Kommentar in der Platzhalter-Datei) - sonst
# findet der Image Updater die Registry-Tags nicht (401).
#
# Das SSH-Keypaar fuer den Git-Write-back (argocd-image-updater-git-creds) ist
# NICHT Teil dieses Scripts - das wurde einmalig generiert und versiegelt, der
# oeffentliche Schluessel liegt als Kommentar in
# gitops/config/argocd-image-updater/sealed-git-writeback-secret.yaml. Nur bei
# Rotation noetig, s. Kommentar dort.

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
