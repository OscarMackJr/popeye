# Requirements: Popeye — MVP Closure + Agent Principals

**Defined:** 2026-10-22
**Core Value:** Every governed model call is attributed. Each completion lands one ledger row with the correct principal, and agent keys can be minted, introspected and revoked under the rules nono depends on.

Spec REQ/TC IDs (e.g. REQ-AGT-05 / TC-AGT-05) are cited in brackets. Where a spec test criterion exists, it is the acceptance test.

## v1 Requirements

### Network Verification (NET)

The design is peering: approved callers sit in the peered `EUS-POPEYE-VNET-01` (East US, 10.10.0.0/16) and reach the Stage 1/2 eastus2 VNet over VNet peering. This replaces the earlier proposal for a VM and Bastion inside the Stage 1/2 VNet (decided 2026-10-22).

- [x] **NET-01**: The peering `vnet-popeye-stage1-stage2-eastus2` ↔ `EUS-POPEYE-VNET-01` is Connected/FullyInSync both ways and allows VNet access. Its ownership is recorded: either imported into or referenced by Popeye Terraform, or documented as networking-owned, so `terraform plan` stays clean.
- [x] **NET-02**: The `privatelink.postgres.database.azure.com` zone is linked to both VNets, and Postgres public network access stays Disabled.
- [ ] **NET-03**: A private DNS zone for the Container Apps environment default domain (`*.ashyglacier-edb44cd7.eastus2.azurecontainerapps.io` and apex → 10.60.0.108) exists and is linked to both VNets, so the gateway's internal FQDN resolves from the caller VNet.
- [x] **NET-04**: An operator on `EUS-VM-POPEYE`, connected through `EUS-POPEY-BASTION`, gets:
  - an RFC1918 address when resolving the Postgres FQDN, and `TcpTestSucceeded: True` on 5432;
  - the gateway's internal FQDN resolving to 10.60.0.108, with 443 reachable.

  Redacted evidence is recorded.
- [x] **NET-05**: The caller VM's control-plane posture is verified, via `Test-PopeyeAzureVerificationVm.ps1` adapted for the peered caller VNet:
  - no public IP on the VM;
  - Bastion subnet /26 or larger;
  - the NSG allows inbound 3389 only from `AzureBastionSubnet`, so the internet-sourced `Allow_Iliya_Promenet` rule is removed or scoped;
  - Entra sign-in enabled.

  Evidence is recorded.
- [x] **NET-06**: VM login on `EUS-VM-POPEYE` is limited to the two approved operators with Virtual Machine User Login. Administrator Login is used only with written approval, and Roger's access is granted.
- [ ] **NET-07**: Temporary verification access is reviewed on an agreed date and removed or renewed with a record: login roles, temporary NSG rules, and the VM if it is dedicated to Popeye.

### Gateway Upgrade & Hardening (GW)

- [ ] **GW-01**: The gateway runs a patched LiteLLM 1.106.x pinned by tag and digest. Versions 1.91.0–1.100.3 are excluded, and `terraform.tfvars.example` is corrected.
- [ ] **GW-02**: CI fails if the pinned LiteLLM version falls in a known GHSA-affected range.
- [ ] **GW-03**: User and agent keys can't reach LiteLLM management routes (`/key/*`, `/user/*`, `/utils/*`). The admin UI is disabled. Negative tests prove 401/403.
- [ ] **GW-04**: The container starts LiteLLM via `exec`, so SIGTERM flushes batched spend. Readiness uses `/health/readiness`, and the termination grace period is at least the batch interval + 10 s.
- [ ] **GW-05**: The gateway config is hardened:
  - `user_api_key_cache_ttl` ≤ 30 s;
  - `allow_client_side_credentials: false`;
  - `LITELLM_LOG=ERROR`;
  - no response caching.
- [ ] **GW-06**: Redis is verified to back budget/spend counters across replicas, and Redis public network access is disabled.

### MVP Smoke Proof & Ledger Hand-off (MVP)

