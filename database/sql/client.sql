-- Gives one client its own login role and database on neves-labs-pg.
--
-- Normally run on a host in the client's account through database/bootstrap-client.sh, which reads the inputs
-- from terraform output and connects as neveslabs_admin, to database postgres. It takes three psql variables:
--
--   client            role and database name (a key of the clients map in database/variables.tf)
--   client_password   from terraform output -json client_passwords, passed either as -v client_password=... or
--                     through a \getenv client_password CLIENT_PASSWORD line placed before this file
--   connection_limit  from terraform output -json client_connection_limits
--
-- Re-running with the same inputs is a no-op: existing objects are skipped, the role membership GRANT raises a
-- notice, and the database privilege grants are repeated silently.
--
-- The script only manages roles it created itself, marked with a COMMENT ON ROLE. If a role with the client's
-- name already exists without that marker (a system role such as rds_superuser, or one made by hand), it stops
-- before touching it, so it never gives a foreign role a login or a password. Likewise it stops if a database
-- with the client's name exists but isn't owned by the client role.
--
-- CREATE ROLE and ALTER ROLE carry the password in plaintext statement text. Keep log_statement = none
-- (mod and ddl both log role DDL) and pgaudit role logging off on neves-labs-pg, or the password lands
-- in the RDS logs.
--
-- Rule: each client gets its own database and login role, never a schema in another client's database.

\set ON_ERROR_STOP on
\set client_role_marker 'Managed by database/sql/client.sql'

-- Without a variable, psql would leave :'name' unexpanded; fail with a clear message instead.
\if :{?client}
\else
  DO $$ BEGIN RAISE EXCEPTION 'pass -v client=... (a key of the clients map in database/variables.tf)'; END $$;
\endif
\if :{?client_password}
\else
  DO $$ BEGIN RAISE EXCEPTION 'pass -v client_password=... (terraform output -json client_passwords)'; END $$;
\endif
\if :{?connection_limit}
\else
  DO $$ BEGIN RAISE EXCEPTION 'pass -v connection_limit=... (terraform output -json client_connection_limits)'; END $$;
\endif

SELECT length(:'client') = 0 AS is_client_empty \gset
\if :is_client_empty
  DO $$ BEGIN RAISE EXCEPTION 'client is empty: pass the client name with -v client=...'; END $$;
\endif

-- An empty value (for example a failed terraform output) would create a login role with an empty password.
SELECT length(:'client_password') = 0 AS is_password_empty \gset
\if :is_password_empty
  DO $$ BEGIN RAISE EXCEPTION 'client_password is empty: check terraform output -json client_passwords'; END $$;
\endif

-- Role steps run in one transaction, so a role is never left created without its marker.
BEGIN;

SELECT EXISTS (
  SELECT 1 FROM pg_roles
  WHERE rolname = :'client'
    AND shobj_description(oid, 'pg_authid') IS DISTINCT FROM :'client_role_marker'
) AS is_foreign_role \gset
\if :is_foreign_role
  \warn Role :client exists but was not created by client.sql.
  DO $$ BEGIN RAISE EXCEPTION 'refusing to alter a role client.sql did not create (no client-role marker comment)'; END $$;
\endif

-- A database with the client's name that the client doesn't own (made by hand, or left from a restore) would
-- otherwise be reused and granted to the client.
SELECT EXISTS (
  SELECT 1 FROM pg_database
  WHERE datname = :'client' AND pg_get_userbyid(datdba) IS DISTINCT FROM :'client'
) AS is_foreign_database \gset
\if :is_foreign_database
  \warn Database :client exists but is not owned by role :client.
  DO $$ BEGIN RAISE EXCEPTION 'refusing to grant on a database the client role does not own'; END $$;
\endif

-- 1. psql variables don't expand inside DO $$, so the conditional statements go through \gexec.
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'client', :'client_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'client') \gexec

SELECT format('COMMENT ON ROLE %I IS %L', :'client', :'client_role_marker')
WHERE NOT EXISTS (
  SELECT 1 FROM pg_roles
  WHERE rolname = :'client' AND shobj_description(oid, 'pg_authid') = :'client_role_marker'
) \gexec

-- 2. Always applied, so the role converges on these attributes. The ::integer cast rejects a non-numeric limit.
-- No NOSUPERUSER: on RDS the admin isn't a superuser, and PostgreSQL 16+ rejects the clause from a non-superuser.
-- Roles this script creates are never superusers, and the marker check refuses any other role.
SELECT format(
  'ALTER ROLE %I WITH LOGIN NOCREATEDB NOCREATEROLE CONNECTION LIMIT %s PASSWORD %L',
  :'client', (:'connection_limit')::integer, :'client_password'
) \gexec

-- 3. On RDS the admin isn't a true superuser: it must be a member of the role to create a database owned by it.
SELECT format('GRANT %I TO CURRENT_USER', :'client') \gexec

COMMIT;

-- 4. CREATE DATABASE can't run inside a transaction or DO block, hence \gexec.
SELECT format('CREATE DATABASE %I OWNER %I', :'client', :'client')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'client') \gexec

-- 5. Other clients' roles must not be able to connect.
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'client') \gexec

-- 6. CREATE lets restores and the client's migrations create trusted extensions (pgcrypto, btree_gist, ...).
SELECT format('GRANT CONNECT, TEMPORARY, CREATE ON DATABASE %I TO %I', :'client', :'client') \gexec
