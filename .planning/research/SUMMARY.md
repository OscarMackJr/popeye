# Project Research Summary

**Project:** Popeye — AI Usage Governance Control Plane (MVP closure + v0.4.x agent principals)
**Domain:** Internal LiteLLM-based AI gateway on Azure Container Apps, adding a delegated agent-key issuer/introspection service, server-stamped ledger attribution, Stage 1 SLO measurement, Entra/Intune fleet automation, and a DLP evaluation
**Researched:** 2026-10-22
**Confidence:** MEDIUM-HIGH. LiteLLM behavior was verified in source at `v1.90.3` and `v1.106.2`, the advisories come from official GHSA pages, and the RFC/spec mapping is solid. Three things need a spike before build: hook internals (header access, relay-key lookup), `httpRouteConfigs` on an internal-LB environment, and cross-replica cache behavior.

Detail lives in `STACK.md`, `FEATURES.md`, `ARCHITECTURE.md` and `PITFALLS.md` in this directory.

## Executive Summary

Popeye already runs a working internal LiteLLM gateway with a Postgres ledger. This milestone has two jobs:
1. Prove the MVP: one attributed ledger row, Stage 1 baselines and runbooks.
2. Add the delegated-agent layer that nono and Liam depend on.

That layer is a small version of OAuth delegation built on opaque bearer keys:
- **Exchange** follows RFC 8693, with `on_behalf_of` as the subject and `agent_id` as the actor.
- **Introspection** follows RFC 7662 and returns a bare `active:false` for anything inactive.
- **Revocation** follows RFC 7009 and is idempotent.

No commercial gateway ships agent principals with on-behalf-of cost rollup, so Popeye has to build this rather than configure it.

All four research files agree on one design rule: logic is placed by when it runs.
- **Issuance-time logic** goes in a new thin Python/FastAPI issuer Container App. It is the only holder of the LiteLLM admin credential.
- **Request-time logic** goes in a `CustomLogger.async_pre_call_hook` baked into a derived LiteLLM image. This covers attribution stamping, `run_id`, the purpose/class prohibition, and relay/`direct_gateway` enforcement.
- **Aggregation** runs out-of-band in a scheduled job that feeds Azure Monitor.

The issuer is never in the model-call path.

### The first priority is upgrading and hardening the gateway

The pinned `v1.90.3` is outside LiteLLM's support window and has two relevant advisories:
- **GHSA-3cv6-jpf6-8222:** SSRF that could leak the gateway's Entra bearer token for Foundry.
- **GHSA-g5ff-637f-6q2m:** a file-read bug that exposes `/proc/self/environ`. That file holds the master key, the database password and the Redis key.

There's an upgrade trap. **GHSA-7hp6-4w63-5g45** (Critical, 9.9: salt-key reuse lets an attacker become proxy admin) is exploitable in the default config on 1.91.0 through 1.100.3, so a newer version is not necessarily a patched one.
- **Target:** the latest patched **1.106.x**, pinned by tag and digest. Re-check the GHSA list on the day you pin.
- **Route lockdown, same phase:** user and agent keys must not reach LiteLLM's native management routes (`/key/*`, `/user/*`, `/ui`, `/utils/*`). Otherwise every key holder has a second issuance API that bypasses the issuer.
- **Measure after the upgrade:** take Stage 1 baselines only once the upgrade is done. From 1.104.0 an exhausted budget returns 422 instead of 429.

### The biggest correctness risk is attribution spoofing

LiteLLM merges request-supplied `spend_logs_metadata` over the key-level values, so the request wins (verified at both tags). The Popeye hook must overwrite the identity fields on every request, and only `run_id` may come from the client.

Other major risks:
- budget inheritance implemented as a copy, which gives N agent keys N times the budget;
- revocation slower than specified, because of the per-replica 60 s auth cache and stale-object resurrection;
- a `key_id` that isn't really a UUID, or that is lost when a row is deleted;
- unresolved spec gaps that become one-way doors once nono builds on them.

## Brownfield Prerequisite Added After Research: In-VNet Network Proof

The networking review received 2026-10-22 shows the private DB route from `vnet-popeye-stage1-stage2-eastus2` is **unproven**. The existing verification VM (`EUS-VM-POPEYE`) sits in a different East US VNet, and the Stage 1/2 resource group has no Bastion.

