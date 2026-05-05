# Cluster-Upgrade Checkliste: k3s v1.32.3 → v1.35.4

**Cluster:** homelab (gmkt-01x/02x/03x + k3s-01a..06a)  
**Startversion:** k3s v1.32.3+k3s1  
**Zielversion:** k3s v1.35.4+k3s1  
**Longhorn:** v1.11.1 (aktuell, unterstützt k3s v1.35)  
**Erstellt:** 2026-05-04  
**Status:** ⬜ = offen · ✅ = erledigt · ⚠️ = Achtung beachten

---

## ⚠️ Kritische Hinweise vorab

### etcd-Zwangsschritt (WICHTIG!)
k3s v1.34+ enthält etcd v3.6. Der etcd-Maintainer hat bestätigt: **es gibt keinen sicheren
Upgrade-Pfad von etcd 3.5 → 3.6, außer über etcd v3.5.26.**  
→ v1.32.3 muss deshalb zuerst auf **v1.32.11** (enthält etcd v3.5.26) gebracht werden,
  bevor v1.33 oder höher installiert wird.

### Upgrade-Reihenfolge (immer einhalten!)
1. **Master zuerst** – immer alle Master upgraden bevor Workers dran kommen
2. **Master einzeln (serial: 1)** – etcd-Quorum benötigt 2 von 3 Master zu jeder Zeit
3. **Workers einzeln (serial: 1)** – Longhorn-Drain erfordert sequenziellen Ablauf
4. **Cluster-Verify zwischen den Runden** – nie zwei Runden ohne Gesundheitscheck

### Upgrade-Pfad (4 Runden)

| Runde | Von       | Nach      | Grund                                      |
|-------|-----------|-----------|--------------------------------------------|
| 0     | v1.32.3   | v1.32.11  | ⚠️ etcd v3.5.26 – Pflicht vor v1.34+       |
| 1     | v1.32.11  | v1.33.11  | Minor-Hop +1                               |
| 2     | v1.33.11  | v1.34.7   | Minor-Hop +1, etcd 3.5 → 3.6              |
| 3     | v1.34.7   | v1.35.4   | Minor-Hop +1, Zielversion                  |

> Aktuelle Patch-Versionen vor dem Start prüfen: https://github.com/k3s-io/k3s/releases

---

## Vorbereitung (einmalig, vor Runde 0)

- [ ] **Longhorn-Status prüfen** – alle Volumes müssen Healthy sein
  ```bash
  kubectl -n longhorn-system get nodes.longhorn.io
  kubectl -n longhorn-system get volumes | grep -v Healthy
  # Erwartung: keine Ausgabe (alle Healthy)
  ```

- [ ] **Alle Pods laufend**
  ```bash
  kubectl get pods -A | grep -Ev 'Running|Completed'
  # Erwartung: keine Ausgabe
  ```

- [ ] **ArgoCD – alle Apps Synced/Healthy**
  ```bash
  kubectl -n argocd get applications
  ```

- [ ] **etcd-Baseline-Snapshot erstellen** (auf gmkt-01x)
  ```bash
  sudo k3s etcd-snapshot save --name pre-upgrade-baseline-$(date +%Y%m%d)
  sudo k3s etcd-snapshot ls
  ```

