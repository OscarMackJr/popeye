<#
.SYNOPSIS
  Verifies private PostgreSQL connectivity from the Popeye verification VM.

.DESCRIPTION
  Runs the VM-side acceptance checks for the Popeye Stage 1/2 verification
  environment. It confirms that the PostgreSQL name resolves to an RFC1918
  address and that TCP 5432 is reachable. It can optionally verify that psql
  is installed and can authenticate using the dedicated reader DSN.

  This script cannot prove Azure-side controls such as Bastion RBAC, subnet
  delegation, or NSG policy. Those checks are listed in the accompanying
  procedure below.

.EXAMPLE
  .\scripts\Test-PopeyeVerificationVm.ps1

.EXAMPLE
  $dsn = (az keyvault secret show --vault-name kv-popeye-gw-98c2b71b --name litellm-reader-dsn --query value -o tsv)
  .\scripts\Test-PopeyeVerificationVm.ps1 -PsqlDsn $dsn
#>

[CmdletBinding()]
param(
  [string] $PostgresFqdn = "pg-popeye-stage1-stage2-eastus2.postgres.database.azure.com",
  [int] $Port = 5432,
  [string] $PsqlDsn,
  [switch] $SkipVmMetadataCheck,
  # Gateway FQDN comes from `az containerapp show` (properties.configuration.ingress.fqdn); never hardcoded.
  [string] $GatewayFqdn,
  [int] $GatewayPort = 443,
  # Optional: the environment staticIp; the resolved A record must equal it.
  [string] $ExpectedGatewayIp,
  # Report only whether psql and az are on PATH (D-18 preflight).
  [switch] $CheckTooling
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-Rfc1918Address {
  param([Parameter(Mandatory)] [System.Net.IPAddress] $Address)

  $bytes = $Address.GetAddressBytes()
  return (
    $bytes[0] -eq 10 -or
    ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
    ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
  )
}

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

function Test-NameAndPort {
  param(
    [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[object]] $Results,
    [Parameter(Mandatory)] [string] $Label,
    [Parameter(Mandatory)] [string] $Name,
    [Parameter(Mandatory)] [int] $Port,
    [string] $ExpectedIp
  )

  try {
    $resolution = @(Resolve-DnsName -Name $Name -Type A -ErrorAction Stop)
    $addresses = @(
      $resolution |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.IPAddress) } |
        ForEach-Object { [System.Net.IPAddress]::Parse($_.IPAddress) }
    )
    $privateAddresses = @($addresses | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and (Test-Rfc1918Address $_) })
    $passed = ($privateAddresses.Count -gt 0)
    if (-not [string]::IsNullOrWhiteSpace($ExpectedIp)) {
      $passed = $passed -and (@($addresses | Where-Object { $_.ToString() -eq $ExpectedIp }).Count -gt 0)
    }
    Add-Result -Results $Results -Check "NET-04 $Label resolves" -Passed $passed -Detail ("Resolved: " + (($addresses | ForEach-Object ToString) -join ", ") + $(if ($ExpectedIp) { "; expected: $ExpectedIp" } else { "" }))
  }
  catch {
    Add-Result -Results $Results -Check "NET-04 $Label resolves" -Passed $false -Detail $_.Exception.Message
  }

  try {
    $connection = Test-NetConnection -ComputerName $Name -Port $Port -WarningAction SilentlyContinue -InformationLevel Detailed
    Add-Result -Results $Results -Check "NET-04 $Label TCP $Port" -Passed ([bool]$connection.TcpTestSucceeded) -Detail ("Remote address: {0}; TCP succeeded: {1}" -f $connection.RemoteAddress, $connection.TcpTestSucceeded)
  }
  catch {
    Add-Result -Results $Results -Check "NET-04 $Label TCP $Port" -Passed $false -Detail $_.Exception.Message
  }
}

$results = [System.Collections.Generic.List[object]]::new()

if ($CheckTooling) {
  # D-18 preflight: report only; non-secret.
  foreach ($tool in @('psql', 'az')) {
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
      Add-Result -Results $results -Check "Tooling: $tool on PATH" -Passed $false -Detail "$tool not found on PATH."
    }
    else {
      $version = "unknown"
      try { $version = ((& $cmd.Source --version 2>&1 | Select-Object -First 1) | Out-String).Trim() } catch { $version = "version query failed" }
      Add-Result -Results $results -Check "Tooling: $tool on PATH" -Passed $true -Detail $version
    }
  }
  $results | Format-Table -AutoSize
  if (@($results | Where-Object Status -eq "FAIL").Count -gt 0) { exit 1 }
  exit 0
}

Test-NameAndPort -Results $results -Label "Postgres" -Name $PostgresFqdn -Port $Port

if ($PSBoundParameters.ContainsKey("GatewayPort") -and [string]::IsNullOrWhiteSpace($GatewayFqdn)) {
  throw "NET-04: -GatewayFqdn is required when -GatewayPort is used."
}
if (-not [string]::IsNullOrWhiteSpace($GatewayFqdn)) {
  Test-NameAndPort -Results $results -Label "Gateway" -Name $GatewayFqdn -Port $GatewayPort -ExpectedIp $ExpectedGatewayIp
}

if (-not $SkipVmMetadataCheck) {
  try {
    $metadata = Invoke-RestMethod -Headers @{ Metadata = "true" } -Uri "http://169.254.169.254/metadata/instance?api-version=2021-02-01" -ErrorAction Stop
    $publicIpAddresses = @($metadata.network.interface.ipv4.ipAddress | ForEach-Object { $_.publicIpAddress } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Add-Result -Results $results -Check "VM has no public IP" -Passed ($publicIpAddresses.Count -eq 0) -Detail $(if ($publicIpAddresses.Count -eq 0) { "No public IP reported by Azure Instance Metadata Service." } else { "Public IP reported: " + ($publicIpAddresses -join ", ") })
  }
  catch {
    Add-Result -Results $results -Check "VM has no public IP" -Passed $false -Detail ("Could not query Azure Instance Metadata Service: " + $_.Exception.Message)
  }
}

if (-not [string]::IsNullOrWhiteSpace($PsqlDsn)) {
  $psql = Get-Command psql -ErrorAction SilentlyContinue
  if ($null -eq $psql) {
    Add-Result -Results $results -Check "psql authenticated query" -Passed $false -Detail "psql is not installed or is not on PATH."
  }
  else {
    try {
      # The command output does not echo the DSN or query result.
      & $psql.Source "--dbname=$PsqlDsn" --no-password --quiet --command "SELECT 1;" | Out-Null
      Add-Result -Results $results -Check "psql authenticated query" -Passed $true -Detail "Dedicated reader DSN authenticated successfully."
    }
    catch {
      Add-Result -Results $results -Check "psql authenticated query" -Passed $false -Detail $_.Exception.Message
    }
  }
}

$results | Format-Table -AutoSize

if (@($results | Where-Object Status -eq "FAIL").Count -gt 0) {
  exit 1
}
