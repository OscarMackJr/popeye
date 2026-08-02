# Data-Class Enforcement Implementation Spec

Version: 0.1
Status: Draft
Audience: popeye implementation agents and reviewers
Primary post-read action: implement the phased prompt in `DATA_CLASS_ENFORCEMENT_IMPLEMENTATION_PROMPT_v0.1.md`.
Source requirement: `DATA_CLASS_ENFORCEMENT_v0.1.md`

## 1. Objective

Implement data-class-derived model allowlists without moving semantic classification into popeye.

Popeye must continue to treat data class as caller/key metadata. It does not inspect prompts, classify content, or infer business meaning. It enforces this invariant:

> A virtual key can call only models whose approved maximum data class is greater than or equal to the key's declared `data_class`.

The allowlist written to LiteLLM keys is generated from source-controlled policy inputs. Operators must not hand-maintain per-key model arrays except through the generator path.

## 2. Current State

Relevant repo surfaces:

- `envs/azure-eastus2/main.tf` renders the regional LiteLLM YAML as `local.litellm_config_yaml` and currently exposes one public model, `twg-foundry`.
- `envs/azure-eastus2/variables.tf` has one Foundry deployment configuration path.
- `config/litellm.azure.example.yaml` documents the rendered config shape.
- `scripts/provision-desktop-keys.ps1` calls LiteLLM `/key/generate` conceptually and currently hard-codes `models = @("twg-foundry")`.

LiteLLM key generation supports both a key-level `models` array and arbitrary `metadata`, so `data_class` can be stored as key metadata while the derived model list is passed as the key allowlist. See LiteLLM key management docs: https://www.mintlify.com/BerriAI/litellm/api/proxy/keys

## 3. Data-Class Vocabulary

Use an ordered, explicit vocabulary in source control:

1. `public`
2. `internal`
3. `confidential`
4. `regulated`

Higher classes may handle lower-class workloads. Lower classes must not handle higher-class workloads.

Default behavior:

- Missing team default: `internal`
- Missing key override: inherit team default
- Missing both after validation/generation: `internal`
- Unknown data class: hard validation failure

This default preserves deny-by-default behavior from the requirement draft: a key with no declared class does not gain broad access.

## 4. Configuration Contract

Add a source-controlled approval registry that is cloud-specific and model-specific.

Recommended file:

`config/model-approval-registry.example.yaml`

Minimum schema:

```yaml
data_classes:
  - public
  - internal
  - confidential
  - regulated

models:
  - public_name: twg-foundry
    cloud: azure
    provider: foundry
    deployment_var: foundry_deployment_name
    approved_max_data_class: internal
    owner: platform
    rationale: "Stage 2 pilot Foundry deployment; synthetic/internal data only."

teams:
  - team_id: desktop-agents
    default_data_class: internal
```

Rules:

- `public_name + cloud` must be unique.
- `approved_max_data_class` must be one of `data_classes`.
- `teams[*].default_data_class` must be one of `data_classes`.
- No provider API keys or secrets in this registry.
- A model approval in Azure does not imply approval for AWS, even when the marketing model family is the same.

The example registry should be usable by tests and local dry runs. Filled production registries may be environment-specific, but they must be source-controlled or generated from a reviewed source-controlled artifact.

## 5. Allowlist Derivation

Add a small derivation tool rather than embedding class-order logic in multiple scripts.

Recommended file:

`scripts/Get-ModelAllowlist.ps1`

Inputs:

- `-RegistryPath`
- `-Cloud`
- `-TeamId`
- optional `-DataClass`

Behavior:

1. Load the registry with a structured YAML parser where available.
2. Resolve effective key class:
   - explicit `-DataClass`, if provided
   - otherwise team default for `-TeamId`
   - otherwise `internal`
3. Select all registry models for `-Cloud` where `rank(approved_max_data_class) >= rank(effective_data_class)`.
4. Emit compact JSON:

```json
{
  "team_id": "desktop-agents",
  "data_class": "internal",
  "cloud": "azure",
  "models": ["twg-foundry"],
  "registry_path": "config/model-approval-registry.example.yaml"
}
```

Failure modes:

- Unknown data class: non-zero exit.
- Unknown team: allowed only if no explicit team registry is required; default class becomes `internal`.
- Empty derived model set: non-zero exit. A generated empty allowlist should not silently create an unusable key.
- Invalid registry shape: non-zero exit with a message naming the bad field.

