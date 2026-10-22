# Popeye — AI Usage Governance Control Plane

## What This Is

Popeye is TWG's AI usage governance control plane. It's an internal-only LiteLLM gateway on Azure Container Apps that enforces model approval, data-class and budget policy, and writes an attributed cost ledger. Endpoint and credential automation and the operational tooling around it are part of Popeye too. This milestone closes the Stage 1/Stage 2 MVP and builds the ratified v0.4.x agent-principal work that nono and Liam integration depend on: agent key exchange, introspection, relays, purpose labels and run metering.

## Core Value

Every governed model call is attributed. Each completion through the gateway lands one ledger row with the correct principal (user or agent, `on_behalf_of`, `key_id`, purpose, `run_id`, tenant). Agent keys can be minted, introspected and revoked under the rules nono depends on.

## Requirements

### Validated

<!-- Inferred from existing code (.planning/codebase/) and STATE.md. -->

- ✓ Azure eastus2 stack applied via Terraform with remote state in Azure Storage — existing
- ✓ LiteLLM gateway on Container Apps: pinned image (rejects `latest`), ≥2 replicas, UAMI, Key Vault secret references — existing
- ✓ Zone-redundant Postgres ledger (`prevent_destroy`) and Azure Managed Redis — existing
- ✓ ADR-002 config delivery: Terraform-rendered LiteLLM YAML as a Container Apps secret; `twg-foundry` routes to the selected Foundry deployment with RBAC — existing
- ✓ Observability: Log Analytics, App Insights, Teams action group, POC page alerts (5xx, low replicas, Postgres availability) — existing
- ✓ Dormant break-glass vault (approvers-only, audited, placeholder secret with ignored drift) — existing
- ✓ Model-approval registry and allowlist derivation, including the REQ-DCE-06 unapprovable `regulated-identifier` guard — existing
- ✓ Registry/schema conformance CI against vendored `vocabulary.yaml`; session-credential issuance request schema and fixtures — existing
- ✓ Endpoint-detection schema and content-free JSONL reader — existing

### Active

**MVP closure (Stage 1/2)**
- [ ] Peered caller network (`EUS-POPEYE-VNET-01` ↔ Stage 1/2 VNet) is proven, with peering ownership recorded. The private Postgres route passed on 2026-10-22.
- [ ] A Container Apps environment private DNS zone is linked to both VNets, so the gateway FQDN resolves from callers.
- [ ] The caller VM is hardened: RDP only from Bastion; User Login for the two approved operators only.
- [ ] Temporary verification access is reviewed or removed on an agreed date.
- [ ] A smoke completion through `twg-foundry` lands one attributed row in the regional ledger, with recorded evidence
- [ ] Stable DNS (`gateway-azure.ai.twg.internal`) ownership decision recorded and the zone/record managed
- [ ] Stage 1 measurement protocol run: latency overhead, budget counter lag, ledger freshness, ledger interruption, budget vs. provider-throttle payloads
- [ ] `specs/STAGE1_BASELINES.md` written; MVP SLOs committed in a roadmap v0.3 revision; placeholder alert criteria replaced with burn-rate/notify thresholds
- [ ] Fallback chain Option B recorded: TC-REL-02 and TC-COST-04 deferred to Stage 3 in the baselines doc
- [ ] Hometown read access and the `request_id`/attribution contract handed off for the `ai_token_usage` query

**Agent keys (v0.4 / v0.4.1 / v0.4.2 / v0.4.3) — the nono/Liam dependency**
- [ ] Agent principals: principal type on every key; agents carry `agent_id` and `on_behalf_of`; onward delegation refused; short expiry with a distinct error (REQ-AGT-01..04)
- [ ] Agent key exchange endpoint on the gateway FQDN: user callers only, `on_behalf_of` taken from the caller, unknown agent/purpose refused, TTL capped at 8h, inherits the caller's class ceiling/tenant/budget, idempotent revocation scoped to the minting key, issuance events (REQ-AGT-05..11)
- [ ] Introspection: returns identity properties only, never secrets; inactive keys return bare `active:false`; registered service callers only; read-only; revocation propagates within 60s; relays recorded (`relayed_by`); `direct_gateway=false` enforced; registered relays only (REQ-AGT-12..19)
- [ ] `key_id` is a lowercase canonical UUID (v4/v7), never reused, byte-identical across exchange, revocation, ledger, issuance event and introspection (REQ-AGT-20..21)
- [ ] Agent-ID registry beside the model-approval registry, vocabulary-checked in the same CI job

**Purpose and run metering (v0.4)**
- [ ] Purpose validated against the program list at issuance; purpose/class prohibition enforced at request time (REQ-PUR-06/07)
- [ ] `run_id` recorded on ledger rows; a run exceeding the cost threshold raises an alert (REQ-RUN-01/02)

**Corrections v0.3**
- [ ] Registry class names match the program vocabulary; `regulated-identifier` unapprovable, enforced in CI (REQ-DCE-05/06)
- [ ] Key issuance rejects non-UUID `tenant_id` (REQ-DCE-07)
- [ ] Endpoint detection: the `twg-gateway-only` profile is demonstrated, detections are content-free in the contract schema, and a detection reaches Popeye alerting (REQ-END-03..05)

**Fleet automation**
- [ ] `provision-desktop-keys.ps1` implemented: Entra group → LiteLLM virtual keys with tenant UUID, joiner/leaver revocation
- [ ] `intune-baseurl-profile.ps1` implemented: pushes the gateway base URL to managed desktops

