---
phase: 01-network-proof-gateway-hardening-smoke-row
plan: 05
subsystem: networking, key-vault
tags: [terraform, private-dns, key-vault, net-03, mvp-01]
requires: [01-02, 01-04]
provides:
  - Count-gated env private DNS zone Terraform (manage_env_dns_zone, default false)
  - default_domain / static_ip module outputs; env_default_domain / env_static_ip root outputs
  - litellm-reader-dsn Key Vault secret (ekg_cube_reader password, role created by SQL in plan 08)
affects: [01-08 admin ceremony, 01-09 network evidence]
key-files:
  modified:
    - modules/gateway-service-azure/outputs.tf
    - envs/azure-eastus2/variables.tf
    - envs/azure-eastus2/main.tf
    - envs/azure-eastus2/outputs.tf
    - scripts/Test-PopeyeVerificationVm.ps1
    - scripts/Test-PopeyeGatewayLockdown.ps1
    - artifacts/popeye-phase1-preflight-2026-10-22.md
decisions:
  - "networking-owns branch taken: Popeye applied defaults only; env DNS zone left to networking (D-14, D-17)"
metrics:
  tasks: 3
  files: 7
completed: 2026-10-23
---

# Phase 1 Plan 05: Env DNS Terraform and reader DSN secret Summary

The env DNS Terraform is ready but turned off (`manage_env_dns_zone = false`), because networking owns the zone. Its name and IP come from the new module outputs. The `litellm-reader-dsn` secret is in the gateway Key Vault (applied 2026-10-23, confirmed by name only), and `terraform plan -detailed-exitcode` exits 0. From the peered caller VM, Postgres resolves privately and TCP 5432 connects. The gateway FQDN does not resolve yet, so NET-03 is recorded as blocked on networking in `artifacts/popeye-phase1-preflight-2026-10-22.md`. Plan 09 hard-gates on it.

## Commits
- 071e489: module outputs and root variables for env DNS
- 3bf47fc: conditional env DNS zone and ledger reader DSN secret
- e828291: allow an empty results list in verification check helpers
- dfa8db9: skip CNAME records in the VM DNS check and stop truncating details

## Deviations from Plan

### [Rule 1 - Bug] Verification helpers rejected an empty results list
`Add-Result` and `Test-NameAndPort` declared `$Results` as Mandatory without `[AllowEmptyCollection()]`. The first call threw before any check ran. The same pattern was in `Test-PopeyeGatewayLockdown.ps1` (used in plan 08), and both are fixed.

### [Rule 1 - Bug] Postgres DNS reported FAIL while resolution worked
`Resolve-DnsName` returns the privatelink CNAME hop, which has no `IPAddress` property, and strict mode threw on it. The script now skips records without that property. The result table now wraps at width 200 so run-command output is not truncated.

### Windows az.cmd quoting
`--query` strings containing `(`, `,`, `'`, `?` or `==` are mangled by the `az.cmd` wrapper in PowerShell. In the operator steps, filtering is done in PowerShell instead.

## Known Stubs
None. The DNS zone resources are intentionally count-gated off.

## Self-Check: PASSED (reader secret present, no drift; NET-03 blocked-on-networking recorded)
