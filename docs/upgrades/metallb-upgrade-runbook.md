# MetalLB Upgrade Runbook: Chart 0.16.0 → 0.16.1

**Datum:** 2026-06-14  
**Status:** ✅ Erfolgreich abgeschlossen am 2026-06-14  
**Scope:** Homelab k3s-Cluster (`reckeweg.io`)  
**Namespace:** `metallb-system`  
**Von:** Helm Chart 0.16.0 / MetalLB v0.16.0  
**Auf:** Helm Chart 0.16.1 / MetalLB v0.16.1  
**Risiko:** 🟢 Niedrig — reiner Patch-Release, keine Breaking Changes, kurzer L2-Ausfall während Speaker-Neustart  
**Deployment-Methode:** ArgoCD GitOps, Multi-Source App (`gitops/apps/metallb.yaml`)

---

## Wichtige Hinweise vorab

### Was sich in 0.16.1 ändert

Reiner Patch-Release — keine Breaking Changes, keine CRD-Änderungen.

#### Fixes (alle Umgebungen)

- **Helm Chart Rendering Fix** — Korrektur bei der Verarbeitung von Default-Values
- **BGPPeer Schema** — `localASN` Feld auf `int64` korrigiert (war `int32`), ermöglicht volle 32-Bit ASN-Range (nicht relevant für L2-Mode)
- **Health Probes** — Endpoints lauschen jetzt standardmäßig auf allen Interfaces
- **Metriken TLS** — PodMonitor/ServiceMonitor und Pod-Annotations setzen jetzt korrekt `scheme: https` (Nachbesserung zum HTTPS-only Metriken-Endpoint aus 0.16.0)

- **Speaker-Neustart bedeutet ~5–30 Sekunden L2-Ausfall** auf den betroffenen IPs. Traefik (`192.168.20.100`) und Gitea SSH (`192.168.20.101`) sind kurz nicht erreichbar.

### Deine Konfiguration

```
MetalLB IP Pool:    192.168.20.50 – 192.168.20.120
Traefik LB:         192.168.20.100
Gitea SSH LB:       192.168.20.101
Interface:          enp1s0.20 (GMKTec Master-Nodes, VLAN 20)
                    eth0.20  (Raspberry Pi Worker-Nodes)
L2Advertisement:    Eigene Ressource in config.yaml
ArgoCD App:         gitops/apps/metallb.yaml
Config:             gitops/config/metallb/config.yaml
```

---

## Phase 1: Pre-Upgrade Checks

### 1.1 Status quo prüfen

```bash
# ArgoCD App Status
argocd app get metallb

# Aktuelle Version bestätigen
kubectl -n argocd get application metallb \
  -o jsonpath='{.spec.sources[0].targetRevision}{"\n"}'
# Erwartung: 0.16.0
# Hinweis: .spec.source (singular) liefert leer bei Multi-Source Apps!

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

### 1.2 L2 Announcements verifizieren (Baseline)

```bash
# Traefik IP erreichbar?
ping -c 3 192.168.20.100
# HINWEIS: ICMP-Timeouts sind normal (UniFi/FritzBox blockiert ICMP auf VLAN 20)
# Verlässlicher Test: curl -sk https://192.168.20.100 -o /dev/null -w "%{http_code}
"
# 404 = Traefik antwortet (kein Hostname-Match), Service ist UP

# Gitea SSH erreichbar?
ping -c 3 192.168.20.101
# .101 ist SSH-only, kein HTTP — Ping-Timeout hier ebenfalls normal

# Speaker-Logs: Announcements aktiv?
for pod in $(kubectl get pods -n metallb-system -l app.kubernetes.io/component=speaker -o name); do
  echo "=== $pod ==="
  kubectl logs -n metallb-system $pod --tail=5
done
```

### 1.3 Annotation-Check: Gibt es veraltete `metallb.universe.tf` Annotations?

```bash
# Services mit altem Annotation-Prefix prüfen
kubectl get svc -A -o json | \
  jq -r '.items[] | select(.metadata.annotations | keys[] | startswith("metallb.universe.tf")) | "\(.metadata.namespace)/\(.metadata.name)"'
