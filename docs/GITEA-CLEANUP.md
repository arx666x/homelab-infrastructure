# Gitea Cleanup Runbook - Vor dem Upgrade

## Ziel
Alte kaputte Gitea ArgoCD App vollständig entfernen (cascade=true),
dabei PostgreSQL-PVC und Gitea-Data-PVC erhalten.

---

## Schritt 0: Repo auf GitHub umstellen

Da Gitea down ist, muss das lokale Git-Repo auf GitHub zeigen damit
du Änderungen pushen und ArgoCD sie lesen kann:

```bash
cd ~/workspace/homelab-infrastructure

# Remote auf GitHub umstellen
git remote set-url origin git@github.com:arx666x/homelab-infrastructure.git

# Verifizieren
git remote -v
# → origin  git@github.com:arx666x/homelab-infrastructure.git (fetch)
# → origin  git@github.com:arx666x/homelab-infrastructure.git (push)

# Aktuellen Stand pushen
git push origin main
```

---

## Schritt 1: PVCs vor ArgoCD-Löschung schützen

ArgoCD respektiert die Annotation `helm.sh/resource-policy: keep` und
lässt diese Ressourcen beim cascade-Delete unangetastet.

```bash
# PVC-Namen zuerst ermitteln
kubectl get pvc -n gitea
```

Erwartete Ausgabe (Namen können leicht abweichen):
```
NAME                              STATUS   CAPACITY
data-gitea-postgresql-0           Bound    10Gi
gitea-shared-storage              Bound    50Gi
redis-data-gitea-redis-master-0   Bound    8Gi   ← diese NICHT schützen (wird gelöscht)
```

```bash
# PostgreSQL-PVC schützen
kubectl annotate pvc data-gitea-postgresql-0 -n gitea \
  "helm.sh/resource-policy=keep" --overwrite

# Gitea-Data-PVC schützen
kubectl annotate pvc gitea-shared-storage -n gitea \
  "helm.sh/resource-policy=keep" --overwrite

# Annotation verifizieren
kubectl get pvc -n gitea -o custom-columns=\
'NAME:.metadata.name,POLICY:.metadata.annotations.helm\.sh/resource-policy'
```

Erwartete Ausgabe:
```
NAME                              POLICY
data-gitea-postgresql-0           keep
gitea                             keep
redis-data-gitea-redis-master-0   <none>
```

---

## Schritt 2: AutoSync deaktivieren (Safety-Net)

Damit ArgoCD während des Löschvorgangs keine Ressourcen neu erstellt:

```bash
kubectl patch application gitea -n argocd --type merge -p \
  '{"spec":{"syncPolicy":{"automated":null}}}'

# Verifizieren
kubectl get application gitea -n argocd -o jsonpath='{.spec.syncPolicy}' | jq .
# → sollte {} oder null sein, kein "automated" Key
```

---

## Schritt 3: Alte ArgoCD App löschen (cascade=true)

```bash
argocd app delete gitea --cascade --yes

# Falls argocd CLI nicht verfügbar, alternativ via kubectl:
kubectl delete application gitea -n argocd
# ACHTUNG: kubectl delete löscht nur die ArgoCD-App, NICHT die k8s-Ressourcen!
# In dem Fall manuell aufräumen (siehe Schritt 3b)
```

### Schritt 3b: Manuelles Aufräumen (nur wenn cascade über kubectl)

```bash
# Alles im Namespace gitea löschen, außer den geschützten PVCs
kubectl delete deployment,statefulset,replicaset -n gitea --all
kubectl delete service -n gitea --all
kubectl delete configmap -n gitea --all
kubectl delete secret -n gitea \
  --field-selector='metadata.name!=gitea-postgresql-secret,metadata.name!=gitea-admin-secret'
kubectl delete ingress -n gitea --all

# Redis-PVC explizit löschen (nicht geschützt)
kubectl delete pvc redis-data-gitea-redis-master-0 -n gitea --ignore-not-found
```

---

## Schritt 4: Verifizieren - Namespace sauber, PVCs erhalten

```bash
# Namespace sollte leer sein außer den PVCs
kubectl get all -n gitea

# PVCs müssen noch da sein
kubectl get pvc -n gitea
```

Erwartetes Ergebnis:
```
# kubectl get all -n gitea
No resources found in gitea namespace.   ← gut

# kubectl get pvc -n gitea
NAME                              STATUS   CAPACITY
data-gitea-postgresql-0           Bound    10Gi    ← erhalten
gitea-shared-storage              Bound    50Gi    ← erhalten
```

> Falls `data-gitea-postgresql-0` noch an ein gelöschtes Pod gebunden scheint
> (Status: Released statt Bound), ist das normal - der neue Pod wird sie wieder claimen.

---

## Schritt 5: Neue Secrets anlegen

Die alten Secrets wurden mit cascade=true gelöscht - neu anlegen:

```bash
cd gitops/config/gitea
chmod +x create-secrets.sh
./create-secrets.sh
```

> Verwende dieselben Credentials wie vorher (Username, Passwort, DB-Passwort),
> damit Gitea die bestehenden Daten auf den PVCs erkennt!

---

## Schritt 6: Neu deployen

Weiter mit dem Deployment-Runbook (GITEA-DEPLOYMENT.md), ab Schritt 2.

```bash
# PostgreSQL zuerst
kubectl apply -f gitops/apps/gitea/postgresql.yaml
kubectl get pods -n gitea -w
# → gitea-postgresql-0: Running 1/1

# Dann Gitea
kubectl apply -f gitops/apps/gitea/gitea.yaml
kubectl get pods -n gitea -w
```

---

## Troubleshooting: PVC im Released-Status

Falls ein PVC nach dem cascade-Delete im Status `Released` steckt
(nicht mehr Bound, aber Daten noch vorhanden):

```bash
# PVC-Status prüfen
kubectl get pvc data-gitea-postgresql-0 -n gitea -o jsonpath='{.status.phase}'

# Falls "Released": claimRef entfernen damit sie neu gebunden werden kann
kubectl patch pvc data-gitea-postgresql-0 -n gitea --type json \
  -p '[{"op":"remove","path":"/spec/claimRef"}]'
```

---

## Zusammenfassung der Reihenfolge

```
0. Repo auf GitHub umstellen
1. PVCs annotieren    (keep)
2. AutoSync aus       (patch application)
3. App löschen        (argocd app delete --cascade)
4. Namespace prüfen   (get all, get pvc)
5. Secrets neu        (create-secrets.sh)
6. Neu deployen       (GITEA-DEPLOYMENT.md ab Schritt 2)
```
