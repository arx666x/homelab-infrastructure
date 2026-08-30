# Aktualisierung der Betriebssysteme und von Kubernetes

Dieses Dokument beschreibt, wie OS- und k3s-Updates für die drei Node-Gruppen
des Homelabs gefahren werden: k3s-Master, k3s-Worker und DNS-Nodes. Alle drei
laufen über eigene Ansible-Playbooks unter `ansible/playbooks/`.

---

## Überblick

| Gruppe | Playbook | Hosts | k3s-Update? | HA-Absicherung |
|--------|----------|-------|-------------|-----------------|
| k3s-Master (gmkt-01x/02x/03x) | `update-master-nodes.yml` | `master` | ja (Pflichtparameter) | etcd-Quorum-Check, `serial: 1` |
| k3s-Worker (k3s-01a…06a) | `update-pi-nodes.yml` | `worker` | optional | Longhorn-Drain, `serial: 1` |
| DNS-Nodes (dns01, später dns02) | `update-dns.yml` | `dns` | n/a (kein k3s) | VRRP-Failover-Check, `serial: 1` |

Alle drei Playbooks aktualisieren nur das Betriebssystem (apt) + optional
Firmware (EEPROM bei Raspberry Pi) und rebooten kontrolliert einen Node nach
dem anderen. Kein Playbook läuft parallel über mehrere Nodes einer Gruppe.

