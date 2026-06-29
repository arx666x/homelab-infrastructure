# k3s Cluster-Upgrade Runbook

**Cluster:** homelab (gmkt-01x/02x/03x + k3s-01a..06a)  
**Status:** ⬜ = offen · ✅ = erledigt · ⚠️ = Achtung beachten

---

## Upgrade-Historie

| Von       | Nach      | Datum      | Besonderheiten                                      |
|-----------|-----------|------------|-----------------------------------------------------|
| v1.28.x   | v1.32.3   | 2026-04-28 | 4 Minor-Hops, Traefik-Swap v2→v3                    |
| v1.32.3   | v1.35.4   | 2026-05-04 | etcd 3.5→3.6 (Pflichtschritt über v1.32.11)         |
| v1.35.4   | v1.36.0   | 2026-05-17 | 1 Hop, RPi-Kernel 6.18 iptables-Umstellung erforderlich |
| v1.36.0   | v1.36.1   | 2026-05-18 | Patch-Release, bugfixes only, kein Sonderfall       |
| v1.36.1   | v1.36.2   | 2026-05-29 | Patch-Release, bugfixes only, kein Sonderfall       |

---

## Allgemeine Regeln (immer einhalten)

1. **Master zuerst** – alle Master upgraden bevor Workers dran kommen
2. **Master einzeln (serial: 1)** – etcd-Quorum benötigt 2 von 3 Master zu jeder Zeit
3. **Workers einzeln (serial: 1)** – Longhorn-Drain erfordert sequenziellen Ablauf
4. **Cluster-Verify nach den Masters** – nie zu den Workers ohne Gesundheitscheck
5. **Nur stable Releases** – keine RC/Pre-release Versionen

---

## Bekannte Eigenheiten dieses Clusters

### ⚠️ RPi-Kernel 6.18+: ip_tables-Modul entfernt (entdeckt: 2026-05-17)

Der Raspberry Pi Kernel 6.18.x (rpt-rpi-2712) enthält kein `ip_tables`-Kernelmodul mehr.
Flannel und kube-proxy brauchen aber iptables – ohne Fix stürzt k3s-agent beim Start ab.

**Bestätigt weiterhin wirksam:** Bei Upgrade v1.36.1→v1.36.2 (2026-05-29) liefen die
RPis bereits auf Kernel 6.18.34 und der nftables-Fix griff ohne Nacharbeit.

**Gelöst im Playbook `update-pi-nodes.yml`:**
- `apt install iptables` stellt das Paket sicher (war auf manchen Nodes nicht installiert)
- `update-alternatives` schaltet `/usr/sbin/iptables` auf `iptables-nft` um (nutzt `nf_tables`-Modul)
- `--kube-proxy-arg=proxy-mode=nftables` wird in die k3s-agent Unit-File eingetragen

**Manuelle Notfallbehebung** (falls Playbook-Fehler mid-run):
```bash
# Auf dem betroffenen Worker:
sudo apt install -y iptables
sudo update-alternatives --set iptables /usr/sbin/iptables-nft
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-nft
# Unit-File nftables-Flag eintragen (falls mehrzeilig):
sudo sed -i "s|'--flannel-iface=eth0.XX' \\\\|'--flannel-iface=eth0.XX' \\\\\n    '--kube-proxy-arg=proxy-mode=nftables' \\\\|" \
  /etc/systemd/system/k3s-agent.service
sudo systemctl daemon-reload && sudo systemctl start k3s-agent
# Danach vom Master:
kubectl uncordon <node-name>
```

### ⚠️ Longhorn Eviction-Timeout bei großen Volumes

Bei Volumes > 20 GB kann die Longhorn-Eviction (Replica-Migration vor dem Drain)
länger als 10 Minuten dauern. Das Playbook ist auf 30 Minuten konfiguriert.

Falls das Playbook mid-run abbricht und Longhorn-Scheduling deaktiviert bleibt:
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

### etcd-Pflichtschritt v1.32→v1.34 (abgeschlossen, nur zur Dokumentation)

k3s v1.34+ enthält etcd v3.6. Der Upgrade-Pfad von etcd 3.5→3.6 erfordert zwingend
etcd v3.5.26 als Zwischenschritt. Das bedeutet: vor einem Sprung auf v1.33+ muss
erst auf **v1.32.11** (enthält etcd v3.5.26) geupgradet werden.

→ **Für alle zukünftigen Upgrades ab v1.34+ nicht mehr relevant** (etcd bleibt 3.6).

---

## Vorbereitung (vor jedem Upgrade)

- [ ] **Longhorn-Status prüfen** – alle Volumes Healthy, kein AllowScheduling=false
  ```bash
  kubectl -n longhorn-system get nodes.longhorn.io
  kubectl -n longhorn-system get volumes | grep -v Healthy
  ```

- [ ] **Alle Pods laufend**
  ```bash
  kubectl get pods -A | grep -Ev 'Running|Completed|Succeeded'
  ```

