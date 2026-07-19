# Runbook: MyHomeIsMyCastle – Zertifikatsverteilung (musicbox + diskstation + Pi-hole/dns01)

**Ziel:** Das cluster-seitig bereits angelegte Wildcard-Zertifikat
(`*.reckeweg.io`) automatisiert auf die Synology DiskStation, die
TrueNAS-Box "musicbox" und Pi-hole (dns01, dediziertes Raspberry Pi 5)
ausrollen. Voraussetzung/Hintergrund: siehe
[myhomeismycastle-cert-distribution-konzept.md](myhomeismycastle-cert-distribution-konzept.md).

Cluster-seitige Manifeste sind bereits im Repo unter
[`gitops/config/cert-distribution/`](../gitops/config/cert-distribution/)
angelegt und werden von ArgoCD automatisch synct, sobald sie gepusht sind.
Dieses Runbook deckt die **manuellen Schritte auf DSM/TrueNAS** ab, die
niemand für dich automatisieren kann (Account-Anlage, Key-Installation,
Caddy-Setup), plus die Rollout-Reihenfolge.

## Übersicht: was ist schon erledigt, was ist manuell

| Schritt | Wer | Status |
|---|---|---|
| Wildcard-`Certificate`, RBAC, ConfigMap-Scripts, CronJob-Manifest | Ich (Repo) | ✅ erledigt |
| TrueNAS-SSH-Keypair generiert, Private Key versiegelt | Ich (Repo) | ✅ erledigt |
| Remote-Wrapper-Script `truenas-cert-deploy.sh` geschrieben | Ich (Repo) | ✅ erledigt |
| `seal-all-secrets.sh` um DSM-Credentials-Block erweitert | Ich (Repo) | ✅ erledigt |
| DSM Service-Account anlegen | **Du (DSM-UI)** | ✅ erledigt |
| DSM Login-Allowlist/Auto-Block konfigurieren | **Du (DSM-UI)** | ✅ erledigt |
| Altes Let's-Encrypt-Zertifikat auf DSM identifizieren/bereinigen | **Du (DSM-UI)** | ✅ erledigt |
| Erster automatisierter Import via CronJob (diskstation) | Ich (Job-Test) | ✅ erledigt, 2026-07-14 |
| TrueNAS Service-User anlegen | **Du (TrueNAS-UI)** | ✅ erledigt |
| SSH-Public-Key auf musicbox installieren (command-restricted) | **Du (TrueNAS-Shell)** | ✅ erledigt |
| Remote-Wrapper-Script installieren (Web-Shell, nicht scp - siehe 3.3) | **Du** | ✅ erledigt |
| Erster automatisierter Import via CronJob (musicbox, TrueNAS-UI-Cert) | Ich (Job-Test) | ✅ erledigt, 2026-07-14 |
| Caddy Custom App für Navidrome/Airsonic anlegen | **Du (TrueNAS-Apps-UI)** | ✅ erledigt, 2026-07-14 |
| Pi-hole Service-User `certdeploy` angelegt (SSH-Key, Passwort gesperrt) | **Du (dns01-Shell)** | ✅ erledigt, 2026-07-19 |
| SSH-Public-Key (derselbe wie TrueNAS) mit `command=` in `authorized_keys` installiert | **Du (dns01-Shell)** | ✅ erledigt, 2026-07-19 |
| Remote-Wrapper-Script `pihole-cert-deploy.sh` installiert | **Du (dns01-Shell)** | ✅ erledigt, 2026-07-19 |
| sudoers-Regel (`NOPASSWD` für genau dieses Script) angelegt | **Du (dns01-Shell)** | ✅ erledigt, 2026-07-19 |
| `pihole.toml` `[webserver]` Port konfiguriert | **Du (dns01-Shell)** | ✅ erledigt, 2026-07-19 |
| `pihole.toml` `[webserver.tls] validity = 0` gesetzt | **Du (dns01-Shell)** | ✅ erledigt, 2026-07-19 |
| Manueller Testlauf via SSH (Dummy-Zertifikat) | Ich (Anleitung) + Du (Ausführung) | ✅ erledigt, 2026-07-19 |
| `deploy-pihole.sh` in ConfigMap + CronJob eingebaut | Ich (Repo) | ✅ erledigt |
| Erster automatisierter Import via CronJob (dns01) | Ich (Job-Test) | ✅ erledigt, 2026-07-19 |
| `seal-all-secrets.sh` ausführen (DSM-Passwort eingeben) | **Du** | offen |
| Manifeste + Sealed Secrets committen & pushen | **Du** (ich kann vorbereiten) | teilweise |

---

## 1. Wildcard-Certificate ausrollen & verifizieren

