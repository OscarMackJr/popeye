# Pitfalls Research

**Domain:** LiteLLM-based internal AI governance gateway (Azure Container Apps) adding delegated agent keys (exchange, introspection, relay, revocation), attributed ledger, Stage 1 SLO measurement, fleet key automation (Entra/Intune), DLP evaluation, break-glass/PIM
**Researched:** 2026-10-22
**Pinned LiteLLM:** `v1.90.3` (`envs/azure-eastus2/terraform.tfvars`). Upstream is now at v1.106.x (2026-10-20).
**Confidence:** MEDIUM overall. The security advisories and release notes are HIGH (official GHSA pages and release notes). The cache and revocation behavior is MEDIUM (upstream PRs and issues, not shipped docs). Some LiteLLM internals are LOW and are flagged inline.

Phase labels used below are suggestions for the roadmapper. They are not yet roadmap IDs:

| Label | Suggested phase |
|---|---|
| **P0 Upgrade & Harden** | LiteLLM version, config hardening, route lockdown (before anything else) |
| **P1 MVP Proof** | smoke completion → one ledger row, DNS |
| **P2 Stage 1 Measurement** | baselines, SLOs, alerts |
| **P3 Issuer Core** | exchange, key_id, registries, issuance events |
| **P4 Introspection/Relay/Revocation** | REQ-AGT-12..19 |
| **P5 Ledger Attribution & Run Metering** | key_id/purpose/run_id/relayed_by on rows |
| **P6 Fleet Automation** | Graph/Intune scripts |
| **P7 DLP Evaluation** | Presidio go/no-go |
| **P8 Ops Readiness** | runbooks, break-glass/PIM |

---

## Critical Pitfalls

### Pitfall 1: Building the issuer on v1.90.3. The pinned gateway has open, exploitable advisories, and the upgrade path has a trap

**What goes wrong:**
v1.90.3 is affected by at least two advisories that matter here because agent keys put new, semi-trusted holders (agents) on the gateway:
- **GHSA-3cv6-jpf6-8222** (authenticated SSRF and provider-credential exfiltration through unvalidated request-body routing parameters). Affects < 1.94.0. Patched in the 1.90.x line at **1.90.7**. Popeye uses `enable_azure_ad_token_refresh` with managed identity to Foundry. If a caller can redirect `api_base`, the gateway sends its **Entra bearer token for Foundry** to an attacker-controlled host.
- **GHSA-g5ff-637f-6q2m** (local file read through `vertex_ai_credentials` on `/utils/transform_request`, High, < 1.95.0, no config workaround). This deployment injects `LITELLM_MASTER_KEY`, `DATABASE_URL` (with the Postgres admin password) and `REDIS_PASSWORD` as environment variables, so `/proc/self/environ` is a full compromise. The advisory says `internal_user_viewer` is enough. Whether a plain virtual key reaches that route on 1.90.3 is unverified, so treat it as exposed.

The trap: **GHSA-7hp6-4w63-5g45** (Critical 9.9, salt-key reuse lets an attacker escalate to proxy admin) is exploitable *in the default config* on **1.91.0 up to 1.100.3**. On 1.87–1.90.x it is exploitable only if `EXPERIMENTAL_UI_LOGIN=true`. Upgrading from 1.90.3 to "something newer but not newest" can make things worse.

**Why it happens:**
Pinning is treated as "safe" and stays frozen. The pin protects against `latest` drift, not against known CVEs. LiteLLM ships patches on many parallel lines (v1.100.x through v1.106.x all received fixes in October 2026), so "newer" does not mean "patched".

**How to avoid:**
- Before issuer work starts, move to a line that is patched for all three advisories: ≥ 1.100.4 on the 1.100 line, or 1.103.6, 1.105.2 or 1.106.1. Re-check the GHSA list on the day you pin.
- Read the breaking changes on the way:
  - v1.103.0: config-defined keys ignore DB values.
  - v1.103.3: the proxy exits on Prisma migration failure.
  - v1.104.0: budget exhausted returns **HTTP 422 instead of 429**; startup fails on a weak or missing master key.
  - v1.90.0: `/key/list` matching is exact.
- Pin by **digest**, or mirror the image into ACR. The 2026-03-24 PyPI compromise (litellm 1.82.7/1.82.8, TeamPCP via a compromised Trivy) did not affect the Docker image, but the attack class is real.
- Add `allow_client_side_credentials: false` explicitly.
- Add a CI job that fails when the pinned tag falls in a GHSA "affected" range.

**Warning signs:**
- The tfvars tag has not changed in more than 60 days.
- New advisories appear on github.com/BerriAI/litellm/security/advisories.
- Baselines were captured on one version and the gateway now runs another.

**Phase to address:** P0, before P2. Baselines measured on 1.90.3 are invalidated by the upgrade (the 422/429 change alone breaks the "budget vs provider-throttle payloads" measurement).

---

### Pitfall 2: Bypassing the issuer through LiteLLM's native management routes (onward delegation and long-lived keys)

**What goes wrong:**
REQ-AGT-05 and v0.4.1 §2.6 say agent keys cannot mint keys, and the issuer is the only path. But LiteLLM's own `/key/generate`, `/key/update`, `/key/regenerate`, `/key/list`, `/key/info`, `/spend/logs`, `/user/info` and `/ui` are served on the **same gateway FQDN**. Depending on the user role tied to the key (`internal_user` can generate its own keys), a desktop user key or an agent key with `user_id=(the human principal)` can call `/key/generate` directly. It then gets a key with no TTL cap, no agent registry check, no `key_id` UUID, no issuance event, and possibly `duration: null`, meaning it never expires. It can also read its own spend logs and metadata, or other keys' hashes through list routes.

**Why it happens:**
Teams model "the issuer is the policy point" and forget the gateway exposes a second, more permissive issuance API to every key holder.

**How to avoid:**
- Mint every user key and agent key with `allowed_routes` limited to LLM API routes (`llm_api_routes`, or `key_type: llm_api`). Only the issuer's dedicated management credential gets management routes.
- Do not create LiteLLM `internal_user` records with self-serve key generation for desktop users. Set `key_generation_settings` and `upperbound_key_generate_params` (duration ≤ 8h for agent-shaped keys) as defence in depth.
- Disable the admin UI (`DISABLE_ADMIN_UI`) or block `/ui`, `/sso/*` and `/key/*` at ingress for everything except the issuer's source. Container Apps rule-based routing or IP restrictions can do this.
- Add a negative test to P3/P4 CI: call `/key/generate`, `/key/update` and `/key/regenerate` with a user key and with an agent key, and expect 401/403 for each.