Before the smoke proof, Phase 1 must:
1. Add `AzureBastionSubnet` (/26 or larger) and a non-delegated `snet-verification-vm`, through Terraform.
2. Create a Bastion host.
3. Create a private-only Windows Server 2022 VM with an NSG that allows 3389 only from Bastion and outbound 5432 only to Postgres.
4. Set up Entra sign-in with VM-scope Reader plus Virtual Machine User Login for the two approved operators only.
5. Prove that DNS resolves to an RFC1918 address and that TCP 5432 succeeds.
6. Re-run `Test-PopeyeAzureVerificationVm.ps1 -VmName`.
7. Decommission the VM on an agreed date.

This same in-VNet foothold doubles as the runner for the smoke test and the Stage 1 measurements.

## Key Findings

### Recommended Stack

**Core technologies:**
- **LiteLLM 1.106.x (patched), pinned by tag and digest.** 1.90.3 is unsupported and vulnerable. The `-stable` suffix no longer exists, so fix `terraform.tfvars.example`.
- **Derived gateway image** (`FROM litellm:<tag>` + `popeye_hooks.py`) in a new ACR. This is the only open-source way to enforce request-time rules: `custom_auth` with virtual keys is Enterprise-only and skips budget and expiry checks. Needs ADR-003.
- **Issuer:** Python 3.13, FastAPI 0.160, Uvicorn 0.54, Pydantic 2.14, httpx 0.28, psycopg 3.3.
  - It calls LiteLLM over REST and doesn't import `litellm`.
  - Its state lives in a **separate `popeye_issuer` database**, because Prisma migrates the `litellm` DB on every boot.
- **Routing:** `azapi` 2.13 for `Microsoft.App/managedEnvironments/httpRouteConfigs@2026-07-01` (GA), since azurerm has no resource for it. Stay on azurerm `~> 4.0`.
- **Tooling:**
  - Python: uv, pytest 9 + pytest-asyncio 1.x, testcontainers (real pinned LiteLLM + Postgres 16), respx, ruff, mypy. Tests are tagged with TC markers.
  - PowerShell: Pester 6.2 + PSScriptAnalyzer.
- **Fleet automation:** Microsoft.Graph.* 2.41.2 submodules. Intune uses the beta `deviceManagementScripts` API.
- **Measurement:** a `popeye-measure` CLI built on httpx + psycopg, correlated on `SpendLogs.request_id`, plus the `x-litellm-overhead-duration-ms` response header.

**Critical config:**
- Set `user_api_key_cache_ttl` to 30 s or less.
- Record `proxy_batch_write_at` (10 s by default; it is the floor for ledger freshness).
- Set `allow_client_side_credentials: false`, `LITELLM_LOG=ERROR` and `disable_add_user_agent_to_request_tags: true`.
- Use `exec litellm` in the container args. Today `sh` is PID 1, swallows SIGTERM, and batched spend rows are lost on every new revision.
- Never rotate `LITELLM_SALT_KEY`.

### Expected Features

**Must have:**
- MVP smoke proof.
- Agent key exchange (REQ-AGT-01..11), with the TTL clamped to `min(requested, 8h, parent expiry)` and inheritance as an intersection of the caller's limits.
- UUID `key_id`, byte-identical on all five surfaces (REQ-AGT-20/21). TC-AGT-21 is nono's integration gate.
- Introspection (REQ-AGT-12..16).
- Request-time enforcement: REQ-PUR-07, REQ-AGT-17..19, and server-stamped anti-spoofing attribution.
- `run_id` on ledger rows plus a scheduled run-cost alert.
- Corrections v0.3.
- Fleet user-key provisioning with metadata back-fill and leaver revocation.
- Stage 1 baselines including issuer SLOs.
- Rehearsed runbooks, including issuer-down and mass revocation.
- PIM break-glass.
- DLP go/no-go.

**Should have (differentiators):**
- Dual attribution: cost rolls up to `on_behalf_of`, activity to `agent_id`.
- `key_id` as the join key across systems.
- Relayed calls that keep the original attribution.
- Short-lived per-run keys. This needs a shared budget.
- Registry entries that carry `owner` and `allowed_purposes`.

**Defer:**
- Exchange rate limits.
- Guardrail rollout beyond the go/no-go.
- Entra Agent ID.
- mTLS/DPoP.
- RFC 7662 field aliases.
- Second-provider fallback.

**Anti-features:**
- Accepting `on_behalf_of`, `tenant_id` or `principal_type` from the request body.
- An agent minting another agent's key.
- Refreshable agent keys.
- Introspection that explains why a key is inactive.
- Run totals computed in the request path.
- Purpose semantics in the gateway.
- Prompt logging "for DLP tuning".
- Buying LiteLLM Enterprise.

