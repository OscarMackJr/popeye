# Phase 1: Network Proof, Gateway Hardening & Smoke Row - Pattern Map

**Mapped:** 2026-10-22
**Files analyzed:** 22 (9 modified, 13 new)
**Analogs found:** 20 / 22 (2 with no in-repo analog)

Honors D-18/D-19: secret-touching steps run interactively (operator `az login` in a Bastion session on EUS-VM-POPEYE), run-command only for non-secret checks. UI check is "disabled page + /login rejected + static only"; management routes must return 401/403 via explicit `allowed_routes`.

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|---|---|---|---|---|
| `modules/gateway-service-azure/main.tf` (MOD: `exec`, probes, grace, image@digest, DISABLE_ADMIN_UI/LITELLM_LOG env, outputs) | config (IaC) | request-response | itself (lines 112-207) | exact (self) |
| `modules/gateway-service-azure/variables.tf` (MOD: tag regex, digest var) | config | n/a | itself lines 14-22, 72-81 (validation blocks) | exact (self) |
| `modules/gateway-service-azure/outputs.tf` (MOD: `default_domain`, `static_ip`) | config | n/a | itself | exact (self) |
| `modules/gateway-state-azure/main.tf` (MOD: clustering policy var) | config | CRUD | itself lines 52-73 | exact (self) |
| `modules/gateway-state-azure/variables.tf` (MOD: clustering policy var; public access default) | config | n/a | itself lines 52-67 | exact (self) |
| `envs/azure-eastus2/main.tf` (MOD: PE subnet, redis zone/link/PE, reader secret, hardening YAML, conditional env DNS) | config (root) | request-response | itself lines 81-111 (subnet, zone, link), 140-193 (random_password + KV secret) | exact (self) |
| `envs/azure-eastus2/variables.tf` (MOD: digest, `manage_env_dns_zone`, `caller_vnet_id`) | config | n/a | itself lines 12-15 | exact (self) |
| `envs/azure-eastus2/litellm-pin.auto.tfvars` (NEW, committed) | config | n/a | `terraform.tfvars.example` | role-match |
| `envs/azure-eastus2/terraform.tfvars.example` (MOD: fix `-stable`) | config | n/a | itself | exact (self) |
| `.gitignore` (MOD) | config | n/a | itself lines 6-8 (`*.tfvars` / `!*.tfvars.example`) | exact (self) |
| `config/litellm.azure.example.yaml` (MOD: sync with rendered YAML) | config | n/a | `local.litellm_config_yaml` in `envs/azure-eastus2/main.tf` 17-39 | exact |
| `config/litellm-advisory-ranges.json` (NEW) | config/data | batch | `config/endpoint-detection.schema.json` / fixtures | partial |
| `scripts/Test-LitellmAdvisoryRange.py` (NEW, CI) | utility/test | transform | `scripts/Test-SessionCredentialFixtures.py` | exact |
| `.github/workflows/terraform.yml` (MOD: advisory step) | config (CI) | batch | `.github/workflows/registry-conformance.yml` session-credential job (13-29) | exact |
| `scripts/Test-PopeyeAzureVerificationVm.ps1` (MOD: caller VNet, NSG source, peering, env zone) | utility/test | request-response (read-only az) | itself | exact (self) |
| `scripts/Test-PopeyeVerificationVm.ps1` (MOD: gateway FQDN resolve + 443) | utility/test | request-response | itself lines 60-82 | exact (self) |
| `scripts/Test-PopeyeVerificationPsql.ps1` (MOD: `-RequestId`/key-hash read-only assertion) | utility/test | CRUD read | itself | exact (self) |
| `scripts/Test-PopeyeGatewayLockdown.ps1` (NEW negative tests) | utility/test | request-response | `Test-PopeyeVerificationVm.ps1` (`Add-Result` pattern) | role-match |
| `scripts/Invoke-PopeyeSmoke.ps1` (NEW) | utility | request-response | `scripts/provision-desktop-keys.ps1` (key/generate body, preamble) + `Test-PopeyeVerificationVm.ps1` | role-match |
| `scripts/Set-PopeyeLedgerReader.ps1` (NEW, ceremony helper) | utility | batch/file-I/O | `scripts/Test-PopeyeVerificationPsql.ps1` (psql invocation) | role-match |
| `sql/ai_usage_grants_azure.sql` (NEW idempotent) | migration/SQL | CRUD | `sql/ai_usage_grants.sql` | exact |
| `specs/POPEYE_VERIFICATION_VM_TEST_PROCEDURE.md` (MOD: D-08 grant amend) | doc | n/a | itself (line 13) | exact (self) |
| `artifacts/*` evidence files (NEW, redacted) | evidence | n/a | `artifacts/popeye-azure-verification-evidence.json` | exact |
| Redis PE / `snet-private-endpoints` / `privatelink.redis.azure.net` | config (IaC) | n/a | root `main.tf` subnet+zone+link blocks | role-match |
| Conditional env DNS zone block | config (IaC) | n/a | root `main.tf` zone+link blocks | role-match |

