# Feature Research

**Domain:** Internal AI usage governance gateway (LiteLLM on Azure Container Apps) adding delegated agent principals: agent key exchange, introspection, relays, purpose labels, run metering, plus MVP operational closure
**Researched:** 2026-10-22
**Confidence:** MEDIUM-HIGH overall. RFC semantics and the spec mapping are HIGH. LiteLLM capability and licensing claims are MEDIUM (official docs, fetched today, against image `v1.90.3`). Competitor comparisons are LOW-MEDIUM (secondary sources).

---

## How This Domain Normally Works (Reference Patterns)

Popeye's ratified design is a small, opaque-bearer-key version of standard OAuth delegation. Mapping it onto the standards shows which behaviours reviewers and integrators will expect by default.

| Popeye feature | Established pattern | What the pattern says is expected | Popeye alignment |
|---|---|---|---|
| Agent key exchange (v0.4.1 §2) | **RFC 8693 Token Exchange**, delegation semantics: `subject_token` is the user, the actor is the agent, and the issued token carries an `act` claim | Delegation keeps the actor's identity separate from the subject's ("A still has its own identity separate from B"). Nested `act` records prior actors. `may_act` states who is allowed to become the actor. | Strong. `on_behalf_of` corresponds to `sub`, and `agent_id` corresponds to `act.sub`. The agent-ID registry plays the role of `may_act`. Refusing onward delegation (REQ-AGT-02/05) means a chain is never more than one level deep, which is stricter than 8693 and correct here. |
| Same pattern, Microsoft flavour | **Entra Agent ID OBO flow**: an agent identity blueprint exchanges a user token, and the result keeps the user's identity while naming the agent as the acting party | Agents hold no long-lived credentials. The user token is obtained by a client and passed in. | Same shape. Entra Agent ID is the obvious future replacement for "user virtual key as subject token" (v0.4.1 §2.6, deferred). |
| Introspection (v0.4.2) | **RFC 7662 Token Introspection** | The resource server must authenticate to the introspection endpoint. An inactive, unknown, or not-permitted token gets `{"active": false}` with no other information. Caching is allowed, and the cache window trades freshness for load. | Strong. REQ-AGT-13/14 match 7662 §2.2 and §4 almost word for word. The field names are Popeye's own (`expires_at`, `on_behalf_of`) rather than 7662's (`exp`, `sub`, `act`). That is acceptable because the contract is ratified. |
| Revocation (v0.4.1 §2.4) | **RFC 7009 Token Revocation** | Revoking an already-invalid token returns success (idempotent), and the caller must be the client the token was issued to. | Strong. REQ-AGT-10 matches. |
| Relayed calls with `direct_gateway=false` (v0.4.2 §2.6) | Sender-constrained tokens (**RFC 8705** mTLS-bound tokens, **RFC 9449** DPoP), plus a gateway "trusted proxy" allowlist | A bearer token is only usable when it is presented together with proof of a specific holder. | Partial, and deliberately so. `direct_gateway=false` binds the key to "some registered relay" rather than to a cryptographic holder. The spec states the replay risk on `direct_gateway=true` keys as accepted (§3). |
| Virtual keys, budgets, and tags | LiteLLM, Portkey, Kong, and agentgateway all use per-key budgets, rate limits, and metadata. Azure APIM uses `llm-token-limit`, `llm-emit-token-metric` with custom dimensions, and `llm-content-safety`. | Per-consumer token or cost quota, per-consumer usage metrics with custom dimensions, and an optional content-safety screen. | Covered by the existing gateway. Purpose labels and agent fields are extra custom dimensions on the same machinery. |
| Agent identity in AI gateways generally | Kong and others usually delegate agent identity to an external IdP (for example WSO2 IS in Kong's tutorial). No gateway product found ships agent principals natively with `on_behalf_of` cost rollup. | — | Popeye's agent principals are a differentiator, not a commodity. Expect to build them rather than configure them. |

**LiteLLM facts that shape the features (MEDIUM, docs.litellm.ai, fetched 2026-10-22):**
- `/key/generate` accepts `duration`, `metadata`, `key_alias`, `max_budget`, `budget_duration`, `soft_budget`, `models`, `team_id`, `user_id`, `tags`, `guardrails`, `allowed_routes`, `max_parallel_requests`, `tpm_limit`/`rpm_limit`. `/key/block`, `/key/unblock`, `/key/info` and regenerate also exist.
- LiteLLM's own key identifier is the **sha256 hash of the secret**. It is logged as `api_key` / `user_api_key_hash` in spend logs. It is **not a UUID**, so REQ-AGT-20 requires Popeye to mint its own UUID, store it in key metadata, and stamp it onto every spend-log row.
- Spend logs accept custom metadata from **three** sources: key/team `metadata.spend_logs_metadata`, request-body `metadata.spend_logs_metadata`, and the `x-litellm-spend-logs-metadata` header. The docs do not say which source wins. That makes attribution spoofing a live risk (see Gap G1).
- **Custom auth combined with virtual keys (`custom_auth_settings.mode: auto`) is Enterprise-only** (v1.72.2+). `async_pre_call_hook` on a `CustomLogger` sees `user_api_key_dict` and the request `data`, and can reject with `HTTPException`. No licence restriction is documented for it. This is the likely open-source enforcement point for the relay check, purpose/class prohibition, and metadata stamping. Its licensing is unconfirmed, so treat that as LOW.
- **Per-key guardrails are Enterprise-only.** Guardrails with `default_on: true` (all traffic) are available in open source. Supported providers include Presidio, Azure Content Safety/text moderation, Lakera, and Bedrock. Available modes are `pre_call`, `during_call`, `post_call`, and `logging_only`.

---

## Feature Landscape

### Table Stakes (Users Expect These)

"Users" here means nono, hometown, olive, and Liam as integrators, plus security/risk and FinOps as reviewers. Missing any of these means the ratified package is not met, or a reviewer rejects the design.

| # | Feature | REQ coverage | Why Expected | Complexity | Notes |
|---|---|---|---|---|---|
| T1 | **Principal type on every key**; agents carry `agent_id` and `on_behalf_of`; onward delegation refused | REQ-AGT-01, -02 (v0.4 draft); vocab `agent_delegation` | Baseline of every delegation model (8693 `act`). Without it the ledger can't tell an agent from a user. | LOW | Validation lives in the issuer. Existing user keys need back-filling with `principal_type=user` (see G9). |
| T2 | **Agent key exchange endpoint**: user-key auth only; `on_behalf_of` taken from the caller; body `on_behalf_of` ignored | REQ-AGT-05, -06 | The core of 8693 and Entra OBO is that the subject comes from an authenticated token, never from the request body. | MEDIUM | First Popeye runtime service (Python on a second Container App). The admin key stays server-side. |
| T3 | **Registry-checked `agent_id` and vocabulary-checked `purpose`**, with distinct errors | REQ-AGT-07, REQ-PUR-06 | Equivalent to `may_act`: only known actors may be delegated to. | LOW-MEDIUM | Agent-ID registry beside the model registry, CI-checked against vendored `vocabulary.yaml` (O3 default). |
| T4 | **TTL clamp (8h cap, shorten never lengthen)**; expired key refused with a distinct error | REQ-AGT-04, -08 | Short-lived delegated credentials are the whole governance win (v0.4 §2.2). Every OBO system caps them. | LOW | Also clamp to the parent user key's expiry (G4). Check LiteLLM's native expired-key error is distinct; otherwise remap it in the hook. |
| T5 | **Inherited, never-exceeded constraints** (class ceiling, tenant, budget) | REQ-AGT-09 | "Intersection, never union" (vocab `permission_model`). This is the property reviewers test first. | MEDIUM | How budget is inherited is under-specified (G2): a *copied* budget multiplies spend by N agent keys. |
| T6 | **Idempotent revocation limited to the minting key** | REQ-AGT-10 | RFC 7009 behaviour. | LOW | Uses LiteLLM `/key/block` or delete. Issuer-side status is the source of truth for introspection. Admin and cascade revocation are missing (G3). |
| T7 | **Issuance and revocation events**, content-free | v0.4.1 §2.5 (no REQ ID) | An audit trail of who minted what is standard for any credential issuer, and SOC/risk will ask for it. | LOW-MEDIUM | No REQ/TC, and the sink, schema and retention are unspecified (G6). |
| T8 | **`key_id` as lowercase UUIDv4/v7, never reused, byte-identical across exchange, revocation, ledger, events and introspection** | REQ-AGT-20, -21 | nono stores a 16-byte `KeyId`. This is a hard cross-repo contract. | MEDIUM | LiteLLM's token hash is not a UUID, so the issuer must mint the UUID, bind it in key metadata, and stamp it onto every ledger row. The v0.1 `key_ref` design (SESSION_CREDENTIAL_ISSUER) is superseded and must be retired explicitly (G8). |
| T9 | **Attributed ledger row per completion**: principal type, `agent_id`, `on_behalf_of`, `purpose`, `key_id`, `tenant_id`, `run_id`, `relayed_by` | REQ-AGT-03, -11, -17, REQ-RUN-01; MVP checklist WS2 | This is the Core Value. Every gateway product offers per-key cost attribution. Popeye's version adds the agent dimensions. | MEDIUM | Must be server-stamped from key metadata, never trusted from request metadata (G1). The MVP smoke proof (one row through `twg-foundry`) is the prerequisite. |
| T10 | **Token introspection for registered services**: identity fields only; bare `active:false`; read-only; registered callers only; no secrets | REQ-AGT-12 to -15 | Textbook RFC 7662. hometown and olive cannot accept agent keys without it. | MEDIUM | Sentinel test on secrets. The relay header secret should also be covered by the sentinel test (G7). |
| T11 | **Revocation propagation bound (60s cache)** | REQ-AGT-16 | Any cached-introspection design must state its staleness window. | LOW (popeye side) | Popeye's part is that revocation is immediately visible at introspection and the gateway. The 60s bound is the consumers' cache discipline, tested against stubs. Gateway-side enforcement goes through LiteLLM's key cache and needs measuring (G5). |
| T12 | **Purpose/class prohibition at request time** | REQ-PUR-07 | Same shape as the existing data-class enforcement. A missing check would be an obvious policy hole. | MEDIUM | Needs a request-time hook. LiteLLM does not do this natively. `analytics`/`marketing` keys must not reach `regulated-financial`+ models. |
| T13 | **Relay enforcement**: `direct_gateway=false` keys usable only through a registered relay; `relayed_by` recorded; unregistered relays refused | REQ-AGT-17, -18, -19 | Ratified, and Liam E2E (TC-E2E-01/05/07) depends on it. | MEDIUM-HIGH | Relay identity mechanism (header or mTLS) is Popeye's choice. A header is the realistic POC choice on Container Apps internal ingress. Needs the pre-call hook. |
| T14 | **Run cost alert** | REQ-RUN-02 (DEMO) | Runaway agents are the case the program exists to catch, and per-request rate limits miss them. | MEDIUM | v0.4 says Popeye doesn't compute run totals, yet the alert needs an aggregate. Resolve by running a scheduled out-of-band ledger query (G10). |
| T15 | **Tenant UUID enforcement at issuance** | REQ-DCE-07 | Program identifier convention. | LOW | Applies to fleet-provisioned user keys too. Agent keys inherit `tenant_id`, so they never take it from the body. |
| T16 | **Fleet user-key provisioning** (Entra group to virtual keys, joiner/leaver) | No REQ ID (PROJECT Active; checklist WS6 calls it Stage 3) | Agent keys derive from user keys, so no user keys means no agents. Leaver revocation is a standard identity-governance control. | MEDIUM-HIGH | Graph app permissions, idempotency, and the leaver cascade into agent keys (G3). `on_behalf_of` identifier format must be fixed first (G11). |
| T17 | **Gateway base URL pushed to managed desktops** (Intune) | No REQ ID | Makes the governed path the zero-configuration path (Corrections §3.1). | LOW-MEDIUM | Can overlap with nono's own configuration. Confirm which wins on agent profiles. |
| T18 | **Stage 1 SLO baselines**: latency overhead p50/p95/p99, budget counter lag, ledger freshness, ledger-interruption behaviour, budget vs throttle payloads | Checklist WS3; Corrections P-4 (Option B) | An internal platform without SLOs isn't operable, and alert thresholds depend on these numbers. | MEDIUM | The issuer and introspection endpoints are now in the agent-start path and have no SLO (G12). |
| T19 | **Six rehearsed runbooks + break-glass through a named group/PIM** | Checklist WS5 | Standard operational-readiness gate. | LOW-MEDIUM (process-heavy) | Add issuer-specific runbooks: issuer down, mass agent-key revocation (G13). |
| T20 | **Endpoint `twg-gateway-only` profile demonstrated; detections content-free and reaching alerting** | REQ-END-03, -04, -05 | Bypass detection is expected for a gateway-only policy. | MEDIUM (cross-repo with nono) | POC-grade transport (JSONL forwarding) is accepted. |
| T21 | **Registry conformance**: class names match the vocabulary; `regulated-identifier` unapprovable | REQ-DCE-05, -06 | Already largely validated. Keep it in the same CI job as the agent-ID registry. | LOW | Mostly done. |

### Differentiators (Competitive Advantage)

These align with the Core Value ("every governed call is attributed") and go beyond what LiteLLM, Portkey, Kong, or APIM give out of the box.

| # | Feature | REQ coverage | Value Proposition | Complexity | Notes |
|---|---|---|---|---|---|
| D1 | **Dual attribution: cost rolls up to `on_behalf_of`, activity to `agent_id`** | REQ-AGT-03; v0.4 §2.3 | Answers "what did agents spend on behalf of the servicing team?" No commercial gateway found ships agent-OBO cost rollup natively. | LOW once T9 exists | The value is mostly in hometown's Cube model. Popeye only needs clean, non-null, stable dimensions. |
| D2 | **Cross-system join key (`key_id` UUID) linking ledger to nono receipt to Liam ATE (`run_id`)** | REQ-AGT-20, -21, REQ-RUN-01 | End-to-end provenance from endpoint sandbox to model spend, keyed by one non-secret identifier. | MEDIUM | Depends on T8 being byte-exact everywhere. TC-AGT-21 is the proof. |
| D3 | **Sanctioned relay with preserved agent attribution (`relayed_by`)** | REQ-AGT-17 to -19 | Most gateways attribute a relayed call to the relaying service's credential and lose the agent and user. Popeye keeps both and records the hop. | MEDIUM-HIGH | Same as T13. It is a differentiator because of attribution fidelity, not access control. |
| D4 | **Per-run short-lived keys instead of per-run budgets** | v0.4 §6 | Reuses per-key budget machinery. One key per run makes `key_id` a natural run boundary and caps blast radius by time. | LOW | Works only if budgets are drawn from a shared parent pool rather than copied (G2). |
| D5 | **Semantics-blind gateway with explicit refusals** (REQ-PGM-03 table) | v0.4 §5 | Keeps the gateway replaceable. Purpose is an opaque label with one hard-coded pairing rule. | — (discipline, not code) | A design-review asset. Put the refusal list in the requirements doc so scope creep can be rejected by citation. |
| D6 | **Content-free events across issuance, introspection and detection** | v0.4.1 §2.5, v0.4.2 §2.4, REQ-END-04 | Audit-grade evidence with no prompt-content retention liability. | LOW | Sentinel tests make this provable. |
| D7 | **Agent-ID registry with per-agent policy** (owner, allowed purposes, max TTL, `direct_gateway` default) | **Not in spec.** Spec only requires the registry to exist. | Moves from "agent is known" to "agent is scoped", which is the natural next step toward 8693 `may_act`. | LOW-MEDIUM | Recommend capturing `owner` and `allowed_purposes` now, enforcing later. Adding fields is cheap; retrofitting owners is not. |
| D8 | **Gateway DLP/guardrail with no-prompt-logging intact** | Checklist WS4 (evaluation only) | Most gateways offer guardrails but log prompts for review. Popeye would run guardrails without retention. | MEDIUM (eval) / HIGH (prod) | Deliverable this milestone is a go/no-go. Open-source LiteLLM supports `default_on` global guardrails; per-key/per-purpose guardrails are Enterprise. |

### Anti-Features (Commonly Requested, Often Problematic)

| Anti-Feature | Why Requested | Why Problematic | Alternative |
|---|---|---|---|
| **Accepting `on_behalf_of` (or `tenant_id`, `principal_type`) from the exchange body** | The pre-ratification v0.1 issuance schema (`contracts/schemas/session-credential-issuance-request-v0.1.schema.json`) *requires* them, and nono could "just send them". | An endpoint could mint a key for another user. Contradicts REQ-AGT-06. | Derive from the authenticated user key. Retire or rev the v0.1 schema to match v0.4.1 §2.1 (G8). |
| **Onward delegation / agent-mints-agent** | Multi-agent orchestrators want sub-agents. | Nested chains break `on_behalf_of` rollup and "intersection" reasoning. RFC 8693 marks nested actors informational only. | Orchestrator asks the *user's* nono-proxy for a sibling key (same `on_behalf_of`, different `agent_id`). |
| **Long-lived or refreshable agent keys** | Fewer exchange calls; long batch agents. | "Shadow-AI problem returning wearing a costume" (v0.4 §2.2). Refresh turns an 8h cap into infinite. | Re-exchange with the live user key. Introspection is read-only and cannot refresh (REQ-AGT-15). |
| **Introspection returning reasons for inactivity** ("expired" vs "revoked") | Easier debugging for hometown/olive. | Enumeration oracle; violates REQ-AGT-13 and RFC 7662 guidance. | Reasons go in Popeye's own introspection events, visible to operators only. |
| **Per-run budgets or Popeye-computed run totals in the request path** | "Stop the runaway agent mid-run." | Two cost calculations eventually disagree. Puts aggregation in the hot path, which breaks "observation never in the request path". | Per-run short-lived key with an inherited (shared) budget for hard stops. Run totals from a scheduled ledger query for alerting. |
| **Tool-call metering in the ledger** | Complete agent cost picture. | Tool calls aren't model calls; olive owns that record (v0.4 §6). | Join olive's execution record to the ledger on `run_id` in hometown. |
| **Purpose semantics in the gateway** (field permissions, group resolution of `on_behalf_of`, action approval) | Popeye already sees every call, so it is tempting to centralise. | Gateway becomes irreplaceable (REQ-PGM-03). | hometown (purpose masking, group resolution) and olive (actions). |
| **Prompt logging "just for DLP tuning"** | Guardrail false-positive analysis. | Breaks the no-prompt-logging constraint and creates a regulated data store. | Synthetic test corpus. Guardrail verdict and category only in logs (`logging_only` mode emits verdicts; confirm it doesn't persist bodies). |
| **Machine-identity / Entra-token exchange now** | Removes the user key from the endpoint; Entra Agent ID exists. | Explicitly deferred (v0.4.1 §2.6, NONO O2). It changes the nono seam and needs re-ratification. | Record Entra Agent ID OBO as the target for a later stage. Keep the field names compatible (`on_behalf_of` = subject, `agent_id` = actor). |
| **Exposing the issuer or introspection publicly / to unregistered services** | Convenience for new consumers. | Internal-only is a hard rule. Adding an introspection caller or relay is a program decision. | Registry PR plus program decision, enforced in CI. |
| **Adopting LiteLLM Enterprise just for custom-auth or per-key guardrails** | Native features. | Licence cost and vendor coupling for things a pre-call hook plus issuer can do. | Thin issuer (Option B) plus `async_pre_call_hook`. Revisit only if the DLP go/no-go needs per-purpose guardrails. |

---

## Gaps the Ratified Specs Don't Cover

These are requirement candidates. Severity is relative to the nono/Liam dependency and the Core Value.

| ID | Gap | Why it matters | Severity | Suggested requirement |
|---|---|---|---|---|
| **G1** | **Attribution anti-spoofing.** No requirement says request-supplied metadata (`metadata.spend_logs_metadata`, `x-litellm-spend-logs-metadata`, `tags`, a body `on_behalf_of`/`key_id`/`relayed_by`) cannot override key-bound attribution. LiteLLM merges all three sources, with undocumented precedence. | A caller could write a false `on_behalf_of` or `relayed_by` into the ledger, which breaks the Core Value. | **CRITICAL** | "Ledger principal fields are derived from key metadata and the validated relay identity only. Request-supplied values for those fields are dropped or refused." Add a TC that sends forged fields and asserts the row is unchanged. `run_id` stays request-supplied by design. |
| **G2** | **Budget inheritance semantics.** REQ-AGT-09 says "inherit budget" but not whether the budget is *shared* (drawn from the user's pool) or *copied*. | A copied `max_budget` on each agent key means N concurrent agents spend N times the user's budget. This defeats D4. | **HIGH** | Agent-key spend counts against the minting user's budget (for example, LiteLLM user-level budget via shared `user_id`, or a per-key `max_budget` set to the parent's *remaining* budget at mint time). Pick one and test it. |
| **G3** | **Revocation beyond the minting key.** Only the minting user key can revoke (REQ-AGT-10). There is no operator/incident revocation (kill one agent key, all keys for an `agent_id`, or all keys for an `on_behalf_of`), and no cascade when the user key is revoked by the leaver flow. | A leaver's agent keys stay valid for up to 8h. A compromised agent can't be stopped by security without the user's key. | **HIGH** | Admin revocation path (break-glass/PIM-gated) by `key_id`, `agent_id`, or `on_behalf_of`. Revoking a user key revokes its live agent keys. Runbook for mass revocation. Check that this doesn't conflict with REQ-AGT-10 ("by anyone other than the minting user key is refused"), which may need a carve-out ratified with nono. |
| **G4** | **Agent expiry bounded by parent expiry.** The TTL clamp is `min(requested, 8h)` and ignores the user key's own expiry or blocked state. | Agent key outlives its delegating credential. | MEDIUM | `expires_at = min(requested, cap, parent_expiry)`. Refuse a blocked or expired parent. |
| **G5** | **Gateway-side revocation latency.** REQ-AGT-16 bounds *service* caches at 60s, but LiteLLM's own key cache (Redis/in-memory, `user_api_key_cache_ttl`) decides how fast a revoked or blocked key stops working *at the gateway*. | Revocation could be slower at the gateway than at hometown/olive. | MEDIUM | Measure in the Stage 1 protocol and set the LiteLLM cache TTL to ≤ 60s. Add a TC: a revoked key is refused at the gateway within the bound. |
| **G6** | **Issuance/introspection event storage.** Sink (Postgres table, Log Analytics), schema, retention, and reader access are unspecified, and neither event type has a REQ/TC. | Audit evidence may be unqueryable or lost. Hometown may need the events to join. | MEDIUM | Event schema in `contracts/schemas/`, sink decision, and a TC that one exchange produces one event with a byte-identical `key_id` (already part of TC-AGT-21's five surfaces). |
| **G7** | **Relay credential hygiene.** If relay identity is a header carrying hometown's application key, nothing says the header must be stripped before the upstream call, kept out of logs, or rejected on non-relay routes. | Leaks a service secret into provider requests and logs. | MEDIUM | Extend the REQ-AGT-12 sentinel test to the relay header. Strip it in the pre-call hook. |
| **G8** | **Contract drift with pre-ratification artefacts.** `session-credential-issuance-request-v0.1.schema.json` requires `on_behalf_of`, `tenant_id`, `principal_type`, `session_id`, `device_ref`, `requested_ttl_seconds`, and has `additionalProperties:false`. Ratified v0.4.1/v0.4.2 bodies are `agent_id`, `purpose`, `ttl_seconds`, `direct_gateway`. `SESSION_CREDENTIAL_ISSUER_v0.1` still says "Option A selected" and defines `key_ref`, both superseded. | A strict schema would reject valid ratified requests, and fixture CI tests the wrong contract. | **HIGH** (cheap to fix, expensive if missed) | New `agent-key-exchange-request` schema matching v0.4.1/v0.4.2. Mark v0.1 superseded. Decide whether `session_id`/`device_ref` survive (nono-side question). |
| **G9** | **Back-filling existing user keys.** No requirement covers giving existing virtual keys `principal_type=user`, a canonical user identifier, `tenant_id` and (O1) a purpose list. | The exchange cannot derive `on_behalf_of` or inherit constraints from a key missing them. REQ-AGT-01 says *every* key. | MEDIUM | Migration step in the fleet-provisioning phase. Exchange refuses callers whose key lacks the required metadata, with a distinct error. |
| **G10** | **Run-cost alert mechanics.** v0.4 says Popeye doesn't compute run totals, but REQ-RUN-02 needs an aggregate. The threshold value, evaluation cadence, and behaviour when `run_id` is absent are unspecified. | Alert either never fires or violates "not in request path". | MEDIUM | Scheduled query over the ledger (Postgres to Log Analytics, or an Azure Monitor scheduled query) grouped by `run_id`, with fallback to `key_id`. Provisional threshold recorded in STAGE1_BASELINES and tuned later. Detection latency equals the cadence plus ledger freshness (measured in WS3). |
| **G11** | **`on_behalf_of` identifier format.** Fixtures use a UPN (`alex@example.invalid`). The vocabulary fixes `tenant_id` format but not the principal identifier. | UPNs change on rename or marriage, which breaks cost rollup and hometown group resolution. Fleet provisioning hard-codes whatever is chosen. | **HIGH** (one-way door) | Use the Entra object ID (UUID) as the canonical `on_behalf_of`, with UPN as a display attribute only. Needs a vocabulary/program decision, so raise it with fiskroad before fleet keys are minted. |
| **G12** | **Issuer/introspection SLOs.** Stage 1 baselines cover the gateway only. The exchange sits in every agent start and introspection in every hometown/olive call. | An issuer outage blocks all agent work, with no target or alert. | MEDIUM | Add issuer availability and p95 latency to the baselines, plus a 5xx/availability alert matching the existing gateway alerts. |
| **G13** | **Runbooks for the new surface.** The six MVP runbooks predate the issuer. | No procedure for issuer down, suspected agent-key compromise, registry mis-edit, or relay misbehaviour. | MEDIUM | Add two runbooks: issuer failure and agent-key mass revocation (the latter depends on G3). |
| **G14** | **Exchange abuse limits.** There is no cap on exchange rate or on live agent keys per user. | Key sprawl, LiteLLM key-table growth, and introspection load. A compromised user key mints thousands of keys. | LOW-MEDIUM | Per-caller rate limit and a max-live-agent-keys cap. Expired-key cleanup job. |
| **G15** | **Distinct error catalogue.** Several TCs require "distinct errors" (expired, unknown agent, invented purpose, prohibition, direct_gateway refusal, unregistered relay, non-user caller), but no codes are defined. nono/Liam must branch on them. | Integrators parse strings, and the tests become brittle. | MEDIUM | Stable error codes in a contract file (the Option B rationale already promises "stable contract-facing error"). |
| **G16** | **Application-principal key issuance.** hometown and olive need `principal_type=application` keys for introspection and relaying, but no issuance path, rotation, or registry binding is specified. | Introspection callers can't authenticate without them. | MEDIUM | Admin-issued application keys bound to the introspection-caller/relay registry, Terraform- or script-managed, stored in Key Vault. |
| **G17** | **Guardrail and the purpose dimension.** The DLP evaluation is global. Nothing considers whether guardrail policy varies by purpose or data class. Per-key guardrails in LiteLLM are Enterprise. | The go/no-go may recommend something open-source LiteLLM can't do per purpose. | LOW (evaluation phase) | Make "global `default_on` only vs per-key" an explicit criterion in the WS4 evaluation. |

---

## Feature Dependencies

```
[MVP smoke proof: one attributed ledger row via twg-foundry] (WS2)
    └──enables──> [Stage 1 baselines + SLOs] (WS3) ──enables──> [burn-rate alerts, run-cost threshold value]
    └──enables──> [Attributed ledger stamping incl. key_id/agent fields] (T9, G1)

[on_behalf_of identifier decision] (G11)
    └──required by──> [Fleet user-key provisioning + back-fill] (T16, G9)
                          └──required by──> [Agent key exchange] (T2)

[Agent-ID registry + introspection-caller/relay registries, CI-checked] (T3, D7, T21)
    └──required by──> [Agent key exchange] (T2) and [Introspection] (T10) and [Relay enforcement] (T13)

[Exchange contract schema re-based on v0.4.1/v0.4.2] (G8) + [error catalogue] (G15)
    └──required by──> [Agent key exchange] (T2)

[Agent key exchange] (T2: T1, T3, T4, T5, T8, T15, G2, G4)
    ├──required by──> [Revocation + issuance events] (T6, T7, G6)
    │                     └──required by──> [Admin/cascade revocation] (G3) ──enhances──> [Joiner/leaver] (T16)
    ├──required by──> [Introspection] (T10) ──required by──> [Revocation propagation TC] (T11, G5)
    └──required by──> [Request-time pre-call hook]
                          ├── [Purpose/class prohibition] (T12)
                          ├── [Relay validation + direct_gateway + relayed_by] (T13, G7)
                          └── [Attribution stamping / anti-spoof] (T9, G1)

[application keys for hometown/olive] (G16) ──required by──> [Introspection] (T10), [Relay] (T13)

[Ledger rows with run_id] (REQ-RUN-01) ──required by──> [Run-cost alert] (T14, G10)

[TC-AGT-21 five-surface key_id trace] requires exchange + revocation + ledger + events + introspection all live

[DLP/guardrail evaluation] (D8) ──conflicts──> [prompt logging] (constraint)
[Per-key guardrails] ──conflicts──> [open-source LiteLLM] (Enterprise feature)
[Machine-identity exchange] ──conflicts──> [ratified nono seam] (needs re-ratification)
```

### Dependency Notes

- **One pre-call hook serves three requirements.** Purpose/class prohibition (REQ-PUR-07), relay enforcement (REQ-AGT-18/19) and attribution stamping (G1) all need request-time logic with access to key metadata and headers. Build it once, in one phase, with one test harness. Its licensing (open-source `CustomLogger` hook) should be verified early against `v1.90.3`.
- **G11 is a one-way door ahead of fleet provisioning.** Once user keys are minted with UPN-based `on_behalf_of`, changing it rewrites ledger history.
- **The exchange must not ship before G8 and G2 are settled.** Shipping against the old v0.1 schema, or with copied budgets, creates defects that nono will build on.
- **TC-AGT-21 is the integration gate for nono.** It needs all five surfaces, so it belongs at the end of the agent-key phases, not in the first.
- **The MVP smoke proof is independent of agent work** but is the foundation for every live (CI-live) TC. Do it first.

---

## MVP Definition (for this milestone)

### Launch With (milestone exit)

- [ ] MVP smoke proof: one attributed ledger row through `twg-foundry` (WS2), since every live TC depends on it
- [ ] `on_behalf_of` identifier format decided (G11), because it's a one-way door
- [ ] Exchange contract schema re-based, error catalogue, registries (agent-ID, introspection callers, relays) in CI (G8, G15, T3)
- [ ] Agent key exchange with TTL clamp (including parent expiry), inheritance with a **shared** budget, UUID `key_id`, revocation, events (REQ-AGT-01..11, -20; G2, G4, G6)
- [ ] Pre-call hook: purpose/class prohibition, relay/`direct_gateway`, attribution stamping with anti-spoofing (REQ-PUR-06/07, REQ-AGT-17..19; G1, G7)
- [ ] Introspection with sentinel tests and revocation propagation, including the gateway cache bound (REQ-AGT-12..16; G5)
- [ ] TC-AGT-21 five-surface trace passes (nono's gate)
- [ ] `run_id` on ledger rows plus a scheduled run-cost alert (REQ-RUN-01/02; G10)
- [ ] Stage 1 baselines including issuer SLOs; Option B fallback descope recorded (WS3; G12)
- [ ] Fleet user-key provisioning with metadata back-fill and leaver revocation (T16; G9)
- [ ] Runbooks rehearsed (six plus issuer-failure plus agent-key mass revocation), break-glass on PIM/group (WS5; G13)
- [ ] DLP go/no-go recommendation (WS4)
- [ ] Corrections v0.3: REQ-DCE-05..07, REQ-END-03..05

### Add After Validation (v1.x)

- [ ] Admin/cascade revocation by `agent_id`/`on_behalf_of` (G3). Strongly recommended in-milestone if the REQ-AGT-10 carve-out can be ratified quickly. Otherwise ship user-key-revocation cascade only.
- [ ] Per-agent policy in the registry: owner, allowed purposes, max TTL (D7)
- [ ] Exchange rate limits and live-key caps (G14)
- [ ] Guardrail rollout per the go/no-go (global `default_on` first)

### Future Consideration (v2+)

- [ ] Entra Agent ID / machine-identity token exchange replacing user-key subject tokens (deferred, needs nono re-ratification)
- [ ] Sender-constrained agent keys (mTLS/DPoP-style) replacing `direct_gateway=true` bearer semantics
- [ ] RFC 7662-compatible field aliases (`exp`, `sub`, `act`) if non-program consumers appear
- [ ] Second-provider fallback (Stage 3; TC-REL-02, TC-COST-04)

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---|---|---|---|
| MVP smoke proof (WS2) | HIGH | LOW | P1 |
| `on_behalf_of` identifier decision (G11) | HIGH | LOW | P1 |
| Contract schema re-base + error catalogue (G8, G15) | HIGH | LOW | P1 |
| Agent key exchange + revocation + events (T1–T8) | HIGH | MEDIUM | P1 |
| Shared-budget inheritance (G2) | HIGH | MEDIUM | P1 |
| Pre-call hook: prohibition, relay, anti-spoof (T12, T13, G1) | HIGH | MEDIUM-HIGH | P1 |
| Introspection (T10, T11) | HIGH | MEDIUM | P1 |
| `key_id` five-surface trace (TC-AGT-21) | HIGH | MEDIUM | P1 |
| Fleet provisioning + back-fill (T16, G9) | HIGH | MEDIUM-HIGH | P1 |
| Stage 1 baselines + SLOs (T18, G12) | HIGH | MEDIUM | P1 |
| Run-cost alert (T14, G10) | MEDIUM | MEDIUM | P1 (DEMO) |
| Runbooks + PIM break-glass (T19, G13) | MEDIUM | LOW-MEDIUM | P1 |
| DLP go/no-go (D8) | MEDIUM | MEDIUM | P1 (evaluation only) |
| Endpoint detection demo (T20) | MEDIUM | MEDIUM | P1 |
| Intune base URL (T17) | MEDIUM | LOW | P2 |
| Admin/cascade revocation (G3) | HIGH | MEDIUM | P1-P2 (ratification-dependent) |
| Registry per-agent policy (D7) | MEDIUM | LOW | P2 |
| Exchange abuse limits (G14) | MEDIUM | LOW | P2 |
| Machine-identity exchange | MEDIUM | HIGH | P3 |

---

## Competitor Feature Analysis

| Feature | LiteLLM (OSS) | Portkey / Kong / agentgateway | Azure APIM AI gateway | Popeye approach |
|---|---|---|---|---|
| Virtual keys with budget/expiry | Native (`/key/generate`, `duration`, `max_budget`) | Native in Portkey/agentgateway. Kong uses rate-limit plugins (request-based in tutorials) | Subscriptions + `llm-token-limit` quotas | Use LiteLLM natively behind the issuer |
| Agent principal / OBO | Not native. Metadata only | Not native. Kong delegates to an external IdP (WSO2 tutorial) | Not native. Pair with Entra Agent ID | **Built**: issuer + metadata + hook (differentiator) |
| Token exchange | None | None found | Entra handles OBO upstream | Thin issuer implementing 8693-style delegation over opaque keys |
| Introspection for downstream services | `/key/info` (admin-scoped, returns more than identity) | Not found | Entra token validation | **Built**: restricted, 7662-style. Never expose `/key/info` |
| Per-request custom attribution dimensions | `spend_logs_metadata`, tags (spoofable from request) | Metadata/tags | `llm-emit-token-metric` custom dimensions | Server-stamped from key metadata (G1) |
| Content guardrails | Presidio, Azure Content Safety, Lakera, etc. Per-key = Enterprise | Portkey guardrails; Kong AI Prompt Guard / PII plugins (LOW, unverified) | `llm-content-safety` | Evaluate this milestone, go/no-go |
| Runaway/run alerts | Budget alerts per key/user/team (Slack; other channels vary, LOW) | Budget limits per key | Azure Monitor on emitted metrics | Scheduled ledger query by `run_id` → Teams action group |

---

## Sources

- RFC 8693 OAuth 2.0 Token Exchange (§1.1, §2.1, §4.1, §4.4): https://www.rfc-editor.org/rfc/rfc8693.html (HIGH)
- RFC 7662 Token Introspection; RFC 7009 Token Revocation; RFC 8705; RFC 9449: rfc-editor.org (HIGH; behaviours cited from the standards, cross-checked against the specs' own language)
- LiteLLM virtual keys: https://docs.litellm.ai/docs/proxy/virtual_keys (MEDIUM)
- LiteLLM custom auth (Enterprise for combined mode): https://docs.litellm.ai/docs/proxy/custom_auth (MEDIUM)
- LiteLLM call hooks: https://docs.litellm.ai/docs/proxy/call_hooks (MEDIUM; licence of `async_pre_call_hook` not stated, so LOW on that point)
- LiteLLM cost tracking / spend logs metadata: https://docs.litellm.ai/docs/proxy/cost_tracking (MEDIUM)
- LiteLLM guardrails: https://docs.litellm.ai/docs/proxy/guardrails/quick_start (MEDIUM)
- Azure APIM AI gateway capabilities: https://learn.microsoft.com/azure/api-management/genai-gateway-capabilities (MEDIUM via search summary)
- Microsoft Entra Agent ID OBO flow: https://learn.microsoft.com/en-us/entra/agent-id/agent-on-behalf-of-oauth-flow (MEDIUM)
- draft-oauth-ai-agents-on-behalf-of-user-02 (expired individual draft): https://datatracker.ietf.org/doc/html/draft-oauth-ai-agents-on-behalf-of-user-02 (LOW, context only)
- Kong agent identity tutorial (WSO2): https://is.docs.wso2.com/en/next/tutorials/kong-ai-gateway-with-agent-identity-aware-access-control/ (LOW)
- agentgateway virtual keys: https://agentgateway.dev/docs/kubernetes/main/llm/virtual-keys/ (LOW)
- Gateway comparisons (secondary): https://www.tooljunction.io/blog/?p=3949, https://spheron.network/blog/ai-gateway-litellm-portkey-kong-gpu-cloud (LOW)
- Internal: specs/POPEYE_v0.4*.md, POPEYE_CORRECTIONS_v0.3.md, STAGE1_STAGE2_MVP_COMPLETION_CHECKLIST_v0.1.md, SESSION_CREDENTIAL_ISSUER_v0.1.md, config/vendored/vocabulary.yaml, contracts/schemas/session-credential-issuance-request-v0.1.schema.json (HIGH)

---
*Feature research for: AI usage governance gateway with delegated agent principals*
*Researched: 2026-10-22*
