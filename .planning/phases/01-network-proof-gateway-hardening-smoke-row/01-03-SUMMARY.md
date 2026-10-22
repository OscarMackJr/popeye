---
phase: 01-network-proof-gateway-hardening-smoke-row
plan: 03
subsystem: ops-scripts
tags: [powershell, postgres, litellm, smoke, lockdown]
requires: []
provides:
  - Azure ekg_cube_reader SQL (SELECT-only on LiteLLM_SpendLogs)
  - Smoke key mint/call/block/budget-probe script
  - Gateway lockdown negative-route test
  - Shared allowed_routes constant
affects: [01-08 admin ceremony]
key-files:
  created:
    - sql/ai_usage_grants_azure.sql
    - scripts/Set-PopeyeLedgerReader.ps1
    - config/llm-allowed-routes.json
    - scripts/Invoke-PopeyeSmoke.ps1
    - scripts/Test-PopeyeGatewayLockdown.ps1
  modified:
    - scripts/Test-PopeyeVerificationPsql.ps1
decisions:
  - "No explicit key_type; explicit allowed_routes list used instead (Pitfall 2)"
metrics:
  tasks: 2
  files: 6
completed: 2026-10-22
---

# Phase 1 Plan 03: Ceremony scripts Summary

Authored the reader SQL, ledger-reader helper, row-assertion extension, smoke script, lockdown script, and shared allowed-routes JSON for the plan 08 admin ceremony. Nothing was run against Azure, Postgres, or the gateway.

## Commits
- 97a1106: Azure reader SQL, Set-PopeyeLedgerReader.ps1, psql row assertion
- 4dc14ae: smoke script, lockdown test, llm-allowed-routes.json

## Deviations from Plan

### Verification limitation (environment)
The worktree sandbox refused to execute `pwsh`/`powershell` ("cannot be shown not to run git"). The PowerShell parse check and the `-DryRun` / `-ValidateOnly` offline runs were therefore NOT executed. Verified instead: Python JSON check of `config/llm-allowed-routes.json` passed; Grep acceptance checks passed (no write-SQL words in Test-PopeyeVerificationPsql.ps1, no Write-Host of secrets, no `key_type` in the smoke script). Plan 08 pre-flight (or the orchestrator) should run:
`pwsh -NoProfile -File scripts/Set-PopeyeLedgerReader.ps1 -KeyVaultName kv.invalid -DryRun` and the smoke `-DryRun` (with `-Count 3` exit 0, `-Count 0` non-zero), plus an AST parse of all four scripts.

Otherwise the plan was executed as written.

## Known Stubs
None.

## Self-Check: PASSED (files and commits exist; PowerShell execution checks deferred as noted)
