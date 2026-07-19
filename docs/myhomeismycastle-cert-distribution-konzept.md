# Konzept: MyHomeIsMyCastle – Zertifikatsverteilung an externe Geräte

**Ziel:** Von `cert-manager` im Cluster ausgestellte Let's-Encrypt-Zertifikate
automatisiert an Geräte außerhalb des Clusters verteilen, die kein eigenes
ACME können oder sollen (Synology DSM, TrueNAS, Pi-hole). Diese Runde deckt
**musicbox** (TrueNAS), **diskstation** (Synology DSM) und **dns01**
(Pi-hole, dediziertes Raspberry Pi 5) ab.

## Grundidee

`cert-manager` kann nur ausstellen. Das eigentliche Problem ist die Verteilung
an Geräte außerhalb des Clusters. Dafür gibt es zwei Muster:

- **Muster A – Traefik davor:** Für reine Web-UIs terminiert Traefik TLS mit
  dem Cluster-Zertifikat, das Backend bleibt HTTP. Keine Verteilungslogik
  nötig, aber ungeeignet für Geräte, die auch von Nicht-HTTP-Clients direkt
  angesprochen werden (DSM: WebDAV/SMB/Login-Redirects; jedes Gerät mit
  eigenem Admin-UI, das man nicht hinter den Cluster hängen will) und bringt
  eine Data-Plane-Abhängigkeit auf den Cluster mit, die man bei manchen
  Geräten (DNS!) nicht will.
- **Muster B – echtes Zertifikat aufs Gerät:** Ein Verteiler-Job im Cluster
  schiebt das fertige Zertifikat per API/SSH auf jedes Ziel. Mehr
  Implementierungsaufwand pro Zielsystem, aber keine Laufzeit-Abhängigkeit
  vom Cluster – fällt der Cluster aus, laufen die Geräte mit ihrem zuletzt
  verteilten (noch gültigen) Zertifikat einfach weiter.

Für **musicbox** und **diskstation** fällt die Wahl auf **Muster B**: beide
Geräte haben Dienste, die nicht ausschließlich über HTTP/Traefik laufen
(DSM-Systemdienste; TrueNAS-Storage-Management), und beide sollen auch bei
Cluster-Ausfall mit gültigem TLS weiterlaufen.

> Für Pi-hole war Muster B ohnehin die einzige Option: DNS → Cluster →
> Traefik → DNS wäre ein zirkulärer Single-Point-of-Failure.
> `cert-manager` bleibt dabei zwar eine **Control-Plane-Abhängigkeit**
> (Renewal alle ~60 Tage, asynchron, unkritisch), aber nie eine
> **Data-Plane-Abhängigkeit** (jede DNS-Anfrage) – der Worst Case ist ein
> abgelaufenes Web-UI-Zertifikat, FTL löst weiter auf.

## Scope dieser Runde

| Ziel | Hostname | IP | Status |
|---|---|---|---|
| Synology DSM | `diskstation.reckeweg.io` | 192.168.11.55 | Umsetzung jetzt |
| TrueNAS SCALE "GoldenEye" 25.10.04 Community | `musicbox.reckeweg.io` | 192.168.11.53 | Umsetzung jetzt |
| Navidrome (Docker-App auf musicbox) | `navidrome.reckeweg.io` | 192.168.11.53 | Umsetzung jetzt (via Caddy) |
| Airsonic (Docker-App auf musicbox) | `airsonic.reckeweg.io` | 192.168.11.53 | Umsetzung jetzt (via Caddy) |
| bonob (Sonos↔Subsonic-Bridge) | – | 192.168.11.53 | Kein eigenes Web-UI, kein Hostname nötig |
| Postgres (Backend für Navidrome/Airsonic) | – | 192.168.11.53 | Reines Backend, kein TLS/Hostname nötig |
| Pi-hole (primär) | `dns01.reckeweg.io` | 192.168.11.57 | Umsetzung jetzt |

`nas.reckeweg.io` aus einem früheren Konzeptentwurf existiert nicht – korrekt
ist `diskstation.reckeweg.io`. `dns.reckeweg.io` (192.168.11.56) ist die per
`keepalived` geswitchte Floating-VIP für DNS-Lookups – unabhängig davon,
welcher Host das Web-UI bedient, kein eigenes Cert-Distribution-Ziel.
`dns02.reckeweg.io` (192.168.11.58) ist als redundanter Pi-hole-Secondary
vorgesehen, aber noch nicht aufgebaut – siehe Backlog.

