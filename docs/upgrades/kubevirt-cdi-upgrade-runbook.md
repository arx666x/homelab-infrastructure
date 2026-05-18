# KubeVirt + CDI Upgrade Runbook

**Ziel:** KubeVirt v1.3.1 → v1.8.2 | CDI v1.59.0 → v1.65.0  
**Methode:** Schrittweise über Minor-Versionen, GitOps via ArgoCD  
**Letzte Aktualisierung:** 2026-05-18 (Schritt 5: v1.7.3 → v1.8.2)

---

## Ausgangslage

- KubeVirt aktuell: **v1.3.1** (kubevirt-operator in Error)
- CDI aktuell: **v1.59.0**
- `virt-launcher-windows-ad-dc-*` → `Error` (kein laufender Workload, kein Risiko)
- Longhorn-Volume `windows-ad-disk` → `detached` (wird danach separat gefixt)
- ArgoCD: `kubevirt-operator` (Wave 20), `cdi-operator` (Wave 21), `windows-ad` (Wave 30)
- KubeVirt-CR hat **kein** `imageTag` gesetzt → Operator-Version = CR-Version (locked)

## Upgrade-Pfad

| Schritt | KubeVirt | CDI | Status |
|---------|----------|-----|--------|
| 1 | v1.3.1 → **v1.4.0** | v1.59.0 → **v1.60.5** | ✅ abgeschlossen |
| 2 | v1.4.0 → **v1.5.2** | v1.60.5 → **v1.61.5** | ✅ abgeschlossen |
| 3 | v1.5.2 → **v1.6.5** | v1.61.5 → **v1.63.1** | ✅ abgeschlossen |
| 4 | v1.6.5 → **v1.7.3** | v1.63.1 → **v1.65.0** | ✅ abgeschlossen |
| 5 | v1.7.3 → **v1.8.2** | v1.65.0 (keine Änderung) | 🔄 aktuell |

> **Warum diese Patch-Versionen?**  
> Immer die letzte verfügbare Patch-Version innerhalb eines Minor-Zweigs –
> enthält alle Bug-Fixes des jeweiligen Minor-Trains.  
> v1.62.x wird übersprungen (v1.63.1 ist der letzte Patch vor v1.64).

---

## Vorab-Checks

```bash
# Aktuellen KubeVirt-Status prüfen
kubectl get kubevirt -n kubevirt
kubectl get pods -n kubevirt

# Aktuellen CDI-Status prüfen
kubectl get cdi -n cdi
kubectl get pods -n cdi

# windows-ad Namespace – erwartet: virt-launcher in Error (bekannt)
kubectl get pods -n windows-ad

# ArgoCD App-Status
argocd app get kubevirt-operator
argocd app get cdi-operator
argocd app get windows-ad
```

---

## Schritt 1: v1.4.0 / CDI v1.60.5

### 1a. Dateien anpassen

**`gitops/config/kubevirt/kustomization.yaml`**
```yaml
resources:
  - https://github.com/kubevirt/kubevirt/releases/download/v1.4.0/kubevirt-operator.yaml
  - kubevirt-cr.yaml
```

**`gitops/config/cdi/kustomization.yaml`**
```yaml
resources:
  - https://github.com/kubevirt/containerized-data-importer/releases/download/v1.60.5/cdi-operator.yaml
  - cdi-cr.yaml
```

### 1b. Commit & Push

```bash
git add gitops/config/kubevirt/kustomization.yaml gitops/config/cdi/kustomization.yaml
git commit -m "chore: upgrade KubeVirt v1.3.1→v1.4.0, CDI v1.59.0→v1.60.5"
git push
```

### 1c. ArgoCD sync

```bash
# ArgoCD triggert automatisch (selfHeal: true) – oder manuell:
argocd app sync kubevirt-operator
argocd app sync cdi-operator
```

### 1d. Verify

```bash
# KubeVirt-Operator-Pod muss v1.4.0 zeigen
kubectl get deployment virt-operator -n kubevirt \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KUBEVIRT_VERSION")].value}'
# Erwarteter Output: v1.4.0

# KubeVirt CR muss Deployed/Available sein
kubectl get kubevirt kubevirt -n kubevirt -o jsonpath='{.status.phase}'
# Erwarteter Output: Deployed

# Alle kubevirt-Pods Running
kubectl get pods -n kubevirt

# CDI-Operator-Version prüfen
kubectl get cdi cdi -n cdi -o jsonpath='{.status.observedVersion}'
# Erwarteter Output: v1.60.5

# CDI-Pods Running
kubectl get pods -n cdi
```

**Go/No-Go:** KubeVirt `phase=Deployed`, alle Pods Running → weiter mit Schritt 2.

---

## Schritt 2: v1.5.2 / CDI v1.61.5

