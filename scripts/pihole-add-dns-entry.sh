#!/usr/bin/env bash
#
# pihole-add-dns-entry.sh
#
# Legt einen internen *.reckeweg.io-Host in Pi-hole an ODER entfernt ihn
# wieder - als EINZIGER Weg dafuer, ersetzt die Pi-hole-Web-UI ("Local DNS
# Records"). Beide Aktionen fassen IMMER beide Config-Quellen zusammen an,
# nie nur eine:
#
#   - dns.hosts (custom.list): "IP hostname" - synct laut Doku automatisch
#     zwischen dns01/dns02, sichtbar in der Web-UI.
#   - misc.dnsmasq_lines: A-Record + leere AAAA-Zeile (NODATA-Block) - der
#     eigentlich wirksame Teil. Wird NICHT automatisch repliziert, muss
#     also explizit auf jedem Node gesetzt werden.
#
# Warum der AAAA-Block noetig ist: es gibt kein NAT-Hairpin auf der FritzBox
# (bestaetigt 2026-08-05/06). Jede App mit Dual-Stack-Aufloesung (getaddrinfo -
# also curl, Safari, Chrome; NICHT dig, das fragt nur A) bekommt sonst
# zusaetzlich die echte oeffentliche IPv6-Adresse ueber die *.reckeweg.io-
# Wildcard-Kette (Cloudflare -> MyFritz) und haengt sich in einer toten
# Verbindung auf, obwohl der A-Record laengst korrekt auf den Cluster zeigt.
# Genau das hat am 2026-08-06 ciq.reckeweg.io / ciq-api.reckeweg.io (und vier
# weitere ChromeIQ-Hosts) lahmgelegt - alle waren nur ueber die UI in
# custom.list angelegt, ohne diesen Block in misc.dnsmasq_lines.
#
# Deshalb fassen ADD und REMOVE hier IMMER beide Quellen zusammen an, in
# einem Durchlauf - eine halbfertige Eintragung (z.B. nur aus dns.hosts
# geloescht, in misc.dnsmasq_lines aber liegen geblieben) kann so nicht
# mehr entstehen.
#
# WICHTIG - WO DAS LAEUFT: Dieses Skript laeuft AUF dns01/dns02 selbst (es
# ruft "pihole-FTL --config ..." und "systemctl restart pihole-FTL" lokal
# auf), NICHT auf dem Mac oder einem anderen Admin-Rechner. Der normale Weg,
# es aufzurufen, ist NICHT direktes SSH+Ausfuehren von Hand, sondern das
# Ansible-Playbook, das es auf BEIDE Nodes verteilt und dort ausfuehrt:
#
#   ansible-playbook -i inventory/hosts.ini playbooks/add-dns-entry.yml \
#     -e dns_host=<hostname.reckeweg.io> -e dns_ip=<ip>
#
#   ansible-playbook -i inventory/hosts.ini playbooks/add-dns-entry.yml \
#     -e dns_action=remove -e dns_host=<hostname.reckeweg.io>
#
# (siehe ansible/playbooks/add-dns-entry.yml im seri-infrastructure-complete-
# Repo). Manuelles SSH+Ausfuehren auf einem einzelnen Node ist nur fuer
# Debugging/Reparatur gedacht, nicht der Regelbetrieb - sonst vergisst man
# wieder den zweiten Node, genau das Problem, das dieses Skript loesen soll.
#
# Muss, wenn manuell aufgerufen, auf JEDEM Pi-hole-Node einzeln laufen
# (dns01 UND dns02) - misc.dnsmasq_lines wird von nebula-sync NICHT
# automatisch repliziert (dns.hosts schon, siehe oben).
# Idempotent in beide Richtungen: beim Anlegen werden bereits vorhandene
# Eintraege je Quelle einzeln erkannt und uebersprungen (Konflikt mit
# ANDERER IP -> Abbruch statt Ueberschreiben); beim Entfernen wird ein
# nicht (mehr) vorhandener Eintrag je Quelle klaglos uebersprungen.
#
# Usage (lokal auf dns01/dns02, nur fuer Debugging):
#   sudo pihole-add-dns-entry.sh <hostname.reckeweg.io> <ip>       # anlegen
#   sudo pihole-add-dns-entry.sh --remove <hostname.reckeweg.io>   # entfernen
#
# Beispiele:
#   sudo pihole-add-dns-entry.sh ciq.reckeweg.io 192.168.20.100
#   sudo pihole-add-dns-entry.sh --remove ciq.reckeweg.io

