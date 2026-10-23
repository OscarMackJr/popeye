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

## Plan 05 outcome (2026-10-23)

env-dns-branch-taken: networking-owns
env-dns-resolution: blocked-on-networking

- Applied with default variables on 2026-10-23 (`manage_env_dns_zone = false`): only the ledger reader password and the `litellm-reader-dsn` Key Vault secret were added. The secret was confirmed by name only (`az keyvault secret list`). `terraform plan -detailed-exitcode` then exited 0.
- `scripts/Test-PopeyeVerificationVm.ps1` via run-command on EUS-VM-POPEYE: Postgres resolves into the Postgres subnet (RFC1918) and TCP 5432 connects (PASS); VM has no public IP (PASS); the gateway FQDN in the environment domain returns "DNS name does not exist" and TCP 443 fails.
- NET-03 blocked: awaiting networking (2026-10-23). Networking still has to create the environment private DNS zone with `*`/`@` records for the environment staticIp, linked to both VNets. Plan 09 hard-gates on this.

## Tooling install attempt (2026-10-23)

psql-on-vm: no
az-on-vm: no

- `scripts/Install-PopeyeVmTooling.ps1` via run-command failed with "Unable to connect to the remote server" on the first download (Azure CLI MSI, aka.ms). `-CheckTooling` confirms neither tool is on PATH.
- EUS-VM-POPEYE has no outbound internet. The ceremony (plan 08) is held until networking provides one of:
  - HTTPS egress for the installers (`aka.ms` / `azcliprod.blob.core.windows.net`, `get.enterprisedb.com`) and for operator `az login` (`login.microsoftonline.com`, `management.azure.com`, `*.vault.azure.net`); or
  - an approved way to place the installers on the VM, plus the Azure endpoints above.
- The env DNS zone (NET-03) is also still pending. Plan 08 needs the gateway FQDN to resolve from the VM.
