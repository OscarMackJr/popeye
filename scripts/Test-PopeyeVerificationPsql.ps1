<#
.SYNOPSIS
  Authenticates to the Popeye PostgreSQL service using a reader-only DSN.

.DESCRIPTION
  With -KeyHash, also asserts (SELECT only, via the reader DSN) that exactly
  -ExpectedCount ledger rows exist for the key within the time window and that
  the D-09 attribution booleans hold. Only PASS lines are printed; row contents
  and the DSN are never printed.

.EXAMPLE
  $dsn = az keyvault secret show --vault-name kv-popeye-gw-98c2b71b --name litellm-reader-dsn --query value -o tsv
  .\scripts\Test-PopeyeVerificationPsql.ps1 -Dsn $dsn
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $Dsn,
  [string] $KeyHash,
  [string] $RequestId,
  [datetime] $SinceUtc = [datetime]::UtcNow.AddHours(-1),
  [int] $TimeoutSeconds = 90,
  [int] $ExpectedCount = 1,
  [string] $ExpectedTeamId = "popeye-poc",
  [string] $ExpectedUserId,
  [string] $ExpectedKeyAlias,
  [string] $ExpectedTenantId
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

if (-not [string]::IsNullOrWhiteSpace($KeyHash)) {
  if ($KeyHash -notmatch '^[0-9a-f]{64}$') { throw "MVP-01: KeyHash must be lowercase sha256 hex." }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedUserId) -and [string]::IsNullOrWhiteSpace($ExpectedKeyAlias)) {
    $ExpectedKeyAlias = "user:$ExpectedUserId"
  }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedTenantId) -and $ExpectedTenantId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
    throw "MVP-01: ExpectedTenantId must be a canonical lowercase UUID."
  }

  function ConvertTo-SqlLiteral([string] $Value) { return "'" + $Value.Replace("'", "''") + "'" }
  function Invoke-ReaderScalar([string] $Sql) {
    $out = & $psql.Source "--dbname=$Dsn" --no-password --quiet --tuples-only --no-align --command $Sql
    if ($LASTEXITCODE -ne 0) { throw "MVP-01: reader query failed with exit code $LASTEXITCODE." }
    return ("$out").Trim()
  }

  $since = $SinceUtc.ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
  $where = "api_key = $(ConvertTo-SqlLiteral $KeyHash) AND ""startTime"" >= $(ConvertTo-SqlLiteral $since)::timestamp"
  $countSql = "SELECT count(*) FROM public.""LiteLLM_SpendLogs"" WHERE $where;"

  # PROXY_BATCH_WRITE_AT defaults to 10 s; wait before the first poll.
  Start-Sleep -Seconds 12
  $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
  $count = [int](Invoke-ReaderScalar $countSql)
  while ($count -lt $ExpectedCount -and [datetime]::UtcNow -lt $deadline) {
    Start-Sleep -Seconds 5
    $count = [int](Invoke-ReaderScalar $countSql)
  }
  if ($count -ne $ExpectedCount) {
    throw "MVP-01: expected exactly $ExpectedCount ledger row(s), found $count"
  }

  $conds = [System.Collections.Generic.List[string]]::new()
  if (-not [string]::IsNullOrWhiteSpace($RequestId) -and $ExpectedCount -eq 1) {
    $conds.Add("request_id = $(ConvertTo-SqlLiteral $RequestId)")
  }
  $conds.Add("team_id = $(ConvertTo-SqlLiteral $ExpectedTeamId)")
  if (-not [string]::IsNullOrWhiteSpace($ExpectedUserId)) { $conds.Add("""user"" = $(ConvertTo-SqlLiteral $ExpectedUserId)") }
  $conds.Add("request_tags::jsonb ? 'mvp-smoke'")
  $conds.Add("messages::text = '{}'")
  $conds.Add("response::text = '{}'")
  if (-not [string]::IsNullOrWhiteSpace($ExpectedKeyAlias)) {
    $conds.Add("metadata->>'user_api_key_alias' = $(ConvertTo-SqlLiteral $ExpectedKeyAlias)")
  }

  # The metadata path for key metadata is LiteLLM-version dependent: probe first.
  $probeSql = "SELECT bool_and(metadata ? 'user_api_key_auth_metadata') FROM public.""LiteLLM_SpendLogs"" WHERE $where;"
  $metaVisible = (Invoke-ReaderScalar $probeSql) -eq "t"
  if ($metaVisible) {
    $conds.Add("metadata->'user_api_key_auth_metadata'->>'principal_type' = 'user'")
    if (-not [string]::IsNullOrWhiteSpace($ExpectedTenantId)) {
      $conds.Add("metadata->'user_api_key_auth_metadata'->>'tenant_id' = $(ConvertTo-SqlLiteral $ExpectedTenantId)")
    }
  }
  else {
    Write-Host "INFO: principal_type/tenant_id not exposed in LiteLLM_SpendLogs.metadata; asserted via key_alias, user, team_id, tags instead"
  }

  $boolSql = "SELECT bool_and(" + ($conds -join " AND ") + ") FROM public.""LiteLLM_SpendLogs"" WHERE $where;"
  if ((Invoke-ReaderScalar $boolSql) -ne "t") {
    throw "MVP-01: ledger attribution assertions failed for the matched row(s)."
  }
  $rid = if ([string]::IsNullOrWhiteSpace($RequestId)) { "n/a" } else { $RequestId }
  Write-Host "PASS: ledger row count == $count (request_id=$rid)."
  Write-Host "PASS: ledger attribution booleans hold for $count row(s) (request_id=$rid)."
}
