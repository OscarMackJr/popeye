# Implementation Prompt: Popeye Review Remediation

Use this prompt with an implementation agent working in the popeye repository.

## Mission

Address every finding in `specs/POPEYE_IMPLEMENTATION_REVIEW_v0.1.md` according to `specs/POPEYE_IMPLEMENTATION_REVIEW_REMEDIATION_SPEC_v0.1.md`.

Prioritize P1 through P4 before cleanup findings. Preserve the existing architecture: LiteLLM on Azure Container Apps, Terraform-rendered non-secret config, Key Vault for durable secrets, no prompt logging, and no custom proxy unless a later ADR explicitly changes that direction.

## Required Reading

Read these files before editing:

- `specs/POPEYE_IMPLEMENTATION_REVIEW_v0.1.md`
- `specs/POPEYE_IMPLEMENTATION_REVIEW_REMEDIATION_SPEC_v0.1.md`
- `specs/AI_USAGE_GOVERNANCE_ROADMAP_v0.2.md`
- `specs/ADR-002-gateway-config-delivery.md`
- `specs/DATA_CLASS_ENFORCEMENT_v0.1.md`
- `specs/DATA_CLASS_ENFORCEMENT_IMPLEMENTATION_SPEC_v0.1.md`
- `modules/gateway-observability-azure/main.tf`
- `modules/gateway-service-azure/main.tf`
- `modules/gateway-service-azure/variables.tf`
- `envs/azure-eastus2/main.tf`
- `STATE.md`

## Phase 1: CI

Add `.github/workflows/terraform.yml`.

It must run:

- `terraform fmt -check -recursive`
- `terraform -chdir=envs/azure-eastus2 init -backend=false`
- `terraform -chdir=envs/azure-eastus2 validate`

Do not add cloud credentials, plans requiring remote state, or applies.

## Phase 2: Alerts

Fix `modules/gateway-observability-azure/main.tf`.

- Remove or replace the inert `Requests > 1000000` placeholder.
- Add at least one realistic Container Apps page alert.
- Add at least one realistic Postgres/ledger page alert.
- Keep Teams action group optional.
- Document alert classes deferred until Stage 1 baselines exist.

Run `terraform fmt` and `terraform validate`.

## Phase 3: Health Probes

Fix `modules/gateway-service-azure/main.tf`.

- Add `startup_probe`, `readiness_probe`, and `liveness_probe` to the LiteLLM container.
- Prefer `/health/liveliness` on port `4000` unless the local config or LiteLLM docs in repo indicate a better endpoint.
- Use tolerant startup settings and normal readiness/liveness intervals.

Run `terraform fmt` and `terraform validate`.

## Phase 4: Data-Class Enforcement

Complete the data-class implementation if not already present.

Expected artifacts:

- `config/model-approval-registry.example.yaml`
- `scripts/Get-ModelAllowlist.ps1`
- updated `scripts/provision-desktop-keys.ps1`
- config comments tying LiteLLM public model names to the registry

Verify:

- default/internal allowlist behavior
- regulated allowlist behavior
- invalid class failure
- provisioning dry run emits `metadata.data_class`

If no live gateway and excluded model are available, mark live TC-REG-03 skipped with that prerequisite.

## Phase 5: State And Secrets

Resolve Redis state posture and state-backend evidence.

Preferred:

- Put Redis password in Key Vault and pass a secret ID into `gateway-service-azure`.

Acceptable POC alternative:

- Correct the misleading comment that says no literal secret values enter state.

Also add `specs/STATE_BACKEND_ACCESS_CONFIRMATION_v0.1.md` with the state sensitivity, encryption, Entra auth, and access-control confirmation fields.

## Phase 6: Fallback Decision

Either implement a second backend and fallback chain, or explicitly descope fallback from the POC.

If descoping:

- Update POC exit criteria or state docs so fallback measurement is not silently required.
- Add owner/date for the second backend prerequisite.

If implementing:

- Keep credentials out of Terraform variables/source.
- Add cloud-specific data-class approval for the fallback model.
- Validate Terraform.

## Phase 7: DNS And Roadmap Hygiene

Resolve the remaining hygiene findings:

- Decide internal DNS ownership and encode it or document owner/date.
- Use canonical `specs/ROADMAP.md` for the team roadmap; update all references.
- Update `STATE.md` `Last updated` and stale status text.

## Verification Required In Final Response

Report:

- Files changed.
- Which findings are closed by code.
- Which findings are closed by explicit descope/documentation.
- Commands run and results.
- Live TC-REG-03 status.
- Any remaining external prerequisite, such as Azure apply, GitHub Actions server-side run, DNS zone ownership, or second-provider access.
