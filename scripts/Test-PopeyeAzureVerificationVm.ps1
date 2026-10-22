<#
.SYNOPSIS
  Performs read-only Azure control-plane validation for the temporary Popeye
  PostgreSQL private-connectivity verification VM.

.DESCRIPTION
  This script never creates, changes, or deletes Azure resources and never
  reads Key Vault secret values. It locates the target VNet, Flexible Server,
  DNS configuration, Bastion, VM, NICs, RBAC assignments, NSGs, and UDRs and
  writes a redacted JSON evidence file. VM-side DNS/TCP checks are deliberately
  left to Test-PopeyeVerificationVm.ps1 from an Azure Bastion session.

  Supply -VmName after Networking has provisioned the temporary VM.  If more
  than one resource group contains the Popeye VNet, supply -ResourceGroupName.

.EXAMPLE
  .\scripts\Test-PopeyeAzureVerificationVm.ps1 -VmName popeye-net-verify-01
#>
[CmdletBinding()]
param(
  [string] $SubscriptionId,
  [string] $ResourceGroupName = 'rg-popeye-stage1-stage2-eastus2',
  [string] $VmName,
  [string] $VnetName = 'vnet-popeye-stage1-stage2-eastus2',
  [string] $PostgresServerName = 'pg-popeye-stage1-stage2-eastus2',
  [string] $PostgresFqdn = 'pg-popeye-stage1-stage2-eastus2.postgres.database.azure.com',
  [string[]] $ApprovedOperatorDisplayNames = @('Oscar Mack', 'Roger'),
  [string] $EvidencePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

$accountArgs = @('account','show','--output','json')
if ($SubscriptionId) { $accountArgs += @('--subscription',$SubscriptionId) }
$account = Invoke-AzJson $accountArgs
$subscription = if ($SubscriptionId) { $SubscriptionId } else { $account.id }
$checks = [System.Collections.Generic.List[object]]::new()
$evidence = [ordered]@{ validationUtc = (Get-Date).ToUniversalTime().ToString('o'); subscriptionId = $subscription; postgresFqdn = $PostgresFqdn }

$resourceGroup = $ResourceGroupName
$vnet = Invoke-AzJson @('network','vnet','show','--resource-group',$resourceGroup,'--name',$VnetName,'--subscription',$subscription,'--output','json')
$evidence.resourceGroup = $resourceGroup
$evidence.vnet = [ordered]@{ name = $vnet.name; id = $vnet.id; addressPrefixes = @($vnet.addressSpace.addressPrefixes) }
$checks.Add((New-Check 'Popeye VNet located' $true "$($vnet.name) in $resourceGroup"))

$server = Invoke-AzJson @('postgres','flexible-server','show','--resource-group',$resourceGroup,'--name',$PostgresServerName,'--subscription',$subscription,'--output','json')
$publicAccessDisabled = ($server.network.publicNetworkAccess -eq 'Disabled')
$checks.Add((New-Check 'PostgreSQL public network access disabled' $publicAccessDisabled "publicNetworkAccess=$($server.network.publicNetworkAccess)"))
$evidence.postgres = [ordered]@{ id=$server.id; fqdn=$server.fullyQualifiedDomainName; publicNetworkAccess=$server.network.publicNetworkAccess; delegatedSubnetId=$server.network.delegatedSubnetResourceId; privateDnsZoneId=$server.network.privateDnsZoneArmResourceId }

$privateDnsZoneId = [string]$server.network.privateDnsZoneArmResourceId
$dnsModel = if ($privateDnsZoneId) { 'VNet-integrated Flexible Server' } else { 'Private Endpoint (or unresolved: no server private DNS zone)' }
$zoneName = if ($privateDnsZoneId) { ($privateDnsZoneId -split '/')[-1] } else { 'privatelink.postgres.database.azure.com' }
$zoneRg = if ($privateDnsZoneId) { Get-ResourceGroupFromId $privateDnsZoneId } else { $null }
if (-not $zoneRg) {
  $zones = @(Invoke-AzJson @('resource','list','--subscription',$subscription,'--resource-type','Microsoft.Network/privateDnsZones','--name',$zoneName,'--output','json'))
  if ($zones.Count -eq 1) { $zoneRg = $zones[0].resourceGroup; $privateDnsZoneId = $zones[0].id }
}
$evidence.privateDns = [ordered]@{ model=$dnsModel; zoneName=$zoneName; zoneId=$privateDnsZoneId }
if ($zoneRg) {
  $links = @(Invoke-AzJson @('network','private-dns','link','vnet','list','--resource-group',$zoneRg,'--zone-name',$zoneName,'--subscription',$subscription,'--output','json'))
  $linked = @($links | Where-Object { $_.virtualNetwork.id -eq $vnet.id }).Count -gt 0
  $checks.Add((New-Check 'Private DNS zone linked to Popeye VNet' $linked "model=$dnsModel; zone=$zoneName"))
  $evidence.privateDns.links = @($links | Select-Object name, @{n='virtualNetworkId';e={$_.virtualNetwork.id}}, registrationEnabled)
} else { $checks.Add((New-Check 'Private DNS zone linked to Popeye VNet' $false "Could not locate zone '$zoneName'.")) }

# Older Azure CLI builds have no `az network bastion` group.  ARM list is
# read-only and keeps the validator compatible with those installations.
$bastionResponse = Invoke-AzJson @('rest','--method','get','--url',"https://management.azure.com/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.Network/bastionHosts?api-version=2024-01-01",'--output','json')
$bastions = @($bastionResponse.value | Where-Object { $_.properties.ipConfigurations.subnet.id -like "$($vnet.id)/*" })
$bastionSubnet = @($vnet.subnets | Where-Object name -eq 'AzureBastionSubnet')
$bastionPrefixOkay = $false
$prefix = $null
if ($bastionSubnet.Count -eq 1) {
  $prefix = if ($bastionSubnet[0].addressPrefix) { $bastionSubnet[0].addressPrefix } else { $bastionSubnet[0].addressPrefixes[0] }
  $bastionPrefixOkay = ([int](($prefix -split '/')[-1])) -le 26
}
$bastionNames = @($bastions | ForEach-Object { $_.name })
$checks.Add((New-Check 'Bastion exists in Popeye VNet' ($bastions.Count -gt 0) "Bastion hosts: $($bastionNames -join ', ')"))
$checks.Add((New-Check 'AzureBastionSubnet is /26 or larger when present' $bastionPrefixOkay "Subnet prefix: $prefix"))
$evidence.bastion = [ordered]@{ hosts=@($bastions | Select-Object name,id); subnet=@($bastionSubnet | Select-Object name,addressPrefix,addressPrefixes) }

if ($VmName) {
  $vm = Invoke-AzJson @('vm','show','--resource-group',$resourceGroup,'--name',$VmName,'--subscription',$subscription,'--show-details','--output','json')
  $evidence.vm = [ordered]@{ id=$vm.id; name=$vm.name; location=$vm.location; powerState=$vm.powerState; osType=$vm.storageProfile.osDisk.osType; imageReference=$vm.storageProfile.imageReference }
  $checks.Add((New-Check 'Verification VM runs Windows' ($vm.storageProfile.osDisk.osType -eq 'Windows') "osType=$($vm.storageProfile.osDisk.osType)"))
  $nics = @($vm.networkProfile.networkInterfaces | ForEach-Object { Invoke-AzJson @('network','nic','show','--ids',$_.id,'--subscription',$subscription,'--output','json') })
  $hasPublicIp = @($nics.ipConfigurations | Where-Object { $_.publicIpAddress }).Count -gt 0
  $checks.Add((New-Check 'Verification VM has no public IP' (-not $hasPublicIp) "NICs: $((@($nics.name) -join ', '))"))
  $subnetIds = @($nics.ipConfigurations.subnet.id | Select-Object -Unique)
  $vmSubnet = @($vnet.subnets | Where-Object { $subnetIds -contains $_.id })
  $nonDelegated = ($vmSubnet.Count -eq 1 -and @($vmSubnet[0].delegations).Count -eq 0)
  $checks.Add((New-Check 'VM is in one isolated non-delegated VNet subnet' $nonDelegated "Subnet(s): $((@($vmSubnet.name) -join ', ')); delegations=$((@($vmSubnet[0].delegations.serviceName) -join ', '))"))
  $extensions = @(Invoke-AzJson @('vm','extension','list','--resource-group',$resourceGroup,'--vm-name',$VmName,'--subscription',$subscription,'--output','json'))
  $entraExtension = @($extensions | Where-Object { $_.publisher -eq 'Microsoft.Azure.ActiveDirectory' -and $_.type -eq 'AADLoginForWindows' }).Count -gt 0
  $checks.Add((New-Check 'Entra ID Windows sign-in extension enabled' $entraExtension "Extensions: $((@($extensions | ForEach-Object { "$($_.publisher)/$($_.type)" }) -join ', '))"))
  $assignedNsgs = @($nics.networkSecurityGroup.id) + @($vmSubnet.networkSecurityGroup.id) | Where-Object { $_ } | Select-Object -Unique
  $nsgRules = @($assignedNsgs | ForEach-Object { Invoke-AzJson @('network','nsg','show','--ids',$_,'--subscription',$subscription,'--output','json') } | ForEach-Object { $_.securityRules + $_.defaultSecurityRules })
  $rdpAllow = @($nsgRules | Where-Object { $_.direction -eq 'Inbound' -and $_.access -eq 'Allow' -and ($_.destinationPortRange -eq '3389' -or $_.destinationPortRanges -contains '3389') })
  $checks.Add((New-Check 'No NSG rule directly allows inbound RDP' ($rdpAllow.Count -eq 0) "Matching rules: $((@($rdpAllow.name) -join ', '))"))
  $evidence.networkSecurityGroups = @($assignedNsgs)
  $evidence.userDefinedRoutes = @($vmSubnet.routeTable.id)
  $roleAssignments = @(Invoke-AzJson @('role','assignment','list','--all','--include-inherited','--scope',$vm.id,'--subscription',$subscription,'--output','json'))
  $loginAssignments = @($roleAssignments | Where-Object { $_.roleDefinitionName -in @('Virtual Machine User Login','Virtual Machine Administrator Login') })
  $evidence.vmLoginAssignments = @($loginAssignments | Select-Object principalName,principalType,roleDefinitionName,scope)
  $operatorNames = @($loginAssignments.principalName | Where-Object { $_ })
  $onlyApproved = $loginAssignments.Count -gt 0 -and @($operatorNames | Where-Object { $_ -notin $ApprovedOperatorDisplayNames }).Count -eq 0
  $checks.Add((New-Check 'VM-login RBAC is limited to approved operators' $onlyApproved "Assignments: $((@($loginAssignments | ForEach-Object { "$($_.principalName):$($_.roleDefinitionName)" }) -join ', '))"))
} else {
  $checks.Add((New-Check 'Verification VM-specific checks' $false 'Not run: rerun with -VmName after provisioning.'))
}

$evidence.checks = @($checks)
$evidenceDirectory = Split-Path -Parent $EvidencePath
if (-not (Test-Path -LiteralPath $evidenceDirectory)) { New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null }
$evidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $EvidencePath -Encoding utf8
$checks | Format-Table -AutoSize
Write-Host "Evidence written to $EvidencePath"
if (@($checks | Where-Object Status -eq 'FAIL').Count -gt 0) { exit 1 }
