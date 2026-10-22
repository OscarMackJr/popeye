<#
.SYNOPSIS
  Idempotently installs psql (PostgreSQL 16 client) and Azure CLI on the Popeye verification VM.

.DESCRIPTION
  Runs ON the Windows VM (EUS-VM-POPEYE). Contains no secrets, no Key Vault access
  and performs no logins, so it is safe to run via run-command (D-18).

  - Detects existing `psql` and `az`; installs only what is missing.
  - Azure CLI: official MSI from https://aka.ms/installazurecliwindowsx64.
  - psql: prefers winget (PostgreSQL.PostgreSQL.16 would install the server, so the
    client-only EDB binaries zip is used when winget cannot install client tools only);
    fallback is the documented EDB binaries zip for PostgreSQL 16 (pinned $PsqlVersion),
    extracted to C:\Program Files\PostgreSQL\16\bin and added to the machine PATH.
  - Verifies with `psql --version` and `az version`, printing PASS/FAIL lines.
  - -DryRun only reports what would be done.

  Invocation from the workstation (non-secret, D-18):

    az vm run-command invoke -g <rg> -n EUS-VM-POPEYE --command-id RunPowerShellScript `
      --scripts @scripts/Install-PopeyeVmTooling.ps1 --parameters DryRun=true

  Then without DryRun:

    az vm run-command invoke -g <rg> -n EUS-VM-POPEYE --command-id RunPowerShellScript `
      --scripts @scripts/Install-PopeyeVmTooling.ps1

  Confirm afterwards with scripts/Test-PopeyeVerificationVm.ps1 -CheckTooling.
  Note: run-command executes as SYSTEM; PATH changes are machine-scope and are visible
  to new sessions (open a new Bastion session after install).
#>

[CmdletBinding()]
param(
  [switch] $DryRun,
  # Pin to match the PostgreSQL v16 server (modules/gateway-state-azure).
  [string] $PsqlVersion = "16.4-1",
  [string] $PsqlInstallRoot = "C:\Program Files\PostgreSQL\16"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
  param([string] $Check, [bool] $Passed, [string] $Detail)
  $results.Add([pscustomobject]@{ Check = $Check; Status = $(if ($Passed) { "PASS" } else { "FAIL" }); Detail = $Detail })
}

function Test-Tool {
  param([Parameter(Mandatory)] [string] $Name)
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Update-SessionPath {
  $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
  $user = [Environment]::GetEnvironmentVariable("Path", "User")
  $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ";"
}

function Install-AzureCli {
  $msi = Join-Path $env:TEMP "AzureCLI.msi"
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri "https://aka.ms/installazurecliwindowsx64" -OutFile $msi -UseBasicParsing
  $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /quiet /norestart" -Wait -PassThru
  Remove-Item $msi -Force -ErrorAction SilentlyContinue
  if ($p.ExitCode -notin 0, 3010) {
    throw "REQ-NET-04: Azure CLI MSI install failed with exit code $($p.ExitCode)"
  }
}

function Install-Psql {
  $binDir = Join-Path $PsqlInstallRoot "bin"
  $winget = Get-Command winget -ErrorAction SilentlyContinue
  if ($winget) {
    # Client-only is not offered by winget for PostgreSQL; try it, then fall back to the zip.
    & winget install --id PostgreSQL.PostgreSQL.16 --version $PsqlVersion.Split("-")[0] `
      --silent --accept-package-agreements --accept-source-agreements `
      --override "--mode unattended --disable-components server,pgAdmin,stackbuilder" 2>&1 | Out-Null
    if (Test-Path (Join-Path $binDir "psql.exe")) { $script:psqlBin = $binDir; return }
  }
  # Fallback: EDB binaries zip for PostgreSQL 16 (documented at enterprisedb.com/download-postgresql-binaries).
  $zipVersion = $PsqlVersion
  $zip = Join-Path $env:TEMP "postgresql-binaries.zip"
  $url = "https://get.enterprisedb.com/postgresql/postgresql-$zipVersion-windows-x64-binaries.zip"
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
  $extract = Join-Path $env:TEMP "pgbin-extract"
  if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
  Expand-Archive -Path $zip -DestinationPath $extract -Force
  New-Item -ItemType Directory -Path $PsqlInstallRoot -Force | Out-Null
  Copy-Item -Path (Join-Path $extract "pgsql\*") -Destination $PsqlInstallRoot -Recurse -Force
  Remove-Item $zip, $extract -Recurse -Force -ErrorAction SilentlyContinue
  if (-not (Test-Path (Join-Path $binDir "psql.exe"))) {
    throw "REQ-NET-04: psql.exe not found under $binDir after install"
  }
}

function Add-MachinePath {
  param([Parameter(Mandatory)] [string] $Dir)
  $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
  if (($machine -split ";") -notcontains $Dir) {
    [Environment]::SetEnvironmentVariable("Path", ($machine.TrimEnd(";") + ";" + $Dir), "Machine")
  }
}

$needAz = -not (Test-Tool "az")
$needPsql = -not (Test-Tool "psql")

if ($DryRun) {
  Add-Result "DryRun az" $true $(if ($needAz) { "would install Azure CLI via aka.ms/installazurecliwindowsx64 MSI" } else { "already present, no action" })
  Add-Result "DryRun psql" $true $(if ($needPsql) { "would install PostgreSQL client $PsqlVersion (winget, else EDB zip) into $PsqlInstallRoot and add bin to machine PATH" } else { "already present, no action" })
} else {
  try {
    if ($needAz) { Install-AzureCli }
    if ($needPsql) {
      Install-Psql
      Add-MachinePath -Dir (Join-Path $PsqlInstallRoot "bin")
    }
    Update-SessionPath
    # Azure CLI MSI installs under Program Files; pick it up if PATH refresh missed it.
    if (-not (Test-Tool "az")) {
      $azDir = "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin"
      if (Test-Path $azDir) { $env:Path += ";$azDir" }
    }
  } catch {
    Add-Result "Install" $false $_.Exception.Message
  }

  try {
    $v = (& psql --version) 2>&1 | Out-String
    Add-Result "psql --version" ($v -match "psql") $v.Trim()
  } catch { Add-Result "psql --version" $false $_.Exception.Message }

  try {
    $v = (& az version --output json) 2>&1 | Out-String
    Add-Result "az version" ($v -match "azure-cli") (($v -replace "\s+", " ").Trim())
  } catch { Add-Result "az version" $false $_.Exception.Message }
}

foreach ($r in $results) { Write-Output ("{0}: {1} - {2}" -f $r.Status, $r.Check, $r.Detail) }

if (@($results | Where-Object { $_.Status -eq "FAIL" }).Count -gt 0) { exit 1 }
