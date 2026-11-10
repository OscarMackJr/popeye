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

## Egress probe (2026-10-27)

psql-on-vm: no
az-on-vm: no
vm-egress-443: blocked (all six destinations, TCP timeout)

- `scripts/Test-PopeyeVmEgress.ps1` via run-command on EUS-VM-POPEYE, 2026-10-27. Output reported `ROWS=7 (expect 7)`, and the positive control passed (Postgres private endpoint resolves into the Postgres subnet, TCP 5432 OK over the peering), so the probe read real results.
- Results:

  | Destination | DNS | TCP 443 | HTTPS |
  |---|---|---|---|
  | login.microsoftonline.com | resolves (public) | TIMEOUT | not reached |
  | management.azure.com | resolves (public) | TIMEOUT | not reached |
  | gateway Key Vault (`*.vault.azure.net`) | resolves (public) | TIMEOUT | not reached |
  | aka.ms | resolves (public) | TIMEOUT | not reached |
  | azcliprod.blob.core.windows.net | resolves (public) | TIMEOUT | not reached |
  | get.enterprisedb.com | resolves (public) | TIMEOUT | not reached |

- Reading: DNS works and every TCP connect on 443 times out, so traffic is dropped on the Azure network path (NSG outbound rule, a route to a firewall/NVA, or no outbound path for the subnet). It is not DNS and not TLS inspection.
- The gateway Key Vault accepts public network access (no `network_acls` in `envs/azure-eastus2/main.tf`), so `*.vault.azure.net` needs only the egress path.
- Results go back to networking (2026-10-27) with a request to check the VM NIC's effective security rules and effective routes. Networking also confirmed the env private DNS zone plan (`*` and `@` → environment staticIp, linked to both VNets, auto-registration off) and that the NSG cleanup (`Allow_Iliya_Promenet`) is done. User Login for both operators (NET-06) is not yet confirmed.
- Plan 08 stays held. Re-run this probe once networking reports the egress change; every destination should show TCP OK and an HTTPS status.

## Networking follow-up (2026-11-03)

vm-egress-443: blocked (no outbound path on the VM subnet)

- Networking asked where the traffic comes from. Reply sent 2026-11-03: the traffic starts on EUS-VM-POPEYE itself (no public IP, subnet 10.10.2.0/24), not from a workstation or from on-prem. Run-command executes in the VM guest OS, so the 2026-10-27 probe connections came from the VM's NIC. The Postgres positive control took the same path over the peering. The ceremony's interactive Bastion session (EUS-POPEY-BASTION) also starts traffic on the VM; Bastion only carries the session.
- The reply asks for an outbound path for the VM on TCP 443 (NAT gateway, firewall/NVA route with allow rules, or LB outbound rule):

  | Destination | Purpose | Need |
  |---|---|---|
  | login.microsoftonline.com | operator `az login` | ongoing |
  | management.azure.com | Azure CLI / ARM | ongoing |
  | `*.vault.azure.net` | Key Vault | ongoing |
  | aka.ms | Azure CLI installer (redirects to the next row) | one-time |
  | azcliprod.blob.core.windows.net | Azure CLI installer download | one-time |
  | get.enterprisedb.com | PostgreSQL client installer | one-time |

- The reply also asks again for NET-06 confirmation (User Login for both approved operators).
- Subnet read from the workstation (`az network vnet subnet show`, `az network nsg rule list`), 2026-11-03: `defaultOutboundAccess` is false (private subnet), there is no NAT gateway or route table on the subnet, and the subnet NSG has no custom rules. The subnet has no outbound internet path at all, which matches the TCP 443 timeouts. The fix is networking's: attach a NAT gateway, or a route table to a firewall/NVA with allow rules for the destinations above.
- Plan 08 stays held. Re-run `scripts/Test-PopeyeVmEgress.ps1` after networking reports the change.

## Networking response on egress design (2026-11-03)

vm-egress-443: blocked (by design, pending approved egress)