### 2a. Dateien anpassen

**`gitops/config/kubevirt/kustomization.yaml`**
```yaml
resources:
  - https://github.com/kubevirt/kubevirt/releases/download/v1.5.2/kubevirt-operator.yaml
  - kubevirt-cr.yaml
```

**`gitops/config/cdi/kustomization.yaml`**
```yaml
resources:
  - https://github.com/kubevirt/containerized-data-importer/releases/download/v1.61.5/cdi-operator.yaml
  - cdi-cr.yaml
```

### 2b. Commit & Push

```bash
git add gitops/config/kubevirt/kustomization.yaml gitops/config/cdi/kustomization.yaml
git commit -m "chore: upgrade KubeVirt v1.4.0→v1.5.2, CDI v1.60.5→v1.61.5"
git push
```

### 2c. ArgoCD sync

```bash
argocd app sync kubevirt-operator
argocd app sync cdi-operator
```

### 2d. Verify

```bash
kubectl get deployment virt-operator -n kubevirt \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KUBEVIRT_VERSION")].value}'
# Erwarteter Output: v1.5.2

kubectl get kubevirt kubevirt -n kubevirt -o jsonpath='{.status.phase}'
# Erwarteter Output: Deployed

kubectl get cdi cdi -n cdi -o jsonpath='{.status.observedVersion}'
# Erwarteter Output: v1.61.5
```

> **Hinweis v1.5:** `AutoResourceLimits` Feature Gate ist jetzt GA und standardmäßig
> aktiv. Kein Handlungsbedarf, aber beobachten ob Ressourcen-Requests sich ändern.

**Go/No-Go:** KubeVirt `phase=Deployed`, CDI `v1.61.5` → weiter mit Schritt 3.

---

## Schritt 3: v1.6.5 / CDI v1.63.1

### 3a. Dateien anpassen

**`gitops/config/kubevirt/kustomization.yaml`**
```yaml
resources:
  - https://github.com/kubevirt/kubevirt/releases/download/v1.6.5/kubevirt-operator.yaml
  - kubevirt-cr.yaml
```

**`gitops/config/cdi/kustomization.yaml`**
```yaml
resources:
  - https://github.com/kubevirt/containerized-data-importer/releases/download/v1.63.1/cdi-operator.yaml
  - cdi-cr.yaml
```

### 3b. Commit & Push

```bash
git add gitops/config/kubevirt/kustomization.yaml gitops/config/cdi/kustomization.yaml
git commit -m "chore: upgrade KubeVirt v1.5.2→v1.6.5, CDI v1.61.5→v1.63.1"
git push
```

### 3c. ArgoCD sync

```bash
argocd app sync kubevirt-operator
argocd app sync cdi-operator
```

### 3d. Verify

```bash
kubectl get deployment virt-operator -n kubevirt \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KUBEVIRT_VERSION")].value}'
# Erwarteter Output: v1.6.5

kubectl get kubevirt kubevirt -n kubevirt -o jsonpath='{.status.phase}'
# Erwarteter Output: Deployed

kubectl get cdi cdi -n cdi -o jsonpath='{.status.observedVersion}'
# Erwarteter Output: v1.63.1
```

> **Hinweis v1.6:** Neues Standardverhalten bei `rolloutStrategy` – bisheriger
> Default ändert sich. Da die windows-ad VM ohnehin down ist, kein Risiko.
> `virt-api` skaliert jetzt dynamisch nach Anzahl schedulbarer Nodes.

**Go/No-Go:** KubeVirt `phase=Deployed`, CDI `v1.63.1` → weiter mit Schritt 4.

---

## Schritt 4: v1.7.3 / CDI v1.65.0 (Ziel)

### 4a. Dateien anpassen

**`gitops/config/kubevirt/kustomization.yaml`**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  # KubeVirt Operator (CRDs + Controller)
  - https://github.com/kubevirt/kubevirt/releases/download/v1.7.3/kubevirt-operator.yaml
  # KubeVirt CR (aktiviert den Operator)
  - kubevirt-cr.yaml
```

**`gitops/config/cdi/kustomization.yaml`**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  # CDI Operator
  - https://github.com/kubevirt/containerized-data-importer/releases/download/v1.65.0/cdi-operator.yaml
  # CDI CR
  - cdi-cr.yaml
```

### 4b. Commit & Push

```bash
git add gitops/config/kubevirt/kustomization.yaml gitops/config/cdi/kustomization.yaml
git commit -m "chore: upgrade KubeVirt v1.6.5→v1.7.3, CDI v1.63.1→v1.65.0"
git push
```

### 4c. ArgoCD sync

```bash
argocd app sync kubevirt-operator
argocd app sync cdi-operator
```

### 4d. Final Verify

