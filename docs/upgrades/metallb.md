# Upgrade Runbook: MetalLB

## Metadaten
- **Namespace:** `metallb-system`
- **Aktuelle Version:** Helm Chart 0.16.1 / MetalLB v0.16.1
- **Quelle:** Helm-Chart-Repo `https://metallb.github.io/metallb` (Chart `metallb`)
- **ArgoCD App-Name:** `metallb`
- **Versions-Check-Quelle:** Helm-Repo-Index über das `helm`-Binary (niemals `index.yaml` direkt mit `yaml.safe_load()` parsen — OOM-Falle, siehe Memory-Notiz zu Helm-Index-Parsing)
- **Major/Minor-Kriterium:** Standard-SemVer-Regel des Upgrade-Checkers (`version_bump_type()` in `scripts/upgrade-agent.py`): Erste Versionsstelle ändert sich → Major, zweite Stelle ändert sich → Minor, sonst Patch. Automatische Ausführung (AUTO) nur bei Patch-Bumps bzw. Minor-Bumps ohne Breaking Changes/CRD-Migration laut Release Notes; alle Major-Bumps sowie Minor-Bumps mit Breaking Changes lösen NOTIFY aus.

## Changelog

| Datum | Von → Nach | Typ | Ausführung | Status | Begründung | Notiz |
|---|---|---|---|---|---|---|
| unbekannt | ... → 0.14.8 | ... | ... | ... | Historie vor Einführung des strukturierten Runbooks nicht vollständig rekonstruierbar (erste im Git nachvollziehbare Version ist 0.14.8, aus Commit `refactor: Apps/Config separated`, 2026-02-23; davor existierte MetalLB bereits unter `gitops/infrastructure/metallb/` in älterer Repo-Struktur) | — |
| 2026-05-04 | 0.14.8 → 0.15.3 | Minor | Manuell | Abgeschlossen | FRR 10.4.1 (CVE-2025-22874 Fix), neue ConfigurationState-CRD, distroless Images, `metallb.universe.tf`-Annotation-Prefix deprecated zugunsten `metallb.io` | Commit `dd3d0b7`; alle 9 Speaker neu gestartet, kein L2-Ausfall bemerkt |
| 2026-05-26 | 0.15.3 → 0.16.0 | Minor | Manuell | Abgeschlossen | Native TLS ersetzt kube-rbac-proxy, FRR 10.5.3, FRR-K8s wird BGP-Default (L2-Mode nicht betroffen); zusätzlich Fix nötig da `frrk8s.enabled` neuer Default `true` ist | Commits `576b38f` (Upgrade) + `da3b99c` (frrk8s-Fix, selber Tag); siehe Stolperfalle unten |
| 2026-06-14 | 0.16.0 → 0.16.1 | Patch | Automatisch | Abgeschlossen | Reiner Patch-Release: Helm-Chart-Rendering-Fix, BGPPeer `localASN` int64-Korrektur, Health-Probes auf allen Interfaces, Metriken-TLS-Scheme-Fix | Commit `d60c2e3` |

### Reklassifizierungen (Minor → Major)

| Datum Erkennung | Ursprünglicher Changelog-Eintrag (Datum) | Grund der Reklassifizierung | Erneute Benachrichtigung gesendet am |
|---|---|---|---|

## Manuelle Vorgehensweise (bei Major/Breaking Change)

### Phase 1: Pre-Upgrade Checks

```bash
# ArgoCD App Status
argocd app get metallb

# Aktuelle Version bestätigen (Multi-Source App — .spec.source (singular) liefert leer!)
kubectl -n argocd get application metallb \
  -o jsonpath='{.spec.sources[0].targetRevision}{"\n"}'

# Alle MetalLB Pods Running?
kubectl get pods -n metallb-system -o wide

# CRDs aktuell vorhanden
kubectl get crds | grep metallb.io

# IP Pools und L2Advertisement
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system -o yaml

# Aktive LoadBalancer-Services
kubectl get svc -A --field-selector spec.type=LoadBalancer
```

L2-Baseline vor dem Upgrade verifizieren:

```bash
# Traefik-IP: ICMP-Timeout ist normal (UniFi/FritzBox blockiert ICMP auf VLAN 20).
# Verlässlicher Test ist HTTPS:
curl -sk https://192.168.20.100 -o /dev/null -w "%{http_code}\n"
# 404 = Traefik antwortet (kein Hostname-Match), Service ist UP

# Gitea SSH (.101) ist SSH-only, kein HTTP — Ping-Timeout ebenfalls normal

# Speaker-Logs: Announcements aktiv?
for pod in $(kubectl get pods -n metallb-system -l app.kubernetes.io/component=speaker -o name); do
  echo "=== $pod ==="
  kubectl logs -n metallb-system $pod --tail=5
done
```

Veraltete `metallb.universe.tf`-Annotations aufspüren (Migration zu `metallb.io/...` empfohlen, nicht kritisch):

```bash
kubectl get svc -A -o json | \
  jq -r '.items[] | select(.metadata.annotations | keys[] | startswith("metallb.universe.tf")) | "\(.metadata.namespace)/\(.metadata.name)"'
```

> Services ohne Annotations liefern `null` keys → jq bricht mit `null (null) has no keys` ab. Harmlos, nur Services *mit* Annotations werden erfasst.

### Phase 2: Wartungsfenster & Backup

- Upgrade-Zeitfenster: Abendstunden oder Wochenende — Speaker-Neustart bedeutet ~5–30 Sekunden L2-Ausfall auf allen betroffenen IPs (Traefik `192.168.20.100`, Gitea SSH `192.168.20.101`, ggf. Home Assistant).

```bash
# Alle MetalLB Custom Resources exportieren
kubectl get ipaddresspool,l2advertisement,bgpadvertisement,community \
  -n metallb-system -o yaml > /tmp/metallb-config-backup-$(date +%Y%m%d).yaml

# Aktuelles Helm Release sichern
helm get values metallb -n metallb-system > /tmp/metallb-helm-values-backup-$(date +%Y%m%d).yaml 2>/dev/null || true

# Git-Status prüfen
git status
git log --oneline -3
cat gitops/apps/metallb.yaml
cat gitops/config/metallb/config.yaml
```

### Phase 3: Upgrade durchführen

```bash
# Version in gitops/apps/metallb.yaml erhöhen (targetRevision), z.B.:
sed -i '' 's/targetRevision: 0.16.0/targetRevision: 0.16.1/' gitops/apps/metallb.yaml
grep targetRevision gitops/apps/metallb.yaml

git add gitops/apps/metallb.yaml
git commit -m "chore: upgrade metallb <alt> → <neu>"
git push

# Sync triggern
argocd app sync metallb
```

### Phase 4: Upgrade beobachten

```bash
kubectl get pods -n metallb-system -w
# Erwarteter Ablauf: controller-xxx Terminating → Running (neu),
# danach metallb-speaker-xxx auf allen Nodes Terminating → Running

kubectl get crds | grep metallb.io

# Versionen in laufenden Pods prüfen
kubectl get pod -n metallb-system -l app.kubernetes.io/component=controller \
  -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'
kubectl get pod -n metallb-system -l app.kubernetes.io/component=speaker \
  -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'
```

### Phase 5: Post-Upgrade Verifikation

```bash
curl -sk https://192.168.20.100 -o /dev/null -w "%{http_code}\n"          # 404 erwartet
curl -sk https://gitea.reckeweg.io/api/healthz -o /dev/null -w "%{http_code}\n"  # 200 erwartet
ssh -o ConnectTimeout=5 -p 22 git@192.168.20.101 2>&1 | head -2           # Auth-Meldung erwartet

# Speaker-Logs auf Fehler prüfen
for pod in $(kubectl get pods -n metallb-system -l app.kubernetes.io/component=speaker -o name); do
  echo "=== $pod ==="
  kubectl logs -n metallb-system $pod --tail=10 | grep -E "announ|level|error|warn" || true
done
# Kein Fehler wie "the specified interfaces used to announce LB IP don't exist"
# Interfaces enp1s0.20 (GMKTec Masters) und eth0.20 (Pi Worker) müssen erkannt werden

kubectl get l2advertisement -n metallb-system -o yaml
argocd app get metallb   # Sync Status: Synced, Health Status: Healthy
```

### Phase 6: Post-Upgrade Housekeeping

- Falls in Phase 1 veraltete `metallb.universe.tf`-Annotations gefunden wurden: in den Service-YAMLs im Repo auf `metallb.io/...` migrieren und via ArgoCD syncen (nicht direkt per `kubectl annotate`, siehe Stolperfalle zu `selfHeal`).
- PrometheusRules für MetalLB nach größeren Upgrades prüfen, da sich Alert-Level zwischen Versionen geändert haben (z.B. 0.14.9).
- Wiki-Eintrag `Cluster_Components/MetalLB` aktualisieren (Version, Upgrade-Datum).

