# Upgrade Runbook: k3s (Cluster)

## Metadaten
- **Namespace:** n/a (Cluster-weite Komponente)
- **Aktuelle Version:** v1.36.4+k3s1
- **Quelle:** GitHub Releases (k3s-io/k3s) — https://github.com/k3s-io/k3s/releases
- **ArgoCD App-Name:** — (nicht ArgoCD-verwaltet, Ansible-Playbooks: update-master-nodes.yml / update-pi-nodes.yml)
- **Versions-Check-Quelle:** Manuell gegen GitHub Releases geprüft (kein automatisierter Checker; Cluster ist nicht GitOps/ArgoCD-verwaltet)
- **Major/Minor-Kriterium:** Sonderregel — k3s-Versionen sehen wie SemVer-Minor-Bumps aus (vX.Y.Z+k3sN), unterliegen aber der Kubernetes-Upgrade-Policy "keine Minor-Version überspringen". Ein Sprung über mehr als einen Minor-Hop erzwingt sequenzielle Zwischenschritte (inkl. ggf. Pflicht-Zwischenversionen wie v1.32.11 für den etcd-3.5→3.6-Übergang). Solche Minor-Hops werden daher **immer als Major (manueller Eingriff)** behandelt, nicht als automatisierbarer Minor-Bump. Reine Patch-Releases innerhalb derselben Minor-Version (z.B. v1.36.1→v1.36.2) gelten als unkritisch, werden aber mangels automatisiertem Checker ebenfalls manuell ausgeführt.

## Changelog

