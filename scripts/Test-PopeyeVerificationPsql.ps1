<#
.SYNOPSIS
  Authenticates to the Popeye PostgreSQL service using a reader-only DSN.

.EXAMPLE
  $dsn = az keyvault secret show --vault-name kv-popeye-gw-98c2b71b --name litellm-reader-dsn --query value -o tsv
  .\scripts\Test-PopeyeVerificationPsql.ps1 -Dsn $dsn
#>

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

# Suppress query output; the DSN is neither written to output nor to a file.
& $psql.Source "--dbname=$Dsn" --no-password --quiet --command "SELECT 1;" | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "psql reader authentication/query check failed with exit code $LASTEXITCODE."
}

Write-Host "PASS: psql authenticated successfully using the dedicated reader DSN."
