# Project State

Project codename: Popeye

Status: Active
Last updated: 2026-08-01
Audience: future implementation agents and maintainers resuming work
Primary post-read action: resume the next engineering task with the correct context and guardrails.

## Current Position

The project is in the Stage 1/Stage 2 POC phase of the AI usage governance control plane. Azure eastus2 infrastructure is live and the selected Foundry backend config has been delivered; the remaining MVP work is to prove attributed traffic through the gateway, complete Stage 1 measurements, and fold the roadmap requirements into operational readiness.

Working sources of truth:

- [AI Usage Governance Roadmap v0.2](./specs/AI_USAGE_GOVERNANCE_ROADMAP_v0.2.md) for architecture, reliability model, SLOs, incident response, and stage sequencing.
- [Gateway Infrastructure And Implementation Plan v0.1](./specs/GATEWAY_INFRASTRUCTURE_PLAN_v0.1.md) for language decisions and per-cloud resource inventories.
- [Popeye Stage 1 Kickoff v0.1](./specs/POPEYE_STAGE1_KICKOFF_v0.1.md) for execution mechanics: ownership, prerequisites, measurement protocol, data rules, descope rules, and the demo script.
- [Popeye roadmap](./specs/ROADMAP.md) for the working scope/MVP boundary between Popeye, hometown, and program-level POCs.
- This file for implementation state.

The Stage 1 POC artifacts (Cube model, POC compose profile) live in the hometown repository; this repository carries everything from Stage 2 onward plus the promoted config and SQL.

## Stage Progress

- Stage 1 (Control-plane POC): ACTIVE / INTEGRATED WITH STAGE 2. Local POC artifacts are still needed for the measurement protocol and demo beats, but the Azure managed stack has also been applied. Exit still produces `specs/STAGE1_BASELINES.md`, which turns provisional SLOs into committed numbers.
- Stage 2 (First managed region, azure-eastus2): APPLIED / FOUNDRY CONFIG DELIVERED. Terraform remote state is in Azure Storage, resources are live in the TWG Architecture POCs subscription, and the Container App latest revision is healthy with two replicas. The gateway now renders `twg-foundry` to the selected Foundry deployment via ADR-002 config delivery, and the gateway identity has Foundry RBAC. A smoke completion and ledger-row confirmation are the next Stage 2 proof points.
- Stage 3 (Second region + reporting + fleet rollout): STUBBED. `envs/aws-use1` and `envs/reporting` are requirements stubs; PowerShell automation skeletons in `scripts/` still need Graph implementation.
- Stage 4 (FinOps operationalization): NOT STARTED.

## What Exists

Terraform (Azure, Stage 2):

- `modules/gateway-state-azure`: zone-redundant Postgres Flexible Server (keys, budgets, regional ledger; `prevent_destroy`) and Azure Managed Redis. Azure Cache for Redis creation was blocked by retirement policy, so new deployments use Managed Redis.
- `modules/gateway-service-azure`: Container Apps gateway, pinned LiteLLM image, min 2 replicas, user-assigned identity, Key Vault secret references, Managed Redis secret wiring, ADR-002 LiteLLM config secret delivery, and optional Foundry RBAC assignment.
- `modules/gateway-observability-azure`: Log Analytics, App Insights, Postgres diagnostics, Teams action group, and conservative POC page alerts for gateway 5xx responses, low gateway replicas, and Postgres availability. Full burn-rate and notify-level thresholds remain deferred to Stage 1 baselines.
- `modules/breakglass-azure`: dormant vault, approvers-only data plane, audited, placeholder secret with ignored drift so Terraform never reverts an active credential mid-incident.
- `envs/azure-eastus2`: root module wiring networking (VNet, delegated subnets, private DNS placeholders), the gateway secrets vault, generated secrets (master key, salt key with `prevent_destroy`, database URL), all four modules, and the configured AzureRM backend. Current outputs include the Container App internal FQDN and Postgres FQDN; stable `gateway-azure.ai.twg.internal` DNS still requires the ownership decision below.

Non-Terraform:

- `config/litellm.azure.example.yaml`: per-region gateway config with no-prompt-logging guardrails and registry-backed model approval comments. Fallback-chain examples remain comments until a second backend is procured.
- `sql/ai_usage_grants.sql`: ledger bootstrap and `ekg_cube_reader` grants, promoted from the POC.
- `scripts/provision-desktop-keys.ps1`, `scripts/intune-baseurl-profile.ps1`: Stage 3 skeletons with Graph TODOs.

## Next Task

Continue the combined Stage 1/Stage 2 MVP:

1. Run a smoke completion through the internal gateway and confirm one attributed row lands in the regional ledger. The current workstation cannot resolve the internal Container Apps FQDN, and `az containerapp exec` did not accept non-interactive smoke commands even though ARM reports both replicas running and ready.
2. Use the smoke evidence to complete the Stage 1 measurement protocol: latency overhead, budget counter lag, ledger freshness, ledger interruption, and budget-versus-provider-throttle payload capture. Run fallback behavior only if the second backend is available; otherwise record it as skipped with the Cloud access owner carrying the second-provider prerequisite.
3. Hand hometown read access and request ID/attribution expectations for the `ai_token_usage` chargeback query; Popeye owns the grant and ledger path, not the Cube model.
4. Evaluate gateway-level content guardrails/DLP on the hook surface: PII masking, prompt-injection screening, latency/error impact, and compatibility with the no-prompt-logging guardrail.
5. Commit MVP SLO numbers into a roadmap v0.3 revision, replace placeholder alert criteria, and rehearse the six MVP runbooks.

## Known Gaps

- Terraform has been initialized, validated, planned, and applied against the TWG Architecture POCs subscription. Final drift check reported no changes.
- Gateway config delivery is now ADR-002: Terraform renders non-secret LiteLLM YAML into a Container Apps secret. Revisit before production if config size, promotion workflow, or audit needs justify a baked image or mounted file.
- Conservative page alerts now cover gateway 5xx responses, low gateway replicas, and Postgres availability. Full burn-rate rules and notify-level budget/fallback/attribution alerts still need Stage 1 baseline thresholds and data-source confirmation.
- Application-VNet peering and the `ai.twg.internal` private DNS zone ownership remain Stage 2 follow-ups. Decision needed by 2026-08-15: central networking owns and delegates/creates `gateway-azure.ai.twg.internal`, or this stack gains variables/data sources to manage the private DNS zone. Owner placeholder: popeye platform owner plus central networking owner.
- Intune/Graph script bodies are skeletons; Stage 3 work.
- Content guardrail/DLP evaluation is now in MVP scope; no implementation or baseline exists yet.
- Break-glass currently grants the signed-in POC principal access because the current Azure identity could not create Entra groups. Replace this with a named approver group/PIM model before MVP exit.

## Guardrails

- Terraform `name_prefix` has been changed to `popeye-` and applied. Do not rename applied Azure resources casually; it will force replacement.
- Never set `litellm_image_tag` to `latest`; validation enforces it, do not weaken the validation.
- Never rotate the salt key via a casual apply; it invalidates stored provider credentials (roadmap 8.2, runbook 4). `prevent_destroy` and `ignore_changes` protect it; treat overrides as incident-class.
- No provider API keys in application config, tfvars, or scripts; managed identity and IAM roles are the design (infrastructure plan sections 2–3).
- The state backend must be encrypted and access-controlled before first apply; state contains generated secrets.
- Observation/reporting resources must never sit in the request path (roadmap 4.1).
- Popeye owns the governed AI request path and cost ledger; hometown owns semantic models, provenance, GraphRAG behavior, and business authorization. Preserve the `request_id` plus attribution metadata contract.
- Do not commit filled `terraform.tfvars` or filled `config/litellm.*.yaml`; examples only.

## Completion Definition For The Current Slice

Current MVP slice is ready to close when:

- Terraform remains clean (`terraform validate` and a no-change plan).
- The real Foundry-backed LiteLLM config is delivered through the chosen ADR-002 mechanism.
- A smoke completion request through `twg-foundry` lands one attributed row in the regional ledger.
- `specs/STAGE1_BASELINES.md` records the required measurements and proposes committed MVP SLOs.
- Gateway-level content guardrail/DLP evaluation is documented with a go/no-go recommendation.
- Runbooks, break-glass approvers, and operational ownership are named and rehearsed.