- [ ] **MVP-01**: A synthetic completion through `twg-foundry`, sent from an approved in-VNet caller, lands exactly one attributed ledger row. Redacted evidence (timestamp, `request_id`) is recorded.
- [ ] **MVP-02**: The DNS ownership decision for `gateway-azure.ai.twg.internal` is recorded. The record resolves to the gateway from an approved caller and survives a redeploy.
- [ ] **MVP-03**: hometown can read attribution through a versioned `popeye_ledger_v1` view. `ekg_cube_reader` has SELECT on the view only, and the grant is re-validated after migrations.
- [ ] **MVP-04**: The `request_id` + attribution contract is documented and handed to hometown.

### Contracts, Decisions & Registries (CON)

- [ ] **CON-01**: The decisions are recorded in a spec/ADR:
  - shared user-entity budget + per-agent-key cap (G2);
  - `on_behalf_of` = Entra object ID (G11);
  - `direct_gateway` required with no default;
  - user-key revocation cascades (G3).
- [ ] **CON-02**: New JSON schemas exist for the exchange request/response, introspection response and key metadata. The v0.1 session-credential schema and `SESSION_CREDENTIAL_ISSUER_v0.1` are marked superseded (G8). CI validates the fixtures.
- [ ] **CON-03**: A stable error-code catalogue covers exchange, revocation, introspection and request-time refusals, and nono/Liam can branch on it (G15).
- [ ] **CON-04**: An agent registry (`agent_id`, `owner`, `allowed_purposes`) plus registered introspection callers and relays live beside the model-approval registry. CI checks them against the vendored vocabulary [O3].
- [ ] **CON-05**: Registry class names match the program vocabulary exactly, and approving `regulated-identifier` fails validation and CI [REQ-DCE-05, REQ-DCE-06].
- [ ] **CON-06**: The issuance and introspection event schema and sink are defined, with events kept content-free (G6).
- [ ] **CON-07**: A policy bundle is rendered by Terraform from the registries and vocabulary and consumed by both the gateway hook and the issuer, with its hash exposed on the health endpoints.

### Request-Time Enforcement (ENF)

- [ ] **ENF-01**: The gateway runs a derived image (pinned LiteLLM + Popeye pre-call hook) from a Popeye container registry. The image pipeline is recorded in ADR-003.
- [ ] **ENF-02**: Ledger principal fields come only from authenticated key metadata and the validated relay identity:
  - `principal_type`, `agent_id`, `on_behalf_of`, `key_id`, `purpose`, tenant and `relayed_by`.
  - Request-supplied values are overwritten.
  - A forged body/header metadata test shows the true principal (G1).
- [ ] **ENF-03**: Ledger rows carry the principal type, plus both identifiers for agents [REQ-AGT-03].
- [ ] **ENF-04**: A key with an `analytics` purpose requesting a regulated-approved model is refused with a policy error [REQ-PUR-07].
- [ ] **ENF-05**: A client-supplied `run_id` is validated, size-limited and recorded. Three requests sharing a `run_id` produce three rows with that value [REQ-RUN-01].
- [ ] **ENF-06**: Contract tests run against the real pinned LiteLLM + Postgres containers and catch behavior drift on every tag bump.

### Fleet Key Provisioning (FLT)

- [ ] **FLT-01**: `provision-desktop-keys.ps1` mints user keys for the transitive members of an Entra group:
  - `principal_type=user`;
  - `user_id`/`on_behalf_of` = Entra object ID;
  - a UUID `tenant_id`;
  - the shared user-entity budget;
  - LLM-only routes.
- [ ] **FLT-02**: Key issuance rejects a non-UUID `tenant_id` with a format error naming the rule [REQ-DCE-07].
- [ ] **FLT-03**: Leavers are blocked:
  - removed members and disabled accounts count as leavers;
  - their agent keys are revoked in cascade;
  - a safety valve aborts on empty or oversized leaver sets;
  - runs are dry-run by default.
- [ ] **FLT-04**: Existing user keys are back-filled with `principal_type`, tenant and budget metadata (G9).
- [ ] **FLT-05**: Graph app roles for the automation identity are granted least-privilege through Terraform. Pester tests cover the empty, paged, nested and disabled cases.
- [ ] **FLT-06**: `intune-baseurl-profile.ps1` pushes the gateway base URL to managed desktops through a pilot ring.

### Agent Key Issuer (ISS)

