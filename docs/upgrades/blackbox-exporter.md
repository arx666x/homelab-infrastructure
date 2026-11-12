# Upgrade Runbook: blackbox-exporter

## Metadaten
- **Namespace:** `monitoring`
- **Aktuelle Version:** Chart 11.21.2 (`prometheus-blackbox-exporter`, Exporter v0.29.1)
- **Quelle:** Helm-Chart-Repo `https://prometheus-community.github.io/helm-charts` (Chart `prometheus-blackbox-exporter`)
- **ArgoCD App-Name:** `blackbox-exporter` (`gitops/apps/blackbox-exporter.yaml`, Sync-Wave 5, nach kube-prometheus-stack wegen der ServiceMonitor-CRD)
- **Versions-Check-Quelle:** Helm-Repo-Index über das `helm`-Binary
- **Major/Minor-Kriterium:** Standard-SemVer der Chart-Version. Vor jedem Bump zusätzlich prüfen, dass die drei Module (`dns_ad_srv`, `tcp_connect`, `ldaps_tls`) im neuen Exporter-Release unverändert unterstützt werden, und dass die ServiceMonitors weiter das Label `release: kube-prometheus-stack` tragen.

**Zweck:** Aktive Funktions-Probes für den Windows-DC (DNS-SRV, TCP 389, LDAPS-TLS 636), Alerts in der Gruppe `windows-ad` in `gitops/apps/monitoring.yaml`. Hintergrund und Grenzen der Probes siehe `docs/monitoring-dokumentation.md`, Abschnitt „Windows-DC-Alerts“.

## Changelog

| Datum | Von → Nach | Typ | Ausführung | Status | Begründung | Notiz |
|---|---|---|---|---|---|---|
| 2026-10-26 | — → 11.20.2 | Erstinstallation | Manuell | Abgeschlossen | Funktions-Monitoring für den Windows-DC nach dessen unbemerktem Ausfall (2026-07-29 bis 2026-10-25) | Commit `ad9a83b` |
| 2026-11-06 | 11.20.2 → 11.21.1 | Minor | Manuell | Abgeschlossen | `helm template` alt/neu mit unseren Values: kein Unterschied in den gerenderten Objekten (Exporter bleibt v0.29.1) | Teil der Update-Runde 2026-11-06; danach alle drei Probes = 1 |
| 2026-11-12 | 11.21.1 → 11.21.2 | Minor (Patch) | Manuell | Abgeschlossen | `helm template` alt/neu mit unseren Values: gerenderte Objekte identisch (nur Chart-Label), Exporter bleibt v0.29.1 | Teil der Update-Runde 2026-11-12; danach alle drei Probes = 1 |

### Reklassifizierungen (Minor → Major)

| Datum Erkennung | Ursprünglicher Changelog-Eintrag (Datum) | Grund der Reklassifizierung | Erneute Benachrichtigung gesendet am |
|---|---|---|---|

## Manuelle Vorgehensweise (bei Major/Breaking Change)

1. Release Notes von Chart und Exporter lesen (Modul-Syntax, entfernte Prober-Optionen).
2. Values aus `gitops/apps/blackbox-exporter.yaml` extrahieren, `helm template` alt/neu rendern und vergleichen (ConfigMap mit den Modulen, ServiceMonitors, Deployment).
3. `targetRevision` bumpen, committen, pushen, `root-infrastructure` und `blackbox-exporter` hard-refreshen.
4. Prüfen (Prometheus hinter SSO, daher per Port-Forward):
   ```bash
   kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090 &
   curl -s 'http://localhost:19090/api/v1/query' --data-urlencode 'query=probe_success{target=~"windows-ad-.*"}'
   ```
   Erwartet: drei Serien (`windows-ad-dns`, `windows-ad-ldap`, `windows-ad-ldaps`) mit Wert 1.

## Bekannte Stolperfallen / Lessons Learned

- **Kein echter LDAP-Bind möglich:** YAML-Escapes wie `\x80` werden zu UTF-8 (`0xC2 0x80`), nicht zu Rohbytes; jede LDAP-Anfrage braucht aber Tags ≥ 0x80, und `query_response.send` hängt immer `\n` an. AD trennt solche Verbindungen (`connection reset by peer`). Deshalb TCP-Connect + LDAPS-TLS-Handshake.
- **NetworkPolicy:** 389/636 sind im Namespace `windows-ad` nur für Pods mit `app.kubernetes.io/name=prometheus-blackbox-exporter` aus `monitoring` offen — ein Label-Wechsel im Chart würde die Probes still brechen (`WindowsADProbeFailed` würde dann feuern).

## Rollback-Plan

`targetRevision` zurücksetzen, committen, pushen, App hard-refreshen. Der Exporter hält keinen Zustand.

## Referenzen

- ArgoCD Application: `gitops/apps/blackbox-exporter.yaml`
- Alerts: `gitops/apps/monitoring.yaml`, Gruppe `windows-ad`
- NetworkPolicy: `gitops/config/windows-ad/05-networkpolicy.yaml`