## Pattern Assignments

### `modules/gateway-service-azure/main.tf` (IaC, request-response)

**Analog:** itself. Edit in place; preserve header comment style (lines 1-13).

**Current args to change** (line 122-123):
```hcl
command = ["/bin/sh", "-c"]
args    = ["printf '%s' \"$LITELLM_CONFIG\" > /tmp/litellm.yaml && litellm --config /tmp/litellm.yaml --host 0.0.0.0 --port 4000"]
```
Change to `... && exec litellm ...`. Add `termination_grace_period_seconds = 45` in `template {}` (line 112, after `max_replicas`).

**Image line** (line 119-120): `image = "ghcr.io/berriai/litellm:${var.litellm_image_tag}"` -> `...:${var.litellm_image_tag}@${var.litellm_image_digest}` (A1: fall back to digest-only if ACA rejects).

**Env block pattern** (lines 168-171), copy for `DISABLE_ADMIN_UI="True"` and `LITELLM_LOG="ERROR"`:
```hcl
env {
  name  = "AZURE_CLIENT_ID"
  value = azurerm_user_assigned_identity.gateway.client_id
}
```

**Probe pattern** (lines 177-205): change readiness `path` to `/health/readiness`; raise startup `failure_count_threshold` (18 -> ~60) for the migration jump (Pitfall 7).

**Outputs** (outputs.tf, existing style, one `output` per value with description). Add:
```hcl
output "default_domain" { value = azurerm_container_app_environment.gateway.default_domain }
output "static_ip"      { value = azurerm_container_app_environment.gateway.static_ip_address }
```
(format multi-line for `terraform fmt`).

---

### `modules/gateway-service-azure/variables.tf` (validation)

**Analog:** itself lines 14-22 and 72-81. Extend, never weaken:
```hcl
variable "litellm_image_tag" {
  description = "..."
  type        = string

  validation {
    condition     = var.litellm_image_tag != "latest" && var.litellm_image_tag != ""
    error_message = "Pin a specific LiteLLM -stable tag. Never latest."
  }
}
```
Replace description/message (the `-stable` wording is obsolete) and add a second `validation` with `can(regex("^v1\\.\\d+\\.\\d+$", var.litellm_image_tag))`; keep the `latest`/empty condition. New `litellm_image_digest` variable follows the same shape with `can(regex("^sha256:[0-9a-f]{64}$", ...))`. The same two variables are duplicated in `envs/azure-eastus2/variables.tf` lines 12-15 (no validation there; description only) and passed at `main.tf` line 231 (`litellm_image_tag = var.litellm_image_tag`).

---

### `modules/gateway-state-azure/main.tf` + `variables.tf` (Redis)

**Analog:** itself. `azurerm_managed_redis.gateway` (main.tf 52-73) gains `clustering_policy = var.redis_clustering_policy` inside `default_database {}`. Variable style (variables.tf 63-67):
```hcl
variable "managed_redis_public_network_access" {
  description = "Public network access until private endpoint support is added to the POC module."
  type        = string
  default     = "Enabled"
}
```
Update description; root passes `"Disabled"` only after the PE exists (D-16). Add `redis_clustering_policy` variable (default per spike; see Pitfall 5). Existing outputs `redis_id`, `redis_hostname`, `redis_ssl_port` (outputs.tf) already suffice for the PE; no new state output needed.

---

### `envs/azure-eastus2/main.tf` (root; new network + secret resources)

**Analog (subnet, non-delegated variant of lines 81-98):**
```hcl
resource "azurerm_subnet" "postgres" {
  name                 = "snet-postgres"
  resource_group_name  = azurerm_resource_group.gateway.name
  virtual_network_name = azurerm_virtual_network.gateway.name
  address_prefixes     = [var.postgres_subnet_cidr]
  ...
}
```
New `azurerm_subnet.private_endpoints` copies this minus `delegation`/`service_endpoints`, with a new `var.private_endpoints_subnet_cidr` (default `10.60.3.0/27`).