**Woher weiß ich, ob überhaupt etwas ansteht?** Seit dem OS-Update-Tracking
(siehe [monitoring-dokumentation.md](monitoring-dokumentation.md#os-update-tracking))
zeigt Prometheus `node_os_updates_pending` und `node_os_reboot_required` pro
Node, und Telegram/Mail meldet sich automatisch, wenn Updates seit >3 Tagen
anstehen oder ein Reboot seit >1h fällig ist. Reines Nachsehen reicht auch:

```bash
kubectl get nodes   # aktuelle k3s-Version pro Node
```

---

## Reihenfolge

1. **Master zuerst, dann Worker.** Bei 3-Node-etcd darf maximal 1 Master
   gleichzeitig down sein - deshalb `update-master-nodes.yml` immer vor
   `update-pi-nodes.yml`, nie umgekehrt.
2. **DNS-Nodes sind unabhängig** vom k3s-Cluster (eigene `[dns]`-Inventory-
   Gruppe, kein k3s dort) - können vorher, nachher oder an einem ganz
   anderen Tag laufen. Einzige Besonderheit: siehe
   [Abschnitt DNS-Nodes](#3-dns-nodes) unten.

---

## 1. k3s-Master

`update-master-nodes.yml` verlangt **zwingend** `k3s_version` - ohne den
Parameter bricht ein Preflight-Check sofort ab. Das ist auch dann so, wenn
gar kein k3s-Upgrade gewünscht ist, sondern nur das OS aktualisiert werden
soll.

### Der Trick: OS-Update ohne k3s-Upgrade

Die eigentlichen Binary-Download/Restart-Schritte im Playbook sind an
`when: k3s_installed_ver != k3s_version` geknüpft. Übergibt man also genau
die **aktuell installierte** Version, überspringt das Playbook den
k3s-Teil automatisch und macht nur Drain, apt-Upgrade und Reboot:

```bash
# Aktuelle Version ermitteln:
kubectl get nodes -o custom-columns='NAME:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion'

# Reine OS-Aktualisierung, kein k3s-Upgrade:
ansible-playbook -i inventory/hosts.ini playbooks/update-master-nodes.yml -e k3s_version=v1.36.2+k3s1
```

(Version durch die tatsächlich installierte ersetzen - `kubectl get nodes`
oben zeigt sie an.)

### Echtes k3s-Upgrade

```bash
ansible-playbook -i inventory/hosts.ini playbooks/update-master-nodes.yml -e k3s_version=v1.29.15+k3s1
```

### Weitere Parameter

```bash
ansible-playbook -i inventory/hosts.ini playbooks/update-master-nodes.yml -e k3s_version=v1.36.2+k3s1 --limit master01
ansible-playbook -i inventory/hosts.ini playbooks/update-master-nodes.yml -e k3s_version=v1.36.2+k3s1 -e skip_os_update=true
ansible-playbook -i inventory/hosts.ini playbooks/update-master-nodes.yml -e k3s_version=v1.36.2+k3s1 -e etcd_snapshot=false
```

Ablauf pro Node: etcd-Quorum-Check → etcd-Snapshot (nur einmal, auf gmkt-01x)
→ `kubectl drain` → apt-Upgrade → ggf. k3s-Binary tauschen → k3s-Server
neu starten → warten bis Ready + etcd wieder im Quorum → `kubectl uncordon`.

---

## 2. k3s-Worker (Raspberry Pi)

Hier ist `k3s_version` **optional** - ohne den Parameter läuft nur das
OS-Update, kein k3s-Upgrade:

```bash
# Reine OS-Aktualisierung:
ansible-playbook -i inventory/hosts.ini playbooks/update-pi-nodes.yml

# Mit k3s-Upgrade:
ansible-playbook -i inventory/hosts.ini playbooks/update-pi-nodes.yml -e k3s_version=v1.29.15+k3s1

# Einzelner Node, mit EEPROM-Update:
ansible-playbook -i inventory/hosts.ini playbooks/update-pi-nodes.yml --limit worker01 -e eeprom_update=true

# Longhorn-Drain überspringen (nur im Notfall):
ansible-playbook -i inventory/hosts.ini playbooks/update-pi-nodes.yml -e skip_longhorn=true
```

Ablauf pro Node: Longhorn-Disk-Eviction aktivieren → `kubectl drain` →
warten bis Replicas migriert sind → apt-Upgrade → EEPROM (optional) →
ggf. k3s-Agent-Binary tauschen → Reboot → warten bis Ready → `kubectl
uncordon` → warten bis Longhorn-Replicas wieder aufgebaut sind.

---

## 3. DNS-Nodes

`update-dns.yml` (dns01, dns02) hat kein k3s und keinen
Versionsparameter - reines OS-Update + optionales EEPROM. Besonderheit:
DNS-Nodes haben **keine Anwendungs-HA**, solange nur dns01 existiert.
keepalived spielt die VIP (192.168.11.56) zwischen DNS-Nodes hin und her,
aber mit nur einem Node gibt es niemanden, der übernehmen könnte - ein
Reboot des aktiven VRRP-Masters bedeutet einen **kompletten DNS-Ausfall**
fürs ganze Netz, bis der Node wieder hochgefahren ist.

Das Playbook prüft das selbst (via `keepalived_exporter`, ob dieser Node
gerade MASTER ist, und ob ein anderer `[dns]`-Host auf Port 53 antwortet)
und **pausiert vor dem Reboot** zur manuellen Bestätigung, wenn kein
Failover verfügbar ist:

```bash
# Normaler Aufruf - pausiert vor dem Reboot mit Warnhinweis,
# wenn kein anderer DNS-Node übernehmen kann (aktuell IMMER der Fall):
ansible-playbook -i inventory/hosts.ini playbooks/update-dns.yml

# Einzelner Node (aktuell ohnehin der einzige):
ansible-playbook -i inventory/hosts.ini playbooks/update-dns.yml --limit dns01

# Mit EEPROM-Update (Raspberry Pi 5):
ansible-playbook -i inventory/hosts.ini playbooks/update-dns.yml -e eeprom_update=true

# Bestätigungs-Pause bewusst überspringen (z.B. für Automatisierung):
ansible-playbook -i inventory/hosts.ini playbooks/update-dns.yml -e confirm=true

# Reboot erzwingen, auch ohne /var/run/reboot-required:
ansible-playbook -i inventory/hosts.ini playbooks/update-dns.yml -e force_reboot=true
```

**Wichtig:** Die Pause (`ansible.builtin.pause`) blockiert nur, wenn das
Playbook interaktiv in einem echten Terminal läuft. Ohne TTY (Cron,
Skript) überspringt Ansible sie automatisch mit einer Warnung - dort also
nur mit `-e confirm=true` bewusst gegenlaufen, nicht blind automatisieren.

Ablauf pro Node: VRRP-Status + Failover prüfen, ggf. Bestätigung einholen
→ apt-Upgrade → EEPROM (optional) → Reboot (nur falls nötig oder
`force_reboot=true`) → warten bis SSH wieder da ist → pihole-FTL,
keepalived, node_exporter, keepalived_exporter sicherstellen → VRRP-Status
danach anzeigen.

Der Failover-Check greift automatisch, seit dns02 in der Inventory aktiv
ist: ist der jeweils andere Node erreichbar, entfällt die Pause.

### Voraussetzung: Exporter müssen vorher installiert sein

Der Post-Check `[ POST ] Kern-Services sicherstellen` erwartet, dass
`node_exporter` und `keepalived_exporter` bereits als systemd-Units
existieren - `update-dns.yml` installiert sie nicht, sondern prüft nur,
ob sie laufen. Installiert werden sie separat über
[`dns-exporters.yml`](../ansible/playbooks/dns-exporters.yml):

```bash
ansible-playbook -i inventory/hosts.ini playbooks/dns-exporters.yml --limit <neuer-node>
```

**Bekannter Fehler**, wenn das für einen neu zur `[dns]`-Gruppe
hinzugefügten Node vergessen wurde (passiert bei dns02, 2026-08-26 -
dns-exporters.yml war nur gegen dns01 gelaufen, bevor dns02 in
`hosts.ini` aktiviert wurde):

```
[ERROR]: Task failed: Module failed: Could not find the requested service node_exporter: host
```

Fix: `dns-exporters.yml` einmalig gegen den betroffenen Node laufen
lassen, danach liefert `update-dns.yml` den Post-Check sauber.
`keepalived_exporter` wird darin nur für `aarch64` installiert (arm64
`.deb`, kein amd64-Downloadpfad) - bei x86_64-DNS-Nodes müsste das
Playbook zuerst um einen amd64-Pfad ergänzt werden.

---

## Zusammenfassung: typischer Update-Durchlauf

```bash
cd ansible

# 1. Master (OS-only, k3s bleibt wie es ist)
ansible-playbook -i inventory/hosts.ini playbooks/update-master-nodes.yml -e k3s_version=v1.36.2+k3s1

# 2. Worker (OS-only)
ansible-playbook -i inventory/hosts.ini playbooks/update-pi-nodes.yml

# 3. DNS-Nodes (unabhängig, eigener Zeitpunkt möglich)
ansible-playbook -i inventory/hosts.ini playbooks/update-dns.yml
```
