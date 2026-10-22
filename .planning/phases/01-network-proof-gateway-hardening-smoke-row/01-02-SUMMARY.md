---
phase: 01-network-proof-gateway-hardening-smoke-row
plan: 02
subsystem: network-verification
tags: [powershell, azure, peering, private-dns, bastion, verification]
requires: []
provides:
  - Control-plane checks for NET-01, NET-02, NET-03, NET-05, NET-06 with JSON evidence
  - VM-side Postgres and gateway FQDN DNS/TCP checks (NET-04) and tooling preflight
  - Amended verification procedure permitting a time-boxed master-key grant
  - Preflight record: env DNS owner, VM tooling, foundry_scope_id
  - VM tooling install script
affects: [01-05, 01-08, 01-09]
tech-stack:
  added: []
  patterns: [read-only verification scripts, run-command for non-secret checks only]
key-files:
  created:
    - artifacts/popeye-phase1-preflight-2026-10-22.md
    - scripts/Install-PopeyeVmTooling.ps1
  modified:
    - scripts/Test-PopeyeAzureVerificationVm.ps1
    - scripts/Test-PopeyeVerificationVm.ps1
    - specs/POPEYE_VERIFICATION_VM_TEST_PROCEDURE.md
key-decisions:
  - "Env DNS zone owned by networking: Popeye does not apply env DNS Terraform (plan 05)"
  - "D-08 extended (user-approved): time-boxed secret-scoped grants on litellm-master-key and litellm-database-url / litellm-reader-dsn for the platform owner"
  - "Tooling on EUS-VM-POPEYE installed via run-command script before the ceremony (plan 08)"
requirements-completed: [NET-01, NET-02, NET-03, NET-04, NET-05, NET-06]
duration: multi-session (checkpoint)
completed: 2026-10-22
---

# Phase 1 Plan 02: Network verification scripts, procedure amendment, preflight Summary

Read-only peered-caller verification scripts (NET-01..06), a procedure amendment for the time-boxed admin-ceremony grants, and a recorded preflight showing networking owns the env DNS zone and that psql/az must be installed on the VM first.

## Tasks

| Task | Name | Commit |
|------|------|--------|
| 1 | Extend control-plane script for peered caller VNet | d37a551 |
| 2 | VM script gateway FQDN checks + tooling preflight; procedure step 7 amendment | 4043885, ced4544 |
| 3 | Preflight decision record + tooling install script | 91ab0f4 |

## Preflight outcomes

- env-dns-owner: networking-owns (plan 05 must not apply env DNS Terraform; NET-03 waits on networking, plan 09 hard-gates)
- psql-on-vm: no, az-on-vm: no (install pending via `scripts/Install-PopeyeVmTooling.ps1`; required before plan 08)
- foundry_scope_id-set: yes (value not recorded in repo)

## Deviations from Plan

**1. [Rule 2 - Missing critical functionality, user-requested] Added scripts/Install-PopeyeVmTooling.ps1**
- **Found during:** Task 3
- **Issue:** psql and az are absent on the VM, blocking the plan 08 ceremony and `-PsqlDsn` checks.
- **Fix:** Idempotent installer with `-DryRun`, Azure CLI via official MSI, psql 16.x client via winget else EDB zip; no secrets, no logins; run-command invocation documented in the header.
- **Files:** scripts/Install-PopeyeVmTooling.ps1
- **Commit:** 91ab0f4

**2. [User confirmation] D-08 extension approved**
- The user approved both the `litellm-master-key` grant and the extension to `litellm-database-url` / `litellm-reader-dsn`; the procedure records the confirmation (commit ced4544). Salt and writer secrets remain forbidden; the VM identity gets no Key Vault grant.

## Verification notes

- All three scripts parse cleanly with the PowerShell AST parser (Install script confirmed in this session).
- Nothing was run against live Azure; the install script and VM script are unexecuted pending the operator's run-command.
- The installer's pinned psql version (16.4-1) and EDB download URL are unverified against the live download site; confirm with `-DryRun` and the first real run, adjust `-PsqlVersion` if the URL 404s.

## Known Stubs

None.

## Threat Flags

None. The install script downloads binaries (aka.ms MSI, EDB zip) over HTTPS without hash pinning; accepted for an internal verification VM, noted for plan 08 review.

## Self-Check: PASSED

Files exist (preflight artifact, install script); commits d37a551, 4043885, ced4544, 91ab0f4 present.