```

Wenn Treffer → diese Services nach dem Upgrade auf `metallb.io/...` migrieren (nicht kritisch, aber empfohlen).

> **Bekannter jq-Fehler:** Services ohne Annotations liefern `null` keys → jq bricht mit `null (null) has no keys` ab.
> Das ist harmlos — Fehlermeldung ignorieren, nur Services *mit* Annotations werden geprüft.

---

## Phase 2: Wartungsfenster & Backup

### 2.1 Zeitpunkt

- Upgrade-Zeitfenster: **Abendstunden oder Wochenende** (kurzer L2-Ausfall!)
- Betroffene Services während Speaker-Neustart (~30 Sekunden):
  - Traefik IngressRoutes (alle Webseiten)
  - Gitea SSH Push/Pull
  - Home Assistant (falls extern angebunden)

### 2.2 Aktuelle Konfiguration sichern

```bash
# Alle MetalLB Custom Resources exportieren
kubectl get ipaddresspool,l2advertisement,bgpadvertisement,community \
  -n metallb-system -o yaml > /tmp/metallb-config-backup-$(date +%Y%m%d).yaml

# Aktuelles Helm Release sichern
helm get values metallb -n metallb-system > /tmp/metallb-helm-values-backup-$(date +%Y%m%d).yaml 2>/dev/null || true

cat /tmp/metallb-config-backup-$(date +%Y%m%d).yaml
```

### 2.3 Git-Status prüfen

```bash
cd ~/git/homelab-infrastructure

# Sauber? Kein Dirty-State?
git status
git log --oneline -3

# Aktuelle metallb ArgoCD App anzeigen
cat gitops/apps/metallb.yaml
cat gitops/config/metallb/config.yaml
```

---

## Phase 3: Upgrade durchführen

### 3.1 targetRevision erhöhen

```bash
cd ~/git/homelab-infrastructure

# Aktuelle Version prüfen
grep targetRevision gitops/apps/metallb.yaml

# Version von 0.16.0 auf 0.16.1 setzen
sed -i '' 's/targetRevision: 0.16.0/targetRevision: 0.16.1/' gitops/apps/metallb.yaml

# Ergebnis prüfen
grep targetRevision gitops/apps/metallb.yaml
# Erwartung: targetRevision: 0.16.1
```

### 3.2 Committen und pushen

```bash
git add gitops/apps/metallb.yaml
git commit -m "chore: upgrade metallb 0.16.0 → 0.16.1

Patch release: Helm chart rendering fix, BGPPeer localASN int64 correction,
health probes all-interface binding, metrics TLS scheme fix"

git push
```

### 3.3 ArgoCD Sync triggern

```bash
# Sync triggern (ArgoCD CLI)
argocd app sync metallb

# Alternativ: ArgoCD UI → metallb App → Sync
```

---

## Phase 4: Upgrade beobachten

### 4.1 Rollout verfolgen

```bash
# Pod-Status in Echtzeit
kubectl get pods -n metallb-system -w

# Erwarteter Ablauf:
# 1. controller-xxx  → Terminating → Running (neu)
# 2. metallb-speaker-xxx (alle Nodes) → Terminating → Running

# Alle Pods müssen READY sein
kubectl get pods -n metallb-system
```

### 4.2 CRDs nach Upgrade prüfen

```bash
# Alle MetalLB CRDs
kubectl get crds | grep metallb.io
# Erwartet (unverändert gegenüber 0.15.x):
# bfdprofiles.metallb.io
# bgpadvertisements.metallb.io
# bgppeers.metallb.io              <-- localASN Feld hinzugekommen (kein Breaking Change)
# communities.metallb.io
# configurationstates.metallb.io
# ipaddresspools.metallb.io
# l2advertisements.metallb.io
# servicebgpstatuses.metallb.io
# servicel2statuses.metallb.io
```

### 4.3 Version in Pods prüfen

```bash
# Controller-Version
kubectl get pod -n metallb-system -l app.kubernetes.io/component=controller \
  -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'
# Erwartung: quay.io/metallb/controller:v0.16.1

# Speaker-Version
kubectl get pod -n metallb-system -l app.kubernetes.io/component=speaker \
  -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'
# Erwartung: quay.io/metallb/speaker:v0.16.1
```

---

## Phase 5: Post-Upgrade Verifikation

### 5.1 L2 Connectivity testen

```bash
# Traefik IP — ping liefert Timeout (ICMP geblockt), HTTPS ist der richtige Test
curl -sk https://192.168.20.100 -o /dev/null -w "%{http_code}
"
# → 404 = Traefik antwortet (kein Route-Match ohne Hostname = OK)
curl -sk https://gitea.reckeweg.io/api/healthz -o /dev/null -w "%{http_code}
"
# → 200

