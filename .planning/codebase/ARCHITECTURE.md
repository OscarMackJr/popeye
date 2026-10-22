<!-- refreshed: 2026-10-22 -->
# Architecture

**Analysis Date:** 2026-10-22

## System Overview

Popeye is an infrastructure-as-code and policy-as-config repository (no application runtime code). It deploys a LiteLLM-based AI gateway (enforcement point) on Azure, plus endpoint/credential automation and policy contracts.

```text
┌─────────────────────────────────────────────────────────────────────┐
│                  Policy / Contract Layer (source-controlled)         │
├──────────────────────┬───────────────────────┬──────────────────────┤
│ Model approval       │ Endpoint detection    │ Session credential   │
│ registry             │ schema                │ issuance schema      │
│ `config/model-       │ `config/endpoint-     │ `contracts/schemas/` │
│  approval-registry.  │  detection.schema.json│                      │
│  example.yaml`       │ `config/vendored/`    │                      │
└──────────┬───────────┴───────────┬───────────┴──────────┬───────────┘
           │                       │                      │
           ▼                       ▼                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│ PowerShell/Python automation `scripts/`  (allowlist derivation, key │
│ lifecycle, Intune profile, detection reader, fixture validators)     │
└──────────┬──────────────────────────────────────────────────────────┘
           ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Terraform root `envs/azure-eastus2/main.tf`                          │
│  ├ module.state          `modules/gateway-state-azure`  (PG, Redis)  │
│  ├ module.observability  `modules/gateway-observability-azure`       │
│  ├ module.service        `modules/gateway-service-azure` (LiteLLM)   │
│  └ module.breakglass     `modules/breakglass-azure`      (dormant KV)│
└──────────┬──────────────────────────────────────────────────────────┘
           ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Azure: Container Apps (LiteLLM, >=2 replicas) -> Foundry (MI + RBAC) │
