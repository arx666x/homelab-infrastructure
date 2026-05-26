# Sealed Secrets Upgrade Runbook: Chart 2.18.5 → 2.18.6

**Datum:** 2026-05-26  
**Scope:** Homelab k3s-Cluster (`reckeweg.io`)  
**Namespace:** `kube-system`  
**Von:** Helm Chart 2.18.5  
**Auf:** Helm Chart 2.18.6  
**Risiko:** 🟢 Niedrig — Patch-Release, keine CRD-Änderungen, kein Breaking Change  
**Deployment-Methode:** ArgoCD GitOps (`gitops/apps/sealed-secrets.yaml`)

---

## Übersicht

| | |
|---|---|
| **Ausgangsversion** | 2.18.5 |
| **Zielversion** | 2.18.6 |
| **Upgrade-Strategie** | Direkter Patch → Git-Commit → ArgoCD Auto-Sync |
| **ArgoCD Application** | `sealed-secrets` |
| **Controller** | `sealed-secrets-controller` |
| **Downtime** | Sekunden — kurzes Controller-Neustart-Fenster; bestehende SealedSecrets bleiben entschlüsselt im Cluster |

> **Hinweis:** Patch-Releases (x.y.**Z**) im Sealed-Secrets-Projekt enthalten keine CRD-Migrationen und keine Breaking Changes. Der Master Key und alle bestehenden SealedSecrets bleiben vollständig kompatibel — kein erneutes Versiegeln nötig.

---

## Phase 1: Pre-Upgrade Checks

### 1.1 Aktuellen Zustand prüfen

```bash
# ArgoCD Application Status
kubectl -n argocd get application sealed-secrets
# Erwartet: SYNC STATUS = Synced, HEALTH STATUS = Healthy

# Aktuelle Chart-Version im Cluster
helm list -n kube-system | grep sealed-secrets
# Erwartet: sealed-secrets  ...  2.18.5

# Controller-Pod läuft?
kubectl -n kube-system get pod -l app.kubernetes.io/name=sealed-secrets

# Alle SealedSecrets gesund?
kubectl get sealedsecrets -A
```

### 1.2 Baseline: SealedSecrets entschlüsseln sich korrekt

```bash
# Kurzer Check: Secrets aus SealedSecrets vorhanden?
kubectl get secret -n gitea gitea-admin-secret -o jsonpath='{.metadata.name}'
kubectl get secret -n monitoring grafana-admin-secret -o jsonpath='{.metadata.name}'
kubectl get secret -n guacamole guacamole-db-secret -o jsonpath='{.metadata.name}'
```

---

## Phase 2: Upgrade durchführen

### 2.1 `targetRevision` erhöhen

```bash
# Aktuellen Wert prüfen
grep targetRevision gitops/apps/sealed-secrets.yaml
# Erwartet: targetRevision: "2.18.5"

# Version setzen
sed -i '' 's/targetRevision: "2.18.5"/targetRevision: "2.18.6"/' gitops/apps/sealed-secrets.yaml

# Ergebnis prüfen
grep targetRevision gitops/apps/sealed-secrets.yaml
# Erwartet: targetRevision: "2.18.6"
```

### 2.2 Committen und pushen

```bash
git add gitops/apps/sealed-secrets.yaml
git commit -m "chore: upgrade sealed-secrets 2.18.5 → 2.18.6"
git push
```

### 2.3 ArgoCD-Sync abwarten

ArgoCD syncronisiert automatisch (Auto-Sync ist aktiv). Alternativ manuell anstoßen:

```bash
argocd app sync sealed-secrets

# Warten bis Synced + Healthy
kubectl -n argocd wait application sealed-secrets \
  --for=jsonpath='{.status.sync.status}'=Synced --timeout=3m
kubectl -n argocd wait application sealed-secrets \
  --for=jsonpath='{.status.health.status}'=Healthy --timeout=3m
```

---

## Phase 3: Post-Upgrade Verifikation

### 3.1 Controller-Version bestätigen

```bash
kubectl -n kube-system get pod -l app.kubernetes.io/name=sealed-secrets \
  -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'
# Erwartet: docker.io/bitnami/sealed-secrets:v0.x.y (entspricht Chart 2.18.6)

helm list -n kube-system | grep sealed-secrets
# CHART-Spalte muss sealed-secrets-2.18.6 zeigen
```

### 3.2 Controller-Logs — keine Fehler

```bash
kubectl -n kube-system logs deployment/sealed-secrets-controller --since=5m \
  | grep -iE "error|panic|fatal" || echo "Keine Fehler"
```

### 3.3 SealedSecrets weiterhin funktionsfähig

```bash
# Alle SealedSecrets im Status prüfen
kubectl get sealedsecrets -A
# Kein Secret darf im Status "Failed" oder "Error" erscheinen

# Probe: ein Secret erneut per kubeseal validieren (optional)
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  | openssl x509 -noout -text | grep -E "Not After|Issuer"
# Certificate muss valide und nicht abgelaufen sein
```

### 3.4 ArgoCD Final-Status

```bash
kubectl -n argocd get application sealed-secrets
# SYNC STATUS:   Synced
# HEALTH STATUS: Healthy
```

---

## Rollback

Falls nach dem Sync Probleme auftreten:

```bash
sed -i '' 's/targetRevision: "2.18.6"/targetRevision: "2.18.5"/' gitops/apps/sealed-secrets.yaml

git add gitops/apps/sealed-secrets.yaml
git commit -m "revert: sealed-secrets zurück auf 2.18.5"
git push
```

ArgoCD syncronisiert automatisch zurück. Bestehende SealedSecrets sind von einem Versions-Rollback des Controllers nicht betroffen.

---

## Durchgeführte Upgrades

| Datum | Von | Auf | Ergebnis | Besonderheiten |
|---|---|---|---|---|
| 2026-05-26 | 2.18.5 | 2.18.6 | ✅ Erfolgreich | Patch-Release, kein erneutes Versiegeln nötig |

---

## Referenzen

- [Sealed Secrets GitHub Releases](https://github.com/bitnami-labs/sealed-secrets/releases)
- [Sealed Secrets Helm Chart (Bitnami Labs)](https://bitnami-labs.github.io/sealed-secrets)
- Lokale ArgoCD App: `gitops/apps/sealed-secrets.yaml`
- Betriebshandbuch: `gitops/sealed-secrets/sealed-secrets-doku.md`