Sobald `gitops/apps/cert-distribution.yaml` gepusht ist, holt ArgoCD den
Namespace, das `Certificate` und die RBAC-Ressourcen. Zertifikatsausstellung
prüfen:

```bash
kubectl get certificate wildcard-reckeweg-io -n cert-distribution
kubectl describe certificate wildcard-reckeweg-io -n cert-distribution
# Bei Problemen:
kubectl get challenges -n cert-distribution
kubectl logs -n cert-manager deploy/cert-manager -f
```

Erwartet: `READY: True` innerhalb weniger Minuten (DNS-01 über den bereits
bestehenden Cloudflare-Token, keine neue Berechtigung nötig – der Token hat
bereits Zone-DNS-Edit auf `reckeweg.io`, das reicht auch für die
`_acme-challenge`-TXT-Records des Wildcards).

## 2. DSM (diskstation.reckeweg.io)

### 2.1 Bestandsaufnahme des alten Zertifikats

Control Panel → Security → Certificate. Notiere:
- Welches Zertifikat ist aktuell `Default`?
- Für welche Domain wurde es ausgestellt (die "andere Domain", die bereinigt
  werden soll)?
- Läuft DSMs eigener Let's-Encrypt-Auto-Renew dafür (meist direkt in der
  Certificate-Verwaltung integriert, kein separater Scheduled Task)?

**Noch nichts löschen** – erst nach erfolgreichem Test in Schritt 2.4.

### 2.2 Service-Account anlegen (manuell, DSM-UI)

Control Panel → User & Group → Create:
- Name z.B. `cert-distributor`
- Starkes, zufälliges Passwort (Passwort-Manager) – **nicht an mich
  weitergeben**, direkt in Schritt 5 über `seal-all-secrets.sh` versiegeln.
- Gruppe: `administrators` (DSM erlaubt Certificate-Import nur für
  Admin-Konten – bekannte Einschränkung, keine feinere Rolle verfügbar).
- 2FA: **aus** (Account wird nur maschinell benutzt).
- Unter "Applications" / Erweiterte Berechtigungen (DSM 7.x): Desktop-/
  Portal-Zugriff für diesen Account deaktivieren, falls die Option existiert
  – reduziert die Angriffsfläche auf reine API-Nutzung.

### 2.3 Härtung

Control Panel → Security → Account:
- Auto-Block nach z.B. 5 Fehlversuchen aktivieren (falls noch nicht an).
- Login-Allowlist (Control Panel → Security → Firewall bzw. Account →
  Login-Einschränkung, je nach DSM-Version): Zugriff auf Port 5001 auf die
  Kubernetes-Node-Range (VLAN 20, `192.168.20.0/24`) beschränken – die
  CronJob-Pods laufen nicht dauerhaft auf einer festen IP, daher Subnetz statt
  Einzel-IP.

### 2.4 Erster manueller Test (empfohlen vor Automatisierung)

```bash
DSM_HOST=diskstation.reckeweg.io
printf "Passwort: "; read -rs DSM_PASSWORD; echo
# -G/--data-urlencode ist Pflicht: Sonderzeichen im Passwort (%, &, +, #, ...)
# machen sonst die Query-String-Interpretation auf DSM-Seite kaputt und
# führen zu "400 - No such account or incorrect password", obwohl Account
# und Passwort eigentlich stimmen.
SID=$(curl -sk -G "https://$DSM_HOST:5001/webapi/auth.cgi" \
  --data-urlencode "api=SYNO.API.Auth" \
  --data-urlencode "version=3" \
  --data-urlencode "method=login" \
  --data-urlencode "account=cert-distributor" \
  --data-urlencode "passwd=$DSM_PASSWORD" \
  --data-urlencode "session=Certificate" \
  --data-urlencode "format=sid" | jq -r .data.sid)
curl -sk "https://$DSM_HOST:5001/webapi/entry.cgi?api=SYNO.Core.Certificate.CRT&method=list&version=1&_sid=$SID" | jq .
```

`printf`+`read -rs` fragt das Passwort maskiert ab, statt es als
Klartext-Argument in die Shell-History zu schreiben (bewusst getrennt von
`read`, weil `-p` in zsh "von Coprocess lesen" statt "Prompt anzeigen"
bedeutet - unter zsh, dem macOS-Standard-Interactive-Shell, würde
`read -rsp "..."  DSM_PASSWORD` sonst mit `read: -p: no coprocess`
fehlschlagen). `$SID` und `$DSM_PASSWORD` bleiben nur in der aktuellen
Shell-Sitzung; Terminal danach schließen, wenn fertig getestet.

