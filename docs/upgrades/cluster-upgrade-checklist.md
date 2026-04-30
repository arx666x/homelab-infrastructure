# Cluster-Upgrade Checkliste: k3s v1.28 → v1.32 + OS-Update

**Cluster:** homelab (gmkt-01x/02x/03x + k3s-01a..06a)  
**Zielversion:** k3s v1.32.x+k3s1  
**Erstellt:** 2026-04-28  
**Status:** ⬜ = offen · ✅ = erledigt · ⚠️ = Achtung erforderlich

---

## Vorbereitung (einmalig, vor Runde 1)

- [ ] **Longhorn-Status prüfen**
  ```bash
  kubectl -n longhorn-system get nodes.longhorn.io
  kubectl -n longhorn-system get volumes | grep -v Healthy
  ```
  Alle Volumes müssen `Healthy` sein, keine `degraded` Replicas.

- [ ] **etcd-Snapshot manuell erstellen** (Baseline-Backup)
  ```bash
  # Auf gmkt-01x:
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
  ```

- [ ] **ArgoCD-Sync-Status prüfen** – alle Apps müssen `Synced/Healthy` sein
  ```bash
  kubectl -n argocd get applications
  ```

- [ ] **Ansible-Inventory prüfen** – beide Gruppen vorhanden?
  ```bash
  ansible k3s_masters --list-hosts
  ansible pi_workers --list-hosts
  ```

- [ ] **Patch-Versionen für alle Runden notieren:**

  | Runde | Von    | Nach   | Empfohlene Version    |
  |-------|--------|--------|-----------------------|
  | 1     | v1.28  | v1.29  | `v1.29.15+k3s1`       |
  | 2     | v1.29  | v1.30  | `v1.30.11+k3s1`       |
  | 3     | v1.30  | v1.31  | `v1.31.7+k3s1`        |
  | 4     | v1.31  | v1.32  | `v1.32.3+k3s1`        |

  > Vor jeder Runde aktuelle Patch-Versionen prüfen:
  > https://github.com/k3s-io/k3s/releases

---

## Runde 1: v1.28 → v1.29

> ⚠️ **Master immer VOR Workers upgraden!**

### Master-Nodes (gmkt-01x → gmkt-02x → gmkt-03x)

- [ ] **Master upgraden** (serial: 1, einer nach dem anderen)
  ```bash
  ansible-playbook update-master-nodes.yml \
    -e k3s_version=v1.29.15+k3s1
  ```

- [ ] **Alle Master Ready und auf v1.29?**
  ```bash
  kubectl get nodes -o wide
  ```

- [ ] **etcd-Quorum gesund?**
  ```bash
  # Auf gmkt-01x:
  sudo k3s etcd-snapshot ls | head -5
  ```

### Worker-Nodes (k3s-01a..06a)

- [ ] **Workers upgraden** (serial: 1)
  ```bash
  ansible-playbook update-pi-nodes.yml \
    -e k3s_version=v1.29.15+k3s1
  ```
  > Erster Testlauf mit einzelnem Node empfohlen:
  > ```bash
  > ansible-playbook update-pi-nodes.yml \
  >   -e k3s_version=v1.29.15+k3s1 \
  >   --limit k3s-01a
  > ```

- [ ] **Alle Nodes Ready und auf v1.29?**
  ```bash
  kubectl get nodes -o wide
  ```

- [ ] **Alle Pods Running/Completed?**
  ```bash
  kubectl get pods -A | grep -Ev 'Running|Completed'
  ```

- [ ] **Longhorn-Volumes Healthy?**
  ```bash
  kubectl -n longhorn-system get volumes | grep -v Healthy
  ```

---

## Runde 2: v1.29 → v1.30

### Master-Nodes

- [ ] **Master upgraden**
  ```bash
  ansible-playbook update-master-nodes.yml \
    -e k3s_version=v1.30.11+k3s1 \
    -e etcd_snapshot=true
  ```

- [ ] **Alle Master Ready und auf v1.30?**

### Worker-Nodes

- [ ] **Workers upgraden**
  ```bash
  ansible-playbook update-pi-nodes.yml \
    -e k3s_version=v1.30.11+k3s1
  ```

- [ ] **Alle Nodes Ready? Pods OK? Longhorn Healthy?**

---

## Runde 3: v1.30 → v1.31

### Master-Nodes

- [ ] **Master upgraden**
  ```bash
  ansible-playbook update-master-nodes.yml \
    -e k3s_version=v1.31.7+k3s1 \
    -e etcd_snapshot=true
  ```

- [ ] **Alle Master Ready und auf v1.31?**

### Worker-Nodes

- [ ] **Workers upgraden**
  ```bash
  ansible-playbook update-pi-nodes.yml \
    -e k3s_version=v1.31.7+k3s1
  ```

- [ ] **Alle Nodes Ready? Pods OK? Longhorn Healthy?**

---

## Runde 4: v1.31 → v1.32

> ⚠️ **Traefik-Schwelle:** k3s 1.32 würde normalerweise Traefik v3 deployen.
> Bei euch ist Traefik via `--disable traefik` in der k3s.service deaktiviert
> → **kein Handlungsbedarf**, das Skip ist bereits sicher verankert.

