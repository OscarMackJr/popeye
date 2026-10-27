<#
.SYNOPSIS
  Per-destination outbound HTTPS probe for the Popeye verification VM.

.DESCRIPTION
  Runs ON the Windows VM (EUS-VM-POPEYE). Read-only: no secrets, no logins, no
  Key Vault data-plane reads, so it is safe to run via run-command (D-18).

  For each destination it reports, in order: DNS resolution, TCP connect (5 s timeout),
  then an HTTPS HEAD request. Any HTTP status (including 3xx/401/403/404) counts as OK,
  because it proves TLS and HTTP completed end to end. Resolved IPs are masked to two
  octets.

  The first row is a positive control: TCP 5432 to the Stage 1/2 Postgres private
  endpoint over the peering. If the control fails, or ROWS is not 7, the run is not
  evidence about egress (empty reads are not clean results); re-run it.

  Destinations are the plan 08 needs: operator `az login` (login.microsoftonline.com,
  management.azure.com, *.vault.azure.net) and the one-time tooling downloads used by
  scripts/Install-PopeyeVmTooling.ps1 (aka.ms -> azcliprod.blob.core.windows.net,
  get.enterprisedb.com).

  Invocation from the workstation (non-secret, D-18):

    az vm run-command invoke -g <rg> -n EUS-VM-POPEYE --command-id RunPowerShellScript `
      --scripts @scripts/Test-PopeyeVmEgress.ps1 --query "value[0].message" -o tsv

  Reading the result: DNS FAIL = name resolution; TCP TIMEOUT = dropped on the network
  path (NSG outbound rule, UDR to a firewall/NVA, or no outbound path); TCP OK but
  HTTPS FAIL = TLS interception or FQDN filtering.
#>

[CmdletBinding()]
param(
  [string] $PostgresFqdn = "pg-popeye-stage1-stage2-eastus2.postgres.database.azure.com",
  # Gateway vault stands in for *.vault.azure.net.
  [string] $KeyVaultName = "kv-popeye-gw-98c2b71b"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$vaultHost = "$KeyVaultName.vault.azure.net"
$targets = @(
  @{ Host = $PostgresFqdn; Port = 5432; Url = $null }  # positive control over the peering
  @{ Host = "login.microsoftonline.com"; Port = 443; Url = "https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration" }
  @{ Host = "management.azure.com"; Port = 443; Url = "https://management.azure.com/" }
  @{ Host = $vaultHost; Port = 443; Url = "https://$vaultHost/healthstatus" }
  @{ Host = "aka.ms"; Port = 443; Url = "https://aka.ms/" }
  @{ Host = "azcliprod.blob.core.windows.net"; Port = 443; Url = "https://azcliprod.blob.core.windows.net/" }
  @{ Host = "get.enterprisedb.com"; Port = 443; Url = "https://get.enterprisedb.com/" }
)

function Get-ShortError {
  param([Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $Record)
  $ex = $Record.Exception
  if ($ex.InnerException) { $ex = $ex.InnerException }
  $m = $ex.Message -replace "\s+", " "
  return $m.Substring(0, [Math]::Min(90, $m.Length))
}

$rows = foreach ($t in $targets) {
  $dns = "FAIL"; $tcp = "-"; $https = "-"; $detail = ""

  try {
    $ip = [Net.Dns]::GetHostAddresses($t.Host) | Where-Object AddressFamily -eq "InterNetwork" | Select-Object -First 1
    if ($ip) { $dns = "OK " + ($ip.IPAddressToString -replace "\.\d+\.\d+$", ".x.x") } else { $detail = "no IPv4 address" }
  } catch { $detail = Get-ShortError $_ }

  if ($dns -like "OK*") {
    $client = New-Object Net.Sockets.TcpClient
    try {
      $ar = $client.BeginConnect($t.Host, $t.Port, $null, $null)
      if ($ar.AsyncWaitHandle.WaitOne(5000) -and $client.Connected) { $tcp = "OK" } else { $tcp = "TIMEOUT" }
    } catch { $tcp = "FAIL"; $detail = Get-ShortError $_ } finally { $client.Close() }
  }

  if ($tcp -eq "OK" -and $t.Url) {
    try {
      $r = Invoke-WebRequest -Uri $t.Url -Method Head -UseBasicParsing -TimeoutSec 10 -MaximumRedirection 0
      $https = "OK " + [int]$r.StatusCode
    } catch {
      $resp = $null
      if ($_.Exception.PSObject.Properties["Response"]) { $resp = $_.Exception.Response }
      if ($resp) { $https = "OK " + [int]$resp.StatusCode } else { $https = "FAIL"; $detail = Get-ShortError $_ }
    }
  }

  [pscustomobject]@{ Host = $t.Host; Port = $t.Port; Dns = $dns; Tcp = $tcp; Https = $https; Detail = $detail }
}

"ROWS=$(@($rows).Count) (expect $($targets.Count))"
$rows | Format-Table -AutoSize -Wrap | Out-String -Width 220
