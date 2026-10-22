<!-- GSD:project-start source:PROJECT.md -->
## Project

**Popeye — AI Usage Governance Control Plane**

Popeye is TWG's AI usage governance control plane. It's an internal-only LiteLLM gateway on Azure Container Apps that enforces model approval, data-class and budget policy, and writes an attributed cost ledger. Endpoint and credential automation and the operational tooling around it are part of Popeye too. This milestone closes the Stage 1/Stage 2 MVP and builds the ratified v0.4.x agent-principal work that nono and Liam integration depend on: agent key exchange, introspection, relays, purpose labels and run metering.

**Core Value:** Every governed model call is attributed. Each completion through the gateway lands one ledger row with the correct principal (user or agent, `on_behalf_of`, `key_id`, purpose, `run_id`, tenant). Agent keys can be minted, introspected and revoked under the rules nono depends on.

### Constraints

- **Security**: No provider API keys in config, tfvars or scripts; managed identity only. The gateway admin/master key never leaves Popeye's side, and the issuer endpoint never exposes it.
- **Security**: No prompt logging. Introspection and logs never contain key secrets (sentinel test). Evidence is redacted and synthetic.
- **Security**: Terraform state is sensitive; filled tfvars and `config/litellm.*.yaml` are never committed.
- **Guardrail**: `litellm_image_tag` never `latest`; `min_replicas` ≥ 2; never rotate the salt key casually; don't rename applied resources (`popeye-` prefix).
- **Architecture**: Observation/reporting never sits in the request path. The gateway stays semantics-blind: labels come from outside, prompts aren't inspected, except where the DLP evaluation recommends otherwise.
- **Tech stack**: The issuer is Python (FastAPI-style) on a second Container App in the existing environment, deployed through Terraform modules matching existing conventions.
- **Dependency**: Timeline driven by nono/Liam integration. The agent key exchange, introspection and the UUID `key_id` must ship before nono writes `AgentSessionRecord`.
- **Change control**: Changing the `key_id` format requires a matching `NONO_v0.4.3` §4 change and re-ratification of the package.
<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->
## Technology Stack

## Languages
- HCL (Terraform) >= 1.7.0 - infrastructure in `envs/` and `modules/`
- PowerShell (Windows PowerShell / pwsh 7 on CI) - Entra/Intune automation and validation scripts in `scripts/`
- Python 3.12 - schema fixture validation `scripts/Test-SessionCredentialFixtures.py`
- YAML - LiteLLM gateway config and model approval registry (`config/*.yaml`)
- JSON / JSON Schema (Draft 2020-12) - `contracts/schemas/session-credential-issuance-request-v0.1.schema.json`, `config/endpoint-detection.schema.json`
- SQL (PostgreSQL) - `sql/ai_usage_grants.sql`
- Markdown - specs and ADRs in `specs/`
## Runtime
- Deployed workload: LiteLLM proxy container `ghcr.io/berriai/litellm:<litellm_image_tag>` (pinned `-stable` tag, no default, `latest` rejected) on Azure Container Apps (`modules/gateway-service-azure/main.tf`)
- Terraform CLI >= 1.7.0 (`envs/azure-eastus2/versions.tf`)
- None for application code (no package.json/requirements.txt). CI installs `jsonschema==4.26.0` via pip.
- Lockfile: `envs/azure-eastus2/.terraform.lock.hcl` present (provider locks)
## Frameworks
- Terraform with module-per-concern layout (`modules/gateway-service-azure`, `gateway-state-azure`, `gateway-observability-azure`, `breakglass-azure`)
- LiteLLM proxy - AI gateway (enforcement, virtual keys, spend ledger)
- Custom fixture-based checks in PowerShell and Python (no Pester/pytest); run in `.github/workflows/registry-conformance.yml`
- GitHub Actions: `.github/workflows/terraform.yml` (`terraform fmt -check -recursive`, `init -backend=false`, `validate` on `envs/azure-eastus2`), `.github/workflows/registry-conformance.yml`
## Key Dependencies
- `hashicorp/azurerm` ~> 4.0 (locked 4.80.0)
- `hashicorp/azuread` ~> 3.0 (locked 3.9.0) - break-glass approver group
- `hashicorp/random` ~> 3.6 (locked 3.9.0) - generated Postgres admin, LiteLLM master/salt keys
- Azure Database for PostgreSQL Flexible Server v16 (`modules/gateway-state-azure/main.tf`)
- Azure Managed Redis (`azurerm_managed_redis`)
- `jsonschema` 4.26.0 (Python, CI only)
- `psql` client (for `scripts/Test-PopeyeVerificationPsql.ps1`), Azure CLI `az` (verification scripts)
## Configuration
- Terraform variables in `envs/azure-eastus2/variables.tf`; real values in gitignored `terraform.tfvars` (template `terraform.tfvars.example`)
- Required: `litellm_image_tag`, `gateway_key_vault_name`, `breakglass_key_vault_name`, `foundry_deployment_name`, `foundry_api_base`, `foundry_api_version`; optional `foundry_scope_id`, `teams_webhook_url` (sensitive), `breakglass_approvers_principal_id`
- Container env uses `os.environ/...` references: `LITELLM_MASTER_KEY`, `DATABASE_URL`, `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD`, `AZURE_CLIENT_ID`
- LiteLLM config rendered inline in `envs/azure-eastus2/main.tf` (`local.litellm_config_yaml`) and delivered as Container Apps secret (ADR-002, `specs/ADR-002-gateway-config-delivery.md`); reference copy `config/litellm.azure.example.yaml`
- `.env` ignored via `.gitignore`; filled `config/litellm.azure.yaml` / `config/litellm.aws.yaml` gitignored
- `envs/azure-eastus2/{versions,backend,variables,outputs,main}.tf`
- Remote state: azurerm backend (Storage account, container `popeye-infra`, Entra auth) in `envs/azure-eastus2/backend.tf`
- Policy data: `config/model-approval-registry.example.yaml`, vendored `config/vendored/vocabulary.yaml` (copied from fiskroad, SHA in `config/vendored/VENDORED.md`)
## Platform Requirements
- Terraform >= 1.7, PowerShell, Python 3.12 + jsonschema, Azure CLI, psql; Windows workstation (provider binaries are windows_amd64)
- Azure eastus2 (Stage 2): Container Apps (internal ingress, min 2 replicas), VNet 10.60.0.0/22, private DNS for Postgres. AWS us-east-1 (`envs/aws-use1`) and reporting (`envs/reporting`) are stubs.
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

