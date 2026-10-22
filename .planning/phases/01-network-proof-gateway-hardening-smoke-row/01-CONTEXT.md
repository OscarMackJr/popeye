# Phase 1: Network Proof, Gateway Hardening & Smoke Row - Context

**Gathered:** 2026-10-22
**Status:** Ready for planning

<domain>
## Phase Boundary

This phase delivers three things:

1. **Network proof.** An approved caller in the peered `EUS-POPEYE-VNET-01` reaches the private Postgres ledger and the gateway's internal FQDN over VNet peering.
2. **Hardened gateway.** The gateway runs a patched LiteLLM 1.106.x, pinned by tag and digest, with management routes locked down and Redis private.
3. **Smoke row.** One synthetic `twg-foundry` completion lands exactly one attributed ledger row, verified through the read-only hometown path.

Requirements: NET-01..06, GW-01..06, MVP-01.

**Not in this phase:**
- Stable `gateway-azure.ai.twg.internal` and the issuer route config (Phase 4/5).
- The gateway hook / derived image (Phase 3).
- Ingress-level path blocking (comes with the route config in Phase 4/5).
- Stage 1 measurements (Phase 7).

**Network status at gathering time (2026-10-22):**
- Peering is Connected both ways.
- Postgres resolves to 10.60.2.5, and 5432 connects from `EUS-VM-POPEYE`.
- The Container Apps environment answers on 10.60.0.108:443.
- The environment domain `ashyglacier-edb44cd7.eastus2.azurecontainerapps.io` does **not** resolve. The private DNS zone is missing and has been requested from networking.

Evidence: `artifacts/popeye-peered-caller-connectivity-2026-10-22.md`.

</domain>

<decisions>
## Implementation Decisions

### Upgrade rollout
- **D-01:** Upgrade in place through `terraform apply` with the new tag and digest. Container Apps rolls a new revision. Brief disruption is acceptable, since there are no production callers yet.
- **D-02:** Before the upgrade apply, take or confirm an on-demand Postgres Flexible Server backup point. Prisma migrations on first boot of 1.106.x are one-way, so the documented rollback is restore-to-point plus re-pinning the previous tag. Write that rollback down before applying.
- **D-03:** On pin day, pin the **latest patched 1.106.x**.
  - Re-check the LiteLLM GHSA list that day.
  - Pin both the tag and the sha256 digest.
  - Never use 1.91.0–1.100.3: GHSA-7hp6-4w63-5g45 is exploitable in the default config there.
  - Fix `terraform.tfvars.example`, which still suggests the nonexistent `-stable` suffix.
- **D-04:** The GHSA-range check runs in the **existing `.github/workflows/terraform.yml`**. A script compares the pinned tag against a committed advisory-range file (no network call at CI time) and fails the PR on a match. Updating the range file is a manual, reviewed change.

### Admin access after lockdown
- **D-05:** The LiteLLM admin UI is **fully disabled** (`DISABLE_ADMIN_UI` or equivalent). All admin work goes through the API or scripts.
- **D-06:** Management routes are closed at the **key level now**. Every non-admin key is minted LLM-API-only (`allowed_routes` / `key_type: llm_api`). Negative tests prove that `/key/*`, `/user/*`, `/utils/*` and the UI return 401/403 for a user key. Ingress-level path restriction is deferred to the Phase 4/5 route config.
- **D-07:** Phase 1 admin scripts (minting the smoke key, applying the reader SQL) use the **master key from Key Vault, fetched at runtime only from the peered VM**. It is never written to disk, logs or tickets. A dedicated admin key arrives with the issuer in Phase 5.
- **D-08:** `POPEYE_VERIFICATION_VM_TEST_PROCEDURE.md` currently forbids operators and the VM from accessing the master key. **Amend that procedure** to allow a **time-boxed, recorded grant**:
  - The platform owner gets Key Vault Secrets User on the `litellm-master-key` secret only (secret scope, not vault scope).
  - The grant lasts only for the admin ceremony window (smoke key minting + reader SQL) and is removed afterwards.
  - Grant and removal timestamps go into the evidence, along with KV access log references.
  - All other secret restrictions in the procedure stay as they are: salt, `litellm-database-url`, writer.

### Smoke test mechanics
- **D-09:** The smoke key carries **forward-compatible attribution** that matches the later key-metadata model (G11/OID decision):
  - `principal_type=user`
  - `user_id` = platform owner's Entra object ID
  - canonical lowercase tenant UUID
  - `team_id=popeye-poc`
  - `key_alias=user:<oid>`
  - feature/request tag `mvp-smoke`
  - LLM-API-only routes