| Datum | Von → Nach | Typ | Ausführung | Status | Begründung | Notiz |
|---|---|---|---|---|---|---|
| unbekannt | ... | ... | ... | ... | Historie vor Einführung des strukturierten Runbooks nicht vollständig rekonstruierbar | — |
| 2026-04-28 | v1.28.x → v1.32.3 | Major | Manuell | Abgeschlossen | 4 Minor-Hops in Folge; zusätzlich Traefik-Swap v2→v3 als Breaking Change | Details zu diesem Sprung nicht mehr im Repo dokumentiert (vor Runbook-Datei) |
| 2026-05-04 | v1.32.3 → v1.35.4 | Major | Manuell | Abgeschlossen | 4 Runden (v1.32.3→v1.32.11→v1.33.11→v1.34.7→v1.35.4); Pflicht-Zwischenschritt v1.32.11 wegen etcd 3.5→3.6-Migration (benötigt etcd v3.5.26 vor Sprung auf v1.34+) | Doku ursprünglich in `k3s-upgrade-1.32-to-1.35.md` (388 Zeilen), später in Runbook zusammengeführt |
| 2026-05-17/18 | v1.35.4 → v1.36.0 | Major | Manuell | Abgeschlossen | 1 Minor-Hop; zusätzlich RPi-Kernel 6.18 hat `ip_tables`-Modul entfernt → nftables-Umstellung in update-pi-nodes.yml erforderlich | Playbook `update-pi-nodes.yml` im selben Zug gefixt |
| 2026-05-18 | v1.36.0 → v1.36.1 | Minor | Manuell | Abgeschlossen | Patch-Release, nur Bugfixes, kein Sonderfall | — |
| 2026-05-29 | v1.36.1 → v1.36.2 | Minor | Manuell | Abgeschlossen | Patch-Release, nur Bugfixes, kein Sonderfall; nftables-Fix aus v1.36.0-Upgrade weiterhin wirksam (RPis liefen bereits auf Kernel 6.18.34) | Dokumentiert in Commit "docs: k3s v1.36.2 upgrade dokumentiert" (2026-06-29) |
| 2026-08-10 | v1.36.2 → v1.36.3 | Minor | Manuell (Ansible) | Abgeschlossen | Patch-Release, nur Bugfixes, kein Sonderfall; zusätzlich OS-Paket-Update auf allen 9 Nodes | Alle 3 Master + alle 6 Worker aktualisiert. Vier separate Longhorn-Eviction-Timeouts (30 min, `longhorn_wait_timeout`) beim Rebuild des 50 GB `pvc-73e5e5c2` (kube-prometheus-stack-Prometheus-Volume) auf gmkt-01x, gmkt-03x, k3s-01a und k3s-06a — jedes Mal lief der Rebuild tatsächlich weiter/schloss kurz nach dem Ansible-Timeout ab (dreimal reines Timing, einmal auf gmkt-01x echter Stall durch `unexpected EOF` beim Datei-Sync, behoben durch Löschen des hängenden WO-Replicas und Neustart des Rebuilds). Betroffene Node-Läufe danach jeweils mit `--limit <node>` erneut angestoßen, kein Datenverlust, Volume blieb durchgehend `healthy`. **Empfehlung:** `longhorn_wait_timeout` in `update-master-nodes.yml`/`update-pi-nodes.yml` für Volumes >20GB auf 3600s erhöhen, siehe Stolperfalle unten. Nebenbefund (nicht durch k3s-Upgrade verursacht, aber durch Node-Drain ausgelöst): `gitea-actions-runner-0` verlor durch Reschedule während master01-Drain seine Registrierung (`invalid character '/' looking for beginning of value`), behoben durch StatefulSet scale 0→1 (nach Pause von ArgoCD-selfHeal); dadurch blockierter ChromeIQ-CI-Backlog löste sich danach selbst auf |
| 2026-09-12/13 | v1.36.4 (unverändert) | OS-Paket-Update, kein k3s-Bump | Manuell (Ansible) | Abgeschlossen | Größere Anzahl ausstehender OS-Pakete auf allen Nodes; k3s_version=v1.36.4+k3s1 (=Ist-Stand) an update-master-nodes.yml übergeben, damit nur OS-Update+Reboot läuft, kein Binary-Swap. Reihenfolge: DNS (dns01/dns02) → Master → Worker | DNS-Nodes über `update-dns-nodes.yml` (neueres, kanonisches Playbook für den aktuellen Zwei-Resolver-Aufbau ohne Keepalived/VIP; `update-dns.yml` ist die veraltete Vorgängerversion für den alten Single-Node-VIP-Aufbau). Master01 traf erneut den bekannten Longhorn-Eviction-Timeout beim `pvc-73e5e5c2`-Rebuild (reines Timing, s.o.) — daraufhin **`full_eviction`-Fix eingeführt** (siehe Stolperfalle unten): Master02+03 liefen danach in ~20 Min. statt vorher 30+ Min. **pro Node** durch, Longhorn blieb durchgehend `healthy`. Worker liefen mit `serial: 2` (seit 2026-08-21) komplett fehlerfrei durch (0× `FAILED - RETRYING`). **k3s-06a-Incident** (unabhängig vom Update, ~9h nach Abschluss des Worker-Laufs): Node hing hart (SSH-Handshake sofort vom Remote-Host gekappt, `containerd` down, Ping ging weiterhin) — Root Cause und Watchdog-Befund siehe eigene Stolperfalle unten. Nebenbei erledigt: verwaiste `homeassistant-config`-PVC (HA lief seit 2026-09-01 stabil auf der Diskstation, Cluster-Deployment `replicas: 0`) inkl. blockierendem `ha-export`-Leftover-Pod entfernt |

### Reklassifizierungen (Minor → Major)

| Datum Erkennung | Ursprünglicher Changelog-Eintrag (Datum) | Grund der Reklassifizierung | Erneute Benachrichtigung gesendet am |
|---|---|---|---|

## Manuelle Vorgehensweise (bei Major/Breaking Change)

> Cluster: homelab (Master gmkt-01x/02x/03x + Worker k3s-01a..06a). Gilt für jeden
> Minor-Hop; bei Mehrfach-Hops (z.B. über mehrere Minor-Versionen) jede Runde einzeln
> durchlaufen.

### Allgemeine Regeln (immer einhalten)

1. **Master zuerst** — alle Master upgraden bevor Workers dran kommen
2. **Master einzeln (`serial: 1`)** — etcd-Quorum benötigt 2 von 3 Master zu jeder Zeit
3. **Workers zu zweit (`serial: 2`, seit 2026-08-10)** — keine etcd-Quorum-Bindung wie bei
   Mastern; Longhorn rebuilt ohnehin nur ein Replica pro Volume gleichzeitig, ein
   zufälliges Zusammentreffen zweier gleichzeitig evakuierter Nodes mit Replicas
   desselben Volumes serialisiert sich dadurch automatisch wieder
