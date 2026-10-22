# Stack Research

**Domain:** AI gateway governance control plane (LiteLLM on Azure Container Apps). This milestone adds an agent-key issuer/introspection service, ledger attribution, Stage 1 measurement, Entra/Intune automation, and a DLP/guardrail evaluation.
**Researched:** 2026-10-22
**Confidence:** HIGH for LiteLLM behavior (verified in LiteLLM source at the pinned tag `v1.90.3` and re-checked at `v1.106.2`) and for library versions (PyPI/PSGallery/registry, queried 2026-10-22). MEDIUM for the Intune and guardrail operational choices.

Scope note: this file covers only the additions. It doesn't re-cover the existing Terraform stack (azurerm 4.80.0 lock, Postgres 16 Flexible Server, Managed Redis, Key Vault, UAMI, Log Analytics/App Insights).

---

## Headline Findings (read these first)

1. **Key metadata does not reach `LiteLLM_SpendLogs` on its own.** `SpendLogs.metadata` is filtered to a fixed `SpendLogsMetadata` TypedDict. Arbitrary key `metadata.*` (for example `metadata.principal_type`) is dropped. Only these reach the ledger row: `metadata.spend_logs_metadata` (nested dict), `user_api_key_alias`, `user_api_key_user_id`, `user_api_key_team_id`, the `api_key` hash, `request_tags`, `session_id`, `agent_id` (native column), and `end_user`. (HIGH, from `litellm/proxy/spend_tracking/spend_tracking_utils.py` and `_types.py::SpendLogsMetadata`)
2. **Callers can spoof request-level `spend_logs_metadata`.** In `litellm_pre_call_utils.py`, key-level `spend_logs_metadata` is merged with the comment *"don't override k-v pair sent by request"*. A caller who sends `x-litellm-spend-logs-metadata: {"on_behalf_of":"someone-else"}` (or the same key in body `metadata`) wins. This holds at both v1.90.3 and v1.106.2. **A Popeye `async_pre_call_hook` must re-stamp the identity fields from the authenticated key.** It runs after `add_litellm_data_to_request`, so it gets the last word. (HIGH)
3. **`key_alias` is the strongest, non-spoofable carrier for `key_id`.** It comes from the key record, lands in `SpendLogs.metadata.user_api_key_alias`, LiteLLM enforces it as unique, and `/key/delete` accepts `key_aliases`. Set `key_alias = <key_id UUID>`. (HIGH)
4. **The pinned `v1.90.3` (2026-07-03) is outside LiteLLM's support window.** LiteLLM now supports only the four most recent stable minor lines (1.103 to 1.106 as of today). Since 1.84.0 the `-stable` suffix no longer exists: `v1.90.3-stable` returns 404 on GHCR and `v1.90.3` returns 200. `terraform.tfvars.example` still says "a specific -stable tag" and needs correcting. (HIGH)
5. **Gateway-side enforcement needs custom Python inside the LiteLLM container.** That covers `direct_gateway=false`, relay validation, `relayed_by`, and the metadata re-stamp. In practice this means a **derived image** (`FROM ghcr.io/berriai/litellm:<tag>` plus a `popeye_hooks.py`) in a new **Azure Container Registry**. The issuer image needs the ACR anyway. (HIGH that a hook is required; MEDIUM on ACR SKU)
6. **"Reachable on the gateway FQDN" maps to Container Apps rule-based routing.** The resource is `Microsoft.App/managedEnvironments/httpRouteConfigs`, which is GA at API `2026-07-01`. **azurerm (4.x and 5.10.0) has no resource for it, so it needs the `azapi` provider (2.13.0).** (HIGH)

---

## Recommended Stack

### Core Technologies

| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| LiteLLM proxy (gateway) | Upgrade the pin from `v1.90.3` to the latest **1.106.x** patch (`v1.106.2` released 2026-10-21) **before** building hooks against it | Key generation, auth, budgets, spend ledger | 1.90 is unsupported. The hook and spend-log code paths are the same in 1.106.2, so build once on a supported line. Pin by tag **and** digest in the derived image | HIGH |
| Python | 3.13.x (`python:3.13-slim-bookworm`, pinned by digest) | Issuer service, LiteLLM hook module, measurement CLI | Every chosen library supports it (pydantic-settings, SQLAlchemy and locust now need 3.11+; Presidio caps at <3.15). 3.12 is security-fix-only. The LiteLLM hook runs on the LiteLLM image's own interpreter, so keep hook code stdlib-only | HIGH |
| FastAPI | 0.160.0 | Issuer HTTP API (exchange, revoke, introspect) | The stated constraint ("FastAPI-style"). Pydantic models give the strict request schemas that the distinct-error REQs need (REQ-AGT-07). Same framework as LiteLLM itself, so one operational idiom | HIGH |
| Uvicorn | 0.54.0 (`uvicorn[standard]`) | ASGI server | Standard FastAPI server. Run 1 worker per container and scale with Container Apps replicas (≥2), matching the gateway posture | HIGH |
| Pydantic | 2.14.1 | Request/response models, strict validation (`extra="forbid"`, UUID types) | `extra="forbid"` turns a stray `on_behalf_of` into a deterministic error. REQ-AGT-06 actually says *ignore*, so use `extra="ignore"` on the exchange body and test it explicitly | HIGH |
| pydantic-settings | 2.16.1 | Env-var config (Key Vault-referenced secrets arrive as env) | Same env-var delivery pattern as the gateway's Container Apps secrets | HIGH |
| httpx | 0.28.1 | Async client to the LiteLLM admin API (`/key/generate`, `/key/info`, `/key/delete`) | Async, timeouts and HTTP/2. Mockable with respx. **Don't import the `litellm` package into the issuer.** Talk REST over the internal FQDN | HIGH |
| psycopg (3) + psycopg-pool | 3.3.6 / 3.3.3 (`psycopg[binary,pool]`) | Issuer's own tables (issuance events, introspection events, key_id ↔ token-hash map, revocation state) | One driver for the async service, sync scripts (measurement, migrations) and tests. Server-side parameter binding plus `psycopg.sql` composition. Simpler than asyncpg + a second sync driver | HIGH |
| PostgreSQL | Existing Flexible Server 16, **new database `popeye_issuer`** with its own role | Issuer persistence | **Don't put issuer tables in the `litellm` database.** LiteLLM runs Prisma migrations on every boot (`migrate deploy` by default, `db push --accept-data-loss` if anyone ever flips `--use_prisma_db_push`), and LiteLLM ships weekly. A separate database removes that risk. Ledger joins don't need cross-db queries because `key_id` rides on the SpendLogs row (see Pattern A) | HIGH (risk), MEDIUM (separate DB vs. separate schema) |
| azapi Terraform provider | 2.13.0 (`Azure/azapi ~> 2.13`) | `httpRouteConfigs` so `/popeye/*` and `/` share the gateway FQDN | Not in azurerm. GA API version `2026-07-01`. Requires a workload-profile environment, and the existing env already has a `Consumption` workload profile | HIGH |
| azurerm (existing) | stay on `~> 4.0` (lock 4.80.0; 4.81.0 is the last 4.x seen) | `azurerm_container_app` (issuer), `azurerm_container_registry`, role assignments | **Don't jump to azurerm 5.x mid-milestone** (5.10.0 is current). It's a major version against applied resources with `prevent_destroy` | HIGH |

### Supporting Libraries (issuer service)

| Library | Version | Purpose | When to Use | Confidence |
|---------|---------|---------|-------------|------------|
| azure-monitor-opentelemetry | 1.8.11 | App Insights traces/metrics/logs from FastAPI | Always. One `configure_azure_monitor()` call. Set `OTEL_` sampling and **never log request bodies or Authorization headers** | HIGH |
| opentelemetry-instrumentation-psycopg | match distro | DB spans for psycopg 3 | The azure distro bundles psycopg2 instrumentation, not psycopg 3 | MEDIUM |
| azure-identity | 1.26.0 | `ManagedIdentityCredential(client_id=...)` | Only if you choose Entra auth to Postgres or call Key Vault at runtime. The default path is Container Apps Key Vault secret references (no SDK) | HIGH |
| structlog | 26.1.0 | Structured JSON logs with a redaction processor | Use one processor that drops `authorization`, `key`, `x-popeye-relay-key` and any `sk-` substring. This is the sentinel test's enforcement point (REQ-AGT-12) | MEDIUM (stdlib `logging` + python-json-logger 4.2.0 is fine too; pick one) |
| PyYAML | latest 6.x | Load agent-ID, introspection-caller and relay registries (vendored-vocabulary checked) | Registries ship in the image at build time. CI validates them with the existing `jsonschema==4.26.0` job | HIGH |
| uuid (stdlib) | — | `key_id` = `uuid.uuid4()`, lowercased via `str()` | v4 satisfies REQ-AGT-20 with no dependency. `uuid.uuid7()` exists only in Python ≥3.14, so use v4 on 3.13 | HIGH |