set -euo pipefail

if [[ "${1:-}" == "--remove" ]]; then
  MODE="remove"
  HOST="${2:?Usage: $0 --remove <hostname.reckeweg.io>}"
  IP=""
else
  MODE="add"
  HOST="${1:?Usage: $0 <hostname.reckeweg.io> <ip>   (oder: $0 --remove <hostname.reckeweg.io>)}"
  IP="${2:?Usage: $0 <hostname.reckeweg.io> <ip>}"
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "Bitte mit sudo ausfuehren." >&2
  exit 1
fi

if ! command -v pihole-FTL >/dev/null 2>&1; then
  echo "FEHLER: pihole-FTL nicht gefunden." >&2
  echo "Dieses Skript laeuft NUR auf dns01/dns02 (den Pi-hole-Nodes selbst) -" >&2
  echo "nicht auf dem Mac oder einem anderen Rechner." >&2
  echo "Von aussen bitte ueber das Ansible-Playbook aufrufen:" >&2
  echo "  ansible-playbook -i inventory/hosts.ini playbooks/add-dns-entry.yml \\" >&2
  echo "    -e dns_host=<hostname.reckeweg.io> -e dns_ip=<ip>" >&2
  exit 1
fi

need_restart=false

# FTL gibt Array-Configs als "[ item, item, ... ]" aus - unquoted,
# komma-getrennt, kein JSON. Zum Lesen: Klammern weg, an Komma splitten, trimmen.
parse_ftl_array() {
  tr -d '[]' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$'
}

# Zum SETZEN erwartet FTL dagegen echtes JSON (quoted, komma-getrennt).
to_json_array() {
  local list="$1" json
  json=$(printf '%s\n' "${list}" | awk '{
    gsub(/\\/, "\\\\"); gsub(/"/, "\\\"");
    printf "\"%s\",", $0
  }' | sed 's/,$//')
  printf '[%s]' "${json}"
}

