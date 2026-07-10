# AI Gateway Infrastructure And Implementation Plan

Version: 0.1
Status: Draft
Audience: platform engineers, cloud/infrastructure owners, CTO
Primary post-read action: confirm the language/component mapping and the two regional resource inventories, then authorize creation of the Terraform repository skeleton.
Companion documents: AI_USAGE_GOVERNANCE_ROADMAP_v0.2.md (architecture, SLOs, incident response), cube/model/ai_token_usage.yml, cube/docker-compose.gateway-poc.yml (Stage 1 POC).

## 1. Implementation Language Decisions

Governing decision: **deploy, don't build.** The gateway, semantic layer, and state stores are off-the-shelf components. Custom code is confined to four small, replaceable components. No custom proxy is written in any language; the gateway's value is its maintained provider integrations, price maps, and token accounting, which are a treadmill, not a project.

Component-to-language mapping:

- **Infrastructure (the bulk of the work): Terraform/HCL.** Two regional stacks plus a shared reporting stack. The gateway vendor publishes AWS Terraform modules on the public registry (`BerriAI/litellm/aws`); use as reference or starting point, then own the fork. All infrastructure is source-controlled per the existing EKG principle.
- **Gateway configuration and semantic models: YAML.** `litellm.config.yaml` per region and Cube models in `cube/model/`. Both validated in CI like every other contract in the project.
- **Gateway extensions (only if needed): Python.** LiteLLM's custom hooks/callbacks (custom auth checks, attribution validation, custom spend logic) are Python. This is the only place Python is required; do not let it spread beyond the gateway plugin surface.
- **Reconciliation and verification: TypeScript, in the hometown repo.** The ledger-completeness reconciler (roadmap 7.4) and a gateway-attribution verifier follow the existing `verify:*` npm script conventions and run in the same CI gate. Proposed scripts: `verify:gateway:ledger-reconciliation`, `verify:gateway:attribution`.
- **Identity and fleet automation: PowerShell + Microsoft Graph.** Entra-ID-to-virtual-key provisioning (joiner/mover/leaver lifecycle for desktop keys) and Intune configuration rollout. Native fit for the O365-managed Windows estate.
- **Endpoint bypass detection: nono's own codebase.** The direct-to-provider detection policy is an extension of nono's existing WFP-based flow observation, written in nono's language, shipped through nono's release process. It is not a component of this repository.
- **Consolidation job: no code first.** Regional-ledger-to-reporting-store consolidation starts as Postgres logical replication or a scheduled `COPY`-based task (pure infrastructure). Only if transformation needs emerge does it become a small Python or TypeScript job. Write the zero-code version first.

Explicitly rejected:

- Rust/C# custom gateway or sidecar meter (build-vs-buy, above).
- C# in-app metering SDKs for Nexus/Intrepid (violates the roadmap section 2 decision; applications carry headers, not components).
- React admin dashboards in Stage 1–2 (the gateway ships an admin UI; reporting is Cube; build UI only when a real gap is proven).

## 2. AWS Regional Stack (gateway-aws)

New resources, all Terraform:

Networking and compute:

- VPC or reuse of the existing application VPC; private subnets for the gateway; security groups permitting ingress only from application subnets and the VPN/desktop egress path.
- ECS Fargate service running the pinned gateway image (2+ tasks across AZs) behind an internal Application Load Balancer. EKS only if the organization already operates it; do not adopt Kubernetes for one service.
- Internal Route 53 record: `gateway-aws.ai.twg.internal`, plus the global `ai-gateway.twg.internal` routing name (roadmap section 5).

State:

- RDS PostgreSQL, Multi-AZ: gateway keys, budgets, regional spend ledger. Dedicated instance; never shared with application-domain databases (roadmap 4.2).
- ElastiCache Redis: rate/budget counters, router cooldown state.

Identity and secrets:

- IAM task role for the gateway with `bedrock:InvokeModel` (and `bedrock:InvokeModelWithResponseStream`) scoped to the approved model ARNs. On AWS the gateway authenticates to Bedrock with its task role: **no long-lived AWS access keys exist in this design.** The POC compose file's `GATEWAY_AWS_ACCESS_KEY_ID` variables are a local-only convenience that this stack retires.
- Secrets Manager: gateway master key, salt key, Azure credentials if cross-cloud fallback is configured from this region. Rotation policies on everything except the salt key (roadmap 8.2 runbook 4 caveat: salt-key rotation invalidates stored credentials and is an incident-class action, not a schedule).

Bedrock:

- Model access enablement for the approved model list (account-level, terraformable via `aws_bedrock_foundation_model` data sources and access grants where supported; some enablement remains a console/API action — record it in the runbook if so).
- Application inference profiles, one per onboarded application (`hometown-ekg`, `intrepid-ai`, `nexus-crm`, `sit-cip`), tagged for cost allocation. These make the monthly bill-versus-ledger spot check (roadmap 7.4) a tag-filtered Cost Explorer query. Note the account/region profile cap when designing the naming scheme.
- Cost allocation tags activated in the billing console (one-time, not terraformable in all cases).

Observability:

- CloudWatch log groups for gateway access/audit logs; OTel collector (sidecar or ADOT) exporting traces/metrics to the existing monitoring stack.
- Alarms wired per roadmap 7.3 (availability burn, ledger write failures, state-store failover).

## 3. Azure Regional Stack (gateway-azure)

New resources, all Terraform (azurerm provider):

Networking and compute:

- Resource group `rg-ai-gateway`; VNet integration with the application VNet or peering; NSGs permitting ingress only from application subnets and the desktop path.
- Azure Container Apps app running the same pinned gateway image (min 2 replicas, zone redundancy where the region supports it) with internal ingress. AKS only under the same rule as EKS above.
- Private DNS: `gateway-azure.ai.twg.internal`.

State:

- Azure Database for PostgreSQL Flexible Server, zone-redundant HA: keys, budgets, regional ledger.
- Azure Cache for Redis.

Identity and secrets:

- User-assigned managed identity for the Container App; Key Vault holding master key, salt key, and any non-identity credentials; Key Vault references injected as Container Apps secrets.
- Foundry authentication via managed identity/RBAC (`Cognitive Services OpenAI User` or the Foundry-equivalent role) rather than API keys wherever the gateway supports it; API key from Key Vault as fallback. Same end state as AWS: no long-lived provider secrets in configuration.

Foundry:

- The model deployments the gateway fronts, terraformed (azurerm cognitive/AI services deployment resources), with TPM quota allocations recorded in Terraform so capacity is source-controlled.
- Diagnostic settings shipping Foundry usage logs to the monitoring workspace (input to the monthly bill-versus-ledger spot check on the Azure side).

Observability:

- Log Analytics workspace + Application Insights (or OTel collector to the common stack — match whatever the organization standardizes on; do not run two telemetry pipelines).
- Alerts per roadmap 7.3.

## 4. Shared Reporting Stack

- Reporting store: one Postgres instance in the cloud chosen by the (open) placement decision; receives both regional ledgers.
- Consolidation: logical replication publications on each regional ledger's spend-log table, subscription on the reporting store; falls back to a scheduled ECS task / Container Apps job if replication across clouds proves operationally awkward. Freshness measured against the 15-minute SLO.
- Cube: containerized deployment (same compute pattern as the regional gateway in whichever cloud hosts reporting) reading the reporting store through a read-only role, `ekg_cube_reader` pattern, `SELECT` on the spend table only (see gateway/sql/ai_usage_grants.sql).
- The reporting store is a derived view rebuildable from regional ledgers; back up the regional ledgers as sources of truth, treat the reporting store's backups as convenience.

## 5. Changes To Existing Resources

Application changes (configuration, not code, plus the header convention):

- Nexus CRM, Intrepid AI components, sit-cip, hometown: base URL swapped to the co-located regional gateway; provider SDK keys replaced by gateway virtual keys; attribution metadata (`spend_logs_metadata`) added to calls. No metering code.
- Raw provider API keys removed from every application secret store, config file, and CI variable set once cutover per app is verified. Removal is the exit criterion of each app's onboarding, not a cleanup afterthought.