**Warning signs:**
- `LiteLLM_VerificationToken` rows whose metadata has no `popeye_key_id`.
- Keys with `expires IS NULL` that are not fleet user keys.
- `/key/*` requests in gateway access logs from non-issuer sources.

**Phase to address:** P0 (route lockdown) and P3 (negative TCs alongside TC-AGT-05).

---

### Pitfall 3: Treating LiteLLM's key identifier as `key_id`, or letting LiteLLM key deletion break the ledger join

**What goes wrong:**
LiteLLM's identity for a key is `token` = SHA-256 hex of the secret, stored in `LiteLLM_VerificationToken` and written to spend logs as `api_key` / `user_api_key_hash`. It is 64 hex chars. It is **not** a UUID, and it is derived from the secret. REQ-AGT-20/21 require a lowercase canonical v4/v7 UUID that is byte-identical on five surfaces. Three failure modes are common:
1. Truncating or reformatting the hash into UUID shape. The result is not a valid v4/v7 version nibble, and it is deterministic from the secret.
2. Storing the UUID only inside LiteLLM key `metadata`. `/key/delete` removes the `VerificationToken` row, so ledger rows (which hold only the hash) can no longer be joined to `key_id` once the key is revoked by deletion.
3. Mixed case or braces: Python `uuid.UUID` str is lowercase, but Postgres `uuid` type output, .NET `Guid.ToString("B")` and PowerShell `[guid]` formatting can differ. nono's 16-byte `KeyId` round-trip then fails byte comparison.

**Why it happens:**
"LiteLLM already has a key ID" is the obvious shortcut. Deletion semantics are rarely tested against the ledger.

**How to avoid:**
- The issuer generates `key_id = uuid7()` (or uuid4), lowercased, and persists it in a **Popeye-owned table**: `agent_key(key_id uuid PK, token_hash text UNIQUE, agent_id, on_behalf_of, purpose, tenant_id, expires_at, revoked_at, direct_gateway, minted_by_token_hash)`.
- Never delete rows. The PK uniqueness gives "never reused" across revocation and expiry.
- Also stamp `key_id` into the LiteLLM key's `metadata` (and `key_alias = "agent-<uuid>"` for operator lookup), but the ledger view joins `spend_logs.api_key → agent_key.token_hash`, not LiteLLM's key table.
- Revoke with `/key/block` (keeps the row) or delete plus Popeye tombstone. Do not rely on LiteLLM rows surviving.
- Render UUIDs only through one function and assert the regex at every egress. TC-AGT-21 should compare raw bytes, not parsed UUIDs.

**Warning signs:**
- Ledger rows for agent traffic with null `key_id` after the key has expired or been revoked.
- Any code path calling `.upper()`, `str(uuid)` from another language, or `::text` on a non-uuid column.

**Phase to address:** P3 (schema). P5 (join, TC-AGT-11/21 live).

---

### Pitfall 4: Attribution forged by the caller through request-level spend metadata

**What goes wrong:**
LiteLLM accepts `metadata.spend_logs_metadata` from three places: key metadata, the **request body** (`metadata.spend_logs_metadata` / `extra_body`), and the **`x-litellm-spend-logs-metadata` header**. Precedence is not documented (official cost-tracking docs). The request `user` field also becomes `end_user`, and `metadata.tags` becomes `request_tags`. If Popeye stamps `principal_type`, `agent_id`, `on_behalf_of`, `purpose`, `tenant_id` or `relayed_by` through spend_logs_metadata and then reads them back in the ledger view, a caller can overwrite or inject them. An agent could, for example, claim `on_behalf_of=<someone else>` or `relayed_by=hometown`. Separately, `spend_logs_metadata` was historically documented as an Enterprise feature, so it may silently no-op on the OSS image (LOW confidence; test it).

**Why it happens:**
It is the documented way to "add custom fields to spend logs", and the client-override path is not obvious.

**How to avoid:**
- Ledger identity fields come **only** from server-side state: the `api_key` hash joined to Popeye's `agent_key` table (Pitfall 3) and the user key registry.
- Only genuinely caller-asserted labels (`run_id`) may come from the request. Validate their format and record them in a separate, clearly labeled column.
- `relayed_by` must be written by Popeye's pre-call hook after relay validation, never read from a client field.
- In an `async_pre_call_hook` (OSS CustomLogger), strip `metadata.spend_logs_metadata`, `metadata.tags`, `user` and the `x-litellm-*` override headers from client requests.
- Add a P5 TC: send a request with a forged `spend_logs_metadata.on_behalf_of` and a forged header, and assert the ledger row shows the true principal.

**Warning signs:**
- The ledger view `SELECT`s identity from `metadata->'spend_logs_metadata'`.
- `end_user` values that don't look like UPNs or UUIDs.

**Phase to address:** P5. P1 should already use the join pattern so the smoke row proves the right thing.

---

### Pitfall 5: Revocation and budget changes propagate slower than the spec says, because of LiteLLM's per-replica auth cache