- [ ] **Longhorn SystemBackup erstellen**
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
  # Warten bis Status: Completed
  ```

- [ ] **Ansible-Inventory prüfen**
  ```bash
  ansible master --list-hosts
  ansible worker --list-hosts
  ```

- [ ] **Aktuelle Version auf allen Nodes bestätigen**
  ```bash
  kubectl get nodes -o wide
  # Alle Nodes: v1.32.3+k3s1
  ```

---

## Runde 0: v1.32.3 → v1.32.11 ⚠️ etcd-Pflichtschritt

> Dieser Schritt ist **zwingend erforderlich** bevor v1.33 oder höher installiert wird.
> Er bringt etcd auf v3.5.26, was für den Übergang zu etcd v3.6 (ab v1.34) nötig ist.

### Master-Nodes

- [ ] **etcd-Snapshot vor Runde 0** (auf gmkt-01x)
  ```bash
  sudo k3s etcd-snapshot save --name pre-r0-$(date +%Y%m%d)
  ```

- [ ] **Master upgraden** auf v1.32.11
  ```bash
  ansible-playbook playbooks/update-master-nodes.yml \
    -e k3s_version=v1.32.11+k3s1
  ```

- [ ] **Alle Master auf v1.32.11 und Ready?**
  ```bash
  kubectl get nodes -o wide
  ```

- [ ] **etcd-Quorum gesund?** (auf gmkt-01x)
  ```bash
  sudo k3s etcd-snapshot save --name post-masters-r0-$(date +%Y%m%d)
  ```

### Worker-Nodes

- [ ] **Erst k3s-01a testen**
  ```bash
  ansible-playbook playbooks/update-pi-nodes.yml \
    -e k3s_version=v1.32.11+k3s1 \
    --limit k3s-01a
  ```

- [ ] **k3s-01a Ready? Longhorn Healthy?**
  ```bash
  kubectl get node k3s-01a
  kubectl -n longhorn-system get volumes | grep -v Healthy
  ```

- [ ] **Alle Workers upgraden**
  ```bash
  ansible-playbook playbooks/update-pi-nodes.yml \
    -e k3s_version=v1.32.11+k3s1
  ```

### Runde-0-Abschlusscheck

- [ ] **Alle Nodes auf v1.32.11?**
  ```bash
  kubectl get nodes -o wide
  ```

- [ ] **Alle Pods Running/Completed?**
  ```bash
  kubectl get pods -A | grep -Ev 'Running|Completed'
  ```

- [ ] **Longhorn Volumes Healthy?**
  ```bash
  kubectl -n longhorn-system get volumes | grep -v Healthy
  ```

---

## Runde 1: v1.32.11 → v1.33.11

### Master-Nodes

- [ ] **etcd-Snapshot vor Runde 1** (auf gmkt-01x)
  ```bash
  sudo k3s etcd-snapshot save --name pre-r1-$(date +%Y%m%d)
  ```

- [ ] **Master upgraden** auf v1.33.11
  ```bash
  ansible-playbook playbooks/update-master-nodes.yml \
    -e k3s_version=v1.33.11+k3s1
  ```

- [ ] **Alle Master auf v1.33.11 und Ready?**
  ```bash
  kubectl get nodes -o wide
  ```

### Worker-Nodes

- [ ] **Erst k3s-01a testen**
  ```bash
  ansible-playbook playbooks/update-pi-nodes.yml \
    -e k3s_version=v1.33.11+k3s1 \
    --limit k3s-01a
  ```

- [ ] **k3s-01a Ready? Longhorn Healthy?**
  ```bash
  kubectl get node k3s-01a
  kubectl -n longhorn-system get volumes | grep -v Healthy
  ```

- [ ] **Alle Workers upgraden**
  ```bash
  ansible-playbook playbooks/update-pi-nodes.yml \
    -e k3s_version=v1.33.11+k3s1
  ```

### Runde-1-Abschlusscheck

- [ ] Alle Nodes auf v1.33.11?
  ```bash
  kubectl get nodes -o wide
  ```
- [ ] Alle Pods Running/Completed?
  ```bash
  kubectl get pods -A | grep -Ev 'Running|Completed'
  ```
- [ ] Longhorn Volumes Healthy?
  ```bash
  kubectl -n longhorn-system get volumes | grep -v Healthy
  ```

---

## Runde 2: v1.33.11 → v1.34.7 ⚠️ etcd 3.5 → 3.6

> Ab v1.34 kommt etcd v3.6. Wer Runde 0 gemacht hat (etcd v3.5.26 in v1.32.11),
> ist abgesichert. Trotzdem: etcd-Snapshot direkt davor ist Pflicht.

### Master-Nodes

- [ ] **etcd-Snapshot vor Runde 2** (auf gmkt-01x)
  ```bash
  sudo k3s etcd-snapshot save --name pre-r2-etcd36-$(date +%Y%m%d)
  sudo k3s etcd-snapshot ls
  ```

- [ ] **Master upgraden** auf v1.34.7
  ```bash
  ansible-playbook playbooks/update-master-nodes.yml \
    -e k3s_version=v1.34.7+k3s1
  ```

- [ ] **Alle Master auf v1.34.7 und Ready?**
  ```bash
  kubectl get nodes -o wide
  ```

- [ ] **etcd nach Runde 2 prüfen** (sollte nun v3.6 nutzen)
  ```bash
  # Auf gmkt-01x – etcd-Member-Status prüfen
  sudo k3s etcd-snapshot save --name post-masters-r2-$(date +%Y%m%d)
  ```

### Worker-Nodes

- [ ] **Erst k3s-01a testen**
  ```bash
  ansible-playbook playbooks/update-pi-nodes.yml \
    -e k3s_version=v1.34.7+k3s1 \
    --limit k3s-01a
  ```

- [ ] **k3s-01a Ready? Longhorn Healthy?**
  ```bash
  kubectl get node k3s-01a
  kubectl -n longhorn-system get volumes | grep -v Healthy
  ```

- [ ] **Alle Workers upgraden**
  ```bash
  ansible-playbook playbooks/update-pi-nodes.yml \
    -e k3s_version=v1.34.7+k3s1
  ```

### Runde-2-Abschlusscheck

- [ ] Alle Nodes auf v1.34.7?
  ```bash
  kubectl get nodes -o wide
  ```
- [ ] Alle Pods Running/Completed?
  ```bash
  kubectl get pods -A | grep -Ev 'Running|Completed'
  ```
- [ ] Longhorn Volumes Healthy?
  ```bash
  kubectl -n longhorn-system get volumes | grep -v Healthy
  ```

---

## Runde 3: v1.34.7 → v1.35.4 (Ziel)

### Master-Nodes

- [ ] **etcd-Snapshot vor Runde 3** (auf gmkt-01x)
  ```bash
  sudo k3s etcd-snapshot save --name pre-r3-final-$(date +%Y%m%d)
  ```

- [ ] **Master upgraden** auf v1.35.4
  ```bash
  ansible-playbook playbooks/update-master-nodes.yml \
    -e k3s_version=v1.35.4+k3s1
  ```

- [ ] **Alle Master auf v1.35.4 und Ready?**
  ```bash
  kubectl get nodes -o wide
  ```

### Worker-Nodes

- [ ] **Erst k3s-01a testen**
  ```bash
  ansible-playbook playbooks/update-pi-nodes.yml \
    -e k3s_version=v1.35.4+k3s1 \
    --limit k3s-01a
  ```

- [ ] **k3s-01a Ready? Longhorn Healthy?**
  ```bash
  kubectl get node k3s-01a
  kubectl -n longhorn-system get volumes | grep -v Healthy
  ```

- [ ] **Alle Workers upgraden**
  ```bash
  ansible-playbook playbooks/update-pi-nodes.yml \
    -e k3s_version=v1.35.4+k3s1
  ```

### Finaler Abschlusscheck

- [ ] **Alle Nodes auf v1.35.4?**
  ```bash
  kubectl get nodes -o wide
  ```

- [ ] **Alle Pods Running/Completed?**
  ```bash
  kubectl get pods -A | grep -Ev 'Running|Completed'
  ```

- [ ] **Longhorn Volumes Healthy?**
  ```bash
  kubectl -n longhorn-system get volumes | grep -v Healthy
  ```

- [ ] **ArgoCD – alle Apps Synced/Healthy?**
  ```bash
  kubectl -n argocd get applications
  ```

- [ ] **Traefik IngressRoutes erreichbar?**
  ```bash
  curl -sk https://gitea.reckeweg.io | head -5
  curl -sk https://grafana.reckeweg.io | head -5
  ```

- [ ] **Abschluss-etcd-Snapshot**
  ```bash
  sudo k3s etcd-snapshot save --name post-upgrade-v1.35.4-$(date +%Y%m%d)
  sudo k3s etcd-snapshot ls
  ```

---

## Rollback (falls nötig)

> Rollback ist nur innerhalb derselben Minor-Version sicher.
> Bei etcd-Upgrade (Runde 2: 3.5→3.6) ist Rollback **nur über etcd-Snapshot-Restore** möglich.

```bash
# etcd-Snapshot wiederherstellen (auf gmkt-01x, Notfall)
sudo systemctl stop k3s
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<snapshot-name>
```

> ⚠️ Cluster-Reset stoppt den Cluster komplett. Alle anderen Master müssen
> danach neu gejoint werden. Nur als letzter Ausweg.

---

## Referenzen

- k3s Releases: https://github.com/k3s-io/k3s/releases
- k3s Upgrade Guide: https://docs.k3s.io/upgrades/manual
- Longhorn Kompatibilität: https://longhorn.io/docs/latest/deploy/install/#installation-requirements
- etcd 3.5→3.6 Hinweis: https://docs.k3s.io/release-notes/v1.32.X
