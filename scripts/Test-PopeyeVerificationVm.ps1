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
  [switch] $SkipVmMetadataCheck
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
    [Parameter(Mandatory)] [System.Collections.Generic.List[object]] $Results,
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

$results = [System.Collections.Generic.List[object]]::new()

try {
  $resolution = @(Resolve-DnsName -Name $PostgresFqdn -Type A -ErrorAction Stop)
  $addresses = @(
    $resolution |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_.IPAddress) } |
      ForEach-Object { [System.Net.IPAddress]::Parse($_.IPAddress) }
  )
  $privateAddresses = @($addresses | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and (Test-Rfc1918Address $_) })
  Add-Result -Results $results -Check "DNS resolves to RFC1918 address" -Passed ($privateAddresses.Count -gt 0) -Detail ("Resolved: " + (($addresses | ForEach-Object ToString) -join ", "))
}
catch {
  Add-Result -Results $results -Check "DNS resolves to RFC1918 address" -Passed $false -Detail $_.Exception.Message
}

try {
  $connection = Test-NetConnection -ComputerName $PostgresFqdn -Port $Port -WarningAction SilentlyContinue -InformationLevel Detailed
  Add-Result -Results $results -Check "TCP $Port reachable" -Passed ([bool]$connection.TcpTestSucceeded) -Detail ("Remote address: {0}; TCP succeeded: {1}" -f $connection.RemoteAddress, $connection.TcpTestSucceeded)
}
catch {
  Add-Result -Results $results -Check "TCP $Port reachable" -Passed $false -Detail $_.Exception.Message
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
