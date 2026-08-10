# Upgrade Runbook: KubeVirt + CDI

## Metadaten
- **Namespace:** `kubevirt` (KubeVirt-Operator + virt-*-Komponenten), `cdi` (CDI-Operator)
- **Aktuelle Version:** KubeVirt v1.9.0 | CDI v1.66.0
- **Quelle:** GitHub Releases (Operator-Manifeste als Remote-Kustomize-Base, kein Helm-Chart)
  - KubeVirt: `https://github.com/kubevirt/kubevirt/releases`
  - CDI: `https://github.com/kubevirt/containerized-data-importer/releases`
- **ArgoCD App-Name:** `kubevirt-operator` (Wave 20, Namespace `kubevirt`) und `cdi-operator` (Wave 21, Namespace `cdi`)
- **Versions-Check-Quelle:** Kein automatischer Versions-Checker (kein Helm-Chart mit `targetRevision`). Die installierte Version steht als Release-URL in `gitops/config/kubevirt/kustomization.yaml` bzw. `gitops/config/cdi/kustomization.yaml` (Zeile `resources: - https://github.com/.../releases/download/<version>/...-operator.yaml`). Neue Releases müssen manuell auf GitHub geprüft werden.
- **Major/Minor-Kriterium:** Minor-Version-Sprünge (z.B. v1.7→v1.8) werden immer wie ein Major-Upgrade behandelt — schrittweise über jede Minor-Version, mit Prüfung der Release-Notes auf Breaking Changes (Feature-Gate-Removals, API-Deprecations, CRD-Änderungen). Patch-Releases innerhalb eines Minor-Zweigs (z.B. v1.8.3→v1.8.4) gelten als unkritisch und können automatisch/direkt eingespielt werden, sofern die Release-Notes keine Breaking Changes ausweisen.

## Changelog