**What goes wrong:**
- Each replica caches validated key objects in memory. `user_api_key_cache_ttl` defaults to **60 s**.
- On current upstream, `/key/delete` evicts only the handling worker's cache. Other workers accept the deleted key until TTL expiry (PR #47609, open as of 2026-10-21).
- The broader broadcast-invalidation fix (PR #36207) was **closed unmerged** on 2026-10-03.
- Issue #25553 (closed "not planned" 2026-07-20) documents `update_cache` **re-writing stale key objects with a fresh 60 s TTL under load**, so `/key/update` changes (`blocked`, `max_budget`, `models`, `metadata`) "may never take effect" on a busy replica.
- Popeye runs ≥ 2 replicas.

So the 60 s revocation bound (REQ-AGT-16) holds at the gateway only on average. Worst case is TTL plus resurrection, and the downstream services may add their own 60 s introspection cache on top. Gateway (60 s) plus service cache (60 s) means a 120 s worst case if the spec's 60 s is read as end-to-end.

**Why it happens:**
Single-replica dev testing passes. The spec's 60 s figure is about service caches, and the gateway's own cache is forgotten.

**How to avoid:**
- Revoke by **block** in LiteLLM **and** by marking `revoked_at` in Popeye's table.
- Enforce revocation in Popeye's `async_pre_call_hook` against a revocation set in Redis (check `token_hash ∈ popeye:revoked`, one O(1) Redis lookup). That makes the gateway path independent of LiteLLM cache semantics.
- Set `user_api_key_cache_ttl` to something like 15–30 s, accepting the extra DB load. Measure it in P2.
- Never use `/key/update` for security-relevant changes on hot keys. Prefer block plus re-mint.
- Write the end-to-end bound explicitly in the baselines doc: gateway ≤ X s, services ≤ 60 s.
- TC-AGT-16 must run against **≥ 2 replicas**, with load during the test.

**Warning signs:**
- A revoked key succeeds after revocation in a two-replica soak test.
- Revocation latency varies by replica.

**Phase to address:** P4 (enforcement). P2 (measure the cache TTL and its effect on DB load).

---

### Pitfall 6: Redis is wired for the router only, so budget counters are per-replica (overshoot) and "budget counter lag" measures the wrong thing

**What goes wrong:**
The rendered config (`envs/azure-eastus2/main.tf` locals) sets Redis only under `router_settings`. LiteLLM's shared proxy usage cache (spend counters, parallel-request limiter, auth cache sharing) is typically initialized from `litellm_settings.cache` / `cache_params` (MEDIUM/LOW confidence on the exact wiring in 1.90.3). Without it, each replica enforces `max_budget` against its own in-memory view plus batched DB writes. A key can exceed budget by roughly N_replicas × in-flight spend.

Even with Redis, upstream PR #45974 (open 2026-10) shows spend counters expiring at the 60 s generic TTL. They are then reseeded from a stale DB value because batched DB writes (`proxy_batch_write_at`) land later, which readmits keys at budget. PR #40940 (open) shows stale caches after budget reset on other pods.

Turning on `cache: true` naively also enables **response caching** for `/chat/completions`. Prompt-derived cache entries then land in Redis, cached completions can be served across principals, and caching conflicts with "no prompt logging".

**Why it happens:**
"We deployed Redis" is assumed to mean "Redis is used for budgets".

**How to avoid:**
- In P0/P2, inspect Redis keys during a load test to confirm which counters live there.
- If enabling `cache: true` for shared state, restrict `supported_call_types` to none (or the equivalent) so no completions are cached. Verify that no prompt-derived keys or values appear in Redis.
- State budget enforcement as **soft, with bounded overshoot**, and measure the overshoot: fire concurrent requests at a key with a tiny `max_budget` across both replicas and record spend above the cap.
- Set `proxy_batch_write_at` deliberately and record it in the baselines.
- Azure Managed Redis uses a clustering policy. Confirm LiteLLM's client works with it: no MOVED errors, and pub/sub available if relying on coordination invalidation (PR #43110 notes the Cluster client lacked pub/sub).
- Fix the Redis `public_network_access` default to `Disabled` with a private endpoint (CONCERNS.md).

**Warning signs:**
- The budget-lag test shows different results per replica.
- Redis `INFO keyspace` is near-empty under load.
- Over-budget spend appears in the ledger.

**Phase to address:** P0 (config). P2 (measure overshoot and lag; record as the TC baseline).

---

### Pitfall 7: Budget "inheritance" implemented as a copy, so agent spend escapes the user's budget

**What goes wrong:**
REQ-AGT-09 says agent keys inherit, and cannot exceed, the caller's budget. LiteLLM has no parent-key concept. Copying `max_budget` from the user key onto each agent key multiplies the budget: 10 agent keys get 10× the budget. Setting no budget on agent keys makes them unbounded. Per-key budget on the user key does not count agent-key spend.

**Why it happens:**
"Inherit" is read as "copy the fields".

**How to avoid:**
- Put the budget on a shared LiteLLM entity, not on keys. Set `user_id = on_behalf_of` on the agent key and enforce the budget on the user record (`LiteLLM_UserTable.max_budget`), or on a per-user team/budget entity, so user-key and agent-key spend share one counter.
- Additionally set a small per-agent-key `max_budget` as a blast-radius cap.
- Copy `models` (the class-ceiling allowlist) as an **intersection** and the tenant as-is.
- TC-AGT-09 should also assert "user + agent spend combined is capped".

**Warning signs:**
- The sum of agent-key spend for one `on_behalf_of` exceeds the user's budget.

**Phase to address:** P3 (design). P6 (fleet user keys must be created with the user-entity budget model from the start; retrofitting means re-minting the fleet).

---

### Pitfall 8: Key secrets leaking through URLs, headers, logs and guardrail payloads (sentinel test passes on the wrong surface)

**What goes wrong:**
Several LiteLLM and Azure paths can put the secret where the sentinel test doesn't look:
- `GET /key/info?key=sk-...` puts the secret in the **URL**. URLs are captured by uvicorn access logs, Container Apps console logs and App Insights request telemetry. v1.90.1 had to redact the key from `/key/info` error messages.
- A custom relay header (for example `x-popeye-relay-key: sk-...`) is **not** stripped like `Authorization`. LiteLLM's 2026-03-18 incident showed request headers (`secret_fields.raw_headers`, including Authorization) flowing into spend logs and OTel traces via the guardrail logging path (fixed in 1.82.3). Issue #20240 reported a similar leak on 1.81.0. Any new guardrail (Presidio in P7) or custom hook that returns the full `data` dict reopens that path.
- `LITELLM_LOG=DEBUG` or `set_verbose` prints request bodies and keys.
- Python `httpx`/`requests` debug logging in the issuer, and FastAPI exception handlers that echo request bodies, are further paths.
- Issue #16336 (fixed Jan 2026) stored full request messages in `proxy_server_request` despite `turn_off_message_logging`.

**Why it happens:**
Sentinel tests usually grep only the HTTP response bodies of the issuer and introspection endpoints.

**How to avoid:**
- Never pass a secret in a query string. Call LiteLLM key info with the key as bearer, or hash locally.
- Relay identity should use a non-replayable or non-secret mechanism: mTLS, or a short-lived signed assertion. If you must use a header, the pre-call hook must `pop()` it before anything else runs.
- The sentinel test (TC-AGT-12) mints a key with a known marker. It then exercises exchange, introspection, relay, error paths, a guardrail-triggering request and a forced 5xx, and greps **all** sinks:
  - Log Analytics `ContainerAppConsoleLogs_CL` and `ContainerAppSystemLogs_CL`
  - App Insights `requests`, `traces` and `dependencies`
  - `LiteLLM_SpendLogs.metadata` and `LiteLLM_ErrorLogs`
  - Redis keys
  - issuance and introspection event tables
- Set `LITELLM_LOG=ERROR`, `json_logs: true` and `disable_error_logs: true`. Assert these in CI against the rendered YAML.

**Warning signs:**
- Any `sk-` substring in Log Analytics: run a scheduled KQL query that alerts on the pattern.
- Spend-log metadata rows larger than about 2 KB.

**Phase to address:** P3/P4 (test harness). P7 (re-run after enabling any guardrail). P0 (log levels).

---

### Pitfall 9: Agents (or the relay) exfiltrating credentials or bypassing `direct_gateway=false` through LiteLLM features you didn't plan for

**What goes wrong:**
- Enforcing `direct_gateway=false` and relay validation with LiteLLM **custom auth** requires an **Enterprise license** when used alongside virtual keys (official custom_auth docs). By default custom auth also skips budget, model and expiry checks unless `custom_auth_run_common_checks` / `enable_post_custom_auth_checks` are set.
- Teams that try custom auth either hit the license wall late, or ship a path that skips expiry and budget checks.
- Pass-through endpoints, MCP and `/utils/*` routes give an agent key additional surfaces.

**Why it happens:**
Custom auth looks like the natural hook point.

**How to avoid:**
- Keep LiteLLM's native virtual-key auth. Implement relay and `direct_gateway` checks in an OSS `CustomLogger.async_pre_call_hook`. It receives `user_api_key_dict` (with key metadata) and the request `data`.
- Raise to reject, with a **distinct error code/body** for the REQ-AGT-18 error.
- Verify the hook runs for every LLM route the key can reach: `/chat/completions`, `/v1/responses`, `/embeddings` and pass-through. Use `allowed_routes` to make that set small.
- Disable MCP and pass-through endpoints unless needed.

**Warning signs:**
- A route on which an agent key with `direct_gateway=false` succeeds without the relay header.
- License warnings in startup logs.

**Phase to address:** P4.

---

### Pitfall 10: Expiry implemented with LiteLLM's semantics instead of the spec's

**What goes wrong:**
- `upperbound_key_generate_params.duration` **rejects** longer durations (400). The spec requires **clamping** (`expires_at = min(requested, 8h)`, TC-AGT-08: request 48 h, get ≤ 8 h).
- The issuer computes `expires_at` locally while LiteLLM computes `expires` from `duration` server-side, so the two disagree by seconds. The exchange response, introspection and LiteLLM then disagree, and nono's view of expiry drifts.
- LiteLLM's expired-key error is a 401/403 "Authentication Error - Expired Key" whose shape has changed historically. Older versions had naive versus timezone-aware UTC bugs. REQ-AGT-04 needs a *distinct*, stable error.
- Container clock skew between replicas is small but non-zero.

**How to avoid:**
- The issuer clamps, then passes an absolute `expires` if supported, or `duration` in seconds. It then **reads back** `expires` from the LiteLLM response and returns *that* value (UTC, ISO-8601 with `Z`) as `expires_at` everywhere.
- Map LiteLLM's expired-key response to Popeye's distinct error in the pre-call hook, or at least pin the exact body in a contract test that runs on every LiteLLM upgrade.
- Introspection must check `expires_at` itself (return `active:false`) and not rely on LiteLLM.

**Phase to address:** P3.

---

### Pitfall 11: Container Apps process and shutdown details lose ledger rows (the "ledger interruption" result is wrong)

**What goes wrong:**
- `modules/gateway-service-azure/main.tf` starts LiteLLM as `/bin/sh -c "printf ... && litellm ..."` **without `exec`**. `sh` is PID 1, SIGTERM from a revision swap or scale-in is not forwarded, and LiteLLM is SIGKILLed after the grace period.
- LiteLLM batches spend writes in memory (`proxy_batch_write_at`), so in-flight spend rows and counters on that replica can be lost (LOW–MEDIUM confidence on exact flush-on-shutdown behavior).
- v1.105.1 notes also describe SpendLogs rows **never written** under row-lock contention on the daily-usage upsert (fixed in v1.105.1 via batching). Another fix addressed double-counted spend on the chat→Responses bridge (v1.102.4/1.103.6/1.105.1).
- Every ADR-002 config change creates a new revision, which is a mass restart.

**How to avoid:**
- Use `exec litellm ...` in the args.
- Set the termination grace period to at least `proxy_batch_write_at` + 10 s.
- In P2, run the "ledger interruption" protocol as a **count reconciliation**: N requests sent, N rows expected, compared by `request_id`. Do this across a deliberate revision swap and a Postgres failover, not just a Postgres stop.
- Use `/health/readiness` for readiness, not `/health/liveliness`. Know that `allow_requests_on_db_unavailable` changes readiness semantics.
- Size `database_connection_pool_limit` × replicas × workers plus issuer connections against the Postgres SKU's `max_connections`.

**Warning signs:**
- Ledger row count is below the client-side success count.
- Gaps align with revision timestamps.

**Phase to address:** P0 (exec, probes). P2 (measure).

---

### Pitfall 12: Fleet leaver automation that revokes everyone, or no one

**What goes wrong:**
`provision-desktop-keys.ps1` reconciles an Entra group against LiteLLM keys. Classic failures:
- A Graph error, throttling (429) or an auth failure yields an **empty member list**, and the leaver pass revokes the entire fleet.
- `Get-MgGroupMember` is **direct members only**. Nested groups are silently excluded, so users are never provisioned, or are revoked if moved into a nested group.
- Without `-All`, only the first page (100) is returned, so users beyond page 1 are "leavers".
- Disabled accounts (`accountEnabled=false`) stay in groups, so leavers keep working keys until HR removes group membership.
- Matching keys to users by UPN or display name breaks on rename. Use the Entra object ID.
- Graph app-role permissions for a managed identity **cannot be granted in the portal**. They need `New-MgServicePrincipalAppRoleAssignment` (or Terraform `azuread_app_role_assignment`) run by a Privileged Role Admin, which is often discovered at go-live. Granting broad `Directory.Read.All` / `Group.Read.All` instead of `GroupMember.Read.All` widens blast radius.
- With a user-assigned identity, `Connect-MgGraph -Identity` without `-ClientId` picks the wrong or no identity.
- The script writes newly minted secrets to transcript or console.
- Intune: env-var or base-URL profiles take effect only at a new logon. Scripts run once (not continuously). User versus system context determines where the variable lands. The profile only sets the URL; it does not stop direct provider access (that is nono/endpoint detection's job).

**How to avoid:**
- Use a **safety valve**: abort the revocation pass if the computed leaver set exceeds a threshold (for example 5% or 10 users) or the member set is empty. Require `-Force` from a human.
- Use transitive membership (`/groups/{id}/transitiveMembers/microsoft.graph.user?$select=id,accountEnabled,userPrincipalName`) with `-All`. Treat `accountEnabled=false` as a leaver.
- Key the mapping on the Entra object ID (store it as LiteLLM `user_id` and in metadata alongside tenant UUID; REQ-DCE-07).
- Grant the least Graph app roles through Terraform. Run in dry-run mode by default, with a diff report.
- Secrets go straight to the delivery channel and never to output. Pester-test the reconciliation logic with fixtures for the empty, paged, nested and disabled cases.
- Revoking a user key must also cascade to that user's agent keys: find agent keys with `minted_by` = user key and block them. Otherwise leavers' agents keep running for up to 8 h.

**Warning signs:**
- The first dry run reports revoke counts close to the group size.
- Provisioned count is less than the group's transitive member count.

**Phase to address:** P6. The cascade belongs to P3/P4 (the issuer owns the `minted_by` relation).

---

### Pitfall 13: Stage 1 SLO measurement that measures noise, or the wrong path

**What goes wrong:**
- Latency overhead is computed as gateway p95 minus "direct" p95 from different vantage points and times. Foundry variance (hundreds of ms) swamps gateway overhead (tens of ms).
- Streaming is measured as total time rather than TTFT.
- Cold replicas and token refresh dominate the first samples.
- Sequential clients suffer coordinated omission.
- Sample sizes are too small for p99.
- Baselines are captured before Pitfall 1's upgrade, the Pitfall 6 config change, or the Pitfall 11 `exec` fix, so they are invalid on day one.
- "Budget vs provider-throttle payloads" are captured on 1.90.3 (429), and the error becomes 422 on ≥ 1.104.0.
- Presidio (P7) is added after the baseline without re-measuring.

**How to avoid:**
- Measure from the same in-VNet verification VM.
- **Interleave** direct and gateway requests (paired design) with identical payloads and `max_tokens`. Report the distribution of paired differences, including TTFT for streaming. Discard warm-up.
- Use an open-loop load generator at a fixed rate.
- Record the LiteLLM version, digest, config hash and replica count *in* `STAGE1_BASELINES.md`. Re-run on any change.
- Define budget-counter lag precisely as the time from the response to (a) Redis counter reflects spend and (b) a DB row exists.
- Define ledger freshness as p95 of `row_inserted_at - request_end`.

**Phase to address:** P2, sequenced after P0. Re-run in P7.

---

### Pitfall 14: DLP/guardrail evaluation that breaks the no-prompt-logging rule or the latency budget

**What goes wrong:**
- Presidio in LiteLLM records `guardrail_information` per request: detected entities, scores, and depending on version and guardrail, `guardrail_response` payloads. That can include **masked or unmasked text**, which flows to spend logs and OTel. Exact contents in your target version are LOW confidence, so verify.
- The `logging_only` mode masks logs only, not the request. Post-call masking alters the response the user sees, and the async logging hook doesn't.
- The Presidio analyzer adds network hops and CPU. Running it as a separate Container App adds per-request latency and a new failure mode (fail-open versus fail-closed must be decided).
- Guardrail bypass bugs exist (v1.90.2 closed one in realtime).
- Evaluating with real prompts in a "test" environment is itself prompt logging.

**How to avoid:**
- Run the evaluation with **synthetic** PII corpora only.
- Assert with the Pitfall 8 sink-grep that no corpus string appears in any sink.
- Measure p50/p95 added latency with the P2 paired method.
- Record fail-open/closed behavior on analyzer outage.
- Make the go/no-go recommendation explicit about which entities, which mode (pre_call versus logging_only) and the residual leakage path.

**Phase to address:** P7. Depends on the P2 harness and the P8 sink-grep tooling.

---

## Moderate Pitfalls

### Pitfall 15: Container Apps internal ingress, DNS and "exchange on the gateway FQDN"
- **What goes wrong:**
  - The spec puts the exchange and introspection on the **gateway FQDN**, but the issuer is a second Container App. Native ingress gives each app its own hostname.
  - Fronting the issuer by having LiteLLM pass-through to it couples issuer availability to the gateway. It also may log bodies containing secrets.
  - The internal environment needs a private DNS zone for its default domain with a wildcard A record to the environment's static IP, linked to every client VNet (peering is still a TODO).
  - The custom domain `gateway-azure.ai.twg.internal` needs a **bring-your-own certificate** (an internal CA cert from Key Vault). Managed certificates depend on public validation (MEDIUM confidence that they're unusable here).
  - A domain binds to only one app/route/environment.
  - Clients (nono, hometown, olive, desktop tools) must trust the internal CA.
- **Prevention:**
  - Use Container Apps **rule-based routing** (`httpRouteConfig`, GA November 2025) on the custom domain: `/popeye/agent-keys*` and `/popeye/introspect*` go to the issuer, everything else goes to the gateway.
  - Path-match exactly and test that `/key/*` is not routed to LiteLLM from outside (ties to Pitfall 2).
  - Decide the DNS zone owner first (overdue since 2026-08-15). It blocks P1 evidence and nono's configuration.
  - Note that an environment cannot switch internal↔external later.
- **Phase:** P1 (DNS/cert). P3 (routing).

### Pitfall 16: Issuer authenticates the user key incorrectly
- **What goes wrong:**
  - The issuer "validates" the caller by checking the key exists, but not that it is unblocked, unexpired and `principal_type=user`.
  - It trusts a principal type from the request.
  - It reads LiteLLM's Postgres tables directly. Prisma schema changes per release break this silently, and v1.103.3 now exits on migration failure.
  - The issuer holds the master key in env vars, where the same `/proc/self/environ` class of bug applies.
- **Prevention:**
  - Resolve the caller via LiteLLM's API using the caller key as bearer, then check `blocked`, `expires` and `metadata.principal_type == "user"` explicitly.
  - Give the issuer a dedicated LiteLLM admin/service key scoped to key-management routes, not `LITELLM_MASTER_KEY`. Fetch it from Key Vault via managed identity at startup.
  - Keep the issuer's DB (events, `agent_key`) in a separate database or schema from `litellm`.
- **Phase:** P3.

### Pitfall 17: Idempotent revocation that leaks existence, or authorizes on the wrong identity
- **What goes wrong:**
  - "Revocation by anyone other than the minting user key is refused" plus "already revoked returns success" combine badly. If an unknown `key_id` returns 404 but a foreign `key_id` returns 403, an attacker can enumerate keys.
  - `minted_by` stored as the user principal (UPN) instead of the user **key** makes it ambiguous after a user key rotates. The spec says "the minting key".
  - With introspection's bare `active:false`, timing or status-code differences reintroduce an oracle.
- **Prevention:**
  - Store `minted_by_token_hash` and the principal.
  - Decide and document the response for unknown versus foreign key_ids (recommend: same 403 for both foreign and unknown; 200 for own-already-revoked).
  - Make inactive introspection responses constant-shape, with the same status code.
- **Phase:** P3/P4.

### Pitfall 18: Registries checked in CI but not at runtime, or loaded per replica inconsistently
- **What goes wrong:**
  - The agent-ID, introspection-caller and relay registries pass CI.
  - At runtime the issuer reads a stale copy baked into an image, or replicas of the issuer and gateway hook load different versions after a partial rollout. A removed agent stays mintable.
  - ADR-002 size limits on the config secret grow as the registries are added.
- **Prevention:**
  - Version-stamp the registries (hash) and expose them on a health endpoint. Alert on mismatch across replicas.
  - Keep registries out of the LiteLLM config secret. The issuer owns them, and the gateway hook only needs relay key hashes.
- **Phase:** P3/P4.

### Pitfall 19: run_id cost alert computed from the ledger in the request path
- **What goes wrong:** The REQ-RUN-02 alert is implemented as a pre-call check against summed spend. That violates "observation never in the request path" and is subject to Pitfall 6 lag.
- **Prevention:** Use a scheduled KQL or SQL query over the ledger (lag is acceptable and stated), routed to the Teams action group. Budgets remain the in-path control.
- **Phase:** P5.

### Pitfall 20: Break-glass "moved to PIM" while standing access remains
- **What goes wrong:**
  - The PIM-eligible approver group is added, but the POC principal assignment, the Terraform deployer's Key Vault Secrets Officer role and `ignore_changes` drift on the break-glass secret remain. The effective break-glass path is unchanged.
  - PIM for Groups / Azure resource eligibility needs Entra ID P2 / ID Governance licensing for every eligible user.
  - Activation takes minutes, which needs rehearsal.
  - Key Vault `AuditEvent` diagnostics must be on, with an alert on secret `Get`, or "audited" is a claim without evidence.
- **Prevention:**
  - Make it a Terraform change: `azurerm_pim_eligible_role_assignment` for the approver group. Remove the POC principal assignment.
  - Move the deployer to a pipeline identity with time-bound elevation.
  - Add an alert on any break-glass vault `SecretGet`. Rehearse activation in the runbook drill and record the timings.
- **Phase:** P8.

---

## Minor Pitfalls

### Pitfall 21: Salt key and master key handling during the upgrade
Never rotate `LITELLM_SALT_KEY`. It encrypts stored credentials, and GHSA-7hp6 shows its cross-use. v1.104.0 refuses weak or default master keys. Confirm the Key Vault value passes before upgrading. v1.103.1 invalidates UI session tokens, which is harmless if the UI is disabled. **Phase:** P0.

### Pitfall 22: Spend log table growth and retention
LiteLLM_SpendLogs grows without bound. `maximum_spend_logs_retention_period` deletes rows, which is fatal for a "source of truth" ledger. Popeye needs its own retention and archival policy before enabling any LiteLLM cleanup job. Run cleanup jobs on one role (`LITELLM_JOB_ROLE=worker`) only. **Phase:** P5/P8.

### Pitfall 23: `/key/list` and filters changed semantics in v1.90.0 (exact match)
Fleet scripts that rely on substring alias matching to find a user's keys miss them. Leavers then don't get revoked. **Phase:** P6.

### Pitfall 24: Untracked evidence artifacts committed
`scripts/Test-PopeyeAzureVerificationVm.zip` and the evidence JSON are untracked, not ignored. P1 smoke evidence must be redacted and synthetic per the constraints. Add `.gitignore` entries before generating more evidence. **Phase:** P1.

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|---|---|---|---|
| Stay on v1.90.3 "until after nono ships" | No upgrade risk during integration | Known SSRF/token exfiltration and file-read on a gateway that now serves agent keys; baselines redone later | Never for agent-key traffic. Upgrade in P0 |
| Use LiteLLM token hash as `key_id` | No mapping table | Violates REQ-AGT-20, ratified change control with nono | Never |
| Attribution through `spend_logs_metadata` only | One config line | Forgeable; join lost on delete; possibly Enterprise-gated | Only for non-identity, informational tags |
| Custom auth for relay checks | Single hook | Enterprise license; skipped budget/expiry checks | Never on OSS |
| Rely on LiteLLM cache TTL for revocation | Zero code | Unbounded under issue #25553 resurrection | POC only, with stated bound and two-replica test |
| Copy user `max_budget` onto agent keys | Simple | Budget multiplied per agent key | Never; use user-entity budget |
| Leaver pass without a safety threshold | Simpler script | One Graph outage revokes the fleet | Never |
| `sh -c` without `exec` | Already works | Lost spend rows on every revision | Never; one-word fix |

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|---|---|---|
| LiteLLM `/key/generate` | Passing `duration` > upper bound expecting a clamp | Clamp in the issuer; read back `expires` |
| LiteLLM `/key/info` | `?key=sk-...` in the URL | Key as bearer, or local SHA-256 lookup in Popeye table |
| LiteLLM `/key/delete` | Assuming the ledger can still resolve the key | Block, plus Popeye tombstone table |
| LiteLLM spend logs | Reading identity from request-supplied metadata | Join `api_key` hash → Popeye `agent_key` |
| Azure Managed Redis | Assuming LiteLLM shares counters because Redis is configured in `router_settings` | Verify proxy usage cache wiring; avoid response caching |
| Foundry via managed identity | Ignoring that the Entra token is a forwardable bearer | Patch GHSA-3cv6; `allow_client_side_credentials: false`; block `api_base`/`user_config` |
| Microsoft Graph (MI) | Granting app roles in the portal; `Directory.Read.All` | Terraform `azuread_app_role_assignment`, `GroupMember.Read.All`, `-ClientId` for UAMI |
| Intune base URL | Expecting immediate effect | Requires logon/refresh; validate with a pilot ring |
| hometown/olive introspection caches | Caching negative results, or caching past `expires_at` | Cache positives ≤ 60 s and ≤ `expires_at`; never cache `active:false` as permanent |

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|---|---|---|---|
| Lowering `user_api_key_cache_ttl` for revocation | Postgres CPU and connection spikes | Redis revocation set in hook instead; measure in P2 | Hundreds of req/s across replicas |
| Connection pool × replicas | `too many connections` at scale-out | Pool limit = max_conn / (replicas × workers) minus issuer | `max_replicas` × 10 > SKU limit |
| Per-request introspection without caching in services | Issuer becomes the hot path for hometown | Honor the 60 s positive cache; issuer ≥ 2 replicas | Agent fan-out workloads |
| Presidio in pre-call | +latency on every call; analyzer outage = gateway outage | Decide fail mode; scope entities; measure | Any production load |
| Daily usage upsert lock contention (pre-1.105.1) | Missing SpendLogs rows | Upgrade; reconcile counts | High rate to a single model |

## Security Mistakes

| Mistake | Risk | Prevention |
|---|---|---|
| Management routes reachable with user/agent keys | Issuer bypass, never-expiring keys | `allowed_routes`, ingress path blocks, negative TCs |
| Secrets in env vars plus file-read CVE | Master key, DB admin password, Redis key exfiltrated | Patch; least-privileged DB user for LiteLLM (not admin); consider Key Vault fetch at start |
| Relay key in custom header | Header logged to spend logs/OTel | mTLS or signed assertion; hook strips header |
| Revocation not cascading from user key | Leaver's agents live up to 8 h | `minted_by` cascade in issuer |
| `active:false` responses that differ by reason | Key existence oracle | Constant shape, status code and timing |
| Admin UI on the internal FQDN | SSO-based role escalation (GHSA-7hp6, -g5ff, XSS GHSA-hhww) | Disable UI or path-block |

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---|---|---|
| Expired agent key returns a generic 401 | nono can't distinguish "re-mint" from "revoked/forbidden" | Distinct, stable error code (REQ-AGT-04), contract-tested across upgrades |
| Budget exhausted error changes 429→422 on upgrade | Clients' retry logic misfires | Document error contract in baselines; contract test |
| TTL silently clamped | Long agent sessions die at 8 h unexpectedly | Return granted `expires_at`; nono re-mints proactively |

## "Looks Done But Isn't" Checklist

- [ ] **Smoke ledger row (P1):** It is often missing a join proof. Verify the row is resolved through the `api_key` hash, not request metadata, and that the request count equals the row count.
- [ ] **Exchange (P3):** Often missing negative tests on LiteLLM-native `/key/generate` with user and agent keys.
- [ ] **key_id (P3/P5):** Often verified only in the exchange response. Verify byte-identity on all 5 surfaces *after* revocation and expiry.
- [ ] **Revocation (P4):** Often tested on one replica. Verify on ≥ 2 replicas under load, gateway plus stub services, and record the worst case.
- [ ] **Introspection (P4):** Often returns extra fields on inactive keys or a different status code. Verify bare `{"active":false}` for all four inactive classes (expired, revoked, unknown, user key).
- [ ] **Sentinel (P3/P4/P7):** Often greps only HTTP responses. Verify Log Analytics, App Insights, SpendLogs.metadata, ErrorLogs, Redis and event tables.
- [ ] **Budget (P2/P3):** Often tested per key. Verify user + agent combined spend is capped, and measure the overshoot across replicas.
- [ ] **Fleet leaver (P6):** Often tested on joiners. Verify empty, paged, nested and disabled fixtures plus the safety threshold, and the agent-key cascade.
- [ ] **Break-glass (P8):** Often "PIM added". Verify the POC principal and standing deployer access are removed and the SecretGet alert fires.
- [ ] **Baselines (P2):** Often missing the version, digest and config hash. Verify they are recorded and that the doc states re-measure triggers.

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---|---|---|
| Exploitable LiteLLM version in production | MEDIUM | Upgrade to a patched line. Rotate the master key, Postgres password, Redis key and any keys seen in logs. Review access logs for `/utils/transform_request` and `api_base` params |
| key_id format shipped wrong | HIGH | Requires a NONO_v0.4.3 §4 change and package re-ratification. Prevent instead |
| Agent keys minted outside the issuer | MEDIUM | Query VerificationToken for keys without `popeye_key_id`, block them, add `allowed_routes` |
| Mass revocation from leaver bug | MEDIUM | Re-run joiner pass from the authoritative group. Keys are new secrets, so desktops need redelivery (Intune) |
| Ledger rows lost (shutdown/lock) | MEDIUM | Reconcile from Foundry usage/billing for the window. State the gap in the evidence |
| Forged attribution in ledger | HIGH | Rebuild identity columns from the `api_key` join. Rows whose key mapping is gone are unrecoverable |

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---|---|---|
| 1 Vulnerable pinned version | P0 | CI GHSA-range check passes; digest-pinned |
| 2 Issuer bypass through native routes | P0 + P3 | Negative TCs: user/agent key → `/key/*` refused |
| 3 key_id vs token hash | P3 + P5 | TC-AGT-20 (1,000 keys), TC-AGT-21 after revoke and expire |
| 4 Forged attribution | P5 (pattern in P1) | Forged-metadata TC shows the true principal |
| 5 Revocation cache | P4 + P2 | Two-replica revocation soak; worst case recorded |
| 6 Redis wiring and budget overshoot | P0 + P2 | Redis keyspace inspected; overshoot measured |
| 7 Budget inheritance | P3 + P6 | Combined user + agent cap TC |
| 8 Secret leakage | P0 + P3/P4 + P7 | Multi-sink sentinel grep |
| 9 Custom auth / extra routes | P4 | TC-AGT-18/19 on every reachable route |
| 10 Expiry semantics | P3 | TC-AGT-08 clamp; distinct expired error contract test |
| 11 Shutdown loses rows | P0 + P2 | N sent = N rows across revision swap |
| 12 Leaver automation | P6 | Pester fixtures; dry-run diff; threshold abort |
| 13 Measurement validity | P2 (after P0) | Baselines doc carries version, digest and paired method |
| 14 DLP vs no-prompt-logging | P7 | Synthetic corpus sink-grep; latency delta |
| 15 DNS / routing / cert | P1 + P3 | nono/hometown resolve and trust FQDN; `/key/*` not routable externally |
| 16 Issuer caller validation | P3 | Blocked/expired/app/agent caller refused |
| 17 Revocation/introspection oracles | P3/P4 | Uniform responses test |
| 18 Registry consistency | P3/P4 | Registry hash on health endpoint matches across replicas |
| 19 run_id alert in path | P5 | Alert is a scheduled query |
| 20 Break-glass standing access | P8 | No non-PIM assignments on the vault; SecretGet alert drill |

## Sources

HIGH (official):
- GHSA-3cv6-jpf6-8222, SSRF/credential exfiltration, patched 1.90.7 and others: https://github.com/BerriAI/litellm/security/advisories/GHSA-3cv6-jpf6-8222
- GHSA-g5ff-637f-6q2m, file read through `vertex_ai_credentials`, < 1.95.0: https://github.com/BerriAI/litellm/security/advisories/GHSA-g5ff-637f-6q2m
- GHSA-7hp6-4w63-5g45, salt-key reuse to proxy admin, 1.91.0–1.100.3: https://github.com/BerriAI/litellm/security/advisories/GHSA-7hp6-4w63-5g45
- GHSA-4xpc-pv4p-pm3w (Host header auth bypass, < 1.84.0); GHSA-hx8v-g79f-8w5f (user_config SSRF, ≤ 1.83.8); advisory index: https://github.com/BerriAI/litellm/security/advisories
- PYSEC-2026-390 (JWT/OIDC cache collision, < 1.83.0): https://osv.dev/vulnerability/PYSEC-2026-390
- Release notes v1.90.0–v1.90.3 and the index (v1.103/v1.104 breaking changes, 422 budget error, v1.105.1 dropped-row fix): https://docs.litellm.ai/release_notes/
- LiteLLM production guidance (`user_api_key_cache_ttl` 60 s default, `proxy_batch_write_at`, `use_redis_transaction_buffer`, pool sizing, readiness probe): https://docs.litellm.ai/docs/proxy/prod
- Virtual keys reference (`allowed_routes`, `key_type`, `upperbound_key_generate_params` rejects rather than clamps, sha256 hashing): https://docs.litellm.ai/docs/proxy/virtual_keys
- Cost tracking (`spend_logs_metadata` through key, body and header; `user` → end_user warning): https://docs.litellm.ai/docs/proxy/cost_tracking.md
- Custom auth (Enterprise license with virtual keys; common checks off by default): https://docs.litellm.ai/docs/proxy/custom_auth
- Guardrail logging secret exposure incident (fixed 1.82.3): https://docs.litellm.ai/blog/guardrail-logging-secret-exposure-incident
- httpx client eviction incident: https://docs.litellm.ai/blog/httpx-cache-eviction-incident
- Container Apps rule-based routing GA (November 2025) and custom domains: https://learn.microsoft.com/en-us/azure/container-apps/rule-based-routing-custom-domain ; https://mc.merill.net/message/AZ512850
- Container Apps private DNS for internal environments: https://learn.microsoft.com/azure/container-apps/private-endpoints-with-dns
- Managed identity Graph app roles (not assignable in portal): https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/how-to-assign-app-role-managed-identity
- Get-MgGroupMember (direct members only, `-All` paging): https://learn.microsoft.com/powershell/module/microsoft.graph.groups/get-mggroupmember

MEDIUM (upstream PRs and issues, current status as of 2026-10-22):
- Issue #25553, stale key-object resurrection after `/key/update` (closed "not planned"): https://github.com/BerriAI/litellm/issues/25553
- PR #47609, deleted key accepted by other workers until TTL (open): https://github.com/BerriAI/litellm/pull/47609
- PR #36207, broadcast invalidation for revoked keys (closed unmerged): https://github.com/BerriAI/litellm/pull/36207
- PR #45974, spend counter TTL vs batched writes; readmission at budget (open): https://github.com/BerriAI/litellm/pull/45974
- PR #40940, stale caches and counters after budget reset on multi-pod (open): https://github.com/BerriAI/litellm/pull/40940
- PR #43110, Redis Cluster pub/sub gap for invalidation: https://github.com/BerriAI/litellm/pull/43110
- Issue #16336, request messages stored despite redaction (fixed Jan 2026): https://github.com/BerriAI/litellm/issues/16336
- Issue #20240, bearer token in guardrail_information on 1.81.0: https://github.com/BerriAI/litellm/issues/20240
- 2026-03-24 PyPI compromise (1.82.7/1.82.8; Docker image unaffected): https://www.netspi.com/blog/executive-blog/ai-ml-pentesting/litellm-supply-chain-compromise/ ; https://snyk.io/es/blog/poisoned-security-scanner-backdooring-litellm/

LOW (inference or needs verification in phase):
- Whether `litellm_settings.cache` is required for cross-replica spend counters in 1.90.3 / target version (Pitfall 6). Verify by Redis keyspace inspection.
- Whether `spend_logs_metadata` works on the OSS image, and request-versus-key precedence (Pitfall 4). Verify with a test.
- LiteLLM flush-on-SIGTERM behavior for batched spend (Pitfall 11).
- Exact `guardrail_information` contents for Presidio in the target version (Pitfall 14).
- Managed certificates being unusable for internal-only custom domains (Pitfall 15).

---
*Pitfalls research for: LiteLLM governance gateway with delegated agent keys (Popeye)*
*Researched: 2026-10-22*
