<#
.SYNOPSIS
  Operator script for plan 01-04 Tasks 2-3: make Managed Redis private in two
  applies with a clustering-policy spike between them (GW-06, D-15, D-16).

.DESCRIPTION
  Runs from the repo root of the main checkout on an az-authenticated
  workstation. Stages, in order:

    PlanA   terraform plan with redis_public_network_access=Enabled, saved to
            $env:TEMP\stageA.tfplan; stop conditions checked from the JSON plan
            (Postgres delete/replace, salt key change, container image change).
    ApplyA  applies the saved stage A plan after a typed YES, then restarts the
            active revision so ACA re-reads the Key Vault redis password and
            waits for >= 2 Running replicas.
    Spike   confirms REDIS_HOST resolves to the private endpoint subnet and runs
            scripts/Test-PopeyeRedisCompat.py inside a replica.
    ApplyB  plans with the default (Disabled), checks stop conditions, applies
            after a typed YES, and confirms publicNetworkAccess = Disabled.
    Health  restarts the revision, checks replicas, readiness 200, console logs
            free of ConnectionError/MOVED/CROSSSLOT, re-runs the spike, and
            confirms terraform plan -detailed-exitcode is 0.

  -Stage All runs every stage with a YES gate before each apply. The script
  never prints secrets: in-replica code reads REDIS_* from the container env
  and prints PASS/FAIL, exception class names and the /27 only. Saved plan
  files contain sensitive values and are deleted after apply.

  az containerapp exec output cannot be captured, so spike rows are read off
  the console. Paste them back for artifacts/popeye-redis-spike-2026-10-22.md.

.EXAMPLE
  .\scripts\Invoke-PopeyeRedisPrivateCutover.ps1 -Stage All

.EXAMPLE
  # Spike failed with MOVED/CROSSSLOT under NoCluster: set
  # redis_clustering_policy = "EnterpriseCluster" in terraform.tfvars, then
  .\scripts\Invoke-PopeyeRedisPrivateCutover.ps1 -Stage PlanA
  .\scripts\Invoke-PopeyeRedisPrivateCutover.ps1 -Stage ApplyA
  .\scripts\Invoke-PopeyeRedisPrivateCutover.ps1 -Stage Spike
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
  [ValidateSet('All', 'PlanA', 'ApplyA', 'Spike', 'ApplyB', 'Health')]
  [string] $Stage = 'All',
  [string] $ResourceGroupName = 'rg-popeye-stage1-stage2-eastus2',
  [string] $ContainerAppName = 'popeye-stage1-stage2-eastus2-app',
  [string] $TerraformDir = 'envs/azure-eastus2',
  [string] $PrivateEndpointPrefix = '10.60.3.',
  [int] $MinReplicas = 2,
  [int] $ReplicaWaitSeconds = 600,
  [int] $ChunkSize = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$planA = Join-Path $env:TEMP 'stageA.tfplan'
$planB = Join-Path $env:TEMP 'stageB.tfplan'
$spikeScript = 'scripts/Test-PopeyeRedisCompat.py'

function Write-Step([string] $Message) { Write-Host "`n=== $Message ===" -ForegroundColor Cyan }

function Confirm-Yes([string] $Prompt) {
  $answer = Read-Host "$Prompt Type YES to continue"
  if ($answer -cne 'YES') { throw "REQ-GW-06: operator declined at '$Prompt'." }
}

function Invoke-Native([string] $File, [string[]] $Arguments) {
  & $File @Arguments
  if ($LASTEXITCODE -ne 0) { throw "REQ-GW-06: '$File $($Arguments -join ' ')' exited $LASTEXITCODE." }
}

function Invoke-TerraformPlan([string] $OutFile, [string[]] $ExtraArgs) {
  $tfArgs = @("-chdir=$TerraformDir", 'plan', '-input=false', "-out=$OutFile") + $ExtraArgs
  Invoke-Native 'terraform' $tfArgs
  Test-PlanSafety -PlanFile $OutFile
}