### Master-Nodes

- [ ] **Vor dem Upgrade: Unit-File auf allen Mastern sicherstellen**
  ```bash
  # Auf jedem Master: --disable traefik muss vorhanden sein
  grep 'disable' /etc/systemd/system/k3s.service
  ```

- [ ] **Master upgraden**
  ```bash
  ansible-playbook update-master-nodes.yml \
    -e k3s_version=v1.32.3+k3s1 \
    -e etcd_snapshot=true
  ```

- [ ] **Alle Master Ready und auf v1.32?**

- [ ] **k3s-internes Traefik NICHT deployed?** (Sicherheitsprüfung)
  ```bash
  kubectl -n kube-system get helmchart traefik 2>/dev/null || echo "OK - nicht vorhanden"
  kubectl -n kube-system get pods | grep traefik || echo "OK - keine Traefik-Pods"
  ```

### Worker-Nodes

- [ ] **Workers upgraden**
  ```bash
  ansible-playbook update-pi-nodes.yml \
    -e k3s_version=v1.32.3+k3s1
  ```

- [ ] **Alle Nodes Ready? Pods OK? Longhorn Healthy?**

---

## Nach Runde 4: OS-Update (falls noch nicht in Runden erledigt)

> Das `update-pi-nodes.yml` erledigt OS-Update und k3s-Update in einem Durchlauf.
> Falls OS-Update separat gewünscht:

- [ ] **Worker OS-Update ohne k3s-Upgrade**
  ```bash
  ansible-playbook update-pi-nodes.yml  # ohne -e k3s_version
  ```

- [ ] **Master OS-Update ohne k3s-Upgrade**
  ```bash
  ansible-playbook update-master-nodes.yml \
    -e k3s_version="" \
    -e skip_os_update=false
  ```
  > Alternativ manuell per apt auf jedem Master (kein Drain nötig bei reinem OS-Update
  > ohne Kernel-Wechsel – bei Kernel-Update jedoch Reboot einplanen).

---

## Abschluss: Gitea Actions Chart deployen

- [ ] **Traefik v2 → v3 upgraden** (ArgoCD)
  ```bash
  # gitops/apps/traefik.yaml: targetRevision von 26.0.0 auf 33.x.x setzen
  # Dann committen und pushen → ArgoCD synct automatisch
  kubectl -n traefik get pods -w
  ```
  > Da ihr keine IngressRoute/Middleware-Ressourcen nutzt, ist die Migration
  > von v2 auf v3 unkritisch.

- [ ] **Traefik v3 läuft?**
  ```bash
  kubectl -n traefik get deployment traefik \
    -o jsonpath='{.spec.template.spec.containers[0].image}'
  ```

- [ ] **gitea-actions Helm Chart deployen**
  ```bash
  helm repo add gitea-charts https://dl.gitea.com/charts/
  helm repo update
  helm show values gitea-charts/actions > /tmp/gitea-actions-values.yaml
  # values anpassen, dann:
  helm upgrade --install gitea-actions gitea-charts/actions \
    -n gitea -f /tmp/gitea-actions-values.yaml
  ```

- [ ] **Actions Runner registriert?**
  ```bash
  kubectl -n gitea get pods | grep actions
  # Gitea UI: Site Administration → Actions → Runners
  ```

---

## Finale Verifikation

- [ ] **Alle Nodes auf v1.32, alle Ready**
  ```bash
  kubectl get nodes -o wide
  ```

- [ ] **Keine degraded Pods**
  ```bash
  kubectl get pods -A | grep -Ev 'Running|Completed|Succeeded'
  ```

- [ ] **Longhorn alle Volumes Healthy**
  ```bash
  kubectl -n longhorn-system get volumes
  ```

- [ ] **ArgoCD alle Apps Synced/Healthy**
  ```bash
  kubectl -n argocd get applications
  ```

- [ ] **kubectl-Version wieder synchron** (Client 1.35 → bei 1.32 Server ist Skew +3, noch außerhalb Spec)
  > Wenn kubectl-Client auf 1.35 bleibt: Warnung bleibt, funktioniert aber.
  > Für sauberen Zustand: kubectl auf v1.32 oder v1.33 downgraden.

- [ ] **Wiki-Seite `Operations_ClusterUpdates.md` aktualisieren**

---

## Rollback-Referenz

Falls ein Master nach dem Upgrade nicht startet:

```bash
# Unit-File aus Backup wiederherstellen
sudo cp /etc/systemd/system/k3s.service.bak-v1.28.5+k3s1 \
        /etc/systemd/system/k3s.service
sudo systemctl daemon-reload

# Binary auf alte Version zurücksetzen
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="v1.28.5+k3s1" \
  INSTALL_K3S_SKIP_START=true \
  sh -s - server
sudo systemctl start k3s
```

Falls etcd-Restore nötig:
```bash
# Auf gmkt-01x – alle anderen Master müssen gestoppt sein!
sudo k3s etcd-snapshot restore \
  --name pre-upgrade-baseline-YYYYMMDD \
  --cluster-reset
```