## Bekannte Stolperfallen / Lessons Learned

- **`frrk8s.enabled=true` ist seit MetalLB 0.16.0 neuer Helm-Chart-Default** und bricht L2-Mode-Setups ohne BGP: ArgoCD schlägt beim Manifest-Rendering mit `nil pointer evaluating interface {}.serviceMonitor` fehl, weil der frr-k8s-Subchart ohne explizite Konfiguration nicht sauber rendert. **Fix:** `frrk8s.enabled: false` explizit in den Helm-Values der ArgoCD-App setzen (L2-Mode benötigt kein FRR-K8s). Entdeckt und gefixt am 2026-05-26 (Commit `da3b99c`, dokumentiert in `929c1fe`), im Rahmen des Upgrades 0.15.3 → 0.16.0. **Verifiziert:** In `gitops/apps/metallb.yaml` ist `frrk8s.enabled: false` aktuell gesetzt — Konfiguration ist korrekt und diese Stolperfalle bleibt relevant für jedes zukünftige Neuaufsetzen oder `--reuse-values`-lose Helm-Upgrades.
- Speaker meldet "interfaces don't exist" → L2Advertisement hat falsche Interface-Namen. Prüfen: `kubectl get l2advertisement -o yaml`; erwartet `enp1s0.20` für GMKTec-Nodes, `eth0.20` für Raspberry-Pi-Nodes.
- ArgoCD setzt L2Advertisement zurück, wenn `selfHeal: true` aktiv ist und manuell per `kubectl patch` geändert wurde → Änderungen immer ins Git-Repo committen, nie nur clusterseitig patchen.
- Gitea SSH (`.101`) nach Speaker-Neustart kurzzeitig tot: ARP-Cache auf Clients veraltet → `arp -d 192.168.20.101` auf dem betroffenen Client; Speaker braucht ca. 30s zum Reannouncement.
- Label-Selector-Mismatch nach Upgrade: Speaker-Pods haben 4/4 Container, aber `component=speaker`-Label wird nicht gefunden → `kubectl get pods -n metallb-system --show-labels` prüfen.
- GMKTec-Nodes ARP-Probleme (k3s-03a-Incident): `arp_announce`/`arp_ignore` falsch gesetzt → `/etc/sysctl.d/99-arp-fix.conf` auf allen Master-Nodes muss aktiv sein.
- ICMP-Ping auf die LoadBalancer-IPs (`.100`, `.101`) liefert grundsätzlich Timeout — das ist UniFi/FritzBox-ICMP-Blocking auf VLAN 20, kein MetalLB-Problem. `curl -sk https://<ip> → 404` ist der korrekte Health-Check (Traefik antwortet, nur kein Hostname-Route-Match).
- ArgoCD-UI kann während des Syncs träge/kurzzeitig nicht erreichbar sein — bekanntes Ressourcenproblem, kein MetalLB-Fehler (siehe ArgoCD-Tuning-Notizen).

## Rollback-Plan

```bash
# Sofortige Rückkehr zur vorherigen Version
sed -i '' 's/targetRevision: <neu>/targetRevision: <alt>/' gitops/apps/metallb.yaml
git add gitops/apps/metallb.yaml
git commit -m "revert: metallb zurück auf <alt> (upgrade fehlgeschlagen)"
git push

argocd app sync metallb --force
kubectl get pods -n metallb-system -w
```

Bei komplettem Ausfall (z.B. kein Git-Push wegen Gitea-Ausfall):

```bash
# ArgoCD Auto-Sync deaktivieren
kubectl patch application metallb -n argocd \
  --type='json' \
  -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'

# Direkt per Helm auf alte Version zurück (Notfall)
helm repo add metallb https://metallb.github.io/metallb
helm repo update
helm upgrade metallb metallb/metallb \
  --namespace metallb-system \
  --version <alt> \
  --reuse-values

# Danach Repo fixen, Auto-Sync wieder aktivieren
```

## Referenzen

- GitHub Releases / Release Notes: https://metallb.universe.tf/release-notes/
- MetalLB Upgrade-Doku: https://metallb.universe.tf/installation/
- Lokales Repo: `gitops/apps/metallb.yaml`, `gitops/config/metallb/config.yaml`
- Verwandtes Runbook: `docs/upgrades/traefik.md`
