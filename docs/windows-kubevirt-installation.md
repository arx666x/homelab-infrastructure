# Windows Server 2025 AD DC
## Installation auf Linux/KVM ohne GUI für KubeVirt

**SERI Homelab | seri.sailpointdemo.com | März 2026**

---

## Zusammenfassung

Dieses Dokument beschreibt den einzig zuverlässigen Weg ein Windows Server 2025 Image zu erstellen das in KubeVirt (k3s Homelab) als Active Directory Domain Controller läuft. Nach zahlreichen gescheiterten Versuchen hat sich folgendes bewaehrt:

- ✅ Windows direkt auf Linux/KVM von ISO installieren mit VirtIO-Treibern
- ✅ noVNC im Browser für GUI-Zugriff ohne Desktop-Umgebung auf dem Linux-Host
- ✅ UEFI ohne Secure Boot
- ✅ VirtIO SCSI als Disk-Controller von Anfang an

---

## Warum alle anderen Ansätze scheiterten

### Versuch 1: VMware Fusion Migration (~6h, gescheitert)

Die naheliegende Idee war ein bestehendes VMware Fusion Image zu konvertieren und in KubeVirt zu deployen.

**NVMe Controller**

VMware nutzte standardmäßig NVMe als Disk-Controller. Die VirtIO-Treiber enthalten keinen VirtIO-NVMe-Treiber — nur VirtIO-SCSI. Jeder Versuch den Bus-Typ in KubeVirt auf `sata`, `scsi` oder `virtio` zu ändern endete im BSOD `IRQL_NOT_LESS_OR_EQUAL`.

**BIOS vs. UEFI**

VMware installiert Windows mit UEFI, KubeVirt/QEMU startete initial mit BIOS (SeaBIOS). SeaBIOS kann UEFI-Partitionen nicht lesen — der Boot-Screen hing bei `Booting from Hard Disk...`.

**Residuale VMware-Treiber**

Selbst nach Deinstallation der VMware Tools blieben Treiber-Reste im System die beim Wechsel des Hardware-Profils zu Kernel-Crashes führten.

> **Lektion:** Eine VMware-zu-QEMU Migration funktioniert nur wenn der Disk-Controller von Anfang an kompatibel war. NVMe in VMware ist eine Sackgasse.

---

### Versuch 2: QEMU auf macOS / HVF (~4h, gescheitert)

Der nächste Versuch war eine Direktinstallation in QEMU auf dem Mac mit HVF-Beschleunigung.

**Zwei CD-ROMs crashen das System**

Windows-ISO und virtio-win-ISO gleichzeitig als IDE CD-ROMs führten unter macOS HVF zu Abstürzen sobald Windows auf das zweite Laufwerk zugriff. USB-Storage als Alternative wurde von Windows Setup nicht als Laufwerk erkannt.

**HVF grundsätzlich instabil für Windows Server 2025**

Auch ohne zweites CD-ROM crashte das Windows Setup bei ca. 20% beim Laden der Treiber. macOS HVF (Hypervisor Framework) ist nicht vollständig kompatibel mit Windows Server 2025. Software-Emulation ohne HVF lief mit ca. 5% Geschwindigkeit — praktisch unbrauchbar.

> **Lektion:** QEMU auf macOS ist für Windows-Installationen ungeeignet. HVF ist kein Ersatz für KVM.

---

### Versuch 3: VMware Fusion (korrekt konfiguriert) + Konvertierung (~5h, fast)

Neuinstallation in VMware Fusion mit SATA-Controller statt NVMe und VirtIO-Treibern. Das Image lief unter KVM mit SATA-Emulation korrekt. In KubeVirt trat dann ein neues Problem auf:

**INACCESSIBLE_BOOT_DEVICE**

