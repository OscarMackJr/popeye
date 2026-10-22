# Phase 1: Network Proof, Gateway Hardening & Smoke Row - Research

**Researched:** 2026-10-22
**Domain:** Azure Container Apps + LiteLLM 1.106.x upgrade/hardening, Azure private networking (peering, private DNS, private endpoints), Postgres ledger read path
**Confidence:** MEDIUM-HIGH (LiteLLM behavior verified in source at `v1.106.2`; Azure Managed Redis cluster-policy interaction with LiteLLM is the main unverified item)

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Upgrade rollout**
- **D-01:** Upgrade in place through `terraform apply` with the new tag and digest. Container Apps rolls a new revision. Brief disruption is acceptable, since there are no production callers yet.
- **D-02:** Before the upgrade apply, take or confirm an on-demand Postgres Flexible Server backup point. Prisma migrations on first boot of 1.106.x are one-way, so the documented rollback is restore-to-point plus re-pinning the previous tag. Write that rollback down before applying.
- **D-03:** On pin day, pin the **latest patched 1.106.x**.
  - Re-check the LiteLLM GHSA list that day.
  - Pin both the tag and the sha256 digest.
  - Never use 1.91.0-1.100.3: GHSA-7hp6-4w63-5g45 is exploitable in the default config there.
  - Fix `terraform.tfvars.example`, which still suggests the nonexistent `-stable` suffix.
- **D-04:** The GHSA-range check runs in the **existing `.github/workflows/terraform.yml`**. A script compares the pinned tag against a committed advisory-range file (no network call at CI time) and fails the PR on a match. Updating the range file is a manual, reviewed change.

**Admin access after lockdown**
- **D-05:** The LiteLLM admin UI is **fully disabled** (`DISABLE_ADMIN_UI` or equivalent). All admin work goes through the API or scripts.
- **D-06:** Management routes are closed at the **key level now**. Every non-admin key is minted LLM-API-only (`allowed_routes` / `key_type: llm_api`). Negative tests prove that `/key/*`, `/user/*`, `/utils/*` and the UI return 401/403 for a user key. Ingress-level path restriction is deferred to the Phase 4/5 route config.
- **D-07:** Phase 1 admin scripts (minting the smoke key, applying the reader SQL) use the **master key from Key Vault, fetched at runtime only from the peered VM**. It is never written to disk, logs or tickets. A dedicated admin key arrives with the issuer in Phase 5.
- **D-08:** `POPEYE_VERIFICATION_VM_TEST_PROCEDURE.md` currently forbids operators and the VM from accessing the master key. **Amend that procedure** to allow a **time-boxed, recorded grant**:
  - The platform owner gets Key Vault Secrets User on the `litellm-master-key` secret only (secret scope, not vault scope).
  - The grant lasts only for the admin ceremony window (smoke key minting + reader SQL) and is removed afterwards.
  - Grant and removal timestamps go into the evidence, along with KV access log references.
  - All other secret restrictions in the procedure stay as they are: salt, `litellm-database-url`, writer.

**Smoke test mechanics**
- **D-09:** The smoke key carries **forward-compatible attribution** that matches the later key-metadata model (G11/OID decision): `principal_type=user`; `user_id` = platform owner's Entra object ID; canonical lowercase tenant UUID; `team_id=popeye-poc`; `key_alias=user:<oid>`; feature/request tag `mvp-smoke`; LLM-API-only routes.
- **D-10:** The smoke key is minted with a **short duration (~24h) and a tiny budget**. Once evidence is recorded it is **blocked, not deleted**, so ledger joins survive.
- **D-11:** The smoke request runs from a **repo script** (e.g. `scripts/Invoke-PopeyeSmoke.ps1`) executed on `EUS-VM-POPEYE` via `az vm run-command invoke`. Synthetic prompt content only. The key is read from Key Vault at runtime and never echoed. Output is redacted to the timestamp, `request_id`, HTTP status and model. The script is repeatable.
- **D-12:** "Exactly one attributed row" is verified through the **read-only `ekg_cube_reader` path**: query `LiteLLM_SpendLogs` by `request_id`, reusing or extending `scripts/Test-PopeyeVerificationPsql.ps1`. This also proves the hometown read path.
- **D-13:** Neither the `litellm-reader-dsn` secret nor the `ekg_cube_reader` role exists today; Key Vault holds only master, salt, database-url and redis-password. Fix: Terraform generates the reader password into Key Vault as `litellm-reader-dsn`; the operator applies `sql/ai_usage_grants.sql` idempotently from the peered VM via run-command during the time-boxed admin window; the DB is private-only so CI can't run the postgres provider; re-validate the grants **after** the upgrade's Prisma migrations.

**Env DNS zone + Redis private access**
- **D-14:** The Container Apps environment private DNS zone follows **whatever networking replies**. The plan includes a ready, parameterized Terraform task (zone `ashyglacier-edb44cd7.eastus2.azurecontainerapps.io`, `*` and `@` A records -> 10.60.0.108, links to both VNets, no auto-registration), executed **only** if networking hands ownership to Popeye. Otherwise Phase 1 only verifies networking's zone (resolution from `EUS-VM-POPEYE`). Read the zone name and IP from the environment's outputs (`default_domain`, `static_ip`), not hardcoded.
- **D-15:** Redis goes private through **Terraform**: a new non-delegated `snet-private-endpoints` in the free 10.60.3.0/24 (e.g. 10.60.3.0/27); a Managed Redis private endpoint; a `privatelink.redis.azure.net` zone linked to the **Stage 1/2 VNet only**; then `managed_redis_public_network_access = "Disabled"`.
- **D-16:** **Sequencing:** (1) Redis private endpoint, then disable public access. (2) Verify the gateway is healthy and counters still work. (3) Then the LiteLLM upgrade. Separate applies keep failures attributable.
- **D-17:** Peering ownership, the RDP NSG rule (`Allow_Iliya_Promenet`), and VM login role fixes (User Login for the two approved operators only) are **networking actions requested by email**. Phase 1 verifies them and records evidence. Popeye Terraform doesn't change them unless networking hands them over.

