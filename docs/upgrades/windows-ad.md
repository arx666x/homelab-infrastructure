# Upgrade Runbook: Windows AD VM (windows-ad-dc)

> **Hinweis:** Dieses Runbook ist neu angelegt und bewusst ehrlich lückenhaft, wo Historie
> nicht rekonstruierbar ist. Es handelt sich um kein Helm-Chart-Deployment, sondern um eine
> KubeVirt-gehostete Windows-Server-VM als AD Domain Controller. Für das KubeVirt/CDI-Operator-
> Upgrade selbst siehe `docs/upgrades/kubevirt-cdi.md` — dort ist explizit dokumentiert, dass
> Operator-Upgrades von der windows-ad VM entkoppelt sind (`selfHeal: false`, `prune: false`).

## Metadaten
- **Namespace:** `windows-ad`
- **Aktuelle Version:** Basis-Image `windows-server-2025-ad-seri.x86.qcow2` (Windows Server 2025 Datacenter, Desktop Experience). In-Guest-Patchstand nicht in Git getrackt.
- **Quelle:** Kein Helm-Chart / keine GitHub-Releases-URL. DataVolume importiert das qcow2-Image per HTTP von der Synology NAS: `http://diskstation:6666/Windows-Server-2025-AD-SERI-X86/windows-server-2025-ad-seri.x86.qcow2` (siehe `gitops/config/windows-ad/02-datavolume.yaml`). Das Image selbst wird manuell außerhalb von Git gebaut (siehe `docs/windows-kubevirt-installation.md`).
- **ArgoCD App-Name:** `windows-ad` (Wave 30, Namespace `windows-ad`, Pfad `gitops/config/windows-ad`)
- **Versions-Check-Quelle:** Kein automatischer Check. Windows Updates werden manuell im Gast-OS eingespielt; die DataVolume-Basis-Image-Version ist in `gitops/config/windows-ad/02-datavolume.yaml` gepinnt (Dateiname/URL-Pfad auf der Synology NAS). Es gibt keinen automatisierten Zugriff auf den Windows-Update-Stand innerhalb der VM.
- **Major/Minor-Kriterium:** n/a – kein Helm-Chart. Windows Feature-Updates (z.B. Server 2022→2025) gelten als Major (manueller Eingriff, AD-Kompatibilität prüfen); kumulative Windows-Updates/Patches gelten als Minor (manuell im Gast eingespielt, kein automatisierter Checker-Zugriff auf das Gast-OS).

## Changelog

| Datum | Von → Nach | Typ | Ausführung | Status | Begründung | Notiz |
|---|---|---|---|---|---|---|
| unbekannt | ... | ... | ... | ... | Historie vor Einführung des strukturierten Runbooks nicht vollständig rekonstruierbar | — |

**Was aus `git log` rekonstruierbar ist (Infrastruktur-Änderungen an der VM-Definition, NICHT Windows-Update-Historie im Gast):**

| Datum | Änderung | Notiz |
|---|---|---|
| 2026-03-03 | Initiales Deployment: KubeVirt-/CDI-Operatoren und windows-ad DC hinzugefügt | Commit `861e380 feat: add kubevirt, cdi operators and windows-ad DC` |
| 2026-03-04 | DataVolume von 60Gi auf 80Gi vergrößert (Image war 62GiB) | Commit `3bd1be3` |
| 2026-03-04 | Disk-Bus von virtio auf scsi geändert (vioscsi-Treiber) | Commit `0e85773` |
| 2026-03-04 | MetalLB-Pool für windows-ad auf `192.168.20.50-192.168.20.120` erweitert | Commit `5ebba51` |
| 2026-03-06 | UEFI-Bootloader-Konfiguration für die VM ergänzt (zwei Commits, zweiter korrigiert Einrückung) | Commits `170dc45`, `3e27239` |
| 2026-03-07 – 2026-03-08 | Mehrfacher Disk-Bus-Wechsel während Fehlersuche: scsi → sata (temporär) → scsi (final) | Commits `93af5d4`, `340215b`, `5e8b483`, `f5dee46` — siehe Stolperfallen |
| 2026-03-19 | NetworkPolicy erweitert: RDP von Cluster-Node-IPs und Pod-Netzwerk erlauben (kube-proxy SNAT) | Commit `db72900` |
| 2026-03-19 | cert-manager Duration-Normalisierungs-Drift in ArgoCD `ignoreDifferences` aufgenommen | Commit `6c260d9` |
| 2026-03-20 | Secrets auf Sealed Secrets migriert | Commits `b9b76f7`, `0b2f99e` |
| 2026-03-24 | Image-URL-Pfad auf der Synology NAS geändert (Verzeichnisstruktur) | Commit `9d74fc0` |
| 2026-04-30 | Dynamischer NodePort-Drift des `windows-ad-lb` Service in ArgoCD `ignoreDifferences` aufgenommen | Commit `8536f20` |
| 2026-06-14 | LDAPS-SAN korrigiert auf `windows-ad.seri.svc.cluster.local` | Commit `740e4f8` |