## Architektur

```
cert-manager (ClusterIssuer letsencrypt-prod, DNS-01 via Cloudflare)
      │
      ▼
Certificate "wildcard-reckeweg-io"        Namespace: cert-distribution
  dnsNames: reckeweg.io, *.reckeweg.io
  RSA-2048, rotationPolicy: Always        (RSA statt ECDSA – manche
  secretName: wildcard-reckeweg-io-tls     Appliances/Firmwares kommen mit
      │                                    ECDSA-Zertifikaten nicht klar)
      ▼
CronJob "cert-distributor" (täglich 03:20, Namespace cert-distribution)
  RBAC: darf nur genau dieses eine Secret lesen
  Pro Ziel: SHA256-Fingerprint des aktuell ausgelieferten Zertifikats
  mit dem lokalen Fingerprint vergleichen → nur bei Abweichung deployen
  (stateless, kein persistenter Renewal-Watcher nötig)
      │
      ├─ deploy-dsm.sh ──────► HTTPS Web-API (SYNO.API.Auth + SYNO.Core.Certificate)
      │                         diskstation.reckeweg.io:5001
      │
      ├─ deploy-truenas.sh ──► SSH (command-restricted Key) ──► musicbox.reckeweg.io
      │                          └─► truenas-cert-deploy.sh (läuft AUF der Box)
      │                                ├─ validiert (Ablauf, SAN-Check)
      │                                ├─ midclt certificate.create/system.general.update
      │                                │  → TrueNAS-UI-Zertifikat (Port 443)
      │                                └─ legt fullchain.pem/privkey.pem auf einem
      │                                   Dataset ab → liest Caddy read-only
      │
      └─ deploy-pihole.sh ───► SSH (derselbe command-restricted Key,
                                  anderes command=) ──► dns01.reckeweg.io
                                  └─► pihole-cert-deploy.sh (läuft AUF der Box)
                                        ├─ validiert (Ablauf, SAN-Check)
                                        ├─ schreibt /etc/pihole/tls.pem (kombinierte
                                        │  PEM-Datei, owner pihole:pihole) über eine
                                        │  eng gefasste NOPASSWD-sudoers-Regel für
                                        │  genau dieses eine Script
                                        └─ systemctl restart pihole-FTL

Auf musicbox zusätzlich (TrueNAS "Custom App", unabhängig vom Cluster):
  Caddy auf Alt-Port (siehe Runbook) → reverse_proxy
    navidrome.reckeweg.io → navidrome:4533
    airsonic.reckeweg.io  → airsonic:4040
  Die TrueNAS-UI selbst bleibt direkt auf Port 443 – Caddy fronted sie
  NICHT (bewusste Entscheidung, siehe Entscheidungs-Log).
```

## Entscheidungs-Log

**Wildcard statt Pro-App-Zertifikat.** Bestehende In-Cluster-Apps
(`auditique`, `homeassistant`, …) bekommen weiterhin je ein eigenes
`Certificate` – das bleibt unverändert. Für die Geräteverteilung ist ein
Wildcard (`*.reckeweg.io` + Apex) die richtige Ausnahme: jedes künftige Ziel
(Pi-hole, weitere Hosts) ist damit ohne neues Zertifikat und ohne neue
Let's-Encrypt-Order abgedeckt – nur ein neuer Deploy-Hook wird nötig.

**Zwei verschiedene Verteilungsmechanismen (DSM vs. TrueNAS).** DSM bietet
mit `SYNO.Core.Certificate` eine offizielle, nicht als deprecated markierte
Web-API – das macht auch der offizielle `acme.sh`-Hook für Synology so, daher
reicht dort reines HTTPS ohne SSH. TrueNAS SCALE hat seine REST-API seit
25.04 als deprecated markiert (Entfernung angekündigt für Version 26, ab
25.10.1 tägliche Alerts bei Nutzung deprecateter Endpunkte) – dort ist
`midclt` per SSH der von TrueNAS selbst empfohlene, zukunftssichere Weg.
Diese Inkonsistenz ist bewusst und dokumentiert, keine versehentliche
Uneinheitlichkeit.