- [ ] **ArgoCD – alle Apps Synced/Healthy**
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

- [ ] **Patch-Version bestätigen:** https://github.com/k3s-io/k3s/releases

---

## Upgrade-Ablauf (Standard: einfacher Minor-Hop)

> Gilt für alle Upgrades ab v1.34+ (kein etcd-Sonderfall mehr).

### Master-Nodes

- [ ] **etcd-Snapshot vor dem Upgrade** (auf gmkt-01x)
  ```bash
  sudo k3s etcd-snapshot save --name pre-upgrade-masters-$(date +%Y%m%d)
  ```

- [ ] **Alle Master upgraden**
  ```bash
  ansible-playbook playbooks/update-master-nodes.yml \
    -e k3s_version=<VERSION>+k3s1
  ```

- [ ] **Alle Master Ready? Pods OK? Longhorn Healthy?**
  ```bash
  kubectl get nodes -o wide
  kubectl get pods -A | grep -Ev 'Running|Completed|Succeeded'
  kubectl -n longhorn-system get volumes | grep -v Healthy
  ```

### Worker-Nodes

- [ ] **Erst worker01 testen**
  ```bash
  ansible-playbook playbooks/update-pi-nodes.yml \
    -e k3s_version=<VERSION>+k3s1 \
    --limit worker01
  ```

- [ ] **worker01 Ready? Longhorn Healthy?**
  ```bash
  kubectl get node k3s-01a
  kubectl -n longhorn-system get volumes | grep -v Healthy
  ```

- [ ] **Alle Workers upgraden**
  ```bash
  ansible-playbook playbooks/update-pi-nodes.yml \
    -e k3s_version=<VERSION>+k3s1
  ```

---

## Upgrade-Ablauf: v1.32 → v1.35 (Sonderfall etcd, abgeschlossen ✅)

> Dokumentiert zur Referenz. Der etcd-Pflichtschritt ist für zukünftige Upgrades
> nicht mehr erforderlich (etcd bleibt auf v3.6).

### Upgrade-Pfad (4 Runden)

| Runde | Von       | Nach      | Grund                                      |
|-------|-----------|-----------|--------------------------------------------|
| 0     | v1.32.3   | v1.32.11  | ⚠️ etcd v3.5.26 – Pflicht vor v1.34+       |
| 1     | v1.32.11  | v1.33.11  | Minor-Hop +1                               |
| 2     | v1.33.11  | v1.34.7   | Minor-Hop +1, etcd 3.5 → 3.6              |
| 3     | v1.34.7   | v1.35.4   | Minor-Hop +1, Zielversion                  |

Jede Runde folgt dem Standard-Ablauf (Master → Verify → Worker → Verify).

**Runde 0 ist der kritische Schritt**: ohne v1.32.11 (etcd v3.5.26) darf v1.33+
**nicht** installiert werden.

---

## Finaler Abschlusscheck

- [ ] **Alle Nodes auf Zielversion, alle Ready**
  ```bash
  kubectl get nodes -o wide
  ```

- [ ] **Keine degraded Pods**
  ```bash
  kubectl get pods -A | grep -Ev 'Running|Completed|Succeeded'
  ```

- [ ] **Longhorn alle Volumes Healthy, alle Nodes Schedulable**
  ```bash
  kubectl -n longhorn-system get volumes | grep -v Healthy
  kubectl -n longhorn-system get nodes.longhorn.io
  ```

- [ ] **ArgoCD alle Apps Synced/Healthy**
  ```bash
  kubectl -n argocd get applications
  ```

- [ ] **Traefik IngressRoutes erreichbar**
  ```bash
  curl -sk https://gitea.reckeweg.io | head -5
  curl -sk https://grafana.reckeweg.io | head -5
  ```

- [ ] **Abschluss-etcd-Snapshot**
  ```bash
  sudo k3s etcd-snapshot save --name post-upgrade-$(date +%Y%m%d)
  sudo k3s etcd-snapshot ls
  ```

---

## Rollback

> Rollback innerhalb derselben Minor-Version ist immer sicher.
> Cross-Minor-Rollback ist nur über etcd-Snapshot-Restore möglich (destruktiv!).

```bash
# Binary auf Vorgängerversion zurücksetzen (Beispiel Master):
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

```bash
# etcd-Snapshot-Restore (Notfall, nur auf gmkt-01x, alle anderen Master gestoppt):
sudo systemctl stop k3s
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<name>
# Danach alle anderen Master neu joinen!
```

---

## Referenzen

- k3s Releases: https://github.com/k3s-io/k3s/releases
- k3s Upgrade Guide: https://docs.k3s.io/upgrades/manual
- Longhorn Kompatibilität: https://longhorn.io/docs/latest/deploy/install/#installation-requirements
- etcd 3.5→3.6 Hinweis: https://docs.k3s.io/release-notes/v1.32.X
