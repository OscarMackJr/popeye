# Popeye Implementation Review Remediation Spec

Version: 0.1
Status: Draft
Audience: popeye implementation agents, reviewers, POC lead
Primary post-read action: execute the phased prompt in `POPEYE_IMPLEMENTATION_REVIEW_REMEDIATION_PROMPT_v0.1.md`.
Source review: `POPEYE_IMPLEMENTATION_REVIEW_v0.1.md`

## 1. Objective

Close every finding in `POPEYE_IMPLEMENTATION_REVIEW_v0.1.md` with implementation work that can be assigned to an agent and reviewed through local or CI verification.

The highest-priority outcome is operational defensibility for infrastructure that is already live:

- Pull requests get a basic Terraform gate before review.
- At least one deployed alert can actually fire.
- Container Apps uses health probes for startup, readiness, and liveness.
- Data-class enforcement has a repository-local implementation path.

The secondary outcome is reducing review ambiguity: places where the repo currently implies a stronger posture than it implements must either be fixed or documented plainly.

## 2. Finding Coverage Matrix

| Finding | Required resolution | POC blocking |
| --- | --- | --- |
| P1 no CI | Add GitHub Actions workflow for Terraform format and validation. | Yes |
| P2 inert alert | Replace the impossible placeholder alert with one or more alerts that can fire now; record deferred baseline-dependent classes. | Yes |
| P3 no Container App probes | Add startup, readiness, and liveness probes to the LiteLLM container. | Yes |
| P4 no data-class enforcement | Land and implement source-controlled model approval registry and derived key allowlists. | Yes |
| S1 Redis key state/comment mismatch | Either move Redis password to Key Vault reference or correct the module comment to state the actual state exposure. | No |
| S2 no fallback chain | Add a second backend plus fallback chain, or amend POC exit criteria and baseline expectations to state single-provider limitation. | No, if explicitly descoped |
| S3 internal DNS TODO | Decide and encode private DNS ownership path or create a tracked follow-up with owner/date. | No |
| S4 roadmap filename divergence | Use canonical `specs/ROADMAP.md` and update references. | No |
| S5 stale `STATE.md` date | Update the timestamp and any stale status text. | No |
| S6 state holds generated secrets | Add a recorded state-backend access-control confirmation artifact. | No |

## 3. Phase 1: CI Gate

Add `.github/workflows/terraform.yml`.

Minimum workflow:

- Run on pull requests and pushes to `main`.
- Check out the repo.
- Install or use Terraform.
- Run `terraform fmt -check -recursive`.
- Run `terraform -chdir=envs/azure-eastus2 init -backend=false`.
- Run `terraform -chdir=envs/azure-eastus2 validate`.
- Optionally validate stub roots only when they have complete provider/module definitions.

No cloud credentials are required for this phase. Do not add secrets or service principals to GitHub.

Acceptance criteria:

- Workflow YAML exists under `.github/workflows/`.
- Local equivalent commands pass.
- The workflow does not run `terraform apply`.
- The workflow does not require Azure credentials.

## 4. Phase 2: Actionable Alerting Baseline

Replace the inert `Requests > 1000000` placeholder in `modules/gateway-observability-azure/main.tf`.

Minimum acceptable implementation:

- Add a Container Apps alert that pages on failed requests or replica unavailability using a threshold that can realistically fire in the POC environment.
- Add a Postgres availability or failed connection alert using collected metrics.
- Keep Teams action group wiring optional through the existing `teams_webhook_url` behavior.
- Remove comments that imply full SLO burn-rate coverage already exists.
- Add comments naming alert classes deferred until `specs/STAGE1_BASELINES.md` supplies measured thresholds.

Design constraints:

- Do not invent tight production SLO thresholds before baselines exist.
- Do not keep dead placeholder alerts that look operational.
- Prefer metric alerts over log alerts for this phase unless the metric namespace lacks the necessary signal.

Acceptance criteria:

- At least one severity-1 gateway alert can fire under plausible POC failure conditions.
- At least one ledger/Postgres alert can fire under plausible POC failure conditions.
- Deferred alert classes are documented as gaps, not represented by inert resources.
- `terraform fmt` and `terraform validate` pass.

## 5. Phase 3: Container Health Probes

Update `modules/gateway-service-azure/main.tf` inside the LiteLLM `container` block.

Required probes:

- `startup_probe` to allow slow config load and initial database/Redis connection.
- `readiness_probe` so traffic is not routed until LiteLLM is ready.
- `liveness_probe` so unhealthy replicas are restarted.

Probe target:

- Prefer LiteLLM's documented health endpoint currently used by runbooks, `/health/liveliness`, on port `4000`.
- If the deployed LiteLLM image exposes a better readiness endpoint, use it and record the reason in a comment.

Acceptance criteria:

- Container App has startup, readiness, and liveness probes.
- Probe timings are tolerant enough for cold starts but strict enough to avoid routing to broken replicas.
- `terraform fmt` and `terraform validate` pass.

## 6. Phase 4: Data-Class Enforcement

Implement or complete the work specified by:

- `DATA_CLASS_ENFORCEMENT_v0.1.md`
- `DATA_CLASS_ENFORCEMENT_IMPLEMENTATION_SPEC_v0.1.md`

Minimum expected repo state:

- `config/model-approval-registry.example.yaml` defines ordered data classes, cloud-specific model approvals, and team defaults.
- `scripts/Get-ModelAllowlist.ps1` derives model allowlists from the registry.
- `scripts/provision-desktop-keys.ps1` uses the derivation script and emits `metadata.data_class`.
- Gateway config comments identify the registry as the model approval source.
- Local dry-run verification proves default/internal/regulated behavior and invalid-class rejection.

Acceptance criteria:

- Manual `models = @("...")` key allowlists are removed from provisioning paths.
- Key payload dry runs include `metadata.data_class`, `metadata.allowlist_source`, and `metadata.allowlist_cloud`.
- A regulated class receives only regulated-approved models from the registry.
- Live TC-REG-03 is either captured or explicitly skipped with the missing prerequisite named.

## 7. Phase 5: Secret-State Posture

Resolve S1 and S6 together.

For S1, choose one of two approaches:

1. Preferred: store the Redis password in Key Vault from the env root and pass a `redis_password_secret_id` into `modules/gateway-service-azure`, mirroring master key, salt key, and database URL.
2. Acceptable POC alternative: correct the misleading comment above Container Apps secrets to state that Redis password and LiteLLM config are literal Container Apps secret values in Terraform state, while the other gateway secrets are Key Vault references.

For S6, add a short source-controlled confirmation artifact.

Recommended file:

`specs/STATE_BACKEND_ACCESS_CONFIRMATION_v0.1.md`

Minimum contents:

- State backend storage account/container name or stable reference.
- Confirmation that encryption at rest is enabled.
- Access model: Entra authentication, named groups or roles with state read/write.
- Statement that Terraform state contains generated secrets and must be treated as sensitive.
- Date and owner placeholder if exact names cannot be committed.

Acceptance criteria:

- The Redis state posture no longer contradicts nearby comments.
- State sensitivity is recorded in the repo.
- No provider API keys are committed.
- `terraform validate` passes if Terraform changed.

## 8. Phase 6: Fallback Chain Decision

Resolve S2 by either implementing fallback or explicitly descoping it.

Preferred implementation path:

- Add a second backend variable set for Bedrock or another approved model provider.
- Add an explicit `router_settings.fallbacks` entry for a named model group.
- Keep cross-cloud fallback limited to model groups marked safe by owners.
- Ensure data-class approvals include the fallback model separately for its cloud.

Acceptable POC descope path:

- Update `POPEYE_STAGE1_KICKOFF_v0.1.md`, `ROADMAP.md` or its renamed equivalent, and `STATE.md` to state that the POC is single-provider.
- Preserve fallback measurement as skipped with a prerequisite, not silently complete.
- Add a follow-up item naming the required second backend owner.

Acceptance criteria:

- Reviewers can tell whether fallback is implemented or intentionally descoped.
- POC exit criteria no longer require an impossible fallback demonstration.
- If implemented, `terraform validate` passes and no provider credentials enter source control.

## 9. Phase 7: DNS And Roadmap Hygiene

Resolve S3, S4, and S5.

S3 internal DNS:

- Decide whether this stack owns `ai.twg.internal` or consumes a centrally owned private DNS zone.
- If this stack owns it, add Terraform resources to create/link the private zone and record `gateway-azure.ai.twg.internal`.
- If central networking owns it, add variables/data sources or a documented TODO with owner and decision date.

S4 roadmap filename:

- Use canonical `specs/ROADMAP.md` for the team roadmap.
- Update references in `README.md`, `specs/README.md`, `STATE.md`, and other specs.
- If not renaming, add an explicit exception note citing the external convention conflict.

S5 state timestamp:

- Update `STATE.md` `Last updated` to the date of the remediation change.
- Adjust any stale wording discovered while editing references.

Acceptance criteria:

- No repo references point to a missing roadmap filename.
- `STATE.md` date reflects the current remediation.
- DNS ownership is either encoded or tracked with owner/date.

## 10. Verification Summary Required

The implementation agent must finish with a verification summary covering:

- CI workflow local command equivalents.
- Terraform format and validation results.
- PowerShell syntax and dry-run results for data-class enforcement.
- Whether live TC-REG-03 was run or skipped.
- Whether fallback was implemented or descoped.
- Any Azure metrics that could not be validated without a live plan/apply.

Do not claim a finding is closed unless there is either code/config evidence or an explicit documented descope accepted by this spec.
