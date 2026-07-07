# Upgrade Runbook: k3s (Cluster)

## Metadaten
- **Namespace:** n/a (Cluster-weite Komponente)
- **Aktuelle Version:** v1.36.2+k3s1
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
3. **Workers einzeln (`serial: 1`)** — Longhorn-Drain erfordert sequenziellen Ablauf
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
  Playbook-Ablauf pro Node: Longhorn-Disk-Eviction aktivieren → `kubectl drain` →
  warten bis Replicas migriert → `apt upgrade` → optional EEPROM-Update → k3s-Agent-
  Binary-Update (Unit-File-Backup/Restore analog Master) → nftables-Fix einspielen →
  Reboot → warten bis Ready → `kubectl uncordon` → Longhorn-Scheduling reaktivieren →
  warten bis Replicas wieder aufgebaut.
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