- **D-10:** The smoke key is minted with a **short duration (~24h) and a tiny budget**. Once evidence is recorded it is **blocked, not deleted**, so ledger joins survive.
- **D-11:** The smoke request runs from a **repo script** (e.g. `scripts/Invoke-PopeyeSmoke.ps1`) executed on `EUS-VM-POPEYE` via `az vm run-command invoke`.
  - Synthetic prompt content only.
  - The key is read from Key Vault at runtime and never echoed.
  - Output is redacted to the timestamp, `request_id`, HTTP status and model.
  - The script is repeatable.
- **D-12:** "Exactly one attributed row" is verified through the **read-only `ekg_cube_reader` path**: query `LiteLLM_SpendLogs` by `request_id`, reusing or extending `scripts/Test-PopeyeVerificationPsql.ps1`. This also proves the hometown read path.
- **D-13:** Neither the `litellm-reader-dsn` secret nor confirmation that the `ekg_cube_reader` role exists is in place today; Key Vault holds only master, salt, database-url and redis-password. Fix this as follows:
  - Terraform generates the reader password into Key Vault as `litellm-reader-dsn`.
  - The operator applies `sql/ai_usage_grants.sql` idempotently from the peered VM via run-command, during the time-boxed admin window.
  - The DB is private-only, so CI can't run the postgres provider.
  - Re-validate the grants **after** the upgrade's Prisma migrations.

### Env DNS zone + Redis private access
- **D-14:** The Container Apps environment private DNS zone follows **whatever networking replies** to the outstanding email:
  - The plan includes a ready, parameterized Terraform task (zone `ashyglacier-edb44cd7.eastus2.azurecontainerapps.io`, `*` and `@` A records → 10.60.0.108, links to both VNets, no auto-registration). It is executed **only** if networking hands ownership to Popeye.
  - Otherwise, Phase 1 only verifies networking's zone (resolution from `EUS-VM-POPEYE`).
  - Read the zone name and IP from the environment's outputs (`default_domain`, `static_ip`), not hardcoded.
- **D-15:** Redis goes private through **Terraform**:
  - a new non-delegated `snet-private-endpoints` in the free 10.60.3.0/24 (e.g. 10.60.3.0/27);
  - a Managed Redis private endpoint;
  - a `privatelink.redis.azure.net` zone linked to the **Stage 1/2 VNet only** (callers never need Redis);
  - then `managed_redis_public_network_access = "Disabled"`.
- **D-16:** **Sequencing:**
  1. Redis private endpoint, then disable public access.
  2. Verify the gateway is healthy and counters still work.
  3. Then the LiteLLM upgrade.

  Separate applies keep failures attributable.
- **D-17:** Peering ownership, the RDP NSG rule (`Allow_Iliya_Promenet`), and VM login role fixes (User Login for the two approved operators only) are **networking actions requested by email**. Phase 1 verifies them and records evidence. Popeye Terraform doesn't change them unless networking hands them over.

### Claude's Discretion
- Exact config-hardening mechanics:
  - `exec` in the container args;
  - readiness probe on `/health/readiness`;
  - termination grace ≥ `proxy_batch_write_at` + 10 s;
  - `user_api_key_cache_ttl` ≤ 30 s;
  - `allow_client_side_credentials: false`;
  - `LITELLM_LOG=ERROR`;
  - no response caching.
- How to verify that Redis backs budget counters across replicas (GW-06), e.g. by inspecting Redis keys during a burst from the peered VM, or by checking the cache settings LiteLLM reports. Never enable response caching to achieve it.
- Advisory-range file format and the check script language (PowerShell or Python, matching the existing CI).
- Evidence file naming under `artifacts/`, plus `.gitignore` entries so raw outputs containing identifiers aren't committed accidentally.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Project and requirements
- `.planning/PROJECT.md` — constraints and guardrails (no `latest`, ≥2 replicas, salt key, no prompt logging, managed identity)
- `.planning/REQUIREMENTS.md` — NET-01..06, GW-01..06, MVP-01 acceptance text
- `.planning/ROADMAP.md` — Phase 1 goal and success criteria
- `.planning/research/SUMMARY.md` — reconciled recommendations, upgrade trap, critical config
- `.planning/research/PITFALLS.md` — vulnerable pin, issuer bypass via native routes, `exec`/SIGTERM spend loss, Redis wiring, sentinel leakage
- `.planning/research/STACK.md` — LiteLLM version facts (`-stable` suffix removed, 1.106.x support window, cache TTL, batch write interval)

### Network
- `artifacts/popeye-peered-caller-connectivity-2026-10-22.md` — current network evidence and open findings
- `artifacts/popeye-azure-verification-evidence.json` — prior control-plane evidence (2026-10-21)
- `specs/POPEYE_VERIFICATION_VM_TEST_PROCEDURE.md` — procedure to amend per D-08
- `specs/POPEYE_NETWORK_VERIFICATION_PRIMER.md` — network verification background
- `specs/FISKROAD_NETWORK_ENGINEER_GUIDE_v0.3.md` — network design guide (DNS zone link gotcha)
- `scripts/Test-PopeyeAzureVerificationVm.ps1`, `scripts/Test-PopeyeVerificationVm.ps1`, `scripts/Test-PopeyeVerificationPsql.ps1` — existing verification scripts to extend for the peered-caller design