- [ ] **ISS-01**: The issuer runs as an internal-only Python Container App (own UAMI, at least 2 replicas, pinned image) with a separate `popeye_issuer` database and a dedicated admin credential. The admin credential never leaves Popeye's side.
- [ ] **ISS-02**: The issuer is reachable on the gateway FQDN under `/popeye/*`, and LiteLLM admin paths are unreachable on that FQDN.
- [ ] **ISS-03**: Every key carries a valid principal type, and agent keys carry `agent_id` and `on_behalf_of` [REQ-AGT-01].
- [ ] **ISS-04**: Issuing an agent key whose `on_behalf_of` is itself an agent fails, so agents can't delegate onward [REQ-AGT-02].
- [ ] **ISS-05**: An expired agent key is refused with a distinct error [REQ-AGT-04].
- [ ] **ISS-06**: The exchange issues agent keys only to `user` callers [REQ-AGT-05].
- [ ] **ISS-07**: `on_behalf_of` is taken from the caller and a body value is ignored [REQ-AGT-06].
- [ ] **ISS-08**: An unknown `agent_id` or an unlisted `purpose` is refused with distinct errors. Purpose validates against the program list [REQ-AGT-07, REQ-PUR-06]. If user keys carry no purpose list, the intersection reduces to vocabulary validation, and that limitation is stated.
- [ ] **ISS-09**: TTL is capped at `min(requested, 8h, parent expiry)` and is never lengthened. A request for 48 h yields an expiry of 8 h or less, and a blocked parent is refused [REQ-AGT-08, G4].
- [ ] **ISS-10**: Agent keys inherit the caller's class ceiling, tenant and shared budget and can't exceed them [REQ-AGT-09, G2].
- [ ] **ISS-11**: Revocation blocks the key (never deletes it), is idempotent, and is limited to the minting user key [REQ-AGT-10].
- [ ] **ISS-12**: Ledger rows on agent keys carry a non-null `key_id` and `principal_type=agent` [REQ-AGT-11].
- [ ] **ISS-13**: Every issued `key_id` is a lowercase canonical UUID, never reused. 1,000 keys match the regex with no duplicates [REQ-AGT-20].
- [ ] **ISS-14**: Content-free issuance events are written for mint and revoke.
- [ ] **ISS-15**: A sentinel key value never appears in any response, log or storage sink:
  - responses;
  - Log Analytics and App Insights;
  - SpendLogs and ErrorLogs;
  - Redis;
  - the event tables.

### Introspection & Relays (INT)

- [ ] **INT-01**: Introspection returns identity properties for an active agent key and never a secret [REQ-AGT-12].
- [ ] **INT-02**: Expired, revoked, unknown and user keys each return a bare `active:false` [REQ-AGT-13].
- [ ] **INT-03**: Only registered service callers may introspect. Unregistered application keys, user keys and agent keys are refused [REQ-AGT-14].
- [ ] **INT-04**: Introspection is read-only, leaving `expires_at` and status unchanged [REQ-AGT-15].
- [ ] **INT-05**: Caching hometown/olive stubs refuse a revoked key within 60 s. The gateway-side bound is measured on at least 2 replicas under load [REQ-AGT-16].
- [ ] **INT-06**: A relayed call yields a ledger row with `principal_type=agent`, the key's `on_behalf_of`, and `relayed_by` [REQ-AGT-17].
- [ ] **INT-07**: A key minted with `direct_gateway=false` refuses an unrelayed call, and also refuses a call relayed by an unregistered identity [REQ-AGT-18].
- [ ] **INT-08**: Only registered relays are accepted, and the relay header is stripped and never logged [REQ-AGT-19, G7].
- [ ] **INT-09**: Application keys for hometown and olive are issued through a governed path (G16).
- [ ] **INT-10**: Revoking a user key cascades to every agent key it minted.
- [ ] **INT-11**: One `key_id` is byte-identical across exchange, revocation, ledger, issuance event and introspection, including after revocation and expiry [REQ-AGT-21]. This is the nono integration gate.

### Stage 1 Baselines & SLOs (SLO)

