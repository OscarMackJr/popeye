# Roadmap: Popeye — MVP Closure + Agent Principals

## Overview

This milestone closes the Stage 1/Stage 2 MVP and builds the ratified v0.4.x agent-principal layer that nono and Liam depend on. The order follows security before features, and decisions before code. First the gateway is proven from inside the Stage 1/2 VNet, patched and locked down, with one attributed smoke row as evidence. Then the one-way-door contracts are fixed. After that the request-time hook makes attribution unspoofable, fleet user keys and the stable FQDN give the exchange something to derive from, and the issuer and introspection deliver the nono integration gate (TC-AGT-21). Measurement, out-of-band alerting, the DLP go/no-go and operational readiness close the milestone, outside the request path.

**nono critical path:** 1 -> 2 -> 3 (+4) -> 5 -> 6 (TC-AGT-21 gate)

**Parallelizable:**
- Phase 2 (contracts and decisions; documents, schemas and CI only) can run alongside Phase 1.
- Phase 4 (stable FQDN and fleet provisioning) can run alongside Phase 3 (gateway hook). Both must finish before Phase 5.
- The Stage 1 gateway measurements in Phase 7 (SLO-01) and the DLP evaluation in Phase 8 (DLP-01..03) only need Phase 1/3 and can start early. The phases close in order because they need issuer SLOs and rehearsed runbooks.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

- [ ] **Phase 1: Network Proof, Gateway Hardening & Smoke Row** - Prove the private route from the peered caller VNet, upgrade and lock down LiteLLM, and land one attributed smoke row
- [ ] **Phase 2: Contracts, Decisions & Registries** - Record the one-way-door decisions, new schemas, error catalogue, agent registry and policy bundle
- [ ] **Phase 3: Gateway Hook, Image & Ledger Contract** - Derived gateway image whose pre-call hook stamps unspoofable attribution; versioned ledger view handed to hometown
- [ ] **Phase 4: Stable FQDN & Fleet Key Provisioning** - Managed `gateway-azure.ai.twg.internal`, Entra-group user keys with safe leaver handling, and an Intune base-URL pilot
- [ ] **Phase 5: Agent Key Issuer Core** - Exchange and revocation on the gateway FQDN, with TTL clamp, inherited limits, UUID `key_id` and content-free events
- [ ] **Phase 6: Introspection, Relays & nono Gate** - Introspection, relay enforcement, revocation propagation and cascade, and TC-AGT-21 byte-identical `key_id`
- [ ] **Phase 7: Stage 1 Baselines, SLOs & Out-of-Band Alerting** - Measured baselines and committed SLOs, plus run-cost, reconciliation, endpoint-detection and security alerts
- [ ] **Phase 8: DLP Go/No-Go & Operational Readiness** - Guardrail evaluation, rehearsed runbooks, PIM break-glass, and verification VM decommission

## Phase Details

### Phase 1: Network Proof, Gateway Hardening & Smoke Row
**Goal**: An approved caller in the peered `EUS-POPEYE-VNET-01` can reach the private Postgres ledger and the gateway's internal FQDN over VNet peering. The gateway runs a patched, locked-down LiteLLM, and one synthetic completion through `twg-foundry` lands exactly one attributed ledger row.
**Depends on**: Nothing (first phase)
**Requirements**: NET-01, NET-02, NET-03, NET-04, NET-05, NET-06, GW-01, GW-02, GW-03, GW-04, GW-05, GW-06, MVP-01
**Success Criteria** (what must be TRUE):
  1. Peering is Connected both ways and its ownership is recorded. The Postgres private DNS zone and a new Container Apps environment private DNS zone are linked to both VNets. Postgres public access stays Disabled.
  2. From `EUS-VM-POPEYE` through `EUS-POPEY-BASTION`:
     - Postgres resolves to an RFC1918 address and 5432 connects.
     - The gateway's internal FQDN resolves to 10.60.0.108 and 443 connects.

     Evidence is recorded.
  3. The caller VM has no public IP, and RDP is allowed only from `AzureBastionSubnet`. Only the two approved operators hold User Login; Administrator Login only with written approval.
  4. The gateway serves traffic on patched LiteLLM 1.106.x, pinned by tag and digest. CI fails a PR that pins a GHSA-affected version.
  5. A user key calling `/key/*`, `/user/*` or `/utils/*`, or the admin UI, gets 401/403. A revision swap flushes batched spend on SIGTERM. Redis backs budget counters across replicas and has public access disabled.
  6. A synthetic completion from the peered caller through `twg-foundry` produces exactly one attributed ledger row, with redacted evidence (timestamp, `request_id`) recorded.
