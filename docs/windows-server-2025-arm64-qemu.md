# Windows Server 2025 ARM64 unter QEMU auf Raspberry Pi 5

## Zielumgebung

Dieses Dokument beschreibt die Installation und Konfiguration von Windows Server 2025 ARM64 unter QEMU/KVM auf einem Raspberry Pi 5 (8 GB RAM, 1 TB SSD). Das erzeugte Image ist für den späteren Einsatz unter **KubeVirt auf einem Mac M4 Pro mit Colima** gedacht.

**Architektur: ARM64 (AArch64) — kein x86!**

---

## Voraussetzungen

### Hardware

- Raspberry Pi 5 mit 8 GB RAM
- 1 TB SSD (z.B. via NVMe HAT)
- Netzwerkverbindung

### Software auf dem Pi 5

```bash
sudo apt install -y qemu-system-aarch64 qemu-utils ovmf swtpm python3
```

### Benötigte Dateien

| Datei | Beschreibung |
|-------|-------------|
| `26100.xxxx...A64FRE_en-us.iso` | Windows 11 ARM64 ISO (Boot-Medium) |
| `26334.5000_SERVERSTANDARD_ARM64_EN-US.ISO` | Windows Server 2025 ARM64 ISO |
| `utm-guest-tools-latest.iso` | UTM Guest Tools (VirtIO-Treiber für ARM64) |
| `/usr/share/AAVMF/AAVMF_CODE.ms.fd` | UEFI Firmware mit Secure Boot (aus ovmf-Paket) |
| `/usr/share/AAVMF/AAVMF_VARS.ms.fd` | UEFI NVRAM Template |

UTM Guest Tools herunterladen:
```bash
wget https://getutm.app/downloads/utm-guest-tools-latest.iso
```

---

## Warum Windows 11 als Boot-Medium?

Windows Server 2025 ARM64 ist derzeit nur als Insider Preview verfügbar und bootet unter QEMU nicht direkt vom ISO in den Installer. Der Windows 11 ARM64 Installer hingegen funktioniert zuverlässig. Der Trick ist:

1. **Windows 11 ARM64 ISO booten** — liefert einen funktionierenden WinPE-Installer
2. **Windows Server 2025 ISO** als zweites Laufwerk einbinden
3. Windows Server manuell mit `dism` und `bcdboot` installieren