- Networking's position: no egress is the agreed design. EUS-VM-POPEYE has no public IP per security requirements, and security rejected assigning one. No centralized firewall/NVA or other approved outbound path exists for the subnet yet. They confirmed the probe reading: DNS works, private Postgres over the peering works, and outbound TCP 443 to public/Azure endpoints is unavailable. It is not a DNS issue.
- Once the central egress solution exists, networking will allow login.microsoftonline.com, management.azure.com and `*.vault.azure.net`, plus aka.ms, azcliprod.blob.core.windows.net and get.enterprisedb.com temporarily for installs.
- If access is needed sooner, networking offered to coordinate with security on an approved temporary egress method that keeps the private-access model.
- The NSG cleanup is confirmed done. Networking will check the VM User Login assignments separately (NET-06 still unconfirmed).
- Follow-up sent (2026-11-03): access is needed before the permanent firewall because it blocks the plan 08 ceremony. It asks for the temporary method, proposed as:
  1. A time-boxed NAT gateway on the VM subnet. There is no public IP on the VM and no inbound path. The subnet NSG allows outbound 443 only to the `AzureActiveDirectory`, `AzureResourceManager` and `AzureKeyVault` service tags and denies other internet traffic. It is removed once the central firewall is in place.
  2. For the one-time installers (no service tags exist for them), whichever security prefers: a short scheduled window allowing general internet access, closed afterwards; networking or security places the installers on the VM; or upgrading EUS-POPEY-BASTION to Standard for file upload.
  It also asks for a rough date for the central firewall.
- EUS-POPEY-BASTION is Basic SKU (read 2026-11-03), so Bastion file transfer is not available today.
- Plan 08 stays held. Re-run `scripts/Test-PopeyeVmEgress.ps1` once an egress path is in place. With the service-tag-only NSG, the three Azure destinations should show TCP OK. The installer destinations stay blocked unless the install window is open.

## Egress opened and tooling installed (2026-11-04)

psql-on-vm: yes
az-on-vm: yes
vm-egress-443: open (NAT gateway; NSG Internet outbound TCP 443 only)

- Networking's change (reported 2026-11-04): the VM stays private with no public IP. Outbound internet goes through an Azure NAT Gateway, and the NSG allows Internet-bound traffic only on TCP 443. Their tests show TCP 443 succeeding to all six destinations and TCP 80 failing to all six, with Postgres TCP 5432 over the peering still working.
- This is broader than the 2026-11-03 proposal (service-tag-only outbound): any HTTPS destination is reachable. Whether it will be tightened after the installs, or stays until the central firewall, has not been asked yet.
- Our re-run of `scripts/Test-PopeyeVmEgress.ps1` (run-command, 2026-11-04): `ROWS=7`, positive control PASS. TCP 443 OK to all six. HTTPS OK for login.microsoftonline.com (200), management.azure.com (400), the gateway Key Vault (405), azcliprod.blob.core.windows.net (400) and get.enterprisedb.com (403). aka.ms showed HTTPS FAIL ("Operation is not valid due to the current state of the object"). That is a Windows PowerShell 5.1 quirk with `-Method Head -MaximumRedirection 0` on a redirect, not a network fault: TCP was OK, and the Azure CLI install via aka.ms then succeeded.
- The Postgres private IP read by networking differs from the 2026-10-22 record. That is expected for a VNet-integrated Flexible Server after failover or restart. The scripts resolve by FQDN, so nothing depends on the IP.
- Tooling install (`scripts/Install-PopeyeVmTooling.ps1` via run-command):
  - Azure CLI 2.92.0 installed (`az version` PASS).
  - The psql binaries (EDB zip, 16.4-1) installed, but `psql --version` printed nothing and exited 0xC0000135 (DLL not found). The Visual C++ 2015-2022 x64 runtime was missing: Windows Server 2022 does not ship it and the EDB zip does not bundle it. A one-off install from `aka.ms/vs/17/release/vc_redist.x64.exe` (exit 0) fixed it, and `psql --version` then returned `psql (PostgreSQL) 16.4`.
  - `-CheckTooling` first reported both tools missing. Run-command's process keeps its start-time PATH and does not see machine PATH changes.
  - Run-command passes `X=true` as `-X true`, and for a switch the stray `true` bound positionally to the next parameter. The dry run showed "PostgreSQL client true".