## Naming Patterns
- PowerShell scripts: Verb-Noun PascalCase `.ps1` in `scripts/` (`scripts/Get-ModelAllowlist.ps1`, `scripts/Read-EndpointDetections.ps1`, `scripts/Test-PopeyeVerificationVm.ps1`). Older ones are kebab-case (`scripts/provision-desktop-keys.ps1`, `scripts/intune-baseurl-profile.ps1`); use Verb-Noun for new scripts.
- Python: `scripts/Test-SessionCredentialFixtures.py` (same Verb-Noun style as scripts).
- Terraform modules: `modules/<name>-azure/{main,variables,outputs}.tf`; env roots in `envs/<cloud>-<region>/` (`main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, `backend.tf`, `terraform.tfvars.example`).
- Config examples: `*.example.yaml`; schemas `*.schema.json`; versioned contract schemas `<name>-v0.1.schema.json` in `contracts/schemas/`.
- Specs: `UPPER_SNAKE_CASE_v0.N.md` in `specs/` (version suffix required; bump on revision).
- Fixtures: `valid-*.json` / `invalid-<reason>.json` in `contracts/fixtures/<contract>/`.
## Code Style
- Terraform: `terraform fmt -check -recursive` enforced in `.github/workflows/terraform.yml`. Run `terraform fmt -recursive` before commit.
- PowerShell: 2-space indent, no formatter configured. Python: 4-space, type hints on `main() -> int`.
- No `.editorconfig`, Prettier, or linters (PSScriptAnalyzer/ruff) configured.
## Script Preamble (PowerShell)
## Import Organization
## Error Handling
- PowerShell: fail fast with `throw "REQ-XXX-NN: <message>"`; strict mode + `Stop`. Validation happens up front, before side effects.
- Check scripts collect results into `System.Collections.Generic.List[object]` of `[pscustomobject]@{Check; Status = PASS|FAIL; Detail}` via `Add-Result` (`scripts/Test-PopeyeVerificationVm.ps1`) and wrap each check in `try/catch`.
- Python: accumulate `failures` list, print `FAIL:` to stderr, return exit code 1; entry via `raise SystemExit(main())`.
- Negative paths are tested by expecting a thrown message (see TESTING.md).
## Logging
## Comments
- Header block comments on each Terraform module stating design rules and citing spec sections (`# Design rules carried from AI_USAGE_GOVERNANCE_ROADMAP_v0.2.md`).
- Reference specs by section ("infrastructure plan section 4").
- Deferred work uses `TODO(stage-N): ...` (e.g. `TODO(stage-3)` in `scripts/provision-desktop-keys.ps1`).
- Use `.invalid` TLD and zero UUIDs for example data (`example.invalid`).
## Terraform Conventions
- Variables have `description`, `type`; secrets `sensitive = true` and "never a literal" in description (`modules/gateway-state-azure/variables.tf`).
- Pin `required_version >= 1.7.0`, `azurerm ~> 4.0` in `envs/azure-eastus2/versions.tf`; lock file `.terraform.lock.hcl` committed.
- Private networking by default (`public_network_access_enabled = false`); resources take `tags = var.tags`.
- `terraform.tfvars.example` committed; real tfvars and state are not.
## Function Design
## Module Design
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

## System Overview
```text
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
- Specs in `specs/` are the source of truth; `STATE.md` tracks implementation state; requirement IDs (e.g. `REQ-DCE-05`, `REQ-CRED-01`) are referenced in code and CI.
- Structural guardrails in Terraform: `litellm_image_tag` has no default and rejects `latest`; `min_replicas >= 2`; salt key `prevent_destroy`.
- Secrets live only in Key Vault and (encrypted) remote state; examples are committed, filled copies (`terraform.tfvars`, `config/litellm.azure.yaml`) are gitignored.
- Entra/Intune automation is deliberately PowerShell, not Terraform.
- Reporting (`ai_token_usage` Cube model) lives in a separate hometown repo.
## Layers
## Data Flow
### Primary Request Path
### Config Delivery (ADR-002)
### Allowlist Derivation
## Key Abstractions
## Entry Points
## Architectural Constraints
- **Threading:** Not applicable (no application runtime); gateway is stateless replicas.
- **Global state:** Terraform remote state; no module-level singletons in code.
- **Circular imports:** None; modules have one-way dependency (state -> observability/service; observability <-> service resolved via IDs in root).
- **Stubs:** `envs/aws-use1/` and `envs/reporting/` (and `modules/reporting-store/`) are requirements stubs only.
- **Internal DNS:** stable `gateway-azure.ai.twg.internal` pending ownership decision; only Container App internal FQDN exists today.
## Anti-Patterns
### Provider keys in config
### Hand-maintained allowlists
## Error Handling
## Cross-Cutting Concerns
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->
## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->



<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
