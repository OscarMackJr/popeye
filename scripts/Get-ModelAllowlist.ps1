<#
.SYNOPSIS
  Derives a LiteLLM model allowlist from the source-controlled model approval registry.

.DESCRIPTION
  Popeye remains semantics-blind: this script enforces labels supplied by the
  classification process. It does not inspect prompts or infer content class.
#>

param(
  [string] $RegistryPath,
  [Parameter(Mandatory)] [string] $Cloud,
  [Parameter(Mandatory)] [string] $TeamId,
  [string] $DataClass
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
  $RegistryPath = Join-Path $PSScriptRoot "..\config\model-approval-registry.example.yaml"
}

function ConvertTo-PlainHashtable {
  param([Parameter(Mandatory)] $Value)

  if ($null -eq $Value) {
    return $null
  }

  if ($Value -is [System.Collections.IDictionary]) {
    $table = @{}
    foreach ($key in $Value.Keys) {
      $table[$key] = ConvertTo-PlainHashtable -Value $Value[$key]
    }
    return $table
  }

  if ($Value -is [pscustomobject]) {
    $table = @{}
    foreach ($property in $Value.PSObject.Properties) {
      $table[$property.Name] = ConvertTo-PlainHashtable -Value $property.Value
    }
    return $table
  }

  if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
    $items = @()
    foreach ($item in $Value) {
      $items += ConvertTo-PlainHashtable -Value $item
    }
    return $items
  }

  return $Value
}

function Read-RegistryWithFallbackParser {
  param([Parameter(Mandatory)] [string] $Path)

  $registry = @{
    data_classes = @()
    models       = @()
    teams        = @()
  }
  $section = $null
  $current = $null

  foreach ($rawLine in Get-Content -LiteralPath $Path) {
    $line = ($rawLine -replace "\s+#.*$", "").TrimEnd()
    if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) {
      continue
    }

    if ($line -match "^([A-Za-z_][A-Za-z0-9_]*):\s*$") {
      $section = $Matches[1]
      $current = $null
      continue
    }

    if ($section -eq "data_classes") {
      if ($line -match "^\s*-\s+(.+?)\s*$") {
        $registry.data_classes += $Matches[1].Trim('"')
        continue
      }
    }
    elseif ($section -in @("models", "teams")) {
      if ($line -match "^\s*-\s+([A-Za-z_][A-Za-z0-9_]*):\s*(.+?)\s*$") {
        $current = @{}
        $current[$Matches[1]] = $Matches[2].Trim('"')
        $registry[$section] += $current
        continue
      }
      if ($line -match "^\s+([A-Za-z_][A-Za-z0-9_]*):\s*(.+?)\s*$") {
        if ($null -eq $current) {
          throw "Invalid registry shape: field outside list item in section '$section'."
        }
        $current[$Matches[1]] = $Matches[2].Trim('"')
        continue
      }
    }

    throw "Unsupported registry YAML line: $rawLine"
  }

  return $registry
}

function Read-ModelApprovalRegistry {
  param([Parameter(Mandatory)] [string] $Path)

  $resolved = Resolve-Path -LiteralPath $Path
  $yaml = Get-Content -LiteralPath $resolved -Raw
  $converter = Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue

  if ($converter) {
    return ConvertTo-PlainHashtable -Value ($yaml | ConvertFrom-Yaml)
  }

  return Read-RegistryWithFallbackParser -Path $resolved
}

function Assert-KnownDataClass {
  param(
    [Parameter(Mandatory)] [string[]] $Classes,
    [Parameter(Mandatory)] [string] $Value,
    [Parameter(Mandatory)] [string] $FieldName
  )

  if ($Classes -notcontains $Value) {
    throw "Unknown data class '$Value' in $FieldName. Known classes: $($Classes -join ', ')."
  }
}

$resolvedRegistryPath = (Resolve-Path -LiteralPath $RegistryPath).Path
$registry = Read-ModelApprovalRegistry -Path $resolvedRegistryPath

foreach ($field in @("data_classes", "models", "teams")) {
  if (-not $registry.ContainsKey($field) -or $null -eq $registry[$field]) {
    throw "Invalid registry shape: missing '$field'."
  }
}

$classes = @($registry.data_classes)
if ($classes.Count -eq 0) {
  throw "Invalid registry shape: data_classes must not be empty."
}

$rank = @{}
for ($i = 0; $i -lt $classes.Count; $i++) {
  $rank[$classes[$i]] = $i
}

$team = @($registry.teams | Where-Object { $_.team_id -eq $TeamId } | Select-Object -First 1)
$effectiveDataClass = "internal"
if ($team.Count -gt 0 -and $team[0].ContainsKey("default_data_class")) {
  $effectiveDataClass = $team[0].default_data_class
}
if (-not [string]::IsNullOrWhiteSpace($DataClass)) {
  $effectiveDataClass = $DataClass
}

Assert-KnownDataClass -Classes $classes -Value $effectiveDataClass -FieldName "effective data_class"

$seenModels = @{}
foreach ($model in @($registry.models)) {
  foreach ($field in @("public_name", "cloud", "approved_max_data_class")) {
    if (-not $model.ContainsKey($field) -or [string]::IsNullOrWhiteSpace($model[$field])) {
      throw "Invalid registry shape: model entry missing '$field'."
    }
  }

  Assert-KnownDataClass -Classes $classes -Value $model.approved_max_data_class -FieldName "models[$($model.public_name)].approved_max_data_class"

  $modelKey = "$($model.public_name)|$($model.cloud)"
  if ($seenModels.ContainsKey($modelKey)) {
    throw "Invalid registry shape: duplicate model approval for '$($model.public_name)' in cloud '$($model.cloud)'."
  }
  $seenModels[$modelKey] = $true
}

foreach ($registryTeam in @($registry.teams)) {
  foreach ($field in @("team_id", "default_data_class")) {
    if (-not $registryTeam.ContainsKey($field) -or [string]::IsNullOrWhiteSpace($registryTeam[$field])) {
      throw "Invalid registry shape: team entry missing '$field'."
    }
  }
  Assert-KnownDataClass -Classes $classes -Value $registryTeam.default_data_class -FieldName "teams[$($registryTeam.team_id)].default_data_class"
}

$derivedModels = @(
  $registry.models |
    Where-Object {
      $_.cloud -eq $Cloud -and
      $rank[$_.approved_max_data_class] -ge $rank[$effectiveDataClass]
    } |
    ForEach-Object { $_.public_name }
)

if ($derivedModels.Count -eq 0) {
  throw "Derived allowlist is empty for team '$TeamId', cloud '$Cloud', data_class '$effectiveDataClass'."
}

[ordered]@{
  team_id       = $TeamId
  data_class    = $effectiveDataClass
  cloud         = $Cloud
  models        = $derivedModels
  registry_path = $resolvedRegistryPath
} | ConvertTo-Json -Compress