### Claude's Discretion
- Exact config-hardening mechanics: `exec` in the container args; readiness probe on `/health/readiness`; termination grace >= `proxy_batch_write_at` + 10 s; `user_api_key_cache_ttl` <= 30 s; `allow_client_side_credentials: false`; `LITELLM_LOG=ERROR`; no response caching.
- How to verify that Redis backs budget counters across replicas (GW-06), e.g. by inspecting Redis keys during a burst from the peered VM, or by checking the cache settings LiteLLM reports. Never enable response caching to achieve it.
- Advisory-range file format and the check script language (PowerShell or Python, matching the existing CI).
- Evidence file naming under `artifacts/`, plus `.gitignore` entries so raw outputs containing identifiers aren't committed accidentally.

### Deferred Ideas (OUT OF SCOPE)
- Ingress-level path restriction for LiteLLM management routes: Phase 4/5, with the `httpRouteConfig` on the stable FQDN.
- Dedicated proxy-admin key replacing master-key use: Phase 5 (issuer).
- Live GitHub advisory API polling (scheduled job opening issues): possible later enhancement; Phase 1 uses only the committed range file.
- Postgres Entra authentication for automation identities: v2 (PG-01).
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| NET-01 | Peering Connected/FullyInSync both ways; ownership recorded | Evidence already shows Connected; record networking-owned (Terraform has no peering resource; do not import). Verify with `az network vnet peering list`. |
| NET-02 | Postgres private zone linked to both VNets; public access Disabled | Already true in 2026-10-22 evidence; re-verify read-only with extended `Test-PopeyeAzureVerificationVm.ps1`. Terraform manages only the Stage 1/2 link; the caller-VNet link is networking's. |
| NET-03 | Container Apps env private DNS zone linked to both VNets | Needs `default_domain` + `static_ip_address` outputs, conditional TF zone (Section "DNS Zone"). Gated on networking reply. |
| NET-04 | Peered-caller data-plane evidence | Adapt `Test-PopeyeVerificationVm.ps1` (add gateway FQDN resolve + 443). |
| NET-05 | Caller VM control-plane posture | Adapt `Test-PopeyeAzureVerificationVm.ps1` for caller VNet; add NSG source check. |
| NET-06 | VM login limited to two operators | Role-assignment check on VM scope; networking action. |
| GW-01 | Patched 1.106.x by tag + digest | Pin `v1.106.2` + index digest (below); strict TF validation. |
| GW-02 | CI fails on GHSA-affected pin | Committed range file + stdlib script; pin must live in a committed file (see Pitfall 1). |
| GW-03 | Key/user/utils/UI routes locked for user keys | Explicit `allowed_routes` list (NOT `key_type: llm_api`, which includes `/utils/*`), `DISABLE_ADMIN_UI`, `disable_env_credential_login`. UI returns 200 "disabled" page, not 401/403 (Pitfall 3). |
| GW-04 | `exec`, readiness, grace period | Verified: lifespan shutdown flushes spend counters + spend log queue at v1.106.2. |
| GW-05 | Config hardening | `user_api_key_cache_ttl` is under `general_settings`; `allow_client_side_credentials` under `general_settings`. |
| GW-06 | Redis backs counters; public access disabled | 1.106.2 coordination-Redis resolution; clustering-policy risk; PE subresource `redisEnterprise`, zone `privatelink.redis.azure.net`, port 10000. |
| MVP-01 | One attributed ledger row | Smoke mechanics, ledger column layout, batch flush wait, reader DSN. |
</phase_requirements>

## Summary

The phase is a brownfield infrastructure upgrade, not a build. Most of the code surface is small: two Terraform modules, one root `main.tf`, a CI step, and four or five PowerShell scripts. The hard part is sequencing and the number of places where the documented intent does not match actual LiteLLM 1.106.2 behavior. Source inspection at `v1.106.2` found six such mismatches that the planner must design around (see Pitfalls): `key_type: llm_api` includes `/utils/*`; `DISABLE_ADMIN_UI` returns HTTP 200 and does not gate `/login` or `/ui`; the `user_api_key_cache_ttl` key lives under `general_settings`; Redis wiring on 1.106 changes (silent soft-fail env fallback); the pin lives in a gitignored file CI can't read; and the Azure Managed Redis default clustering policy (OSSCluster) is likely incompatible with LiteLLM's non-cluster Redis client.

Target pin: `v1.106.2` (released 2026-10-21, latest non-RC 1.106 patch), index digest `sha256:7294b90f868c5c38c99b83021c7ba46f9b439e95f8e32964c925c7d2563a03f7`. No published advisory in the GitHub list affects 1.106.x. GHSA-7hp6 (critical) is fixed at 1.100.4 / 1.101.3 / 1.102.2 / 1.103.1 / 1.104.0rc2 and later. The re-check must be repeated on the actual apply day.

Spend flush on SIGTERM is implemented in the 1.106.2 lifespan shutdown (`flush_spend_counters_on_shutdown`, `_flush_spend_logs_queue_on_shutdown`), so GW-04 reduces to `exec` + a sufficient grace period; `PROXY_BATCH_WRITE_AT` defaults to 10 s.

**Primary recommendation:** Execute in this order, each as its own apply: (1) Redis private endpoint + clustering-policy spike, disable public access; (2) verify gateway health; (3) pin file + CI check + hardening config + upgrade apply; (4) admin ceremony (reader role, smoke key, negative tests, smoke row); (5) network evidence refresh. Put the pin in a committed `.auto.tfvars` file so CI can check what is actually deployed.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Peering, caller VNet NSG/RBAC, caller VM | Networking team (external) | Popeye verification scripts | D-17: networking-owned; Popeye only verifies |
| Env private DNS zone | Networking (default) | Popeye TF (conditional) | D-14 |
| Redis private endpoint + zone | Popeye Terraform (Azure network) | Gateway app | D-15 |
| Image pin + GHSA gate | Repo/CI | Terraform validation | Deterministic, no network at CI time |
| Route lockdown | Gateway app (key-level `allowed_routes`) | Ingress (deferred Phase 4/5) | D-06 |
| Spend flush on revision swap | Container runtime (`exec`, grace period) | LiteLLM lifespan | Verified in source |
| Counter sharing across replicas | Redis (coordination Redis) | LiteLLM | Config + empirical check |
| Ledger row | Postgres `LiteLLM_SpendLogs` (LiteLLM writer) | `ekg_cube_reader` read path | MVP-01 |
| Secrets (master, reader DSN, smoke key) | Key Vault | Operator on peered VM | D-07/D-08 |