# Gitea SSH IP (.101 ist SSH-only)
ssh -o ConnectTimeout=5 -p 22 git@192.168.20.101 2>&1 | head -2
# → "Hi achim! You have successfully authenticated" = OK

# HTTPS Test
curl -sk https://gitea.reckeweg.io/api/healthz | jq .
curl -sk https://homeassistant.reckeweg.io -o /dev/null -w "%{http_code}\n"
```

### 5.2 Speaker Announcements prüfen

```bash
# Alle Speaker-Logs (letzte Zeilen)
for pod in $(kubectl get pods -n metallb-system -l app.kubernetes.io/component=speaker -o name); do
  echo "=== $pod ==="
  kubectl logs -n metallb-system $pod --tail=10 | grep -E "announ|level|error|warn" || true
done

# Keine Fehler wie "the specified interfaces used to announce LB IP don't exist"
# → Interfaces enp1s0.20 (GMKTec) und eth0.20 (Pi) müssen erkannt werden
```

### 5.3 L2Advertisement Interface-Config prüfen

```bash
# Interfaces korrekt gesetzt?
kubectl get l2advertisement -n metallb-system -o yaml
# spec.interfaces muss enp1s0.20 enthalten (GMKTec Masters)
# Falls eth0.20 auch drin war: prüfen ob noch gesetzt
```

### 5.4 Native TLS Metriken-Endpoint prüfen (NEU in 0.16.0)

```bash
# kube-rbac-proxy ist nicht mehr vorhanden — stattdessen self-signed TLS
# Controller und Speaker lauschen direkt auf Port 9120 (HTTPS)
kubectl get pods -n metallb-system -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}{end}'
# Kein "kube-rbac-proxy" Container mehr erwartet

# ConfigurationState prüfen
kubectl get configurationstate -n metallb-system -o yaml 2>/dev/null || echo "CRD not yet present"

# IP Pool Status
kubectl get ipaddresspool -n metallb-system -o yaml
```

### 5.5 ArgoCD Status

```bash
argocd app get metallb
# Sync Status: Synced
# Health Status: Healthy
```

---

## Phase 6: Post-Upgrade Housekeeping

### 6.1 Annotation-Migration (optional, empfohlen)

Falls in Phase 1.3 veraltete `metallb.universe.tf` Annotations gefunden wurden:

```bash
# Beispiel: Service mit altem Prefix patchen
kubectl annotate svc <SERVICE_NAME> -n <NAMESPACE> \
  metallb.io/address-pool=<POOL_NAME> \
  metallb.universe.tf/address-pool-  # Minus = löschen
```

Bei deiner GitOps-Struktur: Annotations in den Service-YAMLs im Repo direkt anpassen und via ArgoCD syncen.

### 6.2 Prometheus Rules (falls kube-prometheus-stack aktiv)

MetalLB 0.14.9 änderte die Standard-Alert-Levels. Nach 0.15.x prüfen ob Alerts noch feuern:

```bash
# PrometheusRules für MetalLB
kubectl get prometheusrule -n metallb-system

# Grafana: MetalLB Dashboard aufrufen falls vorhanden
```

### 6.3 Wiki-Eintrag aktualisieren

In Gitea-Wiki: `Cluster_Components/MetalLB` → Version auf 0.16.1 setzen, Upgrade-Datum eintragen.

---

## Rollback-Plan

Falls nach dem Sync Probleme auftreten (L2 bricht komplett ein):

```bash
# Sofortige Rückkehr zu 0.16.0
cd ~/git/homelab-infrastructure
sed -i '' 's/targetRevision: 0.16.1/targetRevision: 0.16.0/' gitops/apps/metallb.yaml
git add gitops/apps/metallb.yaml
git commit -m "revert: metallb zurück auf 0.16.0 (upgrade fehlgeschlagen)"
git push

# ArgoCD Sync erzwingen
argocd app sync metallb --force

# Warten bis Speaker wieder Running
kubectl get pods -n metallb-system -w
```

Bei komplettem Ausfall (kein Git-Push wegen Gitea-Ausfall):

```bash
# ArgoCD Auto-Sync deaktivieren
kubectl patch application metallb -n argocd \
  --type='json' \
  -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'