Wenn das eine Zertifikatsliste zurückgibt, funktioniert der Zugang. Kommt
weiterhin `{"error":{"code":400},...}` zurück, obwohl Account und Passwort
stimmen: Account-Gruppenmitgliedschaft (`administrators`) und die
Login-Allowlist aus 2.3 gegenprüfen – nicht jede Fehlerursache hinter Code
400 ist tatsächlich ein falsches Passwort.

**Wichtige Korrektur gegenüber der ursprünglichen Annahme (bestätigt am
2026-07-14):** `as_default=true` beim Import reicht bei einem **brandneuen**
Zertifikats-Import NICHT aus, um "Systemstandard" (DSM Desktop Service,
Port 5001 - das, was der Browser tatsächlich sieht) auf das neue Zertifikat
umzustellen. Jeder Dienst in Systemsteuerung → Sicherheit → Zertifikat hat
eine eigene, sticky Zertifikats-Zuordnung; `as_default` setzt nur das
globale Standard-Flag, rebinded aber keine bereits explizit zugeordneten
Dienste. Erst das **Löschen des alten Zertifikats** (`SYNO.Core.Certificate.CRT`,
`method=delete`, `id=<alte-cert-id>`) löst automatisch einen DSM-Webserver-
Neustart aus, bei dem verwaiste Dienst-Zuordnungen auf das neue Standard-
Zertifikat gepatcht werden. Praktische Konsequenz: die Reihenfolge aus
Schritt 2.1 ("erst testen, dann alten Cert löschen") funktioniert für den
**allerersten** Cutover nicht wie gedacht - man muss den alten Cert löschen,
BEVOR man im Browser sieht, ob es geklappt hat. Für **künftige automatische
Renewals** ist das unkritisch: die Renewal-Läufe finden über `desc=cert-manager`
denselben Zertifikats-Slot wieder und aktualisieren ihn per `id=`-Parameter
in-place (kein neuer Slot, kein Rebind-Problem).

Nach dem Löschen des alten Zertifikats: DSMs eigenen Auto-Renew dafür
prüfen/deaktivieren, damit kein zweiter Renewal-Mechanismus mehr aktiv ist.

**Chrome zeigt trotz gültigem Zertifikat "nicht sicher" an?** DevTools →
Security-Tab (nicht Console!) prüfen. Wenn dort "Certificate: valid and
trusted" und "Connection: secure" grün sind, aber unter "Resources" ein
Hinweis auf "active content with certificate errors" erscheint: das ist
eine **pro Origin gespeicherte Chrome-Berechtigung aus einer früheren
Sitzung** (z.B. während der alte, abgelaufene Cert noch aktiv war), keine
aktuelle Störung. Test: gleiche URL im Inkognito-Fenster öffnen - dort
sollte keine Warnung mehr erscheinen. Manche Chrome-Versionen (v141+)
bieten in den normalen Website-Einstellungen kein separates "Zurücksetzen"
mehr für "Unsichere Inhalte", nur noch Blockieren/Zulassen - die Warnung
bleibt dann bis zum nächsten Löschen der Website-Daten kosmetisch bestehen,
ist aber funktional irrelevant.

## 3. TrueNAS (musicbox.reckeweg.io)

### 3.1 Service-User anlegen (manuell, TrueNAS-UI)

Credentials → Users → Add:
- Username z.B. `certdeploy`
- Kein Passwort-Login nötig (nur SSH-Key)
- Shell: `bash` (für das Wrapper-Script)
- Muss `midclt` ausführen dürfen – auf TrueNAS SCALE i.d.R. an
  Admin-/`wheel`-Gruppenmitgliedschaft gekoppelt; ggf. `sudo`-Regel ohne
  Passwort speziell für `midclt`/das Wrapper-Script ergänzen, falls der
  Standard-User nicht ausreicht. Am einfachsten: User in dieselbe Gruppe wie
  der beim TrueNAS-Setup angelegte Admin-User aufnehmen.

### 3.2 SSH-Public-Key installieren