4. **Cluster-Verify nach den Masters** — nie zu den Workers ohne Gesundheitscheck
5. **Nur stable Releases** — keine RC/Pre-release Versionen
6. **Keine Minor-Version überspringen** — jeder Minor-Hop ist eine eigene Runde (Master → Verify → Worker → Verify), auch wenn das Ziel mehrere Minors entfernt liegt

### Vorbereitung (vor jedem Upgrade)

- [ ] **Longhorn-Status prüfen** — alle Volumes Healthy, kein `AllowScheduling=false`
  ```bash
  kubectl -n longhorn-system get nodes.longhorn.io
  kubectl -n longhorn-system get volumes | grep -v Healthy
  ```
- [ ] **Alle Pods laufend**
  ```bash
  kubectl get pods -A | grep -Ev 'Running|Completed|Succeeded'
  ```
- [ ] **ArgoCD — alle Apps Synced/Healthy** (k3s selbst ist nicht ArgoCD-verwaltet, aber Workloads im Cluster sind betroffen)
  ```bash
  kubectl -n argocd get applications
  ```
- [ ] **etcd-Baseline-Snapshot** (auf gmkt-01x)
  ```bash
  sudo k3s etcd-snapshot save --name pre-upgrade-$(date +%Y%m%d)
  sudo k3s etcd-snapshot ls
  ```
- [ ] **Longhorn SystemBackup**
  ```bash
  kubectl apply -f - <<EOF
  apiVersion: longhorn.io/v1beta2
  kind: SystemBackup
  metadata:
    name: pre-upgrade-$(date +%Y%m%d)
    namespace: longhorn-system
  spec:
    volumeBackupPolicy: if-not-present
  EOF
  kubectl -n longhorn-system get systembackup -w
  ```
- [ ] **Zielversion bestätigen:** https://github.com/k3s-io/k3s/releases (nur stable, keine RC)
- [ ] **Prüfen ob ein Pflicht-Zwischenschritt nötig ist** (z.B. etcd-Kompatibilität, Kubernetes-Deprecations) — siehe Release Notes der übersprungenen Minor-Versionen

### Standard-Ablauf pro Minor-Hop (gilt ab v1.34+, kein etcd-Sonderfall mehr)

**Master-Nodes**

- [ ] etcd-Snapshot vor dem Upgrade (auf gmkt-01x)
  ```bash
  sudo k3s etcd-snapshot save --name pre-upgrade-masters-$(date +%Y%m%d)
  ```
- [ ] Alle Master upgraden
  ```bash
  ansible-playbook playbooks/update-master-nodes.yml -e k3s_version=<VERSION>+k3s1
  ```
  Playbook-Ablauf pro Node: Cluster-Health/etcd-Quorum-Precheck → etcd-Snapshot
  (einmalig, nur master01) → `kubectl drain` → `apt upgrade` → k3s-Binary direkt von
  GitHub laden (Unit-File wird gesichert und danach wiederhergestellt, NICHT das
  Install-Script verwenden — das würde `--disable traefik`, `--flannel-iface`,
  `--node-ip` etc. aus der Unit-File verlieren) → Reboot → warten bis Node Ready und
  etcd wieder im Quorum → `kubectl uncordon`.
- [ ] Alle Master Ready? Pods OK? Longhorn Healthy?
  ```bash
  kubectl get nodes -o wide
  kubectl get pods -A | grep -Ev 'Running|Completed|Succeeded'
  kubectl -n longhorn-system get volumes | grep -v Healthy
  ```

**Worker-Nodes**