```bash
# KubeVirt Version
kubectl get deployment virt-operator -n kubevirt \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KUBEVIRT_VERSION")].value}'
# Erwarteter Output: v1.7.3

# KubeVirt CR Status
kubectl get kubevirt kubevirt -n kubevirt
# NAME       AGE   PHASE
# kubevirt   ...   Deployed

# Alle virt-* Pods Running (nur auf AMD64-Nodes wegen nodeSelector)
kubectl get pods -n kubevirt -o wide

# CDI Version
kubectl get cdi cdi -n cdi -o jsonpath='{.status.observedVersion}'
# Erwarteter Output: v1.65.0

# CDI-Pods Running
kubectl get pods -n cdi -o wide

# KubeVirt CR detailliert
kubectl describe kubevirt kubevirt -n kubevirt | grep -A5 "Conditions"
```

> **Hinweis v1.7:**
> - `instancetype.kubevirt.io/v1alpha{1,2}` API und CRDs wurden entfernt.
>   Falls ihr irgendwo `v1alpha1/2` Instancetype-Objekte habt → müssen auf
>   `v1beta1` migriert werden. Für die windows-ad VM mit manueller VM-Spec
>   kein Thema.
> - v1.7.3 enthält Fix für `virt-handler domain-notify.sock` Restart –
>   direkt relevant für den aktuellen Error-Zustand der windows-ad VM.
> - v1.7.3 enthält Fix für SMBIOS-Info in ARM64 Guest VMs.

---

## Schritt 5: v1.8.2 / CDI v1.65.0 (Ziel 2026-05-18)

### Release-Highlights v1.8.x

> **Breaking Changes – vor dem Upgrade prüfen:**
> - **macvtap-Binding entfernt:** Falls irgendwo `interface: macvtap` in VM-Specs → auf
>   `bridge` oder `masquerade` migrieren. windows-ad nutzt kein macvtap → kein Risiko.
> - **SLIRP-Binding entfernt:** Falls `interface: slirp` in VM-Specs → migrieren.
>   windows-ad nutzt kein SLIRP → kein Risiko.
> - **VirtioFS Feature-Gate entfernt:** VirtioFS ist jetzt GA, das `VirtioFS` Feature Gate
>   muss aus der CR entfernt werden (falls vorhanden). Aktuell nicht gesetzt → kein Risiko.
> - **Metric-Umbenennung:** `kubevirt_vmi_migration_data_total_bytes` →
>   `kubevirt_vmi_migration_data_bytes_total` (Prometheus-Alerts ggf. anpassen).

> **Neue Features v1.8.x:**
> - **HAL (Hypervisor Abstraction Layer):** KubeVirt kann jetzt Backends jenseits von KVM
>   nutzen (Fundament für zukünftige Hypervisor-Flexibilität).
> - **ARM64-Verbesserungen:** SMBIOS-Informationen sind jetzt in ARM64-Guest-VMs sichtbar
>   (relevant für zukünftigen Windows Server 2025 ARM auf Colima/ARM-Nodes).
>   Node-Labeller unterstützt jetzt ARM64-Cluster inkl. machine-type Labels.
> - **ContainerPath Volumes:** Flexiblerer Storage-Attachment-Mechanismus.
> - **Incremental Backup (CBT):** Storage-agnostische inkrementelle VM-Backups via
>   QEMU/libvirt Changed Block Tracking.
> - **PCIe NUMA-aware Topology:** GPU- und Host-Device-Placement respektiert NUMA.
> - **rebootPolicy:** Neues Feld für VM-Reboot-Verhalten.
> - **RBAC-Härtung:** VNC/Screenshot aus `kubevirt.io:edit` ClusterRole entfernt.

> **CDI v1.65.0** bleibt unverändert – kompatibel mit KubeVirt 1.8.x.

### 5a. Datei anpassen

**`gitops/config/kubevirt/kustomization.yaml`**
```yaml
resources:
  - https://github.com/kubevirt/kubevirt/releases/download/v1.8.2/kubevirt-operator.yaml
  - kubevirt-cr.yaml
```

CDI bleibt auf v1.65.0 – keine Änderung an `gitops/config/cdi/kustomization.yaml`.

### 5b. Commit & Push

```bash
git add gitops/config/kubevirt/kustomization.yaml
git commit -m "chore: upgrade KubeVirt v1.7.3→v1.8.2"
git push
```

### 5c. ArgoCD sync

```bash
# ArgoCD selfHeal triggert automatisch – oder manuell:
argocd app sync kubevirt-operator
```

### 5d. Final Verify