if [[ "${MODE}" == "add" ]]; then

  # --- dns.hosts (custom.list) -------------------------------------------
  HOSTS_LINE="${IP} ${HOST}"
  current_hosts=$(pihole-FTL --config dns.hosts | parse_ftl_array)

  if printf '%s\n' "${current_hosts}" | grep -qxF "${HOSTS_LINE}"; then
    echo "-> dns.hosts: ${HOST} -> ${IP} bereits vorhanden. Ignoriere."
  elif printf '%s\n' "${current_hosts}" | grep -qF " ${HOST}"; then
    echo "WARNUNG: ${HOST} steht in dns.hosts bereits mit einer ANDEREN IP:" >&2
    printf '%s\n' "${current_hosts}" | grep -F " ${HOST}" >&2
    echo "Bitte manuell bereinigen, kein automatisches Ueberschreiben." >&2
    exit 1
  else
    updated_hosts=$(printf '%s\n%s' "${current_hosts}" "${HOSTS_LINE}")
    pihole-FTL --config dns.hosts "$(to_json_array "${updated_hosts}")"
    echo "-> dns.hosts: ${HOST} -> ${IP} hinzugefuegt."
    need_restart=true
  fi

  # --- misc.dnsmasq_lines --------------------------------------------------
  A_LINE="address=/${HOST}/${IP}"
  AAAA_BLOCK_LINE="address=/${HOST}/"
  current_lines=$(pihole-FTL --config misc.dnsmasq_lines | parse_ftl_array)

  if printf '%s\n' "${current_lines}" | grep -qxF "${A_LINE}"; then
    echo "-> misc.dnsmasq_lines: ${HOST} -> ${IP} bereits vorhanden. Ignoriere."
  elif printf '%s\n' "${current_lines}" | grep -qF "address=/${HOST}/"; then
    echo "WARNUNG: ${HOST} steht in misc.dnsmasq_lines bereits mit einer ANDEREN IP:" >&2
    printf '%s\n' "${current_lines}" | grep -F "address=/${HOST}/" >&2
    echo "Bitte manuell bereinigen, kein automatisches Ueberschreiben." >&2
    exit 1
  else
    updated_lines=$(printf '%s\n%s\n%s' "${current_lines}" "${A_LINE}" "${AAAA_BLOCK_LINE}")
    pihole-FTL --config misc.dnsmasq_lines "$(to_json_array "${updated_lines}")"
    echo "-> misc.dnsmasq_lines: ${HOST} -> ${IP} + AAAA-NODATA hinzugefuegt."
    need_restart=true
  fi

  if [[ "${need_restart}" == true ]]; then
    systemctl restart pihole-FTL
    sleep 1
  fi

  echo "-> Verifikation:"
  printf "   A:    %s\n" "$(dig +short A "${HOST}" @127.0.0.1)"
  printf "   AAAA: %s (sollte leer sein)\n" "$(dig +short AAAA "${HOST}" @127.0.0.1)"

else  # MODE == remove

  # --- dns.hosts (custom.list) entfernen ----------------------------------
  current_hosts=$(pihole-FTL --config dns.hosts | parse_ftl_array)
  if printf '%s\n' "${current_hosts}" | awk -v h="${HOST}" '{n=split($0,a," "); if (a[n]==h) f=1} END{exit !f}'; then
    updated_hosts=$(printf '%s\n' "${current_hosts}" | awk -v h="${HOST}" '{n=split($0,a," "); if (a[n]!=h) print}')
    pihole-FTL --config dns.hosts "$(to_json_array "${updated_hosts}")"
    echo "-> dns.hosts: ${HOST} entfernt."
    need_restart=true
  else
    echo "-> dns.hosts: ${HOST} war nicht eingetragen. Ignoriere."
  fi

  # --- misc.dnsmasq_lines entfernen (A- + AAAA-NODATA-Zeile) --------------
  current_lines=$(pihole-FTL --config misc.dnsmasq_lines | parse_ftl_array)
  PREFIX="address=/${HOST}/"
  if printf '%s\n' "${current_lines}" | grep -qF "${PREFIX}"; then
    updated_lines=$(printf '%s\n' "${current_lines}" | awk -v p="${PREFIX}" 'index($0,p)!=1')
    pihole-FTL --config misc.dnsmasq_lines "$(to_json_array "${updated_lines}")"
    echo "-> misc.dnsmasq_lines: ${HOST} entfernt (A- und AAAA-NODATA-Zeile)."
    need_restart=true
  else
    echo "-> misc.dnsmasq_lines: ${HOST} war nicht eingetragen. Ignoriere."
  fi

  if [[ "${need_restart}" == true ]]; then
    systemctl restart pihole-FTL
    sleep 1
  fi

  echo "-> Verifikation (Hinweis: nach dem Entfernen greift ggf. Conditional"
  echo "   Forwarding oder die oeffentliche *.reckeweg.io-Wildcard-Kette -"
  echo "   ein Ergebnis hier ist nicht automatisch ein Fehler):"
  printf "   A:    %s\n" "$(dig +short A "${HOST}" @127.0.0.1)"
  printf "   AAAA: %s\n" "$(dig +short AAAA "${HOST}" @127.0.0.1)"

fi
