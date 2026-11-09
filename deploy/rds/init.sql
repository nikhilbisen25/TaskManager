-- One RDS instance, two databases, one user each (database-per-service, logically isolated).
-- Run as the RDS master user (not a true superuser) with psql variables auth_pw and task_pw:
--   psql ... -v ON_ERROR_STOP=1 -v auth_pw=... -v task_pw=... -f init.sql
-- Safe to re-run: creates what is missing and re-syncs the passwords.

-- Roles (created without a password, then ALTERed so re-runs keep them in sync with .env)
SELECT 'CREATE ROLE auth LOGIN'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'auth') \gexec
SELECT 'CREATE ROLE task LOGIN'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'task') \gexec

ALTER ROLE auth WITH LOGIN PASSWORD :'auth_pw';
ALTER ROLE task WITH LOGIN PASSWORD :'task_pw';

-- The master user must be a member of a role to create a database owned by it.
GRANT auth TO CURRENT_USER;
GRANT task TO CURRENT_USER;

-- Databases (CREATE DATABASE can't run inside a DO block, hence \gexec)
SELECT 'CREATE DATABASE authdb OWNER auth'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'authdb') \gexec
SELECT 'CREATE DATABASE taskdb OWNER task'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'taskdb') \gexec

-- Isolation: each service user can connect only to its own database.
REVOKE ALL ON DATABASE authdb FROM PUBLIC;
REVOKE ALL ON DATABASE taskdb FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE authdb TO auth;
GRANT CONNECT, TEMPORARY ON DATABASE taskdb TO task;

SELECT datname, pg_get_userbyid(datdba) AS owner
FROM pg_database WHERE datname IN ('authdb', 'taskdb') ORDER BY 1;
