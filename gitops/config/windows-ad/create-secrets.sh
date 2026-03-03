#!/bin/bash
# =============================================================================
# Secrets fuer windows-ad anlegen
# Analog zu gitops/config/gitea/create-secrets.sh
#
# Ausfuehren EINMALIG, MANUELL, VOR dem ersten ArgoCD-Sync:
#   chmod +x gitops/config/windows-ad/create-secrets.sh
#   ./gitops/config/windows-ad/create-secrets.sh
#
# Spaetere Migration zu Sealed Secrets:
#   Die Secrets hier durch SealedSecret-YAMLs ersetzen.
#   Struktur bleibt identisch, nur apiVersion/kind aendern sich.
# =============================================================================

set -euo pipefail

NAMESPACE="windows-ad"

echo "==> Namespace sicherstellen"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# -----------------------------------------------------------------------------
# 1. PKCS12-Passwort fuer cert-manager Keystore
#    (cert-manager exportiert das LDAPS-Zertifikat auch als .p12)
# -----------------------------------------------------------------------------
echo "==> Secret: ad-ldaps-pkcs12-password"
kubectl create secret generic ad-ldaps-pkcs12-password \
  --namespace "$NAMESPACE" \
  --from-literal=password="Sailp0#nt" \
  --dry-run=client -o yaml | kubectl apply -f -

# -----------------------------------------------------------------------------
# 2. CA-Zertifikat von Synology NAS importieren
#    Quellen:
#      http://diskstation:6666/windows-server-2025-ad-seri.certs/ca.cer
#      http://diskstation:6666/windows-server-2025-ad-seri.certs/ca.crt.b64
# -----------------------------------------------------------------------------
echo "==> CA-Zertifikat von Synology laden"
CA_TMP=$(mktemp)
curl -sf "http://diskstation:6666/windows-server-2025-ad-seri.certs/ca.cer" -o "$CA_TMP"

echo "==> Secret: windows-ad-ca"
kubectl create secret generic windows-ad-ca \
  --namespace "$NAMESPACE" \
  --from-file=ca.crt="$CA_TMP" \
  --dry-run=client -o yaml | kubectl apply -f -

# CA auch in andere Namespaces kopieren die LDAPS nutzen
# (anpassen sobald die Tomcat/SERI-Namespaces angelegt sind)
 for ns in seri; do
   kubectl create secret generic windows-ad-ca \
     --namespace "$ns" \
     --from-file=ca.crt="$CA_TMP" \
     --dry-run=client -o yaml | kubectl apply -f -
 done

rm -f "$CA_TMP"

# -----------------------------------------------------------------------------
# 3. LDAP Service Account Credentials
#    (angelegt durch setup-ad-dc.ps1 Phase 3)
# -----------------------------------------------------------------------------
echo "==> Secret: ldap-service-credentials"
kubectl create secret generic ldap-service-credentials \
  --namespace "$NAMESPACE" \
  --from-literal=username="ldap-service@seri.sailpointdemo.com" \
  --from-literal=password="Sailp0#nt" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "==> Fertig. Bitte die CHANGE_ME-Passwoerter anpassen!"
echo "    Dann: git status  (Secrets sind NICHT im Repo, nur dieses Script)"