**Plans**: 9 plans
Plans:
- [ ] 01-01-PLAN.md — GHSA advisory-range checker, CI self-test, gitignore and tfvars.example fixes (GW-02)
- [ ] 01-02-PLAN.md — Extend network verification scripts, amend VM procedure, record DNS-ownership/tooling preflight (NET-01..06)
- [ ] 01-03-PLAN.md — Ceremony scripts: reader SQL, smoke, lockdown, row assertion (MVP-01, GW-03, GW-06)
- [ ] 01-04-PLAN.md — Redis private endpoint, clustering spike, public access Disabled (GW-06)
- [ ] 01-05-PLAN.md — Conditional env DNS zone and reader-DSN secret (NET-03, MVP-01)
- [ ] 01-06-PLAN.md — Upgrade/hardening code, pin file, CI pin check (GW-01..06)
- [ ] 01-07-PLAN.md — Pin-day re-check, rollback runbook, backup, in-place upgrade apply (GW-01, GW-04, GW-05)
- [ ] 01-08-PLAN.md — Admin ceremony: smoke row, lockdown, counters, SIGTERM flush (MVP-01, GW-03, GW-04, GW-06)
- [ ] 01-09-PLAN.md — Final network evidence refresh and evidence index (NET-01..06)
**Research flag**: Needs `--research-phase`. Re-check GHSA on pin day, the 1.90 -> 1.106 breaking changes (422 budget response), Redis wiring and cluster mode, and the impact of Prisma migrations on hometown grants.

### Phase 2: Contracts, Decisions & Registries
**Goal**: The one-way-door decisions and contracts that nono, Liam, hometown and olive build on are recorded, schema-validated and enforced in CI before any issuer or hook code depends on them.
**Depends on**: Nothing (can run in parallel with Phase 1; must complete before Phases 3-5 build on it)
**Requirements**: CON-01, CON-02, CON-03, CON-04, CON-05, CON-06, CON-07
**Success Criteria** (what must be TRUE):
  1. A spec/ADR records the decisions on G2 (shared user-entity budget + per-agent-key cap), G11 (`on_behalf_of` = Entra object ID), `direct_gateway` (required, no default) and G3 (cascade revocation). A reviewer can cite each one.
  2. CI validates fixtures against the new exchange, introspection and key-metadata schemas. The v0.1 session-credential schema and `SESSION_CREDENTIAL_ISSUER_v0.1` are visibly marked superseded.
  3. nono/Liam can look up a stable error code for every exchange, revocation, introspection and request-time refusal in the published catalogue. The issuance/introspection event schema has no content fields.
  4. In CI, the agent registry (agents, introspection callers, relays) is checked against the vendored vocabulary, mismatched class names fail, and approving `regulated-identifier` fails.
  5. Terraform renders a policy bundle from the registries and vocabulary, and its hash can be compared across consumers.
**Plans**: TBD
**Research flag**: Standard patterns. G11 and the `direct_gateway` default need program (fiskroad) and nono confirmation.

### Phase 3: Gateway Hook, Image & Ledger Contract
**Goal**: Every ledger row's principal fields come from authenticated key metadata, never from the request. hometown reads attribution through a versioned, least-privilege view.
**Depends on**: Phase 1 (patched gateway), Phase 2 (metadata contract, policy bundle)
**Requirements**: ENF-01, ENF-02, ENF-03, ENF-04, ENF-05, ENF-06, MVP-03, MVP-04
**Success Criteria** (what must be TRUE):
  1. The gateway runs a derived image (pinned LiteLLM + Popeye hook) pulled from the Popeye registry, with the pipeline recorded in ADR-003. The policy bundle hash appears on its health endpoint.
  2. A request carrying forged `principal_type`, `on_behalf_of`, `key_id`, tenant or `relayed_by` in its body or headers produces a ledger row showing the true principal. The row carries the principal type, plus both identifiers for agent principals.
  3. An `analytics`-purpose key requesting a regulated-approved model is refused with the catalogued policy error. Three requests sharing a valid `run_id` produce three rows with that value, and an oversized `run_id` is rejected.
  4. Contract tests against real pinned LiteLLM + Postgres containers pass, and they fail when a tag bump changes the metadata merge behavior.
  5. `ekg_cube_reader` can SELECT `popeye_ledger_v1` and nothing else, the grant survives a migration, and hometown has the documented `request_id` + attribution contract.
**Plans**: TBD
**Research flag**: Needs `--research-phase` (highest risk). Spike the hook internals at the target tag (header access, relay-key lookup, `spend_logs_metadata` merge) and the ACR SKU. The results set the metadata contract Phase 5 writes.

