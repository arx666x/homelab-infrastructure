-- =============================================================================
-- Authentik – PostgreSQL Setup
-- Auszuführen gegen die Gitea-PostgreSQL Instanz
--
-- Gleiches Muster wie gitops/config/guacamole/postgres-setup.sql: euer
-- PostgreSQL ist ein externes StatefulSet mit postgres:16-alpine, der
-- verfügbare Admin-User ist "gitea" (hat CREATEDB-Recht, ist aber kein
-- Superuser). Anders als bei Guacamole wird das Passwort hier NICHT im
-- Klartext committed - <PASSWORD> vor der Ausführung ersetzen (z.B. mit
-- `openssl rand -base64 32`) und direkt danach per seal-all-secrets.sh
-- versiegeln, damit der Klartextwert nirgends im Repo landet.
--
-- Ausführung, z.B.:
--   kubectl exec -n gitea -it gitea-postgresql-0 -- psql -U gitea -d gitea \
--     -f - < gitops/config/authentik/postgres-setup.sql
-- =============================================================================

CREATE USER authentik WITH PASSWORD '<PASSWORD>';
CREATE DATABASE authentik OWNER authentik;
GRANT ALL PRIVILEGES ON DATABASE authentik TO authentik;