- [ ] Erst worker01 testen
  ```bash
  ansible-playbook playbooks/update-pi-nodes.yml -e k3s_version=<VERSION>+k3s1 --limit worker01
  ```
  Playbook-Ablauf pro Node: Longhorn-Scheduling deaktivieren (seit 2026-09-12 ohne
  volle Replica-Migration, siehe `full_eviction`-Stolperfalle unten) → `kubectl drain`
  → warten bis Volumes sauber detached → `apt upgrade` → optional EEPROM-Update →
  k3s-Agent-Binary-Update (Unit-File-Backup/Restore analog Master) → nftables-Fix
  einspielen → Reboot → warten bis Ready → `kubectl uncordon` → Longhorn-Scheduling
  reaktivieren → warten bis Replicas resynced sind (nur Delta, kein Full-Rebuild
  mehr im Normalfall).
- [ ] worker01 Ready? Longhorn Healthy?
  ```bash
  kubectl get node k3s-01a
  kubectl -n longhorn-system get volumes | grep -v Healthy
  ```
- [ ] Alle Workers upgraden
  ```bash
  ansible-playbook playbooks/update-pi-nodes.yml -e k3s_version=<VERSION>+k3s1
  ```

### Sonderfall: etcd-Pflichtschritt v1.32 → v1.34 (abgeschlossen, nur zur Referenz)

k3s v1.34+ enthält etcd v3.6. Der Upgrade-Pfad von etcd 3.5→3.6 erfordert zwingend
etcd v3.5.26 als Zwischenschritt — d.h. vor einem Sprung auf v1.33+ musste erst auf
**v1.32.11** (enthält etcd v3.5.26) upgegradet werden. Für alle zukünftigen Upgrades
ab v1.34+ nicht mehr relevant (etcd bleibt 3.6).

Historischer Upgrade-Pfad v1.32.3 → v1.35.4 (4 Runden, je Standard-Ablauf
Master → Verify → Worker → Verify):

| Runde | Von | Nach | Grund |
|---|---|---|---|
| 0 | v1.32.3 | v1.32.11 | Pflicht — etcd v3.5.26 vor v1.34+ |
| 1 | v1.32.11 | v1.33.11 | Minor-Hop +1 |
| 2 | v1.33.11 | v1.34.7 | Minor-Hop +1, etcd 3.5 → 3.6 |
| 3 | v1.34.7 | v1.35.4 | Minor-Hop +1, Zielversion |

### Finaler Abschlusscheck

- [ ] Alle Nodes auf Zielversion, alle Ready
  ```bash
  kubectl get nodes -o wide
  ```
- [ ] Keine degraded Pods
  ```bash
  kubectl get pods -A | grep -Ev 'Running|Completed|Succeeded'
  ```
- [ ] Longhorn alle Volumes Healthy, alle Nodes Schedulable
  ```bash
  kubectl -n longhorn-system get volumes | grep -v Healthy
  kubectl -n longhorn-system get nodes.longhorn.io
  ```
- [ ] ArgoCD alle Apps Synced/Healthy
  ```bash
  kubectl -n argocd get applications
  ```
- [ ] Traefik IngressRoutes erreichbar
  ```bash
  curl -sk https://gitea.reckeweg.io | head -5
  curl -sk https://grafana.reckeweg.io | head -5
  ```
- [ ] Abschluss-etcd-Snapshot
  ```bash
  sudo k3s etcd-snapshot save --name post-upgrade-$(date +%Y%m%d)
  sudo k3s etcd-snapshot ls
  ```

## Bekannte Stolperfallen / Lessons Learned

- **RPi-Kernel 6.18+: `ip_tables`-Modul entfernt** (entdeckt 2026-05-17) — Der
  Raspberry-Pi-Kernel 6.18.x (rpt-rpi-2712) enthält kein `ip_tables`-Kernelmodul
  mehr. Flannel und kube-proxy brauchen aber iptables — ohne Fix stürzt `k3s-agent`
  beim Start ab. Gelöst im Playbook `update-pi-nodes.yml`: `apt install iptables`
  stellt das Paket sicher, `update-alternatives` schaltet `/usr/sbin/iptables` auf
  `iptables-nft` um, und `--kube-proxy-arg=proxy-mode=nftables` wird in die
  k3s-agent-Unit-File eingetragen. Bestätigt weiterhin wirksam beim Upgrade
  v1.36.1→v1.36.2 (2026-05-29, Kernel bereits 6.18.34, Fix griff ohne Nacharbeit).
  Manuelle Notfallbehebung falls das Playbook mid-run abbricht:
  ```bash
  sudo apt install -y iptables
  sudo update-alternatives --set iptables /usr/sbin/iptables-nft
  sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-nft
  sudo sed -i "s|'--flannel-iface=eth0.XX' \\\\|'--flannel-iface=eth0.XX' \\\\\n    '--kube-proxy-arg=proxy-mode=nftables' \\\\|" \
    /etc/systemd/system/k3s-agent.service
  sudo systemctl daemon-reload && sudo systemctl start k3s-agent
  # Danach vom Master:
  kubectl uncordon <node-name>
  ```
