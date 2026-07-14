# cert-distribution

Verteilt das von `cert-manager` ausgestellte Wildcard-Zertifikat (`*.reckeweg.io`)
an Geräte außerhalb des Clusters. Konzept und Schritt-für-Schritt-Anleitung:

- [`docs/myhomeismycastle-cert-distribution-konzept.md`](../../../docs/myhomeismycastle-cert-distribution-konzept.md)
- [`docs/myhomeismycastle-cert-distribution-runbook.md`](../../../docs/myhomeismycastle-cert-distribution-runbook.md)

## Dateien

| Datei | Zweck |
|---|---|
| `certificate.yaml` | Wildcard-`Certificate` (RSA-2048, `letsencrypt-prod`) |
| `rbac.yaml` | ServiceAccount + Role, nur Lesezugriff auf das eine Wildcard-Secret |
| `scripts-configmap.yaml` | Deploy-Logik (`common.sh`, `deploy-dsm.sh`, `deploy-truenas.sh`) |
| `cronjob.yaml` | Täglicher CronJob, der die Deploy-Scripts ausführt |
| `remote-scripts/truenas-cert-deploy.sh` | Läuft AUF der TrueNAS-Box, manuell installiert (siehe Runbook) |
| `sealed-secret-ssh-key.yaml` | SealedSecret mit dem TrueNAS-SSH-Private-Key |
| `sealed-secret-dsm-credentials.yaml` | **Existiert erst, nachdem der Nutzer `seal-all-secrets.sh` ausgeführt hat** – siehe Runbook |

## Secrets, die NICHT automatisch reproduzierbar sind

- **`cert-distributor-ssh-key`**: Keypair wurde einmalig generiert und offline
  versiegelt. Rotation: Anleitung im Kommentarblock in
  `gitops/sealed-secrets/seal-all-secrets.sh` (Abschnitt "CERT-DISTRIBUTION").
  Der Public Key muss nach jeder Rotation neu in `authorized_keys` auf der
  TrueNAS-Box hinterlegt werden.
- **`cert-distributor-dsm-credentials`**: Muss der Nutzer selbst erzeugen
  (`seal-all-secrets.sh` fragt Username/Passwort interaktiv ab, Klartext
  verlässt nie die lokale Shell). Voraussetzung: DSM-Service-Account existiert
  bereits (manueller Schritt, siehe Runbook).

Bis beide Secrets im Cluster existieren, schlägt der CronJob beim Job-Run mit
einem Volume-Mount-Fehler fehl - das ist erwartet und kein Grund zur Sorge.