## 6. Key Issuance Contract

Modify key provisioning scripts so generated LiteLLM payloads include:

```json
{
  "user_id": "<identity>",
  "team_id": "<team>",
  "max_budget": 25.0,
  "budget_duration": "30d",
  "models": ["<derived model names>"],
  "metadata": {
    "data_class": "<effective class>",
    "allowlist_source": "<registry file or commit-relative path>",
    "allowlist_cloud": "<cloud>"
  }
}
```

For application key onboarding, use the same derivation path. If a separate app-key script is added later, it must call the shared derivation tool instead of copying the ranking logic.

Manual `models = @(...)` assignments in key issuance code are defects unless they appear inside tests asserting rejection of manual bypasses.

## 7. Terraform And Gateway Config

Stage 2 can remain single-model, but Terraform must stop being the only place that knows the model name.

Required changes:

- Add a Terraform variable or local data structure representing approved model registry entries for the Azure region.
- Render `local.litellm_config_yaml` from that model list instead of a single hard-coded `twg-foundry` block.
- Preserve `store_prompts_in_spend_logs: false`.
- Keep provider credentials out of Terraform variables and rendered YAML.
- Update `config/litellm.azure.example.yaml` comments to point at the approval registry as the source of public model names and data-class approvals.

Acceptable first implementation:

- Keep only one Azure model entry, `twg-foundry`.
- Use the registry for policy derivation and leave deployment connection fields in existing Terraform variables.
- Add validation that registry entries referenced by the Azure environment use `cloud = "azure"`.

Do not add a custom request-path proxy in this phase. The enforcement mechanism is LiteLLM's existing virtual-key model allowlist.

## 8. Error And Audit Requirements

Caller-visible rejection for a disallowed model should be distinguishable from budget exhaustion and provider throttling. In this implementation, that means:

- Verification captures the actual LiteLLM response when a key for a higher data class calls a lower-approved model.
- The captured behavior is documented in the verification output.
- If LiteLLM's native response cannot provide a stable error class/header, record a follow-up requirement for an auth/policy hook or gateway product decision before production.

Audit expectations:

- Key generation payload contains `metadata.data_class`.
- Key generation payload contains enough `allowlist_source` information to identify the registry used.
- Registry changes are normal code review changes.
- Break-glass bypass remains out of scope for enforcement and must be called out in runbooks, not hidden.

## 9. Verification

Minimum automated checks:

- Registry parser rejects unknown data classes.
- `internal` key receives models approved for `internal`, `confidential`, and `regulated`, but not `public`-only if a lower-only model is ever represented.
- `regulated` key receives only `regulated`-approved models.
- Missing data class defaults to `internal`.
- Desktop key provisioning uses derived `models` and writes `metadata.data_class`.

Minimum manual or integration check:

- Generate or dry-run two key payloads:
  - `desktop-agents` with default `internal`
  - a `regulated` override
- Confirm the payloads differ only through the derived model set and metadata, not through hand-edited allowlists.

Optional live check when a gateway is available:

- Create a key with a class that excludes at least one configured model.
- Attempt a request to the excluded model.
- Capture HTTP status, response body, and headers as the evidence for TC-REG-03.

## 10. Phasing

### Phase 1: Registry And Derivation

Create the registry example, derivation tool, and tests/dry-run examples. No Terraform apply required.

### Phase 2: Key Provisioning

Wire `scripts/provision-desktop-keys.ps1` to call the derivation tool and include `metadata.data_class`. Add a dry-run mode if needed so verification does not require Graph or a live gateway.

### Phase 3: Terraform Config Source Alignment

Align Azure gateway config rendering and example YAML with the registry. Keep the deployed behavior equivalent for `twg-foundry`.

### Phase 4: Live Enforcement Evidence

When a reachable gateway and at least two differently approved model entries exist, run the TC-REG-03 live rejection test and record the evidence.

## 11. Acceptance Criteria

- `config/model-approval-registry.example.yaml` exists and expresses class order, model approvals, and team defaults.
- A shared derivation script emits the effective `data_class` and derived model list for a team/key/cloud.
- `scripts/provision-desktop-keys.ps1` no longer hard-codes the model allowlist.
- Key-generation payloads include `metadata.data_class`.
- Terraform and example config no longer make the public model list an undocumented one-off.
- Verification commands are documented and run successfully, except live gateway checks may be explicitly marked skipped when no gateway is reachable.
