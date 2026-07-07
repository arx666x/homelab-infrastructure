# Upgrade Runbooks — Struktur & Prozess

Dieses Verzeichnis enthält je Homelab-Dienst ein Upgrade-Runbook nach
einheitlichem Format (`docs/upgrades/<service-slug>.md`). Ziel: lückenlose,
maschinenlesbare Historie aller Upgrades — egal ob manuell durchgeführt oder
automatisch vom Version-Checker.

## Dateistruktur je Dienst

Jede Datei folgt diesem Schema:

```markdown
# Upgrade Runbook: <Service-Name>

## Metadaten
- **Namespace:** ...
- **Aktuelle Version:** ...
- **Quelle:** ...
- **ArgoCD App-Name:** ...
- **Versions-Check-Quelle:** ...
- **Major/Minor-Kriterium:** ...

## Changelog
| Datum | Von → Nach | Typ | Ausführung | Status | Begründung | Notiz |

### Reklassifizierungen (Minor → Major)
| Datum Erkennung | Ursprünglicher Changelog-Eintrag (Datum) | Grund | Erneute Benachrichtigung gesendet am |

## Manuelle Vorgehensweise (bei Major/Breaking Change)
## Bekannte Stolperfallen / Lessons Learned
## Rollback-Plan
## Referenzen
```

**Statuswerte** im Changelog — exakt einer dieser drei Strings, keine
Freitext-Varianten:
- `Abgeschlossen`
- `Offen – manueller Eingriff nötig`
- `Reklassifiziert (Minor→Major)`

Dienste ohne eigenständiges Chart-/Image-Upgrade (z.B. k3s über Ansible,
ArgoCD-Self-Bootstrap, local-path-provisioner gebündelt mit k3s, Windows-AD-VM
mit Gast-OS-Updates) übernehmen dieselbe Struktur, passen die Metadaten-Felder
aber sinngemäß an (z.B. `ArgoCD App-Name: — (nicht ArgoCD-verwaltet)`).

Abhängige Datenspeicher eines Dienstes (z.B. gitea-postgresql/gitea-valkey zu
Gitea, MySQL zu WordPress) bekommen **kein** eigenes Runbook, sondern werden im
Runbook des Hauptdienstes unter "Metadaten" als zugehörige ArgoCD-Apps
mitgeführt.

## Wie der homelab-version-checker mit den Runbooks interagiert

Die Analyse-Komponente (`scripts/upgrade-agent.py`, läuft wöchentlich montags
08:00 Uhr Europe/Berlin als CronJob im Namespace `monitoring` — nicht zu
verwechseln mit der reinen Sonntags-Benachrichtigung) geht bei jedem
Upgrade-Kandidaten so vor:

1. **Neue Version ermitteln.** Für Helm-Charts über das `helm`-Binary (nie
   `index.yaml` direkt parsen), für Container-Images über GHCR/Docker-Hub-Tag-
   Vergleich. Release-Notes/Changelog der Zwischenversionen werden von GitHub
   geladen.
2. **Einstufen.** Der Checker lädt zusätzlich den Inhalt des im jeweiligen
   `HELM_SERVICES`/`IMAGE_SERVICES`-Eintrag hinterlegten `runbook`-Pfads (siehe
   unten) und gibt ihn zusammen mit den Release-Notes an Claude. Default-Regel
   (SemVer): Major-Bump der Chart-/Image-Version = Major, Minor/Patch = Minor,
   **sofern** die Release-Notes keine Breaking Changes, CRD-Migrationen oder
   Config-Format-Änderungen erwähnen. Ausnahmen sind je Runbook im Feld
   "Major/Minor-Kriterium" explizit dokumentiert (z.B. k3s: Pflicht-Hops
   werden trotz SemVer-Minor als Major behandelt; siehe `docs/upgrades/k3s.md`).
3. **Bei AUTO (Minor/Patch, unkritisch):** Der Checker committet die
   Versionsänderung direkt nach `main` (kein PR mehr seit `188a865` — ArgoCD
   deployt automatisch). Danach in der jeweiligen Service-Datei eine neue
   Changelog-Zeile ergänzen:
   - Ausführung: `Automatisch`
   - Status: `Abgeschlossen`
   - Begründung: kurze Zusammenfassung, warum als Minor eingestuft (z.B.
     "Patch-Release, laut Release Notes nur Bugfixes, keine API-Änderungen")
   - Notiz: Commit-Link
4. **Bei NOTIFY (Major oder riskanter Minor-Bump):** Kein automatischer
   Commit. Telegram + E-Mail wie bisher. Neue Changelog-Zeile:
   - Ausführung: `Manuell`
   - Status: `Offen – manueller Eingriff nötig`
   - Begründung: Claude-Einschätzung, warum als Major/riskant eingestuft
5. **Bei fehlgeschlagenem automatischem Minor-Update** (AUTO-Commit ausgelöst,
   aber Dienst danach defekt/Rollback nötig): Ursprüngliche Changelog-Zeile auf
   Status `Reklassifiziert (Minor→Major)` setzen, neue Zeile in der
   Reklassifizierungs-Tabelle des Runbooks ergänzen, erneute Benachrichtigung
   über denselben Kanal wie eine reguläre Major-Benachrichtigung auslösen.

Diese Schritte 3–5 sind aktuell **manuell** nachzutragen (der Checker schreibt
noch nicht selbst in die Runbook-Dateien) — das Nachtragen ist Teil des
Reviews, wenn ein AUTO-Commit oder eine NOTIFY-Mail eintrifft.

### Runbook-Zuordnung im Checker-Script

`scripts/upgrade-agent.py` referenziert je überwachtem Dienst einen
`runbook`-Pfad in `HELM_SERVICES` bzw. `IMAGE_SERVICES`. Nach dieser Migration
zeigen diese Pfade auf die neuen `<service-slug>.md`-Dateien. Wird ein neuer
Dienst zur Automatisierung hinzugefügt, muss dort zwingend der passende
`docs/upgrades/<slug>.md`-Pfad eingetragen werden, sonst bekommt Claude bei der
Einstufung keinen Cluster-spezifischen Kontext.

## Bekannte Lücken (Stand 2026-07-07)

- **WordPress** (`docs/upgrades/wordpress.md`): läuft produktiv im Cluster,
  ist aber weder als ArgoCD-App noch als Manifest in diesem oder im
  `seri-k8s`-Repo auffindbar. Kein automatischer Check möglich, bis die Quelle
  geklärt/nach `gitops/` migriert ist.
- **local-path-provisioner**, **k3s**, **ArgoCD**, **KubeVirt/CDI**,
  **Windows-AD-VM**: nicht über den Helm-/Image-Mechanismus des Checkers
  automatisierbar (Ansible-, Operator- bzw. Gast-OS-verwaltet). Ihre Runbooks
  dokumentieren die jeweils eigene manuelle Vorgehensweise.
