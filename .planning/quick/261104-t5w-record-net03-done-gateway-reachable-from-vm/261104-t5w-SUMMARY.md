---
quick_id: 261104-t5w
status: complete
completed: 2026-11-04
---

Networking created the env private DNS zone (`*` and `@` → environment staticIp, linked to both VNets, auto-registration off), so NET-03 is done. From EUS-VM-POPEYE via run-command, all five checks PASS:
- Postgres resolves;
- Postgres TCP 5432;
- the gateway FQDN resolves to the expected staticIp;
- gateway TCP 443;
- no public IP.

Fixed the argument guard in both tooling scripts so blank run-command arguments are ignored. "bogus" is still rejected.

NET-06 is waiting on Vinay: networking kept Oscar on VM Administrator Login only, pending confirmation that User Login for Oscar and Roger supersedes the original restriction. Networking recommends keeping the 443-anywhere outbound rule through the ceremony, subject to Security, and wants Promenet to keep owning the shared networking. Plan 01-08 can proceed once NET-06 is settled.
