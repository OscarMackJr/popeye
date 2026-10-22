# Technology Stack

**Analysis Date:** 2026-10-22

## Languages

**Primary:**
- HCL (Terraform) >= 1.7.0 - infrastructure in `envs/` and `modules/`
- PowerShell (Windows PowerShell / pwsh 7 on CI) - Entra/Intune automation and validation scripts in `scripts/`

**Secondary:**
- Python 3.12 - schema fixture validation `scripts/Test-SessionCredentialFixtures.py`
- YAML - LiteLLM gateway config and model approval registry (`config/*.yaml`)
- JSON / JSON Schema (Draft 2020-12) - `contracts/schemas/session-credential-issuance-request-v0.1.schema.json`, `config/endpoint-detection.schema.json`
- SQL (PostgreSQL) - `sql/ai_usage_grants.sql`
- Markdown - specs and ADRs in `specs/`

## Runtime

**Environment:**
- Deployed workload: LiteLLM proxy container `ghcr.io/berriai/litellm:<litellm_image_tag>` (pinned `-stable` tag, no default, `latest` rejected) on Azure Container Apps (`modules/gateway-service-azure/main.tf`)
- Terraform CLI >= 1.7.0 (`envs/azure-eastus2/versions.tf`)

**Package Manager:**
- None for application code (no package.json/requirements.txt). CI installs `jsonschema==4.26.0` via pip.
- Lockfile: `envs/azure-eastus2/.terraform.lock.hcl` present (provider locks)

## Frameworks

**Core:**
- Terraform with module-per-concern layout (`modules/gateway-service-azure`, `gateway-state-azure`, `gateway-observability-azure`, `breakglass-azure`)
- LiteLLM proxy - AI gateway (enforcement, virtual keys, spend ledger)

**Testing:**
- Custom fixture-based checks in PowerShell and Python (no Pester/pytest); run in `.github/workflows/registry-conformance.yml`

**Build/Dev:**
- GitHub Actions: `.github/workflows/terraform.yml` (`terraform fmt -check -recursive`, `init -backend=false`, `validate` on `envs/azure-eastus2`), `.github/workflows/registry-conformance.yml`

## Key Dependencies

**Critical (Terraform providers, locked):**
- `hashicorp/azurerm` ~> 4.0 (locked 4.80.0)
- `hashicorp/azuread` ~> 3.0 (locked 3.9.0) - break-glass approver group
- `hashicorp/random` ~> 3.6 (locked 3.9.0) - generated Postgres admin, LiteLLM master/salt keys

**Infrastructure:**
- Azure Database for PostgreSQL Flexible Server v16 (`modules/gateway-state-azure/main.tf`)
- Azure Managed Redis (`azurerm_managed_redis`)
- `jsonschema` 4.26.0 (Python, CI only)
- `psql` client (for `scripts/Test-PopeyeVerificationPsql.ps1`), Azure CLI `az` (verification scripts)

## Configuration

**Environment:**
- Terraform variables in `envs/azure-eastus2/variables.tf`; real values in gitignored `terraform.tfvars` (template `terraform.tfvars.example`)
- Required: `litellm_image_tag`, `gateway_key_vault_name`, `breakglass_key_vault_name`, `foundry_deployment_name`, `foundry_api_base`, `foundry_api_version`; optional `foundry_scope_id`, `teams_webhook_url` (sensitive), `breakglass_approvers_principal_id`
- Container env uses `os.environ/...` references: `LITELLM_MASTER_KEY`, `DATABASE_URL`, `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD`, `AZURE_CLIENT_ID`
- LiteLLM config rendered inline in `envs/azure-eastus2/main.tf` (`local.litellm_config_yaml`) and delivered as Container Apps secret (ADR-002, `specs/ADR-002-gateway-config-delivery.md`); reference copy `config/litellm.azure.example.yaml`
- `.env` ignored via `.gitignore`; filled `config/litellm.azure.yaml` / `config/litellm.aws.yaml` gitignored

**Build:**
- `envs/azure-eastus2/{versions,backend,variables,outputs,main}.tf`
- Remote state: azurerm backend (Storage account, container `popeye-infra`, Entra auth) in `envs/azure-eastus2/backend.tf`
- Policy data: `config/model-approval-registry.example.yaml`, vendored `config/vendored/vocabulary.yaml` (copied from fiskroad, SHA in `config/vendored/VENDORED.md`)

## Platform Requirements

**Development:**
- Terraform >= 1.7, PowerShell, Python 3.12 + jsonschema, Azure CLI, psql; Windows workstation (provider binaries are windows_amd64)

**Production:**
- Azure eastus2 (Stage 2): Container Apps (internal ingress, min 2 replicas), VNet 10.60.0.0/22, private DNS for Postgres. AWS us-east-1 (`envs/aws-use1`) and reporting (`envs/reporting`) are stubs.

---

*Stack analysis: 2026-10-22*
