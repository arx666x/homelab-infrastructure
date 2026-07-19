#!/usr/bin/env bash
# =============================================================================
# pihole-cert-deploy.sh
#
# Läuft AUF Pi-hole (dns01). Wird ausschließlich über den command-restricted
# SSH-Key aus dem cert-distributor-CronJob aufgerufen (derselbe Key wie für
# musicbox, siehe authorized_keys-Eintrag im Runbook Abschnitt 8.2). Erwartet
# auf stdin die Konkatenation aus Zertifikat/Chain (tls.crt) und Private Key
# (tls.key) - Reihenfolge egal, das Script erkennt nur den CERTIFICATE-Block
# für die Validierung, schreibt den kompletten Stream unverändert weg.
#
# Anders als bei TrueNAS (getrennte cert/key-Felder für midclt) will Pi-hole
# FTL EINE kombinierte PEM-Datei mit beiden Blöcken (siehe pihole.toml,
# [webserver.tls].cert-Kommentar).
#
# Läuft selbst nicht als root - schreibt/restartet über eine eng gefasste
# NOPASSWD-sudoers-Regel für GENAU dieses Script (siehe Runbook Abschnitt 8.3),
# aufgerufen per "sudo" im command= der authorized_keys-Zeile. FTL läuft als
# OS-User 'pihole' (uid 999, gid 1002 auf dns01) - die Zieldatei muss dessen
# Owner sein, sonst kann FTL sie beim Neustart nicht lesen.
# =============================================================================
set -euo pipefail

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/tls.pem"

openssl x509 -in "$WORK/tls.pem" -noout -checkend 0 \
  || { echo "[ERROR] Zertifikat ist bereits abgelaufen, breche ab." >&2; exit 1; }

openssl x509 -in "$WORK/tls.pem" -noout -text \
  | grep -qE 'DNS:(dns01\.reckeweg\.io|\*\.reckeweg\.io)' \
  || { echo "[ERROR] Zertifikat enthält dns01.reckeweg.io nicht als SAN (auch nicht per Wildcard), breche ab." >&2; exit 1; }

install -o pihole -g pihole -m 600 "$WORK/tls.pem" /etc/pihole/tls.pem
systemctl restart pihole-FTL

echo "OK: Pi-hole TLS-Zertifikat aktualisiert."
