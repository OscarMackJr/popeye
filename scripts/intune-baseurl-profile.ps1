<#
.SYNOPSIS
  Intune configuration rollout: point desktop agents at the gateway.
  (Roadmap Tier 2; infrastructure plan section 6 — Graph/PowerShell,
  deliberately not Terraform.)

.DESCRIPTION
  Pushes per-user environment configuration to managed Windows
  workstations:
    ANTHROPIC_BASE_URL   -> https://ai-gateway.twg.internal
    (per-user virtual key delivered separately; never a shared key)

  nono's WFP policy remains the bypass detector for traffic that
  ignores this configuration (flag in pilot, block at Stage 3).

.NOTES
  Skeleton. TODO(stage-3): implement as an Intune remediation/platform
  script or settings-catalog profile via Graph
  (deviceManagement/deviceManagementScripts), targeted at the same
  Entra group provision-desktop-keys.ps1 reads.
#>

param(
  [string] $GatewayDnsName = "https://ai-gateway.twg.internal",
  [Parameter(Mandatory)] [string] $TargetEntraGroupId
)

# TODO(stage-3): Connect-MgGraph with DeviceManagementConfiguration.ReadWrite.All
# TODO(stage-3): create/update the profile setting HKCU/user env:
#   [Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL', $GatewayDnsName, 'User')
# TODO(stage-3): assignment to $TargetEntraGroupId; staged ring rollout.