- [ ] **SLO-01**: The Stage 1 protocol measures the following from an in-VNet runner using paired, interleaved samples:
  - latency overhead;
  - budget counter lag;
  - ledger freshness;
  - ledger interruption (N sent = N rows across a revision swap);
  - budget (422) vs provider-throttle payloads;
  - cross-replica budget overshoot.
- [ ] **SLO-02**: Issuer exchange and introspection latency/availability are measured (G12).
- [ ] **SLO-03**: `specs/STAGE1_BASELINES.md` records results with the LiteLLM version, digest and config hash, and states that fallback (TC-REL-02, TC-COST-04) is deferred to Stage 3 (Option B).
- [ ] **SLO-04**: MVP SLOs are committed in a roadmap v0.3 revision, and placeholder alerts are replaced with burn-rate/notify thresholds.

### Alerting & Detection (ALR)

- [ ] **ALR-01**: A synthetic run exceeding the cost threshold fires an alert. Run totals are computed out-of-band, never in the request path [REQ-RUN-02, G10].
- [ ] **ALR-02**: A monitor job reconciles LiteLLM keys against the issuer registry and alerts on orphaned or out-of-band keys.
- [ ] **ALR-03**: The `twg-gateway-only` profile blocks direct provider access and allows the gateway, shown in a live demo on a managed workstation [REQ-END-03].
- [ ] **ALR-04**: Detections are emitted in the contract schema and are content-free [REQ-END-04].
- [ ] **ALR-05**: A detection reaches Popeye alerting end-to-end [REQ-END-05].
- [ ] **ALR-06**: Alerts exist for secret-shaped strings in logs, Key Vault `SecretGet` anomalies, issuer 5xx, and mint-rate anomalies.

### DLP Evaluation (DLP)

- [ ] **DLP-01**: Gateway guardrails are evaluated on a synthetic corpus: built-in content filter, Presidio PII masking, and prompt-injection screening.
- [ ] **DLP-02**: The evaluation measures paired latency/error impact and fail-open vs fail-closed behavior, and confirms through a sink grep that no prompt content reaches logs or SpendLogs.
- [ ] **DLP-03**: A go/no-go recommendation is documented.

### Operational Readiness (OPS)

- [ ] **OPS-01**: The six MVP runbooks plus issuer-down and agent-key mass revocation are written and rehearsed, with named owners.
- [ ] **OPS-02**: Break-glass access uses a named approver group with PIM-eligible assignments, and the POC principal and standing access are removed.
- [ ] **OPS-03**: PIM-gated admin revocation by `key_id`, `agent_id` or `on_behalf_of` exists, if the REQ-AGT-10 carve-out is ratified with nono (G3).

## v2 Requirements

- **ABUSE-01**: Exchange rate limits and caps on live agent keys per user (G14)
- **GRD-01**: Guardrail production rollout beyond the go/no-go; per-purpose guardrails (G17)
- **ID-01**: Entra Agent ID / machine-identity exchange (needs nono re-ratification)
- **SEC-01**: Sender-constrained keys (mTLS/DPoP) and mTLS relays
- **INT-v2-01**: RFC 7662 field aliases on introspection
- **REG-01**: Enforcing the agent registry's `allowed_purposes` at exchange
- **PG-01**: Postgres Entra authentication for the issuer UAMI

## Out of Scope

