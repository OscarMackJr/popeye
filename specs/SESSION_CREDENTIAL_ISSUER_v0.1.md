# Popeye Session Credential Issuer Preparation v0.1

Version: 0.1  
Status: **Pre-review preparation only — no issuance endpoint or live infrastructure is authorized by this document.**  
Audience: popeye maintainers and the joint nono/popeye/program review.  
Primary post-read action: choose whether the gateway key surface or a thin wrapper will own contract validation, then authorize an implementation plan.

## Contract And Scope

The canonical contract is `fiskroad/contracts/NONO_POPEYE_SESSION_CREDENTIAL_CONTRACT_v0.1.md`. It remains the sole normative source; this document neither copies nor changes its rules.

This preparation covers configuration shape, fixture validation, and the review material needed to map the contract onto Popeye. It does not issue a key, deploy an endpoint, alter Terraform, choose an issuer identity, or set an issuer TTL maximum.

### Prerequisite Status

The contract depends on `POPEYE_v0.4` section 2. That file is not present at `specs/POPEYE_v0.4.md` in this checkout. Agent-principal semantics beyond the canonical contract must therefore be checked against the missing prerequisite before implementation or approval.

### Conflicts Requiring Joint Review

- Existing Popeye endpoint-policy material describes a **per-user** virtual key injected by nono. The canonical contract describes a **per-session agent** credential. The contract wins, but this is a material migration and attribution-review issue; no existing per-user provisioning path is changed by this preparation.

## PROPOSAL FOR JOINT REVIEW — NOT DECIDED: D-2 Endpoint Mapping

**Popeye's selected position for joint review: Option A.** D-2 remains undecided until the cross-repository review ratifies it. Both options put the contract identity fields into LiteLLM virtual-key metadata: `principal_type`, `agent_id`, `on_behalf_of`, `purpose`, and `tenant_id`. The request's session data and requested lifetime are issuance inputs; the gateway key material and expiry are outputs. Neither option settles D-1.

### Option A — Use LiteLLM Key Generation Directly

Nono (once D-1 is decided) calls the gateway's LiteLLM key-generation surface. A Popeye-side integration at that surface prepares the metadata and creates the virtual key.

- **Where section 2.2 validation lives:** in the gateway key-generation integration/configuration boundary before key creation. It must resolve `on_behalf_of`, consult the vendored purpose vocabulary, perform tenant and TTL handling, and authorize the caller.
- **Distinct failures:** the integration must return a separate, stable error for principal shape, onward delegation, purpose, tenant, malformed TTL, and caller authorization. A requested integer above the configured maximum is a successful issuance with a clamped expiry, not an error.
- **Tradeoffs:** fewest network hops and no new service boundary; the contract behavior is coupled tightly to LiteLLM's extension/error capabilities. If that surface cannot supply all identity lookups and distinct responses, this option is not viable without custom gateway behavior.

### Option B — Thin Popeye Issuance Wrapper Ahead of LiteLLM

**Not selected by Popeye.** Retained to make the tradeoff considered by joint review explicit.

A small Popeye-owned issuance boundary accepts the contract request, performs all contract validation, then invokes LiteLLM key generation with the resulting metadata.

- **Where section 2.2 validation lives:** entirely in the wrapper before LiteLLM is called. LiteLLM remains the key generator and ledger metadata carrier, rather than the contract validator.
- **Distinct failures:** the wrapper maps each rejected validation branch to a stable contract-facing error; it also makes the successful clamp visible through the returned expiry. Its error taxonomy is independent of LiteLLM's internal error shapes.
- **Tradeoffs:** clearest audit and test boundary, predictable failures, and less vendor coupling; adds a service/deployment/operational surface that this repository has deliberately not authorized yet. It must not be scaffolded until D-2 is accepted.

## Proposed Metadata And Key-Reference Shape

The following is a configuration shape to review, not a request to alter the live gateway:

| Contract concern | Candidate LiteLLM virtual-key field | Review note |
| --- | --- | --- |
| Agent attribution | `metadata.principal_type`, `metadata.agent_id`, `metadata.on_behalf_of` | Required for compatible ledger attribution; validate against the missing prerequisite before implementation. |
| Purpose and tenant attribution | `metadata.purpose`, `metadata.tenant_id` | Purpose comes from the vendored vocabulary; tenant remains its canonical identifier form. |
| Session correlation | issuance record/session field carrying `session_id` | Confirm the selected key-generation surface preserves it into the necessary reconciliation path. |
| Lifetime | key-generation duration/expiry input derived from `requested_ttl_seconds` | Maximum remains issuer configuration and is not proposed here. |

## `key_ref` (REQ-CRED-03)

The bearer credential returned by LiteLLM key generation is not a usable non-secret reference. Popeye should instead surface the key's server-assigned virtual-key identifier as `key_ref` when that identifier is available from the generation response. If the selected LiteLLM response does not expose a stable server identifier, the issuer must derive `key_ref` from a one-way, keyed reference of that identifier; the bearer value is never input to the derivation or output.

The issuance audit record, gateway logs, and ledger correlation data carry `key_ref` only. The bearer key may transit only in the successful issuance response and its designated injection path. It must not be placed in logs, error bodies, receipt fixtures, ledger rows, configuration, or state records used for reconciliation.

Before implementation, the joint review must confirm that the selected LiteLLM identifier is stable for the virtual key's lifetime and that its metadata reaches ledger rows without requiring the bearer secret.

## Validation Artifacts And Review Boundary

`contracts/schemas/session-credential-issuance-request-v0.1.schema.json` is Popeye's executable structural copy of the contract request schema. The accompanying fixtures and CI exercise request-shape failures under REQ-CRED-01.

Three contract checks cannot be decided from the request JSON alone: resolving whether `on_behalf_of` is an agent, applying an issuer-specific TTL clamp, and authorizing the caller under D-1. The fixtures retain those cases as issuer-runtime vectors. They become failing implementation tests only after D-1 and D-2 select the identity and validation surfaces.

## Open Decisions Left Untouched

- D-1 issuer identity.
- D-2 endpoint mapping (Popeye's Option A position; joint decision still pending).
- D-3 revocation.
- D-4 renewal policy.
- D-5 receipt schema residency.
