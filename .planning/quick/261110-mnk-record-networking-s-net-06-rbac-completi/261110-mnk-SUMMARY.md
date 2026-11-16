---
quick_id: 261110-mnk
status: complete
completed: 2026-11-10
---

Networking applied the NET-06 change on EUS-VM-POPEYE. Oscar moved from Administrator Login to User Login. Oleg has User Login plus Reader on the VM, its NIC and EUS-POPEY-BASTION. Roger's temporary access was removed. Networking found no other principals in the VM login roles. Outbound HTTPS is unchanged for the ceremony. The reply is recorded in the preflight artifact, and STATE, HANDOFF and continue-here now show NET-06 as applied, with our verification pending. NET-06 stays unticked until `Test-PopeyeAzureVerificationVm.ps1` passes and both operators sign in through Bastion.
