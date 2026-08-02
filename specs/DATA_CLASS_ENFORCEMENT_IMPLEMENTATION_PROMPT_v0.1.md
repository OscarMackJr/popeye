# Implementation Prompt: Data-Class Enforcement

Use this prompt with an implementation agent working in the popeye repository.

## Mission

Implement data-class-derived LiteLLM model allowlists from `specs/DATA_CLASS_ENFORCEMENT_IMPLEMENTATION_SPEC_v0.1.md`, preserving popeye's semantics-blind boundary. Do not inspect prompt content, do not build a custom proxy, and do not put provider secrets into config or Terraform variables.

## Required Reading

Read these files before editing:

- `specs/DATA_CLASS_ENFORCEMENT_v0.1.md`
- `specs/DATA_CLASS_ENFORCEMENT_IMPLEMENTATION_SPEC_v0.1.md`
- `specs/ADR-002-gateway-config-delivery.md`
- `envs/azure-eastus2/main.tf`
- `envs/azure-eastus2/variables.tf`
- `config/litellm.azure.example.yaml`
- `scripts/provision-desktop-keys.ps1`

## Phase 1: Registry And Derivation

Add `config/model-approval-registry.example.yaml` with:

- ordered classes: `public`, `internal`, `confidential`, `regulated`
- at least `twg-foundry` for `cloud: azure`
- an explicit `approved_max_data_class`
- a `desktop-agents` team default

Add a shared PowerShell derivation script, preferably `scripts/Get-ModelAllowlist.ps1`, that:

- loads the registry through a structured YAML parser where available
- resolves effective data class from explicit override, team default, then `internal`
- filters models for the requested cloud by class rank
- emits compact JSON containing `team_id`, `data_class`, `cloud`, `models`, and `registry_path`
- fails non-zero for invalid classes, invalid registry shape, or an empty derived model set

Add lightweight tests or deterministic dry-run commands proving:

- unknown classes fail
- missing class defaults to `internal`
- a `regulated` request returns only regulated-approved models

## Phase 2: Key Provisioning

Update `scripts/provision-desktop-keys.ps1` so the key payload uses the shared derivation script instead of `models = @("twg-foundry")`.

The generated LiteLLM payload must include:

- `models` from the derivation result
- `metadata.data_class`
- `metadata.allowlist_source`
- `metadata.allowlist_cloud`

Add parameters as needed, for example:

- `-RegistryPath`
- `-Cloud`
- `-DataClass`
- `-DryRun`

Keep the script safe for local verification without Graph or a live gateway. A dry run that prints sanitized payloads is acceptable. Never print virtual key values.

## Phase 3: Terraform And Example Config

Align the Azure gateway config comments and Terraform locals with the registry concept.

Minimum acceptable change:

- preserve the current single `twg-foundry` deployment behavior
- document that public model names and data-class approvals come from the registry
- avoid provider credentials in Terraform variables or rendered YAML
- preserve `store_prompts_in_spend_logs: false`

If adding Terraform variables for model approval entries, validate that Azure environment entries use `cloud = "azure"` and known data classes.

## Phase 4: Verification Evidence

Run local checks:

- PowerShell parser/derivation dry runs for `desktop-agents`, explicit `internal`, explicit `regulated`, and an invalid class
- syntax check for modified PowerShell files
- `terraform fmt` and `terraform validate` for `envs/azure-eastus2` if Terraform files changed

If a live gateway is available, create a constrained key and attempt a request to an excluded model. Capture HTTP status, response body, and headers. If no live gateway or excluded model exists, mark the live TC-REG-03 check as skipped and explain the missing prerequisite.

## Guardrails

- Do not edit `specs/DATA_CLASS_ENFORCEMENT_v0.1.md` unless explicitly asked.
- Do not manually duplicate class-rank logic in multiple scripts.
- Do not add a custom request-path proxy.
- Do not log prompts, completions, provider API keys, master keys, or generated virtual key values.
- Treat break-glass as an explicit bypass that is documented, not enforced by this control.

## Done Criteria

- Registry example exists.
- Shared derivation script exists and is verified.
- Desktop key provisioning derives allowlists and writes key metadata.
- Terraform/example config point reviewers to the registry as the policy source.
- Verification results are summarized with any skipped live checks called out plainly.