### Phase 4: Stable FQDN & Fleet Key Provisioning
**Goal**: Managed desktops reach the gateway on a stable, Popeye-managed name, and every in-scope Entra user holds a correctly attributed user key. Leavers are blocked safely.
**Depends on**: Phase 1 (hardened gateway), Phase 2 (G2 budget and G11 `on_behalf_of` decisions). Can run in parallel with Phase 3.
**Requirements**: MVP-02, FLT-01, FLT-02, FLT-03, FLT-04, FLT-05, FLT-06
**Success Criteria** (what must be TRUE):
  1. The DNS ownership decision is recorded. `gateway-azure.ai.twg.internal` resolves to the gateway from an approved caller and still resolves after a redeploy.
  2. A dry run, then a live run, of `provision-desktop-keys.ps1` mints user keys for transitive group members, with `principal_type=user`, Entra object ID, UUID tenant, the shared user-entity budget and LLM-only routes. Existing keys are back-filled, and a non-UUID `tenant_id` is rejected with a format error naming the rule.
  3. Removing a member or disabling an account blocks that user's key and cascades to their agent keys. An empty or oversized leaver set aborts the run.
  4. Graph app roles for the automation identity are granted least-privilege through Terraform. Pester covers the empty, paged, nested and disabled cases.
  5. Pilot-ring desktops receive the gateway base URL through the Intune profile.
**Plans**: TBD
**Research flag**: Needs `--research-phase` for the FQDN work (`httpRouteConfigs` on an internal-LB environment with a private custom domain and internal-CA certificate, plus the sidecar fallback). Light check on the Intune beta `deviceManagementScripts` API.

### Phase 5: Agent Key Issuer Core
**Goal**: A user caller can exchange their user key for a short-lived, attributed agent key on the gateway FQDN, and revoke it, under every rule nono depends on. The admin credential never leaves Popeye's side.
**Depends on**: Phase 3 (hook metadata contract), Phase 4 (user keys to derive from, stable FQDN)
**Requirements**: ISS-01, ISS-02, ISS-03, ISS-04, ISS-05, ISS-06, ISS-07, ISS-08, ISS-09, ISS-10, ISS-11, ISS-12, ISS-13, ISS-14, ISS-15
**Success Criteria** (what must be TRUE):
  1. The issuer is reachable at `/popeye/*` on the gateway FQDN as an internal-only, 2+ replica Container App with its own UAMI and `popeye_issuer` database. LiteLLM admin paths are unreachable on that FQDN.
  2. A user caller mints an agent key whose `on_behalf_of` comes from the caller, whatever the body says. Each of these is refused with a distinct catalogued error: agent callers, agent-as-`on_behalf_of`, unknown `agent_id`, unlisted purpose and a blocked parent. The purpose-intersection limitation is stated.
  3. A request for a 48h TTL yields an expiry of 8h or less, and never beyond the parent's. The agent key can't exceed the caller's class ceiling, tenant or shared budget. An expired agent key is refused with a distinct error.
  4. Revocation blocks the key (never deletes it), is idempotent and is limited to the minting user key. Calls on agent keys land ledger rows with `principal_type=agent` and a non-null `key_id`. 1,000 minted `key_id`s are lowercase canonical UUIDs with no duplicates.
  5. Content-free mint and revoke events are written. A sentinel key value never appears in any response, Log Analytics, App Insights, SpendLogs, ErrorLogs, Redis or the event tables.
**Plans**: TBD
**Research flag**: Needs `--research-phase`. Spike the minimum open-source admin role for the dedicated credential (fallback: the master key through a KV reference, recorded as debt).

### Phase 6: Introspection, Relays & nono Gate
**Goal**: Registered services can introspect agent keys safely. Relayed calls keep the original attribution, revocation propagates within bound, and one `key_id` is byte-identical across all five surfaces, which unblocks nono's `AgentSessionRecord`.
**Depends on**: Phase 5
**Requirements**: INT-01, INT-02, INT-03, INT-04, INT-05, INT-06, INT-07, INT-08, INT-09, INT-10, INT-11
**Success Criteria** (what must be TRUE):
  1. hometown and olive hold application keys issued through the governed path. Introspecting an active agent key as a registered caller returns identity properties and no secret. Expired, revoked, unknown and user keys each return a bare `active:false`, and introspection leaves status and `expires_at` unchanged.
  2. Unregistered application keys, user keys and agent keys are refused when they try to introspect.
  3. A call relayed by a registered relay lands a row with `principal_type=agent`, the key's `on_behalf_of` and `relayed_by`. A `direct_gateway=false` key refuses unrelayed calls and calls from unregistered relays. The relay header is stripped and never logged.
  4. On at least 2 replicas under load, caching hometown/olive stubs refuse a revoked key within 60s. Revoking a user key cascades to every agent key it minted.
  5. TC-AGT-21 passes. One `key_id` is byte-identical across exchange, revocation, ledger, issuance event and introspection, including after revocation and expiry.
