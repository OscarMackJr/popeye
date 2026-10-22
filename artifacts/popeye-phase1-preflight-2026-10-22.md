# Popeye Phase 1 Preflight Record (2026-10-22)

Redacted and synthetic. No keys, DSNs, passwords, subscription IDs, resource group names, scope IDs or private IPs beyond CIDR level.

Recorded by plan 01-02 Task 3 from the operator's responses.

## Decisions

env-dns-owner: networking-owns
psql-on-vm: no
az-on-vm: no
foundry_scope_id-set: yes

## Detail

- env-dns-owner: networking-owns. Networking owns the Container Apps environment private DNS zone (zone name is the `defaultDomain` read from `az containerapp env show`, not recorded here). Reply reference: operator confirmation on 2026-10-22.
- psql-on-vm: no. Install pending, see `scripts/Install-PopeyeVmTooling.ps1`.
- az-on-vm: no. Install pending, see `scripts/Install-PopeyeVmTooling.ps1`.
- foundry_scope_id-set: yes. It is set in the operator's gitignored terraform.tfvars. The value is deliberately not recorded in the repo.

## Consequences

### Plan 05 (DNS / gateway networking)

- Popeye does NOT apply env DNS zone Terraform. Networking creates the zone, the `*` and `@` A records (equal to the environment staticIp) and the links to both VNets.
- No `caller_vnet_id` or Microsoft.Network/virtualNetworks/join/action permission is needed by Popeye.
- NET-03 stays blocked until networking creates the zone. `scripts/Test-PopeyeAzureVerificationVm.ps1` reports "zone missing: networking action pending" until then. Plan 09 hard-gates on resolution.

### Plan 08 (admin ceremony)

- psql and az are not on EUS-VM-POPEYE. Tooling must be installed and verified before the ceremony.
- Install via the non-secret run-command path (D-18), from the workstation:

  ```
  az vm run-command invoke -g <rg> -n EUS-VM-POPEYE --command-id RunPowerShellScript --scripts @scripts/Install-PopeyeVmTooling.ps1
  ```

  Use `-DryRun` first to see what would be done. Then confirm with `scripts/Test-PopeyeVerificationVm.ps1 -CheckTooling` (same run-command path).
- Plan 08 must not start until psql-on-vm and az-on-vm are re-recorded as yes.

### Foundry scope

- foundry_scope_id is set, so Foundry RBAC wiring can proceed without an additional operator input.
