# Runbook: MyHomeIsMyCastle – Zertifikatsverteilung (musicbox + diskstation)

**Ziel:** Das cluster-seitig bereits angelegte Wildcard-Zertifikat
(`*.reckeweg.io`) automatisiert auf die Synology DiskStation und die
TrueNAS-Box "musicbox" ausrollen. Voraussetzung/Hintergrund: siehe
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
| TrueNAS Service-User anlegen | **Du (TrueNAS-UI)** | offen |
| SSH-Public-Key auf musicbox installieren (command-restricted) | **Du (TrueNAS-Shell)** | offen |
| Remote-Wrapper-Script per `scp` auf musicbox bringen | **Du** | offen |
| Caddy Custom App für Navidrome/Airsonic anlegen | **Du (TrueNAS-Apps-UI)** | offen |
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

TrueNAS Apps → Discover Apps → Custom App. Grundgerüst (Ports/Container-Namen
an die tatsächliche App-Konfiguration anpassen):

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

`Caddyfile`:

```
navidrome.reckeweg.io:8443 {
  tls /certs/fullchain.pem /certs/privkey.pem
  reverse_proxy navidrome:4533
}

airsonic.reckeweg.io:8443 {
  tls /certs/fullchain.pem /certs/privkey.pem
  reverse_proxy airsonic:4040
}
```

Port `8443` ist die Empfehlung aus dem Konzept (TrueNAS-UI bleibt
unverändert auf 443, Caddy übernimmt bewusst NICHT den Admin-Zugang – siehe
Entscheidungs-Log im Konzeptdokument). `navidrome`/`airsonic` als Hostnamen
im `reverse_proxy` setzen nur, wenn Caddy im selben Docker-Netzwerk wie die
Apps hängt – sonst durch die tatsächliche Container-IP/den Host-Port
ersetzen. Caddy erkennt Änderungen an den gemounteten Zertifikatsdateien
automatisch (Polling), kein Reload nötig.

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

## Backlog

- Pi-hole-Verteilung, sobald die neuen Pi-hole-Geräte final stehen.
- Alerting auf `certmanager_certificate_expiration_timestamp_seconds`.
- Eigenes CronJob-Image statt `apk add` bei jedem Lauf.

Details und Begründungen: siehe
[myhomeismycastle-cert-distribution-konzept.md](myhomeismycastle-cert-distribution-konzept.md).