**Analog (zone + link, lines 100-111):**
```hcl
resource "azurerm_private_dns_zone" "postgres" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.gateway.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "pg-vnet-link"
  resource_group_name   = azurerm_resource_group.gateway.name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.gateway.id
}
```
Copy for `privatelink.redis.azure.net` (link `redis-vnet-link`, Stage 1/2 VNet only, `registration_enabled = false`), then add `azurerm_private_endpoint.redis` per RESEARCH Pattern 4 (`subresource_names = ["redisEnterprise"]`, `private_connection_resource_id = module.state.redis_id`, `private_dns_zone_group`). Include `tags = local.tags`. Note the existing `module "state"` pattern `depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]` (line 210) for ordering.

**Conditional env DNS (D-14):** same zone/link shape, `count = var.manage_env_dns_zone ? 1 : 0`, zone name `module.service.default_domain`, `azurerm_private_dns_a_record` for `*` and `@` -> `[module.service.static_ip]`, second link only when `var.caller_vnet_id != ""`. Existing optional-resource idiom: `count = var.foundry_scope_id == "" ? 0 : 1` (service `main.tf` line 33).

**Reader DSN secret** (copy `random_password` lines 145-148 and `database_url` secret lines 176-187):
```hcl
resource "random_password" "ekg_cube_reader" {
  length  = 32
  special = false
}

resource "azurerm_key_vault_secret" "reader_dsn" {
  name         = "litellm-reader-dsn"
  key_vault_id = azurerm_key_vault.gateway.id
  value = format(
    "postgresql://ekg_cube_reader:%s@%s:5432/%s?sslmode=require",
    random_password.ekg_cube_reader.result,
    module.state.postgres_fqdn,
    module.state.litellm_database_name,
  )
  depends_on = [azurerm_role_assignment.deployer_secrets_officer]
}
```
Note lines 188-193 (redis_password) sit directly after `database_url` with no blank line; `terraform fmt` is enforced in CI.

**Rendered YAML** (lines 17-39, heredoc `<<-EOT`). Add `general_settings` keys per RESEARCH Pattern 2: `user_api_key_cache_ttl: 30`, `allow_client_side_credentials: false`, `disable_env_credential_login: true`, explicit `coordination_redis` block (host/port/password `os.environ/REDIS_*`, `ssl: true`). Keep `litellm_settings` untouched (no `cache: true`). Mirror every change in `config/litellm.azure.example.yaml`.

**Do not touch:** salt key (lines 162-174: `prevent_destroy`, `ignore_changes = [value]`).

---

### `envs/azure-eastus2/litellm-pin.auto.tfvars` (NEW) + `.gitignore`

**Analog:** `terraform.tfvars.example` (key = value style) and `.gitignore` lines 6-8:
```
*.tfvars
!*.tfvars.example
```
Add `!litellm-pin.auto.tfvars` below (negation must come after `*.tfvars`). Note `*.tfvars` glob matches `.auto.tfvars`, so negation is required. Contents: `litellm_image_tag = "v1.106.2"` / `litellm_image_digest = "sha256:..."` (re-verify on apply day). Also fix `terraform.tfvars.example` line 5: replace `# REQUIRED: a specific -stable tag, e.g. "v1.89.x-stable"` with the `vX.Y.Z` guidance and point to the pin file.

---

### `scripts/Test-LitellmAdvisoryRange.py` (CI utility, transform)

**Analog:** `scripts/Test-SessionCredentialFixtures.py` (use stdlib only; no jsonschema).

**Structure to copy** (lines 1-11, 26-60):
```python
#!/usr/bin/env python3
"""Validate ... (REQ-XXX-NN)."""

import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent

def load_json(path: Path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)

def main() -> int:
    failures = []
    ...
        if actual_valid != expected_valid:
            failures.append(f"{name}: expected ...")
        else:
            print(f"PASS: {name}")
    if failures:
        print("FAIL:\n" + "\n".join(failures), file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
```
Adapt: `SELF_TEST_CASES` dict named `"GW-02 rejects v1.100.3"` -> `("v1.100.3", False)`, `v1.90.3` -> False, `v1.106.2` -> True, `v1.104.0rc1`/`-stable` -> False. Support `--self-test` (argparse or `sys.argv`) and a default mode that parses `envs/azure-eastus2/litellm-pin.auto.tfvars` (fail if missing/empty, requirement-ID prefixed messages like `GW-02:`). Half-open `[lo,hi)` tuple compare over `config/litellm-advisory-ranges.json`. Keep file naming Verb-Noun per CLAUDE.md.

