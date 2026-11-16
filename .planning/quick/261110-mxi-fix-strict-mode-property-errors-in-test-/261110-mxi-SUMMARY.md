---
quick_id: 261110-mxi
status: complete
completed: 2026-11-10
---

`Test-PopeyeAzureVerificationVm.ps1` no longer throws on properties that az omits, such as a NIC with no public IP: a `Get-Prop` helper reads them safely. NET-06 now runs in its own block, and `az role assignment list` no longer passes `--all` together with `--scope`. The script parses cleanly and the helper was tested against mock NIC and subnet JSON. Live verification is the operator's re-run. The first run also showed the caller VNet `EUS-POPEYE-VNET-01` is not in `EUS-RG-POPEYE-VM-01`, so `-CallerResourceGroupName` must name its real resource group.