## Standard Stack

### Core
| Item | Version | Purpose | Why |
|------|---------|---------|-----|
| LiteLLM image | `v1.106.2` @ `sha256:7294b90f868c5c38c99b83021c7ba46f9b439e95f8e32964c925c7d2563a03f7` (OCI index) | Gateway | Latest 1.106 patch; not in any advisory range [VERIFIED: GitHub releases API + GHCR manifest HEAD, 2026-10-22] |
| azurerm | `~> 4.0` (locked 4.80.0) | Container App, private endpoint, DNS | Existing |
| random | `~> 3.6` | Reader password | Existing pattern (`random_password`) |
| Terraform | >= 1.7.0 (local 1.15.4) | IaC | Existing |

### Supporting
| Item | Purpose | When |
|------|---------|------|
| Python 3.12 stdlib only | `scripts/Test-LitellmAdvisoryRange.py` | GHSA CI gate; no new pip packages (avoids packaging dependency; CI already has Python 3.12) |
| PowerShell 7 + `Add-Result` pattern | Verification, smoke, negative tests | Project convention |
| `psql` | Row assertion | Present on workstation (PG 18); **unverified on `EUS-VM-POPEYE`** |
| Azure CLI | run-command, role checks | Local 2.87.0 |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Digest-only image ref | `tag@digest` | `ghcr.io/berriai/litellm:v1.106.2@sha256:...` is a valid Docker reference and keeps the human tag readable; confirm Container Apps accepts it at first plan/apply [ASSUMED]. Fall back to digest-only if rejected; the tag stays in a Terraform variable for the CI check either way. |
| `packaging` library for version compare | stdlib tuple compare | Tags are `vX.Y.Z`; stdlib avoids a new dependency and slopcheck gate |

**Installation:** none. No new external packages are introduced in this phase.

## Package Legitimacy Audit

No new external packages are installed (stdlib Python, existing Terraform providers, existing CI pip pin `jsonschema==4.26.0`). slopcheck not needed.

**Packages removed due to slopcheck [SLOP] verdict:** none
**Packages flagged as suspicious [SUS]:** none

## Architecture Patterns

### System Architecture Diagram

```
 Operator --Bastion--> EUS-VM-POPEYE (10.10.2.4, EUS-POPEYE-VNET-01)
        |                    |
        | az vm run-command  |  (a) DNS+TCP checks
        v                    |  (b) smoke call (key from KV)
  KV kv-popeye-gw-98c2b71b <-+  (c) psql reader query
        |                    |
        |          VNet peering (networking-owned)
        |                    v
        |     vnet-popeye-stage1-stage2-eastus2 (10.60.0.0/22)
        |       snet-containerapps 10.60.0.0/23  -- CA env (internal LB, 10.60.0.108)
        |           gateway app x2+ replicas ---> Foundry (managed identity)
        |              |   |  \__ spend rows (batched, 10 s) --> Postgres 10.60.2.5 (snet-postgres)
        |              |   \_____ coordination Redis (PE, 10.60.3.x, port 10000)
        |       snet-private-endpoints 10.60.3.0/27 (NEW)
        |
 Private DNS: privatelink.postgres.database.azure.com (both VNets)
              <env default domain> zone (A: * and @ -> 10.60.0.108)  [networking or Popeye]
              privatelink.redis.azure.net (Stage 1/2 VNet only, NEW)

 CI: PR --> terraform fmt/validate --> NEW advisory-range check (committed pin file vs committed ranges)
```

### Recommended Project Structure
```
envs/azure-eastus2/
  litellm-pin.auto.tfvars     # NEW, committed: litellm_image_tag + litellm_image_digest (add !litellm-pin.auto.tfvars to .gitignore)
  main.tf                     # + coordination_redis, hardening keys, PE subnet/zone, reader password+secret, conditional env DNS
modules/gateway-service-azure/  # exec args, probes, grace period, DISABLE_ADMIN_UI env, image tag@digest, outputs default_domain/static_ip
modules/gateway-state-azure/    # clustering_policy variable, private endpoint inputs
config/litellm-advisory-ranges.json   # NEW committed ranges
scripts/Test-LitellmAdvisoryRange.py  # NEW (CI)
scripts/Invoke-PopeyeSmoke.ps1        # NEW
scripts/Test-PopeyeGatewayLockdown.ps1# NEW negative tests (Add-Result pattern)
scripts/Set-PopeyeLedgerReader.ps1    # NEW applies SQL via run-command (or ceremony helper)
sql/ai_usage_grants_azure.sql         # NEW idempotent Azure variant (see Pitfall 8)
artifacts/                            # redacted evidence only
```

### Pattern 1: Container args with `exec`
```hcl
# modules/gateway-service-azure/main.tf (currently line 123)
args = ["printf '%s' \"$LITELLM_CONFIG\" > /tmp/litellm.yaml && exec litellm --config /tmp/litellm.yaml --host 0.0.0.0 --port 4000"]
# template block:
termination_grace_period_seconds = 45   # >= 10 s batch + 10 s; azurerm supports this argument [CITED: azurerm container_app docs]
```
Spend flush path at shutdown [VERIFIED: litellm v1.106.2 proxy_server.py lifespan]: `_drain_spend_event_producer_on_shutdown` -> `flush_spend_counters_on_shutdown` -> `_flush_spend_logs_queue_on_shutdown`.