KubeVirt nutzt intern immer VirtIO SCSI — erkennbar am Boot-Screen `Scsi(0x0,0x0)` — egal welcher `bus`-Typ in der YAML steht. Windows hatte `vioscsi` zwar installiert aber nicht als BOOT_START-Treiber registriert (`Start=3` statt `Start=0`). Auch das nachträgliche Setzen von `Start=0` per Registry half nicht, da die Treiber-Dateien nur in `C:\Program Files\Virtio-Win\` lagen und nicht in `C:\Windows\System32\drivers\`.

**Recovery-Loop und Tastatur-Hölle**

Windows landete im Recovery-Mode. Dort war es praktisch unmöglich die notwendigen `bcdedit`-Befehle einzugeben:

- VNC/noVNC: Tastatur-Mapping zwischen Mac und Windows Recovery Console fehlerhaft
- Jump Desktop: AltGr / Option-Taste ohne Wirkung auf Remote-System
- Windows Recovery: Eigenes Keyboard-Layout (WinPE-basiert), ignoriert Windows-Spracheinstellungen, immer US-QWERTY intern
- Ergebnis: Slash, geschweifte Klammern und eckige Klammern nicht eingebbar

---

### Warum die Tastatur-Probleme so hartnäckig waren

Das ist ein systematisches Problem aus mehreren Schichten:

| Ebene | Problem |
|-------|---------|
| Mac-Hardware | Kein AltGr. Option-Taste ist nicht AltGr. `{ } [ ] /` liegen auf anderen Kombinationen als auf Windows-Tastaturen. |
| VNC-Protokoll | Tastatur-Events werden als Keycodes übertragen. Mapping zwischen macOS-Keycodes und Windows-Scancodes ist bei Sonderzeichen fehlerhaft. |
| Windows Recovery | WinPE-basiert, ignoriert Windows-Spracheinstellungen komplett. Immer US-QWERTY intern, unabhängig von der gewählten Sprache. |
| Jump Desktop | Modifier-Tasten werden nicht korrekt als AltGr weitergeleitet. Option-Taste hat keine Wirkung auf dem Remote-System. |
| noVNC | Clipboard-Transfer für einzelne Zeichen möglich, aber kein zuverlässiges Tastatur-Mapping für Sonderzeichen in der Recovery-Umgebung. |

> **Fazit:** Wenn Windows in den Recovery-Loop gerät und nur VNC/noVNC als Zugang verfügbar ist, ist das System von einem Mac aus praktisch nicht mehr reparierbar.

---

## Der funktionierende Weg: Direktinstallation auf Linux/KVM

### Voraussetzungen

| Komponente | Details |
|------------|---------|
| Linux-Node | GMKtec (192.168.20.11), Ubuntu, KVM-fähig |
| Pakete | `qemu-system-x86 qemu-utils ovmf novnc websockify` |
| OVMF VARS | `/usr/share/OVMF/OVMF_VARS_4M.fd` |
| Windows ISO | Windows Server 2025, lokal auf Node |
| VirtIO ISO | `virtio-win.iso`, lokal auf Node |
| Ziel-Image | 80GB qcow2 |

---

### Schritt 1: Image und UEFI vorbereiten

```bash
cd ~/windows-install
qemu-img create -f qcow2 windows-fresh.qcow2 80G
cp /usr/share/OVMF/OVMF_VARS_4M.fd ./ovmf-vars.fd
```

---

### Schritt 2: QEMU mit noVNC starten

Zwei IDE CD-ROMs funktionieren unter Linux/KVM problemlos — das war nur unter macOS HVF ein Problem.

```bash
qemu-system-x86_64 \
  -m 4096 -accel kvm -cpu host -smp 4 \
  -drive "if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd" \
  -drive "if=pflash,format=raw,file=./ovmf-vars.fd" \
  -device "virtio-scsi-pci,id=scsi0" \
  -drive "file=windows-fresh.qcow2,format=qcow2,if=none,id=disk0" \
  -device "scsi-hd,drive=disk0,bus=scsi0.0" \
  -drive "file=./windows.iso,media=cdrom,if=none,id=cdrom0" \
  -device "ide-cd,drive=cdrom0,bus=ide.0" \
  -drive "file=./virtio-win.iso,media=cdrom,if=none,id=cdrom1" \
  -device "ide-cd,drive=cdrom1,bus=ide.1" \
  -device "usb-tablet" \
  -device "virtio-net-pci,netdev=net0" \
  -netdev "user,id=net0,hostfwd=tcp::3389-:3389" \
  -monitor "unix:/tmp/qemu-monitor.sock,server,nowait" \
  -vnc :1 -daemonize