| Datum | Von → Nach | Typ | Ausführung | Status | Begründung | Notiz |
|---|---|---|---|---|---|---|
| unbekannt | – → v1.3.1 (KubeVirt) / v1.59.0 (CDI) | Major | Manuell | Abgeschlossen | Initiales Deployment von KubeVirt-Operator, CDI-Operator und windows-ad VM | Commit `861e380 feat: add kubevirt, cdi operators and windows-ad DC` — genaues Datum nicht mehr rekonstruierbar |
| unbekannt | KubeVirt v1.3.1 → v1.4.0, CDI v1.59.0 → v1.60.5 | Major | Manuell | Abgeschlossen | Schrittweises Minor-Upgrade, erster Schritt eines mehrstufigen Plans | Commit `84d3b53` |
| unbekannt | KubeVirt v1.4.0 → v1.5.2, CDI v1.60.5 → v1.61.5 | Major | Manuell | Abgeschlossen | `AutoResourceLimits` Feature Gate wird GA und standardmäßig aktiv | Commit `4bb62f8` |
| unbekannt | KubeVirt v1.5.2 → v1.6.5, CDI v1.61.5 → v1.63.1 | Major | Manuell | Abgeschlossen | Neues Default-Verhalten bei `rolloutStrategy`; `virt-api` skaliert dynamisch nach Anzahl schedulbarer Nodes | Commit `01753e6` |
| unbekannt | KubeVirt v1.6.5 → v1.7.3, CDI v1.63.1 → v1.65.0 | Major | Manuell | Abgeschlossen | `instancetype.kubevirt.io/v1alpha{1,2}` API/CRDs entfernt; Fix für `virt-handler domain-notify.sock` Restart; SMBIOS-Fix für ARM64-Guests | Commit `867776e` |
| unbekannt | KubeVirt v1.7.3 → v1.8.2, CDI bleibt v1.65.0 | Major | Manuell | Abgeschlossen | Breaking: macvtap-Binding entfernt, SLIRP-Binding entfernt, VirtioFS Feature-Gate entfernt (jetzt GA), Metrik-Umbenennung `kubevirt_vmi_migration_data_total_bytes` → `..._bytes_total` | Commit `868cedb`; windows-ad nutzt keines der entfernten Features → kein Risiko |
| 2026-06-14 | KubeVirt v1.8.2 → v1.8.3, CDI bleibt v1.65.0 | Minor | Manuell | Abgeschlossen | Reiner Security-/Bugfix-Patch: Symlink-Traversal in VMExport behoben, virt-api Autorisierungsfehler behoben, CVE GHSA-p77j-4mvh-x3m3 gepatcht | Commit `967cb82` |
| 2026-06-29 | KubeVirt v1.8.3 → v1.8.4, CDI bleibt v1.65.0 | Minor | Manuell | Abgeschlossen | gRPC-Connection-Leak in `virt-handler` behoben (unbegrenztes Memory-Wachstum); CVE-2026-35469 (`moby/spdystream`) gepatcht | Commit `2caf775` |
| 2026-08-03 | KubeVirt v1.8.4 → v1.9.0, CDI bleibt v1.65.0 | Minor | Manuell (kustomization.yaml Release-URL) | Abgeschlossen | Kein Breaking Change relevant für dieses Setup: aktive Feature Gates (`LiveMigration`, `Snapshot`, `HotplugVolumes`, `HostDisk`) nicht entfernt (`HotplugVolumes` graduiert nur zu Beta); strengere Netzwerk-Binding-Validierung betrifft windows-ad nicht (nutzt bereits explizit `masquerade: {}`); cgroup v1 nur deprecated, Removal erst nächstes Release. Neue Komponenten automatisch dazugekommen: `virt-exportproxy` (VMExport GA), `virt-template-apiserver`/`virt-template-controller` (Template-Feature-Gate jetzt default-on) | Beim Pre-Check unabhängig entdeckt: `virt-launcher-windows-ad-dc` hängt in `Init:0/1` mit `fsck`-Fehler auf dem Longhorn-Volume (`pvc-8131dc95-...`) — vermutlich derselbe Root Cause wie der gitea-postgresql-Vorfall vom selben Tag (Node-Reboot vor dem Longhorn-Eviction-Fix in `update-master-nodes.yml`). Nicht durch dieses Upgrade verursacht, bewusst separat behandelt (siehe Stolperfalle "windows-ad VM ist vom Upgrade-Prozess entkoppelt"). **Update:** noch am selben Tag repariert — `disk.img` war zuletzt am 2026-07-29 verändert worden (passt zu `remountRequestedAt: 2026-07-29` im Longhorn-Volume-Status), die Korruption dürfte also älter sein als der heutige Reboot. Fix: VM gestoppt, Volume über einen kurzlebigen Helper-Pod (nur `volumeMounts`, kein `volumeDevices` nötig — reicht um Longhorn zum Attachen zu bewegen, der eigentliche Mount darf ruhig fehlschlagen) erneut attached, `fsck -y` direkt auf `/dev/longhorn/<volume>` via Ansible-Ad-hoc auf dem Node gefahren (Directory-Korruption in `lost+found`, invalide Extent-Bäume, Block-Bitmap-Differenzen behoben), zweiter `fsck`-Lauf bestätigte sauberen Zustand (kubelet konnte danach selbst erfolgreich mounten). VM läuft seither wieder `Running`/`ready=true`. |
| 2026-08-10 | CDI v1.65.0 → v1.66.0, KubeVirt bleibt v1.9.0 | Minor | Manuell (kustomization.yaml Release-URL) | Abgeschlossen | Kein Breaking Change laut Release Notes. Sicherheits-Änderung: `/metrics` auf `cdi-deployment`/`cdi-operator` verlangt jetzt Bearer-Token-Auth (neue `cdi-metrics-reader`-ServiceAccount/ClusterRole automatisch angelegt); `WebhookPvcRendering`-Feature-Gate jetzt default-on | Operator-owned ServiceMonitor (`service-monitor-cdi`, nicht in unserem GitOps) hat die neue `authorization.credentials`-Konfiguration (`cdi-metrics-reader-token`) automatisch mit dem Operator-Update übernommen — keine manuelle Nacharbeit nötig. windows-ad-VM unberührt (weiterhin `selfHeal: false` auf der App), alle CDI-Pods liefen nach dem Sync sauber neu hoch |

