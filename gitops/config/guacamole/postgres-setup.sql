-- =============================================================================
-- Guacamole – PostgreSQL Setup
-- Ausführen gegen die Gitea-PostgreSQL Instanz
--
-- Euer PostgreSQL ist ein externes StatefulSet mit postgres:16-alpine.
-- Der verfügbare Admin-User ist "gitea" (nicht "postgres").
-- Der "gitea" User hat CREATEDB-Rechte, aber ist kein Superuser.
-- Daher: Datenbank mit dem gitea-User anlegen.
-- =============================================================================

CREATE USER guacamole WITH PASSWORD 'cniAjhqBc6XG9tU*7ycM';
CREATE DATABASE guacamole OWNER guacamole;
GRANT ALL PRIVILEGES ON DATABASE guacamole TO guacamole;
