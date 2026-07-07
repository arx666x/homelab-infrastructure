# Upgrade Runbook: local-path-provisioner

## Metadaten
- **Namespace:** kube-system
- **Aktuelle Version:** v0.0.36 (Image `rancher/local-path-provisioner:v0.0.36`, per `kubectl get deploy -n kube-system local-path-provisioner` bestätigt am 2026-07-07)
- **Quelle:** gebündelt mit k3s (rancher/local-path-provisioner), Version an k3s-Release gekoppelt
- **ArgoCD App-Name:** — (kein eigenständiges ArgoCD-App; gebündelt mit k3s)
- **Versions-Check-Quelle:** kein eigener Check – Version ändert sich nur durch k3s-Upgrade, siehe docs/upgrades/k3s.md
- **Major/Minor-Kriterium:** n/a – wird nicht eigenständig upgegradet, sondern folgt dem k3s-Upgrade-Zyklus

## Changelog

| Datum | Von → Nach | Typ | Ausführung | Status | Begründung | Notiz |
|---|---|---|---|---|---|---|
| unbekannt | ... | ... | ... | ... | Historie vor Einführung des strukturierten Runbooks nicht vollständig rekonstruierbar | — |

### Reklassifizierungen (Minor → Major)

| Datum Erkennung | Ursprünglicher Changelog-Eintrag (Datum) | Grund der Reklassifizierung | Erneute Benachrichtigung gesendet am |
|---|---|---|---|

## Manuelle Vorgehensweise (bei Major/Breaking Change)

`local-path-provisioner` wird in diesem Cluster nicht eigenständig verwaltet — es gibt weder eine dedizierte ArgoCD-Application noch ein Manifest im `gitops/`-Verzeichnis dieses Repos dafür. Der Provisioner läuft als k3s-eigener Add-on-Deployment (`kube-system/local-path-provisioner`) und wird ausschließlich durch den k3s-Installer bzw. ein k3s-Upgrade selbst aktualisiert.

Es gibt daher **keinen eigenständigen Upgrade-Prozess** für diese Komponente. Ein Versions-Wechsel passiert immer als Nebeneffekt eines k3s-Upgrades:

1. Vor einem k3s-Upgrade aktuelle Version notieren:
   ```bash
   kubectl get deploy -n kube-system local-path-provisioner \
     -o jsonpath='{.spec.template.spec.containers[0].image}'
   ```
2. k3s-Upgrade gemäß `docs/upgrades/k3s.md` durchführen.
3. Nach dem k3s-Upgrade erneut prüfen, ob sich die local-path-provisioner-Version geändert hat:
   ```bash
   kubectl get deploy -n kube-system local-path-provisioner \
     -o jsonpath='{.spec.template.spec.containers[0].image}'
   kubectl -n kube-system rollout status deploy/local-path-provisioner
   ```
4. Funktionstest: PVC mit StorageClass `local-path` anlegen und prüfen, ob ein PV korrekt provisioniert wird (nur relevant falls `local-path` als StorageClass irgendwo aktiv genutzt wird — im Regelfall ist in diesem Cluster Longhorn die Default-StorageClass, siehe `docs/upgrades/longhorn.md`).

Ein manuelles Update losgelöst vom k3s-Release wird nicht praktiziert und ist nicht Teil dieses Runbooks.

## Bekannte Stolperfallen / Lessons Learned

- Diese Komponente hat keine eigenständige Upgrade-Historie, da sie nicht unabhängig von k3s aktualisiert wird — jede Versionsänderung ist an einen k3s-Release gebunden. Für die eigentliche Upgrade-Historie und bekannte Fallstricke siehe `docs/upgrades/k3s.md`.
- Da kein ArgoCD-App-Objekt existiert, taucht diese Komponente auch nicht im automatisierten Versions-Check/Notification-Flow auf, der für die übrigen ArgoCD-verwalteten Apps in diesem Repo läuft.
- Falls lokale PVCs mit StorageClass `local-path` in Verwendung sind: local-path-provisioner-Volumes sind node-lokal (`hostPath`-basiert) und werden **nicht** von Longhorn-Backups erfasst — bei einem Node-Ausfall gehen sie verloren. Vor jedem Cluster-Wartungsfenster prüfen, ob PVCs mit dieser StorageClass existieren.

## Rollback-Plan

- Kein eigenständiger Rollback-Pfad, da kein eigenständiges Upgrade existiert. Ein Rollback der local-path-provisioner-Version ist nur über ein Rollback des k3s-Releases möglich (siehe Rollback-Plan in `docs/upgrades/k3s.md`).

## Referenzen

- GitHub Releases: https://github.com/rancher/local-path-provisioner/releases
- k3s-Upgrade-Runbook (maßgeblich für Versionsänderungen dieser Komponente): `docs/upgrades/k3s.md`
- k3s-Dokumentation zu Storage-Add-ons: https://docs.k3s.io/storage
