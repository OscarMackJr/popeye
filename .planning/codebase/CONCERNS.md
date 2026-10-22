# Codebase Concerns

**Analysis Date:** 2026-10-22

Repository is a Terraform + PowerShell + spec repo (no application code). Concerns focus on infrastructure, scripts, and spec/implementation drift.

## Tech Debt

**Stage 3 automation scripts are skeletons:**
- Issue: Graph/gateway calls are TODO stubs; `$members = @()` means no keys are ever provisioned.
- Files: `scripts/provision-desktop-keys.ps1` (lines ~41-94), `scripts/intune-baseurl-profile.ps1`
- Impact: Fleet rollout, key issuance, and leaver revocation do not function.
- Fix approach: Implement `Connect-MgGraph -Identity`, `Get-MgGroupMember`, `/key/generate` call, key-to-user mapping, and revocation pass; add tests.

**Unresolved Stage 2 networking:**
- Issue: No app-VNet peering; private DNS zone `ai.twg.internal` ownership undecided (decision was due 2026-08-15, now past).
- Files: `envs/azure-eastus2/main.tf` (TODO at ~59 and ~260), `STATE.md`
- Impact: Gateway only reachable via auto-generated Container Apps internal FQDN; no stable `gateway-azure.ai.twg.internal`; the current workstation cannot resolve it.
- Fix approach: Record the decision, add variables/data sources for the zone, add peering.

**Stub environments:**
- Files: `envs/aws-use1/main.tf`, `envs/aws-use1/README.md`, `envs/reporting/README.md`, `modules/reporting-store/README.md`
- Impact: Second region, fallback chains, and reporting are requirements only; fallback config remains comments in `config/litellm.azure.example.yaml`.

**Alerting is placeholder-grade:**
- Files: `modules/gateway-observability-azure/main.tf`
- Issue: Only 5xx, low replicas, and Postgres availability alerts; burn-rate/budget/fallback/attribution alerts await `specs/STAGE1_BASELINES.md` (file does not exist yet).

**Config delivered as Terraform-rendered Container Apps secret (ADR-002):**
- Files: `modules/gateway-service-azure/main.tf` (container `args` writes `$LITELLM_CONFIG` to `/tmp/litellm.yaml`), `specs/ADR-002-gateway-config-delivery.md`
- Impact: Config changes require a Terraform apply and new revision; size and audit limits flagged for revisit before production.

## Known Bugs / Open Verification

**No end-to-end proof of attributed traffic:**
- Symptoms: Smoke completion through `twg-foundry` and ledger-row confirmation not yet done; `az containerapp exec` does not accept non-interactive commands.
- Files: `STATE.md` (Next Task), `scripts/Test-PopeyeAzureVerificationVm.ps1`, `scripts/Test-PopeyeVerificationVm.ps1`, `scripts/Test-PopeyeVerificationPsql.ps1`
- Workaround: In-VNet verification VM scripts (see `specs/POPEYE_VERIFICATION_VM_TEST_PROCEDURE.md`).

**Stage 1 baselines and DLP evaluation missing:**
- `specs/STAGE1_BASELINES.md` absent; content guardrail/DLP has no implementation or baseline; SLOs remain provisional.

## Security Considerations

**Redis public network access defaults to Enabled:**
- Risk: Managed Redis (budget counters) may be reachable publicly.
- Files: `modules/gateway-state-azure/variables.tf` (`managed_redis_public_network_access`, default `"Enabled"`), `modules/gateway-state-azure/main.tf:59`
- Mitigation: Access keys required. Recommendation: add private endpoint and default to `Disabled`.

**Break-glass granted to the signed-in POC principal:**
- Files: `modules/breakglass-azure/main.tf` (~line 45, `approvers_principal_id` fallback), `STATE.md`
- Risk: No approver group or PIM; single human identity holds break-glass access. Must be replaced before MVP exit.

**Deployer holds secrets officer on gateway vault; secrets live in Terraform state:**
- Files: `envs/azure-eastus2/main.tf` (~135, ~160-180), `envs/azure-eastus2/backend.tf`
- Risk: Master key, salt key, and DB URL (with Postgres admin password) are in state. Mitigation: Entra-auth Azure Storage backend. Recommendation: confirm state storage network restrictions, versioning, and soft delete; see `specs/STATE_BACKEND_ACCESS_CONFIRMATION_v0.1.md`.

**Sensitive identifiers in untracked artifacts:**
- Files: `artifacts/popeye-azure-verification-evidence.json` (subscription ID, resource IDs, FQDNs), `scripts/Test-PopeyeAzureVerificationVm.zip` (binary duplicate of the script, committed-risk)
- Risk: Untracked and not in `.gitignore`; may be committed accidentally. Recommendation: decide whether evidence is committed (scrubbed) or ignored; do not commit the `.zip`.

