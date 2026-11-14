# 01-08 ceremony log (redacted; feeds Task 3)

- Pre-check 2026-11-14 18:13:50Z: pwsh 7.6.10, az, psql, kit 7 files on VM. Replicas (revision 0000006): cbpsn, fvg46.
- Step 1 grant: Key Vault Secrets User at secret scope on litellm-master-key, litellm-database-url, litellm-reader-dsn — all exit 0. **T0 = 2026-11-14 18:17:35Z**.
- Step 2 BLOCKED: `az login` in the Bastion session (pwsh 7.6.10, whoami /upn omack@). The broker (WAM) attempt failed with "You do not have permission to perform the requested action". The device-code / browser attempt (broker disabled) was blocked by Conditional Access: AADSTS53003, app Microsoft Azure CLI, request 8b60b5c8-17ad-44f0-945f-4b586fd55800, 2026-11-14T18:42:39Z, IP 20.231.80.239 (NAT gateway), device state Registered. No secret read yet. Needs an IT CA exception.
- Broker retry (`az config unset core.enable_broker_on_windows; az login`), twice: "The request has timed out.. Status: Response_Status.Status_NoNetwork, Error code: 3400019682". Hypothesis (unconfirmed): the NSG allows TCP 443 only, and the broker's port-80 CRL/OCSP checks fail. Recommended aborting the window and removing the grants.
- The operator's first removal attempt ran in the Bastion session ($oid/$kv empty there): every delete failed, and its "remaining: 0" lines were empty reads. A workstation check showed all 3 grants still present.
- Window closed from the workstation: 3 deletes rc=0, lists returned (exit 0) with 0 remaining. **T1 (aborted) = 2026-11-14 18:49:10Z**. No secret was read in the window.