Diese Tabelle ersetzt nicht den eigentlichen Changelog (dort ist bewusst nur `unbekannt` als Platzhalter für Windows-Versions-/Patch-Historie eingetragen), sondern dokumentiert die Infrastruktur-Timeline zur Einordnung.

### Reklassifizierungen (Minor → Major)

| Datum Erkennung | Ursprünglicher Changelog-Eintrag (Datum) | Grund der Reklassifizierung | Erneute Benachrichtigung gesendet am |
|---|---|---|---|

## Manuelle Vorgehensweise (bei Major/Breaking Change)

Es gibt zwei grundsätzlich verschiedene "Upgrade"-Szenarien für diese VM:

### Szenario A: Windows-Updates im laufenden Gast-OS einspielen (Minor)

Nicht in Git nachvollziehbar, da rein im Gast-OS. Ablauf gemäß bisheriger Praxis (siehe `docs/windows-kubevirt-installation.md`, Schritt 6):

1. Per RDP verbinden (siehe Zugriff unten).
2. Windows Update im Gast ausführen, neu starten falls nötig.
3. Nach Abschluss: Funktionstest — AD-Dienste, LDAPS (Port 636), DNS (Port 53), RDP (Port 3389) erreichbar.
4. **Kein automatischer Rollback möglich**, da Windows Updates nicht über GitOps laufen. Vor größeren Update-Batches empfiehlt sich ein Longhorn-Snapshot des `windows-ad-disk`-Volumes (siehe Rollback-Plan).

### Szenario B: Neues Basis-Image bauen (z.B. Feature-Update, Patch-Level-Refresh, Re-Provisioning) (Major)

Dies ist der einzige Weg, der aktuell dokumentiert und mehrfach durchgeführt wurde. Vollständige Prozedur aus `docs/windows-kubevirt-installation.md`:

**Voraussetzungen:**

| Komponente | Details |
|------------|---------|
| Linux-Node | GMKtec (192.168.20.11), Ubuntu, KVM-fähig |
| Pakete | `qemu-system-x86 qemu-utils ovmf novnc websockify` |
| OVMF VARS | `/usr/share/OVMF/OVMF_VARS_4M.fd` |
| Windows ISO | Windows Server 2025, lokal auf Node |
| VirtIO ISO | `virtio-win.iso`, lokal auf Node |
| Ziel-Image | 80GB qcow2 |

**Ablauf (Kurzfassung, Details siehe `docs/windows-kubevirt-installation.md`):**

1. Neues qcow2-Image anlegen und OVMF-Vars kopieren:
   ```bash
   qemu-img create -f qcow2 windows-fresh.qcow2 80G
   cp /usr/share/OVMF/OVMF_VARS_4M.fd ./ovmf-vars.fd
   ```
