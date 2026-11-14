---
quick_id: 261110-mxi
description: Fix strict-mode property errors in Test-PopeyeAzureVerificationVm.ps1 and isolate NET-06 checks
---

The 2026-11-10 run stopped at "The property 'publicIpAddress' cannot be found": az omits absent properties and StrictMode Latest throws, which hid every NET-05/NET-06 row.

1. Add a strict-mode-safe `Get-Prop` helper; use it for NIC public IP, NSG ids, NSG rule port/source fields, subnet prefixes and extension fields.
2. Split NET-06 into its own try block so a NET-05 error cannot hide the login-role result.
3. Drop `--all` from `az role assignment list` (az rejects `--all` with `--scope`).
