<#
.SYNOPSIS
  Validates endpoint-detection JSONL events and produces a content-free summary.

.DESCRIPTION
  Validates every JSONL record against the endpoint-detection/0.1 schema. A
  supplied webhook receives only the plain-text aggregate summary; no prompt or
  request-body data is accepted by the schema.
#>

param(
  [Parameter(Mandatory)] [string] $Path,
  [string] $SchemaPath = (Join-Path $PSScriptRoot "..\config\endpoint-detection.schema.json"),
  [string] $WebhookUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-StringConstraint {
  param($Value, $Definition, [string] $FieldName)

  if ($Value -isnot [string]) {
    throw "'$FieldName' must be a string."
  }
  if ($Definition.PSObject.Properties.Name -contains "minLength" -and $Value.Length -lt [int]$Definition.minLength) {
    throw "'$FieldName' must not be empty."
  }
  if ($Definition.PSObject.Properties.Name -contains "pattern" -and $Value -notmatch [string]$Definition.pattern) {
    throw "'$FieldName' does not match required pattern '$($Definition.pattern)'."
  }
  if ($Definition.PSObject.Properties.Name -contains "format" -and $Definition.format -eq "date-time") {
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Value, [ref]$parsed)) {
      throw "'$FieldName' must be an ISO-8601 date-time."
    }
  }
}

function Test-EndpointDetectionEvent {
  param($Event, $Schema)

  if ($Event -isnot [pscustomobject]) {
    throw "Event must be a JSON object."
  }

  $eventFields = @($Event.PSObject.Properties.Name)
  foreach ($requiredField in @($Schema.required)) {
    if ($eventFields -notcontains $requiredField) {
      throw "Missing required field '$requiredField'."
    }
  }
  if ($Schema.additionalProperties -eq $false) {
    foreach ($eventField in $eventFields) {
      if ($Schema.properties.PSObject.Properties.Name -notcontains $eventField) {
        throw "Unexpected field '$eventField'."
      }
    }
  }

  foreach ($property in $Schema.properties.PSObject.Properties) {
    $fieldName = $property.Name
    $definition = $property.Value
    $value = $Event.$fieldName
    if ($definition.PSObject.Properties.Name -contains "const" -and $value -ne $definition.const) {
      throw "'$fieldName' must equal '$($definition.const)'."
    }
    if ($definition.PSObject.Properties.Name -contains "type" -and $definition.type -eq "string") {
      Test-StringConstraint -Value $value -Definition $definition -FieldName $fieldName
    }
  }
}

$resolvedPath = (Resolve-Path -LiteralPath $Path).Path
$schema = Get-Content -LiteralPath $SchemaPath -Raw | ConvertFrom-Json
$errors = @()
$events = @()
$lineNumber = 0

foreach ($line in Get-Content -LiteralPath $resolvedPath) {
  $lineNumber++
  if ([string]::IsNullOrWhiteSpace($line)) {
    $errors += "Line ${lineNumber}: blank lines are not valid JSONL events."
    continue
  }
  try {
    $event = $line | ConvertFrom-Json -DateKind String
    Test-EndpointDetectionEvent -Event $event -Schema $schema
    $events += $event
  }
  catch {
    $errors += "Line ${lineNumber}: $($_.Exception.Message)"
  }
}

if ($errors.Count -gt 0) {
  throw "Endpoint detection validation failed:`n$($errors -join "`n")"
}

$summaryLines = @("Endpoint detections: $($events.Count)", "By workstation:")
foreach ($group in $events | Group-Object workstation | Sort-Object Name) {
  $summaryLines += "- $($group.Name): $($group.Count)"
}
$summaryLines += "By destination:"
foreach ($group in $events | Group-Object destination | Sort-Object Name) {
  $summaryLines += "- $($group.Name): $($group.Count)"
}
$summary = $summaryLines -join "`n"

if (-not [string]::IsNullOrWhiteSpace($WebhookUrl)) {
  Invoke-RestMethod -Method Post -Uri $WebhookUrl -ContentType "text/plain; charset=utf-8" -Body $summary | Out-Null
}

$summary
