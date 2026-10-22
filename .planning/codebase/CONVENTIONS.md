# Coding Conventions

**Analysis Date:** 2026-10-22

Repo is infrastructure/governance: Terraform (Azure), PowerShell scripts, one Python script, YAML/JSON config, SQL, and markdown specs. No application source tree, no `.claude/skills` or `.agents/skills`.

## Naming Patterns

**Files:**
- PowerShell scripts: Verb-Noun PascalCase `.ps1` in `scripts/` (`scripts/Get-ModelAllowlist.ps1`, `scripts/Read-EndpointDetections.ps1`, `scripts/Test-PopeyeVerificationVm.ps1`). Older ones are kebab-case (`scripts/provision-desktop-keys.ps1`, `scripts/intune-baseurl-profile.ps1`); use Verb-Noun for new scripts.
- Python: `scripts/Test-SessionCredentialFixtures.py` (same Verb-Noun style as scripts).
- Terraform modules: `modules/<name>-azure/{main,variables,outputs}.tf`; env roots in `envs/<cloud>-<region>/` (`main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, `backend.tf`, `terraform.tfvars.example`).
- Config examples: `*.example.yaml`; schemas `*.schema.json`; versioned contract schemas `<name>-v0.1.schema.json` in `contracts/schemas/`.
- Specs: `UPPER_SNAKE_CASE_v0.N.md` in `specs/` (version suffix required; bump on revision).
- Fixtures: `valid-*.json` / `invalid-<reason>.json` in `contracts/fixtures/<contract>/`.

**Functions (PowerShell):** approved-verb PascalCase (`Test-Rfc1918Address`, `Add-Result`, `Test-EndpointDetectionEvent`).

**Variables:** PowerShell camelCase locals (`$results`, `$tenantIdPattern`), PascalCase params (`$PostgresFqdn`). Terraform and Python use snake_case (`postgres_server_name`, `FIXTURE_DIR` for constants).

**Requirement IDs:** error messages and test names carry a requirement tag, e.g. `REQ-DCE-05/06/07` (data class enforcement), `REQ-CRED-01` (credential issuance). Keep tags in thrown messages; CI matches on them.

## Code Style

**Formatting:**
- Terraform: `terraform fmt -check -recursive` enforced in `.github/workflows/terraform.yml`. Run `terraform fmt -recursive` before commit.
- PowerShell: 2-space indent, no formatter configured. Python: 4-space, type hints on `main() -> int`.
- No `.editorconfig`, Prettier, or linters (PSScriptAnalyzer/ruff) configured.

**Linting:** None beyond `terraform validate`.

## Script Preamble (PowerShell)

Every script starts with comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.EXAMPLE`/`.NOTES`), then `[CmdletBinding()]` (optional) and `param(...)`, then:

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
```

Parameters: `[Parameter(Mandatory)]` for required, trailing `# comment` for example values, `[switch] $DryRun` for side-effect-free runs, default paths via `Join-Path $PSScriptRoot "..\config\..."`.

## Import Organization

Python (`scripts/Test-SessionCredentialFixtures.py`): stdlib (`json`, `pathlib`, `sys`) first, blank line, third-party (`jsonschema`). Paths derived from `ROOT = Path(__file__).resolve().parent.parent`. No aliases.

## Error Handling

- PowerShell: fail fast with `throw "REQ-XXX-NN: <message>"`; strict mode + `Stop`. Validation happens up front, before side effects.
- Check scripts collect results into `System.Collections.Generic.List[object]` of `[pscustomobject]@{Check; Status = PASS|FAIL; Detail}` via `Add-Result` (`scripts/Test-PopeyeVerificationVm.ps1`) and wrap each check in `try/catch`.
- Python: accumulate `failures` list, print `FAIL:` to stderr, return exit code 1; entry via `raise SystemExit(main())`.
- Negative paths are tested by expecting a thrown message (see TESTING.md).

## Logging

`Write-Host`/`print` with `PASS:`/`FAIL:` prefixes. No logging framework. Never print secrets, DSNs, or master keys; secrets resolve at runtime from Key Vault (`-MasterKeySecretUri`). Endpoint detection schema is intentionally content-free (no prompts/bodies).

## Comments

- Header block comments on each Terraform module stating design rules and citing spec sections (`# Design rules carried from AI_USAGE_GOVERNANCE_ROADMAP_v0.2.md`).
- Reference specs by section ("infrastructure plan section 4").
- Deferred work uses `TODO(stage-N): ...` (e.g. `TODO(stage-3)` in `scripts/provision-desktop-keys.ps1`).
- Use `.invalid` TLD and zero UUIDs for example data (`example.invalid`).

## Terraform Conventions

- Variables have `description`, `type`; secrets `sensitive = true` and "never a literal" in description (`modules/gateway-state-azure/variables.tf`).
- Pin `required_version >= 1.7.0`, `azurerm ~> 4.0` in `envs/azure-eastus2/versions.tf`; lock file `.terraform.lock.hcl` committed.
- Private networking by default (`public_network_access_enabled = false`); resources take `tags = var.tags`.
- `terraform.tfvars.example` committed; real tfvars and state are not.

## Function Design

Small single-purpose helper functions defined above main flow; main logic top-level in script. Return values: PowerShell returns objects/booleans; Python `main()` returns int exit code.

## Module Design

Terraform modules expose inputs via `variables.tf`, outputs via `outputs.tf`; one module per tier (`breakglass-azure`, `gateway-observability-azure`, `gateway-service-azure`, `gateway-state-azure`).

---

*Convention analysis: 2026-10-22*