### Pattern 2: Rendered LiteLLM config (key placement matters)
```yaml
general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
  user_api_key_cache_ttl: 30            # general_settings, NOT litellm_settings [VERIFIED: proxy_server.py:6961]
  allow_client_side_credentials: false  # general_settings [VERIFIED: auth_utils.py:470]
  disable_env_credential_login: true    # blocks /login with master-key/UI creds [VERIFIED: login_utils.py]
  coordination_redis:                   # explicit, fails loudly [VERIFIED: proxy_server.py _init_coordination_redis]
    host: os.environ/REDIS_HOST
    port: os.environ/REDIS_PORT
    password: os.environ/REDIS_PASSWORD
    ssl: true
router_settings: { ... existing redis_* kept ... }
litellm_settings:
  store_prompts_in_spend_logs: false
  enable_azure_ad_token_refresh: true
  # do NOT add `cache: true`; do NOT set enable_key_alias_format_validation
```
Env additions: `DISABLE_ADMIN_UI="True"`, `LITELLM_LOG=ERROR`. `port` from env is a string; confirm `CoordinationRedisParams` coerces (pydantic `int | None` coerces numeric strings in lax mode) [ASSUMED] - validate in first boot logs.

### Pattern 3: Smoke key mint (admin ceremony, master key from KV at runtime)
`POST /key/generate` with: `key_alias: "user:<oid>"` (colon is accepted because `enable_key_alias_format_validation` defaults false [VERIFIED]), `user_id: <oid>`, `team_id: "popeye-poc"` (team must exist first: `POST /team/new` with `team_id`; key creation validates team existence [VERIFIED: key_management_endpoints.py:1130]), `models: ["twg-foundry"]`, `duration: "24h"`, `max_budget: 0.25`, `tags: ["mvp-smoke"]`, `metadata: {principal_type, tenant_id}`, and `allowed_routes` as an explicit list (below). Only proxy admin may set `allowed_routes` [VERIFIED: `_check_allowed_routes_caller_permission`]; the master key qualifies.

Allowed-routes list for LLM-only keys (exact-path or prefix match, `route_checks.py`): `["/v1/chat/completions", "/chat/completions", "/v1/embeddings", "/embeddings", "/v1/models", "/models"]` - trim to what Phase 1 needs. Do **not** use `key_type: "llm_api"` for GW-03 (Pitfall 2).

### Pattern 4: Redis private endpoint (Terraform)
```hcl
resource "azurerm_subnet" "private_endpoints" {          # no delegation
  name = "snet-private-endpoints"; address_prefixes = ["10.60.3.0/27"]
  # private_endpoint_network_policies: leave default
}
resource "azurerm_private_dns_zone" "redis" { name = "privatelink.redis.azure.net" }
resource "azurerm_private_dns_zone_virtual_network_link" "redis" { # Stage 1/2 VNet only
  registration_enabled = false
}
resource "azurerm_private_endpoint" "redis" {
  private_service_connection {
    private_connection_resource_id = module.state.redis_id
    subresource_names              = ["redisEnterprise"]   # [CITED: learn.microsoft.com/azure/redis/private-link]
    is_manual_connection           = false
  }
  private_dns_zone_group { name = "redis"; private_dns_zone_ids = [azurerm_private_dns_zone.redis.id] }
}
```
Client connects to `<name>.<region>.redis.azure.net` on **port 10000** (the module already reads the port from `default_database[0].port`); never use the `privatelink` name in config [CITED: same page]. Deleting all PEs re-enables public access by default per docs, so keep `public_network_access = "Disabled"` in state.

### Pattern 5: Env DNS zone (conditional)
`azurerm_container_app_environment` exports `default_domain` and `static_ip_address`. Add them as module outputs; create zone `default_domain` with A records `*` and `@` -> `static_ip_address`, TTL 300, links to Stage 1/2 VNet plus `caller_vnet_id` variable (empty string = skip). Gate the whole block on `var.manage_env_dns_zone` (default `false`). Creating a link to the caller VNet needs `Microsoft.Network/virtualNetworks/join/action` on that remote VNet; the deployer likely lacks it, a reason networking owning it is the likely outcome [ASSUMED].

### Pattern 6: Reader DSN
`random_password.reader` -> KV secret `litellm-reader-dsn` = `postgresql://ekg_cube_reader:<pw>@<pg-fqdn>:5432/litellm?sslmode=require`. Only the new secret is added; the role does not exist until SQL runs. Terraform state holds the password (already true for others). Gateway UAMI has Secrets User at vault scope - the reader DSN becomes readable by the gateway identity; acceptable but note it.

