<#
.SYNOPSIS
  Mints the MVP smoke key, sends synthetic completions, blocks keys, and probes the budget path.

.DESCRIPTION
  Actions:
  - Run: ensure team, mint one user key (principal_type=user, key_alias=user:<oid>,
    24h, max_budget 0.25, tag mvp-smoke, explicit allowed_routes), then send -Count
    synthetic completions on that single key (D-09, D-10, D-06).
  - Block: block (never delete) a supplied key using the master key (D-10).
  - BudgetProbe: GW-06. Mint a tiny-budget key, send up to 15 completions, print a
    status histogram (expect 422 once exhausted, not 429), then block the probe key.

.NOTES
  The master key is fetched from Key Vault at runtime in an interactive operator
  az login session (D-07, D-08, D-18), held only in a local variable, and never
  reaches disk or output. Output is limited to UTC timestamp, request_id, HTTP
  status, model, and key hash; prompt content is synthetic.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)] [ValidateSet("Run", "Block", "BudgetProbe")] [string] $Action,
  [int] $Count = 1,
  [Parameter(Mandatory)] [string] $GatewayBaseUrl,
  [string] $KeyVaultName,
  [string] $MasterKeySecretName = "litellm-master-key",
  [string] $TenantId,
  [string] $UserObjectId,
  [string] $TeamId = "popeye-poc",
  [string] $Model = "twg-foundry",
  [securestring] $Key,
  [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$uuidPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
if ($GatewayBaseUrl -notmatch '^https://') { throw "REQ-MVP-01: GatewayBaseUrl must be https." }
$GatewayBaseUrl = $GatewayBaseUrl.TrimEnd('/')
if ($Count -lt 1 -or $Count -gt 50) { throw "REQ-MVP-01: Count must be between 1 and 50." }
if ($Action -ne "Block") {
  if ($TenantId -notmatch $uuidPattern) { throw "REQ-DCE-07: TenantId must be a canonical lowercase UUID." }
  if ($UserObjectId -notmatch $uuidPattern) { throw "REQ-MVP-01: UserObjectId must be a canonical lowercase UUID." }
}
if ($Action -eq "Block" -and $null -eq $Key) { throw "REQ-MVP-01: -Key is required for Block." }
if (-not $DryRun -and [string]::IsNullOrWhiteSpace($KeyVaultName)) { throw "REQ-MVP-01: KeyVaultName is required." }

$routesPath = Join-Path $PSScriptRoot "..\config\llm-allowed-routes.json"
if (-not (Test-Path -LiteralPath $routesPath)) { throw "REQ-MVP-01: llm-allowed-routes.json not found." }
$allowedRoutes = @((Get-Content -LiteralPath $routesPath -Raw | ConvertFrom-Json).allowed_routes)

function New-KeyBody {
  param([double] $MaxBudget, [string] $Tag)
  return @{
    key_alias      = "user:$UserObjectId"
    user_id        = $UserObjectId
    team_id        = $TeamId
    models         = @($Model)
    duration       = "24h"
    max_budget     = $MaxBudget
    tags           = @($Tag)
    allowed_routes = $allowedRoutes
    metadata       = @{ principal_type = "user"; tenant_id = $TenantId }
  }
}

if ($DryRun) {
  $shape = New-KeyBody -MaxBudget 0.25 -Tag "mvp-smoke"
  $shape.user_id = "<masked>"
  $shape.key_alias = "user:<masked>"
  $shape.metadata = @{ principal_type = "user"; tenant_id = "<masked>" }
  Write-Host "DRYRUN: Action=$Action Count=$Count Model=$Model Team=$TeamId"
  Write-Host ($shape | ConvertTo-Json -Depth 4)
  exit 0
}

function ConvertTo-PlainText([securestring] $Secure) {
  $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
  try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-Sha256Hex([string] $Value) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
  $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
  return ([System.BitConverter]::ToString($hash).Replace("-", "")).ToLowerInvariant()
}

function Invoke-Gateway {
  param([string] $Path, [hashtable] $Body, [string] $Bearer)
  $resp = Invoke-WebRequest -Method Post -Uri "$GatewayBaseUrl$Path" -SkipHttpErrorCheck `
    -Headers @{ Authorization = "Bearer $Bearer" } -ContentType "application/json" `
    -Body ($Body | ConvertTo-Json -Depth 6)
  return $resp
}

function Get-MasterKey {
  $az = Get-Command az -ErrorAction SilentlyContinue
  if ($null -eq $az) { throw "REQ-MVP-01: az CLI is not installed or is not on PATH." }
  $mk = & $az.Source keyvault secret show --vault-name $KeyVaultName --name $MasterKeySecretName --query value -o tsv
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($mk)) { throw "REQ-MVP-01: could not read master key from Key Vault." }
  return $mk
}