- Script fixes, the same day:
  - `Install-PopeyeVmTooling.ps1` installs the Visual C++ runtime when vcruntime140.dll is missing, reports psql's exit code when it prints nothing, and re-reads the machine PATH before checking.
  - `Test-PopeyeVerificationVm.ps1 -CheckTooling` re-reads the machine PATH.
  - Both scripts use `PositionalBinding = $false` and a remaining-arguments catch that accepts only `true`.
  - Verified on the VM: `-CheckTooling` reports PASS for psql 16.4 and az 2.92.0. An installer dry run reports az, psql and vcruntime already present.
- Plan 08 tooling gate: met. Plan 08 stays held on NET-03 (env private DNS zone; the gateway FQDN must resolve from the VM) and NET-06 (User Login for both operators; networking is checking).

## Follow-up to networking (2026-11-04)

- Note sent 2026-11-04. It thanks networking and confirms our probe matches their results (HTTPS to all six destinations, Postgres over the peering, no public IP). It reports that the one-time Azure CLI and PostgreSQL client installs are done.
- Asks before the ceremony:
  1. NET-03: is the Container Apps environment private DNS zone created and linked to both VNets, with `*` and `@` records pointing to the environment staticIp? The gateway FQDN must resolve from the VM.
  2. NET-06: User Login status for both approved operators on EUS-VM-POPEYE.
  3. HTTPS scope: the NSG allows HTTPS to any Internet destination. With the installs done, only login.microsoftonline.com, management.azure.com and `*.vault.azure.net` are needed. The note offers narrowing to the `AzureActiveDirectory`, `AzureResourceManager` and `AzureKeyVault` service tags, and accepts the current rule until the central firewall if networking/security prefer. That is their call.
- Plan 08 stays held on NET-03 and NET-06 pending the reply.

## Networking update: NET-03 done, NET-06 pending decision (2026-11-04)

env-dns-resolution: resolved (zone created by networking)
gateway-from-vm: PASS (DNS and TCP 443, run-command preview)
net-06: pending program decision (Vinay)

- NET-03: networking created the Container Apps environment private DNS zone (the environment `defaultDomain`). It has `@` and `*` A records → the environment staticIp (TTL 3600) and is linked to both VNets (Stage 1/2 and EUS-POPEYE-VNET-01) with auto-registration off. The zone sits in the networking-owned VM resource group, not in Popeye's Terraform. That matches `env-dns-owner: networking-owns`. Their tests from the VM showed the domain and wildcard resolving to the staticIp and TCP 443 succeeding.
- Our check (`scripts/Test-PopeyeVerificationVm.ps1` via run-command, with the gateway Container App FQDN from `az containerapp list` and `-ExpectedGatewayIp` set to the staticIp): all PASS.

  | Check | Status |
  |---|---|
  | NET-04 Postgres resolves (RFC1918) | PASS |
  | NET-04 Postgres TCP 5432 | PASS |
  | NET-04 Gateway resolves (= staticIp) | PASS |
  | NET-04 Gateway TCP 443 | PASS |
  | VM has no public IP | PASS |

  The gateway FQDN has the `.internal.` label under the environment domain, so the wildcard record covers it. This is a run-command preview. The NET-04 evidence of record is still the interactive Bastion session run in plan 08/09.
- The first attempt failed on the 261104-p2v argument guard: run-command passes a blank argument when no switch is given. Fixed in both tooling scripts (blank arguments are ignored; anything other than blank or `true` is still rejected).
- NET-06: networking reviewed the VM RBAC. Only Oscar is assigned, with Virtual Machine Administrator Login at VM scope, per Vinay's original instruction to restrict the VM to Oscar. Before changing anything (Oscar to User Login; Roger to User Login and Reader), networking wants Vinay to confirm the revised access supersedes that restriction. No change made yet.
- Outbound HTTPS: networking recommends keeping the current 443-to-Internet rule through the ceremony, subject to Security's approval. Destination-based restriction (AzureActiveDirectory, AzureResourceManager, AzureKeyVault) will be revisited with the central firewall.
- Ownership: networking recommends Promenet keep managing the shared networking (VNet peering, private DNS, NSG policy) and offered to agree ownership boundaries with Popeye's Terraform. The Postgres private DNS integration is unchanged.
- Plan 08: the network and tooling gates are met. Remaining before the ceremony: Vinay's NET-06 decision (or explicit agreement that Oscar runs the ceremony alone with Admin Login and NET-06 is recorded as such), and Security's view on the temporary outbound rule.