---

### `.github/workflows/terraform.yml` (CI)

**Analog:** `.github/workflows/registry-conformance.yml` lines 20-29:
```yaml
      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - name: REQ-CRED-01 validate issuance request fixtures
        run: python scripts/Test-SessionCredentialFixtures.py
```
Append to the existing `validate` job steps in terraform.yml (currently ends line 31): setup-python step plus `- name: GW-02 check LiteLLM pin against advisory ranges` running `python scripts/Test-LitellmAdvisoryRange.py --self-test` then `python scripts/Test-LitellmAdvisoryRange.py`. No pip install needed (stdlib). Keep `permissions: contents: read`.

---

### `scripts/Test-PopeyeVerificationPsql.ps1` (MOD: row assertion)

**Analog:** itself. Current file is 30 lines; preamble to keep (lines 10-21):
```powershell
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $Dsn
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$psql = Get-Command psql -ErrorAction SilentlyContinue
if ($null -eq $psql) {
  throw "psql is not installed or is not on PATH."
}
```
Add optional `-RequestId`, `-KeyHash` (sha256 of key, computed by caller), `-TimeoutSeconds 90`. Keep the "DSN never echoed" invocation (line 24): `& $psql.Source "--dbname=$Dsn" --no-password --quiet ... | Out-Null`; for the assertion use `--tuples-only --no-align -c "SELECT count(*) FROM public.\"LiteLLM_SpendLogs\" WHERE ..."` (SELECT only), poll until >= 10 s batch flush, `throw "MVP-01: ..."` on count != 1 (Pitfall 10: `request_id` is PK, so count by api_key hash + window). Print only `PASS:` lines plus request_id/count; no row contents.

---

### `scripts/Test-PopeyeVerificationVm.ps1` (MOD: gateway FQDN)

**Analog:** itself lines 34-82. Reuse `Test-Rfc1918Address` and `Add-Result` verbatim; add `-GatewayFqdn` (read from `terraform output gateway_internal_fqdn`; do not hardcode, D-14) and `-GatewayPort 443`, duplicating the DNS and TCP try/catch blocks:
```powershell
try {
  $resolution = @(Resolve-DnsName -Name $PostgresFqdn -Type A -ErrorAction Stop)
  ...
  Add-Result -Results $results -Check "DNS resolves to RFC1918 address" -Passed (...) -Detail (...)
}
catch {
  Add-Result -Results $results -Check "DNS resolves to RFC1918 address" -Passed $false -Detail $_.Exception.Message
}
```
Parameterize by a small helper function so Postgres and gateway share it; keep the `exit 1` on any FAIL (lines 114-116). Runs via run-command (non-secret) per D-18. Note: `-PsqlDsn` branch (95-110) overlaps with the Psql script; leave as-is.

---

### `scripts/Test-PopeyeAzureVerificationVm.ps1` (MOD: caller side)

**Analog:** itself. Keep `Invoke-AzJson`, `New-Check`, ordered `$evidence`, `Set-Content ... -Encoding utf8` (lines 38-56, 138-144). Add:
- Params following lines 20-29: `-CallerVnetName`, `-CallerResourceGroupName`, `-VmResourceGroupName` (the VM lives in `EUS-POPEYE-VNET-01`, not the Popeye RG).
- Peering check using `New-Check 'Peering Connected/FullyInSync both ways' ...` via `Invoke-AzJson @('network','vnet','peering','list',...)`.
- NSG source check: current rule check (lines 122-125) only asserts "no inbound RDP allow"; D-17 needs "3389 only from Bastion subnet / no Internet-source rule" (`Allow_Iliya_Promenet`). Filter `sourceAddressPrefix` instead.
- Env DNS zone link check mirroring lines 76-90 (zone name from `terraform output`/`az containerapp env show --query properties.defaultDomain`, link to both VNets).
- Login-role check already exists (lines 128-133, `$ApprovedOperatorDisplayNames`); keep, point `--scope` at the right VM.
Never reads Key Vault secret values (header contract, line 4); keep that.

---

### `scripts/Test-PopeyeGatewayLockdown.ps1` (NEW, negative tests)