```bash
# KubeVirt Version
kubectl get deployment virt-operator -n kubevirt \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KUBEVIRT_VERSION")].value}'
# Erwarteter Output: v1.8.2

# KubeVirt CR Status
kubectl get kubevirt kubevirt -n kubevirt
# NAME       AGE   PHASE
# kubevirt   ...   Deployed

# Alle virt-* Pods Running (nur auf AMD64-Nodes wegen nodeSelector)
kubectl get pods -n kubevirt -o wide

# CDI bleibt v1.65.0
kubectl get cdi cdi -n cdi -o jsonpath='{.status.observedVersion}'
# Erwarteter Output: v1.65.0

# KubeVirt CR detailliert
kubectl describe kubevirt kubevirt -n kubevirt | grep -A5 "Conditions"
```

**Go/No-Go:** KubeVirt `phase=Deployed`, alle Pods Running → Upgrade abgeschlossen.

---

### Ausblick: Windows Server 2025 ARM auf Colima

v1.8.2 enthält relevante ARM64-Fixes (SMBIOS-Sichtbarkeit in Guests, Node-Labeller für ARM64).
Damit sind die technischen Grundlagen verbessert. Für den Betrieb auf Colima (ARM64-Mac):

1. **Colima mit KVM:** `colima start --vm-type vz --arch aarch64 --cpu 4 --memory 8`
2. **kubevirt-cr.yaml anpassen:** `nodeSelector: kubernetes.io/arch: amd64` entfernen
   oder auf `arm64` wechseln – in einem separaten Runbook dokumentieren.
3. **KubeVirt auf ARM64-Node:** Setzt echtes KVM oder passthrough voraus; Colima
   mit Virtualization Framework (vz) kann KVM-beschleunigung für ARM Guests bieten.
4. **Windows Server 2025 ARM ISO:** Muss als ARM64-Image vorliegen; CDI DataVolume
   oder direkter PVC-Import über Longhorn.

> **Wichtig:** Colima-Test separat durchführen, nicht im Homelab-Cluster.
> Solange `nodeSelector: amd64` in der CR ist, laufen virt-handler etc. nur auf AMD64-Nodes.

---

## Troubleshooting

### ArgoCD OutOfSync nach Upgrade

```bash
# Status prüfen
argocd app get kubevirt-operator

# Manueller Hard-Refresh
argocd app get kubevirt-operator --hard-refresh
argocd app sync kubevirt-operator --force
```

### KubeVirt bleibt in "Deploying"

```bash
# virt-operator Logs
kubectl logs -n kubevirt -l kubevirt.io=virt-operator --tail=50

# KubeVirt CR Events
kubectl describe kubevirt kubevirt -n kubevirt
```

### CDI OutOfSync (bekanntes Muster)

Die ArgoCD `ignoreDifferences` auf `/spec/versions` und `/spec/conversion`
in `cdi-operator.yaml` sollte das abfangen. Falls nicht:

```bash
argocd app sync cdi-operator --server-side-apply
```

### Nach erfolgreichem Upgrade: windows-ad VM

Die windows-ad VM und das Longhorn-Volume werden **separat** nach dem
Upgrade-Abschluss gefixt. Reihenfolge dann:

1. Longhorn-Volume re-attachen / Robustness prüfen
2. `virt-launcher` Pod löschen (VM-Controller startet neuen)
3. VM-Status prüfen

---

## Schnell-Referenz: Versions-URLs

| Komponente | Version | URL |
|-----------|---------|-----|
| KubeVirt Operator | v1.4.0 | `https://github.com/kubevirt/kubevirt/releases/download/v1.4.0/kubevirt-operator.yaml` |
| KubeVirt Operator | v1.5.2 | `https://github.com/kubevirt/kubevirt/releases/download/v1.5.2/kubevirt-operator.yaml` |
| KubeVirt Operator | v1.6.5 | `https://github.com/kubevirt/kubevirt/releases/download/v1.6.5/kubevirt-operator.yaml` |
| KubeVirt Operator | v1.7.3 | `https://github.com/kubevirt/kubevirt/releases/download/v1.7.3/kubevirt-operator.yaml` |
| KubeVirt Operator | **v1.8.2** | `https://github.com/kubevirt/kubevirt/releases/download/v1.8.2/kubevirt-operator.yaml` |
| CDI Operator | v1.60.5 | `https://github.com/kubevirt/containerized-data-importer/releases/download/v1.60.5/cdi-operator.yaml` |
| CDI Operator | v1.61.5 | `https://github.com/kubevirt/containerized-data-importer/releases/download/v1.61.5/cdi-operator.yaml` |
| CDI Operator | v1.63.1 | `https://github.com/kubevirt/containerized-data-importer/releases/download/v1.63.1/cdi-operator.yaml` |
| CDI Operator | v1.65.0 | `https://github.com/kubevirt/containerized-data-importer/releases/download/v1.65.0/cdi-operator.yaml` |
