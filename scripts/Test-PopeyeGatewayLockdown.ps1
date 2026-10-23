<#
.SYNOPSIS
  Proves the user smoke key cannot reach management/UI routes (GW-03, D-06, D-19).

.DESCRIPTION
  A positive control (GET /v1/models must return 200) runs first so a dead key
  cannot false-pass the negative checks. Management and utility routes must
  return 401 or 403. UI checks implement D-19: the disabled page is served,
  POST /login issues no session, and no session cookie is set. A literal
  401/403 on the UI is recorded as a deviation, not asserted. Only route and
  numeric status codes are printed; no response bodies.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $GatewayBaseUrl,
  [Parameter(Mandatory)] [securestring] $UserKey,
  [switch] $ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($GatewayBaseUrl -notmatch '^https://') { throw "REQ-GW-03: GatewayBaseUrl must be https." }
$GatewayBaseUrl = $GatewayBaseUrl.TrimEnd('/')
if ($ValidateOnly) { Write-Host "PASS: parameters valid."; exit 0 }

function Add-Result {
  param(
    [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[object]] $Results,
    [Parameter(Mandatory)] [string] $Check,
    [Parameter(Mandatory)] [bool] $Passed,
    [Parameter(Mandatory)] [string] $Detail
  )
  $Results.Add([pscustomobject]@{
      Check  = $Check
      Status = if ($Passed) { "PASS" } else { "FAIL" }
      Detail = $Detail
    })
}

function Invoke-Probe {
  param([string] $Method, [string] $Path, [hashtable] $Body)
  $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($UserKey)
  try {
    $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    $p = @{
      Method = $Method; Uri = "$GatewayBaseUrl$Path"; SkipHttpErrorCheck = $true
      MaximumRedirection = 0; Headers = @{ Authorization = "Bearer $plain" }
    }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json); $p.ContentType = "application/json" }
    return Invoke-WebRequest @p
  }
  finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $plain = $null
  }
}

$results = [System.Collections.Generic.List[object]]::new()

try {
  $r = Invoke-Probe -Method Get -Path "/v1/models"
  $code = [int]$r.StatusCode
  Add-Result -Results $results -Check "GW-03 positive control: key is valid" -Passed ($code -eq 200) -Detail "GET /v1/models -> $code"
}
catch {
  Add-Result -Results $results -Check "GW-03 positive control: key is valid" -Passed $false -Detail $_.Exception.Message
}

$denyRoutes = @(
  @{ Method = "Post"; Path = "/key/generate"; Body = @{} },
  @{ Method = "Get"; Path = "/key/info" },
  @{ Method = "Post"; Path = "/user/new"; Body = @{} },
  @{ Method = "Get"; Path = "/user/info" },
  @{ Method = "Post"; Path = "/utils/transform_request"; Body = @{} },
  @{ Method = "Post"; Path = "/utils/token_counter"; Body = @{} },
  @{ Method = "Get"; Path = "/utils/model_info" },
  @{ Method = "Get"; Path = "/team/list" },
  @{ Method = "Get"; Path = "/config/yaml" }
)
foreach ($route in $denyRoutes) {
  $name = "GW-03 deny $($route.Path)"
  try {
    $body = if ($route.ContainsKey("Body")) { $route.Body } else { $null }
    $r = Invoke-Probe -Method $route.Method -Path $route.Path -Body $body
    $code = [int]$r.StatusCode
    Add-Result -Results $results -Check $name -Passed ($code -eq 401 -or $code -eq 403) -Detail "$($route.Method.ToUpper()) $($route.Path) -> $code"
  }
  catch {
    Add-Result -Results $results -Check $name -Passed $false -Detail $_.Exception.Message
  }
}

# D-19 UI checks
try {
  $r = Invoke-Probe -Method Get -Path "/sso/key/generate"
  $disabled = ($r.Content -like "*Admin UI is Disabled*")
  Add-Result -Results $results -Check "D-19 disabled page served" -Passed (([int]$r.StatusCode -eq 200) -and $disabled) -Detail "GET /sso/key/generate -> $([int]$r.StatusCode); disabled-text match=$disabled"
}
catch {
  Add-Result -Results $results -Check "D-19 disabled page served" -Passed $false -Detail $_.Exception.Message
}

try {
  $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($UserKey)
  try { $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
  $r = Invoke-WebRequest -Method Post -Uri "$GatewayBaseUrl/login" -SkipHttpErrorCheck -MaximumRedirection 0 `
    -Body @{ username = "admin"; password = $plain }
  $plain = $null
  $code = [int]$r.StatusCode
  $hasCookie = $r.Headers.ContainsKey("Set-Cookie")
  $issued = ($code -ge 200 -and $code -lt 300 -and $hasCookie)
  Add-Result -Results $results -Check "D-19 POST /login issues no session" -Passed (-not $issued) -Detail "POST /login -> $code; session-cookie=$hasCookie"
}
catch {
  Add-Result -Results $results -Check "D-19 POST /login issues no session" -Passed $false -Detail $_.Exception.Message
}

try {
  $r = Invoke-Probe -Method Get -Path "/ui/"
  $hasCookie = $r.Headers.ContainsKey("Set-Cookie")
  Add-Result -Results $results -Check "D-19 GET /ui/ sets no session cookie" -Passed (-not $hasCookie) -Detail "GET /ui/ -> $([int]$r.StatusCode); session-cookie=$hasCookie"
}
catch {
  Add-Result -Results $results -Check "D-19 GET /ui/ sets no session cookie" -Passed $false -Detail $_.Exception.Message
}

Add-Result -Results $results -Check "D-19 deviation recorded" -Passed $true -Detail "D-19 deviation recorded: UI returns disabled page not 401/403, literal 401/403 deferred to Phase 4/5 ingress block"

$results | Format-Table -AutoSize

if (@($results | Where-Object Status -eq "FAIL").Count -gt 0) {
  exit 1
}
