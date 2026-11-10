---
quick_id: 261110-n1z
status: complete
completed: 2026-11-10
---

`Test-PopeyeAzureVerificationVm.ps1` ran on 2026-11-10 with the correct caller VNet resource group (`EUS-RG-POPEYE-VNET-01`). NET-01, NET-02, NET-05 and NET-06 PASS: only Oscar and Oleg hold Virtual Machine User Login, and nobody holds Administrator Login. NET-03 FAILs because the env DNS zone has no link to `vnet-popeye-stage1-stage2-eastus2`. That does not block the ceremony, and it still needs raising with networking. The result is recorded in the preflight artifact, the evidence JSON is regenerated, and the script example now uses the real resource groups and UPNs. NET-06 is ticked after both operators sign in through Bastion.
