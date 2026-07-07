# Upgrade Runbook: sealed-secrets

## Metadaten
- **Namespace:** `kube-system`
- **Aktuelle Version:** 2.19.1 (Helm Chart)
- **Quelle:** Helm-Chart-Repo `https://bitnami.github.io/sealed-secrets` (Chart: `sealed-secrets`); GitHub Releases: `https://github.com/bitnami/sealed-secrets/releases`
- **ArgoCD App-Name:** `sealed-secrets`
- **Versions-Check-Quelle:** homelab-version-checker vergleicht `targetRevision` in `gitops/apps/sealed-secrets.yaml` gegen die neueste Chart-Version im Helm-Repo-Index von `bitnami.github.io/sealed-secrets`
- **Major/Minor-Kriterium:** Standardregel — Patch- und Minor-Bumps (x.y.**Z**, x.**Y**.z) ohne CRD-Änderung und ohne Breaking Change in den Release Notes werden automatisch ausgeführt; Major-Bumps (**X**.y.z) und jeder Bump mit CRD- oder Verschlüsselungsformat-Änderung erfordern manuellen Eingriff.

## Changelog

| Datum | Von → Nach | Typ | Ausführung | Status | Begründung | Notiz |
|---|---|---|---|---|---|---|
| unbekannt | ... | ... | ... | ... | Historie vor Einführung des strukturierten Runbooks nicht vollständig rekonstruierbar | — |
| 2026-05-26 | 2.18.5 → 2.18.6 | Minor (Patch) | Manuell | Abgeschlossen | Patch-Release, keine CRD-Änderungen, kein Breaking Change | Erstes strukturiertes Runbook für diesen Dienst |
| 2026-06-18 | 2.18.6 → 2.19.0 | Minor | Manuell | Abgeschlossen | Repo-Migration `bitnami-labs` → `bitnami` GitHub-Org (alte Helm-Repo-URL lieferte 404); Chart-Upgrade ohne Breaking Change im gleichen Zug miterledigt | `repoURL` in `gitops/apps/sealed-secrets.yaml` von `https://bitnami-labs.github.io/sealed-secrets` auf `https://bitnami.github.io/sealed-secrets` geändert |
| 2026-07-06 | 2.19.0 → 2.19.1 | Minor | Automatisch | Abgeschlossen | Automatisches Minor-Update durch homelab-version-checker, kein Breaking-Change laut Release Notes | Teil von Commit `a7d6250` (gemeinsam mit kube-prometheus-stack 87.3.0→87.10.1); ursprünglich fälschlich als PR (#3/#4) erzeugt, dann manuell direkt auf `main` committet, da Auto-Upgrades laut Policy direkt committen sollen |

### Reklassifizierungen (Minor → Major)

| Datum Erkennung | Ursprünglicher Changelog-Eintrag (Datum) | Grund der Reklassifizierung | Erneute Benachrichtigung gesendet am |
|---|---|---|---|

## Manuelle Vorgehensweise (bei Major/Breaking Change)

### Phase 0: Repo-URL prüfen
Seit der Migration von `bitnami-labs.github.io` auf `bitnami.github.io` (2026-06-18) immer zuerst prüfen, ob `repoURL` in `gitops/apps/sealed-secrets.yaml` noch auf die aktuelle Bitnami-Org zeigt — die alte URL liefert 404 und lässt ArgoCD den Chart-Pull nicht ausführen.

```bash
grep repoURL gitops/apps/sealed-secrets.yaml
# Erwartet: https://bitnami.github.io/sealed-secrets
```

### Phase 1: Pre-Upgrade Checks

```bash
# ArgoCD Application Status
kubectl -n argocd get application sealed-secrets
# Erwartet: SYNC STATUS = Synced, HEALTH STATUS = Healthy

# Aktuelle Chart-Version im Cluster
helm list -n kube-system | grep sealed-secrets

# Controller-Pod läuft?
kubectl -n kube-system get pod -l app.kubernetes.io/name=sealed-secrets

# Alle SealedSecrets gesund?
kubectl get sealedsecrets -A
```

**Baseline: SealedSecrets entschlüsseln sich korrekt**

```bash
kubectl get secret -n gitea gitea-admin-secret -o jsonpath='{.metadata.name}'
kubectl get secret -n monitoring grafana-admin-secret -o jsonpath='{.metadata.name}'
kubectl get secret -n guacamole guacamole-db-secret -o jsonpath='{.metadata.name}'
```

**Bei Major-Upgrade zusätzlich: Private-Key-Backup anlegen**

Der Controller generiert beim ersten Start automatisch ein RSA-Keypair und speichert es als Secret `sealed-secrets-keyXXXXX` im Namespace `kube-system`. Vor jedem Major-Upgrade diesen Key sichern, da ein Verlust bedeutet, dass **alle** bestehenden SealedSecrets neu versiegelt werden müssen:

```bash
kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
  > ~/sealed-secrets-backup/master-key-$(date +%Y%m%d).yaml
```

### Phase 2: Upgrade durchführen

```bash
# Aktuellen Wert prüfen
grep targetRevision gitops/apps/sealed-secrets.yaml

# Version setzen
sed -i '' 's/targetRevision: "<ALT>"/targetRevision: "<NEU>"/' gitops/apps/sealed-secrets.yaml

# Ergebnis prüfen
grep targetRevision gitops/apps/sealed-secrets.yaml
```

Committen und pushen:

```bash
git add gitops/apps/sealed-secrets.yaml
git commit -m "chore: upgrade sealed-secrets <ALT> → <NEU>"
git push
```

ArgoCD-Sync abwarten (Auto-Sync ist aktiv, alternativ manuell anstoßen):

```bash
argocd app sync sealed-secrets

kubectl -n argocd wait application sealed-secrets \
  --for=jsonpath='{.status.sync.status}'=Synced --timeout=3m
kubectl -n argocd wait application sealed-secrets \
  --for=jsonpath='{.status.health.status}'=Healthy --timeout=3m
```

### Phase 3: Post-Upgrade Verifikation

```bash
# Controller-Version bestätigen
kubectl -n kube-system get pod -l app.kubernetes.io/name=sealed-secrets \
  -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'

helm list -n kube-system | grep sealed-secrets

# Controller-Logs — keine Fehler
kubectl -n kube-system logs deployment/sealed-secrets-controller --since=5m \
  | grep -iE "error|panic|fatal" || echo "Keine Fehler"

# Alle SealedSecrets weiterhin funktionsfähig
kubectl get sealedsecrets -A
# Kein Secret darf im Status "Failed" oder "Error" erscheinen

# Zertifikat/Key nach Major-Upgrade prüfen
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  | openssl x509 -noout -text | grep -E "Not After|Issuer"

# ArgoCD Final-Status
kubectl -n argocd get application sealed-secrets
```

## Bekannte Stolperfallen / Lessons Learned
- **Repo-Migration bitnami-labs → bitnami (2026-06-18):** Die alte Helm-Repo-URL `https://bitnami-labs.github.io/sealed-secrets` liefert 404. Muss durch `https://bitnami.github.io/sealed-secrets` ersetzt werden — betrifft `repoURL` in `gitops/apps/sealed-secrets.yaml`. Immer prüfen, ob dieser Wechsel bereits vollzogen ist, bevor ein Versions-Bump versucht wird.
- **Patch-/Minor-Releases sind unkritisch:** x.y.Z-Releases enthalten laut bisheriger Historie keine CRD-Migrationen und keine Breaking Changes. Der Master-Key und alle bestehenden SealedSecrets bleiben vollständig kompatibel — kein erneutes Versiegeln nötig.
- **Private-Key-Rotation bei Major-Upgrades beachten:** Der Controller erstellt beim allerersten Start automatisch ein RSA-Keypair (Secret `sealed-secrets-keyXXXXX`, Namespace `kube-system`). Ein Upgrade selbst rotiert diesen Key nicht automatisch — Rotation erfolgt nur explizit (z.B. via `kubeseal --re-encrypt` oder manuellem Secret-Löschen, was den Controller zur Neugenerierung zwingt). Vor jedem Major-Upgrade den Key sichern; ein unbeabsichtigter Verlust bedeutet, dass alle bestehenden SealedSecrets im Cluster neu versiegelt werden müssen, da sie nicht mehr entschlüsselbar sind.
- **Auto-Upgrade-Workflow committet direkt auf main:** Seit der Umstellung (siehe Commit `188a865`) erzeugt der homelab-version-checker für automatisch klassifizierte Minor-Updates keine PRs mehr, sondern committet direkt. Commit `a7d6250` musste die vorher fälschlich als PR (#3/#4) erzeugten Änderungen händisch nachziehen.

## Rollback-Plan
Falls nach dem Sync Probleme auftreten:

```bash
sed -i '' 's/targetRevision: "<NEU>"/targetRevision: "<ALT>"/' gitops/apps/sealed-secrets.yaml

git add gitops/apps/sealed-secrets.yaml
git commit -m "revert: sealed-secrets zurück auf <ALT>"
git push
```

ArgoCD synchronisiert automatisch zurück. Bestehende SealedSecrets sind von einem Versions-Rollback des Controllers nicht betroffen, solange der Private Key nicht rotiert/gelöscht wurde.

## Referenzen
- GitHub Releases: https://github.com/bitnami/sealed-secrets/releases
- Helm-Chart-Repo: https://bitnami.github.io/sealed-secrets
- Lokale ArgoCD App: `gitops/apps/sealed-secrets.yaml`
- Interne Doku: `gitops/sealed-secrets/sealed-secrets-doku.md`