**Plans**: TBD
**Research flag**: Needs `--research-phase`. Cross-replica revocation (TTL ≤30s + Redis `popeye:revoked` set vs. Managed Redis cluster mode). Clarify with nono, hometown and olive whether the 60s bound is gateway-side or end-to-end.

### Phase 7: Stage 1 Baselines, SLOs & Out-of-Band Alerting
**Goal**: Gateway and issuer behavior is measured, recorded and covered by committed SLOs. Cost, reconciliation, endpoint-detection and security anomalies reach Popeye alerting without anything sitting in the request path.
**Depends on**: Phase 6 (issuer SLOs, key reconciliation and mint-rate alerts need the full issuer). SLO-01 can start once Phase 3 is done.
**Requirements**: SLO-01, SLO-02, SLO-03, SLO-04, ALR-01, ALR-02, ALR-03, ALR-04, ALR-05, ALR-06
**Success Criteria** (what must be TRUE):
  1. The in-VNet runner produces paired, interleaved measurements. They cover latency overhead, budget counter lag, ledger freshness, ledger interruption (N sent = N rows across a revision swap), budget-422 vs. throttle payloads, cross-replica budget overshoot, and issuer exchange/introspection latency and availability.
  2. `specs/STAGE1_BASELINES.md` records the results with the LiteLLM version, digest and config hash, and states the Option B deferral of TC-REL-02/TC-COST-04 to Stage 3. A roadmap v0.3 revision commits the MVP SLOs, and placeholder alerts are replaced with burn-rate/notify thresholds.
  3. A synthetic run that exceeds the cost threshold fires an alert computed out-of-band. An orphaned or out-of-band LiteLLM key raises a reconciliation alert.
  4. In a live demo on a managed workstation, the `twg-gateway-only` profile blocks direct provider access and allows the gateway. The resulting content-free detection, in the contract schema, reaches Popeye alerting.
  5. Alerts fire for secret-shaped strings in logs, Key Vault `SecretGet` anomalies, issuer 5xx and mint-rate anomalies.
**Plans**: TBD
**Research flag**: Standard patterns.

### Phase 8: DLP Go/No-Go & Operational Readiness
**Goal**: Popeye has a documented guardrail decision, rehearsed runbooks with named owners and least-privilege break-glass, and the temporary verification footprint is gone.
**Depends on**: Phase 7 (runbooks reference SLOs and alerts; DLP latency uses the measurement method). The DLP evaluation can start once Phase 3 is done.
**Requirements**: DLP-01, DLP-02, DLP-03, OPS-01, OPS-02, OPS-03, NET-07
**Success Criteria** (what must be TRUE):
  1. The content filter, Presidio PII masking and prompt-injection screening are each evaluated on a synthetic corpus, with paired latency/error deltas and fail-open/fail-closed behavior recorded. A sink grep shows no prompt content in logs or SpendLogs.
  2. A go/no-go guardrail recommendation is documented.
  3. The six MVP runbooks plus issuer-down and agent-key mass revocation have been rehearsed, and each names an owner.
  4. Break-glass access goes through a named approver group with PIM-eligible assignments, and the POC principal and standing access are removed. If the REQ-AGT-10 carve-out is ratified with nono, a PIM-gated admin can revoke by `key_id`, `agent_id` or `on_behalf_of`.
  5. On the agreed date, the verification VM, NIC, login roles and temporary NSG rules are removed, and the decommission is recorded.
**Plans**: TBD
**Research flag**: Needs `--research-phase` for DLP (`guardrail_information` contents, Presidio latency). For ops, check Entra ID P2 licensing for PIM.

## Progress

**Execution Order:**
Phases run in numeric order: 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 8. Phases 1 and 2 can overlap, and so can Phases 3 and 4.

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Network Proof, Gateway Hardening & Smoke Row | 0/9 | Not started | - |
| 2. Contracts, Decisions & Registries | 0/TBD | Not started | - |
| 3. Gateway Hook, Image & Ledger Contract | 0/TBD | Not started | - |
| 4. Stable FQDN & Fleet Key Provisioning | 0/TBD | Not started | - |
| 5. Agent Key Issuer Core | 0/TBD | Not started | - |
| 6. Introspection, Relays & nono Gate | 0/TBD | Not started | - |
| 7. Stage 1 Baselines, SLOs & Out-of-Band Alerting | 0/TBD | Not started | - |
| 8. DLP Go/No-Go & Operational Readiness | 0/TBD | Not started | - |
