-- Popeye Azure variant: read-only ledger access for the semantic layer.
--
-- Idempotent. Re-run after every Prisma migration of the gateway (D-13),
-- because the migration creates/recreates "LiteLLM_SpendLogs".
-- Run as the Postgres admin connected to the litellm database:
--   psql --dbname=<admin dsn> -v ON_ERROR_STOP=1 -v reader_password=<runtime value> -f sql/ai_usage_grants_azure.sql
-- The reader password is supplied at runtime via psql -v and is never stored
-- in this file. See scripts/Set-PopeyeLedgerReader.ps1.
--
-- The local-Docker file (sql/ai_usage_grants.sql) is intentionally untouched.

-- psql does not interpolate variables inside dollar-quoted bodies, so the
-- role statement is built with format(%L) and executed with \gexec.
SELECT CASE
         WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ekg_cube_reader')
           THEN format('ALTER ROLE ekg_cube_reader LOGIN PASSWORD %L', :'reader_password')
         ELSE format('CREATE ROLE ekg_cube_reader LOGIN PASSWORD %L', :'reader_password')
       END
\gexec

GRANT CONNECT ON DATABASE litellm TO ekg_cube_reader;
GRANT USAGE ON SCHEMA public TO ekg_cube_reader;
GRANT SELECT ON public."LiteLLM_SpendLogs" TO ekg_cube_reader;

-- Verification: SELECT yes, write privileges no.
SELECT has_table_privilege('ekg_cube_reader', 'public."LiteLLM_SpendLogs"', 'SELECT') AS can_select,
       (has_table_privilege('ekg_cube_reader', 'public."LiteLLM_SpendLogs"', 'INSERT')
        OR has_table_privilege('ekg_cube_reader', 'public."LiteLLM_SpendLogs"', 'UPDATE')
        OR has_table_privilege('ekg_cube_reader', 'public."LiteLLM_SpendLogs"', 'DELETE')) AS has_write;
