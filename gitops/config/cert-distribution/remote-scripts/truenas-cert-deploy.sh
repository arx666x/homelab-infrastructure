#!/usr/bin/env bash
# =============================================================================
# truenas-cert-deploy.sh
#
# Läuft AUF der TrueNAS-Box (musicbox). Wird ausschließlich über den
# command-restricted SSH-Key aus dem cert-distributor-CronJob aufgerufen
# (siehe authorized_keys-Eintrag im Runbook). Erwartet auf stdin die
# Konkatenation aus Private Key (tls.key) und Zertifikat/Chain (tls.crt) –
# die Reihenfolge ist egal, das Script erkennt beide PEM-Blocktypen selbst.
#
# Tut NICHTS anderes als: validieren, per midclt auf der TrueNAS-UI
# einspielen, alte Zertifikate aufräumen, und eine Kopie für den
# Caddy-Reverse-Proxy (Navidrome/Airsonic) ablegen.
#
# ACHTUNG: CERT_DATASET unten ist ein Platzhalter (Pool-Name "tank") –
# vor dem ersten Rollout an den tatsächlichen Pool-/Dataset-Namen anpassen.
# Ebenso: TrueNAS-Feldnamen (ui_certificate) können sich zwischen Versionen
# leicht unterscheiden – vor Produktivsetzung einmal manuell gegenprüfen:
#   midclt call system.general.config | python3 -m json.tool
# =============================================================================
set -euo pipefail

CERT_DATASET="/mnt/tank/certs/reckeweg.io"
REQUIRED_SAN="musicbox.reckeweg.io"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/stream.pem"

# Stream in Private Key und Zertifikat/Chain zerlegen (Reihenfolge egal).
awk -v work="$WORK" '
  /-----BEGIN .*PRIVATE KEY-----/ { mode="key" }
  /-----BEGIN CERTIFICATE-----/   { mode="cert" }
  mode=="key"  { print > (work "/key.pem") }
  mode=="cert" { print > (work "/fullchain.pem") }
' "$WORK/stream.pem"

[ -s "$WORK/key.pem" ] || { echo "[ERROR] Kein Private Key im Stream gefunden." >&2; exit 1; }
[ -s "$WORK/fullchain.pem" ] || { echo "[ERROR] Kein Zertifikat im Stream gefunden." >&2; exit 1; }

# Validieren, BEVOR irgendetwas angewendet wird.
openssl x509 -in "$WORK/fullchain.pem" -noout -checkend 0 \
  || { echo "[ERROR] Zertifikat ist bereits abgelaufen, breche ab." >&2; exit 1; }

openssl x509 -in "$WORK/fullchain.pem" -noout -text \
  | grep -q "DNS:${REQUIRED_SAN}" \
  || { echo "[ERROR] Zertifikat enthält ${REQUIRED_SAN} nicht als SAN, breche ab." >&2; exit 1; }

NAME="reckeweg-io-$(date +%Y%m%d%H%M%S)"

# JSON-Payload sicher über python3 bauen (kein jq-Dependency auf der Appliance nötig).
PAYLOAD="$(python3 - "$NAME" "$WORK/fullchain.pem" "$WORK/key.pem" <<'PY'
import json, sys
name, cert_path, key_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(cert_path) as f:
    cert = f.read()
with open(key_path) as f:
    key = f.read()
print(json.dumps({
    "create_type": "CERTIFICATE_CREATE_IMPORTED",
    "name": name,
    "certificate": cert,
    "privatekey": key,
}))
PY
)"

NEW_ID="$(midclt call certificate.create "$PAYLOAD" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"

[ -n "$NEW_ID" ] && [ "$NEW_ID" != "None" ] \
  || { echo "[ERROR] certificate.create lieferte keine ID zurück." >&2; exit 1; }

OLD_ID="$(midclt call system.general.config \
  | python3 -c 'import json,sys; c=json.load(sys.stdin); print(c.get("ui_certificate") or "")' || true)"

midclt call system.general.update "$(python3 -c "import json,sys; print(json.dumps({'ui_certificate': int(sys.argv[1])}))" "$NEW_ID")"

# ui_restart trennt die aktuell laufende HTTPS-Session der Middleware –
# das ist erwartet und KEIN Fehler.
midclt call system.general.ui_restart || true

if [ -n "$OLD_ID" ] && [ "$OLD_ID" != "$NEW_ID" ]; then
  midclt call certificate.delete "$OLD_ID" \
    || echo "[WARN] Altes Zertifikat (id=$OLD_ID) konnte nicht automatisch gelöscht werden, bitte manuell in der UI prüfen." >&2
fi

# Für Caddy (Navidrome/Airsonic) zusätzlich als Dateien ablegen.
mkdir -p "$CERT_DATASET"
install -m 600 "$WORK/fullchain.pem" "$CERT_DATASET/fullchain.pem"
install -m 600 "$WORK/key.pem" "$CERT_DATASET/privkey.pem"

echo "OK: TrueNAS-UI-Zertifikat aktualisiert (id=${NEW_ID}), Caddy-Dataset unter ${CERT_DATASET} aktualisiert."