**Local `terraform.tfvars` and `.terraform/` present:**
- Files: `envs/azure-eastus2/terraform.tfvars` (git-ignored via `*.tfvars`), `envs/azure-eastus2/.terraform/`. Keep ignored; never commit.

**Postgres DSN passed on command line:**
- Files: `scripts/Test-PopeyeVerificationPsql.ps1`, `scripts/Test-PopeyeVerificationVm.ps1` (`--dbname=$Dsn`, `--no-password`)
- Risk: DSN may be visible in process listings or transcripts if it embeds credentials. Prefer Entra token or `PGPASSFILE`/`PGPASSWORD` from Key Vault.

**Container image from public GHCR:**
- Files: `modules/gateway-service-azure/main.tf:120` (`ghcr.io/berriai/litellm:${var.litellm_image_tag}`)
- Risk: Tag-pinned, not digest-pinned; supply-chain exposure. Recommendation: pin by digest or mirror into ACR.

## Performance Bottlenecks

**Not measured:**
- Latency overhead, budget counter lag, ledger freshness are unmeasured (Stage 1 protocol pending). Gateway runs min 2 replicas with a shell-wrapped `printf` startup; no load data exists.

## Fragile Areas

**Applied-resource naming and lifecycle guards:**
- Files: `envs/azure-eastus2/variables.tf`, `envs/azure-eastus2/main.tf`
- Why fragile: `name_prefix` (`popeye-`) change forces replacement; salt key rotation invalidates stored provider credentials; `prevent_destroy` on Postgres/salt key blocks teardown; break-glass `ignore_changes` hides drift (`modules/breakglass-azure/main.tf:23,76`).
- Safe modification: Run plan first; treat guard overrides as incident-class (see `STATE.md` Guardrails).

**Spec/documentation sprawl and versioning drift:**
- Files: `specs/POPEYE_v0.4.md`, `v0.4.1`, `v0.4.2`, `v0.4.3`, `specs/POPEYE_CORRECTIONS_v0.3.md`, `specs/FISKROAD_NETWORK_ENGINEER_GUIDE_v0.2.md`/`v0.3.md`
- Why fragile: Multiple overlapping versions with unclear supersession; `STATE.md` (last updated 2026-08-02) does not reference the newer endpoint-detection, session-credential, and verification-VM work. Update `STATE.md` and `specs/README.md` to name authoritative versions.

**Large uncommitted working tree:**
- Most new specs, scripts, `contracts/`, and `config/` additions are untracked; modified `scripts/Get-ModelAllowlist.ps1`, `scripts/provision-desktop-keys.ps1`, `config/model-approval-registry.example.yaml` are unreviewed. Risk of lost work; commit in reviewed slices.

## Scaling Limits

- Single region (eastus2), single Postgres ledger, no failover region or fallback backend. Capacity not characterized.

## Dependencies at Risk

**Azure Cache for Redis retirement:** Replaced with Azure Managed Redis (`modules/gateway-state-azure/main.tf`); newer resource, private endpoint support not yet in module.

**LiteLLM:** Upstream proxy pinned by tag in `envs/azure-eastus2/terraform.tfvars.example`; upgrades untested; no vulnerability scanning in CI.

**Vendored vocabulary:** `config/vendored/vocabulary.yaml` (see `config/vendored/VENDORED.md`) can drift from its upstream source with no automated sync check.

## Missing Critical Features

- Session credential issuer (`specs/SESSION_CREDENTIAL_ISSUER_v0.1.md`): only request schema and fixtures exist (`contracts/schemas/session-credential-issuance-request-v0.1.schema.json`); no issuer implementation.
- Endpoint detection ingestion (`scripts/Read-EndpointDetections.ps1`, `config/endpoint-detection.schema.json`): reader only; no pipeline into the ledger.
- Content guardrails/DLP, named runbook owners, rehearsed runbooks, break-glass approver group.

## Test Coverage Gaps

**Terraform has no tests or plan checks:**
- Files: `.github/workflows/terraform.yml` runs only `fmt -check`, `init -backend=false`, `validate`.
- Risk: No `terraform plan`, tflint, tfsec/checkov, or policy checks; drift and insecure defaults (Redis public access) go undetected. Priority: High.

**PowerShell scripts untested:**
- Files: `scripts/Get-ModelAllowlist.ps1` (213 lines, registry parsing), `scripts/Read-EndpointDetections.ps1`, `scripts/Test-PopeyeVerificationVm.ps1`. No Pester tests or PSScriptAnalyzer in CI. Priority: Medium.

**Registry conformance CI is narrow:**
- Files: `.github/workflows/registry-conformance.yml` (untracked) validates only session-credential request fixtures via `scripts/Test-SessionCredentialFixtures.py`; `config/fixtures/bad-registry.yaml` and `detections.sample.jsonl` are not covered by the visible workflow. Priority: Medium.

---

*Concerns audit: 2026-10-22*