- **Longhorn Eviction-Timeout bei großen Volumes** — Bei Volumes > 20 GB kann die
  Longhorn-Eviction (Replica-Migration vor dem Drain) länger als 10 Minuten dauern.
  Das Playbook ist auf 30 Minuten konfiguriert. Falls das Playbook mid-run abbricht
  und Longhorn-Scheduling deaktiviert bleibt:
  ```bash
  kubectl -n longhorn-system get nodes.longhorn.io
  # AllowScheduling=false → manuell re-enablen:
  kubectl -n longhorn-system patch node.longhorn.io/<node-name> \
    --type=merge \
    -p '{"spec":{"allowScheduling":true,"disks":{"<disk-id>":{"allowScheduling":true,"evictionRequested":false}}}}'
  ```
  Disk-ID findet man in der Ansible-Ausgabe (`[ LONGHORN ] Disk-ID anzeigen`) oder via:
  ```bash
  kubectl -n longhorn-system get node.longhorn.io/<node-name> \
    -o jsonpath='{.spec.disks}' | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(list(d.keys())[0])"
  ```
  **Update 2026-08-10:** Beim v1.36.3-Upgrade trat dieser Timeout viermal auf (gmkt-01x,
  gmkt-03x, k3s-01a, k3s-06a) — jedes Mal wegen des 50 GB `pvc-73e5e5c2`-Volumes
  (kube-prometheus-stack-Prometheus). Zwei Fehlerbilder, unterscheidbar über
  `kubectl -n longhorn-system get engines.longhorn.io -l longhornvolume=<vol> -o jsonpath='{.items[0].status.rebuildStatus}'`:
  - **Reines Timing** (3×): `progress` steigt kontinuierlich, liegt beim Timeout nur
    knapp unter 100 % → einfach ein bis zwei Minuten abwarten, Eviction schließt von
    selbst ab, danach Playbook mit `--limit <node>` erneut anstoßen.
  - **Echter Stall** (1×, gmkt-01x): `progress` bleibt über mehrere Minuten exakt
    gleich, `appliedRebuildingMBps: 0`. Ursache im Instance-Manager-Log des
    Zielnodes (`kubectl -n longhorn-system logs instance-manager-<id>`): Dateitransfer
    brach mit `unexpected EOF` ab, der Ssync-Server terminierte danach nach 5 Minuten
    Idle — kein automatischer Retry. Fix: das hängende (noch nicht synchronisierte,
    Mode `WO`) Replica identifizieren und löschen —
    `kubectl -n longhorn-system delete replica <name>` — Longhorn startet den Rebuild
    automatisch neu. Die 2 verbleibenden gesunden Replicas halten das Volume während
    der gesamten Prozedur `healthy` (nicht `degraded`), kein Datenrisiko.
  **Update 2026-09-12, endgültig behoben (`full_eviction`-Fix):** Statt den Timeout
  nur zu erhöhen, wurde die Ursache selbst entschärft — beide Playbooks haben jetzt
  eine neue Variable `full_eviction` (Default `false`). Bei `false` (normaler
  Reboot) wird nur `allowScheduling:false` gesetzt, **kein** `evictionRequested:true`
  mehr — das Replica bleibt auf dem Node liegen statt komplett auf einen anderen
  Node migriert zu werden, und der "Warten bis alle Replicas evakuiert sind"-Schritt
  entfällt komplett. Beim Wiederkommen synct Longhorn nur das Delta seit dem
  kurzen Offline-Fenster, kein Full-Rebuild mehr nötig. `kubectl drain` +
  "Warten bis keine Volumes mehr attached sind" bleiben unverändert als
  Sicherheitsnetz gegen unclean Shutdowns (siehe Incident 2026-08-03 oben) — nur
  die zusätzliche Longhorn-Replica-Migration, die dafür nie nötig war, fällt weg.
  `full_eviction=true` bleibt für den seltenen Fall einer **dauerhaften**
  Node-Entfernung verfügbar (`-e full_eviction=true`), dort ist die volle Migration
  weiterhin richtig. Praxistest 2026-09-12: master02+master03 liefen mit dem Fix in
  ~20 Min. **zusammen** durch (vorher 30+ Min. **pro Node** allein für die
  Eviction-Wartezeit), Longhorn blieb durchgehend `healthy` — kein Kompromiss bei
  der Datensicherheit, siehe auch Incident 2026-08-03 (dort war fehlendes `drain`
  die Ursache der Korruption, nicht fehlende Longhorn-Migration).