function Test-PlanSafety([string] $PlanFile) {
  # JSON plan holds sensitive values: keep it in memory, never write it out.
  $json = & terraform "-chdir=$TerraformDir" show -json $PlanFile
  if ($LASTEXITCODE -ne 0) { throw "REQ-GW-06: terraform show -json failed for $PlanFile." }
  $plan = $json | ConvertFrom-Json -Depth 100
  $rc = if ($plan.PSObject.Properties['resource_changes']) { $plan.resource_changes } else { @() }
  $changes = @($rc | Where-Object { $_.change.actions -notcontains 'no-op' -and $_.change.actions -notcontains 'read' })

  Write-Host "`nPlanned changes:"
  foreach ($c in $changes) { Write-Host ("  {0,-22} {1}" -f ($c.change.actions -join '/'), $c.address) }

  $stops = [System.Collections.Generic.List[string]]::new()
  foreach ($c in $changes) {
    if ($c.type -eq 'azurerm_postgresql_flexible_server' -and $c.change.actions -contains 'delete') {
      $stops.Add("Postgres destroy/replace: $($c.address)")
    }
    if ($c.address -match 'salt_key') { $stops.Add("salt key change: $($c.address)") }
    if ($c.type -eq 'azurerm_container_app' -and $c.change.before -and $c.change.after) {
      $before = @($c.change.before.template | ForEach-Object { $_.container } | ForEach-Object { $_.image })
      $after = @($c.change.after.template | ForEach-Object { $_.container } | ForEach-Object { $_.image })
      if (($before -join ',') -ne ($after -join ',')) { $stops.Add("container image change: $($c.address)") }
    }
  }
  if ($stops.Count) {
    $stops | ForEach-Object { Write-Host "STOP: $_" -ForegroundColor Red }
    Remove-Item $PlanFile -ErrorAction SilentlyContinue
    throw 'REQ-GW-06: plan violates a stop condition (Postgres, salt key or image). Plan file deleted; do not apply.'
  }
  Write-Host 'PASS: no Postgres destroy/replace, no salt key change, no image change.' -ForegroundColor Green
}

function Get-ActiveRevision {
  $rev = az containerapp revision list -n $ContainerAppName -g $ResourceGroupName `
    --query "[?properties.active] | sort_by(@, &properties.createdTime)[-1].name" -o tsv
  if ($LASTEXITCODE -ne 0 -or -not $rev) { throw 'REQ-GW-06: could not find the active revision.' }
  $rev.Trim()
}

function Restart-ActiveRevision {
  $rev = Get-ActiveRevision
  Write-Host "Restarting revision $rev"
  Invoke-Native 'az' @('containerapp', 'revision', 'restart', '-n', $ContainerAppName, '-g', $ResourceGroupName, '--revision', $rev, '-o', 'none')
  Wait-Replicas -Revision $rev
}

function Wait-Replicas([string] $Revision) {
  $deadline = (Get-Date).AddSeconds($ReplicaWaitSeconds)
  do {
    Start-Sleep -Seconds 15
    $states = @(az containerapp replica list -n $ContainerAppName -g $ResourceGroupName --revision $Revision `
        --query '[].properties.runningState' -o tsv 2>$null)
    $running = @($states | Where-Object { $_ -eq 'Running' }).Count
    Write-Host "  replicas Running: $running / $($states.Count)"
    if ($running -ge $MinReplicas) { Write-Host "PASS: $running replicas Running on $Revision" -ForegroundColor Green; return }
  } while ((Get-Date) -lt $deadline)
  throw "REQ-GW-06: fewer than $MinReplicas Running replicas on $Revision after $ReplicaWaitSeconds s."
}

function Invoke-ReplicaCommand([string] $Command) {
  & az containerapp exec -n $ContainerAppName -g $ResourceGroupName --command $Command
}

function Invoke-InReplica([string] $PythonCode) {
  # exec splits its command on spaces and uses no shell, and the command travels in
  # the URL (IIS answers 404 past ~2 KB), so ship zlib+base64 and stage long payloads
  # in /tmp in chunks.
  $raw = [Text.Encoding]::UTF8.GetBytes($PythonCode)
  $buffer = [IO.MemoryStream]::new()
  $zlib = [IO.Compression.ZLibStream]::new($buffer, [IO.Compression.CompressionLevel]::SmallestSize)
  $zlib.Write($raw, 0, $raw.Length)
  $zlib.Dispose()
  $b64 = [Convert]::ToBase64String($buffer.ToArray())
  $decode = "__import__('zlib').decompress(__import__('base64').b64decode(PAYLOAD))"

  if ($b64.Length -le $ChunkSize) {
    Invoke-ReplicaCommand ("python -c exec({0})" -f $decode.Replace('PAYLOAD', "'$b64'"))
    return
  }
  $stage = '/tmp/popeye-spike.b64'
  for ($i = 0; $i -lt $b64.Length; $i += $ChunkSize) {
    $chunk = $b64.Substring($i, [Math]::Min($ChunkSize, $b64.Length - $i))
    $mode = if ($i -eq 0) { 'w' } else { 'a' }
    Invoke-ReplicaCommand "python -c open('$stage','$mode').write('$chunk')"
  }
  Invoke-ReplicaCommand ("python -c exec({0})" -f $decode.Replace('PAYLOAD', "open('$stage').read()"))
  Invoke-ReplicaCommand "python -c __import__('os').remove('$stage')"
}