Network changes:

- Application subnets/NSGs/SGs: allow egress to the regional gateway.
- Stage 3+ hardening: block direct egress from application subnets to provider endpoints (Bedrock/Foundry/api.anthropic.com and peers) so the gateway is the only path — the server-side analog of nono's endpoint enforcement. Do this only after fallback and break-glass are rehearsed, because it converts "gateway down" from degraded to hard-down for anything not in the break-glass list.

Shared local Docker Postgres:

- Unchanged in the cloud design; the POC's use of it retires when Stage 2's first managed region lands. The `litellm` database and roles from ai_usage_grants.sql migrate to the regional RDS/Flexible Server via the same script.

Break-glass standing capability (terraformed but dormant):

- Pre-created, disabled provider credentials (an IAM role assumable only by the break-glass approvers' group; a Key Vault secret with access policy gated to the same group) so the roadmap 8.3 procedure activates existing audited resources rather than creating credentials during an incident.

## 6. Not Terraformable (Tracked As Runbook/Automation Instead)

- Intune configuration profiles pushing `ANTHROPIC_BASE_URL`/base-URL environment variables to workstations: Microsoft Graph via PowerShell (Intune's Terraform coverage through community providers is not worth the dependency). Source-control the scripts.
- Entra ID pieces: the app registration for the key-provisioning automation and the break-glass approvers group CAN be terraformed with the `azuread` provider and should be; the joiner/mover/leaver key lifecycle itself is the PowerShell + Graph automation.
- Bedrock model-access enablement and billing-console cost-allocation-tag activation, where the provider APIs don't cover them: documented one-time actions in the deployment runbook.
- nono policy profile distribution: ships through nono's own release/update mechanism, not this repo.

## 7. Proposed Repository Layout

New repository `ai-gateway-infra` (or a `deploy/` tree in hometown if the CTO prefers fewer repos; separate repo recommended since its change cadence and reviewers differ):

```
ai-gateway-infra/
  modules/
    gateway-service/        # compute + LB/ingress + identity (cloud-specific implementations)
    gateway-state/          # Postgres + Redis
    gateway-observability/  # logs, metrics export, alarms per roadmap 7.3
    reporting-store/        # consolidated ledger + replication/job
    breakglass/             # dormant credentials + approver group wiring
  envs/
    aws-use1/               # first AWS region root module
    azure-eastus2/          # first Azure region root module
    reporting/              # reporting stack root module
  config/
    litellm.aws.yaml        # per-region gateway config (from litellm.config.example.yaml)
    litellm.azure.yaml
  scripts/
    provision-desktop-keys.ps1   # Entra -> virtual key lifecycle
    intune-baseurl-profile.ps1
  sql/
    ai_usage_grants.sql     # promoted from the POC
```

hometown repo additions (separate PR): `cube/model/ai_token_usage.yml`, the two `verify:gateway:*` TypeScript verifiers, and ROADMAP/STATE updates registering the stage.

## 8. Sequencing Against The Roadmap

- Stage 1 (POC): no cloud Terraform. Local compose only. Output: measured baselines and validated config.
- Stage 2: terraform ONE regional stack (pilot-priority cloud) + break-glass module + observability. Promote the POC's YAML and SQL. Onboard two applications; remove their raw keys.
- Stage 3: terraform the second regional stack + reporting stack + consolidation; Intune/Entra automation rollout; egress hardening begins.
- Stage 4: cost-allocation reconciliation automation; pre-aggregations; no new infrastructure classes expected.

## 9. Open Items For This Plan

- ECS Fargate vs. existing container platform on AWS, and Container Apps vs. existing platform on Azure: default to the managed-simple option unless a platform team already operates EKS/AKS with capacity to own this.
- Which cloud hosts the reporting stack (carries over from roadmap section 11).
- Whether gateway config YAML lives in this repo (deployment-coupled) or hometown (semantic-coupled). Recommendation: this repo; Cube models stay in hometown.
- Terraform state backend and CI (assume the organization's existing standard; if none exists, this project should not be the one to invent it alone).