### LiteLLM-side additions (gateway container)

| Item | Version / Setting | Purpose | Confidence |
|------|-------------------|---------|------------|
| `popeye_hooks.py`, a `CustomLogger` subclass with `async_pre_call_hook` | Built into derived image `<acr>.azurecr.io/popeye-gateway:<litellm-tag>-p<n>` | (a) overwrite `data["metadata"]["spend_logs_metadata"]` identity keys (`principal_type`, `agent_id`, `on_behalf_of`, `key_id`, `purpose`, `tenant_id`) from `user_api_key_dict.metadata`; pass through only client-supplied `run_id`; (b) enforce `direct_gateway=false` by reading the relay header from `data["proxy_server_request"]["headers"]` and checking its SHA-256 against registered relay key hashes, raising a distinct error; (c) stamp `relayed_by`; (d) enforce the purpose/class prohibition (REQ-PUR-07) | HIGH (hook API and order verified in source) |
| `litellm_settings.callbacks: popeye_hooks.proxy_handler_instance` | config | Registers the hook. The module must be importable from the config file's directory or on `PYTHONPATH`. The current config is written to `/tmp/litellm.yaml`, so set `PYTHONPATH=/app/popeye` in the image | HIGH |
| `general_settings.user_api_key_cache_ttl` | set explicitly (≤ 30) | The per-replica in-memory key cache defaults to **60 s**. Revocation via `/key/delete` invalidates only the handling replica's cache, so other replicas may honor a revoked key for up to the TTL. Setting it explicitly makes the "within 60 s" REQ-AGT-16 bound true for the gateway too | HIGH (default verified), MEDIUM (exact cross-replica invalidation path) |
| `general_settings.proxy_batch_write_at` | default **10 s** (`PROXY_BATCH_WRITE_AT`) | Spend-log rows are batch-flushed. This is the floor for "ledger freshness" in Stage 1 measurement. Record it as a config value in `STAGE1_BASELINES.md`, not as a surprise | HIGH |
| `litellm_settings.disable_add_user_agent_to_request_tags` | `true` (recommended) | Keeps `request_tags` to Popeye-controlled tags. The User-Agent string otherwise lands in every ledger row | MEDIUM |

### Infrastructure (Terraform additions)