Der Key wurde bereits generiert (ed25519, Private Key liegt versiegelt in
[`sealed-secret-ssh-key.yaml`](../gitops/config/cert-distribution/sealed-secret-ssh-key.yaml)).
Public Key:

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILC6wKE9R1Nlc0JE5xD7CzQYhecHe90mCtgoGfC7fEOd cert-distributor@cert-distribution.cluster
```

In `~certdeploy/.ssh/authorized_keys` auf musicbox **command-restricted**
eintragen (ein Zeilen-Präfix, kein Freitext-SSH-Zugang):

```
command="/usr/local/bin/truenas-cert-deploy.sh",no-port-forwarding,no-pty,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILC6wKE9R1Nlc0JE5xD7CzQYhecHe90mCtgoGfC7fEOd cert-distributor@cert-distribution.cluster
```

Damit kann der Key **ausschließlich** dieses eine Script ausführen, egal
welches Kommando der Client anfordert.

### 3.3 Remote-Wrapper-Script installieren

**Korrektur gegenüber der ursprünglichen Annahme (live bestätigt am
2026-07-14):** TrueNAS SCALEs Basis-OS ist read-only/immutable, auch für
root – `/usr/local/bin/` ist damit **kein** gültiger Zielort, `sudo install`
dorthin scheitert mit "Read-only file system". Das Script muss auf einem
beschreibbaren Dataset liegen. Ebenso ist `/mnt/<pool>/certs/` direkt unter
der Pool-Wurzel für einen Nicht-root-User i.d.R. nicht beschreibbar
("Permission denied") – das eigene Home-Dataset des Service-Users
funktioniert zuverlässig.

Installation über die **TrueNAS-Web-Shell** (System Settings → Shell, oder
über SSH mit einem Account, der tatsächlich Shell-Zugriff hat – nicht über
den command-restricted Cluster-Key, der kann nur das fertige Script
ausführen):

```bash
sudo mkdir -p /mnt/<pool>/homes/certdeploy/bin
sudo tee /mnt/<pool>/homes/certdeploy/bin/truenas-cert-deploy.sh > /dev/null << 'SCRIPT_EOF'
# ... Inhalt von gitops/config/cert-distribution/remote-scripts/truenas-cert-deploy.sh ...
SCRIPT_EOF
sudo chown root:root /mnt/<pool>/homes/certdeploy/bin/truenas-cert-deploy.sh
sudo chmod 755 /mnt/<pool>/homes/certdeploy/bin/truenas-cert-deploy.sh
sudo chmod 755 /mnt/<pool>/homes/certdeploy/bin
```

`<pool>` durch den tatsächlichen Pool-Namen ersetzen (bei musicbox:
`data-pool`). Der `authorized_keys`-Eintrag aus 3.2 muss exakt auf diesen
Pfad zeigen (`command="/mnt/<pool>/homes/certdeploy/bin/truenas-cert-deploy.sh",...`).

**Vor dem ersten produktiven Lauf im Script prüfen (beides live bestätigt,
im aktuellen Script bereits korrekt):**
- `CERT_DATASET` zeigt auf ein Dataset, das `certdeploy` tatsächlich
  beschreiben darf – **nicht** `/mnt/<pool>/certs/...` direkt (Permission
  denied), sondern `/mnt/<pool>/homes/certdeploy/certs/...`.
- `midclt call certificate.create` und `midclt call certificate.delete`
  sind **Jobs** – `midclt call -j <method> ...` ist Pflicht, sonst liefert
  `midclt` sofort nur die Job-Tracking-ID zurück (ein anderer ID-Raum als
  Zertifikats-IDs), was nachgelagerte Aufrufe mit "not a valid certificate"
  scheitern lässt.
- Feldnamen-Check bei TrueNAS-Versionsupdates: `midclt call
  system.general.config | python3 -m json.tool` – prüfen, dass
  `ui_certificate` weiterhin so heißt.

Manueller Testlauf (simuliert, was der CronJob später automatisch macht) –
von einer Maschine mit Zugriff auf das Cluster-Secret, oder testweise mit
einem beliebigen gültigen Cert+Key-Paar:

```bash
cat /pfad/zu/tls.key /pfad/zu/tls.crt | ssh certdeploy@musicbox.reckeweg.io
```

Erwartete Ausgabe: `OK: TrueNAS-UI-Zertifikat aktualisiert (id=…), Caddy-Dataset unter … aktualisiert.`
Die aktuelle HTTPS-Session der TrueNAS-UI wird dabei kurz getrennt
(`ui_restart`) – das ist erwartetes Verhalten, kein Fehler.

Verifikation danach:

```bash
midclt call certificate.query   # neues Zertifikat vorhanden, altes ggf. weg
midclt call core.get_jobs '[["id","=",<job-id-aus-warn-meldung>]]'  # falls Cleanup als Job im Hintergrund lief
```

### 3.4 Caddy Custom App für Navidrome/Airsonic

**Erledigt und live verifiziert am 2026-07-14** – inklusive Browser-Test:
TrueNAS-UI, Navidrome und Airsonic sind alle drei per HTTPS erreichbar
(TrueNAS-UI auf 443 direkt, Navidrome/Airsonic auf 8443 über Caddy).

TrueNAS Apps → Discover Apps → Custom App akzeptiert eine Compose-YAML
direkt 1:1 zum Einfügen (kein separates Formular). Jede TrueNAS-App läuft
als eigenes Compose-Projekt mit eigenem Docker-Netzwerk
(`ix-navidrome-...`, `ix-airsonic-advanced-...`) – Caddy als neue,
separate App hängt NICHT automatisch im selben Netzwerk. Reverse-Proxy
daher über die auf dem Host published Ports, nicht über Container-Namen:

```bash
sudo docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}'
```

zeigt live die tatsächlichen Host-Ports (live bestätigt: Navidromes
internes 4533 ist NICHT published, aber 7070 ist es; Airsonic-Advanceds
internes 4040 ist als 6060 published – diese können sich bei App-Updates
ändern, vor jeder Änderung neu prüfen).

Caddyfile unter `/mnt/data-pool/apps/caddy/Caddyfile` (per `sudo tee`
angelegt, siehe vorherige Runbook-Version für den genauen Befehl):

```
navidrome.reckeweg.io:8443 {
  tls /certs/fullchain.pem /certs/privkey.pem
  reverse_proxy 192.168.11.53:7070
}