# Direkt auf 0.16.0 helm upgrade (Notfall)
helm repo add metallb https://metallb.github.io/metallb
helm repo update
helm upgrade metallb metallb/metallb \
  --namespace metallb-system \
  --version 0.16.0 \
  --reuse-values

# Danach Repo fixen, Auto-Sync wieder aktivieren
```

---

## Bekannte Fallstricke (aus früheren Sessions)

| Problem | Ursache | Fix |
|---|---|---|
| Speaker meldet "interfaces don't exist" | L2Advertisement hat falsche Interface-Namen | `kubectl get l2advertisement -o yaml` prüfen; `enp1s0.20` für GMKTec, `eth0.20` für Pi |
| ArgoCD setzt L2Advertisement zurück | `selfHeal: true` überschreibt manuelle Patches | Änderungen immer ins Git-Repo committen, nie nur `kubectl patch` |
| Gitea SSH (.101) nach Speaker-Neustart tot | ARP-Cache auf Clients veraltet | `arp -d 192.168.20.101` auf dem betroffenen Client; Speaker braucht ~30s |
| Speaker 4/4 Container, aber `component=speaker` Label nicht gefunden | Label-Selector-Mismatch nach Upgrade | `kubectl get pods -n metallb-system --show-labels` prüfen |
| GMKTec-Nodes ARP-Probleme (k3s-03a Incident) | `arp_announce`/`arp_ignore` falsch | `/etc/sysctl.d/99-arp-fix.conf` auf Masters muss aktiv sein |
| ArgoCD: `nil pointer evaluating interface {}.serviceMonitor` | In 0.16.0 ist `frrk8s.enabled: true` jetzt Default; frr-k8s Subchart schlägt fehl | `frrk8s.enabled: false` in Helm-Values der ArgoCD App setzen (L2-Mode braucht kein FRR-K8s) |

---

## Durchgeführte Upgrades

| Datum | Von | Auf | Ergebnis | Besonderheiten |
|---|---|---|---|---|
| 2026-05-04 | 0.14.8 | 0.15.3 | ✅ Erfolgreich | Alle 9 Speaker neu gestartet, 2 neue CRDs, kein L2-Ausfall bemerkt |
| 2026-05-26 | 0.15.3 | 0.16.0 | ✅ Erfolgreich | Maintenance-Upgrade, kein L2-Ausfall bemerkt |
| 2026-06-14 | 0.16.0 | 0.16.1 | ✅ Erfolgreich | Patch-Release, problemlos |

**Beobachtungen beim Upgrade 0.14.8 → 0.15.3:**
- ArgoCD hat CRDs automatisch korrekt aktualisiert (kein manueller Schritt nötig)
- RBAC-Meldungen in ArgoCD ("missing rules added") sind kein Fehler — dokumentiert neue Permissions für `ConfigurationState`
- Speaker-Logs zeigen `BGPPeer: storage is (re)initializing` → harmlos (L2-Mode, kein BGP aktiv)
- ICMP-Ping auf `.100` liefert Timeout — das ist UniFi/FritzBox ICMP-Blocking, kein MetalLB-Problem
- `curl -sk https://192.168.20.100 → 404` = korrekt (Traefik antwortet, kein Hostname-Route-Match)
- ArgoCD UI war während Sync träge/nicht erreichbar → bekanntes Ressourcenproblem (siehe ArgoCD-Tuning-Notizen)

**Beobachtungen beim Upgrade 0.15.3 → 0.16.0:**
- Reines Maintenance-Upgrade für L2-Mode — keine CRD-Breaking-Changes
- Native TLS ersetzt kube-rbac-proxy (kein `kube-rbac-proxy` Container mehr in Pods)
- FRR 10.5.3 Update transparent im Hintergrund
- L2-Announcements sofort nach Speaker-Neustart wieder aktiv

**Beobachtungen beim Upgrade 0.16.0 → 0.16.1:**
- Patch-Release, keinerlei Probleme
- Kein manueller Eingriff nötig

---

## Referenzen

- [MetalLB Release Notes 0.15.x](https://metallb.universe.tf/release-notes/)
- [MetalLB Upgrade Docs](https://metallb.universe.tf/installation/)
- Lokales Repo: `gitops/apps/metallb.yaml`
- Lokale Config: `gitops/config/metallb/config.yaml`
- Verwandtes Runbook: `traefik-upgrade-runbook.md`