websockify --web /usr/share/novnc 6080 localhost:5901 &
```

Dann im Browser auf dem Mac:

```
http://192.168.20.11:6080/vnc.html
```

> **Wichtig:** `-device usb-tablet` verhindert den Doppelzeiger-Versatz in noVNC. Ohne diesen Parameter gibt es einen Versatz von ca. 2cm zwischen Mauszeiger-Anzeige und tatsächlichem Klickpunkt.

---

### Schritt 3: Windows Installation im Browser

1. Sofort eine Taste drücken wenn `Press any key to boot from CD` erscheint
2. Sprache / Zeit / Tastatur wählen — Next
3. Install Now
4. Edition: **Windows Server 2025 Datacenter (Desktop Experience)**
5. **Custom: Install Windows Server only (advanced)**
6. `Load driver` — Browse — CD Drive (E:, virtio-win) — `vioscsi\2k25\amd64`
7. VirtIO SCSI Controller wird geladen — die 80GB Disk erscheint
8. Disk auswählen — Next — Installation läuft durch (~20 Minuten)
9. Administrator-Passwort setzen

> **Wichtig:** Den Treiberpfad `2k25\amd64` verwenden, nicht `w11\amd64` — `2k25` ist der native Windows Server 2025 Treiber.

---

### Schritt 4: VirtIO Netzwerk-Treiber und Guest Agent installieren

Nach der Installation hat Windows noch keinen Netzwerk-Treiber. Entweder im Device Manager manuell (`E:\NetKVM\2k25\amd64`) oder per MSI:

```
E:\virtio-win-gt-x64.msi
```

> **Wichtig:** Nach der MSI-Installation müssen die Treiber-Dateien manuell nach `System32\drivers` kopiert werden — das MSI legt sie nur in `C:\Program Files\Virtio-Win\` ab, nicht wo Windows sie beim Booten sucht!

```powershell
Copy-Item "C:\Program Files\Virtio-Win\Vioscsi\vioscsi.sys" "C:\Windows\System32\drivers\"
Copy-Item "C:\Program Files\Virtio-Win\Network\netkvm.sys" "C:\Windows\System32\drivers\"
Copy-Item "C:\Program Files\Virtio-Win\Balloon\balloon.sys" "C:\Windows\System32\drivers\"
```

Dann Guest Agent installieren:

```
E:\guest-agent\qemu-ga-x86_64.msi
```

---

### Schritt 5: Setup-Skript herunterladen und ausführen

Python HTTP-Server auf dem Linux-Node starten (zweites SSH-Fenster):

```bash
cd ~/windows-install && python3 -m http.server 8080
```

In Windows PowerShell (`10.0.2.2` ist die QEMU-Host-IP von innen erreichbar):

```powershell
Invoke-WebRequest http://10.0.2.2:8080/setup-ad-dc.ps1 -OutFile C:\setup-ad-dc.ps1
```

ExecutionPolicy für diese Session setzen:
```powershell
      Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
```

Skript ausführen:

```powershell
.\setup-ad-dc.ps1 -Phase 1   # Neustart abwarten
.\setup-ad-dc.ps1 -Phase 2   # automatischer Neustart
.\setup-ad-dc.ps1 -Phase 3   # idempotent, kann wiederholt werden
```

Phase 3 konfiguriert:
- Enterprise Root CA (`SERI-Root-CA`)
- LDAPS Port 636
- RDP mit deaktiviertem NLA (`SecurityLayer=0`, `UserAuthentication=0`)
- Service Account `ldap-service@seri.sailpointdemo.com`
- DNS Forwarder 8.8.8.8 / 8.8.4.4

> **RDP-Hinweis:** `fDenyTSConnections=0` allein reicht nicht. Ohne explizite Deaktivierung von `SecurityLayer` und `UserAuthentication` bindet sich der RDP-Stack nicht an Port 3389 — `TermService` läuft dann zwar, aber Port 3389 ist nicht offen.

---

### Schritt 6: Windows Updates und Image erstellen

Per RDP verbinden auf `192.168.20.11:3389` (QEMU port-forward). Nach Updates:

```powershell
Stop-Computer -Force
```

Image komprimieren und auf Synology hochladen:

```bash
qemu-img convert -f qcow2 -O qcow2 -c -p \
  windows-fresh.qcow2 \
  windows-server-2025-ad-seri.x86.qcow2

sha256sum windows-server-2025-ad-seri.x86.qcow2 \
  > windows-server-2025-ad-seri.x86.qcow2.sha256

scp windows-server-2025-ad-seri.x86.qcow2 \
  achim@diskstation:/volume1/k8s-images/windows-server-2025-ad-seri.x86.qcow2
```

---

## KubeVirt Deployment

### 03-vm.yaml — kritische Einstellungen

```yaml
      domain:
        firmware:              # MUSS unter domain eingerückt sein!
          bootloader:
            efi:
              secureBoot: false
        devices:
          disks:
            - name: windows-disk
              disk:
                bus: scsi      # KubeVirt nutzt intern immer VirtIO SCSI
