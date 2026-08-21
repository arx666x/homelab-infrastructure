# Upgrade Runbook: Home Assistant

## Metadaten
- **Namespace:** homeassistant
- **Aktuelle Version:** 2026.8.2 (Image `ghcr.io/home-assistant/home-assistant`)
- **Quelle:** Docker-Hub-Image / GHCR — `ghcr.io/home-assistant/home-assistant`; Release Notes unter https://www.home-assistant.io/blog/ bzw. https://github.com/home-assistant/core/releases
- **ArgoCD App-Name:** homeassistant
- **Versions-Check-Quelle:** Upgrade-Agent (K8s CronJob) beobachtet neue Image-Tags von `ghcr.io/home-assistant/home-assistant`
- **Major/Minor-Kriterium:** Standardregel mit Verschärfung — Patch-Bump innerhalb derselben Minor-Version (z.B. 2026.6.3 → 2026.6.4) gilt als AUTO-fähig. Jeder Minor-Bump (z.B. 2026.5.x → 2026.6.x) sowie jeder Sprung über mehrere Minor-Versionen gilt zwingend als MANUAL, da HA in Minor-Releases häufig Integrationen entfernt, Config-Schemas ändert oder Automationen bricht.

## Changelog

| Datum | Von → Nach | Typ | Ausführung | Status | Begründung | Notiz |
|---|---|---|---|---|---|---|
| unbekannt | ... | ... | ... | ... | Historie vor Einführung des strukturierten Runbooks nicht vollständig rekonstruierbar | — |
| 2026-03-30 | — (Erstinstallation) | — | Manuell | Abgeschlossen | Home Assistant von externem Host in den k3s-Cluster migriert (plain Deployment, kein Helm-Chart) | Commit "Homeassistant moved to Cluster"; Ausgangsversion vor diesem Runbook nicht dokumentiert |
| 2026-06-18 | 2026.3.4 → 2026.6.3 | Major | Manuell | Abgeschlossen | Multi-Minor-Bump (2026.3→2026.6, 3 Minor-Versionen übersprungen); Changelogs für 2026.4 und 2026.5 nicht vollständig geprüft → laut Entscheidungsregel MANUAL | Runbook `homeassistant-upgrade-runbook.md` in diesem Zug erstmals angelegt |
| 2026-06-22 | 2026.6.3 → 2026.6.4 | Minor (Patch) | Automatisch | Abgeschlossen | Patch-Bump innerhalb 2026.6; laut Release Notes nur Bugfixes, Übersetzungskorrekturen, Security-Fixes und kleinere Dependency-Bumps, keine Breaking Changes/CRD-Migrationen/Config-Schema-Änderungen | Ausgeführt vom Upgrade-Agent (CronJob); genannte Restrisiken: Dependency-Bumps (aiodiscover 3.3.2, lxml 6.1.1) könnten DHCP-Discovery/Scrape-Integrationen subtil beeinflussen; Verhaltensfix bei Growatt `total_output_power` (1000x-Skalierung) kann historische Sensorwerte verschieben oder darauf basierende Automationen auslösen |
| 2026-07-13 | 2026.6.3 → 2026.7.2 | Minor | Manuell | Abgeschlossen | Minor-Bump, laut Regel zwingend MANUAL. Release Notes geprüft: entfernte Integrationen (BlinkStick, Watson TTS, Clementine, Microsoft Face, Gitter) und nicht-reversible DB-Migrationen (KNX Telegram History, airOS Advanced Settings) betreffen diese Installation nicht — `.storage/core.config_entries` enthält nur `analytics, backup, google_translate, hacs, homematicip_local, met, radio_browser, shopping_list, sun, unifi`. `trusted_proxies` bereits korrekt gesetzt (Pod-CIDR + localhost) | Live-Deployment lief tatsächlich noch auf 2026.6.3, nicht 2026.6.4 wie zuvor hier dokumentiert (Automatischer Patch-Eintrag vom 2026-06-22 spiegelt sich nicht im tatsächlichen Deployment-Image) — Metadaten-Zeile oben war entsprechend veraltet. Kein Backup unter `/config/backups/` vorhanden (Backup-Integration zwar konfiguriert, aber nie ausgeführt); Upgrade nach Nutzer-Entscheidung ohne Backup durchgeführt, da Restrisiko durch fehlende betroffene Integrationen als gering eingeschätzt. Rollout beobachtet: Pod healthy, 0 Restarts, Frontend liefert HTTP 200 auf 2026.7.2. `homematicip_local` zeigte während des Boots kurzzeitig Ping/Pong-Abweichungen (`aiohomematic.store.dynamic.ping_pong`, 11:59 Uhr) für alle drei CCU-Instanzen (HmIP-RF, BidCos-RF, VirtualDevices) — trat nur einmalig auf, keine Wiederholung in den folgenden ~50 Min. Vollständiger UI-Funktionstest (Login, Dashboard, CCU-Entitäten) konnte nicht durchgeführt werden, da der Zugang zum HA-Login aktuell fehlt (Passwort-Problem, separat in Bearbeitung) — nachholen sobald Zugang wiederhergestellt ist |
| 2026-08-21 | 2026.7.4 → 2026.8.2 | Minor | Manuell (upgrade-agent-PR #11 als Vorlage, Ausführung manuell) | Abgeschlossen | Minor-Bump, laut Regel zwingend MANUAL. Alle vom Agent genannten Risiken einzeln geprüft und entkräftet: Device-Splitting (2026.8.0) betrifft uns nicht (0 Geräte mit >1 config_entry); Port-80-Default betrifft nur HA-OS-Neuinstallationen (wir laufen als Container) und wäre ohnehin selbstrückgängig; UniFi-Protect-7.1-Pflicht betrifft nur `unifiprotect` (wir nutzen nur `unifi`/Network); die gemeldete "homematicip → 2.14.1"-Warnung bezog sich auf die eingebaute, hier ungenutzte `homematicip_cloud`-Integration — die tatsächlich aktive `homematicip_local`/OpenCCU-Komponente pinnt `aiohomematic` in ihrem eigenen `manifest.json` unabhängig von der HA-Core-Version (war schon vor dem Upgrade auf `2026.8.2`). Kein Backup vorhanden → manuelles `/config`-Backup (107MB, tar) erstellt und an den Nutzer ausgeliefert, bevor das Image gebumpt wurde. Keine DB-Schema-Migration gelaufen (`schema_changes`-Tabelle unverändert seit 2026-04-01) | **Root-Cause-Fund, größer als das Upgrade selbst:** Nach dem Upgrade (und den Pod-Neustarts während eines zeitgleich laufenden Cluster-OS-Updates) hing `OpenCCU-BidCos-RF` dauerhaft in `PROXY_INIT failed timed out`. Ausführliche Diagnose ergab: BidCos-RF nutzt (anders als HmIP-RF) das klassische XML-RPC-Callback-Modell — die CCU muss aktiv zu HA zurückverbinden, um Events/PONGs zu pushen. Home Assistant läuft aber als K8s-Pod mit einer bei jedem Neustart wechselnden internen Pod-IP (10.42.0.0/16) — und die CCU (192.168.11.60) hat gar keine Route in dieses Netz (bestätigt per `nc` direkt von der CCU: Timeout). Das erklärt vermutlich auch die "Ping/Pong-Anomalien" aus dem 2026.7.2-Upgrade und frühere Instabilitäten. **Dauerhafter Fix:** HA-Pod per `nodeSelector` auf `gmkt-03x` gepinnt, Callback-Port 51200 per `hostPort`+`hostIP: 192.168.11.33` (gmkt-03x' mgmt-IP, im selben Netz wie die CCU) durchgereicht, in der `homematicip_local`-Integration `callback_host=192.168.11.33` / `callback_port_xml_rpc=51200` gesetzt (Settings → Geräte & Dienste → Homematic(IP) Local → Konfigurieren, braucht "Erweiterten Modus" im Nutzerprofil). Nach vollem Pod-Neustart (nicht Integrations-"Neu laden" — siehe Stolperfalle unten) liefen alle drei Interfaces fehlerfrei hoch. **Nebenbefund während der Diagnose:** ein `Pi-hole`-DNS-Eintrag für die CCU war verschwunden (vermutlich Aufräumarbeiten), vom Nutzer wiederhergestellt — das behob kurzzeitig ein *anderes*, unabhängiges Symptom, war aber nicht die Hauptursache. **Zusätzlich im selben Zug erledigt:** HTTP-YAML-Migrationswarnung geprüft und `http:`-Block aus `configuration.yaml` entfernt (Migration nach `.storage/http` bestätigt vollständig, `trusted_proxies`/`use_x_forwarded_for`/`server_port: 8123` korrekt übernommen); ein 8h lang hängendes `alertmanager`-PVC (korrupter fsck, unabhängiger Vorfall vom selben Cluster-Update) repariert; verwaistes Forensik-PV `pvc-ec243727-...` vom Gitea-Postgres-Vorfall 2026-08-03 gelöscht (18 Tage ungenutzt, Produktivsystem seither stabil) |

### Reklassifizierungen (Minor → Major)

| Datum Erkennung | Ursprünglicher Changelog-Eintrag (Datum) | Grund der Reklassifizierung | Erneute Benachrichtigung gesendet am |
|---|---|---|---|

## Manuelle Vorgehensweise (bei Major/Breaking Change)

**Schritt 1: Backup prüfen**

Vor dem Upgrade sicherstellen, dass ein aktuelles Backup im PVC vorhanden ist:
```bash
kubectl exec -n homeassistant deployment/homeassistant -- \
  ls -lth /config/backups/ | head -5
```
Falls kein aktuelles Backup vorhanden: Im HA-UI unter **Einstellungen → System →
Backup** manuell anstoßen.

**Schritt 2: Release Notes aller übersprungenen Minor-Versionen prüfen**

Bei Multi-Minor-Bumps (z.B. 2026.3 → 2026.6) müssen die Changelogs **aller**
dazwischenliegenden Minor-Releases gesichtet werden, nicht nur der Zielversion —
Integration-Removals und Config-Schema-Änderungen können in jeder Minor-Version
auftreten. Release Notes: https://www.home-assistant.io/blog/ (nach Monat).

**Schritt 3: Image-Tag bumpen**
```yaml
# gitops/config/homeassistant/deployment.yaml
image: ghcr.io/home-assistant/home-assistant:<ZIELVERSION>
```

**Schritt 4: Commit & Push**
```bash
git add gitops/config/homeassistant/deployment.yaml
git commit -m "chore(homeassistant): upgrade <ALT> → <NEU>"
git push gitea main && git push github main
```

**Schritt 5: Rollout beobachten**

ArgoCD synct automatisch (strategy: Recreate — alter Pod stoppt, neuer startet).
```bash
kubectl rollout status deployment/homeassistant -n homeassistant
kubectl logs -n homeassistant deployment/homeassistant --follow
```
HA führt bei Minor-Upgrades DB-Migrationen durch. Der erste Start kann 2–5 Minuten
dauern. Der `livenessProbe` hat `initialDelaySeconds: 60` / `failureThreshold: 5`
(~2,5 Min. Toleranz) — bei langen Migrationen kurz im Log prüfen statt auf
Probe-Timeout warten.

**Schritt 6: Funktionstest**
- https://homeassistant.reckeweg.io → Login erfolgreich
- Dashboard lädt korrekt
- CCU-Integration (HomeMatic) funktioniert
- Automationen greifen wie erwartet

## Bekannte Stolperfallen / Lessons Learned

- **Kein Helm-Chart** — plain Kubernetes Deployment, kein Helm-Upgrade-Prozess;
  Versionswechsel erfolgt ausschließlich über den Image-Tag in `deployment.yaml`.
- **`strategy: Recreate`** — kein Rolling Update möglich wegen SQLite-Lock auf
  `/config`; während des Upgrades ist HA kurzzeitig nicht erreichbar.
- **Multi-Minor-Bumps verstecken Breaking Changes** — beim Sprung 2026.3.4→2026.6.3
  wurden die Changelogs für 2026.4 und 2026.5 nicht vollständig gesichtet; falls nach
  einem Upgrade Probleme auftreten, gezielt die Release Notes der übersprungenen
  Zwischenversionen nachprüfen.
- **DB-Migrationen sind nicht rückwärtskompatibel** — hat HA bereits eine Migration
  durchgeführt, kann ein Rollback auf die alte Version die Datenbank korrumpieren.
  In diesem Fall Backup aus Schritt 1 einspielen statt Image zurückzusetzen.
- **CCU-Integration (HomeMatic)** — Credentials liegen in
  `gitops/config/homeassistant/sealed-secret-ccu.yaml`; nach jedem Upgrade
  Funktionsfähigkeit der Integration explizit prüfen (nicht nur allgemeinen
  Dashboard-Login).
- **`trusted_proxies` nach Neuaufsetzen** — da HA hinter Traefik läuft, muss
  `http.use_x_forwarded_for` und `http.trusted_proxies` (Pod-CIDR `10.42.0.0/16`,
  VLAN 20 `192.168.20.0/24`) in `/config/configuration.yaml` gesetzt sein, sonst
  blockiert HA externe Logins. Relevant primär bei Neuaufsetzen/Migration, nicht bei
  regulären Versions-Upgrades, da `/config` auf einer persistenten Longhorn-PVC liegt.
- **Kein `latest`-Tag verwenden** — ArgoCD triggert sonst keinen neuen Rollout, da
  sich der Image-Tag nicht ändert.
- **BidCos-RF braucht einen CCU→HA-Callback, HmIP-RF nicht** (gefunden 2026-08-21) —
  Die CCU (`192.168.11.60`, eigenes mgmt-Netz `192.168.11.0/24`) muss für BidCos-RF
  aktiv zu HA zurückverbinden (XML-RPC-Callback für Events/PONGs). HmIP-RF braucht das
  nicht (HA hält die Verbindung). Da HA als K8s-Deployment mit bei jedem Neustart
  wechselnder Pod-IP (`10.42.0.0/16`) läuft und die CCU **keine Route in dieses Netz
  hat**, kann der BidCos-RF-Callback strukturell nie funktionieren, solange kein
  fester, von der CCU erreichbarer Endpunkt existiert. Symptom: `PROXY_INIT failed:
  NoConnectionException ... timed out` nur für BidCos-RF, HmIP-RF/VirtualDevices
  unauffällig; auf der CCU selbst in `/var/log/messages`: `rfd: XmlRpc transport
  error calling event(...) on http://<alte-pod-ip>:<port>/RPC2`.
  **Fix (dauerhaft, seit 2026-08-21 aktiv):**
  - `gitops/config/homeassistant/deployment.yaml`: `nodeSelector:
    kubernetes.io/hostname: gmkt-03x` + `hostPort: 51200` / `hostIP: 192.168.11.33`
    (gmkt-03x' mgmt-IP, im selben Netz wie die CCU) auf einen zusätzlichen Container-Port.
  - In der `homematicip_local`-Integration (Settings → Geräte & Dienste → Homematic(IP)
    Local → Konfigurieren, **"Erweiterter Modus" im Nutzerprofil muss aktiv sein**,
    sonst sind die Felder unsichtbar): `Callback Hostname/IP-Adresse` = `192.168.11.33`,
    `Callback XML-RPC Port` = `51200`.
  - **Bei Umzug auf einen anderen Node** (Node-Ausfall, manuelles Rescheduling) müssen
    `nodeSelector`, `hostIP` und der `callback_host`-Wert in der Integration alle drei
    gemeinsam auf die neue Node-mgmt-IP angepasst werden — sonst bricht der Callback
    wieder.
  - **Diagnose-Tipp:** `nc -zv <mgmt-ip> <callback-port>` direkt von der CCU aus ist
    der zuverlässigste Test — ein TCP-Connect von innerhalb des HA-Pods zur CCU (Ports
    2001/2010/9292) sagt nichts über die Callback-Richtung aus.
- **Integrations-"Neu laden" kann bei hängendem BidCos-RF-Client abstürzen** (gefunden
  2026-08-21) — Ist ein Interface bereits im `failed`-Zustand, wirft `aiohomematic`s
  State-Machine beim Unload einen `InvalidStateTransitionError` (`from failed to
  stopping`), was den kompletten HA-Core-Prozess zum Absturz bringt (`exit code 100`
  im Log, danach kompletter Neustart aller Integrationen). Betrifft potenziell jede
  Situation, in der eine Schnittstelle hängt und man versucht, die Integration über
  die UI neu zu laden. **Workaround:** stattdessen einen vollen Pod-Neustart
  (`kubectl rollout restart deployment/homeassistant -n homeassistant`) durchführen —
  das umgeht den Absturz-Pfad, da der Prozess komplett neu hochfährt statt den
  fehlerhaften Stop-Code-Pfad im laufenden Prozess zu durchlaufen.

## Rollback-Plan

Option A: Git-Revert + Push (bevorzugt)
```bash
git revert HEAD
git push gitea main && git push github main
```

Option B: Direktes Image-Override (ohne Git-Änderung)
```bash
kubectl set image deployment/homeassistant \
  homeassistant=ghcr.io/home-assistant/home-assistant:<ALTE_VERSION> \
  -n homeassistant
```

> Achtung: DB-Migrationen sind nicht rückwärtskompatibel. Hat HA bereits eine
> Migration durchgeführt, kann ein Rollback die Datenbank korrumpieren — in diesem
> Fall stattdessen das Backup aus der Vorbereitung einspielen.

## Referenzen

- GitHub Releases: https://github.com/home-assistant/core/releases
- Release Notes / Blog: https://www.home-assistant.io/blog/
- Interne Doku: `docs/HomeAssistant-Readme.md` (GitOps-Struktur, Migration, trusted_proxies, Sealed Secrets)
- ArgoCD Application: `gitops/apps/homeassistant.yaml`
- Deployment-Manifest: `gitops/config/homeassistant/deployment.yaml`
