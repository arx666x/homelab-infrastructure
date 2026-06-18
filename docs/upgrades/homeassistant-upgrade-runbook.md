# Home Assistant Upgrade Runbook

---

## Upgrade 2026.3.4 → 2026.6.3

**Datum:** 2026-06-18  
**Scope:** Homelab k3s-Cluster (`reckeweg.io`)  
**Namespace:** `homeassistant`  
**Aktuell:** `ghcr.io/home-assistant/home-assistant:2026.3.4`  
**Ziel:** `ghcr.io/home-assistant/home-assistant:2026.6.3`  
**Risiko:** 🟡 Mittel — Multi-Minor-Bump (2026.3 → 2026.6); Changelogs für 2026.4 und 2026.5 nicht vollständig geprüft; keine manuelle Konfiguration bisher aktiv

### Änderungen in 2026.6.3

| Bereich | Änderung | Betrifft uns? |
|---------|----------|---------------|
| MQTT Discovery | Disabled entities werden durch Discovery nicht mehr re-enabled | Prüfen, falls MQTT-Geräte vorhanden |
| HTTP Auth Token | Revert "Unify query token auth" — externe Token-Auth zurückgesetzt | Ggf. Auswirkung auf Camera/Media-Streams |
| UptimeRobot | Update-Intervall geändert | Nein — Integration nicht aktiv |
| Reolink | `reolink_aio` 0.21.0 | Nein — Integration nicht aktiv |
| Frontend | `20260527.6` | Ja — UI-Update, kein Breaking Change |
| Thread/OTBR | Border-Agent-Adresse wird bei Reconnect erneuert | Nein — kein Thread-Setup |

> ⚠️ Changelogs für **2026.4** und **2026.5** wurden nicht vollständig gesichtet.
> Diese Minor-Releases können weitere Breaking Changes enthalten (Integration-Removals,
> Config-Schema-Änderungen). Bei Problemen nach dem Upgrade → Release Notes unter
> https://www.home-assistant.io/blog/ für die entsprechenden Monate prüfen.

### Durchführung

**Schritt 1: Backup prüfen**

Vor dem Upgrade sicherstellen, dass ein aktuelles Backup im PVC vorhanden ist:

```bash
kubectl exec -n homeassistant deployment/homeassistant -- \
  ls -lth /config/backups/ | head -5
```

Falls kein aktuelles Backup: Im HA UI unter **Einstellungen → System → Backup**
manuell anstoßen.

**Schritt 2: Image-Tag bumpen**

```yaml
# gitops/config/homeassistant/deployment.yaml
image: ghcr.io/home-assistant/home-assistant:2026.6.3
```

**Schritt 3: Commit & Push**

```bash
git add gitops/config/homeassistant/deployment.yaml
git commit -m "chore(homeassistant): upgrade 2026.3.4 → 2026.6.3"
git push gitea main && git push github main
```

**Schritt 4: Rollout beobachten**

ArgoCD synct automatisch (strategy: Recreate — alter Pod stoppt, neuer startet).

```bash
kubectl rollout status deployment/homeassistant -n homeassistant
kubectl logs -n homeassistant deployment/homeassistant --follow
```

HA führt bei Minor-Upgrades DB-Migrationen durch. Der erste Start kann 2–5 Minuten dauern.
Der `livenessProbe` hat `initialDelaySeconds: 60` / `failureThreshold: 5` (~2,5 Min. Toleranz) —
bei langen Migrationen kurz im Log prüfen statt auf Probe-Timeout warten.

**Schritt 5: Funktionstest**

- https://homeassistant.reckeweg.io → Login erfolgreich
- Dashboard lädt korrekt
- CCU-Integration (HomeMatic) funktioniert
- Automationen greifen wie erwartet

### Rollback

```bash
# Option A: Git-Revert + Push (bevorzugt)
git revert HEAD
git push gitea main && git push github main

# Option B: Direktes Image-Override (ohne Git-Änderung)
kubectl set image deployment/homeassistant \
  homeassistant=ghcr.io/home-assistant/home-assistant:2026.3.4 \
  -n homeassistant
```

> ⚠️ DB-Migrationen sind nicht rückwärtskompatibel. Hat HA bereits eine Migration
> durchgeführt, kann ein Rollback die Datenbank korrumpieren. In diesem Fall:
> Backup aus Schritt 1 einspielen.

---

## Allgemeines: Entscheidungsregel AUTO vs. MANUAL

| Situation | Verfahren |
|-----------|-----------|
| Patch-Bump innerhalb desselben Minor (z.B. 2026.6.2 → 2026.6.3) | AUTO möglich |
| Minor-Bump (z.B. 2026.5.x → 2026.6.x) | MANUAL — Release Notes prüfen |
| Mehrere Minor-Versionen übersprungen | MANUAL — alle fehlenden Changelogs prüfen |

HA bricht häufig in Minor-Releases: Integrationen werden entfernt, Config-Schemas
ändern sich, Automations können brechen.

## Besonderheiten dieser Installation

- **Kein Helm-Chart** — plain Kubernetes Deployment; kein Helm-Upgrade-Prozess.
- **strategy: Recreate** — kein Rolling Update möglich wegen SQLite-Lock auf `/config`.
- **Keine manuelle Konfiguration bisher** — `/config` wird nach Migration befüllt.
  Nach erstem Start `trusted_proxies` in `/config/configuration.yaml` setzen (siehe README).
- **CCU-Integration** — Credentials in `sealed-secret-ccu.yaml`; nach Upgrade funktionsfähigkeit prüfen.