airsonic.reckeweg.io:8443 {
  tls /certs/fullchain.pem /certs/privkey.pem
  reverse_proxy 192.168.11.53:6060 {
    header_up X-Forwarded-Port 8443
  }
}
```

**`header_up X-Forwarded-Port 8443` bei Airsonic ist Pflicht, bei Navidrome
nicht nötig** (live bestätigt am 2026-07-14): Airsonic-Advanced ist
Spring-Boot-basiert und baut absolute Redirect-URLs (z.B. beim Login-
Redirect nach `/ui/signin`) aus den `X-Forwarded-*`-Headern zusammen. Ohne
explizites `X-Forwarded-Port` nimmt Spring den Default-Port des Schemas an
(443 bei https) statt den Port aus `X-Forwarded-Host` zu übernehmen –
Symptom: Redirect landet auf `https://airsonic.reckeweg.io/...` (ohne
`:8443`), Browser verbindet dadurch auf Port 443 = direkt die TrueNAS-UI,
zeigt deren Login-Seite statt Airsonic. Navidromes Redirect (`/app/`) ist
ein relativer Pfad ohne Host/Port und ist von diesem Problem nicht
betroffen. Bei künftigen Apps hinter Caddy: wenn ein Login-Redirect auf der
falschen "Seite" landet, zuerst die `Location`-Header auf fehlenden Port
prüfen (`curl -vk ... | grep -i location`), bevor man DNS/Zertifikat
verdächtigt.

Compose-Definition für die Custom App:

```yaml
services:
  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports:
      - "8443:8443"
    volumes:
      - /mnt/data-pool/homes/certdeploy/certs/reckeweg.io:/certs:ro
      - /mnt/data-pool/apps/caddy/Caddyfile:/etc/caddy/Caddyfile:ro
```

Port `8443` ist die Empfehlung aus dem Konzept (TrueNAS-UI bleibt
unverändert auf 443, Caddy übernimmt bewusst NICHT den Admin-Zugang – siehe
Entscheidungs-Log im Konzeptdokument). Kein `user:`-Override nötig, obwohl
`privkey.pem` mit `600` nur für `certdeploy` lesbar ist: der Container läuft
per Docker-Default als root, und root liest jede Datei unabhängig von
Unix-Permissions (kein User-Namespace-Remapping auf dieser TrueNAS-Instanz).
Ein `user:`-Override hätte zudem Caddys eigene `/config`/`/data`-Verzeichnisse
im Image (root-owned) unbeschreibbar gemacht. Caddy erkennt Änderungen an
den gemounteten Zertifikatsdateien automatisch (Polling), kein Reload nötig
– der CronJob überschreibt `fullchain.pem`/`privkey.pem` bei jedem
tatsächlichen Zertifikatswechsel (nicht bei jedem Lauf, siehe
Fingerprint-Vergleich in `common.sh`).

**Nicht vergessen – Pi-hole-Eintrag für JEDEN neuen Hostnamen:**
`navidrome.reckeweg.io` und `airsonic.reckeweg.io` sind neue Hostnamen, die
hier zum ersten Mal auftauchen – anders als `musicbox.reckeweg.io` oder
`diskstation.reckeweg.io` haben sie noch KEINEN lokalen Pi-hole-DNS-Eintrag.
Live bestätigt am 2026-07-14: ohne eigenen Eintrag fällt die Auflösung auf
was auch immer der Domain-Default liefert (hier: die Cluster-MetalLB-IP
`192.168.20.100`, VLAN 20) – von einem Management-VLAN-Client aus nicht
erreichbar ("Network is unreachable"), nicht mal ein TLS-/Connection-Fehler.
In Pi-hole unter Local DNS Records ergänzen:

| Hostname | Ziel |
|---|---|
| `navidrome.reckeweg.io` | `192.168.11.53` (musicbox, IP nicht Port – Caddy übernimmt das Routing anhand SNI/Host) |
| `airsonic.reckeweg.io` | `192.168.11.53` |

Diese Regel gilt generell für **jeden** neuen Hostnamen, der über dieses
System verteilt wird (auch künftig für Pi-hole selbst, siehe Backlog) –
DNS-Eintrag ist ein eigener, nicht automatisierter Schritt und gehört in
jede zukünftige Erweiterung mit hinein.

## 4. Secrets versiegeln (DSM-Credentials)

Sobald der DSM-Account aus Schritt 2.2 existiert:

```bash
cd /Users/achim.reckeweg/git/seri-infrastructure-complete
./gitops/sealed-secrets/seal-all-secrets.sh
```

Der neue Abschnitt "5. CERT-DISTRIBUTION" fragt `dsm-user`/`dsm-password`
interaktiv ab (maskierte Eingabe, verlässt nie die Shell) und schreibt
`gitops/config/cert-distribution/sealed-secret-dsm-credentials.yaml`.

## 5. Alles committen & pushen

```bash
git status
git add gitops/apps/cert-distribution.yaml gitops/config/cert-distribution/ gitops/sealed-secrets/seal-all-secrets.sh docs/myhomeismycastle-cert-distribution-*.md
git commit -m "feat(cert-distribution): TLS-Verteilung an musicbox + diskstation"
git push
```

(Push auf beide Remotes gemäß bisherigem Workflow – Gitea primär, GitHub
Backup.)

## 6. Ersten CronJob-Lauf beobachten

```bash
kubectl create job --from=cronjob/cert-distributor cert-distributor-manual-test -n cert-distribution
kubectl logs -n cert-distribution job/cert-distributor-manual-test -f
```

Erwartete Ausgabe: für beide Ziele entweder `[OK] ... importiert/übertragen`
oder (bei zweitem Lauf) `Fingerprint ... stimmt bereits überein, überspringe.`

## 7. Troubleshooting

| Symptom | Wahrscheinliche Ursache | Fix |
|---|---|---|
| `Certificate` bleibt `READY: False` | Cloudflare-DNS-01-Propagation dauert / Token-Scope reicht nicht für Apex+Wildcard | `kubectl describe challenge -n cert-distribution`, DNS manuell mit `dig TXT _acme-challenge.reckeweg.io` prüfen |
| DSM-Login schlägt fehl (`sid` leer) | Falscher Account, Auto-Block hat IP gesperrt, oder Account nicht in `administrators` | Control Panel → Security → Account-Log prüfen, Allowlist-Regel gegenprüfen |
| DSM-API antwortet `{"error":{"code":103}}` | `method` existiert nicht für die aufgerufene API - z.B. `method=list` ist unter `SYNO.Core.Certificate` nicht gültig, sondern nur unter `SYNO.Core.Certificate.CRT` (Import/Delete vs. Listing sind zwei getrennte Sub-APIs) | Verfügbare Version/Pfad gegenprüfen: `curl -sk ".../query.cgi?api=SYNO.API.Info&version=1&method=query&query=<API-Name>" \| jq .` - liefert aber nur Versions-/Pfad-Info, nicht die gültigen Methoden; im Zweifel die tatsächlich benutzte API in `deploy-dsm.sh` mit der Control-Panel-Netzwerk-Konsole (Browser-DevTools beim manuellen Zertifikatsimport) abgleichen |
| DSM-Import meldet Fehler zu `inter_cert` | Let's-Encrypt-Chain hat sich strukturell geändert (mehr/weniger PEM-Blöcke) | `awk`-Split in `common.sh` prüfen, `openssl crl2pkcs7 -nocrl -certfile /certs/tls.crt \| openssl pkcs7 -print_certs -noout` zur Diagnose |
| SSH zu musicbox schlägt fehl | `authorized_keys`-Zeile fehlerhaft, User existiert nicht, Host-Key-Mismatch | `ssh -v` gegen den Key testen, `StrictHostKeyChecking=accept-new` im Script fängt Erstverbindung ab, nicht spätere Host-Key-Änderungen |
| TrueNAS-Wrapper bricht mit "SAN nicht enthalten" ab | Wildcard-Cert enthält `musicbox.reckeweg.io` nicht (sollte durch `*.reckeweg.io` immer der Fall sein) | `openssl x509 -in tls.crt -noout -text \| grep DNS:` prüfen |
| `ui_restart` killt die SSH-Session mitten im Script | Erwartetes Verhalten von TrueNAS | Kein Fehler – Script läuft danach zu Ende, da `\|\| true` |
| Caddy liefert altes Zertifikat weiter aus | Datei-Polling-Intervall von Caddy noch nicht abgelaufen, oder Dataset-Pfad im Compose falsch gemountet | `docker exec` in den Caddy-Container, Dateidatum von `/certs/fullchain.pem` prüfen |
| SSH zu dns01 schlägt fehl | `authorized_keys`-Zeile fehlerhaft, User existiert nicht, oder `-s /bin/bash` fehlt (eine `nologin`-Shell verweigert auch SSH-Forced-Commands komplett) | `ssh -v` gegen den Key testen, `getent passwd certdeploy` prüfen |
| `pihole-cert-deploy.sh` bricht mit "SAN nicht enthalten" ab | Wildcard-Cert enthält `dns01.reckeweg.io` nicht (sollte durch `*.reckeweg.io` immer der Fall sein) | `openssl x509 -in tls.crt -noout -text \| grep DNS:` prüfen |
| `sudo /usr/local/bin/pihole-cert-deploy.sh` verlangt ein Passwort statt durchzulaufen | sudoers-Regel fehlt/falsch geschrieben | `sudo -l -U certdeploy` prüfen, Datei mit `visudo -c -f /etc/sudoers.d/certdeploy` auf Syntax prüfen |
| FTL liefert nach erfolgreichem Deploy trotzdem das alte/ein neues selbstsigniertes Zertifikat aus | `systemctl restart pihole-FTL` im Script schlug fehl, oder `[webserver.tls].validity` steht noch auf dem Default (47) und FTL hat beim nächsten Selfcheck ein eigenes generiert | `sudo journalctl -u pihole-FTL -n 50 --no-pager`, `sudo pihole-FTL --config webserver.tls.validity` (muss `0` sein) |