### Architecture Approach

**Major components:**
1. **LiteLLM gateway (derived image).** Key auth, the native `expired_key` 401, budgets, the allowlist, Foundry routing and SpendLogs.
2. **`popeye_hooks`.** Authoritative identity stamp, `run_id` validation, REQ-PUR-07, the relay rules, stripping `X-Popeye-Relay-Key`, and a Redis revocation-set check. It never calls the issuer.
3. **`popeye-issuer`.** Own UAMI, 2 or more replicas. Exchange, revoke, introspect, events and registries. `litellm_admin.py` is the only code that touches the admin credential. `rules.py` holds pure functions.
4. **`popeye_issuer` DB.** The `agent_keys` registry plus append-only event tables.
5. **`popeye_ledger_v1` view.** The hometown hand-off contract; `ekg_cube_reader` gets SELECT on the view only.
6. **Policy bundle.** Rendered by Terraform as its own secret and consumed by both the hook and the issuer, with its hash exposed on the health endpoints.
7. **`httpRouteConfig` + custom domain + internal-CA certificate.** The stable DNS decision and the routing are one deliverable.
8. **`popeye-monitor` Container Apps Job.** Run cost, reconciliation, DCR to Log Analytics and scheduled-query alerts.

**Patterns:**
- authoritative server-side stamp;
- reserve-then-mint saga;
- revoke by **block**, never delete;
- constant-shape inactive responses;
- policy as data, rendered once and consumed twice.

### Critical Pitfalls

1. **Vulnerable pin and the upgrade trap.** Go to patched 1.106.x by digest, add a CI check against the GHSA ranges, and re-validate the hometown grants after the Prisma migrations.
2. **Issuer bypass through native `/key/*` routes.** Use LLM-only `allowed_routes`, disable the UI, restrict ingress paths, and add negative TCs.
3. **Forged attribution.** The hook overwrites the identity fields. Add a forged-metadata TC.
4. **Copied budget.** Use a user-entity budget plus a per-agent-key cap, starting with the very first fleet mint.
5. **Revocation and cache propagation.** Block keys, set the TTL to 30 s or less, check a Redis revocation set, and run a soak test across 2 or more replicas.
6. **Secret leakage through sinks the sentinel test misses.**
   - Hash keys before calling `/key/info`, never pass raw `sk-` values in URLs.
   - Strip the relay header.
   - Grep every sink, and re-check after enabling any guardrail.
7. **A leaver run that revokes everyone.**
   - Add a safety valve.
   - Use transitive members with `-All`, and treat disabled accounts as leavers.
   - Key users by Entra object ID.
   - Grant Graph roles through Terraform.
   - Dry-run by default.
   - Cascade revocation to agent keys.

Also:
- The Stage 1 method must take paired, interleaved in-VNet samples and record the version, digest and config hash.
- Redis may be wired only under `router_settings`, so budget counters may be per-replica. Verify, and never enable response caching.
- Redis public network access should be Disabled, with a private endpoint.

## Cross-Dimension Conflicts and Reconciled Recommendations

| Topic | Recommendation |
|---|---|
| **`key_id` storage / ledger join** | Each proposal gets a defined role:<br>1. **Source of truth:** a Popeye-owned `agent_keys` table in the `popeye_issuer` DB, with `key_id` as PK and a unique `token_hash`. Rows are never deleted.<br>2. **Ledger carrier:** `key_alias` set to the bare lowercase UUID, which lands unspoofably in `user_api_key_alias`, plus the hook-stamped `spend_logs_metadata.key_id`. `popeye_ledger_v1` reads these; there are no cross-DB joins without FDW.<br>3. **Reconciliation:** the `api_key` hash → `token_hash` join, run by the monitor and asserted in TC-AGT-21.<br>Use a bare UUID alias, not `agent-<uuid>`. User keys use `user:<entra-oid>`. |
| Python version | 3.13 (`python:3.13-slim-bookworm` by digest), `uuid4`. Move to `uuid7` on 3.14. |
| `httpRouteConfigs` API | `2026-07-01` GA. |
| Issuer path prefix | No rewrite: FastAPI keeps `/popeye`. The gateway rule covers only LLM and health paths, not `/`. Reconcile the paths with v0.4.1/v0.4.2. |
| Revoke mechanism | `/key/block` for agent keys and leavers. Hard-delete expired rows only through the monitor, after the evidence window. |
| Gateway revocation bound | Both a TTL of 30 s or less **and** the hook's Redis `popeye:revoked` set check. That is a Redis lookup, not an issuer call. Confirm Managed Redis cluster-mode compatibility. |
| Caller resolution | Hash the key locally, then call `/key/info?key=<sha256>` with the issuer admin credential. Check `blocked`, `expires` and `principal_type=="user"` explicitly. |
| Admin credential | A dedicated key. Spike the minimum open-source role. Fall back to the master key through a KV reference, recorded as debt. |
| Relay key validation | For the POC: static relay-key hashes in the policy bundle, carried in `X-Popeye-Relay-Key`. Strip the header and cover it with the sentinel test. mTLS later. |
| Registry delivery | A rendered policy bundle as its own secret, with its hash on `/healthz` and a vocabulary check in CI. |
| `spend_logs_metadata` on OSS | Verified in source. Confirm with a testcontainers contract test in the hook phase. |

