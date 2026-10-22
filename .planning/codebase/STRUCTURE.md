# Codebase Structure

**Analysis Date:** 2026-10-22

## Directory Layout

```
popeye/
├── README.md            # Orientation and first-apply instructions
├── STATE.md             # Current implementation state and next task
├── .github/workflows/   # terraform.yml, registry-conformance.yml
├── specs/               # Design docs, ADRs, contracts, versioned specs
├── modules/             # Reusable Terraform modules
│   ├── gateway-state-azure/          # Postgres + Managed Redis
│   ├── gateway-service-azure/        # Container Apps LiteLLM gateway
│   ├── gateway-observability-azure/  # Log Analytics, App Insights, alerts
│   ├── breakglass-azure/             # Dormant break-glass vault
│   └── reporting-store/              # Stub (README only)
├── envs/                # Root modules per environment
│   ├── azure-eastus2/   # Implemented (Stage 2)
│   ├── aws-use1/        # Stub
│   └── reporting/       # Stub (README only)
├── config/              # Gateway config, registry, schemas
│   ├── fixtures/        # bad-registry.yaml, detections.sample.jsonl
│   └── vendored/        # vocabulary.yaml + VENDORED.md (copied shared vocab)
├── contracts/           # JSON schemas and fixtures
│   ├── schemas/
│   └── fixtures/session-credential-issuance/
├── scripts/             # PowerShell and Python automation/validators
├── sql/                 # Ledger bootstrap and grants
├── artifacts/           # Verification evidence JSON
└── .planning/codebase/  # GSD codebase maps
```

## Directory Purposes

**`specs/`:** Markdown specs. Key files: `AI_USAGE_GOVERNANCE_ROADMAP_v0.2.md`, `GATEWAY_INFRASTRUCTURE_PLAN_v0.1.md`, `ROADMAP.md`, `ADR-002-gateway-config-delivery.md`, `POPEYE_v0.4*.md`, `ENDPOINT_DETECTION_CONTRACT_v0.1.md`, `SESSION_CREDENTIAL_ISSUER_v0.1.md`, `DATA_CLASS_ENFORCEMENT_*`, `STAGE1_STAGE2_MVP_COMPLETION_CHECKLIST_v0.1.md`, `specs/README.md`.

**`modules/<name>/`:** Each contains `main.tf`, `variables.tf`, `outputs.tf`.

**`envs/azure-eastus2/`:** `main.tf` (networking, vault, secrets, module wiring, LiteLLM YAML), `variables.tf`, `outputs.tf`, `versions.tf`, `backend.tf`, `terraform.tfvars.example`, `.terraform.lock.hcl`. `.terraform/` is local and ignored.

**`config/`:** `litellm.azure.example.yaml`, `model-approval-registry.example.yaml`, `endpoint-detection.schema.json`.

**`scripts/`:** `Get-ModelAllowlist.ps1`, `provision-desktop-keys.ps1`, `intune-baseurl-profile.ps1`, `Read-EndpointDetections.ps1`, `Test-SessionCredentialFixtures.py`, `Test-Popeye*Vm*.ps1`, `Test-PopeyeVerificationPsql.ps1`; `Test-PopeyeAzureVerificationVm.zip` is a packaged copy of the verification script.

## Key File Locations

**Entry Points:** `envs/azure-eastus2/main.tf`; `.github/workflows/*.yml`.
**Configuration:** `envs/azure-eastus2/terraform.tfvars.example`, `envs/azure-eastus2/backend.tf`, `config/*.example.yaml`.
**Core Logic:** `modules/gateway-service-azure/main.tf`, `scripts/Get-ModelAllowlist.ps1`.
**Testing:** CI-driven fixture checks: `config/fixtures/`, `contracts/fixtures/`, `scripts/Test-SessionCredentialFixtures.py`; no unit-test framework.

## Naming Conventions

**Files:**
- Terraform: lowercase `main.tf`/`variables.tf`/`outputs.tf`.
- PowerShell: `Verb-Noun.ps1` PascalCase for new scripts (`Get-ModelAllowlist.ps1`); older ones kebab-case (`provision-desktop-keys.ps1`).
- Specs: `UPPER_SNAKE_vX.Y.md`; ADRs `ADR-NNN-kebab-title.md`.
- Config examples: `*.example.yaml`; filled copies gitignored.
- Schemas: `<name>-v0.1.schema.json`.

**Directories:** lowercase kebab-case; modules `<purpose>-<cloud>`; envs `<cloud>-<region>`.

**Resources:** `name_prefix = popeye-<env>-<region>`.

## Where to Add New Code

**New Azure resource group of infra:** new module in `modules/<purpose>-azure/` with `main.tf`, `variables.tf`, `outputs.tf`; wire in `envs/azure-eastus2/main.tf`.
**New region/cloud:** new `envs/<cloud>-<region>/` root module.
**New approved model:** add entry to `config/model-approval-registry.example.yaml` and matching `model_list` entry in `config/litellm.azure.example.yaml` and `local.litellm_config_yaml`.
**New automation script:** `scripts/Verb-Noun.ps1` with `param()`, `Set-StrictMode`, `$ErrorActionPreference = "Stop"`; add a CI step in `.github/workflows/registry-conformance.yml` for validators.
**New contract:** schema in `contracts/schemas/`, fixtures (valid and invalid) in `contracts/fixtures/<name>/`, spec in `specs/`.
**New decision:** `specs/ADR-NNN-*.md`.

## Special Directories

**`envs/azure-eastus2/.terraform/`:** provider cache; generated, gitignored.
**`artifacts/`:** verification evidence; untracked, redacted JSON.
**`config/vendored/`:** vendored from another repo; do not edit locally (see `config/vendored/VENDORED.md`).
**`.planning/`:** GSD planning output.

---

*Structure analysis: 2026-10-22*