2. QEMU mit noVNC direkt auf dem Linux/KVM-Node starten (nicht auf macOS/HVF — siehe Stolperfallen), UEFI ohne Secure Boot, VirtIO-SCSI als Disk-Controller von Anfang an.
3. Windows Server 2025 Datacenter (Desktop Experience) installieren, Custom-Install, VirtIO-SCSI-Treiber aus `vioscsi\2k25\amd64` laden (nicht `w11\amd64`).
4. VirtIO-Netzwerktreiber und QEMU Guest Agent installieren; Treiber-Dateien manuell nach `C:\Windows\System32\drivers\` kopieren (MSI-Installation legt sie nur in `C:\Program Files\Virtio-Win\` ab, das reicht für den Boot-Treiber nicht).
5. `scripts/setup-ad-dc.ps1` auf die VM übertragen und in Phasen ausführen:
   ```powershell
   .\setup-ad-dc.ps1 -Phase 1   # Computername + Firewall, dann Neustart abwarten
   .\setup-ad-dc.ps1 -Phase 2   # AD DS Forest erstellen, automatischer Neustart
   .\setup-ad-dc.ps1 -Phase 3   # CA, LDAPS, RDP, Service Account — idempotent, wiederholbar
   ```
   Phase 3 konfiguriert: Enterprise Root CA (`SERI-Root-CA`), LDAPS Port 636 mit explizitem SAN-Zertifikat, RDP mit deaktiviertem NLA (`SecurityLayer=0`, `UserAuthentication=0`), Service Account `ldap-service@seri.sailpointdemo.com`, DNS-Forwarder 8.8.8.8/8.8.4.4, LDAP Signing + Channel Binding (`LDAPServerIntegrity=2`, `LdapEnforceChannelBinding=2`).
   Phase 4 (separat, nach Phase 3, sobald IQService installiert ist) registriert das LDAPS-Zertifikat für den SailPoint IQService-Dienst per Serial Number und setzt Startup-Abhängigkeit auf `NTDS`.
6. Windows Updates einspielen, dann `Stop-Computer -Force`.
7. Image komprimieren und auf Synology hochladen:
   ```bash
   qemu-img convert -f qcow2 -O qcow2 -c -p windows-fresh.qcow2 windows-server-2025-ad-seri.x86.qcow2
   sha256sum windows-server-2025-ad-seri.x86.qcow2 > windows-server-2025-ad-seri.x86.qcow2.sha256
   scp windows-server-2025-ad-seri.x86.qcow2 achim@diskstation:/volume1/k8s-images/windows-server-2025-ad-seri.x86.qcow2
   ```
8. In Kubernetes: VM stoppen, altes DataVolume löschen (CDI reimportiert nicht automatisch), dann ArgoCD-Sync auslösen:
   ```bash
   kubectl patch vm windows-ad-dc -n windows-ad --type merge -p '{"spec":{"running":false}}'
   kubectl delete datavolume windows-ad-disk -n windows-ad
   argocd app sync windows-ad --grpc-web
   kubectl get datavolume -n windows-ad -w
   # ImportScheduled -> ImportInProgress -> Succeeded (~10-15 Min)
   ```
9. CA-Zertifikat als Kubernetes Secret aktualisieren (nach jedem neuen Image nötig):
   ```bash
   kubectl create secret generic windows-ad-ca --namespace windows-ad \
     --from-file=ca.crt=ca.cer --dry-run=client -o yaml | kubectl apply -f -
   ```

### Zugriff auf die VM

```bash
virtctl port-forward vm/windows-ad-dc -n windows-ad 3389:3389 &  # RDP
virtctl port-forward vm/windows-ad-dc -n windows-ad 636:636 &    # LDAPS
virtctl port-forward vm/windows-ad-dc -n windows-ad 389:389 &    # LDAP
```

Alternativ per LoadBalancer-IP `192.168.20.50` (Service `windows-ad-lb`, statisch von MetalLB — siehe Stolperfallen zu MetalLB/virt-launcher-Inkompatibilität).

## Bekannte Stolperfallen / Lessons Learned

Aus `docs/windows-kubevirt-installation.md` (Ergebnis mehrerer gescheiterter Vorgehensweisen, ~16h Gesamtaufwand bis zur funktionierenden Methode):

- **VMware-Fusion-Migration scheitert:** VMware nutzt standardmäßig NVMe als Disk-Controller; KubeVirt/VirtIO hat keinen VirtIO-NVMe-Treiber, nur VirtIO-SCSI. Jeder Bus-Wechsel auf `sata`/`scsi`/`virtio` endete im BSOD `IRQL_NOT_LESS_OR_EQUAL`. Zusätzlich: VMware installiert mit UEFI, KubeVirt/QEMU startete initial mit BIOS (SeaBIOS kann UEFI-Partitionen nicht lesen).
- **QEMU auf macOS/HVF ungeeignet:** Zwei CD-ROMs (Windows-ISO + virtio-win-ISO) gleichzeitig als IDE-CD-ROMs crashen unter macOS HVF. HVF ist grundsätzlich instabil für Windows Server 2025 (Setup-Crash bei ca. 20%). Software-Emulation ohne HVF läuft bei ca. 5% Geschwindigkeit — unbrauchbar. **Direktinstallation muss auf echtem Linux/KVM erfolgen.**
- **`INACCESSIBLE_BOOT_DEVICE` bei falscher Treiber-Registrierung:** KubeVirt nutzt intern immer VirtIO-SCSI (`Scsi(0x0,0x0)` im Boot-Screen), unabhängig vom `bus`-Typ in der VM-YAML. Der vioscsi-Treiber muss von Anfang an als `BOOT_START` (`Start=0`) registriert sein — nachträgliches Setzen der Registry hilft nicht, wenn die Treiber-Dateien nur in `C:\Program Files\Virtio-Win\` liegen und nicht in `C:\Windows\System32\drivers\`.
- **Tastatur-Hölle im Windows-Recovery-Mode:** WinPE-basierte Recovery-Console ignoriert Windows-Spracheinstellungen, ist immer US-QWERTY intern — unabhängig vom VNC/Jump-Desktop-Client. Sonderzeichen (`/ { } [ ]`) sind über Mac-Tastatur + VNC/noVNC praktisch nicht eingebbar. Ein System im Recovery-Loop ist von einem Mac aus faktisch nicht mehr reparierbar.
- **Disk-Bus-Historie (Commits `93af5d4`, `340215b`, `5e8b483`, `f5dee46`, März 2026):** Mehrfacher Hin- und Her-Wechsel zwischen `sata` und `scsi` während der Fehlersuche zum Erstboot — am Ende hat sich `scsi` (mit vioscsi-Treiber von Anfang an geladen) als einzig funktionierender Weg bestätigt.
- **`firmware.bootloader.efi.secureBoot: false` Einrückung:** Muss unter `domain:` stehen, nicht daneben — falsche Einrückung führt zu `Failed to unmarshal` in ArgoCD. Secure Boot wird bewusst deaktiviert (UEFI ja, Secure Boot nein) — NVRAM-Verwaltung mit Secure Boot ist komplex und fehleranfällig.
- **RDP bindet trotz `fDenyTSConnections=0` nicht an Port 3389:** Ohne explizite Deaktivierung von `SecurityLayer` und `UserAuthentication` (NLA) läuft `TermService` zwar, aber der RDP-Stack öffnet Port 3389 nicht. Nach jedem VM-Neustart (z.B. nach `Succeeded`-Import) müssen diese Registry-Werte ggf. erneut über den QEMU Guest Agent gesetzt werden, bis Phase 3 des Setup-Skripts dauerhaft/persistent im Image verankert ist — siehe Diagnose/Fix-Befehle in `docs/kubevirt-prerequisites.md`:
  ```bash
  virtctl guestosinfo windows-ad-dc -n windows-ad
  kubectl exec -n windows-ad $(kubectl get pods -n windows-ad -o name) -c compute -- \
    virsh qemu-agent-command windows-ad_windows-ad-dc '{"execute":"guest-exec", ...}'
  ```
- **NetworkPolicy blockiert RDP durch kube-proxy SNAT:** Die VM nutzt `masquerade`-Netzwerkmodus. Traffic über den MetalLB-LoadBalancer (`192.168.20.50`) wird durch kube-proxy per SNAT umgeschrieben — Source-IP wird zur Node-IP (`192.168.20.x`), nicht zur Original-Client-IP. Eine NetworkPolicy die nur `192.168.11.0/24` erlaubt, wird dadurch umgangen. Fix: `192.168.20.0/24` (Node-IPs) und `10.42.0.0/16` (Pod-Netz) zusätzlich zu `192.168.11.0/24` in `gitops/config/windows-ad/05-networkpolicy.yaml` erlauben (bereits umgesetzt, siehe Commit `db72900`).
- **MetalLB L2-Mode inkompatibel mit KubeVirt virt-launcher-Pods:** Die statische IP `192.168.20.50` ist ein manueller Workaround (`sudo ip addr add 192.168.20.50/32 dev enp1s0.20` auf `gmkt-01x`), kein reiner MetalLB-L2-Announce.
- **DataVolume-Größe:** Ursprünglich 60Gi, musste auf 80Gi erhöht werden, da das komprimierte Image bereits 62GiB groß war (Commit `3bd1be3`).
- **CDI reimportiert nicht automatisch:** Ein neues Image erfordert explizites Löschen des alten DataVolume-Objekts (`kubectl delete datavolume windows-ad-disk -n windows-ad`) vor dem nächsten ArgoCD-Sync, sonst bleibt das alte Image aktiv.
- **LDAPS-Zertifikat mit expliziten SANs statt Auto-Enrollment:** AD CS stellt beim DC-Enrollment automatisch ein Kerberos-Zertifikat aus, dessen SANs nur den aktuellen FQDN enthalten. Java (SailPoint IQService) prüft bei LDAPS den Hostnamen gegen die SANs — schlägt fehl, wenn IQService den DC unter einem anderen Namen erreicht (z.B. `windows-ad.seri.svc.cluster.local` statt `ad-resource.seri.sailpointdemo.com`). `setup-ad-dc.ps1` Phase 3 stellt daher ein eigenes WebServer-Zertifikat mit allen bekannten SANs aus (externer FQDN, Wildcard, Cluster-Service-FQDN, Kurzname, Hostname).
- **hosts-Eintrag für Cluster-DNS-Namen nötig:** IQService läuft auf dem DC selbst und versucht `windows-ad.seri.svc.cluster.local` aufzulösen — dieser Name ist nur innerhalb des Kubernetes-Clusters bekannt. Phase 3 setzt einen `127.0.0.1`-hosts-Eintrag, da der DC sich selbst ist.
- **IIQ-Konfiguration muss bevorzugten DC explizit setzen:** Ohne expliziten `servers`-Eintrag in der IIQ-Active-Directory-Anwendungskonfiguration liefert IQService per `Get-ADDomainController` den Namen `ad-resource.seri.sailpointdemo.com` zurück — unbekannt/nicht auflösbar im Kubernetes-Cluster. Muss auf `windows-ad.seri.svc.cluster.local` gesetzt werden.

## Rollback-Plan

- **Kein Git-Revert für Windows-Update-Stand möglich** — Windows Updates laufen nicht über GitOps, es gibt keinen Commit, der zurückgerollt werden könnte.
- **Empfohlen vor größeren Änderungen am Gast-OS (Windows Updates, Feature-Updates):** Longhorn-Snapshot des `windows-ad-disk`-Volumes ziehen, bevor Updates eingespielt werden. Damit lässt sich der Datenträger-Stand zurückrollen, falls der Gast danach nicht mehr bootet oder AD-Dienste ausfallen. (Kein bestehendes Playbook hierfür in diesem Repo gefunden — Snapshot-Erstellung folgt dem allgemeinen Longhorn-Runbook, siehe `docs/upgrades/longhorn.md`.)
- **Rollback auf ein vorheriges Basis-Image:** Falls ein altes, funktionierendes qcow2-Image noch auf der Synology NAS vorhanden ist, kann die DataVolume-Quelle in `gitops/config/windows-ad/02-datavolume.yaml` auf den alten Dateinamen/Pfad zurückgesetzt werden, gefolgt vom gleichen Lösch-und-Reimport-Verfahren wie bei einem Image-Wechsel (`kubectl delete datavolume windows-ad-disk -n windows-ad` + ArgoCD-Sync). Voraussetzung: altes Image wurde vor dem Überschreiben nicht von der NAS gelöscht — dies ist nicht durch dieses Repo abgesichert (kein Backup-Automatismus für alte Images bekannt).
- **Bei fehlgeschlagenem Re-Provisioning (Szenario B):** VM auf `running: false` patchen, DataVolume-Import-Status prüfen (`kubectl get datavolume -n windows-ad -w`), ggf. kompletten Import wiederholen. Die VM selbst bleibt beim Fehlschlag im `Error`/Nicht-laufend-Zustand, ohne dass AD-Dienste in einem inkonsistenten Zwischenzustand nach außen sichtbar werden (LoadBalancer-Endpoints folgen dem Pod-Selector automatisch).

## Referenzen
- GitHub Releases: n/a (kein Chart-/Operator-Release-Zyklus für die VM selbst; Windows-Server-Lifecycle über Microsoft, nicht über dieses Repo getrackt)
- Interne Doku: `docs/windows-kubevirt-installation.md` — vollständige Anleitung zur Image-Erstellung (Direktinstallation auf Linux/KVM, gescheiterte Alternativansätze, Konfigurationsreferenz)
- Interne Doku: `docs/kubevirt-prerequisites.md` — Setup-Voraussetzungen für KubeVirt/CDI/windows-ad, Troubleshooting (RDP-Diagnose via QEMU Guest Agent, NetworkPolicy/SNAT-Problem, virtctl-Befehle)
- Skript: `scripts/setup-ad-dc.ps1` — Phase 1–4 In-Guest-Setup (Computername/Firewall, AD-Forest, CA/LDAPS/RDP/Service-Account, IQService-Zertifikatsregistrierung)
- Verwandtes Runbook: `docs/upgrades/kubevirt-cdi.md` — KubeVirt-/CDI-Operator-Upgrades, von dieser VM entkoppelt (`selfHeal: false`, `prune: false` auf der windows-ad ArgoCD-App)

**Offene Lücken in dieser Recherche (explizit, damit nichts stillschweigend erfunden wurde):**
- Kein Nachweis in Git für tatsächlich durchgeführte Windows-Update-Zyklen im laufenden Gast (nur Image-Neubau-Zyklen und Infrastruktur-Änderungen sind über Git-Commits nachvollziehbar — der eigentliche In-Guest-Patchstand ist nicht getrackt).
- Keine Aussage darüber, ob/wann das aktuell in `02-datavolume.yaml` referenzierte Image zuletzt neu gebaut wurde (Datei-Pfad-Änderung am 2026-03-24 betrifft nur die URL-Struktur auf der NAS, nicht zwingend ein neues Image).
