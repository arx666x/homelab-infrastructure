# Home Assistant – GitOps Deployment

## Dateistruktur im Repo

```
gitops/
├── apps/
│   └── homeassistant.yaml          # ArgoCD Application (wird von root-infrastructure gescannt)
└── config/
    └── homeassistant/
        ├── kustomization.yaml
        ├── namespace.yaml
        ├── pvc.yaml                # Longhorn PVC, 5Gi für /config
        ├── deployment.yaml         # HA Container, strategy: Recreate
        ├── service.yaml            # ClusterIP :8123
        ├── certificate.yaml        # cert-manager Certificate → homeassistant-tls Secret
        ├── ingressroute.yaml       # Traefik, homeassistant.reckeweg.io
        ├── sealed-secret.yaml      # Generische Secrets (ggf. leer/auskommentiert)
        └── sealed-secret-ccu.yaml  # CCU-spezifische Secrets
```

## Pi-hole DNS

Eintrag für `homeassistant.reckeweg.io` → MetalLB IP des Traefik IngressControllers.

```bash
# Traefik-IP ermitteln:
kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

## Migration vom HA Backup

1. Commit + Push → ArgoCD deployed HA mit leerem `/config`
2. Pod-Namen ermitteln:
   ```bash
   kubectl get pods -n homeassistant
   ```
3. Backup in den Pod kopieren:
   ```bash
   kubectl cp homeassistant-backup.tar.gz \
     homeassistant/<pod-name>:/config/homeassistant-backup.tar.gz
   ```
4. Im Pod entpacken:
   ```bash
   kubectl exec -n homeassistant -it <pod-name> -- bash
   cd /config && tar xzf homeassistant-backup.tar.gz --strip-components=1
   rm homeassistant-backup.tar.gz
   exit
   ```
5. Pod neu starten:
   ```bash
   kubectl rollout restart deployment/homeassistant -n homeassistant
   ```

## Wichtig: trusted_proxies in configuration.yaml

Da HA hinter Traefik läuft, muss dies in `/config/configuration.yaml` eingetragen sein:

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 10.42.0.0/16    # Pod CIDR (k3s default)
    - 192.168.20.0/24 # VLAN 20 Kubernetes
```

Ohne diesen Eintrag blockiert HA externe Logins und loggt Warnungen.

## Sealed Secrets

Falls HA-spezifische Secrets benötigt werden (z.B. für Integrationen):

```bash
# Secret erstellen und sealen:
kubectl create secret generic homeassistant-secrets \
  --namespace homeassistant \
  --from-literal=MY_SECRET=value \
  --dry-run=client -o yaml \
  | kubeseal --format yaml > gitops/config/homeassistant/sealed-secret.yaml

# Dann in kustomization.yaml einkommentieren:
# - sealed-secret.yaml
```

## Update-Strategie

HA released sehr häufig neue Versionen. Image-Tag in `deployment.yaml` manuell bumpen:

```yaml
image: ghcr.io/home-assistant/home-assistant:2025.X.Y
```

Neue Versionen: https://github.com/home-assistant/core/releases

> **Kein `latest`-Tag verwenden** – ArgoCD würde keinen neuen Rollout triggern
> da sich der Tag nicht ändert.

Upgrade-Runbook: [docs/upgrades/homeassistant.md](upgrades/homeassistant.md)
