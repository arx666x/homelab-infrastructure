# KubeVirt: Voraussetzungen und Node-Vorbereitung

Dieses Dokument gehoert in die Pre-req Dokumentation des Homelabs.
Es beschreibt was VOR dem ersten ArgoCD-Sync der KubeVirt-Apps erledigt
sein muss.

## Uebersicht

KubeVirt besteht aus zwei Komponenten die unabhaengig voneinander
installiert werden:

| Komponente | Zweck | ArgoCD Wave | Namespace |
|-----------|-------|-------------|-----------|
| KubeVirt Operator | VM-Laufzeitumgebung, virt-handler auf Nodes | 20 | kubevirt |
| CDI Operator | DataVolume / Image-Import von Synology NAS | 21 | cdi |
| Windows AD VM | Active Directory DC fuer seri.sailpointdemo.com | 30 | windows-ad |

## Schritt 1: Node-Vorbereitung (einmalig)

Muss auf allen **AMD64-Nodes** (GMKtec NucBox M5 Ultra) ausgefuehrt werden.
Die **ARM64-Nodes** (Raspberry Pi 5) werden von KubeVirt nicht genutzt —
das steuert der `nodeSelector: kubernetes.io/arch: amd64` in der KubeVirt-CR.

```bash
# Alle AMD64-Nodes auf einmal vorbereiten:
chmod +x scripts/prepare-kubevirt-nodes.sh
./scripts/prepare-kubevirt-nodes.sh

# Oder einzelner Node:
./scripts/prepare-kubevirt-nodes.sh 192.168.20.11
```

Das Script erledigt auf jedem AMD64-Node:

- Prueft CPU-Virtualisierungssupport (`svm` bei AMD Ryzen)
- Laedt `kvm` und `kvm_amd` Kernel-Module
- Konfiguriert dauerhaftes Laden via `/etc/modules-load.d/kubevirt-kvm.conf`
- Setzt `/dev/kvm` Berechtigungen via udev-Regel
- Installiert `qemu-utils` (fuer Disk-Operationen)
- Konfiguriert 4GB Hugepages (verbessert Windows-VM Performance)

### Manuelle Pruefung nach dem Script

```bash
# KVM-Modul geladen?
ssh 192.168.20.31 'lsmod | grep kvm'
# Erwartete Ausgabe:
# kvm_amd               180224  0
# kvm                  1069056  1 kvm_amd

# /dev/kvm erreichbar?
ssh 192.168.20.31 'ls -la /dev/kvm'
# Erwartete Ausgabe:
# crw-rw-rw- 1 root kvm 10, 232 ... /dev/kvm

# KubeVirt kann /dev/kvm nutzen (Test mit privilegiertem Pod):
kubectl run kvm-test --rm -it --restart=Never \
  --image=fedora \
  --overrides='"'"'{"spec":{"nodeSelector":{"kubernetes.io/arch":"amd64"},"containers":[{"name":"kvm-test","image":"fedora","securityContext":{"privileged":true},"command":["ls","-la","/dev/kvm"]}]}}'"'"'
```

## Schritt 2: Secrets anlegen (einmalig)

Die Secrets muessen angelegt werden **bevor** ArgoCD synct:

```bash
# Fuer windows-ad (CA-Zertifikat, LDAP-Credentials):
chmod +x gitops/config/windows-ad/create-secrets.sh
./gitops/config/windows-ad/create-secrets.sh
```

Was das Script anlegt:
- `ad-ldaps-pkcs12-password` — Passwort fuer cert-manager PKCS12-Export
- `windows-ad-ca` — CA-Zertifikat von der Synology NAS
- `ldap-service-credentials` — Service Account fuer LDAPS-Zugriff

Quellen auf Synology NAS:
- `http://diskstation:6666/windows-server-2025-ad-seri.certs/ca.cer`
- `http://diskstation:6666/windows-server-2025-ad-seri.certs/ca.crt.b64`

## Schritt 3: In Repo einchecken und deployen

```bash
# Alles committen
git add \
  gitops/apps/kubevirt/ \
  gitops/config/kubevirt/ \
  gitops/config/cdi/ \
  gitops/config/windows-ad/ \
  scripts/prepare-kubevirt-nodes.sh \
  docs/kubevirt-prerequisites.md

git commit -m "feat: add kubevirt, cdi operators and windows-ad DC"
git push
```

ArgoCD picked die neuen Apps automatisch auf (Root-App scannt `gitops/apps/`).
Durch die Sync-Waves laeuft der Deployment in der richtigen Reihenfolge ab:

```
Wave 20: kubevirt-operator  -> installiert CRDs, virt-handler DaemonSet
Wave 21: cdi-operator       -> installiert CDI, Upload-Proxy
Wave 30: windows-ad         -> Namespace, Cert, DataVolume (Image-Import), VM
```

## Schritt 4: Deployment-Fortschritt verfolgen

```bash
# KubeVirt-Operator Status
kubectl get kubevirt -n kubevirt -w

# virt-handler muss auf allen AMD64-Nodes laufen (3 Pods erwartet)
kubectl get pods -n kubevirt -l kubevirt.io=virt-handler

# CDI-Status
kubectl get cdi -n cdi

# DataVolume-Import verfolgen (startet automatisch mit Wave 30)
kubectl get datavolume -n windows-ad -w

# VM-Status nach abgeschlossenem Import
kubectl get vm,vmi -n windows-ad
```

## Versionsverwaltung

KubeVirt und CDI werden ueber Kustomize Remote-Bases referenziert.
Bei einem Versions-Upgrade:

1. Version in `config/kubevirt/kustomization.yaml` anpassen
2. Version in `config/cdi/kustomization.yaml` anpassen
3. **Reihenfolge einhalten**: Operator zuerst updaten, dann CR

```bash
# Aktuelle Releases pruefen:
# KubeVirt: https://github.com/kubevirt/kubevirt/releases
# CDI:      https://github.com/kubevirt/containerized-data-importer/releases
```

## Bekannte ArgoCD-Eigenheiten

- `prune: false` auf kubevirt-operator und cdi-operator — Operatoren
  nie automatisch loeschen, da sonst alle VMs geloescht wuerden
- `ignoreDifferences` fuer CRD-Status-Felder — Kubernetes normalisiert
  CRD-Felder intern, was ArgoCD sonst als OutOfSync werten wuerde
- `selfHeal: false` auf windows-ad — KubeVirt schreibt VM-Status
  kontinuierlich zurueck, das darf kein Sync ausloesen