### Reklassifizierungen (Minor → Major)

| Datum Erkennung | Ursprünglicher Changelog-Eintrag (Datum) | Grund der Reklassifizierung | Erneute Benachrichtigung gesendet am |
|---|---|---|---|

## Manuelle Vorgehensweise (bei Major/Breaking Change)

KubeVirt/CDI sind Operator-Lifecycle-Manager-Deployments (Remote-Kustomize-Base aus GitHub-Release-Manifesten), kein Helm-Chart. Jedes Upgrade — Major wie Patch — läuft nach demselben manuellen Muster ab, da es keinen automatisierten Versions-Checker für diese Komponenten gibt.

### Grundprinzip: immer Minor-für-Minor

Nie mehr als eine Minor-Version pro Schritt überspringen (z.B. nicht direkt v1.5→v1.8). Innerhalb eines Minor-Zweigs immer die letzte verfügbare Patch-Version verwenden — sie enthält alle Bugfixes des Trains. Einzelne Patch-Releases können übersprungen werden, wenn ein neuerer Patch existiert (z.B. v1.62.x wurde übersprungen, da v1.63.1 der letzte Patch vor v1.64 war).

### Operator-Upgrade-Reihenfolge

1. **Vorab-Checks**
   ```bash
   kubectl get kubevirt -n kubevirt
   kubectl get pods -n kubevirt
   kubectl get cdi -n cdi
   kubectl get pods -n cdi
   kubectl get pods -n windows-ad   # bekannter Zustand vor Upgrade dokumentieren
   argocd app get kubevirt-operator
   argocd app get cdi-operator
   argocd app get windows-ad
   ```

2. **Release-Notes prüfen** (KubeVirt und ggf. CDI) auf:
   - Entfernte/deprecated Feature Gates (müssen ggf. aus der CR entfernt werden, sonst schlägt der Operator beim Start fehl)
   - Entfernte Netzwerk-Binding-Typen (z.B. macvtap, SLIRP in v1.8) — prüfen ob VM-Specs betroffene Bindings nutzen
   - CRD-API-Version-Removals (z.B. `instancetype.kubevirt.io/v1alpha{1,2}` in v1.7)
   - Metrik-Umbenennungen (Prometheus-Alerts/Dashboards ggf. anpassen)

3. **Dateien anpassen** — Kustomize referenziert die Operator-Manifeste direkt als Remote-Base von GitHub:

   **`gitops/config/kubevirt/kustomization.yaml`**
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - https://github.com/kubevirt/kubevirt/releases/download/<VERSION>/kubevirt-operator.yaml
     - kubevirt-cr.yaml
   ```

   **`gitops/config/cdi/kustomization.yaml`** (nur wenn CDI mit-upgraded wird)
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - https://github.com/kubevirt/containerized-data-importer/releases/download/<VERSION>/cdi-operator.yaml
     - cdi-cr.yaml
   ```

   Da die KubeVirt-CR (`kubevirt-cr.yaml`) **kein** `imageTag` setzt, ist die effektive Operator-Version ausschließlich durch die Release-URL in `kustomization.yaml` bestimmt (CR-Version = Operator-Version, "locked").

4. **Commit & Push**
   ```bash
   git add gitops/config/kubevirt/kustomization.yaml gitops/config/cdi/kustomization.yaml
   git commit -m "chore: upgrade KubeVirt <alt>→<neu>[, CDI <alt>→<neu>]"
   git push
   ```

5. **ArgoCD Sync** (selfHeal ist bei beiden Operator-Apps aktiv, greift also automatisch — bei Bedarf manuell forcieren)
   ```bash
   argocd app sync kubevirt-operator
   argocd app sync cdi-operator
   # bei abgelaufener ArgoCD-Session als Fallback:
   kubectl apply -k gitops/config/kubevirt/
   kubectl apply -k gitops/config/cdi/
   ```