- **k3s-06a Hard-Hang trotz aktivem SSH-Watchdog (2026-09-13)** — ~9h nach einem
  regulären, erfolgreichen OS-Update-Lauf fiel k3s-06a in einen Hard-Hang:
  `containerd` down, SSH-Handshake wird sofort vom Remote-Host gekappt
  (`kex_exchange_identification: Connection closed by remote host` — nicht Timeout,
  der TCP-Handshake klappt, sshd kommt aber nicht mehr zum Session-Aufbau), Ping
  funktioniert weiterhin (Kernel-Netzwerkstack lebt, Userspace nicht). Node-Condition:
  `Ready=False, Reason: KubeletNotReady, Message: container runtime is down`.
  Deckt sich mit dem iSCSI-Hang-Incident vom Juli (docs/upgrades — siehe
  `ssh-watchdog.yml`).

  **Watchdog-Befund (via `journalctl -u ssh-watchdog.service`):** Der SSH-Watchdog
  (`ssh-watchdog.timer`, alle 120s, Reboot nach 3 Fehlschlägen) lief bis kurz vor
  dem Hang sauber durch — und dann **komplett gar nicht mehr**, über eine Stunde
  lang keine einzige Log-Zeile, bis der Nutzer den Pi manuell power-gecycelt hat.
  `journalctl -k` zeigt für den ganzen Tag nur **ein** `Booting Linux`-Ereignis
  (Zeitstempel vor NTP-Sync unzuverlässig auf Raspberry Pi ohne Hardware-RTC,
  daher nicht wörtlich zu nehmen) — der Hang war so tief, dass systemd selbst
  keinen neuen Prozess mehr forken konnte, nicht mal das simple
  Watchdog-Check-Skript. Ein Software-Watchdog, der selbst `fork()`/`exec()`
  braucht, kann diese Klasse von Hang strukturell nicht erkennen.

  **Hardware-Watchdog lief durch, hat aber trotzdem nicht ausgelöst — Korrektur
  einer ersten Fehleinschätzung:** `journalctl --list-boots` zeigt für die
  komplette Hang-Phase **keinen einzigen Zwischen-Boot** — der Hardware-Watchdog
  (`bcm2835-wdt`, per Kernel-Log bestätigt mit 1 Minute Hardware-Timeout aktiv,
  `RuntimeWatchdogSec=15` in `/etc/systemd/system.conf`) hat nie ausgelöst, obwohl
  der Node über eine Stunde tot war. **Das liegt NICHT an einem fehlenden/nicht
  scharf gestellten `RebootWatchdogSec`** (das wurde zunächst vermutet und cluster-
  weit auf 5min gesetzt — schadet nicht, behebt aber nicht dieses Problem, da
  `RebootWatchdogSec` nur einen bereits laufenden Reboot-*Vorgang* vor dem
  Hängenbleiben schützt, hier aber nie ein Reboot ausgelöst wurde). Die tatsächliche
  Erklärung stand bereits im Incident vom 2026-07-28: systemds
  Watchdog-Fütterungs-Schleife in PID1 ist ein interner Timer-Callback **ohne**
  Festplatten-I/O — sie läuft weiter, auch wenn ein D-State-Storage-Pile-up (hängender
  iSCSI-/Longhorn-Mount) alles blockiert, was forken oder auf Storage zugreifen muss
  (SSH-Sessions, containerd, auch das SSH-Watchdog-Skript selbst). Ein
  "Lebt-PID1-noch"-Watchdog ist für diese Hang-Klasse strukturell blind.
  `watchdog.service` ist korrekt deaktiviert (bewusst, wegen Konflikt mit
  `RuntimeWatchdogSec` — siehe `ssh-watchdog.yml` Kommentarkopf).

  **Update 2026-09-13, echter Fix umgesetzt (`io-watchdog.yml`):** Ein neuer
  Daemon (`ansible/files/io-watchdog.py`) übernimmt `/dev/watchdog` komplett von
  systemd. Ein einmalig beim Start erzeugter Hintergrund-Thread macht alle 5s
  einen echten Disk-I/O-Roundtrip (Datei schreiben+fsync+lesen+verifizieren) auf
  der lokalen NVMe-Partition; der Haupt-Thread füttert den Hardware-Watchdog nur,
  wenn dieser I/O-Heartbeat jünger als 30s ist (Pythons GIL wird bei blockierenden
  Syscalls freigegeben, der Haupt-Thread läuft also weiter, auch wenn der
  I/O-Thread in D-State hängt). Entscheidend: der I/O-Thread wird **einmalig**
  erzeugt, nicht wie beim SSH-Watchdog-Skript bei jedem Check neu geforkt — ein
  D-State-Hang blockiert also nur diesen einen bereits laufenden Thread, es muss
  während des Hangs nichts Neues gestartet werden, damit die Fütterung aufhört
  und der Hardware-Timeout greift.

  **Stolperfalle beim Rollout — Vendor-Drop-in überschreibt System.conf:**
  Raspberry Pi OS liefert `/usr/lib/systemd/system.conf.d/40-rpi-enable-
  watchdog.conf` (`RuntimeWatchdogSec=1m`, `RebootWatchdogSec=2m`) mit aus. Da
  Drop-ins in `conf.d/`-Verzeichnissen **nach** der Haupt-`system.conf` geladen
  werden und gewinnen, wurde sowohl der ursprüngliche `RebootWatchdogSec`-Fix
  (s.o.) als auch der erste `RuntimeWatchdogSec=off`-Versuch für `io-watchdog.yml`
  von diesem Vendor-Drop-in **kommentarlos überschrieben** — `systemctl show -p
  RuntimeWatchdogUSec` zeigte weiterhin `1min`, `/dev/watchdog` blieb für
  `io-watchdog.service` mit `Errno 16 Device or resource busy` unerreichbar.
  Fix: eigenes Drop-in `/etc/systemd/system.conf.d/50-io-watchdog-override.conf`
  (Dateiname sortiert nach `40-`, gewinnt also) statt direktem Edit von
  `/etc/systemd/system.conf`.

  **Reboot-Verhalten uneinheitlich:** Auf k3s-06a (frisch gehangen + manuell
  power-gecycelt + einmal per Ansible neu gestartet) musste der Node nach dem
  Deploy des Drop-ins **noch einmal** neu gestartet werden, bevor `io-watchdog`
  `/dev/watchdog` öffnen konnte — ein `daemon-reexec` reicht nicht, PID1 hält ein
  bereits geöffnetes Watchdog-Fd über den Reexec hinweg (vermutlich bewusst, wegen
  `nowayout`). Auf den anderen 5 Workern (letzter reine Reboot vom selben Morgen,
  vor Deploy des Drop-ins) hat derselbe Ansible-Lauf dagegen **ohne** weiteren
  Reboot sofort funktioniert — Ursache nicht abschließend geklärt, evtl. Timing
  zwischen den beiden `ssh-watchdog.yml`/`io-watchdog.yml`-Läufen desselben
  Vormittags. Praktische Konsequenz: `io-watchdog.yml` einfach laufen lassen und
  das Playbook selbst (`Check service is active`) melden lassen, ob ein Node
  einen zusätzlichen Reboot braucht, statt das vorab anzunehmen.

  Verifiziert 2026-09-13: alle 6 Worker `io-watchdog.service active`, 0 Restarts,
  `RuntimeWatchdogUSec=0` (systemd-eigenes Petting bestätigt deaktiviert), unser
  Daemon-Prozess hält laut `/proc/<pid>/fd`-Scan exklusiv das Watchdog-Fd. Bewusst
  **nicht** per echtem Hang getestet — nur Normalbetrieb über mehrere Minuten
  beobachtet (stabil, keine Stale-I/O-Warnungen).

  Nicht umgesetzt/außerhalb des Scopes: Master (GMKTec) laufen weiterhin nur mit
  dem einfachen `RebootWatchdogSec`-Grundhygiene-Fix aus `ssh-watchdog.yml`, kein
  `io-watchdog`-Rollout dort — das Problem ist Pi/NVMe-spezifisch, und
  `RuntimeWatchdogUSec` zeigte auf den Mastern zuletzt ohnehin `0`
  (kein aktiver Hardware-Watchdog bekannt/bestätigt).

  **Recovery war folgenlos:** Nach dem manuellen Power-Cycle wurde der Node
  automatisch wieder Ready, die 2 dadurch `degraded` gewordenen Longhorn-Volumes
  (`pvc-8131dc95`, `pvc-fc6489fd` — je ein Replica auf k3s-06a) haben sich
  innerhalb von ~2 Minuten selbstständig wieder auf `healthy` resynced, kein
  manueller Eingriff nötig, kein Datenverlust.
