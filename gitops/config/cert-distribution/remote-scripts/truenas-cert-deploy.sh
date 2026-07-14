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
# TrueNAS-Feldnamen (ui_certificate) können sich zwischen Versionen leicht
# unterscheiden – vor Produktivsetzung einmal manuell gegenprüfen:
#   midclt call system.general.config | python3 -m json.tool
#
# Das Script selbst liegt NICHT unter /usr/local/bin - TrueNAS SCALEs
# Basis-OS ist read-only (immutable), auch für root. Es muss auf einem
# beschreibbaren Dataset liegen (bestätigt live am musicbox-Pool
# "data-pool"), siehe Runbook Abschnitt 3.3.
# =============================================================================
set -euo pipefail

# /mnt/data-pool/certs direkt unter der Pool-Wurzel ist für certdeploy
# nicht beschreibbar (Permission denied, live bestätigt 2026-07-14) -
# certdeploy besitzt aber sein eigenes Home-Dataset, dort funktioniert es.
CERT_DATASET="/mnt/data-pool/homes/certdeploy/certs/reckeweg.io"
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

# Deckt sowohl exakte SANs als auch ein passendes Wildcard-SAN ab
# (unser Cluster-Zertifikat ist *.reckeweg.io, nicht musicbox.reckeweg.io
# wörtlich - ein reiner Literal-Grep würde hier immer fehlschlagen).
SAN_PARENT="${REQUIRED_SAN#*.}"
openssl x509 -in "$WORK/fullchain.pem" -noout -text \
  | grep -qE "DNS:(${REQUIRED_SAN}|\*\.${SAN_PARENT})" \
  || { echo "[ERROR] Zertifikat enthält ${REQUIRED_SAN} nicht als SAN (auch nicht per Wildcard), breche ab." >&2; exit 1; }

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

# certificate.create ist ein Job: ohne -j liefert midclt sofort nur die
# Job-Tracking-ID zurück (ein anderer ID-Raum als Zertifikats-IDs!), was
# den nachfolgenden system.general.update mit "not a valid certificate"
# scheitern lässt - live bestätigt am 2026-07-14 (zwei verwaiste, aber
# valide Zertifikate mit falscher NEW_ID entstanden). -j lässt midclt auf
# den Job warten und dessen tatsächliches Ergebnis liefern; das Ergebnis
# robust gegen dict-mit-id ODER reinen Skalar parsen.
NEW_ID="$(midclt call -j certificate.create "$PAYLOAD" \
  | python3 -c 'import json,sys
r = json.load(sys.stdin)
print(r["id"] if isinstance(r, dict) else r)')"

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