6. **Verify**
   ```bash
   # KubeVirt-Operator-Version
   kubectl get deployment virt-operator -n kubevirt \
     -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KUBEVIRT_VERSION")].value}'

   # Alternative/robuster (CR-Status statt Deployment-Env):
   kubectl get kubevirt kubevirt -n kubevirt -o jsonpath='{.status.observedKubeVirtVersion}'

   # KubeVirt CR Phase muss "Deployed" sein
   kubectl get kubevirt kubevirt -n kubevirt -o jsonpath='{.status.phase}'

   # Alle virt-* Pods Running (nodeSelector: nur AMD64-Nodes)
   kubectl get pods -n kubevirt -o wide

   # CDI-Version
   kubectl get cdi cdi -n cdi -o jsonpath='{.status.observedVersion}'
   kubectl get pods -n cdi -o wide
   ```

   **Go/No-Go:** `phase=Deployed`, alle Pods `Running`, Version-Felder zeigen die Zielversion → nächster Minor-Schritt oder Upgrade abgeschlossen.

### Ausblick: Windows Server 2025 ARM auf Colima (nicht im Homelab-Cluster)

Ab KubeVirt v1.8.x sind relevante ARM64-Fixes enthalten (SMBIOS-Sichtbarkeit in Guests, Node-Labeller unterstützt ARM64-Cluster inkl. machine-type Labels). Für einen zukünftigen Test auf Colima (ARM64-Mac), separat vom Homelab-Cluster:

1. `colima start --vm-type vz --arch aarch64 --cpu 4 --memory 8`
2. `nodeSelector: kubernetes.io/arch: amd64` in `kubevirt-cr.yaml` entfernen oder auf `arm64` wechseln — in einem separaten Runbook dokumentieren
3. Setzt echtes KVM oder Passthrough voraus; Colima mit Virtualization Framework (vz) kann ggf. KVM-Beschleunigung für ARM-Guests bieten
4. Windows Server 2025 ARM ISO müsste als ARM64-Image vorliegen; Import via CDI DataVolume oder direkter PVC-Import über Longhorn

Solange `nodeSelector: amd64` in der CR gesetzt ist, laufen virt-handler etc. ausschließlich auf AMD64-Nodes im Homelab-Cluster.

## Bekannte Stolperfallen / Lessons Learned

- **KubeVirt-CR hat kein `imageTag`** — die Operator-Version wird ausschließlich über die Release-URL in `kustomization.yaml` gesteuert. Ein Versions-Mismatch zwischen `kubevirt-operator.yaml`-URL und erwarteter CR-Version ist der häufigste Fehler.
- **v1.7:** `instancetype.kubevirt.io/v1alpha{1,2}` API und CRDs wurden entfernt. Objekte in diesen API-Versionen müssen vor dem Upgrade auf `v1beta1` migriert werden. Für windows-ad (manuelle VM-Spec ohne Instancetypes) kein Thema, aber bei künftigen VMs prüfen.
- **v1.8 Breaking Changes:**
  - macvtap-Binding entfernt → VM-Specs mit `interface: macvtap` müssen auf `bridge` oder `masquerade` migriert werden.
  - SLIRP-Binding entfernt → VM-Specs mit `interface: slirp` müssen migriert werden.
  - VirtioFS Feature-Gate entfernt (jetzt GA) → falls in der CR gesetzt, muss es entfernt werden, sonst schlägt der Operator-Start fehl.
  - Metrik-Umbenennung `kubevirt_vmi_migration_data_total_bytes` → `kubevirt_vmi_migration_data_bytes_total` — Prometheus-Alerts/Dashboards prüfen.
  - RBAC-Härtung: VNC/Screenshot-Rechte aus der `kubevirt.io:edit` ClusterRole entfernt.
