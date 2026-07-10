<#
.SYNOPSIS
  Entra ID -> gateway virtual key lifecycle for desktop agent users.
  (Infrastructure plan section 1: PowerShell + Microsoft Graph.)

.DESCRIPTION
  Joiner/mover/leaver skeleton:
  - Members of the licensed Entra group get a per-user virtual key
    (team_id = desktop-agents, budget from policy) via /key/generate.
  - Departed members get their keys revoked (/key/delete); revocation
    propagation SLO is under 60 seconds (roadmap section 6).
  - Master key is used ONLY here, server-side; it never reaches a
    workstation (POC config guidance carried forward).

.NOTES
  Stage 3 rollout artifact. Run as a scheduled automation identity
  with Graph GroupMember.Read.All. TODO(stage-3): wire the key
  hand-off to the Intune-delivered user environment (see
  intune-baseurl-profile.ps1) instead of manual distribution.
#>

param(
  [Parameter(Mandatory)] [string] $GatewayBaseUrl,     # https://gateway-azure.ai.twg.internal
  [Parameter(Mandatory)] [string] $EntraGroupId,       # licensed desktop-agent users
  [Parameter(Mandatory)] [string] $MasterKeySecretUri, # Key Vault URI; resolved at runtime
  [decimal] $MonthlyBudgetUsd = 25.0
)

# TODO(stage-3): Connect-MgGraph -Identity (managed identity)
# TODO(stage-3): resolve master key from Key Vault via automation identity

$members = @() # TODO: Get-MgGroupMember -GroupId $EntraGroupId -All

foreach ($m in $members) {
  $body = @{
    user_id         = $m.UserPrincipalName
    team_id         = "desktop-agents"
    max_budget      = $MonthlyBudgetUsd
    budget_duration = "30d"
    models          = @("twg-foundry")   # allowlist per policy
  } | ConvertTo-Json

  # TODO: Invoke-RestMethod -Method Post -Uri "$GatewayBaseUrl/key/generate" `
  #   -Headers @{ Authorization = "Bearer $masterKey" } -Body $body -ContentType 'application/json'
  # TODO: record key->user mapping for leaver revocation; never log the key value.
}

# TODO(stage-3): leaver pass — revoke keys for users no longer in the group.
