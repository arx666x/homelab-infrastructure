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

---

## Troubleshooting

### RDP nicht erreichbar nach VM-Neustart

#### Symptom
RDP-Verbindung auf `192.168.20.50:3389` schlaegt fehl obwohl die VM laeuft.

#### Ursache 1: Windows-Dienste nicht gestartet (transient)
Nach einem unerwarteten VM-Neustart (z.B. durch KubeVirt `runStrategy: Always`
nach einem Shutdown mit Phase `Succeeded`) sind RDP-Registry-Einstellungen
und TermService moeglicherweise nicht aktiv. Dies muss nach jedem Neustart
ueber den QEMU Guest Agent neu gesetzt werden bis Phase 3 des Setup-Scripts
persistent laeuft.

**Diagnose:**
```bash
# VM laeuft aber Ports sind zu?
for port in 3389 445 389; do
  echo -n "Port $port: "
  timeout 3 bash -c "cat < /dev/tcp/10.42.0.97/$port" 2>/dev/null \
    && echo "OPEN" || echo "CLOSED"
done

# Pruefe ob Windows laeuft (Guest Agent):
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
virtctl guestosinfo windows-ad-dc -n windows-ad
```

**Fix via QEMU Guest Agent:**
```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Schritt 1: RDP-Registryeintraege setzen und TermService neu starten
kubectl exec -n windows-ad $(kubectl get pods -n windows-ad -o name) -c compute -- \
  virsh qemu-agent-command windows-ad_windows-ad-dc \
  '{"execute":"guest-exec","arguments":{"path":"powershell.exe","arg":["-Command",
  "New-NetFirewallRule -DisplayName AD-RDP -Direction Inbound -Protocol TCP -LocalPort 3389 -Action Allow -ErrorAction SilentlyContinue;
  Set-ItemProperty -Path \"HKLM:\\System\\CurrentControlSet\\Control\\Terminal Server\" -Name fDenyTSConnections -Value 0 -Type DWord;
  Set-ItemProperty -Path \"HKLM:\\System\\CurrentControlSet\\Control\\Terminal Server\\WinStations\\RDP-Tcp\" -Name SecurityLayer -Value 0 -Type DWord;
  Set-ItemProperty -Path \"HKLM:\\System\\CurrentControlSet\\Control\\Terminal Server\\WinStations\\RDP-Tcp\" -Name UserAuthentication -Value 0 -Type DWord;
  Set-Service -Name TermService -StartupType Automatic;
  Restart-Service TermService -Force"],"capture-output":true}}'

# Schritt 2: PID aus der Antwort nehmen und Status abfragen
kubectl exec -n windows-ad $(kubectl get pods -n windows-ad -o name) -c compute -- \
  virsh qemu-agent-command windows-ad_windows-ad-dc \
  '{"execute":"guest-exec-status","arguments":{"pid":<PID>}}'

# Ausgabe ist Base64-kodiert - dekodieren:
echo "<out-data>" | base64 -d
```

#### Ursache 2: NetworkPolicy blockiert RDP (kube-proxy SNAT)

**Hintergrund:** Die VM verwendet `masquerade` Netzwerk-Modus. Traffic der
ueber den MetalLB LoadBalancer (`192.168.20.50`) kommt wird durch kube-proxy
mit SNAT umgeschrieben — die Source-IP wird zur Node-IP (`192.168.20.x`),
nicht zur Original-Client-IP (`192.168.11.x`). Eine NetworkPolicy die nur
`192.168.11.0/24` erlaubt wird dadurch umgangen.

**Diagnose:**
```bash
# NetworkPolicy pruefen:
kubectl get networkpolicy -n windows-ad -o yaml | grep -A10 "3389"

# nft Logs pruefen ob Pakete gedroppt werden:
sudo nft list ruleset | grep "DROP by policy windows-ad"
```

**Fix in `gitops/config/windows-ad/05-networkpolicy.yaml`:**
```yaml
# RDP: Management-VLAN, Cluster-Nodes und Pod-Netzwerk erlauben
- from:
    - ipBlock:
        cidr: 192.168.11.0/24   # Management-VLAN (direkte Verbindungen)
    - ipBlock:
        cidr: 192.168.20.0/24   # Kubernetes-VLAN (Node-IPs nach SNAT)
    - ipBlock:
        cidr: 10.42.0.0/16      # Pod-Netzwerk (cluster-intern)
  ports:
    - port: 3389
      protocol: TCP
```

#### Ursache 3: VM-IP hat sich nach Neustart geaendert

Nach einem `kubectl delete vmi` bekommt die neue VMI eine andere IP.
Der LoadBalancer Service (`windows-ad-lb`) aktualisiert die Endpoints
automatisch ueber den Pod-Selector — keine manuelle Aktion noetig.

**Aktuelle VM-IP pruefen:**
```bash
kubectl get vmi windows-ad-dc -n windows-ad -o jsonpath='{.status.interfaces[0].ipAddress}'
# oder
kubectl get pod -n windows-ad -o wide
```

### virtctl Befehle schlagen fehl

```
dial tcp 127.0.0.1:8080: connect: connection refused
```

**Ursache:** virtctl sucht den API-Server auf localhost. KUBECONFIG muss
explizit gesetzt werden:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
virtctl <befehl>
```

**Versionskonflikt:**
```
Client Version: 1.7.0 / Server Version: v1.3.1
```
Einige Befehle (z.B. `guestexec`) sind nur in neueren virtctl-Versionen
verfuegbar. Als Alternative den QEMU Guest Agent direkt ueber `virsh` nutzen
(siehe oben).

### VM startet wiederholt neu (runStrategy: Always)

Wenn Windows sich selbst herunterfaehrt (z.B. Windows Update), startet
KubeVirt die VM automatisch neu (`runStrategy: Always`). Im KubeVirt-Log
erscheint dann:

```
"Stopping VM with VMI in phase Succeeded"
"Starting VM due to runStrategy: Always"
```

Dies ist erwartetes Verhalten. Nach dem Neustart muss ggf. RDP manuell
reaktiviert werden (siehe Ursache 1 oben).

**Windows Auto-Update deaktivieren** (empfohlen fuer stabile Dev-Umgebungen):
```powershell
# In Windows PowerShell (via RDP oder Guest Agent):
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" `
  -Name "NoAutoUpdate" -Value 1 -Type DWord -Force
```