- **ArgoCD OutOfSync nach Upgrade:** Tritt gelegentlich auf, weil der Operator Status- und generierte CRD-Felder zurückschreibt. `ignoreDifferences` auf `/status`, `/metadata/annotations` (KubeVirt-CR und CRDs) sowie `/spec/versions`, `/spec/conversion` (CDI-CRDs) fängt das i.d.R. ab. Falls nicht: `argocd app get kubevirt-operator --hard-refresh` und `argocd app sync kubevirt-operator --force`.
- **CDI OutOfSync (bekanntes Muster):** `ignoreDifferences` auf `/spec/versions` und `/spec/conversion` in `cdi-operator.yaml` sollte das abfangen. Falls nicht: `argocd app sync cdi-operator --server-side-apply`.
- **KubeVirt bleibt in "Deploying":** `kubectl logs -n kubevirt -l kubevirt.io=virt-operator --tail=50` und `kubectl describe kubevirt kubevirt -n kubevirt` prüfen.
- **windows-ad VM ist vom Upgrade-Prozess entkoppelt:** Die windows-ad ArgoCD-App hat `selfHeal: false`, weil KubeVirt/CDI ständig Status in die VM-/DataVolume-Objekte zurückschreiben. Nach einem KubeVirt/CDI-Upgrade wird die VM **separat** geprüft, nicht automatisch mit-upgraded:
  1. Longhorn-Volume re-attachen / Robustness prüfen
  2. `virt-launcher` Pod löschen (VM-Controller startet automatisch einen neuen)
  3. VM-Status prüfen (`kubectl get vm,vmi -n windows-ad`)
- **Nur AMD64-Nodes:** `kubevirt-cr.yaml` setzt `nodeSelector: kubernetes.io/arch: amd64` für `infra` und `workloads` — ARM64-Nodes (Raspberry Pi) bekommen keinen virt-handler. Bei ARM64-Erweiterungsplänen (siehe Colima-Ausblick oben) muss das explizit angepasst werden.

## Rollback-Plan

- Da beide ArgoCD-Apps (`kubevirt-operator`, `cdi-operator`) `prune: false` gesetzt haben, entfernt ein Rollback der `kustomization.yaml`-Release-URL auf die vorherige Version **nicht** automatisch neuere CRD-Felder — ein Git-Revert des Versions-Commits plus `argocd app sync --force` ist der Standardweg:
  ```bash
  git revert <upgrade-commit-sha>
  git push
  argocd app sync kubevirt-operator --force
  argocd app sync cdi-operator --force
  ```
- Nach Rollback: gleiche Verify-Schritte wie beim Upgrade (Phase `Deployed`, Pods `Running`, Versionsfelder zeigen wieder die alte Version).
- Die windows-ad VM ist durch `selfHeal: false` und `prune: false` auf der windows-ad-App vom Rollback der Operatoren isoliert — sie muss nach einem Rollback nicht separat zurückgesetzt werden, sollte aber auf Fehlzustände geprüft werden (siehe Stolperfallen).
- **Kein Downtime-Fenster für windows-ad nötig**, solange die VM ohnehin nicht produktiv im Zugriff ist (Stand dieses Runbooks: virt-launcher der VM war während mehrerer Upgrade-Schritte im `Error`-Zustand, kein laufender Workload, daher kein Risiko).

## Referenzen
- GitHub Releases KubeVirt: https://github.com/kubevirt/kubevirt/releases
- GitHub Releases CDI: https://github.com/kubevirt/containerized-data-importer/releases
- Interne Doku: `docs/kubevirt-prerequisites.md` (Setup, Troubleshooting RDP/NetworkPolicy/virtctl für windows-ad)
- Interne Doku: `docs/windows-kubevirt-installation.md` (Windows-Server-2025-Image-Erstellung für KubeVirt)
- Verwandtes Runbook: `docs/upgrades/windows-ad.md` (Windows AD VM selbst, getrennt von KubeVirt/CDI-Operator-Upgrades)