## Spec Gaps Requiring Decisions

These block the nono critical path. Record them in requirements and decide them early.

1. **G1 Attribution anti-spoofing (CRITICAL).** New requirement: ledger principal fields come only from key metadata and a validated relay identity. Values supplied in the request are overwritten. Add a forged-metadata TC.
2. **G2 Shared vs. copied budget (HIGH).** Use a shared user-entity budget plus a per-agent-key cap. Decide before fleet keys are minted.
3. **G11 `on_behalf_of` format (HIGH, one-way door).** Use the Entra object ID; UPN is a display attribute only. Needs a program (fiskroad) decision.
4. **G8 Contract-schema drift (HIGH, cheap).**
   - The v0.1 issuance request schema contradicts the ratified v0.4.1 body.
   - `SESSION_CREDENTIAL_ISSUER_v0.1` still says "Option A".
   - Write new schemas and mark v0.1 superseded.
   - Ask nono whether `session_id` and `device_ref` survive.
5. **G3 Admin and cascade revocation (HIGH).** Add a PIM-gated admin revocation, plus a cascade when a user key is revoked. This needs a carve-out from REQ-AGT-10, ratified with nono. If it isn't ratified, ship the cascade only.

Further gaps:
- G4: clamp agent expiry to the parent's, and refuse a blocked parent.
- G5: gateway revocation latency.
- G6: event sink and schema.
- G7: relay header hygiene.
- G9: back-fill existing user keys.
- G10: run-cost alert mechanics.
- G12: issuer and introspection SLOs.
- G13: issuer runbooks.
- G14: exchange abuse limits.
- G15: error-code catalogue.
- G16: application keys for hometown and olive.
- G17: global vs. per-key guardrails.
- `direct_gateway`: required, with no default; confirm with nono.

## Implications for Roadmap

The research suggests 11 phases.
- **nono critical path:** 1 → 2 → 3 (+4) → 5 → 6 → 7.
- **Parallel pairs:** 3 and 4, and 8 and 9.

1. **In-VNet proof, Gateway Upgrade, Hardening and MVP Smoke Proof**
   - in-VNet verification path (above);
   - patched 1.106.x by digest;
   - `exec`, readiness probe and log levels;
   - UI disabled and route lockdown;
   - cache TTL;
   - Redis wiring verified and public access disabled;
   - GHSA CI check;
   - one attributed smoke row;
   - hometown grants re-validated.
2. **Contracts, Decisions and Registries**
   - decisions on G1, G2, G3, G11 and the `direct_gateway` default;
   - new schemas, with v0.1 marked superseded;
   - error catalogue and event schema;
   - `config/agent-registry.yaml` covering agents, introspection callers and relays, checked in CI;
   - REQ-DCE-05/06;
   - policy-bundle design.
3. **Gateway Hook, Image Pipeline and Ledger Contract**
   - ACR and ADR-003;
   - derived image;
   - `popeye_hooks.py`: stamp, REQ-PUR-07, relay header and the revocation set;
   - contract tests, including the forged-metadata TC;
   - `popeye_ledger_v1` and the grant;
   - hometown hand-off.
4. **Stable FQDN, Custom Domain and Route Config**
   - DNS ownership;
   - internal-CA certificate;
   - azapi `httpRouteConfig`, with admin paths unreachable;
   - A record and RBAC;
   - sidecar fallback.
5. **Fleet User-Key Provisioning + Intune**
   - `provision-desktop-keys.ps1` with every safeguard above;
   - back-fill of existing keys;
   - Graph roles through Terraform;
   - Pester fixtures;
   - Intune base-URL ring pilot.