Dieser Ansatz ist in [diesem Medium-Artikel](https://medium.com/@alfredar08/install-windows-server-2025-and-sql-server-on-a-macbook-with-apple-silicon-m-series-using-utm-aa01e0047719) für UTM beschrieben und wurde für QEMU adaptiert.

---

## Bekannte Probleme und Lösungen

### Problem 1: virtio-net-pci erfordert Treiber

Windows ARM64 hat keinen eingebauten Treiber für `virtio-net-pci` (VEN_1AF4&DEV_1000). Das Gerät erscheint im Gerätemanager als "Ethernet Controller" ohne Treiber. **Ohne `-device virtio-net-pci,netdev=net0` hat Windows überhaupt keine Netzwerkkarte** — auch wenn `netcat` den Port als offen meldet (QEMU quittiert den TCP-Handshake selbst im `user`-Modus).

**Lösung:** UTM Guest Tools installieren, danach erkennt Windows den Treiber automatisch beim nächsten Boot.

### Problem 2: e1000 hat keinen ARM64-Treiber

Der Intel e1000 (`VEN_8086&DEV_100E`) ist ein x86-Treiber und funktioniert nicht unter Windows ARM64. Immer `virtio-net-pci` verwenden.

### Problem 3: TPM für Windows 11 Installer erforderlich

Der Windows 11 Installer verweigert die Installation ohne TPM 2.0. Lösung: `swtpm` als Software-TPM.

### Problem 4: IDE-CD nicht verfügbar auf ARM64

```
No IDE Bus found for device ide-cd
```

ARM64 QEMU hat keinen IDE-Bus. CD-ROM-Images müssen als `usb-storage` eingebunden werden.

### Problem 5: ACPI\LNRO0005 Geräte ohne Treiber

Im Gerätemanager erscheinen viele "Unknown Devices" mit `ACPI\LNRO0005`. Das sind ARM GIC Interrupt Controller Einträge — **normal** auf ARM64 QEMU, kein Handlungsbedarf.

### Problem 6: VNC Clipboard funktioniert nicht

QEMU's eingebauter VNC-Server unterstützt kein Clipboard-Sharing. Dateien in die VM übertragen über Python HTTP-Server auf dem Host:

```bash
# Auf dem Pi 5:
cd /verzeichnis/mit/dateien
python3 -m http.server 8080

# In Windows PowerShell:
Invoke-WebRequest -Uri "http://10.0.2.2:8080/datei.ps1" -OutFile "C:\datei.ps1"
```

`10.0.2.2` ist die QEMU Host-IP aus der VM (Standard QEMU user networking Gateway).

---

## Schritt 1: Vorbereitung

```bash
# Arbeitsverzeichnis
mkdir -p /mnt/longhorn/windows-build
cd /mnt/longhorn/windows-build

# Frisches Image erstellen (64 GB)
qemu-img create -f qcow2 ws2025-arm64-fresh.qcow2 64G

# UEFI NVRAM kopieren (Secure Boot Variante)
cp /usr/share/AAVMF/AAVMF_VARS.ms.fd ws2025-arm64-vars.fd

# TPM State-Verzeichnis erstellen
mkdir -p tpm-state
```

---

## Schritt 2: swtpm starten

**Wichtig:** swtpm muss **vor** QEMU gestartet werden. Er muss bei jedem Start neu gestartet werden (kein automatischer Dienst).

```bash
swtpm socket \
  --tpmstate dir=/mnt/longhorn/windows-build/tpm-state \
  --ctrl type=unixio,path=/mnt/longhorn/windows-build/tpm.sock \
  --tpm2 \
  --daemon

# Prüfen ob Socket vorhanden:
ls -la /mnt/longhorn/windows-build/tpm.sock
```

---

## Schritt 3: Windows Installation starten

QEMU mit beiden ISOs starten (Windows 11 als Boot-Medium, Windows Server als zweites Laufwerk):

```bash
qemu-system-aarch64 \
  -machine virt,accel=kvm \
  -cpu host \
  -smp 4 \
  -m 4096 \
  -drive "if=pflash,format=raw,unit=0,file=/usr/share/AAVMF/AAVMF_CODE.ms.fd,readonly=on" \
  -drive "if=pflash,format=raw,unit=1,file=/mnt/longhorn/windows-build/ws2025-arm64-vars.fd" \
  -chardev socket,id=chrtpm,path=/mnt/longhorn/windows-build/tpm.sock \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-tis-device,tpmdev=tpm0 \
  -device "nec-usb-xhci,id=usb-bus" \
  -device "usb-tablet,bus=usb-bus.0" \
  -device "usb-kbd,bus=usb-bus.0" \
  -device "usb-mouse,bus=usb-bus.0" \
  -device "nvme,drive=disk0,serial=WIN-DISK-001,bootindex=0" \
  -drive "if=none,media=disk,id=disk0,file=/mnt/longhorn/windows-build/ws2025-arm64-fresh.qcow2,discard=unmap,detect-zeroes=unmap" \
  -device "usb-storage,drive=cdrom0,bootindex=1" \
  -drive "if=none,media=cdrom,id=cdrom0,file=/mnt/longhorn/windows-build/WIN11-ARM64.iso,readonly=on" \
  -device "usb-storage,drive=cdrom1,bootindex=2" \
  -drive "if=none,media=cdrom,id=cdrom1,file=/mnt/longhorn/windows-build/26334.5000_SERVERSTANDARD_ARM64_EN-US.ISO,readonly=on" \
  -device "virtio-net-pci,netdev=net0" \
  -netdev "user,id=net0,hostfwd=tcp::3389-:3389,hostfwd=udp::3389-:3389,hostfwd=tcp::5985-:5985" \
  -device "ramfb" \
  -device "virtio-rng-pci" \
  -serial stdio \
  -monitor telnet:127.0.0.1:4444,server,nowait \
  -vnc :0
```

### Installations-Ablauf im Windows 11 Installer

1. Sprache wählen: **English (United States)**, Keyboard: **US** (wichtig für Sonderzeichen!)
2. "I don't have a product key" klicken
3. Edition wählen: **Windows 11 Pro**
4. Falls "This PC doesn't meet the requirements" erscheint: `Shift+F10` drücken, dann:

```cmd
reg add "HKLM\SYSTEM\Setup\MoSetup" /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 1 /f
```

5. Wenn der Installer läuft: `Shift+F10` für Command Prompt
6. Laufwerksbuchstaben ermitteln:

```cmd
diskpart
list volume
exit
```

7. Festplatte partitionieren:

```cmd
diskpart
list disk
select disk 0
clean
convert gpt
create partition efi size=512
format fs=fat32
assign letter=S
create partition msr size=16
create partition primary
shrink minimum=750
format quick fs=ntfs label="Windows"
assign letter=C
create partition primary
format quick fs=ntfs label="Recovery"
assign letter=R
set id="de94bba4-06d1-4d40-a16a-bfd50179d6ac"
gpt attributes=0x8000000000000001
list volume
exit
```

8. Windows Server Image ermitteln (Laufwerksbuchstabe des Server ISOs, z.B. E:):

```cmd
dism /Get-ImageInfo /ImageFile:E:\sources\install.wim
```

9. Windows Server installieren (Index 1 = Standard):

```cmd
dism /Apply-Image /ImageFile:E:\sources\install.wim /Index:1 /ApplyDir:C:\
```

10. Recovery Environment kopieren:

```cmd
mkdir R:\Recovery\WindowsRE
xcopy /h C:\Windows\System32\Recovery\Winre.wim R:\Recovery\WindowsRE
C:\Windows\System32\Reagentc /setreimage /path R:\Recovery\WindowsRE /target C:\Windows
```

11. Boot-Dateien erstellen:

```cmd
bcdboot C:\Windows /s S: /f ALL
exit
```

12. VM herunterfahren, **beide ISOs entfernen**, neu starten.

---

## Schritt 4: Normaler Start (ohne ISOs)

```bash
# swtpm zuerst starten
swtpm socket \
  --tpmstate dir=/mnt/longhorn/windows-build/tpm-state \
  --ctrl type=unixio,path=/mnt/longhorn/windows-build/tpm.sock \
  --tpm2 \
  --daemon

# QEMU starten
qemu-system-aarch64 \
  -machine virt,accel=kvm \
  -cpu host \
  -smp 4 \
  -m 4096 \
  -drive "if=pflash,format=raw,unit=0,file=/usr/share/AAVMF/AAVMF_CODE.ms.fd,readonly=on" \
  -drive "if=pflash,format=raw,unit=1,file=/mnt/longhorn/windows-build/ws2025-arm64-vars.fd" \
  -chardev socket,id=chrtpm,path=/mnt/longhorn/windows-build/tpm.sock \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-tis-device,tpmdev=tpm0 \
  -device "nec-usb-xhci,id=usb-bus" \
  -device "usb-tablet,bus=usb-bus.0" \
  -device "usb-kbd,bus=usb-bus.0" \
  -device "usb-mouse,bus=usb-bus.0" \
  -device "nvme,drive=disk0,serial=WIN-DISK-001,bootindex=0" \
  -drive "if=none,media=disk,id=disk0,file=/mnt/longhorn/windows-build/ws2025-arm64-fresh.qcow2,discard=unmap,detect-zeroes=unmap" \
  -device "virtio-net-pci,netdev=net0" \
  -netdev "user,id=net0,hostfwd=tcp::3389-:3389,hostfwd=udp::3389-:3389,hostfwd=tcp::5985-:5985" \
  -device "ramfb" \
  -device "virtio-rng-pci" \
  -serial stdio \
  -monitor telnet:127.0.0.1:4444,server,nowait \
  -vnc :0
```

VNC-Zugriff: `vnc://IP-des-Pi5:5900`

RDP-Zugriff (nach Treiber-Installation): `IP-des-Pi5:3389`

---

## Schritt 5: UTM Guest Tools installieren (VirtIO-Treiber)

Die UTM Guest Tools enthalten VirtIO-Treiber für ARM64 — notwendig für Netzwerk (`virtio-net-pci`) und später für KubeVirt.

QEMU mit zusätzlicher ISO starten:

```bash
-device "usb-storage,drive=cdrom0,bootindex=2" \
-drive "if=none,media=cdrom,id=cdrom0,file=/mnt/longhorn/windows-build/utm-guest-tools-latest.iso,readonly=on" \
```

In Windows: Installer aus der ISO ausführen. Nach der Installation und einem **Neustart** erkennt Windows den `virtio-net-pci` Netzwerktreiber automatisch — RDP funktioniert danach.

---

## Schritt 6: Windows Server 2025 aktivieren

```cmd
DISM /Online /Set-Edition:ServerStandard /ProductKey:8KNM6-XXBTY-V432K-37Y4G-XQFHM /AcceptEula
```

Anschließend Neustart erforderlich.

---

## Schritt 7: Backup erstellen

Nach erfolgreicher Installation und Aktivierung unbedingt ein Backup anlegen:

```bash
# QEMU stoppen
# Im QEMU Monitor:
# (qemu) quit

cp ws2025-arm64-fresh.qcow2 ws2025-arm64-clean-install.qcow2
cp ws2025-arm64-vars.fd ws2025-arm64-vars-clean.fd
cp -r tpm-state tpm-state-clean
```

---

## QEMU Monitor

Der QEMU Monitor ist über Telnet erreichbar:

```bash
telnet 127.0.0.1 4444
```

Nützliche Befehle:

| Befehl | Funktion |
|--------|----------|
| `quit` | QEMU beenden |
| `info block` | Block-Devices anzeigen |
| `info cpus` | CPU-Status |
| `sendkey 0x35` | `/` Taste senden (bei deutschem Keyboard-Layout) |
| `sendkey shift-0x1a` | `{` Taste senden |
| `sendkey shift-0x1b` | `}` Taste senden |

---

## Tastatur-Hinweise (Deutsches Layout in VNC)

Im VNC/Installer ist das Keyboard-Layout oft US trotz anderer Auswahl. Sonderzeichen auf US-Layout:

| Zeichen | Taste |
|---------|-------|
| `/` | Taste neben rechtem Shift, oder `sendkey 0x35` im QEMU Monitor |
| `{` | `sendkey shift-0x1a` |
| `}` | `sendkey shift-0x1b` |
| `=` | `sendkey shift-0x0d` |

**Empfehlung:** Während der Installation immer **US-Tastaturlayout** wählen. Deutsches Layout kann später in Windows umgestellt werden.

---

## Nächste Schritte: KubeVirt unter Colima

Das fertige Image wird für KubeVirt auf einem Mac M4 Pro unter Colima verwendet. Für KubeVirt gilt:

- **TPM:** KubeVirt unterstützt TPM nativ via `tpmDevice` in der VM-Spec — kein separates swtpm nötig
- **Storage:** KubeVirt verwendet `virtio-scsi` — Windows ARM64 hat dafür eingebaute Treiber
- **Netzwerk:** `virtio-net-pci` mit installiertem UTM Guest Tools Treiber ✅
- **Display:** KubeVirt nutzt VNC/SPICE — kein `ramfb` nötig

---

## Referenzen

- [UTM Guest Tools](https://docs.getutm.app/guest-support/windows/)
- [Medium-Artikel: Windows Server 2025 ARM auf Apple Silicon](https://medium.com/@alfredar08/install-windows-server-2025-and-sql-server-on-a-macbook-with-apple-silicon-m-series-using-utm-aa01e0047719)
- [AAVMF / OVMF Dokumentation](https://github.com/tianocore/tianocore.github.io/wiki/OVMF)
- [swtpm Projekt](https://github.com/stefanberger/swtpm)
