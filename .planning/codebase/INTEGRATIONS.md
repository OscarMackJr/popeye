# External Integrations

**Analysis Date:** 2026-10-22

## APIs & External Services

**LLM providers (via LiteLLM routing):**
- Azure AI Foundry / Azure OpenAI - primary backend, public model `twg-foundry`
  - Config: `foundry_api_base`, `foundry_deployment_name`, `foundry_api_version` in `envs/azure-eastus2/variables.tf`
  - Auth: user-assigned managed identity (`enable_azure_ad_token_refresh: true`, `AZURE_CLIENT_ID`), RBAC role `azurerm_role_assignment.foundry_user` in `modules/gateway-service-azure/main.tf` (scope `foundry_scope_id`)
- AWS Bedrock (Anthropic Claude, `twg-claude`) - planned cross-cloud fallback, commented out in `config/litellm.azure.example.yaml`; `envs/aws-use1/main.tf` is a stub
- Provider credentials, if ever needed, go to Key Vault (`azurerm_key_vault_secret.provider_credential`); never in config or tfvars

**Microsoft Graph (planned, TODO stage-3):**
- Entra group membership (`Get-MgGroupMember`, `GroupMember.Read.All`) and Intune (`DeviceManagementConfiguration.ReadWrite.All`) in `scripts/provision-desktop-keys.ps1`, `scripts/intune-baseurl-profile.ps1`

**Gateway admin API:**
- LiteLLM `/key/generate` and `/key/delete` called from `scripts/provision-desktop-keys.ps1` using master key resolved from Key Vault (`-MasterKeySecretUri`)

**Azure Instance Metadata Service:**
- `http://169.254.169.254/metadata/instance` queried in `scripts/Test-PopeyeVerificationVm.ps1`

## Data Storage

**Databases:**
- Azure PostgreSQL Flexible Server 16, private (delegated subnet + `privatelink.postgres.database.azure.com`), database `litellm`
  - Connection: `DATABASE_URL` (secret in gateway Key Vault)
  - Client: LiteLLM Prisma; reader role/DSN (`litellm-reader-dsn` secret) for semantic layer, grants in `sql/ai_usage_grants.sql` (`litellm_gateway` writer, read-only reader pattern)
  - Reporting tier (`ai_token_usage` Cube model) lives in the external hometown Enterprise Knowledge Graph repo; `envs/reporting` and `modules/reporting-store` are stubs

**File Storage:**
- Azure Storage account for Terraform state (`popeyetfstate98c2b71b`, container `popeye-infra`)

**Caching:**
- Azure Managed Redis (`azurerm_managed_redis.gateway`) for router state; `REDIS_HOST`/`REDIS_PORT`/`REDIS_PASSWORD`

## Authentication & Identity

**Auth Provider:**
- Microsoft Entra ID
  - Terraform/state access via Entra auth (`use_azuread_auth = true`)
  - Container App uses user-assigned managed identity to read Key Vault (`kv_secrets_user`) and call Foundry
  - Per-user LiteLLM virtual keys issued for the licensed Entra desktop-agents group
  - Session credential issuance contract: `specs/SESSION_CREDENTIAL_ISSUER_v0.1.md`, `contracts/schemas/session-credential-issuance-request-v0.1.schema.json`
  - Break-glass: dormant Key Vault with approvers group (`modules/breakglass-azure/main.tf`, `azuread_group.breakglass_approvers`), audit via diagnostic settings

## Monitoring & Observability

**Error Tracking:**
- None dedicated; Azure Monitor metric alerts (failed requests, replica unavailable, Postgres availability) in `modules/gateway-observability-azure/main.tf`

**Logs:**
- Log Analytics workspace + Application Insights; diagnostic settings for Postgres and break-glass Key Vault. Prompt/completion bodies are never stored (`store_prompts_in_spend_logs: false`).
- Endpoint detection events: JSONL validated by `scripts/Read-EndpointDetections.ps1` against `config/endpoint-detection.schema.json` (spec `specs/ENDPOINT_DETECTION_CONTRACT_v0.1.md`)

## CI/CD & Deployment

**Hosting:**
- Azure Container Apps (eastus2); image from GitHub Container Registry `ghcr.io/berriai/litellm`

**CI Pipeline:**
- GitHub Actions: `.github/workflows/terraform.yml`, `.github/workflows/registry-conformance.yml` (no deploy/apply step; apply is manual)

## Environment Configuration

**Required env vars:**
- Gateway runtime: `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, `DATABASE_URL`, `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD`, `AZURE_CLIENT_ID`, `LITELLM_CONFIG`
- Terraform: Azure auth context (az login / ARM_*), tfvars listed in STACK.md

**Secrets location:**
- Azure Key Vault (gateway vault, separate break-glass vault); Terraform-generated secrets also exist in remote state. `envs/azure-eastus2/terraform.tfvars` present locally (gitignored, not read). `artifacts/popeye-azure-verification-evidence.json` holds verification evidence.

## Webhooks & Callbacks

**Incoming:**
- None

**Outgoing:**
- Microsoft Teams incoming webhook via `azurerm_monitor_action_group.notify` (`teams_webhook_url`, optional)
- Optional `-WebhookUrl` aggregate summary post in `scripts/Read-EndpointDetections.ps1`

---

*Integration audit: 2026-10-22*