**Analog:** `scripts/Test-PopeyeVerificationVm.ps1` (`Add-Result` + results table + exit code):
```powershell
$results = [System.Collections.Generic.List[object]]::new()
...
$results | Format-Table -AutoSize
if (@($results | Where-Object Status -eq "FAIL").Count -gt 0) { exit 1 }
```
Per-route loop (RESEARCH "Lockdown negative test shape"): for each of `/key/generate /key/info /user/new /user/info /utils/transform_request /utils/token_counter /team/list /config/yaml` call with the smoke key as bearer (`Invoke-WebRequest -SkipHttpErrorCheck`) and PASS iff status in 401,403. UI per D-19: `GET /sso/key/generate` body contains the disabled text; `POST /login` rejected; `/ui` only static. Take the key from `Read-Host -AsSecureString` or `az keyvault secret show` at runtime; never print it. Output only route + status code.

---

### `scripts/Invoke-PopeyeSmoke.ps1` (NEW) and `scripts/Set-PopeyeLedgerReader.ps1` (NEW)

**Analog:** `scripts/provision-desktop-keys.ps1`. Preamble and validation (lines 22-45):
```powershell
param(
  [Parameter(Mandatory)] [string] $GatewayBaseUrl,
  [Parameter(Mandatory)] [string] $TenantId,           # canonical lowercase UUID from the shared vocabulary
  ...
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$tenantIdPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
if ($TenantId -notmatch $tenantIdPattern) {
  throw "REQ-DCE-07: TenantId must be a canonical lowercase UUID."
}
```
Reuse the tenant regex, `throw "REQ-XXX-NN: ..."` convention (use `REQ-MVP-01` / `MVP-01:`), and the `/key/generate` body shape (lines 70-82): `user_id`, `team_id`, `max_budget`, `models`, `metadata{tenant_id,...}` ConvertTo-Json -Depth 4. Extend with `key_alias = "user:$Oid"`, `duration = "24h"`, `tags = @("mvp-smoke")`, `allowed_routes` explicit list (not `key_type: llm_api`), `metadata.principal_type = "user"`; team `popeye-poc` must exist first (`/team/new`). The file's own TODO (lines 89-91) shows the intended call:
```powershell
# Invoke-RestMethod -Method Post -Uri "$GatewayBaseUrl/key/generate" `
#   -Headers @{ Authorization = "Bearer $masterKey" } -Body $body -ContentType 'application/json'
# never log the key value.
```
Header comment style: `.SYNOPSIS/.DESCRIPTION/.NOTES` (lines 1-20) with the "master key never reaches a workstation" statement updated per D-07/D-08/D-18. Add a `-DryRun` switch as in that script (lines 31, 50, 84) so CI could exercise it. Master key from `az keyvault secret show` at runtime into a local variable only. Smoke output: timestamp, `request_id`, HTTP status, model only.

`Set-PopeyeLedgerReader.ps1`: invoke psql the way `Test-PopeyeVerificationPsql.ps1` does (line 24, `& $psql.Source "--dbname=$Dsn" --no-password ...`) with `-v reader_password=...` from KV at runtime, `-f sql/ai_usage_grants_azure.sql`. Uses the Azure admin DSN (litellm-database-url), which the procedure forbids to operators except in the D-08 window; record that in evidence.

---

### `sql/ai_usage_grants_azure.sql` (NEW)

**Analog:** `sql/ai_usage_grants.sql` (do not break the local one; Pitfall 8). Copy the Step 2 grants verbatim (lines 36-42):
```sql
GRANT CONNECT ON DATABASE litellm TO ekg_cube_reader;
GRANT USAGE ON SCHEMA public TO ekg_cube_reader;
GRANT SELECT ON public."LiteLLM_SpendLogs" TO ekg_cube_reader;
```
Keep the header-comment style (context, run order, verification query block). Omit `CREATE DATABASE` and `litellm_gateway`. Replace the commented role creation (line 34) with an idempotent `DO $$ ... IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='ekg_cube_reader') THEN CREATE ROLE ... LOGIN PASSWORD ...; ELSE ALTER ROLE ...` (psql `:'ekg_cube_reader_password'` variable style as in line 16; psql variable interpolation does not work inside `$$` bodies, so use `\gexec`/`format()` with `set` or two statements). Re-run after the Prisma migrations (D-13).

---

### `specs/POPEYE_VERIFICATION_VM_TEST_PROCEDURE.md` (MOD)

**Analog:** itself, line 13:
> 7. Confirm Key Vault access is restricted to `litellm-reader-dsn` after it exists. Do not grant the VM identity or either operator access to `litellm-database-url`, writer, master, or salt secrets.

Amend per D-08: carve out time-boxed secret-scope Secrets User on `litellm-master-key` for the platform owner only (and, for the SQL step, whatever D-13 needs); keep salt/database-url/writer restrictions, state the VM identity gets no grant (D-18), require grant/removal timestamps + KV log refs in evidence. Specs use versioned names (`UPPER_SNAKE_CASE_v0.N.md`) per CLAUDE.md; this file has no version suffix, so amend in place and note the date.

---

### Evidence files (`artifacts/`)

**Analog:** `artifacts/popeye-azure-verification-evidence.json` (ordered object with `validationUtc`, ids, `checks` array) and `artifacts/popeye-peered-caller-connectivity-2026-10-22.md` (dated markdown). Name new files `popeye-<topic>-evidence-YYYY-MM-DD.{json,md}`. Add `.gitignore` entries `artifacts/*.raw*` and `artifacts/**/*.tmp`.

---

## Shared Patterns

### PowerShell script preamble and error handling
**Source:** `scripts/Test-PopeyeVerificationPsql.ps1` lines 10-21; `scripts/provision-desktop-keys.ps1` lines 22-45
**Apply to:** every new/modified `.ps1`
`[CmdletBinding()]`, `param()`, `Set-StrictMode -Version Latest`, `$ErrorActionPreference = "Stop"`, fail fast with `throw "REQ-XXX-NN: <message>"` before side effects. 2-space indent. New scripts use Verb-Noun names.

### Check-result collection
**Source:** `scripts/Test-PopeyeVerificationVm.ps1` lines 45-58 (`Add-Result`), or `Test-PopeyeAzureVerificationVm.ps1` lines 51-54 (`New-Check`)
**Apply to:** `Test-PopeyeGatewayLockdown.ps1`, extended verification scripts
```powershell
$Results.Add([pscustomobject]@{ Check = $Check; Status = if ($Passed) { "PASS" } else { "FAIL" }; Detail = $Detail })
...
$results | Format-Table -AutoSize
if (@($results | Where-Object Status -eq "FAIL").Count -gt 0) { exit 1 }
```
Each check wrapped in try/catch that records FAIL with `$_.Exception.Message`.

### Secrets never echoed
**Source:** `Test-PopeyeVerificationPsql.ps1` lines 23-24 (`--dbname=$Dsn` + `| Out-Null`); `Test-PopeyeAzureVerificationVm.ps1` header (never reads KV values)
**Apply to:** all ceremony scripts. KV values fetched at runtime into variables, never written to disk/log/evidence; output limited to status, ids, timestamps.

### Python check scripts
**Source:** `scripts/Test-SessionCredentialFixtures.py`
**Apply to:** `Test-LitellmAdvisoryRange.py`. `main() -> int`, `failures` list, `FAIL:` to stderr, `raise SystemExit(main())`, 4-space indent.

### Terraform conventions
**Source:** `modules/*/variables.tf`, root `main.tf`
**Apply to:** all `.tf` changes
Variables have `description`+`type` (secrets `sensitive = true`); resources take `tags = local.tags` (root) / `var.tags` (modules); header comment cites spec; optional resources via `count`; `terraform fmt -recursive` before commit; KV secrets declare `depends_on = [azurerm_role_assignment.deployer_secrets_officer]`; never weaken the `latest`/empty and `min_replicas >= 2` validations.

### CI step style
**Source:** `.github/workflows/registry-conformance.yml` lines 13-29 (named steps prefixed with requirement ID)
**Apply to:** terraform.yml additions.

## No Analog Found

| File | Role | Data Flow | Reason |
|---|---|---|---|
| `config/litellm-advisory-ranges.json` | data | batch | No committed versioned advisory data; use the JSON shape in RESEARCH "Advisory range file" (schema file not required; could mirror `config/endpoint-detection.schema.json` style if a schema is wanted) |
| `azurerm_private_endpoint` + `azurerm_private_dns_zone_group`, `azurerm_private_dns_a_record` | IaC | n/a | No private endpoints or A records exist in repo (Postgres uses VNet integration); use RESEARCH Patterns 4 and 5 |

## Metadata

**Analog search scope:** `modules/`, `envs/azure-eastus2/`, `scripts/`, `sql/`, `config/`, `.github/workflows/`, `specs/` (procedure), `artifacts/`
**Files scanned:** ~20 read in full
**Pattern extraction date:** 2026-10-22
