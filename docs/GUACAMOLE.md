# Guacamole 1.6.0

Browser-basierter Remote-Access Gateway (SSH / RDP / VNC) für das SERI k3s Cluster.

## Übersicht

```
gitops/apps/guacamole.yaml                  ← ArgoCD Application
gitops/config/guacamole/
  kustomization.yaml
  namespace.yaml
  guacd.yaml                                ← Protokoll-Daemon (RDP/VNC/SSH → WebSocket)
  guacamole.yaml                            ← Java-Webapp + init-schema InitContainer
  ingressroute.yaml                         ← Traefik IngressRoute + Root-Redirect
  create-secrets.sh                         ← Secrets anlegen (NICHT in Git committen)
  README.md
```

## Auth-Phasen

| Phase | Auth          | Aktivierung                          |
|-------|---------------|--------------------------------------|
| 1     | Lokales Login | Sofort – `guacadmin` / `guacadmin`   |
| 2     | Keycloak OIDC | `OPENID_ENABLED=true` in guacamole.yaml |

## Architektur

```
Browser → Traefik → guacamole (Java-Webapp, :8080)
                         ↓ Auth (Phase 1: lokal / Phase 2: Keycloak OIDC)
                      PostgreSQL  ← Verbindungsdefinitionen, User, Audit-Log
                         ↓
                      guacd (:4822)  ← Protokoll-Proxy
                         ↓
                    SSH / RDP / VNC Ziel
```

PostgreSQL speichert: User-Accounts, Verbindungsdefinitionen, Berechtigungen,
Session-History. Erwartete Datenmenge: dauerhaft unter 10 MB.
Eine eigene PostgreSQL-Instanz ist nicht nötig – einfach eine neue Datenbank
in der bestehenden Gitea-PostgreSQL anlegen.

---

## Phase 1: Standalone (lokales Login)

### 1. PostgreSQL – Datenbank anlegen

```bash
# Achtung: die Postgres Installation die mit Gitea erfolgt, legt KEINEN user/role postgres an.
# Verwende de gitea user.

kubectl exec -it -n gitea <pg-pod> -- psql -U gitea -d gitea < postgres-setup.sql
```

```sql
-- =============================================================================
-- Guacamole – PostgreSQL Setup
-- Ausführen gegen die Gitea-PostgreSQL Instanz
--
-- Euer PostgreSQL ist ein externes StatefulSet mit postgres:16-alpine.
-- Der verfügbare Admin-User ist "gitea" (nicht "postgres").
-- Der "gitea" User hat CREATEDB-Rechte, aber ist kein Superuser.
-- Daher: Datenbank mit dem gitea-User anlegen.
-- =============================================================================

CREATE USER guacamole WITH PASSWORD 'ChaneMe';
CREATE DATABASE guacamole OWNER guacamole;
GRANT ALL PRIVILEGES ON DATABASE guacamole TO guacamole;
```


oder direkt als OneLiner:
```bash
kubectl exec -it -n gitea gitea-postgresql-0 -- \
  psql -U gitea -d gitea \
  -c "CREATE USER guacamole WITH PASSWORD '<passwort>';" \
  -c "CREATE DATABASE guacamole OWNER guacamole;" \
  -c "GRANT ALL PRIVILEGES ON DATABASE guacamole TO guacamole;"
```  



### 2. Secrets anlegen

```bash
bash gitops/config/guacamole/create-secrets.sh
```

Das Script fragt interaktiv nach dem DB-Passwort und optional nach OIDC-Werten.

Oder manuell:

```bash
kubectl create secret generic guacamole-db-secret \
  --namespace guacamole \
  --from-literal=hostname="gitea-postgresql.gitea.svc.cluster.local" \
  --from-literal=database="guacamole" \
  --from-literal=username="guacamole" \
  --from-literal=password="<passwort>"
```

### 3. ArgoCD-App deployen

```bash
kubectl apply -f gitops/apps/guacamole.yaml
```

### 4. Erster Login

URL: https://guacamole.reckeweg.io/guacamole/
Credentials: `guacadmin` / `guacadmin`
**→ Sofort Passwort ändern!**

---

## Phase 2: Keycloak OIDC (später aktivieren)

### Keycloak-Client anlegen

1. Clients → Create client
   - Client ID: `guacamole`
   - Client type: `OpenID Connect`
2. Capability config:
   - Standard flow: aktiviert
   - Implicit flow: aktiviert ← von Guacamole 1.6 noch benötigt
3. Login settings:
   - Valid redirect URIs: `https://guacamole.reckeweg.io/guacamole/*`
   - Web origins: `https://guacamole.reckeweg.io`
4. Client Scopes → Add mapper:
   - Mapper type: `Group Membership`
   - Token Claim Name: `groups`
   - Full group path: deaktiviert

### OIDC-Secret anlegen

```bash
# Alle Endpoints auf einen Blick:
curl https://keycloak.reckeweg.io/realms/seri/.well-known/openid-configuration | jq .

kubectl create secret generic guacamole-oidc-secret \
  --namespace guacamole \
  --from-literal=issuer="https://keycloak.reckeweg.io/realms/seri" \
  --from-literal=authorization_endpoint="https://keycloak.reckeweg.io/realms/seri/protocol/openid-connect/auth" \
  --from-literal=jwks_endpoint="https://keycloak.reckeweg.io/realms/seri/protocol/openid-connect/certs" \
  --from-literal=client_id="guacamole" \
  --from-literal=redirect_uri="https://guacamole.reckeweg.io/guacamole/"
```

### OIDC aktivieren

In `gitops/config/guacamole/guacamole.yaml`:

```yaml
- name: OPENID_ENABLED
  value: "true"   # war: "false"
```

Committen + pushen → ArgoCD synct automatisch.

> **Fallback:** Bei Problemen `OPENID_ENABLED=false` setzen →
> lokales `guacadmin`-Login ist sofort wieder aktiv.

### Gruppen-basierte Verbindungsrechte

1. Gruppe in Keycloak anlegen, z.B. `guac-admins`
2. Gleiche Gruppe in Guacamole anlegen (Settings → Groups)
3. Der Gruppe Verbindungen zuweisen
4. User in Keycloak der Gruppe hinzufügen → beim nächsten Login automatisch zugewiesen

---

## Verbindungs-Typen

| Protokoll | Port | Typische Ziele                           |
|-----------|------|------------------------------------------|
| SSH       | 22   | k3s Nodes (192.168.11.x / 192.168.20.x) |
| RDP       | 3389 | Windows Server 2025 VM (KubeVirt)        |
| VNC       | 5900 | Beliebige Linux-Desktops                 |