function Invoke-Spike {
  $dns = @"
import os, socket
ip = socket.gethostbyname(os.environ['REDIS_HOST'])
print(('PASS' if ip.startswith('$PrivateEndpointPrefix') else 'FAIL') + ': REDIS_HOST resolves into ' + '.'.join(ip.split('.')[:3]) + '.0/27 range')
"@
  Write-Step 'Spike: private DNS check'
  Invoke-InReplica $dns
  Write-Step 'Spike: Test-PopeyeRedisCompat.py'
  Invoke-InReplica (Get-Content -Raw $spikeScript)
  Write-Host "`nAll rows above must be PASS. On MOVED/CROSSSLOT/ResponseError set redis_clustering_policy = `"EnterpriseCluster`" in terraform.tfvars and rerun PlanA, ApplyA, Spike." -ForegroundColor Yellow
  Confirm-Yes 'Did every spike row PASS?'
}

function Invoke-PlanA {
  Write-Step 'Stage A plan (private endpoint, public access still Enabled)'
  Invoke-TerraformPlan -OutFile $planA -ExtraArgs @('-var', 'redis_public_network_access=Enabled')
  Write-Host 'Expected: creates for subnet, privatelink.redis.azure.net zone + link, private endpoint; Redis replacement and redis-password secret update are acceptable.'
}

function Invoke-ApplyA {
  if (-not (Test-Path $planA)) { throw "REQ-GW-06: $planA not found; run -Stage PlanA first." }
  Confirm-Yes 'Apply the reviewed stage A plan?'
  Write-Step 'Stage A apply'
  try { Invoke-Native 'terraform' @("-chdir=$TerraformDir", 'apply', '-input=false', $planA) }
  finally { Remove-Item $planA -ErrorAction SilentlyContinue }
  Restart-ActiveRevision
}

function Invoke-ApplyB {
  Write-Step 'Stage B plan (public access Disabled)'
  Invoke-TerraformPlan -OutFile $planB -ExtraArgs @()
  Confirm-Yes 'Apply stage B (disable Redis public network access)?'
  try { Invoke-Native 'terraform' @("-chdir=$TerraformDir", 'apply', '-input=false', $planB) }
  finally { Remove-Item $planB -ErrorAction SilentlyContinue }

  $redisId = az resource list -g $ResourceGroupName --resource-type Microsoft.Cache/redisEnterprise --query '[0].id' -o tsv
  $pna = az resource show --ids $redisId --query properties.publicNetworkAccess -o tsv
  if ($pna -ne 'Disabled') { throw "REQ-GW-06: Redis publicNetworkAccess is '$pna', expected Disabled." }
  Write-Host 'PASS: Redis publicNetworkAccess = Disabled (GW-06)' -ForegroundColor Green
}

function Invoke-Health {
  Write-Step 'Health after stage B (D-16 step 2)'
  Restart-ActiveRevision

  Write-Step 'Readiness from inside a replica'
  Invoke-InReplica @"
import urllib.request
print('readiness status:', urllib.request.urlopen('http://localhost:4000/health/readiness', timeout=10).status)
"@

  Write-Step 'Console logs (last 200 lines)'
  $logs = az containerapp logs show -n $ContainerAppName -g $ResourceGroupName --type console --tail 200 --format text 2>$null
  $bad = @($logs | Select-String -Pattern 'ConnectionError|MOVED|CROSSSLOT')
  if ($bad.Count) { throw "REQ-GW-06: $($bad.Count) ConnectionError/MOVED/CROSSSLOT log lines after stage B." }
  Write-Host 'PASS: no ConnectionError/MOVED/CROSSSLOT in the last 200 console lines' -ForegroundColor Green

  Invoke-Spike

  Write-Step 'Drift check'
  & terraform "-chdir=$TerraformDir" plan -input=false -detailed-exitcode
  if ($LASTEXITCODE -ne 0) { throw "REQ-GW-06: terraform plan -detailed-exitcode returned $LASTEXITCODE (0 expected, 2 = drift)." }
  Write-Host 'PASS: terraform plan shows no drift' -ForegroundColor Green
}

if (-not (Test-Path (Join-Path $TerraformDir '.terraform'))) {
  throw "REQ-GW-06: $TerraformDir is not initialised; run terraform -chdir=$TerraformDir init first."
}
if (-not (Test-Path $spikeScript)) { throw "REQ-GW-06: run from the repo root ($spikeScript not found)." }
az account show -o none
if ($LASTEXITCODE -ne 0) { throw 'REQ-GW-06: not logged in to az; run az login.' }

switch ($Stage) {
  'PlanA' { Invoke-PlanA }
  'ApplyA' { Invoke-ApplyA }
  'Spike' { Invoke-Spike }
  'ApplyB' { Invoke-ApplyB }
  'Health' { Invoke-Health }
  'All' {
    Invoke-PlanA
    Invoke-ApplyA
    Invoke-Spike
    Invoke-ApplyB
    Invoke-Health
    Write-Host "`nDone. Reply 'approved' with the clustering policy and the spike PASS rows (no IPs beyond /27)." -ForegroundColor Green
  }
}
