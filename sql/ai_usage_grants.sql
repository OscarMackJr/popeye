-- AI usage governance POC: shared local Postgres bootstrap and grants.
--
-- Context: the shared local Docker Postgres is owned by the nexus role
-- (see specs/STATE.md, Local Shared Postgres Notes). Run this as nexus.
--
-- Step 1 runs BEFORE first gateway boot. Step 2 runs AFTER first
-- gateway boot, because the gateway's Prisma migration creates
-- "LiteLLM_SpendLogs" and friends on startup.

-- ============================================================
-- Step 1: gateway database and writer role (before first boot)
-- ============================================================

CREATE DATABASE litellm;

CREATE ROLE litellm_gateway LOGIN PASSWORD :'litellm_gateway_password';
GRANT ALL PRIVILEGES ON DATABASE litellm TO litellm_gateway;

-- Then, connected to the litellm database:
--   \c litellm
GRANT ALL ON SCHEMA public TO litellm_gateway;

-- GATEWAY_POSTGRES_URL for the compose file:
--   postgresql://litellm_gateway:<password>@<shared-postgres-host>:5432/litellm

-- ============================================================
-- Step 2: read-only semantic-layer access (after first boot)
-- ============================================================
-- Follows the ekg_cube_reader pattern: the semantic layer never
-- connects as a writer. Run connected to the litellm database.

-- Reuse the existing reader role if this instance already has it;
-- otherwise create it:
--   CREATE ROLE ekg_cube_reader LOGIN PASSWORD :'ekg_cube_reader_password';

GRANT CONNECT ON DATABASE litellm TO ekg_cube_reader;
GRANT USAGE ON SCHEMA public TO ekg_cube_reader;

-- The spend ledger only. Deliberately NOT a blanket
-- ALL TABLES grant: the gateway database also holds virtual-key and
-- credential tables that the semantic layer has no business reading.
GRANT SELECT ON public."LiteLLM_SpendLogs" TO ekg_cube_reader;

-- Verification (as ekg_cube_reader):
--   SELECT count(*) FROM public."LiteLLM_SpendLogs";
-- And through Cube, the POC exit-criteria query:
--   measures:   ai_token_usage.cost_usd, ai_token_usage.total_tokens
--   dimensions: ai_token_usage.app_id, ai_token_usage.user_id,
--               ai_token_usage.model_group, ai_token_usage.cloud