| Resource | Purpose | Notes | Confidence |
|----------|---------|-------|------------|
| `azurerm_container_registry` | Hosts `popeye-issuer` and the derived `popeye-gateway` images | `admin_enabled = false`, pull via UAMI `AcrPull`. Use **Standard** if public endpoint + Entra-only auth is acceptable. Use **Premium** if policy requires `public_network_access_enabled = false` + private endpoint (only Premium supports that). Decide in the phase | HIGH (SKU facts), MEDIUM (which SKU) |
| `azurerm_user_assigned_identity` (issuer) + `azurerm_role_assignment` (`AcrPull`, `Key Vault Secrets User`) | Separate identity from the gateway | Keeps blast radius separate. The issuer can read only its own secrets (`issuer-litellm-admin-key`, `issuer-db-dsn`) | HIGH |
| `azurerm_container_app` (issuer) | Second app in the **existing** env | `workload_profile_name = "Consumption"`, `revision_mode = "Single"`, `min_replicas = 2`, `ingress { external_enabled = false, target_port = 8080 }`. Image pinned by variable with no default and `latest` rejected (copy the gateway's validation block). Liveness/readiness probes on `/healthz` and `/readyz` | HIGH |
| `azapi_resource` `Microsoft.App/managedEnvironments/httpRouteConfigs@2026-07-01` | One host: `/popeye/` → issuer (`prefixRewrite: /`), `/` → gateway | Bind `customDomains` to `gateway-azure.ai.twg.internal` once the DNS ownership decision lands (an MVP item already). Rules are order-sensitive, so the more specific prefix goes first. **Warning (Microsoft docs):** a route can expose an internal-ingress app, and any principal with `httpRouteConfigs/write` on the env can create routes. Lock that permission down | HIGH |
| `azurerm_container_app_job` (optional) | Run issuer SQL migrations and the Stage 1 measurement harness inside the VNet | Avoids needing a jump VM for psql. Manual trigger | MEDIUM |
| `azurerm_postgresql_flexible_server_database` `popeye_issuer` | Issuer DB | Role and grants via versioned SQL (pattern of `sql/ai_usage_grants.sql`) | HIGH |

### Development and Test Tools

| Tool | Version | Purpose | Notes | Confidence |
|------|---------|---------|-------|------------|
| uv | 0.13.5 | Dependency resolution and `uv.lock` for the issuer | Locked, reproducible builds. Use `uv sync --frozen` in the Dockerfile builder stage | HIGH |
| pytest | 9.1.1 | Test runner | REQ/TC IDs as markers (`@pytest.mark.tc("TC-AGT-08")`) so CI can report per-TC, matching the repo's spec-driven style | HIGH |
| pytest-asyncio | 1.4.0 | Async tests | Set `asyncio_mode = "auto"`. 1.x removed the old `event_loop` fixture, so don't copy pre-1.0 examples | HIGH |
| testcontainers | 4.15.0 (`testcontainers[postgres]`) | Real Postgres 16 plus a **real pinned LiteLLM container** for contract tests | Highest-value tests: spin `postgres:16` + `ghcr.io/berriai/litellm:<pinned>` (or the derived image) with a config whose model uses `mock_response`, then assert real `SpendLogs` rows carry `key_id`/`principal_type` and that spoofed headers are overwritten. Catches LiteLLM behavior drift on every image bump. Needs Docker (GitHub ubuntu runners have it; Windows dev needs Docker Desktop) | HIGH |
| respx | 0.23.1 | Mock LiteLLM admin API in fast unit tests | For error-mapping tests (LiteLLM 4xx/5xx → stable contract errors) | HIGH |
| hypothesis | 6.170.5 | Property tests: `key_id` format/uniqueness, TTL clamp `min(req, 8h)` | Optional but cheap for REQ-AGT-08/20 | MEDIUM |
| ruff | 0.17.1 | Lint + format | One tool. Add to the existing CI workflow | HIGH |
| mypy | 2.4.0 | Type checking | Strict on the issuer package only | MEDIUM |
| Pester | 6.2.0 | Tests for the PowerShell automation | Runs on Windows PowerShell 5.1 and PowerShell 7.4+. Repo currently has no Pester, so this is a new CI job. Check the "Upgrading from v5" notes if any v5 examples get copied | MEDIUM |
| PSScriptAnalyzer | 1.25.0 | PowerShell lint | Add to CI next to Pester | HIGH |

### Stage 1 measurement tooling

| Tool | Version | Purpose | Why | Confidence |
|------|---------|---------|-----|------------|
| Custom Python CLI `popeye-measure` (httpx + psycopg + stdlib `statistics`) | — | Latency overhead, budget counter lag, ledger freshness, ledger interruption, budget-vs-throttle payload capture | The protocol is correlation-heavy, not load-heavy. Each probe needs response headers plus a Postgres poll. Off-the-shelf load tools don't do the DB side. Output JSON evidence in the same shape as `artifacts/*evidence.json` | HIGH |
| LiteLLM response headers | built-in | `x-litellm-overhead-duration-ms` (gateway overhead, measured server-side), `x-litellm-response-duration-ms`, `x-litellm-timing-*-ms`, `x-litellm-key-spend`, `x-litellm-key-max-budget`, `x-litellm-call-id` | Overhead comes straight from the gateway without a direct-to-Foundry baseline (still do the A/B for the SLO). `SpendLogs.metadata.litellm_overhead_time_ms` stores the same value per row | HIGH |
| Correlation key for freshness | — | `SpendLogs.request_id` = the provider response `id` (`chatcmpl-...`), falling back to `litellm_call_id` | Poll `SELECT "startTime","endTime" FROM "LiteLLM_SpendLogs" WHERE request_id = $1` and measure insert time minus response time. Expect ≥ `proxy_batch_write_at` (10 s) | HIGH |
| locust | 2.47.0 | Only if a concurrency/throughput number is required for the SLO | Not needed for the five listed measurements. Defer | MEDIUM |

### Entra / Graph + Intune automation (PowerShell)

| Module | Version | Purpose | Notes | Confidence |
|--------|---------|---------|-------|------------|
| Microsoft.Graph.Authentication | 2.41.2 | `Connect-MgGraph -Identity` (managed identity) or certificate app auth | Don't use the full `Microsoft.Graph` meta-module (slow import, 40+ submodules). Import only the submodules below | HIGH |
| Microsoft.Graph.Groups | 2.41.2 | `Get-MgGroupMember -All`, or the members **delta** query (`/groups/{id}/members/delta`) for joiner/leaver | Delta gives true joiner/leaver events. Persist the delta link between runs. App permission `GroupMember.Read.All` | HIGH (module), MEDIUM (delta-link persistence location) |
| Microsoft.Graph.Beta.DeviceManagement | 2.41.2 | Intune platform script (`deviceManagementScripts`) or Settings Catalog policy to set the gateway base URL | **Beta API.** Microsoft says /beta isn't recommended for production. Treat it as a contained, versioned risk. Permission `DeviceManagementConfiguration.ReadWrite.All`, and the tenant needs an active Intune license | MEDIUM |
| Az.Accounts / Az.KeyVault | 5.5.3 / 6.6.1 | Resolve the LiteLLM admin credential from Key Vault (`-MasterKeySecretUri` already in the script signature) | Or call the Key Vault REST API with the MI token. Either way, never write the key to disk or transcript | HIGH |

`provision-desktop-keys.ps1` should call LiteLLM `/key/generate` directly. It mints **user** keys, not agent keys, so it doesn't go through the issuer. Set `metadata.principal_type = "user"`, `metadata.tenant_id` (UUID-validated, REQ-DCE-07), `metadata.spend_logs_metadata` (same stamp), `key_alias = "user:<entra-object-id>"`, and `user_id = <entra object id>`. Revoke leavers with `/key/delete {"key_aliases": [...]}`.

### Guardrail / DLP evaluation candidates (LiteLLM built-ins; no new Popeye code)

| Option | How it runs | Fits constraints? | Recommendation | Confidence |
|--------|-------------|-------------------|----------------|------------|
| `litellm_content_filter` (built-in regex/keyword, MASK or BLOCK) | In-process, no extra service | Yes: no external call, ~zero latency, ships with patterns for US SSN, cards, email, phone, IBAN, secrets (`aws_access_key`, `github_token`, `generic_api_key`) | **Evaluate first.** Cheapest baseline for PII masking and secret-leak blocking | HIGH (exists), MEDIUM (quality) |
| Presidio (`guardrail: presidio`, analyzer + anonymizer) | Two extra Container Apps: `mcr.microsoft.com/presidio-analyzer:2.2.362` and `presidio-anonymizer:2.2.362` (PyPI is at 2.2.364; MCR images lag slightly) | Yes: internal-only, no keys, Microsoft-maintained | **Evaluate second** for NER-grade PII. Adds a network hop per request, so measure p95 overhead in the same harness | HIGH |
| Azure AI Content Safety Prompt Shields (`azure/prompt_shield`) | Managed Azure service | **Conflict:** LiteLLM's integration authenticates with `Ocp-Apim-Subscription-Key` only (verified in `guardrail_hooks/azure/base.py`), not managed identity. It would need a key in Key Vault, an exception to the "managed identity only" rule. It also sends prompt text to another service | Evaluate only with an explicit exception decision | HIGH (auth fact) |
| LiteLLM `prompt_injection_detection` (heuristics, optional LLM check) | In-process | Heuristic mode yes. LLM-check mode adds a model call per request | Low-cost baseline for the prompt-injection half of the evaluation | MEDIUM |

**Must-test for any guardrail:** `SpendLogs.metadata.guardrail_information` includes `guardrail_request` and `guardrail_response` fields, and `masked_entity_count`. These may carry prompt fragments into the ledger even with `store_prompts_in_spend_logs: false`. Run the sentinel-string test against the ledger before any "go" recommendation. (MEDIUM: fields verified, redaction behavior unverified)

---

## Key Patterns the Stack Implies (for ARCHITECTURE/roadmap)

**Pattern A: three-channel attribution on every agent key** (all set by the issuer at `/key/generate`):
- `key_alias = "<key_id>"` → `SpendLogs.metadata.user_api_key_alias`. Not spoofable, unique, and supports delete by alias.
- `metadata = {principal_type, agent_id, on_behalf_of, key_id, purpose, tenant_id, data_class_ceiling, direct_gateway, minted_by_token_hash, spend_logs_metadata: {same identity keys}}`. The hook re-stamps `spend_logs_metadata` from this on every request.
- `user_id = <on_behalf_of>` → `SpendLogs.user`. `agent_id = <agent_id>` (LiteLLM's native key column) → `SpendLogs.agent_id`. The key value beats the `x-litellm-agent-id` header. LiteLLM tolerates IDs not in its A2A `LiteLLM_AgentsTable` (verified in `auth_checks.py`), but its semantics are A2A-oriented, so treat this as a mirror, not the source of truth. (MEDIUM)

**Pattern B: issuer authenticates callers through LiteLLM, never with its own credential store.** Exchange: call `GET /key/info` **with the caller's own bearer** (self-lookup is supported when `key` is omitted) and require `metadata.principal_type == "user"`. Introspection: the caller's key must be in the registered introspection-caller list. Look up the presented agent key with the issuer's admin credential (`/key/info?key=<presented>`). Map 404, expired, `blocked`, or non-agent to bare `{"active": false}`. `/key/info` and `/key/delete` accept either the raw `sk-` key or its SHA-256 hex hash, so the issuer stores only `token` hashes, never secrets. Verify that default `key_type` user keys are allowed to call `/key/info` in the phase. (HIGH for API, MEDIUM for route permission)

**Pattern C: use a dedicated issuer admin credential, not `LITELLM_MASTER_KEY`.** Mint a proxy-admin virtual key for the issuer (stored in KV, rotatable, shows as `created_by`) so the master key stays only in the gateway. (MEDIUM: confirm the minimum role that permits generate/info/delete for other users' keys)

---

## Installation

```bash
# Issuer service (pyproject.toml managed by uv)
uv add "fastapi==0.160.0" "uvicorn[standard]==0.54.0" "pydantic==2.14.1" \
       "pydantic-settings==2.16.1" "httpx==0.28.1" \
       "psycopg[binary,pool]==3.3.6" "azure-monitor-opentelemetry==1.8.11" \
       "structlog==26.1.0" "pyyaml"

# Dev / test
uv add --dev "pytest==9.1.1" "pytest-asyncio==1.4.0" "testcontainers[postgres]==4.15.0" \
             "respx==0.23.1" "hypothesis==6.170.5" "ruff==0.17.1" "mypy==2.4.0"
```

```powershell
# Automation (pin RequiredVersion in scripts and CI)
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Groups, Microsoft.Graph.Beta.DeviceManagement -RequiredVersion 2.41.2 -Scope CurrentUser
Install-Module Pester -RequiredVersion 6.2.0 -Scope CurrentUser
Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser
```

```hcl
# envs/azure-eastus2/versions.tf addition
azapi = { source = "Azure/azapi", version = "~> 2.13" }
```

---

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| FastAPI | Litestar / Flask | Never for this repo. The constraint names FastAPI-style, and LiteLLM is FastAPI |
| psycopg 3 + raw SQL | SQLAlchemy 2.1 (+ Alembic) | If the issuer grows past ~5 tables or needs an ORM. Today it's 3–4 append-mostly tables |
| psycopg 3 | asyncpg 0.32 | If profiling shows driver overhead matters (it won't at issuance volumes) |
| Versioned SQL files + tiny runner (or Container Apps Job) | Alembic | If the team already standardizes on Alembic elsewhere |
| `httpRouteConfigs` via azapi | LiteLLM `pass_through_endpoints` forwarding `/popeye/*` to the issuer | Only if azapi is unacceptable. Pass-through puts LiteLLM in the issuance path and logs pass-through calls into `SpendLogs`, polluting the ledger with non-model rows |
| `httpRouteConfigs` via azapi | Separate issuer hostname (`issuer.ai.twg.internal`) | If the program accepts amending "on the gateway FQDN" (v0.4.1 §2.1). Simpler Terraform, but a spec change under change control |
| Derived LiteLLM image in ACR | Delivering `popeye_hooks.py` as a Container Apps secret, `printf`'d to `/tmp` (the ADR-002 pattern) | Don't. Code in secrets bypasses image review/scan and makes hooks drift from the pinned base |
| `async_pre_call_hook` (CustomLogger) | `general_settings.custom_auth` | Don't. `custom_auth` replaces LiteLLM's key auth entirely and would make Popeye re-implement budgets and model access |
| UUIDv4 `key_id` | UUIDv7 | When the runtime moves to Python ≥3.14 (stdlib `uuid.uuid7`). Spec allows either |
| Key Vault-referenced DSN (password role) for `popeye_issuer` | Entra auth to Postgres with the issuer UAMI | Preferable long-term (no password), but the server currently has password auth only. Enabling Entra auth on an applied `prevent_destroy` server is its own change. Defer unless the phase has slack |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| Arbitrary key `metadata.*` as the ledger attribution channel | Doesn't reach `LiteLLM_SpendLogs` (filtered to `SpendLogsMetadata`) | `metadata.spend_logs_metadata` + `key_alias` + `user_id` + native `agent_id` (Pattern A) |
| Trusting request-supplied `spend_logs_metadata` / `x-litellm-spend-logs-metadata` / `x-litellm-agent-id` | Request values override key values (verified at v1.90.3 and v1.106.2). Callers can forge `on_behalf_of` in the ledger | The Popeye pre-call hook re-stamps from the authenticated key. Whitelist only `run_id` from the request |
| LiteLLM token hash as `key_id` | It's SHA-256 hex, not a UUID (REQ-AGT-20). Also, `/key/regenerate` changes it | Issuer-minted UUIDv4 stored in alias + metadata, mapped to the hash in `popeye_issuer` |
| `-stable` image tags / `main-stable` / `latest` | `-stable` suffix dropped since 1.84.0 (404 on GHCR). `main-stable` is being retired | `vX.Y.Z` tag + digest |
| `litellm` Python package inside the issuer | Huge dependency tree with weekly churn. Couples the issuer to internals | REST over httpx, with contract tests against the real container |
| Issuer tables in the `litellm` database `public` schema | Prisma owns that schema and runs migrations on every boot | Separate `popeye_issuer` database |
| Container Apps built-in auth (Easy Auth / Entra) on the issuer | Callers (nono, hometown, olive) authenticate with LiteLLM virtual keys, not Entra tokens (v0.4.1 §2.6: Entra-token exchange is a later stage) | Pattern B |
| `/key/regenerate` with `grace_period` for agent keys | Keeps the old secret valid and changes the token hash. Revocation semantics get murky | Mint new, delete old |
| Full `Microsoft.Graph` meta-module; AzureAD / MSOnline modules | Slow load. AzureAD/MSOnline are retired | Targeted `Microsoft.Graph.*` 2.41.2 submodules |
| Locust/k6 as the primary Stage 1 tool | Doesn't measure the DB side (ledger freshness, counter lag) | `popeye-measure` CLI |

## Stack Patterns by Variant

**If the DNS decision lands `gateway-azure.ai.twg.internal`:**
- Bind it on the `httpRouteConfigs` resource's `customDomains` (needs an environment certificate), not on the gateway app. Point the private DNS A record at the environment's static IP.
- Because then `/` → gateway and `/popeye/*` → issuer share the host, satisfying v0.4.1 §2.1 and v0.4.2 §2.1 with no spec change.

**If ACR must have no public endpoint:**
- Use the Premium SKU + private endpoint + `privatelink.azurecr.io` zone, and build/push from a self-hosted runner or ACR Tasks with a private agent pool.
- Because GitHub-hosted runners can't reach a private-only registry.

**If the DLP evaluation says "go" on Presidio:**
- Add two internal Container Apps in the same env, `min_replicas = 2`, and configure `guardrails:` with `mode: pre_call` and a `presidio_score_thresholds` map.
- Because Presidio runs out-of-process. A single replica becomes a request-path SPOF that violates the min-2 rule.

## Version Compatibility

| Package A | Compatible With | Notes |
|-----------|-----------------|-------|
| LiteLLM `v1.106.x` | Postgres 16, Prisma migrations via `litellm-proxy-extras` | Upgrading from 1.90.3 runs schema migrations on boot (1.106 adds e.g. `SpendLogs.billing_agent_id`, and spend-log partitioning constants appear by default `day`). **Re-validate the hometown `ai_token_usage` reader and `ekg_cube_reader` grants after the bump.** Never rotate `LITELLM_SALT_KEY` during the upgrade |
| `popeye_hooks.py` | LiteLLM `CustomLogger.async_pre_call_hook(user_api_key_dict, cache, data, call_type)` | Signature verified at 1.90.3. Contract-test it on every LiteLLM tag bump (testcontainers) |
| pydantic-settings 2.16.1 | Python ≥3.11 | Rules out 3.10 |
| Presidio 2.2.36x | Python <3.15 | Only matters if Presidio is pip-installed. The MCR images are self-contained |
| pytest-asyncio 1.4.0 | pytest 9.x | 1.x API (no `event_loop` fixture) |
| azapi 2.13.0 | azurerm 4.x, Terraform ≥1.7 | Coexist in one root module. Add to `.terraform.lock.hcl` with `terraform providers lock -platform=windows_amd64 -platform=linux_amd64` (CI is Linux, dev is Windows) |
| Pester 6.2.0 | Windows PowerShell 5.1, pwsh 7.4+ | Matches the repo's dual-shell reality |

## Sources

- LiteLLM source at tag `v1.90.3` (sparse clone) — `schema.prisma` (`LiteLLM_SpendLogs`, `LiteLLM_VerificationToken`, `LiteLLM_AgentsTable`), `proxy/_types.py` (`GenerateRequestBase`, `KeyRequestBase`, `GenerateKeyResponse`, `KeyRequest`, `SpendLogsMetadata`), `proxy/litellm_pre_call_utils.py` (header/key metadata precedence, agent_id resolution), `proxy/spend_tracking/spend_tracking_utils.py` (payload, `request_id`, `session_id`), `proxy/common_request_processing.py` (hook ordering), `integrations/custom_logger.py`, `proxy/management_endpoints/key_management_endpoints.py` (`/key/info` self-lookup, hash-or-raw, alias uniqueness), `proxy/auth/auth_checks.py`, `proxy/proxy_server.py` (`in_memory_cache_ttl = 60`), `constants.py` (`PROXY_BATCH_WRITE_AT = 10`), `proxy/db/prisma_client.py`, `guardrails/guardrail_hooks/{presidio.py, azure/base.py, litellm_content_filter}` — HIGH
- LiteLLM source at `v1.106.2` (raw GitHub) — precedence logic, SpendLogs columns, and cache TTL unchanged — HIGH
- GitHub releases API `BerriAI/litellm` and GHCR manifest checks (`v1.90.3` 200, `v1.90.3-stable` 404) — HIGH
- https://docs.litellm.ai/docs/proxy/release_cycle and https://docs.litellm.ai/blog/cleaner-release-versions — versioning, support window — MEDIUM (WebSearch summary, consistent with GHCR evidence)
- https://docs.litellm.ai/docs/proxy/virtual_keys, https://docs.litellm.ai/docs/proxy/cost_tracking — key endpoints, `spend_logs_metadata` — HIGH
- https://learn.microsoft.com/en-us/azure/container-apps/rule-based-routing — route model, internal-app exposure warning — HIGH
- https://learn.microsoft.com/en-us/azure/templates/microsoft.app/managedenvironments/httprouteconfigs — API versions (GA `2026-07-01`), azapi schema — HIGH
- terraform-provider-azurerm docs tree (no http route config resource), releases (v5.10.0 latest, v4.81.0 last 4.x seen) — HIGH
- registry.terraform.io `Azure/azapi` 2.13.0 — HIGH
- PyPI JSON API (all Python versions above), queried 2026-10-22 — HIGH
- MCR tag lists for presidio-analyzer/anonymizer — HIGH
- PowerShell Gallery API (Microsoft.Graph.* 2.41.2, Pester 6.2.0, PSScriptAnalyzer 1.25.0, Az.Accounts 5.5.3, Az.KeyVault 6.6.1); https://github.com/pester/Pester/releases — HIGH/MEDIUM
- https://learn.microsoft.com/en-us/graph/api/intune-devices-devicemanagementscript-create and the groupAssignments pages — Intune script API is beta — MEDIUM

---
*Stack research for: Popeye agent-key issuer, ledger attribution, Stage 1 measurement, fleet automation, DLP evaluation*
*Researched: 2026-10-22*