## 8. Pi-hole (dns01.reckeweg.io)

Pi-hole ist wie geplant von der DiskStation auf dedizierte Hardware
umgezogen (Raspberry Pi 5, `dns01.reckeweg.io`, 192.168.11.57) und damit aus
dem Backlog in den aktiven Scope gewandert. Anders als bei TrueNAS/DSM läuft
hier ein gewöhnliches Debian-System mit vollem Shell-Zugriff – SSH mit
command-restricted Key ist der naheliegende Weg, keine appliance-spezifische
API nötig. Alle Schritte unten sind **live durchgeführt und bestätigt am
2026-07-19**.

### 8.1 Service-User anlegen

```bash
sudo useradd -m -s /bin/bash certdeploy
sudo passwd -l certdeploy   # kein Passwort-Login, nur SSH-Key
sudo mkdir -p /home/certdeploy/.ssh
sudo chmod 700 /home/certdeploy/.ssh
sudo chown -R certdeploy:certdeploy /home/certdeploy/.ssh
```

`-s /bin/bash` ist Pflicht, nicht `nologin`: SSHs `command=`-Forced-Command-
Mechanismus führt den Befehl über die Login-Shell des Accounts aus – eine
`nologin`-Shell verweigert das komplett, auch für eingeschränkte Kommandos.

### 8.2 SSH-Key wiederverwenden

Kein neuer Key nötig – derselbe `cert-distributor@cert-distribution.cluster`-
Key wie bei musicbox (siehe 3.2) wird hier mit einem anderen `command=`
eingetragen, in `/home/certdeploy/.ssh/authorized_keys`
(Owner `certdeploy:certdeploy`, Mode `600`):

```
command="sudo /usr/local/bin/pihole-cert-deploy.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILC6wKE9R1Nlc0JE5xD7CzQYhecHe90mCtgoGfC7fEOd cert-distributor@cert-distribution.cluster
```

### 8.3 Remote-Wrapper-Script + sudoers

FTL läuft als OS-User `pihole` (`uid=999(pihole) gid=1002(pihole)`),
`/etc/pihole/` gehört `pihole:pihole` – `certdeploy` kann dort nicht direkt
schreiben. Anders als bei TrueNAS (Gruppenmitgliedschaft für `midclt`) löst
das hier eine eng gefasste `sudoers`-Regel, die ausschließlich das eine
Wrapper-Script ohne Passwort erlaubt:

```bash
sudo tee /usr/local/bin/pihole-cert-deploy.sh > /dev/null << 'SCRIPT_EOF'
# ... Inhalt von gitops/config/cert-distribution/remote-scripts/pihole-cert-deploy.sh ...
SCRIPT_EOF
sudo chown root:root /usr/local/bin/pihole-cert-deploy.sh
sudo chmod 750 /usr/local/bin/pihole-cert-deploy.sh

sudo visudo -f /etc/sudoers.d/certdeploy
# Inhalt der Datei:
#   certdeploy ALL=(root) NOPASSWD: /usr/local/bin/pihole-cert-deploy.sh
```

