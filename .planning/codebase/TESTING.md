# Testing Patterns

**Analysis Date:** 2026-10-22

No unit-test framework (Pester, pytest, terratest) is present. Verification is done by fixture-driven check scripts run in GitHub Actions, plus operator-run acceptance scripts for the Azure environment.

## Test Framework

**Runner:**
- Plain scripts with exit codes / thrown errors, executed by CI steps.
- Python 3.12 + `jsonschema==4.26.0` (pinned in `.github/workflows/registry-conformance.yml`).
- PowerShell (`pwsh`) on `ubuntu-latest`.
- Terraform `fmt` + `validate` (`.github/workflows/terraform.yml`).

**Assertion Library:** None. Manual comparison with `throw` (PowerShell) and `failures` list (Python).

**Run Commands:**
```bash
python scripts/Test-SessionCredentialFixtures.py            # REQ-CRED-01 schema fixtures
pwsh ./scripts/Read-EndpointDetections.ps1 -Path config/fixtures/detections.sample.jsonl
pwsh ./scripts/Get-ModelAllowlist.ps1 -RegistryPath config/model-approval-registry.example.yaml -Cloud azure -TeamId desktop-agents
terraform fmt -check -recursive
terraform -chdir=envs/azure-eastus2 init -backend=false && terraform -chdir=envs/azure-eastus2 validate
```
Coverage: not measured.

## Test File Organization

**Location:** Fixtures live beside the contract they exercise, not co-located with scripts.
- `contracts/schemas/*.schema.json` + `contracts/fixtures/session-credential-issuance/` (`valid-request.json`, `invalid-*.json`, `issuer-runtime-cases.json`)
- `config/endpoint-detection.schema.json` + `config/fixtures/detections.sample.jsonl`
- `config/fixtures/bad-registry.yaml` (must be rejected with `REQ-DCE-06`)
- `config/vendored/vocabulary.yaml` (vendored shared vocabulary; see `config/vendored/VENDORED.md`)

**Naming:** Check scripts are `Test-*.ps1` / `Test-*.py` in `scripts/`. Fixtures: `valid-*`, `invalid-<what>`, `bad-*`, `*.sample.*`.

## Test Structure

Table-driven cases keyed by a requirement-tagged name (`scripts/Test-SessionCredentialFixtures.py`):

```python
SCHEMA_CASES = {
    "REQ-CRED-01 rejects a request without agent_id": ("invalid-missing-agent-id.json", False),
}
for name, (filename, expected_valid) in SCHEMA_CASES.items():
    errors = list(validator.iter_errors(load_json(FIXTURE_DIR / filename)))
    if (not errors) != expected_valid: failures.append(...)
    else: print(f"PASS: {name}")
```

Add a new case by dropping a fixture JSON and adding one dict entry. `issuer-runtime-cases.json` holds shape-valid cases retained for a future issuer implementation (JSON Schema cannot check them).

## Negative-Path Pattern (PowerShell in CI)

Run the script expecting failure; re-throw if it unexpectedly passes; assert the message contains the requirement ID:

```powershell
try {
  ./scripts/Get-ModelAllowlist.ps1 -RegistryPath config/fixtures/bad-registry.yaml -Cloud azure -TeamId desktop-agents | Out-Null
  throw 'Bad registry unexpectedly passed validation.'
}
catch {
  if ($_.Exception.Message -eq 'Bad registry unexpectedly passed validation.') { throw }
  if ($_.Exception.Message -notmatch 'REQ-DCE-06') { throw }
}
```
Also used for `scripts/provision-desktop-keys.ps1 -DryRun` with a bad `-TenantId` (`REQ-DCE-07`) and invalid endpoint detection JSONL.

## Mocking

No mocking framework. Isolation is via `-DryRun` switches (`scripts/provision-desktop-keys.ps1` synthesizes a dry-run member), `.invalid` hostnames, and zero UUIDs. Do not call real Graph/Azure/gateway in CI.

## Fixtures and Factories

Static files only; generated bad inputs are written inline to `$env:RUNNER_TEMP` in the workflow. Keep fixtures free of real identities, secrets, and prompt content.

## Conformance Checks (CI)

`.github/workflows/registry-conformance.yml` (triggers: pull_request, push to main; `permissions: contents: read`):
- Job `session-credential-schema`: REQ-CRED-01 fixture validation.
- Job `registry-conformance`: vocabulary vs registry class order (REQ-DCE-05), unapprovable `regulated-identifier` (REQ-DCE-06), bad registry rejection, endpoint detection fixture valid/invalid, tenant ID validation (REQ-DCE-07).

`.github/workflows/terraform.yml`: fmt check, init without backend, validate for `envs/azure-eastus2` only (`envs/aws-use1` and `envs/reporting` are not validated).

## Environment Acceptance Scripts (manual, not CI)

Run on the Azure verification VM or by an operator: `scripts/Test-PopeyeVerificationVm.ps1` (DNS resolves to RFC1918, TCP 5432 reachable, optional psql auth), `scripts/Test-PopeyeVerificationPsql.ps1`, `scripts/Test-PopeyeAzureVerificationVm.ps1` (packaged as `.zip`). Procedure: `specs/POPEYE_VERIFICATION_VM_TEST_PROCEDURE.md`, `specs/POPEYE_NETWORK_VERIFICATION_PRIMER.md`. Output is a PASS/FAIL result table. Azure-side controls (Bastion RBAC, NSG, subnet delegation) are verified by procedure, not script.

## Gaps and Guidance

- No tests for `scripts/intune-baseurl-profile.ps1`, Terraform module behavior, or `sql/ai_usage_grants.sql`.
- Vocabulary check in CI parses YAML with line regex and slices `[0..4]`; adding classes requires updating that step.
- New scripts: add a fixture + a negative-path CI step with a `REQ-` tagged error. Prefer adding Pester only if introducing it repo-wide.

---

*Testing analysis: 2026-10-22*
