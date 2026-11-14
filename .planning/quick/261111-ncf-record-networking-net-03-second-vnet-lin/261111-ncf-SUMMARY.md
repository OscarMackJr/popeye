---
quick_id: 261111-ncf
status: complete
completed: 2026-11-11
---

Networking replied on 2026-11-11. The env DNS zone `ashyglacier-edb44cd7.eastus2.azurecontainerapps.io` is now linked to both `EUS-POPEYE-VNET-01` and `vnet-popeye-stage1-stage2-eastus2`, with auto-registration off, and by their check it resolves to 10.60.0.108. The reply is recorded in the preflight artifact, and STATE, HANDOFF and continue-here are updated. NET-03 stays unticked until our `Test-PopeyeAzureVerificationVm.ps1` re-run PASSes, and it gets ticked in 01-09.