```

> **Wichtig:** Falsche YAML-Einrückung von `firmware` führt zu `Failed to unmarshal` in ArgoCD. Der Block muss unter `domain` stehen, nicht daneben.

> **Secure Boot:** Immer deaktivieren. KubeVirt unterstützt Secure Boot zwar, aber die NVRAM-Verwaltung ist komplex und fehleranfällig. UEFI ja, Secure Boot nein.

---

### Deployment-Ablauf

```bash
# VM stoppen und DataVolume löschen (CDI reimportiert nicht automatisch!)
kubectl patch vm windows-ad-dc -n windows-ad --type merge \
  -p '{"spec":{"running":false}}'
kubectl delete datavolume windows-ad-disk -n windows-ad

argocd app sync windows-ad --grpc-web
kubectl get datavolume -n windows-ad -w
# ImportScheduled → ImportInProgress → Succeeded (~10-15 Min)
```

### CA-Zertifikat als Secret aktualisieren

Nach jedem neuen Image muss das CA-Zertifikat aktualisiert werden:

```bash
kubectl create secret generic windows-ad-ca \
  --namespace windows-ad \
  --from-file=ca.crt=ca.cer \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Zugriff auf die VM

```bash
virtctl port-forward vm/windows-ad-dc -n windows-ad 3389:3389 &  # RDP
virtctl port-forward vm/windows-ad-dc -n windows-ad 636:636 &    # LDAPS
virtctl port-forward vm/windows-ad-dc -n windows-ad 389:389 &    # LDAP
```

> **MetalLB:** MetalLB L2-Mode ist mit KubeVirt `virt-launcher` Pods inkompatibel. Die statische IP `192.168.20.50` ist ein manueller Workaround: `sudo ip addr add 192.168.20.50/32 dev enp1s0.20` auf `gmkt-01x`.

---

## Checkliste für die nächste Installation

**Vorbereitung**
- [ ] Linux-Node mit KVM: `apt install qemu-system-x86 qemu-utils ovmf novnc websockify`
- [ ] Windows Server 2025 ISO und `virtio-win.iso` auf Node vorhanden
- [ ] `setup-ad-dc.ps1` auf HTTP-Server verfügbar

**Installation**
- [ ] `qemu-img create -f qcow2 windows-fresh.qcow2 80G`
- [ ] OVMF VARS kopieren: `cp /usr/share/OVMF/OVMF_VARS_4M.fd ./ovmf-vars.fd`
- [ ] QEMU mit `-device usb-tablet` starten (kein Mausversatz in noVNC)
- [ ] `websockify` starten, Browser auf `http://NODE-IP:6080/vnc.html`
- [ ] Windows installieren: Custom, VirtIO SCSI Treiber aus `vioscsi\2k25\amd64`
- [ ] Netzwerk-Treiber: `NetKVM\2k25\amd64` oder MSI
- [ ] Treiber nach `System32\drivers` kopieren (MSI reicht nicht!)
- [ ] QEMU Guest Agent installieren
- [ ] `setup-ad-dc.ps1` Phase 1, 2, 3
- [ ] RDP-Test: `Get-NetTCPConnection -LocalPort 3389` muss Ergebnis liefern
- [ ] Windows Updates
- [ ] `Stop-Computer -Force`, dann `qemu-img convert -c`

**KubeVirt**
- [ ] `03-vm.yaml`: `firmware.bootloader.efi.secureBoot: false` unter `domain:` eingerückt
- [ ] `03-vm.yaml`: `disk.bus: scsi`
- [ ] DataVolume löschen vor Re-Import
- [ ] CA-Zertifikat als Kubernetes Secret aktualisieren

---

## Konfigurationsreferenz

| Parameter | Wert |
|-----------|------|
| Domain | `seri.sailpointdemo.com` |
| NetBIOS | `SERI` |
| Hostname | `ad-resource` |
| CA Name | `SERI-Root-CA` |
| Service Account | `ldap-service@seri.sailpointdemo.com` |
| CA-Zertifikat | `C:\certs\ca.cer` |
| KubeVirt Namespace | `windows-ad` |
| LoadBalancer IP | `192.168.20.50` (statisch auf `gmkt-01x`) |
| Image URL | `http://diskstation:6666/windows-server-2025-ad-seri.x86.qcow2` |
| Image Größe | ~80GB raw / ~17GB komprimiert |

---

## Zeitaufwand Gesamt

| Versuch / Problem | Zeit | Vermeidbar? |
|-------------------|------|-------------|
| VMware Migration (NVMe-Problem) | ~4h | Ja |
| QEMU auf macOS (HVF-Instabilität) | ~4h | Ja |
| Recovery-Loop + Tastatur-Hölle | ~3h | Ja |
| vioscsi Boot-Treiber Debugging | ~2h | Ja |
| KVM Direktinstallation (funktioniert) | ~3h | Nein |
| **Gesamt** | **~16h** | |