6. **Issuer Core: Exchange, Revocation, Events**
   - module, DB and admin credential;
   - saga;
   - UUID alias;
   - TTL clamp;
   - intersection inheritance;
   - block-based revocation;
   - events;
   - sentinel test;
   - negative tests against the native `/key/*` routes;
   - TC-AGT-05..11 and TC-AGT-20.
7. **Introspection, Relay Enforcement and Revocation Propagation**
   - application keys (G16);
   - introspection and its events;
   - relay enforcement;
   - admin/cascade revocation;
   - two-replica soak;
   - **TC-AGT-21**, nono's gate.
8. **Stage 1 Measurement and SLOs**
   - `popeye-measure`;
   - all of the protocol's measurements, plus budget overshoot and issuer SLOs;
   - `STAGE1_BASELINES.md` with the version, digest and config hash;
   - Option B descope;
   - SLO roadmap revision and burn-rate alerts.
9. **Out-of-Band Alerting, Run Metering and Endpoint Detection**
   - `popeye-monitor`;
   - DCR and alerts;
   - `sk-` leak alert;
   - KV `SecretGet` alert;
   - REQ-END-03..05;
   - ledger retention.
10. **DLP / Guardrail Evaluation**
    - `litellm_content_filter`, then Presidio, then heuristic prompt-injection checks;
    - synthetic corpus and sink grep;
    - latency deltas and fail-open vs. fail-closed;
    - go/no-go.
11. **Operational Readiness**
    - eight rehearsed runbooks;
    - PIM break-glass with standing access removed;
    - `SecretGet` drill.

**Ordering rationale:**
- **Security before features.** Agent keys put semi-trusted holders on the gateway.
- **Decisions before code.** These are one-way doors.
- **Hook before issuer.** The hook carries the most uncertainty, and its results set the metadata contract the issuer writes.
- **Fleet before exchange.** The exchange derives from the user key.
- **TC-AGT-21 last.** It needs all five surfaces.
- **Observation off the critical path.**

### Research Flags

**Need `--research-phase`:**
- Phase 1: GHSA re-check, the 1.90→1.106 breaking changes, Redis wiring and cluster mode, and the Prisma migration impact.
- Phase 3 (highest): hook internals at the target tag, and the ACR SKU.
- Phase 4: route config on an internal LB with a private custom domain.
- Phase 6: minimum open-source admin role.
- Phase 7: cross-replica revocation, and Redis set vs. cluster mode.
- Phase 10: `guardrail_information` contents, and Presidio latency.

**Standard patterns:** Phases 2, 5 (light Intune beta check), 8, 9 and 11 (check P2 licensing).

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Verified in source at both tags; versions checked 2026-10-22 |
| Features | MEDIUM-HIGH | RFC/spec mapping HIGH; licensing claims MEDIUM; competitors LOW-MEDIUM |
| Architecture | MEDIUM | Boundaries HIGH; internal-LB routing undocumented; hook internals LOW until a spike |
| Pitfalls | MEDIUM-HIGH | Advisories HIGH; cache behavior from upstream PRs MEDIUM |

**Overall:** MEDIUM-HIGH

### Gaps to Address

- **Hook internals:** Phase 3 spike, which gates the Phase 6 metadata contract.
- **Internal-LB routing:** Phase 4 spike, with the sidecar fallback.
- **Cross-replica revocation and budget overshoot:** measure in Phases 7 and 8. The end-to-end worst case could be about 120 s if the spec's 60 s is read as end-to-end; clarify with nono, hometown and olive.
- **Dedicated admin credential:** Phase 6 spike.
- **Program and nono decisions** (G1/G2/G3/G8/G11, `direct_gateway`): Phase 2.
- **Postgres Entra auth for the issuer:** deferred; use a Key Vault-referenced password role meanwhile.
- **Redis public access:** fold into Phase 1.
- **Purpose intersection limitation (O1):** state it explicitly.

## Sources

Primary sources (HIGH confidence), with full citations in the four dimension files:
- LiteLLM source at both tags;
- the GHSA advisories and release notes;
- LiteLLM docs;
- Microsoft Learn: rule-based routing, custom domains, `httpRouteConfigs`, Graph app roles;
- RFC 8693, 7662, 7009, 8705 and 9449;
- registry and package version checks;
- the internal Popeye specs.

---
*Research completed: 2026-10-22*
*Ready for roadmap: yes*