### Anti-Patterns to Avoid
- Enabling `litellm_settings.cache: true` to "get Redis working" - enables response caching of prompt-derived entries.
- Relying on the REDIS_* env fallback for coordination - it silently degrades to per-pod memory when Redis is unreachable.
- Running `terraform apply` for DNS/Redis/upgrade in one shot (D-16).
- Putting the real pin only in gitignored `terraform.tfvars`.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Private link DNS | Manual A records for Redis | `private_dns_zone_group` on the PE | Keeps record in sync |
| Image trust | Custom checks | Digest pin (+ optional `cosign verify` with LiteLLM's published key, per release notes) | Release body documents the cosign command |
| Version range compare | Regex hacks | Small tuple compare over a JSON range list | Tags are strict `vX.Y.Z` |
| Postgres role creation in TF | `postgresql` provider | SQL via run-command from peered VM (D-13) | DB private; CI can't reach |
| Spend flush on stop | Custom preStop | `exec` + grace period | LiteLLM lifespan already flushes |

## Runtime State Inventory

This is an in-place upgrade/migration, so runtime state is listed.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | Postgres `litellm` DB: Prisma will apply roughly 86 new migrations (128 -> 214 migration directories between `v1.90.3` and `v1.106.2`); `LiteLLM_SpendLogs` gains columns (e.g. `billing_agent_id`, `agent_id`, `litellm_call_id`). No SpendLogs drop/rename observed in schema. Existing table grants persist through additive migrations. | On-demand backup before apply (D-02); re-run `has_table_privilege('ekg_cube_reader', ...)` after upgrade. `ekg_cube_reader` does not exist yet, so nothing to preserve but the post-upgrade check still runs. |
| Live service config | Container App single revision; LiteLLM config delivered as CA secret (changes force new revision). Redis DB contents are ephemeral counters. | Redis `clustering_policy` change forces DB recreation (data loss acceptable; no response cache). |
| OS-registered state | None - verified by inspection: no scheduled tasks reference LiteLLM version | None |
| Secrets/env vars | KV `redis-password` changes if Redis DB recreated; ACA resolves KV refs only at revision start | After Redis recreation, force a new revision / restart. Salt key untouched (`prevent_destroy`, `ignore_changes`). Master key `sk-` + 48 random chars passes the 1.104+ weak-key check (only empty/unset/publicly known hash are rejected) [VERIFIED: master_key_boot_check.py]. |
| Build artifacts | `terraform.tfvars` (gitignored) still pins `v1.90.3` | Move pin to committed file; keep one source of truth |

## Common Pitfalls

### Pitfall 1: The deployed pin is invisible to CI
**What goes wrong:** `terraform.tfvars` is gitignored; CI would only ever see `terraform.tfvars.example` (`litellm_image_tag = ""`), so a GHSA gate "passes" vacuously.
**How to avoid:** Commit `envs/azure-eastus2/litellm-pin.auto.tfvars` (tag + digest), add `!litellm-pin.auto.tfvars` to `.gitignore`, delete the tag from local `terraform.tfvars`. The CI script reads that file and fails if missing or empty. Add a TF validation for `^v1\.\d+\.\d+$` on the tag and `^sha256:[0-9a-f]{64}$` on the digest, keeping the `latest`/empty rejection.
**Warning signs:** CI green with a blank pin.

### Pitfall 2: `key_type: llm_api` still exposes `/utils/*`
**What goes wrong:** `LiteLLMRoutes.llm_api_routes` includes `openai_routes`, which contains `/utils/token_counter`, `/utils/model_info`, `/utils/transform_request` [VERIFIED: `_types.py` lines ~427-432]. The GHSA-g5ff file-read vector was `/utils/transform_request`. GW-03 requires `/utils/*` -> 401/403.
**How to avoid:** Mint keys with an explicit `allowed_routes` path list (Pattern 3), and put the `/utils/*` negative test in the lockdown script. Phase 4 FLT and Phase 5 issuer must reuse this list (record it as a shared constant, e.g. `config/llm-allowed-routes.json`).
**Note:** Disallowed routes raise HTTP 403 [VERIFIED: `route_checks.py`]. `/key/info`-style routes are in `info_routes`, not `llm_api_routes`.

### Pitfall 3: `DISABLE_ADMIN_UI` is not a 401/403
**What goes wrong:** In 1.106.2 the env var gates `/sso/key/generate` and SAML routes only, and returns an HTML page with **status 200** [VERIFIED: `admin_ui_utils.py`, `ui_sso.py`]. `/ui` (StaticFiles mount) and `POST /login` / `/v2/login` are not gated by it. Without `disable_env_credential_login`, `/login` accepts the master key as the admin password.
**How to avoid:** Set `DISABLE_ADMIN_UI=True` **and** `general_settings.disable_env_credential_login: true` [VERIFIED present in `login_utils.py`]. Define the UI negative tests honestly: `/login` with a user key as password returns 401 (and with the master key also fails), `/sso/key/generate` shows the disabled page, `/ui` serves only static assets with no obtainable session. Success criterion 5 says "admin UI gets 401/403"; surface this to the user: literal 401/403 on `/ui` needs the ingress path block deferred to Phase 4/5. Recommend the plan records this as an accepted, documented deviation.

### Pitfall 4: Redis wiring changed in 1.106; env fallback fails soft
**What goes wrong:** On 1.106.2, if no explicit block or plain-Redis `cache` exists, REDIS_* env vars produce a coordination Redis after a 2 s ping; on any failure it logs a warning and stays per-pod in memory [VERIFIED: `_init_coordination_redis_env_fallback`]. After making Redis private, a DNS mistake would silently remove cross-replica counters while the gateway looks healthy.
**How to avoid:** Use explicit `general_settings.coordination_redis` (raises on bad config, no silent fallback), and verify at runtime: boot log line `coordination_redis: using a standalone Redis from general_settings`, plus key inspection (Pitfall 5).

### Pitfall 5: Azure Managed Redis default clustering policy is OSSCluster
**What goes wrong:** `azurerm_managed_redis.default_database.clustering_policy` defaults to `OSSCluster` and the module does not set it. OSS policy requires a cluster-aware client [CITED: learn.microsoft.com/azure/redis/architecture]. LiteLLM builds a plain `RedisCache` from host/port unless `startup_nodes` is given [VERIFIED: `build_redis_usage_cache`], so non-cluster commands can hit MOVED/CROSSSLOT errors. Enterprise policy exposes a single endpoint but restricts multi-key commands to `DEL, MSET, MGET, EXISTS, UNLINK, TOUCH`; Non-clustered (<= 25 GB) allows everything.
**How to avoid (spike, ~1 task):** Before disabling public access, run the current stack against the three policies on a throwaway basis or pick `NoCluster` (best compatibility for pipelines/Lua; cache size is tiny) and verify empirically: no `MOVED`/`CROSSSLOT` in container logs at `LITELLM_LOG=INFO` for the test, and counters visible in Redis. Changing the policy forces DB recreation (acceptable) and may rotate the access key, so re-apply the `redis-password` secret and restart the revision. **Confidence MEDIUM-LOW** - this is the item most likely to need an adjustment during execution; expose `redis_clustering_policy` as a module variable.

### Pitfall 6: Counter verification is not obvious
**What goes wrong:** A burst from one caller may land on one replica; seeing keys in Redis proves wiring, not cross-replica sharing.
**How to avoid:** From the VM, send N requests with a key with small `max_budget`; inspect Redis from inside the VNet (need a Redis client on the VM, or use `az redis` data-plane? **not available** - use a one-shot Container Apps console `exec` into a replica running `python -c redis...` using the existing env vars) to list `spend:*`-style keys without printing values, and confirm both replicas (use `az containerapp replica list`) enforce the same exhausted budget (expect HTTP **422** on 1.104+, not 429 [CITED: PITFALLS.md from release notes]). Record that response-cache keys are absent.

### Pitfall 7: Migration behavior on the jump
**What goes wrong:** 1.103.3+ exits the proxy on Prisma migration failure; ~86 migrations may exceed the current startup probe budget (10 s initial + 18 x 10 s = ~190 s). Two replicas could migrate concurrently.
**How to avoid:** Raise the startup probe `failure_count_threshold` (for example 60 x 10 s) for the upgrade revision; check Postgres backup first (D-02); watch Log Analytics for migration output. Prisma Migrate serializes via a Postgres advisory lock [ASSUMED]. Single revision mode keeps the old revision serving if the new one never becomes ready, but the DB may already have migrated - rollback is restore-to-point (D-02).

### Pitfall 8: `sql/ai_usage_grants.sql` is written for local Docker
**What goes wrong:** It does `CREATE DATABASE litellm` and creates `litellm_gateway` (Azure already has the DB; gateway uses the admin login), and `CREATE ROLE ekg_cube_reader` is commented out. psql variables `:'x'` need `-v`.
**How to avoid:** Add `sql/ai_usage_grants_azure.sql` (do not break the local one): `DO $$ ... IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='ekg_cube_reader') THEN CREATE ROLE ... LOGIN PASSWORD ...` (password passed via `psql -v` from KV at runtime; never in the file), `ALTER ROLE ... PASSWORD` on re-run for idempotency, `GRANT CONNECT`, `GRANT USAGE ON SCHEMA public`, `GRANT SELECT ON public."LiteLLM_SpendLogs"`. The Azure admin role (`azure_pg_admin` member) can create roles. The table exists only after the gateway has booted once (it has, on 1.90.3).
**Note for Phase 3:** `SELECT` on the whole SpendLogs table also exposes `messages`, `response`, `proxy_server_request` columns (empty with `store_prompts_in_spend_logs: false`). The Phase 3 `popeye_ledger_v1` view is the intended fix.

### Pitfall 9: Run-command has no operator identity
**What goes wrong:** `az vm run-command invoke` runs as SYSTEM on the VM. The D-08 grant is to the *platform owner*, but KV reads from the VM need a credential on the VM. The procedure forbids granting the VM identity master/DB secrets.
**How to avoid / open decision:** For the secret-touching ceremony steps (mint smoke key, apply reader SQL, smoke call, psql assertion) use an interactive Bastion RDP session where the operator runs `az login` (Entra, device code) and the repo scripts, instead of unattended run-command. Keep run-command for non-secret DNS/TCP checks. If the user insists on run-command (D-11), the only way is a time-boxed secret-scope grant to the VM's managed identity (another procedure amendment). Flag in plan as a `checkpoint:decision`.

### Pitfall 10: "Exactly one row" cannot be proven by `request_id` alone
`request_id` is the table PK, so a query by it returns at most one row. Assert instead: exactly one row for the smoke key's `api_key` hash (sha256 of the key) in the time window, plus the `request_id` returned (response `id`, or `x-litellm-call-id` header). Allow >= `PROXY_BATCH_WRITE_AT` (10 s default) before the first poll and poll up to ~90 s. Also assert attribution: SpendLogs `user` / `team_id` / `request_tags` columns and `metadata` JSON (`user_api_key_alias`, `user_api_key_user_id`, `user_api_key_team_id`) match the minted key [STACK.md, verified earlier in source], and `messages`/`response` are `{}`.

### Pitfall 11: Terraform ownership of the second Postgres DNS link
The Terraform stack owns one link (`pg-vnet-link`); the caller-VNet link is networking's. Terraform will not manage or remove it. Record this; do not import. Same for the peering (NET-01): document "networking-owned" and confirm `terraform plan` shows no diff for it (nothing in state).

## Code Examples

### Advisory range file (committed) - from GitHub security advisories API, 2026-10-22 [VERIFIED]
```json
{
  "generated": "2026-10-22",
  "source": "https://github.com/BerriAI/litellm/security/advisories",
  "ranges": [
    {"id":"GHSA-7hp6-4w63-5g45","severity":"critical","affected":[[ "1.91.0","1.100.4"],["1.101.0","1.101.3"],["1.102.0","1.102.2"],["1.103.0","1.103.1"]],"note":"half-open [lo,hi); 1.104.0rc1 also affected, rc tags not allowed"},
    {"id":"GHSA-g5ff-637f-6q2m","severity":"high","affected":[["0.0.0","1.95.0"]]},
    {"id":"GHSA-3cv6-jpf6-8222","severity":"medium","affected":[["0.0.0","1.94.0"]]},
    {"id":"GHSA-4xpc-pv4p-pm3w","severity":"critical","affected":[["0.0.0","1.84.0"]]},
    {"id":"GHSA-r75f-5x8p-qvmc","severity":"critical","affected":[["1.81.16","1.83.7"]]},
    {"id":"GHSA-hhww-mrg2-969h","severity":"medium","affected":[["1.65.5","1.85.0"]]}
  ]
}
```
Include every advisory returned by `GET /repos/BerriAI/litellm/security-advisories` (about 17 on 2026-10-22; older ones are all below 1.84). The gate's pass condition: tag matches `^v\d+\.\d+\.\d+$` (reject rc/dev/`-stable`), and not inside any half-open range. Also add a fixture test: `v1.100.3` and `v1.90.3` must fail, `v1.106.2` must pass. A pre-1.100.4 range caveat: patched backports (1.90.7, 1.89.7 ...) mean old lines can be safe for GHSA-3cv6, but the gate should stay conservative; the 1.106.x policy makes this moot.

### Pin day re-check (script/manual)
```bash
curl -s https://api.github.com/repos/BerriAI/litellm/security-advisories | python -c "..."   # compare to committed ranges
curl -s https://api.github.com/repos/BerriAI/litellm/releases?per_page=30                    # latest non-RC 1.106.x
# digest: anonymous GHCR token, then HEAD manifest and read docker-content-digest
```
Result at research time: latest `v1.106.2` (2026-10-21); `v1.107.0-rc.*` exist but are prereleases - do not pin.

### Lockdown negative test shape (PowerShell, project style)
```powershell
# Add-Result pattern; expect 401/403 for each, with the smoke key as bearer
foreach ($p in '/key/generate','/key/info','/user/new','/user/info','/utils/transform_request','/utils/token_counter','/team/list','/config/yaml') { ... }
# UI: POST /login with username=admin password=<user key> -> expect 401; GET /sso/key/generate -> expect body contains 'Admin UI is Disabled'
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `-stable` image tags | `vX.Y.Z` tags | 1.84.0 | Fix `terraform.tfvars.example` and the validation message |
| Redis only in `router_settings` | Coordination Redis (`general_settings.coordination_redis` or REDIS_* fallback) | by 1.106 | Counters can now be shared; explicit block recommended |
| Budget exhausted -> 429 | 422 | 1.104.0 | Update expectations in negative/budget tests |
| Weak/unset master key allowed | Refused at boot | 1.104.0 | Existing key is fine |
| `db push` vs `migrate deploy` | `migrate deploy`, exit on failure | 1.103.3 | Plan migration monitoring |

**Deprecated/outdated:** `v1.90.3` (unsupported, vulnerable); `key_type: llm_api` as a route lock (too wide).

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Container Apps accepts `image:tag@sha256:...` | Standard Stack | Use digest-only reference; trivial |
| A2 | `coordination_redis.port` accepts the env-string port (pydantic coercion) | Pattern 2 | Boot error; fix by hard-rendering the port number from TF |
| A3 | Prisma migrate serializes concurrent replicas with an advisory lock | Pitfall 7 | Concurrent migration conflict; mitigate by temporarily capping max_replicas=… or restarting one at a time |
| A4 | Deployer lacks join/action on caller VNet; networking will own env DNS zone | Pattern 5 | If Popeye must own it, needs a role grant from networking |
| A5 | NoCluster (or Enterprise) clustering policy makes LiteLLM's Redis client work | Pitfall 5 | Counters stay per-replica; fall back to OSSCluster with `startup_nodes` |
| A6 | `EUS-VM-POPEYE` has psql and Azure CLI | Environment | Install step or run psql from another host |
| A7 | A user key sending an invalid `/login` password yields 401 (not 200 HTML) | Pitfall 3 | Adjust test to assert "no session cookie/token issued" |

## Open Questions

1. **Run-command vs interactive session for secret-touching steps (Pitfall 9).** Recommendation: interactive Bastion session with operator `az login`; needs the user's decision because D-11 names run-command.
2. **Success criterion 5 literal "admin UI -> 401/403".** Not achievable via env var alone on 1.106.2. Recommendation: accept the documented deviation (disabled page + no login + static assets only), with ingress block in Phase 4/5. Needs user ack.
3. **Redis clustering policy.** Spike result decides NoCluster vs EnterpriseCluster vs OSS + startup_nodes.
4. **Networking's reply on env DNS zone ownership** (outstanding); plan both branches.
5. **Does hometown need the table-wide grant at all?** MVP-03 (Phase 3) moves it to a view; Phase 1 follows D-13 as written.
6. **Foundry smoke prerequisites:** `foundry_scope_id` set and the deployment `gpt-5-mini` reachable by the gateway UAMI - verify with a gateway-side health or a master-key test completion before the smoke ceremony.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Terraform | all applies | yes (workstation) | 1.15.4 | - |
| Azure CLI | run-command, role/NSG checks | yes (workstation) | 2.87.0 | - |
| PowerShell 7 (`pwsh`) | scripts | yes | - | Windows PowerShell on VM |
| psql | row assertion | yes on workstation (PG 18); VM unknown | - | Install on VM or run via Bastion elsewhere (workstation cannot reach private PG) |
| Python 3.12 | advisory script (CI + local) | yes | 3.12 | - |
| GHCR / GitHub API (pin day only) | digest + advisory re-check | yes | - | - |
| `EUS-VM-POPEYE` az CLI / psql | ceremony | unverified | - | install |
| Network path workstation -> private resources | - | no (by design) | - | use peered VM |

**Missing with no fallback:** none confirmed. **Missing with fallback:** psql/az on the VM unconfirmed.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | No unit framework (project convention): PowerShell check scripts with `Add-Result` (PASS/FAIL) + Python fixture checks + `terraform fmt/validate` |
| Config file | none (Pester is a later-phase addition for fleet scripts) |
| Quick run command | `terraform fmt -check -recursive && terraform -chdir=envs/azure-eastus2 validate && python scripts/Test-LitellmAdvisoryRange.py --self-test` |
| Full suite command | quick command + the VM-side/ceremony scripts (`Test-PopeyeVerificationVm.ps1`, `Test-PopeyeGatewayLockdown.ps1`, `Invoke-PopeyeSmoke.ps1`, `Test-PopeyeVerificationPsql.ps1`) |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| NET-01 | Peering Connected/FullyInSync both ways | control-plane check | `pwsh scripts/Test-PopeyeAzureVerificationVm.ps1 -VmName EUS-VM-POPEYE ...` (extend) | extend existing |
| NET-02 | PG zone links x2, public access Disabled | control-plane | same script | extend |
| NET-03 | env zone linked to both VNets; resolves | control-plane + VM | same + `Test-PopeyeVerificationVm.ps1` | extend |
| NET-04 | PG RFC1918 + 5432; gateway FQDN -> 10.60.0.108 + 443 | VM-side | `Test-PopeyeVerificationVm.ps1` (add gateway FQDN) | extend |
| NET-05 | no public IP, NSG 3389 only from Bastion subnet, Entra login | control-plane | `Test-PopeyeAzureVerificationVm.ps1` (add NSG source check) | extend |
| NET-06 | login roles limited | control-plane | same | extend |
| GW-01 | pin = v1.106.x + digest in running revision | integration | `az containerapp show` image check + `/health/readiness` + `/health/liveliness`; TF validation | Wave 0 |
| GW-02 | CI fails on affected pin | unit/fixture | `python scripts/Test-LitellmAdvisoryRange.py --self-test` (v1.100.3 fail, v1.106.2 pass) + workflow step | Wave 0 |
| GW-03 | mgmt routes 403, UI locked | integration (VM) | `pwsh scripts/Test-PopeyeGatewayLockdown.ps1` | Wave 0 |
| GW-04 | PID1 is litellm; SIGTERM flush; probe path; grace | integration | revision swap with N sent = N rows; `az containerapp show` spec check | Wave 0 |
| GW-05 | rendered config has TTL <= 30, client creds false, LOG=ERROR, no cache | static | grep/parse of `terraform console`/rendered YAML; startup log line check | Wave 0 |
| GW-06 | Redis counters shared, public disabled | integration | `az redis`/`az resource show` publicNetworkAccess; replica exec key listing; 422 on both replicas | Wave 0 |
| MVP-01 | one attributed row | e2e | `Invoke-PopeyeSmoke.ps1` then `Test-PopeyeVerificationPsql.ps1 -RequestId` | Wave 0 |

### Sampling Rate
- **Per task commit:** quick run command (fmt, validate, advisory self-test)
- **Per wave merge:** quick + any control-plane script runnable from the workstation
- **Phase gate:** all VM-side scripts green with evidence files in `artifacts/` before `/gsd-verify-work`

### Wave 0 Gaps
- [ ] `scripts/Test-LitellmAdvisoryRange.py` + `config/litellm-advisory-ranges.json` + fixtures
- [ ] `envs/azure-eastus2/litellm-pin.auto.tfvars` + `.gitignore` negation
- [ ] `scripts/Test-PopeyeGatewayLockdown.ps1`, `scripts/Invoke-PopeyeSmoke.ps1`
- [ ] `sql/ai_usage_grants_azure.sql`
- [ ] Extend `Test-PopeyeVerificationPsql.ps1` with `-RequestId`/key-hash assertions (read-only SELECT only)
- [ ] `.gitignore` entries for raw evidence (`artifacts/*.raw*`, `artifacts/**/*.tmp`)

## Security Domain

### Applicable ASVS Categories
| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes | Master key only in KV; `disable_env_credential_login`; UI disabled |
| V3 Session Management | limited | No UI sessions obtainable |
| V4 Access Control | yes | Explicit `allowed_routes`; KV secret-scope RBAC, time-boxed; NSG source scoping |
| V5 Input Validation | limited | TF variable regex validation for tag/digest |
| V6 Cryptography | yes | No custom crypto; salt key untouched; TLS to Redis (`ssl: true`) and Postgres (`sslmode=require`) |
| V7/V8 Logging & data protection | yes | `LITELLM_LOG=ERROR`, `store_prompts_in_spend_logs: false`, redacted evidence |

### Known Threat Patterns
| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Known-vulnerable gateway version | Elevation | Digest pin + CI range gate |
| User key reaching management/utility routes | Elevation | Explicit `allowed_routes`; negative tests |
| `/proc/self/environ` disclosure | Info disclosure | Patched version; `/utils/*` closed |
| Public Redis | Info disclosure/Tampering | PE + public Disabled |
| Master key exposure during ceremony | Info disclosure | Time-boxed secret-scope grant; runtime-only; no disk/log; KV audit refs |
| Internet-sourced RDP rule | Elevation | Networking removes `Allow_Iliya_Promenet`; verified by script |
| Evidence leaking identifiers/keys/prompts | Info disclosure | Redaction; gitignore for raw outputs; synthetic prompt |
| Silent loss of shared counters | Tampering (budget bypass) | Explicit coordination_redis + verification |

## Sources

### Primary (HIGH confidence)
- LiteLLM source at tag `v1.106.2` (raw.githubusercontent.com): `proxy_server.py` (lifespan shutdown, coordination Redis, cache TTL, login), `proxy/_types.py` (`LiteLLMRoutes`, `GenerateKeyRequest`), `proxy/auth/route_checks.py`, `proxy/auth/auth_utils.py`, `proxy/auth/master_key_boot_check.py`, `proxy/management_endpoints/key_management_endpoints.py`, `proxy/common_utils/admin_ui_utils.py`, `proxy/management_endpoints/ui_sso.py`, `constants.py`, `schema.prisma`
- GitHub security advisories API for BerriAI/litellm (fetched 2026-10-22); releases API; GHSA-7hp6 advisory page
- GHCR anonymous manifest HEAD for `v1.106.2` (digest above)
- https://learn.microsoft.com/en-us/azure/redis/private-link (subresource `redisEnterprise`, port 10000, zone)
- https://learn.microsoft.com/en-us/azure/redis/architecture (clustering policies)
- azurerm docs (`managed_redis`: `clustering_policy` default `OSSCluster`; `container_app`: `termination_grace_period_seconds`)
- Repo files read: `modules/*`, `envs/azure-eastus2/*`, `sql/ai_usage_grants.sql`, scripts, CI workflows, artifacts, `.planning/research/*`

### Secondary (MEDIUM confidence)
- https://docs.litellm.ai/docs/proxy/prod, `/virtual_keys`, `/ui` (DISABLE_ADMIN_UI statement)

### Tertiary (LOW confidence)
- Prisma advisory-lock behavior; Container Apps `tag@digest` acceptance; Redis policy compatibility (all flagged in Assumptions)

## Metadata

**Confidence breakdown:**
- Standard stack / pin: HIGH - versions, digest and advisories pulled from live sources today
- Architecture / Terraform patterns: MEDIUM-HIGH - standard azurerm resources, not applied here
- Redis cluster compatibility: MEDIUM-LOW - needs the spike
- Pitfalls 2, 3, 4: HIGH - read directly in 1.106.2 source

**Research date:** 2026-10-22
**Valid until:** 2026-10-29 for the pin and advisory data (LiteLLM ships patches weekly; re-check on apply day); 30 days for the rest