FTL erwartet (anders als TrueNAS/`midclt` mit getrennten cert/key-Feldern)
eine **kombinierte** PEM-Datei mit Zertifikat UND Private Key in einer Datei
– das Script splittet daher nichts, sondern validiert und schreibt den
Stream unverändert weg.

### 8.4 `pihole.toml` konfigurieren

`sudo vi /etc/pihole/pihole.toml`, dann `sudo systemctl restart pihole-FTL`:

- `[webserver]` → `port = "80o,443os,[::]:80o,[::]:443os"` – das `o` macht
  jeden Port optional, falls einer mal nicht binden kann.
- `[webserver.tls]` → `cert = "/etc/pihole/tls.pem"` (Default, passt so),
  **und zusätzlich `validity = 0` setzen** – sonst versucht FTL alle 47 Tage,
  das per cert-manager verteilte Zertifikat durch ein neues selbstsigniertes
  zu überschreiben. Am einfachsten direkt per `pihole-FTL --config`
  (kein manuelles Editieren von `pihole.toml` nötig):

  ```bash
  sudo pihole-FTL --config webserver.tls.validity 0
  sudo systemctl restart pihole-FTL
  ```

  Live bestätigt am 2026-07-19: `sudo pihole-FTL --config
  webserver.tls.validity` liefert `0`.

### 8.5 Manueller Testlauf

Von einer Maschine mit Zugriff auf das Cluster-Secret (Private Key existiert
nach dem Sealing sonst nirgends mehr im Klartext):

```bash
kubectl get secret cert-distributor-ssh-key -n cert-distribution \
  -o jsonpath='{.data.ssh-privatekey}' | base64 -d > /tmp/certdeploy_key
chmod 600 /tmp/certdeploy_key

openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/k.pem -out /tmp/c.pem \
  -days 1 -subj "/CN=dns01.reckeweg.io" \
  -addext "subjectAltName=DNS:dns01.reckeweg.io"
cat /tmp/c.pem /tmp/k.pem | ssh -i /tmp/certdeploy_key certdeploy@dns01

rm -f /tmp/certdeploy_key   # sofort danach wieder löschen
```

Erwartete Ausgabe: `OK: Pi-hole TLS-Zertifikat aktualisiert.` – **live
bestätigt am 2026-07-19**. `/etc/pihole/tls.pem` danach `pihole:pihole`,
Mode `600`.

### 8.6 Erster echter CronJob-Lauf

**Live bestätigt am 2026-07-19** (`kubectl create job --from=cronjob/cert-distributor
... -n cert-distribution`): alle drei Ziele in einem Lauf, DSM und TrueNAS
übersprungen (Fingerprint stimmte bereits), Pi-hole erhielt zum ersten Mal
automatisiert das echte cert-manager-Wildcard-Zertifikat:

```
== DSM (diskstation.reckeweg.io) ==
  Fingerprint auf diskstation.reckeweg.io:5001 stimmt bereits überein, überspringe.
== TrueNAS (musicbox.reckeweg.io) ==
  Fingerprint auf musicbox.reckeweg.io:443 stimmt bereits überein, überspringe.
== Pi-hole (dns01.reckeweg.io) ==
OK: Pi-hole TLS-Zertifikat aktualisiert.
  [OK] Zertifikat an Pi-hole übertragen (Remote-Script validiert und wendet an).
```

Damit ist Pi-hole/dns01 auf demselben Reifegrad wie musicbox/diskstation:
vollautomatisiert, täglich um 03:20 Uhr, Fingerprint-gesteuert.

## Backlog

- dns02 (redundanter Pi-hole-Secondary): DNS-Platzhaltereintrag
  (`dns02.reckeweg.io`, 192.168.11.58) existiert bereits, die Hardware/der
  Pi-hole-Betrieb noch nicht. Sobald aufgebaut: identische
  certdeploy/sudoers/Wrapper-Script-Einrichtung wie dns01 (Abschnitt 8 oben),
  plus Ergänzung von `deploy-pihole.sh` um ein zweites Ziel.
- Alerting auf `certmanager_certificate_expiration_timestamp_seconds`.
- Eigenes CronJob-Image statt `apk add` bei jedem Lauf.

Details und Begründungen: siehe
[myhomeismycastle-cert-distribution-konzept.md](myhomeismycastle-cert-distribution-konzept.md).
