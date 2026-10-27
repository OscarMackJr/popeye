---
quick_id: 261027-j3d
status: complete
completed: 2026-10-27
---

Added `scripts/Test-PopeyeVmEgress.ps1` and recorded its 2026-10-27 run on EUS-VM-POPEYE: positive control PASS, ROWS=7, and all six destinations resolve in DNS but time out on TCP 443 (dropped on the Azure network path). Results were drafted for the reply to networking. Networking confirmed the env DNS zone plan and the NSG cleanup; NET-06 User Login is still unconfirmed. Plan 01-08 stays held.

Verification: script parses clean; a workstation run under pwsh 7 with strict mode returned 7 rows, with HTTP statuses 200/302/400/403/405 all counted as reachable.
