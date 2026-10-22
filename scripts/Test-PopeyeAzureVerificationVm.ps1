<#
.SYNOPSIS
  Performs read-only Azure control-plane validation for the peered-caller
  Popeye PostgreSQL / gateway private-connectivity verification VM
  (NET-01..NET-06).

.DESCRIPTION
  This script never creates, changes, or deletes Azure resources and never
  reads Key Vault secret values. It verifies the networking-owned peering
  between the caller VNet and the Popeye VNet, private DNS zones and links on
  both VNets, the Container Apps environment zone, the verification VM
  (no public IP, Bastion-only RDP, Entra login) and the VM login roles. It
  writes a redacted JSON evidence file. VM-side DNS/TCP checks are left to
  Test-PopeyeVerificationVm.ps1.

  Peering, the RDP NSG rule and VM login roles are networking actions (D-17);
  this script only verifies and records. Environment defaultDomain and staticIp
  are always derived from the live environment, never hardcoded.

.EXAMPLE
  .\scripts\Test-PopeyeAzureVerificationVm.ps1 -VmName EUS-VM-POPEYE `
    -CallerResourceGroupName <caller rg> -VmResourceGroupName <vm rg> `
    -ApprovedOperatorDisplayNames 'Oscar Mack','Roger'
#>
[CmdletBinding()]
param(
  [string] $SubscriptionId,
  [string] $CallerVnetName = 'EUS-POPEYE-VNET-01',
  [string] $CallerResourceGroupName,
  [string] $VmResourceGroupName,
  [Alias('VnetName')]
  [string] $PopeyeVnetName = 'vnet-popeye-stage1-stage2-eastus2',
  [Alias('ResourceGroupName')]
  [string] $PopeyeResourceGroupName = 'rg-popeye-stage1-stage2-eastus2',
  [string] $VmName,
  [string] $PostgresServerName = 'pg-popeye-stage1-stage2-eastus2',
  [string] $PostgresFqdn = 'pg-popeye-stage1-stage2-eastus2.postgres.database.azure.com',
  [Parameter(Mandatory)]
  [string[]] $ApprovedOperatorDisplayNames,
  [string] $ContainerAppsEnvironmentName = 'popeye-stage1-stage2-eastus2-env',
  [string] $BastionSubnetName = 'AzureBastionSubnet',
  [string] $AdministratorLoginApproval,
  [string] $EvidencePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (@($ApprovedOperatorDisplayNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -lt 2) {
  throw 'NET-06: -ApprovedOperatorDisplayNames must contain both approved operators.'
}
if ([string]::IsNullOrWhiteSpace($CallerResourceGroupName)) { $CallerResourceGroupName = $PopeyeResourceGroupName }
if ([string]::IsNullOrWhiteSpace($VmResourceGroupName)) { $VmResourceGroupName = $CallerResourceGroupName }

if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
  $EvidencePath = Join-Path (Split-Path -Parent $PSCommandPath) '..\artifacts\popeye-azure-verification-evidence.json'
}

function Invoke-AzJson {
  param([Parameter(Mandatory)][string[]] $Arguments)
  # Azure CLI may emit non-fatal extension warnings on stderr. Keep stdout as
  # JSON so ConvertFrom-Json is not corrupted by those warnings.
  $priorErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $raw = & az @Arguments 2>$null
  $ErrorActionPreference = $priorErrorActionPreference
  if ($LASTEXITCODE -ne 0) { throw "az $($Arguments -join ' ') failed with exit code $LASTEXITCODE." }
  if ([string]::IsNullOrWhiteSpace(($raw -join "`n"))) { return $null }
  return (($raw -join "`n") | ConvertFrom-Json)
}

function New-Check {
  param([string]$Name, [bool]$Passed, [string]$Detail)
  [pscustomobject]@{ Check = $Name; Status = if ($Passed) { 'PASS' } else { 'FAIL' }; Detail = $Detail }
}

function Get-ResourceGroupFromId { param([string]$Id); (($Id -split '/')[4]) }

function Get-SubnetPrefix {
  param($Subnet)
  if ($Subnet.addressPrefix) { return [string]$Subnet.addressPrefix }
  return [string]@($Subnet.addressPrefixes)[0]
}

$accountArgs = @('account','show','--output','json')
if ($SubscriptionId) { $accountArgs += @('--subscription',$SubscriptionId) }
$account = Invoke-AzJson $accountArgs
$subscription = if ($SubscriptionId) { $SubscriptionId } else { $account.id }
$checks = [System.Collections.Generic.List[object]]::new()
$evidence = [ordered]@{ validationUtc = (Get-Date).ToUniversalTime().ToString('o'); subscriptionId = $subscription; postgresFqdn = $PostgresFqdn }

# --- VNets ------------------------------------------------------------------
$popeyeVnet = Invoke-AzJson @('network','vnet','show','--resource-group',$PopeyeResourceGroupName,'--name',$PopeyeVnetName,'--subscription',$subscription,'--output','json')
$evidence.popeyeVnet = [ordered]@{ name = $popeyeVnet.name; id = $popeyeVnet.id; resourceGroup = $PopeyeResourceGroupName; addressPrefixes = @($popeyeVnet.addressSpace.addressPrefixes) }
$checks.Add((New-Check 'Popeye VNet located' $true "$($popeyeVnet.name) in $PopeyeResourceGroupName"))

$callerVnet = $null
try {
  $callerVnet = Invoke-AzJson @('network','vnet','show','--resource-group',$CallerResourceGroupName,'--name',$CallerVnetName,'--subscription',$subscription,'--output','json')
  $evidence.callerVnet = [ordered]@{ name = $callerVnet.name; id = $callerVnet.id; resourceGroup = $CallerResourceGroupName; addressPrefixes = @($callerVnet.addressSpace.addressPrefixes) }
  $checks.Add((New-Check 'Caller VNet located' $true "$($callerVnet.name) in $CallerResourceGroupName"))
}
catch { $checks.Add((New-Check 'Caller VNet located' $false $_.Exception.Message)) }

$vnetIds = @($popeyeVnet.id)
if ($callerVnet) { $vnetIds += $callerVnet.id }

# --- NET-01 peering ---------------------------------------------------------
try {
  $peeringEvidence = [System.Collections.Generic.List[object]]::new()
  $peeringOk = $true
  $peeringDetail = [System.Collections.Generic.List[string]]::new()
  $sides = @(
    @{ Rg = $PopeyeResourceGroupName; Vnet = $PopeyeVnetName; Remote = $callerVnet },
    @{ Rg = $CallerResourceGroupName; Vnet = $CallerVnetName; Remote = $popeyeVnet }
  )
  foreach ($side in $sides) {
    $peerings = @(Invoke-AzJson @('network','vnet','peering','list','--resource-group',$side.Rg,'--vnet-name',$side.Vnet,'--subscription',$subscription,'--output','json'))
    $toRemote = @($peerings | Where-Object { $side.Remote -and $_.remoteVirtualNetwork.id -eq $side.Remote.id })
    if ($toRemote.Count -eq 0) { $peeringOk = $false; $peeringDetail.Add("$($side.Vnet): no peering to remote VNet"); continue }
    foreach ($p in $toRemote) {
      $good = ($p.peeringState -eq 'Connected' -and $p.peeringSyncLevel -eq 'FullyInSync' -and $p.allowVirtualNetworkAccess -eq $true)
      if (-not $good) { $peeringOk = $false }
      $peeringDetail.Add("$($side.Vnet)/$($p.name): state=$($p.peeringState) sync=$($p.peeringSyncLevel) allowVnetAccess=$($p.allowVirtualNetworkAccess)")
      $peeringEvidence.Add([ordered]@{ vnet = $side.Vnet; name = $p.name; peeringState = $p.peeringState; peeringSyncLevel = $p.peeringSyncLevel; allowVirtualNetworkAccess = $p.allowVirtualNetworkAccess })
    }
  }
  $evidence.peerings = @($peeringEvidence)
  $checks.Add((New-Check 'NET-01 peering Connected and FullyInSync both ways' $peeringOk ($peeringDetail -join '; ')))
}
catch { $checks.Add((New-Check 'NET-01 peering Connected and FullyInSync both ways' $false $_.Exception.Message)) }

try {
  $stateDetail = 'ownership: networking-owned (not in Terraform state); state not accessible'
  $stateNote = 'skipped'
  if (Get-Command terraform -ErrorAction SilentlyContinue) {
    $prior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $stateList = & terraform -chdir=envs/azure-eastus2 state list 2>$null
    $tfExit = $LASTEXITCODE
    $ErrorActionPreference = $prior
    if ($tfExit -eq 0) {
      $peeringInState = @($stateList | Where-Object { $_ -match 'peering' })
      if ($peeringInState.Count -eq 0) { $stateDetail = 'ownership: networking-owned (not in Terraform state)'; $stateNote = 'no peering in state' }
      else { $stateDetail = "ownership: peering resources found in Terraform state: $($peeringInState -join ', ')"; $stateNote = 'peering in state' }
    }
  }
  $evidence.peeringOwnership = [ordered]@{ detail = $stateDetail; stateCheck = $stateNote }
  # Informational: never FAIL when state is unavailable.
  $checks.Add((New-Check 'NET-01 peering ownership recorded' $true $stateDetail))
}
catch { $checks.Add((New-Check 'NET-01 peering ownership recorded' $true "state not accessible: $($_.Exception.Message)")) }

# --- NET-02 Postgres private DNS -------------------------------------------
$server = $null
try {
  $server = Invoke-AzJson @('postgres','flexible-server','show','--resource-group',$PopeyeResourceGroupName,'--name',$PostgresServerName,'--subscription',$subscription,'--output','json')
  $publicAccessDisabled = ($server.network.publicNetworkAccess -eq 'Disabled')
  $evidence.postgres = [ordered]@{ id=$server.id; fqdn=$server.fullyQualifiedDomainName; publicNetworkAccess=$server.network.publicNetworkAccess; delegatedSubnetId=$server.network.delegatedSubnetResourceId; privateDnsZoneId=$server.network.privateDnsZoneArmResourceId }

  $privateDnsZoneId = [string]$server.network.privateDnsZoneArmResourceId
  $zoneName = if ($privateDnsZoneId) { ($privateDnsZoneId -split '/')[-1] } else { 'privatelink.postgres.database.azure.com' }
  $zoneRg = if ($privateDnsZoneId) { Get-ResourceGroupFromId $privateDnsZoneId } else { $null }
  if (-not $zoneRg) {
    $zones = @(Invoke-AzJson @('resource','list','--subscription',$subscription,'--resource-type','Microsoft.Network/privateDnsZones','--name',$zoneName,'--output','json'))
    if ($zones.Count -eq 1) { $zoneRg = $zones[0].resourceGroup; $privateDnsZoneId = $zones[0].id }
  }
  $evidence.privateDns = [ordered]@{ zoneName=$zoneName; zoneId=$privateDnsZoneId }
  $linkedAll = $false
  $linkDetail = "Could not locate zone '$zoneName'."
  if ($zoneRg) {
    $links = @(Invoke-AzJson @('network','private-dns','link','vnet','list','--resource-group',$zoneRg,'--zone-name',$zoneName,'--subscription',$subscription,'--output','json'))
    $linkedIds = @($links | ForEach-Object { $_.virtualNetwork.id })
    $missing = @($vnetIds | Where-Object { $_ -notin $linkedIds })
    $linkedAll = ($missing.Count -eq 0 -and $callerVnet)
    $linkDetail = "zone=$zoneName; linked VNets: $(@($links | ForEach-Object { ($_.virtualNetwork.id -split '/')[-1] }) -join ', '); missing: $(@($missing | ForEach-Object { ($_ -split '/')[-1] }) -join ', ')"
    $evidence.privateDns.links = @($links | Select-Object name, @{n='virtualNetworkId';e={$_.virtualNetwork.id}}, registrationEnabled)
  }
  $checks.Add((New-Check 'NET-02 Postgres private DNS zone linked to both VNets' ([bool]$linkedAll) $linkDetail))
  $checks.Add((New-Check 'NET-02 PostgreSQL public network access disabled' $publicAccessDisabled "publicNetworkAccess=$($server.network.publicNetworkAccess)"))
}
catch { $checks.Add((New-Check 'NET-02 Postgres private DNS and public access' $false $_.Exception.Message)) }

# --- NET-03 Container Apps environment zone ---------------------------------
try {
  $envInfo = Invoke-AzJson @('containerapp','env','show','--resource-group',$PopeyeResourceGroupName,'--name',$ContainerAppsEnvironmentName,'--subscription',$subscription,'--output','json')
  $defaultDomain = [string]$envInfo.properties.defaultDomain
  $staticIp = [string]$envInfo.properties.staticIp
  if ([string]::IsNullOrWhiteSpace($defaultDomain) -or [string]::IsNullOrWhiteSpace($staticIp)) { throw 'defaultDomain or staticIp missing from environment.' }
  $evidence.containerAppsEnvironment = [ordered]@{ name = $ContainerAppsEnvironmentName; defaultDomain = $defaultDomain; staticIp = $staticIp }
  $envZones = @(Invoke-AzJson @('resource','list','--subscription',$subscription,'--resource-type','Microsoft.Network/privateDnsZones','--name',$defaultDomain,'--output','json'))
  if ($envZones.Count -eq 0) {
    $checks.Add((New-Check 'NET-03 environment private DNS zone' $false 'zone missing: networking action pending'))
  }
  else {
    $envZone = $envZones[0]
    $records = @(Invoke-AzJson @('network','private-dns','record-set','a','list','--resource-group',$envZone.resourceGroup,'--zone-name',$defaultDomain,'--subscription',$subscription,'--output','json'))
    $wild = @($records | Where-Object { $_.name -eq '*' -and @($_.aRecords.ipv4Address) -contains $staticIp })
    $apex = @($records | Where-Object { $_.name -eq '@' -and @($_.aRecords.ipv4Address) -contains $staticIp })
    $envLinks = @(Invoke-AzJson @('network','private-dns','link','vnet','list','--resource-group',$envZone.resourceGroup,'--zone-name',$defaultDomain,'--subscription',$subscription,'--output','json'))
    $envLinkedIds = @($envLinks | ForEach-Object { $_.virtualNetwork.id })
    $envMissing = @($vnetIds | Where-Object { $_ -notin $envLinkedIds })
    $envOk = ($wild.Count -gt 0 -and $apex.Count -gt 0 -and $envMissing.Count -eq 0 -and $callerVnet)
    $checks.Add((New-Check 'NET-03 environment private DNS zone, records and links' ([bool]$envOk) "zone=$defaultDomain; wildcard A ok=$($wild.Count -gt 0); apex A ok=$($apex.Count -gt 0); VNets missing link: $(@($envMissing | ForEach-Object { ($_ -split '/')[-1] }) -join ', ')"))
    $evidence.containerAppsEnvironment.zoneResourceGroup = $envZone.resourceGroup
  }
}
catch { $checks.Add((New-Check 'NET-03 environment private DNS zone' $false $_.Exception.Message)) }

# --- NET-05 / NET-06 VM checks ---------------------------------------------
if ($VmName) {
  try {
    $vm = Invoke-AzJson @('vm','show','--resource-group',$VmResourceGroupName,'--name',$VmName,'--subscription',$subscription,'--show-details','--output','json')
    $evidence.vm = [ordered]@{ id=$vm.id; name=$vm.name; location=$vm.location; powerState=$vm.powerState; osType=$vm.storageProfile.osDisk.osType }
    $checks.Add((New-Check 'Verification VM runs Windows' ($vm.storageProfile.osDisk.osType -eq 'Windows') "osType=$($vm.storageProfile.osDisk.osType)"))
    $nics = @($vm.networkProfile.networkInterfaces | ForEach-Object { Invoke-AzJson @('network','nic','show','--ids',$_.id,'--subscription',$subscription,'--output','json') })

    # NET-05
    $hasPublicIp = @($nics.ipConfigurations | Where-Object { $_.publicIpAddress }).Count -gt 0
    $checks.Add((New-Check 'NET-05 VM has no public IP' (-not $hasPublicIp) "NICs: $((@($nics.name) -join ', '))"))

    $bastionPrefix = $null
    $bastionOk = $false
    if ($callerVnet) {
      $bs = @($callerVnet.subnets | Where-Object name -eq $BastionSubnetName)
      if ($bs.Count -eq 1) {
        $bastionPrefix = Get-SubnetPrefix $bs[0]
        $bastionOk = ([int](($bastionPrefix -split '/')[-1])) -le 26
      }
    }
    $checks.Add((New-Check 'NET-05 Bastion subnet is /26 or larger' $bastionOk "Subnet $BastionSubnetName prefix: $bastionPrefix"))
    $evidence.bastionSubnet = [ordered]@{ name = $BastionSubnetName; prefix = $bastionPrefix }

    $subnetIds = @($nics.ipConfigurations.subnet.id | Select-Object -Unique)
    $vmSubnet = @()
    if ($callerVnet) { $vmSubnet = @($callerVnet.subnets | Where-Object { $subnetIds -contains $_.id }) }
    $bastionCidrs = @()
    if ($callerVnet) { $bastionCidrs = @($callerVnet.subnets | Where-Object name -eq $BastionSubnetName | ForEach-Object { Get-SubnetPrefix $_ }) }
    $nsgIds = @(@($nics.networkSecurityGroup.id) + @($vmSubnet.networkSecurityGroup.id) | Where-Object { $_ } | Select-Object -Unique)
    $nsgRules = @($nsgIds | ForEach-Object { Invoke-AzJson @('network','nsg','show','--ids',$_,'--subscription',$subscription,'--output','json') } | ForEach-Object { @($_.securityRules) + @($_.defaultSecurityRules) })
    $rdpAllow = @($nsgRules | Where-Object {
        $_ -and $_.direction -eq 'Inbound' -and $_.access -eq 'Allow' -and
        ($_.destinationPortRange -in @('3389','*') -or @($_.destinationPortRanges) -contains '3389')
      })
    $badRdp = @($rdpAllow | Where-Object {
        $sources = @($_.sourceAddressPrefix) + @($_.sourceAddressPrefixes) | Where-Object { $_ }
        @($sources | Where-Object { $_ -in @('*','Internet','0.0.0.0/0') -or ($_ -notin $bastionCidrs -and $_ -ne 'VirtualNetwork' -and $_ -ne 'AzureLoadBalancer') }).Count -gt 0
      })
    $flagged = @($badRdp | ForEach-Object { $_.name })
    $iliya = if ($flagged -contains 'Allow_Iliya_Promenet') { ' (Allow_Iliya_Promenet present: networking must remove it)' } else { '' }
    $checks.Add((New-Check 'NET-05 RDP 3389 NSG source limited to Bastion subnet' ($badRdp.Count -eq 0) "Non-Bastion allow rules: $($flagged -join ', ')$iliya"))
    $evidence.networkSecurityGroups = @($nsgIds)

    $extensions = @(Invoke-AzJson @('vm','extension','list','--resource-group',$VmResourceGroupName,'--vm-name',$VmName,'--subscription',$subscription,'--output','json'))
    $entraExtension = @($extensions | Where-Object { $_.publisher -eq 'Microsoft.Azure.ActiveDirectory' -and $_.typePropertiesType -eq 'AADLoginForWindows' -or ($_.publisher -eq 'Microsoft.Azure.ActiveDirectory' -and $_.type -like '*AADLoginForWindows') }).Count -gt 0
    $checks.Add((New-Check 'NET-05 Entra ID Windows sign-in extension enabled' $entraExtension "Extensions: $((@($extensions | ForEach-Object { "$($_.publisher)/$($_.name)" }) -join ', '))"))

    # NET-06
    $roleAssignments = @(Invoke-AzJson @('role','assignment','list','--all','--include-inherited','--scope',$vm.id,'--subscription',$subscription,'--output','json'))
    $userLogin = @($roleAssignments | Where-Object { $_.roleDefinitionName -eq 'Virtual Machine User Login' })
    $adminLogin = @($roleAssignments | Where-Object { $_.roleDefinitionName -eq 'Virtual Machine Administrator Login' })
    $evidence.vmLoginAssignments = @(($userLogin + $adminLogin) | Select-Object principalName,principalType,roleDefinitionName,scope)
    $unapproved = @($userLogin.principalName | Where-Object { $_ -and $_ -notin $ApprovedOperatorDisplayNames })
    $checks.Add((New-Check 'NET-06 VM User Login limited to approved operators' ($unapproved.Count -eq 0) "Unapproved holders: $($unapproved -join ', ')"))
    foreach ($operator in $ApprovedOperatorDisplayNames) {
      $holds = @($userLogin | Where-Object { $_.principalName -eq $operator }).Count -gt 0
      $checks.Add((New-Check "NET-06 operator $operator holds VM User Login" $holds "Virtual Machine User Login at VM scope: $holds"))
    }
    if ($adminLogin.Count -gt 0) {
      $approved = -not [string]::IsNullOrWhiteSpace($AdministratorLoginApproval)
      $evidence.administratorLoginApproval = $AdministratorLoginApproval
      $checks.Add((New-Check 'NET-06 no Virtual Machine Administrator Login unless approved' $approved "Holders: $((@($adminLogin.principalName) -join ', ')); approval recorded: $approved"))
    }
    else {
      $checks.Add((New-Check 'NET-06 no Virtual Machine Administrator Login unless approved' $true 'No administrator login assignments.'))
    }
  }
  catch { $checks.Add((New-Check 'NET-05/NET-06 VM checks' $false $_.Exception.Message)) }
}
else {
  $checks.Add((New-Check 'NET-05/NET-06 VM-specific checks' $false 'Not run: rerun with -VmName.'))
}

$evidence.checks = @($checks)
$evidenceDirectory = Split-Path -Parent $EvidencePath
if (-not (Test-Path -LiteralPath $evidenceDirectory)) { New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null }
$evidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $EvidencePath -Encoding utf8
$checks | Format-Table -AutoSize
Write-Host "Evidence written to $EvidencePath"
if (@($checks | Where-Object Status -eq 'FAIL').Count -gt 0) { exit 1 }