function New-VirtualKey {
  param([string] $MasterKey, [double] $MaxBudget, [string] $Tag)
  $r = Invoke-Gateway -Path "/key/generate" -Body (New-KeyBody -MaxBudget $MaxBudget -Tag $Tag) -Bearer $MasterKey
  if ([int]$r.StatusCode -ne 200) { throw "REQ-MVP-01: /key/generate returned HTTP $([int]$r.StatusCode)." }
  $k = ($r.Content | ConvertFrom-Json).key
  if ([string]::IsNullOrWhiteSpace($k)) { throw "REQ-MVP-01: /key/generate returned no key." }
  return $k
}

function Send-Completion {
  param([string] $VirtualKey)
  $body = @{
    model      = $Model
    messages   = @(@{ role = "user"; content = "Reply with the single word: ok" })
    max_tokens = 5
  }
  $r = Invoke-Gateway -Path "/v1/chat/completions" -Body $body -Bearer $VirtualKey
  $rid = $null
  if ($r.Headers.ContainsKey("x-litellm-call-id")) { $rid = @($r.Headers["x-litellm-call-id"])[0] }
  if (-not $rid -and [int]$r.StatusCode -eq 200) { $rid = ($r.Content | ConvertFrom-Json).id }
  return [pscustomobject]@{ RequestId = $rid; HttpStatus = [int]$r.StatusCode }
}

function Revoke-VirtualKey {
  param([string] $MasterKey, [string] $VirtualKey)
  $r = Invoke-Gateway -Path "/key/block" -Body @{ key = $VirtualKey } -Bearer $MasterKey
  return [int]$r.StatusCode
}

$masterKey = Get-MasterKey
try {
  switch ($Action) {
    "Run" {
      $t = Invoke-Gateway -Path "/team/new" -Body @{ team_id = $TeamId; team_alias = $TeamId } -Bearer $masterKey
      if ([int]$t.StatusCode -ge 500) { throw "REQ-MVP-01: /team/new returned HTTP $([int]$t.StatusCode)." }
      # 4xx is tolerated: the team may already exist.

      $newKey = New-VirtualKey -MasterKey $masterKey -MaxBudget 0.25 -Tag "mvp-smoke"
      $keyHash = Get-Sha256Hex $newKey
      $ids = [System.Collections.Generic.List[string]]::new()
      $last = $null
      for ($i = 0; $i -lt $Count; $i++) {
        $last = Send-Completion -VirtualKey $newKey
        if ($last.RequestId) { $ids.Add([string]$last.RequestId) }
      }
      $out = [pscustomobject]@{
        Timestamp  = [datetime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        RequestId  = $last.RequestId
        RequestIds = if ($Count -gt 1) { $ids.ToArray() } else { $null }
        HttpStatus = $last.HttpStatus
        Model      = $Model
        KeyHash    = $keyHash
        Key        = (ConvertTo-SecureString -String $newKey -AsPlainText -Force)
      }
      Write-Host "Timestamp=$($out.Timestamp) RequestId=$($out.RequestId) HttpStatus=$($out.HttpStatus) Model=$($out.Model) KeyHash=$($keyHash.Substring(0, 8))... Count=$Count"
      $out
    }
    "Block" {
      $plain = ConvertTo-PlainText $Key
      $code = Revoke-VirtualKey -MasterKey $masterKey -VirtualKey $plain
      Write-Host "Timestamp=$([datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')) KeyHash=$((Get-Sha256Hex $plain).Substring(0, 8))... HttpStatus=$code"
      if ($code -ne 200) { throw "REQ-MVP-01: /key/block returned HTTP $code." }
    }
    "BudgetProbe" {
      $probeKey = New-VirtualKey -MasterKey $masterKey -MaxBudget 0.0001 -Tag "mvp-smoke-budget"
      try {
        $hist = @{}
        for ($i = 0; $i -lt 15; $i++) {
          $c = (Send-Completion -VirtualKey $probeKey).HttpStatus
          $hist["$c"] = 1 + $(if ($hist.ContainsKey("$c")) { $hist["$c"] } else { 0 })
        }
        Write-Host ("Status histogram: " + (($hist.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join " "))
        if ($hist.ContainsKey("429")) { Write-Host "FAIL: budget exhaustion produced HTTP 429 (expected 422)." }
        elseif ($hist.ContainsKey("422")) { Write-Host "PASS: budget exhaustion produced HTTP 422." }
        else { Write-Host "FAIL: no HTTP 422 observed within 15 completions." }
      }
      finally {
        $code = Revoke-VirtualKey -MasterKey $masterKey -VirtualKey $probeKey
        Write-Host "Probe key blocked (HttpStatus=$code)."
      }
    }
  }
}
finally {
  $masterKey = $null
}
