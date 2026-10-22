<#
.SYNOPSIS
  Creates/updates the read-only ekg_cube_reader role on the Popeye gateway database.

.DESCRIPTION
  Fetches the admin DSN and reader DSN from Key Vault at runtime (operator az login
  session, D-18), extracts the reader password in memory, and runs
  sql/ai_usage_grants_azure.sql with psql -v reader_password. Nothing secret is
  printed or written to disk. Only PASS/FAIL lines are emitted.

.EXAMPLE
  .\scripts\Set-PopeyeLedgerReader.ps1 -KeyVaultName kv-popeye-gw-98c2b71b -DryRun
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $KeyVaultName,
  [string] $AdminSecretName = "litellm-database-url",
  [string] $ReaderSecretName = "litellm-reader-dsn",
  [string] $SqlPath,
  [switch] $VerifyOnly,
  [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($SqlPath)) {
  $SqlPath = Join-Path $PSScriptRoot "..\sql\ai_usage_grants_azure.sql"
}
if (-not (Test-Path -LiteralPath $SqlPath)) {
  throw "REQ-MVP-01: SQL file not found: $SqlPath"
}

if ($DryRun) {
  Write-Host "PASS: dry run - parameters valid, SQL file present; no Key Vault or database call made."
  exit 0
}

$psql = Get-Command psql -ErrorAction SilentlyContinue
if ($null -eq $psql) { throw "REQ-MVP-01: psql is not installed or is not on PATH." }
$az = Get-Command az -ErrorAction SilentlyContinue
if ($null -eq $az) { throw "REQ-MVP-01: az CLI is not installed or is not on PATH." }

$adminDsn = & $az.Source keyvault secret show --vault-name $KeyVaultName --name $AdminSecretName --query value -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($adminDsn)) {
  throw "REQ-MVP-01: could not read admin secret from Key Vault."
}

if ($VerifyOnly) {
  $tbl = 'public."LiteLLM_SpendLogs"'
  $q = "SELECT has_table_privilege('ekg_cube_reader','$tbl','SELECT') AND NOT (has_table_privilege('ekg_cube_reader','$tbl','INSERT') OR has_table_privilege('ekg_cube_reader','$tbl','UPDATE') OR has_table_privilege('ekg_cube_reader','$tbl','DELETE'));"
  $out = & $psql.Source "--dbname=$adminDsn" --no-password --quiet --tuples-only --no-align --command $q
  if ($LASTEXITCODE -eq 0 -and ("$out".Trim() -eq "t")) {
    Write-Host "PASS: ekg_cube_reader has SELECT only on LiteLLM_SpendLogs."
    exit 0
  }
  Write-Host "FAIL: ekg_cube_reader privilege verification failed."
  exit 1
}

$readerDsn = & $az.Source keyvault secret show --vault-name $KeyVaultName --name $ReaderSecretName --query value -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($readerDsn)) {
  throw "REQ-MVP-01: could not read reader secret from Key Vault."
}
if ($readerDsn -notmatch '^postgres(?:ql)?://[^:/@]+:([^@]+)@') {
  throw "REQ-MVP-01: reader secret is not a postgres URL with a password."
}
$readerPassword = [System.Uri]::UnescapeDataString($Matches[1])

& $psql.Source "--dbname=$adminDsn" --no-password --quiet -v ON_ERROR_STOP=1 -v "reader_password=$readerPassword" -f $SqlPath | Out-Null
if ($LASTEXITCODE -ne 0) {
  Write-Host "FAIL: reader role SQL failed with exit code $LASTEXITCODE."
  exit 1
}
Write-Host "PASS: ekg_cube_reader role and SELECT-only privilege applied."