## NET-06 decision (2026-11-04)

net-06: approved (Vinay), pending networking RBAC change

- Operator change: Oleg replaces Roger as the second approved operator for EUS-VM-POPEYE.
- Vinay's decision (2026-11-04): it is fine for Oleg and Oscar to have access to the VM as non-admins. This supersedes the original instruction restricting the VM to Oscar.
- Requested from networking: move Oscar from Virtual Machine Administrator Login to Virtual Machine User Login, and grant Oleg Virtual Machine User Login plus the narrow-scope Reader needed to connect through Bastion. No other principals.
- Verify after the change with `scripts/Test-PopeyeAzureVerificationVm.ps1 -ApprovedOperatorDisplayNames 'Oscar Mack','<Oleg display name>'`.

## NET-06 RBAC applied by networking (2026-11-10)

net-06: applied (networking), pending Popeye verification

- Networking reports the approved change is done on EUS-VM-POPEYE:
  - Oscar: Virtual Machine Administrator Login removed, replaced with Virtual Machine User Login.
  - Oleg: Virtual Machine User Login on the VM, plus Reader on the VM, its NIC and EUS-POPEY-BASTION for Bastion connectivity.
  - Roger: temporary Popeye access removed.
  - Networking reviewed the VM login role assignments; no other unapproved principals hold VM login roles.
- Outbound HTTPS (NAT gateway, NSG Internet outbound 443) is unchanged for the ceremony, as agreed.
- Still to do on our side, after RBAC propagation:
  1. `scripts/Test-PopeyeAzureVerificationVm.ps1 -ApprovedOperatorDisplayNames 'Oscar Mack','<Oleg display name>'`: NET-06 rows PASS (User Login limited to the two operators, both hold it, no Administrator Login).
  2. Oscar and Oleg each sign in through EUS-POPEY-BASTION with Entra credentials and confirm a non-admin session.
- NET-06 gets ticked once both pass. Anything unexpected goes back to networking.

## NET-06 control-plane verification (2026-11-10)

net-06: control plane PASS; Bastion sign-in by both operators pending

- `scripts/Test-PopeyeAzureVerificationVm.ps1` was run from the operator workstation after the 261110-mxi fix, with caller VNet `EUS-POPEYE-VNET-01` in `EUS-RG-POPEYE-VNET-01` and the VM in `EUS-RG-POPEYE-VM-01`. The VM subnet is named `EUS-POPEYE-VNET-02`. Evidence: `artifacts/popeye-azure-verification-evidence.json`.
- PASS:
  - NET-01: peering is Connected and FullyInSync both ways, and networking owns it.
  - NET-02: the Postgres private DNS zone is linked to both VNets, and public network access is Disabled.
  - NET-05: no public IP; the Bastion subnet is 10.10.3.0/26; no RDP allow rule from outside Bastion; the Entra sign-in extension is present.
  - NET-06: only the two approved operators hold Virtual Machine User Login (inherited assignments included), both hold it, and nobody has Administrator Login.
- FAIL, NET-03: the environment zone `ashyglacier-edb44cd7.eastus2.azurecontainerapps.io` (in `EUS-RG-POPEYE-VM-01`) has correct wildcard and apex A records → 10.60.0.108 and is linked to the caller VNet. It has **no link to `vnet-popeye-stage1-stage2-eastus2`**, which NET-03 requires. This does not block the ceremony, because the VM resolves the gateway through the caller VNet link (proven 2026-11-04). To raise with networking.
- The operator list is matched against the role assignment's `principalName`, which is the UPN, not the display name.
