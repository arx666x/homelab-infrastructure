# Upgrade Runbook: csi-driver-smb

## Metadaten
- **Namespace:** `kube-system`
- **Aktuelle Version:** Chart v1.20.4 (smbplugin v1.20.4)
- **Quelle:** Helm-Chart-Repo `https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/charts` (Chart `csi-driver-smb`), Releases unter https://github.com/kubernetes-csi/csi-driver-smb/releases
- **ArgoCD App-Name:** `csi-driver-smb` (`gitops/apps/csi-driver-smb.yaml`, keine eigenen Values, `ServerSideApply=true`)
- **Versions-Check-Quelle:** Helm-Repo-Index (Chart-Versionen dort ohne `v`-Präfix, z.B. `1.20.4`; `targetRevision` in der App steht historisch mit `v`-Präfix und wird von ArgoCD trotzdem korrekt aufgelöst)
- **Major/Minor-Kriterium:** Standardregel (SemVer der Chart-Version). Chart- und Treiber-Version laufen synchron. Zusätzlich vor jedem Upgrade prüfen, ob sich die CSI-Sidecar-Images (provisioner, resizer, livenessprobe, node-driver-registrar) ändern — die sind die häufigste Quelle realer Änderungen.

**Nutzer:** Ausschließlich ChromeIQ — statische PVs/PVCs (`storageClassName: smb-static`, `Retain`) auf die Musicbox-Shares `//musicbox/music` (ROX), `playlists` und `rsnotes` (RWX), siehe `gitops/config/chromeiq/smb-pv.yaml`. Keine dynamische Provisionierung.

## Changelog

| Datum | Von → Nach | Typ | Ausführung | Status | Begründung | Notiz |
|---|---|---|---|---|---|---|
| 2026-07-29 | — → v1.20.3 | Erstinstallation | Manuell | Abgeschlossen | Erste SMB/CIFS-Fähigkeit im Cluster für ChromeIQ (Commit `6136f38`, Version in `282fda1` von Platzhalter v1.18.0 auf v1.20.3 korrigiert) | Runbook erst am 2026-10-24 angelegt, Historie aus Git rekonstruiert |
| 2026-10-24 | v1.20.3 → v1.20.4 | Minor (Patch) | Manuell | Abgeschlossen | `helm template` alt/neu: Controller-Sidecar `csi-resizer` v2.2.0 → v2.2.1, Windows-DaemonSet bekommt `--require-privacy-for-global-mapping=true` (Windows-Nodes gibt es bei uns nicht, DaemonSet ist inert), keine CRD-/RBAC-Änderungen | Teil der Update-Runde 2026-10-24. Controller neu gerollt (4/4 Running, `smbplugin:v1.20.4`), alle drei ChromeIQ-SMB-PVCs weiterhin Bound, ChromeIQ-Pods Running |

### Reklassifizierungen (Minor → Major)

| Datum Erkennung | Ursprünglicher Changelog-Eintrag (Datum) | Grund der Reklassifizierung | Erneute Benachrichtigung gesendet am |
|---|---|---|---|

## Manuelle Vorgehensweise (bei Major/Breaking Change)

1. Release Notes aller Zwischenversionen lesen (Breaking Changes, entfernte Mount-Optionen, Mindestversion Kubernetes).
2. `helm template csi-driver-smb smb/csi-driver-smb --version <alt|neu> -n kube-system --include-crds` rendern und vergleichen (Images, Args, RBAC, CSIDriver-Objekt).
3. `targetRevision` in `gitops/apps/csi-driver-smb.yaml` bumpen, committen, pushen; `root-infrastructure` und `csi-driver-smb` hard-refreshen.
4. Verifizieren:
   ```bash
   kubectl -n kube-system get pods -l app=csi-smb-controller
   kubectl -n kube-system get ds csi-smb-node
   kubectl get pvc -n chromeiq | grep smb
   kubectl -n chromeiq get pods
   ```
   Bestehende Mounts laufender Pods bleiben beim Rollout des Node-Plugins erhalten; neu startende Pods mounten mit dem neuen Treiber.

## Bekannte Stolperfallen / Lessons Learned

- **PVC muss statisch gebunden werden** — Longhorn ist Default-StorageClass. Ohne expliziten `storageClassName: smb-static` + `claimRef` würde Longhorn die PVC dynamisch übernehmen (siehe Commit `6136f38`).
- **Kein Sync-Wave-Zwang** — eine PVC/ein Pod, der auf den noch nicht bereiten Treiber verweist, bleibt nur Pending/ContainerCreating und heilt sich selbst.

## Rollback-Plan

`targetRevision` auf die vorherige Version zurücksetzen, committen, pushen, App hard-refreshen. Da nur statische PVs mit `Retain` genutzt werden, gibt es keinen Datenzustand im Treiber, der zurückgerollt werden müsste.

## Referenzen

- ArgoCD Application: `gitops/apps/csi-driver-smb.yaml`
- PV/PVC: `gitops/config/chromeiq/smb-pv.yaml`
- Upstream: https://github.com/kubernetes-csi/csi-driver-smb
