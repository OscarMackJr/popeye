# Peered Caller Connectivity Evidence — 2026-10-22

Method: `az vm run-command invoke` (RunPowerShellScript, read-only DNS/TCP checks) on `EUS-VM-POPEYE`
(10.10.2.4, `EUS-POPEYE-VNET-01`, East US), peered to `vnet-popeye-stage1-stage2-eastus2`.
Run by: platform owner. No credentials were used or captured.

| Check | Result |
|---|---|
| Peering both directions | Connected / FullyInSync, VNet access allowed |
| `privatelink.postgres.database.azure.com` links | Both VNets, Completed |
| Postgres public network access | Disabled |
| Resolve `pg-popeye-stage1-stage2-eastus2.postgres.database.azure.com` | CNAME → `*.privatelink.postgres.database.azure.com` → 10.60.2.5 (RFC1918) — PASS |
| TCP 5432 to 10.60.2.5 | TcpTestSucceeded True — PASS |
| TCP 443 to Container Apps env static IP 10.60.0.108 | TcpTestSucceeded True — PASS |
| Resolve env domain `ashyglacier-edb44cd7.eastus2.azurecontainerapps.io` | DNS name does not exist — FAIL (no private DNS zone for the env domain) |

Open findings (control plane, same date):
- NSG `EUS-POPEYE-NSG` rule `Allow_Iliya_Promenet` permits inbound 3389 from an Internet address (VM has no public IP; still violates Bastion-only rule).
- VM login: one Administrator Login assignment remains (platform owner); second approved operator has none.
- No private DNS zone for the Container Apps environment domain → gateway FQDN unresolvable from callers; blocks the MVP smoke completion.