### Gateway and infrastructure
- `envs/azure-eastus2/main.tf` — root module; renders LiteLLM YAML (ADR-002); Redis wiring under `router_settings`
- `modules/gateway-service-azure/main.tf` — container `command`/`args` (no `exec`), probes, image reference
- `modules/gateway-service-azure/variables.tf` — `litellm_image_tag` validation (must stay strict)
- `modules/gateway-state-azure/main.tf`, `modules/gateway-state-azure/variables.tf` — Managed Redis, `managed_redis_public_network_access` (default `Enabled`)
- `envs/azure-eastus2/terraform.tfvars.example` — fix the `-stable` guidance
- `config/litellm.azure.example.yaml` — reference config; keep it in sync with the rendered config
- `specs/ADR-002-gateway-config-delivery.md` — config delivery mechanism
- `.github/workflows/terraform.yml` — CI to extend with the GHSA-range check

### Ledger
- `sql/ai_usage_grants.sql` — ledger bootstrap and `ekg_cube_reader` grants (apply per D-13)
- `specs/STAGE1_STAGE2_MVP_COMPLETION_CHECKLIST_v0.1.md` — Workstream 2 smoke-proof rules (synthetic content, redaction, evidence)
- `specs/STATE_BACKEND_ACCESS_CONFIRMATION_v0.1.md` — state sensitivity

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/Test-PopeyeVerificationPsql.ps1`: an authenticated read-only Postgres check. Extend it for the `request_id` row assertion (D-12).
- `scripts/Test-PopeyeAzureVerificationVm.ps1`: read-only control-plane checks with JSON evidence output. Adapt it for the peered caller VNet: `-VnetName`/`-ResourceGroupName` for the caller side, NSG source checks, login-role checks.
- `az vm run-command invoke` (RunPowerShellScript) on `EUS-VM-POPEYE` is proven to work from the platform owner's workstation. It's the runner for the smoke script and the reader SQL.
- The `managed_redis_public_network_access` module variable already exists. It only needs the private endpoint and DNS added before it's flipped.

### Established Patterns
- Hard Terraform validations (`litellm_image_tag` rejects `latest`/empty, `min_replicas >= 2`) are part of the design. Extend them, for example by validating the digest format, and never weaken them.
- Secrets reach the app through Key Vault references. Generated secrets live in Key Vault. Filled tfvars and the rendered `config/litellm.azure.yaml` are gitignored.
- Evidence goes in `artifacts/` and is redacted: no keys, DSNs or prompts.
- The salt key is `prevent_destroy` with ignored drift. The upgrade must not touch it.

### Integration Points
- Container `args` in `modules/gateway-service-azure/main.tf:123` currently runs `printf ... && litellm ...` under `sh -c`. Add `exec` before `litellm`.
- The rendered LiteLLM YAML in `envs/azure-eastus2/main.tf` gains `litellm_settings`/`general_settings` keys (cache TTL, client-side credentials off, UI disabled).
- The VNet `vnet-popeye-stage1-stage2-eastus2` (10.60.0.0/22) has `snet-containerapps` 10.60.0.0/23 and `snet-postgres` 10.60.2.0/24. 10.60.3.0/24 is free, for the private endpoint subnet.
- Container Apps environment: `popeye-stage1-stage2-eastus2-env`, internal, static IP 10.60.0.108, default domain `ashyglacier-edb44cd7.eastus2.azurecontainerapps.io`.
- Key Vault `kv-popeye-gw-98c2b71b` currently holds only `litellm-database-url`, `litellm-master-key`, `litellm-salt-key` and `redis-password`.

</code_context>

<specifics>
## Specific Ideas

- The smoke row should be *real* evidence for later phases. Its attribution shape (Entra object ID, `user:<oid>` alias, tenant UUID) intentionally matches the Phase 2 key-metadata decisions, so the row doesn't need to be redone.
- Every privileged action in this phase is a recorded, time-boxed ceremony. Grant and removal timestamps go into the evidence.
- The networking team's choice of peering is the adopted design. The email asking for the env DNS zone and cleanup has been drafted and sent or pending. The plan must handle either reply on DNS ownership.

</specifics>

<deferred>
## Deferred Ideas

- Ingress-level path restriction for LiteLLM management routes: Phase 4/5, with the `httpRouteConfig` on the stable FQDN.
- Dedicated proxy-admin key replacing master-key use: Phase 5 (issuer).
- Live GitHub advisory API polling (scheduled job opening issues): possible later enhancement; Phase 1 uses only the committed range file.
- Postgres Entra authentication for automation identities: v2 (PG-01).

</deferred>

---

*Phase: 01-network-proof-gateway-hardening-smoke-row*
*Context gathered: 2026-10-22*