**Caddy fronted NICHT die TrueNAS-UI.** Diskutierte Alternative: Caddy
übernimmt Port 443 komplett (auch für die TrueNAS-UI selbst, die dann auf
einen internen Alt-Port als Break-Glass-Zugang verschoben würde) – dann
wären alle drei Hostnamen auf der Box ohne Port-Suffix erreichbar. Dagegen
entschieden: die TrueNAS-UI ist die höchstprivilegierte Oberfläche der Box
(Storage, Nutzer, alles), und ein zusätzlicher Hop durch einen
Allzweck-Proxy-Container im Pfad des Admin-Zugangs vergrößert dessen
Angriffs-/Ausfallfläche unnötig. Stattdessen: TrueNAS-UI bleibt unverändert
auf 443 direkt erreichbar, Caddy übernimmt nur Navidrome/Airsonic auf einem
Alt-Port (konkreter Port: siehe Runbook).

**bonob ohne eigenen Hostnamen.** bonob ist eine Sonos↔Subsonic-Bridge ohne
eigenes Web-UI – sie ruft Navidrome/Airsonic als Client auf, wird selbst
nicht von außen angesprochen. Kein Certificate-Bedarf.

**RSA-2048 statt ECDSA.** Aus der ursprünglichen Konzeptdiskussion
übernommen: ältere Appliance-/Firmware-TLS-Stacks (Synology, teils auch
TrueNAS-Subsysteme) haben mit ECDSA-Zertifikaten schon Kompatibilitätsprobleme
gezeigt. RSA-2048 ist der konservativere, breiter kompatible Default.

**Pi-hole nutzt SSH wie TrueNAS, nicht die DSM-Web-API-Variante.** Pi-hole v6
(FTL) hat keine offizielle Zertifikats-Import-API. Anders als TrueNAS läuft
Pi-hole aber auf einem gewöhnlichen Debian-System mit vollem Shell-Zugriff –
SSH mit command-restricted Key ist hier der naheliegende Weg, keine
appliance-spezifische API nötig. Der bereits existierende
`cert-distributor`-SSH-Key wird wiederverwendet: derselbe Public Key steht
jetzt sowohl in musicboxs als auch in dns01s `authorized_keys`, jeweils mit
unterschiedlichem `command=`-Forced-Command – kein zusätzliches SealedSecret
nötig.

**Least-Privilege ohne Gruppenmitgliedschaft (Pi-hole).** TrueNAS braucht für
`midclt` eine Gruppenmitgliedschaft mit erweiterten Rechten für den
Service-User. Auf dns01 bekommt `certdeploy` stattdessen keine erweiterten
Gruppenrechte, sondern eine `sudoers`-Regel, die exakt ein Script
(`pihole-cert-deploy.sh`) ohne Passwort erlaubt – kombiniert mit dem
command-restricted SSH-Key ergeben sich zwei unabhängige
Einschränkungsebenen für denselben Zugriff.

## Sicherheitsmodell

- **RBAC:** Der `cert-distributor`-ServiceAccount darf im Cluster
  ausschließlich das eine Secret `wildcard-reckeweg-io-tls` lesen (`Role` mit
  `resourceNames`-Einschränkung) – kein Zugriff auf andere Secrets/Namespaces.
- **SSH-Key command-restricted:** Derselbe Key, mit dem der CronJob auf
  musicbox zugreift, ist auch auf dns01 hinterlegt – in `authorized_keys`
  jeweils auf ein einziges festes Kommando beschränkt
  (`command="...truenas-cert-deploy.sh",...` bzw.
  `command="sudo .../pihole-cert-deploy.sh",...`). Selbst bei kompromittiertem
  Key/SealedSecret-Master-Key kann der Cluster auf beiden Zielen
  ausschließlich Zertifikate deployen, sonst nichts.
- **sudoers statt Gruppenmitgliedschaft (Pi-hole):** `certdeploy` auf dns01
  hat keine `sudo`-Rechte außer für exakt
  `/usr/local/bin/pihole-cert-deploy.sh` (NOPASSWD,
  `/etc/sudoers.d/certdeploy`). Zwei unabhängige Einschränkungsebenen: selbst
  wer den SSH-Forced-Command umgehen könnte, stößt auf eine sudoers-Regel,
  die nur dasselbe eine Script erlaubt.
