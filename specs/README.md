# Specifications

Source-controlled specifications for the AI gateway control plane.

## Planning Entry Points

- [Current State](../STATE.md)
- [AI Usage Governance Roadmap v0.2](./AI_USAGE_GOVERNANCE_ROADMAP_v0.2.md) — architecture, reliability model, SLOs, incident response, staged roadmap.
- [Gateway Infrastructure And Implementation Plan v0.1](./GATEWAY_INFRASTRUCTURE_PLAN_v0.1.md) — language decisions, per-cloud resource inventories, repository layout, sequencing.
- [Popeye Stage 1 Kickoff v0.1](./POPEYE_STAGE1_KICKOFF_v0.1.md) — POC execution direction: ownership, prerequisites, measurement protocol, demo script.
- [Popeye Roadmap](./ROADMAP.md) — working scope/MVP boundary across Popeye, hometown, and program-level POCs.
- [Data-Class Enforcement v0.1](./DATA_CLASS_ENFORCEMENT_v0.1.md) — requirement draft for deriving model allowlists from regulated data classification.
- [Data-Class Enforcement Implementation Spec v0.1](./DATA_CLASS_ENFORCEMENT_IMPLEMENTATION_SPEC_v0.1.md) — implementation-ready scope and acceptance criteria.
- [Data-Class Enforcement Implementation Prompt v0.1](./DATA_CLASS_ENFORCEMENT_IMPLEMENTATION_PROMPT_v0.1.md) — phased execution prompt for implementation agents.
- [Popeye Implementation Review v0.1](./POPEYE_IMPLEMENTATION_REVIEW_v0.1.md) - review findings to remediate before POC.
- [Popeye Implementation Review Remediation Spec v0.1](./POPEYE_IMPLEMENTATION_REVIEW_REMEDIATION_SPEC_v0.1.md) - implementation-ready remediation plan for all review findings.
- [Popeye Implementation Review Remediation Prompt v0.1](./POPEYE_IMPLEMENTATION_REVIEW_REMEDIATION_PROMPT_v0.1.md) - phased execution prompt for remediation agents.
- [State Backend Access Confirmation v0.1](./STATE_BACKEND_ACCESS_CONFIRMATION_v0.1.md) - Terraform state sensitivity and access-control confirmation.

## Cross-Repository Artifacts

Owned by the hometown repository (semantic layer), referenced here:

- `cube/model/ai_token_usage.yml` — the governed usage/cost model.
- `cube/docker-compose.gateway-poc.yml` — Stage 1 local POC profile.
- Planned verifiers: `verify:gateway:ledger-reconciliation`,
  `verify:gateway:attribution` (roadmap 7.4; hometown `verify:*`
  conventions).

Owned by this repository:

- `config/litellm.azure.example.yaml` — per-region gateway configuration.
- `sql/ai_usage_grants.sql` — ledger database bootstrap and read-only
  grants (promoted from the POC; reused by the Stage 3 reporting store).
- `scripts/` — Entra/Intune automation (deliberately not Terraform;
  see infrastructure plan section 6).

## Pending Decision Records

To be added as ADRs when decided (roadmap section 11):

- ADR-001: Gateway product (LiteLLM OSS vs. Enterprise vs. Azure APIM).
- [ADR-002: Gateway config delivery](./ADR-002-gateway-config-delivery.md) - Terraform-rendered non-secret YAML delivered as a Container Apps secret.
- ADR-003: Reporting store placement and consolidation mechanism.
- ADR-004: Cross-cloud-safe model group list (with application owners).