| Feature | Reason |
|---------|--------|
| AWS second region / fallback chain | Stage 3; Option B descope recorded in the baselines |
| Public exposure of gateway or issuer | Internal-only is a hard design rule |
| Cube `ai_token_usage` model | Owned by hometown; Popeye owns only the ledger view, grants and contract |
| Tool-call metering | olive meters tool calls in its own record (v0.4 §6) |
| Per-run budgets | Short-lived per-run keys achieve the same outcome (v0.4 §6) |
| Accepting `on_behalf_of`/`tenant_id`/`principal_type` from the request body | Contradicts REQ-AGT-06; anti-feature |
| Refreshable agent keys; agent-mints-agent | Anti-features per the ratified specs |
| LiteLLM Enterprise (custom_auth, per-key guardrails) | The open-source pre-call hook covers the need |
| Prompt logging for DLP tuning | Violates the no-prompt-logging guardrail |
| Stage 4 FinOps | Follows MVP |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| NET-01 | Phase 1 | Complete |
| NET-02 | Phase 1 | Complete |
| NET-03 | Phase 1 | Pending (networking-owned zone; evidence in 01-09) |
| NET-04 | Phase 1 | Complete |
| NET-05 | Phase 1 | Complete |
| NET-06 | Phase 1 | Complete |
| NET-07 | Phase 8 | Pending |
| GW-01 | Phase 1 | Pending |
| GW-02 | Phase 1 | Pending |
| GW-03 | Phase 1 | Pending |
| GW-04 | Phase 1 | Pending |
| GW-05 | Phase 1 | Pending |
| GW-06 | Phase 1 | Pending |
| MVP-01 | Phase 1 | Pending |
| MVP-02 | Phase 4 | Pending |
| MVP-03 | Phase 3 | Pending |
| MVP-04 | Phase 3 | Pending |
| CON-01 | Phase 2 | Pending |
| CON-02 | Phase 2 | Pending |
| CON-03 | Phase 2 | Pending |
| CON-04 | Phase 2 | Pending |
| CON-05 | Phase 2 | Pending |
| CON-06 | Phase 2 | Pending |
| CON-07 | Phase 2 | Pending |
| ENF-01 | Phase 3 | Pending |
| ENF-02 | Phase 3 | Pending |
| ENF-03 | Phase 3 | Pending |
| ENF-04 | Phase 3 | Pending |
| ENF-05 | Phase 3 | Pending |
| ENF-06 | Phase 3 | Pending |
| FLT-01 | Phase 4 | Pending |
| FLT-02 | Phase 4 | Pending |
| FLT-03 | Phase 4 | Pending |
| FLT-04 | Phase 4 | Pending |
| FLT-05 | Phase 4 | Pending |
| FLT-06 | Phase 4 | Pending |
| ISS-01 | Phase 5 | Pending |
| ISS-02 | Phase 5 | Pending |
| ISS-03 | Phase 5 | Pending |
| ISS-04 | Phase 5 | Pending |
| ISS-05 | Phase 5 | Pending |
| ISS-06 | Phase 5 | Pending |
| ISS-07 | Phase 5 | Pending |
| ISS-08 | Phase 5 | Pending |
| ISS-09 | Phase 5 | Pending |
| ISS-10 | Phase 5 | Pending |
| ISS-11 | Phase 5 | Pending |
| ISS-12 | Phase 5 | Pending |
| ISS-13 | Phase 5 | Pending |
| ISS-14 | Phase 5 | Pending |
| ISS-15 | Phase 5 | Pending |
| INT-01 | Phase 6 | Pending |
| INT-02 | Phase 6 | Pending |
| INT-03 | Phase 6 | Pending |
| INT-04 | Phase 6 | Pending |
| INT-05 | Phase 6 | Pending |
| INT-06 | Phase 6 | Pending |
| INT-07 | Phase 6 | Pending |
| INT-08 | Phase 6 | Pending |
| INT-09 | Phase 6 | Pending |
| INT-10 | Phase 6 | Pending |
| INT-11 | Phase 6 | Pending |
| SLO-01 | Phase 7 | Pending |
| SLO-02 | Phase 7 | Pending |
| SLO-03 | Phase 7 | Pending |
| SLO-04 | Phase 7 | Pending |
| ALR-01 | Phase 7 | Pending |
| ALR-02 | Phase 7 | Pending |
| ALR-03 | Phase 7 | Pending |
| ALR-04 | Phase 7 | Pending |
| ALR-05 | Phase 7 | Pending |
| ALR-06 | Phase 7 | Pending |
| DLP-01 | Phase 8 | Pending |
| DLP-02 | Phase 8 | Pending |
| DLP-03 | Phase 8 | Pending |
| OPS-01 | Phase 8 | Pending |
| OPS-02 | Phase 8 | Pending |
| OPS-03 | Phase 8 | Pending |

**Coverage:**
- v1 requirements: 78 total
- Mapped to phases: 78
- Unmapped: 0 ✓

---
*Requirements defined: 2026-10-22*
*Last updated: 2026-10-22 after roadmap creation (traceability filled)*