- **Remote-seitige Validierung:** `truenas-cert-deploy.sh` und
  `pihole-cert-deploy.sh` prüfen beide Ablaufdatum (`openssl x509 -checkend
  0`) und SAN (`musicbox.reckeweg.io` bzw. `dns01.reckeweg.io` muss enthalten
  sein) BEVOR irgendetwas angewendet wird.
- **DSM-Härtung:** Der DSM-Service-Account braucht (DSM-bedingt) lokale
  Admin-Rechte, um Zertifikate importieren zu dürfen – das ist eine bekannte
  DSM-Einschränkung, keine granularere Rolle verfügbar. Mitigation im
  Runbook: Login-IP-Allowlist auf die Kubernetes-VLAN-Range, Auto-Block nach
  Fehlversuchen, kein Desktop-/Portal-Zugriff für den Account, Passwort
  ausschließlich als SealedSecret (nie im Klartext im Repo).
- **Stateless Verteiler:** Kein persistenter Renewal-Watcher – der Fingerprint-
  Vergleich bei jedem Lauf reicht. Ein kaputter CronJob fällt lange vor
  Ablauf auf (Let's-Encrypt-Renewal läuft 30 Tage vor Ablauf).

## Cluster-weite Erkenntnisse aus dem ersten Rollout (2026-07-14)

Bei der Erstausstellung des Wildcard-Zertifikats sind zwei Dinge zutage
getreten, die über cert-distribution hinaus relevant sind:

- **cert-manager prüft DNS-01-Propagation jetzt über öffentliche Resolver,
  nicht mehr über die Cluster-Default-Route.** Ursprünglich hing die
  Erstausstellung >2h fest, weil cert-manager seinen Propagation-Selfcheck
  über CoreDNS → Node-`resolv.conf` → Pi-hole (192.168.11.55) macht, und
  Pi-hole eine negative Antwort für den frisch angelegten
  `_acme-challenge`-TXT-Record gecached hatte, weit über die SOA-Negative-TTL
  hinaus. Fix (siehe `gitops/apps/cert-manager.yaml`):
  `--dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53` +
  `--dns01-recursive-nameservers-only=true`. Das betrifft **alle** künftigen
  DNS-01-Zertifikate im Cluster, nicht nur dieses Wildcard-Zertifikat.
- **`*.reckeweg.io` ist per CNAME auf die FritzBox delegiert**
  (`achim.reckeweg.io` → `t0dv6nfx59d5d3r6.myfritz.net`, dokumentiert in
  `myHomeIsMyCastle: Netzwerk_FritzBox.md`) für externen Zugriff/Port-
  Forwarding/VPN. Das ist kein Konflikt mit den `_acme-challenge`-TXT-Records
  von cert-manager, da ein spezifischer Record-Name (`_acme-challenge.reckeweg.io`
  TXT) einen Wildcard-CNAME-Treffer (`*.reckeweg.io`) korrekt überstimmt –
  bestätigt durch erfolgreiche Ausstellung. Wichtig für alle künftigen
  DNS-Änderungen an der Zone: dieser Wildcard-CNAME nicht versehentlich
  anfassen/löschen, er ist aktiv genutzte Netzwerk-Infrastruktur, kein
  Altlast-Rest.

## Backlog (nicht Teil dieser Runde)

- **dns02 (redundanter Pi-hole-Secondary):** DNS-Platzhaltereintrag
  (`dns02.reckeweg.io`, 192.168.11.58) existiert bereits, die Hardware/der
  Pi-hole-Betrieb noch nicht. Sobald aufgebaut: identische
  certdeploy/sudoers/Wrapper-Script-Einrichtung wie dns01 (Runbook Abschnitt
  8), plus Ergänzung von `deploy-pihole.sh` um ein zweites Ziel.
- **Alerting** auf `certmanager_certificate_expiration_timestamp_seconds`
  (kube-prometheus-stack ist bereits im Cluster vorhanden) – bisher nicht
  eingerichtet, sollte nachgezogen werden, sobald diese Runde stabil läuft.
- **Custom Cronjob-Image** statt `apk add --no-cache ...` bei jedem Lauf
  (aktuell akzeptiertes MVP – kostet nur ein paar Sekunden Laufzeit pro Tag,
  spart aber den Aufwand, ein eigenes Image zu bauen/pushen).