│ Postgres ledger (`sql/ai_usage_grants.sql`) -> hometown Cube reader  │
└─────────────────────────────────────────────────────────────────────┘
```

## Component Responsibilities

| Component | Responsibility | File |
|-----------|----------------|------|
| Azure root module | Networking, gateway Key Vault, generated secrets, wires modules, renders LiteLLM YAML | `envs/azure-eastus2/main.tf` |
| State module | Zone-redundant Postgres Flexible Server (`prevent_destroy`) and Azure Managed Redis | `modules/gateway-state-azure/main.tf` |
| Service module | Container App with pinned LiteLLM image, UAMI, Key Vault refs, config secret, Foundry RBAC | `modules/gateway-service-azure/main.tf` |
| Observability module | Log Analytics, App Insights, Teams action group, POC alerts | `modules/gateway-observability-azure/main.tf` |
| Break-glass module | Dormant vault, approvers-only, audited | `modules/breakglass-azure/main.tf` |
| Gateway config reference | Non-secret LiteLLM routing config example | `config/litellm.azure.example.yaml` |
| Model approval registry | Data-class-to-model approvals; source of key allowlists | `config/model-approval-registry.example.yaml` |
| Allowlist derivation | Derives per-team model allowlist from registry | `scripts/Get-ModelAllowlist.ps1` |
| Key lifecycle | Entra group -> LiteLLM virtual keys (joiner/leaver) | `scripts/provision-desktop-keys.ps1` |
| Intune profile | Pushes gateway base URL to desktops (skeleton) | `scripts/intune-baseurl-profile.ps1` |
| Detection reader | Validates endpoint-detection JSONL, content-free summary | `scripts/Read-EndpointDetections.ps1` |
| Credential fixture check | Validates issuance request schema fixtures | `scripts/Test-SessionCredentialFixtures.py` |
| Verification VM scripts | Read-only Azure/VM private-connectivity checks | `scripts/Test-PopeyeAzureVerificationVm.ps1`, `scripts/Test-PopeyeVerificationVm.ps1`, `scripts/Test-PopeyeVerificationPsql.ps1` |
| Ledger SQL | Gateway DB bootstrap and read-only `ekg_cube_reader` grants | `sql/ai_usage_grants.sql` |
| CI | Terraform checks; registry/schema conformance | `.github/workflows/terraform.yml`, `.github/workflows/registry-conformance.yml` |

## Pattern Overview

**Overall:** Spec-driven, layered IaC with policy-as-data; "semantics-blind" enforcement (labels supplied externally, gateway never inspects prompts).

**Key Characteristics:**
- Specs in `specs/` are the source of truth; `STATE.md` tracks implementation state; requirement IDs (e.g. `REQ-DCE-05`, `REQ-CRED-01`) are referenced in code and CI.
- Structural guardrails in Terraform: `litellm_image_tag` has no default and rejects `latest`; `min_replicas >= 2`; salt key `prevent_destroy`.
- Secrets live only in Key Vault and (encrypted) remote state; examples are committed, filled copies (`terraform.tfvars`, `config/litellm.azure.yaml`) are gitignored.
- Entra/Intune automation is deliberately PowerShell, not Terraform.
- Reporting (`ai_token_usage` Cube model) lives in a separate hometown repo.

## Layers

**Specs/Decisions:** `specs/` (roadmap, infra plan, ADR-002, contracts, review/remediation docs).
**Policy/Contracts:** `config/`, `contracts/`.
**Automation:** `scripts/`.
**Infrastructure:** `envs/*` (root modules) composing `modules/*`.
**Data:** `sql/`.

## Data Flow

### Primary Request Path

1. Client (desktop agent / app) calls internal gateway base URL with a per-user virtual key (provisioned by `scripts/provision-desktop-keys.ps1`).
2. LiteLLM on Container Apps (`modules/gateway-service-azure/main.tf`) checks key/budget/model allowlist against Postgres and Redis (`modules/gateway-state-azure`).
3. Gateway routes `twg-foundry` to the Foundry deployment using managed identity (`litellm_config_yaml` in `envs/azure-eastus2/main.tf`).
4. Token counts and cost (no prompt bodies; `store_prompts_in_spend_logs: false`) land in the regional ledger, read by `ekg_cube_reader` (`sql/ai_usage_grants.sql`).

### Config Delivery (ADR-002)

1. Terraform renders LiteLLM YAML from variables (`local.litellm_config_yaml`).
2. Passed as `litellm_config_yaml` to the service module, stored as a Container Apps secret.
3. Entrypoint writes it to `/tmp/litellm.yaml`; config change = new revision (`specs/ADR-002-gateway-config-delivery.md`).

### Allowlist Derivation

1. `config/model-approval-registry.example.yaml` -> `scripts/Get-ModelAllowlist.ps1 -Cloud -TeamId [-DataClass]` -> allowlist used when generating keys.

**State Management:** Terraform remote state in Azure Storage (`envs/azure-eastus2/backend.tf`, Entra auth); runtime state in Postgres (keys, budgets, ledger) and Redis (counters).

## Key Abstractions

**Model approval registry:** `data_classes`, `models`, `teams` in YAML; classes must match `config/vendored/vocabulary.yaml`; `regulated-identifier` is unapprovable (REQ-DCE-06).
**Endpoint detection event:** `endpoint-detection/0.1` JSONL (`config/endpoint-detection.schema.json`, sample `config/fixtures/detections.sample.jsonl`).
**Session credential issuance request:** `contracts/schemas/session-credential-issuance-request-v0.1.schema.json` with fixtures in `contracts/fixtures/session-credential-issuance/`.

## Entry Points

**Terraform apply:** `envs/azure-eastus2/` (`terraform init/plan/apply`).
**PowerShell scripts:** each in `scripts/` is standalone with `param()` blocks.
**CI:** `.github/workflows/*.yml` on PR and push to main.

## Architectural Constraints

- **Threading:** Not applicable (no application runtime); gateway is stateless replicas.
- **Global state:** Terraform remote state; no module-level singletons in code.
- **Circular imports:** None; modules have one-way dependency (state -> observability/service; observability <-> service resolved via IDs in root).
- **Stubs:** `envs/aws-use1/` and `envs/reporting/` (and `modules/reporting-store/`) are requirements stubs only.
- **Internal DNS:** stable `gateway-azure.ai.twg.internal` pending ownership decision; only Container App internal FQDN exists today.

## Anti-Patterns

### Provider keys in config
**What happens:** Putting API keys in LiteLLM YAML or tfvars.
**Why it's wrong:** Config is stored in Terraform state/Container Apps secret.
**Do this instead:** Managed identity + RBAC; Key Vault references (`modules/gateway-service-azure/main.tf`).

### Hand-maintained allowlists
**What happens:** Editing key allowlists directly.
**Do this instead:** Derive from registry with `scripts/Get-ModelAllowlist.ps1`; keep `model_list` in sync with registry entries.

## Error Handling

**Strategy:** Fail fast. PowerShell uses `Set-StrictMode -Version Latest` and `$ErrorActionPreference = "Stop"`; errors cite requirement IDs; CI asserts bad fixtures are rejected. Terraform uses variable `validation` blocks.

## Cross-Cutting Concerns

**Logging:** Log Analytics/App Insights (`modules/gateway-observability-azure`); prompts never logged.
**Validation:** JSON schemas + fixtures, registry vocabulary checks in CI.
**Authentication:** Entra (Graph automation, Azure AD auth for state backend), managed identity to Key Vault/Foundry, LiteLLM virtual keys.

---

*Architecture analysis: 2026-10-22*