- **Install-Script überschreibt Unit-File-Flags** — Das offizielle k3s-Install-Script
  (`get.k3s.io`) überschreibt die systemd-Unit-File und würde dabei alle Flags
  verlieren (`--disable traefik`, `--flannel-iface`, `--node-ip`, `--cluster-init`
  usw.). Deshalb laden beide Playbooks das Binary direkt von GitHub und
  sichern/restaurieren die Unit-File separat, statt das Install-Script zu nutzen.
- **k3s-Versionsstring in URLs** — Das `+` in `vX.Y.Z+k3sN` muss beim Download von
  GitHub Releases URL-encoded werden (`+` → `%2B`).

## Rollback-Plan

> Rollback innerhalb derselben Minor-Version ist immer sicher. Cross-Minor-Rollback
> ist nur über etcd-Snapshot-Restore möglich (destruktiv!).

Binary auf Vorgängerversion zurücksetzen (Beispiel Master):
```bash
sudo systemctl stop k3s
VERSION_URL="v1.36.1%2Bk3s1"   # + muss URL-encoded werden
sudo curl -sfL \
  "https://github.com/k3s-io/k3s/releases/download/${VERSION_URL}/k3s" \
  -o /usr/local/bin/k3s
sudo chmod 755 /usr/local/bin/k3s
# Unit-File aus Backup wiederherstellen:
sudo cp /etc/systemd/system/k3s.service.bak-v1.36.2+k3s1 \
        /etc/systemd/system/k3s.service
sudo systemctl daemon-reload && sudo systemctl start k3s
```

etcd-Snapshot-Restore (Notfall, nur auf gmkt-01x, alle anderen Master gestoppt):
```bash
sudo systemctl stop k3s
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<name>
# Danach alle anderen Master neu joinen!
```

## Referenzen

- GitHub Releases: https://github.com/k3s-io/k3s/releases
- k3s Upgrade Guide: https://docs.k3s.io/upgrades/manual
- Longhorn Kompatibilität: https://longhorn.io/docs/latest/deploy/install/#installation-requirements
- etcd 3.5→3.6 Hinweis: https://docs.k3s.io/release-notes/v1.32.X
- Ansible-Playbooks: `ansible/playbooks/update-master-nodes.yml`, `ansible/playbooks/update-pi-nodes.yml`, `ansible/playbooks/install-k3s-direct.yml`
- Inventory: `ansible/inventory/hosts.ini`, `ansible/inventory/group_vars/{all,master,worker}.yml`