**Operational readiness**
- [ ] Gateway content guardrail/DLP evaluation (PII masking, prompt-injection screening, latency/error impact, no-prompt-logging compatibility) with a go/no-go recommendation
- [ ] The six MVP runbooks rehearsed, with operational owners named
- [ ] Break-glass access moved from the POC principal to a named approver group/PIM model

### Out of Scope

- AWS second region (`envs/aws-use1`, Stage 3) — needs a second provider; fallback is deferred under Option B
- Public exposure of the gateway or issuer — internal-only is a hard design rule
- Cube semantic model / `ai_token_usage` model — hometown owns it; Popeye owns only the ledger, grants and attribution contract
- Tool-call metering — tool calls aren't model calls; olive meters them in its own record (v0.4 §6)
- Per-run budgets — budgets stay per key; short-lived per-run keys achieve the same outcome (v0.4 §6)
- Stage 4 FinOps operationalization — follows MVP

## Context

- **Brownfield IaC/policy repo.** Terraform for Azure, PowerShell for Entra/Intune, Python for fixture validators. Until now there's been no application runtime code. The issuer service is the first one. The codebase map is in `.planning/codebase/`.
- **Spec-driven.** `specs/` is the source of truth. REQ/TC IDs are referenced in code and CI. Ratified specs: v0.4.1, v0.4.2 and v0.4.3 (2026-10-19, ratified with `NONO_v0.4.x` and `LIAM_*_v0.4` as one package). v0.4 and Corrections v0.3 are drafts. `SESSION_CREDENTIAL_ISSUER_v0.1.md` captures the D-2 options; this milestone picks Option B (thin wrapper).
- **Cross-repo seams.** nono writes `AgentSessionRecord` with a 16-byte `KeyId` and needs popeye's UUID guarantee. hometown and olive cache introspection results and act as relays. hometown reads the ledger via `ekg_cube_reader`.
- **Program open items O1–O3 resolved with the proposed defaults:**
  - 8h TTL cap.
  - Agent-ID registry beside the model registry.
  - If user keys carry no explicit purpose list, the purpose intersection reduces to vocabulary validation. That is a stated limitation.
- **Verification evidence** (2026-10-21, `artifacts/popeye-azure-verification-evidence.json`): Postgres public access is disabled and the private DNS zone is linked (PASS). Bastion and VM checks FAIL or were not run.
- **Networking review (latest email to networking, received 2026-10-22).**
  - The existing `EUS-VM-POPEYE` (Windows Server 2022, no public IP, Entra sign-in) sits in `EUS-POPEYE-VNET-01`, East US, 10.10.2.4, with its own Bastion. That is a different environment. A connection from it doesn't prove connectivity from the Stage 1/2 eastus2 VNet.
  - The Stage 1/2 resource group has no Bastion.
  - VM login on `EUS-VM-POPEYE` currently grants Administrator Login to three identities, which exceeds the two approved operators. That needs correcting or explicit approval.
  - **Resolution (same day):** networking peered the two VNets instead. A read-only run-command test from `EUS-VM-POPEYE` proved Postgres (10.60.2.5:5432) and the gateway environment (10.60.0.108:443) over the peering. The environment domain does not yet resolve, because the private DNS zone is missing.
- `STATE.md` (root) is the pre-GSD implementation log, last updated 2026-08-02. It stays as the human-facing state doc alongside `.planning/STATE.md`.

## Constraints

- **Security**: No provider API keys in config, tfvars or scripts; managed identity only. The gateway admin/master key never leaves Popeye's side, and the issuer endpoint never exposes it.
- **Security**: No prompt logging. Introspection and logs never contain key secrets (sentinel test). Evidence is redacted and synthetic.
- **Security**: Terraform state is sensitive; filled tfvars and `config/litellm.*.yaml` are never committed.
- **Guardrail**: `litellm_image_tag` never `latest`; `min_replicas` ≥ 2; never rotate the salt key casually; don't rename applied resources (`popeye-` prefix).
- **Architecture**: Observation/reporting never sits in the request path. The gateway stays semantics-blind: labels come from outside, prompts aren't inspected, except where the DLP evaluation recommends otherwise.
- **Tech stack**: The issuer is Python (FastAPI-style) on a second Container App in the existing environment, deployed through Terraform modules matching existing conventions.
- **Dependency**: Timeline driven by nono/Liam integration. The agent key exchange, introspection and the UUID `key_id` must ship before nono writes `AgentSessionRecord`.
- **Change control**: Changing the `key_id` format requires a matching `NONO_v0.4.3` §4 change and re-ratification of the package.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Milestone covers both MVP closure and the v0.4.x agent-key work | nono/Liam depend on agent keys; the MVP proof is the foundation for attributed agent traffic | — Pending |
| Agent key issuer = thin Popeye wrapper service (D-2 Option B) | Keeps the admin credential server-side; one place to enforce issuance rules, introspection, relays and events | — Pending |
| Issuer runs as a second Container App, Python | Same network/identity envelope as the gateway; Python fits the existing validator tooling | — Pending |
| Fallback chain P-4 → Option B (defer TC-REL-02/TC-COST-04 to Stage 3) | No second provider procured; descope rules allow it if stated explicitly | — Pending |
| O1–O3 use proposed defaults (8h TTL, registry beside model registry, purpose = vocabulary validation if no user purpose list) | Unblocks implementation; limitations are stated rather than silent | — Pending |
| Network design is VNet peering from `EUS-POPEYE-VNET-01`, replacing a VM and Bastion inside the Stage 1/2 VNet | Networking chose peering. A peered caller VNet is how real callers connect, and the private route was proven on 2026-10-22 | ✓ Good |
| Intune/Graph fleet scripts in scope | Needed to mint user keys (with tenant UUID) that agent keys derive from | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-10-22 after initialization (networking review folded in)*
